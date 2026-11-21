defmodule Mythweaver.Assistant.Tools.Prompts do
  @moduledoc "Assistant tools over prompts, prompt blocks, bindings and outlets (`Mythweaver.Prompts`)."

  alias Mythweaver.AI.SamplerParams
  alias Mythweaver.Assistant.Paths
  alias Mythweaver.Assistant.Tool
  alias Mythweaver.Assistant.Tools.Args
  alias Mythweaver.Assistant.Tools.Batch
  alias Mythweaver.Assistant.Tools.Preview
  alias Mythweaver.Chats.Chat
  alias Mythweaver.Prompts
  alias Mythweaver.Prompts.Binding
  alias Mythweaver.Prompts.Block
  alias Mythweaver.Prompts.Outlet
  alias Mythweaver.Prompts.Prompt
  alias Mythweaver.Prompts.PromptBlock
  alias Mythweaver.Sharing.Visibility

  @prompt_keys ~w(name description purpose enabled thinking site_visibility)
  @block_create_keys ~w(name kind role content description speaker_roles site_visibility role_tag forbid_overrides)
  @block_update_keys ~w(name description role content enabled kind speaker_roles site_visibility role_tag
                        forbid_overrides)
  @outlet_keys ~w(key name description)
  @binding_target_keys ~w(provider_id ai_model_id character_id chat_id)

  defp purposes, do: Enum.map(Ecto.Enum.values(Prompt, :purpose), &Atom.to_string/1)
  defp thinking_levels, do: Enum.map(SamplerParams.thinking_levels(), &Atom.to_string/1)
  defp binding_scopes, do: Enum.map(Ecto.Enum.values(Binding, :scope), &Atom.to_string/1)

  def tools do
    id_only = fn description ->
      %{
        "type" => "object",
        "properties" => %{"id" => %{"type" => "string", "description" => description}},
        "required" => ["id"]
      }
    end

    prompt_props = %{
      "name" => %{"type" => "string"},
      "description" => %{"type" => "string"},
      "purpose" => %{"type" => "string", "enum" => purposes(), "description" => "What the prompt is used for."},
      "enabled" => %{"type" => "boolean"},
      "thinking" => %{
        "type" => "string",
        "enum" => thinking_levels(),
        "description" => "Reasoning effort the prompt asks for; omit or set null to use the model's own level."
      },
      "site_visibility" => %{
        "type" => "string",
        "enum" => ~w(readable runtime_only),
        "description" =>
          "What users may see of a site prompt: readable (everything) or runtime_only (its blocks' content hidden; the model still gets it). " <>
            "Site items only; a personal one must stay readable."
      }
    }

    block_props = %{
      "name" => %{"type" => "string"},
      "description" => %{"type" => "string"},
      "role" => %{"type" => "string", "enum" => ~w(system user assistant)},
      "content" => %{"type" => "string", "description" => "Template text."},
      "enabled" => %{"type" => "boolean"},
      "kind" => %{"type" => "string", "enum" => ~w(template chat_history)},
      "speaker_roles" => %{
        "type" => "string",
        "enum" => ~w(responder fixed),
        "description" =>
          "Chat-history block speaker mode: responder (default; each speaker's own lines as assistant) or fixed " <>
            "(every non-player character as assistant)."
      },
      "role_tag" => %{
        "type" => ["string", "null"],
        "enum" => ["main", "post_history", nil],
        "description" =>
          "Template blocks only: main is replaced by a card's system prompt, post_history by its post-history " <>
            "instructions ({{ original }} is the block's own text); null for neither."
      },
      "forbid_overrides" => %{
        "type" => "boolean",
        "description" => "A tagged block keeps its own text and drops the card's."
      },
      "site_visibility" => %{
        "type" => "string",
        "enum" => ~w(readable runtime_only),
        "description" =>
          "What users may see of a site block: readable (everything) or runtime_only (its content hidden; the model still gets it). " <>
            "Site items only; a personal one must stay readable."
      }
    }

    outlet_props = %{
      "key" => %{
        "type" => "string",
        "description" => "Stable id lore entries store; lowercase letters, numbers, underscores."
      },
      "name" => %{"type" => "string"},
      "description" => %{"type" => "string"}
    }

    prompts = {"prompt", "prompts"}
    blocks = {"prompt block", "prompt blocks"}
    outlets = {"prompt outlet", "prompt outlets"}
    prompt_label = fn scope, id -> with %{name: name} <- Prompts.get_editable_prompt(scope, id), do: name end
    block_label = fn scope, id -> with %{name: name} <- Prompts.get_editable_block(scope, id), do: name end
    usable_block_label = fn scope, id -> with %{name: name} <- Prompts.get_block(scope, id), do: name end
    membership_label = fn scope, id -> with %{block: block} <- Prompts.get_prompt_block(scope, id), do: block.name end
    outlet_label = fn scope, id -> with %{name: name} <- Prompts.get_editable_outlet(scope, id), do: name end

    [
      %Tool{
        name: "list_prompts",
        description: "Lists the prompts the user may use, optionally only those of one purpose or searched by name.",
        parameters: %{
          "type" => "object",
          "properties" => %{"purpose" => %{"type" => "string", "enum" => purposes()}, "query" => Args.query_property()},
          "required" => []
        },
        kind: :read,
        summary: fn args -> if args["purpose"], do: "List #{args["purpose"]} prompts", else: "List prompts" end,
        run: &list_prompts/2
      },
      %Tool{
        name: "get_prompt",
        description:
          "Reads a prompt and its blocks in order; each block row carries its membership_id (the block's place in " <>
            "this prompt).",
        parameters: id_only.("Prompt id."),
        kind: :read,
        summary: fn args -> "Read prompt #{args["id"] || "…"}" end,
        run: &get_prompt/2
      },
      Batch.items("create_prompts",
        description: "Creates prompts (empty; add blocks with create_prompt_blocks or add_prompt_blocks).",
        verb: "Create",
        noun: prompts,
        item: %{"type" => "object", "properties" => prompt_props, "required" => ["name"]},
        run: &create_prompt/2
      ),
      Batch.items("update_prompts",
        description: "Changes prompts. Only given keys change.",
        verb: "Update",
        noun: prompts,
        label: prompt_label,
        item: %{
          "type" => "object",
          "properties" => Map.put(prompt_props, "id", %{"type" => "string"}),
          "required" => ["id"]
        },
        run: &update_prompt/2
      ),
      Batch.ids("delete_prompts",
        description: "Deletes prompts. Their blocks are kept.",
        verb: "Delete",
        noun: prompts,
        label: prompt_label,
        run: &delete_prompt/2
      ),
      Batch.ids("duplicate_prompts",
        description: "Copies prompts, each with its block list, into new prompts the user owns.",
        verb: "Duplicate",
        noun: prompts,
        label: fn scope, id -> with %{name: name} <- Prompts.get_prompt(scope, id), do: name end,
        run: &duplicate_prompt/2
      ),
      %Tool{
        name: "list_prompt_blocks",
        description: "Lists the prompt blocks the user may use, optionally searched by name.",
        parameters: %{"type" => "object", "properties" => %{"query" => Args.query_property()}, "required" => []},
        kind: :read,
        summary: fn _ -> "List prompt blocks" end,
        run: &list_blocks/2
      },
      Batch.items("create_prompt_blocks",
        description: "Creates prompt blocks, each appended to a prompt when its prompt_id is given.",
        verb: "Create",
        noun: blocks,
        item: %{
          "type" => "object",
          "properties" =>
            block_props
            |> Map.delete("enabled")
            |> Map.put("prompt_id", %{"type" => "string", "description" => "Prompt to append the block to; optional."}),
          "required" => ["name", "kind", "role"]
        },
        run: &create_block/2
      ),
      Batch.items("update_prompt_blocks",
        description:
          "Changes prompt blocks. Only given keys change. Switching kind to chat_history clears the content.",
        verb: "Update",
        noun: blocks,
        label: block_label,
        item: %{
          "type" => "object",
          "properties" => Map.put(block_props, "id", %{"type" => "string"}),
          "required" => ["id"]
        },
        run: &update_block/2
      ),
      Batch.ids("delete_prompt_blocks",
        description: "Deletes prompt blocks; each disappears from every prompt using it.",
        verb: "Delete",
        noun: blocks,
        label: block_label,
        run: &delete_block/2
      ),
      Batch.items("add_prompt_blocks",
        description: "Adds existing prompt blocks to prompts, each appended at the end.",
        verb: "Add",
        noun: blocks,
        label: usable_block_label,
        item: %{
          "type" => "object",
          "properties" => %{
            "id" => %{"type" => "string", "description" => "Block id to add."},
            "prompt_id" => %{"type" => "string", "description" => "Prompt to add it to."},
            "enabled" => %{"type" => "boolean", "description" => "Enabled in this prompt; defaults true."}
          },
          "required" => ["id", "prompt_id"]
        },
        run: &add_prompt_block/2
      ),
      Batch.ids("remove_prompt_blocks",
        description:
          "Removes blocks from their prompt by membership id (get_prompt's membership_id); the block itself is kept.",
        verb: "Remove",
        noun: blocks,
        label: membership_label,
        run: &remove_prompt_block/2
      ),
      Batch.items("update_prompt_block_memberships",
        description: "Switches blocks on or off within one prompt each, by membership id (get_prompt's membership_id).",
        verb: "Update",
        noun: {"prompt block membership", "prompt block memberships"},
        label: membership_label,
        item: %{
          "type" => "object",
          "properties" => %{
            "id" => %{"type" => "string", "description" => "Membership id (get_prompt's membership_id)."},
            "enabled" => %{"type" => "boolean"}
          },
          "required" => ["id", "enabled"]
        },
        run: &update_prompt_block_membership/2
      ),
      %Tool{
        name: "reorder_prompt_blocks",
        description:
          "Sets a prompt's block order. block_ids must be every block currently in the prompt, each once, in the new order.",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "id" => %{"type" => "string", "description" => "Prompt id."},
            "block_ids" => %{
              "type" => "array",
              "items" => %{"type" => "string"},
              "description" => "The prompt's block ids (not membership ids), in the new order."
            }
          },
          "required" => ["id", "block_ids"]
        },
        kind: :write,
        summary: fn _ -> "Reorder prompt blocks" end,
        preview: Preview.one(prompt_label),
        run: &reorder_prompt_blocks/2
      },
      %Tool{
        name: "list_prompt_bindings",
        description:
          "Lists a roleplay prompt's bindings: where it is bound (global, a connection, a model, a character, a " <>
            "chat, or a character in a chat).",
        parameters: id_only.("Prompt id."),
        kind: :read,
        summary: fn _ -> "List prompt bindings" end,
        run: &list_bindings/2
      },
      Batch.items("bind_prompts",
        description:
          "Binds roleplay prompts at a scope: global (none), connection (provider_id), model (ai_model_id), " <>
            "character (character_id), chat (chat_id) or character_in_chat (character_id and chat_id).",
        verb: "Bind",
        noun: prompts,
        label: prompt_label,
        item: %{
          "type" => "object",
          "properties" => %{
            "id" => %{"type" => "string", "description" => "Prompt id; must be purpose roleplay."},
            "scope" => %{"type" => "string", "enum" => binding_scopes(), "description" => "Binding specificity."},
            "provider_id" => %{"type" => "string", "description" => "Connection id; for scope connection."},
            "ai_model_id" => %{"type" => "string", "description" => "Model id; for scope model."},
            "character_id" => %{
              "type" => "string",
              "description" => "Character id; for scope character and character_in_chat."
            },
            "chat_id" => %{"type" => "string", "description" => "Chat id; for scope chat and character_in_chat."}
          },
          "required" => ["id", "scope"]
        },
        run: &bind_prompt/2
      ),
      Batch.ids("unbind_prompts",
        description: "Removes prompt bindings (ids from list_prompt_bindings).",
        verb: "Unbind",
        noun: {"prompt binding", "prompt bindings"},
        label: &binding_label/2,
        run: &unbind_prompt/2
      ),
      %Tool{
        name: "list_prompt_outlets",
        description: "Lists the prompt outlets lore entries can target (outlet custom), optionally searched by name.",
        parameters: %{"type" => "object", "properties" => %{"query" => Args.query_property()}, "required" => []},
        kind: :read,
        summary: fn _ -> "List prompt outlets" end,
        run: &list_outlets/2
      },
      %Tool{
        name: "get_prompt_outlet",
        description: "Reads a prompt outlet.",
        parameters: id_only.("Outlet id."),
        kind: :read,
        summary: fn _ -> "Read prompt outlet" end,
        run: fn scope, args ->
          with {:ok, outlet} <- fetch(&Prompts.get_outlet/2, scope, args, "id"), do: {:ok, outlet_result(outlet)}
        end
      },
      Batch.items("create_prompt_outlets",
        description: "Creates prompt outlets lore entries can target.",
        verb: "Create",
        noun: outlets,
        item: %{"type" => "object", "properties" => outlet_props, "required" => ["key", "name"]},
        run: fn scope, args ->
          scope |> Prompts.create_outlet(Args.attrs(args, @outlet_keys)) |> Args.wrap(&outlet_result/1)
        end
      ),
      Batch.items("update_prompt_outlets",
        description: "Changes prompt outlets. Only given keys change.",
        verb: "Update",
        noun: outlets,
        label: outlet_label,
        item: %{
          "type" => "object",
          "properties" => Map.put(outlet_props, "id", %{"type" => "string"}),
          "required" => ["id"]
        },
        run: fn scope, args ->
          with {:ok, outlet} <- fetch(&Prompts.get_editable_outlet/2, scope, args, "id") do
            scope |> Prompts.update_outlet(outlet, Args.attrs(args, @outlet_keys)) |> Args.wrap(&outlet_result/1)
          end
        end
      ),
      Batch.ids("delete_prompt_outlets",
        description: "Deletes prompt outlets. Lore entries keyed to a deleted outlet keep that key.",
        verb: "Delete",
        noun: outlets,
        label: outlet_label,
        run: fn scope, args ->
          with {:ok, outlet} <- fetch(&Prompts.get_editable_outlet/2, scope, args, "id") do
            scope |> Prompts.delete_outlet(outlet) |> Args.wrap(&%{"deleted" => true, "id" => &1.id})
          end
        end
      )
    ]
  end

  defp list_prompts(scope, args) do
    with {:ok, purpose} <- purpose(args["purpose"]) do
      rows =
        for p <- Prompts.list_prompts(scope, purpose) do
          %{
            "id" => p.id,
            "name" => p.name,
            "description" => Args.cut(p.description),
            "purpose" => p.purpose,
            "enabled" => p.enabled,
            "owner" => Args.owner(p),
            "path" => Paths.prompt(p.id)
          }
        end

      {:ok, Args.list("prompts", Args.by_name(rows, args["query"]))}
    end
  end

  defp purpose(nil), do: {:ok, nil}

  defp purpose(value) do
    if value in purposes(),
      do: {:ok, String.to_existing_atom(value)},
      else: {:error, Args.error("unknown purpose; use one of #{Enum.join(purposes(), ", ")}")}
  end

  defp get_prompt(scope, args) do
    with {:ok, prompt} <- fetch(&Prompts.get_prompt/2, scope, args, "id") do
      blocks =
        for pb <- Prompts.list_prompt_blocks(prompt) do
          %{
            "membership_id" => pb.id,
            "block_id" => pb.block.id,
            "name" => pb.block.name,
            "kind" => pb.block.kind,
            "role" => pb.block.role,
            "enabled" => pb.enabled,
            "content" => if(!Visibility.block_hidden_for?(scope, pb.block, prompt), do: Args.cut(pb.block.content)),
            "path" => Paths.prompt_block(pb.block.id)
          }
        end

      {:ok, prompt |> prompt_result() |> Map.put("blocks", blocks)}
    end
  end

  defp create_prompt(scope, args),
    do: scope |> Prompts.create_prompt(Args.attrs(args, @prompt_keys)) |> Args.wrap(&prompt_result/1)

  defp update_prompt(scope, args) do
    with {:ok, prompt} <- fetch(&Prompts.get_editable_prompt/2, scope, args, "id") do
      scope |> Prompts.update_prompt(prompt, Args.attrs(args, @prompt_keys)) |> Args.wrap(&prompt_result/1)
    end
  end

  defp delete_prompt(scope, args) do
    with {:ok, prompt} <- fetch(&Prompts.get_editable_prompt/2, scope, args, "id") do
      scope |> Prompts.delete_prompt(prompt) |> Args.wrap(&%{"deleted" => true, "id" => &1.id})
    end
  end

  defp duplicate_prompt(scope, args) do
    with {:ok, prompt} <- fetch(&Prompts.get_prompt/2, scope, args, "id") do
      scope |> Prompts.duplicate_prompt(prompt) |> Args.wrap(&prompt_result/1)
    end
  end

  defp list_blocks(scope, args) do
    rows =
      for b <- Prompts.list_blocks(scope) do
        content = if !Visibility.block_hidden_for?(scope, b, nil), do: Args.cut(b.content)
        b |> block_result() |> Map.merge(%{"content" => content, "owner" => Args.owner(b)})
      end

    {:ok, Args.list("blocks", Args.by_name(rows, args["query"]))}
  end

  defp create_block(scope, args) do
    prompt =
      if args["prompt_id"] in [nil, ""],
        do: {:ok, nil},
        else: fetch(&Prompts.get_editable_prompt/2, scope, args, "prompt_id")

    # A block held for review is not added to the prompt.
    with {:ok, prompt} <- prompt,
         {:ok, block} <-
           wrap_error(Prompts.create_block(scope, Args.attrs(args, @block_create_keys), for_prompt: prompt)),
         {:ok, _} <- add_to(scope, prompt, block) do
      {:ok, block |> block_result() |> Map.put("prompt_id", prompt && prompt.id)}
    else
      {:held, hold} -> {:ok, Args.held(hold)}
      error -> error
    end
  end

  defp add_to(_scope, nil, _block), do: {:ok, nil}
  defp add_to(scope, prompt, block), do: wrap_error(Prompts.add_block(scope, prompt, block, %{}))

  defp update_block(scope, args) do
    with {:ok, block} <- fetch(&Prompts.get_editable_block/2, scope, args, "id") do
      scope |> Prompts.update_block(block, Args.attrs(args, @block_update_keys)) |> Args.wrap(&block_result/1)
    end
  end

  defp delete_block(scope, args) do
    with {:ok, block} <- fetch(&Prompts.get_editable_block/2, scope, args, "id") do
      scope |> Prompts.delete_block(block) |> Args.wrap(&%{"deleted" => true, "id" => &1.id})
    end
  end

  defp add_prompt_block(scope, args) do
    with {:ok, block} <- fetch(&Prompts.get_block/2, scope, args, "id"),
         {:ok, prompt} <- fetch(&Prompts.get_editable_prompt/2, scope, args, "prompt_id") do
      scope |> Prompts.add_block(prompt, block, Args.attrs(args, ~w(enabled))) |> Args.wrap(&membership_result/1)
    end
  end

  defp remove_prompt_block(scope, args) do
    with {:ok, membership} <- fetch(&Prompts.get_prompt_block/2, scope, args, "id") do
      scope |> Prompts.remove_block(membership) |> Args.wrap(&%{"deleted" => true, "id" => &1.id})
    end
  end

  defp update_prompt_block_membership(scope, args) do
    with {:ok, membership} <- fetch(&Prompts.get_prompt_block/2, scope, args, "id") do
      scope
      |> Prompts.update_block_membership(membership, Args.attrs(args, ~w(enabled)))
      |> Args.wrap(&membership_result/1)
    end
  end

  defp reorder_prompt_blocks(scope, args) do
    with {:ok, prompt} <- fetch(&Prompts.get_editable_prompt/2, scope, args, "id"),
         {:ok, block_ids} <- Args.uuid_list(args, "block_ids"),
         {:ok, _} <- wrap_error(Prompts.reorder_blocks(scope, prompt, block_ids)) do
      {:ok, %{"id" => prompt.id, "reordered" => true, "path" => Paths.prompt(prompt.id)}}
    end
  end

  defp list_bindings(scope, args) do
    with {:ok, prompt} <- fetch(&Prompts.get_prompt/2, scope, args, "id") do
      {:ok, Args.list("bindings", Enum.map(Prompts.list_bindings(scope, prompt), &binding_row/1))}
    end
  end

  defp bind_prompt(scope, args) do
    with {:ok, prompt} <- fetch(&Prompts.get_editable_prompt/2, scope, args, "id"),
         {:ok, binding_scope} <- binding_scope(args["scope"]),
         {:ok, ids} <- binding_target_ids(args) do
      scope |> Prompts.bind_prompt(prompt, binding_scope, ids) |> Args.wrap(&binding_result/1)
    end
  end

  defp binding_scope(value) do
    if value in binding_scopes(),
      do: {:ok, String.to_existing_atom(value)},
      else: {:error, Args.error("scope must be one of #{Enum.join(binding_scopes(), ", ")}")}
  end

  defp binding_target_ids(args) do
    Enum.reduce_while(@binding_target_keys, {:ok, []}, fn key, {:ok, acc} ->
      if is_nil(args[key]) do
        {:cont, {:ok, acc}}
      else
        case Args.uuid(args, key) do
          {:ok, uuid} -> {:cont, {:ok, [{String.to_existing_atom(key), uuid} | acc]}}
          error -> {:halt, error}
        end
      end
    end)
  end

  defp unbind_prompt(scope, args) do
    with {:ok, binding} <- fetch(&Prompts.get_binding/2, scope, args, "id") do
      scope |> Prompts.unbind_prompt(binding) |> Args.wrap(&%{"deleted" => true, "id" => &1.id})
    end
  end

  defp binding_label(scope, id) do
    with %Binding{} = binding <- Prompts.get_binding(scope, id),
         %{name: name} <- Prompts.get_prompt(scope, binding.prompt_id) do
      "#{binding.scope} binding of “#{name}”"
    else
      _ -> nil
    end
  end

  defp list_outlets(scope, args) do
    rows = for o <- Prompts.list_outlets(scope), do: o |> outlet_result() |> Map.put("owner", Args.owner(o))
    {:ok, Args.list("outlets", Args.by_name(rows, args["query"]))}
  end

  defp fetch(getter, scope, args, key) do
    with {:ok, id} <- Args.uuid(args, key) do
      case getter.(scope, id) do
        nil -> {:error, Args.error(:not_found)}
        row -> {:ok, row}
      end
    end
  end

  defp wrap_error({:ok, _} = ok), do: ok
  defp wrap_error({:held, _hold} = held), do: held
  defp wrap_error({:error, reason}), do: {:error, Args.error(reason)}

  defp prompt_result(%Prompt{} = p) do
    %{
      "id" => p.id,
      "name" => p.name,
      "description" => p.description,
      "purpose" => p.purpose,
      "enabled" => p.enabled,
      "thinking" => p.thinking,
      "site_visibility" => p.site_visibility,
      "path" => Paths.prompt(p.id)
    }
  end

  defp block_result(%Block{} = b) do
    %{
      "id" => b.id,
      "name" => b.name,
      "description" => b.description,
      "kind" => b.kind,
      "role" => b.role,
      "content" => b.content,
      "enabled" => b.enabled,
      "speaker_roles" => b.speaker_roles,
      "role_tag" => b.role_tag,
      "forbid_overrides" => b.forbid_overrides,
      "site_visibility" => b.site_visibility,
      "path" => Paths.prompt_block(b.id)
    }
  end

  defp membership_result(%PromptBlock{} = pb) do
    %{
      "membership_id" => pb.id,
      "prompt_id" => pb.prompt_id,
      "block_id" => pb.block_id,
      "position" => pb.position,
      "enabled" => pb.enabled
    }
  end

  defp binding_row(%Binding{} = b) do
    b
    |> binding_result()
    |> Map.merge(%{
      "provider_name" => b.provider && b.provider.name,
      "ai_model_name" => b.model && b.model.name,
      "character_name" => b.character && b.character.name,
      "chat_title" => b.chat && Chat.title(b.chat)
    })
  end

  defp binding_result(%Binding{} = b) do
    %{
      "id" => b.id,
      "prompt_id" => b.prompt_id,
      "scope" => to_string(b.scope),
      "provider_id" => b.provider_id,
      "ai_model_id" => b.ai_model_id,
      "character_id" => b.character_id,
      "chat_id" => b.chat_id
    }
  end

  defp outlet_result(%Outlet{} = o),
    do: %{
      "id" => o.id,
      "key" => o.key,
      "name" => o.name,
      "description" => o.description,
      "path" => Paths.prompt_outlet(o.id)
    }
end
