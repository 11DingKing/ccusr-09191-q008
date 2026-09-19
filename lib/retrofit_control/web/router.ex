defmodule RetrofitControl.Web.Router do
  @moduledoc """
  HTTP 接口（Plug/Cowboy，无外部数据库与消息中间件依赖）。

  写接口支持 `Idempotency-Key` 请求头：断线重试、客户端重复点击、
  离线补传都不会产生重复扣款/重复推进。
  """

  use Plug.Router

  alias RetrofitControl.Engine

  plug(Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason
  )

  plug(:match)
  plug(:dispatch)

  # ── 健康与厂长视图 ────────────────────────────────────────────────

  get "/healthz" do
    send_json(conn, 200, %{status: "ok", service: "retrofit-control"})
  end

  get "/api/v1/board/lines" do
    send_json(conn, 200, %{lines: Engine.line_board()})
  end

  get "/api/v1/board/lines/:line_id" do
    send_json(conn, 200, Engine.line_board(Engine, conn.params["line_id"]))
  end

  get "/api/v1/board/budget" do
    send_json(conn, 200, Engine.budget_board())
  end

  get "/api/v1/audit" do
    opts =
      []
      |> maybe_opt(:line_id, conn.query_params["line_id"])
      |> maybe_opt(:limit, parse_pos_int(conn.query_params["limit"]))

    send_json(conn, 200, %{events: Engine.audit(Engine, opts)})
  end

  get "/api/v1/state" do
    # 诊断接口：完整读模型（金额单位：分）
    send_json(conn, 200, Engine.state() |> redact())
  end

  # ── 主数据 ────────────────────────────────────────────────

  post "/api/v1/lines" do
    command(conn, :register_line)
  end

  post "/api/v1/lines/:line_id/devices" do
    command(conn, :register_device, %{"line_id" => conn.params["line_id"]})
  end

  post "/api/v1/lines/:line_id/phases" do
    command(conn, :plan_phase, %{"line_id" => conn.params["line_id"]})
  end

  post "/api/v1/lines/:line_id/quotes" do
    command(conn, :record_quote, %{"line_id" => conn.params["line_id"]})
  end

  # ── 合同版本 ────────────────────────────────────────────────

  post "/api/v1/lines/:line_id/contracts/activate" do
    command(conn, :activate_contract, %{"line_id" => conn.params["line_id"]})
  end

  # ── 执行流程 ────────────────────────────────────────────────

  post "/api/v1/lines/:line_id/phases/:code/start" do
    command(conn, :start_phase, %{"line_id" => conn.params["line_id"], "code" => conn.params["code"]})
  end

  post "/api/v1/lines/:line_id/phases/:code/acceptance" do
    command(conn, :submit_acceptance, %{
      "line_id" => conn.params["line_id"],
      "code" => conn.params["code"]
    })
  end

  post "/api/v1/acceptance/:submission_id/approve" do
    command(conn, :approve, %{"submission_id" => conn.params["submission_id"]})
  end

  post "/api/v1/acceptance/:submission_id/reject" do
    command(conn, :reject, %{"submission_id" => conn.params["submission_id"]})
  end

  post "/api/v1/lines/:line_id/rollback" do
    command(conn, :rollback, %{"line_id" => conn.params["line_id"]})
  end

  # ── 外部采购回执（回调） ────────────────────────────────────────────────

  post "/api/v1/procurement/receipts" do
    command(conn, :receive_receipt)
  end

  get "/api/v1/procurement/pending" do
    send_json(conn, 200, %{pending: Engine.pending_pos()})
  end

  post "/api/v1/procurement/flush" do
    RetrofitControl.Procurement.Dispatcher.flush()
    send_json(conn, 200, %{flushed: true})
  end

  match _ do
    send_json(conn, 404, %{error: "NOT_FOUND", message: "路由不存在：#{conn.request_path}"})
  end

  # ── 辅助 ────────────────────────────────────────────────

  defp command(conn, action, extra \\ %{}) do
    idem = get_req_header(conn, "idempotency-key") |> List.first()
    body = conn.body_params || %{}

    params =
      body
      |> coerce_body()
      |> Map.merge(extra)
      |> Map.put_new("idempotency_key", idem)

    apply_engine(action, params, conn)
  end

  defp apply_engine(action, params, conn) do
    case apply(Engine, action, [params]) do
      {:ok, view} ->
        status = if is_map(view) and view[:auto_rejected] == true, do: 422, else: 200
        send_json(conn, status, view)

      {:error, %RetrofitControl.DomainError{} = err} ->
        send_json(conn, 409, %{error: err.code, message: err.message})

      {:error, other} ->
        send_json(conn, 500, %{error: "INTERNAL", message: inspect(other)})
    end
  end

  # 金额/数值字段转整数
  defp coerce_body(%{} = body) do
    Map.new(body, fn
      {k, v} when k in ["fee_cents", "main_budget_cents", "risk_budget_cents"] and is_binary(v) ->
        {k, String.to_integer(v)}

      {k, v} when k in ["reserve_rate_bp", "penalty_rate_bp_per_day", "penalty_cap_bp", "payment_days", "order"] and is_binary(v) ->
        {k, String.to_integer(v)}

      {k, v} ->
        {k, v}
    end)
  end

  defp maybe_opt(list, _k, nil), do: list
  defp maybe_opt(list, k, v), do: [{k, v} | list]

  defp parse_pos_int(nil), do: nil
  defp parse_pos_int(s) when is_binary(s), do: String.to_integer(s)

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  defp redact(state), do: state
end
