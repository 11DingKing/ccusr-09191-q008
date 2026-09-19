ExUnit.start()

defmodule RetrofitControl.TestFactory do
  @moduledoc "测试用：构造彼此隔离的内存/文件控制塔实例与基础世界。"
  alias RetrofitControl.{Tower, EventLog, Procurement.SimAdapter}

  def unique(base), do: :"#{base}_#{:erlang.unique_integer([:positive])}"

  @doc "启动内存事件日志 + 模拟采购系统 + 控制塔（互不影响其它测试）。"
  def start_tower do
    log = unique(:Log)
    adapter = unique(:Sim)
    tower = unique(:Tower)

    {:ok, _} = EventLog.start_link(name: log, path: nil)
    {:ok, _} = SimAdapter.start_link(name: adapter, fail_first: 0)

    {:ok, _} =
      Tower.start_link(
        name: tower,
        event_log: log,
        adapter: SimAdapter,
        adapter_name: adapter,
        path: nil
      )

    %{tower: tower, log: log, adapter: adapter}
  end

  @doc "在指定目录启动文件持久化的控制塔（用于断点恢复测试）。"
  def start_persisted(dir, fail_first \\ 0) do
    log = unique(:LogP)
    adapter = unique(:SimP)
    tower = unique(:TowerP)

    {:ok, _} = EventLog.start_link(name: log, path: Path.join(dir, "events.log"), fsync: false)
    {:ok, _} = SimAdapter.start_link(name: adapter, fail_first: fail_first)

    {:ok, _} =
      Tower.start_link(
        name: tower,
        event_log: log,
        adapter: SimAdapter,
        adapter_name: adapter,
        path: dir
      )

    %{tower: tower, log: log, adapter: adapter, dir: dir}
  end

  def stop_all(%{tower: t, log: l, adapter: a}) do
    stop(t)
    stop(l)
    stop(a)
    :ok
  end

  defp stop(name) do
    pid = Process.whereis(name)
    if pid && Process.alive?(pid), do: GenServer.stop(name, :normal, 1000)
  rescue
    _ -> :ok
  end

  @doc """
  播种一个基础世界：
  产线 L1、设备 D1（能力可定制）、合同 C1 v1、总预算与风险储备、阶段 P1。
  """
  def seed_world(t, opts \\ []) do
    caps = Keyword.get(opts, :caps, ["5g_nsa", "mqtt", "opcua"])
    total = Keyword.get(opts, :total, 100_000)
    reserve = Keyword.get(opts, :reserve, 20_000)
    amount = Keyword.get(opts, :amount, 30_000)
    required = Keyword.get(opts, :required, ["5g_nsa", "mqtt"])
    vendor = Keyword.get(opts, :vendor, "vendorA")
    planned_end = Keyword.get(opts, :planned_end, ~D[2026-12-31])

    ok!(Tower.register_line(t, %{id: "L1", name: "一号装配线"}))

    ok!(
        Tower.catalog_device(t, %{
          id: "D1",
          line_id: "L1",
          kind: "gateway",
          class: "GW-X1",
          caps: caps,
          vendor_id: vendor
        })
      )

    ok!(
        Tower.record_contract(t, %{
          id: "C1",
          line_id: "L1",
          vendor_id: vendor,
          version: 1,
          effective_from: ~D[2026-01-01]
        })
      )

    ok!(Tower.configure_budget(t, %{total: total, reserve: reserve}))

    ok!(
        Tower.plan_phase(t, %{
          id: "P1",
          line_id: "L1",
          seq: 1,
          name: "5G网关上线",
          device_class: "GW-X1",
          required_caps: required,
          planned_end: planned_end,
          amount_cents: amount,
          vendor_id: vendor
        })
      )

    ok!(
        Tower.record_quote(t, %{
          id: "Q1",
          vendor_id: vendor,
          version: 1,
          amount_cents: amount,
          contract_id: "C1",
          line_id: "L1"
        })
      )

    %{line: "L1", device: "D1", contract: "C1", phase: "P1", vendor: vendor}
  end

  def submit(t, phase, contract, overrides \\ %{}) do
    params =
      Map.merge(
        %{
          phase_id: phase,
          vendor_id: "vendorA",
          contract_version_id: contract,
          device_caps: ["5g_nsa", "mqtt", "opcua"],
          evidence: %{"firmware" => "1.4.2"}
        },
        overrides
      )

    Tower.submit_acceptance(t, params)
  end

  def ok!({:ok, result}), do: result
  def ok!(other), do: raise("expected {:ok, _}, got: #{inspect(other)}")

  def err!({:error, reason}), do: reason
  def err!(other), do: raise("expected {:error, _}, got: #{inspect(other)}")
end
