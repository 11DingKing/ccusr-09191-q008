import Config

# 测试不自动启动应用监督树：各用例通过 TestFactory 启动隔离实例；
# HTTP 测试自行启动默认单例。
config :retrofit_control,
  data_dir: Path.join(System.tmp_dir!(), "retrofit_test_default"),
  procurement_client: RetrofitControl.Procurement.MockClient,
  auto_dispatch: false,
  http_port: 8123,
  autostart: false

config :logger, level: :warning
