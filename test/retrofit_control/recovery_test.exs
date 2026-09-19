defmodule RetrofitControl.RecoveryTest do
  use ExUnit.Case, async: false

  import RetrofitControl.Scenario
  alias RetrofitControl.{Engine, Journal, TestFactory, Util, Procurement}

  setup ctx do
    tc = TestFactory.start_context()
    build(tc.engine)
    activate(tc.engine, "L1", "Q1", "v1")
    Map.put(ctx, :tc, tc)
  end

  # 关闭引擎，另起一个指向同一数据目录的新实例（模拟服务重启）
  defp restart(tc) do
    # mock server/client 是命名单例，保留；停止数据面组件
    Enum.each(tc.sup_ids, fn
      id when is_tuple(id) -> stop_supervised!(id)
      _ -> :keep
    end)

    ref = :erlang.unique_integer([:positive])
    cname = Module.concat(ClockRestart, "C#{ref}")
    name = Module.concat(EngineRestart, "E#{ref}")
    jname = Module.concat(JournalRestart, "J#{ref}")
    dname = Module.concat(DispRestart, "D#{ref}")

    {:ok, _} = Util.start_clock(cname)

    {:ok, _} =
      start_supervised(%{
        id: {Journal, ref},
        start: {Journal, :start_link, [[dir: tc.dir, name: jname]]}
      })

    {:ok, engine} =
      start_supervised(%{
        id: {Engine, ref},
        start: {Engine, :start_link, [[dir: tc.dir, journal: jname, clock: cname, name: name]]}
      })

    _ = Engine.state(engine)

    {:ok, dispatcher} =
      start_supervised(%{
        id: {Procurement.Dispatcher, ref},
        start:
          {Procurement.Dispatcher, :start_link,
           [[client: Procurement.MockClient, engine: engine, auto: false, name: dname]]}
      })

    %{engine: engine, journal: jname, clock: cname, dispatcher: dispatcher, dir: tc.dir}
  end

  test "重启后状态完全一致：预算锁/安全节点/待决单都从事件日志重放恢复", %{tc: tc} do
    {:ok, _} = Engine.start_phase(%{line_id: "L1", code: "P1"}, tc.engine)

    {:ok, %{submission_id: sid}} =
      Engine.submit_acceptance(%{
        line_id: "L1", code: "P1", vendor_id: "VendorA",
        device_ids: ["GW-1"], captured_at: "2026-02-10"
      }, tc.engine)

    before = Engine.state(tc.engine)
    lock_before = before.locks[{"L1", "P1"}]

    tc2 = restart(tc)
    after_state = Engine.state(tc2.engine)

    assert after_state.lines["L1"].active_contract.version == "v1"
    assert after_state.locks[{"L1", "P1"}].status == lock_before.status
    assert after_state.locks[{"L1", "P1"}].fee_cents == lock_before.fee_cents
    assert after_state.phases["L1"]["P1"].status == "SUBMITTED"

    sub = Engine.submission_view(tc2.engine, sid)
    assert sub.status == "PENDING"
    assert sub.contract_version == "v1"

    # 重启后批准仍然可以正常完成（时钟、预算、采购单都连续）
    {:ok, view} = approve(tc2.engine, sid)
    assert view.approved

    # 幂等：重启后用同一个 Idempotency-Key 重放启动命令，不会产生第二把锁
    assert {:error, _} =
             Engine.start_phase(%{line_id: "L1", code: "P1"}, tc2.engine)
  end

  test "跨月费用按自然月拆分且合计恒等于合同费用（含罚则单独列示）", %{tc: tc} do
    # 开工 2/20，实测 4/05（计划 2/10，已延期）
    TestFactory.set_time(tc, ~D[2026-02-20])
    {:ok, _} = Engine.start_phase(%{line_id: "L1", code: "P1"}, tc.engine)
    TestFactory.reset_time(tc)

    # 离线验收：现场 4/05 完成，4/08 才回到有网环境补传
    TestFactory.set_time(tc, ~D[2026-04-08])

    {:ok, %{submission_id: sid, offline: true}} =
      Engine.submit_acceptance(%{
        line_id: "L1", code: "P1", vendor_id: "VendorA",
        device_ids: ["GW-1"], captured_at: "2026-04-05",
        offline: true, evidence_ref: "signed-pdf-20260405"
      }, tc.engine)

    # 补传晚到不改变延期口径：按 captured_at（4/05）而非补传日（4/08）计罚
    {:ok, view} = approve(tc.engine, sid)
    overdue = Date.diff(~D[2026-04-05], ~D[2026-02-10])
    assert view.overdue_days == overdue
    assert Enum.map(view.monthly, & &1["period"]) == ["2026-02", "2026-03", "2026-04"]
    assert Enum.sum(Enum.map(view.monthly, & &1["amount_cents"])) == 300_000 * 100

    # 预算视图按账期展示跨月费用
    board = Engine.budget_board(tc.engine)
    periods = board.monthly |> Map.new(&{&1.period, &1.net_cents})
    assert periods[{"L1", "2026-02"}] > 0
    assert periods[{"L1", "2026-03"}] > 0
    assert periods[{"L1", "2026-04"}] > 0
    assert Enum.sum(Map.values(periods)) == 300_000 * 100

    # 采购金额 = 费用 - 罚则
    po = Engine.pending_pos(tc.engine) |> Enum.find(&(&1.submission_id == sid))
    assert po.amount_cents == view.payable_cents
    assert po.amount_cents < 300_000 * 100

    TestFactory.reset_time(tc)
  end

  test "离线补传幂等：同一验收重复上传只产生一张验收单", %{tc: tc} do
    {:ok, _} = Engine.start_phase(%{line_id: "L1", code: "P1"}, tc.engine)

    params = %{
      line_id: "L1", code: "P1", vendor_id: "VendorA",
      device_ids: ["GW-1"], captured_at: "2026-02-11", offline: true
    }

    {:ok, first} = Engine.submit_acceptance(Map.put(params, :idempotency_key, "offline-001"), tc.engine)
    {:ok, again} = Engine.submit_acceptance(Map.put(params, :idempotency_key, "offline-001"), tc.engine)
    assert first.submission_id == again.submission_id

    phase = Engine.state(tc.engine).phases["L1"]["P1"]
    assert length(phase.submissions) == 1
  end

  test "采购单成功回执：outbox 投递 CONFIRMED，重复回执幂等", %{tc: tc} do
    {:ok, _} = Engine.start_phase(%{line_id: "L1", code: "P1"}, tc.engine)

    {:ok, %{submission_id: sid}} =
      Engine.submit_acceptance(%{
        line_id: "L1", code: "P1", vendor_id: "VendorA",
        device_ids: ["GW-1"], captured_at: "2026-02-10"
      }, tc.engine)

    {:ok, view} = Engine.approve(%{submission_id: sid}, tc.engine)
    po_id = view.po_id

    assert is_binary(po_id)

    # 投递器向外部系统下单
    TestFactory.flush(tc)

    po = Engine.state(tc.engine).outbox[po_id]
    assert po.status == "CONFIRMED"
    assert po.external_ref =~ "EXT-PO-"

    # 再 flush：外部系统返回“首次结果”，回执幂等不重复落账
    TestFactory.flush(tc)
    confirm_events =
      tc.engine |> Engine.audit() |> Enum.count(&(&1.type == "po_confirmed"))
    assert confirm_events == 1

    assert sid
  end

  test "外部拒单：走补偿流程 po_compensated，重启后仍可继续补偿", %{tc: tc} do
    {:ok, _} = Engine.start_phase(%{line_id: "L1", code: "P1"}, tc.engine)

    {:ok, %{submission_id: sid}} =
      Engine.submit_acceptance(%{
        line_id: "L1", code: "P1", vendor_id: "VendorA",
        device_ids: ["GW-1"], captured_at: "2026-02-10"
      }, tc.engine)

    {:ok, %{po_id: po_id}} = approve(tc.engine, sid)

    TestFactory.set_mode(tc, "reject")
    TestFactory.flush(tc)

    po = Engine.state(tc.engine).outbox[po_id]
    assert po.status == "COMPENSATED"
    assert po.compensation_ref =~ "CMP-"

    # 验收事实不变，补偿可审计
    assert Engine.state(tc.engine).phases["L1"]["P1"].status == "ACCEPTED"
    types = tc.engine |> Engine.audit(line_id: "L1") |> Enum.map(& &1.type)
    assert "po_rejected" in types and "po_compensated" in types

    # 重启后 inbox 去重仍生效：同样的回执再送一次不会产生第二次补偿事件
    tc2 = restart(tc)

    before_count =
      tc2.engine
      |> Engine.audit(line_id: "L1")
      |> Enum.count(&(&1.type == "po_compensated"))

    key = "receipt-auto:#{po_id}:REJECTED"
    {:ok, _} =
      Engine.receive_receipt(%{po_id: po_id, status: "REJECTED", idempotency_key: key}, tc2.engine)

    after_count =
      tc2.engine
      |> Engine.audit(line_id: "L1")
      |> Enum.count(&(&1.type == "po_compensated"))

    assert after_count == before_count
    assert after_count >= 1
  end

  test "网络故障重试：先失败后成功，采购单最终 CONFIRMED 且只确认一次", %{tc: tc} do
    {:ok, _} = Engine.start_phase(%{line_id: "L1", code: "P1"}, tc.engine)

    {:ok, %{submission_id: sid}} =
      Engine.submit_acceptance(%{
        line_id: "L1", code: "P1", vendor_id: "VendorA",
        device_ids: ["GW-1"], captured_at: "2026-02-10"
      }, tc.engine)

    {:ok, %{po_id: po_id}} = approve(tc.engine, sid)

    TestFactory.set_mode(tc, "fail")
    TestFactory.flush(tc)
    assert Engine.state(tc.engine).outbox[po_id].status == "PENDING_CONFIRM"

    # 恢复网络，重试成功（外部系统此前没见过该单，因为 fail 未送达）
    TestFactory.set_mode(tc, "ok")
    TestFactory.flush(tc)
    assert Engine.state(tc.engine).outbox[po_id].status == "CONFIRMED"

    TestFactory.flush(tc)
    confirms = tc.engine |> Engine.audit() |> Enum.count(&(&1.type == "po_confirmed"))
    assert confirms == 1
  end

  test "崩溃时半截日志行自动截除，不影响此前已确认事件", %{tc: tc} do
    {:ok, _} = Engine.start_phase(%{line_id: "L1", code: "P1"}, tc.engine)

    # 模拟进程被 kill -9 时最后一行写了一半
    File.write!(Path.join(tc.dir, "events.log"), "{\"seq\":999,\"ev", [:append])

    tc2 = restart(tc)
    st = Engine.state(tc2.engine)
    # 此前的 line/device/phase/contract/start 事件全部保留
    assert st.phases["L1"]["P1"].status == "IN_PROGRESS"
    assert File.exists?(Path.join(tc.dir, "events.log.corrupt"))
  end
end
