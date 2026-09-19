defmodule RetrofitControl.State do
  @moduledoc """
  内存读模型：完全由 Journal 事件重放得到，本身绝不落盘。

  重启时状态为空 → 重放 fsync 事件日志重建，因此“业务状态”和“审计事件”
  永远不会出现不一致。
  """

  alias RetrofitControl.DomainError, as: E

  defstruct lines: %{},
            phases: %{},
            devices: %{},
            quotes: %{},
            locks: %{},
            entries: [],
            outbox: %{},
            inbox: %{},
            idempotency: %{},
            meta: %{},
            seq: 0

  # ───────────────────────────── 读模型辅助 ─────────────────────────────

  def line!(state, line_id) do
    Map.get(state.lines, line_id) || raise E.not_found("产线")
  end

  def phase(state, line_id, code) do
    get_in(state.phases, [Access.key(line_id, %{}), code])
  end

  def phase!(state, line_id, code) do
    phase(state, line_id, code) || raise E.not_found("阶段 #{code}")
  end

  def phases_of(state, line_id) do
    state.phases[line_id]
    |> case do
      nil -> []
      map -> Map.values(map)
    end
    |> Enum.sort_by(& &1.order)
  end

  def active_contract(state, line_id) do
    state.lines[line_id][:active_contract]
  end

  def active_quote(state, line_id) do
    contract = active_contract(state, line_id)
    contract && state.quotes[contract.quote_id]
  end

  def lock_for(state, line_id, code) do
    state.locks[{line_id, code}]
  end

  @doc """
  单条产线预算汇总（单位：分）。预算池按产线独立：
  * locked：该产线当前占用（锁定）的费用/储备；
  * consumed：已结算且未被红冲的费用；
  * available：总额 - 占用 - 消耗。
  """
  def budget_summary(state, line_id) do
    lock_amounts =
      state.locks
      |> Map.values()
      |> Enum.filter(&(&1.line_id == line_id and &1.status == "LOCKED"))
      |> Enum.reduce(%{main: 0, risk: 0}, fn lock, acc ->
        %{acc | main: acc.main + lock.fee_cents, risk: acc.risk + lock.reserve_cents}
      end)

    consumed =
      state.entries
      |> Enum.filter(&(&1.type == "SETTLE" and &1.active and &1.line_id == line_id))
      |> Enum.reduce(0, &(&1.amount_cents + &2))

    line = state.lines[line_id]
    main_total = (line && line.main_budget_cents) || 0
    risk_total = (line && line.risk_budget_cents) || 0

    %{
      line_id: line_id,
      main_total_cents: main_total,
      risk_total_cents: risk_total,
      main_locked_cents: lock_amounts.main,
      risk_locked_cents: lock_amounts.risk,
      main_consumed_cents: consumed,
      main_available_cents: main_total - lock_amounts.main - consumed,
      risk_available_cents: risk_total - lock_amounts.risk
    }
  end

  @doc "全厂预算汇总（各产线独立池加总，仅供看板总览；裁决按产线池判断）。"
  def global_budget_summary(state) do
    state.lines
    |> Map.keys()
    |> Enum.map(&budget_summary(state, &1))
    |> Enum.reduce(
      %{
        main_total_cents: 0,
        risk_total_cents: 0,
        main_locked_cents: 0,
        risk_locked_cents: 0,
        main_consumed_cents: 0,
        main_available_cents: 0,
        risk_available_cents: 0
      },
      fn s, acc ->
        Map.merge(acc, s, fn
          :line_id, _, _ -> nil
          _k, a, b -> a + b
        end)
      end
    )
  end

  def submission(state, submission_id) do
    Enum.find_value(state.phases, nil, fn {_line, phases} ->
      Enum.find_value(phases, nil, fn {_code, p} ->
        Enum.find(p.submissions, nil, &(&1.id == submission_id))
      end)
    end)
  end

  def submission!(state, submission_id) do
    submission(state, submission_id) || raise E.not_found("验收单")
  end

  # ───────────────────────────── 事件应用（纯函数） ─────────────────────────────

  def apply(state, event, envelope \\ %{})

  # 工厂主数据与预算池（日志里第一次出现时建立工厂）
  def apply(state, %{"type" => "line_registered"} = e, _env) do
    line = %{
      id: e["line_id"],
      name: e["name"],
      main_budget_cents: e["main_budget_cents"],
      risk_budget_cents: e["risk_budget_cents"],
      active_contract: nil,
      created_at: e["at"]
    }

    %{state | lines: Map.put(state.lines, line.id, line)}
  end

  def apply(state, %{"type" => "device_registered"} = e, _env) do
    device = %{
      id: e["device_id"],
      line_id: e["line_id"],
      kind: e["kind"],
      model: e["model"],
      provides: MapSet.new(e["provides"] || []),
      firmware: e["firmware"],
      registered_at: e["at"]
    }

    %{state | devices: Map.put(state.devices, device.id, device)}
  end

  def apply(state, %{"type" => "phase_planned"} = e, _env) do
    phase = %{
      line_id: e["line_id"],
      code: e["code"],
      name: e["name"],
      order: e["order"],
      needs: MapSet.new(e["needs"] || []),
      min_firmware: e["min_firmware"] || "0",
      planned_done_date: e["planned_done_date"],
      depends_on: e["depends_on"],
      status: "PLANNED",
      submissions: [],
      current_submission_id: nil,
      accepted: nil,
      safe_node: false,
      rolled_back_from: nil,
      started_at: nil,
      rolled_back_at: nil,
      rollback_reason: nil
    }

    %{
      state
      | phases:
          put_in(state.phases, [Access.key(e["line_id"], %{}), e["code"]], phase)
    }
  end

  def apply(state, %{"type" => "quote_recorded"} = e, _env) do
    quote_item = %{
      id: e["quote_id"],
      line_id: e["line_id"],
      vendor_id: e["vendor_id"],
      version: e["version"],
      fee_cents: e["fee_cents"],
      reserve_rate_bp: e["reserve_rate_bp"] || 0,
      penalty_rate_bp_per_day: e["penalty_rate_bp_per_day"] || 0,
      penalty_cap_bp: e["penalty_cap_bp"] || 10_000,
      payment_days: e["payment_days"] || 0,
      note: e["note"],
      recorded_at: e["at"]
    }

    %{state | quotes: Map.put(state.quotes, quote_item.id, quote_item)}
  end

  def apply(state, %{"type" => "contract_superseded"} = e, _env) do
    contract = %{
      id: e["contract_id"],
      line_id: e["line_id"],
      quote_id: e["quote_id"],
      version: e["version"],
      valid_from: e["valid_from"],
      superseded: false
    }

    lines =
      update_in(state.lines, [Access.key!(e["line_id"])], fn line ->
        line =
          if line.active_contract do
            %{line | active_contract: %{line.active_contract | superseded: true}}
          else
            line
          end

        %{line | active_contract: contract}
      end)

    # 待决单作废、阶段回实施中、预算锁释放均由 submission_superseded /
    # budget_lock_released 显式事件承载，保证审计与状态严格一致。
    %{state | lines: lines}
  end

  def apply(state, %{"type" => "phase_started"} = e, _env) do
    update_phase(state, e["line_id"], e["code"], fn p ->
      %{p | status: "IN_PROGRESS", started_at: e["at"]}
    end)
  end

  def apply(state, %{"type" => "budget_locked"} = e, _env) do
    lock = %{
      key: {e["line_id"], e["code"]},
      line_id: e["line_id"],
      code: e["code"],
      submission_id: nil,
      quote_id: e["quote_id"],
      contract_version: e["contract_version"],
      fee_cents: e["fee_cents"],
      reserve_cents: e["reserve_cents"],
      status: "LOCKED",
      seq: e["lock_seq"],
      at: e["at"],
      released_at: nil,
      release_reason: nil
    }

    %{state | locks: Map.put(state.locks, lock.key, lock)}
  end

  def apply(state, %{"type" => "budget_lock_released"} = e, _env) do
    release_lock(state, e["line_id"], e["code"], e["at"], e["reason"])
  end

  def apply(state, %{"type" => "acceptance_submitted"} = e, _env) do
    sub = %{
      id: e["submission_id"],
      line_id: e["line_id"],
      code: e["code"],
      vendor_id: e["vendor_id"],
      contract_version: e["contract_version"],
      quote_id: e["quote_id"],
      device_ids: e["device_ids"],
      captured_at: e["captured_at"],
      submitted_at: e["submitted_at"],
      evidence_ref: e["evidence_ref"],
      offline: e["offline"] || false,
      idempotency_key: e["idempotency_key"],
      status: "PENDING",
      decided_at: nil,
      po_id: nil,
      reason: nil,
      reason_code: nil
    }

    update_phase(state, e["line_id"], e["code"], fn p ->
      %{p | status: "SUBMITTED", submissions: p.submissions ++ [sub], current_submission_id: sub.id}
    end)
  end

  def apply(state, %{"type" => "submission_superseded"} = e, _env) do
    sid = e["submission_id"]
    state = update_submission(state, sid, fn s ->
      %{s | status: "SUPERSEDED", decided_at: e["at"]}
    end)

    # 若该阶段因此已无待决单（换版/重新提交覆盖），阶段回到实施中
    found_phase = phase(state, e["line_id"], e["code"])

    if found_phase && found_phase.current_submission_id == sid do
      update_phase(state, e["line_id"], e["code"], fn p ->
        %{p | status: "IN_PROGRESS", current_submission_id: nil}
      end)
    else
      state
    end
  end

  def apply(state, %{"type" => "acceptance_approved"} = e, _env) do
    state =
      update_submission(state, e["submission_id"], fn s ->
        %{s | status: "APPROVED", decided_at: e["at"], po_id: e["po_id"]}
      end)

    update_phase(state, e["line_id"], e["code"], fn p ->
      acc = %{
        submission_id: e["submission_id"],
        vendor_id: e["vendor_id"],
        at: e["at"],
        accepted_date: e["accepted_date"],
        contract_version: e["contract_version"]
      }

      # 批准点即为可回退的“安全节点”
      %{p | status: "ACCEPTED", accepted: acc, safe_node: true}
    end)
  end

  def apply(state, %{"type" => "acceptance_rejected"} = e, _env) do
    state =
      update_submission(state, e["submission_id"], fn s ->
        %{s | status: "REJECTED", decided_at: e["at"], reason: e["reason"], reason_code: e["reason_code"]}
      end)

    update_phase(state, e["line_id"], e["code"], fn p ->
      %{p | status: "IN_PROGRESS"}
    end)
  end

  def apply(state, %{"type" => "budget_settled"} = e, _env) do
    lock = state.locks[{e["line_id"], e["code"]}]

    lock =
      lock && %{lock | status: "SETTLED", submission_id: e["submission_id"]}

    locks =
      if lock,
        do: Map.put(state.locks, lock.key, lock),
        else: state.locks

    entries =
      Enum.map(e["monthly"], fn m ->
        %{
          type: "SETTLE",
          active: true,
          line_id: e["line_id"],
          code: e["code"],
          quote_id: e["quote_id"],
          submission_id: e["submission_id"],
          period: m["period"],
          amount_cents: m["amount_cents"],
          days: m["days"],
          at: e["at"],
          idem: "settle:#{e["submission_id"]}:#{m["period"]}"
        }
      end)

    %{state | locks: locks, entries: state.entries ++ entries}
  end

  def apply(state, %{"type" => "budget_reversed"} = e, _env) do
    # 将该阶段此前生效的结算条目标记失效，并追加冲销条目（跨月的每一条都要红冲）
    entries =
      Enum.flat_map(state.entries, fn entry ->
        if entry.type == "SETTLE" and entry.active and entry.line_id == e["line_id"] and
             entry.code == e["code"] do
          reversal = %{
            entry
            | type: "REVERSAL",
              active: false,
              amount_cents: -entry.amount_cents,
              at: e["at"],
              idem: "reverse:#{e["rollback_event_id"]}:#{entry.period}"
          }

          [%{entry | active: false}, reversal]
        else
          [entry]
        end
      end)

    locks =
      case Map.get(state.locks, {e["line_id"], e["code"]}) do
        %{status: "SETTLED"} = lock -> Map.put(state.locks, lock.key, %{lock | status: "REVERSED"})
        _ -> state.locks
      end

    %{state | entries: entries, locks: locks}
  end

  def apply(state, %{"type" => "phase_rolled_back"} = e, _env) do
    update_phase(state, e["line_id"], e["code"], fn p ->
      %{
        p
        | status: "ROLLED_BACK",
          accepted: nil,
          safe_node: false,
          rolled_back_from: p.current_submission_id,
          current_submission_id: nil,
          rolled_back_at: e["at"],
          rollback_reason: e["reason"]
      }
    end)
  end

  def apply(state, %{"type" => "po_created"} = e, _env) do
    po = %{
      id: e["po_id"],
      line_id: e["line_id"],
      code: e["code"],
      submission_id: e["submission_id"],
      vendor_id: e["vendor_id"],
      amount_cents: e["amount_cents"],
      fee_cents: e["fee_cents"],
      penalty_cents: e["penalty_cents"],
      contract_version: e["contract_version"],
      status: "PENDING_CONFIRM",
      attempts: 0,
      created_at: e["at"],
      idempotency_key: e["idempotency_key"],
      external_ref: nil,
      confirmed_at: nil,
      rejected_at: nil,
      reject_reason: nil,
      compensated_at: nil,
      compensation_ref: nil
    }

    %{state | outbox: Map.put(state.outbox, po.id, po)}
  end

  def apply(state, %{"type" => "po_confirmed"} = e, _env) do
    update_outbox(state, e["po_id"], fn po ->
      %{po | status: "CONFIRMED", external_ref: e["external_ref"], confirmed_at: e["at"]}
    end)
  end

  def apply(state, %{"type" => "po_rejected"} = e, _env) do
    update_outbox(state, e["po_id"], fn po ->
      %{po | status: "REJECTED", rejected_at: e["at"], reject_reason: e["reason"]}
    end)
  end

  def apply(state, %{"type" => "po_compensated"} = e, _env) do
    state =
      update_outbox(state, e["po_id"], fn po ->
        %{po | status: "COMPENSATED", compensated_at: e["at"], compensation_ref: e["compensation_ref"]}
      end)

    inbox = Map.put(state.inbox, e["idempotency_key"], %{processed_at: e["at"]})
    %{state | inbox: inbox}
  end

  def apply(state, event, %{"seq" => seq, "at" => at}) do
    # 未知事件不报错（向前兼容），但登记幂等键的事件需记录。
    if event["idempotency_key"] do
      idem =
        Map.put_new(state.idempotency, event["idempotency_key"], %{
          kind: event["type"],
          at: event["at"] || at
        })

      %{state | seq: seq, idempotency: idem}
    else
      %{state | seq: seq}
    end
  end

  # 无 envelope（理论上仅测试直接调用）
  def apply(state, _event, %{}), do: state

  # ───────────────────────────── 内部小工具 ─────────────────────────────

  defp update_phase(state, line_id, code, fun) do
    phases =
      Map.update(state.phases, line_id, %{}, fn line_phases ->
        existing = Map.get(line_phases, code)

        updated =
          if existing do
            fun.(existing)
          else
            # 容错：事件先于阶段快照到达时，以最小结构应用（正常流程不会走到）
            fun.(%{
              line_id: line_id,
              code: code,
              name: code,
              order: 0,
              needs: MapSet.new(),
              min_firmware: "0",
              planned_done_date: nil,
              depends_on: nil,
              status: "PLANNED",
              submissions: [],
              current_submission_id: nil,
              accepted: nil,
              safe_node: false,
              rolled_back_from: nil,
              started_at: nil,
              rolled_back_at: nil,
              rollback_reason: nil
            })
          end

        Map.put(line_phases, code, updated)
      end)

    %{state | phases: phases}
  end

  defp update_submission(state, submission_id, fun) do
    phases =
      Map.new(state.phases, fn {line_id, phases} ->
        new_phases =
          Map.new(phases, fn {code, p} ->
            submissions =
              Enum.map(p.submissions, fn s ->
                if s.id == submission_id, do: fun.(s), else: s
              end)

            {code, %{p | submissions: submissions}}
          end)

        {line_id, new_phases}
      end)

    %{state | phases: phases}
  end

  defp release_lock(state, line_id, code, at, reason) do
    case Map.get(state.locks, {line_id, code}) do
      %{status: "LOCKED"} = lock ->
        lock = %{lock | status: "RELEASED", released_at: at, release_reason: reason}
        %{state | locks: Map.put(state.locks, lock.key, lock)}

      _ ->
        state
    end
  end

  defp update_outbox(state, po_id, fun) do
    case Map.fetch(state.outbox, po_id) do
      {:ok, po} -> %{state | outbox: Map.put(state.outbox, po_id, fun.(po))}
      :error -> state
    end
  end
end
