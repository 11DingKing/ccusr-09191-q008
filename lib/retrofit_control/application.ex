defmodule RetrofitControl.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Plug.Cowboy, scheme: :http, plug: RetrofitControl.Router, options: [port: port()]}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: RetrofitControl.Supervisor)
  end

  defp port do
    System.get_env("PORT", "8080") |> String.to_integer()
  end
end
