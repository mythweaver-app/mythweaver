defmodule Mythweaver.Accounts.ThrottleTest do
  use ExUnit.Case, async: true

  alias Mythweaver.Accounts.Throttle

  defp key!(kind \\ :password), do: {kind, make_ref()}

  test "attempts count up front: past the free ones, the next is refused with nothing recorded" do
    key = key!()

    for _ <- 1..5, do: assert(Throttle.attempt(key) == :ok)

    assert {:error, {:throttled, seconds}} = Throttle.attempt(key)
    assert seconds in 29..30
  end

  test "parallel attempts can't all pass while their passwords are being checked" do
    key = key!()

    results =
      1..20
      |> Task.async_stream(fn _ -> Throttle.attempt(key) end, max_concurrency: 20)
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &(&1 == :ok)) == 5
    assert Enum.count(results, &match?({:error, {:throttled, _}}, &1)) == 15
  end

  test "a refused attempt counts on no key; release takes one back; clear forgets the key" do
    email = key!(:login_email)
    ip = key!(:login_ip)

    for _ <- 1..5, do: assert(Throttle.attempt([email, ip]) == :ok)
    assert {:error, {:throttled, _}} = Throttle.attempt([email, ip])

    # The IP was charged for the five allowed attempts only, so it has 15 left.
    for _ <- 1..15, do: assert(Throttle.attempt(ip) == :ok)
    assert {:error, {:throttled, _}} = Throttle.attempt(ip)

    Throttle.release(ip)
    assert Throttle.attempt(ip) == :ok

    Throttle.clear(email)
    assert Throttle.attempt(email) == :ok
  end
end
