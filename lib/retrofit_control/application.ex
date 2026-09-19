defmodule RetrofitControl.Application do
  @moduledoc "应用监督树：事件日志 → 领域引擎 → 采购补偿投递器 → HTTP 服务。"
  use Application

  @impl true
  def start(_type, _args) do
    if Application.get_env(:retrofit_control, :autostart, true) == false do
      Supervisor.start_link([], strategy: :one_for_one, name: RetrofitControl.Supervisor)
    else
      do_start()
    end
  end

  defp do_start do
    port = Application.get_env(:retrofit_control, :http_port, 8080)
    client = Application.get_env(:retrofit_control, :procurement_client, RetrofitControl.Procurement.MockClient)
    auto_dispatch = Application.get_env(:retrofit_control, :auto_dispatch, true)

    children =
      [
        # Engine 启动时自带 Journal（同进程组链接，Journal 崩溃会连带重启引擎并重放恢复）
        RetrofitControl.Engine,
        # 内置“外部采购系统”（演示用；生产替换为 HttpcClient 对接真实系统）
        if(client == RetrofitControl.Procurement.MockClient, do: RetrofitControl.Procurement.MockServer, else: nil),
        if(client == RetrofitControl.Procurement.MockClient, do: RetrofitControl.Procurement.MockClient, else: nil),
        {RetrofitControl.Procurement.Dispatcher, [client: client, auto: auto_dispatch]},
        {Plug.Cowboy, scheme: :http, plug: RetrofitControl.Web.Router, options: [port: port]}
      ]
      |> Enum.reject(&is_nil/1)

    opts = [strategy: :rest_for_one, name: RetrofitControl.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
