# 中小工厂改造交付控制塔

该后端起始工程使用 Elixir 与 Phoenix 生态，依赖 PostgreSQL/Ecto 和 NATS 客户端。当前仅提供健康路由与连接边界，里程碑、预算、合同版本和采购补偿流程尚未实现。

```bash
mix deps.get
mix test
mix run --no-halt
```

测试不建立外部连接，生产密钥及连接地址不得写入仓库。
