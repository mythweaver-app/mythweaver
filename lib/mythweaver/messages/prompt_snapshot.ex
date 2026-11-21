defmodule Mythweaver.Messages.PromptSnapshot do
  @moduledoc """
  What one generation actually sent and received, attached to the swipe it produced.

  `sections` are the resolved prompt blocks in order with their token counts and template errors,
  `lore` the activation result that fed them (with each entry's rendered text), `injections` what
  became of each chat injection, `variable_writes` the template variable writes the generation
  committed, `request` the exact JSON body the adapter sent (no headers), and `response` the assembled
  outcome: final text, reasoning, finish reason, usage, or the error. `context` is the context-limit
  fit (`Mythweaver.Prompts.ContextLimit`; nil when the reply had no limit). `protected` is the build's
  `protected_values` (`"label"`, `"text"`, `"source"`: `"site"` or `"share"`), what `redacted/2`
  scrubs. The row is kept unredacted; `redacted/2` is the only view the UI renders, so hidden
  content never reaches a page that may not read it.

  Every map is stored with string keys (`Mythweaver.Messages` normalizes through JSON), so a struct
  returned from an insert reads the same as one loaded from the database.
  """

  use Mythweaver.Schema
  use Gettext, backend: Mythweaver.Gettext

  import Ecto.Changeset

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.AI.Model
  alias Mythweaver.Attachments
  alias Mythweaver.Lore.Activation
  alias Mythweaver.Messages.MessageBody
  alias Mythweaver.Prompts.Builder
  alias Mythweaver.Prompts.Prompt
  alias Mythweaver.Sharing.Protected
  alias Mythweaver.Sharing.Visibility
  alias Mythweaver.Tokenizer

  @type t :: %__MODULE__{}

  schema "prompt_snapshots" do
    field :tokenizer, :string
    field :sections, {:array, :map}, default: []
    field :lore, :map, default: %{}
    field :request, :map
    field :response, :map
    field :variable_writes, {:array, :map}, default: []
    field :template_errors, {:array, :string}, default: []
    field :injections, {:array, :map}, default: []
    field :context, :map
    field :protected, {:array, :map}, default: []

    belongs_to :message_body, MessageBody
    belongs_to :ai_model, Model

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Captured before the request goes out; `message_body_id` is set on the struct, never cast."
  def create_changeset(snapshot, attrs),
    do:
      cast(snapshot, attrs, [
        :ai_model_id,
        :tokenizer,
        :sections,
        :lore,
        :variable_writes,
        :template_errors,
        :injections,
        :context,
        :protected
      ])

  @doc "The request and response arrive later in the stream."
  def update_changeset(snapshot, attrs), do: cast(snapshot, attrs, [:request, :response])

  @doc """
  The `sections`, `lore`, `template_errors`, `injections`, `context` and `protected` attrs for
  `prompt` as `Builder.build/2` built it, with `lore` the `Activation.resolve/2` result it was built
  from. Sections are counted in `model`'s tokenizer (`nil` estimates). Share stamps are for the
  build's chat owner (`built.owner_id`).
  """
  @spec build_attrs(Prompt.t(), Builder.built(), Activation.result(), Model.t() | nil) :: map()
  def build_attrs(prompt, built, lore, model) do
    owner_id = built.owner_id

    blocks =
      Map.new(prompt.prompt_blocks, fn %{block: block} ->
        source = Builder.block_source(block, prompt, owner_id)
        {block.id, %{name: block.name, hidden: source == :site, share: source == :share}}
      end)

    %{
      sections: Enum.map(built.segments, &section_map(&1, blocks, model)),
      lore: lore_map(lore, built.lore, owner_id),
      template_errors: built.errors,
      injections: Enum.map(built.injections, &injection_map/1),
      context: context_map(built.context),
      protected:
        Enum.map(built.protected_values, &%{"label" => &1.label, "text" => &1.text, "source" => to_string(&1.source)})
    }
  end

  defp context_map(nil), do: nil

  defp context_map(report) do
    %{
      "limit" => report.limit,
      "reserve" => report.reserve,
      "used" => report.used,
      "kept" => report.kept,
      "trimmed" => report.trimmed,
      "estimated" => report.estimated?,
      "overflow" => report.overflow?
    }
  end

  @doc """
  One `Prompts.Builder` segment, counted in `model`'s tokenizer (`nil` estimates). `blocks` holds each
  block's name and whether it is hidden in the built prompt by the site rule (`hidden`) or the share
  rule (`share`, `Prompts.Builder.block_source/3`); a hidden block's template section is
  `"content_hidden"` or `"share_hidden"`. A chat-history segment's inline images add
  `Attachments.image_tokens/2` each (with the model's `image_detail`), and its natively sent PDFs and
  audio `Attachments.file_tokens/2`, which are always estimates; image ids are kept so the inspector
  can show them.
  """
  @spec section_map(
          map(),
          %{optional(Ecto.UUID.t()) => %{name: String.t(), hidden: boolean(), share: boolean()}},
          Model.t() | nil
        ) :: map()
  def section_map(segment, blocks, model) do
    {tokens, kind} = Tokenizer.count(model, segment.content)
    detail = model && model.image_detail
    block = Map.get(blocks, segment.block_id, %{name: nil, hidden: false, share: false})

    sent =
      for turn <- Map.get(segment, :turns) || [],
          image <- Map.get(turn, :images, []),
          do: %{"id" => image.id, "tokens" => Attachments.image_tokens(image, detail)}

    image_tokens = sent |> Enum.map(& &1["tokens"]) |> Enum.sum()
    files = for turn <- Map.get(segment, :turns) || [], file <- Map.get(turn, :files, []), do: file
    file_tokens = files |> Enum.map(&Attachments.file_tokens(&1, model)) |> Enum.sum()

    %{
      "role" => to_string(segment.role),
      "source" => to_string(segment.source),
      "block_id" => segment.block_id,
      "block_name" => block.name,
      "content" => segment.content,
      # Chat history is what was said, not the block's content, so only a template section hides.
      "content_hidden" => block.hidden and segment.source == :template,
      "share_hidden" => block.share and segment.source == :template,
      "tokens" => tokens + image_tokens + file_tokens,
      "images" => length(sent),
      # Each inline image, in order, with its estimated cost.
      "inline_images" => sent,
      "image_tokens" => image_tokens,
      "file_tokens" => file_tokens,
      "estimated" => kind == :estimate or sent != [] or files != [],
      "template_errors" => Map.get(segment, :errors, [])
    }
  end

  @doc "One `Prompts.Builder` injection report."
  @spec injection_map(Builder.injection_report()) :: map()
  def injection_map(report) do
    %{
      "injection_id" => report.id,
      "key" => report.key,
      "position" => to_string(report.position),
      "depth" => report.depth,
      "role" => report.role && to_string(report.role),
      "status" => to_string(report.status),
      "text" => report.text,
      "template_errors" => report.errors
    }
  end

  @doc """
  The parts of an `Activation.resolve/2` result the inspector shows. `rendered` is
  `Prompts.Builder.build/2`'s `lore`: each entry's rendered text (stored as a one-item list), its
  template errors, and `placed`, false only when the builder had nowhere to put an `at_depth` entry.
  An activated entry is `"share_hidden"` when its book is share-protected for `owner_id`'s chat
  (`Mythweaver.Sharing.Visibility.share_protected?/2`).
  """
  @spec lore_map(Activation.result(), Builder.lore_render(), Ecto.UUID.t() | nil) :: map()
  def lore_map(result, rendered, owner_id) do
    shared =
      result.activated
      |> Enum.uniq_by(& &1.book.id)
      |> Map.new(&{&1.book.id, Visibility.share_protected?(&1.book, owner_id)})

    %{
      "activated" =>
        Enum.map(result.activated, fn decision ->
          render = rendered[decision.entry.id]

          %{
            "entry_id" => decision.entry.id,
            "entry_name" => decision.entry.name,
            "book_id" => decision.book.id,
            "book_name" => decision.book.name,
            "content_hidden" => Visibility.content_hidden?(decision.book),
            "share_hidden" => shared[decision.book.id],
            "book_hidden" => Visibility.book_hidden?(decision.book),
            "slot" => decision.slot,
            "reason" => to_string(decision.reason),
            "pass" => decision.pass,
            "effective_order" => decision.effective_order,
            "tokens" => decision.tokens,
            "content" => decision.entry.content,
            "rendered" =>
              case render do
                %{text: text} -> [text]
                nil -> []
              end,
            "template_errors" =>
              case render do
                %{errors: errors} -> errors
                nil -> []
              end,
            "placed" => not match?(%{placed: false}, render)
          }
        end),
      "rejected" =>
        Enum.map(result.rejected, fn rejection ->
          %{
            "entry_id" => rejection.entry.id,
            "entry_name" => rejection.entry.name,
            "book_name" => rejection.book.name,
            "content_hidden" => Visibility.content_hidden?(rejection.book),
            "book_hidden" => Visibility.book_hidden?(rejection.book),
            "reason" => to_string(rejection.reason),
            "detail" => rejection.detail
          }
        end),
      "budget" => %{
        "limit" => result.budget.limit,
        "used" => result.budget.used,
        "overflowed" => result.budget.overflowed?,
        "estimated" => result.budget.estimated?
      },
      "passes" => result.passes
    }
  end

  @doc """
  The snapshot as `scope` may see it.

  What is hidden: every share-hidden entry, section and `"share"` `protected` value always, since
  a share has no admin bypass; content-hidden (site) ones unless `scope` may view hidden content
  (`Mythweaver.Sharing.Visibility.view_hidden?/1`). Such a scope gets the snapshot unchanged when
  nothing in it is share-hidden.

  A hidden entry's text, raw and rendered, is replaced by `"[Hidden lore: Book]"` (`"[Hidden
  lore]"` when the whole book is site-hidden), each hidden `protected` text by its label, and each
  hidden section's text by `"[Hidden block: Name]"`, longest first, in the sections, the injections
  (whose templates can quote `anchors.lore.*`), the snapshot's and sections' template errors,
  anywhere in the request, and the response's reasoning (not its text). A hidden section's content
  becomes its label and its template errors, which can quote its source, are dropped, as are a
  hidden entry's. Without `view_hidden?`, a site-hidden book's entry and book names are replaced and
  every activated entry's content and rendered text are dropped from `lore` (they are visible in the
  sections); with it, only share-hidden entries lose theirs. Token counts are untouched.

  Rows from before user visibility carry `"locked"`, read as content-hidden; rows from before shares
  have no `"share_hidden"` or `"source"`, read as not share-hidden and `"site"`.
  """
  @spec redacted(Scope.t() | nil, %__MODULE__{}) :: %__MODULE__{}
  def redacted(scope, %__MODULE__{} = snapshot) do
    view? = Visibility.view_hidden?(scope)
    if view? and not share_hidden?(snapshot), do: snapshot, else: redact(snapshot, view?)
  end

  defp share_hidden?(snapshot) do
    Enum.any?(snapshot.sections || [], &share_hidden_item?/1) or
      Enum.any?(Map.get(snapshot.lore || %{}, "activated", []), &share_hidden_item?/1) or
      Enum.any?(snapshot.protected || [], &(&1["source"] == "share"))
  end

  defp redact(snapshot, view?) do
    activated = Map.get(snapshot.lore || %{}, "activated", [])

    # Templates see only a placeholder for protected lore, so the text recorded in the snapshot is
    # the entry's own rendered text and exact-text replacement finds it. Snapshots from before
    # templates have no "rendered" key, so the raw content is scrubbed too.
    lore_pairs =
      for entry <- activated,
          entry_hidden?(entry, view?),
          text <- [entry["content"] | Map.get(entry, "rendered", [])],
          is_binary(text) and String.trim(text) != "",
          do: {text, hidden_label(entry)}

    protected_pairs =
      for %{"text" => text, "label" => label} = value <- snapshot.protected || [],
          value_hidden?(value, view?),
          do: {text, label}

    section_pairs =
      for section <- snapshot.sections,
          section_hidden?(section, view?),
          do: {section["content"], section_label(section)}

    replacements = lore_pairs ++ protected_pairs ++ section_pairs

    %{
      snapshot
      | sections: Enum.map(snapshot.sections, &redact_section(&1, replacements, view?)),
        template_errors: scrub(snapshot.template_errors || [], replacements),
        injections:
          Enum.map(snapshot.injections || [], fn injection ->
            injection
            |> Map.update("text", nil, &scrub(&1, replacements))
            |> Map.update("template_errors", [], &scrub(&1, replacements))
          end),
        request: scrub(snapshot.request, replacements),
        response: redact_response(snapshot.response, replacements),
        lore: redact_lore(snapshot.lore || %{}, view?),
        # The texts themselves: a redacted copy must not carry what it scrubbed.
        protected:
          Enum.map(snapshot.protected || [], fn value ->
            if value_hidden?(value, view?), do: Map.delete(value, "text"), else: value
          end)
    }
  end

  defp redact_section(section, replacements, view?) do
    if section_hidden?(section, view?) do
      Map.merge(section, %{"content" => section_label(section), "template_errors" => []})
    else
      section
      |> Map.update("content", nil, &scrub(&1, replacements))
      |> Map.update("template_errors", [], &scrub(&1, replacements))
    end
  end

  defp section_hidden?(section, view?),
    do: share_hidden_item?(section) or (not view? and section["content_hidden"] == true)

  defp section_label(section),
    do:
      dpgettext("chat", "status: stands in for a hidden prompt block's text", "[Hidden block: %{block_name}]",
        block_name: section["block_name"]
      )

  defp redact_response(%{"reasoning" => reasoning} = response, replacements),
    do: %{response | "reasoning" => scrub(reasoning, replacements)}

  defp redact_response(response, _replacements), do: response

  defp share_hidden_item?(item), do: Map.get(item, "share_hidden") == true
  defp content_hidden?(entry), do: Map.get(entry, "content_hidden", Map.get(entry, "locked", false)) == true
  defp entry_hidden?(entry, view?), do: share_hidden_item?(entry) or (not view? and content_hidden?(entry))
  defp value_hidden?(value, view?), do: value["source"] == "share" or not view?
  defp book_hidden?(entry), do: Map.get(entry, "book_hidden", false) == true

  defp hidden_label(entry) do
    if book_hidden?(entry),
      do: dpgettext("chat", "status: stands in for hidden lore's text", "[Hidden lore]"),
      else:
        dpgettext("chat", "status: stands in for hidden lore's text", "[Hidden lore: %{book_name}]",
          book_name: entry["book_name"]
        )
  end

  defp scrub(value, replacements), do: Protected.scrub(value, replacements)

  defp redact_lore(lore, true) do
    Map.update(lore, "activated", [], fn entries ->
      Enum.map(entries, fn entry ->
        if share_hidden_item?(entry),
          do: Map.drop(entry, ["content", "rendered", "template_errors"]),
          else: entry
      end)
    end)
  end

  defp redact_lore(lore, false) do
    lore
    |> Map.update("activated", [], fn entries ->
      Enum.map(entries, &(&1 |> hide_names() |> Map.drop(["content", "rendered"]) |> drop_hidden_errors()))
    end)
    |> Map.update("rejected", [], fn entries -> Enum.map(entries, &hide_names/1) end)
  end

  defp hide_names(entry) do
    if book_hidden?(entry) do
      Map.merge(entry, %{
        "entry_name" => dpgettext("chat", "status: name shown for a lore entry hidden from the viewer", "Hidden entry"),
        "book_name" => dpgettext("chat", "status: name shown for a lore book hidden from the viewer", "Hidden book")
      })
    else
      entry
    end
  end

  defp drop_hidden_errors(entry) do
    if entry_hidden?(entry, false), do: Map.delete(entry, "template_errors"), else: entry
  end
end
