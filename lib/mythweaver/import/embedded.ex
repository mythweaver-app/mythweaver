defmodule Mythweaver.Import.Embedded do
  @moduledoc """
  Reads the Mythweaver bundle an exported external file carries (`extensions.mythweaver` of a card,
  World Info file or preset; `chat_metadata.mythweaver` of a chat log's header).

  The embedded map stores a `digest/1` of the importer's own reading of the file's standard fields
  at export. When the file still reads the same, it imports as the bundle (origin matching and
  review, like a `.mythweaver` file); otherwise only its standard fields import, with a warning.
  """

  use Gettext, backend: Mythweaver.Gettext

  alias Mythweaver.Attachments.FileInfo
  alias Mythweaver.Bundle
  alias Mythweaver.Import.Text

  @doc "The `\"mythweaver\"` map inside `extensions` (a card's, World Info's, preset's or chat header's), or nil."
  @spec extract(term()) :: map() | nil
  def extract(extensions) do
    case Text.map(extensions)["mythweaver"] do
      %{} = embedded -> embedded
      _other -> nil
    end
  end

  @doc """
  The digest of a parsed file's standard fields: everything but `:warnings`, `:unconverted`,
  `:avatar`, `:embedded` and a card's `:source_file`, and, for lore books, presets and chats, the
  names that come from the filename (the file's `:name`, and every preset block's). A card's unset
  greetings (nil `:first_message`, empty `:alternate_greetings`/`:group_greetings`) are left out
  too, so cards exported before greetings existed still match.
  """
  @spec digest(map()) :: String.t()
  def digest(parsed) do
    parsed
    |> Map.drop([:warnings, :unconverted, :avatar, :embedded, :source_file])
    |> drop_names()
    |> drop_empty_greetings()
    |> Bundle.digest()
  end

  @greeting_keys [:first_message, :alternate_greetings, :group_greetings]

  defp drop_empty_greetings(%{kind: :character} = parsed),
    do: Map.reject(parsed, fn {key, value} -> key in @greeting_keys and value in [nil, []] end)

  defp drop_empty_greetings(parsed), do: parsed

  defp drop_names(%{kind: :preset} = parsed),
    do: parsed |> Map.delete(:name) |> Map.update!(:blocks, fn blocks -> Enum.map(blocks, &Map.delete(&1, :name)) end)

  defp drop_names(%{kind: kind} = parsed) when kind in [:lore_book, :chat], do: Map.delete(parsed, :name)
  defp drop_names(parsed), do: parsed

  @doc """
  `parsed` with its `:embedded` key resolved: no embedded bundle → `parsed` as is; one whose digest
  matches and that reads as a bundle → `%{kind: :bundle, name, bundle, warnings: []}` (a card's
  avatar added as the root character's avatar blob); otherwise `parsed` with a warning that its
  Mythweaver-only details weren't imported.
  """
  @spec resolve(map()) :: map()
  def resolve(parsed) do
    case Map.pop(parsed, :embedded) do
      {nil, parsed} ->
        parsed

      {embedded, parsed} ->
        with true <- embedded["digest"] == digest(parsed),
             {:ok, bundle} <- Bundle.from_embedded(embedded) do
          %{kind: :bundle, name: parsed.name, bundle: put_avatar(bundle, parsed[:avatar]), warnings: []}
        else
          _changed ->
            changed =
              dgettext(
                "import_export",
                "This file was changed outside Mythweaver, so its Mythweaver-only details weren't imported."
              )

            %{parsed | warnings: parsed.warnings ++ [changed]}
        end
    end
  end

  # Only a character that had an avatar at export gets one: a PNG card without one is drawn on a
  # placeholder image.
  defp put_avatar(bundle, bytes) when is_binary(bytes) do
    case Enum.find_index(bundle.items, &(&1.root and &1.kind == :character and &1.data["avatar"] != nil)) do
      nil ->
        bundle

      index ->
        uid = :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
        {:ok, info} = FileInfo.parse(bytes, nil)
        blob = %{kind: info.kind, content_type: info.content_type, filename: nil, description: nil, bytes: bytes}

        %{
          bundle
          | items: List.update_at(bundle.items, index, &put_in(&1, [:data, "avatar"], uid)),
            blobs: Map.put(bundle.blobs, uid, blob)
        }
    end
  end

  defp put_avatar(bundle, _bytes), do: bundle
end
