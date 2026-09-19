defmodule RetrofitControl.Money do
  @moduledoc """
  金额统一使用整数“分”，避免浮点误差。
  同时集中处理跨月费用拆分与延期罚则，保证口径在服务重启后仍一致。
  """

  @doc "把 {元, 分} 或纯元数字折算为分（仅接受整数金额，金额单位为分）。"
  def cents(n) when is_integer(n), do: n

  @doc """
  按自然月把一笔发生在 [from, to] 区间内的费用拆分到各月份。

  费用按当月在区间内的天数占比分摊（每天等额 = 总额 / 总天数）。
  返回 %{\"YYYY-MM\" => 分}，用于“跨月费用保持一致”的台账。
  """
  def split_by_month(total_cents, from_date, to_date) when is_integer(total_cents) do
    total_days = Date.diff(to_date, from_date) + 1

    if total_days <= 0 do
      %{month_key(from_date) => total_cents}
    else
      days = Date.range(from_date, to_date)

      buckets =
        Enum.reduce(days, %{}, fn date, acc ->
          key = month_key(date)
          Map.update(acc, key, 1, &(&1 + 1))
        end)

      # 先按比例分配，再用余数修正保证总额恒定（分不丢失）。
      allocated =
        Enum.map(buckets, fn {key, days} ->
          {key, div(total_cents * days, total_days), days}
        end)

      used = Enum.reduce(allocated, 0, fn {_, v, _}, sum -> sum + v end)
      remainder = total_cents - used

      # 把余数补给天数最多的月份（跨月费用合计始终等于原额）。
      {largest_key, _, _} =
        Enum.reduce(allocated, {nil, nil, -1}, fn {key, val, days}, {ak, av, ad} ->
          if days > ad, do: {key, val, days}, else: {ak, av, ad}
        end)

      Map.new(allocated, fn {key, val, _} ->
        if key == largest_key, do: {key, val + remainder}, else: {key, val}
      end)
    end
  end

  @doc """
  计算延期罚则（分）。

  - completed_at 未超过 planned_end：0
  - 每延误 1 天，按阶段批准时锁定的金额的 rate_per_day_bp/10000 计提
  - 设有封顶 cap_bp（万分比），默认 30%
  """
  def late_penalty(_planned_end, nil, _locked_cents, _opts), do: 0

  def late_penalty(planned_end, completed_at, locked_cents, opts) do
    late_days = Date.diff(completed_at, planned_end)

    if late_days <= 0 do
      0
    else
      rate_bp = Keyword.get(opts, :rate_per_day_bp, 50)
      cap_bp = Keyword.get(opts, :cap_bp, 3000)

      raw = div(locked_cents * rate_bp * late_days, 10_000)
      cap = div(locked_cents * cap_bp, 10_000)
      min(raw, cap)
    end
  end

  def month_key(%Date{} = d), do: "#{d.year}-#{pad(d.month)}"

  def month_key(%NaiveDateTime{} = dt), do: month_key(NaiveDateTime.to_date(dt))

  defp pad(n) when n < 10, do: "0#{n}"
  defp pad(n), do: to_string(n)
end
