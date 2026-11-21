defmodule Mythweaver.Notifications.WebPush do
  @moduledoc """
  Sends one Web Push message to one browser subscription: RFC 8291 `aes128gcm` encryption and the
  RFC 8292 VAPID header come from `web_push_ex` (`WebPushEx.request/3`, which only builds the
  request); delivery is Req, retries off, since a retried push can reach a person twice.

  Keys are `config :web_push_ex, :vapid` (`public_key`, `private_key`, `subject`), set by
  `config/runtime.exs` from the `MYTHWEAVER_VAPID_*` variables. Without them `configured?/0` is
  false and nothing push-related runs or shows. Tests reach the push service through
  `config :mythweaver, :push_req_options` (`Req.Test`).
  """

  alias Mythweaver.Net.Guard

  @type subscription :: %{endpoint: String.t(), p256dh: String.t(), auth: String.t()}
  @type urgency :: :very_low | :low | :normal | :high

  @doc "Whether VAPID keys are set, so push can be offered and sent."
  @spec configured?() :: boolean()
  def configured? do
    vapid = Application.get_env(:web_push_ex, :vapid, [])
    Enum.all?([:public_key, :private_key, :subject], &(vapid[&1] not in [nil, ""]))
  end

  @doc "The VAPID public key, the browser's `applicationServerKey` (url-safe base64), or nil."
  @spec public_key() :: String.t() | nil
  def public_key, do: if(configured?(), do: Application.get_env(:web_push_ex, :vapid)[:public_key])

  @doc """
  Encrypts `payload` (JSON-encoded) for `subscription` and posts it to the subscription's push
  service. Options: `:ttl` (seconds the push service keeps it for an offline device, default 3600),
  `:urgency` (default `:normal`) and `:topic` (a newer push with the same topic replaces an
  undelivered one; at most 32 url-safe base64 characters).

  `:gone` means the subscription no longer exists (404/410): delete it.
  """
  @spec push(subscription(), map(), keyword()) :: :ok | :gone | {:error, pos_integer() | term()}
  def push(%{endpoint: endpoint, p256dh: p256dh, auth: auth}, payload, opts \\ []) do
    request =
      WebPushEx.request(
        %WebPushEx.Subscription{endpoint: URI.parse(endpoint), keys: %{p256dh: p256dh, auth: auth}},
        Jason.encode!(payload)
      )

    headers =
      request.headers
      # Req sets Content-Length from the body.
      |> Map.delete("Content-Length")
      |> Map.merge(%{
        "TTL" => to_string(Keyword.get(opts, :ttl, 3600)),
        "Urgency" => opts |> Keyword.get(:urgency, :normal) |> urgency()
      })
      |> then(&if topic = opts[:topic], do: Map.put(&1, "Topic", topic), else: &1)

    [url: endpoint, body: request.body, headers: headers, retry: false, receive_timeout: 15_000]
    |> Keyword.merge(Application.get_env(:mythweaver, :push_req_options, []))
    |> Req.new()
    # The browser hands over the endpoint, so it is untrusted.
    |> Guard.attach(private: :deny, max_body: 64 * 1024)
    |> Req.post()
    |> case do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: status}} when status in [404, 410] -> :gone
      {:ok, %{status: status}} -> {:error, status}
      {:error, reason} -> {:error, reason}
    end
  end

  defp urgency(:very_low), do: "very-low"
  defp urgency(urgency) when urgency in [:low, :normal, :high], do: Atom.to_string(urgency)
end
