# 中小工厂改造交付控制塔（Retrofit Control Tower）

按产线**逐段上线** 5G 网关 / 采集器 / 边缘应用的后端服务。
工厂不敢一次性停线，因此每个阶段（里程碑）都必须在满足前置条件时才推进，
预算超限或设备能力不兼容时可回退到上一个“安全节点”。

## 它解决什么问题

- **设备能力清单**：登记网关/采集器具备的能力（5G、MQTT、OPC-UA…），阶段声明所需能力，提交时校验兼容性。
- **阶段里程碑 + 验收依赖**：每条产线按序号拆段，后段依赖前段已验收，依赖不满足不能推进。
- **供应商报价版本 + 合同换版**：报价与合同分版本管理；服务商只能在**仍有效**的合同版本上提交，
  即便提交时合格，批准前合同被换版也会被拒绝（批准瞬间重新裁决）。
- **预算与风险储备**：批准即锁定预算（hold），验收时转为花费并释放锁定；主预算不足自动动用风险储备，
  主预算+储备仍不足则拒绝；回滚生成带符号冲红，预算重新可用。
- **并发裁决**：所有写命令在单一 GenServer 内串行执行，多个服务商并发提交时，
  只有“依赖完成 + 能力兼容 + 合同有效 + 预算可锁”的阶段被推进。
- **审计事件**：每次批准 / 驳回 / 回滚 / 预算占用 / 采购回执都落审计事件，序号连续递增、持久化。
- **跨月费用 + 延期罚则**：验收费用按自然月拆分（总额恒定，分不丢失）；超过计划完成日按天计提罚则并有封顶。
- **离线验收补传**：现场离线时结果先落盘暂存（不推进阶段），恢复后补传；补传仍校验合同版本，
  离线期间换版则拒绝并保留暂存。
- **外部采购幂等补偿**：以订单键幂等派发；外部失败进入补偿重试；回执重复送达幂等不重复入账，
  冲突回执被拒绝。
- **断点恢复**：事件全部追加写入事件日志（fsync），周期性快照；服务重启后“快照 + 事件重放”完整恢复，
  跨月费用、罚则、锁定、安全节点、离线暂存全部一致。

厂长无需看代码，通过报表接口即可确认：**哪条产线可以继续、哪笔预算被锁定、退回了哪个安全节点**。

## 运行

```bash
mix deps.get        # 本项目零外部依赖，实际无需下载
mix test            # 自动化测试（不建立任何外部连接）
PORT=8080 TOWER_DATA_DIR=./data mix run --no-halt
```

- 金额单位统一为整数“分”，不使用浮点。
- 持久化默认写入 `TOWER_DATA_DIR`（默认系统临时目录）下的 `events.log` 与 `snapshot.bin`。
- 生产密钥与连接地址通过环境变量注入，不得写入仓库。

## 主要 HTTP 接口

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/healthz` | 健康检查 |
| GET | `/report` | 厂长报表：产线能否继续 / 预算锁定 / 安全节点 |
| GET | `/audits` | 审计事件流 |
| POST | `/lines` `/devices` `/contracts` `/quotes` `/budget` `/phases` | 基础档案 |
| POST | `/contracts/:id/supersede` | 合同换版（旧版失效） |
| POST | `/acceptances` | 服务商提交验收结果（裁决依赖/合同/能力） |
| POST | `/submissions/:id/approve` | 批准（再次裁决 + 锁定预算） |
| POST | `/submissions/:id/reject` | 驳回 |
| POST | `/phases/:id/accept` | 确认验收（跨月费用 + 罚则 + 触发采购） |
| POST | `/lines/:id/rollback` | 回滚到安全节点（冲红台账） |
| POST | `/offline` `/offline/:key/backfill` | 离线暂存 / 补传 |
| POST | `/procurement/receipts` `/procurement/retry` | 采购回执（幂等）/ 补偿重试 |
| POST | `/admin/recover` | 触发断点恢复（启动时也会自动执行） |

写接口支持 `Idempotency-Key` 头：重复请求返回首次结果，不重复锁预算 / 不重复发单。

### 典型流转

```bash
# 1. 档案 + 预算 + 合同 + 阶段
curl -s -XPOST localhost:8080/lines    -d '{"id":"L1","name":"总装一线"}' -H 'Content-Type: application/json'
curl -s -XPOST localhost:8080/budget   -d '{"total":100000,"reserve":20000}' -H 'Content-Type: application/json'
# ... devices / contracts / phases ...

# 2. 服务商并发提交 -> 裁决
curl -s -XPOST localhost:8080/acceptances \
  -d '{"phase_id":"S1","vendor_id":"VA","contract_version_id":"K1","device_caps":["5g_nsa","mqtt"]}' \
  -H 'Content-Type: application/json' -H 'Idempotency-Key: sub-s1-1'

# 3. 批准（锁预算）-> 确认验收（跨月费用/罚则/采购）-> 必要时回滚
curl -s -XPOST localhost:8080/submissions/sub_xxxx/approve -d '{"actor":"厂长"}' -H 'Content-Type: application/json'
curl -s -XPOST localhost:8080/phases/S1/accept      -d '{"completed_at":"2026-11-20"}' -H 'Content-Type: application/json'
curl -s -XPOST localhost:8080/lines/L1/rollback     -d '{"actor":"厂长","reason":"能力复测不兼容"}' -H 'Content-Type: application/json'

# 4. 厂长视角
curl -s localhost:8080/report
```

## 架构与一致性

```
HTTP(:gen_tcp, 零依赖) ──► Tower(单 GenServer, 串行命令/裁决)
                              │  命令 -> 事件列表（含审计占位）
                              ├─► EventLog(追加写 + fsync + 快照)
                              ├─► Domain.apply_event(纯函数投影/预算由台账派生)
                              └─► Procurement.Adapter(外部边界, 幂等补偿)
```

- **事件溯源**：状态是事件的折叠结果；预算不从命令里直接加减，而由台账有符号求和派生，
  杜绝 hold/spend 双计数；回滚用“把净额清零”的反向行实现，天然可重复且总额守恒。
- **原子批**：一次批准产生的“锁定台账 + 阶段状态 + 审计”整批一次落盘，重启后要么都在要么都不在。
- **测试不建立外部连接**：HTTP、持久化、采购系统均为标准库 / 内存模拟实现；
  PostgreSQL、NATS 等生产适配器通过 `RetrofitControl.Platform` 的配置边界接入。

## 自动化测试覆盖

`mix test`（33 个用例）覆盖：

- 合同换版（提交后、批准前换版被拒；登记新版后可继续）
- 并发验收（多服务商同时提交，仅满足前置且在有效合同上的阶段推进）
- 预算竞争（并发抢同一笔预算仅一方获胜；动用风险储备；总额不足拒绝且零锁定）
- 阶段回滚（批准后回退释放 hold/储备；验收后回退红冲跨月花费与罚则；多段回退只退目标段）
- 跨月费用守恒、延期罚则计提与封顶
- 采购回执幂等、首次失败补偿重试、冲突回执拒绝
- 离线结果暂存 / 换版拒绝 / 重启后补传
- 断点恢复（事件重放、快照增量重放、真实进程重启后状态一致）
- 幂等键重复批准只锁一次预算、审计序号连续唯一
- HTTP 端到端：厂长报表展示可继续产线、锁定预算与回退节点
