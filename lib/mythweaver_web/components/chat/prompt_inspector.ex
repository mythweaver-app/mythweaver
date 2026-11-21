defmodule MythweaverWeb.Chat.PromptInspector do
  @moduledoc """
  The prompt modal opened from a message footer: what the active swipe's generation actually sent.

  A summary compares the provider's exact prompt token count with the sum of the counted sections
  (the difference is chat-template overhead) and shows how much of the prompt the provider reused from
  its prompt cache, as a count and as a share of the prompt; the context box likewise shows how full
  the limit is. A one-line bar below it shows what filled the prompt: each section, the template
  overhead and the reserve kept for the reply. Six views then show the resolved sections with their
  share of the prompt and any template errors, the lore activation result, what became of each chat
  injection, the variable writes the prompt's templates committed, the raw request JSON, and the
  assembled response.

  It renders only `Mythweaver.Messages.PromptSnapshot.redacted/2` output, so hidden lore never
  reaches a non-admin's page.
  """

  use MythweaverWeb, :html

  alias Mythweaver.Attachments
  alias Mythweaver.Format
  alias Mythweaver.Lore.Settings

  @doc "The inspector's views in tab order, as `{view, label}`."
  def views do
    [
      items: dpgettext("chat", "tab: prompt inspector, the prompt's sections", "Sections"),
      lore: dpgettext("chat", "tab: prompt inspector, activated lore", "Lore"),
      injections: dpgettext("chat", "tab: prompt inspector, injections", "Injections"),
      variables: dpgettext("chat", "tab: prompt inspector, variable writes", "Variables"),
      request: dpgettext("chat", "tab: prompt inspector, the raw request", "Request"),
      response: dpgettext("chat", "tab: prompt inspector, the raw response", "Response")
    ]
  end

  attr :inspector, :map, required: true

  def prompt_inspector(assigns) do
    %{snapshot: snapshot, body: body} = assigns.inspector
    sections = snapshot.sections
    sum = Enum.reduce(sections, 0, &(&1["tokens"] + &2))
    estimated? = Enum.any?(sections, & &1["estimated"])
    cached = cached_tokens(snapshot.response)
    chart = chart(sections, sum, body, snapshot.context)

    assigns =
      assign(assigns,
        snapshot: snapshot,
        body: body,
        view: assigns.inspector.view,
        expanded: assigns.inspector.expanded,
        sections: Enum.with_index(sections),
        sum: sum,
        estimated?: estimated?,
        cached: cached,
        cached_share: cached_share(cached, body.prompt_tokens),
        context_full: context_full(snapshot.context),
        chart: chart,
        chart_total: chart |> Enum.map(& &1.tokens) |> Enum.sum(),
        chart_caption: chart_caption(chart, sum, estimated?, snapshot.context),
        lore: snapshot.lore,
        lore_slots: lore_slots(snapshot.lore["activated"]),
        views: views(),
        images: Map.get(assigns.inspector, :images, %{}),
        json: Map.get(%{request: snapshot.request, response: snapshot.response}, assigns.inspector.view)
      )

    ~H"""
    <%!-- `lower-bound="none"`: the content lives inside `<.modal>`'s slot, a nested component root. --%>
    <style :type={MythweaverWeb.ColocatedScopedCSS} lower-bound="none">
      /* The wrapper is the slot root carrying this block's scope marker, so it must be `div:scope`. */
      div:scope {
        display: flex;
        flex-direction: column;
        gap: var(--size-3);
      }

      .prompt-summary {
        display: grid;
        grid-template-columns: repeat(auto-fit, minmax(9rem, 1fr));
        gap: var(--size-2);
        margin: 0;
      }

      .prompt-summary div {
        padding: var(--size-2);
        border: 1px solid var(--border-grey);
        border-radius: var(--radius-2);
      }

      .prompt-summary dt {
        font-size: 0.8rem;
        color: var(--muted-foreground);
      }

      .prompt-summary dd {
        margin: 0;
        font-weight: 600;
        overflow-wrap: anywhere;
      }

      .prompt-views {
        display: flex;
        flex-wrap: wrap;
        gap: var(--size-2);
      }

      .prompt-list {
        list-style: none;
        margin: 0;
        padding: 0;
        display: flex;
        flex-direction: column;
        gap: var(--size-1);
      }

      .prompt-row {
        border: 1px solid var(--border-grey);
        border-radius: var(--radius-2);
      }

      .prompt-section-toggle {
        display: flex;
        flex-direction: column;
        gap: var(--size-1);
        inline-size: 100%;
        text-align: start;
        background: none;
        border: 0;
        padding: var(--size-2);
        color: inherit;
        font: inherit;
        cursor: pointer;
      }

      .prompt-section-toggle:hover {
        background: var(--surface-5);
      }

      .prompt-row-head {
        display: flex;
        flex-wrap: wrap;
        align-items: center;
        gap: var(--size-2);
        font-size: 0.85rem;
        color: var(--muted-foreground);
      }

      .prompt-row-name {
        color: var(--foreground);
        font-weight: 600;
      }

      .prompt-row-tokens {
        margin-inline-start: auto;
      }

      .prompt-section-track {
        display: block;
        block-size: 4px;
        border-radius: var(--radius-1);
        background: var(--surface-4);
        overflow: hidden;
      }

      .prompt-section-bar {
        display: block;
        block-size: 100%;
        background: var(--chart-color, var(--primary-accent));
      }

      .prompt-row-plain {
        padding: var(--size-2);
      }

      .prompt-text,
      .prompt-json {
        white-space: pre-wrap;
        overflow-wrap: anywhere;
        max-block-size: 60dvh;
        overflow: auto;
        margin: 0;
        padding: var(--size-2);
        max-inline-size: none;
      }

      .prompt-text {
        border-block-start: 1px solid var(--border-grey);
      }

      .prompt-section-images {
        display: flex;
        flex-wrap: wrap;
        gap: var(--size-2);
        padding: var(--size-2);
        border-block-start: 1px solid var(--border-grey);
      }

      .prompt-section-images figure {
        display: flex;
        flex-direction: column;
        gap: var(--size-1);
        margin: 0;
      }

      .prompt-section-images img {
        max-inline-size: 160px;
        max-block-size: 160px;
        object-fit: contain;
        border-radius: var(--radius-2);
      }

      .prompt-section-images figcaption {
        font-size: 0.85rem;
        color: var(--muted-foreground);
      }

      .prompt-json {
        font-family: var(--font-monospace-code, ui-monospace, monospace);
        font-size: 0.85rem;
        border: 1px solid var(--border-grey);
        border-radius: var(--radius-2);
      }

      .prompt-lore-budget,
      .prompt-empty {
        display: flex;
        align-items: center;
        gap: var(--size-2);
        margin: 0;
        color: var(--muted-foreground);
      }

      .prompt-lore-heading,
      .prompt-lore-slot {
        margin: 0;
        font-size: 0.9rem;
      }

      .prompt-lore-slot {
        font-size: 0.75rem;
        text-transform: uppercase;
        letter-spacing: 0.05em;
        color: var(--muted-foreground);
      }

      .prompt-section-error {
        margin: 0;
        padding: 0 var(--size-2) var(--size-2);
        font-size: 0.85rem;
        color: var(--destructive);
        overflow-wrap: anywhere;
      }

      .prompt-variable-value {
        font-family: var(--font-monospace-code, ui-monospace, monospace);
        overflow-wrap: anywhere;
      }

      /* The reset (`assets/css/reset.css`) centers a `figure`'s items, which would shrink the bar
         to nothing. */
      .prompt-chart {
        margin: 0;
        display: flex;
        flex-direction: column;
        align-items: stretch;
        gap: var(--size-1);
      }

      .prompt-chart-bar {
        display: flex;
        block-size: 0.75rem;
        border: 1px solid var(--border-grey);
        border-radius: var(--radius-2);
        background: var(--surface-2);
        overflow: hidden;
      }

      /* Grown by token count from a zero basis, so the segments split the bar exactly in proportion.
         Each is the anchor for its own popup; `anchor-scope` keeps the shared name per segment. */
      .prompt-chart-segment {
        flex: var(--tokens) 0 0;
        min-inline-size: 0;
        background: var(--chart-color);
        anchor-name: --prompt-segment;
        anchor-scope: --prompt-segment;
      }

      /* An outline, not `filter`: a filter would make the segment the popup's containing block, so
         the bar's `overflow: hidden` would clip it. */
      .prompt-chart-segment:is(:hover, :focus) {
        outline: 1px solid var(--foreground);
        outline-offset: -1px;
      }

      /* A hairline between neighbors, drawn inside so it takes no width from the proportions. */
      .prompt-chart-segment + .prompt-chart-segment {
        box-shadow: inset 1px 0 var(--background);
      }

      .prompt-chart-segment--overhead {
        background: var(--muted-foreground);
      }

      .prompt-chart-segment--reserve {
        background: repeating-linear-gradient(
          45deg,
          var(--surface-8) 0 4px,
          transparent 4px 8px
        );
      }

      /* `position: fixed` escapes the bar's `overflow: hidden`; it flips to stay on screen. */
      .prompt-chart-popup {
        display: none;
        position: fixed;
        position-anchor: --prompt-segment;
        position-area: block-start center;
        position-try-fallbacks:
          flip-block,
          block-start span-inline-end,
          block-start span-inline-start;
        z-index: 50;
        margin: var(--size-1);
        inline-size: max-content;
        max-inline-size: min(36ch, calc(100vw - 2 * var(--size-2)));
        padding: var(--size-1) var(--size-2);
        border: 1px solid var(--border);
        border-radius: var(--radius-2);
        background: var(--surface-8);
        color: var(--foreground);
        box-shadow: var(--elevation-md);
        font-size: 0.8rem;
        line-height: 1.4;
        pointer-events: none;
      }

      .prompt-chart-segment:is(:hover, :focus) > .prompt-chart-popup {
        display: flex;
        flex-direction: column;
      }

      .prompt-chart-popup strong {
        font-weight: 600;
      }

      .prompt-chart-popup span {
        color: var(--muted-foreground);
      }

      .prompt-chart figcaption {
        font-size: 0.8rem;
        color: var(--muted-foreground);
      }

      .prompt-summary-share {
        font-weight: 400;
        color: var(--muted-foreground);
      }

      /* A tap focuses a segment (`tabindex="-1"`), which shows its popup on touch screens. */
      .prompt-chart-segment:focus {
        outline: 1px solid var(--foreground);
        outline-offset: -1px;
      }
    </style>

    <.modal
      id="prompt-inspector-modal"
      title={dpgettext("chat", "heading: modal showing the prompt a reply was sent", "Prompt")}
      on_cancel="close_prompt_inspector"
      class="modal--wide"
    >
      <div class="prompt-inspector">
        <dl id="prompt-summary" class="prompt-summary">
          <div>
            <dt>{dpgettext("chat", "field label: tokens in the prompt sent", "Prompt tokens")}</dt>
            <dd>{number_or_dash(@body.prompt_tokens)}</dd>
          </div>
          <div :if={@cached} id="prompt-cached">
            <dt>
              {dpgettext("chat", "field label: prompt tokens the provider had cached", "Cached")}
            </dt>
            <dd>
              {Format.number(@cached)}<span
                :if={@cached_share}
                id="prompt-cached-share"
                class="prompt-summary-share"
              > · {Format.percent(@cached_share)}</span>
            </dd>
          </div>
          <div>
            <dt>{dpgettext("chat", "field label: tokens of the prompt's sections", "Sections")}</dt>
            <dd>{approx(@estimated?, @sum)}</dd>
          </div>
          <div :if={@snapshot.context} id="prompt-context">
            <dt>{dpgettext("chat", "field label: context window use of the prompt", "Context")}</dt>
            <dd>
              {dpgettext(
                "chat",
                "status: context window tokens used, its limit and the tokens kept for the reply",
                "%{used_tokens}/%{token_limit} · %{reserved_tokens} reserved",
                used_tokens: approx(@snapshot.context["estimated"], @snapshot.context["used"]),
                token_limit: Format.number(@snapshot.context["limit"]),
                reserved_tokens: Format.number(@snapshot.context["reserve"])
              )}<span
                :if={@context_full}
                id="prompt-context-full"
                class="prompt-summary-share"
              > · {dpgettext(
                "chat",
                "status: how full the context window is",
                "%{context_share} full",
                context_share: Format.percent(@context_full)
              )}</span>
            </dd>
          </div>
          <div :if={@snapshot.context && @snapshot.context["trimmed"] > 0} id="prompt-context-trimmed">
            <dt>{dpgettext("chat", "field label: messages trimmed from the prompt", "Trimmed")}</dt>
            <dd>
              {dpngettext(
                "chat",
                "status: older messages trimmed from the prompt to fit the context window",
                "%{message_count} older message",
                "%{message_count} older messages",
                @snapshot.context["trimmed"],
                message_count: Format.number(@snapshot.context["trimmed"])
              )}
            </dd>
          </div>
          <div :if={@body.prompt_tokens}>
            <dt>
              {dpgettext(
                "chat",
                "field label: prompt tokens outside the sections",
                "Template overhead"
              )}
            </dt>
            <dd>{Format.number(@body.prompt_tokens - @sum)}</dd>
          </div>
          <div>
            <dt>{dpgettext("chat", "field label: tokens in the reply", "Completion tokens")}</dt>
            <dd>{number_or_dash(@body.completion_tokens)}</dd>
          </div>
          <div>
            <dt>
              {dpgettext("chat", "field label: tokenizer that counted the prompt", "Tokenizer")}
            </dt>
            <dd>
              {@snapshot.tokenizer ||
                dpgettext("chat", "status: no tokenizer, counts estimated", "none (estimated)")}
            </dd>
          </div>
        </dl>

        <figure :if={@chart != []} id="prompt-chart" class="prompt-chart">
          <div class="prompt-chart-bar" aria-hidden="true">
            <span
              :for={segment <- @chart}
              id={segment.id}
              class={["prompt-chart-segment", "prompt-chart-segment--#{segment.kind}"]}
              tabindex="-1"
              style={segment_style(segment)}
            >
              <span id={"#{segment.id}-popup"} class="prompt-chart-popup">
                <strong>{segment.label}</strong>
                <span>
                  {dpngettext(
                    "chat",
                    "tooltip: tokens of a prompt chart segment and its share",
                    "%{token_count} token · %{token_share}",
                    "%{token_count} tokens · %{token_share}",
                    segment.tokens,
                    token_count: Format.number(segment.tokens),
                    token_share:
                      Format.percent(if(@chart_total > 0, do: segment.tokens / @chart_total, else: 0),
                        max_fractional_digits: 1
                      )
                  )}
                </span>
              </span>
            </span>
          </div>
          <figcaption id="prompt-chart-caption">{@chart_caption}</figcaption>
        </figure>

        <nav
          class="prompt-views"
          aria-label={dpgettext("chat", "aria label: prompt inspector view switcher", "Prompt views")}
        >
          <.button
            :for={{view, label} <- @views}
            id={"prompt-view-#{view}"}
            phx-click="prompt_inspector_view"
            phx-value-view={view}
            aria-pressed={to_string(@view == view)}
          >
            {label}
          </.button>
        </nav>

        <ul
          :if={@view == :items and @snapshot.template_errors != []}
          id="prompt-template-errors"
          class="prompt-list"
        >
          <li
            :for={{error, i} <- Enum.with_index(@snapshot.template_errors)}
            id={"prompt-template-error-#{i}"}
            class="prompt-section-error"
          >
            {error}
          </li>
        </ul>

        <ol :if={@view == :items} id="prompt-sections" class="prompt-list">
          <li :for={{section, index} <- @sections} id={"prompt-section-#{index}"} class="prompt-row">
            <button
              type="button"
              id={"prompt-section-toggle-#{index}"}
              class="prompt-section-toggle"
              phx-click="toggle_prompt_section"
              phx-value-index={index}
              aria-expanded={to_string(@expanded == index)}
            >
              <span class="prompt-row-head">
                <span class="prompt-row-name">{section["block_name"] || section["source"]}</span>
                <.badge>{section["source"]}</.badge>
                <span>{section["role"]}</span>
                <span class="prompt-row-tokens">
                  {dpngettext(
                    "chat",
                    "unit: tokens of a prompt section",
                    "%{token_count} token",
                    "%{token_count} tokens",
                    section["tokens"],
                    token_count: approx(section["estimated"], section["tokens"])
                  )}
                  <%!-- Older snapshots predate the key. --%>
                  <span
                    :if={(section["images"] || 0) > 0}
                    title={
                      dgettext(
                        "chat",
                        "Image tokens are estimated by OpenAI's tile rule; other backends count differently"
                      )
                    }
                  >
                    {dpngettext(
                      "chat",
                      "status: images counted in a prompt section's token total",
                      "(incl. %{image_count} image ≈%{image_tokens})",
                      "(incl. %{image_count} images ≈%{image_tokens})",
                      section["images"],
                      image_count: Format.number(section["images"]),
                      image_tokens: Format.number(section["image_tokens"])
                    )}
                  </span>
                </span>
              </span>
              <span class="prompt-section-track">
                <span
                  class="prompt-section-bar"
                  style={
                    "inline-size: #{share(section["tokens"], @sum)}%; --chart-color: var(--chart-#{rem(index, 8) + 1})"
                  }
                ></span>
              </span>
            </button>
            <.template_errors
              id={"prompt-section-error-#{index}"}
              errors={section["template_errors"]}
            />
            <%!--
              `phx-no-format`: `.prompt-text` is `pre-wrap`, so any whitespace the formatter adds
              between these tags would render as text.
            --%>
            <div
              :if={@expanded == index}
              id={"prompt-section-text-#{index}"}
              class="prompt-text"
              phx-no-format
            >{section["content"]}</div>
            <%!-- The images this section sent inline, in order, with their estimated cost. The
                 text above still lists their description lines, which were not sent for these. --%>
            <div
              :if={@expanded == index and (section["inline_images"] || []) != []}
              id={"prompt-section-images-#{index}"}
              class="prompt-section-images"
            >
              <figure
                :for={{sent, i} <- Enum.with_index(section["inline_images"], 1)}
                id={"prompt-section-image-#{index}-#{i}"}
              >
                <img
                  :if={@images[sent["id"]]}
                  src={Attachments.url(@images[sent["id"]], :thumb)}
                  alt={
                    @images[sent["id"]].description || @images[sent["id"]].filename ||
                      dpgettext("chat", "alt text: image sent inline in a prompt", "Image")
                  }
                  loading="lazy"
                />
                <figcaption>
                  {image_caption(i, sent["tokens"], !@images[sent["id"]])}
                </figcaption>
              </figure>
            </div>
          </li>
        </ol>

        <div :if={@view == :lore} id="prompt-lore" class="prompt-list">
          <p id="prompt-lore-budget" class="prompt-lore-budget">
            <span>
              {dpngettext(
                "chat",
                "status: lore token budget used of its limit",
                "Budget %{used_tokens}/%{token_limit} token",
                "Budget %{used_tokens}/%{token_limit} tokens",
                @lore["budget"]["limit"],
                used_tokens: approx(@lore["budget"]["estimated"], @lore["budget"]["used"]),
                token_limit: Format.number(@lore["budget"]["limit"])
              )}
            </span>
            <span :if={@lore["passes"]}>
              · {dpngettext(
                "chat",
                "status: lore activation passes",
                "%{pass_count} pass",
                "%{pass_count} passes",
                @lore["passes"],
                pass_count: Format.number(@lore["passes"])
              )}
            </span>
            <.badge :if={@lore["budget"]["overflowed"]}>
              {dpgettext("chat", "badge: lore went over its token budget", "overflowed")}
            </.badge>
          </p>

          <h3 class="prompt-lore-heading">
            {dpgettext("chat", "heading: lore entries that were activated", "Activated")}
          </h3>
          <div id="prompt-lore-activated" class="prompt-list">
            <p :if={@lore_slots == []} class="prompt-empty">
              {dpgettext("chat", "empty state: no activated lore entries", "None")}
            </p>
            <section
              :for={{slot, entries} <- @lore_slots}
              id={"prompt-lore-slot-#{slot}"}
              class="prompt-list"
            >
              <h4 class="prompt-lore-slot">{slot}</h4>
              <ul class="prompt-list">
                <li
                  :for={entry <- entries}
                  id={"prompt-lore-#{entry["entry_id"]}"}
                  class="prompt-row prompt-row-plain"
                >
                  <span class="prompt-row-head">
                    <span class="prompt-row-name">{entry["entry_name"]}</span>
                    <span>{entry["book_name"]}</span>
                    <.badge :if={entry["placed"] == false}>
                      {dpgettext("chat", "badge: lore entry activated but not placed", "not placed")}
                    </.badge>
                    <span>{entry["reason"]}</span>
                    <span :if={entry["effective_order"]}>
                      {dpgettext(
                        "chat",
                        "unit: insertion order of a lore entry",
                        "order %{lore_order}",
                        lore_order: Format.number(entry["effective_order"])
                      )}
                    </span>
                    <span :if={entry["pass"]}>
                      {dpgettext(
                        "chat",
                        "unit: activation pass of a lore entry",
                        "pass %{pass_number}",
                        pass_number: Format.number(entry["pass"])
                      )}
                    </span>
                    <span class="prompt-row-tokens">
                      {dpngettext(
                        "chat",
                        "unit: tokens of a lore entry",
                        "%{token_count} token",
                        "%{token_count} tokens",
                        entry["tokens"],
                        token_count: Format.number(entry["tokens"])
                      )}
                    </span>
                  </span>
                  <.template_errors
                    id={"prompt-lore-error-#{entry["entry_id"]}"}
                    errors={entry["template_errors"]}
                  />
                </li>
              </ul>
            </section>
          </div>

          <h3 class="prompt-lore-heading">
            {dpgettext("chat", "heading: lore entries that were rejected", "Rejected")}
          </h3>
          <ul id="prompt-lore-rejected" class="prompt-list">
            <li :if={@lore["rejected"] == []} class="prompt-empty">
              {dpgettext("chat", "empty state: no rejected lore entries", "None")}
            </li>
            <li :for={entry <- @lore["rejected"]} class="prompt-row prompt-row-plain">
              <span class="prompt-row-head">
                <span class="prompt-row-name">{entry["entry_name"]}</span>
                <span>{entry["reason"]}</span>
                <span :if={entry["detail"]}>{entry["detail"]}</span>
              </span>
            </li>
          </ul>
        </div>

        <ol :if={@view == :injections} id="prompt-injections" class="prompt-list">
          <li :if={@snapshot.injections == []} class="prompt-empty">
            {dpgettext("chat", "empty state: prompt had no injections", "No injections")}
          </li>
          <li
            :for={{injection, index} <- Enum.with_index(@snapshot.injections)}
            id={"prompt-injection-#{index}"}
            class="prompt-row prompt-row-plain"
          >
            <span class="prompt-row-head">
              <span class="prompt-row-name">{injection["key"]}</span>
              <.badge>
                {injection["position"]}{if injection["depth"],
                  do:
                    " · " <>
                      dpgettext(
                        "chat",
                        "unit: depth an injection was inserted at",
                        "depth %{injection_depth}",
                        injection_depth: Format.number(injection["depth"])
                      )}
              </.badge>
              <span :if={injection["role"]}>{injection["role"]}</span>
              <.badge>{injection["status"]}</.badge>
            </span>
            <div :if={injection["text"]} class="prompt-text" phx-no-format>{injection["text"]}</div>
            <.template_errors
              id={"prompt-injection-error-#{index}"}
              errors={injection["template_errors"]}
            />
          </li>
        </ol>

        <ol :if={@view == :variables} id="prompt-variable-writes" class="prompt-list">
          <li :if={@snapshot.variable_writes == []} class="prompt-empty">
            {dpgettext("chat", "empty state: reply wrote no variables", "No variable writes")}
          </li>
          <li
            :for={{write, index} <- Enum.with_index(@snapshot.variable_writes)}
            id={"prompt-variable-write-#{index}"}
            class="prompt-row prompt-row-plain"
          >
            <span class="prompt-row-head">
              <.badge>{write["scope"]}</.badge>
              <span class="prompt-row-name">{write["key"]}</span>
              <span>=</span>
              <span class="prompt-variable-value">
                {if is_nil(write["value"]),
                  do: dpgettext("chat", "status: a variable that was deleted", "deleted"),
                  else: Jason.encode!(write["value"])}
              </span>
            </span>
          </li>
        </ol>

        <%= if @view in [:request, :response] do %>
          <p :if={is_nil(@json)} id={"prompt-#{@view}"} class="prompt-empty">
            {dpgettext("chat", "empty state: raw request or response not stored", "Not recorded.")}
          </p>
          <pre :if={@json} id={"prompt-#{@view}"} class="prompt-json" phx-no-format>{Jason.encode!(@json, pretty: true)}</pre>
        <% end %>
      </div>
    </.modal>
    """
  end

  # A snapshot row's template errors (absent in older snapshots), ids `<id>-<n>`. Styled by the
  # `lower-bound="none"` block above, which reaches into this nested component.
  attr :id, :string, required: true
  attr :errors, :any, required: true

  defp template_errors(assigns) do
    ~H"""
    <p
      :for={{error, i} <- Enum.with_index(List.wrap(@errors))}
      id={"#{@id}-#{i}"}
      class="prompt-section-error"
    >
      {error}
    </p>
    """
  end

  defp share(_tokens, 0), do: 0
  defp share(tokens, sum), do: Float.round(tokens / sum * 100, 1)

  defp number_or_dash(nil), do: "—"
  defp number_or_dash(n), do: Format.number(n)

  # A token count, "≈"-prefixed when estimated.
  defp approx(true, n), do: "≈" <> Format.number(n)
  defp approx(_estimated, n), do: Format.number(n)

  defp image_caption(i, tokens, true) do
    dpngettext(
      "chat",
      "status: inline prompt image, its estimated tokens, the image is now deleted",
      "Image %{image_number} · ≈%{token_count} token · since deleted",
      "Image %{image_number} · ≈%{token_count} tokens · since deleted",
      tokens,
      image_number: Format.number(i),
      token_count: Format.number(tokens)
    )
  end

  defp image_caption(i, tokens, false) do
    dpngettext(
      "chat",
      "status: inline prompt image and its estimated tokens",
      "Image %{image_number} · ≈%{token_count} token",
      "Image %{image_number} · ≈%{token_count} tokens",
      tokens,
      image_number: Format.number(i),
      token_count: Format.number(tokens)
    )
  end

  # The context bar's segments, in order: each section with tokens (ids keep the section's index, so
  # `prompt-chart-section-N` matches `prompt-section-N`), the template overhead, then with a context
  # limit the reply's reserve.
  defp chart(sections, sum, body, context) do
    section_segments =
      for {%{"tokens" => tokens} = section, i} <- Enum.with_index(sections),
          is_integer(tokens) and tokens > 0 do
        %{
          id: "prompt-chart-section-#{i}",
          kind: :section,
          label: section["block_name"] || section["source"],
          tokens: tokens,
          color: rem(i, 8) + 1
        }
      end

    overhead = (body.prompt_tokens || 0) - sum

    overhead_segments =
      if overhead > 0,
        do: [
          %{
            id: "prompt-chart-overhead",
            kind: :overhead,
            label: dpgettext("chat", "field label: prompt tokens outside the sections", "Template overhead"),
            tokens: overhead,
            color: nil
          }
        ],
        else: []

    section_segments ++ overhead_segments ++ reserve_segments(context)
  end

  defp reserve_segments(%{"reserve" => reserve}) when is_integer(reserve) and reserve > 0,
    do: [
      %{
        id: "prompt-chart-reserve",
        kind: :reserve,
        label: dpgettext("chat", "tooltip: context tokens kept free for the reply", "Reserved for the reply"),
        tokens: reserve,
        color: nil
      }
    ]

  defp reserve_segments(_context), do: []

  defp chart_caption(chart, sum, estimated?, context) do
    case context do
      %{} ->
        filled = chart |> Enum.filter(&(&1.kind in [:section, :overhead])) |> Enum.map(& &1.tokens) |> Enum.sum()

        dngettext(
          "chat",
          "%{filled_tokens} of %{token_limit} token filled · %{reserved_tokens} reserved for the reply",
          "%{filled_tokens} of %{token_limit} tokens filled · %{reserved_tokens} reserved for the reply",
          context["limit"],
          filled_tokens: approx(estimated?, filled),
          token_limit: Format.number(context["limit"]),
          reserved_tokens: Format.number(context["reserve"])
        )

      _ ->
        n = Enum.count(chart, &(&1.kind == :section))

        dngettext(
          "chat",
          "%{token_total} tokens across %{section_count} section",
          "%{token_total} tokens across %{section_count} sections",
          n,
          token_total: approx(estimated?, sum),
          section_count: Format.number(n)
        )
    end
  end

  defp segment_style(%{tokens: t, color: nil}), do: "--tokens: #{t}"
  defp segment_style(%{tokens: t, color: c}), do: "--tokens: #{t}; --chart-color: var(--chart-#{c})"

  defp cached_share(nil, _prompt), do: nil
  defp cached_share(_cached, prompt) when not is_integer(prompt) or prompt <= 0, do: nil
  defp cached_share(cached, prompt), do: min(1, cached / prompt)

  # The context box's `used` as a share of its `limit`, uncapped so an overfull prompt reads over 100%.
  defp context_full(%{"used" => used, "limit" => limit}) when is_integer(used) and is_integer(limit) and limit > 0,
    do: used / limit

  defp context_full(_context), do: nil

  # The provider's `prompt_tokens_details.cached_tokens` (OpenAI's field; llama.cpp sends it too). A
  # streamed reply stores the usage object as `usage`, an unstreamed one the whole response. Nil when
  # the provider does not report it.
  defp cached_tokens(%{"usage" => %{} = usage}) do
    case usage["usage"] || usage do
      %{"prompt_tokens_details" => %{"cached_tokens" => n}} when is_integer(n) -> n
      _ -> nil
    end
  end

  defp cached_tokens(_response), do: nil

  # Activated lore grouped by slot, known slots in injection order, then any slot
  # `Settings.slots/0` does not know (a derived slot string must still show, not vanish).
  # Entries keep their activation order within a slot.
  defp lore_slots(activated) do
    by_slot = Enum.group_by(activated || [], & &1["slot"])
    known = Settings.slots()
    unknown = by_slot |> Map.keys() |> Enum.reject(&(&1 in known)) |> Enum.sort()

    for slot <- known ++ unknown, entries <- [Map.get(by_slot, slot)], entries != nil, do: {slot, entries}
  end
end
