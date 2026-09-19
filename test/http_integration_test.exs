defmodule RetrofitControl.HttpIntegrationTest do
  use ExUnit.Case, async: false

  alias RetrofitControl.Json

  setup_all do
    dir = Path.join(System.tmp_dir!(), "tower_http_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    start_app(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    # 让服务绑定端口 0（由内核分配），再从 HttpPort 读取实际端口，避免 close/re-bind 竞态。
    port = wait_bound(100)
    wait_ready(port, 100)
    %{port: port, dir: dir}
  end

  defp start_app(dir) do
    System.put_env("TOWER_DATA_DIR", dir)
    System.put_env("PORT", "0")

    {:ok, _} = Application.ensure_all_started(:retrofit_control)
    :retrofit_control
  end

  defp wait_bound(0), do: flunk("HTTP server never bound a port")

  defp wait_bound(n) do
    case RetrofitControl.HttpPort.get() do
      nil ->
        Process.sleep(20)
        wait_bound(n - 1)

      port ->
        port
    end
  end

  defp wait_ready(_port, 0), do: flunk("server never became ready")

  defp wait_ready(port, n) do
    case request(port, "GET", "/healthz", nil, nil) do
      {:ok, 200, _} -> :ok
      _ ->
        Process.sleep(25)
        wait_ready(port, n - 1)
    end
  end

  defp request(port, method, path, body, idem, retries \\ 5) do
    case :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :raw]) do
      {:ok, sock} ->
        do_request(sock, method, path, body, idem)

      {:error, :econnrefused} when retries > 0 ->
        Process.sleep(25)
        request(port, method, path, body, idem, retries - 1)
    end
  end

  defp do_request(sock, method, path, body, idem) do
    body = body && Json.encode(body)

    headers =
      [~s(Host: localhost), "Connection: close"]
      |> Kernel.++(if body, do: ["Content-Type: application/json", "Content-Length: #{byte_size(body)}"], else: [])
      |> Kernel.++(if idem, do: ["Idempotency-Key: #{idem}"], else: [])
      |> Enum.join("\r\n")

    payload =
      "#{method} #{path} HTTP/1.1\r\n#{headers}\r\n\r\n#{if body, do: body, else: ""}"

    :ok = :gen_tcp.send(sock, payload)
    {:ok, resp} = read_until_closed(sock, "")
    :gen_tcp.close(sock)
    parse(resp)
  end

  # 连接由服务端在响应后关闭：读到 closed 即完整；timeout 只作为兜底再补读一次。
  defp read_until_closed(sock, acc) do
    case :gen_tcp.recv(sock, 0, 3_000) do
      {:ok, data} -> read_until_closed(sock, acc <> data)
      {:error, :closed} -> {:ok, acc}
      {:error, :timeout} -> maybe_reread(sock, acc)
    end
  end

  defp maybe_reread(sock, acc) do
    case :gen_tcp.recv(sock, 0, 200) do
      {:ok, data} -> read_until_closed(sock, acc <> data)
      _ -> {:ok, acc}
    end
  end

  defp parse(resp) do
    [status_line | _] = String.split(resp, "\r\n")
    [_, code_str | _] = String.split(status_line, " ")
    code = String.to_integer(code_str)

    body =
      case String.split(resp, "\r\n\r\n", parts: 2) do
        [_] -> nil
        [_, b] when b == "" -> nil
        [_, b] -> Json.decode(b) |> elem(1)
      end

    {:ok, code, body}
  end

  test "健康检查", %{port: port} do
    assert {:ok, 200, %{"status" => "ok"}} = request(port, "GET", "/healthz", nil, nil)
  end

  test "厂长可通过报表看到哪条产线可继续、哪笔预算被锁定、回退节点", %{port: port} do
    # 播种：产线 + 预算 + 合同 + 阶段
    assert {:ok, 200, _} = request(port, "POST", "/lines", %{id: "HL1", name: "HTTP装配线"}, nil)

    assert {:ok, 200, _} =
             request(
               port,
               "POST",
               "/devices",
               %{
                 id: "HD1",
                 line_id: "HL1",
                 kind: "gateway",
                 class: "G1",
                 caps: ["5g_nsa", "mqtt"],
                 vendor_id: "vA"
               },
               nil
             )

    assert {:ok, 200, _} =
             request(
               port,
               "POST",
               "/contracts",
               %{
                 id: "HC1",
                 line_id: "HL1",
                 vendor_id: "vA",
                 version: 1,
                 effective_from: "2026-01-01"
               },
               nil
             )

    assert {:ok, 200, _} =
             request(port, "POST", "/budget", %{total: 100_000, reserve: 20_000}, nil)

    assert {:ok, 200, _} =
             request(
               port,
               "POST",
               "/phases",
               %{
                 id: "HP1",
                 line_id: "HL1",
                 seq: 1,
                 name: "5G网关",
                 device_class: "G1",
                 required_caps: ["5g_nsa"],
                 planned_end: "2026-12-31",
                 amount_cents: 30_000,
                 vendor_id: "vA"
               },
               nil
             )

    # 提交 + 批准（幂等头）
    assert {:ok, 200, sub} =
             request(
               port,
               "POST",
               "/acceptances",
               %{
                 phase_id: "HP1",
                 vendor_id: "vA",
                 contract_version_id: "HC1",
                 device_caps: ["5g_nsa", "mqtt"]
               },
               "submit-hp1"
             )

    sid = sub["submission_id"]

    assert {:ok, 200, app} =
             request(port, "POST", "/submissions/#{sid}/approve", %{actor: "厂长"}, "appr-hp1")

    assert app["decision"] == "approved"

    # 重复带相同幂等键 -> 幂等，不重复锁预算
    assert {:ok, 200, again} =
             request(port, "POST", "/submissions/#{sid}/approve", %{actor: "厂长"}, "appr-hp1")

    assert again["idempotent"] == true

    # 报表：预算锁定 30_000，产线安全节点为 1
    assert {:ok, 200, report} = request(port, "GET", "/report", nil, nil)
    assert report["budget"]["locked_cents"] == 30_000
    line = Enum.find(report["lines"], &(&1["line_id"] == "HL1"))
    assert line["safety_node"] == 1

    # 回滚
    assert {:ok, 200, rb} =
             request(port, "POST", "/lines/HL1/rollback", %{actor: "厂长", reason: "复测不兼容"}, nil)

    assert rb["rolled_back_to_safety_node"] == 0

    assert {:ok, 200, report2} = request(port, "GET", "/report", nil, nil)
    assert report2["budget"]["locked_cents"] == 0
  end

  test "旧合同版本提交被裁决拒绝（留痕且不锁定预算）", %{port: port} do
    assert {:ok, 200, _} = request(port, "POST", "/lines", %{id: "HL2", name: "线2"}, nil)

    assert {:ok, 200, _} =
             request(
               port,
               "POST",
               "/devices",
               %{
                 id: "HD2",
                 line_id: "HL2",
                 kind: "gateway",
                 class: "G2",
                 caps: ["5g_nsa"],
                 vendor_id: "vA"
               },
               nil
             )

    assert {:ok, 200, _} =
             request(
               port,
               "POST",
               "/contracts",
               %{id: "HC2", line_id: "HL2", vendor_id: "vA", version: 1, effective_from: "2026-01-01"},
               nil
             )

    assert {:ok, 200, _} = request(port, "POST", "/budget", %{total: 10_000, reserve: 0}, nil)

    assert {:ok, 200, _} =
             request(
               port,
               "POST",
               "/phases",
               %{
                 id: "HP2",
                 line_id: "HL2",
                 seq: 1,
                 name: "g",
                 device_class: "G2",
                 required_caps: ["5g_nsa"],
                 planned_end: "2026-12-31",
                 amount_cents: 1_000,
                 vendor_id: "vA"
               },
               nil
             )

    assert {:ok, 200, decision} =
             request(
               port,
               "POST",
               "/acceptances",
               %{phase_id: "HP2", vendor_id: "vA", contract_version_id: "OLD", device_caps: ["5g_nsa"]},
               nil
             )

    # 旧合同版本：提交被持久化留痕但裁决拒绝，且不得锁定任何预算
    assert decision["decision"] == "denied"
    assert decision["reason"] =~ "合同版本"

    assert {:ok, 200, report} = request(port, "GET", "/report", nil, nil)
    assert report["budget"]["locked_cents"] == 0
  end
end
