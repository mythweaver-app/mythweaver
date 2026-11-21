defmodule Mythweaver.Moderation.SanctionsTest do
  use Mythweaver.DataCase, async: true

  alias Mythweaver.Accounts
  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Accounts.UserToken
  alias Mythweaver.Moderation
  alias Mythweaver.Moderation.Ban
  alias Mythweaver.Moderation.Fingerprints
  alias Mythweaver.Moderation.LogEntry
  alias Mythweaver.Moderation.Report
  alias Mythweaver.Moderation.Reports
  alias Mythweaver.Moderation.Sanctions
  alias Mythweaver.Notifications
  alias Mythweaver.Permissions

  defp user!, do: scope!(%{role: :user}).user

  defp ban!(actor, user, params) do
    {:ok, %{bans: bans}} = Sanctions.ban(actor, user, Map.merge(%{"reason" => "spam", "duration" => "7d"}, params))
    bans
  end

  describe "ban/3" do
    test "an account ban deletes the target's session tokens and is the active ban" do
      moderator = scope!()
      user = user!()
      Accounts.generate_user_session_token(user)
      Accounts.generate_user_session_token(user)

      assert {:ok, %{bans: [%Ban{kind: :account, id: id}], tokens: [_, _]}} =
               Sanctions.ban(moderator, user, %{"reason" => "spam", "duration" => "7d", "account" => "true"})

      assert Repo.all_by(UserToken, user_id: user.id) == []
      assert %Ban{id: ^id} = Sanctions.active_ban(user, %{})
    end

    test "a ban whose end has passed is inactive" do
      user = user!()
      [ban] = ban!(scope!(), user, %{"account" => "true"})

      Repo.update_all(from(b in Ban, where: b.id == ^ban.id),
        set: [ends_at: DateTime.add(DateTime.utc_now(:second), -1, :minute)]
      )

      assert Sanctions.active_ban(user, %{}) == nil
    end

    test "lifting a ban makes it inactive and logs :ban_lifted" do
      moderator = scope!()
      user = user!()
      [ban] = ban!(moderator, user, %{"account" => "true"})

      assert {:ok, %Ban{lifted_at: %DateTime{}}} = Sanctions.lift_ban(moderator, ban.id)
      assert Sanctions.active_ban(user, %{}) == nil

      assert Repo.exists?(
               from(e in LogEntry,
                 where: e.action == :ban_lifted and e.subject_id == ^ban.id and e.actor_id == ^moderator.user.id
               )
             )
    end

    test "owners and the moderator themself cannot be suspended" do
      moderator = scope!()
      owner = scope!(%{role: :owner}).user
      params = %{"reason" => "spam", "duration" => "7d", "account" => "true"}

      assert Sanctions.ban(moderator, owner, params) == {:error, :owner}
      assert Sanctions.ban(moderator, moderator.user, params) == {:error, :self}
    end

    test "a value the moderator was also seen with is refused" do
      moderator = scope!()
      user = user!()
      :ok = Fingerprints.record(user.id, %{device: "shared-device"})
      :ok = Fingerprints.record(moderator.user.id, %{device: "shared-device"})

      assert Sanctions.ban(moderator, user, %{
               "reason" => "spam",
               "duration" => "7d",
               "values" => ["device:shared-device"]
             }) == {:error, :own_signal}
    end

    test "a value the target was never seen with is refused" do
      moderator = scope!()
      user = user!()
      :ok = Fingerprints.record(user.id, %{ip: "203.0.113.7"})

      assert Sanctions.ban(moderator, user, %{
               "reason" => "spam",
               "duration" => "7d",
               "values" => ["ip:198.51.100.1"]
             }) == {:error, :unknown_value}
    end

    test "nothing to ban is refused" do
      assert Sanctions.ban(scope!(), user!(), %{"reason" => "spam", "duration" => "7d"}) == {:error, :no_targets}
    end

    test "banning needs sudo mode" do
      moderator = %{scope!() | sudo_until: nil}

      assert Sanctions.ban(moderator, user!(), %{"reason" => "spam", "duration" => "7d", "account" => "true"}) ==
               {:error, :sudo_required}
    end

    test "an IP ban matches another account seen with that IP, never an owner" do
      user = user!()
      :ok = Fingerprints.record(user.id, %{ip: "203.0.113.7"})
      [%Ban{id: id}] = ban!(scope!(), user, %{"values" => ["ip:203.0.113.7"]})

      other = user!()
      owner = scope!(%{role: :owner}).user

      assert %Ban{id: ^id, kind: :ip} = Sanctions.active_ban(other, %{ip: "203.0.113.7"})
      assert Sanctions.active_ban(other, %{ip: "198.51.100.1"}) == nil
      assert Sanctions.active_ban(owner, %{ip: "203.0.113.7"}) == nil
    end

    test "a ban with a report_id marks that report actioned" do
      user = user!()
      {:ok, report} = Reports.report(scope!(%{role: :user}), :user, user.id, "rude")

      ban!(scope!(), user, %{"account" => "true", "report_id" => report.id})

      assert %Report{status: :actioned, resolved_at: %DateTime{}} = Repo.get(Report, report.id)
    end

    test "a value-only ban of an owner is refused" do
      owner = scope!(%{role: :owner}).user
      :ok = Fingerprints.record(owner.id, %{ip: "203.0.113.7"})

      assert Sanctions.ban(scope!(), owner, %{"reason" => "x", "duration" => "7d", "values" => ["ip:203.0.113.7"]}) ==
               {:error, :owner}
    end

    test "a value ban returns every session seen with the value, deleting none" do
      user = user!()
      token = Accounts.generate_user_session_token(user)
      :ok = Fingerprints.record(user.id, %{device: "dev-abc"})

      assert {:ok, %{tokens: tokens}} =
               Sanctions.ban(scope!(), user, %{"reason" => "x", "duration" => "7d", "values" => ["device:dev-abc"]})

      assert Enum.any?(tokens, &(&1.token == token))
      assert Accounts.get_user_by_session_token(token)
    end

    test "account and value bans need their own permissions" do
      user = user!()
      :ok = Fingerprints.record(user.id, %{ip: "203.0.113.7"})
      [account_ban] = ban!(scope!(), user, %{"account" => "true"})

      fingerprints = granted!("moderation.fingerprints")
      sanction = granted!("moderation.accounts.sanction")
      params = %{"reason" => "x", "duration" => "7d"}

      assert Sanctions.ban(fingerprints, user, Map.put(params, "account", "true")) == {:error, :unauthorized}
      assert Sanctions.lift_ban(fingerprints, account_ban.id) == {:error, :unauthorized}
      assert Sanctions.ban(sanction, user, Map.put(params, "values", ["ip:203.0.113.7"])) == {:error, :unauthorized}
    end

    test "device and fingerprint bans match other accounts" do
      user = user!()
      fingerprint = String.duplicate("ab", 16)
      :ok = Fingerprints.record(user.id, %{device: "dev-a", fingerprint: fingerprint})
      ban!(scope!(), user, %{"values" => ["device:dev-a", "fingerprint:#{fingerprint}"]})
      other = user!()

      assert %Ban{kind: :device, value: "dev-a"} = Sanctions.active_ban(other, %{device: "dev-a"})
      assert %Ban{kind: :fingerprint} = Sanctions.active_ban(other, %{fingerprint: fingerprint})
    end

    test "every ban row is logged" do
      user = user!()
      :ok = Fingerprints.record(user.id, %{ip: "203.0.113.7"})
      bans = ban!(scope!(), user, %{"account" => "true", "values" => ["ip:203.0.113.7"]})

      assert length(bans) == 2

      for ban <- bans do
        assert Repo.exists?(from(e in LogEntry, where: e.action == :banned and e.subject_id == ^ban.id))
      end
    end

    test "banning, lifting and warning broadcast a moderation change" do
      Phoenix.PubSub.subscribe(Mythweaver.PubSub, Moderation.topic())
      moderator = scope!()
      user = user!()

      [ban] = ban!(moderator, user, %{"account" => "true"})
      assert_receive {Mythweaver.Moderation, :changed}
      {:ok, _} = Sanctions.lift_ban(moderator, ban.id)
      assert_receive {Mythweaver.Moderation, :changed}
      {:ok, _} = Sanctions.warn(moderator, user, "Be kind")
      assert_receive {Mythweaver.Moderation, :changed}
    end
  end

  defp granted!(key) do
    user = user!()
    Permissions.put_grant!(user, key, :allow)
    sudo(Scope.for_user(user))
  end

  describe "warnings" do
    test "warn/4 leaves a pending warning and an inbox notification until acknowledged" do
      user = user!()

      assert {:ok, _warning} = Sanctions.warn(scope!(), user, "Be kind")
      assert Sanctions.pending_warnings?(user.id)

      assert [%{kind: :moderation_warning, body: "Be kind"}] = Notifications.inbox(Scope.for_user(user))

      assert :ok = Sanctions.acknowledge_warnings(Scope.for_user(user))
      refute Sanctions.pending_warnings?(user.id)
    end

    test "owners and the moderator themself cannot be warned" do
      moderator = scope!()
      owner = scope!(%{role: :owner}).user

      assert Sanctions.warn(moderator, owner, "x") == {:error, :owner}
      assert Sanctions.warn(moderator, moderator.user, "x") == {:error, :self}
    end

    test "a report about another account is left open" do
      a = user!()
      b = user!()
      {:ok, report} = Reports.report(scope!(%{role: :user}), :user, b.id, "rude")

      assert {:ok, warning} = Sanctions.warn(scope!(), a, "Be kind", report.id)
      assert warning.report_id == nil
      assert %Report{status: :open} = Repo.get(Report, report.id)
    end
  end
end
