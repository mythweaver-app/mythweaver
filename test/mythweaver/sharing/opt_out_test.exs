defmodule Mythweaver.Sharing.OptOutTest do
  use Mythweaver.DataCase

  alias Mythweaver.Characters
  alias Mythweaver.Chats
  alias Mythweaver.Lore
  alias Mythweaver.Sharing
  alias Mythweaver.Tags

  setup do
    %{admin: scope!(), user: scope!(%{role: :user})}
  end

  defp character!(scope, name, opts \\ []) do
    {:ok, character} = Characters.create_character(scope, %{name: name}, opts)
    character
  end

  defp book!(scope, name, attrs) do
    {:ok, book} = Lore.create_book(scope, Map.merge(%{name: name}, attrs), site: true)
    book
  end

  defp chat!(scope, characters) do
    {:ok, chat} =
      Chats.create_chat(scope, %{"participants" => Enum.map(characters, &%{"character_id" => &1.id})})

    chat
  end

  defp ids(rows), do: Enum.map(rows, & &1.id)

  test "an opted-out site character leaves the user's lists and chats; opt_in restores it to the lists",
       %{admin: admin, user: user} do
    bard = character!(admin, "Bard", site: true)
    chat = chat!(user, [bard, character!(user, "Mine"), character!(user, "Also mine")])
    :ok = Tags.set_item_tags(user, bard, :mine, ["favourite"])

    assert {:ok, %{participants: 1, taggings: 1}} = Sharing.opt_out_impact(user, bard)
    assert {:ok, %{participants: 1, taggings: 1}} = Sharing.opt_out(user, bard)

    refute bard.id in ids(Characters.list_characters(user))
    refute Characters.get_character(user, bard.id)
    refute bard.id in Enum.map(Chats.get_chat!(chat.id).participants, & &1.character_id)
    assert length(Chats.get_chat!(chat.id).participants) == 2

    # Others, and the site's editors' lists, still have it.
    assert bard.id in ids(Characters.list_characters(scope!(%{role: :user})))
    assert bard.id in ids(Characters.list_editable_characters(admin))

    assert [%{opted_out?: true, forced?: false}] =
             Enum.filter(Sharing.list_site_items(user), &(&1.item.id == bard.id))

    assert :ok = Sharing.opt_in(user, bard)
    assert bard.id in ids(Characters.list_characters(user))
    assert [%{opted_out?: false}] = Enum.filter(Sharing.list_site_items(user), &(&1.item.id == bard.id))
  end

  test "an opted-out site book stops resolving for the user's chats", %{admin: admin, user: user} do
    atlas = book!(admin, "Atlas", %{global: true})
    chat = chat!(user, [character!(user, "A"), character!(user, "B")])
    assert atlas.id in ids(Lore.books_for_chat(chat))

    assert {:ok, _impact} = Sharing.opt_out(user, atlas)
    refute atlas.id in ids(Lore.books_for_chat(chat))
    refute atlas.id in ids(Lore.list_usable_books(user))
  end

  test "a forced book, a personal item and a missing user refuse", %{admin: admin, user: user} do
    vault = book!(admin, "Vault", %{forced: true})
    mine = character!(user, "Mine")

    assert Sharing.opt_out(user, vault) == {:error, :forced}
    assert Sharing.opt_out_impact(user, vault) == {:error, :forced}
    assert [%{forced?: true, opted_out?: false}] = Enum.filter(Sharing.list_site_items(user), &(&1.item.id == vault.id))
    assert Sharing.opt_out(user, mine) == {:error, :unauthorized}
    assert Sharing.opt_out(%{user | user: nil}, character!(admin, "Site", site: true)) == {:error, :unauthorized}
  end
end
