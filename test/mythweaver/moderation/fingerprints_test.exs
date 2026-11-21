defmodule Mythweaver.Moderation.FingerprintsTest do
  use Mythweaver.DataCase, async: true

  alias Mythweaver.Moderation.Fingerprint
  alias Mythweaver.Moderation.Fingerprints

  defp user! do
    scope!(%{role: :user}).user
  end

  defp backdate!(user_id, last_seen_at) do
    Repo.update_all(from(f in Fingerprint, where: f.user_id == ^user_id),
      set: [first_seen_at: last_seen_at, last_seen_at: last_seen_at]
    )
  end

  test "recording a known signal again bumps seen_count and moves last_seen_at" do
    user = user!()
    :ok = Fingerprints.record(user.id, %{ip: "203.0.113.7"})
    earlier = DateTime.add(DateTime.utc_now(:second), -2, :day)
    backdate!(user.id, earlier)

    :ok = Fingerprints.record(user.id, %{ip: "203.0.113.7"})

    assert [%Fingerprint{kind: :ip, value: "203.0.113.7", seen_count: 2} = row] = Fingerprints.for_user(user.id)
    assert row.first_seen_at == earlier
    assert DateTime.after?(row.last_seen_at, earlier)
  end

  test "an IP row gets GeoIP data on each sighting, kept when a sighting finds none" do
    user = user!()
    :ok = Fingerprints.record(user.id, %{ip: "81.2.69.142", device: "dev-x"})

    rows = Map.new(Fingerprints.for_user(user.id), &{&1.kind, &1})
    assert rows.ip.geo["city"] == "London"
    assert rows.device.geo == nil

    Repo.update_all(from(f in Fingerprint, where: f.user_id == ^user.id and f.kind == :ip),
      set: [geo: %{"city" => "Old"}]
    )

    :ok = Fingerprints.record(user.id, %{ip: "81.2.69.142"})
    assert Repo.get!(Fingerprint, rows.ip.id).geo["city"] == "London"

    # 203.0.113.7 is in neither test database, like any address when no database is loaded.
    :ok = Fingerprints.record(user.id, %{ip: "203.0.113.7"})
    Repo.update_all(from(f in Fingerprint, where: f.value == "203.0.113.7"), set: [geo: %{"city" => "Kept"}])
    :ok = Fingerprints.record(user.id, %{ip: "203.0.113.7"})
    assert Repo.one!(from(f in Fingerprint, where: f.value == "203.0.113.7")).geo == %{"city" => "Kept"}
  end

  test "linked_accounts/1 ranks a shared device above a shared IP and skips self and user agents" do
    user = user!()
    device_twin = user!()
    ip_neighbour = user!()
    agent_twin = user!()

    :ok = Fingerprints.record(user.id, %{ip: "203.0.113.7", device: "device-a", user_agent: "Firefox"})
    :ok = Fingerprints.record(ip_neighbour.id, %{ip: "203.0.113.7"})
    :ok = Fingerprints.record(device_twin.id, %{device: "device-a"})
    :ok = Fingerprints.record(agent_twin.id, %{user_agent: "Firefox"})

    assert [%{user: first, matches: [%{kind: :device, value: "device-a"}]}, %{user: second, matches: [%{kind: :ip}]}] =
             Fingerprints.linked_accounts(user.id)

    assert first.id == device_twin.id
    assert second.id == ip_neighbour.id
  end

  test "prune/1 deletes rows last seen over a year before now and keeps younger ones" do
    user = user!()
    :ok = Fingerprints.record(user.id, %{ip: "203.0.113.7"})
    [%Fingerprint{last_seen_at: last_seen}] = Fingerprints.for_user(user.id)

    assert Fingerprints.prune(DateTime.add(last_seen, 364, :day)) == 0
    assert [_] = Fingerprints.for_user(user.id)

    assert Fingerprints.prune(DateTime.add(last_seen, 366, :day)) == 1
    assert Fingerprints.for_user(user.id) == []
  end

  test "a long user agent is recorded" do
    user = user!()
    agent = String.duplicate("a", 400)

    assert Fingerprints.record(user.id, %{user_agent: agent}) == :ok
    assert [%Fingerprint{kind: :user_agent, value: ^agent}] = Fingerprints.for_user(user.id)
  end

  test "a shared device outranks a shared browser fingerprint" do
    [a, b, c] = [user!(), user!(), user!()]
    fingerprint = String.duplicate("cd", 16)
    :ok = Fingerprints.record(a.id, %{fingerprint: fingerprint, device: "dev-ac"})
    :ok = Fingerprints.record(b.id, %{fingerprint: fingerprint})
    :ok = Fingerprints.record(c.id, %{device: "dev-ac"})

    assert [%{user: %{id: first}}, %{user: %{id: second}}] = Fingerprints.linked_accounts(a.id)
    assert {first, second} == {c.id, b.id}
  end
end
