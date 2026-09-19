defmodule RetrofitControl.Procurement.MockServer do
  @moduledoc """
  外部采购系统的模拟实现（演示/无网环境使用）。

  行为模拟真实采购系统：
  * 按 `Idempotency-Key` 幂等：重复提交返回首次结果（409 + 原回执）；
  * 支持通过 X-Mock-Mode 头注入 reject / fail / pending，用于演示补偿流程；
  * 采购单号大于内置额度时直接拒单。

  这是“外部系统”：本项目的 Journal 不覆盖它，它的去重状态独立存在，
  用于验证我们这一侧的补偿与重试在真实语义下是否正确。
  """

  use Agent

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %{seen: %{}} end, name: __MODULE__)
  end

  def reset do
    Agent.update(__MODULE__, fn _ -> %{seen: %{}} end)
  end

  @doc "测试直接调用（不经 HTTP）。"
  def create_purchase_order(po, mode \\ "ok") do
    key = po.idempotency_key

    case Agent.get(__MODULE__, &Map.fetch(&1.seen, key)) do
      {:ok, first} ->
        # 模拟真实系统的幂等：重复请求返回首次结果
        {:duplicate, first}

      :error ->
        result = decide(po, mode)

        # 网络故障不代表对方受理：不落去重表，允许后续安全重试
        if match?({:error, _}, result) do
          {:first, result}
        else
          Agent.update(__MODULE__, fn st ->
            put_in(st.seen[key], result)
          end)

          {:first, result}
        end
    end
  end

  defp decide(po, mode) do
    cond do
      mode == "reject" ->
        {:rejected, %{reason: "模拟采购系统拒单：供应商资质过期"}}

      mode == "fail" ->
        {:error, :mock_network_failure}

      mode == "pending" ->
        {:pending, %{}}

      po.amount_cents < 0 ->
        {:rejected, %{reason: "扣款金额为负（罚则超过费用）"}}

      true ->
        {:ok, %{external_ref: "EXT-" <> String.upcase(po.id)}}
    end
  end
end

defmodule RetrofitControl.Procurement.MockClient do
  @moduledoc "投递器使用的内存客户端，默认成功；可通过 set_mode/1 注入故障。"

  @behaviour RetrofitControl.Procurement.Client

  use Agent

  def start_link(_), do: Agent.start_link(fn -> %{mode: "ok"} end, name: __MODULE__)

  def set_mode(mode), do: Agent.update(__MODULE__, &%{&1 | mode: mode})

  @impl true
  def create_purchase_order(po) do
    mode = Agent.get(__MODULE__, & &1.mode)

    case RetrofitControl.Procurement.MockServer.create_purchase_order(po, mode) do
      {:first, result} -> result
      {:duplicate, first} ->
        # 模拟真实系统的幂等：重复请求返回首次确认结果
        case first do
          {:ok, %{external_ref: ref}} -> {:confirmed, %{external_ref: ref}}
          other -> other
        end
    end
  end
end
