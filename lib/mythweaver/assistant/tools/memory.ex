defmodule Mythweaver.Assistant.Tools.Memory do
  @moduledoc """
  Assistant tools over `Mythweaver.Memory` (Memory Books): memory profiles, side prompts, side
  prompt sets and a role-play chat's memory settings. Memory runs themselves are not tools.
  """

  alias Mythweaver.Assistant.Paths
  alias Mythweaver.Assistant.Tool
  alias Mythweaver.Assistant.Tools.Args
  alias Mythweaver.Assistant.Tools.Batch
  alias Mythweaver.Assistant.Tools.Preview
  alias Mythweaver.Chats
  alias Mythweaver.Chats.Chat
  alias Mythweaver.Memory
  alias Mythweaver.Repo

  @activation ~w(keyword constant vector)
  @outlets ~w(character examples author_note at_depth custom)
  @placements ~w(before after)

  @profile_keys ~w(name ai_model_id memory_prompt_id group_memory_prompt_id consolidation_prompt_id compaction_prompt_id
                   topical_clip_prompt_id character_memory_prompt_id clip_review_prompt_id clip_suggestions_prompt_id
                   combine_clips_prompt_id temperature max_tokens structured_output title_format consolidation_title_format
                   activation outlet placement custom_outlet depth order_mode order prevent_recursion exclude_recursion
                   character_aware)
  @side_prompt_keys ~w(name prompt_id enabled run_after_memory run_on_interval interval previous_memories use_context
                       target_book_id title keywords activation outlet placement custom_outlet depth order
                       prevent_recursion exclude_recursion ignore_budget profile_id save_versions macros)
  @set_keys ~w(name rows)
  @chat_settings_keys ~w(memory_book_id profile_id auto_enabled auto_trigger auto_interval auto_buffer auto_token_threshold
                         auto_hide leave_unhidden context_entry_ids side_prompt_book_ids character_book_ids cast_ids
                         side_prompt_set_mode side_prompt_set_id)

  @id %{"type" => "string", "description" => "Id."}
  @strings %{"type" => "array", "items" => %{"type" => "string"}}

  @entry_props %{
    "activation" => %{"type" => "string", "enum" => @activation, "description" => "How the written entries activate."},
    "outlet" => %{"type" => "string", "enum" => @outlets, "description" => "Where the written entries are injected."},
    "placement" => %{"type" => "string", "enum" => @placements},
    "custom_outlet" => %{
      "type" => "string",
      "description" => "The custom outlet's key, required when outlet is custom."
    },
    "depth" => %{"type" => "integer", "description" => "Message depth, for outlet at_depth."},
    "order" => %{"type" => "integer", "minimum" => 0, "description" => "The written entries' order in their book."},
    "prevent_recursion" => %{"type" => "boolean"},
    "exclude_recursion" => %{"type" => "boolean"}
  }

  @profile_props Map.merge(@entry_props, %{
                   "name" => %{"type" => "string", "description" => "Profile name."},
                   "ai_model_id" => %{"type" => "string", "description" => "Model id the memory runs use."},
                   "memory_prompt_id" => %{"type" => "string", "description" => "A memory-purpose prompt id."},
                   "group_memory_prompt_id" => %{
                     "type" => "string",
                     "description" => "A group-memory-purpose prompt id."
                   },
                   "consolidation_prompt_id" => %{
                     "type" => "string",
                     "description" => "A consolidation-purpose prompt id."
                   },
                   "compaction_prompt_id" => %{"type" => "string", "description" => "A compaction-purpose prompt id."},
                   "topical_clip_prompt_id" => %{
                     "type" => "string",
                     "description" => "A topical-clip-purpose prompt id."
                   },
                   "character_memory_prompt_id" => %{
                     "type" => "string",
                     "description" => "A character-memory-purpose prompt id."
                   },
                   "clip_review_prompt_id" => %{"type" => "string", "description" => "A clip-review-purpose prompt id."},
                   "clip_suggestions_prompt_id" => %{
                     "type" => "string",
                     "description" => "A clip-suggestions-purpose prompt id."
                   },
                   "combine_clips_prompt_id" => %{
                     "type" => "string",
                     "description" => "A combine-clips-purpose prompt id."
                   },
                   "temperature" => %{"type" => "number"},
                   "max_tokens" => %{
                     "type" => "integer",
                     "minimum" => 0,
                     "description" => "0 uses the model's own limit."
                   },
                   "structured_output" => %{"type" => "boolean", "description" => "Ask for a JSON reply."},
                   "title_format" => %{
                     "type" => "string",
                     "description" => "Memory entry title, e.g. [000] - {{title}}."
                   },
                   "consolidation_title_format" => %{"type" => "string"},
                   "order_mode" => %{"type" => "string", "enum" => ~w(auto manual)},
                   "character_aware" => %{
                     "type" => "boolean",
                     "description" => "Memories note which characters were present."
                   }
                 })

  @side_prompt_props Map.merge(@entry_props, %{
                       "name" => %{"type" => "string"},
                       "prompt_id" => %{"type" => "string", "description" => "A side-prompt-purpose prompt id."},
                       "enabled" => %{"type" => "boolean"},
                       "run_after_memory" => %{"type" => "boolean", "description" => "Runs after each memory is made."},
                       "run_on_interval" => %{"type" => "boolean", "description" => "Runs every interval messages."},
                       "interval" => %{"type" => "integer", "minimum" => 1},
                       "previous_memories" => %{"type" => "integer", "minimum" => 0, "maximum" => 7},
                       "use_context" => %{"type" => "boolean"},
                       "target_book_id" => %{
                         "type" => "string",
                         "description" => "Book written to; unset is the chat's memory book."
                       },
                       "title" => %{
                         "type" => "string",
                         "description" => "Entry title; unset is the side prompt's name."
                       },
                       "keywords" => @strings,
                       "ignore_budget" => %{"type" => "boolean"},
                       "profile_id" => %{
                         "type" => "string",
                         "description" => "Overrides the chat's memory profile for the model."
                       },
                       "save_versions" => %{"type" => "boolean"},
                       "macros" =>
                         Map.put(
                           @strings,
                           "description",
                           "Lowercase letters, digits, underscores; the Liquid macro names this prompt uses."
                         )
                     })

  @row_item %{
    "type" => "object",
    "properties" => %{
      "side_prompt_id" => %{"type" => "string", "description" => "Side prompt id for this row."},
      "label" => %{"type" => "string", "description" => "Names this row's entry; blank uses the side prompt's title."},
      "macro_values" => %{
        "type" => "object",
        "additionalProperties" => %{"type" => "string"},
        "description" => "Macro name to value, for the side prompt's runtime macros."
      }
    },
    "required" => ["side_prompt_id"]
  }

  @set_props %{
    "name" => %{"type" => "string", "description" => "Set name."},
    "rows" => %{
      "type" => "array",
      "items" => @row_item,
      "description" => "Ordered rows; replaces the set's current rows entirely."
    }
  }

  @id_map %{"type" => "object", "additionalProperties" => %{"type" => "string"}}

  @chat_settings_props %{
    "memory_book_id" => %{
      "type" => "string",
      "description" => "The book memories are written to; one the user may edit."
    },
    "profile_id" => %{"type" => "string", "description" => "Memory profile id."},
    "auto_enabled" => %{"type" => "boolean", "description" => "Make memories automatically."},
    "auto_trigger" => %{
      "type" => "string",
      "enum" => ~w(messages tokens),
      "description" => "Unset follows the setting."
    },
    "auto_interval" => %{"type" => "integer", "minimum" => 5, "maximum" => 250},
    "auto_buffer" => %{"type" => "integer", "minimum" => 0, "maximum" => 50},
    "auto_token_threshold" => %{"type" => "integer", "minimum" => 1},
    "auto_hide" => %{
      "type" => "string",
      "enum" => ~w(none all last),
      "description" => "Hide summarized messages from the AI."
    },
    "leave_unhidden" => %{"type" => "integer", "minimum" => 0, "maximum" => 50},
    "context_entry_ids" => Map.put(@strings, "description", "Additional-context lore entry ids, in order."),
    "side_prompt_book_ids" => Map.put(@id_map, "description", "Side prompt id to the book it writes to."),
    "character_book_ids" => Map.put(@id_map, "description", "Character id to its character memory book."),
    "cast_ids" => Map.put(@strings, "description", "Silent-witness character ids; each a non-player participant."),
    "side_prompt_set_mode" => %{
      "type" => "string",
      "enum" => ~w(default individual set),
      "description" => "Which side prompts run; set needs side_prompt_set_id."
    },
    "side_prompt_set_id" => %{"type" => "string"}
  }

  def tools do
    profile_label = fn scope, id -> with %{name: name} <- Memory.get_editable_profile(scope, id), do: name end
    side_prompt_label = fn scope, id -> with %{name: name} <- Memory.get_editable_side_prompt(scope, id), do: name end
    set_label = fn scope, id -> with %{name: name} <- Memory.get_editable_side_prompt_set(scope, id), do: name end

    chat_label = fn scope, id ->
      case chat_fetch(scope, %{"id" => id}, "id") do
        {:ok, chat} -> Chat.title(chat)
        _ -> nil
      end
    end

    profiles = {"memory profile", "memory profiles"}
    side_prompts = {"side prompt", "side prompts"}
    sets = {"side prompt set", "side prompt sets"}

    [
      list_tool(
        "list_memory_profiles",
        "List the memory profiles the user may edit, optionally searched by name.",
        fn scope ->
          for p <- Memory.list_profiles(scope) do
            %{
              "id" => p.id,
              "name" => p.name,
              "default" => p.default,
              "owner" => Args.owner(p),
              "path" => Paths.memory_profile(p.id)
            }
          end
        end
      ),
      get_tool("get_memory_profile", "A memory profile's settings.", &Memory.get_profile/2, &profile_map/1),
      Batch.items("create_memory_profiles",
        description: "Create memory profiles: the model, prompts and entry settings Memory Books use.",
        verb: "Create",
        noun: profiles,
        item: schema(@profile_props, ["name"]),
        run: fn scope, args ->
          scope |> Memory.create_profile(Args.attrs(args, @profile_keys)) |> Args.wrap(&profile_map/1)
        end
      ),
      Batch.items("update_memory_profiles",
        description: "Change memory profiles; only the given fields change.",
        verb: "Update",
        noun: profiles,
        label: profile_label,
        item: schema(Map.put(@profile_props, "id", @id), ["id"]),
        run: fn scope, args ->
          with {:ok, profile} <- fetch(&Memory.get_editable_profile/2, scope, args) do
            scope |> Memory.update_profile(profile, Args.attrs(args, @profile_keys)) |> Args.wrap(&profile_map/1)
          end
        end
      ),
      Batch.ids("delete_memory_profiles",
        description: "Delete memory profiles.",
        verb: "Delete",
        noun: profiles,
        label: profile_label,
        run: fn scope, args ->
          with {:ok, profile} <- fetch(&Memory.get_editable_profile/2, scope, args) do
            scope |> Memory.delete_profile(profile) |> Args.wrap(&deleted/1)
          end
        end
      ),
      %Tool{
        name: "set_default_memory_profile",
        description: "Make a memory profile its owner's default, used by chats that pick none.",
        parameters: schema(%{"id" => @id}, ["id"]),
        kind: :write,
        summary: fn _ -> "Set the default memory profile" end,
        preview: Preview.one(profile_label),
        run: fn scope, args ->
          with {:ok, profile} <- fetch(&Memory.get_editable_profile/2, scope, args) do
            scope |> Memory.set_default_profile(profile) |> Args.wrap(&profile_map/1)
          end
        end
      },
      list_tool(
        "list_side_prompts",
        "List the side prompts the user may edit, optionally searched by name.",
        fn scope ->
          for s <- Memory.list_side_prompts(scope) do
            %{
              "id" => s.id,
              "name" => s.name,
              "prompt_id" => s.prompt_id,
              "enabled" => s.enabled,
              "owner" => Args.owner(s),
              "path" => Paths.side_prompt(s.id)
            }
          end
        end
      ),
      get_tool("get_side_prompt", "A side prompt's settings.", &Memory.get_side_prompt/2, &side_prompt_map/1),
      Batch.items("create_side_prompts",
        description: "Create side prompts: extra prompts that write their own lore entries alongside memories.",
        verb: "Create",
        noun: side_prompts,
        item: schema(@side_prompt_props, ["name", "prompt_id"]),
        run: fn scope, args ->
          scope |> Memory.create_side_prompt(Args.attrs(args, @side_prompt_keys)) |> Args.wrap(&side_prompt_map/1)
        end
      ),
      Batch.items("update_side_prompts",
        description: "Change side prompts; only the given fields change.",
        verb: "Update",
        noun: side_prompts,
        label: side_prompt_label,
        item: schema(Map.put(@side_prompt_props, "id", @id), ["id"]),
        run: fn scope, args ->
          with {:ok, side_prompt} <- fetch(&Memory.get_editable_side_prompt/2, scope, args) do
            scope
            |> Memory.update_side_prompt(side_prompt, Args.attrs(args, @side_prompt_keys))
            |> Args.wrap(&side_prompt_map/1)
          end
        end
      ),
      Batch.ids("delete_side_prompts",
        description: "Delete side prompts.",
        verb: "Delete",
        noun: side_prompts,
        label: side_prompt_label,
        run: fn scope, args ->
          with {:ok, side_prompt} <- fetch(&Memory.get_editable_side_prompt/2, scope, args) do
            scope |> Memory.delete_side_prompt(side_prompt) |> Args.wrap(&deleted/1)
          end
        end
      ),
      list_tool(
        "list_side_prompt_sets",
        "List the side prompt sets the user may edit, optionally searched by name.",
        fn scope ->
          for s <- Memory.list_side_prompt_sets(scope) do
            %{"id" => s.id, "name" => s.name, "owner" => Args.owner(s), "path" => Paths.side_prompt_set(s.id)}
          end
        end
      ),
      get_tool(
        "get_side_prompt_set",
        "A side prompt set and its ordered rows.",
        &Memory.get_editable_side_prompt_set/2,
        &set_map/1
      ),
      Batch.items("create_side_prompt_sets",
        description: "Create side prompt sets: ordered side prompts, each row with its own label and macro values.",
        verb: "Create",
        noun: sets,
        item: schema(@set_props, ["name"]),
        run: fn scope, args ->
          scope |> Memory.create_side_prompt_set(Args.attrs(args, @set_keys)) |> Args.wrap(&set_map/1)
        end
      ),
      Batch.items("update_side_prompt_sets",
        description: "Change side prompt sets; rows, when given, replace the set's rows entirely.",
        verb: "Update",
        noun: sets,
        label: set_label,
        item: schema(Map.put(@set_props, "id", @id), ["id"]),
        run: fn scope, args ->
          with {:ok, set} <- fetch(&Memory.get_editable_side_prompt_set/2, scope, args) do
            scope |> Memory.update_side_prompt_set(set, Args.attrs(args, @set_keys)) |> Args.wrap(&set_map/1)
          end
        end
      ),
      Batch.ids("delete_side_prompt_sets",
        description: "Delete side prompt sets.",
        verb: "Delete",
        noun: sets,
        label: set_label,
        run: fn scope, args ->
          with {:ok, set} <- fetch(&Memory.get_editable_side_prompt_set/2, scope, args) do
            scope |> Memory.delete_side_prompt_set(set) |> Args.wrap(&deleted/1)
          end
        end
      ),
      %Tool{
        name: "get_chat_memory_settings",
        description:
          "A role-play chat's memory settings (id from list_chats); effective_auto is the automatic-memory " <>
            "trigger in effect after settings defaults.",
        parameters: schema(%{"chat_id" => %{"type" => "string", "description" => "Role-play chat id."}}, ["chat_id"]),
        kind: :read,
        summary: fn _ -> "Read a chat's memory settings" end,
        run: fn scope, args ->
          with {:ok, chat} <- chat_fetch(scope, args, "chat_id") do
            {:ok, chat_settings_map(scope, chat, Memory.chat_settings(scope, chat))}
          end
        end
      },
      Batch.items("update_chat_memory_settings",
        description: "Change role-play chats' memory settings (each item's id is a chat id); only given fields change.",
        verb: "Update",
        noun: {"chat's memory settings", "chats' memory settings"},
        label: chat_label,
        item:
          schema(
            Map.put(@chat_settings_props, "id", %{"type" => "string", "description" => "Role-play chat id."}),
            ["id"]
          ),
        run: &update_chat_settings/2
      )
    ]
  end

  defp list_tool(name, description, rows) do
    %Tool{
      name: name,
      description: description,
      parameters: schema(%{"query" => Args.query_property()}, []),
      kind: :read,
      summary: fn _ -> String.replace(name, "_", " ") |> String.capitalize() end,
      run: fn scope, args ->
        key = String.replace_prefix(name, "list_", "")
        {:ok, Args.list(key, Args.by_name(rows.(scope), args["query"]))}
      end
    }
  end

  defp get_tool(name, description, getter, map) do
    %Tool{
      name: name,
      description: description,
      parameters: schema(%{"id" => @id}, ["id"]),
      kind: :read,
      summary: fn _ -> String.replace(name, "get_", "Read ") |> String.replace("_", " ") end,
      run: fn scope, args -> with {:ok, row} <- fetch(getter, scope, args), do: {:ok, map.(row)} end
    }
  end

  defp update_chat_settings(scope, args) do
    with {:ok, chat} <- chat_fetch(scope, args, "id") do
      settings = Memory.chat_settings(scope, chat)

      case Memory.update_chat_settings(scope, settings, Args.attrs(args, @chat_settings_keys)) do
        {:ok, updated} ->
          # The context leaves the broadcast to its callers, as the memory panel does.
          Memory.broadcast_changed(chat.id)
          {:ok, chat_settings_map(scope, chat, updated)}

        {:error, reason} ->
          {:error, Args.error(reason)}
      end
    end
  end

  defp schema(props, required), do: %{"type" => "object", "properties" => props, "required" => required}

  defp fetch(getter, scope, args) do
    with {:ok, id} <- Args.uuid(args, "id") do
      case getter.(scope, id) do
        nil -> {:error, Args.error(:not_found)}
        row -> {:ok, row}
      end
    end
  end

  defp chat_fetch(scope, args, key) do
    with {:ok, id} <- Args.uuid(args, key) do
      case Chats.get_chat(scope, id) do
        %Chat{kind: :roleplay} = chat -> {:ok, chat}
        _ -> {:error, Args.error(:not_found)}
      end
    end
  end

  defp deleted(row), do: %{"deleted" => true, "id" => row.id, "name" => row.name}

  defp string_keys(row, keys) do
    row
    |> Map.take(Enum.map(keys, &String.to_existing_atom/1))
    |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)
  end

  defp profile_map(profile) do
    profile
    |> string_keys(["id", "default" | @profile_keys])
    |> Map.merge(%{"owner" => Args.owner(profile), "path" => Paths.memory_profile(profile.id)})
  end

  defp side_prompt_map(side_prompt) do
    side_prompt
    |> string_keys(["id" | @side_prompt_keys])
    |> Map.merge(%{"owner" => Args.owner(side_prompt), "path" => Paths.side_prompt(side_prompt.id)})
  end

  # A freshly written set carries rows without their side prompts.
  defp set_map(set) do
    set = Repo.preload(set, [rows: :side_prompt], force: true)

    rows =
      for r <- Enum.sort_by(set.rows, & &1.position) do
        %{
          "id" => r.id,
          "side_prompt_id" => r.side_prompt_id,
          "side_prompt_name" => r.side_prompt && r.side_prompt.name,
          "label" => r.label,
          "macro_values" => r.macro_values,
          "position" => r.position
        }
      end

    %{
      "id" => set.id,
      "name" => set.name,
      "rows" => rows,
      "owner" => Args.owner(set),
      "path" => Paths.side_prompt_set(set.id)
    }
  end

  defp chat_settings_map(scope, chat, settings) do
    settings
    |> string_keys(["id", "highest_processed" | @chat_settings_keys])
    |> Map.merge(%{
      "chat_id" => chat.id,
      "effective_auto" => Map.new(Memory.auto_settings(scope, settings), fn {k, v} -> {Atom.to_string(k), v} end),
      "path" => Paths.chat_memory(chat.id)
    })
  end
end
