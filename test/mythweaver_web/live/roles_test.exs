defmodule MythweaverWeb.RolesTest do
  use MythweaverWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.AI

  describe "a user without admin rights" do
    setup %{conn: conn} do
      user = register_user!(%{role: :user})
      %{conn: log_in_user(conn, user), scope: Scope.for_user(user)}
    end

    test "is redirected away from the admin screens", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/moderation/users")
    end

    test "reaches the content editors, each opening on its placeholder", %{conn: conn} do
      for {path, placeholder} <- [
            {~p"/characters", "#character-placeholder"},
            {~p"/prompts", "#prompt-placeholder"},
            {~p"/scripts", "#script-placeholder"}
          ] do
        assert {:ok, view, _html} = live(conn, path)
        assert has_element?(view, placeholder)
      end
    end

    test "sees the chat page without admin links", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      refute has_element?(view, "#nav-moderation")
    end

    test "reaches account settings and jobs", %{conn: conn} do
      assert {:ok, _view, _html} = live(conn, ~p"/users/settings")
      assert {:ok, _view, _html} = live(conn, ~p"/jobs")
    end

    test "manages their own AI connections, and never sees the site's", %{conn: conn, scope: scope} do
      {:ok, site} = AI.create_provider(Scope.for_user(register_user!()), %{name: "Site", base_url: "http://site"})
      {:ok, own} = AI.create_provider(scope, %{name: "Mine", base_url: "http://mine", api_key: "sk-mine"})

      {:ok, view, _html} = live(conn, ~p"/ai/providers/#{own.id}/edit")
      assert has_element?(view, "#ai-providers-#{own.id}")
      refute has_element?(view, "#ai-providers-#{site.id}")

      assert {:error, {:live_redirect, %{to: "/ai/providers"}}} = live(conn, ~p"/ai/providers/#{site.id}/edit")
    end
  end
end
