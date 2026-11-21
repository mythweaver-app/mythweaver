defmodule MythweaverWeb.Bulk do
  @moduledoc """
  Bulk select, edit and delete over one or more lists of a LiveView.

  A screen opts in by `attach/2`ing `MythweaverWeb.Bulk.Spec`s in `mount/3` and rendering
  `MythweaverWeb.BulkComponents`' `bulk_toggle`, `bulk_bar` and `bulk_check` (or passing `bulk` to
  `MythweaverWeb.Pane.pane_items/1`). The attached `handle_event` hook owns every `bulk_*` event and
  halts it; anything else continues to the LiveView.

  State lives in the `:bulk` assign. `specs` and `selected` are keyed by the spec name as a string,
  so event params are never turned into atoms. Rows are processed one at a time through the
  spec's context functions, with no transaction: every per-row rule runs, and partial success is
  reported rather than rolled back. A selection survives search filtering, so the count and the
  actions include hidden rows.

  A spec with a `tag_kind` also gets a Tags action: a modal that adds and removes tags on every
  selected row (`Mythweaver.Tags.edit_item_tags/5`), the viewer's own tags or, for a content
  manager, the site's (applied to site rows only; any other row is reported as refused). After it,
  a screen's `tag_vocabulary` assign (`MythweaverWeb.TagFilter`), when present, is reloaded so the
  new tags are suggested.
  """

  use Gettext, backend: Mythweaver.Gettext

  import Phoenix.Component, only: [assign: 3, to_form: 2]
  import Phoenix.LiveView, only: [attach_hook: 4, push_event: 3, push_patch: 2, put_flash: 3]

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Tags
  alias MythweaverWeb.Bulk.Field
  alias MythweaverWeb.Bulk.Selection
  alias MythweaverWeb.Bulk.Spec
  alias MythweaverWeb.EnumLabels
  alias Phoenix.LiveView.Socket

  defstruct specs: %{}, order: [], active?: false, selected: %{}, edit: nil, tags: nil

  @type t :: %__MODULE__{}

  @doc "Assigns `:bulk` for `specs` and attaches the event hook."
  @spec attach(Socket.t(), [Spec.t()]) :: Socket.t()
  def attach(socket, specs) do
    names = Enum.map(specs, &Atom.to_string(&1.name))

    bulk = %__MODULE__{
      specs: Map.new(specs, &{Atom.to_string(&1.name), &1}),
      order: names,
      selected: Map.new(names, &{&1, MapSet.new()})
    }

    socket
    |> assign(:bulk, bulk)
    |> attach_hook(:bulk, :handle_event, &handle_event/3)
  end

  @doc "The specs in the order they were attached."
  @spec specs(t()) :: [Spec.t()]
  def specs(%__MODULE__{order: order, specs: specs}), do: Enum.map(order, &Map.fetch!(specs, &1))

  @spec selected?(t(), String.t(), term()) :: boolean()
  def selected?(%__MODULE__{selected: selected}, list, id),
    do: MapSet.member?(Map.get(selected, list, MapSet.new()), id)

  @doc "The selected row count over every list."
  @spec count(t()) :: non_neg_integer()
  def count(%__MODULE__{selected: selected}), do: selected |> Map.values() |> Enum.map(&MapSet.size/1) |> Enum.sum()

  @spec selected_ids(t(), String.t()) :: [term()]
  def selected_ids(%__MODULE__{selected: selected}, list),
    do: selected |> Map.get(list, MapSet.new()) |> MapSet.to_list()

  @doc false
  def handle_event("bulk_mode", _params, socket) do
    bulk = socket.assigns.bulk
    active? = not bulk.active?

    bulk = %{
      bulk
      | active?: active?,
        edit: nil,
        tags: nil,
        selected: if(active?, do: bulk.selected, else: cleared(bulk))
    }

    {:halt, socket |> put(bulk) |> refresh_all()}
  end

  # A toggle or a range only records the selection: the browser has already set those boxes (the
  # click itself, or `RangeSelect` for a range), so the rows are not re-rendered. Re-rendering
  # streamed rows replaces each row's content, which drops the clicked box's focus and moves the
  # list's scroll position. Lists rendered from assigns (not streams) still follow `@bulk`.
  def handle_event("bulk_toggle", %{"list" => list, "id" => id}, socket) do
    case socket.assigns.bulk.specs do
      %{^list => spec} ->
        {:halt, update_selected(socket, list, &Selection.toggle(&1, id, spec.ids.(socket)))}

      _ ->
        {:halt, socket}
    end
  end

  def handle_event("bulk_range", %{"ids" => ids}, socket) when is_list(ids) do
    specs = socket.assigns.bulk.specs

    socket =
      ids
      |> Enum.flat_map(fn entry ->
        case String.split(to_string(entry), ":", parts: 2) do
          [list, id] when is_map_key(specs, list) -> [{list, id}]
          _ -> []
        end
      end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.reduce(socket, fn {list, range}, socket ->
        spec = specs[list]
        update_selected(socket, list, &Selection.add_range(&1, range, spec.ids.(socket)))
      end)

    {:halt, socket}
  end

  def handle_event("bulk_all", _params, socket) do
    bulk = socket.assigns.bulk
    listed = Map.new(bulk.specs, fn {name, spec} -> {name, spec.ids.(socket)} end)

    all? =
      Enum.any?(listed, fn {_, ids} -> ids != [] end) and
        Enum.all?(listed, fn {name, ids} -> Enum.all?(ids, &MapSet.member?(bulk.selected[name], &1)) end)

    selected =
      if all?,
        do: cleared(bulk),
        else: Map.new(bulk.selected, fn {name, sel} -> {name, MapSet.union(sel, MapSet.new(listed[name]))} end)

    {:halt, socket |> put(%{bulk | selected: selected}) |> push_checks()}
  end

  def handle_event("bulk_clear", _params, socket) do
    bulk = socket.assigns.bulk
    {:halt, socket |> put(%{bulk | selected: cleared(bulk)}) |> push_checks()}
  end

  def handle_event("bulk_delete", _params, socket) do
    scope = socket.assigns.current_scope

    {socket, results} =
      socket.assigns.bulk
      |> specs()
      |> Enum.reduce({socket, []}, fn spec, {socket, results} ->
        name = Atom.to_string(spec.name)

        case selected_ids(socket.assigns.bulk, name) do
          [] ->
            {socket, results}

          ids ->
            {done, failed} = run(scope, spec, ids, &spec.delete.(scope, &1))
            open = spec.open_id.(socket)
            socket = update_selected(socket, name, &MapSet.difference(&1, MapSet.new(done)))
            socket = spec.refresh.(socket)
            socket = if open in done, do: push_patch(socket, to: spec.index_path), else: socket
            {socket, results ++ [{spec, done, failed}]}
        end
      end)

    {:halt, flash(socket, results, :deleted)}
  end

  def handle_event("bulk_edit", %{"list" => list}, socket) do
    bulk = socket.assigns.bulk

    with %{^list => %Spec{fields: [_ | _], update: update} = spec} when is_function(update) <- bulk.specs,
         [_ | _] <- selected_ids(bulk, list) do
      scope = socket.assigns.current_scope

      options =
        Map.new(spec.fields, fn
          %Field{options: fun} = f when is_function(fun, 1) -> {f.key, fun.(scope)}
          %Field{} = f -> {f.key, f.options}
        end)

      edit = %{list: list, form: to_form(%{}, as: :bulk), options: options, error: nil}
      {:halt, put(socket, %{bulk | edit: edit})}
    else
      _ -> {:halt, socket}
    end
  end

  def handle_event("bulk_edit_validate", %{"bulk" => params} = event, socket) do
    case socket.assigns.bulk do
      %{edit: %{list: list} = edit} = bulk ->
        keys = Enum.map(bulk.specs[list].fields, &Atom.to_string(&1.key))

        params =
          case event["_target"] do
            # A chip input posts a list (`bulk[key][]`).
            ["bulk", key | _] -> if key in keys, do: Map.put(params, "apply_#{key}", "true"), else: params
            _ -> params
          end

        {:halt, put(socket, %{bulk | edit: %{edit | form: to_form(params, as: :bulk, action: :validate)}})}

      _ ->
        {:halt, socket}
    end
  end

  def handle_event("bulk_edit_save", %{"bulk" => params}, socket) do
    case socket.assigns.bulk do
      %{edit: %{list: list} = edit} = bulk ->
        spec = bulk.specs[list]
        attrs = attrs(spec.fields, params)
        form = to_form(params, as: :bulk, action: :validate)

        if attrs == %{} do
          {:halt,
           put(socket, %{bulk | edit: %{edit | form: form, error: gettext("Tick at least one field to change.")}})}
        else
          save(socket, spec, list, attrs, %{edit | form: form})
        end

      _ ->
        {:halt, socket}
    end
  end

  def handle_event("bulk_edit_close", _params, socket) do
    {:halt, put(socket, %{socket.assigns.bulk | edit: nil})}
  end

  def handle_event("bulk_tags", %{"list" => list}, socket) do
    bulk = socket.assigns.bulk

    with %{^list => %Spec{tag_kind: kind}} when not is_nil(kind) <- bulk.specs,
         [_ | _] <- selected_ids(bulk, list) do
      scope = socket.assigns.current_scope
      graph = Tags.graph(scope.user.id)

      tags = %{
        list: list,
        site?: kind != :chat and Scope.can?(scope, "site.content.manage"),
        form: to_form(%{"domain" => "mine"}, as: :tags),
        add: [],
        remove: [],
        invalid: [],
        add_errors: [],
        remove_errors: [],
        vocabulary: Tags.vocabulary(scope.user.id, graph),
        error: nil
      }

      {:halt, put(socket, %{bulk | tags: tags})}
    else
      _ -> {:halt, socket}
    end
  end

  def handle_event("bulk_tags_validate", %{"tags" => params}, socket) do
    case socket.assigns.bulk do
      %{tags: %{} = tags} = bulk -> {:halt, put(socket, %{bulk | tags: put_tag_params(tags, params)})}
      _ -> {:halt, socket}
    end
  end

  def handle_event("bulk_tags_save", %{"tags" => params}, socket) do
    case socket.assigns.bulk do
      %{tags: %{list: list} = tags} = bulk ->
        tags = put_tag_params(tags, params)

        cond do
          tags.add_errors != [] or tags.remove_errors != [] ->
            {:halt, put(socket, %{bulk | tags: %{tags | error: gettext("Fix the highlighted tags first.")}})}

          tags.add == [] and tags.remove == [] ->
            {:halt, put(socket, %{bulk | tags: %{tags | error: gettext("Add or remove at least one tag.")}})}

          true ->
            save_tags(socket, bulk.specs[list], list, tags)
        end

      _ ->
        {:halt, socket}
    end
  end

  def handle_event("bulk_tags_close", _params, socket) do
    {:halt, put(socket, %{socket.assigns.bulk | tags: nil})}
  end

  def handle_event(_event, _params, socket), do: {:cont, socket}

  defp save(socket, spec, list, attrs, edit) do
    scope = socket.assigns.current_scope
    bulk = socket.assigns.bulk
    {done, failed} = run(scope, spec, selected_ids(bulk, list), &spec.update.(scope, &1, attrs))

    case {done, failed} do
      {[], [{_title, reason} | _]} ->
        {:halt, put(socket, %{bulk | edit: %{edit | error: reason}})}

      _ ->
        open = spec.open_id.(socket)
        socket = socket |> put(%{bulk | edit: nil}) |> spec.refresh.()
        socket = if open in done, do: push_patch(socket, to: spec.edit_path.(open)), else: socket
        {:halt, flash(socket, [{spec, done, failed}], :updated)}
    end
  end

  defp put_tag_params(tags, params) do
    {add, bad_add, add_errors} = Tags.normalize_list(params["add"])
    {remove, bad_remove, remove_errors} = Tags.normalize_list(params["remove"])
    domain = if tags.site? and params["domain"] == "site", do: "site", else: "mine"

    %{
      tags
      | form: to_form(%{"domain" => domain}, as: :tags, action: :validate),
        add: add,
        remove: remove,
        invalid: bad_add ++ bad_remove,
        add_errors: add_errors,
        remove_errors: remove_errors,
        error: nil
    }
  end

  defp save_tags(socket, spec, list, tags) do
    scope = socket.assigns.current_scope
    bulk = socket.assigns.bulk
    domain = if tags.form.params["domain"] == "site", do: :site, else: :mine

    {done, failed} =
      run(scope, spec, selected_ids(bulk, list), fn row ->
        with :ok <- Tags.edit_item_tags(scope, row, domain, tags.add, tags.remove), do: {:ok, row}
      end)

    case {done, failed} do
      {[], [{_title, reason} | _]} ->
        {:halt, put(socket, %{bulk | tags: %{tags | error: reason}})}

      _ ->
        open = spec.open_id.(socket)
        socket = socket |> put(%{bulk | tags: nil}) |> reload_vocabulary() |> spec.refresh.()
        socket = if open in done, do: push_patch(socket, to: spec.edit_path.(open)), else: socket
        {:halt, flash(socket, [{spec, done, failed}], :tagged)}
    end
  end

  # New tags become suggestions in the screen's tag filter and editor.
  defp reload_vocabulary(%{assigns: %{tag_vocabulary: _, tag_graph: graph}} = socket),
    do: assign(socket, :tag_vocabulary, Tags.vocabulary(socket.assigns.current_scope.user.id, graph))

  defp reload_vocabulary(socket), do: socket

  # Fetches and acts on each id; a row that is gone is skipped. `{done_ids, [{title, reason}]}`.
  defp run(scope, spec, ids, fun) do
    Enum.reduce(ids, {[], []}, fn id, {done, failed} ->
      case spec.get.(scope, id) do
        nil ->
          {done, failed}

        row ->
          case fun.(row) do
            {:ok, _} -> {[id | done], failed}
            {:held, _hold} -> {done, [{spec.title.(row), held_reason()} | failed]}
            {:error, :hold_limit} -> {done, [{spec.title.(row), hold_limit_reason()} | failed]}
            {:error, reason} -> {done, [{spec.title.(row), reason(reason)} | failed]}
          end
      end
    end)
    |> then(fn {done, failed} -> {Enum.reverse(done), Enum.reverse(failed)} end)
  end

  @doc false
  # The string-keyed attrs of the fields whose apply box is ticked.
  def attrs(fields, params) do
    for %Field{key: key} = field <- fields, params["apply_#{key}"] == "true", into: %{} do
      name = Atom.to_string(key)
      {name, value(field, Map.get(params, name))}
    end
  end

  defp value(%Field{type: :checkbox}, value), do: value == "true"
  defp value(%Field{type: :tags, max: 1}, values), do: values |> chips() |> List.last()
  defp value(%Field{type: :tags}, values), do: chips(values)
  defp value(%Field{type: :select, prompt: prompt}, "") when not is_nil(prompt), do: nil
  defp value(%Field{cast: cast}, value) when is_function(cast, 1), do: cast.(value || "")
  defp value(%Field{}, value), do: value

  defp chips(values), do: values |> List.wrap() |> Enum.reject(&(&1 == ""))

  defp reason(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(&MythweaverWeb.CoreComponents.translate_error/1)
    |> Enum.map_join("; ", fn {field, messages} -> field_error(field, Enum.join(List.wrap(messages), ", ")) end)
  end

  defp reason({:invalid, raw, message}), do: field_error(raw, message)
  defp reason(:self), do: pgettext("status: why a bulk action skipped an item", "Your own account")
  defp reason(:own_role), do: pgettext("status: why a bulk action skipped an item", "Your own role")
  defp reason(reason) when reason in [:unauthorized, :in_use, :sudo_required], do: EnumLabels.skip_reason(reason)
  defp reason(_reason), do: pgettext("status: why a bulk action skipped an item", "Failed")

  defp held_reason, do: pgettext("status: why a bulk action skipped an item", "Waiting for moderator review")

  defp hold_limit_reason, do: pgettext("status: why a bulk action skipped an item", "Too much waiting for review")

  defp field_error(field, message) do
    gettext_comment(
      "A value's validation errors in a bulk action's failure summary; the first placeholder is a field's internal name or the rejected value."
    )

    pgettext("status: errors of one field in a bulk failure summary", "%{field_name}: %{error_messages}",
      field_name: field,
      error_messages: message
    )
  end

  defp flash(socket, [], _action), do: socket

  defp flash(socket, results, action) do
    message =
      Enum.map_join(results, " ", fn {%Spec{count_label: count_label}, done, failed} ->
        ok = if done != [], do: done_sentence(action, count_label.(length(done)))

        bad =
          if failed != [] do
            failures = Enum.map_join(failed, ", ", fn {t, r} -> failure(t, r) end)
            failed_sentence(action, length(failed), failures)
          end

        [ok, bad] |> Enum.reject(&is_nil/1) |> Enum.join(" ")
      end)

    kind = if Enum.any?(results, fn {_, done, _} -> done != [] end), do: :info, else: :error
    put_flash(socket, kind, message)
  end

  defp failure(title, reason) do
    gettext_comment("One item in a bulk action's failure list: the item's name, then why it failed.")

    pgettext("status: one failed item in a bulk failure summary", "%{item_title} (%{failure_reason})",
      item_title: title,
      failure_reason: reason
    )
  end

  @failed_comment "Flash after a bulk action; %{failure_list} is a comma-separated list of item names, each followed by its reason in parentheses."

  defp done_sentence(:deleted, item_totals) do
    gettext_comment("Flash after a bulk action; %{item_totals} is a counted noun phrase such as \"3 characters\".")
    pgettext("status: flash after a bulk delete", "Deleted %{item_totals}.", item_totals: item_totals)
  end

  defp done_sentence(:updated, item_totals) do
    gettext_comment("Flash after a bulk action; %{item_totals} is a counted noun phrase such as \"3 characters\".")
    pgettext("status: flash after a bulk update", "Updated %{item_totals}.", item_totals: item_totals)
  end

  defp done_sentence(:tagged, item_totals) do
    gettext_comment("Flash after a bulk action; %{item_totals} is a counted noun phrase such as \"3 characters\".")
    pgettext("status: flash after a bulk tag change", "Tagged %{item_totals}.", item_totals: item_totals)
  end

  defp failed_sentence(action, n, failures) do
    bindings = [failed_count: Mythweaver.Format.number(n), failure_list: failures]

    case action do
      :deleted ->
        gettext_comment(@failed_comment)

        ngettext(
          "%{failed_count} couldn't be deleted: %{failure_list}.",
          "%{failed_count} couldn't be deleted: %{failure_list}.",
          n,
          bindings
        )

      :updated ->
        gettext_comment(@failed_comment)

        ngettext(
          "%{failed_count} couldn't be updated: %{failure_list}.",
          "%{failed_count} couldn't be updated: %{failure_list}.",
          n,
          bindings
        )

      :tagged ->
        gettext_comment(@failed_comment)

        ngettext(
          "%{failed_count} couldn't be tagged: %{failure_list}.",
          "%{failed_count} couldn't be tagged: %{failure_list}.",
          n,
          bindings
        )
    end
  end

  defp update_selected(socket, name, fun) do
    bulk = socket.assigns.bulk
    put(socket, %{bulk | selected: Map.update!(bulk.selected, name, fun)})
  end

  defp cleared(bulk), do: Map.new(bulk.selected, fn {name, _} -> {name, MapSet.new()} end)

  defp put(socket, bulk), do: assign(socket, :bulk, bulk)

  # Specs may share a refresh (the lore tree): run each distinct one once.
  defp refresh_all(socket) do
    socket.assigns.bulk |> specs() |> Enum.map(& &1.refresh) |> Enum.uniq() |> Enum.reduce(socket, & &1.(&2))
  end

  # Select all and Clear set the boxes in the browser (`RangeSelect`'s `bulk_checks`) instead of
  # re-rendering the rows, for the same reason as a toggle. `ids` is every selected `list:id`.
  defp push_checks(socket) do
    ids = for {list, ids} <- socket.assigns.bulk.selected, id <- ids, do: "#{list}:#{id}"
    push_event(socket, "bulk_checks", %{ids: ids})
  end
end
