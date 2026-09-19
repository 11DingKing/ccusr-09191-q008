defmodule RetrofitControl.MixProject do
  use Mix.Project

  def project do
    [
      app: :retrofit_control,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  # 自动化测试不自动启动应用（HTTP 集成测试按需显式启动，使用独立端口与临时数据目录）。
  defp aliases do
    [
      test: "test --no-start"
    ]
  end

  # 核心领域、事件存储与 HTTP 适配器均使用 Erlang/Elixir 标准库实现，
  # 因此运行与自动化测试不依赖外部数据库或消息中间件（测试不建立外部连接）。
  # PostgreSQL/NATS 等生产适配器通过 RetrofitControl.Platform 的配置边界接入。
  def application do
    [
      extra_applications: [:logger],
      mod: {RetrofitControl.Application, []}
    ]
  end

  defp deps do
    []
  end
end
