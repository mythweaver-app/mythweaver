defmodule Mythweaver.Assistant.Tools.Lore do
  @moduledoc """
  Assistant tools over `Mythweaver.Lore`: lore books and their entries, memberships and order,
  chat/character bindings, filters, pools and moving books to the site.
  """

  alias Mythweaver.Assistant.Paths
  alias Mythweaver.Assistant.Tool
  alias Mythweaver.Assistant.Tools.Args
  alias Mythweaver.Assistant.Tools.Batch
  alias Mythweaver.Assistant.Tools.Preview
  alias Mythweaver.Characters
  alias Mythweaver.Chats
  alias Mythweaver.Chats.Chat
  alias Mythweaver.Lore
  alias Mythweaver.Tags.Tag

  @book_keys ~w(name description global priority scan_depth token_budget recursive site_visibility forced tag_filter_mode)
  @entry_keys ~w(name content activation keywords secondary_keywords outlet placement depth probability
                 case_sensitive secondary_logic match_whole_words custom_outlet sticky cooldown delay
                 exclude_recursion prevent_recursion character_filter_mode ignore_budget role trigger_only
                 delay_until_recursion)
  @pool_keys ~w(name description max_activations)

  @book_props %{
    "name" => %{"type" => "string", "description" => "Book name."},
    "description" => %{"type" => "string", "description" => "What the book covers."},
    "global" => %{"type" => "boolean", "description" => "Active in every chat."},
    "priority" => %{
      "type" => "integer",
      "minimum" => 1,
      "maximum" => 5,
      "description" => "1–5; higher wins the budget."
    },
    "scan_depth" => %{"type" => "integer", "description" => "How many recent messages keywords scan."},
    "token_budget" => %{"type" => "integer", "description" => "Max tokens of entries this book injects."},
    "recursive" => %{"type" => "boolean", "description" => "Entries may activate other entries."},
    "site_visibility" => %{
      "type" => "string",
      "enum" => ~w(readable runtime_only hidden),
      "description" =>
        "What users may see of a site book: readable (everything), runtime_only (names but never content; " <>
          "the model still gets it), or hidden (nothing). Site books only; a personal book must stay readable."
    },
    "forced" => %{
      "type" => "boolean",
      "description" =>
        "Active in every chat and always delivered in the reply, whatever lore settings say. Site books only."
    },
    "tag_filter_mode" => %{
      "type" => "string",
      "enum" => ~w(off include exclude),
      "description" =>
        "off: the tag filter is ignored. include: the book applies only when a participant carries one of its " <>
          "filter_tags. exclude: the book is skipped when a participant carries one."
    }
  }

  @entry_props %{
    "name" => %{"type" => "string", "description" => "Entry name."},
    "content" => %{"type" => "string", "description" => "Text injected when the entry activates."},
    "activation" => %{"type" => "string", "enum" => ~w(keyword constant vector), "description" => "How it activates."},
    "keywords" => %{"type" => "array", "items" => %{"type" => "string"}, "description" => "Trigger keywords."},
    "secondary_keywords" => %{"type" => "array", "items" => %{"type" => "string"}},
    "outlet" => %{
      "type" => "string",
      "enum" => ~w(character examples author_note at_depth custom),
      "description" => "Where it is injected (default character)."
    },
    "placement" => %{"type" => "string", "enum" => ~w(before after), "description" => "Before or after the outlet."},
    "depth" => %{"type" => "integer", "description" => "Message depth, for outlet at_depth."},
    "probability" => %{"type" => "integer", "minimum" => 0, "maximum" => 100},
    "case_sensitive" => %{"type" => "boolean"},
    "secondary_logic" => %{
      "type" => "string",
      "enum" => ~w(and_any and_all not_any not_all),
      "description" => "How secondary_keywords narrow a keyword match: must contain any/all of them, or none/not all."
    },
    "match_whole_words" => %{
      "type" => "boolean",
      "description" => "Keywords match whole words only. Unset inherits the lore settings default."
    },
    "custom_outlet" => %{
      "type" => "string",
      "description" => "The custom outlet's key, required when outlet is custom."
    },
    "sticky" => %{
      "type" => "integer",
      "description" => "Messages the entry stays active after activating, without rematching."
    },
    "cooldown" => %{
      "type" => "integer",
      "description" => "Messages the entry cannot reactivate for, counted from the end of its sticky window."
    },
    "delay" => %{
      "type" => "integer",
      "description" => "The entry never activates before the chat has this many messages."
    },
    "exclude_recursion" => %{
      "type" => "boolean",
      "description" => "This entry's own keywords never scan other entries' injected content."
    },
    "prevent_recursion" => %{
      "type" => "boolean",
      "description" => "This entry's content is never scanned for other entries' keywords."
    },
    "character_filter_mode" => %{
      "type" => "string",
      "enum" => ~w(off include exclude),
      "description" =>
        "off: no filter. include: activates only when a participant is in filter_characters or carries a filter_tags tag. " <>
          "exclude: skipped when one does. Set the filters with set_lore_entry_filters."
    },
    "ignore_budget" => %{
      "type" => "boolean",
      "description" => "This entry's tokens are never counted against its book's token_budget."
    },
    "role" => %{
      "type" => "string",
      "enum" => ~w(system user assistant),
      "description" => "The message role the entry's content is injected as (default system)."
    },
    "trigger_only" => %{
      "type" => "boolean",
      "description" =>
        "The entry activates (taking its pool slot and feeding recursion) but its content is never inserted."
    },
    "delay_until_recursion" => %{
      "type" => "integer",
      "minimum" => 0,
      "description" =>
        "0: no delay. Otherwise the entry only activates on recursion passes, at this level (1 opens first)."
    }
  }

  @pool_props %{
    "name" => %{"type" => "string", "description" => "Pool name."},
    "description" => %{"type" => "string"},
    "max_activations" => %{
      "type" => "integer",
      "minimum" => 1,
      "description" => "How many of the pool's matching entries may activate at once, picked by weight."
    }
  }

  @id %{"type" => "string", "description" => "Id."}
  @ids %{"type" => "array", "items" => @id}
  @texts %{"type" => "array", "items" => %{"type" => "string"}}

  def tools do
    books = {"lore book", "lore books"}
    entries = {"lore entry", "lore entries"}
    pools = {"lore pool", "lore pools"}
    book_label = &book_name/2
    entry_label = &entry_name/2
    pool_label = &pool_name/2

    [
      %Tool{
        name: "list_lore_books",
        description: "List the lore books the user may edit, optionally searched by name.",
        parameters: schema(%{"query" => Args.query_property()}, []),
        kind: :read,
        summary: fn _ -> "List lore books" end,
        run: fn scope, args ->
          rows =
            for b <- Lore.list_books(scope) do
              %{
                "id" => b.id,
                "name" => b.name,
                "description" => Args.cut(b.description),
                "entry_count" => length(b.book_entries),
                "owner" => Args.owner(b),
                "path" => Paths.lore_book(b.id)
              }
            end

          {:ok, Args.list("lore_books", Args.by_name(rows, args["query"]))}
        end
      },
      %Tool{
        name: "get_lore_book",
        description: "A lore book's settings, chat/character bindings, tag filter and entries.",
        parameters: schema(%{"id" => @id}, ["id"]),
        kind: :read,
        summary: fn _ -> "Read lore book" end,
        run: fn scope, args ->
          with {:ok, id} <- Args.uuid(args, "id"), {:ok, book} <- found(Lore.get_book(scope, id)) do
            entries =
              for %{entry: e, enabled: enabled, order: order} <- book.book_entries do
                %{
                  "id" => e.id,
                  "name" => e.name,
                  "activation" => e.activation,
                  "keywords" => e.keywords,
                  "outlet" => e.outlet,
                  "placement" => e.placement,
                  "enabled" => enabled,
                  "order" => order,
                  "path" => Paths.lore_entry(e.id)
                }
              end

            {:ok, book |> book_map() |> Map.put("entries", entries)}
          end
        end
      },
      %Tool{
        name: "list_lore_entries",
        description:
          "List lore entries, optionally searched by name. With book_id, the entries of that book; " <>
            "without it, every entry the user may edit, unlinked ones (in no book) included.",
        parameters: schema(%{"book_id" => @id, "query" => Args.query_property()}, []),
        kind: :read,
        summary: fn args -> if args["book_id"], do: "List a lore book's entries", else: "List lore entries" end,
        run: fn scope, args ->
          with {:ok, rows} <- entry_rows(scope, args) do
            {:ok, Args.list("lore_entries", Args.by_name(rows, args["query"]))}
          end
        end
      },
      Batch.items("create_lore_books",
        description: "Create lore books.",
        verb: "Create",
        noun: books,
        item: schema(@book_props, ["name"]),
        run: fn scope, args ->
          with {:ok, book} <- wrap_error(Lore.create_book(scope, Args.attrs(args, @book_keys))) do
            {:ok, reload_book(scope, book)}
          end
        end
      ),
      Batch.items("update_lore_books",
        description: "Change lore books; only the given fields change.",
        verb: "Update",
        noun: books,
        label: book_label,
        item: schema(Map.put(@book_props, "id", @id), ["id"]),
        run: fn scope, args ->
          with {:ok, book} <- editable_book(scope, args) do
            scope |> Lore.update_book(book, Args.attrs(args, @book_keys)) |> Args.wrap(&book_map/1)
          end
        end
      ),
      Batch.ids("delete_lore_books",
        description: "Delete lore books. Entries only in a deleted book become unlinked.",
        verb: "Delete",
        noun: books,
        label: book_label,
        run: fn scope, args ->
          with {:ok, book} <- editable_book(scope, args) do
            scope |> Lore.delete_book(book) |> Args.wrap(&%{"deleted" => true, "id" => &1.id, "name" => &1.name})
          end
        end
      ),
      %Tool{
        name: "get_lore_entry",
        description:
          "A lore entry's fields and the ids of its books, pools and filter characters, and its filter tags.",
        parameters: schema(%{"id" => @id}, ["id"]),
        kind: :read,
        summary: fn _ -> "Read lore entry" end,
        run: fn scope, args ->
          with {:ok, id} <- Args.uuid(args, "id"), {:ok, entry} <- found(Lore.get_entry(scope, id)) do
            {:ok, entry_map(entry)}
          end
        end
      },
      Batch.items("create_lore_entries",
        description: "Create lore entries, each in the given book when its book_id is set.",
        verb: "Create",
        noun: entries,
        item: schema(Map.put(@entry_props, "book_id", @id), ["name", "content"]),
        run: fn scope, args ->
          with {:ok, book_ids} <- book_ids(args) do
            attrs =
              args
              |> Args.attrs(@entry_keys)
              |> Map.put_new("outlet", "character")
              |> Map.put_new("placement", "before")

            scope |> Lore.create_entry(attrs, book_ids, %{}) |> Args.wrap(&entry_map/1)
          end
        end
      ),
      Batch.items("update_lore_entries",
        description: "Change lore entries; only the given fields change.",
        verb: "Update",
        noun: entries,
        label: entry_label,
        item: schema(Map.put(@entry_props, "id", @id), ["id"]),
        run: fn scope, args ->
          with {:ok, entry} <- editable_entry(scope, args) do
            scope |> Lore.update_entry(entry, Args.attrs(args, @entry_keys)) |> Args.wrap(&entry_map/1)
          end
        end
      ),
      Batch.items("set_lore_entries_enabled",
        description:
          "Switch lore entries on or off. With book_id only in that book; without it in every book the entry is in. " <>
            "A disabled entry never activates from that book.",
        verb: "Enable or disable",
        noun: entries,
        label: entry_label,
        item:
          schema(
            %{
              "id" => @id,
              "enabled" => %{"type" => "boolean", "description" => "true switches it on, false off."},
              "book_id" => %{"type" => "string", "description" => "Only this book; optional."}
            },
            ["id", "enabled"]
          ),
        run: &set_enabled/2
      ),
      Batch.ids("delete_lore_entries",
        description: "Delete lore entries from every book.",
        verb: "Delete",
        noun: entries,
        label: entry_label,
        run: fn scope, args ->
          with {:ok, entry} <- editable_entry(scope, args) do
            scope |> Lore.delete_entry(entry) |> Args.wrap(&%{"deleted" => true, "id" => &1.id, "name" => &1.name})
          end
        end
      ),
      Batch.items("set_lore_entry_books",
        description:
          "Set which books lore entries are in. book_ids replaces an entry's books exactly; [] unlinks it (it then " <>
            "never activates). New memberships land at the top of their book.",
        verb: "Set books of",
        noun: entries,
        label: entry_label,
        item:
          schema(
            %{
              "id" => @id,
              "book_ids" => Map.put(@ids, "description", "The entry's books; replaces its current ones exactly.")
            },
            ["id", "book_ids"]
          ),
        run: fn scope, args ->
          with {:ok, entry} <- editable_entry(scope, args),
               {:ok, book_ids} <- Args.uuid_list(args, "book_ids"),
               {:ok, _} <- wrap_error(Lore.set_entry_books(scope, entry, book_ids)) do
            {:ok, entry_map(Lore.get_editable_entry(scope, entry.id))}
          end
        end
      ),
      %Tool{
        name: "reorder_lore_book_entries",
        description:
          "Set a lore book's entry order, top first (the top entry sorts first). entry_ids must be every entry " <>
            "currently in the book, each once. Only this book's order changes.",
        parameters:
          schema(
            %{
              "book_id" => @id,
              "entry_ids" => Map.put(@ids, "description", "Every entry currently in the book, top first.")
            },
            ["book_id", "entry_ids"]
          ),
        kind: :write,
        summary: fn _ -> "Reorder a lore book's entries" end,
        preview: fn scope, args -> [Preview.row(book_label, scope, args["book_id"])] end,
        run: fn scope, args ->
          with {:ok, book} <- editable_book(scope, args, "book_id"),
               {:ok, entry_ids} <- Args.uuid_list(args, "entry_ids"),
               {:ok, _} <- wrap_error(Lore.reorder_book_entries(scope, book, entry_ids)) do
            {:ok, %{"reordered" => true, "book_id" => book.id, "path" => Paths.lore_book(book.id)}}
          end
        end
      },
      Batch.items("set_lore_entry_order",
        description: "Set lore entries' order number in one book each; higher sorts first. Other books keep theirs.",
        verb: "Set order of",
        noun: entries,
        label: entry_label,
        item:
          schema(
            %{
              "id" => @id,
              "book_id" => @id,
              "order" => %{
                "type" => "integer",
                "minimum" => 0,
                "description" => "Position in this book only; higher sorts first."
              }
            },
            ["id", "book_id", "order"]
          ),
        run: fn scope, args ->
          with {:ok, entry} <- editable_entry(scope, args),
               {:ok, book} <- editable_book(scope, args, "book_id"),
               {:ok, _} <- wrap_error(Lore.set_membership_order(scope, book, entry.id, args["order"])) do
            {:ok, entry_map(Lore.get_editable_entry(scope, entry.id))}
          end
        end
      ),
      Batch.items("set_lore_book_chats",
        description:
          "Bind lore books to the user's own role-play chats. chat_ids replaces a book's chat bindings exactly; " <>
            "other users' chats already bound are kept.",
        verb: "Set chats of",
        noun: books,
        label: book_label,
        item:
          schema(
            %{"id" => @id, "chat_ids" => Map.put(@ids, "description", "Chat ids from list_chats; [] unbinds all.")},
            ["id", "chat_ids"]
          ),
        run: fn scope, args ->
          with {:ok, book} <- editable_book(scope, args),
               {:ok, chat_ids} <- Args.uuid_list(args, "chat_ids"),
               {:ok, _} <- wrap_error(Lore.set_book_chats(scope, book, chat_ids)) do
            {:ok, reload_book(scope, book)}
          end
        end
      ),
      Batch.items("set_lore_book_characters",
        description:
          "Bind lore books to characters: the book applies in any chat the character is in. character_ids " <>
            "replaces a book's character bindings exactly.",
        verb: "Set characters of",
        noun: books,
        label: book_label,
        item:
          schema(
            %{"id" => @id, "character_ids" => Map.put(@ids, "description", "Character ids; [] unbinds all.")},
            ["id", "character_ids"]
          ),
        run: fn scope, args ->
          with {:ok, book} <- editable_book(scope, args),
               {:ok, character_ids} <- Args.uuid_list(args, "character_ids"),
               {:ok, _} <- wrap_error(Lore.set_book_characters(scope, book, character_ids)) do
            {:ok, reload_book(scope, book)}
          end
        end
      ),
      %{
        Batch.items("set_lore_bindings_enabled",
          description: "Switch a lore book's chat or character binding on or off, without removing it.",
          verb: "Set",
          noun: {"lore binding", "lore bindings"},
          item:
            schema(
              %{
                "book_id" => @id,
                "kind" => %{"type" => "string", "enum" => ~w(chat character), "description" => "Which binding."},
                "target_id" => %{"type" => "string", "description" => "The chat id or character id, matching kind."},
                "enabled" => %{"type" => "boolean"}
              },
              ["book_id", "kind", "target_id", "enabled"]
            ),
          run: &set_binding/2
        )
        | preview: fn scope, args -> args["items"] |> List.wrap() |> Enum.map(&binding_line(scope, &1)) end
      },
      Batch.items("set_lore_entry_filters",
        description:
          "Set lore entries' character and/or tag filter (used when character_filter_mode is include/exclude). " <>
            "Only the fields given change; [] clears one. At least one of character_ids or tags is required.",
        verb: "Set filters of",
        noun: entries,
        label: entry_label,
        item:
          schema(
            %{
              "id" => @id,
              "character_ids" => Map.put(@ids, "description", "Replaces the entry's filter characters."),
              "tags" =>
                Map.put(@texts, "description", "Tag texts (e.g. series:metroid); replaces the entry's filter tags.")
            },
            ["id"]
          ),
        run: &set_entry_filters/2
      ),
      Batch.items("set_lore_book_filter_tags",
        description: "Set lore books' tag filter (used when tag_filter_mode is include/exclude).",
        verb: "Set filter tags of",
        noun: books,
        label: book_label,
        item:
          schema(
            %{"id" => @id, "tags" => Map.put(@texts, "description", "Replaces the book's tag filter exactly.")},
            ["id", "tags"]
          ),
        run: fn scope, args ->
          with {:ok, book} <- editable_book(scope, args),
               {:ok, tags} <- texts(args, "tags"),
               {:ok, _} <- wrap_error(Lore.set_book_filter_tags(scope, book, tags)) do
            {:ok, reload_book(scope, book)}
          end
        end
      ),
      %Tool{
        name: "list_lore_pools",
        description:
          "List the lore pools the user may edit: groups of entries of which at most max_activations activate, " <>
            "picked by weight.",
        parameters: schema(%{"query" => Args.query_property()}, []),
        kind: :read,
        summary: fn _ -> "List lore pools" end,
        run: fn scope, args ->
          rows = for p <- Lore.list_pools(scope), do: Map.put(pool_map(p), "entry_count", length(p.pool_entries))
          {:ok, Args.list("lore_pools", Args.by_name(rows, args["query"]))}
        end
      },
      %Tool{
        name: "get_lore_pool",
        description: "A lore pool's settings and its entries with their weights.",
        parameters: schema(%{"id" => @id}, ["id"]),
        kind: :read,
        summary: fn _ -> "Read lore pool" end,
        run: fn scope, args ->
          with {:ok, pool} <- editable_pool(scope, args) do
            entries =
              for pe <- pool.pool_entries,
                  do: %{
                    "id" => pe.entry.id,
                    "name" => pe.entry.name,
                    "weight" => pe.weight,
                    "override" => pe.override,
                    "scored" => pe.scored
                  }

            {:ok, pool |> pool_map() |> Map.put("entries", entries)}
          end
        end
      },
      Batch.items("create_lore_pools",
        description: "Create lore pools; add entries with set_lore_entry_pools.",
        verb: "Create",
        noun: pools,
        item: schema(@pool_props, ["name"]),
        run: fn scope, args -> scope |> Lore.create_pool(Args.attrs(args, @pool_keys)) |> Args.wrap(&pool_map/1) end
      ),
      Batch.items("update_lore_pools",
        description: "Change lore pools; only the given fields change.",
        verb: "Update",
        noun: pools,
        label: pool_label,
        item: schema(Map.put(@pool_props, "id", @id), ["id"]),
        run: fn scope, args ->
          with {:ok, pool} <- editable_pool(scope, args) do
            scope |> Lore.update_pool(pool, Args.attrs(args, @pool_keys)) |> Args.wrap(&pool_map/1)
          end
        end
      ),
      Batch.ids("delete_lore_pools",
        description: "Delete lore pools. Their entries stay.",
        verb: "Delete",
        noun: pools,
        label: pool_label,
        run: fn scope, args ->
          with {:ok, pool} <- editable_pool(scope, args) do
            scope |> Lore.delete_pool(pool) |> Args.wrap(&%{"deleted" => true, "id" => &1.id, "name" => &1.name})
          end
        end
      ),
      Batch.items("set_lore_entry_pools",
        description:
          "Set which pools lore entries are in. pool_ids replaces an entry's pools exactly; new ones take the default weight.",
        verb: "Set pools of",
        noun: entries,
        label: entry_label,
        item:
          schema(%{"id" => @id, "pool_ids" => Map.put(@ids, "description", "Pool ids; [] removes it from all.")}, [
            "id",
            "pool_ids"
          ]),
        run: fn scope, args ->
          with {:ok, entry} <- editable_entry(scope, args),
               {:ok, pool_ids} <- Args.uuid_list(args, "pool_ids"),
               {:ok, _} <- wrap_error(Lore.set_entry_pools(scope, entry, pool_ids)) do
            {:ok, entry_map(Lore.get_editable_entry(scope, entry.id))}
          end
        end
      ),
      Batch.items("set_lore_pool_weights",
        description:
          "Set entries' weights and flags within a pool; a higher weight is picked more often. override: the " <>
            "entry wins over non-override members, by highest order. scored: members whose keywords match " <>
            "fewer than the best drop out first.",
        verb: "Set weights in",
        noun: pools,
        label: pool_label,
        item:
          schema(
            %{
              "id" => Map.put(@id, "description", "Pool id."),
              "entry_id" => @id,
              "weight" => %{"type" => "integer", "minimum" => 0},
              "override" => %{"type" => "boolean"},
              "scored" => %{"type" => "boolean"}
            },
            ["id", "entry_id"]
          ),
        run: &set_pool_weight/2
      ),
      %{
        Batch.items("transfer_lore_books",
          description:
            "Move the user's own lore books and their entries to the site, removing every link the site may not " <>
              "hold. A site book is never made personal again. Needs the site content permission and sudo mode.",
          verb: "Transfer",
          noun: books,
          label: book_label,
          item: schema(%{"id" => @id}, ["id"]),
          run: &transfer/2
        )
        | preview: fn scope, args -> args["items"] |> List.wrap() |> Enum.map(&transfer_line(scope, &1)) end
      }
    ]
  end

  defp schema(props, required), do: %{"type" => "object", "properties" => props, "required" => required}

  defp found(nil), do: {:error, Args.error(:not_found)}
  defp found(row), do: {:ok, row}

  defp wrap_error({:error, reason}), do: {:error, Args.error(reason)}
  defp wrap_error(ok), do: ok

  defp book_name(scope, id), do: with(%{name: name} <- Lore.get_editable_book(scope, id), do: name)
  defp entry_name(scope, id), do: with(%{name: name} <- Lore.get_editable_entry(scope, id), do: name)
  defp pool_name(scope, id), do: with(%{name: name} <- Lore.get_pool(scope, id), do: name)
  defp chat_name(scope, id), do: with(%Chat{} = chat <- Chats.get_chat(scope, id), do: Chat.title(chat))
  defp character_name(scope, id), do: with(%{name: name} <- Characters.get_character(scope, id), do: name)

  defp editable_book(scope, args, key \\ "id") do
    with {:ok, id} <- Args.uuid(args, key), do: found(Lore.get_editable_book(scope, id))
  end

  defp editable_entry(scope, args) do
    with {:ok, id} <- Args.uuid(args, "id"), do: found(Lore.get_editable_entry(scope, id))
  end

  defp editable_pool(scope, args) do
    with {:ok, id} <- Args.uuid(args, "id"), do: found(Lore.get_pool(scope, id))
  end

  # A book written outside `update_book/3` comes back without its bindings preloaded.
  defp reload_book(scope, book), do: book_map(Lore.get_editable_book(scope, book.id) || Lore.get_book(scope, book.id))

  defp texts(args, key) do
    case args[key] do
      list when is_list(list) -> if Enum.all?(list, &is_binary/1), do: {:ok, list}, else: texts_error(key)
      _ -> texts_error(key)
    end
  end

  defp texts_error(key), do: {:error, Args.error("#{key} must be a list of strings.")}

  defp book_ids(%{"book_id" => id} = args) when not is_nil(id) do
    with {:ok, id} <- Args.uuid(args, "book_id"), do: {:ok, [id]}
  end

  defp book_ids(_), do: {:ok, []}

  defp set_enabled(scope, args) do
    with {:ok, entry} <- editable_entry(scope, args),
         {:ok, enabled} <- enabled(args),
         {:ok, books} <- target_books(entry, args),
         :ok <- set_each(scope, books, entry.id, enabled) do
      {:ok, entry_map(Lore.get_editable_entry(scope, entry.id))}
    end
  end

  defp enabled(%{"enabled" => enabled}) when is_boolean(enabled), do: {:ok, enabled}
  defp enabled(_args), do: {:error, Args.error("enabled must be true or false.")}

  defp target_books(entry, %{"book_id" => id} = args) when not is_nil(id) do
    with {:ok, id} <- Args.uuid(args, "book_id") do
      case Enum.find(entry.books, &(&1.id == id)) do
        nil -> {:error, Args.error(:not_a_member)}
        book -> {:ok, [book]}
      end
    end
  end

  defp target_books(%{books: []}, _args), do: {:error, Args.error("The entry is in no book, so it never activates.")}
  defp target_books(%{books: books}, _args), do: {:ok, books}

  defp set_each(scope, books, entry_id, enabled) do
    Enum.reduce_while(books, :ok, fn book, :ok ->
      case Lore.set_membership_enabled(scope, book, entry_id, enabled) do
        {:ok, _} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, Args.error(reason)}}
      end
    end)
  end

  defp set_binding(scope, %{"kind" => kind} = args) do
    with {:ok, book} <- editable_book(scope, args, "book_id"),
         {:ok, target_id} <- Args.uuid(args, "target_id"),
         {:ok, enabled} <- enabled(args),
         {:ok, binding} <- find_binding(book, kind, target_id) do
      scope
      |> Lore.set_binding_enabled(binding, enabled)
      |> Args.wrap(&%{"book_id" => book.id, "kind" => kind, "target_id" => target_id, "enabled" => &1.enabled})
    end
  end

  defp find_binding(book, "chat", target_id) do
    case Enum.find(book.book_chats, &(&1.chat_id == target_id)) do
      nil -> {:error, Args.error("That book is not bound to that chat.")}
      binding -> {:ok, binding}
    end
  end

  defp find_binding(book, "character", target_id) do
    case Enum.find(book.book_characters, &(&1.character_id == target_id)) do
      nil -> {:error, Args.error("That book is not bound to that character.")}
      binding -> {:ok, binding}
    end
  end

  defp find_binding(_book, _kind, _target_id), do: {:error, Args.error("kind must be chat or character.")}

  defp binding_line(scope, %{"book_id" => book_id, "kind" => kind, "target_id" => id, "enabled" => enabled})
       when kind in ["chat", "character"] do
    label = if kind == "chat", do: &chat_name/2, else: &character_name/2
    toggle = if enabled == true, do: "enable", else: "disable"
    "#{Preview.row(&book_name/2, scope, book_id)} ↔ #{kind} #{Preview.row(label, scope, id)}: #{toggle}"
  end

  defp binding_line(_scope, _item), do: "Not a binding"

  defp set_entry_filters(scope, args) do
    with :ok <- filters_given(args),
         {:ok, entry} <- editable_entry(scope, args),
         {:ok, _} <- maybe_filter_characters(scope, entry, args),
         {:ok, _} <- maybe_filter_tags(scope, entry, args) do
      {:ok, entry_map(Lore.get_editable_entry(scope, entry.id))}
    end
  end

  defp filters_given(args) do
    if is_nil(args["character_ids"]) and is_nil(args["tags"]),
      do: {:error, Args.error("character_ids or tags is required.")},
      else: :ok
  end

  defp maybe_filter_characters(_scope, _entry, %{"character_ids" => nil}), do: {:ok, :ok}

  defp maybe_filter_characters(scope, entry, %{"character_ids" => _} = args) do
    with {:ok, ids} <- Args.uuid_list(args, "character_ids"),
         do: wrap_error(Lore.set_entry_filter_characters(scope, entry, ids))
  end

  defp maybe_filter_characters(_scope, _entry, _args), do: {:ok, :ok}

  defp maybe_filter_tags(_scope, _entry, %{"tags" => nil}), do: {:ok, :ok}

  defp maybe_filter_tags(scope, entry, %{"tags" => _} = args) do
    with {:ok, tags} <- texts(args, "tags"), do: wrap_error(Lore.set_entry_filter_tags(scope, entry, tags))
  end

  defp maybe_filter_tags(_scope, _entry, _args), do: {:ok, :ok}

  defp set_pool_weight(scope, args) do
    attrs = args |> Args.attrs(~w(weight override scored)) |> Map.new(fn {k, v} -> {String.to_existing_atom(k), v} end)

    with {:ok, pool} <- editable_pool(scope, args),
         {:ok, entry_id} <- Args.uuid(args, "entry_id"),
         {:ok, _} <- pool_membership(pool, entry_id),
         {:ok, entry} <- found(Lore.get_editable_entry(scope, entry_id)),
         {:ok, :ok} <- wrap_error(Lore.set_pool_memberships(scope, entry, %{pool.id => attrs})) do
      {:ok, membership} = pool_membership(Lore.get_pool(scope, pool.id), entry_id)

      {:ok,
       %{
         "pool_id" => membership.lore_pool_id,
         "entry_id" => membership.lore_entry_id,
         "weight" => membership.weight,
         "override" => membership.override,
         "scored" => membership.scored
       }}
    end
  end

  defp pool_membership(pool, entry_id) do
    case Enum.find(pool.pool_entries, &(&1.lore_entry_id == entry_id)) do
      nil -> {:error, Args.error("That entry is not in that pool.")}
      membership -> {:ok, membership}
    end
  end

  defp transfer(scope, args) do
    with {:ok, book} <- editable_book(scope, args),
         {:ok, impact} <- wrap_error(Lore.transfer_impact(scope, book, :site)),
         {:ok, moved} <- wrap_error(Lore.transfer_book(scope, book, :site)) do
      {:ok, scope |> reload_book(moved) |> Map.put("impact", impact_map(impact))}
    end
  end

  defp transfer_line(scope, %{"id" => id} = item) do
    name = Preview.row(&book_name/2, scope, id)

    with {:ok, book} <- editable_book(scope, item),
         {:ok, impact} <- Lore.transfer_impact(scope, book, :site) do
      changes =
        impact
        |> impact_map()
        |> Enum.sort()
        |> Enum.map_join(", ", fn {k, n} -> "#{n} #{String.replace(k, "_", " ")}" end)

      "#{name} → site" <> if(changes == "", do: "", else: ": #{changes}")
    else
      _ -> name
    end
  end

  defp transfer_line(_scope, _item), do: "Not found: nil"

  defp impact_map(impact), do: for({kind, n} <- impact, n > 0, into: %{}, do: {Atom.to_string(kind), n})

  # A book's entries in the book's injection order, as its editor lists them (a usable book may
  # hold entries the user cannot edit); otherwise the editable entries, which the lore editor's
  # search covers.
  defp entry_rows(scope, %{"book_id" => id} = args) when not is_nil(id) do
    with {:ok, id} <- Args.uuid(args, "book_id"), {:ok, book} <- found(Lore.get_book(scope, id)) do
      {:ok, scope |> Lore.list_entries_in_book(book) |> Enum.map(&entry_row/1)}
    end
  end

  defp entry_rows(scope, _args), do: {:ok, scope |> Lore.list_entries() |> Enum.map(&entry_row/1)}

  defp entry_row(entry) do
    %{
      "id" => entry.id,
      "name" => entry.name,
      "activation" => entry.activation,
      "keywords" => entry.keywords,
      "outlet" => entry.outlet,
      "content" => Args.cut(entry.content),
      "book_ids" => Enum.map(entry.books, & &1.id),
      "disabled_book_ids" => disabled_book_ids(entry),
      "path" => Paths.lore_entry(entry.id)
    }
  end

  defp book_map(book) do
    book
    |> Map.take(Enum.map(["id" | @book_keys], &String.to_existing_atom/1))
    |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)
    |> Map.merge(%{
      "kind" => book.kind,
      "owner" => Args.owner(book),
      "path" => Paths.lore_book(book.id),
      "chat_ids" => Enum.map(book.book_chats, & &1.chat_id),
      "disabled_chat_ids" => for(%{enabled: false, chat_id: id} <- book.book_chats, do: id),
      "character_ids" => Enum.map(book.book_characters, & &1.character_id),
      "disabled_character_ids" => for(%{enabled: false, character_id: id} <- book.book_characters, do: id),
      "filter_tags" => Enum.map(book.filter_tags, &Tag.text/1)
    })
  end

  defp pool_map(pool) do
    %{
      "id" => pool.id,
      "name" => pool.name,
      "description" => Args.cut(pool.description),
      "max_activations" => pool.max_activations,
      "owner" => Args.owner(pool)
    }
  end

  defp entry_map(entry) do
    entry
    |> Map.take([:id | Enum.map(@entry_keys, &String.to_existing_atom/1)])
    |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)
    |> Map.merge(%{
      "book_ids" => Enum.map(entry.books, & &1.id),
      "disabled_book_ids" => disabled_book_ids(entry),
      "pool_ids" => Enum.map(entry.pools, & &1.id),
      "filter_character_ids" => Enum.map(entry.filter_characters, & &1.id),
      "filter_tags" => Enum.map(entry.filter_tags, &Tag.text/1),
      "owner" => Args.owner(entry),
      "path" => Paths.lore_entry(entry.id)
    })
  end

  defp disabled_book_ids(entry), do: for(%{enabled: false, lore_book_id: id} <- entry.book_entries, do: id)
end
