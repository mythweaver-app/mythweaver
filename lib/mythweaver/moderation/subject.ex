defmodule Mythweaver.Moderation.Subject do
  @moduledoc """
  What content moderation reads from a moderated row (pure): its kind, its content type
  (`Mythweaver.Moderation.Modes`), whether it may be held, and its text fields.

  The text fields are derived from the schema (every `:string` and `{:array, :string}` field but
  `source_file`), so a new column is covered without listing it. Encrypted and map fields (an AI
  connection's `api_key`, `extra_headers`) are not strings, so secrets never reach rules, webhooks
  or the review screens. Every list stops growing once its text reaches `max_scan_chars`.
  """

  use Gettext, backend: Mythweaver.Gettext

  alias Mythweaver.AI
  alias Mythweaver.Characters.Character
  alias Mythweaver.Chats.Chat
  alias Mythweaver.Lore.LoreBook
  alias Mythweaver.Lore.LoreEntry
  alias Mythweaver.Moderation
  alias Mythweaver.Prompts.Block
  alias Mythweaver.Prompts.Outlet
  alias Mythweaver.Prompts.Prompt

  @type kind ::
          :character
          | :lore_entry
          | :lore_book
          | :ai_provider
          | :ai_model
          | :prompt
          | :block
          | :outlet
          | :chat
          | :message
  @type field :: {String.t(), String.t()}

  @kinds %{
    Character => :character,
    LoreEntry => :lore_entry,
    LoreBook => :lore_book,
    AI.Provider => :ai_provider,
    AI.Model => :ai_model,
    Prompt => :prompt,
    Block => :block,
    Outlet => :outlet,
    Chat => :chat
  }

  @holdable [:character, :lore_entry, :ai_provider, :ai_model, :prompt, :block, :outlet]
  @skipped_fields [:source_file]
  @skipped_import_keys [:avatar, :warnings, :foreign, :source_file, :__meta__]
  @skipped_import_strings Enum.map(@skipped_import_keys, &Atom.to_string/1)

  @doc "The kind of a moderated schema or row."
  @spec kind(module() | struct()) :: kind()
  def kind(%{__struct__: schema}), do: kind(schema)
  def kind(schema) when is_atom(schema), do: Map.fetch!(@kinds, schema)

  @doc "The content type a kind is moderated under."
  @spec type(kind() | :import) :: Moderation.Modes.type()
  def type(kind) when kind in [:message, :chat], do: :chats
  def type(:character), do: :characters
  def type(kind) when kind in [:lore_entry, :lore_book], do: :lore
  def type(kind) when kind in [:ai_provider, :ai_model], do: :ai
  def type(kind) when kind in [:prompt, :block, :outlet], do: :prompts

  @doc "Whether a restrictive mode holds this kind's writes (a lore book and a chat are only scanned)."
  @spec holdable?(atom()) :: boolean()
  def holdable?(kind), do: kind in @holdable

  @doc "The schema's text fields: every string or string-array field but `source_file`."
  @spec text_fields(module()) :: [atom()]
  def text_fields(schema) do
    for field <- schema.__schema__(:fields),
        field not in @skipped_fields,
        schema.__schema__(:type, field) in [:string, {:array, :string}],
        do: field
  end

  @doc "`{label, text}` of every non-blank text field of `row`; arrays joined with newlines."
  @spec fields(struct()) :: [field()]
  def fields(%{__struct__: schema} = row) do
    schema
    |> text_fields()
    |> Enum.flat_map(fn field ->
      case text(Map.get(row, field)) do
        nil -> []
        text -> [{Atom.to_string(field), text}]
      end
    end)
    |> capped()
  end

  @doc "A row's display title: its `name`, else its `key`, else \"Untitled\"."
  @spec title(map()) :: String.t()
  def title(row) do
    [Map.get(row, :name), Map.get(row, :key)]
    |> Enum.find(&(is_binary(&1) and String.trim(&1) != ""))
    |> Kernel.||(dpgettext("moderation", "status: title of a moderated item that has no name", "Untitled"))
  end

  @doc """
  Every text in a parsed import (`Mythweaver.Import.parse/2`), labelled by its key path
  (`"book.entries.3.content"`). Skips avatars, warnings, foreign keys and non-UTF-8 binaries (images).
  """
  @spec import_fields(term()) :: [field()]
  def import_fields(parsed), do: parsed |> walk([]) |> capped()

  @doc "The fields joined into one text, for a snapshot."
  @spec join([field()]) :: String.t()
  def join(fields), do: Enum.map_join(fields, "\n\n", fn {label, text} -> "#{label}: #{text}" end)

  defp walk(%{__struct__: _} = struct, path), do: struct |> Map.from_struct() |> walk(path)

  defp walk(map, path) when is_map(map) do
    map
    |> Enum.reject(fn {key, _} -> key in @skipped_import_keys or key in @skipped_import_strings end)
    |> Enum.sort_by(fn {key, _} -> to_string(key) end)
    |> Enum.flat_map(fn {key, value} -> walk(value, [to_string(key) | path]) end)
  end

  defp walk(list, path) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.flat_map(fn {value, index} -> walk(value, [Integer.to_string(index) | path]) end)
  end

  defp walk(text, path) when is_binary(text) do
    if String.valid?(text) and String.trim(text) != "",
      do: [{path |> Enum.reverse() |> Enum.join("."), text}],
      else: []
  end

  defp walk(_other, _path), do: []

  @doc "A text field's value as moderated text (arrays joined with newlines), or nil when blank."
  @spec text(term()) :: String.t() | nil
  def text(value) when is_binary(value), do: if(String.trim(value) != "", do: value)

  def text(values) when is_list(values) do
    values |> Enum.filter(&(is_binary(&1) and String.trim(&1) != "")) |> Enum.join("\n") |> text()
  end

  def text(_), do: nil

  defp capped(fields) do
    max = Moderation.config(:max_scan_chars) || 200_000

    fields
    |> Enum.reduce_while({[], 0}, fn {label, text}, {acc, total} ->
      if total >= max do
        {:halt, {acc, total}}
      else
        text = String.slice(text, 0, max - total)
        {:cont, {[{label, text} | acc], total + String.length(text)}}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end
end
