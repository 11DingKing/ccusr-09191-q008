defmodule RetrofitControl.Router do
  @moduledoc """
  HTTP 路由：把厂长/服务商/采购系统的请求映射到控制塔命令。

  所有写接口都接受可选的 `Idempotency-Key` 头做幂等；
  成功返回 200/201，业务前置不满足返回 409/422，缺参数返回 400。
  """

  alias RetrofitControl.{Json, Tower}

  @tower RetrofitControl.Tower

  # 允许从 JSON 字符串键安全转换为原子键的白名单（避免 String.to_atom 动态泄漏）。
  @known_keys ~w(
    id name kind class caps line_id vendor_id version effective_from note by_version
    valid_until contract_id amount_cents total reserve seq device_class
    required_caps planned_end depends_on quote_id phase_id contract_version_id
    device_id device_caps evidence actor reason completed_at penalty
    rate_per_day_bp cap_bp from_seq to_seq stored_key payload occurred_at
    offline order_id receipt_key status submission_id firmware
  )

  def handle(%{method: method, path: path, body: body, headers: headers}) do
    idem = header(headers, "idempotency-key")
    route(method, trim_path(path), body, idem)
  end

  defp header(headers, key) do
    Enum.find_value(headers, fn
      {k, v} when k == key -> to_string(v)
      _ -> nil
    end)
  end

  defp trim_path(path) do
    path |> String.split("?") |> hd() |> String.trim("/")
  end

  # ---- health / read ----
  defp route(:GET, "healthz", _, _), do: {200, ~s({"status":"ok"})}
  defp route(:GET, "report", _, _), do: ok(Tower.report(@tower))
  defp route(:GET, "audits", _, _), do: ok(Tower.audits(@tower))
  defp route(:GET, "state", _, _), do: ok(serialize(Tower.state(@tower)))

  # ---- 基础档案 ----
  defp route(:POST, "lines", body, idem),
    do: command(body, idem, &Tower.register_line(@tower, &1, &2))

  defp route(:POST, "devices", body, idem),
    do: command(body, idem, &Tower.catalog_device(@tower, &1, &2))

  defp route(:POST, "contracts", body, idem),
    do: command(body, idem, &Tower.record_contract(@tower, &1, &2))

  defp route(:POST, "quotes", body, idem),
    do: command(body, idem, &Tower.record_quote(@tower, &1, &2))

  defp route(:POST, "budget", body, idem),
    do: command(body, idem, &Tower.configure_budget(@tower, &1, &2))

  defp route(:POST, "phases", body, idem),
    do: command(body, idem, &Tower.plan_phase(@tower, &1, &2))

  defp route(:POST, "contracts/" <> rest, body, idem) do
    case String.split(rest, "/") do
      [id, "supersede"] ->
        with_params(body, idem, fn p, idem ->
          Tower.supersede_contract(@tower, id, p[:by_version], idem)
        end)

      _ ->
        not_found()
    end
  end

  # ---- 验收 / 推进 ----
  defp route(:POST, "acceptances", body, idem),
    do: command(body, idem, &Tower.submit_acceptance(@tower, &1, &2))

  defp route(:POST, "submissions/" <> rest, body, idem) do
    case String.split(rest, "/") do
      [id, "approve"] ->
        with_params(body, idem, fn p, idem ->
          Tower.approve(@tower, id, p[:actor] || "厂长", idem)
        end)

      [id, "reject"] ->
        with_params(body, idem, fn p, idem ->
          Tower.reject(@tower, id, p[:reason] || "验收不通过", p[:actor] || "厂长", idem)
        end)

      _ ->
        not_found()
    end
  end

  defp route(:POST, "phases/" <> rest, body, idem) do
    case String.split(rest, "/") do
      [id, "accept"] ->
        with_params(body, idem, fn p, idem ->
          p =
            p
            |> Map.put(:phase_id, id)
            |> Map.update(:completed_at, nil, &parse_date/1)
            |> maybe_penalty()

          Tower.confirm_accepted(@tower, p, idem)
        end)

      _ ->
        not_found()
    end
  end

  defp route(:POST, "lines/" <> rest, body, idem) do
    case String.split(rest, "/") do
      [lid, "rollback"] ->
        with_params(body, idem, fn p, idem ->
          opts =
            p
            |> Map.take([:to_seq, :from_seq, :actor, :reason])
            |> Enum.reject(fn {_, v} -> is_nil(v) end)
            |> Map.new()

          Tower.rollback(@tower, lid, opts, idem)
        end)

      _ ->
        not_found()
    end
  end

  # ---- 离线 ----
  defp route(:POST, "offline", body, idem),
    do: command(body, idem, &Tower.store_offline_result(@tower, &1, &2))

  defp route(:POST, "offline/" <> rest, body, idem) do
    case String.split(rest, "/") do
      [key, "backfill"] ->
        with_params(body, idem, fn _p, idem -> Tower.backfill_acceptance(@tower, key, idem) end)

      _ ->
        not_found()
    end
  end

  # ---- 采购 ----
  defp route(:POST, "procurement/receipts", body, idem),
    do: command(body, idem, &Tower.receive_receipt(@tower, &1, &2))

  defp route(:POST, "procurement/retry", _body, _idem) do
    case Tower.retry_pending_procurement(@tower) do
      {:ok, results} -> ok(%{retried: results})
      e -> unwrap(e)
    end
  end

  defp route(:POST, "admin/recover", _body, _idem) do
    case Tower.recover_restart(@tower) do
      {:ok, info} -> {200, Json.encode(info)}
      e -> unwrap(e)
    end
  end

  defp route(_, _, _, _), do: not_found()

  defp command(body, idem, fun), do: with_params(body, idem, fun)

  defp with_params(raw, idem, fun) do
    case parse_json(raw) do
      {:ok, params} when is_map(params) ->
        params = coerce(atomize(params))
        unwrap(fun.(params, idem))

      {:error, msg} ->
        {400, Json.encode(%{error: msg})}
    end
  end

  defp parse_json(""), do: {:ok, %{}}
  defp parse_json(nil), do: {:ok, %{}}

  defp parse_json(raw) do
    case Json.decode(raw) do
      {:ok, map} when is_map(map) -> {:ok, map}
      {:ok, _} -> {:error, "请求体必须是 JSON 对象"}
      {:error, msg} -> {:error, msg}
    end
  end

  defp atomize(map) when is_map(map) do
    map
    |> Enum.filter(fn {k, _} -> k in @known_keys end)
    |> Map.new(fn {k, v} -> {String.to_existing_atom(k), atomize(v)} end)
  end

  defp atomize(list) when is_list(list), do: Enum.map(list, &atomize/1)
  defp atomize(other), do: other

  defp coerce(p) do
    p
    |> maybe_date(:planned_end)
    |> maybe_date(:effective_from)
    |> maybe_date(:valid_until)
    |> maybe_date(:occurred_at)
  end

  defp maybe_date(p, key) do
    case Map.get(p, key) do
      s when is_binary(s) -> Map.put(p, key, parse_date(s))
      _ -> p
    end
  end

  defp maybe_penalty(p) do
    case Map.get(p, :penalty) do
      m when is_map(m) and m != %{} ->
        kw = m |> atomize() |> Enum.to_list()
        Map.put(p, :penalty, kw)

      _ ->
        Map.delete(p, :penalty)
    end
  end

  defp parse_date(s) do
    case Date.from_iso8601(s) do
      {:ok, d} -> d
      _ -> s
    end
  end

  defp unwrap({:ok, result}), do: {200, Json.encode(serialize(result))}
  defp unwrap(:ok), do: {200, ~s({"ok":true})}
  defp unwrap({:error, reason}), do: {422, Json.encode(%{error: reason})}

  defp ok(term), do: {200, Json.encode(serialize(term))}
  defp not_found, do: {404, ~s({"error":"not_found"})}

  # 让 Date / NaiveDateTime / MapSet / 结构体可被 JSON 编码。
  defp serialize(%Date{} = d), do: Date.to_iso8601(d)
  defp serialize(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)
  defp serialize(%MapSet{} = ms), do: MapSet.to_list(ms)

  defp serialize(struct) when is_struct(struct) do
    struct |> Map.from_struct() |> serialize()
  end

  defp serialize(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), serialize(v)}
      {k, v} -> {to_string(k), serialize(v)}
    end)
  end

  defp serialize(list) when is_list(list), do: Enum.map(list, &serialize/1)
  defp serialize(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> serialize()
  defp serialize(other), do: other
end
