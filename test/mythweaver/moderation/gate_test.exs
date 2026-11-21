defmodule Mythweaver.Moderation.GateTest do
  use Mythweaver.DataCase

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Characters
  alias Mythweaver.Characters.Character
  alias Mythweaver.Lore
  alias Mythweaver.Moderation.Gate
  alias Mythweaver.Moderation.Hold
  alias Mythweaver.Moderation.Holds
  alias Mythweaver.Moderation.LogEntry
  alias Mythweaver.Moderation.Report
  alias Mythweaver.Moderation.Rules
  alias Mythweaver.Notifications.Notification
  alias Mythweaver.Permissions

  defp user!(grants) do
    scope = scope!(%{role: :user})
    Enum.each(grants, fn {key, effect} -> :ok = Permissions.put_grant!(scope.user, key, effect) end)
    Scope.for_user(scope.user)
  end

  defp rule!(attrs) do
    {:ok, rule} =
      Rules.create_rule(
        scope!(),
        Map.merge(%{"name" => "Words", "kind" => "regex", "content_types" => ["characters", "lore"]}, attrs)
      )

    rule
  end

  defp character!(scope, attrs) do
    {:ok, character} = Gate.unmoderated(fn -> Characters.create_character(scope, attrs) end)
    character
  end

  defp own_holds(scope), do: Enum.filter(Holds.list(scope!()), &(&1.user_id == scope.user.id))

  defp notifications(scope, kind),
    do: Repo.all(from(n in Notification, where: n.user_id == ^scope.user.id and n.kind == ^kind))

  defp characters(scope), do: Repo.all(from(c in Character, where: c.user_id == ^scope.user.id))

  @restrictive [{"moderation.characters.restrictive", :allow}]

  describe "restrictive" do
    test "with no rules, a create is held and applied at once" do
      scope = user!(@restrictive)

      assert {:held, %Hold{}} = Characters.create_character(scope, %{"name" => "Ada", "description" => "x"})
      assert [%Character{name: "Ada"}] = characters(scope)
      assert [_] = notifications(scope, :submission_approved)
      assert own_holds(scope) == []
    end

    test "a flagged create waits for a moderator, who approves it" do
      scope = user!(@restrictive)
      rule!(%{"pattern" => "forbidden"})

      assert {:held, hold} = Characters.create_character(scope, %{"name" => "Ada", "description" => "a forbidden word"})
      assert characters(scope) == []

      assert [%Hold{id: id, status: :review, findings: [finding]}] = own_holds(scope)
      assert id == hold.id
      assert finding["excerpt"] =~ "forbidden"

      moderator = scope!()
      assert {:ok, %Character{name: "Ada"}} = Holds.approve(moderator, hold.id)
      assert [_] = characters(scope)
      assert Repo.exists?(from(e in LogEntry, where: e.action == :hold_approved and e.actor_id == ^moderator.user.id))
    end

    test "a reject rule discards it and tells the submitter which rule" do
      scope = user!(@restrictive)
      rule!(%{"name" => "No slurs", "pattern" => "forbidden", "regex_action" => "reject"})

      assert {:held, _} = Characters.create_character(scope, %{"name" => "Ada", "description" => "forbidden"})
      assert characters(scope) == []
      assert own_holds(scope) == []
      assert [%Notification{body: body}] = notifications(scope, :submission_rejected)
      assert body =~ "No slurs"
    end

    test "a text edit is held; a non-text edit saves; a newer edit replaces the older" do
      scope = user!(@restrictive)
      rule!(%{"pattern" => "forbidden"})
      character = character!(scope, %{"name" => "Ada", "description" => "fine"})

      assert {:held, _} = Characters.update_character(scope, character, %{"description" => "forbidden"})
      assert Repo.reload(character).description == "fine"
      assert {:ok, _} = Characters.update_character(scope, character, %{"talkativeness" => 0.9})

      assert {:held, _} = Characters.update_character(scope, character, %{"description" => "forbidden again"})
      assert [%Hold{previous: %{"description" => "fine"}}] = Holds.list_own(scope)
    end

    test "owners and users a group denies are exempt" do
      owner = scope!(%{role: :owner})
      rule!(%{"pattern" => "forbidden"})
      assert {:ok, _} = Characters.create_character(owner, %{"name" => "Ada", "description" => "forbidden"})

      :ok = Permissions.put_grant!(:everyone, "moderation.characters.restrictive", :allow)
      {:ok, group} = Permissions.create_group(scope!(), %{name: "Trusted"})
      :ok = Permissions.put_grant!(group, "moderation.characters.restrictive", :deny)
      trusted = scope!(%{role: :user})
      :ok = Permissions.add_member!(group, trusted.user)
      trusted = Scope.for_user(trusted.user)

      assert {:ok, _} = Characters.create_character(trusted, %{"name" => "Bea", "description" => "forbidden"})
      assert {:held, _} = Characters.create_character(user!([]), %{"name" => "Cy", "description" => "forbidden"})
    end

    test "unmoderated writes are neither held nor scanned" do
      scope = user!([{"moderation.lore.restrictive", :allow}])
      rule!(%{"pattern" => "forbidden"})

      {:ok, entry} =
        Gate.unmoderated(fn ->
          Lore.create_entry(scope, %{"name" => "E", "content" => "ok", "keywords" => ["e"]}, [])
        end)

      assert {:ok, _} = Gate.unmoderated(fn -> Lore.update_entry(scope, entry, %{"content" => "forbidden"}) end)
      assert {:held, _} = Lore.update_entry(scope, entry, %{"content" => "forbidden 2"})
    end

    test "a user over the hold limit is refused" do
      config = Application.get_env(:mythweaver, Mythweaver.Moderation)
      on_exit(fn -> Application.put_env(:mythweaver, Mythweaver.Moderation, config) end)
      Application.put_env(:mythweaver, Mythweaver.Moderation, Keyword.put(config, :max_user_holds, 1))

      scope = user!(@restrictive)
      rule!(%{"pattern" => "forbidden"})

      assert {:held, _} = Characters.create_character(scope, %{"name" => "A", "description" => "forbidden"})

      assert {:error, :hold_limit} =
               Characters.create_character(scope, %{"name" => "B", "description" => "forbidden"})
    end
  end

  describe "permissive" do
    test "saves, then opens one rule report the next match updates" do
      scope = user!([{"moderation.characters.permissive", :allow}])
      rule!(%{"pattern" => "forbidden"})

      assert {:ok, character} = Characters.create_character(scope, %{"name" => "Ada", "description" => "forbidden"})
      assert {:ok, _} = Characters.update_character(scope, character, %{"description" => "forbidden twice"})

      assert [%Report{source: :rule, subject_type: :character, snapshot: snapshot}] =
               Repo.all(from(r in Report, where: r.subject_id == ^character.id))

      assert snapshot =~ "forbidden twice"
    end
  end
end
