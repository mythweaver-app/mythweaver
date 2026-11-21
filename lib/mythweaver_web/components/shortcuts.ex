defmodule MythweaverWeb.Shortcuts do
  @moduledoc """
  The app's keyboard shortcuts: one fixed registry that feeds the key listener (`help/1`'s
  `.Shortcuts` hook), the `?` help popup and the command palette's key hints. Shortcuts are fixed:
  there are no settings and users cannot edit them.

  An entry's `action` is `{:command, id}` (a `MythweaverWeb.CommandPalette.Commands` id, run through
  the palette's `"shortcut"` event), `:palette`, `:help`, `:search_global` / `:search_local` (open
  the search overlay, `MythweaverWeb.Search`), or `nil` (listed only; another component owns the
  key). `typing` says when it fires while an editable element has focus: `:always`;
  `:outside_editor` (everywhere, inputs included, except inside a CodeMirror editor other than the
  message composer, which keeps the key for itself); `:composer` (also inside the message composer);
  `:idle` (also in the composer while it is empty).
  `when` is a CSS selector that must match for the shortcut to fire. `phase` picks the window
  listener: `:capture` runs before anything else; `:bubble` yields to a handler that already took
  the key (`defaultPrevented`).
  """

  # Bare `Phoenix.Component` plus direct imports, like `CoreComponents.Modal`.
  use Phoenix.Component
  use Gettext, backend: Mythweaver.Gettext

  import Iconex, only: [lucide: 1]
  import MythweaverWeb.CoreComponents.Button, only: [button: 1]

  @shortcuts [
    %{
      id: "palette",
      group: :general,
      keys: ["Mod", "P"],
      action: :palette,
      typing: :always
    },
    %{
      id: "search_global",
      group: :general,
      keys: ["Mod", "K"],
      action: :search_global,
      typing: :always
    },
    %{
      id: "search_local",
      group: :general,
      keys: ["Mod", "F"],
      action: :search_local,
      typing: :outside_editor,
      when: "#search[data-local]"
    },
    %{
      id: "editor_find",
      group: :general,
      keys: ["Mod", "F"],
      action: nil
    },
    %{id: "save_form", group: :general, keys: ["Mod", "Enter"], action: nil},
    %{id: "help", group: :general, keys: ["?"], action: :help, typing: :idle},
    %{
      id: "edit_last",
      group: :chat,
      keys: ["ArrowUp"],
      action: {:command, "chat.edit_last"},
      typing: :idle,
      when: "#messages"
    },
    %{
      id: "edit_last_player",
      group: :chat,
      keys: ["Mod", "ArrowUp"],
      action: {:command, "chat.edit_last_player"},
      typing: :idle,
      when: "#messages"
    },
    %{
      id: "swipe_prev",
      group: :chat,
      keys: ["ArrowLeft"],
      action: {:command, "chat.swipe_prev"},
      typing: :idle,
      when: "#messages"
    },
    %{
      id: "swipe_next",
      group: :chat,
      keys: ["ArrowRight"],
      action: {:command, "chat.swipe_next"},
      typing: :idle,
      when: "#messages"
    },
    %{
      id: "regenerate",
      group: :chat,
      keys: ["Mod", "Enter"],
      action: {:command, "chat.regenerate"},
      typing: :composer,
      when: "#messages"
    },
    %{
      id: "continue",
      group: :chat,
      keys: ["Alt", "Enter"],
      action: {:command, "chat.continue"},
      typing: :composer,
      when: "#messages"
    },
    %{
      id: "refine",
      group: :chat,
      keys: ["Mod", "E"],
      action: {:command, "chat.refine"},
      typing: :composer,
      when: "#messages"
    },
    %{
      id: "stop",
      group: :chat,
      keys: ["Escape"],
      action: {:command, "chat.stop"},
      typing: :always,
      phase: :bubble,
      when: "#stop-generation"
    },
    %{id: "send", group: :composer, keys: ["Enter"], action: nil},
    %{id: "newline", group: :composer, keys: ["Shift", "Enter"], action: nil},
    %{id: "history_prev", group: :composer, keys: ["Alt", "ArrowUp"], action: nil},
    %{id: "history_next", group: :composer, keys: ["Alt", "ArrowDown"], action: nil},
    %{id: "edit_save", group: :composer, keys: ["Escape"], action: nil}
  ]

  @shortcuts Enum.map(@shortcuts, &Map.merge(%{typing: nil, phase: :capture, when: nil}, &1))

  @by_command for %{action: {:command, id}, keys: keys} <- @shortcuts, into: %{}, do: {id, keys}

  @groups [:general, :chat, :composer]

  @doc "Every shortcut, in help-popup order, each with its translated `label`."
  @spec all() :: [map()]
  def all, do: Enum.map(@shortcuts, &Map.put(&1, :label, shortcut_label(&1.id)))

  defp shortcut_label("palette"), do: pgettext("menu item: keyboard shortcut action", "Open the command palette")
  defp shortcut_label("search_global"), do: pgettext("menu item: keyboard shortcut action", "Search everything")
  defp shortcut_label("search_local"), do: pgettext("menu item: keyboard shortcut action", "Search this page")

  defp shortcut_label("editor_find"),
    do: pgettext("menu item: keyboard shortcut action", "Find and replace in the focused editor")

  defp shortcut_label("save_form"), do: pgettext("menu item: keyboard shortcut action", "Save the form being edited")
  defp shortcut_label("help"), do: pgettext("menu item: keyboard shortcut action", "Show keyboard shortcuts")
  defp shortcut_label("edit_last"), do: pgettext("menu item: keyboard shortcut action", "Edit the last message")
  defp shortcut_label("edit_last_player"), do: pgettext("menu item: keyboard shortcut action", "Edit your last message")

  defp shortcut_label("swipe_prev"),
    do: pgettext("menu item: keyboard shortcut action", "Previous swipe of the last reply (the newest after the first)")

  defp shortcut_label("swipe_next"),
    do: pgettext("menu item: keyboard shortcut action", "Next swipe of the last reply (a new one after the newest)")

  defp shortcut_label("regenerate"), do: pgettext("menu item: keyboard shortcut action", "Regenerate the last reply")
  defp shortcut_label("continue"), do: pgettext("menu item: keyboard shortcut action", "Continue the last reply")

  defp shortcut_label("refine"),
    do: pgettext("menu item: keyboard shortcut action", "Rewrite the last reply with the composer text as instructions")

  defp shortcut_label("stop"), do: pgettext("menu item: keyboard shortcut action", "Stop generating")
  defp shortcut_label("send"), do: pgettext("menu item: keyboard shortcut action", "Send the message")
  defp shortcut_label("newline"), do: pgettext("menu item: keyboard shortcut action", "New line")
  defp shortcut_label("history_prev"), do: pgettext("menu item: keyboard shortcut action", "Previous sent message")
  defp shortcut_label("history_next"), do: pgettext("menu item: keyboard shortcut action", "Next sent message")
  defp shortcut_label("edit_save"), do: pgettext("menu item: keyboard shortcut action", "Save and close a message edit")

  defp group_title(:general), do: pgettext("heading: group of general keyboard shortcuts", "General")
  defp group_title(:chat), do: pgettext("heading: group of chat keyboard shortcuts", "Chat")
  defp group_title(:composer), do: pgettext("heading: group of message composer keyboard shortcuts", "Composer")

  @doc "The keys of the shortcut running command `command_id`, or `nil`."
  @spec keys_for_command(String.t()) :: [String.t()] | nil
  def keys_for_command(command_id), do: Map.get(@by_command, command_id)

  @doc "The shortcuts the `.Shortcuts` hook listens for, as JSON-ready maps."
  @spec client_bindings() :: [map()]
  def client_bindings do
    for %{action: action} = s <- @shortcuts, action != nil do
      {kind, command} =
        case action do
          {:command, id} -> {"command", id}
          other -> {Atom.to_string(other), nil}
        end

      %{
        id: s.id,
        keys: s.keys,
        action: kind,
        command: command,
        typing: Atom.to_string(s.typing),
        phase: Atom.to_string(s.phase),
        when: s.when
      }
    end
  end

  @doc "A shortcut's keys as `<kbd>` chips; nothing for `nil`."
  attr :keys, :list, default: nil

  def keys(%{keys: nil} = assigns), do: ~H""

  def keys(assigns) do
    ~H"""
    <style :type={MythweaverWeb.ColocatedCSS}>
      :root[data-platform="mac"] .shortcut-other,
      :root:not([data-platform="mac"]) .shortcut-mac {
        display: none;
      }

      .shortcut {
        display: inline-flex;
        gap: var(--size-1);
      }

      kbd.shortcut-key {
        background: var(--surface-3);
        border: 1px solid var(--border);
        border-radius: var(--radius-1);
        font-size: 0.75rem;
        min-inline-size: 1.5em;
        text-align: center;
        padding: 0 var(--size-1);
      }
    </style>
    <span class="shortcut">
      <%= for key <- @keys do %>
        <%= case Map.fetch(platform_labels(), key) do %>
          <% {:ok, {mac, other}} -> %>
            <kbd class="shortcut-key"><span class="shortcut-mac">{mac}</span><span class="shortcut-other">{other}</span></kbd>
          <% :error -> %>
            <kbd class="shortcut-key">{label(key)}</kbd>
        <% end %>
      <% end %>
    </span>
    """
  end

  # mac / other labels; tokens not listed render the same everywhere.
  defp platform_labels do
    %{
      "Mod" => {"⌘", pgettext("keyboard key: Control", "Ctrl")},
      "Alt" => {"⌥", pgettext("keyboard key: Alt", "Alt")},
      "Shift" => {"⇧", pgettext("keyboard key: Shift", "Shift")}
    }
  end

  defp label("ArrowUp"), do: "↑"
  defp label("ArrowDown"), do: "↓"
  defp label("ArrowLeft"), do: "←"
  defp label("ArrowRight"), do: "→"
  defp label("Escape"), do: pgettext("keyboard key: Escape", "Esc")
  defp label("Enter"), do: pgettext("keyboard key: Enter", "Enter")
  defp label(key), do: if(String.length(key) == 1, do: String.upcase(key), else: key)

  @doc "The `?` help popup, which also hosts the app's one key listener. Render once per page."
  def help(assigns) do
    assigns =
      assign(assigns,
        bindings: Jason.encode!(client_bindings()),
        sections: for(group <- @groups, do: {group, group_title(group), Enum.filter(all(), &(&1.group == group))})
      )

    ~H"""
    <style :type={MythweaverWeb.ColocatedScopedCSS} lower-bound="none">
      dialog:scope {
        padding: 0;
        border: 0;
        background: none;
        inline-size: min(32rem, calc(100vw - 2 * var(--panel-gap)));
        max-inline-size: min(32rem, calc(100vw - 2 * var(--panel-gap)));
        color: var(--foreground);
      }

      dialog:scope::backdrop {
        background: oklch(0 0 0 / 0.5);
        backdrop-filter: blur(5px) saturate(30%) brightness(60%);
      }

      .shortcut-help-panel {
        background: color-mix(in oklch, var(--surface-5) 75%, transparent);
        border: 1px solid var(--border);
        border-radius: var(--radius-3);
        box-shadow: var(--elevation-2xl);
        padding: var(--size-3);
        display: flex;
        flex-direction: column;
        gap: var(--size-3);
      }

      .shortcut-help-header {
        display: flex;
        align-items: center;
        justify-content: space-between;
        gap: var(--size-2);
      }

      h2,
      h3 {
        margin: 0;
      }

      h2 {
        font-size: 1.1rem;
      }

      h3 {
        font-size: 0.85rem;
        text-transform: uppercase;
        color: var(--muted-foreground);
        margin-block-end: var(--size-1);
      }

      dl {
        margin: 0;
        display: flex;
        flex-direction: column;
        gap: var(--size-1);
      }

      dl > div {
        display: flex;
        justify-content: space-between;
        align-items: center;
        gap: var(--size-2);
      }

      dt,
      dd {
        margin: 0;
      }
    </style>
    <dialog
      id="shortcut-help"
      class="shortcut-help"
      phx-hook=".Shortcuts"
      phx-update="ignore"
      data-bindings={@bindings}
      aria-labelledby="shortcut-help-title"
    >
      <div class="shortcut-help-panel">
        <header class="shortcut-help-header">
          <h2 id="shortcut-help-title">
            {pgettext("heading: keyboard shortcuts help dialog", "Keyboard shortcuts")}
          </h2>
          <form method="dialog">
            <.button
              type="submit"
              icon
              size="sm"
              aria-label={pgettext("aria label: close the keyboard shortcuts dialog", "Close")}
            >
              <.lucide name="x" />
            </.button>
          </form>
        </header>
        <section :for={{group, title, entries} <- @sections} id={"shortcut-help-#{group}"}>
          <h3>{title}</h3>
          <dl>
            <div :for={entry <- entries} id={"shortcut-help-#{entry.id}"}>
              <dt>{entry.label}</dt>
              <dd><.keys keys={entry.keys} /></dd>
            </div>
          </dl>
        </section>
      </div>
    </dialog>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".Shortcuts">
      const MAC = /Mac|iPhone|iPad/.test(navigator.platform);
      const EDITABLE =
        "input, textarea, select, [contenteditable='true'], [contenteditable=''], .cm-editor";

      function match(e, b) {
        const mods = b.keys.slice(0, -1);
        const key = b.keys[b.keys.length - 1];
        const mod = mods.includes("Mod");
        if ((MAC ? e.metaKey : e.ctrlKey) !== mod) return false;
        if (MAC ? e.ctrlKey : e.metaKey) return false;
        if (e.altKey !== mods.includes("Alt")) return false;
        if (key !== "?" && e.shiftKey !== mods.includes("Shift")) return false;
        return key.length === 1
          ? e.key.toLowerCase() === key.toLowerCase()
          : e.key === key;
      }

      function typingAllows(b) {
        if (b.typing === "outside_editor") {
          const cm = document.activeElement?.closest(".cm-editor");
          return !cm || !!cm.closest("#message-composer-content");
        }
        if (b.typing === "always") return true;
        const target = document.activeElement;
        if (!target?.closest(EDITABLE)) return true;
        if (!target.closest("#message-composer-content")) return false;
        if (b.typing === "composer") return true;
        return (
          document
            .querySelector("#message-composer-content textarea")
            ?.value.trim() === ""
        );
      }

      export default {
        mounted() {
          document.documentElement.dataset.platform = MAC ? "mac" : "other";
          const bindings = JSON.parse(this.el.dataset.bindings);
          const handler = (phase) => (e) => {
            if (e.isComposing || e.repeat) return;
            if (phase === "bubble" && e.defaultPrevented) return;
            const open = document.querySelector("dialog[open]");
            const b = bindings.find(
              (b) =>
                b.phase === phase &&
                match(e, b) &&
                (!b.when || document.querySelector(b.when)) &&
                (b.action === "palette" ||
                  !open ||
                  (b.action.startsWith("search_") && open.id === "search-dialog")) &&
                typingAllows(b),
            );
            if (!b) return;
            e.preventDefault();
            e.stopPropagation();
            if (b.action === "command")
              this.pushEventTo("#command-palette", "shortcut", { id: b.command });
            else if (b.action === "palette")
              window.dispatchEvent(new CustomEvent("shortcuts:palette"));
            else if (b.action === "help") this.el.showModal();
            else if (b.action === "search_global" || b.action === "search_local")
              window.dispatchEvent(
                new CustomEvent("shortcuts:search", {
                  detail: { mode: b.action === "search_global" ? "global" : "local" },
                }),
              );
          };
          this.onCapture = handler("capture");
          this.onBubble = handler("bubble");
          window.addEventListener("keydown", this.onCapture, true);
          window.addEventListener("keydown", this.onBubble);
          this.el.addEventListener("click", (e) => {
            if (e.target === this.el) this.el.close();
          });
        },
        destroyed() {
          window.removeEventListener("keydown", this.onCapture, true);
          window.removeEventListener("keydown", this.onBubble);
        },
      };
    </script>
    """
  end
end
