defmodule RetrofitControl.MixProject do
  use Mix.Project

  def project do
    [
      app: :retrofit_control,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [
      # :inets/:ssl 仅在对接真实外部采购系统（Erlang :httpc）时使用；
      # 交付包内置的采购系统是内存模拟服务，断网也可运行全部流程与测试。
      extra_applications: [:logger, :crypto, :inets, :ssl],
      mod: {RetrofitControl.Application, []}
    ]
  end

  defp deps do
    [
      # 运行环境为 Elixir 1.14 / OTP 25：固定到兼容版本
      {:plug, "~> 1.13.6", override: true},
      {:plug_cowboy, "~> 2.6.0"},
      {:cowboy, "~> 2.10.0", override: true},
      {:jason, "~> 1.4.0"}
    ]
  end
end
