defmodule RetrofitControl.PlatformTest do
  use ExUnit.Case, async: true

  test "缺少外部适配器时不报告就绪" do
    refute RetrofitControl.Platform.ready?([])
  end
end
