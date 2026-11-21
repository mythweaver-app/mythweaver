defmodule MythweaverWeb.LorePoolLiveTest do
  use MythweaverWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Lore
  alias Mythweaver.Lore.LorePool
  alias Mythweaver.Repo

  setup :register_and_log_in_user

  defp pool!(scope, name, attrs \\ %{}) do
    {:ok, pool} = Lore.create_pool(scope, Map.put(attrs, :name, name))
    pool
  end

  defp entry!(scope, name) do
    {:ok, entry} = Lore.create_entry(scope, %{name: name, content: "#{name} content", keywords: ["x"]}, [])
    entry
  end

  test "index lists the scope's pools, selects none and switches back to the books", %{scope: scope, conn: conn} do
    pool = pool!(scope, "Weather")

    {:ok, view, _html} = live(conn, ~p"/lore/pools")

    assert has_element?(view, "#lore-pools-#{pool.id}")
    assert has_element?(view, "#lore-pool-placeholder")
    assert has_element?(view, "#pane-switch-lore[href='/lore']")
  end

  test "creating a pool saves it and opens its editor", %{scope: scope, conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/lore/pools/new")

    view
    |> form("#lore-pool-form", lore_pool: %{name: "Moods", max_activations: "2"})
    |> render_submit()

    pool = Repo.get_by!(LorePool, name: "Moods")
    assert pool.user_id == scope.user.id
    assert pool.max_activations == 2
    assert_patch(view, ~p"/lore/pools/#{pool.id}/edit")
  end

  test "a pool's editor saves its settings and lists its members", %{scope: scope, conn: conn} do
    pool = pool!(scope, "Weather")
    rain = entry!(scope, "Rain")
    {:ok, :ok} = Lore.set_entry_pools(scope, rain, [pool.id])
    {:ok, :ok} = Lore.set_pool_memberships(scope, rain, %{pool.id => %{weight: 7, override: true}})

    {:ok, view, _html} = live(conn, ~p"/lore/pools/#{pool.id}/edit")

    assert has_element?(view, "#lore-pool-member-#{rain.id} a[href='/lore/entries/#{rain.id}/edit']")
    assert view |> element("#lore-pool-member-#{rain.id}") |> render() =~ "weight 7"

    view
    |> form("#lore-pool-form", lore_pool: %{max_activations: "0"})
    |> render_submit()

    assert Repo.get!(LorePool, pool.id).max_activations == 1

    view
    |> form("#lore-pool-form", lore_pool: %{max_activations: "3"})
    |> render_submit()

    assert Repo.get!(LorePool, pool.id).max_activations == 3
  end

  test "deleting a pool keeps its entries", %{scope: scope, conn: conn} do
    pool = pool!(scope, "Weather")
    rain = entry!(scope, "Rain")
    {:ok, :ok} = Lore.set_entry_pools(scope, rain, [pool.id])

    {:ok, view, _html} = live(conn, ~p"/lore/pools/#{pool.id}/edit")
    view |> element("#delete-lore-pool") |> render_click()

    assert_patch(view, ~p"/lore/pools")
    refute Repo.get(LorePool, pool.id)
    assert Lore.get_editable_entry(scope, rain.id)
  end

  test "another user's pool does not open", %{conn: conn} do
    pool = pool!(Scope.for_user(register_user!()), "Theirs")

    {:ok, view, _html} = live(conn, ~p"/lore/pools")
    refute has_element?(view, "#lore-pools-#{pool.id}")

    assert {:error, {:live_redirect, %{to: "/lore/pools"}}} = live(conn, ~p"/lore/pools/#{pool.id}/edit")
  end
end
