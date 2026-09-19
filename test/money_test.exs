defmodule RetrofitControl.MoneyTest do
  use ExUnit.Case, async: true
  alias RetrofitControl.Money

  describe "跨月费用拆分" do
    test "单日费用全部落在当月" do
      split = Money.split_by_month(10_000, ~D[2026-03-15], ~D[2026-03-15])
      assert split == %{"2026-03" => 10_000}
    end

    test "跨两个月按天拆分且总额恒定（含余数修正）" do
      # 2026-03 共 31 天，区间 3/31..4/2 = 3 天
      split = Money.split_by_month(10_000, ~D[2026-03-31], ~D[2026-04-02])
      assert Map.keys(split) |> Enum.sort() == ["2026-03", "2026-04"]
      assert Enum.sum(Map.values(split)) == 10_000
      # 3月 1 天得 3333，4月 2 天（天数最多）拿余数 1，得 6667
      assert split["2026-03"] == div(10_000 * 1, 3)
      assert split["2026-04"] == div(10_000 * 2, 3) + rem(10_000, 3)
    end

    test "不能整除时差额补给天数最多的月份，总额绝不丢分" do
      Enum.each(1..50, fn cents ->
        split = Money.split_by_month(cents, ~D[2026-01-31], ~D[2026-02-02])
        assert Enum.sum(Map.values(split)) == cents
      end)
    end
  end

  describe "延期罚则" do
    test "按期完成不罚" do
      assert Money.late_penalty(~D[2026-12-31], ~D[2026-12-31], 100_000, []) == 0
      assert Money.late_penalty(~D[2026-12-31], nil, 100_000, []) == 0
    end

    test "延期按天计提并受封顶限制" do
      # 默认 50bp/天，封顶 30%
      p10 = Money.late_penalty(~D[2026-12-31], ~D[2027-01-10], 100_000, [])
      assert p10 == div(100_000 * 50 * 10, 10_000)

      p_huge = Money.late_penalty(~D[2026-01-01], ~D[2027-06-01], 100_000, [])
      assert p_huge == div(100_000 * 3000, 10_000)
    end
  end
end
