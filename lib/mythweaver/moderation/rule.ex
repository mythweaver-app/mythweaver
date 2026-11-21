defmodule Mythweaver.Moderation.Rule do
  @moduledoc """
  One content-moderation rule (`Mythweaver.Moderation.Rules`), checked by `Moderation.Scanner`
  against every moderated save of its `content_types`.

  A `:regex` rule matches `pattern` (Unicode, case-insensitive unless `case_sensitive`) against each
  text field and answers `regex_action` (`:flag` or `:reject`) on a match. A `:webhook` rule POSTs
  the content to `url` (signed with `secret` when set) and takes the verdict from the response
  (`:sync`) or from a later POST to its signed callback URL (`:callback`, which needs
  `Mythweaver.Moderation.callback_url/0`). `secret` is encrypted at rest and never shown back: a
  blank param keeps it, `clear_secret` removes it.
  """

  use Mythweaver.Schema
  use Gettext, backend: Mythweaver.Gettext

  import Ecto.Changeset

  alias Mythweaver.Encrypted.Binary

  @type t :: %__MODULE__{}

  schema "moderation_rules" do
    field :name, :string
    field :kind, Ecto.Enum, values: [:regex, :webhook]
    field :enabled, :boolean, default: true
    # Literal lockstep with `Mythweaver.Moderation.Modes.types/0`.
    field :content_types, {:array, Ecto.Enum}, values: [:chats, :characters, :lore, :ai, :prompts], default: []
    field :pattern, :string
    field :case_sensitive, :boolean, default: false
    field :regex_action, Ecto.Enum, values: [:flag, :reject], default: :flag
    field :url, :string
    field :secret, Binary, redact: true
    field :webhook_mode, Ecto.Enum, values: [:sync, :callback], default: :sync
    field :timeout_ms, :integer, default: 10_000
    field :callback_timeout_minutes, :integer, default: 1440
    field :clear_secret, :boolean, virtual: true, default: false

    timestamps(type: :utc_datetime)
  end

  @doc "A changeset for a moderator's edit."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(rule, attrs) do
    rule
    |> cast(attrs, [
      :name,
      :kind,
      :enabled,
      :content_types,
      :pattern,
      :case_sensitive,
      :regex_action,
      :url,
      :webhook_mode,
      :timeout_ms,
      :callback_timeout_minutes,
      :clear_secret
    ])
    |> put_secret(attrs)
    |> validate_required([:name, :kind])
    |> validate_length(:name, max: 100)
    |> validate_length(:content_types, min: 1, message: dgettext_noop("errors", "choose at least one content type"))
    |> validate_kind()
  end

  @doc "The compiled `pattern` of a regex rule."
  @spec compile(t()) :: {:ok, Regex.t()} | {:error, term()}
  def compile(%__MODULE__{pattern: pattern, case_sensitive: cs}), do: compile(pattern || "", cs)

  @doc "Compiles `pattern` the way a regex rule does."
  @spec compile(String.t(), boolean()) :: {:ok, Regex.t()} | {:error, term()}
  def compile(pattern, case_sensitive), do: Regex.compile(pattern, if(case_sensitive, do: "u", else: "iu"))

  defp put_secret(changeset, attrs) do
    secret = attrs["secret"] || attrs[:secret]

    cond do
      get_change(changeset, :clear_secret) == true -> put_change(changeset, :secret, nil)
      is_binary(secret) and String.trim(secret) != "" -> put_change(changeset, :secret, secret)
      true -> changeset
    end
  end

  defp validate_kind(changeset) do
    case get_field(changeset, :kind) do
      :regex -> validate_regex(changeset)
      :webhook -> validate_webhook(changeset)
      _ -> changeset
    end
  end

  defp validate_regex(changeset) do
    changeset = changeset |> validate_required([:pattern]) |> validate_length(:pattern, max: 5000)

    with pattern when is_binary(pattern) <- get_field(changeset, :pattern),
         {:error, {msg, _at}} <- compile(pattern, get_field(changeset, :case_sensitive) == true) do
      add_error(changeset, :pattern, dgettext_noop("errors", "is not a valid regular expression: %{regex_error}"),
        regex_error: msg
      )
    else
      _ -> changeset
    end
  end

  defp validate_webhook(changeset) do
    changeset
    |> validate_required([:url])
    |> validate_change(:url, fn :url, url ->
      case URI.new(url) do
        {:ok, %URI{scheme: scheme, host: host}} when scheme in ["http", "https"] and is_binary(host) and host != "" ->
          []

        _ ->
          [url: dgettext_noop("errors", "must be an http(s) URL")]
      end
    end)
    |> validate_number(:timeout_ms, greater_than_or_equal_to: 1000, less_than_or_equal_to: 60_000)
    |> validate_number(:callback_timeout_minutes, greater_than_or_equal_to: 1, less_than_or_equal_to: 10_080)
    |> validate_callback()
  end

  defp validate_callback(changeset) do
    if get_field(changeset, :webhook_mode) == :callback and is_nil(Mythweaver.Moderation.callback_url()),
      do:
        add_error(changeset, :webhook_mode, dgettext_noop("errors", "needs MODERATION_CALLBACK_URL set on the server")),
      else: changeset
  end
end
