defmodule RetrofitControl.JsonTest do
  use ExUnit.Case, async: true
  alias RetrofitControl.Json

  test "数字、字符串、数组、对象与转义的解码" do
    assert {:ok, 1} = Json.decode("1")
    assert {:ok, -3} = Json.decode("-3")
    assert {:ok, 1.5} = Json.decode("1.5")
    assert {:ok, 1000.0} = Json.decode("1e3")
    assert {:ok, -2.5e-4} = Json.decode("-2.5E-2")
    assert {:ok, [1, 2, 3]} = Json.decode("[1,2,3]")

    assert {:ok, %{"a" => 1, "b" => "x", "c" => [true, nil, false]}} =
             Json.decode(~s({"a":1,"b":"x","c":[true,null,false]}))

    assert {:ok, "a\"b\\c\n"} = Json.decode(~s("a\\"b\\\\c\\n"))
  end

  test "紧跟 } 或 ] 的数字不会吞掉分隔符" do
    assert {:ok, %{"version" => 1}} = Json.decode(~s({"version":1}))
    assert {:ok, %{"x" => %{"y" => [10, 20]}, "z" => -1}} =
             Json.decode(~s({"x":{"y":[10,20]},"z":-1}))
  end

  test "非法 JSON 返回错误而非崩溃" do
    assert {:error, _} = Json.decode("{")
    assert {:error, _} = Json.decode(~s({"a":}))
    assert {:error, _} = Json.decode("123x")
  end

  test "编码往返" do
    map = %{"line_id" => "L1", "amount_cents" => 30_000, "monthly" => %{"2026-09" => 5714}}
    assert {:ok, ^map} = map |> Json.encode() |> Json.decode()
  end
end
