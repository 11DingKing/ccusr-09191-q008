defmodule RetrofitControl.Procurement.Dispatcher do
  @moduledoc """
  采购出站投递器（outbox 模式 + 幂等补偿）：

  * 批准产生的 `po_created` 事件先落盘，再由本进程异步投递外部采购系统；
  * 外部系统以采购单号做 Idempotency-Key 去重，因此超时可安全重试；
  * 成功回执 CONFIRMED 落审计；失败回执 REJECTED 触发补偿（po_compensated）；
  * 服务重启时扫描 `PENDING_CONFIRM` 的采购单继续投递——断点恢复；
  * 指数退避，避免故障时打爆采购系统。

  所有状态推进仍通过 Engine 命令走 Journal，投递器本身不持有业务事实。
  """

  use GenServer

  require Logger

  alias RetrofitControl.Engine

  @tick_ms 500

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)
  end

  @doc "立即尝试投递全部待处理采购单（测试用，不用等退避计时）。"
  def flush(server \\ __MODULE__) do
    GenServer.call(server, :flush, :infinity)
  end

  def status(server \\ __MODULE__) do
    GenServer.call(server, :status)
  end

  # ── GenServer ──

  @impl true
  def init(opts) do
    state = %{
      attempts: %{},
      client: opts[:client] || Engine.procurement_client(),
      engine: opts[:engine] || Engine,
      auto: Keyword.get(opts, :auto, true),
      failures: 0
    }

    if state.auto, do: Process.send_after(self(), :tick, 50)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    state = dispatch_pending(state)
    Process.send_after(self(), :tick, @tick_ms)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def handle_call(:flush, _from, state) do
    state = dispatch_pending(Map.put(state, :force, true))
    {:reply, :ok, state}
  end

  def handle_call(:status, _from, state) do
    {:reply, %{attempts: state.attempts, failures: state.failures}, state}
  end

  defp dispatch_pending(state) do
    force = Map.get(state, :force, false)
    state = Map.delete(state, :force)
    # engine 可能是注册名（atom）或 PID：GenServer.call 两者都支持，
    # 但 Kernel.apply/2 只接受模块名，因此这里统一走 call。
    pending = GenServer.call(state.engine, :pending_pos)

    Enum.reduce(pending, state, fn po, acc ->
      if force do
        do_dispatch(acc, po)
      else
        attempts = Map.get(acc.attempts, po.id, 0)
        backoff_ticks = min(:math.pow(2, attempts) |> trunc(), 30)

        if attempts > 0 and rem(:erlang.phash2(po.id, 1000) + 1, backoff_ticks + 1) != 0 do
          acc
        else
          do_dispatch(acc, po)
        end
      end
    end)
  end

  defp do_dispatch(state, po) do
    client = state.client
    attempts = Map.get(state.attempts, po.id, 0) + 1

    case safe_call(client, :create_purchase_order, [po]) do
      {:ok, %{external_ref: ref}} ->
        apply_receipt(state.engine, po.id, "CONFIRMED", %{external_ref: ref})
        %{state | attempts: Map.put(state.attempts, po.id, attempts)}

      {:confirmed, %{external_ref: ref}} ->
        apply_receipt(state.engine, po.id, "CONFIRMED", %{external_ref: ref})
        state

      {:rejected, %{reason: reason}} ->
        apply_receipt(state.engine, po.id, "REJECTED", %{reason: reason})
        %{state | attempts: Map.put(state.attempts, po.id, attempts), failures: state.failures + 1}

      {:pending, _} ->
        # 外部系统异步回执，等待 receive_receipt
        state

      {:error, reason} ->
        Logger.warning("采购单 #{po.id} 投递失败（第 #{attempts} 次）：#{inspect(reason)}，将按退避重试")
        %{state | attempts: Map.put(state.attempts, po.id, attempts), failures: state.failures + 1}
    end
  end

  defp apply_receipt(engine, po_id, status, extra) do
    params =
      Map.merge(%{po_id: po_id, status: status}, extra)
      |> Map.put(:idempotency_key, "receipt-auto:#{po_id}:#{status}")

    idem = params[:idempotency_key]

    case GenServer.call(engine, {:command, :receive_receipt, params, idem}) do
      {:ok, _view} ->
        :ok

      {:error, reason} ->
        # 已被其他回执处理等冲突不重试，仅记录
        Logger.info("采购单 #{po_id} 回执落库跳过：#{inspect(reason)}")
    end
  end

  defp safe_call(mod, fun, args) do
    apply(mod, fun, args)
  rescue
    e -> {:error, {:exception, e}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end
end
