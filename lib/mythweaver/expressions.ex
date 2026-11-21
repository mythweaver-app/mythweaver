defmodule Mythweaver.Expressions do
  @moduledoc """
  Character expressions, after SillyTavern's Expression Images extension and expressions-plus.

  After a finished reply, and after a message the player sends or edits, `classify_later/5` queues
  an `:expression` job (`Mythweaver.Expressions.Workers.Classify`) that asks the
  `expressions.classifier_model` to score the message's emotions (0..100). `apply_scores/3` resolves
  the scores into one label through the character's rule profile (`Mythweaver.Expressions.Resolver`)
  and stores it, with a sprite of that label, on the message body; the sprite then takes the place of
  the author's portrait beside the message. With no classifier model set, nothing is queued.

  Labels are the 28 GoEmotions labels (`base_labels/0`), the character's custom labels and its
  profile's rule names. Sprites (`Sprite`) belong to a character, in its Default set (`outfit_id` nil)
  or an `Outfit`; a chat participant picks the outfit. Rule profiles (`Profile`) are owned rows under
  `Mythweaver.Ownership`; their writes, and every sprite or outfit write, announce `:characters`.
  """

  use Gettext, backend: Mythweaver.Gettext

  import Ecto.Query

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.AI
  alias Mythweaver.AI.Model
  alias Mythweaver.Attachments
  alias Mythweaver.Attachments.Attachment
  alias Mythweaver.Changes
  alias Mythweaver.Characters.Character
  alias Mythweaver.Chats
  alias Mythweaver.Chats.Chat
  alias Mythweaver.Chats.Participant
  alias Mythweaver.Expressions.Encoder
  alias Mythweaver.Expressions.Outfit
  alias Mythweaver.Expressions.Profile
  alias Mythweaver.Expressions.Resolver
  alias Mythweaver.Expressions.Sprite
  alias Mythweaver.Jobs
  alias Mythweaver.Messages
  alias Mythweaver.Messages.Message
  alias Mythweaver.Messages.MessageBody
  alias Mythweaver.Ownership
  alias Mythweaver.Repo
  alias Mythweaver.Settings

  # SillyTavern's order (`public/scripts/extensions/expressions/index.js`), which is also GoEmotions'
  # label id order: a classifier model's logits arrive in exactly this order (`Encoder`).
  @base_labels ~w(admiration amusement anger annoyance approval caring confusion curiosity desire
                  disappointment disapproval disgust embarrassment excitement fear gratitude grief joy
                  love nervousness optimism pride realization relief remorse sadness surprise neutral)

  @max_pack_entries 1000
  @max_pack_bytes 500_000_000

  ## Labels

  @doc "The 28 GoEmotions labels the classifier always rates."
  @spec base_labels() :: [String.t()]
  def base_labels, do: @base_labels

  @doc """
  Whether `label` is a usable expression label: 1-40 of `a-z`, `0-9` and `_`. No `-` or `.`, which
  separate a sprite file name's label from its suffix (`joy-2.png`, `joy.alt.png`).
  """
  @spec valid_label?(term()) :: boolean()
  def valid_label?(label) when is_binary(label), do: Regex.match?(~r/^[a-z0-9_]{1,40}$/, label)
  def valid_label?(_label), do: false

  @doc "The labels the classifier rates for `character`: the base labels, then its custom ones."
  @spec classifier_labels(Character.t()) :: [String.t()]
  def classifier_labels(%Character{expression_labels: labels}), do: @base_labels ++ labels

  @doc "Every label of `character` under `profile`: the classifier labels, then the enabled rule names."
  @spec labels(Character.t(), Profile.t() | nil) :: [String.t()]
  def labels(%Character{} = character, profile) do
    rules = if profile, do: for(r <- profile.rules, r.enabled, do: r.name), else: []
    Enum.uniq(classifier_labels(character) ++ rules)
  end

  @doc """
  The label a sprite file name stands for, SillyTavern's way: `Joy.png`, `joy-2.webp` and
  `joy.expressive.png` are all `joy`.
  """
  @spec label_from_filename(String.t()) :: {:ok, String.t()} | :error
  def label_from_filename(name) when is_binary(name) do
    label =
      name
      |> Path.basename()
      |> Path.rootname()
      |> String.downcase()
      |> String.split(~r/[.\-]/, parts: 2)
      |> hd()

    if valid_label?(label), do: {:ok, label}, else: :error
  end

  ## Profiles

  @doc "Rule profiles `scope` may use: the site's plus its own, by name."
  @spec list_profiles(Scope.t()) :: [Profile.t()]
  def list_profiles(%Scope{} = scope), do: profiles_query() |> Ownership.usable(scope) |> Repo.all()

  @doc "Rule profiles `scope` may edit, by name."
  @spec list_editable_profiles(Scope.t()) :: [Profile.t()]
  def list_editable_profiles(%Scope{} = scope), do: profiles_query() |> Ownership.editable(scope) |> Repo.all()

  defp profiles_query, do: from(p in Profile, order_by: [asc: p.name, asc: p.id])

  @doc "A profile `scope` may use, or nil."
  @spec get_profile(Scope.t(), term()) :: Profile.t() | nil
  def get_profile(%Scope{} = scope, id), do: get_owned(Ownership.usable(Profile, scope), id)

  @doc "A profile `scope` may edit, or nil."
  @spec get_editable_profile(Scope.t(), term()) :: Profile.t() | nil
  def get_editable_profile(%Scope{} = scope, id), do: get_owned(Ownership.editable(Profile, scope), id)

  defp get_owned(query, id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> Repo.get(query, id)
      :error -> nil
    end
  end

  def change_profile(%Profile{} = profile, attrs \\ %{}), do: Profile.changeset(profile, attrs)

  @doc "Creates a profile owned per `Ownership.new_owner/3`: `scope`'s own, or the site's with `site: true`."
  @spec create_profile(Scope.t(), map(), keyword()) :: {:ok, Profile.t()} | {:error, Ecto.Changeset.t() | :unauthorized}
  def create_profile(%Scope{} = scope, attrs \\ %{}, opts \\ []) do
    with {:ok, owner} <- Ownership.new_owner(scope, Profile, opts) do
      %Profile{user_id: owner, rules: []}
      |> Profile.changeset(attrs)
      |> Repo.insert()
      |> Changes.notify(:characters)
    end
  end

  @spec update_profile(Scope.t(), Profile.t(), map()) ::
          {:ok, Profile.t()} | {:error, Ecto.Changeset.t() | :unauthorized}
  def update_profile(%Scope{} = scope, %Profile{} = profile, attrs) do
    with :ok <- Ownership.authorize_edit(scope, profile) do
      profile |> Profile.changeset(attrs) |> Repo.update() |> Changes.notify(:characters)
    end
  end

  @doc "Deletes a profile; characters using it fall back to the default profile."
  @spec delete_profile(Scope.t(), Profile.t()) :: {:ok, Profile.t()} | {:error, :unauthorized}
  def delete_profile(%Scope{} = scope, %Profile{} = profile) do
    with :ok <- Ownership.authorize_delete(scope, profile),
         do: profile |> Repo.delete() |> Changes.notify(:characters)
  end

  @doc """
  The rule profile `character` resolves with, for `scope` (the chat owner): its own
  `expression_profile_id`, else the `expressions.default_profile` setting, else nil. A profile that
  is gone, or one the owner may not reference, falls through.
  """
  @spec effective_profile(Scope.t(), Character.t()) :: Profile.t() | nil
  def effective_profile(%Scope{} = scope, %Character{} = character) do
    load_profile(character.expression_profile_id, character.user_id) ||
      load_profile(Settings.get(scope, "expressions.default_profile"), scope_user_id(scope))
  end

  defp load_profile(nil, _owner_id), do: nil
  defp load_profile(id, owner_id), do: get_owned(Ownership.for_owner(Profile, owner_id), id)

  defp scope_user_id(%Scope{user: %{id: id}}), do: id
  defp scope_user_id(%Scope{}), do: nil

  ## Character settings

  @doc "A changeset for the character's expression settings."
  def change_settings(%Character{} = character, attrs \\ %{}), do: Character.expression_changeset(character, attrs)

  @doc "Updates the character's custom labels, fallback label and rule profile."
  @spec update_settings(Scope.t(), Character.t(), map()) ::
          {:ok, Character.t()} | {:error, Ecto.Changeset.t() | :unauthorized}
  def update_settings(%Scope{} = scope, %Character{} = character, attrs) do
    with :ok <- Ownership.authorize_edit(scope, character) do
      character
      |> Character.expression_changeset(attrs)
      |> validate_profile_reference(character.user_id)
      |> Repo.update()
      |> Changes.notify(:characters)
    end
  end

  defp validate_profile_reference(changeset, owner_id) do
    case Ecto.Changeset.get_change(changeset, :expression_profile_id) do
      nil ->
        changeset

      id ->
        case Repo.get(Profile, id) do
          %Profile{} = profile ->
            if Ownership.reference_ok?(owner_id, profile),
              do: changeset,
              else:
                Ecto.Changeset.add_error(
                  changeset,
                  :expression_profile_id,
                  dgettext_noop("errors", "is not available to this character")
                )

          nil ->
            Ecto.Changeset.add_error(
              changeset,
              :expression_profile_id,
              dgettext_noop("errors", "is not available to this character")
            )
        end
    end
  end

  ## Outfits

  @doc "The character's outfits, in order."
  @spec list_outfits(Scope.t(), Character.t()) :: [Outfit.t()]
  def list_outfits(%Scope{}, %Character{id: id}) do
    Repo.all(from(o in Outfit, where: o.character_id == ^id, order_by: [asc: o.position, asc: o.name]))
  end

  @spec create_outfit(Scope.t(), Character.t(), String.t()) ::
          {:ok, Outfit.t()} | {:error, Ecto.Changeset.t() | :unauthorized}
  def create_outfit(%Scope{} = scope, %Character{} = character, name) do
    with :ok <- Ownership.authorize_edit(scope, character) do
      position =
        Repo.one(from(o in Outfit, where: o.character_id == ^character.id, select: max(o.position))) || -1

      %Outfit{character_id: character.id, position: position + 1}
      |> Outfit.changeset(%{name: name})
      |> Repo.insert()
      |> Changes.notify(:characters, character.user_id)
    end
  end

  @doc "Deletes an outfit and its sprites, and their files."
  @spec delete_outfit(Scope.t(), Outfit.t()) :: {:ok, Outfit.t()} | {:error, :unauthorized}
  def delete_outfit(%Scope{} = scope, %Outfit{} = outfit) do
    character = Repo.get!(Character, outfit.character_id)

    with :ok <- Ownership.authorize_edit(scope, character) do
      files = Repo.all(from(s in Sprite, where: s.outfit_id == ^outfit.id, select: s.attachment_id))
      result = Repo.delete(outfit)
      if match?({:ok, _}, result), do: Attachments.delete_orphaned(files)
      Changes.notify(result, :characters, character.user_id)
    end
  end

  @doc "An outfit `scope` may edit (through its character), or nil."
  @spec get_editable_outfit(Scope.t(), term()) :: Outfit.t() | nil
  def get_editable_outfit(%Scope{} = scope, id), do: get_editable_part(scope, Outfit, id)

  defp get_editable_part(scope, schema, id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %{character_id: character_id} = row <- Repo.get(schema, id),
         %Character{} = character <- Repo.get(Character, character_id),
         :ok <- Ownership.authorize_edit(scope, character) do
      row
    else
      _ -> nil
    end
  end

  ## Sprites

  @doc "Every sprite of the character, with its attachment, oldest first."
  @spec list_sprites(Scope.t(), Character.t()) :: [Sprite.t()]
  def list_sprites(%Scope{}, %Character{id: id}), do: sprites_of(id)

  defp sprites_of(character_id) do
    Repo.all(
      from(s in Sprite,
        where: s.character_id == ^character_id,
        order_by: [asc: s.inserted_at, asc: s.id],
        preload: :attachment
      )
    )
  end

  @doc """
  Adds one sprite per `{label, attachment}` to the character's `outfit_id` set (nil: Default). A label
  the character does not know yet (`labels/2`) becomes a custom label in the same transaction.
  """
  @spec add_sprites(Scope.t(), Character.t(), Ecto.UUID.t() | nil, [{String.t(), Attachment.t()}]) ::
          {:ok, %{sprites: [Sprite.t()], new_labels: [String.t()]}}
          | {:error, :unauthorized | :invalid_outfit | :invalid_label}
  def add_sprites(%Scope{} = scope, %Character{} = character, outfit_id, pairs) do
    with :ok <- Ownership.authorize_edit(scope, character),
         :ok <- check_outfit(character, outfit_id),
         :ok <- if(Enum.all?(pairs, fn {label, _} -> valid_label?(label) end), do: :ok, else: {:error, :invalid_label}) do
      Repo.transaction(fn ->
        # Locked and re-read: two uploads finishing together must not drop each other's new labels.
        fresh = Repo.one!(from(c in Character, where: c.id == ^character.id, lock: "FOR UPDATE"))
        known = labels(fresh, effective_profile(scope, fresh))
        new_labels = pairs |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.reject(&(&1 in known))

        if new_labels != [] do
          fresh
          |> Character.expression_changeset(%{expression_labels: fresh.expression_labels ++ new_labels})
          |> Repo.update!()
        end

        sprites =
          for {label, %Attachment{status: :ready} = attachment} <- pairs do
            %Sprite{character_id: character.id, outfit_id: outfit_id, attachment_id: attachment.id, label: label}
            |> Repo.insert!()
            |> Map.put(:attachment, attachment)
          end

        %{sprites: sprites, new_labels: new_labels}
      end)
      |> Changes.notify(:characters, character.user_id)
    end
  end

  defp check_outfit(_character, nil), do: :ok

  defp check_outfit(%Character{id: id}, outfit_id) do
    if Repo.exists?(from(o in Outfit, where: o.id == ^outfit_id and o.character_id == ^id)),
      do: :ok,
      else: {:error, :invalid_outfit}
  end

  @doc "Deletes a sprite and its file."
  @spec delete_sprite(Scope.t(), Sprite.t()) :: {:ok, Sprite.t()} | {:error, :unauthorized}
  def delete_sprite(%Scope{} = scope, %Sprite{} = sprite) do
    character = Repo.get!(Character, sprite.character_id)

    with :ok <- Ownership.authorize_edit(scope, character) do
      result = Repo.delete(sprite)
      if match?({:ok, _}, result), do: Attachments.delete_orphaned([sprite.attachment_id])
      Changes.notify(result, :characters, character.user_id)
    end
  end

  @doc "A sprite `scope` may edit (through its character), or nil."
  @spec get_editable_sprite(Scope.t(), term()) :: Sprite.t() | nil
  def get_editable_sprite(%Scope{} = scope, id), do: get_editable_part(scope, Sprite, id)

  @doc "The labels with at least one sprite in `outfit_id`'s set (nil: Default)."
  @spec available([Sprite.t()], Ecto.UUID.t() | nil) :: MapSet.t(String.t())
  def available(sprites, outfit_id), do: for(%{outfit_id: ^outfit_id, label: l} <- sprites, into: MapSet.new(), do: l)

  @doc "`outfit_id`'s sprites of `label`."
  @spec sprites_for([Sprite.t()], Ecto.UUID.t() | nil, String.t()) :: [Sprite.t()]
  def sprites_for(sprites, outfit_id, label),
    do: Enum.filter(sprites, &(&1.outfit_id == outfit_id and &1.label == label))

  @doc "Whether the character has any sprite."
  @spec has_sprites?(Ecto.UUID.t()) :: boolean()
  def has_sprites?(character_id), do: Repo.exists?(from(s in Sprite, where: s.character_id == ^character_id))

  ## Sprite packs

  @doc """
  Imports a SillyTavern sprite pack: a ZIP of `label.png`-style images. Root files go to `outfit_id`
  (nil: Default); files one folder deep go to the outfit named after the folder, created when missing
  (expressions-plus subfolder sets). Deeper files, unparseable names and files that are not images are
  reported in `skipped`; directories, `__MACOSX/` and dotfiles are ignored.
  """
  @spec import_pack(Scope.t(), Character.t(), Path.t(), Ecto.UUID.t() | nil) ::
          {:ok, %{added: non_neg_integer(), skipped: [String.t()], outfits: [String.t()], new_labels: [String.t()]}}
          | {:error, :unauthorized | :invalid_outfit | :invalid_zip | :too_large}
  def import_pack(%Scope{} = scope, %Character{} = character, zip_path, outfit_id) do
    path = String.to_charlist(zip_path)

    with :ok <- Ownership.authorize_edit(scope, character),
         :ok <- check_outfit(character, outfit_id),
         :ok <- check_pack(path),
         {:ok, files} <- unzip(path) do
      {groups, skipped} = store_pack_files(scope, files)
      import_groups(scope, character, outfit_id, groups, skipped)
    end
  end

  defp check_pack(path) do
    case :zip.list_dir(path) do
      {:ok, entries} ->
        files = for {:zip_file, _name, info, _comment, _offset, _size} <- entries, do: File.Stat.from_record(info)

        if length(files) > @max_pack_entries or Enum.sum_by(files, & &1.size) > @max_pack_bytes,
          do: {:error, :too_large},
          else: :ok

      {:error, _} ->
        {:error, :invalid_zip}
    end
  end

  defp unzip(path) do
    case :zip.unzip(path, [:memory]) do
      {:ok, files} -> {:ok, files}
      {:error, _} -> {:error, :invalid_zip}
    end
  end

  # `{%{:default | folder_name => [{label, attachment}]}, skipped}`. Files are stored before any
  # transaction opens.
  defp store_pack_files(scope, files) do
    {groups, skipped} =
      files
      |> Enum.map(fn {name, bin} -> {to_string(name), bin} end)
      |> Enum.reject(fn {name, _} -> ignored_entry?(name) end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.reduce({%{}, []}, fn {name, bin}, {groups, skipped} ->
        with {:ok, group, file} <- pack_group(name),
             {:ok, label} <- label_from_filename(file),
             {:ok, attachment} <- Attachments.store_binary(bin, filename: file, kinds: [:image], quota_scope: scope) do
          {Map.update(groups, group, [{label, attachment}], &[{label, attachment} | &1]), skipped}
        else
          _ -> {groups, [name | skipped]}
        end
      end)

    {Map.new(groups, fn {group, pairs} -> {group, Enum.reverse(pairs)} end), Enum.reverse(skipped)}
  end

  defp ignored_entry?(name) do
    String.ends_with?(name, "/") or String.starts_with?(name, "__MACOSX/") or
      name |> Path.split() |> Enum.any?(&String.starts_with?(&1, "."))
  end

  defp pack_group(name) do
    case Path.split(name) do
      [file] -> {:ok, :default, file}
      [folder, file] -> {:ok, folder, file}
      _ -> :error
    end
  end

  defp import_groups(scope, character, outfit_id, groups, skipped) do
    existing = Map.new(list_outfits(scope, character), &{&1.name, &1.id})

    Enum.reduce(groups, {:ok, %{added: 0, skipped: skipped, outfits: [], new_labels: []}}, fn {group, pairs},
                                                                                              {:ok, acc} ->
      target =
        case group do
          :default -> {:ok, outfit_id, nil}
          name when is_map_key(existing, name) -> {:ok, existing[name], nil}
          name -> with {:ok, outfit} <- create_outfit(scope, character, name), do: {:ok, outfit.id, name}
        end

      with {:ok, target_id, created} <- target,
           {:ok, %{sprites: sprites, new_labels: new_labels}} <- add_sprites(scope, character, target_id, pairs) do
        {:ok,
         %{
           acc
           | added: acc.added + length(sprites),
             outfits: acc.outfits ++ List.wrap(created),
             new_labels: Enum.uniq(acc.new_labels ++ new_labels)
         }}
      else
        _ ->
          Attachments.delete_orphaned(Enum.map(pairs, fn {_, a} -> a.id end))
          names = Enum.map(pairs, fn {_, a} -> if group == :default, do: a.filename, else: "#{group}/#{a.filename}" end)
          {:ok, %{acc | skipped: acc.skipped ++ names}}
      end
    end)
  end

  ## Classification

  @doc """
  Classifies `body_id` of `message_id` when classification applies: a usable
  `expressions.classifier_model`, a roleplay chat, a character author with sprites, and a non-blank
  body. A chat or text model gets an `:expression` job; a classifier model is called directly, in
  the background (`Mythweaver.Expressions.Encoder`). Always `:ok`; checks run cheapest first, so the
  default (no classifier model) costs one settings read. `opts`: `:override_manual` (replace an
  expression set by hand).
  """
  @spec classify_later(Scope.t(), Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t(), keyword()) :: :ok
  def classify_later(%Scope{} = scope, chat_id, message_id, body_id, opts \\ []) do
    with id when is_binary(id) <- Settings.get(scope, "expressions.classifier_model"),
         %Model{} = model <- AI.get_model(scope, id),
         true <- AI.usable?(scope, model),
         :roleplay <- Repo.one(from(c in Chat, where: c.id == ^chat_id, select: c.kind)),
         character_id when is_binary(character_id) <-
           Repo.one(from(m in Message, where: m.id == ^message_id, select: m.author_character_id)),
         true <- has_sprites?(character_id),
         content when is_binary(content) <- Repo.one(from(b in MessageBody, where: b.id == ^body_id, select: b.content)),
         false <- String.trim(content) == "",
         %Character{} = character <- Repo.get(Character, character_id) do
      params = %{
        "chat_id" => chat_id,
        "message_id" => message_id,
        "body_id" => body_id,
        "character_id" => character.id,
        "override_manual" => Keyword.get(opts, :override_manual, false)
      }

      case model.completion_mode do
        :classifier ->
          Encoder.classify_later(scope, model, params)

        _generating ->
          _ =
            Jobs.enqueue(scope, :expression, %{
              ai_model_id: model.id,
              chat_id: chat_id,
              origin: :background,
              label:
                Mythweaver.Locale.with_user_locale(scope, fn ->
                  dpgettext(
                    "characters",
                    "badge: background job that picks a character's expression",
                    "Expression: %{character_name}",
                    character_name: character.name
                  )
                end),
              params: params
            })

          :ok
      end
    else
      _ -> :ok
    end
  end

  @doc """
  Stores a finished classification (`scores`, label => 0..100) on the job's body and announces the
  message. Skipped when the body is gone, its expression was set by hand (unless the job overrides
  that) or the message now has another author.
  """
  @spec apply_scores(Scope.t(), map(), %{String.t() => integer()}) ::
          {:ok, %{String.t() => term()}}
  def apply_scores(%Scope{} = scope, params, scores) do
    body = Repo.get(MessageBody, params["body_id"])
    message = body && Repo.get(Message, body.message_id)
    character = Repo.get(Character, params["character_id"])

    cond do
      is_nil(message) or is_nil(character) ->
        {:ok, %{"skipped" => "gone"}}

      body.expression_source == :manual and params["override_manual"] != true ->
        {:ok, %{"skipped" => "manual"}}

      message.author_character_id != character.id ->
        {:ok, %{"skipped" => "reattributed"}}

      true ->
        {label, sprite} = resolve_for(scope, message.chat_id, character, scores, message.id)

        body
        |> MessageBody.expression_changeset(%{
          expression: label,
          expression_scores: scores,
          expression_source: :classified,
          expression_sprite_id: sprite && sprite.id
        })
        |> Repo.update!()

        broadcast(scope, message)
        {:ok, %{"body_id" => body.id, "expression" => label}}
    end
  end

  @doc """
  The label and sprite `scores` resolve to for `character` in `chat_id`: against its participant's
  outfit, then the Default set when the outfit has nothing that matches. The sprite avoids the one
  the character's previous message showed when `expressions.reroll_if_same` is on.
  """
  @spec resolve_for(Scope.t(), Ecto.UUID.t(), Character.t(), map(), Ecto.UUID.t() | nil) ::
          {String.t() | nil, Sprite.t() | nil}
  def resolve_for(%Scope{} = scope, chat_id, %Character{} = character, scores, message_id \\ nil) do
    sprites = sprites_of(character.id)
    outfit_id = active_outfit_id(chat_id, character.id)
    profile = effective_profile(scope, character)

    config = %{
      labels: classifier_labels(character),
      rules: if(profile, do: profile.rules, else: []),
      fallback: character.fallback_expression
    }

    resolve = &Resolver.resolve(scores, Map.put(config, :available, available(sprites, &1)))

    {label, set} =
      case {resolve.(outfit_id), outfit_id} do
        {nil, outfit} when not is_nil(outfit) -> {resolve.(nil), nil}
        {label, outfit} -> {label, outfit}
      end

    sprite =
      label &&
        Resolver.pick_sprite(
          sprites_for(sprites, set, label),
          previous_sprite_id(chat_id, character.id, message_id),
          Settings.get(scope, "expressions.reroll_if_same")
        )

    {label, sprite}
  end

  defp active_outfit_id(chat_id, character_id) do
    Repo.one(
      from(p in Participant, where: p.chat_id == ^chat_id and p.character_id == ^character_id, select: p.outfit_id)
    )
  end

  # The sprite the character's latest other message in the chat shows.
  defp previous_sprite_id(chat_id, character_id, message_id) do
    query =
      from(m in Message,
        join: b in MessageBody,
        on: b.message_id == m.id and b.active,
        where: m.chat_id == ^chat_id and m.author_character_id == ^character_id and not is_nil(b.expression_sprite_id),
        order_by: [desc: m.position],
        limit: 1,
        select: b.expression_sprite_id
      )

    query = if message_id, do: where(query, [m], m.id != ^message_id), else: query
    Repo.one(query)
  end

  @doc """
  Sets the active swipe's expression by hand: `label` must have a sprite in the author's outfit or
  its Default set. `""` clears it back to the portrait. Either way a later classification leaves it
  alone unless asked to (`reclassify/2`).
  """
  @spec set_manual(Scope.t(), Message.t(), String.t()) ::
          {:ok, Message.t()} | {:error, :unauthorized | :no_sprite}
  def set_manual(%Scope{} = scope, %Message{} = message, label) do
    with :ok <- Chats.authorize(scope, message.chat_id, :manage),
         %MessageBody{} = body <- Message.active_body(message) || {:error, :no_sprite},
         {:ok, attrs} <- manual_attrs(scope, message, body, label) do
      body |> MessageBody.expression_changeset(Map.put(attrs, :expression_source, :manual)) |> Repo.update!()
      {:ok, broadcast(scope, message)}
    end
  end

  defp manual_attrs(_scope, _message, _body, ""), do: {:ok, %{expression: nil, expression_sprite_id: nil}}

  defp manual_attrs(scope, %Message{author_character_id: character_id} = message, body, label)
       when is_binary(character_id) do
    sprites = sprites_of(character_id)
    outfit_id = active_outfit_id(message.chat_id, character_id)

    pool =
      case sprites_for(sprites, outfit_id, label) do
        [] -> sprites_for(sprites, nil, label)
        pool -> pool
      end

    case Resolver.pick_sprite(pool, body.expression_sprite_id, Settings.get(scope, "expressions.reroll_if_same")) do
      nil -> {:error, :no_sprite}
      sprite -> {:ok, %{expression: label, expression_sprite_id: sprite.id}}
    end
  end

  defp manual_attrs(_scope, _message, _body, _label), do: {:error, :no_sprite}

  @doc """
  Queues a fresh classification of the active swipe that replaces an expression set by hand.
  `{:error, :off}` when no classifier model is set.
  """
  @spec reclassify(Scope.t(), Message.t()) :: :ok | {:error, :off | :unauthorized}
  def reclassify(%Scope{} = scope, %Message{} = message) do
    with :ok <- Chats.authorize(scope, message.chat_id, :manage) do
      case {Settings.get(scope, "expressions.classifier_model"), Message.active_body(message)} do
        {nil, _} -> {:error, :off}
        {_, nil} -> :ok
        {_, body} -> classify_later(scope, message.chat_id, message.id, body.id, override_manual: true)
      end
    end
  end

  @doc """
  The labels a hand pick may choose for `message`: those with a sprite in its author's outfit in
  `chat_id` or the Default set, in `labels/2` order, then labels left only by their sprites.
  """
  @spec picker_labels(Scope.t(), Ecto.UUID.t(), Message.t()) :: [String.t()]
  def picker_labels(%Scope{} = scope, chat_id, %Message{author_character_id: character_id})
      when is_binary(character_id) do
    case Repo.get(Character, character_id) do
      nil ->
        []

      character ->
        sprites = sprites_of(character_id)

        avail =
          MapSet.union(available(sprites, active_outfit_id(chat_id, character_id)), available(sprites, nil))

        ordered = labels(character, effective_profile(scope, character))
        Enum.filter(ordered, &MapSet.member?(avail, &1)) ++ Enum.sort(MapSet.to_list(avail) -- ordered)
    end
  end

  def picker_labels(%Scope{}, _chat_id, %Message{}), do: []

  defp broadcast(scope, %Message{id: id, chat_id: chat_id}) do
    case Messages.get_message(scope, id) do
      nil ->
        nil

      message ->
        Messages.broadcast_message_updated(chat_id, message)
        message
    end
  end
end
