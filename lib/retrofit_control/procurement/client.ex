defmodule RetrofitControl.Procurement.Client do
  @moduledoc """
  外部采购系统客户端行为（Behaviour）。
  生产用 HttpcClient，测试用 Stub 注入故障/回执，演示用内置 MockServer。
  """

  @callback create_purchase_order(map()) ::
              {:ok, %{external_ref: String.t()}}
              | {:confirmed, %{external_ref: String.t()}}
              | {:rejected, %{reason: String.t()}}
              | {:error, term()}
end

defmodule RetrofitControl.Procurement.HttpcClient do
  @moduledoc """
  真实外部采购系统适配器：通过 Erlang :httpc 调用外部 HTTP。
  外部系统按 `Idempotency-Key` 去重；本适配器只在 outbox 重试中被调用，
  因此网络超时可以安全重试。默认不启用（交付包使用内置 MockServer）。
  """

  @behaviour RetrofitControl.Procurement.Client

  @impl true
  def create_purchase_order(po) do
    base = Application.get_env(:retrofit_control, :procurement_url, "http://127.0.0.1:9099/po")

    body =
      Jason.encode!(%{
        po_id: po.id,
        vendor_id: po.vendor_id,
        amount_cents: po.amount_cents,
        idempotency_key: po.idempotency_key
      })

    headers = [
      {'content-type', 'application/json'},
      {'idempotency-key', String.to_charlist(po.idempotency_key)}
    ]

    :inets.start()
    :ssl.start()

    case :httpc.request(:post, {String.to_charlist(base), headers, 'application/json', body},
           [{:timeout, 3000}, {:connect_timeout, 2000}],
           []) do
      {:ok, {{_, 200, _}, _resp_headers, resp_body}} ->
        %{"external_ref" => ref} = Jason.decode!(resp_body)
        {:ok, %{external_ref: ref}}

      {:ok, {{_, 202, _}, _resp_headers, _resp_body}} ->
        # 外部系统已受理但回执异步到达：等待回执补偿流程
        {:pending, %{}}

      {:ok, {{_, status, _}, _resp_headers, resp_body}} when status in [409] ->
        %{"external_ref" => ref} = Jason.decode!(resp_body)
        {:confirmed, %{external_ref: ref}}

      {:ok, {{_, status, _}, _resp_headers, resp_body}} when status >= 400 ->
        {:rejected, %{reason: "HTTP #{status}: #{String.slice(resp_body, 0, 200)}"}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
