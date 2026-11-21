defmodule MythweaverWeb.Chat.CaptionQuestion do
  @moduledoc """
  The "Ask…" dialog: a one-time question sent to the caption model in place of its caption prompt
  (`Mythweaver.Attachments.Captions.request/4` and `request_staged/4`'s `:instruction`). Opened by
  an image's Ask… button, and, with the `images.ask_every_time` setting on, by every description a
  person starts. A blank question gives the usual description. Cancel, Escape or the backdrop
  dismiss it without describing.
  """

  use MythweaverWeb, :html

  attr(:question, :map,
    required: true,
    doc: "`%{target: {:staged, [attachment_id]} | {:sent, attachment_id}}`"
  )

  def caption_question(assigns) do
    assigns = assign(assigns, :title, title(assigns.question.target))

    ~H"""
    <%!--
      `lower-bound="none"`: the content lives inside `<.modal>`'s slot, a nested component root. Each
      of this template's own tags then carries the scope marker and is a scope root, so the rules are
      `tag:scope`-qualified.
    --%>
    <style :type={MythweaverWeb.ColocatedScopedCSS} lower-bound="none">
      div:scope.caption-question-actions {
        display: flex;
        justify-content: flex-end;
        gap: var(--size-2);
        margin-top: var(--size-3);
      }
    </style>

    <.modal id="caption-question-modal" title={@title} on_cancel="cancel_caption_question">
      <.form
        for={%{}}
        as={:caption_question}
        id="caption-question-form"
        phx-submit="submit_caption_question"
      >
        <.editor
          name="question"
          value=""
          id="caption-question-text"
          rows={3}
          autofocus
          submit_on_enter
          spellcheck
          placeholder={
            dpgettext(
              "chat",
              "placeholder: one-time question to the image caption model",
              "Leave blank for the usual description"
            )
          }
        />
        <div class="caption-question-actions">
          <.button
            id="caption-question-cancel"
            phx-click={JS.dispatch("modal:close", to: "#caption-question-modal")}
          >
            {dpgettext("chat", "button: close the image question dialog", "Cancel")}
          </.button>
          <.button id="caption-question-submit" type="submit" variant="primary">
            {dpgettext(
              "chat",
              "button: send the question about the image to the caption model",
              "Describe"
            )}
          </.button>
        </div>
      </.form>
    </.modal>
    """
  end

  defp title({:staged, [_, _ | _]}),
    do: dpgettext("chat", "heading: dialog asking the caption model about several images", "Ask about these images")

  defp title(_target),
    do: dpgettext("chat", "heading: dialog asking the caption model about one image", "Ask about this image")
end
