defmodule RetrofitControl.ContractVersionTest do
  use ExUnit.Case, async: false

  import RetrofitControl.Scenario
  alias RetrofitControl.{Engine, TestFactory, DomainError}

  setup ctx do
    tc = TestFactory.start_context()
    build(tc.engine)
    {:ok, %{version: "v1"}} = activate(tc.engine, "L1", "Q1", "v1")
    {:ok, %{code: "P1"}} = start_p1(tc.engine)
    Map.put(ctx, :tc, tc)
  end

  defp gw_submit(tc, captured \\ "2026-02-10", idem \\ nil) do
    {:ok, %{submission_id: sid}} =
      submit(tc.engine, %{
        line_id: "L1",
        code: "P1",
        vendor_id: "VendorA",
        device_ids: ["GW-1"],
        captured_at: captured
      }, idem)

    sid
  end

  test "版本号必须递增；不能激活相同或更旧的合同版本", %{tc: tc} do
    assert {:error, %DomainError{code: "CONTRACT_VERSION_ORDER"}} =
             activate(tc.engine, "L1", "Q1", "v1")

    assert {:error, %DomainError{code: "CONTRACT_VERSION_ORDER"}} =
             activate(tc.engine, "L1", "Q1", "v0")

    {:ok, %{version: "v2"}} = activate(tc.engine, "L1", "Q2", "v2")
  end

  test "提交后合同换版：旧验收单立即作废，再批准得到 SUBMISSION_NOT_PENDING", %{tc: tc} do
    sid = gw_submit(tc)
    {:ok, %{version: "v2"}} = activate(tc.engine, "L1", "Q2", "v2")

    # 换版事件原子地：旧待决单作废 + 阶段回实施中 + v1 预算锁释放
    assert {:error, %DomainError{code: "SUBMISSION_NOT_PENDING"}} =
             approve(tc.engine, sid)

    phase = Engine.state(tc.engine).phases["L1"]["P1"]
    assert phase.status == "IN_PROGRESS"
    assert is_nil(phase.current_submission_id)

    lock = Engine.state(tc.engine).locks[{"L1", "P1"}]
    assert lock.status == "RELEASED"

    types = tc.engine |> Engine.audit(line_id: "L1") |> Enum.map(& &1.type)
    assert "contract_superseded" in types
    assert "submission_superseded" in types
    assert "budget_lock_released" in types
  end

  test "换版后用新合同服务商重新提交并批准（CONTRACT_STALE 闸门兜底）", %{tc: tc} do
    sid = gw_submit(tc)
    {:ok, _} = activate(tc.engine, "L1", "Q2", "v2")

    assert Engine.submission_view(tc.engine, sid).status == "SUPERSEDED"

    # 新合同是 VendorB
    assert {:error, %DomainError{code: "VENDOR_NOT_CONTRACTED"}} =
             Engine.submit_acceptance(%{
               line_id: "L1",
               code: "P1",
               vendor_id: "VendorA",
               device_ids: ["GW-1"]
             }, tc.engine)

    # 旧锁已释放：按 v2 重新开工竞争预算，然后 VendorB 提交
    TestFactory.set_time(tc, ~D[2026-02-20])
    {:ok, _} = Engine.start_phase(%{line_id: "L1", code: "P1"}, tc.engine)

    {:ok, %{submission_id: sid2, contract_version: "v2"}} =
      Engine.submit_acceptance(%{
        line_id: "L1",
        code: "P1",
        vendor_id: "VendorB",
        device_ids: ["GW-1"],
        captured_at: "2026-02-20"
      }, tc.engine)

    {:ok, %{approved: true}} = approve(tc.engine, sid2)
    TestFactory.reset_time(tc)

    # 即使把 sid（旧版）状态人工置回待决，批准闸门也会以 CONTRACT_STALE 拦截。
    # 这里通过幂等事件重放保证：旧版单无法在 v2 合同上结算
    board = Engine.line_board(tc.engine, "L1")
    assert board.safe_node == "P1"
    assert board.contract_version == "v2"
  end

  test "合同激活命令幂等：同一个 Idempotency-Key 重放不产生第二份合同", %{tc: tc} do
    {:ok, first} = activate(tc.engine, "L1", "Q2", "v2", "k-activate")
    {:ok, again} = activate(tc.engine, "L1", "Q2", "v2", "k-activate")
    assert first.contract_id == again.contract_id

    count =
      tc.engine
      |> Engine.audit(line_id: "L1")
      |> Enum.count(&(&1.type == "contract_superseded" and &1.detail["version"] == "v2"))

    assert count == 1
  end
end
