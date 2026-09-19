defmodule RetrofitControl.Procurement.Adapter do
  @moduledoc """
  外部采购系统边界。

  生产环境可替换为真实 HTTP/SOAP 客户端（通过 RetrofitControl.Platform 配置注入）。
  这里提供内存模拟实现，支持“前 N 次派发失败、随后成功、回执可重复送达”，
  用于验证采购回执的幂等补偿流程。

  关键约定：外部系统以 `order_key` 做幂等键；重复派发同一 key 不会产生第二张真实订单。
  """

  @callback dispatch(order :: map, config :: term) ::
              {:ok, dispatch_ref :: binary} | {:error, term}

  @callback confirm_receipt(dispatch_ref :: binary, config :: term) ::
              {:ok, receipt_key :: binary} | {:error, term}
end

defmodule RetrofitControl.Procurement.SimAdapter do
  @moduledoc "内存模拟采购系统，进程状态记录真实订单，保证外部侧也幂等。"
  @behaviour RetrofitControl.Procurement.Adapter

  use Agent

  def start_link(opts \\ []) do
    Agent.start_link(
      fn ->
        %{
          fail_first: Keyword.get(opts, :fail_first, 0),
          attempts: %{},
          dispatched: %{},
          receipts: %{}
        }
      end,
      name: opts[:name] || __MODULE__
    )
  end

  @impl true
  def dispatch(order, name \\ __MODULE__) do
    Agent.get_and_update(name, fn st ->
      n = Map.get(st.attempts, order.order_key, 0) + 1
      st = put_in(st.attempts[order.order_key], n)

      cond do
        Map.has_key?(st.dispatched, order.order_key) ->
          ref = st.dispatched[order.order_key]
          {{:ok, ref}, st}

        n <= st.fail_first ->
          {{:error, "external system temporarily unavailable (attempt #{n})"}, st}

        true ->
          ref = "po-ref-#{order.order_key}"
          {{:ok, ref}, put_in(st.dispatched[order.order_key], ref)}
      end
    end)
  end

  @impl true
  def confirm_receipt(ref, name \\ __MODULE__) do
    Agent.get(name, fn st ->
      case Enum.find(st.dispatched, fn {_k, r} -> r == ref end) do
        nil ->
          {:error, "unknown dispatch ref"}

        {key, _} ->
          {:ok, Map.get(st.receipts, ref, "receipt-#{key}")}
      end
    end)
  end

  @doc "模拟采购系统主动推送回执（可能重复推送）。"
  def push_receipt(name \\ __MODULE__, order_key, receipt_key) do
    Agent.update(name, fn st ->
      ref = "po-ref-#{order_key}"
      put_in(st.receipts[ref], receipt_key)
    end)
  end

  def state(name \\ __MODULE__), do: Agent.get(name, & &1)
end
