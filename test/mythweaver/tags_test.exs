defmodule Mythweaver.TagsTest do
  use Mythweaver.DataCase

  alias Mythweaver.Characters
  alias Mythweaver.Chats
  alias Mythweaver.Tags
  alias Mythweaver.Tags.Graph

  defp character!(scope, name \\ "C", opts \\ []) do
    {:ok, character} = Characters.create_character(scope, %{name: name}, opts)
    character
  end

  defp tag!(scope, attrs, opts \\ []) do
    {:ok, tag} = Tags.create_tag(scope, attrs, opts)
    tag
  end

  defp expanded(owner_id, character) do
    texts = Map.get(Tags.tags_by_item(owner_id, :character, [character.id]), character.id, [])
    Graph.expand(Tags.graph(owner_id), texts)
  end

  defp filter(owner_id, characters, chips) do
    {predicates, []} = Tags.parse_predicates(chips)
    Tags.filter_items(characters, :character, owner_id, Tags.graph(owner_id), predicates)
  end

  describe "normalize/1" do
    test "trims, downcases, collapses whitespace and splits the namespace" do
      assert Tags.normalize("  Series:The  Lord ") == {:ok, {"series", "the lord", "series:the lord"}}
      assert Tags.normalize(":Smile") == {:ok, {"", "smile", "smile"}}
    end

    test "refuses texts that would read as filter syntax" do
      assert Tags.normalize("-x") == {:error, "can't start with -"}
      assert Tags.normalize("a*") == {:error, "can't contain *"}
      assert Tags.normalize(":") == {:error, "needs a name"}
      assert Tags.normalize(String.duplicate("n", 65) <> ":x") == {:error, "is too long"}
    end
  end

  describe "parse_predicates/1" do
    test "splits valid chips from invalid ones" do
      assert Tags.parse_predicates(["Series:Metroid", "-color:red", "Character:*", "*", "-"]) ==
               {[
                  {:include, {:tag, "series:metroid"}},
                  {:exclude, {:tag, "color:red"}},
                  {:include, {:namespace, "character"}}
                ], [{"*", "* must be a namespace wildcard like series:*"}, {"-", "needs a tag"}]}
    end
  end

  test "sort/1 puts namespaced texts first" do
    assert Tags.sort(["smile", "series:b", "a", "character:z"]) == ["character:z", "series:b", "a", "smile"]
  end

  describe "siblings" do
    test "a site sibling resolves for everyone; a user's own rule wins for them alone" do
      site = scope!()
      user = scope!(%{role: :user})
      tag!(site, %{"text" => "lotr", "ideal_text" => "series:lotr"}, site: true)

      character = character!(user)
      assert :ok = Tags.set_item_tags(user, character, :mine, ["lotr"])
      assert MapSet.member?(expanded(user.user.id, character), "series:lotr")

      lotr = user |> Tags.list_editable_tags() |> Enum.find(&(&1.user_id == user.user.id and &1.name == "lotr"))
      assert {:ok, _} = Tags.update_tag(user, lotr, %{"ideal_text" => "series:lord of the rings"})
      assert Graph.ideal(Tags.graph(user.user.id), "lotr") == "series:lord of the rings"
      assert Graph.ideal(Tags.graph(nil), "lotr") == "series:lotr"
    end
  end

  describe "parents" do
    test "implications chain and drive filters" do
      site = scope!()
      tag!(site, %{"text" => "series:metroid", "parent_texts" => ["studio:nintendo"]}, site: true)
      tag!(site, %{"text" => "character:samus", "parent_texts" => ["series:metroid"]}, site: true)

      tagged = character!(site, "Samus", site: true)
      plain = character!(site, "Plain", site: true)
      assert :ok = Tags.set_item_tags(site, tagged, :site, ["character:samus"])
      all = [tagged, plain]

      assert filter(nil, all, ["studio:nintendo"]) == [tagged]
      assert filter(nil, all, ["series:*"]) == [tagged]
      assert filter(nil, all, ["-series:metroid"]) == [plain]
      assert filter(nil, all, []) == all

      assert Graph.display(Tags.graph(nil), ["character:samus"]) == %{implied: ["series:metroid", "studio:nintendo"]}
    end
  end

  describe "cycles" do
    test "a sibling that loops back is refused" do
      site = scope!()
      tag!(site, %{"text" => "a", "ideal_text" => "b"})
      b = site |> Tags.list_editable_tags() |> Enum.find(&(&1.name == "b"))

      assert {:error, changeset} = Tags.update_tag(site, b, %{"ideal_text" => "a"})
      assert %{ideal_text: ["would loop back to this tag"]} = errors_on(changeset)
    end

    test "a parent that loops back is refused" do
      site = scope!()
      tag!(site, %{"text" => "x", "parent_texts" => ["y"]})

      y = site |> Tags.list_editable_tags() |> Enum.find(&(&1.name == "y"))
      assert {:error, changeset} = Tags.update_tag(site, y, %{"parent_texts" => ["x"]})
      assert %{parent_texts: ["x would loop back to this tag"]} = errors_on(changeset)
    end
  end

  describe "write rules" do
    test "site taggings need a content manager and a site item; chats never take them" do
      site = scope!()
      user = scope!(%{role: :user})
      site_character = character!(site, "C", site: true)
      own = character!(user)

      assert {:error, :unauthorized} = Tags.set_item_tags(user, site_character, :site, ["x"])
      assert {:error, :unauthorized} = Tags.set_item_tags(site, own, :site, ["x"])

      {:ok, chat} =
        Chats.create_chat(site, %{
          participants: [%{character_id: site_character.id}, %{character_id: character!(site, "C", site: true).id}]
        })

      assert {:error, :unauthorized} = Tags.set_item_tags(site, chat, :site, ["x"])
      assert :ok = Tags.set_item_tags(site, chat, :mine, ["campaign:one"])
      assert Tags.item_tags(site, chat) == %{site: [], mine: ["campaign:one"]}
    end

    test "another user's own tags stay theirs" do
      site = scope!()
      alice = scope!(%{role: :user})
      bob = scope!(%{role: :user})
      shared = character!(site, "C", site: true)

      assert :ok = Tags.set_item_tags(alice, shared, :mine, ["secret"])
      assert Tags.tags_by_item(bob.user.id, :character, [shared.id]) == %{}
      assert Tags.tags_by_item(alice.user.id, :character, [shared.id]) == %{shared.id => ["secret"]}
      assert Tags.item_tags(bob, shared) == %{site: [], mine: []}
    end

    test "edit_item_tags/5 adds and removes within one domain and keeps the rest" do
      site = scope!()
      character = character!(site, "C", site: true)
      :ok = Tags.set_item_tags(site, character, :site, ["series:metroid"])
      :ok = Tags.set_item_tags(site, character, :mine, ["keep", "old"])

      assert :ok = Tags.edit_item_tags(site, character, :mine, ["New", "keep"], ["OLD", "absent"])
      assert Tags.item_tags(site, character) == %{site: ["series:metroid"], mine: ["keep", "new"]}

      user = scope!(%{role: :user})
      assert {:error, :unauthorized} = Tags.edit_item_tags(user, character!(user), :site, ["x"], [])
    end

    test "invalid text is reported" do
      user = scope!(%{role: :user})

      assert {:error, {:invalid, "-x", "can't start with -"}} =
               Tags.set_item_tags(user, character!(user), :mine, ["-x"])
    end
  end

  describe "vocabulary/2" do
    test "counts uses across the viewer's domains, keeping the sorted order" do
      site = scope!()
      user = scope!(%{role: :user})

      for name <- ["A", "B"] do
        assert :ok = Tags.set_item_tags(site, character!(site, name, site: true), :site, ["series:metroid"])
      end

      tag!(site, %{"text" => "unused"}, site: true)
      assert :ok = Tags.set_item_tags(user, character!(user), :mine, ["series:metroid", "smile"])

      assert Enum.map(Tags.vocabulary(user.user.id, Tags.graph(user.user.id)), &{&1.text, &1.uses}) ==
               [{"series:metroid", 3}, {"smile", 1}, {"unused", 0}]

      site_vocabulary = Tags.vocabulary(nil, Tags.graph(nil))
      assert %{uses: 2} = Enum.find(site_vocabulary, &(&1.text == "series:metroid"))
      refute Enum.any?(site_vocabulary, &(&1.text == "smile"))
    end
  end
end
