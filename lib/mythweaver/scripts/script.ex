defmodule Mythweaver.Scripts.Script do
  @moduledoc """
  One Lua script, run by `Mythweaver.Scripts.run/3` in every chat when its `trigger` fires.
  `user_id` is its owner (nil: the site's, see `Mythweaver.Scripts`). `dependencies` are scripts of the same trigger that must succeed first. The `last_*` status fields
  are set only by `Mythweaver.Scripts.record_results/2`, for runs in chats of users who may edit the
  script (a site script's status reflects only admins' chats), and cleared when the body or trigger changes.
  """

  use Mythweaver.Schema
  use Gettext, backend: Mythweaver.Gettext

  import Ecto.Changeset

  alias Mythweaver.Accounts.User
  alias Mythweaver.Scripts.Command
  alias Mythweaver.Scripts.Sandbox

  @max_body_bytes 64 * 1024

  @type t :: %__MODULE__{}
  @type trigger :: :ai_generation | :user_message | :lore_activated | :image_described | :command | :quick_reply

  schema "scripts" do
    field :name, :string
    field :description, :string
    field :priority, :integer, default: 0

    field :trigger, Ecto.Enum,
      values: [:ai_generation, :user_message, :lore_activated, :image_described, :command, :quick_reply],
      default: :ai_generation

    field :body, :string, default: ""
    field :enabled, :boolean, default: true
    field :last_error, :string
    field :last_error_at, :utc_datetime
    field :last_success_at, :utc_datetime
    field :dependency_ids, {:array, Ecto.UUID}, virtual: true, default: []

    many_to_many :dependencies, __MODULE__,
      join_through: "script_dependencies",
      join_keys: [script_id: :id, dependency_id: :id],
      on_replace: :delete

    field :site_visibility, Ecto.Enum, values: [:readable, :runtime_only], default: :readable

    belongs_to :user, User
    # What `Mythweaver.Sharing.Clone` copied this from (no FK: the source may go). Never cast.
    field :cloned_from_type, Ecto.Enum,
      values: [
        :character,
        :lore_book,
        :prompt,
        :block,
        :outlet,
        :script,
        :memory_profile,
        :side_prompt,
        :side_prompt_set,
        :ai_model
      ]

    field :cloned_from_id, Ecto.UUID
    # The catalog release a clone from a listing was made of (`Mythweaver.Catalog`).
    field :cloned_from_release_id, Ecto.UUID
    # Set on a catalog mirror row (`Mythweaver.Catalog`): its listing and the live row it copies.
    # Never cast.
    field :frozen_listing_id, Ecto.UUID
    field :mirror_of_id, Ecto.UUID

    timestamps(type: :utc_datetime)
  end

  @doc "Select options for the trigger field, in display order."
  def trigger_options do
    [
      {dpgettext("scripts", "option: event that runs a script", "Incoming AI generation"), :ai_generation},
      {dpgettext("scripts", "option: event that runs a script", "Outgoing user message"), :user_message},
      {dpgettext("scripts", "option: event that runs a script", "Lore book activated"), :lore_activated},
      {dpgettext("scripts", "option: event that runs a script", "Image described"), :image_described},
      {dpgettext("scripts", "option: event that runs a script", "Command palette"), :command},
      {dpgettext("scripts", "option: event that runs a script", "Quick reply"), :quick_reply}
    ]
  end

  @doc """
  The hex SHA-256 of the trigger and body joined by a newline: what a subscriber consented to when
  they enabled a shared script (`Mythweaver.Sharing.Toggle`). Must match the SQL in
  `Mythweaver.Scripts.effective/2`.
  """
  @spec consent_hash(t()) :: String.t()
  def consent_hash(%__MODULE__{trigger: t, body: b}),
    do: :crypto.hash(:sha256, "#{t}\n#{b}") |> Base.encode16(case: :lower)

  @doc false
  def changeset(script, attrs) do
    attrs = normalize_dependency_ids(attrs)

    script
    |> cast(attrs, [:name, :description, :priority, :trigger, :enabled, :dependency_ids, :site_visibility])
    # A separate cast so a cleared body stays `""` (the column is NOT NULL) instead of nil.
    |> cast(attrs, [:body], empty_values: [nil])
    |> validate_required([:name, :trigger])
    |> validate_length(:name, max: 255)
    |> validate_site_visibility()
    |> validate_length(:body, max: @max_body_bytes, count: :bytes)
    |> unique_constraint(:name, name: :scripts_user_id_name_index)
    |> validate_syntax()
    |> validate_command_header()
    |> reset_status()
  end

  # A run outcome describes the body and trigger it ran with; after either changes it is stale.
  defp reset_status(changeset) do
    if changed?(changeset, :body) or changed?(changeset, :trigger) do
      change(changeset, last_error: nil, last_error_at: nil, last_success_at: nil)
    else
      changeset
    end
  end

  # The form sends a hidden blank entry so every dependency can be cleared.
  defp normalize_dependency_ids(attrs) do
    Map.new(attrs, fn
      {key, ids} when key in [:dependency_ids, "dependency_ids"] and is_list(ids) ->
        {key, Enum.reject(ids, &(&1 == ""))}

      pair ->
        pair
    end)
  end

  # Parsed in a capped process (`Sandbox.parse/1`): this runs in the editing LiveView on every
  # change, and parser memory grows with nesting depth.
  defp validate_syntax(changeset) do
    with false <- Keyword.has_key?(changeset.errors, :body),
         body when is_binary(body) <- get_change(changeset, :body),
         false <- String.trim(body) == "",
         {:error, errors} <- Sandbox.parse(body) do
      add_error(changeset, :body, Enum.join(errors, "; "))
    else
      _ -> changeset
    end
  end

  defp validate_command_header(changeset) do
    with :command <- get_field(changeset, :trigger),
         false <- Keyword.has_key?(changeset.errors, :body),
         body when is_binary(body) <- get_field(changeset, :body),
         false <- String.trim(body) == "",
         {:error, errors} <- Command.parse(body) do
      add_error(changeset, :body, Enum.join(errors, "; "))
    else
      _ -> changeset
    end
  end

  # A site row may hide its protected content from users; a personal row is only ever its owner's.
  defp validate_site_visibility(changeset) do
    if get_field(changeset, :user_id) != nil and get_field(changeset, :site_visibility) != :readable,
      do: add_error(changeset, :site_visibility, dgettext_noop("errors", "only site items can be runtime-only")),
      else: changeset
  end
end
