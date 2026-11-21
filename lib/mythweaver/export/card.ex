defmodule Mythweaver.Export.Card do
  @moduledoc """
  Writes a bundle's character as a Character Card: V3 JSON, a PNG with `chara` (V2) and `ccv3` (V3)
  `tEXt` chunks, or a CHARX zip. The inverse of `Mythweaver.Import.Card`.

  A bound book whose every entry is a card field (`Mythweaver.Import.Card.fields/0`, "Depth
  prompt", or the "System prompt" and "Post-history instructions" older imports wrote), each at most
  once, enabled and constant, is a *card book*: the first by name is lifted back into the card's
  fields. A book imported as one (`kind: card`) may have moved its entries; any other must keep
  each in its import location, without keywords. A lifted prompt yields to the character's own
  non-blank prompt field. Every other bound book becomes the card's `character_book`, written like
  World Info entries (`Mythweaver.Export.WorldInfo.mapped_entry/8`) in its V2 shape
  (`Mythweaver.Import.WorldInfo.character_book_extensions/0`). Card text goes through
  `Mythweaver.Export.Macros.to_st/1`; the bundle travels under `data.extensions.mythweaver`, with
  the digest of the importer's own reading of the card.
  """

  use Gettext, backend: Mythweaver.Gettext

  alias Mythweaver.Bundle
  alias Mythweaver.Export
  alias Mythweaver.Export.Macros
  alias Mythweaver.Export.Png
  alias Mythweaver.Export.WorldInfo
  alias Mythweaver.Import.Card, as: ImportCard
  alias Mythweaver.Import.Embedded
  alias Mythweaver.Import.Png, as: ImportPng
  alias Mythweaver.Import.WorldInfo, as: ImportWorldInfo

  defp not_png,
    do:
      dgettext(
        "import_export",
        "The avatar couldn't be made a PNG, so the card shows a blank image; choose CHARX to keep it."
      )

  defp no_avatar, do: dgettext("import_export", "JSON cards carry no avatar; choose PNG or CHARX to keep it.")

  @extensions %{
    "image/png" => "png",
    "image/jpeg" => "jpg",
    "image/webp" => "webp",
    "image/gif" => "gif",
    "image/avif" => "avif"
  }

  @type format :: :card_json | :card_png | :charx

  @doc "The card file in `format` for the character item `root_uid` of `bundle`. `opts`: `bundle:` (default true)."
  @spec file(Bundle.t(), String.t(), format(), keyword()) :: %{
          bytes: binary(),
          filename: String.t(),
          content_type: String.t(),
          warnings: [String.t()]
        }
  def file(bundle, root_uid, format, opts \\ [])

  def file(%Bundle{} = bundle, root_uid, :card_json, opts) do
    %{v3: v3, warnings: warnings} = build(bundle, root_uid, opts)
    name = character(bundle, root_uid).name
    warnings = if avatar(bundle, root_uid), do: warnings ++ [no_avatar()], else: warnings

    %{
      bytes: Jason.encode!(v3, pretty: true),
      filename: Export.filename(name, "json"),
      content_type: "application/json",
      warnings: warnings
    }
  end

  def file(%Bundle{} = bundle, root_uid, :card_png, opts) do
    {image, bundle, image_warnings} =
      case avatar(bundle, root_uid) do
        nil -> {Png.placeholder(), bundle, []}
        %{content_type: "image/png", bytes: bytes} -> png_image(bundle, root_uid, bytes)
        _other -> {Png.placeholder(), drop_avatar(bundle, root_uid), [not_png()]}
      end

    %{v3: v3, v2: v2, warnings: warnings} = build(bundle, root_uid, opts)

    bytes =
      Png.embed(image, [
        {"chara", Base.encode64(Jason.encode!(v2))},
        {"ccv3", Base.encode64(Jason.encode!(v3))}
      ])

    %{
      bytes: bytes,
      filename: Export.filename(character(bundle, root_uid).name, "png"),
      content_type: "image/png",
      warnings: warnings ++ image_warnings
    }
  end

  def file(%Bundle{} = bundle, root_uid, :charx, opts) do
    %{v3: v3, warnings: warnings} = build(bundle, root_uid, opts)

    files =
      case avatar(bundle, root_uid) do
        nil ->
          [{~c"card.json", Jason.encode!(v3)}]

        blob ->
          ext = Map.get(@extensions, blob.content_type, "bin")
          path = "assets/icon/images/main.#{ext}"
          asset = %{"type" => "icon", "uri" => "embeded://#{path}", "name" => "main", "ext" => ext}
          v3 = put_in(v3, ["data", "assets"], [asset])
          [{~c"card.json", Jason.encode!(v3)}, {String.to_charlist(path), blob.bytes}]
      end

    {:ok, {_name, bytes}} = :zip.create(~c"card.charx", files, [:memory])

    %{
      bytes: bytes,
      filename: Export.filename(character(bundle, root_uid).name, "charx"),
      content_type: "application/x-charx",
      warnings: warnings
    }
  end

  # The avatar without its text chunks; one that won't parse as a PNG is left out like a non-PNG.
  defp png_image(bundle, root_uid, bytes) do
    case ImportPng.strip_text(bytes) do
      {:ok, image} -> {image, bundle, []}
      {:error, _message} -> {Png.placeholder(), drop_avatar(bundle, root_uid), [not_png()]}
    end
  end

  # A placeholder image isn't the character's avatar, so the embedded item mustn't claim one.
  defp drop_avatar(bundle, root_uid) do
    items =
      Enum.map(bundle.items, fn
        %{uid: ^root_uid} = item -> put_in(item, [:data, "avatar"], nil)
        item -> item
      end)

    %{bundle | items: items}
  end

  defp character(bundle, root_uid), do: Enum.find(bundle.items, &(&1.uid == root_uid))

  defp avatar(bundle, root_uid) do
    case character(bundle, root_uid).data["avatar"] do
      nil -> nil
      uid -> Map.get(bundle.blobs, uid)
    end
  end

  @doc """
  The V3 and V2 card maps for the character item `root_uid`, and the warnings (leftover Liquid ST
  can't run). `opts`: `bundle:` (default true) adds `extensions.mythweaver`.
  """
  @spec build(Bundle.t(), String.t(), keyword()) :: %{v3: map(), v2: map(), warnings: [String.t()]}
  def build(%Bundle{} = bundle, root_uid, opts \\ []) do
    items = WorldInfo.index(bundle)
    character = Map.fetch!(items, root_uid)
    data = character.data

    books =
      for %{"uid" => uid} <- List.wrap(data["books"]),
          %{kind: :lore_book} = book <- [items[uid]],
          do: book

    books = Enum.sort_by(books, & &1.name)
    card_book = Enum.find(books, &card_book?(items, &1))
    other_books = Enum.reject(books, &(&1 == card_book))

    {description, names} =
      convert(data["description"], dpgettext("import_export", "field label: character card field", "Description"), [])

    {first_message, names} =
      convert(
        data["first_message"],
        dpgettext("import_export", "field label: character card field", "First message"),
        names
      )

    {alternates, names} =
      convert_all(
        List.wrap(data["alternate_greetings"]),
        fn number ->
          dpgettext(
            "import_export",
            "field label: numbered alternate greeting of a character card",
            "Alternate greeting %{greeting_number}",
            greeting_number: number
          )
        end,
        names
      )

    {group_greetings, names} =
      convert_all(
        List.wrap(data["group_greetings"]),
        fn number ->
          dpgettext(
            "import_export",
            "field label: numbered group-only greeting of a character card",
            "Group-only greeting %{greeting_number}",
            greeting_number: number
          )
        end,
        names
      )

    {system_prompt, names} =
      convert(
        card_prompt(data, "system_prompt"),
        dpgettext("import_export", "field label: character card field", "System prompt"),
        names
      )

    {post_history, names} =
      convert(
        card_prompt(data, "post_history_instructions"),
        dpgettext("import_export", "field label: character card field", "Post-history instructions"),
        names
      )

    {fields, extensions, names} = lift(items, card_book, data, names)
    {character_book, names} = character_book(items, other_books, character.name, WorldInfo.outlet_names(bundle), names)
    foreign = data["foreign"] || %{}

    card =
      Map.merge(
        %{
          "name" => character.name,
          "description" => description,
          "personality" => "",
          "scenario" => "",
          "first_mes" => first_message,
          "mes_example" => "",
          "creator_notes" => data["creator_notes"] || "",
          "system_prompt" => system_prompt,
          "post_history_instructions" => post_history,
          "alternate_greetings" => alternates,
          "group_only_greetings" => group_greetings,
          "tags" => List.wrap(data["tags"]),
          "creator" => data["creator"] || "",
          "character_version" => data["character_version"] || "",
          "extensions" =>
            Map.merge(foreign["extensions"] || %{}, Map.put(extensions, "talkativeness", data["talkativeness"]))
        },
        fields
      )

    card = Map.merge(foreign["data"] || %{}, card)
    card = if character_book, do: Map.put(card, "character_book", character_book), else: card
    v3 = %{"spec" => "chara_card_v3", "spec_version" => "3.0", "data" => card}

    v3 =
      if Keyword.get(opts, :bundle, true) do
        digest =
          v3
          |> Jason.encode!()
          |> Jason.decode!()
          |> ImportCard.normalize()
          |> then(fn {:ok, parsed} -> Embedded.digest(parsed) end)

        put_in(v3, ["data", "extensions", "mythweaver"], Bundle.to_embedded(bundle, digest))
      else
        v3
      end

    v2 = %{
      "spec" => "chara_card_v2",
      "spec_version" => "2.0",
      "data" => Map.delete(v3["data"], "group_only_greetings")
    }

    warnings = WorldInfo.macro_warnings(names) ++ WorldInfo.entry_warnings(book_entries(items, other_books))
    %{v3: v3, v2: v2, warnings: warnings}
  end

  # In `:add` mode the card text goes alongside the prompt; ST says so with `{{original}}`.
  defp card_prompt(data, key) do
    text = data[key]

    if to_string(data["card_prompt_mode"]) == "add" and is_binary(text) and String.trim(text) != "" and
         not String.contains?(text, ["{{original}}", "{{ original }}"]),
       do: "{{original}}\n" <> text,
       else: text
  end

  defp convert(text, label, names) do
    case Macros.to_st(text) do
      {st, true} -> {st, [label | names]}
      {st, false} -> {st, names}
    end
  end

  defp convert_all(texts, label, names) do
    texts
    |> Enum.with_index(1)
    |> Enum.map_reduce(names, fn {text, i}, names -> convert(text, label.(Mythweaver.Format.number(i)), names) end)
  end

  ## Card book

  # label => {source key, location}; "Depth prompt" is the depth prompt extension. "System prompt"
  # and "Post-history instructions" are what card books imported before card prompt fields held.
  defp signatures do
    ImportCard.fields()
    |> Map.new(fn {key, label, location, _order} -> {label, {key, location}} end)
    |> Map.put("Depth prompt", {"depth_prompt", %{outlet: :at_depth}})
    |> Map.put("System prompt", {"system_prompt", %{outlet: :character, placement: :before}})
    |> Map.put(
      "Post-history instructions",
      {"post_history_instructions", %{outlet: :custom, custom_outlet: :post_history}}
    )
  end

  # A card book: one whose entries are all card fields, enabled and constant (card text is always
  # sent), each at most once. One imported as such (`kind: card`) may have moved them; any other
  # must look exactly like an import's. A book with a disabled or non-constant field stays lore, so
  # nothing about it is lost.
  defp card_book?(items, book) do
    signatures = signatures()

    case WorldInfo.entries(items, book) do
      [] ->
        false

      members ->
        labels = Enum.map(members, fn {entry, _membership} -> entry.data["name"] end)

        Enum.uniq(labels) == labels and
          Enum.all?(members, fn {entry, membership} ->
            card_field?(entry.data, membership, signatures, book.data["kind"] == "card")
          end)
    end
  end

  defp card_field?(data, membership, signatures, card_kind?) do
    case Map.fetch(signatures, data["name"]) do
      {:ok, {_key, location}} ->
        membership["enabled"] != false and data["activation"] == "constant" and
          (card_kind? or
             (List.wrap(data["keywords"]) == [] and
                Enum.all?(location, fn {field, value} -> data[Atom.to_string(field)] == to_string(value) end)))

      :error ->
        false
    end
  end

  # The card fields and extensions lifted from the card book's entries. A prompt field the
  # character (`data`) has itself wins over the book's entry.
  defp lift(_items, nil, _data, names), do: {%{}, %{}, names}

  defp lift(items, book, data, names) do
    signatures = signatures()

    items
    |> WorldInfo.entries(book)
    |> Enum.reject(fn {entry, _membership} ->
      {key, _location} = Map.fetch!(signatures, entry.data["name"])
      key in ["system_prompt", "post_history_instructions"] and is_binary(data[key]) and String.trim(data[key]) != ""
    end)
    |> Enum.reduce({%{}, %{}, names}, fn {entry, _membership}, {fields, extensions, names} ->
      label = entry.data["name"]
      {text, names} = convert(entry.data["content"], label, names)

      case Map.fetch!(signatures, label) do
        {"depth_prompt", _location} ->
          depth = %{"prompt" => text, "depth" => entry.data["depth"] || 4, "role" => entry.data["role"] || "system"}
          {fields, Map.put(extensions, "depth_prompt", depth), names}

        {"mes_example", _location} ->
          {Map.put(fields, "mes_example", examples(text)), extensions, names}

        {key, _location} ->
          {Map.put(fields, key, text), extensions, names}
      end
    end)
  end

  # The reverse of the importer's `examples/1`: `[Example chat]` lines become `<START>`, and the text
  # opens with one.
  defp examples(text) do
    lines =
      text
      |> String.split(~r/\r?\n/)
      |> Enum.map(&if(String.trim(&1) == "[Example chat]", do: "<START>", else: &1))

    first = Enum.find(lines, &(String.trim(&1) != ""))
    joined = Enum.join(lines, "\n")

    if first && String.upcase(String.trim(first)) == "<START>", do: joined, else: "<START>\n" <> joined
  end

  ## Character book

  defp book_entries(items, books) do
    books
    |> Enum.flat_map(&WorldInfo.entries(items, &1))
    |> Enum.map(&elem(&1, 0))
    |> Enum.uniq_by(& &1.uid)
  end

  defp character_book(_items, [], _name, _outlets, names), do: {nil, names}

  defp character_book(items, [first | _rest] = books, character_name, outlets, names) do
    members =
      books
      |> Enum.flat_map(&WorldInfo.entries(items, &1))
      |> Enum.uniq_by(fn {entry, _membership} -> entry.uid end)

    index_by_uid = members |> Enum.with_index(fn {entry, _membership}, i -> {entry.uid, i} end) |> Map.new()

    {entries, names} =
      members
      |> Enum.with_index()
      |> Enum.map_reduce(names, fn {{entry, membership}, i}, names ->
        {content, left?} = Macros.to_st(entry.data["content"])
        {keys, names} = WorldInfo.entry_keys(entry, left?, names)
        {book_entry(entry, membership, i, content, keys, outlets, index_by_uid, items), names}
      end)

    # SillyTavern ignores an embedded book's `scan_depth`, `token_budget` and `recursive_scanning`,
    # so they're written only when an imported card carried them (its `foreign`). The first book's
    # priority, order adjustment and budget go in `stlo`, as in a World Info file.
    foreign = get_in(first.data, ["foreign", "character_book"]) || %{}
    {foreign_extensions, foreign} = Map.pop(foreign, "extensions", %{})
    foreign_extensions = if is_map(foreign_extensions), do: foreign_extensions, else: %{}

    {book, foreign_extensions} =
      foreign
      |> Map.merge(%{
        "name" => if(length(books) == 1, do: first.name, else: "#{character_name} (lore)"),
        "entries" => entries
      })
      |> WorldInfo.put_stlo(first.data, foreign_extensions)

    book = if foreign_extensions == %{}, do: book, else: Map.put(book, "extensions", foreign_extensions)
    {book, names}
  end

  # A World Info entry (`WorldInfo.mapped_entry/8`) in V2 `character_book` shape, the reverse of
  # `Mythweaver.Import.WorldInfo`'s `convert_entry/3`; the keys an import couldn't map (`foreign`)
  # are written back under the mapped ones.
  defp book_entry(entry, membership, i, content, keys, outlets, index_by_uid, items) do
    wi = WorldInfo.mapped_entry(entry, membership, i, content, keys, outlets, index_by_uid, items)
    foreign = get_in(entry.data, ["foreign", "character_book"]) || %{}

    extensions =
      for {wi_key, cb_key} <- ImportWorldInfo.character_book_extensions(),
          Map.has_key?(wi, wi_key),
          into: %{},
          do: {cb_key, wi[wi_key]}

    mapped = %{
      "id" => wi["uid"],
      "keys" => wi["key"],
      "secondary_keys" => wi["keysecondary"],
      "comment" => wi["comment"],
      "content" => wi["content"],
      "constant" => wi["constant"],
      "selective" => wi["selective"],
      "insertion_order" => wi["order"],
      "enabled" => not wi["disable"],
      "position" => if(wi["position"] == 0, do: "before_char", else: "after_char"),
      "use_regex" => true,
      "extensions" =>
        WorldInfo.merge_foreign(foreign["extensions"] || %{}, extensions, "secondary_keys", "character_filter")
    }

    WorldInfo.merge_foreign(foreign["entry"] || %{}, mapped, "secondary_keys", "character_filter")
  end
end
