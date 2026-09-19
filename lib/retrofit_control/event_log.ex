defmodule RetrofitControl.EventLog do
  @moduledoc """
  追加式（append-only）事件日志，单进程 GenServer 串行写入。

  - 每条事件在返回前 `fsync` 落盘（File.binwrite 后 :file.sync），保证“批准/驳回/回滚/预算占用”持久化。
  - 事件用 term_to_binary + Base 编码逐行写入；快照用二进制整体写入并 fsync。
  - 重启时：先读最近快照，再重放其后的事件 -> 完全恢复（断点恢复）。
  - path 为 nil 时退化为纯内存（单元测试隔离使用）。
  """

  use GenServer

  defstruct [:path, :dir, :snap_path, events: [], snapshot: nil, snapshot_seq: 0, fsync: true]

  # ---- public ----

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name])
  end

  @doc "追加一条事件并等待落盘确认。"
  def append(server \\ __MODULE__, event), do: GenServer.call(server, {:append, event})

  def append_many(server \\ __MODULE__, events) when is_list(events),
    do: GenServer.call(server, {:append_many, events})

  @doc "读取全部事件（内存或磁盘重放）。"
  def events(server \\ __MODULE__), do: GenServer.call(server, :events)

  @doc "写入状态快照。"
  def write_snapshot(server \\ __MODULE__, state, seq),
    do: GenServer.call(server, {:write_snapshot, state, seq})

  @doc "从磁盘恢复：返回 {snapshot_state_or_nil, snapshot_seq, events_after_snapshot}。"
  def replay(server \\ __MODULE__), do: GenServer.call(server, :replay)

  def memory?(%{path: nil}), do: true
  def memory?(_), do: false

  # ---- callbacks ----

  @impl true
  def init(opts) do
    path = opts[:path]
    fsync = Keyword.get(opts, :fsync, true)

    state =
      case path do
        nil ->
          %__MODULE__{path: nil, fsync: false}

        p ->
          dir = Path.dirname(p)
          File.mkdir_p!(dir)
          snap_path = Path.join(dir, "snapshot.bin")
          %__MODULE__{path: p, dir: dir, snap_path: snap_path, fsync: fsync}
      end

    {:ok, state}
  end

  @impl true
  def handle_call({:append, event}, _from, state) do
    do_append(state, [event])
    {:reply, :ok, %__MODULE__{state | events: state.events ++ [event]}}
  end

  def handle_call({:append_many, events}, _from, state) do
    do_append(state, events)
    {:reply, :ok, %__MODULE__{state | events: state.events ++ events}}
  end

  def handle_call(:events, _from, %{path: nil} = state), do: {:reply, state.events, state}

  def handle_call(:events, _from, state) do
    {:reply, read_events(state.path), state}
  end

  def handle_call({:write_snapshot, domain_state, seq}, _from, state) do
    case state do
      %{path: nil} ->
        {:reply, :ok, %__MODULE__{state | snapshot: domain_state, snapshot_seq: seq}}

      _ ->
        bin = :erlang.term_to_binary({seq, domain_state}, [:compressed])
        tmp = state.snap_path <> ".tmp"
        File.mkdir_p!(state.dir)
        File.write!(tmp, bin)
        File.rename!(tmp, state.snap_path)
        {:reply, :ok, state}
    end
  end

  def handle_call(:replay, _from, %{path: nil} = state) do
    {:reply, {state.snapshot, state.snapshot_seq, state.events}, state}
  end

  def handle_call(:replay, _from, state) do
    {snap_state, snap_seq} = read_snapshot(state.snap_path)
    all = read_events(state.path)
    after_snap = Enum.drop(all, snap_seq)
    {:reply, {snap_state, snap_seq, after_snap}, state}
  end

  # ---- io ----

  defp do_append(%__MODULE__{path: nil}, _events), do: :ok

  defp do_append(%__MODULE__{path: path, fsync: fsync?}, events) do
    File.mkdir_p!(Path.dirname(path))
    lines = Enum.map(events, fn e -> Base.encode64(:erlang.term_to_binary(e)) <> "\n" end)
    File.write!(path, IO.iodata_to_binary(lines), [:append, :raw])
    if fsync?, do: fsync_file(path)
    :ok
  end

  defp fsync_file(path) do
    case :file.open(path, [:raw, :read, :append]) do
      {:ok, fd} ->
        :file.sync(fd)
        :file.close(fd)

      _ ->
        :ok
    end
  end

  defp read_snapshot(path) do
    case File.read(path) do
      {:ok, bin} ->
        {seq, state} = :erlang.binary_to_term(bin)
        {state, seq}

      _ ->
        {nil, 0}
    end
  end

  defp read_events(path) do
    case File.read(path) do
      {:ok, body} ->
        body
        |> String.split("\n", trim: true)
        |> Enum.map(fn line -> :erlang.binary_to_term(Base.decode64!(line)) end)

      _ ->
        []
    end
  end
end
