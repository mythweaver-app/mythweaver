defmodule Mythweaver.Assistant.Tools.Tags do
  @moduledoc """
  Assistant tools over `Mythweaver.Tags`: the tags the user sees and their rules, the tags on items
  of every taggable kind, finding items by tag as the lists' tag filters do, adding and removing
  tags on items (the bulk Tags action), and the `/tags` manager's create, update and delete.

  An item is `{"kind", "id"}`, reached as the user sees it (a role-play chat, never an assistant
  thread). Its tags come in the editors' two domains: `mine`, the user's own, and `site`,
  everyone's; `Mythweaver.Tags` decides who may write which.
  """

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.AI
  alias Mythweaver.Assistant.Paths
  alias Mythweaver.Assistant.Tool
  alias Mythweaver.Assistant.Tools.Args
  alias Mythweaver.Assistant.Tools.Batch
  alias Mythweaver.Characters
  alias Mythweaver.Chats
  alias Mythweaver.Chats.Chat
  alias Mythweaver.Lore
  alias Mythweaver.Prompts
  alias Mythweaver.Scripts
  alias Mythweaver.Tags
  alias Mythweaver.Tags.Graph
  alias Mythweaver.Tags.Tag

  # Each is a `Mythweaver.Tags.Tagging` kind.
  @kinds ~w[character chat lore_book lore_entry prompt prompt_block script ai_model]

  @kind %{"type" => "string", "enum" => @kinds, "description" => "What the item is."}
  @id %{"type" => "string", "description" => "Id."}
  @item %{"type" => "object", "properties" => %{"kind" => @kind, "id" => @id}, "required" => ["kind", "id"]}

  @tag_props %{
    "text" => %{"type" => "string", "description" => "The tag: name, or namespace:name (e.g. series:metroid)."},
    "displays_as" => %{
      "type" => "string",
      "description" => "Its sibling: the tag shown in its place (e.g. lotr as series:lord of the rings). Empty: none."
    },
    "parents" => %{
      "type" => "array",
      "items" => %{"type" => "string"},
      "description" => "The tags it implies (e.g. character:samus implies series:metroid)."
    }
  }

  @syntax "Tag text is lowercased; namespace:name or a plain name."

  def tools do
    noun = {"tag", "tags"}
    tag_label = fn scope, id -> with %Tag{} = tag <- Tags.get_editable_tag(scope, id), do: Tag.text(tag) end

    [
      %Tool{
        name: "list_tags",
        description:
          "List every tag the user sees (the site's and their own), optionally searched by text, with what each " <>
            "displays as when a sibling rule shows it as another tag, and every tag it implies through parent rules. " <>
            @syntax,
        parameters: object(%{"query" => Args.query_property()}, []),
        kind: :read,
        summary: fn _ -> "List tags" end,
        run: &list_tags/2
      },
      %Tool{
        name: "list_editable_tags",
        description:
          "List the tag rows the user may change or delete (their own, plus the site's for a content manager), " <>
            "optionally searched by text, each with its own sibling and parents and how many items carry it.",
        parameters: object(%{"query" => Args.query_property()}, []),
        kind: :read,
        summary: fn _ -> "List editable tags" end,
        run: &list_editable_tags/2
      },
      %Tool{
        name: "get_item_tags",
        description:
          "Read the tags on items: site_tags (everyone's), my_tags (the user's own) and the tags those imply. " <>
            "Takes 1 to 100 items.",
        parameters: object(%{"items" => Batch.array(@item, "The items.")}, ["items"]),
        kind: :read,
        summary: &Batch.count("Read the tags of", &1["items"], {"item", "items"}),
        run: &get_item_tags/2
      },
      %Tool{
        name: "find_tagged_items",
        description:
          "Find the items whose tags pass every filter, as the lists' tag filters do: tag (it, a sibling of it or " <>
            "a tag implying it is present), -tag (absent), namespace:* (any tag in that namespace). Searches the " <>
            "given kinds, or every kind.",
        parameters:
          object(
            %{
              "tags" => %{
                "type" => "array",
                "items" => %{"type" => "string"},
                "minItems" => 1,
                "description" => ~s|Filters, e.g. ["series:metroid", "-color:red", "character:*"].|
              },
              "kinds" => %{"type" => "array", "items" => @kind, "description" => "Kinds to search; all when left out."},
              "query" => Args.query_property()
            },
            ["tags"]
          ),
        kind: :read,
        summary: fn args -> "Find items tagged #{args["tags"] |> strings() |> Enum.join(" ")}" end,
        run: &find_tagged_items/2
      },
      %Tool{
        name: "tag_items",
        description:
          "Add tags to and remove tags from items, keeping their other tags. domain mine (default): the user's " <>
            "own tags, which only they see, on any item they can see. domain site: everyone's tags, on site items " <>
            "only, for a content manager who may edit the item; chats never take site tags. Removing matches the " <>
            "item's own tags exactly; to drop an implied tag, remove the tag implying it. Tags that don't exist " <>
            "yet are created. #{@syntax} #{Batch.rule()}",
        parameters:
          object(
            %{
              "items" =>
                Batch.array(
                  object(
                    %{
                      "kind" => @kind,
                      "id" => @id,
                      "add" => %{"type" => "array", "items" => %{"type" => "string"}, "description" => "Tags to add."},
                      "remove" => %{
                        "type" => "array",
                        "items" => %{"type" => "string"},
                        "description" => "Tags to remove."
                      },
                      "domain" => %{"type" => "string", "enum" => ~w[mine site], "description" => "Whose tags."}
                    },
                    ["kind", "id"]
                  ),
                  "One object per item."
                )
            },
            ["items"]
          ),
        kind: :write,
        summary: &Batch.count("Retag", &1["items"], {"item", "items"}),
        preview: fn scope, args -> args["items"] |> List.wrap() |> Enum.map(&tag_line(scope, &1)) end,
        run: &tag_items/2
      },
      # The card marks the site tags, the ones everyone sees.
      %{
        Batch.items("create_tags",
          description:
            "Create tags, each with an optional sibling and parents; tags those name that don't exist yet are created. " <>
              "Tags are the user's own unless site is true: everyone's, for a content manager only, and only when the " <>
              "user asks for site tags. #{@syntax}",
          verb: "Create",
          noun: noun,
          name_key: "text",
          item:
            object(
              Map.put(@tag_props, "site", %{
                "type" => "boolean",
                "description" => "A site tag, seen by everyone, instead of the user's own. Default false."
              }),
              ["text"]
            ),
          run: &create/2
        )
        | preview: fn _scope, args -> args["items"] |> List.wrap() |> Enum.map(&create_line/1) end
      },
      Batch.items("update_tags",
        description:
          "Change tags (ids from list_editable_tags): rename, set or clear the sibling, or replace the parents. " <>
            "Fields left out keep their value; a renamed tag stays on its items.",
        verb: "Update",
        noun: noun,
        label: tag_label,
        item: object(Map.put(@tag_props, "id", @id), ["id"]),
        run: fn scope, args ->
          with {:ok, tag} <- editable_tag(scope, args), do: scope |> Tags.update_tag(tag, tag_attrs(args)) |> wrap_tag()
        end
      ),
      Batch.ids("delete_tags",
        description: "Delete tags (ids from list_editable_tags); each leaves every item, sibling and parent rule.",
        verb: "Delete",
        noun: noun,
        label: tag_label,
        run: fn scope, args ->
          with {:ok, tag} <- editable_tag(scope, args) do
            scope |> Tags.delete_tag(tag) |> Args.wrap(&%{"deleted" => true, "id" => &1.id, "text" => Tag.text(&1)})
          end
        end
      )
    ]
  end

  defp object(props, required), do: %{"type" => "object", "properties" => props, "required" => required}

  ## Tags and rules

  defp list_tags(scope, args) do
    graph = Tags.graph(scope.user.id)

    rows =
      for %{text: text, ideal: ideal} <- Tags.vocabulary(scope.user.id, graph) do
        %{"text" => text, "displays_as" => ideal, "implies" => graph |> Graph.ancestors(text) |> sorted()}
      end

    {:ok, Args.list("tags", Args.by_name(rows, args["query"], "text"))}
  end

  defp list_editable_tags(scope, args) do
    rows = for tag <- Tags.list_editable_tags(scope), do: Map.put(tag_map(tag), "usage_count", tag.usage_count)
    {:ok, Args.list("tags", Args.by_name(rows, args["query"], "text"))}
  end

  defp editable_tag(scope, args) do
    with {:ok, id} <- Args.uuid(args, "id") do
      case Tags.get_editable_tag(scope, id) do
        nil -> {:error, Args.error(:not_found)}
        tag -> {:ok, tag}
      end
    end
  end

  # Only the keys given, so an update leaves the rest; a null sibling or parent list clears it.
  defp tag_attrs(args) do
    for {from, to} <- [{"text", "text"}, {"displays_as", "ideal_text"}, {"parents", "parent_texts"}],
        Map.has_key?(args, from),
        into: %{} do
      case {from, args[from]} do
        {"displays_as", nil} -> {to, ""}
        {"parents", nil} -> {to, []}
        {_, value} -> {to, value}
      end
    end
  end

  defp create(scope, %{"site" => true} = args) do
    if Scope.can?(scope, "site.content.manage"),
      do: scope |> Tags.create_tag(tag_attrs(args), site: true) |> wrap_tag(),
      else: {:error, Args.error("Only a content manager creates site tags.")}
  end

  defp create(scope, args), do: scope |> Tags.create_tag(tag_attrs(args)) |> wrap_tag()

  defp create_line(%{"text" => text} = args) when is_binary(text),
    do: if(args["site"] == true, do: "#{text} (site tag)", else: text)

  defp create_line(args) when is_map(args), do: "Untitled"
  defp create_line(_args), do: "Not an object"

  defp wrap_tag({:error, :unauthorized}), do: {:error, Args.error("You may not create or change tags here.")}
  defp wrap_tag(result), do: Args.wrap(result, &tag_map/1)

  defp tag_map(%Tag{} = tag) do
    %{
      "id" => tag.id,
      "text" => Tag.text(tag),
      "owner" => Args.owner(tag),
      "displays_as" => tag.ideal && Tag.text(tag.ideal),
      "parents" => tag.parents |> Enum.map(&Tag.text/1) |> Tags.sort(),
      "path" => Paths.tag(tag.id)
    }
  end

  ## Items

  defp get_item_tags(scope, args) do
    with {:ok, items} <- Batch.fetch_list(args, "items") do
      graph = Tags.graph(scope.user.id)

      Batch.each(items, fn entry ->
        with {:ok, kind, item} <- fetch_item(scope, entry), do: {:ok, item_map(scope, graph, kind, item)}
      end)
    end
  end

  defp find_tagged_items(scope, args) do
    with {:ok, predicates} <- predicates(args["tags"]),
         {:ok, kinds} <- kinds(args["kinds"]) do
      viewer = scope.user.id
      graph = Tags.graph(viewer)

      rows =
        Enum.flat_map(kinds, fn kind ->
          tagging_kind = String.to_existing_atom(kind)
          items = kind |> list(scope) |> Tags.filter_items(tagging_kind, viewer, graph, predicates)
          tags = Tags.tags_by_item(viewer, tagging_kind, Enum.map(items, & &1.id))

          for item <- items do
            %{
              "kind" => kind,
              "id" => item.id,
              "name" => name(item),
              "tags" => graph |> Graph.expand(Map.get(tags, item.id, [])) |> sorted(),
              "path" => path(kind, item.id)
            }
          end
        end)

      {:ok, Args.list("items", Args.by_name(rows, args["query"]))}
    end
  end

  defp predicates(raws) do
    case strings(raws) do
      [] ->
        {:error, Args.error("tags must list at least one filter")}

      raws ->
        case Tags.parse_predicates(raws) do
          {predicates, []} ->
            {:ok, predicates}

          {_, errors} ->
            {:error, Args.error(Enum.map_join(errors, "; ", fn {raw, message} -> "#{raw}: #{message}" end))}
        end
    end
  end

  defp kinds(nil), do: {:ok, @kinds}

  defp kinds(kinds) when is_list(kinds) do
    case Enum.reject(kinds, &(&1 in @kinds)) do
      [] when kinds != [] -> {:ok, Enum.uniq(kinds)}
      _ -> {:error, kind_error()}
    end
  end

  defp kinds(_kinds), do: {:error, kind_error()}

  defp tag_items(scope, args) do
    with {:ok, items} <- Batch.fetch_list(args, "items") do
      graph = Tags.graph(scope.user.id)
      Batch.each(items, &tag_item(scope, graph, &1))
    end
  end

  # A failed item that exists is named as it is stored.
  defp tag_item(scope, graph, args) do
    with {:ok, kind, item} <- fetch_item(scope, args) do
      result =
        with {:ok, add, remove, domain} <- tag_changes(args) do
          case Tags.edit_item_tags(scope, item, domain, add, remove) do
            :ok -> {:ok, item_map(scope, graph, kind, item)}
            {:error, reason} -> {:error, tagging_error(reason, domain)}
          end
        end

      with {:error, error} <- result, do: {:error, Map.put(error, "name", name(item))}
    end
  end

  defp tag_changes(%{"domain" => domain}) when domain not in [nil, "mine", "site"],
    do: {:error, Args.error("domain must be mine or site")}

  defp tag_changes(args) do
    add = args["add"]
    remove = args["remove"]

    cond do
      not text_list?(add) or not text_list?(remove) -> {:error, Args.error("add and remove must be lists of tags")}
      strings(add) == [] and strings(remove) == [] -> {:error, Args.error("Give tags to add or remove.")}
      true -> {:ok, strings(add), strings(remove), if(args["domain"] == "site", do: :site, else: :mine)}
    end
  end

  defp text_list?(nil), do: true
  defp text_list?(list), do: is_list(list) and Enum.all?(list, &is_binary/1)

  defp tagging_error({:invalid, raw, message}, _domain), do: Args.error("#{raw}: #{message}")

  defp tagging_error(:unauthorized, :site),
    do: Args.error("Site tags go only on site items, by a content manager who may edit them; chats take none.")

  defp tagging_error(:unauthorized, :mine), do: Args.error("You may not create tags.")

  defp tag_line(scope, args) when is_map(args) do
    item =
      case fetch_item(scope, args) do
        {:ok, kind, item} -> "#{name(item)} (#{String.replace(kind, "_", " ")})"
        _ -> "Not found: #{inspect(args["id"])}"
      end

    changes = Enum.map(strings(args["add"]), &"+#{&1}") ++ Enum.map(strings(args["remove"]), &"-#{&1}")
    domain = if args["domain"] == "site", do: " (site tags)", else: ""
    "#{item}: #{Enum.join(changes, ", ")}#{domain}"
  end

  defp tag_line(_scope, _args), do: "Not an object"

  defp fetch_item(scope, %{"kind" => kind} = args) when kind in @kinds do
    with {:ok, id} <- Args.uuid(args, "id") do
      case get(kind, scope, id) do
        nil -> {:error, Args.error(:not_found)}
        item -> {:ok, kind, item}
      end
    end
  end

  defp fetch_item(_scope, args) when is_map(args), do: {:error, kind_error()}
  defp fetch_item(_scope, _args), do: {:error, Args.error("Each item must be an object.")}

  defp kind_error, do: Args.error("kind must be one of: #{Enum.join(@kinds, ", ")}")

  defp item_map(scope, graph, kind, item) do
    %{site: site, mine: mine} = Tags.item_tags(scope, item)

    %{
      "kind" => kind,
      "id" => item.id,
      "name" => name(item),
      "site_tags" => site,
      "my_tags" => mine,
      "implied" => Graph.display(graph, site ++ mine).implied,
      "path" => path(kind, item.id)
    }
  end

  # The item as the user sees it: the tagging rules in `Mythweaver.Tags` decide what they may write.
  defp get("character", scope, id), do: Characters.get_character(scope, id)

  defp get("chat", scope, id) do
    case Chats.get_chat(scope, id) do
      %Chat{kind: :roleplay} = chat -> chat
      _ -> nil
    end
  end

  defp get("lore_book", scope, id), do: Lore.get_book(scope, id)
  defp get("lore_entry", scope, id), do: Lore.get_entry(scope, id)
  defp get("prompt", scope, id), do: Prompts.get_prompt(scope, id)
  defp get("prompt_block", scope, id), do: Prompts.get_block(scope, id)
  defp get("script", scope, id), do: Scripts.get_script(scope, id)
  defp get("ai_model", scope, id), do: AI.get_editable_model(scope, id) || AI.get_model(scope, id)

  defp list("character", scope), do: Characters.list_characters(scope)
  defp list("chat", scope), do: Chats.list_chats(scope, :roleplay)
  defp list("lore_book", scope), do: Lore.list_usable_books(scope)
  defp list("lore_entry", scope), do: Lore.list_usable_entries(scope)
  defp list("prompt", scope), do: Prompts.list_prompts(scope)
  defp list("prompt_block", scope), do: Prompts.list_blocks(scope)
  defp list("script", scope), do: Scripts.list_scripts(scope)

  defp list("ai_model", scope),
    do:
      Enum.uniq_by(AI.list_editable_models(scope) ++ AI.list_models(scope) ++ AI.list_embedding_models(scope), & &1.id)

  defp name(%Chat{} = chat), do: Chat.title(chat)
  defp name(%{name: name}), do: name

  defp path("character", id), do: Paths.character(id)
  defp path("chat", id), do: Paths.chat(id)
  defp path("lore_book", id), do: Paths.lore_book(id)
  defp path("lore_entry", id), do: Paths.lore_entry(id)
  defp path("prompt", id), do: Paths.prompt(id)
  defp path("prompt_block", id), do: Paths.prompt_block(id)
  defp path("script", id), do: Paths.script(id)
  defp path("ai_model", id), do: Paths.model(id)

  defp strings(list) when is_list(list), do: Enum.filter(list, &is_binary/1)
  defp strings(_), do: []

  defp sorted(set), do: set |> MapSet.to_list() |> Tags.sort()
end
