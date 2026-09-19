defmodule RetrofitControl.TowerGatingTest do
  use ExUnit.Case, async: false
  import RetrofitControl.TestFactory
  alias RetrofitControl.{Tower, Domain}

  setup do
    ctx = start_tower()
    on_exit(fn -> stop_all(ctx) end)
    ctx
  end

  defp eligible_phase1(t) do
    {:ok, %{decision: :eligible, submission_id: sid}} = submit(t, "P1", "C1")
    {:ok, _} = Tower.approve(t, sid, "厂长")
    sid
  end

  test "满足依赖、能力、有效合同的提交可以推进并锁定预算", %{tower: t} do
    seed_world(t)
    {:ok, sub} = submit(t, "P1", "C1")
    assert sub.decision == :eligible

    {:ok, app} = Tower.approve(t, sub.submission_id, "厂长")
    assert app.decision == :approved
    assert app.locked_cents == 30_000

    totals = Domain.totals(Tower.state(t))
    assert totals.committed == 30_000
    # 批准动作必须留审计
    actions = Enum.map(Tower.audits(t), & &1.action)
    assert :approve in actions
  end

  test "前置依赖未验收时，后继阶段提交被拒绝", %{tower: t} do
    seed_world(t)

      ok!(
        Tower.plan_phase(t, %{
          id: "P2",
          line_id: "L1",
          seq: 2,
          name: "边缘应用",
          device_class: "GW-X1",
          required_caps: ["5g_nsa"],
          planned_end: ~D[2027-01-31],
          amount_cents: 10_000,
          vendor_id: "vendorA",
          depends_on: ["P1"]
        })
      )

    {:ok, denied2} = submit(t, "P2", "C1")
    assert denied2.decision == :denied
    assert denied2.reason =~ "验收依赖未完成"

    # 推进 P1 验收后，P2 的前置满足
    _sid = eligible_phase1(t)
    {:ok, _} = Tower.confirm_accepted(t, %{phase_id: "P1", completed_at: ~D[2026-11-01]})
    {:ok, again} = submit(t, "P2", "C1")
    assert again.decision == :eligible
  end

  test "设备能力不兼容（缺 opcua）直接拒绝", %{tower: t} do
    seed_world(t, required: ["5g_nsa", "mqtt", "opcua"])
    {:ok, denied_cap} = submit(t, "P1", "C1", %{device_caps: ["5g_nsa", "mqtt"]})
    assert denied_cap.decision == :denied
    assert denied_cap.reason =~ "设备能力不兼容"
  end

  test "引用不存在的合同版本被拒绝", %{tower: t} do
    seed_world(t)
    {:ok, denied_con} = submit(t, "P1", "NOPE")
    assert denied_con.decision == :denied
    assert denied_con.reason =~ "合同版本"
  end

  test "合同换版后，旧版本上的提交即使先合格也无法批准", %{tower: t} do
    seed_world(t)
    # 服务商先在 C1 上提交且当时合格
    {:ok, sub} = submit(t, "P1", "C1")
    assert sub.decision == :eligible

    # 工厂随后把合同换版到 v2
    ok!(Tower.supersede_contract(t, "C1", 2))

    # 批准瞬间重新校验：旧版已失效，禁止推进
    {:ok, app} = Tower.approve(t, sub.submission_id, "厂长")
    assert app.decision == :denied
    assert app.reason =~ "换版"
    # 预算不得被锁定
    assert Domain.totals(Tower.state(t)).committed == 0
  end

  test "合同换版后再登记 v2 才能继续推进", %{tower: t} do
    seed_world(t)
    {:ok, sub} = submit(t, "P1", "C1")
    ok!(Tower.supersede_contract(t, "C1", 2))
    {:ok, denied} = Tower.approve(t, sub.submission_id, "厂长")
    assert denied.decision == :denied

      ok!(
        Tower.record_contract(t, %{
          id: "C2",
          line_id: "L1",
          vendor_id: "vendorA",
          version: 2,
          effective_from: ~D[2026-06-01]
        })
      )

    {:ok, sub2} = submit(t, "P1", "C2")
    {:ok, app} = Tower.approve(t, sub2.submission_id, "厂长")
    assert app.decision == :approved
  end

  test "多个服务商并发提交：仅满足前置且在有效合同上的阶段被推进", %{tower: t} do
    seed_world(t)

      ok!(
        Tower.plan_phase(t, %{
          id: "P2",
          line_id: "L1",
          seq: 2,
          name: "边缘应用",
          device_class: "GW-X1",
          required_caps: ["5g_nsa"],
          planned_end: ~D[2027-01-31],
          amount_cents: 5_000,
          vendor_id: "vendorA",
          depends_on: ["P1"]
        })
      )

    # 并发：P1 合格、P2 依赖未完成、P1 旧合同版本
    tasks =
      [
        Task.async(fn -> submit(t, "P1", "C1") end),
        Task.async(fn -> submit(t, "P2", "C1") end),
        Task.async(fn -> submit(t, "P1", "C9") end)
      ]

    [r1, r2, r3] = Task.await_many(tasks)
    assert {:ok, %{decision: :eligible}} = r1
    assert {:ok, d2} = r2
    assert d2.decision == :denied and d2.reason =~ "验收依赖未完成"
    assert {:ok, d3} = r3
    assert d3.decision == :denied and d3.reason =~ "合同版本"
  end
end
