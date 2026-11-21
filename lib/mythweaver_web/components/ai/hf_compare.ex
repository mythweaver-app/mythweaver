defmodule MythweaverWeb.AI.HFCompare do
  @moduledoc """
  The compare-and-apply modal behind the model form's "Fill from Hugging Face".

  One row per setting Hugging Face supplies: the form's value on the left, Hugging Face's on the
  right, and a toggle between them. The left cell shows what the form will hold after "Apply to
  form", so an applied row reads the Hugging Face value with the old one noted underneath. Rows
  are server-held state (`Mythweaver.AI.HuggingFace.row/0`); every button pushes an event, nothing
  here writes the form.
  """

  use MythweaverWeb, :html

  alias Mythweaver.AI.HuggingFace

  attr :compare, :map, required: true

  def hf_compare(assigns) do
    Iconex.hint(:lucide, ~w[arrow-left undo-2])

    compare = assigns.compare

    assigns =
      assign(assigns,
        rows: Enum.filter(compare.rows, &(compare.show_unchanged? or HuggingFace.changed?(&1)))
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

      .hf-compare-source {
        margin: 0;
        color: var(--muted-foreground);
      }

      .hf-compare-source a {
        color: var(--foreground);
      }

      .hf-compare-toolbar {
        display: flex;
        flex-wrap: wrap;
        align-items: center;
        gap: var(--size-2);
      }

      .hf-compare-toolbar-label {
        color: var(--muted-foreground);
        font-size: 0.85rem;
      }

      .hf-compare-unchanged {
        margin-inline-start: auto;
      }

      .hf-compare-columns,
      .hf-row-grid {
        display: grid;
        grid-template-columns: 1fr auto 1fr;
        align-items: center;
        gap: var(--size-2);
      }

      .hf-compare-columns {
        font-size: 0.8rem;
        font-weight: 600;
        color: var(--muted-foreground);
      }

      /* Holds the middle column open to the toggle's width so headers line up with cells. */
      .hf-compare-columns-gap {
        inline-size: 2rem;
      }

      .hf-compare-rows {
        list-style: none;
        margin: 0;
        padding: 0;
        display: flex;
        flex-direction: column;
        gap: var(--size-3);
      }

      .hf-row {
        display: flex;
        flex-direction: column;
        gap: var(--size-1);
      }

      .hf-row-label {
        font-size: 0.75rem;
        text-transform: uppercase;
        letter-spacing: 0.04em;
        color: var(--muted-foreground);
      }

      .hf-row-current,
      .hf-row-hf {
        display: flex;
        flex-direction: column;
        gap: var(--size-1);
        min-inline-size: 0;
        border: 1px solid var(--border-grey);
        border-radius: var(--radius-2);
        padding: var(--size-2);
        background: var(--surface-2);
        overflow-wrap: anywhere;
      }

      .hf-row--applied .hf-row-current {
        border-color: var(--primary-accent);
      }

      .hf-row-hf {
        color: var(--muted-foreground);
      }

      .hf-row-was {
        color: var(--muted-foreground);
      }

      .hf-compare-empty {
        margin: 0;
        color: var(--muted-foreground);
      }

      .hf-compare-footer {
        display: flex;
        justify-content: flex-end;
        gap: var(--size-2);
      }

      /* Phones: one column per row; each value labels itself instead of the column headers. */
      @media (--phone) {
        .hf-compare-columns {
          display: none;
        }
        .hf-row-grid {
          grid-template-columns: minmax(0, 1fr) auto;
        }
        .hf-row-hf {
          grid-column: 1 / -1;
        }
        .hf-row-current::before,
        .hf-row-hf::before {
          content: attr(data-phone-label);
          color: var(--muted-foreground);
        }
      }
    </style>

    <.modal
      id="hf-compare-modal"
      title={
        dpgettext(
          "ai",
          "heading: dialog comparing model form values with Hugging Face's",
          "Compare with Hugging Face"
        )
      }
      on_cancel="close_hf_compare"
      class="modal--wide"
    >
      <div class="hf-compare">
        <p id="hf-compare-source" class="hf-compare-source">
          {dgettext("ai", "Review differences and apply only what you want.")}
          {dpgettext(
            "ai",
            "field label: Hugging Face repository the compared values come from",
            "Hugging Face:"
          )}
          <a
            href={"https://huggingface.co/#{@compare.tokenizer}"}
            target="_blank"
            rel="noopener"
          >
            {@compare.tokenizer}
          </a>
          <span :if={@compare.tokenizer != @compare.source}>
            {dpgettext(
              "ai",
              "status: the tokenizer comes from this base model repository",
              "(base model of %{model_repo})",
              model_repo: @compare.source
            )}
          </span>
        </p>

        <div class="hf-compare-toolbar">
          <span class="hf-compare-toolbar-label">
            {dpgettext(
              "ai",
              "heading: buttons choosing Hugging Face fields to apply",
              "Select fields to apply"
            )}
          </span>
          <.button id="hf-copy-missing" phx-click="hf_copy_missing">
            <.lucide name="copy" />
            {dpgettext("ai", "button: use Hugging Face values for empty model fields", "Copy missing")}
          </.button>
          <.button id="hf-copy-all" phx-click="hf_copy_all">
            <.lucide name="copy-check" />
            {dpgettext("ai", "button: use every Hugging Face value in the model form", "Copy all")}
          </.button>
          <.button
            id="hf-toggle-unchanged"
            class="hf-compare-unchanged"
            phx-click="hf_toggle_unchanged"
            aria-pressed={to_string(@compare.show_unchanged?)}
          >
            <.lucide name="eye" />
            {dpgettext(
              "ai",
              "toggle: also list Hugging Face fields equal to the form's",
              "Show unchanged"
            )}
          </.button>
        </div>

        <div :if={@rows != []} class="hf-compare-columns">
          <span>{dpgettext("ai", "column header: the model form's current values", "Current")}</span>
          <span class="hf-compare-columns-gap"></span>
          <span>{dpgettext("ai", "column header: values Hugging Face supplies", "Hugging Face")}</span>
        </div>

        <ol :if={@rows != []} id="hf-compare-rows" class="hf-compare-rows">
          <li
            :for={row <- @rows}
            id={"hf-row-#{dom_key(row)}"}
            class={["hf-row", row.apply? && "hf-row--applied"]}
          >
            <span class="hf-row-label">{row.label}</span>
            <div class="hf-row-grid">
              <div
                class="hf-row-current"
                data-phone-label={
                  dpgettext(
                    "ai",
                    "field label: the model form's current value, on phones",
                    "Current: "
                  )
                }
              >
                <span>{HuggingFace.display(if row.apply?, do: row.hf, else: row.current)}</span>
                <small :if={row.apply? and HuggingFace.changed?(row)} class="hf-row-was">
                  {dpgettext(
                    "ai",
                    "status: an AI model setting's value before applying Hugging Face data",
                    "Was %{previous_value}",
                    previous_value: HuggingFace.display(row.current)
                  )}
                </small>
              </div>
              <.button
                icon
                size="sm"
                id={"hf-row-toggle-#{dom_key(row)}"}
                phx-click="hf_toggle_row"
                phx-value-key={row.key}
                disabled={not HuggingFace.changed?(row)}
                aria-label={
                  if row.apply?,
                    do:
                      dpgettext(
                        "ai",
                        "aria label: undo using the Hugging Face value for this field",
                        "Keep current value"
                      ),
                    else:
                      dpgettext(
                        "ai",
                        "aria label: use the Hugging Face value for this field",
                        "Use Hugging Face value"
                      )
                }
              >
                <.lucide name={if row.apply?, do: "undo-2", else: "arrow-left"} />
              </.button>
              <div
                class="hf-row-hf"
                data-phone-label={
                  dpgettext(
                    "ai",
                    "field label: the value Hugging Face supplies, on phones",
                    "Hugging Face: "
                  )
                }
              >
                {HuggingFace.display(row.hf)}
              </div>
            </div>
          </li>
        </ol>

        <p :if={@rows == []} id="hf-compare-empty" class="hf-compare-empty">
          {dgettext("ai", "Everything Hugging Face knows already matches this form.")}
        </p>

        <div class="hf-compare-footer">
          <.button id="hf-compare-cancel" phx-click="close_hf_compare">
            {dpgettext("ai", "button: close the Hugging Face comparison without applying", "Cancel")}
          </.button>
          <.button variant="primary" id="hf-compare-apply" phx-click="hf_apply">
            {dpgettext(
              "ai",
              "button: apply the chosen Hugging Face values to the model form",
              "Apply to form"
            )}
          </.button>
        </div>
      </div>
    </.modal>
    """
  end

  defp dom_key(row), do: String.replace(row.key, ".", "-")
end
