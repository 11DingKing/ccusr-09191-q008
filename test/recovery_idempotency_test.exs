defmodule RetrofitControl.RecoveryIdempotencyTest do
  use ExUnit.Case, async: false
  import RetrofitControl.TestFactory
  alias RetrofitControl.{Tower, EventLog, Domain, Procurement.SimAdapter}

  setup do
    dir = Path.join(System.tmp_dir!(), "tower_rec_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp stack(dir, fail_first \\ 0) do
    uniq = :erlang.unique_integer([:positive])
    log = :"rec_log_#{uniq}"
    ada = :"rec_ada_#{uniq}"

    {:ok, _} =
      EventLog.start_link(name: log, path: Path.join(dir, "events.log"), fsync: false)

    {:ok, _} = SimAdapter.start_link(name: ada, fail_first: fail_first)

    tower = start_tower_only(dir, log, ada)
    %{dir: dir, log: log, ada: ada, tower: tower}
  end

  defp start_tower_only(dir, log, ada) do
    tower = :"rec_t_#{:erlang.unique_integer([:positive])}"

    {:ok, _} =
      Tower.start_link(
        name: tower,
        event_log: log,
        adapter: SimAdapter,
        adapter_name: ada,
        path: dir
      )

    tower
  end

  # 模拟控制塔进程崩溃后，仅重启 Tower（事件日志与文件保留），再执行断点恢复。
  defp restart_tower(dir, log, ada, old) do
    GenServer.stop(old)
    tower = start_tower_only(dir, log, ada)
    {:ok, info} = Tower.recover_restart(tower)
    {tower, info}
  end

  test "服务重启后通过事件重放恢复阶段、预算、台账与审计", %{dir: dir} do
    %{tower: t, log: log, ada: ada} = stack(dir)
    seed_world(t)
    {:ok, %{submission_id: sid}} = submit(t, "P1", "C1")
    {:ok, _} = Tower.approve(t, sid, "厂长")
    ok!(Tower.confirm_accepted(t, %{phase_id: "P1", completed_at: ~D[2026-11-05]}))

    before = Tower.state(t)
    assert before.phases["P1"].status == :accepted
    spent = Domain.totals(before).spent
    audit_n = length(before.audits)

    {t2, info} = restart_tower(dir, log, ada, t)
    assert info.replayed > 0

    after_state = Tower.state(t2)
    assert after_state.phases["P1"].status == :accepted
    assert Domain.totals(after_state).spent == spent
    assert length(after_state.audits) == audit_n
    assert after_state.safety_nodes["L1"] == 1
  end

  test "离线暂存结果随事件重放恢复，重启后仍可补传", %{dir: dir} do
    %{tower: t, log: log, ada: ada} = stack(dir)
    seed_world(t)

    ok!(
      Tower.store_offline_result(t, %{
        stored_key: "off-restart",
        phase_id: "P1",
        vendor_id: "vendorA",
        contract_version_id: "C1",
        device_caps: ["5g_nsa", "mqtt"]
      })
    )

    {t2, _} = restart_tower(dir, log, ada, t)

    assert Map.has_key?(Tower.state(t2).offline_store, "off-restart")
    {:ok, bf} = Tower.backfill_acceptance(t2, "off-restart")
    assert bf.backfilled == true
  end

  test "带快照的恢复：快照之后的事件被增量重放", %{dir: dir} do
    %{tower: t, log: log, ada: ada} = stack(dir)
    seed_world(t)
    :ok = Tower.snapshot_now(t)
    {:ok, %{submission_id: sid}} = submit(t, "P1", "C1")
    {:ok, _} = Tower.approve(t, sid, "厂长")

    {t2, info} = restart_tower(dir, log, ada, t)
    # 快照覆盖了播种事件，只需重放其后事件
    assert info.from_snapshot > 0
    assert Tower.state(t2).phases["P1"].status == :approved
  end

  test "同一幂等键重复批准只锁定一次预算", %{dir: dir} do
    %{tower: t} = stack(dir)
    seed_world(t)

    {:ok, %{submission_id: sid}} = submit(t, "P1", "C1")

    {:ok, first} = Tower.approve(t, sid, "厂长", "approve-key-7")
    assert first.decision == :approved
    {:ok, second} = Tower.approve(t, sid, "厂长", "approve-key-7")
    assert second.idempotent == true

    totals = Domain.totals(Tower.state(t))
    assert totals.committed == 30_000

    holds =
      Tower.state(t).ledger
      |> Map.values()
      |> Enum.filter(&(&1.kind == :hold))

    assert length(holds) == 1
  end

  test "每次批准/驳回/回滚/占用都有独立递增的审计事件", %{dir: dir} do
    %{tower: t} = stack(dir)
    seed_world(t, total: 20_000, reserve: 30_000)

    {:ok, %{submission_id: sid}} = submit(t, "P1", "C1")
    {:ok, _} = Tower.approve(t, sid, "厂长")

    audits = Tower.audits(t)
    seqs = Enum.map(audits, & &1.seq)
    assert seqs == Enum.sort(seqs)
    assert seqs == Enum.uniq(seqs)

    approve_audit = Enum.find(audits, &(&1.action == :approve))
    assert approve_audit.result == :ok
    assert approve_audit.safety_node == 1
    assert approve_audit.contract_version_id == "C1"
  end
end
