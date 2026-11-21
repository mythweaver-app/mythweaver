defmodule MythweaverWeb.CommandPalette.Commands do
  @moduledoc """
  The command palette's commands: the open chat's actions, then navigation to every screen, then
  one `lua: <name>` command per enabled command script (`Mythweaver.Scripts.list_commands/1`), then
  one `quick reply: <name>` command per enabled quick reply script on a chat page.
  Chat commands reuse `MainChatLive`'s own events, so they act exactly as its buttons do.
  """

  use MythweaverWeb, :verified_routes
  use Gettext, backend: Mythweaver.Gettext

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Chats.Chat
  alias Mythweaver.Messages
  alias Mythweaver.Messages.Cleanup
  alias Mythweaver.Scripts
  alias MythweaverWeb.CommandPalette.Command

  # Which global commands a non-admin may run: chats, jobs and settings always; the AI editors'
  # commands per `MythweaverWeb.AIAccess`; every other editor's per `MythweaverWeb.ContentAccess`.
  @user_command_ids ~w(chats.open chat.switch jobs.open settings.open)
  @ai_command_ids ~w(ai_providers.open ai_provider.new ai_provider.edit ai_models.open ai_model.new ai_model.edit)

  @doc """
  Every command available to `scope` with `chat` open (`nil` off a chat page), in display order.
  An assistant thread gets no chat or quick reply commands: they act on role-play chats.
  """
  @spec list(Scope.t(), Chat.t() | nil) :: [Command.t()]
  def list(%Scope{} = scope, chat) do
    chat_commands = if roleplay?(chat), do: chat_commands(scope), else: []

    chat_commands ++
      global_commands(scope) ++
      cleanup_commands(scope) ++ script_commands(scope, chat) ++ quick_reply_commands(scope, chat)
  end

  @doc "The built-in command `id` taking no params (`chat` `nil` off a chat page), or `nil`."
  @spec get(Scope.t(), Chat.t() | nil, String.t()) :: Command.t() | nil
  def get(%Scope{} = scope, chat, id) do
    chat_commands = if roleplay?(chat), do: chat_commands(scope), else: []
    Enum.find(chat_commands ++ global_commands(scope) ++ cleanup_commands(scope), &(&1.id == id and &1.params == []))
  end

  defp roleplay?(%Chat{kind: :roleplay}), do: true
  defp roleplay?(_chat), do: false

  defp chat_commands(scope) do
    [
      chat_event("chat.new", dpgettext("commands", "command palette entry (area: action)", "chat: new"), "new_chat"),
      chat_nav(
        "chat.settings",
        dpgettext("commands", "command palette entry (area: action)", "chat: settings"),
        &~p"/chats/#{&1.id}/settings"
      ),
      chat_nav(
        "chat.memory",
        dpgettext("commands", "command palette entry (area: action)", "chat: memory"),
        &~p"/chats/#{&1.id}/memory"
      ),
      chat_event(
        "chat.memory.create",
        dpgettext("commands", "command palette entry (area: action)", "chat: create memory"),
        "bulk_create_memory"
      ),
      chat_command(
        "chat.memory.scene",
        dpgettext("commands", "command palette entry (area: action)", "chat: create scene memory"),
        [
          integer(
            "start",
            dpgettext("commands", "field label: parameter of the palette command chat: create scene memory", "Start")
          ),
          integer(
            "end",
            dpgettext("commands", "field label: parameter of the palette command chat: create scene memory", "End")
          )
        ],
        fn values, chat ->
          with {:ok, [start, finish]} <- message_range(values["start"], values["end"]),
               do: {:navigate, ~p"/chats/#{chat.id}/memory?start=#{start}&end=#{finish}"}
        end
      ),
      chat_nav(
        "chat.memory.consolidate",
        dpgettext("commands", "command palette entry (area: action)", "chat: consolidate memories"),
        &~p"/chats/#{&1.id}/memory?tab=consolidate"
      ),
      chat_event(
        "chat.memory.next",
        dpgettext("commands", "command palette entry (area: action)", "chat: create next memory"),
        "memory_next"
      ),
      chat_command(
        "chat.memory.catchup",
        dpgettext("commands", "command palette entry (area: action)", "chat: catch up memories"),
        [
          integer(
            "start",
            dpgettext("commands", "field label: parameter of the palette command chat: catch up memories", "Start")
          ),
          integer(
            "end",
            dpgettext("commands", "field label: parameter of the palette command chat: catch up memories", "End")
          ),
          integer(
            "chunk",
            dpgettext("commands", "field label: parameter of the palette command chat: catch up memories", "Chunk size")
          )
        ],
        fn values, chat ->
          with {:ok, [start, finish]} <- message_range(values["start"], values["end"]),
               {:ok, chunk} <- chunk_size(values["chunk"]) do
            {:navigate,
             ~p"/chats/#{chat.id}/memory?catchup_start=#{start}&catchup_end=#{finish}&catchup_chunk=#{chunk}"}
          end
        end
      ),
      chat_command(
        "chat.memory.run_side_prompt",
        dpgettext("commands", "command palette entry (area: action)", "chat: run side prompt"),
        [
          ref(
            :side_prompt,
            dpgettext("commands", "field label: parameter of the palette command chat: run side prompt", "Side prompt")
          ),
          optional_integer(
            "start",
            dpgettext("commands", "field label: parameter of the palette command chat: run side prompt", "Start")
          ),
          optional_integer(
            "end",
            dpgettext("commands", "field label: parameter of the palette command chat: run side prompt", "End")
          )
        ],
        fn values, chat ->
          with {:ok, [start, finish]} <- message_range(values["start"], values["end"]) do
            {:navigate,
             ~p"/chats/#{chat.id}/memory?tab=side&side_prompt_id=#{values["item"]}&side_start=#{start}&side_end=#{finish}"}
          end
        end
      ),
      chat_command(
        "chat.memory.enable_side_prompt",
        dpgettext("commands", "command palette entry (area: action)", "chat: enable side prompt"),
        [
          ref(
            :side_prompt,
            dpgettext(
              "commands",
              "field label: parameter of the palette command chat: enable side prompt",
              "Side prompt"
            )
          )
        ],
        fn %{"item" => id}, _chat ->
          {:chat_event, "memory_set_side_prompt_enabled", %{"id" => id, "enabled" => "true"}}
        end
      ),
      chat_command(
        "chat.memory.disable_side_prompt",
        dpgettext("commands", "command palette entry (area: action)", "chat: disable side prompt"),
        [
          ref(
            :side_prompt,
            dpgettext(
              "commands",
              "field label: parameter of the palette command chat: disable side prompt",
              "Side prompt"
            )
          )
        ],
        fn %{"item" => id}, _chat ->
          {:chat_event, "memory_set_side_prompt_enabled", %{"id" => id, "enabled" => "false"}}
        end
      ),
      chat_event(
        "chat.memory.enable_all_side_prompts",
        dpgettext("commands", "command palette entry (area: action)", "chat: enable all side prompts"),
        "memory_enable_all_side_prompts"
      ),
      chat_event(
        "chat.memory.disable_all_side_prompts",
        dpgettext("commands", "command palette entry (area: action)", "chat: disable all side prompts"),
        "memory_disable_all_side_prompts"
      ),
      chat_event(
        "chat.memory.highest",
        dpgettext("commands", "command palette entry (area: action)", "chat: show processed boundary"),
        "memory_show_highest"
      ),
      chat_command(
        "chat.memory.set_highest",
        dpgettext("commands", "command palette entry (area: action)", "chat: set processed boundary"),
        [
          integer(
            "number",
            dpgettext(
              "commands",
              "field label: parameter of the palette command chat: set processed boundary",
              "Message number"
            )
          )
        ],
        fn values, _chat ->
          with {:ok, [number]} <- message_numbers([values["number"]]),
               do: {:chat_event, "memory_set_highest", %{"number" => number}}
        end
      ),
      chat_event(
        "chat.memory.clear_highest",
        dpgettext("commands", "command palette entry (area: action)", "chat: clear processed boundary"),
        "memory_clear_highest"
      ),
      chat_event(
        "chat.variables",
        dpgettext("commands", "command palette entry (area: action)", "chat: variables"),
        "open_chat_variables"
      ),
      chat_event(
        "chat.injections",
        dpgettext("commands", "command palette entry (area: action)", "chat: injections"),
        "open_chat_injections"
      ),
      chat_event(
        "chat.queue",
        dpgettext("commands", "command palette entry (area: action)", "chat: turn queue"),
        "open_queue"
      ),
      chat_event(
        "chat.auto_mode",
        dpgettext("commands", "command palette entry (area: action)", "chat: toggle auto mode"),
        "toggle_auto_mode"
      ),
      chat_event(
        "chat.stop",
        dpgettext("commands", "command palette entry (area: action)", "chat: stop generation"),
        "stop_generation"
      ),
      chat_command(
        "chat.generate",
        dpgettext("commands", "command palette entry (area: action)", "chat: generate reply"),
        [
          ref(
            :participant,
            dpgettext("commands", "field label: parameter of the palette command chat: generate reply", "Speaker")
          )
        ],
        fn %{"item" => v}, _chat -> {:chat_event, "generate_reply", %{"character_id" => v}} end
      ),
      chat_command(
        "chat.regenerate",
        dpgettext("commands", "command palette entry (area: action)", "chat: regenerate last reply"),
        [],
        fn _values, chat -> last_message_event(scope, chat, "regenerate") end
      ),
      chat_command(
        "chat.continue",
        dpgettext("commands", "command palette entry (area: action)", "chat: continue last reply"),
        [],
        fn _values, chat -> last_message_event(scope, chat, "continue") end
      ),
      chat_command(
        "chat.refine",
        dpgettext(
          "commands",
          "command palette entry (area: action)",
          "chat: rewrite last reply with the composer text"
        ),
        [],
        fn _values, chat -> last_message_event(scope, chat, "refine_message") end
      ),
      chat_command(
        "chat.edit_last",
        dpgettext("commands", "command palette entry (area: action)", "chat: edit last message"),
        [],
        fn _values, chat -> last_message_event(scope, chat, "edit_message") end
      ),
      chat_command(
        "chat.expression.set",
        dpgettext("commands", "command palette entry (area: action)", "chat: set expression of last message"),
        [
          %{
            name: "expression",
            label:
              dpgettext(
                "commands",
                "field label: parameter of the palette command chat: set expression of last message",
                "Expression (blank: portrait)"
              ),
            type: :string,
            optional?: true,
            choices: nil
          }
        ],
        fn values, chat ->
          with {:chat_event, _, %{"message_id" => id}} <- last_message_event(scope, chat, "set_expression"),
               do: {:chat_event, "set_expression", %{"message_id" => id, "expression" => values["expression"] || ""}}
        end
      ),
      chat_command(
        "chat.expression.reclassify",
        dpgettext("commands", "command palette entry (area: action)", "chat: classify last message's expression again"),
        [],
        fn _v, chat -> last_message_event(scope, chat, "reclassify_expression") end
      ),
      chat_command(
        "chat.expression.outfit",
        dpgettext("commands", "command palette entry (area: action)", "chat: change outfit"),
        [
          ref(
            :participant,
            dpgettext("commands", "field label: parameter of the palette command chat: change outfit", "Character")
          )
        ],
        fn %{"item" => v}, chat ->
          case Enum.find(chat.participants, &(&1.character_id == v)) do
            nil -> not_participant()
            participant -> {:chat_event, "open_participant_settings", %{"id" => participant.id}}
          end
        end
      ),
      chat_command(
        "chat.edit_last_player",
        dpgettext("commands", "command palette entry (area: action)", "chat: edit last player message"),
        [],
        fn _values, chat ->
          case Messages.last_player_message(scope, chat) do
            nil -> no_player_message()
            message -> {:chat_event, "edit_message", %{"message_id" => message.id}}
          end
        end
      ),
      chat_command(
        "chat.swipe_prev",
        dpgettext("commands", "command palette entry (area: action)", "chat: previous swipe"),
        [],
        fn _values, chat -> last_message_event(scope, chat, "swipe_prev") end
      ),
      chat_command(
        "chat.swipe_next",
        dpgettext("commands", "command palette entry (area: action)", "chat: next swipe"),
        [],
        fn _values, chat -> swipe_next(scope, chat) end
      ),
      chat_event(
        "chat.jump_latest",
        dpgettext("commands", "command palette entry (area: action)", "chat: jump to latest"),
        "jump_to_latest"
      ),
      chat_command(
        "chat.jump",
        dpgettext("commands", "command palette entry (area: action)", "chat: go to message"),
        [
          integer(
            "number",
            dpgettext("commands", "field label: parameter of the palette command chat: go to message", "Message number")
          )
        ],
        fn values, _chat ->
          with {:ok, [number]} <- message_numbers([values["number"]]),
               do: {:chat_event, "jump_to_message", %{"number" => number}}
        end
      ),
      chat_event(
        "chat.describe_attachments",
        dpgettext("commands", "command palette entry (area: action)", "chat: describe all attachments"),
        "describe_all_attachments"
      ),
      chat_command(
        "chat.caption",
        dpgettext("commands", "command palette entry (area: action)", "chat: caption image"),
        [
          %{
            name: "image",
            label: dpgettext("commands", "field label: parameter of the palette command chat: caption image", "Image"),
            type: :image,
            optional?: false,
            choices: nil
          },
          %{
            name: "prompt",
            label: dpgettext("commands", "field label: parameter of the palette command chat: caption image", "Prompt"),
            type: :string,
            optional?: true,
            choices: nil
          }
        ],
        fn values, _chat ->
          {:chat_event, "caption_image", %{"attachment_id" => values["image"], "prompt" => values["prompt"]}}
        end
      ),
      chat_command(
        "chat.play_as",
        dpgettext("commands", "command palette entry (area: action)", "chat: play as"),
        [ref(:bot, dpgettext("commands", "field label: parameter of the palette command chat: play as", "Character"))],
        fn %{"item" => v}, _chat -> {:chat_event, "play_as", %{"character_id" => v}} end
      ),
      chat_event(
        "chat.add_participants",
        dpgettext("commands", "command palette entry (area: action)", "chat: add participants"),
        "open_add_participant"
      ),
      # Toggle mute lists bots in panel order with muted ones in place, unlike the other pickers.
      chat_command(
        "chat.toggle_mute",
        dpgettext("commands", "command palette entry (area: action)", "chat: toggle mute"),
        [
          Map.put(
            ref(
              :bot,
              dpgettext("commands", "field label: parameter of the palette command chat: toggle mute", "Participant")
            ),
            :panel_order?,
            true
          )
        ],
        fn %{"item" => v}, chat ->
          case Enum.find(chat.participants, &(&1.character_id == v)) do
            nil -> not_participant()
            participant -> {:chat_event, "toggle_mute", %{"id" => participant.id}}
          end
        end
      ),
      chat_event(
        "chat.toggle_mute_all",
        dpgettext("commands", "command palette entry (area: action)", "chat: toggle mute shown characters"),
        "toggle_mute_all"
      ),
      chat_event(
        "chat.toggle_muted_visibility",
        dpgettext("commands", "command palette entry (area: action)", "chat: toggle muted participants"),
        "toggle_hide_muted"
      ),
      chat_command(
        "chat.show_muted",
        dpgettext("commands", "command palette entry (area: action)", "chat: show muted participants"),
        [],
        fn _values, _chat -> {:chat_event, "set_hide_muted", %{"hide" => false}} end
      ),
      chat_command(
        "chat.hide_muted",
        dpgettext("commands", "command palette entry (area: action)", "chat: hide muted participants"),
        [],
        fn _values, _chat -> {:chat_event, "set_hide_muted", %{"hide" => true}} end
      ),
      chat_command(
        "chat.delete_message",
        dpgettext("commands", "command palette entry (area: action)", "chat: delete message"),
        [
          ref(
            :message,
            dpgettext("commands", "field label: parameter of the palette command chat: delete message", "Message")
          )
        ],
        fn %{"item" => v}, _chat -> {:chat_event, "delete_message", %{"message_id" => v}} end
      ),
      chat_command(
        "chat.toggle_message_visibility",
        dpgettext("commands", "command palette entry (area: action)", "chat: toggle message visibility"),
        [
          ref(
            :message,
            dpgettext(
              "commands",
              "field label: parameter of the palette command chat: toggle message visibility",
              "Message"
            )
          )
        ],
        fn %{"item" => v}, _chat -> {:chat_event, "toggle_message_visibility", %{"message_id" => v}} end
      )
    ]
  end

  defp global_commands(scope), do: Enum.filter(global_commands(), &command_allowed?(scope, &1.id))

  # Outside `global_commands/0`: their `run` needs the scope.
  defp cleanup_commands(scope) do
    mine = %Command{
      id: "cleanup.mine",
      title: dpgettext("commands", "command palette entry (area: action)", "cleanup: my chats"),
      run: fn _values, _chat ->
        {:task, fn -> {:ok, scope |> Cleanup.clean_up_mine() |> elem(1) |> Cleanup.summary()} end}
      end
    }

    all = %Command{
      id: "cleanup.all",
      title: dpgettext("commands", "command palette entry (area: action)", "cleanup: all chats"),
      run: fn _values, _chat -> {:task, fn -> cleanup_all(scope) end} end
    }

    if Scope.can?(scope, "site.cleanup.run"), do: [mine, all], else: [mine]
  end

  defp cleanup_all(scope) do
    case Cleanup.clean_up_all(scope) do
      {:ok, stats} ->
        {:ok, Cleanup.summary(stats)}

      {:error, :unauthorized} ->
        gettext_comment("Error flash when someone without the site cleanup permission runs \"cleanup: all chats\".")
        {:error, dgettext("commands", "You can't clean up every user's chats.")}
    end
  end

  defp command_allowed?(_scope, id) when id in @user_command_ids, do: true
  defp command_allowed?(scope, id) when id in @ai_command_ids, do: MythweaverWeb.AIAccess.allowed?(scope)

  defp command_allowed?(scope, id) when id in ["import.open", "export.open"],
    do: MythweaverWeb.ContentAccess.any?(scope)

  defp command_allowed?(scope, id) do
    case command_area(id) do
      nil -> false
      area -> MythweaverWeb.ContentAccess.allowed?(scope, area)
    end
  end

  defp command_area("characters." <> _), do: :characters
  defp command_area("character." <> _), do: :characters
  defp command_area("lore" <> _), do: :lore
  defp command_area("prompt" <> _), do: :prompts
  defp command_area("variable" <> _), do: :variables
  defp command_area("script" <> _), do: :scripts
  defp command_area("memory_profile" <> _), do: :memory
  defp command_area("side_prompt" <> _), do: :memory
  defp command_area("tag" <> _), do: :tags
  defp command_area(_id), do: nil

  defp global_commands do
    [
      nav("chats.open", dpgettext("commands", "command palette entry (area: action)", "chats: open"), ~p"/"),
      edit(
        "chat.switch",
        dpgettext("commands", "command palette entry (area: action)", "chat: switch"),
        ref(:chat, dpgettext("commands", "field label: parameter of the palette command chat: switch", "Chat")),
        &~p"/chats/#{&1}"
      ),
      nav(
        "characters.open",
        dpgettext("commands", "command palette entry (area: action)", "characters: open"),
        ~p"/characters"
      ),
      nav("import.open", dpgettext("commands", "command palette entry (area: action)", "import: open"), ~p"/import"),
      nav(
        "submissions.open",
        dpgettext("commands", "command palette entry (area: action)", "submissions: open"),
        ~p"/submissions"
      ),
      nav("export.open", dpgettext("commands", "command palette entry (area: action)", "export: open"), ~p"/export"),
      nav(
        "character.new",
        dpgettext("commands", "command palette entry (area: action)", "character: new"),
        ~p"/characters/new"
      ),
      edit(
        "character.edit",
        dpgettext("commands", "command palette entry (area: action)", "character: edit"),
        ref(
          :character,
          dpgettext("commands", "field label: parameter of the palette command character: edit", "Character")
        ),
        &~p"/characters/#{&1}/edit"
      ),
      nav("lore.open", dpgettext("commands", "command palette entry (area: action)", "lore: open"), ~p"/lore"),
      nav(
        "lore_book.new",
        dpgettext("commands", "command palette entry (area: action)", "lore book: new"),
        ~p"/lore/new"
      ),
      edit(
        "lore_book.edit",
        dpgettext("commands", "command palette entry (area: action)", "lore book: edit"),
        ref(
          :lore_book,
          dpgettext("commands", "field label: parameter of the palette command lore book: edit", "Lore book")
        ),
        &~p"/lore/#{&1}/edit"
      ),
      nav(
        "lore_entry.new",
        dpgettext("commands", "command palette entry (area: action)", "lore entry: new"),
        ~p"/lore/entries/new"
      ),
      edit(
        "lore_entry.edit",
        dpgettext("commands", "command palette entry (area: action)", "lore entry: edit"),
        ref(
          :lore_entry,
          dpgettext("commands", "field label: parameter of the palette command lore entry: edit", "Lore entry")
        ),
        &~p"/lore/entries/#{&1}/edit"
      ),
      nav(
        "lore_pools.open",
        dpgettext("commands", "command palette entry (area: action)", "lore pools: open"),
        ~p"/lore/pools"
      ),
      nav(
        "lore_pool.new",
        dpgettext("commands", "command palette entry (area: action)", "lore pool: new"),
        ~p"/lore/pools/new"
      ),
      nav("prompts.open", dpgettext("commands", "command palette entry (area: action)", "prompts: open"), ~p"/prompts"),
      nav("prompt.new", dpgettext("commands", "command palette entry (area: action)", "prompt: new"), ~p"/prompts/new"),
      edit(
        "prompt.edit",
        dpgettext("commands", "command palette entry (area: action)", "prompt: edit"),
        ref(:prompt, dpgettext("commands", "field label: parameter of the palette command prompt: edit", "Prompt")),
        &~p"/prompts/#{&1}/edit"
      ),
      nav(
        "prompt_blocks.open",
        dpgettext("commands", "command palette entry (area: action)", "prompt blocks: open"),
        ~p"/prompts/blocks"
      ),
      nav(
        "prompt_block.new",
        dpgettext("commands", "command palette entry (area: action)", "prompt block: new"),
        ~p"/prompts/blocks/new"
      ),
      edit(
        "prompt_block.edit",
        dpgettext("commands", "command palette entry (area: action)", "prompt block: edit"),
        ref(
          :prompt_block,
          dpgettext("commands", "field label: parameter of the palette command prompt block: edit", "Prompt block")
        ),
        &~p"/prompts/blocks/#{&1}/edit"
      ),
      nav(
        "prompt_outlets.open",
        dpgettext("commands", "command palette entry (area: action)", "prompt outlets: open"),
        ~p"/prompts/outlets"
      ),
      nav(
        "prompt_outlet.new",
        dpgettext("commands", "command palette entry (area: action)", "prompt outlet: new"),
        ~p"/prompts/outlets/new"
      ),
      nav(
        "expression_profiles.open",
        dpgettext("commands", "command palette entry (area: action)", "expression rules: open"),
        ~p"/characters/expression-profiles"
      ),
      nav(
        "expression_profile.new",
        dpgettext("commands", "command palette entry (area: action)", "expression rules: new"),
        ~p"/characters/expression-profiles/new"
      ),
      edit(
        "prompt_outlet.edit",
        dpgettext("commands", "command palette entry (area: action)", "prompt outlet: edit"),
        ref(
          :prompt_outlet,
          dpgettext("commands", "field label: parameter of the palette command prompt outlet: edit", "Outlet")
        ),
        &~p"/prompts/outlets/#{&1}/edit"
      ),
      nav(
        "ai_providers.open",
        dpgettext("commands", "command palette entry (area: action)", "ai providers: open"),
        ~p"/ai/providers"
      ),
      nav(
        "ai_provider.new",
        dpgettext("commands", "command palette entry (area: action)", "ai provider: new"),
        ~p"/ai/providers/new"
      ),
      edit(
        "ai_provider.edit",
        dpgettext("commands", "command palette entry (area: action)", "ai provider: edit"),
        ref(
          :ai_provider,
          dpgettext("commands", "field label: parameter of the palette command ai provider: edit", "Provider")
        ),
        &~p"/ai/providers/#{&1}/edit"
      ),
      nav(
        "ai_models.open",
        dpgettext("commands", "command palette entry (area: action)", "ai models: open"),
        ~p"/ai/models"
      ),
      nav(
        "ai_model.new",
        dpgettext("commands", "command palette entry (area: action)", "ai model: new"),
        ~p"/ai/models/new"
      ),
      edit(
        "ai_model.edit",
        dpgettext("commands", "command palette entry (area: action)", "ai model: edit"),
        ref(:model, dpgettext("commands", "field label: parameter of the palette command ai model: edit", "Model")),
        &~p"/ai/models/#{&1}/edit"
      ),
      nav(
        "variables.open",
        dpgettext("commands", "command palette entry (area: action)", "variables: open"),
        ~p"/variables"
      ),
      nav(
        "variable.new",
        dpgettext("commands", "command palette entry (area: action)", "variable: new"),
        ~p"/variables/new"
      ),
      edit(
        "variable.edit",
        dpgettext("commands", "command palette entry (area: action)", "variable: edit"),
        ref(
          :global_variable,
          dpgettext("commands", "field label: parameter of the palette command variable: edit", "Variable")
        ),
        &~p"/variables/#{&1}/edit"
      ),
      nav("scripts.open", dpgettext("commands", "command palette entry (area: action)", "scripts: open"), ~p"/scripts"),
      nav("script.new", dpgettext("commands", "command palette entry (area: action)", "script: new"), ~p"/scripts/new"),
      edit(
        "script.edit",
        dpgettext("commands", "command palette entry (area: action)", "script: edit"),
        ref(:script, dpgettext("commands", "field label: parameter of the palette command script: edit", "Script")),
        &~p"/scripts/#{&1}/edit"
      ),
      nav("tags.open", dpgettext("commands", "command palette entry (area: action)", "tags: open"), ~p"/tags"),
      nav("tag.new", dpgettext("commands", "command palette entry (area: action)", "tag: new"), ~p"/tags/new"),
      edit(
        "tag.edit",
        dpgettext("commands", "command palette entry (area: action)", "tag: edit"),
        ref(:tag, dpgettext("commands", "field label: parameter of the palette command tag: edit", "Tag")),
        &~p"/tags/#{&1}/edit"
      ),
      nav("jobs.open", dpgettext("commands", "command palette entry (area: action)", "jobs: open"), ~p"/jobs"),
      nav(
        "memory_profiles.open",
        dpgettext("commands", "command palette entry (area: action)", "memory profiles: open"),
        ~p"/memory/profiles"
      ),
      nav(
        "memory_profile.new",
        dpgettext("commands", "command palette entry (area: action)", "memory profile: new"),
        ~p"/memory/profiles/new"
      ),
      edit(
        "memory_profile.edit",
        dpgettext("commands", "command palette entry (area: action)", "memory profile: edit"),
        ref(
          :memory_profile,
          dpgettext("commands", "field label: parameter of the palette command memory profile: edit", "Profile")
        ),
        &~p"/memory/profiles/#{&1}/edit"
      ),
      nav(
        "side_prompts.open",
        dpgettext("commands", "command palette entry (area: action)", "side prompts: open"),
        ~p"/memory/side-prompts"
      ),
      nav(
        "side_prompt.new",
        dpgettext("commands", "command palette entry (area: action)", "side prompt: new"),
        ~p"/memory/side-prompts/new"
      ),
      edit(
        "side_prompt.edit",
        dpgettext("commands", "command palette entry (area: action)", "side prompt: edit"),
        ref(
          :side_prompt,
          dpgettext("commands", "field label: parameter of the palette command side prompt: edit", "Side prompt")
        ),
        &~p"/memory/side-prompts/#{&1}/edit"
      ),
      nav(
        "settings.open",
        dpgettext("commands", "command palette entry (area: action)", "settings: open"),
        ~p"/settings"
      )
    ]
  end

  defp script_commands(scope, chat) do
    bound = Scripts.Command.chat_bound_types()

    Enum.flat_map(Scripts.list_commands(scope), fn %{script: script, description: description, params: params} ->
      chat? = Enum.any?(params, &(&1.type in bound))

      if chat? and chat == nil do
        []
      else
        [
          %Command{
            id: "script:" <> script.id,
            title:
              dpgettext("commands", "command palette entry (area: action)", "lua: %{script_name}",
                script_name: script.name
              ),
            description: description,
            params: params,
            chat?: chat?,
            run: fn _values, _chat -> {:script, script.id} end
          }
        ]
      end
    end)
  end

  # The composer hook supplies the text (`quick_reply:collect`), as a toolbar click does.
  defp quick_reply_commands(_scope, chat) when not is_struct(chat, Chat), do: []
  defp quick_reply_commands(_scope, %Chat{kind: kind}) when kind != :roleplay, do: []

  defp quick_reply_commands(scope, _chat) do
    for script <- Scripts.list_quick_replies(scope) do
      %Command{
        id: "quick_reply:" <> script.id,
        title:
          dpgettext("commands", "command palette entry (area: action)", "quick reply: %{script_name}",
            script_name: script.name
          ),
        description: script.description,
        chat?: true,
        run: fn _values, _chat -> {:chat_event, "quick_reply", %{"id" => script.id}} end
      }
    end
  end

  # Message positions are int4 columns, so a display number past that would fail in the database.
  @max_message 2_147_483_647

  # The palette hands built-in commands its raw text; blank optional values stay nil.
  defp message_numbers(values) do
    numbers = Enum.map(values, &parse_number/1)
    if :error in numbers, do: message_number_error(), else: {:ok, numbers}
  end

  defp message_number_error do
    gettext_comment("Error flash when a palette command gets a message number that is not a whole number from 1 up.")
    {:error, dgettext("commands", "Message numbers start at 1.")}
  end

  defp message_range(start, finish) do
    with {:ok, [first, last]} <- message_numbers([start, finish]) do
      if first && last && first > last, do: range_error(), else: {:ok, [first, last]}
    end
  end

  defp range_error do
    gettext_comment(
      "Error flash when a palette command's Start message number is greater than its End; Start and End are the parameter labels."
    )

    {:error, dgettext("commands", "Start must not be after End.")}
  end

  defp chunk_size(value) do
    case parse_number(value) do
      n when is_integer(n) and n in 5..250 ->
        {:ok, n}

      _ ->
        gettext_comment("Error flash when the palette command \"chat: catch up memories\" gets a bad Chunk size.")
        {:error, dgettext("commands", "Chunk size must be 5 to 250 messages.")}
    end
  end

  defp parse_number(value) do
    case String.trim(to_string(value || "")) do
      "" ->
        nil

      text ->
        case Integer.parse(text) do
          {n, ""} when n in 1..@max_message//1 -> n
          _ -> :error
        end
    end
  end

  defp ref(type, label), do: %{name: "item", label: label, type: type, optional?: false, choices: nil}
  defp integer(name, label), do: %{name: name, label: label, type: :integer, optional?: false, choices: nil}
  defp optional_integer(name, label), do: %{name: name, label: label, type: :integer, optional?: true, choices: nil}

  defp nav(id, title, path), do: %Command{id: id, title: title, run: fn _values, _chat -> {:navigate, path} end}

  # `editable?`: an editor opens only rows the viewer may edit, so its picker suggests only those
  # (`Suggestions.candidates/3`), where a script parameter of the same type takes any usable row.
  defp edit(id, title, param, path) do
    %Command{
      id: id,
      title: title,
      params: [Map.put(param, :editable?, true)],
      run: fn %{"item" => v}, _chat -> {:navigate, path.(v)} end
    }
  end

  defp chat_command(id, title, params, run), do: %Command{id: id, title: title, params: params, chat?: true, run: run}

  defp chat_event(id, title, event), do: chat_command(id, title, [], fn _values, _chat -> {:chat_event, event, %{}} end)

  defp chat_nav(id, title, path), do: chat_command(id, title, [], fn _values, chat -> {:navigate, path.(chat)} end)

  defp last_message_event(scope, chat, event) do
    case Messages.list_messages_page(scope, chat, limit: 1) do
      {[message], _more?} -> {:chat_event, event, %{"message_id" => message.id}}
      {[], _more?} -> no_messages()
    end
  end

  # Right on the newest swipe of a character reply makes a new swipe, as in SillyTavern.
  defp swipe_next(scope, chat) do
    case Messages.list_messages_page(scope, chat, limit: 1) do
      {[], _more?} ->
        no_messages()

      {[message], _more?} ->
        if message.author_is_character and List.last(message.bodies).active,
          do: {:chat_event, "regenerate", %{"message_id" => message.id}},
          else: {:chat_event, "swipe_next", %{"message_id" => message.id}}
    end
  end

  defp no_messages do
    gettext_comment("Error flash when a palette command acts on the last message of a chat that has none.")
    {:error, dgettext("commands", "This chat has no messages yet.")}
  end

  defp not_participant do
    gettext_comment("Error flash when a palette command names a character who is not in the open chat.")
    {:error, dgettext("commands", "Not a participant of this chat.")}
  end

  defp no_player_message do
    gettext_comment("Error flash when \"chat: edit last player message\" runs before the player has sent anything.")
    {:error, dgettext("commands", "You haven't sent a message in this chat yet.")}
  end
end
