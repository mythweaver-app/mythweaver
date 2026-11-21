defmodule MythweaverWeb.BulkComponents do
  @moduledoc """
  The UI of `MythweaverWeb.Bulk`: the Select toggle, per-row select boxes, and the selection bar
  with its edit and tags modals. `selection_bar/1` is also the toolbar of any other row selection.
  """

  use MythweaverWeb, :html

  alias Mythweaver.Format
  alias MythweaverWeb.Bulk
  alias Phoenix.HTML.Form

  attr :id, :string, required: true
  attr :count, :integer, required: true
  attr :clear, :string, required: true, doc: "the event that clears the selection"
  attr :label, :string, default: nil, doc: "the toolbar's aria label; defaults to \"Selected items\""
  slot :action, required: true, doc: "one bulk action control each, acting on the selection"

  @doc "The toolbar over a row selection: the count, each action, then Clear."
  def selection_bar(assigns) do
    ~H"""
    <style :type={MythweaverWeb.ColocatedScopedCSS}>
      div:scope {
        display: flex;
        flex-wrap: wrap;
        align-items: center;
        gap: var(--size-2);
        padding: var(--size-1) var(--size-2);
        border: 1px solid var(--border-grey);
        border-radius: var(--radius-2);
        background: var(--surface-3);
      }

      .selection-bar-count {
        font-weight: 600;
        font-variant-numeric: tabular-nums;
      }

      .selection-bar-actions {
        display: flex;
        flex-wrap: wrap;
        gap: var(--size-1);
        margin-inline-end: auto;
      }
    </style>
    <div
      id={@id}
      class="selection-bar"
      role="toolbar"
      aria-label={
        @label || pgettext("aria label: toolbar acting on the selected rows", "Selected items")
      }
    >
      <span class="selection-bar-count">
        {pngettext(
          "status: how many rows are selected",
          "%{selected_count} selected",
          "%{selected_count} selected",
          @count,
          selected_count: Format.number(@count)
        )}
      </span>
      <span class="selection-bar-actions">
        {render_slot(@action)}
      </span>
      <.button size="sm" id={"#{@id}-clear"} phx-click={@clear}>
        <.lucide name="x" /> {pgettext("button: clear the row selection", "Clear")}
      </.button>
    </div>
    """
  end

  attr :bulk, Bulk, required: true
  attr :id, :string, required: true
  attr :notext, :boolean, default: false

  @doc "Turns select mode on and off."
  def bulk_toggle(assigns) do
    Iconex.hint(:lucide, ~w[list-checks check])

    {label, title} =
      if assigns.bulk.active? do
        {pgettext("button: leave bulk select mode", "Done"),
         pgettext("tooltip: button that leaves bulk select mode", "Done with Bulk Select")}
      else
        {pgettext("button: enter bulk select mode", "Select"),
         pgettext("tooltip: button that enters bulk select mode", "Bulk Select")}
      end

    assigns = assigns |> assign(%{label: label, title: title})

    ~H"""
    <.button
      size="sm"
      id={@id}
      phx-click="bulk_mode"
      title={@title}
      aria-pressed={to_string(@bulk.active?)}
    >
      <.lucide name={if @bulk.active?, do: "check", else: "list-checks"} />
      {if !@notext, do: @label}
    </.button>
    """
  end

  attr :bulk, Bulk, required: true
  attr :list, :string, required: true
  attr :id, :any, required: true
  attr :class, :any, default: nil, doc: "layout hook for the caller"

  attr :dom_id, :string,
    default: nil,
    doc: "the box's DOM id when the row shows more than once; defaults to `bulk-<list>-<id>`"

  slot :inner_block, required: true

  @doc "A row in select mode: its select box, then the row label."
  def bulk_check(assigns) do
    ~H"""
    <style :type={MythweaverWeb.ColocatedCSS}>
      label.bulk-check {
        display: flex;
        align-items: center;
        gap: var(--size-2);
        cursor: pointer;
      }
    </style>
    <label class={["bulk-check", @class]}>
      <input
        type="checkbox"
        id={@dom_id || "bulk-#{@list}-#{@id}"}
        data-range-id={"#{@list}:#{@id}"}
        phx-click="bulk_toggle"
        phx-value-list={@list}
        phx-value-id={@id}
        checked={Bulk.selected?(@bulk, @list, @id)}
      />
      {render_slot(@inner_block)}
    </label>
    """
  end

  attr :bulk, Bulk, required: true
  attr :id, :string, required: true

  @doc "The selection bar of select mode, with the edit modal: the whole bulk UI but the boxes."
  def bulk_bar(assigns) do
    assigns =
      assign(assigns,
        count: Bulk.count(assigns.bulk),
        editable: Enum.filter(Bulk.specs(assigns.bulk), &(&1.fields != [] and is_function(&1.update))),
        taggable: Enum.filter(Bulk.specs(assigns.bulk), & &1.tag_kind)
      )

    ~H"""
    <.selection_bar
      :if={@bulk.active?}
      id={@id}
      count={@count}
      clear="bulk_clear"
      label={pgettext("aria label: bulk selection toolbar", "Bulk selection")}
    >
      <:action>
        <.button size="sm" id={"#{@id}-all"} phx-click="bulk_all">
          <.lucide name="list-checks" /> {pgettext(
            "button: select every row in bulk mode",
            "Select all"
          )}
        </.button>
      </:action>
      <:action :for={spec <- @editable}>
        <.button
          size="sm"
          id={"#{@id}-edit-#{spec.name}"}
          phx-click="bulk_edit"
          phx-value-list={spec.name}
          disabled={Bulk.selected_ids(@bulk, Atom.to_string(spec.name)) == []}
        >
          <.lucide name="pencil" />
          {if length(Bulk.specs(@bulk)) == 1,
            do: pgettext("button: bulk-edit the selected rows", "Edit…"),
            else: spec.edit_label || pgettext("button: bulk-edit the selected rows", "Edit…")}
        </.button>
      </:action>
      <:action :for={spec <- @taggable}>
        <.button
          size="sm"
          id={"#{@id}-tags-#{spec.name}"}
          phx-click="bulk_tags"
          phx-value-list={spec.name}
          disabled={Bulk.selected_ids(@bulk, Atom.to_string(spec.name)) == []}
        >
          <.lucide name="tags" />
          {if length(Bulk.specs(@bulk)) == 1,
            do: pgettext("button: bulk-change tags of the selected rows", "Tags…"),
            else: spec.tag_label || pgettext("button: bulk-change tags of the selected rows", "Tags…")}
        </.button>
      </:action>
      <:action>
        <.button
          size="sm"
          danger
          id={"#{@id}-delete"}
          phx-click="bulk_delete"
          data-confirm={delete_confirm(@count)}
          disabled={@count == 0}
        >
          <.lucide name="trash" /> {pgettext("button: delete the selected rows", "Delete")}
        </.button>
      </:action>
    </.selection_bar>
    <.bulk_edit_modal :if={@bulk.edit} bulk={@bulk} />
    <.bulk_tags_modal :if={@bulk.tags} bulk={@bulk} />
    """
  end

  attr :bulk, Bulk, required: true

  defp bulk_tags_modal(assigns) do
    %{tags: tags, specs: specs} = assigns.bulk
    n = length(Bulk.selected_ids(assigns.bulk, tags.list))
    spec = specs[tags.list]

    assigns =
      assign(assigns,
        tags: tags,
        n: n,
        title: tag_title(spec.count_label.(n))
      )

    ~H"""
    <style :type={MythweaverWeb.ColocatedScopedCSS} lower-bound="none">
      div.bulk-tags-body:scope {
        display: flex;
        flex-direction: column;
        gap: var(--size-3);
      }

      .bulk-tags-error {
        margin: 0;
        color: var(--destructive);
      }
    </style>
    <.modal id="bulk-tags-modal" title={@title} on_cancel="bulk_tags_close">
      <.form
        for={@tags.form}
        id="bulk-tags-form"
        phx-change="bulk_tags_validate"
        phx-submit="bulk_tags_save"
        phx-hook="UnsavedChanges"
        data-saved={is_nil(@tags.form.action)}
      >
        <div class="bulk-tags-body">
          <.input
            :if={@tags.site?}
            type="select"
            field={@tags.form[:domain]}
            id="bulk-tags-form-domain"
            label={pgettext("field label: which tag set a bulk tag change uses", "Which tags")}
            options={[
              {pgettext("option: the user's own tags", "My tags"), "mine"},
              {pgettext("option: the site-wide tags", "Site tags"), "site"}
            ]}
          >
            <:hint>
              {gettext("Site tags go on site rows only; everyone sees them. My tags only you see.")}
            </:hint>
          </.input>
          <.tag_input
            id="bulk-tags-form-add"
            name="tags[add][]"
            label={pgettext("field label: tags a bulk change adds", "Add tags")}
            values={@tags.add}
            vocabulary={@tags.vocabulary}
            invalid={@tags.invalid}
            errors={@tags.add_errors}
          />
          <.tag_input
            id="bulk-tags-form-remove"
            name="tags[remove][]"
            label={pgettext("field label: tags a bulk change removes", "Remove tags")}
            values={@tags.remove}
            vocabulary={@tags.vocabulary}
            invalid={@tags.invalid}
            errors={@tags.remove_errors}
          >
            <:hint>{gettext("Removes exactly these tags; an item's other tags stay.")}</:hint>
          </.tag_input>
          <p :if={@tags.error} id="bulk-tags-error" class="bulk-tags-error">{@tags.error}</p>
          <.form_actions>
            <.button type="button" phx-click={JS.dispatch("modal:close", to: "#bulk-tags-modal")}>
              {pgettext("button: close the form without saving", "Cancel")}
            </.button>
            <.button type="submit" variant="primary" id="bulk-tags-submit">{apply_label(@n)}</.button>
          </.form_actions>
        </div>
      </.form>
    </.modal>
    """
  end

  attr :bulk, Bulk, required: true

  defp bulk_edit_modal(assigns) do
    %{edit: edit, specs: specs} = assigns.bulk
    spec = specs[edit.list]
    n = length(Bulk.selected_ids(assigns.bulk, edit.list))

    assigns =
      assign(assigns,
        edit: edit,
        form: edit.form,
        fields: spec.fields,
        n: n,
        title: edit_title(spec.count_label.(n))
      )

    ~H"""
    <style :type={MythweaverWeb.ColocatedScopedCSS} lower-bound="none">
      div.bulk-edit-body:scope {
        display: flex;
        flex-direction: column;
        gap: var(--size-3);
      }

      .bulk-edit-field {
        display: flex;
        flex-direction: column;
        gap: var(--size-2);
      }

      .bulk-edit-field:has(input[id^="bulk-edit-form-apply-"]:not(:checked))
        > :last-child {
        opacity: 0.55;
      }

      .bulk-edit-error {
        margin: 0;
        color: var(--destructive);
      }
    </style>
    <.modal id="bulk-edit-modal" title={@title} on_cancel="bulk_edit_close">
      <.form
        for={@form}
        id="bulk-edit-form"
        phx-change="bulk_edit_validate"
        phx-submit="bulk_edit_save"
        phx-hook="UnsavedChanges"
        data-saved={is_nil(@form.action)}
      >
        <div class="bulk-edit-body">
          <div :for={field <- @fields} class="bulk-edit-field" id={"bulk-edit-field-#{field.key}"}>
            <.input
              type="checkbox"
              field={@form[:"apply_#{field.key}"]}
              id={"bulk-edit-form-apply-#{field.key}"}
              label={
                pgettext(
                  "field label: checkbox that includes this field in a bulk edit",
                  "Change %{field_label}",
                  field_label: field.label
                )
              }
            />
            <.field_input field={field} form={@form} options={@edit.options[field.key]} />
          </div>
          <p :if={@edit.error} id="bulk-edit-error" class="bulk-edit-error">{@edit.error}</p>
          <.form_actions>
            <.button type="button" phx-click={JS.dispatch("modal:close", to: "#bulk-edit-modal")}>
              {pgettext("button: close the form without saving", "Cancel")}
            </.button>
            <.button type="submit" variant="primary" id="bulk-edit-submit">{apply_label(@n)}</.button>
          </.form_actions>
        </div>
      </.form>
    </.modal>
    """
  end

  attr :field, Bulk.Field, required: true
  attr :form, Form, required: true
  attr :options, :list, default: []

  defp field_input(%{field: %{type: :select}} = assigns) do
    ~H"""
    <.input
      type="select"
      field={@form[@field.key]}
      id={"bulk-edit-form-#{@field.key}"}
      label={@field.label}
      options={@options}
      prompt={@field.prompt}
    />
    """
  end

  defp field_input(%{field: %{type: :number}} = assigns) do
    ~H"""
    <.input
      type="number"
      field={@form[@field.key]}
      id={"bulk-edit-form-#{@field.key}"}
      label={@field.label}
      min={@field.min}
      max={@field.max}
      step={@field.step}
    />
    """
  end

  defp field_input(%{field: %{type: :text}} = assigns) do
    ~H"""
    <.input
      type="text"
      field={@form[@field.key]}
      id={"bulk-edit-form-#{@field.key}"}
      label={@field.label}
    />
    """
  end

  # The sentinel `""` the chip input posts is not a chip.
  defp field_input(%{field: %{type: :tags}} = assigns) do
    assigns = assign(assigns, :values, assigns.form[assigns.field.key].value |> List.wrap() |> Enum.reject(&(&1 == "")))

    ~H"""
    <.tag_input
      id={"bulk-edit-form-#{@field.key}"}
      name={"bulk[#{@field.key}][]"}
      label={@field.label}
      max={@field.max}
      values={@values}
      vocabulary={@options}
    />
    """
  end

  defp field_input(assigns) do
    ~H"""
    <.input
      type="checkbox"
      field={@form[@field.key]}
      id={"bulk-edit-form-#{@field.key}"}
      label={@field.label}
    />
    """
  end

  defp delete_confirm(n) do
    gettext_comment("Confirm dialog before deleting every selected row in bulk select mode.")

    ngettext(
      "Delete %{selected_count} selected? This can't be undone.",
      "Delete %{selected_count} selected? This can't be undone.",
      n,
      selected_count: Format.number(n)
    )
  end

  defp tag_title(item_totals) do
    gettext_comment("The placeholder is a counted noun phrase such as \"3 characters\".")
    pgettext("heading: bulk tag dialog", "Tag %{item_totals}", item_totals: item_totals)
  end

  defp edit_title(item_totals) do
    gettext_comment("The placeholder is a counted noun phrase such as \"3 characters\".")
    pgettext("heading: bulk edit dialog", "Edit %{item_totals}", item_totals: item_totals)
  end

  defp apply_label(n) do
    pngettext(
      "button: apply a bulk change to the selected rows",
      "Apply to %{item_count}",
      "Apply to %{item_count}",
      n,
      item_count: Format.number(n)
    )
  end
end
