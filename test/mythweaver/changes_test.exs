defmodule Mythweaver.ChangesTest do
  # Not async: user B also hears site broadcasts, and a concurrent test's site write would reach it.
  use Mythweaver.DataCase

  alias Mythweaver.Changes

  test "a user's own writes reach only that user; site writes reach everyone" do
    a = scope!(%{role: :user})
    b = scope!(%{role: :user})

    test_pid = self()

    listen = fn scope, tag ->
      spawn_link(fn ->
        Changes.subscribe(scope, [:characters])
        send(test_pid, {:subscribed, tag})

        for _ <- 1..2 do
          receive do
            {Changes, kind} -> send(test_pid, {tag, kind})
          end
        end
      end)
    end

    listen.(a, :a)
    listen.(b, :b)
    assert_receive {:subscribed, :a}
    assert_receive {:subscribed, :b}

    Changes.broadcast(:characters, a.user.id)
    assert_receive {:a, :characters}
    refute_receive {:b, :characters}, 100

    Changes.broadcast(:characters, nil)
    assert_receive {:a, :characters}
    assert_receive {:b, :characters}
  end
end
