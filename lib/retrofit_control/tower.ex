defmodule RetrofitControl.Tower do
  @moduledoc """
  改造交付“控制塔”。

  所有写命令都在同一个 GenServer 内串行执行，因此多个服务商并发提交验收结果时：
  只有“满足前置依赖 且 设备能力兼容 且 仍在有效合同版本上 且 预算可锁定”的阶段才能被推进。
  每次批准/驳回/回滚/预算占用都先持久化为事件，再投影到内存状态，并追加审计事件。
  命令支持幂等键（idem_key），重复请求返回首次结果而不重复占用预算或重复发单。
  """

  use GenServer
  alias RetrofitControl.{Domain, EventLog, Money, Json}
  alias RetrofitControl.Procurement.SimAdapter

  @snapshot_every 50

  # ================= public API =================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)
  end

  def reset(server \\ __MODULE__, opts \\ []), do: GenServer.call(server, {:reset, opts})

  # ---- 基础档案 ----
  def register_line(server \\ __MODULE__, params, idem \\ nil),
    do: call(server, {:register_line, params, idem})

  def catalog_device(server \\ __MODULE__, params, idem \\ nil),
    do: call(server, {:catalog_device, params, idem})

  def record_contract(server \\ __MODULE__, params, idem \\ nil),
    do: call(server, {:record_contract, params, idem})

  def supersede_contract(server \\ __MODULE__, contract_id, by_version, idem \\ nil),
    do: call(server, {:supersede_contract, contract_id, by_version, idem})

  def record_quote(server \\ __MODULE__, params, idem \\ nil),
    do: call(server, {:record_quote, params, idem})

  def configure_budget(server \\ __MODULE__, params, idem \\ nil),
    do: call(server, {:configure_budget, params, idem})

  def plan_phase(server \\ __MODULE__, params, idem \\ nil),
    do: call(server, {:plan_phase, params, idem})

  # ---- 验收 / 推进 ----
  def submit_acceptance(server \\ __MODULE__, params, idem \\ nil),
    do: call(server, {:submit_acceptance, params, idem})

  def approve(server \\ __MODULE__, submission_id, actor, idem \\ nil),
    do: call(server, {:approve, submission_id, actor, idem})

  def reject(server \\ __MODULE__, submission_id, reason, actor, idem \\ nil),
    do: call(server, {:reject, submission_id, reason, actor, idem})

  def confirm_accepted(server \\ __MODULE__, params, idem \\ nil),
    do: call(server, {:confirm_accepted, params, idem})

  def rollback(server \\ __MODULE__, line_id, opts \\ %{}, idem \\ nil),
    do: call(server, {:rollback, line_id, opts, idem})

  # ---- 采购补偿 ----
  def receive_receipt(server \\ __MODULE__, params, idem \\ nil),
    do: call(server, {:receive_receipt, params, idem})

  def retry_pending_procurement(server \\ __MODULE__),
    do: GenServer.call(server, :retry_pending)

  # ---- 离线 / 恢复 ----
  def store_offline_result(server \\ __MODULE__, params, idem \\ nil),
    do: call(server, {:store_offline_result, params, idem})

  def backfill_acceptance(server \\ __MODULE__, stored_key, idem \\ nil),
    do: call(server, {:backfill_acceptance, stored_key, idem})

  def recover_restart(server \\ __MODULE__), do: GenServer.call(server, :recover_restart)

  # ---- 读模型 ----
  def state(server \\ __MODULE__), do: GenServer.call(server, :state)
  def report(server \\ __MODULE__), do: GenServer.call(server, :report)
  def audits(server \\ __MODULE__), do: GenServer.call(server, :audits)
  def snapshot_now(server \\ __MODULE__), do: GenServer.call(server, :snapshot_now)

  defp call(server, msg), do: GenServer.call(server, msg, :infinity)

  # ================= callbacks =================

  @impl true
  def init(opts) do
    {:ok,
     %{
       log: opts[:event_log] || EventLog,
       adapter: opts[:adapter] || SimAdapter,
       adapter_name: opts[:adapter_name] || SimAdapter,
       state: Domain.fresh(),
       recovered: false,
       snapshot_every: Keyword.get(opts, :snapshot_every, @snapshot_every),
       log_path: opts[:path]
     }}
  end

  @impl true
  def handle_call({:reset, opts}, _from, _s) do
    {:reply, :ok,
     %{
       log: opts[:event_log] || EventLog,
       adapter: opts[:adapter] || SimAdapter,
       adapter_name: opts[:adapter_name] || SimAdapter,
       state: Domain.fresh(),
       recovered: false,
       snapshot_every: Keyword.get(opts, :snapshot_every, @snapshot_every),
       log_path: opts[:path]
     }}
  end

  def handle_call(:state, _from, s), do: {:reply, s.state, s}
  def handle_call(:audits, _from, s), do: {:reply, Enum.reverse(s.state.audits), s}

  def handle_call(:recover_restart, _from, s) do
    # 断点恢复：读取最近快照，再重放其后事件；离线暂存结果随事件一并恢复。
    {snap, snap_seq, after_events} = EventLog.replay(s.log)
    base = snap || Domain.fresh()
    state = Domain.apply_events(base, after_events)

    events = [
      {:restart_recovered,
       %{at: now(), from_seq: snap_seq, replayed: length(after_events)}}
    ]

    EventLog.append_many(s.log, events)
    state = Domain.apply_events(state, events)

    {:reply,
     {:ok,
      %{restart_count: state.restart_count, replayed: length(after_events), from_snapshot: snap_seq}},
     %{s | state: state, recovered: true}}
  end

  def handle_call(:snapshot_now, _from, s) do
    EventLog.write_snapshot(s.log, s.state, s.state.seq)
    EventLog.append_many(s.log, [{:snapshot_taken, %{at: now(), seq: s.state.seq}}])
    {:reply, :ok, s}
  end

  def handle_call(:report, _from, s), do: {:reply, build_report(s.state), s}

  def handle_call(:retry_pending, _from, s) do
    {events, results} =
      s.state.procurement
      |> Map.values()
      |> Enum.filter(&(&1.status != :acknowledged))
      |> Enum.reduce({[], []}, fn order, {evs, results} ->
        case s.adapter.dispatch(
               %{order_key: order.id, amount_cents: order.amount_cents},
               s.adapter_name
             ) do
          {:ok, ref} ->
            case s.adapter.confirm_receipt(ref, s.adapter_name) do
              {:ok, receipt} ->
                new_evs = [
                  {:procurement_dispatch_attempted, %{order_id: order.id, ok: true, at: now()}},
                  {:procurement_acknowledged,
                   %{order_id: order.id, receipt_key: receipt, at: now()}},
                  audit(:procurement_compensate, %{
                    line_id: order.line_id,
                    phase_id: order.phase_id,
                    amount_cents: order.amount_cents,
                    result: :acknowledged,
                    reason: "补偿重试成功 #{receipt}"
                  })
                ]

                {evs ++ new_evs, [{order.id, :acknowledged} | results]}

              {:error, err} ->
                retry_evs(order, err, evs, results)
            end

          {:error, err} ->
            retry_evs(order, err, evs, results)
        end
      end)

    events = assign_audit_seq(s.state, events)
    EventLog.append_many(s.log, events)
    state2 = Domain.apply_events(s.state, events)
    {:reply, {:ok, Enum.reverse(results)}, %{s | state: state2}}
  end

  # 其余带参命令统一进入命令分发。
  def handle_call(msg, _from, s) when is_tuple(msg), do: handle_command(msg, s)

  defp retry_evs(order, err, evs, results) do
    new_evs = [
      {:procurement_dispatch_attempted,
       %{order_id: order.id, ok: false, error: err, at: now()}},
      audit(:procurement_compensate, %{
        phase_id: order.phase_id,
        result: :retry_wait,
        reason: err
      })
    ]

    {evs ++ new_evs, [{order.id, :retry_wait} | results]}
  end

  # ================= 命令实现 =================
  #
  # 每个命令闭包返回 {:ok, result, events} 或 {:ok, result, events, after_hook}；
  # 事件里的审计占位由 finalize/4 统一赋审计序号后，整批一次落盘，
  # 保证“批准 / 预算占用 / 审计”在重启后要么都在、要么都不在。

  defp handle_command({:register_line, params, idem}, s),
    do: run(s, idem, fn st ->
      require_keys!(params, ~w(id name)a)
      if Map.has_key?(st.lines, params.id), do: fail("产线 #{params.id} 已存在")

      {:ok, %{line_id: params.id},
       [
         {:line_registered,
          %{id: params.id, name: params.name, at: now(), kind: Map.get(params, :kind, "装配线")}},
         audit(:line_registered, %{line_id: params.id, result: :ok, detail: params.name})
       ]}
    end)

  defp handle_command({:catalog_device, p, idem}, s),
    do: run(s, idem, fn st ->
      require_keys!(p, ~w(id line_id kind class caps)a)
      line!(st, p.line_id)
      caps = MapSet.new(p.caps)

      {:ok, %{device_id: p.id},
       [
         {:device_cataloged,
          %{
            id: p.id,
            line_id: p.line_id,
            kind: p.kind,
            class: p.class,
            caps: MapSet.to_list(caps),
            vendor_id: p[:vendor_id],
            contract_version_id: p[:contract_version_id],
            gateway_id: p[:gateway_id],
            at: now()
          }},
         audit(:device_cataloged, %{
           line_id: p.line_id,
           result: :ok,
           detail: "#{p.kind}/#{p.class}"
         })
       ]}
    end)

  defp handle_command({:record_contract, p, idem}, s),
    do: run(s, idem, fn st ->
      require_keys!(p, ~w(id line_id vendor_id version effective_from)a)
      line!(st, p.line_id)

      dup =
        Enum.find(Map.values(st.contracts), fn c ->
          c.line_id == p.line_id and c.vendor_id == p.vendor_id and c.version == p.version
        end)

      if dup, do: fail("合同版本 #{p.vendor_id}@#{p.version} 已存在")

      {:ok, %{contract_id: p.id},
       [
         {:contract_recorded,
          %{
            id: p.id,
            line_id: p.line_id,
            vendor_id: p.vendor_id,
            version: p.version,
            effective_from: p.effective_from,
            note: p[:note],
            at: now()
          }},
         audit(:contract_recorded, %{
           line_id: p.line_id,
           contract_version_id: p.id,
           result: :ok,
           detail: "v#{p.version}"
         })
       ]}
    end)

  defp handle_command({:supersede_contract, contract_id, by_version, idem}, s),
    do: run(s, idem, fn st ->
      c = contract!(st, contract_id)
      if c.status != :active, do: fail("合同 #{contract_id} 已失效，不能再次换版")

      {:ok, %{contract_id: contract_id, superseded_by: by_version},
       [
         {:contract_superseded, %{contract_id: contract_id, by_version: by_version, at: now()}},
         audit(:contract_superseded, %{
           line_id: c.line_id,
           contract_version_id: contract_id,
           result: :ok,
           reason: "被 v#{by_version} 取代"
         })
       ]}
    end)

  defp handle_command({:record_quote, p, idem}, s),
    do: run(s, idem, fn _st ->
      require_keys!(p, ~w(id vendor_id version amount_cents)a)

      {:ok, %{quote_id: p.id},
       [
         {:quote_recorded,
          %{
            id: p.id,
            vendor_id: p.vendor_id,
            version: p.version,
            amount_cents: p.amount_cents,
            valid_until: p[:valid_until],
            contract_id: p[:contract_id],
            line_id: p[:line_id],
            at: now()
          }},
         audit(:quote_recorded, %{
           line_id: p[:line_id],
           contract_version_id: p[:contract_id],
           amount_cents: p.amount_cents,
           result: :ok
         })
       ]}
    end)

  defp handle_command({:configure_budget, p, idem}, s),
    do: run(s, idem, fn _st ->
      require_keys!(p, ~w(total reserve)a)
      if p.total < 0 or p.reserve < 0, do: fail("预算不能为负")
      # 风险储备是独立于主预算的应急池（可大于主预算），批准时主预算不足再动用储备。

      {:ok, %{total: p.total, reserve: p.reserve},
       [
         {:budget_configured, %{total: p.total, reserve: p.reserve, at: now()}},
         audit(:budget_configured, %{
           amount_cents: p.total,
           result: :ok,
           detail: "总预算#{p.total} 风险储备#{p.reserve}"
         })
       ]}
    end)

  defp handle_command({:plan_phase, p, idem}, s),
    do: run(s, idem, fn st ->
      require_keys!(
        p,
        ~w(id line_id seq name device_class required_caps planned_end amount_cents)a
      )

      line!(st, p.line_id)

      if Enum.find(Domain.line_phases(st, p.line_id), &(&1.seq == p.seq)),
        do: fail("产线 #{p.line_id} 序号 #{p.seq} 已存在阶段")

      if is_list(p[:depends_on]) do
        existing = MapSet.new(Domain.line_phases(st, p.line_id), & &1.id)
        missing = Enum.reject(p.depends_on, &MapSet.member?(existing, &1))
        if missing != [], do: fail("验收依赖不存在: #{Enum.join(missing, ",")}")
      end

      if p.amount_cents < 0, do: fail("阶段金额不能为负")

      {:ok, %{phase_id: p.id},
       [
         {:phase_planned,
          %{
            id: p.id,
            line_id: p.line_id,
            seq: p.seq,
            name: p.name,
            device_class: p.device_class,
            required_caps: p.required_caps,
            planned_end: p.planned_end,
            amount_cents: p.amount_cents,
            depends_on: p[:depends_on] || [],
            vendor_id: p[:vendor_id],
            quote_id: p[:quote_id],
            at: now()
          }},
         audit(:phase_planned, %{
           line_id: p.line_id,
           phase_id: p.id,
           amount_cents: p.amount_cents,
           result: :ok
         })
       ]}
    end)

  # ---- 提交验收（多服务商并发，统一在本进程串行裁决）----
  defp handle_command({:submit_acceptance, p, idem}, s),
    do: run(s, idem, fn st ->
      require_keys!(p, ~w(phase_id vendor_id contract_version_id)a)
      phase = phase!(st, p.phase_id)

      if phase.status in [:planned, :blocked, :rejected] do
        case evaluate(st, phase, p) do
          :ok ->
            sub_id = id(st, 0, "sub")

            {:ok,
             %{
               submission_id: sub_id,
               phase_id: phase.id,
               decision: :eligible,
               reason: "满足前置依赖、能力兼容、合同有效，可批准"
             },
             [
               {:submission_received, submission_attrs(sub_id, phase, p)},
               audit(:submit_acceptance, %{
                 line_id: phase.line_id,
                 phase_id: phase.id,
                 contract_version_id: p.contract_version_id,
                 result: :pending,
                 reason: "满足前置条件，等待批准"
               })
             ]}

          {:error, reason} ->
            {:ok, wrap, evs} = deny_items(st, phase, p, reason)
            {:ok, wrap, evs}
        end
      else
        {:ok, wrap, evs} = deny_items(st, phase, p, "阶段状态为 #{phase.status}，不接受新提交")
        {:ok, wrap, evs}
      end
    end)

  # ---- 批准：再次校验 + 锁定预算 ----
  defp handle_command({:approve, submission_id, actor, idem}, s),
    do: run(s, idem, fn st ->
      sub = submission!(st, submission_id)
      phase = phase!(st, sub.phase_id)

      cond do
        phase.status in [:approved, :accepted] ->
          {:ok, %{phase_id: phase.id, decision: :already, status: phase.status}, []}

        sub.status != :received ->
          fail("提交 #{submission_id} 状态为 #{sub.status}，不可批准")

        true ->
          # 批准瞬间重新做完整裁决：防止“提交后合同被换版 / 预算被并发阶段抢空”。
          p = %{
            vendor_id: sub.vendor_id,
            contract_version_id: sub.contract_version_id,
            device_id: sub.device_id,
            device_caps: sub.device_caps,
            evidence: sub.evidence
          }

          # 批准门：提交条件 + 预算必须此刻仍满足（预算可能在提交后被并发阶段抢空）。
          approve_gate =
            with :ok <- evaluate(st, phase, p),
                 :ok <- approve_budget_gate(st, phase) do
              :ok
            end

          case approve_gate do
            :ok ->
              t = Domain.totals(st)
              lock = phase.amount_cents
              main_free = max(t.total - t.committed - t.spent, 0)
              from_reserve = max(lock - main_free, 0)

              hold_id = id(st, 0, "led")
              reserve_id = if from_reserve > 0, do: id(st, 1, "ledr")

              events =
                [
                  {:ledger_posted,
                   %{
                     id: hold_id,
                     phase_id: phase.id,
                     line_id: phase.line_id,
                     kind: :hold,
                     amount_cents: lock,
                     reason: "批准阶段锁定预算",
                     created_at: now()
                   }}
                ]
                |> maybe_add(from_reserve > 0, {
                  :ledger_posted,
                  %{
                    id: reserve_id,
                    phase_id: phase.id,
                    line_id: phase.line_id,
                    kind: :reserve_draw,
                    amount_cents: from_reserve,
                    reason: "主预算不足，动用风险储备",
                    created_at: now()
                  }
                })
                |> Kernel.++([
                  {:phase_approved,
                   %{
                     phase_id: phase.id,
                     contract_version_id: sub.contract_version_id,
                     submission_id: sub.id,
                     amount_cents: lock,
                     reserve_cents: from_reserve,
                     locked_ledger_id: hold_id,
                     rollback_node: phase.seq,
                     at: now()
                   }},
                  audit(:approve, %{
                    actor: actor,
                    line_id: phase.line_id,
                    phase_id: phase.id,
                    submission_id: sub.id,
                    contract_version_id: sub.contract_version_id,
                    amount_cents: lock,
                    safety_node: phase.seq,
                    result: :ok,
                    detail: if(from_reserve > 0, do: "动用风险储备#{from_reserve}")
                  })
                ])

              {:ok,
               %{
                 phase_id: phase.id,
                 decision: :approved,
                 locked_cents: lock,
                 from_reserve_cents: from_reserve,
                 safety_node: phase.seq
               }, events}

            {:error, reason} ->
              {:ok, %{phase_id: phase.id, decision: :denied, reason: reason},
               [
                 {:advance_denied,
                  %{phase_id: phase.id, submission_id: sub.id, reason: reason, at: now()}},
                 audit(:approve, %{
                   actor: actor,
                   line_id: phase.line_id,
                   phase_id: phase.id,
                   contract_version_id: sub.contract_version_id,
                   amount_cents: phase.amount_cents,
                   result: :denied,
                   reason: reason
                 })
               ]}
          end
      end
    end)

  # ---- 驳回 ----
  defp handle_command({:reject, submission_id, reason, actor, idem}, s),
    do: run(s, idem, fn st ->
      sub = submission!(st, submission_id)
      phase = phase!(st, sub.phase_id)

      if phase.status in [:approved, :accepted],
        do: fail("阶段已#{phase.status}，请使用回滚而非驳回")

      {:ok, %{phase_id: phase.id, decision: :rejected},
       [
         {:phase_rejected,
          %{phase_id: phase.id, submission_id: sub.id, reason: reason, at: now()}},
         audit(:reject, %{
           actor: actor,
           line_id: phase.line_id,
           phase_id: phase.id,
           submission_id: sub.id,
           result: :rejected,
           reason: reason
         })
       ]}
    end)

  # ---- 确认验收：释放锁定、跨月费用、延期罚则、触发采购 ----
  defp handle_command({:confirm_accepted, p, idem}, s),
    do: run(s, idem, fn st ->
      require_keys!(p, ~w(phase_id completed_at)a)
      phase = phase!(st, p.phase_id)

      if phase.status != :approved,
        do: fail("阶段 #{phase.id} 状态为 #{phase.status}，需先批准才能确认验收")

      from = phase.approved_at && NaiveDateTime.to_date(phase.approved_at)
      to = p.completed_at
      monthly = Money.split_by_month(phase.amount_cents, from || to, to)
      penalty = Money.late_penalty(phase.planned_end, to, phase.amount_cents, p[:penalty] || [])

      # 1) 释放批准时的 hold（带符号反向行）
      release_hold =
        {:ledger_reversed,
         %{
           id: id(st, 0, "rel"),
           phase_id: phase.id,
           line_id: phase.line_id,
           kind: :hold,
           amount_cents: -phase.amount_cents,
           reverses: phase.locked_ledger_id,
           reason: "验收通过，释放预算锁定",
           created_at: now()
         }}

      # 2) 跨月费用（按月拆分 spend，总额恒定）
      month_items =
        monthly
        |> Enum.with_index()
        |> Enum.map(fn {{month, amt}, idx} ->
          {:ledger_posted,
           %{
             id: id(st, idx + 1, "ledm"),
             phase_id: phase.id,
             line_id: phase.line_id,
             kind: :spend,
             amount_cents: amt,
             month: month,
             reason: "验收通过·跨月费用",
             created_at: now()
           }}
        end)

      # 3) 延期罚则
      penalty_item =
        if penalty > 0 do
          [
            {:ledger_posted,
             %{
               id: id(st, map_size(monthly) + 1, "ledp"),
               phase_id: phase.id,
               line_id: phase.line_id,
               kind: :penalty,
               amount_cents: penalty,
               month: Money.month_key(to),
               reason: "延期罚则 #{Date.diff(to, phase.planned_end)} 天",
               created_at: now()
             }}
          ]
        else
          []
        end

      order_id = id(st, map_size(monthly) + 2, "po")

      events =
        [release_hold]
        |> Kernel.++(month_items)
        |> Kernel.++(penalty_item)
        |> Kernel.++([
          {:phase_accepted,
           %{
             phase_id: phase.id,
             completed_at: to,
             spent_ledger_id: "spend-#{phase.id}",
             penalty_ledger_id: if(penalty > 0, do: "penalty-#{phase.id}"),
             penalty_cents: penalty,
             at: now()
           }},
          {:procurement_created,
           %{
             id: order_id,
             phase_id: phase.id,
             line_id: phase.line_id,
             amount_cents: phase.amount_cents,
             receipt_key: nil,
             attempts: 0,
             at: now()
           }},
          audit(:confirm_accepted, %{
            line_id: phase.line_id,
            phase_id: phase.id,
            amount_cents: phase.amount_cents,
            result: :accepted,
            safety_node: phase.seq,
            detail:
              "跨月费用#{Json.encode(monthly)}" <>
                if(penalty > 0, do: " 延期罚则#{penalty}", else: "")
          })
        ])

      {:ok,
       %{
         phase_id: phase.id,
         decision: :accepted,
         safety_node: phase.seq,
         monthly_cents: monthly,
         penalty_cents: penalty,
         procurement_order_id: order_id
       }, events, {:procure, order_id}}
    end)

  # ---- 回滚到安全节点 ----
  defp handle_command({:rollback, line_id, opts, idem}, s),
    do: run(s, idem, fn st ->
      line!(st, line_id)
      phases = Domain.line_phases(st, line_id)
      active = Enum.filter(phases, &(&1.status in [:approved, :accepted]))

      if active == [], do: fail("产线 #{line_id} 没有可回滚的阶段")

      from_seq = opts[:from_seq] || Enum.max(Enum.map(active, & &1.seq))
      approved_seqs = phases |> Enum.filter(&(&1.status == :approved)) |> Enum.map(& &1.seq)
      accepted_seqs = phases |> Enum.filter(&(&1.status == :accepted)) |> Enum.map(& &1.seq)

      # 默认退回“最近安全节点”之后：
      # 若存在已批准未验收阶段，从最靠前的那一段开始回退（保留其前已验收成果）；
      # 否则把所有已验收段一并回退（退回上一安全节点）。
      default_to =
        cond do
          approved_seqs != [] -> Enum.min(approved_seqs)
          accepted_seqs != [] -> Enum.min(accepted_seqs)
        end

      to_seq = opts[:to_seq] || default_to

      if to_seq > from_seq, do: fail("回滚目标节点不能高于当前节点")

      affected =
        Enum.filter(phases, fn ph ->
          ph.seq >= to_seq and ph.seq <= from_seq and ph.status in [:approved, :accepted]
        end)

      affected_ids = MapSet.new(affected, & &1.id)

      # 台账按阶段+种类求净额，再生成“把净额清零”的带符号反向行：
      # 已批准未验收 -> 释放 hold、退回动用的储备；
      # 已验收       -> 红冲 spend / penalty、退回动用的储备。
      net_by_phase =
        st.ledger
        |> Map.values()
        |> Enum.filter(&(&1.line_id == line_id and &1.phase_id in affected_ids))
        |> Enum.group_by(& &1.phase_id)
        |> Map.new(fn {pid, entries} ->
          nets =
            entries
            |> Enum.group_by(& &1.kind)
            |> Map.new(fn {kind, es} -> {kind, Enum.sum(Enum.map(es, & &1.amount_cents))} end)

          {pid, nets}
        end)

      {reversal_items, _} =
        Enum.flat_map_reduce(affected, 0, fn ph, offset ->
          nets = Map.get(net_by_phase, ph.id, %{})

          pairs =
            [:hold, :spend, :penalty, :reserve_draw]
            |> Enum.map(&{&1, Map.get(nets, &1, 0)})
            |> Enum.filter(fn {_, v} -> v != 0 end)

          items =
            pairs
            |> Enum.with_index()
            |> Enum.map(fn {{kind, net}, k} ->
              {:ledger_reversed,
               %{
                 id: id(st, offset + k, "rev"),
                 phase_id: ph.id,
                 line_id: line_id,
                 kind: kind,
                 amount_cents: -net,
                 reverses: "net-#{ph.id}-#{kind}",
                 reason: "阶段回滚冲红(#{kind})",
                 created_at: now()
               }}
            end)

          {items, offset + length(pairs)}
        end)

      safety_seq = to_seq - 1

      released_cents =
        Enum.sum(Enum.map(affected, fn ph -> ph.amount_cents + (ph.penalty_cents || 0) end))

      events =
        reversal_items ++
          [
            {:phase_rolled_back,
             %{
               line_id: line_id,
               from_seq: from_seq,
               to_seq: to_seq,
               safety_seq: safety_seq,
               affected: Enum.map(affected, & &1.id),
               at: now()
             }},
            audit(:rollback, %{
              actor: Map.get(opts, :actor, "厂长"),
              line_id: line_id,
              result: :rolled_back,
              safety_node: safety_seq,
              amount_cents: released_cents,
              reason:
                Map.get(
                  opts,
                  :reason,
                  "预算超限或能力不兼容，回退到安全节点 #{safety_seq}"
                )
            })
          ]

      {:ok,
       %{
         line_id: line_id,
         rolled_back_to_safety_node: safety_seq,
         affected_phases: Enum.map(affected, & &1.id),
         released_cents: released_cents
       }, events}
    end)

  # ---- 离线验收：先持久化暂存，不推进 ----
  defp handle_command({:store_offline_result, p, idem}, s),
    do: run(s, idem, fn _st ->
      require_keys!(p, ~w(stored_key phase_id)a)

      if Map.has_key?(s.state.offline_store, p.stored_key),
        do: fail("离线结果 #{p.stored_key} 已暂存")

      payload = Map.delete(p, :stored_key)

      {:ok, %{stored_key: p.stored_key, stored: true},
       [
         {:offline_result_stored,
          %{stored_key: p.stored_key, phase_id: p.phase_id, payload: payload, at: now()}},
         audit(:offline_stored, %{
           phase_id: p.phase_id,
           result: :stored,
           reason: "现场离线，验收结果已落盘待补传"
         })
       ]}
    end)

  defp handle_command({:backfill_acceptance, stored_key, idem}, s),
    do: run(s, idem, fn st ->
      case st.offline_store[stored_key] do
        nil ->
          fail("没有找到离线暂存结果 #{stored_key}")

        %{payload: payload} ->
          # 补传必须重新满足“合同版本仍有效、依赖完成、能力兼容、预算可锁”等前置条件；
          # 若合同在离线期间被换版，则补传被拒绝，保证离线补传与在线推进口径一致。
          phase = phase!(st, payload.phase_id)
          p = Map.put_new(payload, :vendor_id, phase.vendor_id)

          if phase.status in [:planned, :blocked, :rejected] do
            case evaluate(st, phase, p) do
              :ok ->
                sub_id = id(st, 0, "sub")

                {:ok,
                 %{
                   stored_key: stored_key,
                   backfilled: true,
                   submission_id: sub_id,
                   decision: :eligible
                 },
                 [
                   {:submission_received, submission_attrs(sub_id, phase, p)},
                   {:offline_result_consumed, %{stored_key: stored_key, at: now()}},
                   audit(:offline_backfill, %{
                     line_id: phase.line_id,
                     phase_id: phase.id,
                     contract_version_id: p.contract_version_id,
                     result: :ok,
                     reason: "离线验收结果补传成功"
                   })
                 ]}

              {:error, reason} ->
                # 前置不满足：暂存结果保留（不消费），便于换版或修复后再次补传。
                {:ok,
                 %{stored_key: stored_key, backfilled: false, decision: :denied, reason: reason},
                 [
                   {:advance_denied,
                    %{phase_id: phase.id, submission_id: nil, reason: reason, at: now()}},
                   audit(:offline_backfill, %{
                     line_id: phase.line_id,
                     phase_id: phase.id,
                     result: :denied,
                     reason: reason
                   })
                 ]}
            end
          else
            fail("阶段 #{phase.id} 已处于 #{phase.status}，离线补传不再适用")
          end
      end
    end)

  # ---- 采购回执：幂等 ----
  defp handle_command({:receive_receipt, p, idem}, s),
    do: run(s, idem, fn st ->
      require_keys!(p, ~w(order_id receipt_key)a)
      order = procurement!(st, p.order_id)

      if order.status == :acknowledged do
        # 回执重复送达：幂等返回首次回执，不重复入账。
        if order.receipt_key == p.receipt_key do
          {:ok, %{order_id: order.id, idempotent: true, receipt_key: order.receipt_key}, []}
        else
          fail("订单 #{order.id} 已有不同回执 #{order.receipt_key}，拒绝冲突回执")
        end
      else
        {:ok, %{order_id: order.id, acknowledged: true, receipt_key: p.receipt_key},
         [
           {:procurement_acknowledged,
            %{order_id: order.id, receipt_key: p.receipt_key, at: now()}},
           audit(:procurement_receipt, %{
             line_id: order.line_id,
             phase_id: order.phase_id,
             amount_cents: order.amount_cents,
             result: :acknowledged,
             detail: p.receipt_key
           })
         ]}
      end
    end)

  # ================= 裁决逻辑（纯函数） =================

  defp evaluate(st, phase, p) do
    # 提交裁决只看“前置依赖 / 有效合同版本 / 设备能力”。
    # 预算竞争放在批准锁定那一刻（check_budget_lock），因为提交后预算可能被并发阶段抢空。
    with :ok <- check_dependencies(st, phase),
         :ok <- check_contract(st, phase, p),
         :ok <- check_capabilities(st, phase, p) do
      :ok
    end
  end

  defp check_dependencies(st, phase) do
    missing =
      (phase.depends_on || [])
      |> Enum.reject(fn dep_id ->
        case st.phases[dep_id] do
          nil -> false
          dep -> dep.status == :accepted
        end
      end)

    if missing == [], do: :ok, else: {:error, "验收依赖未完成: #{Enum.join(missing, ",")}"}
  end

  defp check_contract(st, phase, p) do
    contract = st.contracts[p.contract_version_id]

    cond do
      is_nil(contract) ->
        {:error, "合同版本 #{p.contract_version_id} 不存在"}

      contract.status != :active ->
        {:error,
         "合同版本 v#{contract.version} 已被 v#{contract.superseded_by} 换版，禁止在旧版上推进"}

      contract.line_id != phase.line_id ->
        {:error, "合同不属于该产线"}

      phase.vendor_id && contract.vendor_id != phase.vendor_id ->
        {:error, "服务商与阶段约定不符"}

      true ->
        :ok
    end
  end

  defp check_capabilities(st, phase, p) do
    provided =
      cond do
        is_list(p[:device_caps]) -> MapSet.new(p.device_caps)
        is_binary(p[:device_id]) and st.devices[p.device_id] -> st.devices[p.device_id].caps
        true -> MapSet.new()
      end

    required = MapSet.new(phase.required_caps)

    if MapSet.subset?(required, provided) do
      :ok
    else
      missing = required |> MapSet.difference(provided) |> MapSet.to_list()
      {:error, "设备能力不兼容，缺少: #{Enum.join(missing, ",")}"}
    end
  end

  defp check_budget(st, phase) do
    avail = Domain.budget_available(st)

    if avail >= phase.amount_cents do
      :ok
    else
      {:error, "预算不足：需#{phase.amount_cents}，可用#{avail}（含风险储备）"}
    end
  end

  # 批准锁定门：主预算+风险储备合计必须仍能锁足该阶段。
  defp approve_budget_gate(st, phase) do
    t = Domain.totals(st)
    main_free = max(t.total - t.committed - t.spent, 0)
    reserve_left = max(t.reserve - t.reserve_drawn, 0)

    if main_free + reserve_left >= phase.amount_cents do
      :ok
    else
      {:error,
       "预算竞争失败：需#{phase.amount_cents}，可用#{main_free + reserve_left}（主预算+风险储备）"}
    end
  end

  defp deny_items(st, phase, p, reason) do
    sub_id = id(st, 0, "sub")

    {:ok, %{submission_id: sub_id, decision: :denied, reason: reason},
     [
       {:submission_received, submission_attrs(sub_id, phase, p)},
       {:advance_denied, %{phase_id: phase.id, submission_id: sub_id, reason: reason, at: now()}},
       audit(:submit_acceptance, %{
         line_id: phase.line_id,
         phase_id: phase.id,
         contract_version_id: p.contract_version_id,
         result: :denied,
         reason: reason
       })
     ]}
  end

  # ================= 执行 / 持久化 =================

  defp run(s, idem, fun) do
    case idem_hit(s.state, idem) do
      {:hit, result} ->
        {:reply, {:ok, Map.put(result, :idempotent, true)}, s}

      :miss ->
        try do
          case fun.(s.state) do
            {:ok, result, events} ->
              finalize(s, idem, result, events, nil)

            {:ok, result, events, after_hook} ->
              finalize(s, idem, result, events, after_hook)

            {:error, reason} ->
              {:reply, {:error, reason}, s}
          end
        catch
          {:business_error, msg} -> {:reply, {:error, msg}, s}
        end
    end
  end

  defp finalize(s, idem, result, events, after_hook) do
    events = assign_audit_seq(s.state, events)

    events =
      if idem,
        do: events ++ [{:idem_recorded, %{key: idem, result: result, at: now()}}],
        else: events

    # 整批一次落盘：批准/预算占用/审计原子可见，重启后要么都在要么都不在。
    EventLog.append_many(s.log, events)
    state = Domain.apply_events(s.state, events)
    maybe_snapshot(s, state)

    s =
      case after_hook do
        {:procure, order_id} when is_binary(order_id) ->
          dispatch_new_procurement(%{s | state: state}, order_id)

        _ ->
          %{s | state: state}
      end

    {:reply, {:ok, result}, s}
  end

  # 为审计占位分配本批内连续、且接在已有审计序号之后的序号。
  defp assign_audit_seq(st, events) do
    {events, _} =
      Enum.map_reduce(events, st.audit_seq, fn
        {:audit_with_seq, base}, n ->
          n = n + 1
          {{:audit_appended, Map.put(base, :seq, n)}, n}

        event, n ->
          {event, n}
      end)

    events
  end

  defp dispatch_new_procurement(s, order_id) do
    order = s.state.procurement[order_id]

    events =
      case s.adapter.dispatch(
             %{order_key: order.id, amount_cents: order.amount_cents},
             s.adapter_name
           ) do
        {:ok, ref} ->
          case s.adapter.confirm_receipt(ref, s.adapter_name) do
            {:ok, receipt} ->
              [
                {:procurement_dispatch_attempted, %{order_id: order.id, ok: true, at: now()}},
                {:procurement_acknowledged,
                 %{order_id: order.id, receipt_key: receipt, at: now()}},
                audit(:procurement_dispatch, %{
                  line_id: order.line_id,
                  phase_id: order.phase_id,
                  amount_cents: order.amount_cents,
                  result: :acknowledged,
                  detail: receipt
                })
              ]

            {:error, err} ->
              dispatch_failed(order, err)
          end

        {:error, err} ->
          dispatch_failed(order, err)
      end

    events = assign_audit_seq(s.state, events)
    EventLog.append_many(s.log, events)
    %{s | state: Domain.apply_events(s.state, events)}
  end

  defp dispatch_failed(order, err) do
    [
      {:procurement_dispatch_attempted,
       %{order_id: order.id, ok: false, error: err, at: now()}},
      audit(:procurement_dispatch, %{
        phase_id: order.phase_id,
        result: :retry_wait,
        reason: err
      })
    ]
  end

  defp maybe_snapshot(s, state) do
    if s.log_path && state.seq > 0 && rem(state.seq, s.snapshot_every) == 0 do
      EventLog.write_snapshot(s.log, state, state.seq)
    end
  end

  # ================= 审计 / 厂长报表 =================

  defp audit(action, attrs) do
    {:audit_with_seq,
     %{
       at: now(),
       action: action,
       result: Map.get(attrs, :result, :ok),
       actor: Map.get(attrs, :actor, "system"),
       line_id: Map.get(attrs, :line_id),
       phase_id: Map.get(attrs, :phase_id),
       submission_id: Map.get(attrs, :submission_id),
       contract_version_id: Map.get(attrs, :contract_version_id),
       amount_cents: Map.get(attrs, :amount_cents),
       safety_node: Map.get(attrs, :safety_node),
       reason: Map.get(attrs, :reason),
       idem_key: Map.get(attrs, :idem_key),
       detail: Map.get(attrs, :detail)
     }}
  end

  defp build_report(st) do
    t = Domain.totals(st)

    lines =
      st.lines
      |> Map.values()
      |> Enum.sort_by(& &1.id)
      |> Enum.map(fn line ->
        phases = Domain.line_phases(st, line.id)
        node = Map.get(st.safety_nodes, line.id, 0)

        next_action =
          cond do
            # 1) 有已批准待验收的阶段：现场已锁预算，等待上线完成后确认验收
            (p = Enum.find(phases, &(&1.status == :approved))) ->
              "可以继续：第#{p.seq}段《#{p.name}》已批准并锁定预算，等待上线完成后确认验收"

            # 2) 有处于规划/阻塞、且前置依赖与预算就绪的阶段
            (p = Enum.find(phases, &(&1.status in [:planned, :blocked]))) &&
                report_gate(st, p) == :ok ->
              "可以继续：第#{p.seq}段《#{p.name}》前置依赖与预算已就绪，等待服务商在有效合同版本上提交"

            (p = Enum.find(phases, &(&1.status in [:planned, :blocked]))) ->
              {:error, r} = report_gate(st, p)
              "暂停：第#{p.seq}段《#{p.name}》#{r}"

            # 3) 有被驳回/回滚的阶段，需要决策（整改后重新提交或保持回退）
            (p = Enum.find(phases, &(&1.status in [:rejected, :rolled_back]))) ->
              "暂停：第#{p.seq}段《#{p.name}》状态为#{p.status}，已退回安全节点#{node}，需整改后重新提交"

            # 4) 全部验收
            phases != [] and Enum.all?(phases, &(&1.status == :accepted)) ->
              "全部阶段已验收，可考虑下一段产线"

            true ->
              "暂无可推进阶段"
          end

        %{
          line_id: line.id,
          name: line.name,
          safety_node: node,
          can_continue: String.starts_with?(next_action, "可以继续"),
          next_action: next_action,
          phases:
            Enum.map(phases, fn ph ->
              %{
                seq: ph.seq,
                phase_id: ph.id,
                name: ph.name,
                status: ph.status,
                amount_cents: ph.amount_cents,
                contract_version_id: ph.contract_version_id,
                planned_end: ph.planned_end,
                completed_at: ph.completed_at
              }
            end),
          net_cents: Domain.line_spent(st, line.id)
        }
      end)

    %{
      generated_at: now_iso(),
      budget: %{
        total_cents: t.total,
        locked_cents: t.committed,
        spent_cents: t.spent,
        available_cents: t.total + t.reserve - t.committed - t.spent,
        reserve_cents: t.reserve,
        reserve_drawn_cents: t.reserve_drawn
      },
      lines: lines,
      procurement: %{
        pending: Enum.count(Map.values(st.procurement), &(&1.status != :acknowledged)),
        acknowledged: Enum.count(Map.values(st.procurement), &(&1.status == :acknowledged))
      },
      restart_count: st.restart_count,
      audit_count: length(st.audits)
    }
  end

  defp report_gate(st, phase) do
    with :ok <- check_dependencies(st, phase),
         :ok <- check_budget(st, phase) do
      :ok
    end
  end

  # ================= helpers =================

  # 命令内唯一 ID：以当前事件序号为基准 + 偏移；追加 :uniq 防止跨实体同序号冲突。
  # 不同前缀(实体集合)本就分表存放，seq 单调增长保证不与历史记录冲突。
  defp id(st, offset, prefix) do
    n = st.seq + offset + 1
    "#{prefix}_#{String.pad_leading(Integer.to_string(n), 4, "0")}"
  end

  defp idem_hit(_st, nil), do: :miss

  defp idem_hit(st, key) do
    case st.idem[key] do
      nil -> :miss
      %{result: r} -> {:hit, r}
    end
  end

  defp submission_attrs(sub_id, phase, p) do
    %{
      id: sub_id,
      phase_id: phase.id,
      line_id: phase.line_id,
      vendor_id: p.vendor_id,
      contract_version_id: p.contract_version_id,
      device_id: p[:device_id],
      device_caps: p[:device_caps] || [],
      evidence: p[:evidence] || %{},
      at: now(),
      submitted_at: now(),
      occurred_at: p[:occurred_at],
      offline: p[:offline] || false
    }
  end

  defp maybe_add(list, true, item), do: list ++ [item]
  defp maybe_add(list, false, _), do: list

  defp require_keys!(map, keys) do
    Enum.each(keys, fn k ->
      unless Map.has_key?(map, k) or Map.has_key?(map, to_string(k)) do
        fail("缺少必填参数 #{k}")
      end
    end)
  end

  defp line!(st, id), do: st.lines[id] || fail("产线 #{id} 不存在")
  defp phase!(st, id), do: st.phases[id] || fail("阶段 #{id} 不存在")
  defp contract!(st, id), do: st.contracts[id] || fail("合同 #{id} 不存在")
  defp submission!(st, id), do: st.submissions[id] || fail("验收提交 #{id} 不存在")
  defp procurement!(st, id), do: st.procurement[id] || fail("采购订单 #{id} 不存在")

  defp fail(msg), do: throw({:business_error, msg})

  # Elixir 1.14 的 utc_now/1 参数是日历而非精度，这里用默认秒级；事件顺序以进程串行 + seq 为准。
  defp now, do: NaiveDateTime.utc_now()
  defp now_iso, do: NaiveDateTime.to_iso8601(now())
end
