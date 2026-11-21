defmodule MythweaverWeb.Chat.ImageRequest do
  @moduledoc """
  The dialog a script's `mw.images.request(prompt, opts)` opens in every tab of the chat
  (`Mythweaver.Attachments.request_image/3`). A browser opens a file picker only from a click, so
  the dialog's Choose image button does it: its click opens the composer's own file input, and the
  chosen image joins the composer like any upload, which fulfils the request and closes the dialog
  in every tab. A `mw.characters.set_avatar` request works the same, but its image becomes the
  character's avatar instead of joining the composer. Cancel, Escape or the backdrop dismiss it.
  """

  use MythweaverWeb, :html

  attr(:request, :map,
    required: true,
    doc: "`%{id:, prompt:, callback:, avatar:}`; `avatar` is set for a `set_avatar` request"
  )

  attr(:input_id, :string,
    required: true,
    doc: "the composer upload's file input (`@uploads.composer_files.ref`)"
  )

  def image_request(assigns) do
    ~H"""
    <%!--
      `lower-bound="none"`: the content lives inside `<.modal>`'s slot, a nested component root. Each
      of this template's own tags then carries the scope marker and is a scope root, so the rules are
      `tag:scope`-qualified.
    --%>
    <style :type={MythweaverWeb.ColocatedScopedCSS} lower-bound="none">
      p:scope.image-request-prompt {
        margin: 0;
        white-space: pre-wrap;
      }

      div:scope.image-request-actions {
        display: flex;
        justify-content: flex-end;
        gap: var(--size-2);
        margin-top: var(--size-3);
      }
    </style>

    <.modal
      id="image-request-modal"
      title={
        if @request[:avatar],
          do:
            dpgettext(
              "chat",
              "heading: dialog where a script asks for a character avatar",
              "Avatar requested"
            ),
          else:
            dpgettext("chat", "heading: dialog where a script asks for an image", "Image requested")
      }
      on_cancel="dismiss_image_request"
    >
      <p id="image-request-prompt" class="image-request-prompt">
        {@request.prompt || default_prompt(@request)}
      </p>

      <div class="image-request-actions">
        <.button
          id="image-request-cancel"
          phx-click={JS.dispatch("modal:close", to: "#image-request-modal")}
        >
          {dpgettext("chat", "button: dismiss a script's image request", "Cancel")}
        </.button>
        <.button
          id="image-request-choose"
          variant="primary"
          phx-hook=".ChooseRequestedImage"
          data-input={@input_id}
        >
          <.lucide name="image-plus" /> {dpgettext(
            "chat",
            "button: pick an image file for a script's request",
            "Choose image"
          )}
        </.button>
      </div>
    </.modal>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".ChooseRequestedImage">
      // Within the click, so the browser lets the file picker open. The dialog stays open until an
      // image is attached: a picker closed without choosing leaves the request standing.
      export default {
        mounted() {
          this.el.addEventListener("click", () =>
            document.getElementById(this.el.dataset.input)?.click(),
          );
        },
      };
    </script>
    """
  end

  defp default_prompt(%{avatar: %{name: name}}),
    do: dgettext("chat", "A script asks you for an avatar for %{character_name}.", character_name: name)

  defp default_prompt(_request), do: dgettext("chat", "A script asks you to attach an image.")
end
