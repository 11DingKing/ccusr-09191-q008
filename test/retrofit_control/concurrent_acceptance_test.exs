defmodule RetrofitControl.ConcurrentAcceptanceTest do
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

  test "同一阶段并发重复提交：只有最后一次有效，前序全部作废", %{tc: tc} do
    # 10 个进程同时提交（含离线补传的不同实测日）
    results =
      Task.async_stream(1..10, fn i ->
        captured = "2026-02-#{String.pad_leading(to_string(rem(i, 25) + 1), 2, "0")}"

        Engine.submit_acceptance(%{
          line_id: "L1",
          code: "P1",
          vendor_id: "VendorA",
          device_ids: ["GW-1"],
          captured_at: captured,
          offline: i > 5,
          idempotency_key: "submit-#{i}"
        }, tc.engine)
      end, max_concurrency: 10)
      |> Enum.map(fn {:ok, r} -> r end)

    # 每个请求都被受理（不报错），因为提交是“最新覆盖”语义
    assert Enum.all?(results, &match?({:ok, _}, &1))

    phase = Engine.state(tc.engine).phases["L1"]["P1"]
    assert phase.status == "SUBMITTED"
    assert length(phase.submissions) == 10

    pending = Enum.filter(phase.submissions, &(&1.status == "PENDING"))
    assert length(pending) == 1

    # 只有当前待决单可被批准；批准其余单返回 SUBMISSION_NOT_PENDING
    current_id = hd(pending).id

    {:ok, %{approved: true, submission_id: approved_id, po_id: po_id}} =
      approve(tc.engine, current_id)

    assert approved_id == current_id
    assert is_binary(po_id)

    stale =
      phase.submissions
      |> Enum.reject(&(&1.id == current_id))
      |> Enum.take(3)

    Enum.each(stale, fn s ->
      assert {:error, %DomainError{code: "SUBMISSION_NOT_PENDING"}} =
               Engine.approve(%{submission_id: s.id}, tc.engine)
    end)
  end

  test "并发批准与回滚竞争：前置被回退后，后续验收不可能被推进", %{tc: tc} do
    # P1 验收通过
    {:ok, %{submission_id: s1}} =
      submit(tc.engine, %{
        line_id: "L1", code: "P1", vendor_id: "VendorA",
        device_ids: ["GW-1"], captured_at: "2026-02-08"
      })

    {:ok, %{approved: true}} = approve(tc.engine, s1)

    # P2 开工并提交
    {:ok, _} = Engine.start_phase(%{line_id: "L1", code: "P2"}, tc.engine)

    {:ok, %{submission_id: s2}} =
      submit(tc.engine, %{
        line_id: "L1", code: "P2", vendor_id: "VendorA",
        device_ids: ["COL-1"], captured_at: "2026-03-10"
      })

    # 两个动作并发：厂长批准 P2 vs. 退回 P1 安全节点
    tasks =
      [
        Task.async(fn -> {:approve, Engine.approve(%{submission_id: s2}, tc.engine)} end),
        Task.async(fn ->
          {:rollback, Engine.rollback(%{line_id: "L1", code: "P1", reason: "网关能力复测失败"}, tc.engine)}
        end)
      ]

    outcomes = tasks |> Enum.map(&Task.await/1) |> Map.new()

    case outcomes[:approve] do
      {:ok, %{approved: true}} ->
        # 批准先到：回滚 P1 会连带撤销 P2，最终只有 P1 之前（即无）安全节点
        assert {:ok, %{rolled_back_phases: phases}} = outcomes[:rollback]
        assert "P1" in phases and "P2" in phases

      _ ->
        # 回滚先到：批准被系统驳回（前置已回退），回滚成功
        assert {:ok, %{rolled_back_to: :origin}} = outcomes[:rollback]

        assert {:ok, %{approved: false, reason_code: "PREDECESSOR_ROLLED_BACK"}} =
                 outcomes[:approve]
    end

    # 最终不变量：任一已验收阶段的前置必须也已验收
    phases = Engine.phases_for_assert(tc.engine, "L1")

    Enum.each(phases, fn p ->
      if p.status == "ACCEPTED" and p.code != "P1" do
        prev =
          Enum.find(phases, &(&1.order == p.order - 1))

        assert prev.status == "ACCEPTED",
               "不变量破坏：#{p.code} 已验收但前置 #{prev.code} 为 #{prev.status}"
      end
    end)
  end

  test "并发提交跨前置阶段：P2 永远不能在 P1 未验收时提交/开工", %{tc: tc} do
    assert {:error, %DomainError{code: "PREDECESSOR_NOT_ACCEPTED"}} =
             Engine.start_phase(%{line_id: "L1", code: "P2"}, tc.engine)

    assert {:error, %DomainError{code: "PHASE_NOT_SUBMITTABLE"}} =
      Engine.submit_acceptance(%{
        line_id: "L1", code: "P2", vendor_id: "VendorA",
        device_ids: ["COL-1"]
      }, tc.engine)
  end
end
