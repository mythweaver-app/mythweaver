defmodule Mythweaver.Scripts.API.Characters do
  @moduledoc """
  `mw.characters.*`: every character the script's scope may use (its own plus the site's), not only
  the current chat's. Writes (`update`, `set_appearance`, `set_avatar`) need edit rights on the
  character and refuse "unauthorized" otherwise.
  """

  use Gettext, backend: Mythweaver.Gettext

  import Mythweaver.Scripts.API.Convert

  alias Mythweaver.Attachments
  alias Mythweaver.Characters
  alias Mythweaver.Characters.Character
  alias Mythweaver.Ownership
  alias Mythweaver.Sharing.Visibility

  @fields [
    :id,
    :name,
    :description,
    :pronouns,
    :appearance,
    :creator,
    :creator_notes,
    :character_version,
    :talkativeness,
    :site_visibility
  ]

  @functions %{
    list:
      {"mw.characters.list()",
       dgettext_noop("scripts", "Every usable character (your own and the site's), not only this chat's.")},
    get: {"mw.characters.get(id)", dgettext_noop("scripts", ~s(The character with this id, or nil, "not_found".))},
    find:
      {"mw.characters.find(name)",
       dgettext_noop(
         "scripts",
         ~s[The first usable character with this name, ignoring case and surrounding spaces (your own before the site's, then the oldest), or nil, "not_found".]
       )},
    update:
      {"mw.characters.update(id, fields)",
       dgettext_noop("scripts", ~s(Updates the given fields, e.g. {name = "Ciri"}; returns the character.))},
    set_avatar:
      {"mw.characters.set_avatar(character, prompt?, describe?)",
       dgettext_noop(
         "scripts",
         ~s[Asks the player for an image that becomes the character's avatar (character is its id or table): the chat shows a dialog with prompt and a Choose image button. Returns true at once; the avatar is set when the image is chosen. The avatar is then described when images.auto_caption is on and the character's Appearance follows its avatar (describe true or false overrides both), and the description fills an appearance nobody wrote. A newer request replaces an open one. Refuses "not_found", or "not_allowed" in lore_activated.]
       )},
    set_appearance:
      {"mw.characters.set_appearance(character, text)",
       dgettext_noop(
         "scripts",
         "Saves text as how the character looks (character is its id or table); blank clears it. Returns the character."
       )}
  }

  @usage Map.new(@functions, fn {name, {signature, _info}} -> {name, signature} end)

  @doc "The installed functions' signatures and descriptions, by name."
  def functions, do: @functions

  def install(lua, ctx), do: install_functions(lua, [:mw, :characters], @functions, &call(&1, ctx, &2, &3))

  @doc """
  A character's Lua table. `hide_content?` blanks `description` and `appearance`, for a reader who may
  not see a runtime-only site character's content.
  """
  def to_table(%Character{} = character, hide_content? \\ false) do
    table = Map.take(character, @fields)
    if hide_content?, do: %{table | description: nil, appearance: nil}, else: table
  end

  defp call(:list, ctx, [], state), do: ok(state, Enum.map(Characters.list_characters(ctx.scope), &table(ctx, &1)))

  defp call(:get, ctx, [id], state) when is_binary(id) do
    with_character(ctx, id, state, &ok(state, table(ctx, &1)))
  end

  defp call(:find, ctx, [name], state) when is_binary(name) do
    case Characters.find_character_by_name(ctx.scope, name) do
      nil -> refuse(state, :not_found)
      character -> ok(state, table(ctx, character))
    end
  end

  # The changeset's cast list is the whitelist of writable fields.
  defp call(:update, ctx, [id, fields], state) when is_binary(id) do
    attrs = fields!(state, fields, @usage.update)

    with_character(ctx, id, state, fn character ->
      ctx.scope |> Characters.update_character(character, attrs) |> reply(state, &table(ctx, &1))
    end)
  end

  defp call(:set_avatar, %{trigger: :lore_activated}, _args, state), do: refuse(state, :not_allowed)

  defp call(:set_avatar, ctx, [character | rest], state) when length(rest) <= 2 do
    {prompt, describe?} =
      case rest do
        [] ->
          {nil, nil}

        [prompt] when is_binary(prompt) or is_nil(prompt) ->
          {prompt, nil}

        [prompt, describe?]
        when (is_binary(prompt) or is_nil(prompt)) and (is_boolean(describe?) or is_nil(describe?)) ->
          {prompt, describe?}

        _ ->
          usage!(@usage.set_avatar)
      end

    with_character(ctx, character_id!(state, character, :set_avatar), state, fn character ->
      with_edit_rights(ctx, character, state, fn ->
        avatar = %{character_id: character.id, name: character.name, describe?: describe?}
        _id = Attachments.request_image(ctx.chat.id, prompt, nil, avatar: avatar)
        ok(state, true)
      end)
    end)
  end

  defp call(:set_appearance, ctx, [character, text], state) when is_binary(text) do
    with_character(ctx, character_id!(state, character, :set_appearance), state, fn character ->
      case Characters.update_character(ctx.scope, character, %{appearance: text}) do
        {:ok, character} ->
          :ok = Attachments.broadcast_appearance_updated(character.id)
          ok(state, table(ctx, character))

        {:held, _hold} ->
          refuse(state, :held_for_review)

        {:error, reason} ->
          refuse(state, reason)
      end
    end)
  end

  defp call(name, _ctx, _args, _state), do: usage!(@usage[name])

  defp table(ctx, character), do: to_table(character, Visibility.content_hidden_for?(ctx.scope, character))

  # A character id, or a table carrying one (a character table, or a message's `author`).
  defp character_id!(_state, id, _name) when is_binary(id), do: id

  defp character_id!(state, {:tref, _} = table, name) do
    case fields!(state, table, @usage[name]) do
      %{"id" => id} when is_binary(id) -> id
      _ -> usage!(@usage[name])
    end
  end

  defp character_id!(_state, _character, name), do: usage!(@usage[name])

  defp with_character(ctx, id, state, fun) do
    case fetch(id, &Characters.get_character(ctx.scope, &1)) do
      nil -> refuse(state, :not_found)
      character -> fun.(character)
    end
  end

  defp with_edit_rights(ctx, character, state, fun) do
    case Ownership.authorize_edit(ctx.scope, character) do
      :ok -> fun.()
      {:error, reason} -> refuse(state, reason)
    end
  end
end
