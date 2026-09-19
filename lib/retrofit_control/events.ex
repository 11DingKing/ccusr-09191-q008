defmodule RetrofitControl.Events do
  @moduledoc """
  系统中所有可持久化事件的名称清单。事件即审计——任何业务状态变化都必须
  对应此清单中的一个事件，由 Journal fsync 落盘。
  """

  # 组织与主数据
  def line_registered, do: "line_registered"
  def device_registered, do: "device_registered"
  def phase_planned, do: "phase_planned"
  def quote_recorded, do: "quote_recorded"

  # 合同/报价版本
  def contract_superseded, do: "contract_superseded"

  # 阶段执行
  def phase_started, do: "phase_started"
  def budget_locked, do: "budget_locked"
  def acceptance_submitted, do: "acceptance_submitted"
  def submission_superseded, do: "submission_superseded"
  def acceptance_approved, do: "acceptance_approved"
  def acceptance_rejected, do: "acceptance_rejected"
  def budget_settled, do: "budget_settled"
  def budget_reversed, do: "budget_reversed"
  def budget_lock_released, do: "budget_lock_released"
  def phase_rolled_back, do: "phase_rolled_back"

  # 外部采购（幂等补偿）
  def po_created, do: "po_created"
  def po_confirmed, do: "po_confirmed"
  def po_rejected, do: "po_rejected"
  def po_compensated, do: "po_compensated"

  @all ~w(
    line_registered device_registered phase_planned quote_recorded
    contract_superseded phase_started budget_locked
    acceptance_submitted submission_superseded
    acceptance_approved acceptance_rejected
    budget_settled budget_reversed budget_lock_released phase_rolled_back
    po_created po_confirmed po_rejected po_compensated
  )

  def all, do: @all
end

defmodule RetrofitControl.DomainError do
  @moduledoc "业务规则冲突：含稳定错误码与中文人读说明，可直接展示给厂长。"
  defexception [:code, :message, :meta]

  @type t :: %__MODULE__{}

  def new(code, message, meta \\ %{}) do
    %__MODULE__{code: code, message: message, meta: meta}
  end

  def not_found(what), do: new("NOT_FOUND", "#{what}不存在")

  defimpl Jason.Encoder do
    def encode(err, opts) do
      Jason.Encode.map(
        %{error: err.code, message: err.message, meta: err.meta},
        opts
      )
    end
  end
end
