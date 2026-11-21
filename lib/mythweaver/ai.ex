defmodule Mythweaver.AI do
  @moduledoc """
  The AI context: provider connections, models, the links between them, and completions.

  A `Provider` is one API connection (adapter + URL + credential). A `Model` is exactly one AI model,
  carrying its friendly name, capabilities, limits, and default sampler params. The two are joined
  many-to-many through `ProviderModel` because the same model is usually reachable through several
  connections; `next_provider_model/3` rotates between them so no single connection is hammered.

  Selection is two-level: provider `priority` chooses the tier (a priority-1 connection takes every
  call while enabled), then link `weight` splits traffic *within* that tier as a share, not as a second
  preference order: weights 3/2/1 send exactly 3:2:1 of the calls and never starve the weight-1 link.
  Mechanically each link carries a `selection_deadline`; the smallest wins and advances by `1 / weight`.
  See `reference/weighted_selection.md` for the full explanation and a worked trace.

  `stream/4` and `stream_link/4` stream one completion and return a normalized `Completion` alongside
  the link that served it. Generation does not call them directly: every generation goes through
  `Mythweaver.Jobs`, which owns provider slots, timeouts and cancellation, and whose runner calls
  `stream_link/4` with the link the scheduler picked.

  ## Ownership ("bring your own provider")

  A connection or model with `user_id` nil is the site's: holders of `"site.ai.manage"` manage it,
  and holders of `"ai.site_models.use"` (or `"site.ai.manage"`) run the site's models. One with a
  `user_id` is that user's own, created when it holds `"ai.connections.create"`: only they see, edit
  or run it (site managers included, so nobody reads another user's key). A link joins a model and
  a connection with the same owner, so a site model never routes onto a personal key and a
  personal model never spends a site one, with one exception: a model shared in `:own_key` mode
  (`Mythweaver.Sharing`) may be linked to the subscriber's own connection (`link_model/4`).
  Selection is still per run (`next_provider_model/3`): only the run owner's connections, the
  site's when they may run site models, and the model owner's for an `:owner_key` share whose owner
  holds `"sharing.ai.owner_key"`.

  Editable (`list_providers/1`, `get_provider/2`, `list_editable_models/1`): your own, plus the
  site's for a site manager, plus models shared with you as an editor. Usable (`list_models/1`,
  `get_model/2`, `default_model/1`): your own, plus the site's when allowed, plus models shared
  with you.
  """

  use Gettext, backend: Mythweaver.Gettext

  import Ecto.Query, warn: false

  alias Mythweaver.Accounts
  alias Mythweaver.Accounts.Scope
  alias Mythweaver.AI.Completion
  alias Mythweaver.AI.Embedding
  alias Mythweaver.AI.EmbeddingRequest
  alias Mythweaver.AI.Model
  alias Mythweaver.AI.ModelGroup
  alias Mythweaver.AI.Provider
  alias Mythweaver.AI.Provider.Adapter
  alias Mythweaver.AI.Provider.ThinkingDialect
  alias Mythweaver.AI.ProviderModel
  alias Mythweaver.AI.Request
  alias Mythweaver.AI.SamplerParams
  alias Mythweaver.AI.Transfer
  alias Mythweaver.Changes
  alias Mythweaver.Chats
  alias Mythweaver.Chats.Chat
  alias Mythweaver.Chats.Participant
  alias Mythweaver.Format
  alias Mythweaver.Jobs
  alias Mythweaver.Lore.EntryEmbedding
  alias Mythweaver.Lore.MessageEmbedding
  alias Mythweaver.Memory.Profile
  alias Mythweaver.Moderation.Gate
  alias Mythweaver.Moderation.Hold
  alias Mythweaver.Ownership
  alias Mythweaver.Permissions.Group
  alias Mythweaver.Permissions.Member
  alias Mythweaver.Permissions.Quota
  alias Mythweaver.Prompts.Binding
  alias Mythweaver.Prompts.Prompt
  alias Mythweaver.Repo
  alias Mythweaver.Settings
  alias Mythweaver.Sharing.Share

  ## Ownership (`Mythweaver.Ownership`)

  @doc """
  Who owns a connection or model `scope` creates (`Mythweaver.Ownership.new_owner/3`): `scope`'s own
  for an `"ai.connections.create"` holder, else the site for a `"site.ai.manage"` holder, else
  `{:error, :unauthorized}`. `site: true` makes it the site's, which needs `"site.ai.manage"`.
  """
  @spec new_owner(Scope.t(), keyword()) :: {:ok, Ecto.UUID.t() | nil} | {:error, :unauthorized}
  def new_owner(%Scope{} = scope, opts \\ []), do: Ownership.new_owner(scope, Provider, opts)

  @doc "Whether `scope` may choose between a site and a personal row when creating one."
  @spec owner_choice?(Scope.t()) :: boolean()
  def owner_choice?(%Scope{} = scope),
    do: Scope.can?(scope, "site.ai.manage") and Scope.can?(scope, "ai.connections.create")

  @doc """
  Moves a connection (with every model linked to it) or a model to the site (`:site`), removing every
  reference the site may not hold (`Mythweaver.AI.Transfer`). Needs `"site.ai.manage"`, a row
  `scope` may edit and sudo mode. `{:error, :same_owner}` when the row is already the site's;
  `{:error, {:name_taken, names}}` when the site already has rows of those names.
  """
  @spec transfer(Scope.t(), Provider.t() | Model.t(), :site) ::
          {:ok, Provider.t() | Model.t()}
          | {:error, :unauthorized | :same_owner | :sudo_required | {:name_taken, [String.t()]}}
  def transfer(%Scope{} = scope, row, :site) do
    with :ok <- authorize_transfer(scope, row),
         :ok <- Mythweaver.Accounts.authorize_sudo(scope),
         {:ok, _} = result <- Transfer.run(row) do
      Changes.broadcast(:ai, [nil, row.user_id])
      result
    end
  end

  @doc "What `transfer/3` would change, and the names it would collide on (`Transfer.impact/1`)."
  @spec transfer_impact(Scope.t(), Provider.t() | Model.t(), :site) ::
          {:ok, {Transfer.impact(), [String.t()]}} | {:error, :unauthorized | :same_owner}
  def transfer_impact(%Scope{} = scope, row, :site) do
    with :ok <- authorize_transfer(scope, row), do: {:ok, Transfer.impact(row)}
  end

  defp authorize_transfer(scope, %struct{} = row) when struct in [Provider, Model] do
    cond do
      not Scope.can?(scope, "site.ai.manage") or authorize_edit(scope, row) != :ok -> {:error, :unauthorized}
      is_nil(row.user_id) -> {:error, :same_owner}
      true -> :ok
    end
  end

  defp authorize_edit(scope, row), do: Ownership.authorize_edit(scope, row)
  defp editable(query, scope), do: Ownership.editable(query, scope)

  @doc """
  Narrows a `Model` query to the models `scope` may run, under `usable?/2`'s rule, in one query.
  List callers filter with it rather than calling `usable?/2` per row.
  """
  @spec usable(Ecto.Queryable.t(), Scope.t()) :: Ecto.Query.t()
  def usable(query, %Scope{} = scope) do
    query = Ownership.usable(query, scope, shared?(scope))

    if Scope.can?(scope, "site.ai.manage") do
      query
    else
      allowed = scope |> allowed_groups() |> select([g], g.ai_model_id)

      where(
        query,
        [m],
        not is_nil(m.user_id) or m.id not in subquery(from(g in ModelGroup, select: g.ai_model_id)) or
          m.id in subquery(allowed)
      )
    end
  end

  defp shared?(%Scope{} = scope), do: Scope.can?(scope, "site.ai.manage") or Scope.can?(scope, "ai.site_models.use")

  # The `ModelGroup` rows that let `scope`'s user run their model: the Everyone group's and those of
  # the user's own groups. None without a user.
  defp allowed_groups(%Scope{user: %Accounts.User{id: uid}}) do
    from(g in ModelGroup,
      join: grp in assoc(g, :group),
      left_join: mem in Member,
      on: mem.group_id == g.group_id and mem.user_id == ^uid,
      where: grp.system_key == :everyone or not is_nil(mem.user_id)
    )
  end

  defp allowed_groups(%Scope{}), do: from(g in ModelGroup, where: false)

  # A model with no groups is open; one with groups needs one of `allowed_groups/1`. One query: the
  # model's group rows, and how many of them allow `scope`.
  defp group_allowed?(scope, model_id) do
    allowed = scope |> allowed_groups() |> where([g], g.ai_model_id == ^model_id)

    {groups, allowed} =
      Repo.one!(
        from(g in ModelGroup,
          left_join: a in subquery(allowed),
          on: a.group_id == g.group_id,
          where: g.ai_model_id == ^model_id,
          select: {count(), count(a.group_id)}
        )
      )

    groups == 0 or allowed > 0
  end

  @doc """
  Whether `scope` may run `model`: its own, or a site model when allowed and, when the model lists
  groups (`set_model_groups/3`), the scope's user is in one of them (site managers always are).
  """
  @spec usable?(Scope.t(), Model.t()) :: boolean()
  def usable?(%Scope{} = scope, %Model{} = model) do
    Ownership.usable?(scope, model, shared?(scope)) and
      (model.user_id != nil or Scope.can?(scope, "site.ai.manage") or group_allowed?(scope, model.id))
  end

  @doc "The ids of the groups allowed to run site model `model` (`[]`: everyone allowed site models)."
  @spec model_group_ids(Model.t()) :: [Ecto.UUID.t()]
  def model_group_ids(%Model{id: id}),
    do: Repo.all(from(g in ModelGroup, where: g.ai_model_id == ^id, select: g.group_id))

  @doc """
  Replaces the groups allowed to run site model `model` with `group_ids` (ids that are not groups
  are dropped; `[]` opens it to everyone allowed site models). Needs `"site.ai.manage"`.
  """
  @spec set_model_groups(Scope.t(), Model.t(), [Ecto.UUID.t()]) :: :ok | {:error, :unauthorized}
  def set_model_groups(%Scope{} = scope, %Model{user_id: nil, id: model_id} = model, group_ids)
      when is_list(group_ids) do
    if Scope.can?(scope, "site.ai.manage") do
      ids = for id <- group_ids, {:ok, id} <- [Ecto.UUID.cast(id)], uniq: true, do: id

      {:ok, :ok} =
        Repo.transaction(fn ->
          Repo.delete_all(from(g in ModelGroup, where: g.ai_model_id == ^model_id))
          valid = Repo.all(from(g in Group, where: g.id in ^ids, select: g.id))
          Repo.insert_all(ModelGroup, Enum.map(valid, &%{ai_model_id: model_id, group_id: &1}))
          :ok
        end)

      Changes.notify({:ok, model}, :ai)
      :ok
    else
      {:error, :unauthorized}
    end
  end

  def set_model_groups(%Scope{}, %Model{}, _group_ids), do: {:error, :unauthorized}

  @doc "Whether `scope` may add connections and models of its own (or the site's, for a site manager)."
  @spec can_add?(Scope.t()) :: boolean()
  def can_add?(%Scope{} = scope), do: Ownership.can_create?(scope, Provider)

  ## Providers

  @doc "The connections `scope` may edit: its own, plus the site's for an admin, each with `model_count`."
  def list_providers(%Scope{} = scope) do
    links = from(pm in ProviderModel, where: pm.provider_id == parent_as(:provider).id, select: count())

    from(p in Provider, as: :provider, order_by: [asc: p.name], select_merge: %{model_count: subquery(links)})
    |> editable(scope)
    |> Repo.all()
  end

  @doc "`{name, id}` select options for every connection `scope` may edit."
  def provider_options(%Scope{} = scope), do: Enum.map(list_providers(scope), &{&1.name, &1.id})

  def get_provider!(id), do: Provider |> Repo.get!(id) |> Repo.preload(provider_preloads())

  @doc "A connection `scope` may edit, or nil."
  def get_provider(%Scope{} = scope, id) do
    from(p in Provider, where: p.id == ^id)
    |> editable(scope)
    |> Repo.one()
    |> Repo.preload(provider_preloads())
  end

  @doc """
  Creates a connection, `scope`'s own by default or the site's with `site: true` (`new_owner/2`).
  """
  @spec create_provider(Scope.t(), map(), keyword()) ::
          {:ok, Provider.t()}
          | {:held, Hold.t()}
          | {:error, Ecto.Changeset.t() | :unauthorized | :quota_exceeded | :hold_limit}
  def create_provider(%Scope{} = scope, attrs \\ %{}, opts \\ []) do
    {followups, opts} = Keyword.pop(opts, :followups, [])

    with {:ok, owner} <- new_owner(scope, opts),
         :ok <- Quota.check_new_row(scope, owner, "quota.ai_connections", Provider) do
      changeset = Provider.changeset(%Provider{user_id: owner}, attrs)

      scope
      |> Gate.run(changeset, {__MODULE__, :create_provider, [attrs, opts]}, [followups: followups], fn ->
        Repo.insert(changeset)
      end)
      |> Changes.notify(:ai)
    end
  end

  # Re-enabling a provider reactivates all of its links at once; they keep their stored
  # `selection_deadline` rather than rebasing, so a long-disabled provider's links run ahead for at
  # most one cycle before the schedule self-corrects. Per-link re-enabling rebases (see
  # `update_link/3`); doing it here would mean writing every link row from the provider context.
  @spec update_provider(Scope.t(), Provider.t(), map()) ::
          {:ok, Provider.t()} | {:held, Hold.t()} | {:error, Ecto.Changeset.t() | :unauthorized | :hold_limit}
  def update_provider(%Scope{} = scope, %Provider{} = provider, attrs) do
    with :ok <- authorize_edit(scope, provider) do
      changeset = Provider.changeset(provider, attrs)

      scope
      |> Gate.run(changeset, {__MODULE__, :update_provider, [{:row, Provider, provider.id}, attrs]}, [], fn ->
        changeset |> Repo.update() |> admission_changed()
      end)
      |> Changes.notify(:ai)
    end
  end

  @doc "Deletes a provider; its links cascade, the models themselves are untouched."
  @spec delete_provider(Scope.t(), Provider.t()) ::
          {:ok, Provider.t()} | {:error, Ecto.Changeset.t() | :unauthorized}
  def delete_provider(%Scope{} = scope, %Provider{} = provider) do
    with :ok <- authorize_edit(scope, provider),
         do: provider |> Repo.delete() |> admission_changed() |> Changes.notify(:ai)
  end

  # The job scheduler admits from providers and links, and only on events: after a change to
  # either, a queued job may now fit, or never can.
  defp admission_changed({:ok, _} = ok) do
    Jobs.providers_changed()
    ok
  end

  defp admission_changed(error), do: error

  def change_provider(%Provider{} = provider, attrs \\ %{}) do
    Provider.changeset(provider, attrs)
  end

  defp provider_preloads, do: [provider_models: :model]

  ## Models

  @doc "The chat and text models `scope` may run: its own, plus the site's when allowed. Embedding and classifier models are excluded."
  def list_models(%Scope{} = scope) do
    from(m in Model,
      where: m.completion_mode in ^Model.text_modes(),
      order_by: [asc: m.name],
      preload: ^model_preloads()
    )
    |> usable(scope)
    |> Repo.all()
  end

  @doc "The embedding models `scope` may run, by name."
  @spec list_embedding_models(Scope.t()) :: [Model.t()]
  def list_embedding_models(%Scope{} = scope), do: list_mode(scope, :embedding)

  @doc "The classifier models (`completion_mode: :classifier`) `scope` may run, by name."
  @spec list_classifier_models(Scope.t()) :: [Model.t()]
  def list_classifier_models(%Scope{} = scope), do: list_mode(scope, :classifier)

  defp list_mode(scope, mode) do
    from(m in Model, where: m.completion_mode == ^mode, order_by: [asc: m.name], preload: ^model_preloads())
    |> usable(scope)
    |> Repo.all()
  end

  @doc "`{name, id}` select options for every model `scope` may run."
  def model_options(%Scope{} = scope), do: Enum.map(list_models(scope), &{&1.name, &1.id})

  @doc "The models `scope` may edit: its own, plus the site's for an admin, each with `connection_count`."
  def list_editable_models(%Scope{} = scope) do
    links = from(pm in ProviderModel, where: pm.ai_model_id == parent_as(:model).id, select: count())

    from(m in Model, as: :model, order_by: [asc: m.name], select_merge: %{connection_count: subquery(links)})
    |> editable(scope)
    |> Repo.all()
  end

  def get_model!(id), do: Model |> Repo.get!(id) |> Repo.preload(model_preloads())

  @doc "A model `scope` may run, or nil. Workers call it with the job initiator's scope."
  def get_model(%Scope{} = scope, id), do: from(m in Model, where: m.id == ^id) |> usable(scope) |> one_model()

  @doc "A model `scope` may edit, or nil."
  def get_editable_model(%Scope{} = scope, id),
    do: from(m in Model, where: m.id == ^id) |> editable(scope) |> one_model()

  defp one_model(query), do: query |> Repo.one() |> Repo.preload(model_preloads())

  @doc """
  Creates a model, `scope`'s own by default or the site's with `site: true` (`new_owner/2`).
  """
  @spec create_model(Scope.t(), map(), keyword()) ::
          {:ok, Model.t()}
          | {:held, Hold.t()}
          | {:error, Ecto.Changeset.t() | :unauthorized | :quota_exceeded | :hold_limit}
  def create_model(%Scope{} = scope, attrs \\ %{}, opts \\ []) do
    {followups, opts} = Keyword.pop(opts, :followups, [])

    with {:ok, owner} <- new_owner(scope, opts),
         :ok <- Quota.check_new_row(scope, owner, "quota.ai_models", Model) do
      changeset = new_model_changeset(owner, attrs)

      scope
      |> Gate.run(changeset, {__MODULE__, :create_model, [attrs, opts]}, [followups: followups], fn ->
        Repo.insert(changeset)
      end)
      |> Changes.notify(:ai)
    end
  end

  defp new_model_changeset(owner, attrs) do
    %Model{user_id: owner}
    |> Model.changeset(attrs)
    |> validate_caption_model()
    |> validate_caption_prompt()
  end

  @doc """
  Updates a model. Its `completion_mode` changes only to a mode every current use accepts
  (`mode_switch_blockers/2`); leaving embedding deletes the vectors it made, which are only a cache.
  """
  @spec update_model(Scope.t(), Model.t(), map()) ::
          {:ok, Model.t()} | {:held, Hold.t()} | {:error, Ecto.Changeset.t() | :unauthorized | :hold_limit}
  def update_model(%Scope{} = scope, %Model{} = model, attrs) do
    with :ok <- authorize_edit(scope, model) do
      changeset =
        model
        |> change_model(attrs)
        |> validate_caption_model()
        |> validate_caption_prompt()

      scope
      |> Gate.run(changeset, {__MODULE__, :update_model, [{:row, Model, model.id}, attrs]}, [], fn ->
        Repo.transaction(fn ->
          case Repo.update(changeset) do
            {:ok, updated} ->
              if model.completion_mode == :embedding and updated.completion_mode != :embedding,
                do: delete_embeddings(model.id)

              updated

            {:error, changeset} ->
              Repo.rollback(changeset)
          end
        end)
      end)
      |> Changes.notify(:ai)
    end
  end

  defp delete_embeddings(model_id) do
    Repo.delete_all(from(e in EntryEmbedding, where: e.ai_model_id == ^model_id))
    Repo.delete_all(from(e in MessageEmbedding, where: e.ai_model_id == ^model_id))
  end

  @doc """
  What keeps `model` from switching to `mode`, as translated phrases like `"2 chats"` or `"the
  Embedding model setting"`; `[]` when every current use accepts the new mode. Chats, participants,
  memory profiles, prompt bindings and models it captions for accept only `Model.text_modes/0`; a
  model setting accepts its kind's modes (`Settings.accepted_modes/1`). Assistant threads
  (`kind: :assistant`) accept only `:chat`. Past usage (stats, jobs, snapshots) never counts.
  """
  @spec mode_switch_blockers(Model.t(), :chat | :text | :embedding | :classifier) :: [String.t()]
  def mode_switch_blockers(%Model{id: nil}, _mode), do: []
  def mode_switch_blockers(%Model{completion_mode: mode}, mode), do: []

  def mode_switch_blockers(%Model{id: id}, new) do
    rows =
      case new do
        :chat ->
          []

        :text ->
          count = Repo.aggregate(from(c in Chat, where: c.kind == :assistant and c.ai_model_id == ^id), :count)
          if count > 0, do: [blocker_phrase(:assistant, count)], else: []

        _ ->
          for {schema, field, kind} <- [
                {Chat, :ai_model_id, :chat},
                {Participant, :ai_model_id, :participant},
                {Profile, :ai_model_id, :profile},
                {Binding, :ai_model_id, :binding},
                {Model, :caption_model_id, :captioned}
              ],
              count = Repo.aggregate(from(r in schema, where: field(r, ^field) == ^id), :count),
              count > 0,
              do: blocker_phrase(kind, count)
      end

    rows ++
      for %{models: kind} = use <- Settings.model_uses(id),
          new not in Settings.accepted_modes(kind),
          do: setting_phrase(use)
  end

  # Phrases completing "can't change to this mode while it is used by …" (errors domain: they are
  # part of a changeset message).
  defp blocker_phrase(:assistant, count),
    do:
      dngettext(
        "errors",
        "%{conversation_count} Mythweaver conversation",
        "%{conversation_count} Mythweaver conversations",
        count, conversation_count: Format.number(count))

  defp blocker_phrase(:chat, count),
    do: dngettext("errors", "%{chat_count} chat", "%{chat_count} chats", count, chat_count: Format.number(count))

  defp blocker_phrase(:participant, count),
    do:
      dngettext("errors", "%{participant_count} chat participant", "%{participant_count} chat participants", count,
        participant_count: Format.number(count)
      )

  defp blocker_phrase(:profile, count),
    do:
      dngettext("errors", "%{profile_count} memory profile", "%{profile_count} memory profiles", count,
        profile_count: Format.number(count)
      )

  defp blocker_phrase(:binding, count),
    do:
      dngettext("errors", "%{binding_count} prompt binding", "%{binding_count} prompt bindings", count,
        binding_count: Format.number(count)
      )

  defp blocker_phrase(:captioned, count),
    do:
      dngettext(
        "errors",
        "%{model_count} model as its caption model",
        "%{model_count} models as their caption model",
        count, model_count: Format.number(count))

  defp setting_phrase(%{label: label}) do
    gettext_comment("%{setting_name} is the translated name of a model setting, e.g. Embedding model.")
    dgettext("errors", "the %{setting_name} setting", setting_name: label)
  end

  defp validate_mode_switch(%Ecto.Changeset{data: model} = changeset) do
    case mode_switch_blockers(model, Ecto.Changeset.get_field(changeset, :completion_mode)) do
      [] ->
        changeset

      blockers ->
        gettext_comment(
          ~s(Shown under a model's mode select. %{blockers} is a list of phrases such as "2 chats" or "the Embedding model setting".)
        )

        Ecto.Changeset.add_error(
          changeset,
          :completion_mode,
          dgettext_noop("errors", "can't change to this mode while it is used by %{blockers}"),
          blockers: Format.list(blockers)
        )
    end
  end

  # The caption model describes the images, audio and video a model cannot take, so it must take at
  # least one of them itself. Same-owner rule as connections, read under this model's owner, so it is
  # the site's or that same owner's: a site model never names a personal captioner.
  defp validate_caption_model(changeset) do
    owner = Ecto.Changeset.get_field(changeset, :user_id)

    case Ecto.Changeset.get_field(changeset, :caption_model_id) do
      nil ->
        changeset

      id ->
        case Repo.get(Model, id) do
          %Model{user_id: captioner_owner} = captioner when captioner_owner in [nil, owner] ->
            if Model.sees_images?(captioner) or Model.hears_audio?(captioner) or Model.watches_video?(captioner),
              do: changeset,
              else:
                Ecto.Changeset.add_error(
                  changeset,
                  :caption_model_id,
                  dgettext_noop("errors", "must be a chat model that supports images, audio or video")
                )

          _missing_or_other_owner ->
            Ecto.Changeset.add_error(changeset, :caption_model_id, dgettext_noop("errors", "does not exist"))
        end
    end
  end

  # Like the caption model, the prompt is the site's or this model's owner's own.
  defp validate_caption_prompt(changeset) do
    owner = Ecto.Changeset.get_field(changeset, :user_id)

    case Ecto.Changeset.get_change(changeset, :caption_prompt_id) do
      nil ->
        changeset

      id ->
        prompts = Ownership.for_owner(Prompt, owner)

        if Repo.exists?(from(p in prompts, where: p.id == ^id and p.purpose == :caption)),
          do: changeset,
          else:
            Ecto.Changeset.add_error(changeset, :caption_prompt_id, dgettext_noop("errors", "must be a caption prompt"))
    end
  end

  @doc """
  `{name, id}` select options for every model that can describe images, audio or video for a model
  of `owner_id`'s (the site's, or that owner's own), except `exclude_id`.
  """
  def caption_model_options(%Scope{}, owner_id, exclude_id) do
    from(m in Model,
      where: m.completion_mode == :chat and (m.supports_images or m.supports_audio or m.supports_video),
      order_by: [asc: m.name],
      select: {m.name, m.id}
    )
    |> Ownership.for_owner(owner_id)
    |> Repo.all()
    |> Enum.reject(fn {_name, id} -> id == exclude_id end)
  end

  @doc """
  The site's default caption model: describes avatars, and AI-generated images in chats where no
  participant names one. It is `images.default_caption_model`, or the first caption-capable site model
  by name when that is unset or no longer qualifies; `:none` when `scope` may not run it.
  """
  @spec default_caption_model(Scope.t()) :: {:ok, Model.t()} | :none
  def default_caption_model(%Scope{} = scope) do
    chosen =
      case Settings.get(scope, "images.default_caption_model") do
        nil -> nil
        id -> Repo.one(from(m in site_caption_models(), where: m.id == ^id))
      end

    case chosen || Repo.one(from(m in site_caption_models(), order_by: [asc: m.name], limit: 1)) do
      %Model{} = model -> if usable?(scope, model), do: {:ok, model}, else: :none
      nil -> :none
    end
  end

  defp site_caption_models do
    from(m in Model, where: is_nil(m.user_id) and m.supports_images and m.completion_mode == :chat)
  end

  @doc "Deletes a model; its links cascade, the providers themselves are untouched."
  @spec delete_model(Scope.t(), Model.t()) :: {:ok, Model.t()} | {:error, Ecto.Changeset.t() | :unauthorized}
  def delete_model(%Scope{} = scope, %Model{} = model) do
    with :ok <- authorize_edit(scope, model), do: Changes.notify(Repo.delete(model), :ai)
  end

  @doc "The model's changeset, mode-switch rule included (`mode_switch_blockers/2`)."
  def change_model(%Model{} = model, attrs \\ %{}) do
    model |> Model.changeset(attrs) |> validate_mode_switch()
  end

  defp model_preloads, do: [provider_models: :provider]

  ## Discovery

  @doc """
  Asks `provider` which models it serves, annotating each entry against what this app already has.

  Returns `{:ok, [entry]}` where an entry is:

      %{
        id: String.t(),                          # the provider's wire id
        name: String.t(),                        # friendly name; falls back to `id`
        attrs: %{String.t() => term()},          # `Model` fields the payload advertised, if any
        model_id: Ecto.UUID.t() | nil,           # local Model with this `api_model_id`, if any
        linked?: boolean()                       # that local model is already linked to `provider`
      }

  The annotation is computed here rather than in the caller because it is two DB reads over the whole
  result set; a UI doing it per row would issue one query per advertised model.

  `{:error, reason}` is the adapter's own reason, untouched: `{:http_error, status, body}`,
  `{:transport_error, message}`, or `{:unexpected_body, body}`.
  """
  @spec discover_models(Scope.t(), Provider.t()) :: {:ok, [map()]} | {:error, term()}
  def discover_models(%Scope{} = scope, %Provider{} = provider) do
    module = Adapter.module_for(provider.adapter)

    with :ok <- authorize_edit(scope, provider),
         {:ok, entries} <- module.discover_models(provider) do
      {:ok, annotate_discovered(scope, provider, entries)}
    end
  end

  @doc """
  Checks that `provider` answers: its `/models` listing must come back HTTP 200 with a readable
  body (SillyTavern's "Connect" status check). `provider` need not be saved, so a connection form
  can be tested before it is stored (by anyone who may add one). Nothing is written.

  `{:ok, advertised_count}`, `{:error, :unauthorized}`, or `discover_models/2`'s adapter reasons. A
  provider whose `/models` is public (OpenRouter) passes with a bad key; `test_link/2` is the check
  that reaches auth.
  """
  @spec check_provider(Scope.t(), Provider.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def check_provider(%Scope{} = scope, %Provider{} = provider) do
    with :ok <- authorize_check(scope, provider),
         {:ok, entries} <- Adapter.module_for(provider.adapter).discover_models(provider) do
      {:ok, length(entries)}
    end
  end

  defp authorize_check(scope, %Provider{id: nil}), do: if(can_add?(scope), do: :ok, else: {:error, :unauthorized})
  defp authorize_check(scope, %Provider{} = provider), do: authorize_edit(scope, provider)

  @doc """
  Annotates discovery entries against current local state: which wire ids already exist as models, and
  which of those are already linked to `provider`.

  Separate from `discover_models/2` so a caller that just wrote a model or link can refresh the rows it
  is already displaying with no second HTTP request.
  """
  # Two set reads for the whole page rather than a lookup per row. `api_model_id` is the join key, not
  # `name`: the wire id is what the provider and the local row must agree on, and a user is free to
  # rename a local model. Only the provider owner's models count: those are the only ones it may link.
  def annotate_discovered(%Scope{}, %Provider{} = provider, entries) do
    wire_ids = Enum.map(entries, & &1.id)

    local =
      from(m in Model, where: m.api_model_id in ^wire_ids, select: {m.api_model_id, m.id})
      |> same_owner(provider.user_id)
      |> Repo.all()
      |> Map.new()

    linked =
      from(pm in ProviderModel,
        where: pm.provider_id == ^provider.id,
        select: pm.ai_model_id
      )
      |> Repo.all()
      |> MapSet.new()

    # Matches a `DiscoveredModel` or an already-annotated entry: `refresh_discovered/1` feeds this
    # function's own output back through it.
    Enum.map(entries, fn %{id: id, name: name, attrs: attrs} ->
      model_id = Map.get(local, id)

      %{
        id: id,
        name: presence(name) || id,
        attrs: attrs,
        model_id: model_id,
        linked?: model_id != nil and MapSet.member?(linked, model_id)
      }
    end)
  end

  # `/models` entries carry `name` only on some backends (llama-swap does, OpenAI does not), and an
  # empty string is as absent as `nil`.
  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_value), do: nil

  @doc """
  Creates a model from one annotated discovery entry and links it to `provider`, in one transaction.
  The model belongs to the provider's owner, so the two can be linked.

  The entry's `id` becomes `api_model_id`, its `name` is used verbatim, and its `attrs` (whatever the
  provider advertised: context/response limits, per-Mtok pricing, capability flags) are cast alongside.
  `notes` is never among them: it is user-authored, so a provider's `description` is dropped at the
  adapter. `completion_mode` is `:chat` unless the entry advertised an embedding model (OpenRouter's
  `architecture.output_modalities`). No other surveyed backend reports a mode, so for llama.cpp
  (`--embeddings`), vLLM and Ollama embedding models the caller passes `as: :embedding`, which
  adds the entry as an embedding model and drops its chat capability flags; `as: :classifier` does
  the same for a sequence classifier (llama-server `--pooling rank`).

  Returns `{:ok, %Model{}}`, `{:error, :unauthorized}`, or `{:error, %Ecto.Changeset{}}` from
  whichever step failed. Both writes roll back together: a name collision on the model or an
  already-linked pair leaves nothing behind.
  """
  @spec create_discovered_model(Scope.t(), Provider.t(), map(), [{:as, :embedding | :classifier}]) ::
          {:ok, Model.t()} | {:error, Ecto.Changeset.t() | :unauthorized}
  def create_discovered_model(scope, provider, entry, opts \\ [])

  def create_discovered_model(%Scope{} = scope, %Provider{} = provider, %{id: wire_id, name: name, attrs: attrs}, opts)
      when is_binary(wire_id) and is_binary(name) and is_map(attrs) do
    attrs =
      case opts[:as] do
        mode when mode in [:embedding, :classifier] ->
          attrs
          |> Map.reject(fn {key, _} -> String.starts_with?(key, "supports_") end)
          |> Map.put("completion_mode", to_string(mode))

        nil ->
          attrs
      end

    with :ok <- authorize_edit(scope, provider),
         :ok <- Quota.check_new_row(scope, provider.user_id, "quota.ai_models", Model) do
      Repo.transaction(fn ->
        # Identity pair merged last so an advertised key can never shadow `name` or `api_model_id`.
        model_attrs = Map.merge(attrs, %{"name" => name, "api_model_id" => wire_id})

        with {:ok, model} <- provider.user_id |> new_model_changeset(model_attrs) |> Repo.insert(),
             {:ok, _link} <- link_model(scope, provider, model) do
          model
        else
          {:error, %Ecto.Changeset{} = changeset} -> Repo.rollback(changeset)
        end
      end)
      # Again after the commit: `link_model/4`'s own notice ran inside the transaction.
      |> admission_changed()
      |> Changes.notify(:ai, provider.user_id)
    end
  end

  @doc """
  Links an already-local model to `provider` by the model's id, for a discovered entry this app
  already knows. `{:error, :not_found}` when the id does not resolve: a stale page whose model was
  deleted in another tab must not raise.
  """
  @spec link_discovered_model(Scope.t(), Provider.t(), Ecto.UUID.t()) ::
          {:ok, ProviderModel.t()} | {:error, Ecto.Changeset.t() | :not_found | :unauthorized}
  def link_discovered_model(%Scope{} = scope, %Provider{} = provider, model_id) do
    with :ok <- authorize_edit(scope, provider) do
      from(m in Model, where: m.id == ^model_id)
      |> same_owner(provider.user_id)
      |> one_model()
      |> case do
        nil -> {:error, :not_found}
        model -> link_model(scope, provider, model)
      end
    end
  end

  defp same_owner(query, owner_id), do: Ownership.owned_exactly(query, owner_id)

  @doc "`{name, id}` select options for the models `provider` may serve: those with its owner."
  def link_model_options(%Provider{} = provider) do
    from(m in Model, order_by: [asc: m.name], select: {m.name, m.id})
    |> same_owner(provider.user_id)
    |> Repo.all()
  end

  ## Links

  @doc """
  Links a model to a provider with the same owner (both the site's, or both one user's), so a site
  model never routes onto a personal key. The one exception crosses owners: a user may link their
  own connection to a model shared with them in `:own_key` mode (`Mythweaver.Sharing`); the link is
  theirs, as its provider is. A duplicate surfaces as the unique-constraint changeset error rather
  than a raise, so a UI can show it on the form.
  """
  @spec link_model(Scope.t(), Provider.t(), Model.t(), map()) ::
          {:ok, ProviderModel.t()} | {:error, Ecto.Changeset.t() | :unauthorized}
  def link_model(%Scope{} = scope, %Provider{} = provider, %Model{} = model, attrs \\ %{}) do
    with :ok <- authorize_edit(scope, provider),
         true <-
           model.user_id == provider.user_id || own_key_link?(scope, provider, model) || {:error, :unauthorized} do
      attrs
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.merge(%{"provider_id" => provider.id, "ai_model_id" => model.id})
      |> then(&ProviderModel.changeset(%ProviderModel{}, &1))
      |> Ecto.Changeset.put_change(:selection_deadline, joining_deadline(model.id))
      |> Repo.insert()
      |> admission_changed()
      |> Changes.notify(:ai, provider.user_id)
    end
  end

  defp own_key_link?(%Scope{user: %{id: uid}}, %Provider{user_id: uid}, %Model{id: model_id, user_id: owner})
       when is_binary(owner) do
    Repo.exists?(
      from(s in Share,
        where:
          s.item_type == :ai_model and s.item_id == ^model_id and s.user_id == ^uid and s.status == :accepted and
            s.ai_mode == :own_key
      )
    )
  end

  defp own_key_link?(_scope, _provider, _model), do: false

  @spec update_link(Scope.t(), ProviderModel.t(), map()) ::
          {:ok, ProviderModel.t()} | {:error, Ecto.Changeset.t() | :unauthorized}
  def update_link(%Scope{} = scope, %ProviderModel{} = link, attrs) do
    with :ok <- authorize_link(scope, link) do
      link
      |> ProviderModel.changeset(attrs)
      |> rebase_on_activation(link)
      |> Repo.update()
      |> admission_changed()
      |> Changes.notify(:ai, [nil, scope.user.id])
    end
  end

  # A link has its provider's owner (an own-key link to a shared model too).
  defp authorize_link(scope, %ProviderModel{provider_id: provider_id}) do
    owner = Repo.one(from(p in Provider, where: p.id == ^provider_id, select: struct(p, [:id, :user_id])))
    if owner, do: authorize_edit(scope, owner), else: {:error, :unauthorized}
  end

  # A link that was disabled, or whose weight just changed, holds a deadline that no longer relates
  # to its siblings': re-enabling one stuck at an old value hands it every call until it catches up,
  # and a weight change would otherwise burn off deadline accrued in the old step size. Both cases
  # rejoin at the active minimum, so the new share takes effect from the next selection.
  defp rebase_on_activation(changeset, %ProviderModel{} = link) do
    reactivated? = Ecto.Changeset.get_change(changeset, :enabled) == true and not link.enabled
    reweighted? = not is_nil(Ecto.Changeset.get_change(changeset, :weight))

    if reactivated? or reweighted? do
      Ecto.Changeset.put_change(changeset, :selection_deadline, joining_deadline(link.ai_model_id))
    else
      changeset
    end
  end

  @doc "One link by its own id, or `nil`. Preloaded for a UI that renders both sides."
  def get_link(id), do: ProviderModel |> Repo.get(id) |> Repo.preload([:provider, :model])

  @doc """
  The links from the scope user's own connections to `model`, each with its provider, by provider
  name: what a subscriber linked to a model shared with them in `:own_key` mode.
  """
  @spec list_own_links(Scope.t(), Model.t()) :: [ProviderModel.t()]
  def list_own_links(%Scope{user: %{id: uid}}, %Model{id: model_id}) do
    from(pm in ProviderModel,
      join: p in assoc(pm, :provider),
      where: pm.ai_model_id == ^model_id and p.user_id == ^uid,
      order_by: [asc: p.name],
      preload: [provider: p]
    )
    |> Repo.all()
  end

  def change_link(%ProviderModel{} = link, attrs \\ %{}) do
    ProviderModel.changeset(link, attrs)
  end

  @doc "Drops one link by row."
  @spec delete_link(Scope.t(), ProviderModel.t()) ::
          {:ok, ProviderModel.t()} | {:error, Ecto.Changeset.t() | :unauthorized}
  def delete_link(%Scope{} = scope, %ProviderModel{} = link) do
    with :ok <- authorize_link(scope, link),
         do: link |> Repo.delete() |> admission_changed() |> Changes.notify(:ai, [nil, scope.user.id])
  end

  ## Selection

  @doc """
  Picks the next enabled link for `model` and records the use, or `{:error, :no_provider}`.

  Ordering: provider `priority` first, so weighting distributes traffic *within* a priority tier and
  a priority-1 connection is always preferred while enabled ("free before paid"). Then
  `selection_deadline`, which is the total order inside a tier. Then `id`, which keeps the order
  total on the exact deadline ties equal weights produce constantly, so selection is deterministic
  rather than dependent on physical row order.

  `weight` is a share of traffic, not a preference order. Each link carries a virtual deadline;
  selection takes the smallest and advances it by `1 / weight`, so a weight-3 link advances in
  one-third steps and returns to the front three times as often as a weight-1 link. Over any full
  cycle the split is exact (weights 3/2/1 give exactly 3:2:1) and no link is ever starved, which
  is why this is a deadline schedule rather than a weighted random draw (a random draw hits the
  right ratio only in expectation and leaves a low-weight link with zero calls in short windows).

  Equal weights degenerate to plain round-robin: every deadline advances by 1, so the order is the
  insertion order and every link is served once before any repeats.

  Only the links `run_owner` (the user id whose run it is: the chat's owner, else the initiator; nil
  for none) may spend are candidates (`link_owners/2`): those on their own connections, the site's
  when they may use site models, and the model owner's when the model is shared with them in
  `:owner_key` mode. That last case needs the model owner to still hold `"sharing.ai.owner_key"`;
  when they don't and nothing else serves the run, it fails `{:owner_key_withdrawn, model_name}`.

  `opts`:

    * `:except_provider_ids`: links on these providers are not considered. The job scheduler passes
      the providers whose `max_concurrency` slots are all taken.
  """
  @spec next_provider_model(Model.t(), Ecto.UUID.t() | nil, keyword()) ::
          {:ok, ProviderModel.t()} | {:error, :no_provider | {:owner_key_withdrawn, String.t()}}
  def next_provider_model(%Model{} = model, run_owner, opts \\ []) do
    {query, failure} = candidate_links(model, run_owner, Keyword.get(opts, :except_provider_ids, []))

    Repo.transaction(fn ->
      Repo.one(from(m in Model, where: m.id == ^model.id, select: m.id, lock: "FOR UPDATE"))

      case Repo.one(query) do
        nil ->
          Repo.rollback(failure)

        link ->
          link = Repo.preload(link, [:provider, :model])

          link
          |> Ecto.Changeset.change(
            last_used_at: DateTime.utc_now(),
            use_count: link.use_count + 1,
            selection_deadline: link.selection_deadline + 1 / link.weight
          )
          |> Repo.update!()
      end
    end)
  end

  @doc """
  Whose run it is, for `next_provider_model/3`: in a chat (a `Chat` or its id), `scope`'s user when
  it spends its own models there (`Mythweaver.Chats.spends_own?/2`: the owner, or an `:own`
  member), else the chat's owner; outside a chat, `scope`'s user. A scope already swapped to the
  owner (`Chats.run_scope/2`) gets the owner.
  """
  @spec run_owner(Scope.t(), Chat.t() | Ecto.UUID.t() | nil) :: Ecto.UUID.t() | nil
  def run_owner(%Scope{} = scope, nil), do: scope.user && scope.user.id

  def run_owner(%Scope{} = scope, %Chat{} = chat),
    do: if(Chats.spends_own?(scope, chat), do: scope.user.id, else: chat.user_id)

  def run_owner(%Scope{} = scope, chat_id) when is_binary(chat_id) do
    case Repo.get(Chat, chat_id) do
      nil -> run_owner(scope, nil)
      chat -> run_owner(scope, chat)
    end
  end

  @doc """
  The link `next_provider_model/3` would pick now, without recording a use: what
  `Mythweaver.Permissions.Quota.check_spend/3` charges a run before it is queued.
  """
  @spec peek_provider_model(Model.t(), Ecto.UUID.t() | nil) ::
          {:ok, ProviderModel.t()} | {:error, :no_provider | {:owner_key_withdrawn, String.t()}}
  def peek_provider_model(%Model{} = model, run_owner) do
    {query, failure} = candidate_links(model, run_owner, [])

    case Repo.one(query) do
      nil -> {:error, failure}
      link -> {:ok, Repo.preload(link, [:provider, :model])}
    end
  end

  # The next-link query narrowed to the connections `run_owner` may spend, and the error when it
  # finds none: their own; the site's when they may use site models; the model owner's for an
  # accepted `:owner_key` share whose owner still holds `"sharing.ai.owner_key"`, else
  # `{:owner_key_withdrawn, name}`.
  defp candidate_links(%Model{} = model, run_owner, except) do
    {owners, site?, failure} =
      case run_owner && Accounts.get_user(run_owner) do
        nil ->
          {[], false, :no_provider}

        user ->
          site? = shared?(Scope.for_user(user))

          case owner_key_share?(model, user.id) && Accounts.get_user(model.user_id) do
            falsy when falsy in [nil, false] ->
              {[user.id], site?, :no_provider}

            owner ->
              if Scope.can?(Scope.for_user(owner), "sharing.ai.owner_key"),
                do: {[user.id, owner.id], site?, :no_provider},
                else: {[user.id], site?, {:owner_key_withdrawn, model.name}}
          end
      end

    query = where(next_link_query(model, except), [_pm, p], p.user_id in ^owners or (^site? and is_nil(p.user_id)))
    {query, failure}
  end

  defp owner_key_share?(%Model{user_id: nil}, _user_id), do: false
  defp owner_key_share?(%Model{user_id: user_id}, user_id), do: false

  defp owner_key_share?(%Model{} = model, user_id) do
    Repo.exists?(
      from(s in Share,
        where:
          s.item_type == :ai_model and s.item_id == ^model.id and s.user_id == ^user_id and s.status == :accepted and
            s.ai_mode == :owner_key
      )
    )
  end

  # The model-row lock taken first in `next_provider_model/3` serialises selection per model, so each
  # caller sees the deadline the previous caller advanced. A lock on the link row alone does not:
  # Postgres re-checks only the WHERE clause of a blocked `FOR UPDATE`, not the ORDER BY, so a second
  # caller would get the same link back. Preloads still run after this query.
  defp next_link_query(%Model{} = model, []) do
    from(pm in ProviderModel,
      join: p in assoc(pm, :provider),
      where: pm.ai_model_id == ^model.id and pm.enabled and p.enabled,
      order_by: [asc: p.priority, asc: pm.selection_deadline, asc: pm.id],
      limit: 1
    )
  end

  defp next_link_query(%Model{} = model, except_provider_ids),
    do: where(next_link_query(model, []), [pm], pm.provider_id not in ^except_provider_ids)

  # The deadline a link joining `model`'s rotation must start at: the smallest deadline among the
  # links already active. A joiner left at 0.0 while incumbents sit at 60.0 would win every call
  # until it caught up (measured as 30 consecutive calls in a three-link rotation). Returns 0.0 when
  # no active sibling exists, which is the first link's correct starting point.
  defp joining_deadline(ai_model_id) do
    from(pm in ProviderModel,
      join: p in assoc(pm, :provider),
      where: pm.ai_model_id == ^ai_model_id and pm.enabled and p.enabled,
      select: min(pm.selection_deadline)
    )
    |> Repo.one()
    |> Kernel.||(0.0)
  end

  @doc """
  The model `scope` runs when nothing more specific names one: `ai.default_model` (the user's
  choice, else the site's), or, when that is unset or names a model `scope` may no longer run
  (`usable?/2`), the single model `scope` may run, when there is exactly one.

  "Usable" also means reachable: at least one enabled link on an enabled provider. `AI.Model` has no
  `enabled` flag of its own, so reachability is the only definition of "configured" available. A
  chosen model is not checked for reachability: an unreachable choice fails when it runs, rather
  than silently billing another connection.

  `{:error, :no_model}` when nothing is reachable, `{:error, :ambiguous_model}` when more than one is:
  a silent pick among several would bill the wrong connection.
  """
  @spec default_model(Scope.t()) :: {:ok, Model.t()} | {:error, :no_model | :ambiguous_model}
  def default_model(%Scope{} = scope) do
    chosen =
      case Settings.get(scope, "ai.default_model") do
        nil -> nil
        id -> from(m in Model, where: m.id == ^id) |> usable(scope) |> Repo.one()
      end

    if chosen, do: {:ok, Repo.preload(chosen, model_preloads())}, else: sole_reachable_model(scope)
  end

  defp sole_reachable_model(scope) do
    from(m in Model,
      join: pm in assoc(m, :provider_models),
      join: p in assoc(pm, :provider),
      where: pm.enabled and p.enabled and m.completion_mode in ^Model.text_modes(),
      distinct: true,
      limit: 2
    )
    |> usable(scope)
    |> Repo.all()
    |> case do
      [model] -> {:ok, Repo.preload(model, model_preloads())}
      [] -> {:error, :no_model}
      _many -> {:error, :ambiguous_model}
    end
  end

  ## Completions

  # A test bills real tokens; this is enough for a short greeting.
  @test_max_tokens 16

  @doc """
  Sends one "Hi" through `link` (SillyTavern's "Test Message") and returns `{:ok, %Completion{}}`, or
  `{:ok, %Embedding{}}` for an embedding or classifier model.

  Selection is bypassed: the request goes to this link even when it is disabled, and the use is not
  recorded, so a test never skews rotation. The reply is capped at #{@test_max_tokens} tokens and
  thinking is not requested: a dialect's thinking budget derives from `max_tokens` and could reject
  the cap. `link` must have `:provider` and `:model` loaded, as `get_link/1` returns it.

  Deliberately outside `Mythweaver.Jobs`: a test is a connection check the user is watching, so it
  takes no provider slot, writes no job row and is never queued behind generations.
  """
  @spec test_link(Scope.t(), ProviderModel.t()) :: {:ok, Completion.t() | Embedding.t()} | {:error, term()}
  def test_link(%Scope{} = scope, %ProviderModel{provider: %Provider{} = provider, model: %Model{} = model} = link) do
    with :ok <- authorize_edit(scope, provider) do
      adapter = Adapter.module_for(provider.adapter)
      model = %{model | sampler: %{model.sampler | max_tokens: @test_max_tokens, thinking: nil}}

      case model.completion_mode do
        :embedding ->
          adapter.embed(provider, embedding_request(model, link, ["Hi"]))

        :classifier ->
          adapter.embed(provider, classification_request(model, link, ["Hi"]))

        :chat ->
          adapter.complete(
            provider,
            build_request(model, link, %{messages: [%Request.Message{role: :user, content: "Hi"}]})
          )

        :text ->
          adapter.complete(provider, build_request(model, link, %{prompt: "Hi"}))
      end
    end
  end

  @doc """
  Embeds `texts` with `model`, choosing one of `run_owner`'s links (`next_provider_model/3`) by
  weighted selection, and returns the vectors in input order with the link used.

  Deliberately outside `Mythweaver.Jobs`: it is one short, non-streaming call made while a prompt is
  being assembled, so queueing it behind generations would stall the reply. It takes no provider slot.

  A model that is not an embedding model gives `{:error, {:invalid_request, :not_embedding_model}}`.
  """
  @spec embed(Model.t(), Ecto.UUID.t() | nil, [String.t()]) ::
          {:ok, Embedding.t(), ProviderModel.t()} | {:error, term()}
  def embed(%Model{completion_mode: :embedding} = model, run_owner, [_ | _] = texts) do
    with {:ok, link} <- next_provider_model(model, run_owner),
         {:ok, embedding} <-
           Adapter.module_for(link.provider.adapter).embed(link.provider, embedding_request(model, link, texts)),
         do: {:ok, embedding, link}
  end

  def embed(%Model{}, _run_owner, _texts), do: {:error, {:invalid_request, :not_embedding_model}}

  @doc """
  Classifies `texts` with a classifier model (`completion_mode: :classifier`), choosing one of
  `run_owner`'s links by weighted selection: each text's raw logits, one per label in the model's own label order, with
  the link used. Sent to `/embeddings` as llama-server serves a sequence classifier
  (`--embedding --pooling rank`), with `embd_normalize: -1`: its default L2 normalization would
  scale the logits.

  Outside `Mythweaver.Jobs` like `embed/2`: one short call that must not wait behind generations on
  the same connection. A model that is not a classifier gives
  `{:error, {:invalid_request, :not_classifier_model}}`.
  """
  @spec classify(Model.t(), Ecto.UUID.t() | nil, [String.t()]) ::
          {:ok, Embedding.t(), ProviderModel.t()} | {:error, term()}
  def classify(%Model{completion_mode: :classifier} = model, run_owner, [_ | _] = texts) do
    with {:ok, link} <- next_provider_model(model, run_owner),
         {:ok, logits} <-
           Adapter.module_for(link.provider.adapter).embed(link.provider, classification_request(model, link, texts)),
         do: {:ok, logits, link}
  end

  def classify(%Model{}, _run_owner, _texts), do: {:error, {:invalid_request, :not_classifier_model}}

  # The request's own key goes last in `merged_extra_body/4`, so no model or link layer can turn the
  # normalization back on.
  defp classification_request(model, link, texts) do
    %EmbeddingRequest{
      model_id: ProviderModel.effective_model_id(link),
      input: texts,
      extra_body: merged_extra_body(model, nil, link, %{"embd_normalize" => -1})
    }
  end

  defp embedding_request(model, link, texts) do
    %EmbeddingRequest{
      model_id: ProviderModel.effective_model_id(link),
      input: texts,
      extra_body: merged_extra_body(model, nil, link, nil)
    }
  end

  @doc """
  Streams one completion for `model`, choosing one of `run_owner`'s links (`next_provider_model/3`)
  by weighted selection.

  `input` is `%{messages: [%Mythweaver.AI.Request.Message{}]}` for a chat model or `%{prompt: "…"}` for
  a text model, matching the model's `completion_mode`. Optional keys adjust the one request
  (`build_request/3`), e.g. `thinking:` a prompt's reasoning effort, never above the model's own.

  `on_event` is invoked in the calling process for each `Mythweaver.AI.StreamEvent` as it arrives:
  first one `%StreamEvent.Request{url:, body:}` carrying the exact JSON body about to be sent (no
  headers), then `%StreamEvent.Delta{text:}` and `%StreamEvent.Reasoning{text:}` as tokens land, then
  one final `%StreamEvent.Done{finish_reason:}`. Before the first token there may also be any number
  of optional `%StreamEvent.PromptProgress{done:, total:}` events, on connections whose backend
  reports prompt processing (`Mythweaver.AI.Provider.Adapter`, "Progress contract").
  Its return value is ignored.

  Returns `{:ok, %Completion{}, %ProviderModel{}}` with the fully assembled completion once the stream
  ends, so a caller that rendered deltas live can still persist the final text and token counts.

  The use is counted up front: selection has already incremented `use_count`/`last_used_at` before
  the request runs, so a failed stream still counts as a use and a broken provider rotates away
  instead of being retried immediately. There is no failover; `{:error, reason}` from the adapter
  reaches the caller untouched.
  """
  def stream(%Model{} = model, run_owner, input, on_event) when is_map(input) and is_function(on_event, 1) do
    with {:ok, link} <- next_provider_model(model, run_owner), do: stream_link(link, model, input, on_event)
  end

  @doc """
  Streams one completion through `link` with no selection: the caller already chose it (the job
  scheduler, which picks a link only when its provider has a free slot). `link` must have `:provider`
  and `:model` loaded, as `next_provider_model/3` returns it. Same `input`, events and return as
  `stream/3`.
  """
  def stream_link(%ProviderModel{provider: %Provider{} = provider} = link, %Model{} = model, input, on_event)
      when is_map(input) and is_function(on_event, 1) do
    with {:ok, %Completion{} = completion} <-
           Adapter.module_for(provider.adapter).stream(provider, build_request(model, link, input), on_event) do
      {:ok, completion, link}
    end
  end

  # One definition of the request contract, shared by both wire paths, so the struct cannot drift.
  #
  # Six optional `input` keys let a caller adjust one request without editing the model: `:sampler`,
  # `SamplerParams` field overrides merged over `model.sampler` (nil values ignored); `:thinking`, the
  # reasoning effort the request's prompt asks for, capped by the model's own level
  # (`SamplerParams.cap_thinking/2`); `:extra_body`, deep-merged after every other layer; `:stop`,
  # strings that end the reply without being sent (`Request.stop` adds the sampler's sent
  # `stop_sequences`, so both are enforced locally); `:session_id`, copied to `Request.session_id`
  # untouched; and `:tools`, the functions offered (`Request.tools`).
  defp build_request(%Model{} = model, %ProviderModel{} = link, input) do
    sampler = model.sampler |> override_sampler(input[:sampler]) |> request_thinking(model, input[:thinking])

    %Request{
      model_id: ProviderModel.effective_model_id(link),
      mode: model.completion_mode,
      sampler: sampler,
      sampler_dialect: link.sampler_dialect || link.provider.sampler_dialect,
      messages: input[:messages],
      prompt: input[:prompt],
      extra_body: merged_extra_body(model, sampler, link, input[:extra_body]),
      reasoning_tags: Model.reasoning_tags(model),
      stop: Enum.uniq(((sampler && sampler.stop_sequences) || []) ++ (input[:stop] || [])),
      session_id: input[:session_id],
      tools: input[:tools] || []
    }
  end

  @doc "The reasoning effort a request asking for `requested` gets on `model` (`SamplerParams.cap_thinking/2`)."
  @spec effective_thinking(Model.t(), SamplerParams.thinking() | nil) :: SamplerParams.thinking() | nil
  def effective_thinking(%Model{sampler: sampler}, requested),
    do: SamplerParams.cap_thinking(requested, sampler && sampler.thinking)

  defp request_thinking(sampler, _model, nil), do: sampler

  defp request_thinking(sampler, model, requested),
    do: %{(sampler || %SamplerParams{}) | thinking: effective_thinking(model, requested)}

  defp override_sampler(sampler, overrides) when overrides in [nil, %{}], do: sampler

  defp override_sampler(sampler, overrides) do
    Enum.reduce(overrides, sampler || %SamplerParams{}, fn
      {_key, nil}, acc -> acc
      {key, value}, acc -> Map.replace!(acc, key, value)
    end)
  end

  # Thinking dialect fragment is the base; model, then connection, then link, then the request override it.
  defp merged_extra_body(model, sampler, link, request_body) do
    [thinking_body(sampler, link), model.extra_body, link.provider.extra_body, link.extra_body, request_body]
    |> Enum.reduce(%{}, &deep_merge(&2, &1 || %{}))
  end

  # The connection's dialect, unless the link overrides it; nil on both sends nothing.
  defp thinking_body(%SamplerParams{thinking: effort} = sampler, %ProviderModel{} = link) when not is_nil(effort) do
    case link.thinking_dialect || link.provider.thinking_dialect do
      nil -> %{}
      dialect -> ThinkingDialect.module_for(dialect).body(effort, sampler)
    end
  end

  defp thinking_body(_sampler, _link), do: %{}

  # Nested objects (e.g. `chat_template_kwargs`) combine across layers; any other value is replaced.
  defp deep_merge(left, right) do
    Map.merge(left, right, fn
      _key, %{} = l, %{} = r -> deep_merge(l, r)
      _key, _l, r -> r
    end)
  end
end
