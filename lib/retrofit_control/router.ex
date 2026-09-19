defmodule RetrofitControl.Router do
  use Plug.Router

  plug :match
  plug :dispatch

  get "/healthz" do
    send_resp(conn, 200, ~s({"status":"ok"}))
  end

  match _ do
    send_resp(conn, 404, ~s({"error":"not_found"}))
  end
end
