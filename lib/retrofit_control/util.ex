defmodule RetrofitControl.Util do
  @moduledoc """
  通用工具：时间/金额/日期。

  所有业务代码取时间都走本模块，引擎内部允许注入时钟（测试跨月费用、
  离线补传、延期罚则时不依赖真实墙钟）。金额一律使用整数“分”，避免浮点误差。
  """

  use Agent

  @doc """
  启动可被替换的时钟（测试用）。生产环境始终读取真实 UTC 时间。
  每个引擎持有独立时钟进程，避免并发测试互相干扰。
  """
  def start_clock(name \\ __MODULE__.Clock) do
    if Process.whereis(name) do
      {:ok, Process.whereis(name)}
    else
      Agent.start_link(fn -> nil end, name: name)
    end
  end

  @doc "用固定/虚拟时间替换墙钟；nil 表示恢复真实时间。"
  def set_clock(fun_or_nil, name \\ __MODULE__.Clock)
      when is_function(fun_or_nil, 0) or is_nil(fun_or_nil) do
    Agent.update(name, fn _ -> fun_or_nil end)
  end

  @doc "当前 UTC 时间（DateTime）。优先级：进程字典时钟 > 命名时钟 Agent > 真实时间。"
  def now(name \\ __MODULE__.Clock) do
    case Process.get(:rc_clock_fun) do
      fun when is_function(fun, 0) ->
        fun.()

      _ ->
        fun =
          try do
            Agent.get(name, & &1)
          rescue
            _ -> nil
          end

        case fun do
          nil -> DateTime.utc_now()
          fun -> fun.()
        end
    end
  end

  @doc "在指定虚拟时钟函数下执行一段同步逻辑（用于 Journal 提交回调）。"
  def with_clock_fun(nil, block), do: block.()

  def with_clock_fun(fun, block) when is_function(fun, 0) do
    old = Process.get(:rc_clock_fun)
    Process.put(:rc_clock_fun, fun)

    try do
      block.()
    after
      case old do
        nil -> Process.delete(:rc_clock_fun)
        _ -> Process.put(:rc_clock_fun, old)
      end
    end
  end

  @doc "当前 ISO8601 字符串。"
  def now_iso(name \\ __MODULE__.Clock), do: DateTime.to_iso8601(now(name))

  @doc "当前业务日期（~D），以 UTC 计日。"
  def today(name \\ __MODULE__.Clock), do: DateTime.to_date(now(name))

  @doc "在虚拟时钟下执行一段代码，结束后恢复真实时间。"
  def with_virtual_clock(clock_name, date_or_fun, block) do
    fun =
      case date_or_fun do
        %Date{} ->
          fn -> DateTime.new!(date_or_fun, ~T[10:00:00.000000]) end

        f when is_function(f, 0) ->
          f
      end

    set_clock(fun, clock_name)

    try do
      block.()
    after
      set_clock(nil, clock_name)
    end
  end

  @doc "yyyy-mm-dd。"
  def date_iso(date), do: Date.to_iso8601(date)

  @doc "两个日期相差天数（to - from），可为负。"
  def days_between(%Date{} = from, %Date{} = to) do
    Date.diff(to, from)
  end

  @doc """
  将 [from, to] 区间（左闭右闭）按自然月切分。
  返回 [{月初, 月末日(实际区间端点), 天数}]，用于跨月费用拆分。
  例：2026-03-30..2026-04-02 -> [{~D[2026-03-30], ~D[2026-03-31], 2},
                                 {~D[2026-04-01], ~D[2026-04-02], 2}]
  """
  def split_by_month(%Date{} = from, %Date{} = to) do
    if Date.compare(to, from) == :lt, do: throw({:badarg, "结束日期早于开始日期"})

    do_split(from, to, [])
  end

  defp do_split(cursor, to, acc) do
    if Date.compare(cursor, to) == :gt do
      Enum.reverse(acc)
    else
      last_day = :calendar.last_day_of_the_month(cursor.year, cursor.month)
      month_end = Date.new!(cursor.year, cursor.month, last_day)
      seg_end = if Date.compare(month_end, to) == :gt, do: to, else: month_end
      days = Date.diff(seg_end, cursor) + 1
      do_split(Date.add(seg_end, 1), to, [{cursor, seg_end, days} | acc])
    end
  end

  @doc "yyyy-mm 形式的账期键。"
  def period_key(%Date{year: y, month: m}) do
    :io_lib.format("~4..0B-~2..0B", [y, m]) |> to_string()
  end

  @doc "把分格式化为人民币元字符串（仅供展示）。"
  def format_yuan(cents) when is_integer(cents) do
    sign = if cents < 0, do: "-", else: ""
    a = abs(cents)
    "#{sign}¥#{div(a, 100)}.#{String.pad_leading(to_string(rem(a, 100)), 2, "0")}"
  end
end
