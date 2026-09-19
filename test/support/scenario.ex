defmodule RetrofitControl.Scenario do
  @moduledoc """
  构造一个“两条产线、逐段上线”的标准场景：
  L1（冲压线，100 万主预算 + 15% 风险池）与 L2（焊装线，20 万小预算，用于预算竞争），
  各三个阶段 P1 网关 → P2 采集器 → P3 边缘应用。
  """

  alias RetrofitControl.Engine

  defmodule B do
    @moduledoc "金额（元→分）。"
    def yuan(n), do: n * 100
  end

  def build(server) do
    # 业务场景设定在 2026 年初：用虚拟时钟驱动 captured_at 校验与时间戳
    clock =
      case server do
        name when is_atom(name) -> GenServer.call(name, :clock)
        _ -> RetrofitControl.Util.Clock
      end

    RetrofitControl.Util.set_clock(
      fn -> DateTime.new!(~D[2026-01-15], ~T[09:00:00.000000]) end,
      clock
    )

    ok!(Engine.register_line(%{
      line_id: "L1",
      name: "冲压一线",
      main_budget_cents: B.yuan(1_000_000),
      risk_budget_cents: B.yuan(200_000)
    }, server))

    ok!(Engine.register_line(%{
      line_id: "L2",
      name: "焊装二线",
      main_budget_cents: B.yuan(200_000),
      risk_budget_cents: B.yuan(40_000)
    }, server))

    # 设备能力清单：网关 5G 能力、采集器协议能力、边缘应用算力能力
    Enum.each(
      [
        {"GW-1", "gateway", ["5g_nsa", "vpn_boot"], "2.1.0"},
        {"COL-1", "collector", ["modbus_tcp", "opc_ua"], "1.4.0"},
        {"EDGE-1", "edge_app", ["vision_infer", "mqtt_bridge"], "3.0.0"}
      ],
      fn {id, kind, caps, fw} ->
        ok!(Engine.register_device(%{
          line_id: "L1",
          device_id: id,
          kind: kind,
          provides: caps,
          firmware: fw
        }, server))
      end
    )

    # 旧报价 v1：30 万/段，15% 风险储备，逾期 1‰/天（封顶 50%）
    ok!(Engine.record_quote(%{
      line_id: "L1",
      quote_id: "Q1",
      vendor_id: "VendorA",
      version: "v1",
      fee_cents: B.yuan(300_000),
      reserve_rate_bp: 1500,
      penalty_rate_bp_per_day: 10,
      penalty_cap_bp: 5000,
      planned: nil
    }, server))

    # 新报价 v2：能力升级后 32 万/段
    ok!(Engine.record_quote(%{
      line_id: "L1",
      quote_id: "Q2",
      vendor_id: "VendorB",
      version: "v2",
      fee_cents: B.yuan(320_000),
      reserve_rate_bp: 1500,
      penalty_rate_bp_per_day: 10,
      penalty_cap_bp: 5000
    }, server))

    # L2 报价
    ok!(Engine.record_quote(%{
      line_id: "L2",
      quote_id: "Q3",
      vendor_id: "VendorA",
      version: "v1",
      fee_cents: B.yuan(150_000),
      reserve_rate_bp: 1500
    }, server))

    # 三阶段里程碑（依赖链 P1 → P2 → P3）
    phases = [
      {"P1", "5G 网关上线", 1, ["5g_nsa"], "1.0.0", "2026-02-10"},
      {"P2", "采集器部署", 2, ["modbus_tcp", "opc_ua"], "1.0.0", "2026-03-15"},
      {"P3", "边缘应用验收", 3, ["vision_infer", "mqtt_bridge"], "2.0.0", "2026-04-20"}
    ]

    Enum.each(phases, fn {code, name, order, needs, fw, due} ->
      ok!(Engine.plan_phase(%{
        line_id: "L1",
        code: code,
        name: name,
        order: order,
        needs: needs,
        min_firmware: fw,
        planned_done_date: due
      }, server))
    end)

    # L2 一个阶段（预算竞争用）
    ok!(Engine.plan_phase(%{
      line_id: "L2",
      code: "P1",
      name: "L2 网关",
      order: 1,
      needs: ["5g_nsa"],
      planned_done_date: "2026-02-10"
    }, server))

    :ok
  end

  def activate(server, line_id, quote_id, version, idem \\ nil) do
    Engine.activate_contract(%{
      line_id: line_id,
      quote_id: quote_id,
      version: version,
      idempotency_key: idem
    }, server)
  end

  def start_p1(server, line_id \\ "L1", idem \\ nil) do
    Engine.start_phase(%{line_id: line_id, code: "P1", idempotency_key: idem}, server)
  end

  def submit(server, params, idem \\ nil) do
    Engine.submit_acceptance(Map.put(params, :idempotency_key, idem), server)
  end

  def approve(server, sid, idem \\ nil) do
    Engine.approve(%{submission_id: sid, idempotency_key: idem}, server)
  end

  def ok!({:ok, v}), do: v
  def ok!(other), do: raise("期望 {:ok, _}，实际：#{inspect(other)}")
end
