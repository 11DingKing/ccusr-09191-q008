defmodule Mix.Tasks.Retro.Demo do
  @moduledoc """
  端到端演示：重置本地数据目录后，演示“逐段上线—并发提交—合同换版—
  能力不兼容驳回—延期跨月验收—回退安全节点—采购补偿”的完整闭环。

      mix retro.demo
  """
  @shortdoc "运行端到端交付演示（会清空 data/default）"

  use Mix.Task

  alias RetrofitControl.Engine

  def run(_args) do
    # 不启动默认监督树：先确保默认进程停掉，清空数据目录，再以全新实例运行
    for name <- [
          RetrofitControl.Procurement.Dispatcher,
          RetrofitControl.Engine,
          RetrofitControl.Journal,
          RetrofitControl.Procurement.MockClient,
          RetrofitControl.Procurement.MockServer
        ],
        (pid = Process.whereis(name)) != nil do
      GenServer.stop(pid)
    end

    Process.sleep(100)

    data_dir = Application.get_env(:retrofit_control, :data_dir, "data/default")
    File.rm_rf!(data_dir)
    IO.puts("已清空数据目录 #{data_dir}，重新构建演示场景…\n")

    {:ok, _} = RetrofitControl.Journal.start_link(dir: data_dir)
    {:ok, _} = RetrofitControl.Engine.start_link(dir: data_dir)
    # 演示场景设定在 2026 年改造期
    RetrofitControl.Util.set_clock(
      fn -> DateTime.new!(~D[2026-04-22], ~T[10:00:00.000000]) end,
      RetrofitControl.Util.Clock
    )

    {:ok, _} = RetrofitControl.Procurement.MockServer.start_link([])
    {:ok, _} = RetrofitControl.Procurement.MockClient.start_link([])

    {:ok, _} =
      RetrofitControl.Procurement.Dispatcher.start_link(
        client: RetrofitControl.Procurement.MockClient,
        engine: RetrofitControl.Engine,
        auto: false
      )

    # 1) 主数据
    Engine.register_line!(%{
      line_id: "L1",
      name: "冲压一线",
      main_budget_cents: yuan(1_000_000),
      risk_budget_cents: yuan(200_000)
    })

    Enum.each(
      [
        {"GW-1", "gateway", ["5g_nsa"], "2.1.0"},
        {"COL-1", "collector", ["modbus_tcp", "opc_ua"], "1.4.0"},
        {"EDGE-1", "edge_app", ["vision_infer", "mqtt_bridge"], "3.0.0"}
      ],
      fn {id, kind, caps, fw} ->
        Engine.register_device!(%{
          line_id: "L1", device_id: id, kind: kind, provides: caps, firmware: fw
        })
      end
    )

    [
      {"P1", "5G 网关上线", 1, ["5g_nsa"], "1.0.0", "2026-02-10"},
      {"P2", "采集器部署", 2, ["modbus_tcp", "opc_ua"], "1.0.0", "2026-03-15"},
      {"P3", "边缘应用验收", 3, ["vision_infer", "mqtt_bridge"], "2.0.0", "2026-04-20"}
    ]
    |> Enum.each(fn {code, name, order, needs, fw, due} ->
      Engine.plan_phase!(%{
        line_id: "L1", code: code, name: name, order: order,
        needs: needs, min_firmware: fw, planned_done_date: due
      })
    end)

    Engine.record_quote!(%{
      line_id: "L1", quote_id: "Q1", vendor_id: "VendorA", version: "v1",
      fee_cents: yuan(300_000), reserve_rate_bp: 1500,
      penalty_rate_bp_per_day: 10, penalty_cap_bp: 5000
    })

    # 2) 合同 + P1 上线
    Engine.activate_contract!(%{line_id: "L1", quote_id: "Q1", version: "v1"})
    Engine.start_phase!(%{line_id: "L1", code: "P1"})
    IO.puts("✓ P1 开工，锁定预算 30 万 + 风险储备 4.5 万")

    # 3) 能力不兼容被系统驳回（用采集器冒充网关提交）
    Engine.submit_acceptance(%{
      line_id: "L1", code: "P1", vendor_id: "VendorA",
      device_ids: ["COL-1"], captured_at: "2026-02-09"
    })
    |> case do
      {:error, %{code: "CAPABILITY_MISMATCH"} = err} ->
        IO.puts("✓ 提交闸门拦截能力不兼容：#{err.message}")

      other ->
        IO.puts("（能力校验结果：#{inspect(other)}）")
    end

    # 4) 正确设备提交 + 批准（按期，无罚则）
    %{submission_id: s1} =
      Engine.submit_acceptance!(%{
        line_id: "L1", code: "P1", vendor_id: "VendorA",
        device_ids: ["GW-1"], captured_at: "2026-02-10"
      })

    %{po_id: po1} = Engine.approve!(%{submission_id: s1})
    IO.puts("✓ P1 验收通过，成为安全节点；生成采购单 #{po1}")
    RetrofitControl.Procurement.Dispatcher.flush()
    IO.puts("✓ 采购系统已确认（幂等补偿）")

    # 5) P2 延期跨月
    Engine.start_phase!(%{line_id: "L1", code: "P2"})

    %{submission_id: s2} =
      Engine.submit_acceptance!(%{
        line_id: "L1", code: "P2", vendor_id: "VendorA",
        device_ids: ["COL-1"], captured_at: "2026-04-05", offline: true
      })

    view = Engine.approve!(%{submission_id: s2})

    IO.puts(
      "✓ P2 离线补传验收：逾期 #{view.overdue_days} 天，" <>
        "罚则 #{RetrofitControl.Util.format_yuan(view.penalty_cents)}，" <>
        "跨月账期 #{Enum.map_join(view.monthly, ", ", & &1["period"])}"
    )

    RetrofitControl.Procurement.Dispatcher.flush()

    # 6) P3
    Engine.start_phase!(%{line_id: "L1", code: "P3"})

    %{submission_id: s3} =
      Engine.submit_acceptance!(%{
        line_id: "L1", code: "P3", vendor_id: "VendorA",
        device_ids: ["EDGE-1"], captured_at: "2026-04-22"
      })

    Engine.approve!(%{submission_id: s3})
    RetrofitControl.Procurement.Dispatcher.flush()
    IO.puts("✓ P3 验收通过，三段全部上线\n")

    # 7) 回退到 P1 安全节点
    rb = Engine.rollback!(%{line_id: "L1", code: "P1", reason: "采集数据复测不合格"})
    IO.puts("↩ #{rb.note}；红冲阶段 #{Enum.join(rb.rolled_back_phases, "、")}\n")

    IO.puts("============================================================")
    IO.puts(" 现在运行 `mix retro.board` 查看厂长视图，或：")
    IO.puts("   mix retro.board L1          单条产线详情")
    IO.puts("   mix retro.board --audit=20  最近审计事件")
    IO.puts("============================================================")
  end

  defp yuan(n), do: n * 100
end
