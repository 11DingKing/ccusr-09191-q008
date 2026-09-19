# 工厂 5G 改造 · 阶段化交付控制塔（retrofit_control）

中型工厂不敢一次性停线改造。该后端让服务商**按产线逐段上线** 5G 网关、采集器、
边缘应用，并在预算超限、能力不兼容、合同失效时**及时回退到上一个安全节点**。

它回答厂长最关心的三个问题（无需看代码）：

1. **哪条产线可以继续？** 卡在哪一步、为什么；
2. **哪笔预算被锁定？** 主预算与风险储备分别锁了多少、属于哪个阶段/合同版本；
3. **退回到了哪个安全节点？** 已验收里程碑、跨月费用、采购单如何被红冲。

## 为什么不用数据库

> 交付环境无 PostgreSQL/NATS 服务端，且要求“重启必须一致、审计必须可信”。

系统以**仅追加事件日志（append-only journal）**作为唯一事实源：

- 每条事件写盘后立即 `fsync`，进程被 `kill -9`/断电不丢已确认操作；
- 批准、驳回、回滚、**每一次预算占用/释放/红冲**都是一条事件，**审计视图直接读日志文件**，
  因此审计不可能与业务状态不一致；
- 服务启动时重放日志重建内存读模型——天然的**断点恢复**；
- 最后一行若因崩溃写了半截（非法 JSON），启动时自动截除并转存 `events.log.corrupt` 备查。

并发控制：所有写命令在同一个 Journal 进程内**串行完成“读最新状态 → 规则裁决 → fsync 落盘”**。
多个服务商并发提交、多个审批并发抢预算，都只有满足前置条件且仍挂在有效合同版本上的阶段能推进。

技术栈：Elixir 1.14 / OTP 25 + Plug/Cowboy（HTTP）+ Jason（JSON）。**零外部中间件**，
交付包内置“外部采购系统”的内存模拟，断网即可运行全部流程与测试。

## 快速开始

```bash
mix deps.get
mix test            # 31 个自动化测试，覆盖下述全部关键场景
mix retro.demo      # 端到端演示：能力拦截→验收→跨月罚则→采购确认→回退
mix retro.board     # 厂长控制台看板（产线/预算/安全节点）
mix run --no-halt   # 启动 HTTP 服务（默认 8080，PORT 可改）
```

演示输出会逐行展示：开工锁预算、能力不兼容被拦、P1 成安全节点、P2 离线补传跨月验收
（逾期 21 天、罚则、跨月账期）、采购幂等确认、最终回退到初始状态并红冲全部费用。

## 核心业务规则

| 主题 | 规则 |
|------|------|
| 阶段里程碑 | 阶段按顺序串联（默认前置=上一阶段，也可显式 `depends_on`）；前置未验收不能开工/提交 |
| 设备能力清单 | 每台设备声明 `provides` 能力与固件版本；阶段声明 `needs` 与最低固件；能力为设备并集，缺一即拒 |
| 合同版本 | 报价（quote）有版本；激活合同必须版本号递增；换版后旧合同上的待决验收单**立即作废**、旧预算锁释放，必须用新合同服务商重新提交 |
| 预算 | 主预算 + 风险储备（按报价 bp 比率）按产线独立；开工即锁定（占用），驳回/换版/回滚释放，批准时结算消耗 |
| 风险储备 | 独立于主预算，不足同样拒绝开工 |
| 验收闸门 | 批准时复核：① 仍在有效合同版本 ② 前置仍已验收（并发回滚兜底）③ 设备能力仍兼容 ④ 预算锁版本匹配；任一不满足**系统自动驳回**并释放锁 |
| 跨月费用 | 按期/提前全额计入计划完成月；延期则从计划完成日到实测完成日按自然月、按天均摊，最后账期吸收取整余差，**合计恒等于合同费用**；回滚时逐月红冲 |
| 延期罚则 | 按 `captured_at`（实测/补传日）与计划完成日的天数差计罚（日费率 bp，有封顶）；离线晚补传不改变延期口径 |
| 离线验收补传 | `offline=true` + `captured_at`（不能晚于今天）+ `Idempotency-Key`，重复上传只产生一张验收单 |
| 回滚 | 只能回退到已验收安全节点；目标及其后所有已验收节点撤销、跨月结算红冲、后续待决单作废、占用锁释放；结果明确告知“退回到哪个节点” |
| 采购补偿 | 批准生成 `po_created`（outbox）→ 异步投递外部采购系统，按采购单号幂等去重，超时按指数退避重试；CONFIRMED 落确认，REJECTED 走 `po_compensated` 补偿；回执也幂等，重启后继续补偿 |

