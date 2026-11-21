defmodule Mythweaver.Messages.CleanupTest do
  use Mythweaver.DataCase

  alias Mythweaver.AI
  alias Mythweaver.Characters
  alias Mythweaver.Chats
  alias Mythweaver.Lore.MessageEmbedding
  alias Mythweaver.Messages
  alias Mythweaver.Messages.Cleanup
  alias Mythweaver.Messages.Message
  alias Mythweaver.Messages.MessageBody
  alias Mythweaver.Settings

  @thresholds %{after_messages: 2, swipe_similarity: 80}

  @a "The knight rode north at dawn, his banner snapping in the cold wind above the silent hills."
  @b "The knight rode south at dawn, his banner snapping in the cold wind above the silent hills."
  @other "A dragon slept beneath the mountain, dreaming of gold."

  defp setup_chat(scope \\ scope!()) do
    {:ok, character} = Characters.create_character(scope, %{name: "Alice"})
    {:ok, other} = Characters.create_character(scope, %{name: "Bob"})

    {:ok, chat} =
      Chats.create_chat(scope, %{
        name: "Chat",
        participants: [%{character_id: character.id}, %{character_id: other.id}]
      })

    %{scope: scope, chat: chat, character: character}
  end

  defp say!(%{scope: scope, chat: chat, character: character}, content) do
    {:ok, message} = Messages.send_message(scope, chat, character.id, content)
    message
  end

  # `n` messages, oldest first.
  defp messages!(ctx, n), do: for(i <- 1..n, do: say!(ctx, "Message #{i}"))

  # Adds a swipe as `add_body/2` does from the UI: its source is the swipe shown at the time.
  defp swipe!(%Message{id: id}, content) do
    {:ok, body} = Messages.add_body(Repo.get!(Message, id), %{content: content})
    body
  end

  defp bodies(%Message{id: id}) do
    Repo.all(from(b in MessageBody, where: b.message_id == ^id, order_by: [asc: b.inserted_at, asc: b.id]))
  end

  defp original(message), do: hd(bodies(message))

  defp snapshot!(body) do
    {:ok, snapshot} = Messages.create_prompt_snapshot(body, %{sections: []})
    snapshot
  end

  defp embedder!(scope) do
    n = System.unique_integer([:positive])

    {:ok, provider} =
      AI.create_provider(scope, %{name: "P-#{n}", adapter: :openai_compatible, base_url: "http://localhost:8080/v1"})

    {:ok, model} =
      AI.create_model(scope, %{name: "Embedder-#{n}", api_model_id: "embed-1", completion_mode: :embedding})

    {:ok, _link} = AI.link_model(scope, provider, model)
    model
  end

  defp embed!(body, model) do
    now = DateTime.utc_now(:second)

    Repo.insert_all(MessageEmbedding, [
      %{
        id: Mythweaver.Schema.generate_id(),
        message_body_id: body.id,
        ai_model_id: model.id,
        content_hash: :crypto.hash(:sha256, "x"),
        embedding: Pgvector.new([1.0, 0.0]),
        inserted_at: now,
        updated_at: now
      }
    ])
  end

  defp embedded?(body), do: Repo.exists?(from(e in MessageEmbedding, where: e.message_body_id == ^body.id))

  describe "run/2 swipe merge" do
    setup do
      ctx = setup_chat()
      old = say!(ctx, @a)
      [_, _, recent] = messages!(ctx, 3)
      Map.merge(ctx, %{old: old, recent: recent})
    end

    test "keeps the newer of two similar swipes and hands it the older one's lineage", %{chat: chat, old: old} do
      a = original(old)
      %{id: b_id} = b = swipe!(old, @b)
      %{id: c_id} = swipe!(old, @other)
      assert b.source_body_id == a.id

      assert %{chats: 1, swipes: 1} = Cleanup.run(chat, @thresholds)

      assert [%{id: ^b_id, source_body_id: nil}, %{id: ^c_id, active: true}] = bodies(old)
    end

    test "never drops the active swipe; its newer near-copy goes instead", %{scope: scope, chat: chat, old: old} do
      %{id: a_id} = a = original(old)
      swipe!(old, @b)
      {:ok, _} = Messages.set_active_body(scope, Repo.get!(MessageBody, a.id))

      assert %{swipes: 1} = Cleanup.run(chat, @thresholds)

      assert [%{id: ^a_id, active: true}] = bodies(old)
    end

    test "re-points swipes derived from a dropped one at its replacement", %{scope: scope, chat: chat, old: old} do
      a = original(old)
      %{id: b_id} = swipe!(old, @b)
      {:ok, _} = Messages.set_active_body(scope, Repo.get!(MessageBody, a.id))
      %{id: d_id} = d = swipe!(old, @other)
      assert d.source_body_id == a.id

      Cleanup.run(chat, @thresholds)

      assert [%{id: ^b_id, source_body_id: nil}, %{id: ^d_id, source_body_id: ^b_id, active: true}] = bodies(old)
    end

    test "keeps swipes under the similarity threshold", %{chat: chat, old: old} do
      swipe!(old, @other)

      assert %{swipes: 0} = Cleanup.run(chat, @thresholds)
      assert length(bodies(old)) == 2
    end

    test "leaves the newest messages alone", %{chat: chat, recent: recent} do
      swipe!(recent, "Message 4, indeed.")

      assert %{swipes: 0} = Cleanup.run(chat, @thresholds)
      assert length(bodies(recent)) == 2
    end
  end

  describe "run/2 metadata" do
    test "deletes old snapshots, reasoning and inactive embeddings; recent ones stay" do
      ctx = setup_chat()
      [old, _, _, recent] = messages!(ctx, 4)
      model = embedder!(ctx.scope)

      old_original = original(old)
      old_active = swipe!(old, @other)
      recent_body = original(recent)

      for body <- [old_original, old_active, recent_body] do
        body |> Ecto.Changeset.change(reasoning: "Thinking") |> Repo.update!()
        embed!(body, model)
      end

      snapshot!(old_active)
      snapshot!(recent_body)

      assert %{snapshots: 1} = Cleanup.run(ctx.chat, @thresholds)

      assert Messages.get_prompt_snapshot(ctx.scope, old_active.id) == nil
      assert Messages.get_prompt_snapshot(ctx.scope, recent_body.id)

      assert Repo.get!(MessageBody, old_active.id).reasoning == nil
      assert Repo.get!(MessageBody, old_original.id).reasoning == nil
      assert Repo.get!(MessageBody, recent_body.id).reasoning == "Thinking"

      refute embedded?(old_original)
      assert embedded?(old_active)
      assert embedded?(recent_body)
    end
  end

  describe "check/1" do
    setup do
      ctx = setup_chat()
      :ok = Settings.put(ctx.scope, :user, "cleanup.after_messages", 2)
      :ok = Settings.put(ctx.scope, :user, "cleanup.every_messages", 2)
      ctx
    end

    test "cleans once the count passes the age and lands on the cadence", ctx do
      [old | _] = messages!(ctx, 3)
      snapshot = snapshot!(original(old))

      Cleanup.check(ctx.chat.id)
      assert Messages.get_prompt_snapshot(ctx.scope, snapshot.message_body_id)

      say!(ctx, "Message 4")
      Cleanup.check(ctx.chat.id)
      assert Messages.get_prompt_snapshot(ctx.scope, snapshot.message_body_id) == nil
    end

    test "does nothing with automatic cleanup off", ctx do
      :ok = Settings.put(ctx.scope, :user, "cleanup.automatic", false)
      [old | _] = messages!(ctx, 4)
      snapshot = snapshot!(original(old))

      Cleanup.check(ctx.chat.id)
      assert Messages.get_prompt_snapshot(ctx.scope, snapshot.message_body_id)
    end
  end

  describe "manual cleanups" do
    # A chat with 3 messages whose oldest has a snapshot; returns that snapshot's body id.
    defp old_snapshot_chat!(scope) do
      ctx = setup_chat(scope)
      [old | _] = messages!(ctx, 3)
      snapshot!(original(old)).message_body_id
    end

    defp snapshot?(body_id), do: Repo.exists?(from(s in Messages.PromptSnapshot, where: s.message_body_id == ^body_id))

    test "clean_up_mine/1 cleans only the user's chats, automatic cleanup on or off" do
      scope = scope!()
      :ok = Settings.put(scope, :user, "cleanup.after_messages", 2)
      :ok = Settings.put(scope, :user, "cleanup.automatic", false)
      mine = [old_snapshot_chat!(scope), old_snapshot_chat!(scope)]
      theirs = old_snapshot_chat!(scope!())

      assert {:ok, %{chats: 2, snapshots: 2}} = Cleanup.clean_up_mine(scope)

      refute Enum.any?(mine, &snapshot?/1)
      assert snapshot?(theirs)
    end

    test "clean_up_all/1 needs the permission" do
      assert Cleanup.clean_up_all(scope!(%{role: :user})) == {:error, :unauthorized}
    end

    test "clean_up_all/1 cleans every chat with the site values" do
      owner = scope!(%{role: :owner})
      :ok = Settings.put(owner, :site, "cleanup.after_messages", 2)
      user = scope!(%{role: :user})
      :ok = Settings.put(user, :user, "cleanup.after_messages", 1000)
      chats = [old_snapshot_chat!(owner), old_snapshot_chat!(user)]

      assert {:ok, %{snapshots: 2}} = Cleanup.clean_up_all(owner)
      refute Enum.any?(chats, &snapshot?/1)
    end
  end

  test "summary/1 counts each kind in singular or plural" do
    assert Cleanup.summary(%{chats: 1, swipes: 1, snapshots: 2}) ==
             "Cleaned up 1 chat: merged 1 swipe and removed 2 prompt snapshots."
  end
end
