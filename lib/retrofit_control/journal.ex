defmodule RetrofitControl.Journal do
  @moduledoc """
  仅追加（append-only）持久化事件日志——整套系统的唯一事实源。

  设计要点：
  * 每条事件一行 JSON，写入后立即 `File.sync!/1`（fsync），宕机/断电不丢已确认操作；
  * 启动时先加载快照再顺序重放事件，天然支持“服务重启保持一致”与断点恢复；
  * 所有状态变更（批准/驳回/回滚/预算占用/合同换版/采购补偿……）都是事件，
    审计视图直接读取事件，因此审计不可能与业务状态不一致；
  * 最后一行若因崩溃写坏（截断的 JSON），启动时自动截掉并另存 `.corrupt` 备查。
  """

  use GenServer

  require Logger

  @enforce_keys [:dir, :log_path, :file, :seq]
  defstruct [:dir, :log_path, :file, :seq]

  # ── 客户端 API ─────────────────────────────────────────────────────

  def start_link(opts) when is_list(opts) do
    name = opts[:name] || __MODULE__
    GenServer.start_link(__MODULE__, Map.new(opts), name: name)
  end

  def start_link(opts) when is_map(opts) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)
  end

  @doc """
  原子地完成“决定 + 落盘”：由调用方传入函数，在 Journal 进程内串行执行，
  返回 `{:ok, result}`。回调返回 `{:ok, events, result}` 或 `{:error, reason}`。
  多服务商并发提交因此被串行化裁决，不会出现脏读/丢更新。
  clock 为时钟 Agent 名（测试虚拟时间用）。
  """
  def commit(server \\ __MODULE__, fun, clock \\ nil) when is_function(fun, 0) do
    GenServer.call(server, {:commit, fun, clock}, :infinity)
  end

  @doc "重放日志构建状态（供测试与恢复核对使用）。"
  def replay(server \\ __MODULE__, initial, apply_fun) do
    GenServer.call(server, {:replay, initial, apply_fun}, :infinity)
  end

  def seq(server \\ __MODULE__) do
    GenServer.call(server, :seq)
  end

  def log_path(server \\ __MODULE__) do
    GenServer.call(server, :log_path)
  end

  # ── GenServer 回调 ─────────────────────────────────────────────────

  @impl true
  def init(opts) do
    dir = opts[:dir] || Path.join("data", "default")
    File.mkdir_p!(dir)
    log_path = Path.join(dir, "events.log")

    state = %__MODULE__{
      dir: dir,
      log_path: log_path,
      file: File.open!(log_path, [:append, :raw, :binary]),
      seq: 0
    }

    state = repair_torn_tail(state)
    {:ok, state}
  end

  @impl true
  def handle_call({:commit, fun, clock}, _from, state) do
    outcome =
      RetrofitControl.Util.with_clock_fun(clock_fun(clock), fn ->
        fun.()
      end)

    case outcome do
      {:ok, events, result} when is_list(events) ->
        state = Enum.reduce(events, state, fn ev, acc -> append(acc, ev) end)
        {:reply, {:ok, events, result}, state}

      {:ok, result} ->
        {:reply, {:ok, [], result}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:replay, initial, apply_fun}, _from, state) do
    result =
      File.stream!(state.log_path, [:read], :line)
      |> Enum.reduce(initial, fn line, acc ->
        envelope = Jason.decode!(line)
        apply_fun.(acc, envelope["event"], envelope)
      end)

    {:reply, result, state}
  end

  def handle_call(:seq, _from, state), do: {:reply, state.seq, state}
  def handle_call(:log_path, _from, state), do: {:reply, state.log_path, state}

  # ── 内部实现 ───────────────────────────────────────────────────────

  defp append(state, event) do
    seq = state.seq + 1

    envelope = %{
      seq: seq,
      at: RetrofitControl.Util.now_iso(),
      event: event
    }

    :ok = IO.binwrite(state.file, Jason.encode!(envelope) <> "\n")
    :ok = :file.sync(state.file)
    %{state | seq: seq}
  end

  # 把时钟 Agent 的当前值转成进程字典函数；nil 表示走真实墙钟
  defp clock_fun(nil), do: nil

  defp clock_fun(clock_name) do
    fn ->
      case Agent.get(clock_name, & &1) do
        nil -> DateTime.utc_now()
        fun -> fun.()
      end
    end
  end

  @doc false
  # 日志最后一行若不是合法 JSON（进程被 kill -9 / 磁盘写满导致半截行），截掉它。
  # 由于每条事件都 fsync，历史行不可能损坏，需要检查的只有文件末尾。
  def repair_torn_tail(state) do
    case File.read(state.log_path) do
      {:ok, ""} ->
        state

      {:ok, content} ->
        {good_lines, last_line, seq} =
          content
          |> String.split("\n")
          |> scan_lines([], nil, 0)

        if last_line != "" do
          File.write!(state.log_path <> ".corrupt", last_line <> "\n", [:append])
          File.write!(state.log_path, Enum.join(good_lines, "\n") <> "\n")
          Logger.warning("检测到 1 行截断日志，已截除并保存至 events.log.corrupt")
        end

        %{state | seq: seq}

      {:error, _} ->
        state
    end
  end

  # 返回 {完整且合法的行, 末尾可能半截的行, 最后合法序号}
  defp scan_lines([], good, partial, seq),
    do: {Enum.reverse(good), partial || "", seq}

  defp scan_lines([""], good, partial, seq),
    do: {Enum.reverse(good), partial || "", seq}

  defp scan_lines([line | rest], good, _partial, seq) do
    case Jason.decode(line) do
      {:ok, %{"seq" => n}} -> scan_lines(rest, [line | good], "", n)
      {:error, _} -> {Enum.reverse(good), line, seq}
    end
  end
end