所有写接口都接受 `Idempotency-Key` 请求头，断线重试/重复点击/服务重启都不会二次推进或二次扣款。

## HTTP 接口（节选）

```
POST /api/v1/lines                                  注册产线（含主预算/风险池）
POST /api/v1/lines/:line_id/devices                 登记设备能力
POST /api/v1/lines/:line_id/phases                  规划里程碑阶段
POST /api/v1/lines/:line_id/quotes                  记录供应商报价版本
POST /api/v1/lines/:line_id/contracts/activate      激活/换版合同
POST /api/v1/lines/:line_id/phases/:code/start      开工（锁定预算）
POST /api/v1/lines/:line_id/phases/:code/acceptance 服务商提交/离线补传验收
POST /api/v1/acceptance/:id/approve                 厂长批准
POST /api/v1/acceptance/:id/reject                  厂长驳回
POST /api/v1/lines/:line_id/rollback                回退到安全节点
POST /api/v1/procurement/receipts                   外部采购回执（幂等）
POST /api/v1/procurement/flush                      立即尝试投递待处理采购单

GET  /api/v1/board/lines[ /:line_id]                厂长看板
GET  /api/v1/board/budget                           预算占用/消耗/跨月账期
GET  /api/v1/audit?line_id=&limit=N                 审计事件（直接来自落盘日志）
GET  /healthz
```

金额单位统一为整数“分”。错误返回 `409` + 稳定错误码（如 `BUDGET_EXCEEDED`、
`CONTRACT_STALE`、`CAPABILITY_MISMATCH`、`PREDECESSOR_ROLLED_BACK`、`NOT_SAFE_NODE`）。

## 自动化测试覆盖

```bash
mix test
```

- `contract_version_test.exs`：版本号必须递增、换版作废旧待决单并释放锁、新服务商重新提交、命令幂等重放；
- `concurrent_acceptance_test.exs`：同阶段 10 路并发提交只留一个有效待决单、批准与回滚并发竞争的最终不变量（没有阶段能越过未验收前置）；
- `budget_competition_test.exs`：8 路并发开工只有一个赢家、主预算/风险池硬约束、驳回后预算回池再占用、批准结算消耗；
- `rollback_test.exs`：回退到 P1/中间节点 P2 的红冲与安全节点重设、跨月账期净额归零、回退后可重新推进且罚则正确；
- `recovery_test.exs`：**重启后状态完全一致**、跨月拆分合计恒等、离线补传幂等、采购成功/拒单补偿/网络故障重试、半截日志截除恢复；
- `capability_rule_test.exs`：能力缺失、设备归属、固件门槛、延期罚则封顶、多设备能力并集；
- `http_test.exs`：真实 Cowboy 端到端 JSON 链路与幂等头。

## 对接真实外部采购系统

默认 `Procurement.MockClient`（内存模拟，支持注入 reject/fail/pending）。
生产将配置切换为 `RetrofitControl.Procurement.HttpcClient` 并设置 `PROCUREMENT_URL`，
该适配器通过 Erlang `:httpc` 携带 `Idempotency-Key` 调用外部系统，
超时安全重试、`409` 识别为对方幂等去重。

## 数据与配置

- 事件日志目录：`DATA_DIR`（默认 `data/default/events.log`）；可备份/审计，勿手工编辑；
- HTTP 端口：`PORT`（默认 8080）；
- 生产密钥/连接地址不入库（`.gitignore` 已忽略 `data/`、密钥等）。
