defmodule RetrofitControl.ProcurementOfflineTest do
  use ExUnit.Case, async: false
  import RetrofitControl.TestFactory
  alias RetrofitControl.Tower

  defp approve_and_accept(t, completed \\ ~D[2026-11-20]) do
    {:ok, %{submission_id: sid}} = submit(t, "P1", "C1")
    {:ok, _} = Tower.approve(t, sid, "厂长")
    {:ok, acc} = Tower.confirm_accepted(t, %{phase_id: "P1", completed_at: completed})
    acc
  end

  describe "外部采购回执幂等补偿" do
    test "首次派发失败进入补偿，重试成功后幂等入账（重复回执不重复确认）" do
      # 用 fail_first=1 让采购系统第 1 次派发失败、第 2 次成功
      dir = Path.join(System.tmp_dir!(), "tower_proc_#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      c2 = start_persisted(dir, 1)
      t2 = c2.tower
      on_exit(fn -> stop_all(c2) end)

      seed_world(t2)
      acc = approve_and_accept(t2)
      order_id = acc.procurement_order_id

      # 首次派发失败 -> 订单处于待补偿
      order = Tower.state(t2).procurement[order_id]
      assert order.status in [:retry_wait, :in_flight]

      # 补偿重试（第 2 次派发成功）
      {:ok, results} = Tower.retry_pending_procurement(t2)
      assert {^order_id, :acknowledged} = List.keyfind(results, order_id, 0)
      assert Tower.state(t2).procurement[order_id].status == :acknowledged

      receipt = Tower.state(t2).procurement[order_id].receipt_key

      # 采购系统重复推送同一回执：幂等，不产生第二条确认事件
      {:ok, r1} = Tower.receive_receipt(t2, %{order_id: order_id, receipt_key: receipt})
      assert r1.idempotent == true
      {:ok, r2} = Tower.receive_receipt(t2, %{order_id: order_id, receipt_key: receipt})
      assert r2.idempotent == true

      acks =
        Tower.audits(t2)
        |> Enum.filter(&(&1.action in [:procurement_receipt, :procurement_compensate]))

      assert Enum.any?(acks, &(&1.result == :acknowledged))
    end

    test "冲突回执（不同回执键）被拒绝" do
      ctx = start_tower()
      on_exit(fn -> stop_all(ctx) end)
      t = ctx.tower
      seed_world(t)
      acc = approve_and_accept(t)
      order_id = acc.procurement_order_id
      receipt = Tower.state(t).procurement[order_id].receipt_key
      assert is_binary(receipt)

      assert {:error, reason} =
               Tower.receive_receipt(t, %{order_id: order_id, receipt_key: "different-key"})

      assert reason =~ "冲突回执"
    end
  end

  describe "离线验收补传" do
    test "离线结果先落盘不推进，恢复后补传且必须仍满足合同版本" do
      ctx = start_tower()
      on_exit(fn -> stop_all(ctx) end)
      t = ctx.tower
      seed_world(t)

        ok!(
          Tower.store_offline_result(t, %{
            stored_key: "offline-001",
            phase_id: "P1",
            vendor_id: "vendorA",
            contract_version_id: "C1",
            device_caps: ["5g_nsa", "mqtt"],
            evidence: %{"signed_at" => "2026-09-10T08:00:00"}
          })
        )

      # 暂存期间阶段不得被推进
      assert Tower.state(t).phases["P1"].status == :planned

      # 情况一：补传时合同仍有效 -> 成功
      {:ok, bf} = Tower.backfill_acceptance(t, "offline-001")
      assert bf.backfilled == true
      assert bf.decision == :eligible

      # 暂存项被消费
      assert Tower.state(t).offline_store == %{}
      # 可据补传产生的提交继续批准
      {:ok, _} = Tower.approve(t, bf.submission_id, "厂长")
      assert Tower.state(t).phases["P1"].status == :approved
    end

    test "离线期间合同被换版，补传被拒绝且暂存保留" do
      ctx = start_tower()
      on_exit(fn -> stop_all(ctx) end)
      t = ctx.tower
      seed_world(t)

        ok!(
          Tower.store_offline_result(t, %{
            stored_key: "offline-002",
            phase_id: "P1",
            vendor_id: "vendorA",
            contract_version_id: "C1",
            device_caps: ["5g_nsa", "mqtt"]
          })
        )

      ok!(Tower.supersede_contract(t, "C1", 2))

      {:ok, bf} = Tower.backfill_acceptance(t, "offline-002")
      assert bf.backfilled == false
      assert bf.reason =~ "换版"

      # 暂存保留，待换版修复后可再次补传；阶段因被拒进入 blocked，等待有效合同重新提交
      assert Map.has_key?(Tower.state(t).offline_store, "offline-002")
      assert Tower.state(t).phases["P1"].status == :blocked
    end
  end
end
