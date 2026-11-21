defmodule MythweaverWeb.LiveSync do
  @moduledoc """
  Keeps a LiveView in step with writes made elsewhere (another tab, another user, a script, a job).

  `attach/3` subscribes to `Mythweaver.Changes` kinds and calls `refresh.(socket, kinds)` once per
  burst: messages already queued are drained into one call. `attach_editor/3` also tracks the page's
  URL (`live_sync_path`) and the `changed_elsewhere?` flag for `sync_open/3` and
  `<.changed_elsewhere>`, whose "Discard and reload" patches to that URL so `handle_params/3` rebuilds
  the form; the hook clears the flag on every `handle_params`.
  """

  import Phoenix.Component, only: [assign: 2, assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1, push_patch: 2, put_flash: 3]

  alias Mythweaver.Changes
  alias Phoenix.HTML.Form
  alias Phoenix.LiveView.Socket

  @type refresh :: (Socket.t(), [Changes.kind()] -> Socket.t())

  @doc "Subscribes to `kinds` (when connected) and runs `refresh` on each burst of changes."
  @spec attach(Socket.t(), [Changes.kind()], refresh()) :: Socket.t()
  def attach(socket, kinds, refresh) do
    if connected?(socket), do: Changes.subscribe(socket.assigns.current_scope, kinds)

    attach_hook(socket, :live_sync, :handle_info, fn
      {Changes, kind}, socket -> {:halt, refresh.(socket, drain([kind]))}
      _message, socket -> {:cont, socket}
    end)
  end

  @doc "`attach/3` plus the `changed_elsewhere?` and `live_sync_path` assigns an editor needs."
  @spec attach_editor(Socket.t(), [Changes.kind()], refresh()) :: Socket.t()
  def attach_editor(socket, kinds, refresh) do
    socket
    |> assign(changed_elsewhere?: false, live_sync_path: nil)
    |> attach(kinds, refresh)
    |> attach_hook(:live_sync_params, :handle_params, fn _params, uri, socket ->
      {:cont, assign(socket, changed_elsewhere?: false, live_sync_path: path(uri))}
    end)
  end

  defp drain(kinds) do
    receive do
      {Changes, kind} -> drain([kind | kinds])
    after
      0 -> Enum.uniq(kinds)
    end
  end

  defp path(uri) do
    case URI.parse(uri) do
      %URI{path: path, query: nil} -> path
      %URI{path: path, query: query} -> path <> "?" <> query
    end
  end

  @doc """
  Re-reads the open row held in `assigns[key]` (no-op when nil). Required opts: `:fetch`
  (`id -> row | nil`, through the screen's own editable getter), `:clean?` (boolean, the form's
  `data-saved` test, usually `clean?/1` of it), `:reload` (`(socket, fresh) -> socket`, rebuilds
  the form from `fresh`), `:gone` (index path), `:gone_message` (the whole flash sentence, written by the caller in its
  own domain, e.g. "The character was deleted or moved elsewhere."). Optional: `:ignore` (fields
  left out of the comparison), `:compare` (`(held, fresh) -> boolean`, default `changed?/3` with
  `:ignore`), `:force` (reload a clean form even when the row compares equal, e.g. tags changed),
  `:on_gone` (`socket -> socket`, run first when the row is gone, e.g. to close forms built on it).

    * row gone: runs `:on_gone`, assigns `key` nil, flashes `:gone_message`,
      patches to `:gone`;
    * clean and (changed or force): `reload`;
    * dirty and changed: `changed_elsewhere?: true`, `key` keeps the held row (so a save's changeset
      only carries the fields the user actually edited);
    * otherwise: `key` takes the fresh row (status fields such as a script's last run stay current).
  """
  @spec sync_open(Socket.t(), atom(), keyword()) :: Socket.t()
  def sync_open(socket, key, opts) do
    case socket.assigns[key] do
      nil -> socket
      held -> sync_held(socket, key, held, opts[:fetch].(held.id), opts)
    end
  end

  defp sync_held(socket, key, _held, nil, opts) do
    on_gone = Keyword.get(opts, :on_gone, & &1)

    socket
    |> on_gone.()
    |> assign(key, nil)
    |> put_flash(:error, Keyword.fetch!(opts, :gone_message))
    |> push_patch(to: Keyword.fetch!(opts, :gone))
  end

  defp sync_held(socket, key, held, fresh, opts) do
    ignore = Keyword.get(opts, :ignore, [])
    compare = Keyword.get(opts, :compare, &changed?(&1, &2, ignore))
    changed? = compare.(held, fresh)

    cond do
      Keyword.fetch!(opts, :clean?) and (changed? or Keyword.get(opts, :force, false)) ->
        Keyword.fetch!(opts, :reload).(socket, fresh)

      changed? ->
        assign(socket, :changed_elsewhere?, true)

      true ->
        assign(socket, key, fresh)
    end
  end

  @doc "Whether `form` is open and untouched (its `data-saved` test): no form counts as not clean."
  @spec clean?(Form.t() | nil) :: boolean()
  def clean?(%Form{action: action}), do: is_nil(action)
  def clean?(nil), do: false

  @doc "Whether two rows of one schema differ in any stored field besides timestamps and `ignore`."
  @spec changed?(struct(), struct(), [atom()]) :: boolean()
  def changed?(%schema{} = held, %schema{} = fresh, ignore \\ []) do
    fields = schema.__schema__(:fields) -- [:inserted_at, :updated_at | ignore]
    Map.take(held, fields) != Map.take(fresh, fields)
  end
end
