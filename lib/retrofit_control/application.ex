defmodule RetrofitControl.Application do
  @moduledoc "应用监督树：事件日志、采购模拟适配器、控制塔、HTTP 边界。"
  use Application

  @impl true
  def start(_type, _args) do
    data_dir = System.get_env("TOWER_DATA_DIR", Path.join(System.tmp_dir!(), "retrofit_control"))
    event_path = Path.join(data_dir, "events.log")
    port = System.get_env("PORT", "8080") |> String.to_integer()

    File.mkdir_p!(data_dir)

    children = [
      {Task.Supervisor, name: RetrofitControl.WebTaskSupervisor},
      RetrofitControl.HttpPort,
      {RetrofitControl.EventLog,
       name: RetrofitControl.EventLog, path: event_path},
      {RetrofitControl.Procurement.SimAdapter, name: RetrofitControl.Procurement.SimAdapter},
      %{
        id: RetrofitControl.TowerStarter,
        start: {__MODULE__, :start_tower, [event_path]},
        restart: :transient
      },
      %{
        id: RetrofitControl.HttpTask,
        start:
          {Task, :start_link,
           [
             fn ->
               RetrofitControl.HttpServer.accept(port, &RetrofitControl.Router.handle/1)
             end
           ]},
        restart: :permanent
      }
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: RetrofitControl.Supervisor)
  end

  def start_tower(event_path) do
    case RetrofitControl.Tower.start_link(
           name: RetrofitControl.Tower,
           event_log: RetrofitControl.EventLog,
           adapter: RetrofitControl.Procurement.SimAdapter,
           adapter_name: RetrofitControl.Procurement.SimAdapter,
           path: event_path
         ) do
      {:ok, pid} ->
        # 启动即做断点恢复（快照 + 事件重放），保证服务重启后状态一致。
        {:ok, _info} = RetrofitControl.Tower.recover_restart(RetrofitControl.Tower)
        {:ok, pid}

      other ->
        other
    end
  end
end
