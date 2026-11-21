defmodule Mythweaver.CharactersTest do
  use Mythweaver.DataCase

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Characters
  alias Mythweaver.Characters.Character
  alias Mythweaver.Characters.Favorite
  alias Mythweaver.Repo
  alias Mythweaver.Schema

  setup do
    %{scope: scope!()}
  end

  describe "create_character/1" do
    test "persists name and a long description that exceeds varchar(255)", %{scope: scope} do
      long_description = String.duplicate("x", 5000)

      assert {:ok, %Character{} = character} =
               Characters.create_character(scope, %{
                 name: "Aqua",
                 description: long_description,
                 creator: "Natsume",
                 creator_notes: "Original creator notes",
                 character_version: "1.2",
                 pronouns: "she/her"
               })

      assert character.name == "Aqua"
      assert character.description == long_description
      assert character.creator == "Natsume"
      assert character.creator_notes == "Original creator notes"
      assert character.character_version == "1.2"
      assert character.pronouns == "she/her"

      reloaded = Characters.get_character!(character.id)
      assert reloaded.description == long_description
      assert reloaded.creator == "Natsume"
      assert reloaded.creator_notes == "Original creator notes"
      assert reloaded.character_version == "1.2"
      assert reloaded.pronouns == "she/her"
      assert String.length(reloaded.description) == 5000
    end

    test "requires a name", %{scope: scope} do
      assert {:error, changeset} = Characters.create_character(scope, %{description: "no name"})
      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end

    test "rejects a description that does not parse as a template", %{scope: scope} do
      assert {:error, changeset} = Characters.create_character(scope, %{name: "X", description: "{% if %}"})
      assert [error] = errors_on(changeset).description
      assert error =~ "has invalid template syntax"
    end

    test "names the greeting that does not parse as a template", %{scope: scope} do
      assert {:error, changeset} =
               Characters.create_character(scope, %{name: "X", alternate_greetings: ["Hi.", "{% if %}"]})

      assert [error] = errors_on(changeset).alternate_greetings
      assert error =~ "entry 2 has invalid template syntax: "
    end

    test "source_file and foreign are cast only on import", %{scope: scope} do
      {:ok, c} = Characters.create_character(scope, %{name: "X", source_file: "x", foreign: %{"a" => 1}})
      assert %{source_file: nil, foreign: %{}} = c

      assert {:ok, %{source_file: nil, foreign: %{}}} =
               Characters.update_character(scope, c, %{"foreign" => %{"b" => 2}, "source_file" => "x"})

      assert {:ok, %{source_file: "x", foreign: %{"b" => 2}}} =
               Characters.update_character(scope, c, %{"foreign" => %{"b" => 2}, "source_file" => "x"}, import: true)

      assert {:ok, %{source_file: "y", foreign: %{"c" => 3}}} =
               Characters.create_character(scope, %{name: "Y", source_file: "y", foreign: %{"c" => 3}}, import: true)
    end
  end

  test "list_characters/0 returns inserted characters", %{scope: scope} do
    {:ok, character} = Characters.create_character(scope, %{name: "Megumin"})
    assert Characters.list_characters(scope) == [character]
  end

  describe "get_character!/1 and get_character/1" do
    test "get_character!/1 returns the character by id", %{scope: scope} do
      {:ok, character} = Characters.create_character(scope, %{name: "Darkness"})
      assert Characters.get_character!(character.id) == character
    end

    test "get_character/1 returns nil for an unknown id", %{scope: scope} do
      assert Characters.get_character(scope, Schema.generate_id()) == nil
    end
  end

  test "update_character/2 changes the name", %{scope: scope} do
    {:ok, character} = Characters.create_character(scope, %{name: "Kazuma"})

    assert {:ok, %Character{} = updated} =
             Characters.update_character(scope, character, %{name: "Satou"})

    assert updated.name == "Satou"
  end

  test "delete_character/1 removes the character", %{scope: scope} do
    {:ok, character} = Characters.create_character(scope, %{name: "Wiz"})
    assert {:ok, %Character{}} = Characters.delete_character(scope, character)
    assert Characters.get_character(scope, character.id) == nil
  end

  test "create_character/2 refuses a non-admin scope and inserts nothing", %{scope: scope} do
    assert Characters.create_character(%Scope{}, %{name: "X"}) == {:error, :unauthorized}
    refute Enum.any?(Characters.list_characters(scope), &(&1.name == "X"))
  end

  describe "ownership" do
    setup %{scope: admin} do
      user = scope!(%{role: :user})
      other = scope!(%{role: :user})
      {:ok, site} = Characters.create_character(admin, %{name: "Site"}, site: true)
      {:ok, mine} = Characters.create_character(user, %{name: "Mine"})
      {:ok, theirs} = Characters.create_character(other, %{name: "Theirs"})
      %{user: user, site: site, mine: mine, theirs: theirs}
    end

    test "an admin's characters are their own unless created for the site, a user's their own", ctx do
      %{scope: admin, site: site, mine: mine, user: user} = ctx
      assert site.user_id == nil
      assert mine.user_id == user.user.id
      assert {:ok, %{user_id: admin_id}} = Characters.create_character(admin, %{name: "Admin's"})
      assert admin_id == admin.user.id
      assert {:error, :unauthorized} = Characters.create_character(user, %{name: "X"}, site: true)
    end

    test "a user uses their own and site characters but edits only their own", ctx do
      %{user: user, site: site, mine: mine, theirs: theirs} = ctx

      assert user |> Characters.list_characters() |> Enum.map(& &1.id) |> Enum.sort() == Enum.sort([site.id, mine.id])
      assert Enum.map(Characters.list_editable_characters(user), & &1.id) == [mine.id]
      assert Characters.get_character(user, site.id)
      refute Characters.get_character(user, theirs.id)
      refute Characters.get_editable_character(user, site.id)

      assert {:error, :unauthorized} = Characters.update_character(user, site, %{name: "X"})
      assert {:error, :unauthorized} = Characters.update_character(user, theirs, %{name: "X"})
      assert {:error, :unauthorized} = Characters.delete_character(user, site)
      assert {:ok, %{name: "Renamed"}} = Characters.update_character(user, mine, %{name: "Renamed"})
    end

    test "an admin neither sees nor edits a user's character", %{scope: admin, mine: mine, site: site} do
      refute Characters.get_character(admin, mine.id)
      assert Enum.map(Characters.list_editable_characters(admin), & &1.id) == [site.id]
      assert {:error, :unauthorized} = Characters.update_character(admin, mine, %{name: "X"})
      assert {:error, :unauthorized} = Characters.delete_character(admin, mine)
    end

    test "find_character_by_name prefers the user's own over a site character", %{scope: admin, user: user} do
      {:ok, _site} = Characters.create_character(admin, %{name: "Twin"}, site: true)
      {:ok, own} = Characters.create_character(user, %{name: "Twin"})

      assert Characters.find_character_by_name(user, "twin").id == own.id
      assert Characters.find_character_by_name(admin, "twin").user_id == nil
      refute Characters.find_character_by_name(admin, "Theirs")
    end

    test "usable_by?/2 resolves by chat owner", %{user: user, site: site, mine: mine, theirs: theirs} do
      assert Characters.usable_by?(user.user.id, site.id)
      assert Characters.usable_by?(user.user.id, mine.id)
      refute Characters.usable_by?(user.user.id, theirs.id)
      refute Characters.usable_by?(nil, mine.id)
    end
  end

  describe "favorites" do
    setup %{scope: admin} do
      user = scope!(%{role: :user})
      {:ok, zed} = Characters.create_character(admin, %{name: "Zed"}, site: true)

      [bea, cal, amy] =
        for name <- ~w(Bea Cal Amy) do
          {:ok, character} = Characters.create_character(user, %{name: name})
          character
        end

      %{user: user, zed: zed, bea: bea, cal: cal, amy: amy}
    end

    defp listed(characters), do: Enum.map(characters, &{&1.name, &1.favorite})

    test "a user's favorites list first, each group by name, for that user only", %{user: user, zed: zed, cal: cal} do
      assert :ok = Characters.set_favorite(user, zed, true)
      assert :ok = Characters.set_favorite(user, cal, true)

      assert listed(Characters.list_characters(user)) ==
               [{"Cal", true}, {"Zed", true}, {"Amy", false}, {"Bea", false}]

      assert listed(Characters.list_editable_characters(user)) == [{"Cal", true}, {"Amy", false}, {"Bea", false}]

      other = scope!(%{role: :user})
      assert listed(Characters.list_characters(other)) == [{"Zed", false}]
    end

    test "starring is idempotent and unstarring restores name order", %{user: user, cal: cal} do
      assert :ok = Characters.set_favorite(user, cal, true)
      assert :ok = Characters.set_favorite(user, cal, true)
      assert Characters.favorite?(user, cal)
      assert Enum.map(Characters.list_characters(user), & &1.name) == ~w(Cal Amy Bea Zed)

      assert :ok = Characters.set_favorite(user, cal, false)
      refute Characters.favorite?(user, cal)
      assert Enum.map(Characters.list_characters(user), & &1.name) == ~w(Amy Bea Cal Zed)
    end

    test "a character the user may not use can't be starred", %{user: user} do
      {:ok, theirs} = Characters.create_character(scope!(%{role: :user}), %{name: "Theirs"})

      assert {:error, :unauthorized} = Characters.set_favorite(user, theirs, true)
      assert Repo.aggregate(Favorite, :count) == 0
    end

    test "a character deleted meanwhile is not found", %{user: user, cal: cal} do
      Repo.delete!(cal)

      assert {:error, :not_found} = Characters.set_favorite(user, cal, true)
      assert Repo.aggregate(Favorite, :count) == 0
    end
  end
end
