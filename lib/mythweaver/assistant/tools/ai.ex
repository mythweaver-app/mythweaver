defmodule Mythweaver.Assistant.Tools.AI do
  @moduledoc """
  Assistant tools over `Mythweaver.AI`: connections (providers), discovery, models, the links
  between them and moving them to the site. No tool takes or returns an API key; `request_api_key`
  opens a form card that saves it without the model.
  """

  alias Mythweaver.AI
  alias Mythweaver.AI.Completion
  alias Mythweaver.AI.Embedding
  alias Mythweaver.AI.ProviderModel
  alias Mythweaver.AI.SamplerParams
  alias Mythweaver.Assistant.Paths
  alias Mythweaver.Assistant.Tool
  alias Mythweaver.Assistant.Tools.Args
  alias Mythweaver.Assistant.Tools.Batch
  alias Mythweaver.Assistant.Tools.Preview
  alias Mythweaver.Ownership
  alias Mythweaver.Sharing.Visibility

  @connection_keys ~w(name adapter thinking_dialect sampler_dialect base_url enabled priority extra_headers extra_body
                      request_timeout_ms max_concurrency prompt_progress)
  @model_keys ~w(name api_model_id completion_mode context_window supports_images supports_files supports_audio
                 supports_video supports_tools supports_thinking continue_prefill reasoning_prefix reasoning_suffix
                 tokenizer prompt_cost_per_mtok completion_cost_per_mtok notes extra_body caption_model_id
                 caption_prompt_id caption_max_tokens inline_image_limit inline_audio_limit inline_video_limit
                 inline_document_limit image_detail chat_first_token_seconds chat_stall_seconds chat_deadline_seconds
                 background_first_token_seconds background_stall_seconds background_deadline_seconds sampler)
  @link_keys ~w(enabled api_model_id_override weight extra_body thinking_dialect sampler_dialect)
  @dialects ~w(openai openrouter llama_cpp)

  def tools do
    connection_label = fn scope, id -> with %{name: name} <- AI.get_provider(scope, id), do: name end
    model_label = fn scope, id -> with %{name: name} <- AI.get_editable_model(scope, id), do: name end
    link_label = &link_name/2
    connections = {"connection", "connections"}
    models = {"model", "models"}
    links = {"link", "links"}

    [
      %Tool{
        name: "list_connections",
        description:
          "List the AI connections (OpenAI-compatible endpoints) the user may edit, optionally searched by name.",
        parameters: object(%{"query" => Args.query_property()}, []),
        kind: :read,
        summary: fn _ -> "List AI connections" end,
        run: fn scope, args ->
          rows = Enum.map(AI.list_providers(scope), &connection/1)
          {:ok, Args.list("connections", Args.by_name(rows, args["query"]))}
        end
      },
      Batch.items("create_connections",
        description:
          "Create AI connections. Each has no API key: call request_api_key afterwards for one that needs it.",
        verb: "Create",
        noun: connections,
        item:
          object(
            Map.put(
              connection_properties(),
              "site",
              bool("True to make it a site connection instead of your own; site managers only.")
            ),
            ["name", "base_url"]
          ),
        run: &new_connection/2
      ),
      Batch.items("update_connections",
        description:
          "Change AI connections' settings. Only given fields change on each; null clears a dialect override.",
        verb: "Update",
        noun: connections,
        label: connection_label,
        item: object(Map.put(connection_properties(), "id", string("Connection id.")), ["id"]),
        run: &update_connection/2
      ),
      Batch.ids("delete_connections",
        description: "Delete connections. Their model links go with them; the models stay.",
        verb: "Delete",
        noun: connections,
        label: connection_label,
        run: fn scope, args ->
          with {:ok, provider} <- fetch_provider(scope, args, "id") do
            scope
            |> AI.delete_provider(provider)
            |> Args.wrap(&%{"deleted" => true, "id" => &1.id, "name" => &1.name})
          end
        end
      ),
      %Tool{
        name: "request_api_key",
        description:
          "Show the user a form to enter an existing connection's API key; pass the id a create_connections or list_connections result gave. The key is saved straight to the connection; you never see it.",
        parameters: object(%{"connection_id" => string("Connection id.")}, ["connection_id"]),
        kind: :input,
        summary: fn _ -> "Set the API key for a connection" end,
        # Checks the connection before the form opens; the key itself arrives through
        # `Mythweaver.Assistant.submit_api_key/4`.
        run: fn scope, args ->
          with {:ok, provider} <- fetch_provider(scope, args, "connection_id"),
               do: {:ok, %{"connection_id" => provider.id, "name" => provider.name}}
        end
      },
      %Tool{
        name: "test_connection",
        description: "Check that a connection answers its /models listing.",
        parameters: object(%{"connection_id" => string("Connection id.")}, ["connection_id"]),
        kind: :read,
        summary: fn _ -> "Test a connection" end,
        run: fn scope, args ->
          with {:ok, provider} <- fetch_provider(scope, args, "connection_id") do
            scope |> AI.check_provider(provider) |> Args.wrap(&%{"ok" => true, "models_offered" => &1})
          end
        end
      },
      %Tool{
        name: "discover_models",
        description: "List the models a connection offers (wire ids) and whether each is already linked.",
        parameters: object(%{"connection_id" => string("Connection id.")}, ["connection_id"]),
        kind: :read,
        summary: fn _ -> "Discover a connection's models" end,
        run: fn scope, args ->
          with {:ok, provider} <- fetch_provider(scope, args, "connection_id") do
            scope
            |> AI.discover_models(provider)
            |> Args.wrap(fn entries ->
              Args.list("models", for(e <- entries, do: %{"id" => e.id, "name" => e.name, "linked" => e.linked?}))
            end)
          end
        end
      },
      %Tool{
        name: "add_models",
        description:
          "Add models one connection offers (wire ids from discover_models), creating each model or linking an existing one. " <>
            Batch.rule(),
        parameters:
          object(
            %{
              "connection_id" => string("Connection id."),
              "models" => Batch.array(%{"type" => "string"}, "The models' wire ids from discover_models."),
              "as_embedding" => %{"type" => "boolean", "description" => "Add them as embedding models."}
            },
            ["connection_id", "models"]
          ),
        kind: :write,
        summary: &Batch.count("Add", &1["models"], {"model", "models"}),
        # Wire ids name what will be added; they are the provider's, not rows yet.
        preview: fn _scope, args -> for m <- List.wrap(args["models"]), do: to_string(m) end,
        run: &add_models/2
      },
      %Tool{
        name: "list_models",
        description:
          "List the models the user may run, optionally searched by name: chat and text models by default, or " <>
            "embedding or classifier models by mode.",
        parameters:
          object(
            %{
              "query" => Args.query_property(),
              "mode" => %{
                "type" => "string",
                "enum" => ["chat_and_text", "embedding", "classifier"],
                "description" => "Which kind of model to list; omit for chat/text models."
              }
            },
            []
          ),
        kind: :read,
        summary: fn _ -> "List AI models" end,
        run: fn scope, args ->
          case mode_rows(scope, args["mode"]) do
            {:ok, rows} ->
              {:ok, Args.list("models", rows |> Enum.map(&model(scope, &1)) |> Args.by_name(args["query"]))}

            :error ->
              {:error, Args.error("mode must be chat_and_text, embedding or classifier")}
          end
        end
      },
      Batch.items("update_models",
        description:
          "Change AI models' settings. Only given fields change on each; sampler changes only its given fields. " <>
            "completion_mode changes only to a mode every current chat, participant, memory profile, prompt binding " <>
            "and captioning model accepts.",
        verb: "Update",
        noun: models,
        label: model_label,
        item: object(Map.put(model_properties(), "id", string("Model id.")), ["id"]),
        run: &update_model/2
      ),
      Batch.ids("delete_models",
        description: "Delete models. Their connection links go with them; the connections stay.",
        verb: "Delete",
        noun: models,
        label: model_label,
        run: fn scope, args ->
          with {:ok, model} <- editable_model(scope, args["id"]) do
            scope |> AI.delete_model(model) |> Args.wrap(&%{"deleted" => true, "id" => &1.id, "name" => &1.name})
          end
        end
      ),
      Batch.items("create_links",
        description:
          "Link models to connections so each can be served through it; a model and connection must have the same owner.",
        verb: "Link",
        noun: links,
        item:
          object(
            Map.merge(
              %{"provider_id" => string("Connection id."), "model_id" => string("Model id.")},
              link_properties()
            ),
            ["provider_id", "model_id"]
          ),
        run: &create_link/2
      ),
      Batch.items("update_links",
        description:
          "Change links' weight, enabled flag, wire-id override or per-link extras. Only given fields change.",
        verb: "Update",
        noun: links,
        label: link_label,
        item: object(Map.put(link_properties(), "id", string("Link id.")), ["id"]),
        run: fn scope, item ->
          with {:ok, link} <- fetch_link(item, "id") do
            scope |> AI.update_link(link, Args.attrs(item, @link_keys)) |> Args.wrap(&link_full/1)
          end
        end
      ),
      Batch.ids("delete_links",
        description: "Unlink models from connections. Neither row itself is deleted.",
        verb: "Unlink",
        noun: links,
        label: link_label,
        run: fn scope, args ->
          with {:ok, link} <- fetch_link(args, "id") do
            scope |> AI.delete_link(link) |> Args.wrap(&%{"deleted" => true, "id" => &1.id})
          end
        end
      ),
      %Tool{
        name: "test_link",
        description:
          "Send one capped test message (a few real tokens) through a link to prove its connection and key work " <>
            "for that model.",
        parameters: object(%{"link_id" => string("Link id.")}, ["link_id"]),
        kind: :write,
        summary: fn _ -> "Test a model link" end,
        preview: fn scope, args -> [Preview.row(link_label, scope, args["link_id"])] end,
        run: fn scope, args ->
          with {:ok, link} <- fetch_link(args, "link_id") do
            scope |> AI.test_link(link) |> Args.wrap(&test_result/1)
          end
        end
      },
      transfer_tool("transfer_connections", connections, connection_label, &transfer_connection/2,
        description:
          "Move the user's own connections to the site, moving every model linked to each with them. " <>
            "A site connection is never made personal again. Needs the site AI permission and sudo mode."
      ),
      transfer_tool("transfer_models", models, model_label, &transfer_model/2,
        description:
          "Move the user's own models to the site, dropping every link the site may not hold. " <>
            "A site model is never made personal again. Needs the site AI permission and sudo mode."
      )
    ]
  end

  defp transfer_tool(name, {_one, many} = noun, label, transfer, opts) do
    %Tool{
      name: name,
      description: Keyword.fetch!(opts, :description) <> " " <> Batch.rule(),
      parameters: object(%{"ids" => Batch.array(%{"type" => "string"}, "The #{many}' ids.")}, ["ids"]),
      kind: :write,
      summary: &Batch.count("Transfer", &1["ids"], noun),
      preview: fn scope, args -> Enum.map(List.wrap(args["ids"]), &Preview.row(label, scope, &1)) end,
      run: fn scope, args ->
        with {:ok, ids} <- Batch.fetch_list(args, "ids"), do: Batch.each(Enum.uniq(ids), &transfer.(scope, &1))
      end
    }
  end

  defp new_connection(scope, item) do
    opts = [site: item["site"] == true]
    scope |> AI.create_provider(Args.attrs(item, @connection_keys), opts) |> Args.wrap(&connection_full/1)
  end

  defp update_connection(scope, item) do
    with {:ok, provider} <- fetch_provider(scope, item, "id") do
      scope |> AI.update_provider(provider, Args.attrs(item, @connection_keys)) |> Args.wrap(&connection_full/1)
    end
  end

  defp update_model(scope, item) do
    with {:ok, model} <- editable_model(scope, item["id"]) do
      scope |> AI.update_model(model, Args.attrs(item, @model_keys)) |> Args.wrap(&model_full(scope, &1))
    end
  end

  defp create_link(scope, item) do
    with {:ok, provider} <- fetch_provider(scope, item, "provider_id"),
         {:ok, model_id} <- Args.uuid(item, "model_id"),
         {:ok, model} <- found(AI.get_editable_model(scope, model_id)) do
      scope |> AI.link_model(provider, model, Args.attrs(item, @link_keys)) |> Args.wrap(&link_full/1)
    end
  end

  defp transfer_connection(scope, id) do
    with {:ok, provider} <- fetch_provider(scope, %{"id" => id}, "id") do
      scope |> AI.transfer(provider, :site) |> Args.wrap(&connection_full/1)
    end
  end

  defp transfer_model(scope, id) do
    with {:ok, model} <- editable_model(scope, id) do
      scope |> AI.transfer(model, :site) |> Args.wrap(&model_full(scope, &1))
    end
  end

  defp mode_rows(scope, mode) when mode in [nil, "chat_and_text"], do: {:ok, AI.list_models(scope)}
  defp mode_rows(scope, "embedding"), do: {:ok, AI.list_embedding_models(scope)}
  defp mode_rows(scope, "classifier"), do: {:ok, AI.list_classifier_models(scope)}
  defp mode_rows(_scope, _mode), do: :error

  # Discovers once for the whole batch.
  defp add_models(scope, args) do
    with {:ok, models} <- Batch.fetch_list(args, "models"),
         {:ok, provider, entries} <- discovered(scope, args) do
      Batch.each(Enum.uniq(models), &add_entry(scope, provider, entries, &1, embedding(args)))
    end
  end

  defp embedding(args), do: if(args["as_embedding"] == true, do: [as: :embedding], else: [])

  defp discovered(scope, args) do
    with {:ok, provider} <- fetch_provider(scope, args, "connection_id"),
         {:ok, entries} <- scope |> AI.discover_models(provider) |> Args.wrap(& &1) do
      {:ok, provider, entries}
    end
  end

  defp add_entry(scope, provider, entries, wire_id, opts) do
    case Enum.find(entries, &(&1.id == wire_id)) do
      nil ->
        {:error, %{"error" => "That connection does not offer it; call discover_models."}}

      %{linked?: true, model_id: model_id} ->
        {:ok, %{"ok" => true, "already_linked" => true, "id" => model_id, "path" => Paths.model(model_id)}}

      %{model_id: model_id} when is_binary(model_id) ->
        scope
        |> AI.link_discovered_model(provider, model_id)
        |> Args.wrap(fn _ -> %{"ok" => true, "linked" => true, "id" => model_id, "path" => Paths.model(model_id)} end)

      entry ->
        scope
        |> AI.create_discovered_model(provider, Map.take(entry, [:id, :name, :attrs]), opts)
        |> Args.wrap(&model(scope, &1))
    end
  end

  defp fetch_provider(scope, args, key) do
    with {:ok, id} <- Args.uuid(args, key), do: found(AI.get_provider(scope, id))
  end

  defp editable_model(scope, id) do
    with {:ok, id} <- Args.uuid(%{"id" => id}, "id"), do: found(AI.get_editable_model(scope, id))
  end

  # `AI.get_link/1` is unscoped by design; the context's writes check the link's connection, and
  # the preview name is given only to a scope that may edit it.
  defp fetch_link(args, key) do
    with {:ok, id} <- Args.uuid(args, key), do: found(AI.get_link(id))
  end

  defp link_name(scope, id) do
    with %ProviderModel{provider: provider, model: model} <- AI.get_link(id),
         :ok <- Ownership.authorize_edit(scope, provider) do
      "#{model.name} via #{provider.name}"
    else
      _ -> nil
    end
  end

  defp found(nil), do: {:error, Args.error(:not_found)}
  defp found(row), do: {:ok, row}

  defp test_result(%Completion{} = c),
    do: %{"ok" => true, "reply" => Args.cut(c.text), "finish_reason" => c.finish_reason && to_string(c.finish_reason)}

  defp test_result(%Embedding{vectors: [vector | _]}), do: %{"ok" => true, "vector_length" => length(vector)}
  defp test_result(%Embedding{}), do: %{"ok" => true, "vector_length" => 0}

  defp connection(provider) do
    %{
      "id" => provider.id,
      "name" => provider.name,
      "base_url" => provider.base_url,
      "enabled" => provider.enabled,
      "api_key_set" => provider.api_key not in [nil, ""],
      "model_count" => provider.model_count,
      "owner" => Args.owner(provider),
      "path" => Paths.connection(provider.id)
    }
  end

  defp connection_full(provider) do
    provider
    |> connection()
    |> Map.merge(%{
      "adapter" => to_string(provider.adapter),
      "thinking_dialect" => enum_string(provider.thinking_dialect),
      "sampler_dialect" => enum_string(provider.sampler_dialect),
      "priority" => provider.priority,
      "extra_headers" => provider.extra_headers,
      "extra_body" => provider.extra_body,
      "request_timeout_ms" => provider.request_timeout_ms,
      "max_concurrency" => provider.max_concurrency,
      "prompt_progress" => provider.prompt_progress
    })
  end

  # A model whose protected settings `scope` may not read (`Visibility.content_hidden_for?/2`: a
  # Runtime-only site or shared model) gives them as nil, with `"content_hidden"`.
  defp model(scope, model) do
    hidden? = Visibility.content_hidden_for?(scope, model)

    %{
      "id" => model.id,
      "name" => model.name,
      "api_model_id" => if(not hidden?, do: model.api_model_id),
      "completion_mode" => to_string(model.completion_mode),
      "supports_tools" => model.supports_tools,
      "context_window" => model.context_window,
      "owner" => Args.owner(model),
      "path" => Paths.model(model.id)
    }
    |> hidden(hidden?)
  end

  defp model_full(scope, model) do
    fields = @model_keys -- ~w(sampler prompt_cost_per_mtok completion_cost_per_mtok completion_mode image_detail)
    hidden? = Visibility.content_hidden_for?(scope, model)
    protected = if hidden?, do: Enum.map(AI.Model.protected_fields(), &Atom.to_string/1), else: []

    model
    |> Map.take(Enum.map(fields, &String.to_existing_atom/1))
    |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)
    |> Map.merge(model(scope, model))
    |> Map.merge(%{
      "prompt_cost_per_mtok" => decimal_string(model.prompt_cost_per_mtok),
      "completion_cost_per_mtok" => decimal_string(model.completion_cost_per_mtok),
      "image_detail" => enum_string(model.image_detail),
      "sampler" => sampler_map(model.sampler)
    })
    |> Map.new(fn {k, v} -> if k in protected, do: {k, nil}, else: {k, v} end)
  end

  defp hidden(map, true), do: Map.put(map, "content_hidden", true)
  defp hidden(map, false), do: map

  defp link_full(link) do
    %{
      "id" => link.id,
      "provider_id" => link.provider_id,
      "model_id" => link.ai_model_id,
      "enabled" => link.enabled,
      "weight" => link.weight,
      "api_model_id_override" => link.api_model_id_override,
      "extra_body" => link.extra_body,
      "thinking_dialect" => enum_string(link.thinking_dialect),
      "sampler_dialect" => enum_string(link.sampler_dialect),
      # Links have no page of their own: they are edited on the connection's.
      "path" => Paths.connection(link.provider_id)
    }
  end

  defp enum_string(nil), do: nil
  defp enum_string(atom), do: Atom.to_string(atom)

  defp decimal_string(nil), do: nil
  defp decimal_string(%Decimal{} = d), do: Decimal.to_string(d)

  defp sampler_map(nil), do: nil

  defp sampler_map(%SamplerParams{} = sampler) do
    sampler
    |> Map.from_struct()
    |> Map.new(fn
      {:sampler_order, order} -> {"sampler_order", Enum.map(order, &Atom.to_string/1)}
      {:thinking, level} -> {"thinking", enum_string(level)}
      {key, value} -> {Atom.to_string(key), value}
    end)
  end

  defp connection_properties do
    %{
      "name" => string("Display name."),
      "base_url" => string("Base URL, e.g. http://localhost:8080/v1."),
      "adapter" => %{
        "type" => "string",
        "enum" => ["openai_compatible"],
        "description" => "The connection's wire protocol. Only one value exists today."
      },
      "thinking_dialect" =>
        dialect("How a prompt's reasoning effort is translated onto the wire; null clears it (none sent)."),
      "sampler_dialect" =>
        dialect("How typed sampler fields are named on the wire; null clears it to the generic dialect."),
      "enabled" => bool("Whether the connection is used."),
      "priority" => %{
        "type" => "integer",
        "minimum" => 1,
        "maximum" => 5,
        "description" =>
          "1 (preferred) to 5. A lower-priority connection only serves when every priority above it is disabled."
      },
      "extra_headers" =>
        json_object(
          "Extra HTTP headers merged into every request to this connection: string keys, scalar or list-of-scalar values."
        ),
      "extra_body" =>
        json_object(
          "JSON merged into every request body sent to this connection, before the model's and link's layers."
        ),
      "request_timeout_ms" => int("Request timeout in milliseconds. Must be greater than 0."),
      "max_concurrency" => int("How many generations run on this connection at once. Must be at least 1."),
      "prompt_progress" =>
        bool("Ask this connection's backend for prompt-processing progress; some hosted APIs reject the key.")
    }
  end

  defp model_properties do
    limit = "How many of the newest messages with this kind of attachment send it in full; null sends every one. >= 0."
    timing = "Time limit override in seconds; null keeps the tag's default, 0 means no limit. >= 0."

    %{
      "name" => string("Display name."),
      "api_model_id" => string("The exact id sent on the wire, e.g. gemma-4 or claude-sonnet-4-5."),
      "completion_mode" => %{
        "type" => "string",
        "enum" => ["chat", "text", "embedding", "classifier"],
        "description" =>
          "What the model is for. Switching away from chat/text is refused while any chat, participant, memory " <>
            "profile, prompt binding or captioning model still uses it; switching away from embedding deletes its " <>
            "cached vectors."
      },
      "context_window" => int("Context window in tokens. Must be greater than 0."),
      "supports_images" => bool("The model accepts images."),
      "supports_files" => bool("The model accepts document files."),
      "supports_audio" => bool("The model accepts audio."),
      "supports_video" => bool("The model accepts video."),
      "supports_tools" => bool("The model supports native tool calls."),
      "supports_thinking" => bool("The response carries separate reasoning content."),
      "continue_prefill" =>
        bool("Chat mode only: continue a message as a trailing assistant turn instead of a nudge instruction."),
      "reasoning_prefix" =>
        string(
          "Inline tags that open and close this model's reasoning in the raw reply text, e.g. <think> and </think>; set both or neither."
        ),
      "reasoning_suffix" =>
        string(
          "Inline tags that open and close this model's reasoning in the raw reply text, e.g. <think> and </think>; set both or neither."
        ),
      "tokenizer" =>
        string("Hugging Face repo id (owner/name) whose tokenizer counts this model's tokens; null estimates instead."),
      "prompt_cost_per_mtok" =>
        num("Theoretical price per million prompt tokens, used only when the provider reports no real charge."),
      "completion_cost_per_mtok" =>
        num("Theoretical price per million completion tokens, used only when the provider reports no real charge."),
      "notes" => string("Free-form notes."),
      "extra_body" =>
        json_object(
          "JSON merged into every request body for this model, after the connection's layer and before the link's."
        ),
      "caption_model_id" =>
        string(
          "Id of a chat model that supports images, audio or video, used to describe this model's unsupported " <>
            "attachment kinds. Must be the site's or this model's own owner's."
        ),
      "caption_prompt_id" =>
        string("Id of a caption-purpose prompt giving the captioning instruction; omit for the built-in instruction."),
      "caption_max_tokens" => int("Max tokens for a caption reply. Must be greater than 0."),
      "inline_image_limit" => int(limit),
      "inline_audio_limit" => int(limit),
      "inline_video_limit" => int(limit),
      "inline_document_limit" => int(limit),
      "image_detail" => %{
        "type" => "string",
        "enum" => ["low", "auto", "high"],
        "description" => "OpenAI-style image detail sent with each image; null sends none."
      },
      "chat_first_token_seconds" => int("Chat reply, first token. " <> timing),
      "chat_stall_seconds" => int("Chat reply, stall between tokens. " <> timing),
      "chat_deadline_seconds" => int("Chat reply, whole reply. " <> timing),
      "background_first_token_seconds" => int("Background job, first token. " <> timing),
      "background_stall_seconds" => int("Background job, stall between tokens. " <> timing),
      "background_deadline_seconds" => int("Background job, whole reply. " <> timing),
      "sampler" => sampler_schema()
    }
  end

  defp link_properties do
    %{
      "enabled" => bool("Whether this link is used by selection. Defaults to true."),
      "weight" =>
        int(
          "Share of in-tier traffic versus this model's other links; e.g. 3 gets 3x the calls of a weight-1 " <>
            "sibling. Defaults to 1, must be >= 1."
        ),
      "api_model_id_override" =>
        string("This connection's own wire id for the model, when it differs from the model's own api_model_id."),
      "extra_body" =>
        json_object(
          "JSON merged into every request body for this link, last: after the model's and connection's layers."
        ),
      "thinking_dialect" =>
        dialect("Overrides the connection's thinking dialect for this link only; null inherits the connection's."),
      "sampler_dialect" =>
        dialect("Overrides the connection's sampler dialect for this link only; null inherits the connection's.")
    }
  end

  defp sampler_schema do
    strings = fn description -> %{"type" => "array", "items" => %{"type" => "string"}, "description" => description} end

    %{
      "type" => "object",
      "description" => "Sampling defaults; only the given fields change.",
      "properties" => %{
        "temperature" => num("0 to 5."),
        "top_p" => num("Above 0, up to 1."),
        "top_k" => int(">= 0."),
        "min_p" => num("0 to 1."),
        "top_a" => num("0 to 1."),
        "typical_p" => num("Above 0, up to 1."),
        "repetition_penalty" => num("Above 0, up to 4."),
        "frequency_penalty" => num("-2 to 2."),
        "presence_penalty" => num("-2 to 2."),
        "repetition_penalty_range" => int(">= 0."),
        "max_tokens" => int("Reply length cap. Above 0."),
        "seed" => int("Fixed RNG seed."),
        "stop_sequences" => strings.("Strings that end generation; non-empty entries only."),
        "top_n_sigma" => num(">= 0."),
        "dry_multiplier" => num(">= 0."),
        "dry_base" => num(">= 1."),
        "dry_allowed_length" => int(">= 0."),
        "dry_penalty_last_n" => int(">= 0."),
        "dry_sequence_breakers" => strings.(~s(Non-empty strings, e.g. "\\n".)),
        "xtc_threshold" => num("0 to 1."),
        "xtc_probability" => num("0 to 1."),
        "dynatemp_low" => num("0 to 5; set together with dynatemp_high."),
        "dynatemp_high" => num("0 to 5; set together with dynatemp_low."),
        "dynatemp_exponent" => num("Above 0, up to 10; needs a dynatemp range set."),
        "ignore_eos" => bool("Never stop at the model's own end token."),
        "skip_special_tokens" => bool("Strip special tokens from the reply text."),
        "sampler_order" => %{
          "type" => "array",
          "items" => %{"type" => "string", "enum" => Enum.map(SamplerParams.default_sampler_order(), &to_string/1)},
          "description" =>
            "llama.cpp's own sampler names, in the order to apply them. Empty keeps the default order; otherwise " <>
              "every sampler name must appear exactly once."
        },
        "logit_bias" => json_object("Token string to bias: a number from -100 to 100, or false to ban it outright."),
        "thinking" => %{
          "type" => "string",
          "enum" => Enum.map(SamplerParams.thinking_levels(), &to_string/1),
          "description" => "Reasoning effort level."
        },
        "extra" =>
          json_object(
            "Knobs with no typed field above (mirostat, grammar, smoothing): string keys, scalar or list-of-scalar " <>
              "values, sent verbatim."
          )
      },
      "required" => []
    }
  end

  defp object(properties, required), do: %{"type" => "object", "properties" => properties, "required" => required}
  defp string(description), do: %{"type" => "string", "description" => description}
  defp int(description), do: %{"type" => "integer", "description" => description}
  defp num(description), do: %{"type" => "number", "description" => description}
  defp bool(description), do: %{"type" => "boolean", "description" => description}
  defp json_object(description), do: %{"type" => "object", "description" => description}
  defp dialect(description), do: %{"type" => "string", "enum" => @dialects, "description" => description}
end
