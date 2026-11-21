defmodule MythweaverWeb.PermissionGrid do
  @moduledoc """
  The permission form shared by `MythweaverWeb.GroupLive` and `MythweaverWeb.UserLive`: one section
  per `Mythweaver.Permissions.Catalog` category, a Deny / Unset / Allow radio group per flag (the
  stored value checked, Unset when there is none) and a select plus number per limit (Unset /
  Unlimited / Set; `:bytes` limits in MiB, `:cents` limits in dollars). A flag the viewer does not hold is a disabled fieldset,
  so the browser leaves it out of the submit and its row is kept.

  A search field above the form filters the rows in the browser (the `.PermissionSearch` hook): a
  row stays when every word typed appears in its category, label, description or key, and a
  section with no row left hides. It sits outside the form, so it is never submitted, and
  filtering only hides rows, so unsaved choices in hidden rows still save. Its id is
  `<form id>-search`; the no-match notice is `<form id>-search-empty`.

  Fields post as `grants[<key>]` and `limits[<key>]`; `to_grants/1` turns that into the map
  `Mythweaver.Permissions.set_group_grants/3` takes. Ids are `<form id>-grant-<key, dots as
  dashes>`: a flag's fieldset (its radios add `-deny`, `-unset`, `-allow`) or a limit's select (its
  number adds `-limit`).
  """
  use MythweaverWeb, :html

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Permissions
  alias Mythweaver.Permissions.Catalog

  @mib 1_048_576

  attr :id, :string, required: true, doc: "the form id"
  attr :event, :string, required: true, doc: "the submit event"
  attr :grants, :map, required: true, doc: "the holder's rows, `Permissions.grants_for/1`"
  attr :scope, Scope, required: true, doc: "the viewer, for `Permissions.may_set?/3`"
  attr :disabled, :boolean, default: false, doc: "the viewer may not change this holder at all"

  def grid(assigns) do
    ~H"""
    <%!-- Rows follow `SettingsLive`'s `setting_row`: title over a muted description on the left,
         controls on the right, a rule between rows, a roomy gap between categories. --%>
    <style :type={MythweaverWeb.ColocatedScopedCSS}>
      /* `<.form>` carries no marker from this block; its slot's one root div does, and is a scope
         root, so it is reached as `div:scope`. Everything else is inside it. */
      div.permission-grid:scope {
        display: flex;
        flex-direction: column;
        gap: var(--size-5);
      }

      .permission-grid-section {
        display: flex;
        flex-direction: column;
        gap: var(--size-1);
      }

      .permission-grid-row {
        display: grid;
        grid-template-columns: minmax(0, 1fr) auto;
        gap: var(--size-1) var(--size-4);
        align-items: center;
        padding: var(--size-2) 0;
        border-block-end: 1px solid var(--border-grey);
      }

      .permission-grid-label {
        display: flex;
        flex-direction: column;
        gap: var(--size-1);
        min-inline-size: 0;
      }

      .permission-grid-title {
        font-weight: 600;
      }

      .permission-grid-description,
      .permission-grid-hint {
        margin: 0;
        font-size: 0.9rem;
        color: var(--muted-foreground);
      }

      .permission-grid-controls {
        display: flex;
        align-items: center;
        gap: var(--size-2);
      }

      .permission-grid-mode {
        inline-size: 9rem;
      }

      .permission-grid-number {
        inline-size: 8rem;
      }

      /* Deny / Unset / Allow as one segmented control, so a column of rows reads at a glance: red
         denies, filled allows, neutral is unset. */
      .permission-grid-effect {
        display: inline-flex;
        margin: 0;
        padding: 0;
        border: 1px solid var(--border);
        border-radius: var(--radius-2);
        overflow: hidden;
        background: var(--surface-1);
      }

      .permission-grid-effect label {
        display: inline-flex;
        align-items: center;
        position: relative;
        padding: var(--size-1) var(--size-3);
        font-size: 0.9rem;
        cursor: pointer;
        user-select: none;

        & + label {
          border-inline-start: 1px solid var(--border);
        }

        &:has(input:focus-visible) {
          outline: 2px solid var(--ring);
          outline-offset: -2px;
        }

        &:has(input:disabled) {
          cursor: not-allowed;
          opacity: 0.6;
        }

        &:has(input[value="deny"]:checked) {
          background: var(--destructive);
          color: var(--destructive-foreground);
        }

        &:has(input[value=""]:checked) {
          background: var(--surface-6);
        }

        &:has(input[value="allow"]:checked) {
          background: var(--primary);
          color: var(--primary-foreground);
        }
      }

      /* The radio itself is the label's hit area; only the segment shows. */
      .permission-grid-effect input {
        position: absolute;
        opacity: 0;
        pointer-events: none;
      }

      .permission-grid-row[hidden],
      .permission-grid-section[hidden] {
        display: none;
      }

      div.permission-grid-search:scope {
        margin-block-end: var(--size-3);
      }

      .permission-grid-empty {
        margin: 0;
        color: var(--muted-foreground);
      }

      .permission-grid-actions {
        display: flex;
        justify-content: flex-end;
      }

      @media (--phone) {
        .permission-grid-row {
          grid-template-columns: minmax(0, 1fr);
        }
        .permission-grid-controls {
          flex-wrap: wrap;
        }
      }
    </style>
    <%!-- `phx-update="ignore"`: a re-render (switching holders, saving) keeps the typed filter, which
         the rows' `ignore_attributes` keep applied. --%>
    <div
      id={"#{@id}-search"}
      class="permission-grid-search"
      phx-hook=".PermissionSearch"
      phx-update="ignore"
      data-target={@id}
    >
      <.input
        type="search"
        name="permission_search"
        id={"#{@id}-search-input"}
        value=""
        placeholder={
          dpgettext(
            "admin",
            "placeholder: search field over the permission list",
            "Search permissions…"
          )
        }
        aria-label={
          dpgettext(
            "admin",
            "aria label: search field over the permission list",
            "Search permissions"
          )
        }
        autocomplete="off"
      />
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".PermissionSearch">
      // Hides grid rows that do not contain every typed word (rows carry their text, lowercased, in
      // `data-search`), then sections left empty, and shows the no-match notice when nothing is left.
      export default {
        mounted() {
          this.input = this.el.querySelector("input");
          this.input.addEventListener("input", () => this.filter());
          this.input.addEventListener("keydown", (e) => {
            if (e.key === "Escape" && this.input.value !== "") {
              e.preventDefault();
              this.input.value = "";
              this.filter();
            }
          });
        },

        filter() {
          const grid = document.getElementById(this.el.dataset.target);
          if (!grid) return;
          const words = this.input.value.toLowerCase().split(/\s+/).filter(Boolean);
          let shown = 0;

          for (const section of grid.querySelectorAll(".permission-grid-section")) {
            let visible = 0;

            for (const row of section.querySelectorAll(".permission-grid-row")) {
              const match = words.every((w) => row.dataset.search.includes(w));
              row.hidden = !match;
              if (match) visible++;
            }

            section.hidden = visible === 0;
            shown += visible;
          }

          const empty = document.getElementById(`${this.el.id}-empty`);
          if (empty) empty.hidden = shown > 0;
        },
      };
    </script>
    <.form for={%{}} as={:grants} id={@id} phx-submit={@event}>
      <div class="permission-grid">
        <p
          id={"#{@id}-search-empty"}
          class="permission-grid-empty"
          hidden
          phx-mounted={JS.ignore_attributes(["hidden"])}
        >
          {dpgettext(
            "admin",
            "empty state: no permission matches the search",
            "No permissions match."
          )}
        </p>
        <section
          :for={{category_id, category, entries} <- Catalog.categories()}
          id={"#{@id}-#{category_id}"}
          class="permission-grid-section"
          phx-mounted={JS.ignore_attributes(["hidden"])}
        >
          <.section_header>{category}</.section_header>
          <div
            :for={entry <- entries}
            class="permission-grid-row"
            data-key={entry.key}
            data-search={search_text(category, entry)}
            phx-mounted={JS.ignore_attributes(["hidden"])}
          >
            <div class="permission-grid-label">
              <span
                :if={entry.kind == :flag}
                class="permission-grid-title"
                id={field_id(@id, entry.key) <> "-label"}
              >
                {entry.label}
              </span>
              <label
                :if={entry.kind == :limit}
                class="permission-grid-title"
                for={field_id(@id, entry.key)}
              >
                {entry.label}
              </label>
              <p class="permission-grid-description">{entry.description}</p>
              <p :if={not settable?(@scope, entry)} class="permission-grid-hint">
                <.lucide name="lock" /> {dgettext("admin", "You don't hold this permission.")}
              </p>
            </div>
            <%= if entry.kind == :flag do %>
              <fieldset
                class="permission-grid-effect"
                id={field_id(@id, entry.key)}
                aria-labelledby={field_id(@id, entry.key) <> "-label"}
                disabled={@disabled or not settable?(@scope, entry)}
              >
                <label :for={{text, value} <- effect_options()}>
                  <input
                    type="radio"
                    name={"grants[#{entry.key}]"}
                    id={"#{field_id(@id, entry.key)}-#{if value == "", do: "unset", else: value}"}
                    value={value}
                    checked={flag_value(@grants[entry.key]) == value}
                  />
                  {text}
                </label>
              </fieldset>
            <% else %>
              <div class="permission-grid-controls">
                <div class="permission-grid-mode">
                  <.input
                    type="select"
                    name={"grants[#{entry.key}]"}
                    id={field_id(@id, entry.key)}
                    value={limit_mode(@grants[entry.key])}
                    options={limit_mode_options()}
                    disabled={@disabled}
                  />
                </div>
                <div class="permission-grid-number">
                  <.input
                    type="number"
                    name={"limits[#{entry.key}]"}
                    id={field_id(@id, entry.key) <> "-limit"}
                    value={limit_number(@grants[entry.key], entry.unit)}
                    min="0"
                    step={if entry.unit == :cents, do: "0.01", else: "1"}
                    placeholder={placeholder(entry.unit)}
                    disabled={@disabled}
                  />
                </div>
              </div>
            <% end %>
          </div>
        </section>
        <div class="permission-grid-actions">
          <.button type="submit" variant="primary" id={"#{@id}-save"} disabled={@disabled}>
            {dpgettext("admin", "button: save the permission list", "Save permissions")}
          </.button>
        </div>
      </div>
    </.form>
    """
  end

  @doc """
  The `Permissions.set_*_grants/3` map from the grid's params: flags pass through; a limit's
  `"set"` becomes its number (MiB → bytes for `:bytes`, dollars → cents for `:cents`; a blank or bad
  number stays invalid).
  """
  @spec to_grants(map()) :: %{String.t() => String.t()}
  def to_grants(params) do
    limits = Map.get(params, "limits", %{})

    params
    |> Map.get("grants", %{})
    |> Map.new(fn {key, value} ->
      case {Catalog.get(key), value} do
        {%{kind: :limit, unit: unit}, "set"} -> {key, limit_param(Map.get(limits, key, ""), unit)}
        _ -> {key, value}
      end
    end)
  end

  defp limit_param(raw, :bytes) do
    case Integer.parse(String.trim(raw)) do
      {mib, ""} -> Integer.to_string(mib * @mib)
      _ -> "invalid"
    end
  end

  defp limit_param(raw, :cents) do
    with {dollars, ""} <- Decimal.parse(String.trim(raw)),
         false <- Decimal.inf?(dollars) or Decimal.nan?(dollars) or Decimal.negative?(dollars) do
      dollars |> Decimal.mult(100) |> Decimal.round(0) |> Decimal.to_integer() |> Integer.to_string()
    else
      _ -> "invalid"
    end
  end

  defp limit_param(raw, _unit), do: if(String.trim(raw) == "", do: "invalid", else: raw)

  @doc "An error from the permission functions as flash text."
  @spec error_text(term()) :: String.t()
  def error_text({:not_held, key}) do
    gettext_comment("Flash when saving permissions that include one the viewer lacks; the placeholder is its name.")

    dgettext("admin", "You can't change \"%{permission_name}\": you don't hold that permission.",
      permission_name: Catalog.fetch!(key).label
    )
  end

  def error_text({:invalid, key}) do
    case Catalog.fetch!(key) do
      %{unit: :cents, label: label} ->
        gettext_comment("Flash when a spending limit is not a valid amount; the placeholder is the limit's name.")
        dgettext("admin", "\"%{permission_name}\" needs a dollar amount of 0 or more.", permission_name: label)

      %{label: label} ->
        gettext_comment("Flash when a count or size limit is not a valid number; the placeholder is the limit's name.")
        dgettext("admin", "\"%{permission_name}\" needs a whole number of 0 or more.", permission_name: label)
    end
  end

  def error_text(:system_group) do
    gettext_comment("Flash when a change a system group does not allow is attempted.")
    dgettext("admin", "System groups can't be changed that way.")
  end

  def error_text(:unauthorized) do
    gettext_comment("Flash when the viewer may not make a permission change.")
    dgettext("admin", "You are not allowed to do that.")
  end

  defp effect_options do
    [
      {dpgettext("admin", "option: a permission's effect", "Deny"), "deny"},
      {dpgettext("admin", "option: a permission's effect", "Unset"), ""},
      {dpgettext("admin", "option: a permission's effect", "Allow"), "allow"}
    ]
  end

  defp limit_mode_options do
    [
      {dpgettext("admin", "option: how a permission limit is set", "Unset"), ""},
      {dpgettext("admin", "option: how a permission limit is set", "Unlimited"), "unlimited"},
      {dpgettext("admin", "option: how a permission limit is set", "Set"), "set"}
    ]
  end

  defp settable?(scope, %{kind: :flag, key: key}), do: Permissions.may_set?(scope, key, :allow)
  defp settable?(_scope, %{kind: :limit}), do: true

  defp field_id(form_id, key), do: "#{form_id}-grant-#{String.replace(key, ".", "-")}"

  defp search_text(category, entry),
    do: String.downcase(Enum.join([category, entry.label, entry.description, entry.key], " "))

  defp flag_value(nil), do: ""
  defp flag_value(grant), do: Atom.to_string(grant.effect)

  defp limit_mode(nil), do: ""
  defp limit_mode(%{limit_value: nil}), do: "unlimited"
  defp limit_mode(_grant), do: "set"

  defp placeholder(:bytes), do: dpgettext("admin", "unit: upload storage limit, in mebibytes", "MiB")
  defp placeholder(:cents), do: dpgettext("admin", "unit: spending limit, in US dollars", "USD")
  defp placeholder(_unit), do: nil

  defp limit_number(%{limit_value: n}, :bytes) when is_integer(n), do: div(n, @mib)

  defp limit_number(%{limit_value: n}, :cents) when is_integer(n),
    do: n |> Decimal.new() |> Decimal.div(100) |> Decimal.round(2) |> Decimal.to_string(:normal)

  defp limit_number(%{limit_value: n}, _unit) when is_integer(n), do: n
  defp limit_number(_grant, _unit), do: nil
end
