defmodule RetrofitControl.CapabilityRuleTest do
  use ExUnit.Case, async: false

  import RetrofitControl.Scenario
  alias RetrofitControl.{Engine, TestFactory, DomainError}

  setup ctx do
    tc = TestFactory.start_context()
    build(tc.engine)
    activate(tc.engine, "L1", "Q1", "v1")
    {:ok, _} = start_p1(tc.engine)
    Map.put(ctx, :tc, tc)
  end

  test "设备能力不满足阶段需要：提交即拒，批准闸门同样兜底", %{tc: tc} do
    assert {:error, %DomainError{code: "CAPABILITY_MISMATCH", message: msg}} =
             Engine.submit_acceptance(%{
               line_id: "L1", code: "P1", vendor_id: "VendorA",
               device_ids: ["COL-1"]
             }, tc.engine)

    assert msg =~ "5g_nsa"
  end

  test "不属于本产线的设备不能用于验收（DEVICE_LINE_MISMATCH）", %{tc: tc} do
    {:ok, _} =
      Engine.register_device(%{
        line_id: "L2", device_id: "GW-L2", kind: "gateway",
        provides: ["5g_nsa"], firmware: "2.0.0"
      }, tc.engine)

    assert {:error, %DomainError{code: "DEVICE_LINE_MISMATCH"}} =
             Engine.submit_acceptance(%{
               line_id: "L1", code: "P1", vendor_id: "VendorA",
               device_ids: ["GW-L2"]
             }, tc.engine)
  end

  test "未登记的设备不能用于验收（DEVICE_UNKNOWN）", %{tc: tc} do
    assert {:error, %DomainError{code: "DEVICE_UNKNOWN"}} =
             Engine.submit_acceptance(%{
               line_id: "L1", code: "P1", vendor_id: "VendorA",
               device_ids: ["NO-SUCH-DEVICE"]
             }, tc.engine)
  end

  test "固件低于最低要求：FIRMWARE_TOO_OLD", %{tc: tc} do
    {:ok, _} =
      Engine.register_device(%{
        line_id: "L1", device_id: "GW-OLD", kind: "gateway",
        provides: ["5g_nsa"], firmware: "0.9.0"
      }, tc.engine)

    assert {:error, %DomainError{code: "FIRMWARE_TOO_OLD"}} =
      Engine.submit_acceptance(%{
        line_id: "L1", code: "P1", vendor_id: "VendorA",
        device_ids: ["GW-OLD"]
      }, tc.engine)
  end

  test "延期罚则按天累计并受封顶约束", %{tc: tc} do
    # 计划 2/10；实测 3/02 → 20 天 × 1‰ = 2%
    {:ok, %{submission_id: sid}} =
      Engine.submit_acceptance(%{
        line_id: "L1", code: "P1", vendor_id: "VendorA",
        device_ids: ["GW-1"], captured_at: "2026-03-02"
      }, tc.engine)

    {:ok, view} = approve(tc.engine, sid)
    assert view.overdue_days == 20
    assert view.penalty_cents == 300_000 * 100 * 20 * 10 |> div(10_000)
    assert view.payable_cents == 300_000 * 100 - view.penalty_cents

    # 提前完成无罚则
    {:ok, _} = Engine.rollback(%{line_id: "L1", code: "P1"}, tc.engine)
    {:ok, _} = Engine.start_phase(%{line_id: "L1", code: "P1"}, tc.engine)

    {:ok, %{submission_id: sid2}} =
      Engine.submit_acceptance(%{
        line_id: "L1", code: "P1", vendor_id: "VendorA",
        device_ids: ["GW-1"], captured_at: "2026-02-01"
      }, tc.engine)

    {:ok, view2} = approve(tc.engine, sid2)
    assert view2.penalty_cents == 0
    assert view2.payable_cents == 300_000 * 100
  end

  test "离线实测日不能晚于今天", %{tc: tc} do
    TestFactory.set_time(tc, ~D[2026-02-15])

    assert {:error, %DomainError{code: "FUTURE_CAPTURE"}} =
             Engine.submit_acceptance(%{
               line_id: "L1", code: "P1", vendor_id: "VendorA",
               device_ids: ["GW-1"], captured_at: "2026-02-16"
             }, tc.engine)

    TestFactory.reset_time(tc)
  end

  test "能力清单可以多设备并集满足", %{tc: tc} do
    # P2 需要 modbus_tcp + opc_ua；先推进 P1
    {:ok, %{submission_id: s1}} =
      Engine.submit_acceptance(%{
        line_id: "L1", code: "P1", vendor_id: "VendorA",
        device_ids: ["GW-1"], captured_at: "2026-02-10"
      }, tc.engine)

    {:ok, _} = approve(tc.engine, s1)
    {:ok, _} = Engine.start_phase(%{line_id: "L1", code: "P2"}, tc.engine)

    # 单设备 COL-1 已同时具备两种协议
    {:ok, %{submission_id: s2}} =
      Engine.submit_acceptance(%{
        line_id: "L1", code: "P2", vendor_id: "VendorA",
        device_ids: ["COL-1"], captured_at: "2026-03-14"
      }, tc.engine)

    {:ok, %{approved: true}} = approve(tc.engine, s2)
  end
end
