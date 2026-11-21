defmodule Mythweaver.Scripts.EventReference do
  @moduledoc false
  # The `event` global per trigger: the one source for `Mythweaver.Scripts`' moduledoc and the
  # script editor's reference. Descriptions are `dgettext_noop` msgids (or `{context, msgid}` for
  # short ones), translated on read by `Mythweaver.Scripts.common_event_fields/0` and
  # `Mythweaver.Scripts.event_reference/0`. A module of its own so the moduledoc can use it.

  use Gettext, backend: Mythweaver.Gettext

  def data do
    common_event_fields = [
      {"trigger", "string", dgettext_noop("scripts", "The trigger that ran this script, e.g. \"user_message\".")},
      {"chat_id", "string",
       dgettext_noop(
         "scripts",
         "The chat the event happened in. `mw.messages.*`, `mw.generation.*`, `mw.memory.*`, `mw.vars.*` and `mw.injections.*` act on it."
       )}
    ]

    event_reference = [
      %{
        trigger: :user_message,
        summary:
          dgettext_noop(
            "scripts",
            "Runs when the player sends a message or saves an edit, before it is stored. Blank text with no images skips scripts. Only the chat owner's own messages run them; another member's run none."
          ),
        fields: [
          {"text", "string",
           dgettext_noop(
             "scripts",
             "The message text after template rendering. A script earlier in the run order may already have rewritten it."
           )},
          {"character_id", "string",
           dgettext_noop(
             "scripts",
             "The author: the chat's player for a new message, the message's author for an edit."
           )},
          {"message_id", "string | nil", dgettext_noop("scripts", "The edited message, or nil for a new message.")},
          {"edit", "bool", dgettext_noop("scripts", "True when an existing message is being edited.")},
          {"images", "array of string",
           dgettext_noop(
             "scripts",
             "The ids of the images sent with the message (already stored, so mw.images.get and mw.images.caption work on them), or the edited message's images."
           )}
        ],
        returns:
          dgettext_noop(
            "scripts",
            "Return a string to replace the text, or nil (or nothing) to keep it. Returning blank text cancels a send unless images are attached; a blank edit is refused."
          ),
        example: ~S'return event.text .. " *waves*"'
      },
      %{
        trigger: :ai_generation,
        summary:
          dgettext_noop(
            "scripts",
            "Runs when an AI reply finishes successfully, before it is saved. A stopped or failed reply runs no scripts."
          ),
        fields: [
          {"text", "string",
           dgettext_noop(
             "scripts",
             "The reply's full text. A continue includes the original text before the new part. A script earlier in the run order may already have rewritten it."
           )},
          {"message_id", "string", dgettext_noop("scripts", "The message the reply is written into.")},
          {"character_id", "string",
           {"field label: script event field, the character who spoke",
            dpgettext_noop(
              "scripts",
              "field label: script event field, the character who spoke",
              "The character who spoke."
            )}},
          {"mode", "string", dgettext_noop("scripts", ~s("new", "regenerate", "continue" or "refine".))},
          {"script_triggered", "bool",
           dgettext_noop("scripts", "True when a script started this generation through mw.generation.*.")}
        ],
        returns:
          dgettext_noop(
            "scripts",
            "Return a string to replace the saved text, or nil (or nothing) to keep it. The prompt inspector still shows what the model sent. mw.generation.* is refused here."
          ),
        example: ~S'return (event.text:gsub("%s+$", ""))'
      },
      %{
        trigger: :lore_activated,
        summary:
          dgettext_noop(
            "scripts",
            "Runs when a generation activates lore, after the lore is resolved and before the prompt is sent."
          ),
        fields: [
          {"character_id", "string", dgettext_noop("scripts", "The character about to speak.")},
          {"books", "array of {id, name}",
           dgettext_noop("scripts", "Each book with at least one activated entry, once.")},
          {"entries", "array of {id, name, book_id}",
           dgettext_noop("scripts", "Every activated entry, with the book it activated from.")},
          {"script_triggered", "bool",
           dgettext_noop("scripts", "True when a script started this generation through mw.generation.*.")}
        ],
        returns:
          dgettext_noop(
            "scripts",
            "Return values are ignored. Changes to lore or prompts apply from the next generation, because this one's prompt is already built. mw.generation.* is refused here."
          ),
        example: ~S'for _, e in ipairs(event.entries) do mw.lore.set_entry_enabled(e.book_id, e.id, false) end'
      },
      %{
        trigger: :image_described,
        summary:
          dgettext_noop(
            "scripts",
            "Runs when an image in a chat gets a description: from a caption model, typed by a person, or set by a script outside this trigger. Before replies waiting on the caption read it. Avatars run no scripts. Only the chat owner's own descriptions run them; another member's run none."
          ),
        fields: [
          {"text", "string",
           dgettext_noop(
             "scripts",
             "The new description. A script earlier in the run order may already have rewritten it."
           )},
          {"image_id", "string",
           {"field label: script event field, the image that got a description",
            dpgettext_noop(
              "scripts",
              "field label: script event field, the image that got a description",
              "The described image."
            )}},
          {"message_id", "string | nil",
           dgettext_noop("scripts", "The message the image belongs to, or nil for an image still in the composer.")},
          {"by", "string",
           {"field label: script event field, who wrote the image description",
            dpgettext_noop(
              "scripts",
              "field label: script event field, who wrote the image description",
              ~s("model", "person" or "script".)
            )}},
          {"model_id", "string | nil", dgettext_noop("scripts", "The caption model, when by is \"model\".")},
          {"tag", "string | nil",
           dgettext_noop(
             "scripts",
             "The tag passed to mw.images.caption(id, {tag = ...}) or to the mw.images.request(prompt, {tag = ...}) that brought the image, or nil."
           )},
          {"data", "any",
           dgettext_noop(
             "scripts",
             "The opts.data passed alongside the tag, as given, or nil. Held in memory: nil after a server restart."
           )}
        ],
        returns:
          dgettext_noop(
            "scripts",
            "Return a string to replace the saved description, or nil (or nothing) to keep it; blank is ignored. mw.images.set_description here saves without running this trigger again. mw.generation.* is refused here."
          ),
        example: ~S'return (event.text:gsub("^This image shows ", ""))'
      },
      %{
        trigger: :command,
        summary:
          dgettext_noop(
            "scripts",
            ~S[Runs when picked from the command palette (Cmd-P / Ctrl-P) as "lua: <name>". Declare its inputs with --- comment lines at the very top: "---@param name type Label" (name? for an optional one), other "---" text is the command's description, and other ---@ tags are ignored. Types: string, integer, number, boolean, character, participant, message, lore_book, lore_entry, prompt, prompt_block, model, chat, script, or choices "a"|"b". A participant or message parameter offers the command only in a chat. Other scripts can call it with mw.commands.run(name, args); it then runs with the caller's event and trigger, only event.args replaced, and its return values go back to the caller unchanged.]
          ),
        fields: [
          {"args", "table",
           dgettext_noop(
             "scripts",
             "The parameters by name: text for string and choices, numbers, booleans, and record tables for entities (a character or participant is a character table, a message a message table, a lore book or entry, prompt or prompt block its table, model {id, name, api_model_id, completion_mode}, chat {id, name}, script {id, name, description, trigger, enabled}). A blank optional parameter is nil."
           )}
        ],
        returns:
          dgettext_noop(
            "scripts",
            ~S[Return a string or number to show it as a notice; nil or nothing shows none. Off a chat page chat_id is nil and mw.messages.*, mw.images.*, mw.generation.*, mw.memory.*, mw.vars.*, mw.injections.* and mw.lore.set_chat_bound return nil, "no_chat".]
          ),
        example:
          "---@param who participant Who speaks\nmw.generation.generate(event.args.who.id)\nreturn event.args.who.name .. \" is up\""
      },
      %{
        trigger: :quick_reply,
        summary:
          dgettext_noop(
            "scripts",
            ~S[A button above the chat composer, labelled with the script's name, and a command palette entry "quick reply: <name>". Runs when either is clicked or picked, in a chat with a player character. Buttons are ordered by priority (higher first), then name.]
          ),
        fields: [
          {"text", "string", dgettext_noop("scripts", "What is in the composer when it runs; may be blank.")}
        ],
        returns:
          dgettext_noop(
            "scripts",
            ~S[Return a string to put it in the composer in place of what is there. Return {"message", text} to send text as if typed and sent: templates, {! !} blocks and user_message scripts run, staged images go with it, and the composer is cleared. Return {"clear"} to empty the composer. nil or nothing changes nothing.]
          ),
        example: ~S'return {"message", event.text .. " *waves*"}'
      },
      %{
        trigger: :inline,
        summary:
          dgettext_noop(
            "scripts",
            "Runs once when a message containing {! … !} is sent from the composer; the block is never stored. Blocks run in order; a syntax error in any block blocks the send, and a runtime error stops the send at that block."
          ),
        fields: [
          {"character_id", "string", dgettext_noop("scripts", "The player character sending the message.")},
          {"images", "array of string", dgettext_noop("scripts", "The ids of the images being sent.")},
          {"index", "integer",
           dgettext_noop("scripts", "This block's position among the message's {! !} blocks, from 1.")}
        ],
        returns:
          dgettext_noop(
            "scripts",
            "Return a string or number to put in the block's place, or nothing (or nil) to remove the block. If the whole message is then blank and has no images, nothing is posted."
          ),
        example:
          ~S'for _, m in ipairs(mw.messages.list()) do if m.character_id == event.character_id then mw.messages.set_visible(m.id, false) end end'
      }
    ]

    {common_event_fields, event_reference}
  end
end
