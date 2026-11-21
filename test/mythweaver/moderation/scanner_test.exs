defmodule Mythweaver.Moderation.ScannerTest do
  use MythweaverWeb.ConnCase

  import Ecto.Query

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Characters
  alias Mythweaver.Characters.Character
  alias Mythweaver.Moderation.Hold
  alias Mythweaver.Moderation.Holds
  alias Mythweaver.Moderation.Rules
  alias Mythweaver.Moderation.Scanner
  alias Mythweaver.Moderation.Store
  alias Mythweaver.Notifications.Notification
  alias Mythweaver.Repo

  defp restrictive! do
    user = register_user!(%{role: :user})
    :ok = Mythweaver.Permissions.put_grant!(user, "moderation.characters.restrictive", :allow)
    Scope.for_user(user)
  end

  defp webhook!(attrs) do
    {:ok, rule} =
      Rules.create_rule(
        Scope.for_user(register_user!()),
        Map.merge(
          %{
            "name" => "Hook",
            "kind" => "webhook",
            "content_types" => ["characters"],
            "url" => "https://mod.example/check"
          },
          attrs
        )
      )

    rule
  end

  defp own_hold(scope), do: Enum.find(Store.list_holds(), &(&1.user_id == scope.user.id))
  defp characters(scope), do: Repo.all(from(c in Character, where: c.user_id == ^scope.user.id))

  defp notifications(scope, kind),
    do: Repo.all(from(n in Notification, where: n.user_id == ^scope.user.id and n.kind == ^kind))

  defp create!(scope), do: Characters.create_character(scope, %{"name" => "Ada", "description" => "a tale"})

  test "a sync webhook's reject discards the hold; the body is signed" do
    webhook!(%{"secret" => "s3cret"})
    test = self()

    Req.Test.stub(Mythweaver.Moderation, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:webhook, body, Plug.Conn.get_req_header(conn, "x-mythweaver-signature")})
      Req.Test.json(conn, %{"action" => "reject", "reason" => "nope"})
    end)

    scope = restrictive!()
    assert {:held, _} = create!(scope)

    assert_received {:webhook, body, [signature]}
    assert %{"fields" => %{"description" => "a tale"}, "held" => true} = Jason.decode!(body)
    assert signature == "sha256=" <> Scanner.signature("s3cret", body)

    assert characters(scope) == []
    assert own_hold(scope) == nil
    assert [%Notification{body: reason}] = notifications(scope, :submission_rejected)
    assert reason =~ "nope"
  end

  test "a failing webhook leaves the hold for review" do
    webhook!(%{})
    Req.Test.stub(Mythweaver.Moderation, &Plug.Conn.send_resp(&1, 500, "boom"))

    scope = restrictive!()
    assert {:held, _} = create!(scope)

    assert %Hold{status: :review, findings: [%{"action" => "flag", "reason" => "webhook failed: 500"}]} =
             own_hold(scope)
  end

  test "a callback rule waits for its callback; a tampered token is refused", %{conn: conn} do
    webhook!(%{"webhook_mode" => "callback"})
    test = self()

    Req.Test.stub(Mythweaver.Moderation, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:callback_url, Jason.decode!(body)["callback_url"]})
      Plug.Conn.send_resp(conn, 202, "")
    end)

    scope = restrictive!()
    assert {:held, _} = create!(scope)
    assert_received {:callback_url, url}
    assert %Hold{status: :scanning} = own_hold(scope)

    path = URI.parse(url).path
    assert conn |> post(path <> "x", %{"action" => "approve"}) |> response(404)
    assert conn |> post(path, %{"action" => "maybe"}) |> response(422)
    assert conn |> post(path, %{"action" => "approve"}) |> response(204)

    assert [%Character{name: "Ada"}] = characters(scope)
    assert own_hold(scope) == nil
  end

  test "an unanswered callback flags in time, and an old hold expires" do
    webhook!(%{"webhook_mode" => "callback", "callback_timeout_minutes" => 1})
    Req.Test.stub(Mythweaver.Moderation, &Plug.Conn.send_resp(&1, 202, ""))

    # The Store is global: other tests' leftover holds belong to users this test cannot see.
    for %Hold{id: id} <- Store.list_holds(), do: Store.take_hold(id)

    scope = restrictive!()
    assert {:held, hold} = create!(scope)
    now = System.system_time(:millisecond)

    :ok = Store.sweep(now + 2 * 86_400_000)
    assert %Hold{status: :review, findings: [%{"reason" => "webhook did not answer in time"}]} = own_hold(scope)

    :ok = Store.sweep(now + 8 * 86_400_000)
    refute Store.get_hold(hold.id)
    assert [_] = notifications(scope, :submission_rejected)
  end

  test "a pattern that hits its match limit flags instead of crashing" do
    {:ok, _rule} =
      Rules.create_rule(Scope.for_user(register_user!()), %{
        "name" => "Slow",
        "kind" => "regex",
        "content_types" => ["characters"],
        "pattern" => "(a+)+$"
      })

    scope = restrictive!()

    assert {:held, _} =
             Characters.create_character(scope, %{"name" => "Bo", "description" => String.duplicate("a", 5000) <> "b"})

    assert %Hold{status: :review, findings: [%{"reason" => "pattern hit its match limit"}]} = own_hold(scope)
    :ok = Holds.withdraw(scope, own_hold(scope).id)
  end
end
