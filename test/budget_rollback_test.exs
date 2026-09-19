defmodule RetrofitControl.BudgetRollbackTest do
  use ExUnit.Case, async: false
  import RetrofitControl.TestFactory
  alias RetrofitControl.{Tower, Domain}

  setup do
    ctx = start_tower()
    on_exit(fn -> stop_all(ctx) end)
    ctx
  end

  defp approve(t, phase \\ "P1", contract \\ "C1", caps \\ ["5g_nsa", "mqtt"]) do
    {:ok, %{submission_id: sid}} = submit(t, phase, contract, %{device_caps: caps})
    Tower.approve(t, sid, "厂长")
  end

  describe "预算竞争" do
    test "两条产线并发抢同一笔预算，只有能锁足的阶段获胜", %{tower: t} do
      # 总预算 50_000，储备 0；每阶段 30_000，只能锁一个
      seed_world(t, total: 50_000, reserve: 0, amount: 30_000)

      # 第二条产线与阶段
      ok!(Tower.register_line(t, %{id: "L2", name: "二号包装线"}))

        ok!(
          Tower.catalog_device(t, %{
            id: "D2",
            line_id: "L2",
            kind: "gateway",
            class: "GW-Y1",
            caps: ["5g_nsa", "mqtt"],
            vendor_id: "vendorB"
          })
        )

        ok!(
          Tower.record_contract(t, %{
            id: "C2",
            line_id: "L2",
            vendor_id: "vendorB",
            version: 1,
            effective_from: ~D[2026-01-01]
          })
        )

        ok!(
          Tower.plan_phase(t, %{
            id: "Q1",
            line_id: "L2",
            seq: 1,
            name: "网关",
            device_class: "GW-Y1",
            required_caps: ["5g_nsa"],
            planned_end: ~D[2026-12-31],
            amount_cents: 30_000,
            vendor_id: "vendorB"
          })
        )

      results =
        [
          Task.async(fn -> approve(t, "P1", "C1") end),
          Task.async(fn -> approve(t, "Q1", "C2", ["5g_nsa", "mqtt"]) end)
        ]
        |> Task.await_many()

      decisions =
        results
        |> Enum.map(fn
          {:ok, r} -> if r.decision == :approved, do: :approved, else: :denied
          {:error, _} -> :error
        end)
        |> Enum.sort()

      assert decisions == [:approved, :denied]
      totals = Domain.totals(Tower.state(t))
      assert totals.committed == 30_000
      assert Domain.budget_available(Tower.state(t)) == 20_000
    end

    test "主预算不足时动用风险储备并留痕", %{tower: t} do
      seed_world(t, total: 20_000, reserve: 30_000, amount: 30_000)
      {:ok, app} =
        (fn ->
           {:ok, %{submission_id: sid}} = submit(t, "P1", "C1")
           Tower.approve(t, sid, "厂长")
         end).()

      assert app.decision == :approved
      assert app.from_reserve_cents == 10_000
      totals = Domain.totals(Tower.state(t))
      assert totals.reserve_drawn == 10_000
    end

    test "主预算+储备仍不足则拒绝，不产生任何锁定", %{tower: t} do
      seed_world(t, total: 20_000, reserve: 5_000, amount: 30_000)
      {:ok, denied} = approve(t)
      assert denied.decision == :denied
      assert denied.reason =~ "预算竞争失败"
      assert Domain.totals(Tower.state(t)).committed == 0
    end
  end

  describe "阶段回滚到安全节点" do
    test "已批准未验收的阶段回滚会释放 hold 与储备，退回节点 0", %{tower: t} do
      seed_world(t, total: 20_000, reserve: 30_000, amount: 30_000)
      {:ok, _} = approve(t)
      assert Domain.totals(Tower.state(t)).committed == 30_000

      {:ok, rb} = Tower.rollback(t, "L1", %{reason: "能力复测不兼容"})
      assert rb.rolled_back_to_safety_node == 0
      assert rb.affected_phases == ["P1"]

      totals = Domain.totals(Tower.state(t))
      assert totals.committed == 0
      assert totals.reserve_drawn == 0
      # 预算恢复可用
      assert Domain.budget_available(Tower.state(t)) == 50_000

      phase = Tower.state(t).phases["P1"]
      assert phase.status == :rolled_back

      report = Tower.report(t)
      line = Enum.find(report.lines, &(&1.line_id == "L1"))
      assert line.safety_node == 0
      assert Enum.any?(Tower.audits(t), &(&1.action == :rollback and &1.safety_node == 0))
    end

    test "回滚已验收阶段会红冲跨月花费与延期罚则", %{tower: t} do
      seed_world(t, amount: 30_000)
      {:ok, _} = approve(t)

      {:ok, acc} =
        Tower.confirm_accepted(t, %{
          phase_id: "P1",
          completed_at: ~D[2027-02-15],
          penalty: [rate_per_day_bp: 100, cap_bp: 3000]
        })

      assert acc.penalty_cents > 0
      totals = Domain.totals(Tower.state(t))
      assert totals.committed == 0
      assert totals.spent == 30_000 + acc.penalty_cents

      {:ok, rb} = Tower.rollback(t, "L1")
      assert rb.rolled_back_to_safety_node == 0

      totals2 = Domain.totals(Tower.state(t))
      assert totals2.spent == 0
      # 回滚后预算再次可用于重新上线
      assert Domain.budget_available(Tower.state(t)) == 120_000
    end

    test "两连续阶段：回滚第2段只退回第2段，安全节点停在第1段", %{tower: t} do
      seed_world(t, total: 100_000, reserve: 0, amount: 10_000)

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

      {:ok, _} = approve(t, "P1", "C1")
      ok!(Tower.confirm_accepted(t, %{phase_id: "P1", completed_at: ~D[2026-10-01]}))
      {:ok, s2} = submit(t, "P2", "C1")
      {:ok, _} = Tower.approve(t, s2.submission_id, "厂长")

      {:ok, rb} = Tower.rollback(t, "L1")
      assert rb.rolled_back_to_safety_node == 1
      assert rb.affected_phases == ["P2"]

      st = Tower.state(t)
      assert st.phases["P1"].status == :accepted
      assert st.phases["P2"].status == :rolled_back
    end
  end

  describe "确认验收与跨月费用/罚则" do
    test "验收后 hold 释放、跨月花费入账，合计与阶段金额一致", %{tower: t} do
      seed_world(t, amount: 30_000)
      {:ok, _} = approve(t)

      {:ok, acc} =
        Tower.confirm_accepted(t, %{phase_id: "P1", completed_at: ~D[2026-12-15]})

      assert Enum.sum(Map.values(acc.monthly_cents)) == 30_000
      totals = Domain.totals(Tower.state(t))
      assert totals.spent == 30_000
      assert totals.committed == 0

      # 安全节点推进到第 1 段
      report = Tower.report(t)
      line = Enum.find(report.lines, &(&1.line_id == "L1"))
      assert line.safety_node == 1
      assert line.next_action =~ "全部阶段已验收"
    end
  end
end
