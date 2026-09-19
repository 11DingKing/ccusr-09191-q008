defmodule RetrofitControl.Engine do
  @moduledoc """
  领域引擎：对外提供全部业务命令。

  并发模型：所有写命令都进入 `Journal.commit/1`，在同一个 Journal 进程内
  “读取最新状态 → 规则裁决 → 生成事件 → fsync 落盘”一气呵成。多个服务商
  并发提交验收、多个审批并发抢预算，都在此被串行化裁决，只有满足前置条件
  且仍挂在有效合同版本上的阶段能被推进。

  幂等：携带 `Idempotency-Key` 的命令在重启前后都只生效一次，重放时
  Journal 中已记录的键会直接回放首次结果。
  """

  use GenServer

  require Logger

  alias RetrofitControl.{State, Journal, Util, Events, DomainError}

  # ───────────────────────────── 公共 API ─────────────────────────────

  def start_link(opts \\ []) do
    opts = if is_list(opts), do: Map.new(opts), else: opts
    GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)
  end

  def state(server \\ __MODULE__), do: GenServer.call(server, :state)
  def reset(dir) do
    with {:ok, files} <- File.rm_rf(dir), do: files
  end

  @doc "按 id 查找验收单（测试/API 用）。"
  def submission_view(server \\ __MODULE__, submission_id) do
    st = state(server)
    State.submission(st, submission_id)
  end

  @doc "按顺序返回某产线全部阶段（断言不变量用）。"
  def phases_for_assert(server \\ __MODULE__, line_id) do
    State.phases_of(state(server), line_id)
  end

  # —— 主数据 ——
  def register_line(params, server \\ __MODULE__), do: command(server, :register_line, params)
  def register_device(params, server \\ __MODULE__), do: command(server, :register_device, params)
  def plan_phase(params, server \\ __MODULE__), do: command(server, :plan_phase, params)
  def record_quote(params, server \\ __MODULE__), do: command(server, :record_quote, params)

  # —— 合同换版 ——
  def activate_contract(params, server \\ __MODULE__), do: command(server, :activate_contract, params)

  # —— 执行 ——
  def start_phase(params, server \\ __MODULE__), do: command(server, :start_phase, params)
  def submit_acceptance(params, server \\ __MODULE__), do: command(server, :submit_acceptance, params)
  def approve(params, server \\ __MODULE__), do: command(server, :approve, params)
  def reject(params, server \\ __MODULE__), do: command(server, :reject, params)
  def rollback(params, server \\ __MODULE__), do: command(server, :rollback, params)

  # —— 外部采购回执（幂等补偿） ——
  def receive_receipt(params, server \\ __MODULE__), do: command(server, :receive_receipt, params)
  def pending_pos(server \\ __MODULE__), do: GenServer.call(server, :pending_pos)

  def procurement_client do
    Application.get_env(:retrofit_control, :procurement_client,
                         RetrofitControl.Procurement.HttpcClient)
  end

  def put_procurement_client(client) do
    Application.put_env(:retrofit_control, :procurement_client, client)
  end

  # —— 读模型（厂长视图） ——
  def line_board(server \\ __MODULE__, line_id \\ :all)

  def line_board(server, :all) do
    GenServer.call(server, :line_board)
  end

  def line_board(server, line_id) when is_binary(line_id) do
    GenServer.call(server, {:line_board, line_id})
  end

  def budget_board(server \\ __MODULE__) do
    GenServer.call(server, :budget_board)
  end

  def audit(server \\ __MODULE__, opts \\ []) do
    GenServer.call(server, {:audit, opts})
  end

  defp command(server, name, params) do
    idem = params[:idempotency_key] || params["idempotency_key"]
    GenServer.call(server, {:command, name, params, idem})
  end

  # 便捷宏：所有写命令的 ! 版本，失败即抛 DomainError（供脚本/演示使用）
  bang_actions = ~w(
    register_line register_device plan_phase record_quote activate_contract
    start_phase submit_acceptance approve reject rollback receive_receipt
  )a

  for action <- bang_actions do
    def unquote(:"#{action}!")(params, server \\ __MODULE__) do
      case unquote(action)(params, server) do
        {:ok, view} -> view
        {:error, err} -> raise err
      end
    end
  end

  # ───────────────────────────── GenServer ─────────────────────────────

  @impl true
  def init(opts) do
    dir = opts[:dir] || Application.get_env(:retrofit_control, :data_dir, "data/default")
    clock = opts[:clock] || default_clock_ref(opts[:name])

    unless opts[:clock] do
      {:ok, _pid} = Util.start_clock(clock)
    end

    unless opts[:journal] do
      File.mkdir_p!(dir)

      case Journal.start_link(dir: dir) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end

    journal = opts[:journal] || Journal

    {:ok,
     %{
       dir: dir,
       journal: journal,
       clock: clock,
       state: %State{},
       replay_results: %{}
     }, {:continue, :replay}}
  end

  # 默认引擎共享全局时钟；命名引擎使用独立时钟，支持并发测试
  defp default_clock_ref(nil), do: Util.Clock
  defp default_clock_ref(name), do: Module.concat(name, Clock)

  @doc "把引擎时钟拨到指定日期（测试跨月费用、延期罚则、离线补传用）。"
  def set_virtual_time(server \\ __MODULE__, %Date{} = date) do
    GenServer.call(server, {:set_clock, fn -> DateTime.new!(date, ~T[10:00:00.000000]) end})
  end

  def reset_time(server \\ __MODULE__) do
    GenServer.call(server, {:set_clock, nil})
  end

  @impl true
  def handle_continue(:replay, s) do
    idem_results = %{}

    {state, idem_results} =
      Journal.replay(s.journal, {%State{}, idem_results}, fn {st, results}, ev, envelope ->
        st = State.apply(st, ev, envelope)
        # 重放时恢复命令级幂等结果，重启后重放同样请求不会二次生效
        results =
          case ev do
            %{"idempotency_key" => key} when is_binary(key) and key != "" ->
              if Map.has_key?(results, key),
                do: results,
                else: Map.put(results, key, replay_result(ev))

            _ ->
              results
          end

        {st, results}
      end)

    Logger.info("事件重放完成：#{state.seq} 条事件，产线 #{map_size(state.lines)} 条")
    {:noreply, %{s | state: state, replay_results: idem_results}}
  end

  @impl true
  def handle_call(:state, _from, s), do: {:reply, s.state, s}
  def handle_call(:clock, _from, s), do: {:reply, s.clock, s}

  def handle_call({:set_clock, fun}, _from, s) do
    Util.set_clock(fun, s.clock)
    {:reply, :ok, s}
  end

  def handle_call({:command, name, params, idem}, _from, s) do
    # 命令级幂等键与系统内部键（po:/receipt: 等）分开命名空间
    command_key = idem && "idem:" <> idem

    case command_key && Map.fetch(s.replay_results, command_key) do
      {:ok, cached} ->
        Logger.info("幂等命中 #{idem}，回放首次结果")
        {:reply, {:ok, cached}, s}

      _ ->
        execute_command(s, name, params, command_key)
    end
  end

  defp execute_command(s, name, params, command_key) do
    result =
      Journal.commit(
        s.journal,
        fn -> decide(s.state, name, params, command_key) end,
        s.clock
      )

    case result do
      {:ok, events, view} ->
        new_state =
          Enum.reduce(events, s.state, fn ev, acc ->
            State.apply(acc, ev, %{at: ev["at"]})
          end)

        # 仅缓存命令级幂等结果（内部派生事件的键不作为命令重放入口）
        results =
          if command_key do
            Map.put(s.replay_results, command_key, view)
          else
            s.replay_results
          end

        {:reply, {:ok, view}, %{s | state: new_state, replay_results: results}}

      {:error, reason} ->
        {:reply, {:error, reason}, s}
    end
  end

  def handle_call(:pending_pos, _from, s) do
    pending = s.state.outbox |> Map.values() |> Enum.filter(&(&1.status in ["PENDING_CONFIRM", "REJECTED"]))
    {:reply, pending, s}
  end

  def handle_call(:line_board, _from, s) do
    {:reply, boards(s), s}
  end

  def handle_call({:line_board, line_id}, _from, s) do
    {:reply, board_for(s.state, line_id), s}
  end

  def handle_call(:budget_board, _from, s) do
    {:reply, budget_view(s.state), s}
  end

  def handle_call({:audit, opts}, _from, s) do
    {:reply, audit_view(s, opts), s}
  end

  # ───────────────────────────── 裁决总入口 ─────────────────────────────

  defp decide(state, name, params, idem_key) do
    params = atomize(params)

    try do
      {events, view} = __decide(state, name, params, idem_key)
      events = List.wrap(events)
      {:ok, events, view}
    rescue
      e in DomainError ->
        {:error, e}
    end
  end

  defp __decide(state, :register_line, p, idem) do
    id = p[:line_id] || raise(DomainError, "缺少 line_id")

    if Map.has_key?(state.lines, id),
      do: raise(DomainError.new("DUPLICATE_LINE", "产线已存在：#{id}"))

    main_cents = p[:main_budget_cents] || 0
    risk_cents = p[:risk_budget_cents] || 0

    if main_cents < 0 or risk_cents < 0,
      do: raise(DomainError.new("BAD_AMOUNT", "预算不能为负"))

    ev =
      base(idem, Events.line_registered(), %{
        line_id: id,
        name: p[:name] || id,
        main_budget_cents: main_cents,
        risk_budget_cents: risk_cents,
        at: Util.now_iso()
      })

    {[ev], %{line_id: id}}
  end

  defp __decide(state, :register_device, p, idem) do
    _line = State.line!(state, p[:line_id])
    id = p[:device_id] || raise(DomainError, "缺少 device_id")

    if Map.has_key?(state.devices, id),
      do: raise(DomainError.new("DUPLICATE_DEVICE", "设备已存在：#{id}"))

    ev =
      base(idem, Events.device_registered(), %{
        device_id: id,
        line_id: p[:line_id],
        kind: p[:kind] || "gateway",
        model: p[:model] || "unknown",
        provides: p[:provides] || [],
        firmware: p[:firmware] || "0",
        at: Util.now_iso()
      })

    {[ev], %{device_id: id}}
  end

  defp __decide(state, :plan_phase, p, idem) do
    _line = State.line!(state, p[:line_id])
    existing = State.phases_of(state, p[:line_id])

    code = p[:code] || raise(DomainError, "缺少 code")

    if Enum.any?(existing, &(&1.code == code)),
      do: raise(DomainError.new("DUPLICATE_PHASE", "阶段已存在：#{code}"))

    order = p[:order] || length(existing) + 1

    if Enum.any?(existing, &(&1.order == order)),
      do: raise(DomainError.new("DUPLICATE_ORDER", "阶段顺序重复：#{order}"))

    planned =
      p[:planned_done_date] ||
        raise(DomainError.new("BAD_DATE", "缺少计划完成日 planned_done_date（yyyy-mm-dd）"))

    validate_date!(planned)

    # 依赖：默认前一阶段；显式指定时必须存在且顺序更早
    depends = p[:depends_on]

    if depends do
      dep = State.phase(state, p[:line_id], depends)
      if is_nil(dep), do: raise(DomainError.new("BAD_DEPENDENCY", "依赖阶段不存在：#{depends}"))
      if dep.order >= order, do: raise(DomainError.new("BAD_DEPENDENCY", "依赖阶段必须早于当前阶段"))
    end

    ev =
      base(idem, Events.phase_planned(), %{
        line_id: p[:line_id],
        code: code,
        name: p[:name] || code,
        order: order,
        needs: p[:needs] || [],
        min_firmware: p[:min_firmware] || "0",
        planned_done_date: planned,
        depends_on: depends,
        at: Util.now_iso()
      })

    {[ev], %{line_id: p[:line_id], code: code}}
  end

  defp __decide(state, :record_quote, p, idem) do
    _line = State.line!(state, p[:line_id])
    id = p[:quote_id] || raise(DomainError, "缺少 quote_id")

    if Map.has_key?(state.quotes, id),
      do: raise(DomainError.new("DUPLICATE_QUOTE", "报价已存在：#{id}"))

    fee = p[:fee_cents] || raise(DomainError.new("BAD_AMOUNT", "缺少 fee_cents"))

    ev =
      base(idem, Events.quote_recorded(), %{
        quote_id: id,
        line_id: p[:line_id],
        vendor_id: p[:vendor_id] || "vendor",
        version: p[:version] || "v1",
        fee_cents: fee,
        reserve_rate_bp: p[:reserve_rate_bp] || 1500,
        penalty_rate_bp_per_day: p[:penalty_rate_bp_per_day] || 10,
        penalty_cap_bp: p[:penalty_cap_bp] || 5000,
        payment_days: p[:payment_days] || 30,
        note: p[:note],
        at: Util.now_iso()
      })

    {[ev], %{quote_id: id}}
  end

  # ─────────────── 合同换版 ───────────────

  defp __decide(state, :activate_contract, p, idem) do
    line_id = p[:line_id]
    line = State.line!(state, line_id)
    quote = state.quotes[p[:quote_id]] || raise(DomainError.not_found("报价版本"))

    if quote.line_id != line_id,
      do: raise(DomainError.new("QUOTE_LINE_MISMATCH", "报价不属于该产线"))

    new_version = p[:version] || quote.version
    current = line.active_contract

    if current != nil and ver_cmp(current.version, new_version) != :lt and p[:force] != true do
      raise DomainError.new(
              "CONTRACT_VERSION_ORDER",
              "新版本号必须大于当前生效版本 #{current.version}（收到 #{new_version}）"
            )
    end

    contract_id = "C-#{line_id}-#{new_version}"
    now = Util.now_iso()

    ev =
      base(idem, Events.contract_superseded(), %{
        contract_id: contract_id,
        line_id: line_id,
        quote_id: quote.id,
        version: new_version,
        valid_from: p[:valid_from] || Util.date_iso(Util.today()),
        at: now
      })

    # 旧合同上所有“待决验收单”显式作废（审计可见），其阶段回实施中，
    # 旧版预算锁显式释放——钱回到池子，等待按新合同重新竞争。
    pending =
      state
      |> State.phases_of(line_id)
      |> Enum.filter(&(&1.status == "SUBMITTED"))
      |> Enum.flat_map(fn ph ->
        Enum.filter(ph.submissions, &(&1.status == "PENDING"))
        |> Enum.map(&{ph.code, &1.id})
      end)

    supersede_events =
      Enum.map(pending, fn {code, sub_id} ->
        base(nil, Events.submission_superseded(), %{
          line_id: line_id,
          code: code,
          submission_id: sub_id,
          at: now
        })
      end)

    locked_codes =
      state
      |> State.phases_of(line_id)
      |> Enum.filter(fn ph ->
        ph.status == "SUBMITTED" and match?(%{status: "LOCKED"}, State.lock_for(state, line_id, ph.code))
      end)
      |> Enum.map(& &1.code)

    release_events =
      Enum.map(locked_codes, fn code ->
        base(nil, Events.budget_lock_released(), %{
          line_id: line_id,
          code: code,
          reason: "contract_superseded:#{new_version}",
          at: now
        })
      end)

    {[ev] ++ supersede_events ++ release_events,
     %{
       contract_id: contract_id,
       version: new_version,
       superseded: current && current.version,
       superseded_submissions: Enum.map(pending, fn {_, sid} -> sid end),
       released_locks: locked_codes
     }}
  end

  # ─────────────── 阶段启动（预算在此锁定，竞争失败则不允许启动） ───────────────

  defp __decide(state, :start_phase, p, idem) do
    line_id = p[:line_id]
    code = p[:code]
    phase = State.phase!(state, line_id, code)
    contract = require_contract!(state, line_id)
    quote = State.active_quote(state, line_id)

    # 可开工的情形：首次开工（PLANNED）、回退后重开（ROLLED_BACK）、
    # 或驳回/换版释放预算后重新占用（IN_PROGRESS 且无有效锁）。
    # 已结算或有待决验收单（SUBMITTED）的阶段不允许重新开工。
    existing_lock = State.lock_for(state, line_id, code)

    cond do
      phase.status in ["SUBMITTED", "ACCEPTED"] ->
        raise DomainError.new(
                "PHASE_NOT_STARTABLE",
                "阶段当前状态为「#{phase_status_cn(phase.status)}」，不能开工"
              )

      phase.status not in ["PLANNED", "ROLLED_BACK", "IN_PROGRESS"] ->
        raise DomainError.new("PHASE_NOT_STARTABLE", "阶段当前状态 #{phase.status}，不能开工")

      existing_lock && existing_lock.status == "LOCKED" ->
        raise DomainError.new("BUDGET_ALREADY_LOCKED", "该阶段预算已锁定")

      existing_lock && existing_lock.status == "SETTLED" ->
        raise DomainError.new("PHASE_ALREADY_SETTLED", "该阶段已结算，不能重复开工")

      true ->
        :ok
    end

    # 前置验收依赖：默认前一阶段；被回滚的前置不满足
    with dep when not is_nil(dep) <- dependency_of(state, phase) do
      dep_phase = State.phase!(state, line_id, dep)

      if dep_phase.status != "ACCEPTED" do
        raise DomainError.new(
                "PREDECESSOR_NOT_ACCEPTED",
                "前置阶段 #{dep} 尚未验收通过（当前 #{phase_status_cn(dep_phase.status)}），#{code} 不能开工"
              )
      end
    end

    reserve = div(quote.fee_cents * quote.reserve_rate_bp, 10_000)
    summary = State.budget_summary(state, line_id)

    if summary.main_available_cents < quote.fee_cents do
      raise DomainError.new(
              "BUDGET_EXCEEDED",
              "主预算不足：本阶段费 #{Util.format_yuan(quote.fee_cents)}，可用仅 #{Util.format_yuan(summary.main_available_cents)}"
            )
    end

    if summary.risk_available_cents < reserve do
      raise DomainError.new(
              "RISK_BUDGET_EXCEEDED",
              "风险储备不足：需 #{Util.format_yuan(reserve)}，风险池可用 #{Util.format_yuan(summary.risk_available_cents)}"
            )
    end

    lock_seq = next_lock_seq(state)

    lock_ev =
      base(idem && "#{idem}:lock", Events.budget_locked(), %{
        line_id: line_id,
        code: code,
        quote_id: quote.id,
        contract_version: contract.version,
        fee_cents: quote.fee_cents,
        reserve_cents: reserve,
        lock_seq: lock_seq,
        at: Util.now_iso()
      })

    start_ev =
      base(nil, Events.phase_started(), %{
        line_id: line_id,
        code: code,
        at: Util.now_iso()
      })

    {[lock_ev, start_ev],
     %{
       line_id: line_id,
       code: code,
       locked_fee_cents: quote.fee_cents,
       locked_reserve_cents: reserve,
       contract_version: contract.version
     }}
  end

  # ─────────────── 验收提交（并发闸门） ───────────────

  defp __decide(state, :submit_acceptance, p, idem) do
    line_id = p[:line_id]
    code = p[:code]
    phase = State.phase!(state, line_id, code)
    contract = require_contract!(state, line_id)
    quote = state.quotes[contract.quote_id]

    vendor_id = p[:vendor_id] || raise(DomainError, "缺少 vendor_id")

    if vendor_id != quote.vendor_id do
      raise DomainError.new(
              "VENDOR_NOT_CONTRACTED",
              "当前有效合同的服务商是 #{quote.vendor_id}，#{vendor_id} 无权提交验收"
            )
    end

    # 阶段处于实施中或已提交待决时都允许提交：待决单先作废，以最新一次为准
    # （服务商并发提交、离线补传覆盖都走同一条路径）
    if phase.status not in ["IN_PROGRESS", "SUBMITTED"] do
      raise DomainError.new(
              "PHASE_NOT_SUBMITTABLE",
              "阶段当前状态为「#{phase_status_cn(phase.status)}」，不能提交验收"
            )
    end

    captured_at = p[:captured_at] || Util.date_iso(Util.today())
    validate_date!(captured_at)

    if Date.from_iso8601!(captured_at) > Util.today() do
      raise DomainError.new("FUTURE_CAPTURE", "离线验收的实测日期不能晚于今天")
    end

    device_ids = p[:device_ids] || []
    check_capabilities!(state, phase, device_ids)

    sub_id = "S-" <> rand_hex(6)

    # 旧待决单先作废（同一阶段重新提交/补传）
    old_pending =
      phase.submissions
      |> Enum.filter(&(&1.status == "PENDING"))
      |> Enum.map(& &1.id)

    supersede_events =
      Enum.map(old_pending, fn sid ->
        base(nil, Events.submission_superseded(), %{
          line_id: line_id,
          code: code,
          submission_id: sid,
          at: Util.now_iso()
        })
      end)

    ev =
      base(idem, Events.acceptance_submitted(), %{
        submission_id: sub_id,
        line_id: line_id,
        code: code,
        vendor_id: vendor_id,
        contract_version: contract.version,
        quote_id: quote.id,
        device_ids: device_ids,
        captured_at: captured_at,
        submitted_at: Util.now_iso(),
        evidence_ref: p[:evidence_ref],
        offline: p[:offline] || false,
        at: Util.now_iso()
      })

    {supersede_events ++ [ev],
     %{
       submission_id: sub_id,
       superseded: old_pending,
       contract_version: contract.version,
       offline: p[:offline] || false
     }}
  end

  # ─────────────── 批准（能力不兼容 → 系统驳回；预算竞争 → 胜者通吃） ───────────────

  defp __decide(state, :approve, p, idem) do
    sid = p[:submission_id] || raise(DomainError, "缺少 submission_id")
    sub = State.submission!(state, sid)

    if sub.status != "PENDING" do
      raise DomainError.new(
              "SUBMISSION_NOT_PENDING",
              "验收单已是「#{submission_status_cn(sub.status)}」状态，不能批准"
            )
    end

    # 任一闸门不通过 → 系统自动驳回（旧合同版本/前置已回滚/能力不兼容/预算版本不符）
    case approval_gate(state, sub) do
      :ok -> finalize_approval(state, sub, idem)
      {:auto_reject, code, message} -> auto_reject_events(state, sub, code, message, idem)
    end
  end

  defp approval_gate(state, sub) do
    line = State.line!(state, sub.line_id)
    phase = State.phase!(state, sub.line_id, sub.code)
    current = line.active_contract

    cond do
      is_nil(current) ->
        {:auto_reject, "NO_CONTRACT", "有效合同已不存在，系统驳回该验收单"}

      current.version != sub.contract_version ->
        {:auto_reject, "CONTRACT_STALE",
         "合同已换版（当前 #{current.version}），验收单基于旧版本 #{sub.contract_version}，系统驳回"}

      true ->
        check_predecessor(state, phase)
    end
  end

  defp check_predecessor(state, phase) do
    case dependency_of(state, phase) do
      nil ->
        check_approval_capability(state, phase)

      dep ->
        dep_phase = State.phase!(state, phase.line_id, dep)

        if dep_phase.status == "ACCEPTED" do
          check_approval_capability(state, phase)
        else
          {:auto_reject, "PREDECESSOR_ROLLED_BACK",
           "前置阶段 #{dep} 已回退（#{phase_status_cn(dep_phase.status)}），验收前置条件失效，系统驳回"}
        end
    end
  end

  defp check_approval_capability(state, phase) do
    sub = State.submission!(state, phase.current_submission_id)

    try do
      check_capabilities!(state, phase, sub.device_ids)
      check_lock(state, sub)
    rescue
      e in DomainError ->
        {:auto_reject, e.code, "系统驳回：#{e.message}"}
    end
  end

  defp check_lock(state, sub) do
    lock = State.lock_for(state, sub.line_id, sub.code)

    cond do
      is_nil(lock) or lock.status not in ["LOCKED", "SETTLED"] ->
        raise DomainError.new("BUDGET_NOT_LOCKED", "阶段预算未锁定，不能批准")

      lock.contract_version != sub.contract_version ->
        raise DomainError.new(
                "CONTRACT_STALE",
                "预算锁定在合同 #{lock.contract_version}，验收单属于 #{sub.contract_version}"
              )

      true ->
        :ok
    end
  end

  defp finalize_approval(state, sub, idem) do
    line_id = sub.line_id
    code = sub.code
    phase = State.phase!(state, line_id, code)
    quote = state.quotes[sub.quote_id]
    captured = Date.from_iso8601!(sub.captured_at)
    planned = Date.from_iso8601!(phase.planned_done_date)

    # 延期罚则：按实测/补传日期计算（离线补传晚到不改变延期天数口径）
    overdue_days = max(0, Util.days_between(planned, captured))
    penalty = calc_penalty(quote, overdue_days)
    fee = quote.fee_cents
    payable = fee - penalty

    # 跨月费用：开工日→实测完成日按自然月拆分，合计恒等于合同费用
    monthly = monthly_settlement(phase, captured, fee)
    po_id = "PO-" <> rand_hex(8)

    settle_ev =
      base(idem && "#{idem}:settle", Events.budget_settled(), %{
        line_id: line_id,
        code: code,
        quote_id: quote.id,
        submission_id: sub.id,
        fee_cents: fee,
        penalty_cents: penalty,
        overdue_days: overdue_days,
        monthly: monthly,
        at: Util.now_iso()
      })

    approve_ev =
      base(nil, Events.acceptance_approved(), %{
        line_id: line_id,
        code: code,
        submission_id: sub.id,
        vendor_id: sub.vendor_id,
        contract_version: sub.contract_version,
        po_id: po_id,
        accepted_date: sub.captured_at,
        at: Util.now_iso()
      })

    po_ev =
      base(nil, Events.po_created(), %{
        po_id: po_id,
        line_id: line_id,
        code: code,
        submission_id: sub.id,
        vendor_id: sub.vendor_id,
        amount_cents: payable,
        fee_cents: fee,
        penalty_cents: penalty,
        contract_version: sub.contract_version,
        idempotency_key: "po:#{po_id}",
        at: Util.now_iso()
      })

    {[settle_ev, approve_ev, po_ev],
     %{
       approved: true,
       submission_id: sub.id,
       po_id: po_id,
       fee_cents: fee,
       penalty_cents: penalty,
       overdue_days: overdue_days,
       payable_cents: payable,
       monthly: monthly,
       safe_node: code
     }}
  end

  defp __decide(state, :reject, p, idem) do
    sid = p[:submission_id] || raise(DomainError, "缺少 submission_id")
    sub = State.submission!(state, sid)

    if sub.status != "PENDING",
      do: raise(DomainError.new("SUBMISSION_NOT_PENDING", "验收单不是待决状态"))

    reason = p[:reason] || "厂长驳回"
    code = p[:reason_code] || "MANAGER_REJECTED"

    auto_reject_events(state, sub, code, reason, idem)
  end

  # ─────────────── 回滚：退回到指定的已验收安全节点（含其后所有节点） ───────────────

  defp __decide(state, :rollback, p, idem) do
    line_id = p[:line_id]
    target = State.phase!(state, line_id, p[:code])

    if target.status != "ACCEPTED" do
      raise DomainError.new(
              "NOT_SAFE_NODE",
              "「#{target.code}」当前不是已验收安全节点（#{phase_status_cn(target.status)}），不能作为回退目标"
            )
    end

    # 回退到 target 意味着 target 及之后所有已验收节点全部撤销，预算红冲、安全节点重设
    later =
      State.phases_of(state, line_id)
      |> Enum.filter(&(&1.order >= target.order and &1.status in ["ACCEPTED", "ROLLED_BACK", "SUBMITTED", "IN_PROGRESS"]))

    accepted_later = Enum.filter(later, &(&1.status == "ACCEPTED"))
    safe_nodes_before =
      State.phases_of(state, line_id)
      |> Enum.filter(&(&1.order < target.order and &1.status == "ACCEPTED"))
      |> Enum.map(& &1.code)

    rollback_id = "RB-" <> rand_hex(6)

    # 已验收节点：预算红冲 + 节点撤销
    accepted_events =
      Enum.flat_map(accepted_later, fn ph ->
        [
          base(nil, Events.budget_reversed(), %{
            line_id: line_id,
            code: ph.code,
            rollback_event_id: rollback_id,
            at: Util.now_iso()
          }),
          base(nil, Events.phase_rolled_back(), %{
            line_id: line_id,
            code: ph.code,
            reason: p[:reason] || "回退至安全节点",
            rollback_event_id: rollback_id,
            at: Util.now_iso()
          })
        ]
      end)

    # 更晚的未验收阶段（实施中/待验收）：待决单作废、占用的预算释放，
    # 阶段回到 ROLLED_BACK 状态，等待按新安全节点重新开工
    trailing =
      later
      |> Enum.filter(&(&1.status in ["IN_PROGRESS", "SUBMITTED"]))

    trailing_events =
      Enum.flat_map(trailing, fn ph ->
        pending_supersede =
          ph.submissions
          |> Enum.filter(&(&1.status == "PENDING"))
          |> Enum.map(fn s ->
            base(nil, Events.submission_superseded(), %{
              line_id: line_id,
              code: ph.code,
              submission_id: s.id,
              at: Util.now_iso()
            })
          end)

        release =
          case State.lock_for(state, line_id, ph.code) do
            %{status: "LOCKED"} ->
              [
                base(nil, Events.budget_lock_released(), %{
                  line_id: line_id,
                  code: ph.code,
                  reason: "rollback:#{rollback_id}",
                  at: Util.now_iso()
                })
              ]

            _ ->
              []
          end

        rb_ev =
          base(nil, Events.phase_rolled_back(), %{
            line_id: line_id,
            code: ph.code,
            reason: p[:reason] || "前置安全节点回退",
            rollback_event_id: rollback_id,
            at: Util.now_iso()
          })

        pending_supersede ++ release ++ [rb_ev]
      end)

    events = accepted_events ++ trailing_events

    # 命令级幂等键挂在最后一个事件上即可（整批原子落盘）
    events = attach_idem(events, idem)

    new_safe = List.last(safe_nodes_before)

    {events,
     %{
       line_id: line_id,
       rolled_back_to: new_safe || :origin,
       rolled_back_phases: Enum.map(accepted_later ++ trailing, & &1.code),
       reversed_settlement_phases: Enum.map(accepted_later, & &1.code),
       remaining_safe_nodes: safe_nodes_before,
       rollback_event_id: rollback_id,
       note: if(new_safe, do: "产线已退回到安全节点 #{new_safe}", else: "产线已退回到改造前的初始状态")
     }}
  end

  # ─────────────── 外部采购回执（幂等补偿） ───────────────

  defp __decide(state, :receive_receipt, p, idem) do
    po_id = p[:po_id] || raise(DomainError, "缺少 po_id")
    po = state.outbox[po_id] || raise(DomainError.not_found("采购单"))
    key = idem || "receipt:#{po_id}:#{p[:status]}:#{p[:external_ref] || "x"}"

    cond do
      Map.has_key?(state.inbox, key) ->
        {[], %{duplicate: true, po_id: po_id}}

      p[:status] == "CONFIRMED" and po.status in ["PENDING_CONFIRM", "CONFIRMED"] ->
        ev =
          base(key, Events.po_confirmed(), %{
            po_id: po_id,
            external_ref: p[:external_ref] || "EXT-#{po_id}",
            at: Util.now_iso()
          })

        {[ev], %{po_id: po_id, status: "CONFIRMED"}}

      p[:status] == "REJECTED" and po.status in ["PENDING_CONFIRM", "REJECTED"] ->
        # 采购侧拒绝/超时：走补偿——冲销采购单，业务上该验收保持“已验收”，
        # 但财务侧标记需要人工处理；预算结算不自动回滚（验收事实仍成立）。
        comp_ref = "CMP-" <> rand_hex(6)

        reject_ev =
          base(nil, Events.po_rejected(), %{
            po_id: po_id,
            line_id: po.line_id,
            code: po.code,
            reason: p[:reason] || "采购系统拒单",
            at: Util.now_iso()
          })

        comp_ev =
          base(key, Events.po_compensated(), %{
            po_id: po_id,
            line_id: po.line_id,
            code: po.code,
            compensation_ref: comp_ref,
            idempotency_key: key,
            at: Util.now_iso()
          })

        {[reject_ev, comp_ev],
         %{po_id: po_id, status: "COMPENSATED", compensation_ref: comp_ref}}

      true ->
        raise DomainError.new(
                "RECEIPT_STATUS_CONFLICT",
                "采购单当前状态 #{po.status}，无法接收 #{p[:status]} 回执"
              )
    end
  end

  # ───────────────────────────── 系统驳回（能力不兼容等） ─────────────────────────────

  defp auto_reject_events(state, sub, code, message, idem) do
    reject_ev =
      base(idem && "#{idem}:reject", Events.acceptance_rejected(), %{
        line_id: sub.line_id,
        code: sub.code,
        submission_id: sub.id,
        reason_code: code,
        reason: message,
        at: Util.now_iso()
      })

    # 预算锁释放（驳回后钱回到池子里，可用于整改后再开工/再提交）
    release_ev =
      case State.lock_for(state, sub.line_id, sub.code) do
        %{status: "LOCKED"} ->
          [
            base(nil, Events.budget_lock_released(), %{
              line_id: sub.line_id,
              code: sub.code,
              reason: "reject:#{sub.id}",
              at: Util.now_iso()
            })
          ]

        _ ->
          []
      end

    {[reject_ev] ++ release_ev,
     %{
       approved: false,
       auto_rejected: code not in ["MANAGER_REJECTED"],
       submission_id: sub.id,
       reason_code: code,
       reason: message
     }}
  end

  # ───────────────────────────── 规则小函数 ─────────────────────────────

  defp require_contract!(state, line_id) do
    State.active_contract(state, line_id) ||
      raise DomainError.new("NO_CONTRACT", "产线尚无有效合同版本，无法推进")
  end

  # 阶段依赖：显式 depends_on 优先，否则取顺序上的前一阶段
  defp dependency_of(state, phase) do
    case phase do
      %{depends_on: dep} when not is_nil(dep) -> dep
      _ ->
        prev =
          State.phases_of(state, phase.line_id)
          |> Enum.filter(&(&1.order < phase.order))
          |> Enum.max_by(& &1.order, fn -> nil end)

        prev && prev.code
    end
  end

  defp check_capabilities!(state, phase, device_ids) do
    if device_ids == [] do
      raise DomainError.new("NO_DEVICES", "验收必须附带设备清单")
    end

    devices =
      Enum.map(device_ids, fn id ->
        state.devices[id] || raise DomainError.new("DEVICE_UNKNOWN", "设备不在能力清单中：#{id}")
      end)

    Enum.each(devices, fn d ->
      if d.line_id != phase.line_id,
        do: raise(DomainError.new("DEVICE_LINE_MISMATCH", "设备 #{d.id} 不属于本产线"))
    end)

    provided =
      devices
      |> Enum.map(& &1.provides)
      |> Enum.reduce(MapSet.new(), &MapSet.union/2)

    missing = MapSet.difference(phase.needs, provided)

    unless Enum.empty?(missing) do
      raise DomainError.new(
              "CAPABILITY_MISMATCH",
              "设备能力不满足阶段要求，缺少：#{Enum.join(missing, "、")}"
            )
    end

    # 固件版本门槛：任一设备固件低于最低要求即判定能力不兼容
    bad_fw =
      devices
      |> Enum.filter(fn d -> ver_cmp(d.firmware, phase.min_firmware) == :lt end)

    unless bad_fw == [] do
      raise DomainError.new(
              "FIRMWARE_TOO_OLD",
              "设备固件低于 #{phase.min_firmware}：#{Enum.map(bad_fw, & &1.id) |> Enum.join("、")}"
            )
    end
  end

  defp calc_penalty(quote, overdue_days) do
    raw = div(quote.fee_cents * quote.penalty_rate_bp_per_day * overdue_days, 10_000)
    cap = div(quote.fee_cents * quote.penalty_cap_bp, 10_000)
    min(raw, cap)
  end

  # 跨月费用拆分：
  # * 按期或提前（captured <= 计划完成日）：费用全额计入计划完成日所在账期（1 天）；
  # * 延期：从计划完成日到实际完成日按自然月、按天均摊，
  #   最后一个账期吸收取整余差，保证合计恒等于合同费用。
  defp monthly_settlement(phase, captured, fee_cents) do
    planned = Date.from_iso8601!(phase.planned_done_date)

    if Date.compare(captured, planned) != :gt do
      [%{"period" => Util.period_key(planned), "days" => 1, "amount_cents" => fee_cents}]
    else
      segs = Util.split_by_month(planned, captured)
      total_days = Enum.reduce(segs, 0, fn {_, _, d}, acc -> acc + d end)

      {monthly, allocated} =
        Enum.reduce(segs, {[], 0}, fn {seg_start, _seg_end, days}, {acc, alloc} ->
          amount = div(fee_cents * days, total_days)
          period = Util.period_key(seg_start)
          entry = %{"period" => period, "days" => days, "amount_cents" => amount}
          {[entry | acc], alloc + amount}
        end)

      monthly = Enum.reverse(monthly)

      # 余差并入最后一个账期（按天整除的余数，保证合计恒等于费用）
      List.update_at(monthly, -1, fn m ->
        Map.put(m, "amount_cents", m["amount_cents"] + (fee_cents - allocated))
      end)
    end
  end

  defp next_lock_seq(state) do
    (state.locks |> Map.values() |> Enum.map(& &1.seq) |> Enum.max(fn -> 0 end)) + 1
  end

  # 事件一律使用字符串键（JSON 形态）：落盘与重放读模型都按 string 键访问。
  defp base(idem, type, payload) do
    payload
    |> stringify_keys()
    |> Map.put("type", type)
    |> maybe_put("idempotency_key", idem)
  end

  defp stringify_keys(%Date{} = d), do: Date.to_iso8601(d)
  defp stringify_keys(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), stringify_keys(v)}
      {k, v} when is_binary(k) -> {k, stringify_keys(v)}
    end)
  end

  defp stringify_keys(list) when is_list(list) do
    Enum.map(list, &stringify_keys/1)
  end

  defp stringify_keys(other), do: other

  defp maybe_put(map, _k, nil), do: map
  defp maybe_put(map, k, v), do: Map.put(map, k, v)

  defp attach_idem(events, nil), do: events
  defp attach_idem(events, idem), do: List.update_at(events, -1, &Map.put(&1, "idempotency_key", idem))

  defp rand_hex(n) do
    n |> div(2) |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
  end

  defp validate_date!(s) do
    case Date.from_iso8601(s) do
      {:ok, _} -> :ok
      _ -> raise DomainError.new("BAD_DATE", "日期格式应为 yyyy-mm-dd：#{s}")
    end
  end

  # 只把白名单内的 JSON 键转成 atom，避免外部输入污染 atom 表
  @known_keys ~w(
    idempotency_key line_id line_name name device_id kind model provides firmware
    code order needs min_firmware planned_done_date depends_on
    quote_id vendor_id version reserve_rate_bp penalty_rate_bp_per_day
    penalty_cap_bp payment_days note valid_from force fee_cents main_budget_cents
    risk_budget_cents captured_at device_ids evidence_ref offline
    submission_id reason reason_code status external_ref reason po_id
  )

  defp atomize(params) when is_map(params) do
    Map.new(params, fn {k, v} ->
      if is_binary(k) and k in @known_keys, do: {String.to_atom(k), v}, else: {k, v}
    end)
  end

  defp atomize(params), do: params

  # ───────────────────────────── 视图 ─────────────────────────────

  defp boards(s) do
    s.state.lines
    |> Map.keys()
    |> Enum.sort()
    |> Enum.map(&board_for(s.state, &1))
  end

  defp board_for(state, line_id) do
    line = State.line!(state, line_id)
    quote = State.active_quote(state, line_id)
    phases = State.phases_of(state, line_id)

    accepted = phases |> Enum.filter(&(&1.status == "ACCEPTED"))
    safe = List.last(accepted)

    next_phase =
      phases
      |> Enum.filter(&(&1.status in ["PLANNED", "IN_PROGRESS", "SUBMITTED", "ROLLED_BACK"]))
      |> Enum.min_by(& &1.order, fn -> nil end)

    {can_continue, blockers} =
      analyze_next(state, line_id, next_phase)

    locks =
      state.locks
      |> Map.values()
      |> Enum.filter(&(&1.line_id == line_id and &1.status == "LOCKED"))
      |> Enum.map(fn l ->
        %{
          phase: l.code,
          fee_cents: l.fee_cents,
          reserve_cents: l.reserve_cents,
          contract_version: l.contract_version
        }
      end)

    %{
      line_id: line_id,
      line_name: line.name,
      contract_version: line.active_contract && line.active_contract.version,
      vendor_id: quote && quote.vendor_id,
      phases:
        Enum.map(phases, fn p ->
          %{
            code: p.code,
            name: p.name,
            status: p.status,
            status_cn: phase_status_cn(p.status),
            safe_node: p.safe_node,
            current_submission: brief_sub(p)
          }
        end),
      safe_node: safe && safe.code,
      safe_node_cn: safe_node_text(safe),
      next_action_phase: next_phase && next_phase.code,
      can_continue: can_continue,
      blockers: blockers,
      locked_budget: locks
    }
  end

  defp brief_sub(%{current_submission_id: nil}), do: nil

  defp brief_sub(p) do
    s = Enum.find(p.submissions, &(&1.id == p.current_submission_id))
    s && %{id: s.id, status: s.status, vendor_id: s.vendor_id, captured_at: s.captured_at, offline: s.offline}
  end

  defp safe_node_text(nil), do: "改造前初始状态（尚无已验收节点）"
  defp safe_node_text(p), do: "#{p.code} #{p.name}（已验收）"

  defp analyze_next(_state, _line_id, nil), do: {false, ["所有阶段均已验收完成"]}

  defp analyze_next(state, line_id, phase) do
    blockers =
      []
      |> Kernel.++(if is_nil(State.active_contract(state, line_id)), do: ["尚无有效合同版本"], else: [])
      |> Kernel.++(
        case phase.status do
          "PLANNED" ->
            dep_blocker(state, phase) ++ budget_blocker(state, phase)

          "ROLLED_BACK" ->
            ["该节点已被回退，需重新开工（预算将重新占用）"]

          "IN_PROGRESS" ->
            ["等待服务商提交验收"]

          "SUBMITTED" ->
            ["等待厂长批准/驳回"] ++ stale_blocker(state, phase)

          _ ->
            []
        end
      )

    {blockers == [], blockers}
  end

  defp dep_blocker(state, phase) do
    with dep when not is_nil(dep) <- dependency_of(state, phase) do
      dep_phase = State.phase!(state, phase.line_id, dep)

      if dep_phase.status == "ACCEPTED",
        do: [],
        else: ["前置阶段 #{dep} 未验收（#{phase_status_cn(dep_phase.status)}）"]
    else
      _ -> []
    end
  end

  defp budget_blocker(state, phase) do
    quote = State.active_quote(state, phase.line_id)
    summary = State.budget_summary(state, phase.line_id)

    if quote do
      reserve = div(quote.fee_cents * quote.reserve_rate_bp, 10_000)

      cond do
        summary.main_available_cents < quote.fee_cents ->
          ["主预算不足：需 #{Util.format_yuan(quote.fee_cents)}，可用 #{Util.format_yuan(summary.main_available_cents)}"]

        summary.risk_available_cents < reserve ->
          ["风险储备不足：需 #{Util.format_yuan(reserve)}，可用 #{Util.format_yuan(summary.risk_available_cents)}"]

        true ->
          []
      end
    else
      ["当前合同无对应报价"]
    end
  end

  defp stale_blocker(state, phase) do
    sub_id = phase.current_submission_id

    if sub_id do
      sub = State.submission!(state, sub_id)
      current = State.active_contract(state, phase.line_id)

      if current && current.version != sub.contract_version,
        do: ["验收单基于旧合同 #{sub.contract_version}，必须驳回后重新提交"],
        else: []
    else
      []
    end
  end

  defp budget_view(state) do
    per_line =
      state.lines
      |> Map.keys()
      |> Enum.sort()
      |> Enum.map(fn line_id ->
        s = State.budget_summary(state, line_id)
        Map.put(s, :line_name, state.lines[line_id].name)
      end)

    summary = State.global_budget_summary(state)

    monthly =
      state.entries
      |> Enum.filter(&(&1.type in ["SETTLE", "REVERSAL"]))
      |> Enum.group_by(&{&1.line_id, &1.period})
      |> Enum.map(fn {{line_id, period}, list} ->
        %{
          line_id: line_id,
          period: period,
          net_cents: Enum.sum(Enum.map(list, & &1.amount_cents))
        }
      end)
      |> Enum.sort_by(&{&1.line_id, &1.period})

    %{
      summary: summary,
      summary_cn: %{
        main_total: Util.format_yuan(summary.main_total_cents),
        main_locked: Util.format_yuan(summary.main_locked_cents),
        main_consumed: Util.format_yuan(summary.main_consumed_cents),
        main_available: Util.format_yuan(summary.main_available_cents),
        risk_total: Util.format_yuan(summary.risk_total_cents),
        risk_locked: Util.format_yuan(summary.risk_locked_cents),
        risk_available: Util.format_yuan(summary.risk_available_cents)
      },
      monthly: monthly,
      per_line: per_line,
      locks:
        state.locks
        |> Map.values()
        |> Enum.filter(&(&1.status == "LOCKED"))
        |> Enum.map(fn l ->
          %{line_id: l.line_id, phase: l.code, fee_cents: l.fee_cents, reserve_cents: l.reserve_cents}
        end)
    }
  end

  defp audit_view(s, opts) do
    # 直接从日志文件按 seq 读取——审计视图与落盘事件严格一致
    line_id = opts[:line_id]

    Journal.replay(s.journal, [], fn acc, ev, envelope ->
      if is_nil(line_id) or ev["line_id"] == line_id do
        acc ++
          [
            %{
              seq: envelope["seq"],
              at: envelope["at"],
              type: ev["type"],
              line_id: ev["line_id"],
              code: ev["code"],
              detail: ev
            }
          ]
      else
        acc
      end
    end)
    |> then(fn events -> maybe_take(events, opts[:limit]) end)
  end

  defp maybe_take(events, nil), do: events
  defp maybe_take(events, n), do: Enum.take(events, -n)

  # 重启后重放：命令级幂等键首次出现的事件即该命令的“事实结果”，
  # 再次收到同键请求时回放它，绝不二次推进或二次扣款。
  defp replay_result(%{"type" => type} = ev) do
    case type do
      "line_registered" -> %{line_id: ev["line_id"]}
      "device_registered" -> %{device_id: ev["device_id"]}
      "phase_planned" -> %{line_id: ev["line_id"], code: ev["code"]}
      "quote_recorded" -> %{quote_id: ev["quote_id"]}
      "contract_superseded" -> %{contract_id: ev["contract_id"], version: ev["version"]}
      "phase_started" -> %{line_id: ev["line_id"], code: ev["code"], restarted: true}
      "acceptance_submitted" -> %{submission_id: ev["submission_id"], replay: true}
      "acceptance_approved" -> %{approved: true, submission_id: ev["submission_id"], po_id: ev["po_id"], replay: true}
      "acceptance_rejected" -> %{approved: false, submission_id: ev["submission_id"], reason_code: ev["reason_code"], replay: true}
      "phase_rolled_back" -> %{line_id: ev["line_id"], code: ev["code"], replay: true}
      "po_confirmed" -> %{po_id: ev["po_id"], status: "CONFIRMED", replay: true}
      "po_compensated" -> %{po_id: ev["po_id"], status: "COMPENSATED", replay: true}
      _ -> %{replay: true}
    end
  end

  @doc false
  # 宽松版本号比较：同时兼容 "v2"、"2"、"2.1.0" 这类合同版本写法。
  # 返回 :lt | :eq | :gt。
  def ver_cmp(a, b) when is_binary(a) and is_binary(b) do
    ta = a |> strip_v() |> parse_ver()
    tb = b |> strip_v() |> parse_ver()
    len = max(tuple_size(ta), tuple_size(tb))
    ta = pad_tuple(ta, len)
    tb = pad_tuple(tb, len)

    cond do
      ta < tb -> :lt
      ta > tb -> :gt
      true -> :eq
    end
  end

  # 去掉开头的版本前缀（v/V/version-），trim_leading 不能用（它按字符集裁剪）
  defp strip_v(<<"v", rest::binary>>), do: rest
  defp strip_v(<<"V", rest::binary>>), do: rest
  defp strip_v(other), do: other

  defp pad_tuple(t, len) do
    t
    |> Tuple.to_list()
    |> Kernel.++(List.duplicate(0, len - tuple_size(t)))
    |> List.to_tuple()
  end

  defp parse_ver(s) do
    s
    |> String.split(".")
    |> Enum.map(fn part ->
      case Integer.parse(part) do
        {n, _} -> n
        :error -> 0
      end
    end)
    |> List.to_tuple()
  end

  defp phase_status_cn("PLANNED"), do: "待开工"
  defp phase_status_cn("IN_PROGRESS"), do: "实施中"
  defp phase_status_cn("SUBMITTED"), do: "待验收"
  defp phase_status_cn("ACCEPTED"), do: "已验收"
  defp phase_status_cn("REJECTED"), do: "已驳回"
  defp phase_status_cn("ROLLED_BACK"), do: "已回退"
  defp phase_status_cn(other), do: other

  defp submission_status_cn("PENDING"), do: "待决"
  defp submission_status_cn("APPROVED"), do: "已批准"
  defp submission_status_cn("REJECTED"), do: "已驳回"
  defp submission_status_cn("SUPERSEDED"), do: "已作废"
  defp submission_status_cn(other), do: other
end
