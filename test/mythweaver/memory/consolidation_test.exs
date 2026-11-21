defmodule Mythweaver.Memory.ConsolidationTest do
  # Not `async: true`: memory jobs run in scheduler-spawned tasks, which need the shared sandbox and
  # shared `Req.Test` stubs.
  use Mythweaver.DataCase

  alias Mythweaver.AI
  alias Mythweaver.Characters
  alias Mythweaver.Chats
  alias Mythweaver.Jobs
  alias Mythweaver.Jobs.Job
  alias Mythweaver.Jobs.Scheduler
  alias Mythweaver.Lore
  alias Mythweaver.Lore.BookEntry
  alias Mythweaver.Memory
  alias Mythweaver.Memory.Clips
  alias Mythweaver.Memory.Consolidation
  alias Mythweaver.Memory.Record
  alias Mythweaver.Notifications
  alias Mythweaver.Notifications.Notification
  alias Mythweaver.Prompts

  setup context do
    scope = scope!()
    Req.Test.set_req_test_to_shared(context)
    on_exit(fn -> await_idle(100) end)
    :ok = Jobs.subscribe(scope)

    player = character!(scope, "Player")
    responder = character!(scope, "Responder")
    model = linked_model!(scope)
    chat = chat!(scope, [player, responder])
    profile = profile!(scope, model)
    book = Memory.ensure_book(scope, chat)

    %{scope: scope, player: player, responder: responder, model: model, chat: chat, profile: profile, book: book}
  end

  defp await_idle(0) do
    %{running: running, queued: queued} = Scheduler.status()
    Enum.each(running ++ queued, &Scheduler.cancel/1)
  end

  defp await_idle(tries) do
    case Scheduler.status() do
      %{running: [], queued: []} ->
        :ok

      _busy ->
        Process.sleep(10)
        await_idle(tries - 1)
    end
  end

  describe "batches/4" do
    test "cuts by entry count", ctx do
      records = for i <- 1..5, do: memory!(ctx, i, "Short #{i}.")
      batches = Consolidation.batches(records, 2, 12_000, nil)
      assert Enum.map(batches, &length/1) == [2, 2, 1]
      assert List.flatten(batches) == records
    end

    test "cuts by token budget, an oversize record alone", ctx do
      small = String.duplicate("word ", 30)
      big = String.duplicate("word ", 300)

      records =
        [a, b, c, d] = for {text, i} <- Enum.with_index([small, small, big, small], 1), do: memory!(ctx, i, text)

      assert Consolidation.batches(records, 20, 100, nil) == [[a, b], [c], [d]]
    end
  end

  test "a consolidation saves an Arc and marks its sources consolidated and disabled", %{scope: scope} = ctx do
    [one, two] = for i <- 1..2, do: memory!(ctx, i, "Memory #{i}.")
    stub_reply(arc_reply(["001", "002"]))

    assert {:ok, [job]} = Consolidation.consolidate(scope, ctx.chat, ctx.book, 1, [one.id, two.id], review: false)
    assert job.label == "Arc from 2 memories"
    assert %Job{status: :completed, result: %{"record_ids" => [arc_id]}} = await_job(scope, job)

    arc = Record |> Repo.get!(arc_id) |> Repo.preload([:entry, :sources])
    assert %Record{kind: :consolidation, tier: 1, sequence: 1, range_start: 0, range_end: 3} = arc
    assert arc.entry.name == "[ARC 001] - The Arc"
    assert arc.entry.content == "Both memories, together."
    assert Memory.record_enabled?(arc)
    assert arc |> Map.get(:sources) |> Enum.map(& &1.id) |> Enum.sort() == Enum.sort([one.id, two.id])

    for source <- [one, two] do
      source = Record |> Repo.get!(source.id) |> Repo.preload(:entry)
      assert source.consolidated_into_id == arc.id
      assert source.disabled_by_consolidation
      refute Memory.record_enabled?(source)
    end

    assert Consolidation.eligible(scope, ctx.book, 1) == []
    assert Consolidation.consolidate(scope, ctx.chat, ctx.book, 1, [one.id]) == {:error, :ineligible}
  end

  test "eligible records follow the book's order, imported records included", %{scope: scope} = ctx do
    generated = memory!(ctx, 2, "Generated.")
    imported = memory!(ctx, 1, "Imported.")
    Repo.update_all(from(r in Record, where: r.id == ^imported.id), set: [range_start: nil, range_end: nil])

    for {record, order} <- [{imported, 1}, {generated, 2}] do
      Repo.update_all(
        from(be in BookEntry,
          where: be.lore_book_id == ^ctx.book.id and be.lore_entry_id == ^record.lore_entry_id
        ),
        set: [order: order]
      )
    end

    assert Enum.map(Consolidation.eligible(scope, ctx.book, 1), & &1.id) == [imported.id, generated.id]
    assert Enum.map(Clips.topical_sources(scope, ctx.book.id), & &1.id) == [imported.id, generated.id]
  end

  test "drops an unknown member id and keeps the unassigned list for review", %{scope: scope} = ctx do
    [one, two] = for i <- 1..2, do: memory!(ctx, i, "Memory #{i}.")

    reply =
      Jason.encode!(%{
        summaries: [%{title: "The Arc", summary: "Only one.", keywords: ["arc"], member_ids: ["001", "009"]}],
        unassigned_items: [%{id: "002", reason: "Unrelated"}, %{id: "042", reason: "Ghost"}]
      })

    stub_reply(reply)

    {:ok, [job]} = Consolidation.consolidate(scope, ctx.chat, ctx.book, 1, [one.id, two.id], review: true)
    assert %Job{status: :review, result: result} = job = await_job(scope, job)

    assert [%{"title" => "The Arc", "source_ids" => [one_id]}] = result["candidates"]
    assert one_id == one.id
    assert result["unassigned"] == [%{"record_id" => two.id, "reason" => "Unrelated"}]

    assert {:ok, [arc]} =
             Memory.approve(scope, job, %{"candidates" => %{"0" => %{"keep" => "true", "title" => "Edited"}}})

    assert Lore.get_entry!(arc.lore_entry_id).name == "[ARC 001] - Edited"
    assert Repo.get!(Record, two.id).consolidated_into_id == nil
  end

  test "approving refuses a candidate key that is not an index", %{scope: scope} = ctx do
    [one, two] = for i <- 1..2, do: memory!(ctx, i, "Memory #{i}.")

    stub_reply(
      Jason.encode!(%{summaries: [%{title: "Arc", summary: "Both.", keywords: ["arc"], member_ids: ["001", "002"]}]})
    )

    {:ok, [job]} = Consolidation.consolidate(scope, ctx.chat, ctx.book, 1, [one.id, two.id], review: true)
    %Job{status: :review} = job = await_job(scope, job)

    assert Memory.approve(scope, job, %{"candidates" => %{"zero" => %{"keep" => "true"}}}) == {:error, :invalid}
    assert Jobs.get_job(scope, job.id).status == :review
    assert Repo.get!(Record, one.id).consolidated_into_id == nil
  end

  test "check_ready announces a watched tier at its minimum and keeps it in the inbox until consolidated",
       %{scope: scope} = ctx do
    :ok = Mythweaver.Settings.put(scope, :site, "memory.consolidation_watch_tiers", [1])
    :ok = Mythweaver.Settings.put(scope, :site, "memory.consolidation_minimum_1", 2)

    :ok = Phoenix.PubSub.subscribe(Mythweaver.PubSub, Memory.topic(ctx.chat.id))
    book_id = ctx.book.id
    chat_id = ctx.chat.id

    one = memory!(ctx, 1, "One.")
    assert Consolidation.check_ready(scope, ctx.book) == :ok
    refute_received {:consolidation_ready, _}
    assert Notifications.inbox(scope) == []

    two = memory!(ctx, 2, "Two.")
    assert Consolidation.check_ready(scope, ctx.book) == :ok
    assert_received {:consolidation_ready, %{book_id: ^book_id, tier: 1}}

    # Announced again on the next save, but listed once; "Clear all" leaves it.
    assert Consolidation.check_ready(scope, ctx.book) == :ok
    :ok = Notifications.dismiss_all(scope)

    assert [%Notification{kind: :consolidation_ready, chat_id: ^chat_id, lore_book_id: ^book_id, tier: 1} = n] =
             Notifications.inbox(scope)

    assert Notifications.path(n) == "/chats/#{chat_id}/memory?tab=consolidate"

    # The save follows the job's completion with its readiness check: wait for the inbox to change.
    :ok = Notifications.subscribe(scope)
    stub_reply(arc_reply(["001", "002"]))
    {:ok, [job]} = Consolidation.consolidate(scope, ctx.chat, ctx.book, 1, [one.id, two.id], review: false)
    %Job{status: :completed} = await_job(scope, job)

    assert_receive {Notifications, :inbox_changed}
    assert Notifications.inbox(scope) == []
  end

  test "check_ready reaches only the saving owner's chats on a shared book", %{scope: scope} = ctx do
    :ok = Mythweaver.Settings.put(scope, :site, "memory.consolidation_watch_tiers", [1])
    :ok = Mythweaver.Settings.put(scope, :site, "memory.consolidation_minimum_1", 1)

    # Two admins, each with a chat on the same site book.
    {:ok, shared} = Lore.create_book(scope, %{name: "Shared memories"}, site: true)
    other = scope!()
    other_chat = chat!(other, [character!(other, "Their player"), character!(other, "Their responder")])

    for {owner, chat} <- [{scope, ctx.chat}, {other, other_chat}] do
      {:ok, _} = Memory.update_chat_settings(owner, Memory.chat_settings(owner, chat), %{memory_book_id: shared.id})
    end

    memory!(%{ctx | book: shared}, 1, "One.")
    book_id = shared.id

    :ok = Phoenix.PubSub.subscribe(Mythweaver.PubSub, Memory.topic(other_chat.id))
    assert Consolidation.check_ready(scope, shared) == :ok
    refute_received {:consolidation_ready, _}

    :ok = Phoenix.PubSub.subscribe(Mythweaver.PubSub, Memory.topic(ctx.chat.id))
    assert Consolidation.check_ready(scope, shared) == :ok
    assert_received {:consolidation_ready, %{book_id: ^book_id, tier: 1}}
    refute_received {:consolidation_ready, _}
  end

  test "regenerating a consolidated memory is refused", %{scope: scope} = ctx do
    [one, two] = for i <- 1..2, do: memory!(ctx, i, "Memory #{i}.")
    stub_reply(arc_reply(["001", "002"]))

    {:ok, [job]} = Consolidation.consolidate(scope, ctx.chat, ctx.book, 1, [one.id, two.id], review: false)
    %Job{status: :completed} = await_job(scope, job)

    assert Memory.regenerate(scope, ctx.chat, Repo.get!(Record, one.id)) == {:error, :consolidated}
  end

  test "an unattended save is refused when an unclaimed source changed", %{scope: scope} = ctx do
    [one, two] = for i <- 1..2, do: memory!(ctx, i, "Memory #{i}.")
    blocking_reply(arc_reply(["001"]))

    {:ok, [job]} = Consolidation.consolidate(scope, ctx.chat, ctx.book, 1, [one.id, two.id], review: false)
    assert_receive {:blocked, pid}
    {:ok, _entry} = Lore.update_entry(scope, two.entry, %{content: "Changed while it ran."})
    send(pid, :release)

    assert %Job{status: :failed, error: "Not saved: the source changed after this was queued."} = await_job(scope, job)
    assert Repo.all(from(r in Record, where: r.kind == :consolidation)) == []
  end

  test "retrying a consolidation that failed on a changed source reads the sources again, and saves",
       %{scope: scope} = ctx do
    [one, two] = for i <- 1..2, do: memory!(ctx, i, "Memory #{i}.")
    blocking_reply(arc_reply(["001"]))

    {:ok, [job]} = Consolidation.consolidate(scope, ctx.chat, ctx.book, 1, [one.id, two.id], review: false)
    assert_receive {:blocked, pid}
    {:ok, _entry} = Lore.update_entry(scope, two.entry, %{content: "Changed while it ran."})
    send(pid, :release)
    %Job{status: :failed} = await_job(scope, job)

    stub_reply(arc_reply(["001", "002"]))
    {:ok, _} = Jobs.retry(scope, job.id)

    assert %Job{status: :completed} = await_job(scope, job)
    assert [%Record{}] = Repo.all(from(r in Record, where: r.kind == :consolidation))
  end

  test "approving a compaction after the entry was edited is refused", %{scope: scope} = ctx do
    record = memory!(ctx, 1, "A long, wordy memory.")
    stub_reply("A memory.")

    assert {:ok, job} = Memory.compact(scope, ctx.chat, record)
    assert %Job{status: :review, result: %{"content" => "A memory."}} = job = await_job(scope, job)

    {:ok, _entry} = Lore.update_entry(scope, record.entry, %{content: "Rewritten by hand."})

    assert Memory.approve(scope, job, %{"content" => "A memory."}) == {:error, :changed}
    assert Lore.get_entry!(record.lore_entry_id).content == "Rewritten by hand."
    assert Jobs.get_job(scope, job.id).status == :review
  end

  test "retrying a compaction after the entry was edited compacts it as it is now, and saves",
       %{scope: scope} = ctx do
    record = memory!(ctx, 1, "A long, wordy memory.")
    stub_reply("A memory.")

    {:ok, job} = Memory.compact(scope, ctx.chat, record)
    %Job{status: :review} = job = await_job(scope, job)
    {:ok, _entry} = Lore.update_entry(scope, record.entry, %{content: "Rewritten by hand, at length."})
    assert Memory.approve(scope, job, %{"content" => "A memory."}) == {:error, :changed}

    stub_reply("Rewritten.")
    {:ok, _} = Jobs.retry(scope, job.id)
    %Job{status: :review, result: %{"content" => "Rewritten."}} = retried = await_job(scope, job)
    assert retried.prompt_name == Prompts.get_prompt!(ctx.profile.compaction_prompt_id).name

    assert {:ok, _record} = Memory.approve(scope, retried, %{"content" => "Rewritten."})
    assert Lore.get_entry!(record.lore_entry_id).content == "Rewritten."
  end

  test "compacting unsaved text renders it chatless and completes unreviewed with the rewrite", %{scope: scope} do
    test = self()

    Req.Test.stub(Mythweaver.AI, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:request, body})
      reply(conn, "Short.")
    end)

    assert {:ok, job} = Memory.compact_text(scope, %{title: "T", content: "Long wordy text.", kind: "lore"})

    assert %Job{status: :completed, chat_id: nil, result: %{"content" => "Short."}, prompt_name: "Test compaction"} =
             await_job(scope, job)

    assert_received {:request, body}
    assert body =~ "Long wordy text."

    assert Memory.compact_text(scope, %{title: "T", content: "  "}) == {:error, :empty}
  end

  test "a compaction's response limit follows its entry's length, not the profile's, plus reasoning room",
       %{scope: scope, profile: profile} do
    prompt = Prompts.get_prompt!(profile.compaction_prompt_id)
    short = "A short entry about the inn."
    long = String.duplicate("The innkeeper keeps a ledger of every guest and their debts. ", 800)

    limit = fn content, thinking ->
      {:ok, _prompt} = Prompts.update_prompt(scope, prompt, %{thinking: thinking})
      test = self()

      Req.Test.stub(Mythweaver.AI, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test, {:max_tokens, Jason.decode!(body)["max_tokens"]})
        reply(conn, "Short.")
      end)

      {:ok, job} = Memory.compact_text(scope, %{title: "Inn", content: content})
      %Job{status: :completed} = await_job(scope, job)
      assert_received {:max_tokens, max_tokens}
      max_tokens
    end

    # The profile allows 4096; neither entry is held to it.
    assert profile.max_tokens == 4096
    assert limit.(short, :none) < 4096
    assert limit.(long, :none) > 4096
    assert limit.(short, :medium) > limit.(short, :none)
    assert limit.(long, :high) > limit.(long, :medium)
  end

  describe "coverage check" do
    setup ctx do
      sources = for i <- 1..3, do: memory!(ctx, i, "Memory #{i}.")

      stub_reply(
        Jason.encode!(%{
          summaries: [%{title: "The Arc", summary: "Only one.", keywords: ["arc"], member_ids: ["001"]}],
          unassigned_items: [%{id: "002", reason: "Unrelated"}]
        })
      )

      %{sources: sources}
    end

    test "a review lists sources the model skipped as left out", %{scope: scope, sources: [one, two, three]} = ctx do
      {:ok, [job]} = Consolidation.consolidate(scope, ctx.chat, ctx.book, 1, [one.id, two.id, three.id], review: true)
      assert %Job{status: :review, result: result} = await_job(scope, job)

      assert result["unassigned"] == [
               %{"record_id" => two.id, "reason" => "Unrelated"},
               %{"record_id" => three.id, "reason" => "Not summarized or listed by the model."}
             ]
    end

    test "an unattended save keeps and announces the left-out sources", %{scope: scope, sources: sources} = ctx do
      [one, two, three] = sources
      :ok = Phoenix.PubSub.subscribe(Mythweaver.PubSub, Memory.topic(ctx.chat.id))

      {:ok, [job]} = Consolidation.consolidate(scope, ctx.chat, ctx.book, 1, Enum.map(sources, & &1.id), review: false)
      assert %Job{status: :completed, result: result} = await_job(scope, job)

      assert Enum.map(result["unassigned"], & &1["record_id"]) == [two.id, three.id]
      assert Repo.get!(Record, one.id).consolidated_into_id
      assert Repo.get!(Record, two.id).consolidated_into_id == nil
      assert Repo.get!(Record, three.id).consolidated_into_id == nil
      assert_receive {:consolidation_left_out, %{count: 2}}
    end
  end

  describe "regenerate_candidate/3" do
    setup %{scope: scope} = ctx do
      [one, two, three] = for i <- 1..3, do: memory!(ctx, i, "Memory #{i}.")

      stub_reply(
        Jason.encode!(%{
          summaries: [
            %{title: "First", summary: "One.", keywords: ["a"], member_ids: ["001"]},
            %{title: "Second", summary: "Two and three.", keywords: ["b"], member_ids: ["002", "003"]}
          ],
          unassigned_items: []
        })
      )

      {:ok, [job]} = Consolidation.consolidate(scope, ctx.chat, ctx.book, 1, [one.id, two.id, three.id], review: true)
      %Job{status: :review} = job = await_job(scope, job)
      %{review: job}
    end

    test "replaces only that candidate and keeps its sources", %{scope: scope, review: review} do
      [first, second] = review.result["candidates"]
      stub_reply(arc_reply(["001", "002"]))

      assert {:ok, child} = Consolidation.regenerate_candidate(scope, review, 1)
      assert %Job{status: :completed} = await_job(scope, child)

      parent = Jobs.get_job(scope, review.id)
      assert parent.status == :review
      assert [^first, replaced] = parent.result["candidates"]
      assert replaced["title"] == "The Arc"
      assert replaced["summary"] == "Both memories, together."
      assert replaced["source_ids"] == second["source_ids"]
    end

    test "an unknown index is not found", %{scope: scope, review: review} do
      assert Consolidation.regenerate_candidate(scope, review, 5) == {:error, :not_found}
    end

    test "the child fails when the review was discarded first", %{scope: scope, review: review} do
      blocking_reply(arc_reply(["001"]))

      assert {:ok, child} = Consolidation.regenerate_candidate(scope, review, 1)
      assert_receive {:blocked, pid}
      {:ok, _} = Memory.discard(scope, review)
      send(pid, :release)

      assert %Job{status: :failed, error: error} = await_job(scope, child)
      assert error =~ "changed"
    end
  end

  ## Helpers

  defp arc_reply(member_ids) do
    Jason.encode!(%{
      summaries: [%{title: "The Arc", summary: "Both memories, together.", keywords: ["arc"], member_ids: member_ids}],
      unassigned_items: []
    })
  end

  # A tier-0 record in the chat's book covering positions `2i - 2..2i - 1`.
  defp memory!(%{scope: scope, book: book, chat: chat}, i, content) do
    {:ok, entry} =
      Lore.create_entry(scope, %{name: "[#{i}] Memory", content: content, keywords: ["memory#{i}"]}, [book.id])

    {:ok, record} =
      %Record{}
      |> Record.changeset(%{
        lore_entry_id: entry.id,
        lore_book_id: book.id,
        chat_id: chat.id,
        kind: :memory,
        tier: 0,
        sequence: i,
        range_start: 2 * i - 2,
        range_end: 2 * i - 1
      })
      |> Repo.insert()

    Repo.preload(record, :entry)
  end

  defp await_job(scope, %Job{id: id}) do
    receive do
      {:job_changed, %{id: ^id, status: status}} when status in [:completed, :failed, :canceled, :review] ->
        Jobs.get_job(scope, id)
    after
      2000 -> flunk("job #{id} did not finish; now #{Jobs.get_job(scope, id).status}")
    end
  end

  defp stub_reply(text), do: Req.Test.stub(Mythweaver.AI, &reply(&1, text))

  # Holds the request until the test sends `:release`, so the test can act while the job runs.
  defp blocking_reply(text) do
    test = self()

    Req.Test.stub(Mythweaver.AI, fn conn ->
      send(test, {:blocked, self()})

      receive do
        :release -> reply(conn, text)
      end
    end)
  end

  defp reply(conn, text) do
    frames = [
      "data: #{Jason.encode!(%{choices: [%{index: 0, delta: %{content: text}, finish_reason: nil}]})}\n\n",
      ~s(data: {"choices":[{"finish_reason":"stop","index":0,"delta":{}}]}\n\n),
      "data: [DONE]\n\n"
    ]

    conn = Plug.Conn.send_chunked(conn, 200)

    Enum.reduce(frames, conn, fn frame, conn ->
      {:ok, conn} = Plug.Conn.chunk(conn, frame)
      conn
    end)
  end

  defp character!(scope, name) do
    {:ok, character} = Characters.create_character(scope, %{name: name})
    character
  end

  defp chat!(scope, [player | _] = characters) do
    {:ok, chat} =
      Chats.create_chat(scope, %{
        name: "Consolidation chat",
        participants: Enum.map(characters, &%{character_id: &1.id}),
        player_character_id: player.id
      })

    Chats.get_chat!(chat.id)
  end

  defp linked_model!(scope) do
    {:ok, provider} =
      AI.create_provider(scope, %{
        name: "Local-#{System.unique_integer([:positive])}",
        adapter: :openai_compatible,
        base_url: "http://localhost:8080/v1"
      })

    {:ok, model} =
      AI.create_model(scope, %{name: "Gemma-#{System.unique_integer([:positive])}", api_model_id: "gemma-4"})

    {:ok, _link} = AI.link_model(scope, provider, model)
    model
  end

  defp profile!(scope, model) do
    {:ok, profile} =
      Memory.create_profile(scope, %{
        name: "Default",
        ai_model_id: model.id,
        consolidation_prompt_id: prompt!(scope, :consolidation, "{{ anchors.memory.sources_text }}").id,
        compaction_prompt_id: prompt!(scope, :compaction, "{{ anchors.memory.entry.content }}").id
      })

    {:ok, profile} = Memory.set_default_profile(scope, profile)
    profile
  end

  defp prompt!(scope, purpose, material) do
    {:ok, prompt} = Prompts.create_prompt(scope, %{name: "Test #{purpose}", purpose: purpose})
    {:ok, block} = Prompts.create_block(scope, %{name: "Task #{purpose}", content: "Do the #{purpose}."})
    {:ok, user} = Prompts.create_block(scope, %{name: "Material #{purpose}", role: :user, content: material})
    {:ok, _} = Prompts.add_block(scope, prompt, block)
    {:ok, _} = Prompts.add_block(scope, prompt, user)
    prompt
  end
end
