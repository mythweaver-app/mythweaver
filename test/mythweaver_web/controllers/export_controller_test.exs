defmodule MythweaverWeb.ExportControllerTest do
  use MythweaverWeb.ConnCase

  alias Mythweaver.Bundle
  alias Mythweaver.Characters

  setup :register_and_log_in_user

  defp character!(scope, name) do
    {:ok, character} = Characters.create_character(scope, %{name: name})
    character
  end

  test "a native export downloads a bundle", %{scope: scope, conn: conn} do
    aqua = character!(scope, "Aqua")

    conn = post(conn, ~p"/export", export: %{"items" => ["character:#{aqua.id}"], "format" => "native"})

    assert response(conn, 200)
    assert [~s(attachment; filename="Aqua.mythweaver")] = get_resp_header(conn, "content-disposition")
    assert {:ok, %Bundle{items: items}} = Bundle.decode(conn.resp_body)
    assert Enum.any?(items, &(&1.kind == :character and &1.name == "Aqua" and &1.root))
  end

  test "an unknown id redirects back with the error", %{conn: conn} do
    conn =
      post(conn, ~p"/export", export: %{"items" => ["character:#{Ecto.UUID.generate()}"], "format" => "native"})

    assert redirected_to(conn) == ~p"/export"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Something you picked is no longer available."
  end
end
