defmodule Mythweaver.Memory.AssistanceTest do
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
  alias Mythweaver.Memory
  alias Mythweaver.Memory.Clips
  alias Mythweaver.Memory.Record
  alias Mythweaver.Memory.Scene
  alias Mythweaver.Memory.TopicSuggestion
  alias Mythweaver.Messages
  alias Mythweaver.Prompts

  @memory ~s({"title": "Title", "content": "Kai drank tea.", "keywords": ["tea"]})
  @sentence "Kai poured a cup of green tea."

  setup context do
    scope = scope!()
    Req.Test.set_req_test_to_shared(context)
    on_exit(fn -> await_idle(100) end)
    :ok = Jobs.subscribe(scope)

    player = character!(scope, "Player")
    responder = character!(scope, "Kai")
    model = linked_model!(scope)
    chat = chat!(scope, [player, responder])
    profile!(scope, model)

    {:ok, clip} = Clips.save_clip(scope, chat, "likes tea", {:new, "Kai", :keyword})
    topical = topical!(scope, chat, clip.lore_book_id)

    {:ok, _} = Messages.send_message(scope, chat, responder.id, @sentence)
    {:ok, _} = Messages.send_message(scope, chat, player.id, "Nice.")

    %{scope: scope, chat: chat, clip: clip, topical: topical, player: player, responder: responder}
  end

  test "update mode queues a review whose approval appends the kept clip line", ctx do
    mode!(ctx.scope, "update")
    stub_replies(review: Jason.encode!(%{"001" => @sentence, "002" => "new body", "003" => "x"}))

    job = save_memory!(ctx)
    assert [assist] = assistance_jobs(1)
    assert assist.parent_id == job.id
    assert %Job{status: :review, result: %{"candidates" => [ordinary, topical]}} = await_job(ctx.scope, assist)
    assert %{"type" => "ordinary", "record_id" => clip_id, "text" => @sentence, "message_number" => 1} = ordinary
    assert clip_id == ctx.clip.id
    assert %{"type" => "topical", "text" => "new body"} = topical

    review = Jobs.get_job(ctx.scope, assist.id)

    assert {:ok, _} =
             Memory.approve(ctx.scope, review, %{
               "candidates" => %{"0" => %{"keep" => "true", "text" => @sentence}, "1" => %{"keep" => "false"}}
             })

    assert content(ctx.clip) == "=== Kai ===\n\n- likes tea\n- #{@sentence}\n\n=== END Kai ==="
    assert content(ctx.topical) == "Tea body"
    assert Jobs.get_job(ctx.scope, assist.id).status == :completed
  end

  test "an ordinary suggestion not in the scene is dropped", ctx do
    mode!(ctx.scope, "update")
    stub_replies(review: Jason.encode!(%{"001" => "Kai hates tea.", "002" => "new body"}))

    save_memory!(ctx)
    [assist] = assistance_jobs(1)
    assert %Job{status: :review, result: %{"candidates" => [%{"type" => "topical"}]}} = await_job(ctx.scope, assist)
  end

  test "a reply holding only a suggestion not in the scene fails the job", ctx do
    mode!(ctx.scope, "update")
    stub_replies(review: Jason.encode!(%{"001" => "Kai hates tea."}))

    save_memory!(ctx)
    [assist] = assistance_jobs(1)
    assert %Job{status: :failed} = await_job(ctx.scope, assist)
  end

  test "automatic mode appends ordinary lines without review", ctx do
    mode!(ctx.scope, "automatic")
    stub_replies(review: Jason.encode!(%{"001" => @sentence}))

    save_memory!(ctx)
    [assist] = assistance_jobs(1)
    assert %Job{status: :completed, result: %{"applied" => 1}} = await_job(ctx.scope, assist)
    assert content(ctx.clip) =~ "- #{@sentence}\n\n=== END Kai ==="
  end

  test "suggesting queues topics first; an approved topic queues a topical clip of the scene", ctx do
    mode!(ctx.scope, "update_and_suggest")

    stub_replies(
      review: "{}",
      suggest: Jason.encode!(%{"topics" => [%{"topic" => "Kai's tea", "keywords" => ["tea"]}]})
    )

    save_memory!(ctx)
    assert [suggest, review] = assistance_jobs(2)
    assert suggest.params["pass"] == "suggest" and review.params["pass"] == "review"
    assert suggest.params["clip_ids"] == [ctx.topical.id]

    assert %Job{status: :review, result: %{"topics" => [%{"topic" => "Kai's tea", "keywords" => ["tea"]}]}} =
             suggest = await_job(ctx.scope, suggest)

    assert %Job{status: :completed} = await_job(ctx.scope, review)

    assert {:ok, _} =
             Memory.approve(ctx.scope, suggest, %{
               "topics" => %{
                 "0" => %{"keep" => "true", "topic" => "Kai's tea", "keywords" => "tea"},
                 "new" => %{"topic" => "", "keywords" => ""}
               }
             })

    assert [topical_job] = Repo.all(from(j in Job, where: j.tag == :topical_clip))
    assert topical_job.params["topic"] == "Kai's tea"
    assert topical_job.params["keywords"] == ["tea"]
    assert topical_job.params["snapshot"]["messages"]["message_ids"] == suggest.params["message_ids"]
    assert length(suggest.params["message_ids"]) == 2
  end

  test "regenerating a memory queues no assistance", ctx do
    mode!(ctx.scope, "update")
    stub_replies(review: "{}")

    job = save_memory!(ctx)
    [assist] = assistance_jobs(1)
    %Job{status: :completed} = await_job(ctx.scope, assist)

    record = Repo.get!(Record, job.result["record_id"])
    {:ok, regen} = Memory.regenerate(ctx.scope, ctx.chat, record)
    %Job{status: :review} = regen = await_job(ctx.scope, regen)
    {:ok, _} = Memory.approve(ctx.scope, regen, regen.result)
    await_idle(100)
    assert [_] = assistance_jobs(1)
  end

  test "a topical clip edited before approval refuses the whole approval", ctx do
    mode!(ctx.scope, "update")
    stub_replies(review: Jason.encode!(%{"001" => @sentence, "002" => "new body"}))

    save_memory!(ctx)
    [assist] = assistance_jobs(1)
    review = await_job(ctx.scope, assist)

    {:ok, _} = Lore.update_entry(ctx.scope, Lore.get_entry!(ctx.topical.lore_entry_id), %{content: "Edited"})

    assert Memory.approve(ctx.scope, review, %{}) == {:error, :changed}
    assert content(ctx.clip) == "=== Kai ===\n\n- likes tea\n\n=== END Kai ==="
    assert content(ctx.topical) == "Edited"
    assert Jobs.get_job(ctx.scope, assist.id).status == :review
  end

  test "retrying a review whose clip was edited reviews the clips as they are now, and approves",
       ctx do
    mode!(ctx.scope, "update")
    stub_replies(review: Jason.encode!(%{"001" => @sentence, "002" => "new body"}))

    save_memory!(ctx)
    [assist] = assistance_jobs(1)
    review = await_job(ctx.scope, assist)
    {:ok, _} = Lore.update_entry(ctx.scope, Lore.get_entry!(ctx.topical.lore_entry_id), %{content: "Edited"})
    assert Memory.approve(ctx.scope, review, %{}) == {:error, :changed}

    {:ok, _} = Jobs.retry(ctx.scope, assist.id)
    retried = await_job(ctx.scope, assist)

    assert {:ok, _} = Memory.approve(ctx.scope, retried, %{})
  end

  test "approving refuses a topic key that is not an index or \"new\"", ctx do
    suggest = suggest_review!(ctx, [%{"topic" => "Kai's tea", "keywords" => ["tea"]}])

    assert Memory.approve(ctx.scope, suggest, %{
             "topics" => %{"first" => %{"keep" => "true", "topic" => "Kai's tea", "keywords" => "tea"}}
           }) == {:error, :invalid}

    assert Clips.list_topic_suggestions(ctx.scope, ctx.chat) == []
    assert Jobs.get_job(ctx.scope, suggest.id).status == :review
  end

  describe "pending topic suggestions" do
    test "approving stores the kept topics and queues drafts carrying the suggestion", ctx do
      suggest =
        suggest_review!(ctx, [
          %{"topic" => "Kai's tea", "keywords" => ["tea"]},
          %{"topic" => "Kai's cup", "keywords" => ["cup"]}
        ])

      assert {:ok, _} =
               Memory.approve(ctx.scope, suggest, %{
                 "topics" => %{
                   "0" => %{"keep" => "true", "topic" => "Kai's tea", "keywords" => "tea"},
                   "1" => %{"keep" => "false", "topic" => "Kai's cup", "keywords" => "cup"},
                   "new" => %{"topic" => "Green tea", "keywords" => ""}
                 }
               })

      assert [tea, green] = Clips.list_topic_suggestions(ctx.scope, ctx.chat)
      assert {tea.topic, tea.keywords, green.topic, green.keywords} == {"Kai's tea", ["tea"], "Green tea", []}
      assert tea.lore_book_id == suggest.params["book_id"] and tea.book.id == tea.lore_book_id
      assert tea.record_id == suggest.params["record_id"]
      assert tea.message_ids == suggest.params["message_ids"]
      assert tea.job_id == suggest.id

      jobs = Repo.all(from(j in Job, where: j.tag == :topical_clip, order_by: [asc: j.inserted_at, asc: j.id]))
      assert Enum.map(jobs, & &1.params["suggestion_id"]) == [tea.id, green.id]
      assert Enum.map(jobs, & &1.params["keywords"]) == [["tea"], ["Green tea"]]
      assert Enum.all?(Clips.list_topic_suggestions(ctx.scope, ctx.chat), & &1.drafting?)
    end

    test "a discarded draft leaves the suggestion pending to draft again", ctx do
      [suggestion] = approve_topic!(ctx, "Kai's tea")
      [first] = Repo.all(from(j in Job, where: j.tag == :topical_clip))
      assert %Job{status: :review} = first = await_job(ctx.scope, first)
      assert {:error, :busy} = Clips.draft_topic_suggestion(ctx.scope, ctx.chat, suggestion.id)

      {:ok, _} = Memory.discard(ctx.scope, first)
      assert [%TopicSuggestion{drafting?: false}] = Clips.list_topic_suggestions(ctx.scope, ctx.chat)

      assert {:ok, again} = Clips.draft_topic_suggestion(ctx.scope, ctx.chat, suggestion.id)
      assert again.params["suggestion_id"] == suggestion.id
      assert again.params["snapshot"]["messages"]["message_ids"] == suggestion.message_ids
      assert again.params["source_ids"] == [suggestion.record_id]
      assert {:error, :busy} = Clips.draft_topic_suggestion(ctx.scope, ctx.chat, suggestion.id)
      assert [%TopicSuggestion{drafting?: true}] = Clips.list_topic_suggestions(ctx.scope, ctx.chat)
      await_job(ctx.scope, again)
    end

    test "saving the draft deletes the suggestion", ctx do
      [suggestion] = approve_topic!(ctx, "Kai's tea")
      [draft] = Repo.all(from(j in Job, where: j.tag == :topical_clip))
      assert %Job{status: :review} = draft = await_job(ctx.scope, draft)

      assert {:ok, %Record{kind: :topical_clip}} = Memory.approve(ctx.scope, draft, %{"content" => "Kai loves tea."})
      refute Repo.get(TopicSuggestion, suggestion.id)
      assert Clips.list_topic_suggestions(ctx.scope, ctx.chat) == []
    end

    @tag :capture_log
    test "a re-suggested topic already pending for the book is stored once", ctx do
      [suggestion] = approve_topic!(ctx, "Kai's tea")

      {:ok, _} = Messages.send_message(ctx.scope, ctx.chat, ctx.responder.id, "More tea?")
      {:ok, _} = Messages.send_message(ctx.scope, ctx.chat, ctx.player.id, "Please.")
      {:ok, job} = Memory.create_memory(ctx.scope, ctx.chat, 2, 3, review: false)
      %Job{status: :completed} = await_job(ctx.scope, job)
      [_first, second] = assistance_jobs(2)
      second = await_job(ctx.scope, second)

      assert {:ok, _} =
               Memory.approve(ctx.scope, second, %{
                 "topics" => %{"0" => %{"keep" => "true", "topic" => "KAI'S TEA", "keywords" => "tea"}}
               })

      assert [%TopicSuggestion{id: id, topic: "Kai's tea"}] = Clips.list_topic_suggestions(ctx.scope, ctx.chat)
      assert id == suggestion.id
    end

    test "dismissing deletes; another chat's suggestion is not found", ctx do
      [suggestion] = approve_topic!(ctx, "Kai's tea")
      other = chat!(ctx.scope, [ctx.player, ctx.responder])

      assert Clips.dismiss_topic_suggestion(ctx.scope, other, suggestion.id) == {:error, :not_found}
      assert Clips.draft_topic_suggestion(ctx.scope, other, suggestion.id) == {:error, :not_found}
      assert Clips.dismiss_topic_suggestion(ctx.scope, ctx.chat, suggestion.id) == :ok
      assert Clips.list_topic_suggestions(ctx.scope, ctx.chat) == []
      assert Clips.dismiss_topic_suggestion(ctx.scope, ctx.chat, suggestion.id) == {:error, :not_found}
    end
  end

  ## Helpers

  defp save_memory!(%{scope: scope, chat: chat}) do
    {:ok, job} = Memory.create_memory(scope, chat, 0, 1, review: false)
    %Job{status: :completed} = job = await_job(scope, job)
    job
  end

  # A topic-suggestions review of a new memory whose reply suggests `topics`.
  defp suggest_review!(ctx, topics) do
    mode!(ctx.scope, "suggest")
    stub_replies(suggest: Jason.encode!(%{"topics" => topics}))
    save_memory!(ctx)
    [suggest] = assistance_jobs(1)
    %Job{status: :review} = suggest = await_job(ctx.scope, suggest)
    suggest
  end

  defp approve_topic!(ctx, topic) do
    suggest = suggest_review!(ctx, [%{"topic" => topic, "keywords" => ["tea"]}])

    {:ok, _} =
      Memory.approve(ctx.scope, suggest, %{
        "topics" => %{"0" => %{"keep" => "true", "topic" => topic, "keywords" => "tea"}}
      })

    Clips.list_topic_suggestions(ctx.scope, ctx.chat)
  end

  # The memory job completes inside its save; assistance is queued just after commit.
  defp assistance_jobs(count, tries \\ 100) do
    jobs = Repo.all(from(j in Job, where: j.tag == :memory_assistance, order_by: [asc: j.inserted_at, asc: j.id]))

    if length(jobs) >= count or tries == 0 do
      jobs
    else
      Process.sleep(10)
      assistance_jobs(count, tries - 1)
    end
  end

  defp content(%Record{lore_entry_id: id}), do: Lore.get_entry!(id).content

  defp mode!(scope, mode), do: :ok = Mythweaver.Settings.put(scope, :user, "memory.assistance_mode", mode)

  defp await_job(scope, %Job{id: id}) do
    receive do
      {:job_changed, %{id: ^id, status: status}} when status in [:completed, :failed, :canceled, :review] ->
        Jobs.get_job(scope, id)
    after
      2000 -> flunk("job #{id} did not finish; now #{Jobs.get_job(scope, id).status}")
    end
  end

  defp stub_replies(replies) do
    Req.Test.stub(Mythweaver.AI, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      text =
        cond do
          body =~ "Summarize as JSON." -> @memory
          body =~ "Review the clips." -> replies[:review]
          body =~ "Suggest topics." -> replies[:suggest]
          true -> "Topical body."
        end

      reply(conn, text)
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

  defp topical!(scope, chat, book_id) do
    {:ok, entry} = Lore.create_entry(scope, %{name: "Tea", content: "Tea body", keywords: ["tea"]}, [book_id])

    {:ok, record} =
      %Record{}
      |> Record.changeset(%{
        lore_entry_id: entry.id,
        lore_book_id: book_id,
        chat_id: chat.id,
        kind: :topical_clip,
        written_fingerprint: Scene.sha256(entry.content),
        snapshot: %{"topic" => "Tea"}
      })
      |> Repo.insert()

    record
  end

  defp prompt!(scope, name, purpose, instruction) do
    {:ok, prompt} = Prompts.create_prompt(scope, %{name: name, purpose: purpose})
    {:ok, block} = Prompts.create_block(scope, %{name: "#{name} block", content: instruction})

    {:ok, scene} =
      Prompts.create_block(scope, %{
        name: "#{name} scene",
        role: :user,
        content: "{{ anchors.memory.scene }}\n{{ anchors.memory.clips_text }}"
      })

    {:ok, _} = Prompts.add_block(scope, prompt, block)
    {:ok, _} = Prompts.add_block(scope, prompt, scene)
    prompt
  end

  defp character!(scope, name) do
    {:ok, character} = Characters.create_character(scope, %{name: name})
    character
  end

  defp chat!(scope, [player | _] = characters) do
    {:ok, chat} =
      Chats.create_chat(scope, %{
        name: "Assist chat",
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
    memory = prompt!(scope, "Memory: Test", :memory, "Summarize as JSON.")
    review = prompt!(scope, "Assist: Test", :clip_review, "Review the clips.")
    suggest = prompt!(scope, "Topics: Test", :clip_suggestions, "Suggest topics.")
    topical = prompt!(scope, "Topical: Test", :topical_clip, "Write the topical clip.")

    {:ok, profile} =
      Memory.create_profile(scope, %{
        name: "Default",
        ai_model_id: model.id,
        memory_prompt_id: memory.id,
        clip_review_prompt_id: review.id,
        clip_suggestions_prompt_id: suggest.id,
        topical_clip_prompt_id: topical.id
      })

    {:ok, profile} = Memory.set_default_profile(scope, profile)
    profile
  end
end
