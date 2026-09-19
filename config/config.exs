import Config

# 事件日志目录（唯一持久化事实源；审计、状态、断点恢复均来自它）
config :retrofit_control,
  data_dir: System.get_env("DATA_DIR", "data/default"),
  http_port: String.to_integer(System.get_env("PORT", "8080")),
  # 默认对接内置的模拟采购系统；生产可配置 HttpcClient + procurement_url
  procurement_client: RetrofitControl.Procurement.MockClient,
  procurement_url: System.get_env("PROCUREMENT_URL", "http://127.0.0.1:9099/po"),
  auto_dispatch: true

config :logger, level: :info
