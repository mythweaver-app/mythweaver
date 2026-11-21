defmodule MythweaverWeb.ModerationReportLiveTest do
  use MythweaverWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Catalog
  alias Mythweaver.Catalog.Listing
  alias Mythweaver.Characters
  alias Mythweaver.Characters.Character
  alias Mythweaver.Chats
  alias Mythweaver.Messages
  alias Mythweaver.Messages.Message
  alias Mythweaver.Moderation.Holds
  alias Mythweaver.Moderation.Report
  alias Mythweaver.Moderation.Reports
  alias Mythweaver.Moderation.Rules
  alias Mythweaver.Repo

  setup do
    %{moderator: register_user!(), owner: register_user!(%{role: :user}), reporter: register_user!(%{role: :user})}
  end

  defp character!(%Scope{} = scope, name) do
    {:ok, character} = Characters.create_character(scope, %{name: "#{name}-#{System.unique_integer([:positive])}"})
    character
  end

  # A chat of `owner`'s that `reporter` joined, holding one character message, reported by `reporter`.
  defp message_report!(%{owner: owner, reporter: reporter}) do
    owner_scope = Scope.for_user(owner)
    reporter_scope = Scope.for_user(reporter)
    [a, b] = Enum.map(["A", "B"], &character!(owner_scope, &1))
    {:ok, chat} = Chats.create_chat(owner_scope, %{participants: [%{character_id: a.id}, %{character_id: b.id}]})
    {:ok, member} = Chats.invite(owner_scope, chat, reporter.handle, :guest)
    {:ok, _} = Chats.accept_invite(reporter_scope, member.id)

    {:ok, message} =
      Messages.create_message(chat, %{
        author_is_character: true,
        author_character_id: a.id,
        bodies: [%{content: "Something vile"}]
      })

    {:ok, report} = Reports.report(reporter_scope, :message, message.id, "Hateful")
    {message, report}
  end

  defp listing_report!(%{owner: owner, reporter: reporter}) do
    owner_scope = Scope.for_user(owner)

    {:ok, listing} =
      Catalog.publish(owner_scope, character!(owner_scope, "Aqua"), %{title: "Aqua", visibility: :readable})

    {:ok, report} = Reports.report(Scope.for_user(reporter), :listing, listing.id, "Stolen art")
    {listing, report}
  end

  test "a reported message is listed and deleting it after the password prompt resolves the report", ctx do
    {message, report} = message_report!(ctx)
    conn = log_in_user(build_conn(), ctx.moderator, sudo: false)

    {:ok, view, _html} = live(conn, ~p"/moderation/reports")
    assert has_element?(view, "#moderation-tab-reports")
    assert has_element?(view, "#report-placeholder")
    assert has_element?(view, "#reports-#{report.id}", "Message")
    assert has_element?(view, "#reports-#{report.id}", "Something vile")

    view |> element("#reports-#{report.id} a") |> render_click()
    assert_patch(view, ~p"/moderation/reports/#{report.id}")
    assert has_element?(view, "#report-reason", "Hateful")
    assert has_element?(view, "#report-reporter-link[href='/moderation/users/#{ctx.reporter.id}/record']")
    assert has_element?(view, "#report-subject-link[href='/moderation/users/#{ctx.owner.id}/record']")
    assert has_element?(view, "#report-open[href='/moderation/lookup/message/#{message.id}']")

    assert has_element?(
             view,
             "#report-sanction[href='/moderation/users/#{ctx.owner.id}/record?report=#{report.id}']"
           )

    view |> element("#report-delete-content") |> render_click()
    assert has_element?(view, "#sudo-modal")
    assert Repo.get(Message, message.id)

    view |> form("#sudo-form", sudo: %{password: "a long test password"}) |> render_submit()
    assert_patch(view, ~p"/moderation/reports")
    refute Repo.get(Message, message.id)
    assert Repo.get!(Report, report.id).status == :actioned
    refute has_element?(view, "#reports-#{report.id}")
    assert has_element?(view, "#report-placeholder")
  end

  test "taking a reported listing down needs a reason and removes it", ctx do
    {listing, report} = listing_report!(ctx)
    {:ok, view, _html} = live(log_in_user(build_conn(), ctx.moderator), ~p"/moderation/reports/#{report.id}")

    assert has_element?(view, "#report-open[href='/moderation/lookup/listing/#{listing.id}']")
    refute has_element?(view, "#report-delete-content")

    view |> form("#report-takedown", takedown: %{reason: "  "}) |> render_submit()
    assert render(view) =~ "Say why it is taken down; its owner is told"
    assert Repo.get(Listing, listing.id)

    view |> form("#report-takedown", takedown: %{reason: "Not theirs"}) |> render_submit()
    assert_patch(view, ~p"/moderation/reports")
    refute Repo.get(Listing, listing.id)
    assert Repo.get!(Report, report.id).status == :actioned
    refute has_element?(view, "#reports-#{report.id}")
  end

  test "dismissing the only report empties the list", ctx do
    {_listing, report} = listing_report!(ctx)
    {:ok, view, _html} = live(log_in_user(build_conn(), ctx.moderator), ~p"/moderation/reports/#{report.id}")

    view |> element("#report-dismiss") |> render_click()
    assert_patch(view, ~p"/moderation/reports")
    assert Repo.get!(Report, report.id).status == :dismissed
    refute has_element?(view, "#reports-#{report.id}")
    assert render(view) =~ "No open reports"
  end

  test "a report resolved elsewhere closes and a new one appears", ctx do
    {_listing, report} = listing_report!(ctx)
    {:ok, view, _html} = live(log_in_user(build_conn(), ctx.moderator), ~p"/moderation/reports/#{report.id}")

    {:ok, _} = Reports.dismiss(Scope.for_user(ctx.moderator), report.id)
    assert_patch(view, ~p"/moderation/reports")
    assert render(view) =~ "That report is already resolved"
    refute has_element?(view, "#reports-#{report.id}")

    {_message, other} = message_report!(ctx)
    assert has_element?(view, "#reports-#{other.id}")
  end

  test "an account without moderation.reports is redirected home", ctx do
    assert {:error, {:redirect, %{to: "/"}}} = live(log_in_user(build_conn(), ctx.reporter), ~p"/moderation/reports")
  end

  test "a click after the report was resolved elsewhere closes it", ctx do
    {_message, report} = message_report!(ctx)
    {:ok, view, _html} = live(log_in_user(build_conn(), ctx.moderator), ~p"/moderation/reports/#{report.id}")

    {:ok, _} = Reports.dismiss(Scope.for_user(ctx.moderator), report.id)
    assert_patch(view, ~p"/moderation/reports")

    render_click(view, "dismiss", %{})
    assert has_element?(view, "#report-placeholder")
  end

  describe "content moderation queues" do
    defp flag_rule!(ctx) do
      {:ok, rule} =
        Rules.create_rule(Scope.for_user(ctx.moderator), %{
          "name" => "Words",
          "kind" => "regex",
          "content_types" => ["characters"],
          "pattern" => "forbidden"
        })

      rule
    end

    defp held!(ctx, name) do
      :ok = Mythweaver.Permissions.put_grant!(ctx.owner, "moderation.characters.restrictive", :allow)
      scope = Scope.for_user(ctx.owner)
      {:held, hold} = Characters.create_character(scope, %{"name" => name, "description" => "a forbidden thing"})
      hold
    end

    test "a held item is approved from the held queue", ctx do
      flag_rule!(ctx)
      hold = held!(ctx, "Held-#{System.unique_integer([:positive])}")
      {:ok, view, _html} = live(log_in_user(build_conn(), ctx.moderator), ~p"/moderation/held")

      assert has_element?(view, "#review-tab-held")
      assert has_element?(view, "#held-#{hold.id}")

      view |> element("#held-#{hold.id} a") |> render_click()
      assert_patch(view, ~p"/moderation/held/#{hold.id}")
      assert has_element?(view, "#held-title", hold.title)
      assert has_element?(view, "#held-findings")
      assert has_element?(view, "#held-fields", "a forbidden thing")

      view |> element("#held-approve") |> render_click()
      assert_patch(view, ~p"/moderation/held")
      assert Repo.get_by(Character, name: hold.title)
    end

    test "rejecting a held item needs a reason", ctx do
      flag_rule!(ctx)
      hold = held!(ctx, "Held-#{System.unique_integer([:positive])}")
      {:ok, view, _html} = live(log_in_user(build_conn(), ctx.moderator), ~p"/moderation/held/#{hold.id}")

      html = view |> form("#held-reject-form", reject: %{reason: ""}) |> render_submit()
      assert html =~ "Say why it is rejected"
      assert has_element?(view, "#held-title")

      view |> form("#held-reject-form", reject: %{reason: "Not allowed"}) |> render_submit()
      assert_patch(view, ~p"/moderation/held")
      refute Holds.get(Scope.for_user(ctx.moderator), hold.id)
    end

    test "a rule report is listed under Flagged with its findings", ctx do
      owner_scope = Scope.for_user(ctx.owner)
      character = character!(owner_scope, "Ada")

      finding = %{"rule" => "Words", "action" => "flag", "field" => "description", "excerpt" => "bad", "reason" => nil}
      :ok = Reports.flag(:character, character.id, ctx.owner.id, "description: bad", [finding])
      [report] = Reports.list_open(Scope.for_user(ctx.moderator), :rule)

      {:ok, view, _html} = live(log_in_user(build_conn(), ctx.moderator), ~p"/moderation/flagged")
      assert has_element?(view, "#reports-#{report.id}", "automated rules")

      view |> element("#reports-#{report.id} a") |> render_click()
      assert_patch(view, ~p"/moderation/flagged/#{report.id}")
      assert has_element?(view, "#report-findings", "Words")
      assert has_element?(view, "#report-delete-content")
    end
  end
end
