defmodule Mythweaver.Bundle do
  @moduledoc """
  A Mythweaver bundle: exported items, chat transcripts and file blobs, independent of format.

  The native `.mythweaver` file is `encode/1`'s output, a zstd-compressed SQLite database
  (`application_id` `0x4D595448` "MYTH", `user_version` 1; tables `meta`, `items`, `messages`,
  `blobs`). External formats (cards, World Info, presets, chat logs) carry the same items as JSON
  under `extensions.mythweaver` (`to_embedded/2`, `from_embedded/1`).

  - `meta`: string keys and values (`"format"`, `"version"`, `"app_version"`, `"exported_at"`,
    `"title"`).
  - `items`: `%{uid, kind, name, root, position, data}`; `kind` is an atom from `kinds/0`, `data` a
    JSON map with string keys, `position` the exporter's emission order (dependencies first).
  - `messages`: `%{chat_uid => [message map]}`, each list in transcript order.
  - `blobs`: `%{uid => %{kind, content_type, filename, description, bytes}}`, `uid` the lowercase hex
    sha256 of `bytes`, `kind` an `Attachments.Attachment` kind atom.

  A link in item or message data (a participant, a prompt's blocks, a message's author, …) is the
  target's `uid` when the bundle carries the target, else a ref map `%{"kind", "uid", "name"}`
  (bundle kind string, the uid the target would have, its name) that an importer re-matches by
  origin, then name. A target the exporter may not use is nil, and left out of lists.
  """

  use Gettext, backend: Mythweaver.Gettext

  alias Mythweaver.Attachments.Attachment
  alias Mythweaver.Bundle.SQLite

  defstruct meta: %{}, items: [], messages: %{}, blobs: %{}

  @type kind ::
          :character
          | :lore_book
          | :lore_entry
          | :lore_pool
          | :prompt
          | :prompt_block
          | :prompt_outlet
          | :ai_model
          | :script
          | :memory_profile
          | :side_prompt
          | :side_prompt_set
          | :chat

  @type item :: %{
          uid: String.t(),
          kind: kind(),
          name: String.t(),
          root: boolean(),
          position: integer(),
          data: map()
        }

  @type blob :: %{
          kind: atom(),
          content_type: String.t(),
          filename: String.t() | nil,
          description: String.t() | nil,
          bytes: binary()
        }

  @type t :: %__MODULE__{
          meta: %{String.t() => String.t()},
          items: [item()],
          messages: %{String.t() => [map()]},
          blobs: %{String.t() => blob()}
        }

  @kinds %{
    character: "character",
    lore_book: "lore_book",
    lore_entry: "lore_entry",
    lore_pool: "lore_pool",
    prompt: "prompt",
    prompt_block: "prompt_block",
    prompt_outlet: "prompt_outlet",
    ai_model: "ai_model",
    script: "script",
    memory_profile: "memory_profile",
    side_prompt: "side_prompt",
    side_prompt_set: "side_prompt_set",
    chat: "chat"
  }

  @kinds_by_string Map.new(@kinds, fn {atom, string} -> {string, atom} end)

  @decision_kinds [
    :character,
    :lore_book,
    :prompt,
    :ai_model,
    :script,
    :memory_profile,
    :side_prompt,
    :side_prompt_set,
    :chat
  ]

  @format "mythweaver-bundle"
  @max_size Bitwise.bsl(1, 30)
  # Decompression is fed this much input at a time, so a stream that inflates past its declared
  # size is stopped within one step (a zstd block is at most 128 KiB from a 4-byte RLE block).
  @chunk 4096

  defp invalid, do: dgettext("import_export", "This isn't a valid Mythweaver bundle.")
  defp newer, do: dgettext("import_export", "This bundle needs a newer Mythweaver.")
  defp too_large, do: dgettext("import_export", "This bundle is too large.")

  @doc "Every item kind, atom to the string bundle files use."
  @spec kinds() :: %{kind() => String.t()}
  def kinds, do: @kinds

  @doc "The kind atom for bundle string `string`, or nil when it names no kind."
  @spec kind(String.t()) :: kind() | nil
  def kind(string), do: Map.get(@kinds_by_string, string)

  @doc "The kinds that get their own Replace / Skip / Copy decision on import."
  @spec decision_kinds() :: [kind()]
  def decision_kinds, do: @decision_kinds

  @doc """
  The `.mythweaver` file bytes for `bundle`: zstd (one frame, with its content size) over the SQLite
  database. `meta` is written with `"format"` and `"version"` fixed, and `"app_version"` and
  `"exported_at"` filled in unless given; nil values are left out.
  """
  @spec encode(t()) :: binary()
  def encode(%__MODULE__{} = bundle) do
    meta =
      %{"app_version" => app_version(), "exported_at" => DateTime.to_iso8601(DateTime.utc_now(:second))}
      |> Map.merge(bundle.meta)
      |> Map.merge(%{"format" => @format, "version" => "1"})

    %{
      meta: for({key, value} <- Enum.sort(meta), value != nil, do: [key, value]),
      items:
        Enum.map(
          bundle.items,
          &[&1.uid, Map.fetch!(@kinds, &1.kind), &1.name, root(&1.root), &1.position, Jason.encode!(&1.data)]
        ),
      messages:
        for(
          {chat_uid, messages} <- Enum.sort(bundle.messages),
          {message, position} <- Enum.with_index(messages),
          do: [chat_uid, position, Jason.encode!(message)]
        ),
      blobs:
        for(
          {uid, blob} <- Enum.sort(bundle.blobs),
          do: [uid, Atom.to_string(blob.kind), blob.content_type, blob.filename, blob.description, blob.bytes]
        )
    }
    |> SQLite.write()
    |> :zstd.compress()
    |> IO.iodata_to_binary()
  end

  defp root(true), do: 1
  defp root(false), do: 0

  defp app_version, do: to_string(Application.spec(:mythweaver, :vsn))

  @doc """
  Reads `.mythweaver` file bytes. Refuses (`{:error, message}`) input over 1 GiB decompressed, or
  without a declared size, or whose size doesn't match it; a database of a newer format version; and
  anything that isn't a sound bundle database (wrong `application_id`, a failed `quick_check`,
  triggers or views in its schema, missing tables, malformed rows or JSON).
  """
  @spec decode(binary()) :: {:ok, t()} | {:error, String.t()}
  def decode(bytes) when is_binary(bytes) do
    with {:ok, database} <- decompress(bytes),
         {:ok, rows} <- read(database),
         {:ok, bundle} <- build(rows) do
      {:ok, bundle}
    else
      :error -> {:error, invalid()}
      {:error, _message} = error -> error
    end
  end

  defp read(database) do
    case SQLite.read(database) do
      {:ok, rows} -> {:ok, rows}
      {:error, :newer} -> {:error, newer()}
      {:error, :invalid} -> {:error, invalid()}
    end
  end

  defp decompress(bytes) do
    case frame_size(bytes) do
      {:ok, size} when size > @max_size -> {:error, too_large()}
      {:ok, size} -> inflate(bytes, size)
      :error -> {:error, invalid()}
    end
  end

  defp frame_size(bytes) do
    case :zstd.get_frame_header(bytes) do
      {:ok, %{frameType: :ZSTD_frame, frameContentSize: size}} when is_integer(size) -> {:ok, size}
      _other -> :error
    end
  rescue
    _error -> :error
  end

  defp inflate(bytes, size) do
    {:ok, context} = :zstd.context(:decompress)

    try do
      inflate(context, bytes, size, 0, [])
    rescue
      ErlangError -> {:error, invalid()}
    after
      :zstd.close(context)
    end
  end

  defp inflate(context, bytes, size, seen, acc) do
    {chunk, rest} = if byte_size(bytes) > @chunk, do: split(bytes), else: {bytes, <<>>}

    {status, rest, output} =
      case if(rest == <<>>, do: :zstd.finish(context, chunk), else: :zstd.stream(context, chunk)) do
        {:done, output} -> {:done, rest, output}
        {:continue, output} -> {:continue, rest, output}
        {:continue, remainder, output} -> {:continue, IO.iodata_to_binary([remainder, rest]), output}
      end

    seen = seen + IO.iodata_length(output)
    acc = [acc | output]

    cond do
      seen > size -> {:error, invalid()}
      status == :done and seen == size -> {:ok, IO.iodata_to_binary(acc)}
      status == :done -> {:error, invalid()}
      true -> inflate(context, rest, size, seen, acc)
    end
  end

  defp split(bytes), do: {binary_part(bytes, 0, @chunk), binary_part(bytes, @chunk, byte_size(bytes) - @chunk)}

  defp build(rows) do
    with {:ok, meta} <- build_meta(rows.meta),
         {:ok, items} <- all_ok(rows.items, &db_item/1),
         :ok <- unique_uids(items),
         {:ok, messages} <- all_ok(rows.messages, &db_message/1),
         {:ok, blobs} <- all_ok(rows.blobs, &db_blob/1) do
      {:ok,
       %__MODULE__{
         meta: meta,
         items: items,
         messages: Enum.group_by(messages, &elem(&1, 0), &elem(&1, 1)),
         blobs: Map.new(blobs)
       }}
    end
  end

  defp build_meta(rows) do
    meta = Map.new(rows, fn [key, value] -> {key, value} end)

    if meta["format"] == @format and Enum.all?(meta, fn {k, v} -> is_binary(k) and is_binary(v) end),
      do: {:ok, meta},
      else: :error
  end

  defp db_item([uid, kind, name, root, position, data]) when root in [0, 1] and is_integer(position) do
    with {:ok, data} <- json_map(data), do: item(uid, kind, name, root == 1, position, data)
  end

  defp db_item(_row), do: :error

  defp db_message([chat_uid, _position, data]) when is_binary(chat_uid) do
    with {:ok, data} <- json_map(data), do: {:ok, {chat_uid, data}}
  end

  defp db_message(_row), do: :error

  defp db_blob([uid, kind, content_type, filename, description, bytes])
       when is_binary(uid) and is_binary(kind) and is_binary(content_type) and is_binary(bytes) and
              (is_binary(filename) or is_nil(filename)) and (is_binary(description) or is_nil(description)) do
    case Enum.find(Ecto.Enum.values(Attachment, :kind), &(Atom.to_string(&1) == kind)) do
      nil ->
        :error

      kind ->
        {:ok,
         {uid, %{kind: kind, content_type: content_type, filename: filename, description: description, bytes: bytes}}}
    end
  end

  defp db_blob(_row), do: :error

  defp json_map(text) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _other -> :error
    end
  end

  defp json_map(_text), do: :error

  defp item(uid, kind, name, root, position, data)
       when is_binary(uid) and is_binary(kind) and is_binary(name) and is_map(data) do
    with {:ok, _uuid} <- Ecto.UUID.cast(uid),
         kind when kind != nil <- kind(kind) do
      {:ok, %{uid: uid, kind: kind, name: name, root: root, position: position, data: data}}
    else
      _other -> :error
    end
  end

  defp item(_uid, _kind, _name, _root, _position, _data), do: :error

  defp unique_uids(items) do
    uids = Enum.map(items, & &1.uid)
    if length(Enum.uniq(uids)) == length(uids), do: :ok, else: :error
  end

  defp all_ok(list, fun) do
    Enum.reduce_while(list, {:ok, []}, fn element, {:ok, acc} ->
      case fun.(element) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      :error -> :error
    end
  end

  @doc """
  Lowercase hex sha256 of `term` in deterministic external term format. External files store it so
  an import can tell whether their standard fields changed since export.
  """
  @spec digest(term()) :: String.t()
  def digest(term),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(term, [:deterministic])) |> Base.encode16(case: :lower)

  @doc """
  The `extensions.mythweaver` map for `bundle` with standard-field digest `digest`:
  `%{"version" => 1, "digest" => digest, "roots" => [uid], "items" => [%{"uid", "kind", "name",
  "data"}]}` in position order, plus `"messages"` when any chat has a transcript. Blobs are not
  embedded.

  `"messages"` is one flat list: each message map gains a `"chat_uid"` key naming its chat, chats
  in uid order, each chat's messages in transcript order.
  """
  @spec to_embedded(t(), String.t()) :: map()
  def to_embedded(%__MODULE__{} = bundle, digest) do
    items = Enum.sort_by(bundle.items, & &1.position)

    embedded = %{
      "version" => 1,
      "digest" => digest,
      "roots" => for(item <- items, item.root, do: item.uid),
      "items" =>
        Enum.map(
          items,
          &%{"uid" => &1.uid, "kind" => Map.fetch!(@kinds, &1.kind), "name" => &1.name, "data" => &1.data}
        )
    }

    messages =
      for {chat_uid, messages} <- Enum.sort(bundle.messages),
          message <- messages,
          do: Map.put(message, "chat_uid", chat_uid)

    if messages == [], do: embedded, else: Map.put(embedded, "messages", messages)
  end

  @doc """
  A bundle from an `extensions.mythweaver` map (`to_embedded/2`'s shape), or `:error` when it isn't
  version 1 or its shapes are wrong: `roots` a list of item uids, `items` a list of maps with a
  UUID `"uid"` (unique), a known `"kind"`, a string `"name"` and a map `"data"`, and the optional
  `"messages"` a list of maps each carrying a string `"chat_uid"`.

  Items keep their list order as `position` and are `root` when listed in `roots`. Messages are
  grouped by `"chat_uid"` (removed from each map), keeping their order. The digest is not checked
  here. The bundle has no meta and no blobs.
  """
  @spec from_embedded(map()) :: {:ok, t()} | :error
  def from_embedded(%{"version" => 1, "roots" => roots, "items" => items} = embedded)
      when is_list(roots) and is_list(items) do
    roots = MapSet.new(roots)

    with {:ok, items} <- all_ok(Enum.with_index(items), &embedded_item(&1, roots)),
         :ok <- unique_uids(items),
         true <- MapSet.subset?(roots, MapSet.new(items, & &1.uid)),
         {:ok, messages} <- embedded_messages(Map.get(embedded, "messages")) do
      {:ok, %__MODULE__{items: items, messages: messages}}
    else
      _other -> :error
    end
  end

  def from_embedded(_embedded), do: :error

  defp embedded_item({%{"uid" => uid, "kind" => kind, "name" => name, "data" => data}, position}, roots),
    do: item(uid, kind, name, MapSet.member?(roots, uid), position, data)

  defp embedded_item(_item, _roots), do: :error

  defp embedded_messages(nil), do: {:ok, %{}}

  defp embedded_messages(messages) when is_list(messages) do
    if Enum.all?(messages, &match?(%{"chat_uid" => chat_uid} when is_binary(chat_uid), &1)),
      do: {:ok, Enum.group_by(messages, & &1["chat_uid"], &Map.delete(&1, "chat_uid"))},
      else: :error
  end

  defp embedded_messages(_messages), do: :error
end
