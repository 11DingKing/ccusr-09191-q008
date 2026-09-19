defmodule RetrofitControl.MixProject do
  use Mix.Project

  def project do
    [app: :retrofit_control, version: "0.1.0", elixir: "~> 1.17", start_permanent: Mix.env() == :prod, deps: deps()]
  end

  def application, do: [extra_applications: [:logger], mod: {RetrofitControl.Application, []}]

  defp deps do
    [
      {:phoenix, "~> 1.7"},
      {:plug_cowboy, "~> 2.7"},
      {:ecto_sql, "~> 3.12"},
      {:postgrex, ">= 0.0.0"},
      {:gnat, "~> 1.9"}
    ]
  end
end
