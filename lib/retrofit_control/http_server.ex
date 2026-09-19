defmodule RetrofitControl.HttpServer do
  @moduledoc """
  基于 :gen_tcp 的极简 HTTP/1.1 适配器（零外部依赖）。

  采用 raw 模式自行完成最小可用的 HTTP/1.1 请求解析（请求行 + 头部 + Content-Length body），
  避免 Erlang http_bin/http 解析器在切换 packet 模式时的缓冲语义差异。
  生产可替换为 Bandit/Plug；此处只为控制塔提供可运行的 HTTP 边界。
  """

  require Logger

  @max_header_bytes 1_000_000
  @header_wait_ms 5_000
  @body_wait_ms 15_000

  def accept(port, handler) do
    socket = listen_with_retry(port, 50)
    {:ok, actual_port} = :inet.port(socket)

    if port != actual_port do
      Logger.info("HTTP server listening on ephemeral port #{actual_port}")
    else
      Logger.info("HTTP server listening on #{actual_port}")
    end

    if Process.whereis(RetrofitControl.HttpPort), do: RetrofitControl.HttpPort.put(actual_port)
    loop_acceptor(socket, handler)
  end

  defp listen_with_retry(port, 0), do: raise("cannot bind port #{port}")

  defp listen_with_retry(port, attempts) do
    case :gen_tcp.listen(port, [:binary, packet: :raw, active: false, reuseaddr: true]) do
      {:ok, socket} ->
        socket

      {:error, :eaddrinuse} ->
        Process.sleep(20)
        listen_with_retry(port, attempts - 1)

      {:error, other} ->
        raise "listen error on port #{port}: #{inspect(other)}"
    end
  end

  defp loop_acceptor(socket, handler) do
    case :gen_tcp.accept(socket) do
      {:ok, client} ->
        {:ok, pid} =
          Task.Supervisor.start_child(RetrofitControl.WebTaskSupervisor, fn ->
            serve(client, handler)
          end)

        # 即使单连接处理进程已退出，也不能让 accept 循环崩掉（保证服务持续可用）。
        _ = :gen_tcp.controlling_process(client, pid)
        loop_acceptor(socket, handler)

      {:error, :closed} ->
        :stopped

      {:error, :emfile} ->
        Process.sleep(50)
        loop_acceptor(socket, handler)

      {:error, _other} ->
        loop_acceptor(socket, handler)
    end
  end

  defp serve(client, handler) do
    with {:ok, head_buf, headers} <- read_headers(client, ""),
         {:ok, method, path} <- parse_request_line(headers),
         {:ok, body, _rest} <- read_body(client, head_buf, headers) do
      resp = handler.(%{method: method, path: path, headers: headers, body: body})
      send_resp(client, resp)
    else
      {:error, :closed} ->
        :ok

      {:error, :bad_request} ->
        send_resp(client, {400, ~s({"error":"bad_request"})})

      {:error, _reason} ->
        send_resp(client, {400, ~s({"error":"bad_request"})})
    end
  rescue
    e ->
      Logger.error("HTTP serve error: #{Exception.message(e)}")
      send_resp(client, {500, ~s({"error":"internal"})})
  catch
    :exit, _ -> :ok
  end

  # 读到 \r\n\r\n 为止；head_buf 保留分隔符之后的字节（可能是部分/全部 body）。
  defp read_headers(client, acc) do
    cond do
      byte_size(acc) > @max_header_bytes ->
        {:error, :too_large}

      String.contains?(acc, "\r\n\r\n") ->
        [head, tail] = String.split(acc, "\r\n\r\n", parts: 2)
        {:ok, tail, parse_headers(head)}

      true ->
        case :gen_tcp.recv(client, 0, @header_wait_ms) do
          {:ok, chunk} -> read_headers(client, acc <> chunk)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp parse_headers(head) do
    [request_line | lines] = String.split(head, "\r\n")

    headers =
      lines
      |> Enum.map(fn line ->
        case String.split(line, ":", parts: 2) do
          [k, v] -> {String.trim(k) |> String.downcase(), String.trim(v)}
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    [{"request_line", String.trim(request_line)} | headers]
  end

  defp parse_request_line(headers) do
    with request_line when is_binary(request_line) <- header(headers, "request_line"),
         [method_str, raw_path | _] <- String.split(request_line, " ") do
      path = raw_path |> String.split("?") |> hd()
      {:ok, method(method_str), path}
    else
      _ -> {:error, :bad_request}
    end
  end

  defp header(headers, key),
    do: Enum.find_value(headers, fn {k, v} -> if k == key, do: v end)

  defp method("GET"), do: :GET
  defp method("POST"), do: :POST
  defp method("PUT"), do: :PUT
  defp method("DELETE"), do: :DELETE
  defp method("PATCH"), do: :PATCH
  defp method(_), do: :OTHER

  defp read_body(client, head_buf, headers) do
    case header(headers, "content-length") do
      nil ->
        {:ok, "", head_buf}

      len_str ->
        case Integer.parse(len_str) do
          {len, _} when len >= 0 ->
            collect_body(client, head_buf, len)

          _ ->
            {:error, :bad_request}
        end
    end
  end

  defp collect_body(_client, buf, len) when byte_size(buf) >= len do
    body = binary_part(buf, 0, len)
    {:ok, body, binary_part(buf, len, byte_size(buf) - len)}
  end

  defp collect_body(client, buf, len) do
    need = len - byte_size(buf)

    case :gen_tcp.recv(client, need, @body_wait_ms) do
      {:ok, chunk} -> collect_body(client, buf <> chunk, len)
      {:error, reason} -> {:error, reason}
    end
  end

  defp send_resp(client, {status, body}) when is_integer(status) and is_binary(body) do
    resp =
      [
        "HTTP/1.1 #{status} #{status_reason(status)}\r\n",
        "content-type: application/json; charset=utf-8\r\n",
        "content-length: #{byte_size(body)}\r\n",
        "connection: close\r\n\r\n",
        body
      ]

    :gen_tcp.send(client, resp)
    # 半关闭写端后再关，确保客户端能在收到 FIN 前读完整响应，避免读侧丢尾包。
    :gen_tcp.shutdown(client, :write)
    :gen_tcp.close(client)
  end

  defp status_reason(200), do: "OK"
  defp status_reason(201), do: "Created"
  defp status_reason(400), do: "Bad Request"
  defp status_reason(404), do: "Not Found"
  defp status_reason(408), do: "Request Timeout"
  defp status_reason(409), do: "Conflict"
  defp status_reason(422), do: "Unprocessable Entity"
  defp status_reason(500), do: "Internal Server Error"
  defp status_reason(_), do: "OK"
end
