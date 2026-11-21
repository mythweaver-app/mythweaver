defmodule Mythweaver.Assistant.Tools.TagsTest do
  use Mythweaver.DataCase

  alias Mythweaver.Assistant.Tools
  alias Mythweaver.Assistant.Tools.Args
  alias Mythweaver.Characters
  alias Mythweaver.Lore
  alias Mythweaver.Schema
  alias Mythweaver.Tags
  alias Mythweaver.Tags.Tag

  defp run!(scope, name, args) do
    {:ok, tool} = Tools.fetch(name)
    Tools.run(scope, tool, args)
  end

  defp preview(scope, name, args) do
    {:ok, tool} = Tools.fetch(name)
    tool.preview.(scope, args)
  end

  defp character!(scope, name, opts \\ []) do
    {:ok, character} = Characters.create_character(scope, %{name: name}, opts)
    character
  end

  defp entry!(scope, name) do
    attrs = %{"name" => name, "content" => "c", "keywords" => [name], "outlet" => "character"}
    {:ok, entry} = Lore.create_entry(scope, attrs, [], %{})
    entry
  end

  test "tag_items edits each item's own tags across kinds and names the ones refused" do
    site = scope!()
    user = scope!(%{role: :user})
    shared = character!(site, "Samus", site: true)
    entry = entry!(user, "Zebes")
    :ok = Tags.set_item_tags(user, shared, :mine, ["keep", "old"])

    items = [
      %{"kind" => "character", "id" => shared.id, "add" => ["Series:Metroid"], "remove" => ["old"]},
      %{"kind" => "lore_entry", "id" => entry.id, "add" => ["place:planet"]},
      %{"kind" => "character", "id" => shared.id, "add" => ["x"], "domain" => "site"}
    ]

    assert preview(user, "tag_items", %{"items" => items}) == [
             "Samus (character): +Series:Metroid, -old",
             "Zebes (lore entry): +place:planet",
             "Samus (character): +x (site tags)"
           ]

    assert {:ok, %{"done" => [character, lore], "failed" => [%{"index" => 2, "name" => "Samus", "error" => _}]}} =
             run!(user, "tag_items", %{"items" => items})

    assert %{"my_tags" => ["series:metroid", "keep"], "site_tags" => []} = character
    assert %{"my_tags" => ["place:planet"], "path" => "/lore/entries/" <> _} = lore
    assert Tags.item_tags(site, shared) == %{site: [], mine: []}
  end

  test "find_tagged_items applies siblings, parents, exclusions and namespace wildcards" do
    scope = scope!()
    {:ok, _} = Tags.create_tag(scope, %{"text" => "character:samus", "parent_texts" => ["series:metroid"]})
    {:ok, _} = Tags.create_tag(scope, %{"text" => "metroid", "ideal_text" => "series:metroid"})
    samus = character!(scope, "Samus")
    ridley = character!(scope, "Ridley")
    entry = entry!(scope, "Zebes")
    :ok = Tags.set_item_tags(scope, samus, :mine, ["character:samus"])
    :ok = Tags.set_item_tags(scope, ridley, :mine, ["metroid", "villain"])
    :ok = Tags.set_item_tags(scope, entry, :mine, ["metroid"])

    find = &run!(scope, "find_tagged_items", &1)

    assert {:ok, %{"items" => rows, "total" => 3}} = find.(%{"tags" => ["metroid"]})
    assert rows |> Enum.map(& &1["name"]) |> Enum.sort() == ["Ridley", "Samus", "Zebes"]

    assert {:ok, %{"items" => [%{"name" => "Samus", "tags" => ["character:samus", "series:metroid"]}]}} =
             find.(%{"tags" => ["series:metroid", "-villain", "character:*"]})

    assert {:ok, %{"items" => [%{"kind" => "lore_entry", "name" => "Zebes"}]}} =
             find.(%{"tags" => ["metroid"], "kinds" => ["lore_entry"]})

    assert {:error, %{"error" => "a*: * must be a namespace wildcard like series:*"}} = find.(%{"tags" => ["a*"]})
  end

  test "get_item_tags lists hard tags by domain and what they imply" do
    scope = scope!()
    {:ok, _} = Tags.create_tag(scope, %{"text" => "character:samus", "parent_texts" => ["series:metroid"]}, site: true)
    samus = character!(scope, "Samus", site: true)
    :ok = Tags.set_item_tags(scope, samus, :site, ["character:samus"])
    unknown = Schema.generate_id()

    assert {:ok, %{"done" => [row], "failed" => [%{"index" => 1, "error" => "Not found."}]}} =
             run!(scope, "get_item_tags", %{
               "items" => [%{"kind" => "character", "id" => samus.id}, %{"kind" => "prompt", "id" => unknown}]
             })

    assert %{"site_tags" => ["character:samus"], "my_tags" => [], "implied" => ["series:metroid"]} = row
  end

  test "create, update and delete tags with their sibling and parents" do
    scope = scope!(%{role: :user})

    items = [%{"text" => "LOTR", "displays_as" => "series:lord of the rings", "parents" => ["genre:fantasy"]}]
    assert preview(scope, "create_tags", %{"items" => items}) == ["LOTR"]

    assert {:ok, %{"done" => [created]}} = run!(scope, "create_tags", %{"items" => items})

    assert %{
             "id" => id,
             "text" => "lotr",
             "owner" => "personal",
             "displays_as" => "series:lord of the rings",
             "parents" => ["genre:fantasy"]
           } = created

    assert {:ok, %{"tags" => [%{"text" => "lotr", "displays_as" => "series:lord of the rings"}]}} =
             run!(scope, "list_tags", %{"query" => "lotr"})

    assert preview(scope, "update_tags", %{"items" => [%{"id" => id, "displays_as" => nil}]}) == [
             "lotr: displays as nil"
           ]

    assert {:ok, %{"done" => [%{"displays_as" => nil, "parents" => ["genre:fantasy"]}]}} =
             run!(scope, "update_tags", %{"items" => [%{"id" => id, "displays_as" => nil}]})

    assert {:error, %{"failed" => [%{"name" => "-bad", "error" => "invalid"}]}} =
             run!(scope, "create_tags", %{"items" => [%{"text" => "-bad"}]})

    assert {:ok, %{"done" => [%{"deleted" => true, "text" => "lotr"}]}} = run!(scope, "delete_tags", %{"ids" => [id]})
    assert Tags.get_editable_tag(scope, id) == nil
  end

  test "create_tags makes the user's own tags unless site is asked for, even for a content manager" do
    manager = scope!()
    user = scope!(%{role: :user})
    items = [%{"text" => "mine", "parents" => ["implied"]}, %{"text" => "shared", "site" => true}]

    assert preview(manager, "create_tags", %{"items" => items}) == ["mine", "shared (site tag)"]

    assert {:ok, %{"done" => [%{"owner" => "personal"}, %{"owner" => "site"}]}} =
             run!(manager, "create_tags", %{"items" => items})

    assert manager |> Tags.list_editable_tags() |> Map.new(&{Tag.text(&1), Args.owner(&1)}) == %{
             "mine" => "personal",
             "implied" => "personal",
             "shared" => "site"
           }

    assert {:error, %{"failed" => [%{"name" => "x", "error" => "Only a content manager creates site tags."}]}} =
             run!(user, "create_tags", %{"items" => [%{"text" => "x", "site" => true}]})
  end
end
