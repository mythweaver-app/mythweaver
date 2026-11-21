defmodule Mythweaver.Export do
  @moduledoc """
  Exports: picking what to export, previewing what it carries, and building the file.

  Exportable kinds are `kinds/0`; `exportables/2` lists a scope's rows of one kind. A request
  (`request/1`, from the export form's params) names `{kind, id}` items and a format. `:native`
  (a `.mythweaver` bundle, `Mythweaver.Bundle.encode/1`) takes any selection; the SillyTavern
  formats take exactly one item of a fitting kind (`formats/2`). Every file carries the selection's
  owned closure (`Mythweaver.Export.Collect`); external files embed it under
  `extensions.mythweaver` so a Mythweaver import is lossless.
  """

  use Gettext, backend: Mythweaver.Gettext

  import Ecto.Query, only: [order_by: 3]

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.AI
  alias Mythweaver.Attachments
  alias Mythweaver.Attachments.Attachment
  alias Mythweaver.Bundle
  alias Mythweaver.Characters
  alias Mythweaver.Characters.Character
  alias Mythweaver.Chats
  alias Mythweaver.Chats.Chat
  alias Mythweaver.Export.Card
  alias Mythweaver.Export.ChatLog
  alias Mythweaver.Export.Collect
  alias Mythweaver.Export.Preset
  alias Mythweaver.Export.WorldInfo
  alias Mythweaver.Lore
  alias Mythweaver.Memory
  alias Mythweaver.Ownership
  alias Mythweaver.Prompts
  alias Mythweaver.Repo
  alias Mythweaver.Scripts.Script
  alias Mythweaver.Sharing.Visibility

  defmodule Request do
    @moduledoc """
    A parsed export request: the `{kind, id}` items, the format, the preset's sampler model, and
    whether a SillyTavern file carries the Mythweaver bundle (`include_bundle`).
    """
    defstruct items: [], format: :native, sampler_model_id: nil, include_bundle: true

    @type t :: %__MODULE__{
            items: [{Bundle.kind(), Ecto.UUID.t()}],
            format: Mythweaver.Export.format(),
            sampler_model_id: Ecto.UUID.t() | nil,
            include_bundle: boolean()
          }
  end

  @type format :: :native | :card_png | :card_json | :charx | :world_info | :st_preset | :st_chat

  @kinds [:character, :lore_book, :prompt, :ai_model, :script, :memory_profile, :side_prompt, :side_prompt_set, :chat]

  @kinds_by_string Map.new(@kinds, &{Atom.to_string(&1), &1})

  @formats %{
    "native" => :native,
    "card_png" => :card_png,
    "card_json" => :card_json,
    "charx" => :charx,
    "world_info" => :world_info,
    "st_preset" => :st_preset,
    "st_chat" => :st_chat
  }

  @doc "The exportable kinds with their labels, in display order."
  @spec kinds() :: [{Bundle.kind(), String.t()}]
  def kinds, do: Enum.map(@kinds, &{&1, kind_label(&1)})

  defp kind_label(:character), do: dpgettext("import_export", "tab: kind of item to export", "Characters")
  defp kind_label(:lore_book), do: dpgettext("import_export", "tab: kind of item to export", "Lore books")
  defp kind_label(:prompt), do: dpgettext("import_export", "tab: kind of item to export", "Prompts")
  defp kind_label(:ai_model), do: dpgettext("import_export", "tab: kind of item to export", "AI models")
  defp kind_label(:script), do: dpgettext("import_export", "tab: kind of item to export", "Scripts")
  defp kind_label(:memory_profile), do: dpgettext("import_export", "tab: kind of item to export", "Memory profiles")
  defp kind_label(:side_prompt), do: dpgettext("import_export", "tab: kind of item to export", "Side prompts")
  defp kind_label(:side_prompt_set), do: dpgettext("import_export", "tab: kind of item to export", "Side prompt sets")
  defp kind_label(:chat), do: dpgettext("import_export", "tab: kind of item to export", "Chats")

  defp format_label(:native), do: dpgettext("import_export", "option: file format of an export", "Mythweaver bundle")

  defp format_label(:card_png),
    do: dpgettext("import_export", "option: file format of an export", "Character card (PNG)")

  defp format_label(:card_json),
    do: dpgettext("import_export", "option: file format of an export", "Character card (JSON)")

  defp format_label(:charx),
    do: dpgettext("import_export", "option: file format of an export", "Character card (CHARX)")

  defp format_label(:world_info), do: "SillyTavern World Info"

  defp format_label(:st_preset),
    do: dpgettext("import_export", "option: file format of an export", "SillyTavern preset")

  defp format_label(:st_chat), do: dpgettext("import_export", "option: file format of an export", "SillyTavern chat")

  @content_type "application/vnd.mythweaver.bundle"

  defp nothing,
    do:
      dpgettext(
        "import_export",
        "status: flash when an export is submitted with nothing chosen",
        "Choose something to export."
      )

  defp unknown_format,
    do:
      dpgettext(
        "import_export",
        "status: error when an export names a format that doesn't exist",
        "Unknown export format."
      )

  defp unavailable, do: dgettext("import_export", "Something you picked is no longer available.")

  defp not_png,
    do:
      dgettext("import_export", "The avatar isn't a PNG and the image proxy can't convert it; choose CHARX to keep it.")

  @doc """
  The rows of `kind` `scope` may export, as `%{id, name}`, by name. Site rows whose content is
  hidden from `scope` (runtime-only characters, prompts and scripts, runtime-only or hidden lore
  books) are left out; chats are `scope`'s own role-play chats.
  """
  @spec exportables(Scope.t(), Bundle.kind()) :: [%{id: Ecto.UUID.t(), name: String.t()}]
  def exportables(%Scope{} = scope, kind) do
    scope
    |> rows(kind)
    |> Enum.map(&%{id: &1.id, name: name(kind, &1)})
  end

  defp rows(scope, kind) when kind in [:character, :lore_book, :prompt, :script],
    do: scope |> visible_rows(kind) |> Enum.reject(&Visibility.content_hidden_for?(scope, &1))

  defp rows(scope, :ai_model),
    do: Enum.sort_by(AI.list_models(scope) ++ AI.list_embedding_models(scope), &{&1.name, &1.id})

  defp rows(scope, :memory_profile), do: Memory.list_usable_profiles(scope)
  defp rows(scope, :side_prompt), do: Memory.list_usable_side_prompts(scope)
  defp rows(scope, :side_prompt_set), do: Memory.list_usable_side_prompt_sets(scope)
  defp rows(scope, :chat), do: Chats.list_chats(scope, :roleplay)

  defp visible_rows(scope, :character), do: Characters.list_characters(scope)
  defp visible_rows(scope, :lore_book), do: Lore.list_usable_books(scope)
  defp visible_rows(scope, :prompt), do: Prompts.list_prompts(scope)

  defp visible_rows(scope, :script),
    do: Script |> Ownership.usable(scope) |> order_by([s], asc: s.name, asc: s.id) |> Repo.all()

  defp name(:chat, chat), do: Chat.title(chat)
  defp name(_kind, row), do: row.name

  @doc """
  Whether `row`, a `kind` row `scope` already sees, is one of `exportables/2`, checked without
  listing them: content-hidden site rows, classifier models and other users' chats are not.
  """
  @spec exportable_row?(Scope.t(), Bundle.kind(), struct()) :: boolean()
  def exportable_row?(scope, kind, row) when kind in [:character, :lore_book, :prompt, :script],
    do: not Visibility.content_hidden_for?(scope, row)

  def exportable_row?(scope, :ai_model, %AI.Model{} = model),
    do: model.completion_mode != :classifier and AI.usable?(scope, model)

  def exportable_row?(%Scope{user: %{id: uid}}, :chat, %Chat{kind: :roleplay, user_id: uid}), do: true
  def exportable_row?(_scope, :chat, _row), do: false

  def exportable_row?(_scope, kind, _row) when kind in [:memory_profile, :side_prompt, :side_prompt_set], do: true

  @doc """
  Parses the export form's params: `"items"` (`["kind:id", ...]`; unknown kinds and malformed ids
  are ignored), `"format"` (default `"native"`), `"sampler_model_id"` (blank for none) and
  `"include_bundle"` (`"false"` leaves the Mythweaver bundle out of a SillyTavern file).
  """
  @spec request(map()) :: {:ok, Request.t()} | {:error, String.t()}
  def request(params) when is_map(params) do
    items = params |> Map.get("items") |> List.wrap() |> Enum.flat_map(&item/1) |> Enum.uniq()

    cond do
      items == [] ->
        {:error, nothing()}

      not Map.has_key?(@formats, Map.get(params, "format", "native")) ->
        {:error, unknown_format()}

      true ->
        {:ok,
         %Request{
           items: items,
           format: Map.fetch!(@formats, Map.get(params, "format", "native")),
           sampler_model_id: uuid(params["sampler_model_id"]),
           include_bundle: params["include_bundle"] != "false"
         }}
    end
  end

  defp item(value) when is_binary(value) do
    with [kind, id] <- String.split(value, ":", parts: 2),
         {:ok, kind} <- Map.fetch(@kinds_by_string, kind),
         {:ok, id} <- Ecto.UUID.cast(id) do
      [{kind, id}]
    else
      _other -> []
    end
  end

  defp item(_value), do: []

  defp uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> id
      :error -> nil
    end
  end

  defp uuid(_value), do: nil

  @doc """
  The formats for exporting `items`, each `%{format, label, available?, reason}`: the native bundle
  always; for exactly one item, its kind's SillyTavern formats too. A PNG card needs no avatar, a PNG
  one, or an image proxy that re-encodes to PNG (`Mythweaver.Attachments.png?/1`).
  """
  @spec formats(Scope.t(), [{Bundle.kind(), Ecto.UUID.t()}]) :: [
          %{format: format(), label: String.t(), available?: boolean(), reason: String.t() | nil}
        ]
  def formats(%Scope{} = scope, items) do
    [format(:native) | single_formats(scope, items)]
  end

  defp single_formats(scope, [{:character, id}]) do
    png =
      case character(scope, id) do
        %Character{avatar: %Attachment{} = avatar} ->
          if Attachments.png?(avatar), do: format(:card_png), else: format(:card_png, not_png())

        _other ->
          format(:card_png)
      end

    [png, format(:card_json), format(:charx)]
  end

  defp single_formats(_scope, [{:lore_book, _id}]), do: [format(:world_info)]
  defp single_formats(_scope, [{:prompt, _id}]), do: [format(:st_preset)]
  defp single_formats(_scope, [{:chat, _id}]), do: [format(:st_chat)]
  defp single_formats(_scope, _items), do: []

  defp format(format, reason \\ nil),
    do: %{format: format, label: format_label(format), available?: is_nil(reason), reason: reason}

  defp character(scope, id) do
    case Characters.get_character(scope, id) do
      nil -> nil
      character -> Characters.preload_avatar(scope, character)
    end
  end

  @doc """
  What `build/2` would put in the file, without reading files or transcripts: counts by kind (plus
  `:message` and `:blob`) and the warnings about left-out lore.
  """
  @spec plan(Scope.t(), Request.t()) ::
          {:ok, %{counts: %{atom() => non_neg_integer()}, warnings: [String.t()]}} | {:error, String.t()}
  def plan(%Scope{} = scope, %Request{} = request) do
    with :ok <- check(scope, request),
         {:ok, counts, warnings} <- Collect.plan(scope, request.items) do
      {:ok, %{counts: counts, warnings: warnings}}
    end
  end

  @doc """
  The export file for `request`: `%{bytes, filename, content_type, warnings}`. Every item must be
  one of `exportables/2`, and the format one `formats/2` offers as available.
  """
  @spec build(Scope.t(), Request.t()) ::
          {:ok, %{bytes: binary(), filename: String.t(), content_type: String.t(), warnings: [String.t()]}}
          | {:error, String.t()}
  def build(%Scope{} = scope, %Request{} = request) do
    with :ok <- check(scope, request),
         {:ok, bundle, warnings} <- Collect.run(scope, request.items) do
      file = file(scope, request, bundle)
      {:ok, %{file | warnings: Map.get(file, :warnings, []) ++ warnings}}
    end
  end

  defp check(scope, %Request{items: items, format: format}) do
    cond do
      items == [] ->
        {:error, nothing()}

      not exportable?(scope, items) ->
        {:error, unavailable()}

      true ->
        case Enum.find(formats(scope, items), &(&1.format == format)) do
          nil -> {:error, unknown_format()}
          %{available?: false, reason: reason} -> {:error, reason}
          %{} -> :ok
        end
    end
  end

  defp exportable?(scope, items) do
    items
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.all?(fn {kind, ids} ->
      available = MapSet.new(exportables(scope, kind), & &1.id)
      Enum.all?(ids, &MapSet.member?(available, &1))
    end)
  end

  defp file(_scope, %Request{format: :native}, bundle) do
    roots = Enum.filter(bundle.items, & &1.root)

    {title, filename} =
      case roots do
        [root] -> {root.name, filename(root.name, "mythweaver")}
        _many -> {"Mythweaver export", "mythweaver-export-#{Date.utc_today()}.mythweaver"}
      end

    %{
      bytes: Bundle.encode(%{bundle | meta: %{"title" => title}}),
      filename: filename,
      content_type: @content_type,
      warnings: []
    }
  end

  defp file(scope, %Request{format: format} = request, bundle) do
    root = Enum.find(bundle.items, & &1.root).uid

    opts = [bundle: request.include_bundle]

    case format do
      :card_png -> bundle |> png_avatar(scope, request.items, root) |> Card.file(root, :card_png, opts)
      format when format in [:card_json, :charx] -> Card.file(bundle, root, format, opts)
      :world_info -> WorldInfo.file(bundle, root, opts)
      :st_preset -> Preset.file(bundle, root, sampler_model(scope, request.sampler_model_id), opts)
      :st_chat -> ChatLog.file(bundle, root, opts)
    end
  end

  # A PNG card's image is its avatar, so a JPEG/WebP/… avatar is re-encoded by the image proxy. When
  # that fails the blob keeps its type and `Card` falls back to the placeholder, with a warning.
  defp png_avatar(bundle, scope, [{:character, id}], root) do
    with %{data: %{"avatar" => uid}} when is_binary(uid) <- Enum.find(bundle.items, &(&1.uid == root)),
         %{content_type: type} = blob when type != "image/png" <- bundle.blobs[uid],
         %Character{avatar: %Attachment{} = avatar} <- character(scope, id),
         {:ok, png} <- Attachments.png(avatar) do
      put_in(bundle.blobs[uid], %{blob | bytes: png, content_type: "image/png"})
    else
      _unchanged -> bundle
    end
  end

  defp sampler_model(_scope, nil), do: nil

  defp sampler_model(scope, id) do
    case Repo.get(AI.Model, id) do
      # A model whose sampler `scope` may not read (Runtime-only) adds none to the preset.
      %AI.Model{} = model ->
        if AI.usable?(scope, model) and not Visibility.content_hidden_for?(scope, model),
          do: model

      nil ->
        nil
    end
  end

  @doc ~S"""
  A download filename: `name` with path and control characters (`/ \ : * ? " < > |`) replaced by
  `_` and trimmed (`"export"` when nothing is left), plus `.ext`.
  """
  @spec filename(String.t() | nil, String.t()) :: String.t()
  def filename(name, ext) do
    base = (name || "") |> String.replace(~r/[\/\\:*?"<>|\x00-\x1f]/, "_") |> String.trim()
    "#{if base == "", do: "export", else: base}.#{ext}"
  end
end
