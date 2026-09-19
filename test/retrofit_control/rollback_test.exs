defmodule RetrofitControl.RollbackTest do
  use ExUnit.Case, async: false

  import RetrofitControl.Scenario
  alias RetrofitControl.{Engine, TestFactory, DomainError}

  setup ctx do
    tc = TestFactory.start_context()
    build(tc.engine)
    activate(tc.engine, "L1", "Q1", "v1")
    Map.put(ctx, :tc, tc)
  end

  # 逐段推进虚拟时钟到各阶段实测日，保证 captured_at 不晚于“今天”
  defp accept_phase(tc, code, devices, captured) do
    TestFactory.set_time(tc, Date.from_iso8601!(captured))

    {:ok, _} = Engine.start_phase(%{line_id: "L1", code: code}, tc.engine)

    {:ok, %{submission_id: sid}} =
      Engine.submit_acceptance(%{
        line_id: "L1", code: code, vendor_id: "VendorA",
        device_ids: devices, captured_at: captured
      }, tc.engine)

    {:ok, view} = approve(tc.engine, sid)
    TestFactory.reset_time(tc)
    view
  end

  test "回滚到 P1：P1/P2 结算红冲、安全节点回到 P1 之前、之后阶段全部重开", %{tc: tc} do
    # P1 按期，P2 延期跨月（计划 3/15，实测 4/05），P3 也验收
    accept_phase(tc, "P1", ["GW-1"], "2026-02-10")
    accept_phase(tc, "P2", ["COL-1"], "2026-04-05")
    accept_phase(tc, "P3", ["EDGE-1"], "2026-04-25")

    budget = Engine.budget_board(tc.engine)
    assert budget.summary.main_consumed_cents == 900_000 * 100

    # 回滚目标必须是已验收安全节点；不存在的阶段得到 NOT_FOUND
    assert {:error, %DomainError{code: "NOT_FOUND"}} =
             Engine.rollback(%{line_id: "L1", code: "P9"}, tc.engine)

    # 厂长决定退回到 P1（发现 P2 采集数据不可信）
    {:ok, rb} = Engine.rollback(%{line_id: "L1", code: "P1", reason: "采集数据不可信，复测失败"}, tc.engine)

    assert rb.rolled_back_to == :origin
    assert Enum.sort(rb.rolled_back_phases) == ["P1", "P2", "P3"]
    assert rb.note == "产线已退回到改造前的初始状态"

    # 预算：所有结算红冲，消耗归零，可用全额恢复
    summary = Engine.budget_board(tc.engine).summary
    assert summary.main_consumed_cents == 0
    assert summary.main_available_cents == summary.main_total_cents
    assert summary.risk_available_cents == summary.risk_total_cents

    # 跨月账期净额为 0（每个账期都有等额反向红冲）
    monthly = Engine.budget_board(tc.engine).monthly
    Enum.each(monthly, fn m -> assert m.net_cents == 0 end)

    # 阶段状态
    phases =
      tc.engine
      |> Engine.phases_for_assert("L1")
      |> Map.new(&{&1.code, &1})

    assert phases["P1"].status == "ROLLED_BACK"
    assert phases["P2"].status == "ROLLED_BACK"
    assert phases["P3"].status == "ROLLED_BACK"
    refute phases["P1"].safe_node

    # 厂长视图：下一个动作是 P1 重新开工，阻塞原因清晰
    board = Engine.line_board(tc.engine, "L1")
    assert board.safe_node_cn == "改造前初始状态（尚无已验收节点）"
    assert board.next_action_phase == "P1"
    refute board.can_continue

    # 审计：回滚事件数 = 3 个红冲 + 3 个回退
    events = Engine.audit(tc.engine, line_id: "L1")
    assert Enum.count(events, &(&1.type == "budget_reversed")) == 3
    assert Enum.count(events, &(&1.type == "phase_rolled_back")) == 3
  end

  test "回滚到中间安全节点 P2：仅 P2/P3 红冲，P1 保持验收", %{tc: tc} do
    accept_phase(tc, "P1", ["GW-1"], "2026-02-10")
    accept_phase(tc, "P2", ["COL-1"], "2026-03-20")
    accept_phase(tc, "P3", ["EDGE-1"], "2026-04-25")

    {:ok, rb} = Engine.rollback(%{line_id: "L1", code: "P2"}, tc.engine)

    assert rb.rolled_back_to == "P1"
    assert Enum.sort(rb.rolled_back_phases) == ["P2", "P3"]

    phases = Engine.phases_for_assert(tc.engine, "L1") |> Map.new(&{&1.code, &1})
    assert phases["P1"].status == "ACCEPTED"
    assert phases["P1"].safe_node
    assert phases["P2"].status == "ROLLED_BACK"

    summary = Engine.budget_board(tc.engine).summary
    assert summary.main_consumed_cents == 300_000 * 100

    board = Engine.line_board(tc.engine, "L1")
    assert board.safe_node == "P1"
    assert board.next_action_phase == "P2"
  end

  test "回滚后可以从安全节点重新逐段推进，且重新结算金额正确", %{tc: tc} do
    accept_phase(tc, "P1", ["GW-1"], "2026-02-10")
    accept_phase(tc, "P2", ["COL-1"], "2026-03-20")
    {:ok, _} = Engine.rollback(%{line_id: "L1", code: "P2"}, tc.engine)

    # 重新走 P2（从 P1 安全节点继续）
    {:ok, _} = Engine.start_phase(%{line_id: "L1", code: "P2"}, tc.engine)

    {:ok, %{submission_id: sid}} =
      Engine.submit_acceptance(%{
        line_id: "L1", code: "P2", vendor_id: "VendorA",
        device_ids: ["COL-1"], captured_at: "2026-05-10"
      }, tc.engine)

    {:ok, view} = approve(tc.engine, sid)
    # 延期：计划 3/15 → 实测 5/10 = 56 天 × 1‰ = 5.6%
    assert view.overdue_days == 56
    assert view.penalty_cents == 300_000 * 100 * 56 * 10 |> div(10_000)
    assert view.approved

    # P1 + P2 都被消耗（P2 是红冲后重新结算，旧条目已失效）
    active_entries =
      tc.engine
      |> Engine.state()
      |> Map.fetch!(:entries)
      |> Enum.filter(&(&1.type == "SETTLE" and &1.active))

    assert Enum.sum(Enum.map(active_entries, & &1.amount_cents)) == 600_000 * 100
  end
end
