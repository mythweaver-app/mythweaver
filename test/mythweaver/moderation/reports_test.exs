defmodule Mythweaver.Moderation.ReportsTest do
  use Mythweaver.DataCase

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Catalog
  alias Mythweaver.Characters
  alias Mythweaver.Chats
  alias Mythweaver.Messages
  alias Mythweaver.Moderation.LogEntry
  alias Mythweaver.Moderation.Report
  alias Mythweaver.Moderation.Reports

  defp character!(scope, name) do
    {:ok, character} = Characters.create_character(scope, %{name: name})
    character
  end

  defp listing!(scope) do
    {:ok, listing} = Catalog.publish(scope, character!(scope, "Hero"), %{title: "Hero", visibility: :readable})
    listing
  end

  defp chat!(owner) do
    [a, b] = [character!(owner, "Ann"), character!(owner, "Bea")]

    {:ok, chat} =
      Chats.create_chat(owner, %{
        name: "Tavern",
        player_character_id: a.id,
        participants: [%{character_id: a.id}, %{character_id: b.id}]
      })

    Chats.get_chat(chat.id)
  end

  defp member!(owner, chat) do
    user = scope!(%{role: :user})
    {:ok, member} = Chats.invite(owner, chat, user.user.handle, :guest)
    {:ok, _} = Chats.accept_invite(user, member.id)
    user
  end

  describe "report/4" do
    test "a listing: anyone but its owner, while it is up" do
      publisher = scope!(%{role: :user})
      reporter = scope!(%{role: :user})
      listing = listing!(publisher)

      assert {:error, :unauthorized} = Reports.report(publisher, :listing, listing.id, "mine")

      assert {:ok, %Report{subject_type: :listing, subject_user_id: owner_id, snapshot: "Hero", status: :open}} =
               Reports.report(reporter, :listing, listing.id, "stolen art")

      assert owner_id == publisher.user.id

      :ok = Catalog.takedown(scope!(), listing, "stolen")
      assert {:error, :not_found} = Reports.report(scope!(%{role: :user}), :listing, listing.id, "still bad")
    end

    test "an account: anyone but themselves" do
      reporter = scope!(%{role: :user})
      target = scope!(%{role: :user})

      assert {:error, :unauthorized} = Reports.report(reporter, :user, reporter.user.id, "me")

      assert {:ok, %Report{subject_type: :user, subject_user_id: target_id, snapshot: snapshot}} =
               Reports.report(reporter, :user, target.user.id, "spam")

      assert target_id == target.user.id
      assert snapshot == "@" <> target.user.handle
    end

    test "a message: only another member of its chat, never its author" do
      owner = scope!(%{role: :user})
      chat = chat!(owner)
      guest = member!(owner, chat)
      [a | _] = Enum.map(chat.participants, & &1.character_id)
      {:ok, message} = Messages.send_message(owner, chat, a, "the owner's rude words")

      assert {:error, :unauthorized} = Reports.report(scope!(%{role: :user}), :message, message.id, "rude")
      assert {:error, :unauthorized} = Reports.report(owner, :message, message.id, "rude")

      assert {:ok, %Report{subject_type: :message, subject_user_id: author_id, snapshot: snapshot}} =
               Reports.report(guest, :message, message.id, "rude")

      assert author_id == owner.user.id
      assert snapshot =~ "the owner's rude words"
    end

    test "one open report per reporter and subject, again once dismissed" do
      reporter = scope!(%{role: :user})
      target = scope!(%{role: :user})

      assert {:ok, report} = Reports.report(reporter, :user, target.user.id, "spam")
      assert {:error, :already_reported} = Reports.report(reporter, :user, target.user.id, "more spam")

      assert {:ok, %Report{status: :dismissed}} = Reports.dismiss(scope!(), report.id)
      assert {:ok, %Report{status: :open}} = Reports.report(reporter, :user, target.user.id, "more spam")
    end

    test "denying reports.create for Everyone turns reporting off, a user's own allow back on" do
      target = scope!(%{role: :user})
      :ok = Mythweaver.Permissions.put_grant!(:everyone, "reports.create", :deny)

      assert {:error, :unauthorized} = Reports.report(scope!(%{role: :user}), :user, target.user.id, "spam")

      allowed = scope!(%{role: :user})
      :ok = Mythweaver.Permissions.put_grant!(allowed.user, "reports.create", :allow)
      allowed = Scope.for_user(allowed.user)
      assert {:ok, %Report{}} = Reports.report(allowed, :user, target.user.id, "spam")
    end
  end

  test "list_open/2 needs moderation.reports" do
    target = scope!(%{role: :user})
    {:ok, report} = Reports.report(scope!(%{role: :user}), :user, target.user.id, "spam")

    assert Reports.list_open(scope!(%{role: :user}), :user) == []
    assert [%Report{id: id}] = Reports.list_open(scope!(), :user)
    assert id == report.id
  end

  test "dismiss/2 writes :report_dismissed to the moderation log" do
    moderator = scope!()
    target = scope!(%{role: :user})
    {:ok, report} = Reports.report(scope!(%{role: :user}), :user, target.user.id, "spam")

    assert {:ok, _} = Reports.dismiss(moderator, report.id)

    assert [%LogEntry{action: :report_dismissed, subject_type: :report, subject_id: subject_id} = entry] =
             Repo.all(LogEntry)

    assert subject_id == report.id
    assert entry.actor_id == moderator.user.id
    assert entry.target_user_id == target.user.id
    assert Reports.list_open(moderator, :user) == []
  end

  describe "flag/5" do
    test "opens one rule report per subject and updates it while open" do
      owner = scope!(%{role: :user})
      character = character!(owner, "Ada")
      finding = %{"rule" => "Words", "action" => "flag", "field" => "description", "excerpt" => "bad", "reason" => nil}

      :ok = Reports.flag(:character, character.id, owner.user.id, "first", [finding])
      :ok = Reports.flag(:character, character.id, owner.user.id, "second", [%{finding | "action" => "reject"}])

      assert [%Report{source: :rule, reporter_id: nil, snapshot: "second", reason: reason} = report] =
               Reports.list_open(scope!(), :rule)

      assert reason == "Rules recommend removal. Words: bad"
      assert Reports.list_open(scope!(), :user) == []

      reviewer = scope!(%{role: :user})
      :ok = Mythweaver.Permissions.put_grant!(reviewer.user, "moderation.review", :allow)
      reviewer = Scope.for_user(reviewer.user)
      assert Reports.get(reviewer, report.id)
      assert {:ok, %Report{status: :dismissed}} = Reports.dismiss(reviewer, report.id)

      :ok = Reports.flag(:character, character.id, owner.user.id, "third", [finding])
      assert [%Report{snapshot: "third"}] = Reports.list_open(scope!(), :rule)
    end
  end

  describe "without moderation.reports" do
    test "dismiss/2 is refused and get/2 finds nothing" do
      reporter = scope!(%{role: :user})
      {:ok, report} = Reports.report(reporter, :user, scope!(%{role: :user}).user.id, "spam")
      moderator = scope!()
      denied = %{moderator | permissions: Map.put(moderator.permissions, "moderation.reports", false)}

      assert Reports.dismiss(denied, report.id) == {:error, :unauthorized}
      assert Repo.get!(Report, report.id).status == :open
      assert Reports.get(denied, report.id) == nil
    end
  end
end
