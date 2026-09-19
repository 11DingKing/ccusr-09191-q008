ExUnit.start(assert_receive_timeout: 2000)

# 外部采购系统模拟（命名单例）：整个测试运行共享，每个用例之间重置去重表。
# start_if_not_started 兼容 test_helper 在同一 VM 中被重复加载的情况。
unless Process.whereis(RetrofitControl.Procurement.MockServer) do
  {:ok, _} = RetrofitControl.Procurement.MockServer.start_link([])
end

unless Process.whereis(RetrofitControl.Procurement.MockClient) do
  {:ok, _} = RetrofitControl.Procurement.MockClient.start_link([])
end

ExUnit.after_suite(fn _ ->
  if Process.whereis(RetrofitControl.Procurement.MockServer) do
    RetrofitControl.Procurement.MockServer.reset()
  end
end)
