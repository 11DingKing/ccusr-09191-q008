defmodule Mix.Tasks.Retro.Board do
  @moduledoc """
  厂长控制台报表：不看代码、不查数据库，直接回答三件事——

  1. 哪条产线可以继续、卡在哪里；
  2. 哪笔预算被锁定（主预算 + 风险储备）；
  3. 若发生回退，退到了哪个安全节点。

      mix retro.board            # 全部产线 + 预算总览
      mix retro.board L1         # 单条产线详情
      mix retro.board --audit=20 # 最近 20 条审计事件
  """
  @shortdoc "厂长看板：产线能否继续 / 预算锁定 / 安全节点"

  use Mix.Task

  alias RetrofitControl.Engine

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")
    Process.sleep(150)

    {opts, positional, _} =
      OptionParser.parse(args, strict: [audit: :integer])

    line_id = List.first(positional)

    boards = if line_id, do: [Engine.line_board(Engine, line_id)], else: Engine.line_board(Engine)

    print_banner()
    Enum.each(boards, &print_line_board/1)
    print_budget(Engine.budget_board(Engine))

    if opts[:audit] do
      print_audit(Engine.audit(Engine, limit: opts[:audit]))
    end

    if line_id == nil and opts[:audit] == nil do
      IO.puts(IO.ANSI.faint() <> "\n（追加 --audit=N 查看最近 N 条审计事件）" <> IO.ANSI.reset())
    end
  end

  defp print_banner do
    IO.puts("""
    ================================================================
     工厂 5G 改造 · 阶段化交付控制塔
    ================================================================
    """)
  end

  defp print_line_board(b) do
    status_color = if b.can_continue, do: :green, else: :yellow

    IO.puts("""
    ┌─ 产线 #{b.line_id} #{b.line_name}
    │  有效合同版本：#{b.contract_version || "（无）"}    签约服务商：#{b.vendor_id || "—"}
    │  安全节点：#{b.safe_node_cn}
    │  下一步：#{phase_label(b.next_action_phase, b.phases)}
    │  能否继续：#{colorize(status_color, yes_no(b.can_continue))}
    """)

    Enum.each(b.phases, fn p ->
      mark =
        cond do
          p.safe_node -> "●"
          p.status == "ROLLED_BACK" -> "↩"
          p.status == "IN_PROGRESS" -> "▶"
          p.status == "SUBMITTED" -> "?"
          p.status == "ACCEPTED" -> "●"
          true -> "○"
        end

      sub =
        if p.current_submission do
          sub_line = "验收单 #{p.current_submission.id}（#{p.current_submission.status}）"

          sub_line =
            if p.current_submission.offline,
              do: sub_line <> " [离线补传 #{p.current_submission.captured_at}]",
              else: sub_line

          "    └ #{sub_line}\n"
        else
          ""
        end

      IO.puts("    #{mark} #{p.code}  #{p.name}  [#{p.status_cn}]\n#{sub}")
    end)

    if b.blockers != [] do
      IO.puts("    阻塞原因：")
      Enum.each(b.blockers, &IO.puts("      ⚠ #{&1}"))
    end

    if b.locked_budget != [] do
      IO.puts("    锁定预算：")

      Enum.each(b.locked_budget, fn l ->
        IO.puts(
          "      🔒 阶段 #{l.phase}：费 #{RetrofitControl.Util.format_yuan(l.fee_cents)}" <>
            " + 风险储备 #{RetrofitControl.Util.format_yuan(l.reserve_cents)}（合同 #{l.contract_version}）"
        )
      end)
    end

    IO.puts("└────────────────────────────────────────────────────────────────\n")
  end

  defp phase_label(nil, _), do: "全部阶段已完成"

  defp phase_label(code, phases) do
    p = Enum.find(phases, &(&1.code == code))
    "#{code} #{p && p.name}（#{p && p.status_cn}）"
  end

  defp yes_no(true), do: "是 ✓"
  defp yes_no(false), do: "否"

  defp print_budget(board) do
    c = board.summary_cn

    IO.puts("""
    ┌─ 预算总览（全厂）
    │  主预算：总额 #{c.main_total}  已锁定 #{c.main_locked}  已消耗 #{c.main_consumed}  可用 #{c.main_available}
    │  风险池：总额 #{c.risk_total}  已锁定 #{c.risk_locked}  可用 #{c.risk_available}
    │
    │  按产线：
    """)

    Enum.each(board.per_line, fn l ->
      IO.puts(
        "    #{l.line_id}：主可用 #{RetrofitControl.Util.format_yuan(l.main_available_cents)} / " <>
          "总 #{RetrofitControl.Util.format_yuan(l.main_total_cents)}；" <>
          "风险可用 #{RetrofitControl.Util.format_yuan(l.risk_available_cents)}"
      )
    end)

    if board.locks != [] do
      IO.puts("    当前锁定：")

      Enum.each(board.locks, fn l ->
        IO.puts(
          "      🔒 #{l.line_id}/#{l.phase}：#{RetrofitControl.Util.format_yuan(l.fee_cents)}" <>
            "（储备 #{RetrofitControl.Util.format_yuan(l.reserve_cents)}）"
        )
      end)
    end

    if board.monthly != [] do
      IO.puts("    跨月费用（红冲后净额）：")

      Enum.each(board.monthly, fn m ->
        IO.puts(
          "      #{m.line_id}  #{m.period}：#{RetrofitControl.Util.format_yuan(m.net_cents)}"
        )
      end)
    end

    IO.puts("└────────────────────────────────────────────────────────────────\n")
  end

  defp print_audit(events) do
    IO.puts("┌─ 最近审计事件（持久化、只追加、与业务状态严格一致）")

    Enum.each(events, fn e ->
      IO.puts("  ##{e.seq}  #{e.at}  #{e.type}  #{e.line_id || ""}/#{e.code || ""}")
    end)

    IO.puts("└────────────────────────────────────────────────────────────────")
  end

  defp colorize(color, text) do
    case color do
      :green -> IO.ANSI.green() <> text <> IO.ANSI.reset()
      :yellow -> IO.ANSI.yellow() <> text <> IO.ANSI.reset()
      _ -> text
    end
  end
end
