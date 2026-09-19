defmodule RetrofitControl.HTTPTest do
  use ExUnit.Case, async: false

  alias RetrofitControl.{Engine, Util, Procurement}

  @port 8199

  setup_all do
    dir = Path.join(System.tmp_dir!(), "rc-http-test-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    # 默认应用监督树在 test 环境不自动启动；幂等启动 HTTP 所需默认单例。
    unless Process.whereis(RetrofitControl.Util.Clock) do
      {:ok, _} = Util.start_clock(RetrofitControl.Util.Clock)
    end

    # 让 Engine 用全新目录启动其 Journal（避免读到上一次运行的默认目录）
    unless Process.whereis(RetrofitControl.Engine) do
      {:ok, _} = Engine.start_link(dir: dir)
    end

    Procurement.MockServer.reset()
    Procurement.MockClient.set_mode("ok")

    unless Process.whereis(RetrofitControl.Procurement.Dispatcher) do
      {:ok, _} =
        Procurement.Dispatcher.start_link(
          client: Procurement.MockClient,
          engine: RetrofitControl.Engine,
          auto: false
        )
    end

    {:ok, _} = Plug.Cowboy.http(RetrofitControl.Web.Router, [], port: @port, ref: :test_http)

    on_exit(fn -> Plug.Cowboy.shutdown(:test_http) end)

    line_suffix =
      4 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

    {:ok, suffix: line_suffix}
  end

  defp req(method, path, body \\ nil, headers \\ []) do
    :inets.start()
    :ssl.start()
    url = String.to_charlist("http://127.0.0.1:#{@port}#{path}")
    headers = [{'content-type', 'application/json'} | headers]

    request =
      case method do
        :get ->
          {:get, {url, headers}}

        :post ->
          {:post, {url, headers, 'application/json', if(body, do: Jason.encode!(body), else: ~c"")}}
      end

    {:ok, {{_, status, _}, resp_headers, resp_body}} =
      :httpc.request(elem(request, 0), elem(request, 1), [{:timeout, 3000}], [])

    downcased =
      Enum.map(resp_headers, fn {k, v} ->
        {String.downcase(to_string(k)), to_string(v)}
      end)

    {status, Jason.decode!(resp_body), downcased}
  end

  test "健康检查" do
    {200, body, _} = req(:get, "/healthz")
    assert body["status"] == "ok"
  end

  test "完整业务链路 + 厂长看板 JSON 可直接阅读", %{suffix: suf} do
    line = "L" <> suf
    dev = "GW" <> suf
    quote_id = "Q" <> suf
    phase = "P" <> suf

    {200, _, _} =
      req(:post, "/api/v1/lines", %{
        line_id: line, name: "冲压一线-#{suf}",
        main_budget_cents: 50_000_000, risk_budget_cents: 10_000_000
      })

    {200, _, _} =
      req(:post, "/api/v1/lines/#{line}/devices", %{
        device_id: dev, kind: "gateway", provides: ["5g_nsa"], firmware: "2.0"
      })

    {200, _, _} =
      req(:post, "/api/v1/lines/#{line}/phases", %{
        code: phase, name: "网关", order: 1, needs: ["5g_nsa"],
        planned_done_date: "2026-02-10"
      })

    {200, _, _} =
      req(:post, "/api/v1/lines/#{line}/quotes", %{
        quote_id: quote_id, vendor_id: "VendorA", version: "v1", fee_cents: 30_000_00
      })

    {200, contract, _} =
      req(:post, "/api/v1/lines/#{line}/contracts/activate", %{quote_id: quote_id})

    assert contract["version"] == "v1"

    {200, started, _} = req(:post, "/api/v1/lines/#{line}/phases/#{phase}/start", %{})
    assert started["locked_fee_cents"] == 30_000_00

    {200, submitted, _} =
      req(:post, "/api/v1/lines/#{line}/phases/#{phase}/acceptance", %{
        vendor_id: "VendorA", device_ids: [dev], captured_at: "2026-02-09"
      }, [{'idempotency-key', String.to_charlist("sub-http-#{suf}")}])

    sid = submitted["submission_id"]

    # 幂等头重放：同一个键返回同一张验收单
    {200, again, _} =
      req(:post, "/api/v1/lines/#{line}/phases/#{phase}/acceptance", %{
        vendor_id: "VendorA", device_ids: [dev], captured_at: "2026-02-09"
      }, [{'idempotency-key', String.to_charlist("sub-http-#{suf}")}])

    assert again["submission_id"] == sid

    {200, approved, _} = req(:post, "/api/v1/acceptance/#{sid}/approve", %{})
    assert approved["approved"] == true

    {200, board, _} = req(:get, "/api/v1/board/lines/#{line}")
    assert board["safe_node"] == phase
    assert board["safe_node_cn"] =~ phase

    {200, budget, _} = req(:get, "/api/v1/board/budget")
    line_budget = Enum.find(budget["per_line"], &(&1["line_id"] == line))
    assert line_budget["main_consumed_cents"] == 30_000_00
    assert is_list(budget["monthly"])

    {200, audit, _} = req(:get, "/api/v1/audit?line_id=#{line}&limit=8")
    types = Enum.map(audit["events"], & &1["type"])
    assert "budget_locked" in types
    assert "acceptance_approved" in types
    assert "po_created" in types
    assert List.last(audit["events"])["type"] == "po_created"
  end

  test "业务错误返回 409 与稳定错误码" do
    {status, body, _} = req(:post, "/api/v1/lines/NO-SUCH-LINE-9/phases/P1/start", %{})
    assert status == 409
    assert body["error"] == "NOT_FOUND"
  end
end
