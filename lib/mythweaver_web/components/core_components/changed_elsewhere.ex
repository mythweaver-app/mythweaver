defmodule MythweaverWeb.CoreComponents.ChangedElsewhere do
  @moduledoc """
  The notice an editor shows when its open row was saved elsewhere (another tab, another user, a
  script) while the form holds unsaved edits (`MythweaverWeb.LiveSync.sync_open/3`). The edits stay;
  the button discards them and reloads the row, by `patch` (the page's own URL, re-running
  `handle_params/3`) or, given no `patch`, by the `phx-click` passed in `rest`.
  """

  use Phoenix.Component
  use Gettext, backend: Mythweaver.Gettext

  import Iconex, only: [lucide: 1]
  import MythweaverWeb.CoreComponents.Button, only: [button: 1]

  attr :id, :string, required: true
  attr :patch, :string, default: nil, doc: "the URL that reloads the row; else pass `phx-click`"
  attr :rest, :global, include: ~w(phx-click phx-target)

  def changed_elsewhere(assigns) do
    ~H"""
    <style :type={MythweaverWeb.ColocatedScopedCSS}>
      div.changed-elsewhere:scope {
        display: flex;
        flex-wrap: wrap;
        align-items: center;
        gap: var(--size-2);
        padding: var(--size-2) var(--size-3);
        border: 1px solid var(--primary-accent);
        border-radius: var(--radius-3);
        background: var(--surface-3);
      }

      p {
        margin: 0;
        flex: 1 1 20ch;
      }
    </style>

    <div id={@id} class="changed-elsewhere" role="status">
      <.lucide name="refresh-cw" />
      <p>
        {gettext(
          "This was changed elsewhere while you were editing. Saving writes your version over it."
        )}
      </p>
      <.button :if={@patch} size="sm" variant="secondary" id={"#{@id}-reload"} patch={@patch}>
        {discard_label()}
      </.button>
      <.button :if={!@patch} size="sm" variant="secondary" id={"#{@id}-reload"} {@rest}>
        {discard_label()}
      </.button>
    </div>
    """
  end

  defp discard_label,
    do:
      pgettext(
        "button: drop the form's unsaved edits and load the row saved elsewhere",
        "Discard my changes and reload"
      )
end
