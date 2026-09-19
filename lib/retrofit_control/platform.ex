defmodule RetrofitControl.Platform do
  @moduledoc "生产环境 PostgreSQL 与 NATS 连接的配置边界。"

  def ready?(config) do
    Keyword.has_key?(config, :postgrex) and Keyword.has_key?(config, :nats)
  end
end
