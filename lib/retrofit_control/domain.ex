defmodule RetrofitControl.Domain do
  @moduledoc """
  改造交付控制塔的领域状态与事件投影。

  采用事件溯源：所有命令的结果都是“事件列表”，状态由事件折叠（fold/`apply_event`）得到。
  因此服务重启后只需重放事件日志即可恢复全部一致性状态（里程碑、预算台账、审计、采购回执）。
  """

  defmodule Phase do
    @enforce_keys [:id, :line_id, :seq, :name, :device_class, :required_caps, :planned_end, :amount_cents]
    defstruct [
      :id,
      :line_id,
      :seq,
      :name,
      :device_class,
      :required_caps,
      :planned_end,
      :amount_cents,
      :vendor_id,
      :quote_id,
      :depends_on,
      :contract_version_id,
      :submission_id,
      :approved_at,
      :completed_at,
      :locked_ledger_id,
      :spent_ledger_id,
      :penalty_ledger_id,
      :reserve_cents,
      :penalty_cents,
      :rollback_node,
      :evidence,
      status: :planned
    ]
  end

  defmodule Contract do
    @enforce_keys [:id, :version, :effective_from]
    defstruct [
      :id,
      :line_id,
      :vendor_id,
      :version,
      :effective_from,
      :superseded_by,
      :note,
      status: :active
    ]
  end

  defmodule Quote do
    @enforce_keys [:id, :vendor_id, :version, :amount_cents]
    defstruct [:id, :vendor_id, :version, :amount_cents, :valid_until, :contract_id, :line_id]
  end

  defmodule Device do
    @enforce_keys [:id, :line_id, :kind, :class]
    defstruct [:id, :line_id, :kind, :class, :caps, :contract_version_id, :gateway_id, :vendor_id]
  end

  defmodule LedgerEntry do
    @enforce_keys [:id, :phase_id, :kind, :amount_cents]
    defstruct [
      :id,
      :phase_id,
      :line_id,
      :kind,
      :amount_cents,
      :month,
      :currency,
      :reverses,
      :reason,
      :created_at
    ]
  end

  defmodule ProcurementOrder do
    @enforce_keys [:id, :phase_id, :amount_cents]
    defstruct [
      :id,
      :phase_id,
      :line_id,
      :amount_cents,
      :receipt_key,
      :last_attempt,
      :attempts,
      :acknowledged_at,
      :error,
      status: :pending
    ]
  end

  defmodule Submission do
    @enforce_keys [:id, :phase_id, :vendor_id]
    defstruct [
      :id,
      :phase_id,
      :line_id,
      :vendor_id,
      :contract_version_id,
      :device_id,
      :device_caps,
      :evidence,
      :submitted_at,
      :occurred_at,
      :decision_reason,
      :decided_at,
      offline: false,
      status: :received
    ]
  end

  defmodule AuditEvent do
    @enforce_keys [:seq, :at, :action, :result]
    defstruct [
      :seq,
      :at,
      :action,
      :result,
      :actor,
      :line_id,
      :phase_id,
      :submission_id,
      :contract_version_id,
      :amount_cents,
      :safety_node,
      :reason,
      :idem_key,
      :detail
    ]
  end

  defmodule State do
    defstruct [
      lines: %{},
      devices: %{},
      contracts: %{},
      quotes: %{},
      phases: %{},
      ledger: %{},
      submissions: %{},
      procurement: %{},
      audits: [],
      idem: %{},
      offline_store: %{},
      budget: %{total: 0, committed: 0, spent: 0, reserve: 0, reserve_drawn: 0},
      seq: 0,
      audit_seq: 0,
      # 每条产线当前的“安全节点”（最近一次成功验收的阶段序号），回滚即退到该节点。
      safety_nodes: %{},
      restart_count: 0,
      last_event_at: nil
    ]
  end

  def fresh, do: %State{}

  def next_seq(%State{seq: s}), do: s + 1

  def next_id(%State{} = state, prefix) do
    n = next_seq(state)
    "#{prefix}_#{String.pad_leading(Integer.to_string(n), 4, "0")}"
  end

  def next_audit_seq(%State{audit_seq: n}), do: n + 1

  @doc "折叠事件列表得到状态。"
  def apply_events(%State{} = state, events) when is_list(events) do
    Enum.reduce(events, state, &apply_event/2)
  end

  # --- 事件投影 ---

  def apply_event({:line_registered, attrs}, s) do
    line = Map.merge(%{status: :active}, Map.delete(attrs, :event))
    %State{s | lines: Map.put(s.lines, attrs.id, line), seq: s.seq + 1, last_event_at: attrs.at}
  end

  def apply_event({:device_cataloged, attrs}, s) do
    d = struct(Device, Map.put(attrs, :caps, MapSet.new(attrs.caps || [])))
    %State{s | devices: Map.put(s.devices, d.id, d), seq: s.seq + 1, last_event_at: attrs.at}
  end

  def apply_event({:contract_recorded, attrs}, s) do
    c = struct(Contract, attrs)
    %State{s | contracts: Map.put(s.contracts, c.id, c), seq: s.seq + 1, last_event_at: attrs.at}
  end

  def apply_event({:contract_superseded, attrs}, s) do
    contracts =
      case s.contracts[attrs.contract_id] do
        nil ->
          s.contracts

        c ->
          Map.put(s.contracts, c.id, %Contract{c | status: :superseded, superseded_by: attrs.by_version})
      end

    %State{s | contracts: contracts, seq: s.seq + 1, last_event_at: attrs.at}
  end

  def apply_event({:quote_recorded, attrs}, s) do
    q = struct(Quote, attrs)
    %State{s | quotes: Map.put(s.quotes, q.id, q), seq: s.seq + 1, last_event_at: attrs.at}
  end

  def apply_event({:budget_configured, attrs}, s) do
    budget =
      s.budget
      |> Map.merge(Map.take(attrs, [:total, :reserve]))

    %State{s | budget: budget, seq: s.seq + 1, last_event_at: attrs.at}
  end

  def apply_event({:phase_planned, attrs}, s) do
    p = struct(Phase, attrs)
    %State{s | phases: Map.put(s.phases, p.id, p), seq: s.seq + 1, last_event_at: attrs.at}
  end

  def apply_event({:submission_received, attrs}, s) do
    sub = struct(Submission, attrs)
    s = %State{s | submissions: Map.put(s.submissions, sub.id, sub)}
    %State{s | seq: s.seq + 1, last_event_at: attrs.at}
  end

  def apply_event({:advance_denied, attrs}, s) do
    s =
      case s.submissions[attrs.submission_id] do
        nil ->
          s

        sub ->
          %State{
            s
            | submissions:
                Map.put(s.submissions, sub.id, %Submission{
                  sub
                  | status: :denied,
                    decision_reason: attrs.reason,
                    decided_at: attrs.at
                })
          }
      end

    s =
      case attrs.phase_id && s.phases[attrs.phase_id] do
        nil -> s
        p -> %State{s | phases: Map.put(s.phases, p.id, %Phase{p | status: :blocked})}
      end

    mark_seq(s, attrs.at)
  end

  def apply_event({:phase_approved, attrs}, s) do
    p = s.phases[attrs.phase_id]

    p = %Phase{
      p
      | status: :approved,
        contract_version_id: attrs.contract_version_id,
        submission_id: attrs.submission_id,
        approved_at: attrs.at,
        locked_ledger_id: attrs.locked_ledger_id,
        reserve_cents: attrs.reserve_cents || 0,
        rollback_node: attrs.rollback_node
    }

    # 预算占用由台账的 :hold 行派生，这里只更新阶段状态与安全节点，避免重复计数。
    node = Map.get(s.safety_nodes, p.line_id, 0)

    safety =
      if attrs.rollback_node > node do
        Map.put(s.safety_nodes, p.line_id, attrs.rollback_node)
      else
        s.safety_nodes
      end

    %State{
      s
      | phases: Map.put(s.phases, p.id, p),
        safety_nodes: safety,
        seq: s.seq + 1,
        last_event_at: attrs.at
    }
  end

  def apply_event({:phase_rejected, attrs}, s) do
    s =
      case s.submissions[attrs.submission_id] do
        nil ->
          s

        sub ->
          %State{
            s
            | submissions:
                Map.put(s.submissions, sub.id, %Submission{
                  sub
                  | status: :rejected,
                    decision_reason: attrs.reason,
                    decided_at: attrs.at
                })
          }
      end

    case s.phases[attrs.phase_id] do
      nil ->
        s

      p ->
        %State{
          s
          | phases: Map.put(s.phases, p.id, %Phase{p | status: :rejected}),
            seq: s.seq + 1,
            last_event_at: attrs.at
        }
    end
  end

  def apply_event({:phase_accepted, attrs}, s) do
    p = s.phases[attrs.phase_id]

    p = %Phase{
      p
      | status: :accepted,
        completed_at: attrs.completed_at,
        spent_ledger_id: attrs.spent_ledger_id,
        penalty_ledger_id: attrs.penalty_ledger_id,
        penalty_cents: attrs.penalty_cents || 0
    }

    # 预算从台账派生（:hold 释放 + :spend/:penalty 入账 + 跨月拆分都在台账中）。
    node = Map.get(s.safety_nodes, p.line_id, 0)

    safety =
      if p.seq >= node do
        Map.put(s.safety_nodes, p.line_id, p.seq)
      else
        s.safety_nodes
      end

    %State{
      s
      | phases: Map.put(s.phases, p.id, p),
        safety_nodes: safety,
        seq: s.seq + 1,
        last_event_at: attrs.at
    }
  end

  def apply_event({:phase_rolled_back, attrs}, s) do
    # 回滚到安全节点：目标阶段及其后继全部退回，已占用/已花台账生成冲红记录。
    phases =
      Enum.reduce(s.phases, s.phases, fn {id, p}, acc ->
        if p.line_id == attrs.line_id and p.seq >= attrs.to_seq and p.seq <= attrs.from_seq and
             p.status in [:approved, :accepted] do
          Map.put(acc, id, %Phase{
            p
            | status: :rolled_back,
              rollback_node: attrs.to_seq - 1,
              completed_at: nil
          })
        else
          acc
        end
      end)

    safety = Map.put(s.safety_nodes, attrs.line_id, attrs.safety_seq)
    %State{s | phases: phases, safety_nodes: safety, seq: s.seq + 1, last_event_at: attrs.at}
  end

  def apply_event({:ledger_posted, attrs}, s) do
    e = struct(LedgerEntry, attrs)
    # 预算占用/花费统一从台账求和派生（见 totals/1），事件本身不再直接改预算，杜绝双计数。
    %State{s | ledger: Map.put(s.ledger, e.id, e), seq: s.seq + 1, last_event_at: attrs[:at] || attrs[:created_at]}
  end

  def apply_event({:ledger_reversed, attrs}, s) do
    # 冲红/释放以“带符号同类型行”入账（attrs.amount_cents 已带正确正负号）；
    # totals/1 按有符号求和即可得到回滚或验收后的预算，冲红链幂等由调用方按净额计算。
    e = struct(LedgerEntry, attrs)
    %State{s | ledger: Map.put(s.ledger, e.id, e), seq: s.seq + 1, last_event_at: attrs[:at] || attrs[:created_at]}
  end

  def apply_event({:procurement_created, attrs}, s) do
    o = struct(ProcurementOrder, attrs)
    %State{s | procurement: Map.put(s.procurement, o.id, o), seq: s.seq + 1, last_event_at: attrs.at}
  end

  def apply_event({:procurement_dispatch_attempted, attrs}, s) do
    case s.procurement[attrs.order_id] do
      nil ->
        s

      o ->
        o = %ProcurementOrder{
          o
          | last_attempt: attrs.at,
            attempts: (o.attempts || 0) + 1,
            status: if(attrs.ok, do: :in_flight, else: :retry_wait),
            error: if(attrs.ok, do: nil, else: attrs.error)
        }

        %State{s | procurement: Map.put(s.procurement, o.id, o), seq: s.seq + 1, last_event_at: attrs.at}
    end
  end

  def apply_event({:procurement_acknowledged, attrs}, s) do
    case s.procurement[attrs.order_id] do
      nil ->
        s

      o ->
        o = %ProcurementOrder{
          o
          | status: :acknowledged,
            receipt_key: attrs.receipt_key,
            acknowledged_at: attrs.at,
            error: nil
        }

        %State{s | procurement: Map.put(s.procurement, o.id, o), seq: s.seq + 1, last_event_at: attrs.at}
    end
  end

  def apply_event({:offline_result_stored, attrs}, s) do
    # 离线验收结果先持久化暂存，不推进阶段；待连接恢复后用 backfill_acceptance 补传。
    # 随事件日志重放恢复，因此“服务重启”不会丢失待补传的离线结果。
    %State{
      s
      | offline_store:
          Map.put(s.offline_store, attrs.stored_key, %{
            phase_id: attrs.phase_id,
            payload: attrs.payload,
            at: attrs.at
          }),
        seq: s.seq + 1,
        last_event_at: attrs.at
    }
  end

  def apply_event({:offline_result_consumed, attrs}, s) do
    %State{
      s
      | offline_store: Map.delete(s.offline_store, attrs.stored_key),
        seq: s.seq + 1,
        last_event_at: attrs.at
    }
  end

  def apply_event({:audit_appended, attrs}, s) do
    a = struct(AuditEvent, attrs)
    %State{s | audits: [a | s.audits], audit_seq: a.seq, seq: s.seq + 1, last_event_at: attrs.at}
  end

  def apply_event({:idem_recorded, attrs}, s) do
    %State{
      s
      | idem: Map.put(s.idem, attrs.key, %{result: attrs.result, at: attrs.at}),
        seq: s.seq + 1,
        last_event_at: attrs.at
    }
  end

  def apply_event({:snapshot_taken, attrs}, s) do
    %State{s | seq: s.seq + 1, last_event_at: attrs.at}
  end

  def apply_event({:restart_recovered, attrs}, s) do
    %State{s | restart_count: s.restart_count + 1, seq: s.seq + 1, last_event_at: attrs.at}
  end

  defp mark_seq(s, at), do: %State{s | seq: s.seq + 1, last_event_at: at}

  # --- 查询辅助 ---

  @doc "产线阶段按序号排序。"
  def line_phases(%State{} = s, line_id) do
    s.phases
    |> Map.values()
    |> Enum.filter(&(&1.line_id == line_id))
    |> Enum.sort_by(& &1.seq)
  end

  def active_contract(%State{} = s, line_id, vendor_id) do
    Enum.find(Map.values(s.contracts), fn c ->
      c.line_id == line_id and c.vendor_id == vendor_id and c.status == :active
    end)
  end

  @doc "从台账派生预算汇总：committed=在锁未释放，spent=花费+罚则，reserve_drawn=动用储备。"
  def totals(%State{} = s) do
    entries = Map.values(s.ledger)

    committed =
      entries
      |> Enum.filter(&(&1.kind in [:hold, :release]))
      |> Enum.reduce(0, &(&1.amount_cents + &2))

    spent =
      entries
      |> Enum.filter(&(&1.kind in [:spend, :penalty]))
      |> Enum.reduce(0, &(&1.amount_cents + &2))

    reserve_drawn =
      entries
      |> Enum.filter(&(&1.kind == :reserve_draw))
      |> Enum.reduce(0, &(&1.amount_cents + &2))

    %{
      total: s.budget.total,
      reserve: s.budget.reserve,
      committed: committed,
      spent: spent,
      reserve_drawn: reserve_drawn
    }
  end

  @doc "预算可用于锁定的余额（总预算 + 风险储备 - 在锁 - 已花费）。"
  def budget_available(%State{} = s) do
    t = totals(s)
    t.total + t.reserve - t.committed - t.spent
  end

  def line_spent(%State{} = s, line_id) do
    s.ledger
    |> Map.values()
    |> Enum.filter(&(&1.line_id == line_id))
    |> Enum.reduce(0, fn e, sum -> sum + e.amount_cents end)
  end
end
