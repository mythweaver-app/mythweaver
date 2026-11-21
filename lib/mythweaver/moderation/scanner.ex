defmodule Mythweaver.Moderation.Scanner do
  @moduledoc """
  Runs the enabled moderation rules (`Mythweaver.Moderation.Rules.enabled_for/1`) over a
  `Mythweaver.Moderation.Scan` and acts on the verdict.

  Each rule adds a finding: a string-keyed map of `"rule_id"`, `"rule"`, `"action"` (`"approve"`,
  `"flag"` or `"reject"`), `"field"`, `"excerpt"` and `"reason"`. A regex rule finds on its first
  matching field (a pattern that hits its match limit, or no longer compiles, flags). A webhook rule
  POSTs the content as JSON, signed with `x-mythweaver-signature: sha256=<hex HMAC>` when it has a
  secret, and reads `{"action", "reason"}` from the response; a callback-mode rule that answers 2xx
  without a verdict is awaited until its `callback_timeout_minutes` (`callback/3`). Any failure
  flags. The first reject ends the scan.

  `conclude/1` decides: any reject rejects, else any flag sends it to review, else it is approved. A
  held item is then released, discarded or left for a moderator (`Mythweaver.Moderation.Holds`); a
  saved row gets a rule report (`Mythweaver.Moderation.Reports.flag/5`) on review or reject.
  """

  use Gettext, backend: Mythweaver.Gettext

  alias Mythweaver.Accounts
  alias Mythweaver.Moderation
  alias Mythweaver.Moderation.Hold
  alias Mythweaver.Moderation.Holds
  alias Mythweaver.Moderation.Reports
  alias Mythweaver.Moderation.Rule
  alias Mythweaver.Moderation.Rules
  alias Mythweaver.Moderation.Scan
  alias Mythweaver.Moderation.Store
  alias Mythweaver.Moderation.TaskSupervisor
  alias Mythweaver.Net.Guard

  @actions ~w[approve flag reject]
  @excerpt_bytes 60

  @doc "Runs `scan` in the background (inline when `:moderation_in_background` is false)."
  @spec scan_later(Scan.t()) :: :ok
  def scan_later(%Scan{} = scan) do
    scan = %{scan | id: scan.id || Mythweaver.Schema.generate_id()}

    if Application.get_env(:mythweaver, :moderation_in_background, true) do
      {:ok, _pid} = Task.Supervisor.start_child(TaskSupervisor, fn -> run(scan) end)
      :ok
    else
      run(scan)
    end
  end

  @doc "Runs every enabled rule of the scan's type, then concludes it or waits for callbacks."
  @spec run(Scan.t()) :: :ok
  def run(%Scan{} = scan) do
    scan = %{scan | id: scan.id || Mythweaver.Schema.generate_id()}

    scan =
      Enum.reduce_while(Rules.enabled_for(scan.type), scan, fn rule, scan ->
        scan = check(rule, scan)
        if rejected?(scan), do: {:halt, scan}, else: {:cont, scan}
      end)

    if rejected?(scan) or scan.awaiting == %{} do
      conclude(%{scan | awaiting: %{}})
    else
      :ok = Store.put_scan(scan)
      if scan.hold_id, do: Store.update_hold(scan.hold_id, &%{&1 | findings: scan.findings})
      :ok
    end
  end

  @doc "A callback rule's verdict for the waiting scan `scan_id`."
  @spec callback(String.t(), String.t(), map()) :: :ok | {:error, :not_found | :invalid}
  def callback(scan_id, rule_id, params) do
    with {:ok, action} <- callback_action(params),
         {:ok, %Scan{awaiting: %{^rule_id => {_deadline, name}}} = scan} <- take(scan_id) do
      finding = finding(rule_id, name, action, nil, nil, reason(params))
      scan = %{scan | findings: scan.findings ++ [finding], awaiting: Map.delete(scan.awaiting, rule_id)}

      if action == "reject" or scan.awaiting == %{} do
        conclude(%{scan | awaiting: %{}})
      else
        :ok = Store.put_scan(scan)
        if scan.hold_id, do: Store.update_hold(scan.hold_id, &%{&1 | findings: scan.findings})
        :ok
      end
    else
      {:error, :invalid} -> {:error, :invalid}
      # A scan taken but not awaiting this rule goes back as it was.
      {:ok, %Scan{} = scan} -> put_back(scan)
      _ -> {:error, :not_found}
    end
  end

  defp take(scan_id) do
    case Store.take_scan(scan_id) do
      {:ok, scan} -> {:ok, scan}
      :error -> {:error, :not_found}
    end
  end

  defp put_back(scan) do
    :ok = Store.put_scan(scan)
    {:error, :not_found}
  end

  defp callback_action(%{"action" => action}) when action in @actions, do: {:ok, action}
  defp callback_action(_params), do: {:error, :invalid}

  @doc """
  Handles what `Mythweaver.Moderation.Store.sweep/1` pulled out at `now_ms`: each hold is discarded,
  and each scan's overdue callback rules flag.
  """
  @spec expired([Hold.t()], [Scan.t()], integer()) :: :ok
  def expired(holds, scans, now_ms) do
    days = div(Moderation.config(:hold_ttl_hours), 24)

    Enum.each(holds, fn hold ->
      Holds.discard(hold, :expired, Mythweaver.Locale.with_user_locale(hold.user_id, fn -> expired_reason(days) end))
    end)

    Enum.each(scans, fn scan ->
      {overdue, awaiting} = Map.split_with(scan.awaiting, fn {_rule, {deadline, _}} -> deadline <= now_ms end)

      findings =
        Enum.map(overdue, fn {rule_id, {_deadline, name}} ->
          finding(rule_id, name, "flag", nil, nil, "webhook did not answer in time")
        end)

      scan = %{scan | findings: scan.findings ++ findings, awaiting: awaiting}

      if awaiting == %{} do
        conclude(scan)
      else
        :ok = Store.put_scan(scan)
        if scan.hold_id, do: Store.update_hold(scan.hold_id, &%{&1 | findings: scan.findings})
      end
    end)
  end

  @doc "The verdict of a finished scan's findings."
  @spec verdict([map()]) :: :approve | :review | :reject
  def verdict(findings) do
    cond do
      Enum.any?(findings, &(&1["action"] == "reject")) -> :reject
      Enum.any?(findings, &(&1["action"] == "flag")) -> :review
      true -> :approve
    end
  end

  @doc "Acts on a finished scan's verdict."
  @spec conclude(Scan.t()) :: :ok
  def conclude(%Scan{hold_id: hold_id} = scan) when is_binary(hold_id) do
    case verdict(scan.findings) do
      :approve ->
        Holds.release(hold_id)

      :reject ->
        case Store.take_hold(hold_id) do
          {:ok, hold} ->
            reason = Mythweaver.Locale.with_user_locale(hold.user_id, fn -> summary(scan.findings) end)
            Holds.discard(%{hold | findings: scan.findings}, :rejected, reason)

          :error ->
            :ok
        end

      :review ->
        case Store.update_hold(hold_id, &%{&1 | status: :review, findings: scan.findings}) do
          :ok ->
            Moderation.broadcast_changed()
            Moderation.broadcast_submissions_changed(scan.user_id)

          :error ->
            :ok
        end
    end

    :ok
  end

  def conclude(%Scan{} = scan) do
    if verdict(scan.findings) != :approve,
      do: :ok = Reports.flag(scan.subject_type, scan.subject_id, scan.user_id, scan.snapshot, scan.findings)

    :ok
  end

  defp expired_reason(days) do
    gettext_comment("Notification body when content held for moderator review expired unreviewed.")

    dngettext(
      "moderation",
      "It waited more than %{day_count} day for review and was discarded.",
      "It waited more than %{day_count} days for review and was discarded.",
      days,
      day_count: Mythweaver.Format.number(days)
    )
  end

  @doc "A submitter-facing summary of the findings that stopped an item."
  @spec summary([map()]) :: String.t()
  def summary(findings) do
    lines =
      findings
      |> Enum.filter(&(&1["action"] == "reject"))
      |> Enum.map_join("; ", &"#{&1["rule"]}#{if &1["reason"], do: ": #{&1["reason"]}"}")

    gettext_comment(
      "Notification body when the moderation rules rejected the user's content; the placeholder lists each rule name with its reason (\"rule: reason\"), separated by semicolons, as written by moderators."
    )

    dgettext("moderation", "It was rejected by the moderation rules (%{rule_reasons}).", rule_reasons: lines)
  end

  defp rejected?(scan), do: Enum.any?(scan.findings, &(&1["action"] == "reject"))

  defp check(%Rule{kind: :regex} = rule, scan) do
    case Rule.compile(rule) do
      {:ok, regex} -> regex_check(rule, regex, scan)
      {:error, _} -> add(scan, finding(rule.id, rule.name, "flag", nil, nil, "pattern does not compile"))
    end
  end

  defp check(%Rule{kind: :webhook} = rule, scan), do: webhook_check(rule, scan)

  defp regex_check(rule, regex, scan) do
    opts = [:report_errors, {:capture, :first, :index}, {:match_limit, 10_000_000}, {:match_limit_recursion, 100_000}]

    Enum.reduce_while(scan.fields, scan, fn {label, text}, scan ->
      case :re.run(text, regex.re_pattern, opts) do
        {:match, [{pos, len}]} ->
          action = Atom.to_string(rule.regex_action)
          {:halt, add(scan, finding(rule.id, rule.name, action, label, excerpt(text, pos, len), nil))}

        {:error, _} ->
          {:halt, add(scan, finding(rule.id, rule.name, "flag", label, nil, "pattern hit its match limit"))}

        :nomatch ->
          {:cont, scan}
      end
    end)
  end

  defp excerpt(text, pos, len) do
    from = max(pos - @excerpt_bytes, 0)
    to = min(pos + len + @excerpt_bytes, byte_size(text))
    text |> binary_part(from, to - from) |> String.replace_invalid()
  end

  defp webhook_check(rule, scan) do
    callback? = rule.webhook_mode == :callback and Moderation.callback_url() != nil
    body = Jason.encode!(payload(rule, scan, callback?))

    headers =
      [{"content-type", "application/json"}] ++
        if(rule.secret, do: [{"x-mythweaver-signature", "sha256=" <> signature(rule.secret, body)}], else: [])

    request =
      Req.new(
        [url: rule.url, method: :post, body: body, headers: headers, retry: false, receive_timeout: rule.timeout_ms] ++
          Application.get_env(:mythweaver, :moderation_req_options, [])
      )
      |> Guard.attach(private: :allow, max_body: 64 * 1024)

    case Req.request(request) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        case verdict_body(body) do
          {:ok, action, reason} ->
            add(scan, finding(rule.id, rule.name, action, nil, nil, reason))

          :error when callback? ->
            deadline = System.system_time(:millisecond) + rule.callback_timeout_minutes * 60_000
            %{scan | awaiting: Map.put(scan.awaiting, rule.id, {deadline, rule.name})}

          :error ->
            add(
              scan,
              finding(rule.id, rule.name, "flag", nil, nil, "webhook failed: #{inspect({:invalid_body, status})}")
            )
        end

      {:ok, %Req.Response{status: status}} ->
        add(scan, finding(rule.id, rule.name, "flag", nil, nil, "webhook failed: #{inspect(status)}"))

      {:error, exception} ->
        add(scan, finding(rule.id, rule.name, "flag", nil, nil, "webhook failed: #{inspect(error_reason(exception))}"))
    end
  end

  defp error_reason(%{reason: reason}), do: reason
  defp error_reason(exception), do: exception

  defp verdict_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, map} -> verdict_body(map)
      {:error, _} -> :error
    end
  end

  defp verdict_body(%{"action" => action} = body) when action in @actions, do: {:ok, action, reason(body)}
  defp verdict_body(_body), do: :error

  defp reason(%{"reason" => reason}) when is_binary(reason) and reason != "", do: String.slice(reason, 0, 500)
  defp reason(_), do: nil

  defp payload(rule, scan, callback?) do
    user = scan.user_id && Accounts.get_user(scan.user_id)

    %{
      "event" => "moderation.scan",
      "scan_id" => scan.id,
      "content_type" => Atom.to_string(scan.type),
      "subject_type" => Atom.to_string(scan.subject_type),
      "subject_id" => scan.subject_id,
      "action" => Atom.to_string(scan.action),
      "held" => scan.hold_id != nil,
      "user" => %{"id" => scan.user_id, "handle" => user && user.handle},
      "title" => scan.title,
      "fields" => Map.new(scan.fields)
    }
    |> then(&if(scan.chat_id, do: Map.put(&1, "chat_id", scan.chat_id), else: &1))
    |> then(&if(callback?, do: Map.put(&1, "callback_url", callback_url(scan, rule)), else: &1))
  end

  @doc "The URL a callback rule answers `scan` on."
  @spec callback_url(Scan.t(), Rule.t()) :: String.t()
  def callback_url(scan, rule) do
    token = Phoenix.Token.sign(MythweaverWeb.Endpoint, "moderation callback", %{"scan" => scan.id, "rule" => rule.id})
    "#{Moderation.callback_url()}/moderation/callback/#{token}"
  end

  @doc "The hex HMAC-SHA256 of `body` with `secret`."
  @spec signature(String.t(), iodata()) :: String.t()
  def signature(secret, body), do: :hmac |> :crypto.mac(:sha256, secret, body) |> Base.encode16(case: :lower)

  defp add(scan, finding), do: %{scan | findings: scan.findings ++ [finding]}

  defp finding(rule_id, rule, action, field, excerpt, reason) do
    %{
      "rule_id" => rule_id,
      "rule" => rule,
      "action" => action,
      "field" => field,
      "excerpt" => excerpt,
      "reason" => reason
    }
  end
end
