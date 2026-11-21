defmodule Mythweaver.Jobs.LiveOutputTest do
  use ExUnit.Case, async: true

  alias Mythweaver.Jobs.LiveOutput
  alias Mythweaver.Schema

  test "another process reads the owner's chunks in arrival order, until a clear or the owner exits" do
    job_id = Schema.generate_id()
    test = self()

    owner =
      spawn(fn ->
        buffer = LiveOutput.open(job_id)
        LiveOutput.append(buffer, :delta, "Hel")
        LiveOutput.append(buffer, :reasoning, "Hmm, ")
        LiveOutput.append(buffer, :delta, "lo")
        LiveOutput.append(buffer, :reasoning, "greet.")
        send(test, :written)

        receive do
          :clear ->
            :ok = LiveOutput.clear(buffer)
            send(test, :cleared)
        end

        receive do
          :stop -> :ok
        end
      end)

    assert_receive :written, 2_000
    assert LiveOutput.read(job_id) == %{content: "Hello", reasoning: "Hmm, greet.", protected: []}

    send(owner, :clear)
    assert_receive :cleared, 2_000
    assert LiveOutput.read(job_id) == %{content: "", reasoning: "", protected: []}

    ref = Process.monitor(owner)
    send(owner, :stop)
    assert_receive {:DOWN, ^ref, :process, ^owner, :normal}, 2_000
    assert LiveOutput.read(job_id) == nil
  end

  test "a second buffer for a job already registered is refused and writes nothing" do
    job_id = Schema.generate_id()
    first = LiveOutput.open(job_id)
    LiveOutput.append(first, :delta, "kept")

    second = Task.async(fn -> LiveOutput.open(job_id) end) |> Task.await()

    assert second == nil
    assert LiveOutput.append(second, :delta, "dropped") == :ok
    assert LiveOutput.read(job_id) == %{content: "kept", reasoning: "", protected: []}
  end

  test "the buffer keeps its scrub pairs, set at open or replaced by its owner, unapplied" do
    job_id = Schema.generate_id()
    buffer = LiveOutput.open(job_id, [{"secret", "[Hidden]"}])
    LiveOutput.append(buffer, :reasoning, "a secret")

    assert LiveOutput.read(job_id) == %{content: "", reasoning: "a secret", protected: [{"secret", "[Hidden]"}]}

    assert LiveOutput.protect(job_id, [{"other", "[Other]"}]) == :ok
    assert %{protected: [{"other", "[Other]"}]} = LiveOutput.read(job_id)
  end
end
