defmodule RetrofitControl.HttpPort do
  @moduledoc "保存当前 HTTP 监听端口，供测试在绑定端口 0 后发现实际端口。"
  use Agent

  def start_link(_ \\ []), do: Agent.start_link(fn -> nil end, name: __MODULE__)
  def put(port), do: Agent.update(__MODULE__, fn _ -> port end)
  def get, do: Agent.get(__MODULE__, & &1)
end
