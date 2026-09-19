defmodule RetrofitControl.BudgetCompetitionTest do
  use ExUnit.Case, async: false

  import RetrofitControl.Scenario
  alias RetrofitControl.{Engine, TestFactory, DomainError, Util}

  setup ctx do
    tc = TestFactory.start_context()
    build(tc.engine)
    activate(tc.engine, "L1", "Q1", "v1")
    activate(tc.engine, "L2", "Q3", "v1")
    Map.put(ctx, :tc, tc)
  end

  test "同一阶段并发开工抢预算：只有一个赢家，另一个得到 BUDGET_ALREADY_LOCKED", %{tc: tc} do
    results =
      Task.async_stream(1..8, fn _ ->
        Engine.start_phase(%{line_id: "L1", code: "P1"}, tc.engine)
      end, max_concurrency: 8)
      |> Enum.map(fn {:ok, r} -> r end)

    oks = Enum.filter(results, &match?({:ok, _}, &1))
    errs = Enum.filter(results, &match?({:error, _}, &1))

    assert length(oks) == 1

    # 其余并发请求都不能推进：要么锁已存在，要么阶段已被赢家推进（串行裁决）
    assert Enum.all?(errs, fn
             {:error, %DomainError{code: code}} ->
               code in ["BUDGET_ALREADY_LOCKED", "PHASE_NOT_STARTABLE"]
           end)

    summary = Engine.budget_board(tc.engine).summary
    assert summary.main_locked_cents == 300_000 * 100
    assert summary.risk_locked_cents == 45_000 * 100
  end

  test "预算池硬约束：可用不足时开工被拒绝（不会出现超支锁定）", %{tc: tc} do
    # L2 总预算 20 万，单段报价 15 万 + 15% 风险 2.25 万：主预算可容纳一次
    {:ok, _} = Engine.start_phase(%{line_id: "L2", code: "P1"}, tc.engine)
    summary = Engine.budget_board(tc.engine).summary

    # 全局主预算剩余 = 120万 - 30万(L1未锁) ... 这里 L1 未开工，实际只锁了 15 万
    assert summary.main_locked_cents == 150_000 * 100

    # 注册第二个会超主预算的阶段：先把 L1 P1 开工（锁 30 万），仍够；
    # 再造一个 90 万的阶段报价让池子见底
    {:ok, _} = Engine.start_phase(%{line_id: "L1", code: "P1"}, tc.engine)

    # 此时主预算锁定 45 万；规划一条 95 万的新阶段，风险 15%
    {:ok, _} =
      Engine.record_quote(%{
        line_id: "L1", quote_id: "Q-BIG", vendor_id: "VendorA", version: "vbig",
        fee_cents: 950_000 * 100, reserve_rate_bp: 1500
      }, tc.engine)

    {:ok, _} = Engine.plan_phase(%{
      line_id: "L1", code: "PBIG", name: "大额阶段", order: 9,
      needs: ["5g_nsa"], planned_done_date: "2026-12-01"
    }, tc.engine)

    # 直接启动会因依赖失败（order=9 前置是 P3），无前置链不影响预算检查顺序：
    # 依赖检查先于预算。这里验证“前置失败时不能推进”，另起一条无依赖线验证预算。
    assert {:error, %DomainError{code: "PREDECESSOR_NOT_ACCEPTED"}} =
             Engine.start_phase(%{line_id: "L1", code: "PBIG"}, tc.engine)

    # 用 P2 做预算竞争：若人为把可用压到低于 30 万——驳回 L1 P1 释放后再连开多段
    # 这里通过小预算工厂线验证纯预算不足：构造 L3 总预算 10 万、报价 15 万
    {:ok, _} =
      Engine.register_line(%{
        line_id: "L3", name: "试验线",
        main_budget_cents: 100_000 * 100, risk_budget_cents: 100_000 * 100
      }, tc.engine)

    {:ok, _} =
      Engine.record_quote(%{
        line_id: "L3", quote_id: "Q3S", vendor_id: "VendorA", version: "v1",
        fee_cents: 150_000 * 100
      }, tc.engine)

    {:ok, _} =
      Engine.plan_phase(%{
        line_id: "L3", code: "P1", needs: [], planned_done_date: "2026-03-01"
      }, tc.engine)

    {:ok, _} = Engine.activate_contract(%{line_id: "L3", quote_id: "Q3S", version: "v1"}, tc.engine)

    assert {:error, %DomainError{code: "BUDGET_EXCEEDED"}} =
             Engine.start_phase(%{line_id: "L3", code: "P1"}, tc.engine)

    # 锁定的钱没有任何变化（原子裁决，不会半锁）
    assert Engine.budget_board(tc.engine).summary.main_locked_cents == 450_000 * 100
  end

  test "驳回后预算回到池子，整改后可重新占用；批准后结算消耗", %{tc: tc} do
    {:ok, _} = Engine.start_phase(%{line_id: "L1", code: "P1"}, tc.engine)
    before_lock = Engine.budget_board(tc.engine).summary

    {:ok, %{submission_id: sid}} =
      Engine.submit_acceptance(%{
        line_id: "L1", code: "P1", vendor_id: "VendorA",
        device_ids: ["GW-1"], captured_at: "2026-02-09"
      }, tc.engine)

    # 厂长驳回
    {:ok, %{approved: false, auto_rejected: false}} =
      Engine.reject(%{submission_id: sid, reason: "现场照片不清晰"}, tc.engine)

    after_reject = Engine.budget_board(tc.engine).summary
    assert after_reject.main_locked_cents == before_lock.main_locked_cents - 300_000 * 100
    assert after_reject.main_available_cents == before_lock.main_available_cents + 300_000 * 100

    # 重新开工 → 重新锁定 → 批准结算
    {:ok, _} = Engine.start_phase(%{line_id: "L1", code: "P1"}, tc.engine)
    {:ok, %{submission_id: sid2}} =
      Engine.submit_acceptance(%{
        line_id: "L1", code: "P1", vendor_id: "VendorA",
        device_ids: ["GW-1"], captured_at: "2026-02-11"
      }, tc.engine)

    {:ok, %{approved: true, fee_cents: fee}} = approve(tc.engine, sid2)
    assert fee == 300_000 * 100

    final = Engine.budget_board(tc.engine).summary
    assert final.main_consumed_cents == 300_000 * 100
    assert final.main_locked_cents == 0
  end

  test "风险储备池独立于主预算：主预算够但风险池不够同样拒绝", %{tc: tc} do
    # 风险池只给 1000 分
    {:ok, _} =
      Engine.register_line(%{
        line_id: "L4", name: "低储备线",
        main_budget_cents: 1_000_000 * 100, risk_budget_cents: 1000
      }, tc.engine)

    {:ok, _} =
      Engine.record_quote(%{
        line_id: "L4", quote_id: "Q4", vendor_id: "VendorA", version: "v1",
        fee_cents: 100_000 * 100, reserve_rate_bp: 1500
      }, tc.engine)

    {:ok, _} =
      Engine.plan_phase(%{
        line_id: "L4", code: "P1", needs: [], planned_done_date: "2026-03-01"
      }, tc.engine)

    {:ok, _} = Engine.activate_contract(%{line_id: "L4", quote_id: "Q4", version: "v1"}, tc.engine)

    assert {:error, %DomainError{code: "RISK_BUDGET_EXCEEDED"}} =
             Engine.start_phase(%{line_id: "L4", code: "P1"}, tc.engine)
  end
end
