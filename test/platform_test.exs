defmodule RetrofitControl.PlatformTest do
  use ExUnit.Case, async: true

  test "缺少外部适配器时不报告就绪" do
    refute RetrofitControl.Platform.ready?([])
  end

  test "同时配置 PostgreSQL 与 NATS 边界时报告就绪" do
    assert RetrofitControl.Platform.ready?(postgrex: [], nats: [])
  end
end
