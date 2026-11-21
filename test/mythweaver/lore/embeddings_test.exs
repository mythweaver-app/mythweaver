defmodule Mythweaver.Lore.EmbeddingsTest do
  use Mythweaver.DataCase

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.AI
  alias Mythweaver.Analytics.GenerationStat
  alias Mythweaver.Characters
  alias Mythweaver.Chats
  alias Mythweaver.Lore
  alias Mythweaver.Lore.Embeddings
  alias Mythweaver.Lore.EntryEmbedding
  alias Mythweaver.Lore.MessageEmbedding
  alias Mythweaver.Messages
  alias Mythweaver.Messages.Message
  alias Mythweaver.Permissions
  alias Mythweaver.Settings

  setup do
    %{scope: scope!()}
  end

  describe "refresh/4" do
    test "embeds an entry once, and again only after its content changes", %{scope: scope} do
      stub_embeddings()
      model = embedder!(scope)
      entry = entry!(scope, "Dragons hoard gold")

      assert :ok = refresh(scope, model, [entry])
      assert_received {:embed, ["Dragons hoard gold"]}
      assert :ok = refresh(scope, model, [entry])
      refute_received {:embed, _}

      {:ok, entry} = Lore.update_entry(scope, entry, %{content: "The tavern"})
      assert MapSet.member?(Embeddings.compare(model, [entry], []).unembedded, entry.id)

      assert :ok = refresh(scope, model, [entry])
      assert_received {:embed, ["The tavern"]}
      assert Embeddings.compare(model, [entry], []).unembedded == MapSet.new()
      assert Repo.aggregate(EntryEmbedding, :count) == 1
    end
  end

  describe "embed_messages/3" do
    test "embeds active, finished, non-blank bodies newest first, once each", %{scope: scope} do
      stub_embeddings()
      model = embedder!(scope)
      %{chat: chat, author: author} = scene(scope)
      Messages.subscribe(chat)

      first = say(scope, chat, author, "First")
      second = say(scope, chat, author, "Second")
      {:ok, _generating} = Messages.create_generating_message(chat, author.id)
      blank = say(scope, chat, author, "Soon blank")
      blank |> Message.active_body() |> Ecto.Changeset.change(content: "  ") |> Repo.update!()
      fifth = say(scope, chat, author, "Fifth")

      assert :ok = Embeddings.embed_messages(scope, chat, model)
      assert_received {:embed, ["Fifth", "Second", "First"]}
      refute_received {:embed, _}

      ids = Enum.map([fifth, second, first], &Message.active_body(&1).id)
      assert_received {:bodies_embedded, ^ids}

      assert :ok = Embeddings.embed_messages(scope, chat, model)
      refute_received {:embed, _}

      old_body = Message.active_body(second)
      {:ok, swipe} = Messages.add_body(second, %{content: "Second, again"})
      assert :ok = Embeddings.embed_messages(scope, chat, model)
      assert_received {:embed, ["Second, again"]}
      assert_received {:bodies_embedded, [swipe_id]}
      assert swipe_id == swipe.id
      assert Repo.get_by(MessageEmbedding, message_body_id: old_body.id, ai_model_id: model.id)
    end
  end

  describe "compare/3" do
    test "scores each entry by its best match in the window, without calling the API", %{scope: scope} do
      stub_embeddings()
      model = embedder!(scope)
      %{chat: chat, author: author} = scene(scope)
      dragon = entry!(scope, "Dragons hoard gold")
      tavern = entry!(scope, "The tavern")
      lands = say(scope, chat, author, "A dragon lands")
      rain = say(scope, chat, author, "Rain falls")

      :ok = refresh(scope, model, [dragon, tavern])
      :ok = Embeddings.embed_messages(scope, chat, model)
      unembedded = say(scope, chat, author, "Unembedded words")

      Req.Test.stub(Mythweaver.AI, fn _conn -> flunk("compare/3 must not call the API") end)

      # The max over the window: one strongly related message is enough.
      %{scores: scores} = Embeddings.compare(model, [dragon], body_ids([lands, rain]))
      assert_in_delta scores[dragon.id], 1.0, 0.001

      %{scores: scores, messages_embedded?: true} = Embeddings.compare(model, [tavern], body_ids([lands]))
      assert_in_delta scores[tavern.id], 0.0, 0.001

      assert %{scores: scores, messages_embedded?: false} =
               Embeddings.compare(model, [dragon, tavern], body_ids([unembedded]))

      assert scores == %{}
    end
  end

  describe "recording" do
    test "each call is a background :embedding stat priced like a reply", %{scope: scope} do
      stub_embeddings()
      model = embedder!(scope, %{prompt_cost_per_mtok: 2000})

      :ok = refresh(scope, model, [entry!(scope, "Dragons hoard gold")])

      stat = Repo.get_by!(GenerationStat, tag: :embedding)
      assert stat.origin == :background
      assert stat.status == :completed
      assert stat.prompt_tokens == 7
      assert Decimal.equal?(stat.cost, Decimal.new("0.014"))
      assert stat.cost_estimated

      stub_embeddings(%{"cost" => 0.002})
      :ok = refresh(scope, model, [entry!(scope, "The tavern")])

      [reported] = Repo.all(from(s in GenerationStat, where: s.tag == :embedding and not s.cost_estimated))
      assert Decimal.equal?(reported.cost, Decimal.from_float(0.002))
    end
  end

  describe "spending" do
    setup %{scope: admin} do
      %{user: limited!("quota.spend_per_day", 1), site: embedder!(admin, %{prompt_cost_per_mtok: 2000}, site: true)}
    end

    test "embed_messages/3 stops once the site model's spending limit is reached", %{user: user, site: site} do
      stub_embeddings()
      %{chat: chat, author: author} = scene(user)
      for i <- 1..65, do: say(user, chat, author, "Message #{i}")

      assert Embeddings.embed_messages(user, chat, site) == {:error, :quota_exceeded}
      assert_received {:embed, input}
      assert length(input) == 64
      assert hd(input) == "Message 65"
      refute_received {:embed, _}
      assert Repo.aggregate(MessageEmbedding, :count) == 64

      own = embedder!(user, %{prompt_cost_per_mtok: 2000})
      assert :ok = Embeddings.embed_messages(user, chat, own)
      assert_received {:embed, _}
      assert_received {:embed, _}
    end

    test "refresh/4 stops the same way", %{user: user, site: site} do
      stub_embeddings()
      entries = for i <- 1..65, do: entry!(user, "Entry #{i}")

      assert refresh(user, site, entries) == {:error, :quota_exceeded}
      assert_received {:embed, input}
      assert length(input) == 64
      refute_received {:embed, _}
      assert Repo.aggregate(EntryEmbedding, :count) == 64

      own = embedder!(user, %{prompt_cost_per_mtok: 2000})
      assert :ok = refresh(user, own, entries)
    end
  end

  describe "sync_chat/1" do
    test "makes no call for a chat without Vector entries", %{scope: scope} do
      stub_embeddings()
      model = embedder!(scope)
      :ok = Settings.put(scope, :user, "lore.embedding_model", model.id)
      %{chat: chat, book: book, author: author} = scene(scope)
      entry!(scope, "Dragons", [book.id], %{activation: :keyword, keywords: ["dragon"]})
      say(scope, chat, author, "A dragon lands")

      assert :ok = Embeddings.sync_chat(chat.id)
      refute_received {:embed, _}
    end

    test "embeds the chat's Vector entries and its messages", %{scope: scope} do
      stub_embeddings()
      model = embedder!(scope)
      :ok = Settings.put(scope, :user, "lore.embedding_model", model.id)
      %{chat: chat, book: book, author: author} = scene(scope)
      entry = entry!(scope, "Dragons hoard gold", [book.id])
      message = say(scope, chat, author, "A dragon lands")

      assert :ok = Embeddings.sync_chat(chat.id)
      assert_received {:embed, ["Dragons hoard gold"]}
      assert_received {:embed, ["A dragon lands"]}
      assert Repo.get_by(EntryEmbedding, lore_entry_id: entry.id, ai_model_id: model.id)
      assert Repo.get_by(MessageEmbedding, message_body_id: Message.active_body(message).id, ai_model_id: model.id)

      assert Embeddings.status(scope, Chats.get_chat!(chat.id), body_ids([message])) == %{
               on?: true,
               embedded: MapSet.new(body_ids([message]))
             }
    end

    test "a forced book embeds under the site's model, the rest under the user's", %{scope: admin} do
      stub_embeddings()
      site_model = embedder!(admin, %{}, site: true)
      user_model = embedder!(admin, %{}, site: true)
      :ok = Settings.put(admin, :site, "lore.embedding_model", site_model.id)

      user = scope!(%{role: :user})
      :ok = Settings.put(user, :user, "lore.embedding_model", user_model.id)
      %{chat: chat, book: book, author: author} = scene(user)
      forced = entry!(admin, "Rules of dragons", [book!(admin, %{forced: true}, site: true).id])
      own = entry!(user, "The tavern", [book.id])
      message = say(user, chat, author, "A dragon lands")

      assert :ok = Embeddings.sync_chat(chat.id)

      assert embedded_entries(site_model) == [forced.id]
      assert embedded_entries(user_model) == [own.id]
      body_id = Message.active_body(message).id
      assert Repo.get_by(MessageEmbedding, message_body_id: body_id, ai_model_id: site_model.id)
      assert Repo.get_by(MessageEmbedding, message_body_id: body_id, ai_model_id: user_model.id)

      assert %{on?: true, embedded: embedded} = Embeddings.status(user, Chats.get_chat!(chat.id), [body_id])
      assert embedded == MapSet.new([body_id])
    end
  end

  describe "status/3" do
    test "is off for a chat without Vector entries", %{scope: scope} do
      %{chat: chat, author: author} = scene(scope)
      message = say(scope, chat, author, "Hello")

      assert Embeddings.status(scope, Chats.get_chat!(chat.id), body_ids([message])) == %{
               on?: false,
               embedded: MapSet.new()
             }
    end
  end

  ## Helpers

  # Each text becomes `[1.0, 0.0]` if it mentions a dragon, else `[0.0, 1.0]`. Every request's input
  # is sent to the test process as `{:embed, input}`.
  defp stub_embeddings(usage \\ %{}) do
    test = self()

    Req.Test.stub(Mythweaver.AI, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      input = Jason.decode!(raw)["input"]
      send(test, {:embed, input})

      data =
        input
        |> Enum.with_index()
        |> Enum.map(fn {text, i} ->
          %{"index" => i, "embedding" => if(text =~ ~r/dragon/i, do: [1.0, 0.0], else: [0.0, 1.0])}
        end)

      Req.Test.json(conn, %{"data" => data, "usage" => Map.merge(%{"prompt_tokens" => 7}, usage)})
    end)
  end

  defp refresh(scope, model, entries), do: Embeddings.refresh(scope, model, entries, origin: :background, chat_id: nil)

  defp embedder!(scope, attrs \\ %{}, opts \\ []) do
    {:ok, provider} =
      AI.create_provider(
        scope,
        %{name: "P-#{unique()}", adapter: :openai_compatible, base_url: "http://localhost:8080/v1"},
        opts
      )

    {:ok, model} =
      AI.create_model(
        scope,
        Map.merge(%{name: "Embedder-#{unique()}", api_model_id: "embed-1", completion_mode: :embedding}, attrs),
        opts
      )

    {:ok, _link} = AI.link_model(scope, provider, model)
    AI.get_model!(model.id)
  end

  defp limited!(key, limit) do
    scope = scope!(%{role: :user})
    :ok = Permissions.put_grant!(scope.user, key, limit)
    Scope.for_user(scope.user)
  end

  defp entry!(scope, content, book_ids \\ [], attrs \\ %{}) do
    attrs = Map.merge(%{name: "E-#{unique()}", content: content, activation: :vector, keywords: []}, attrs)
    {:ok, entry} = Lore.create_entry(scope, attrs, book_ids)
    entry
  end

  defp book!(scope, attrs \\ %{}, opts \\ []) do
    {:ok, book} = Lore.create_book(scope, Map.merge(%{name: "book-#{unique()}"}, attrs), opts)
    book
  end

  # Two characters, a chat they both participate in, and a book bound to that chat.
  defp scene(scope) do
    author = character!(scope, "Hero")
    foil = character!(scope, "Foil")

    {:ok, chat} =
      Chats.create_chat(scope, %{
        name: "chat-#{unique()}",
        participants: [%{character_id: author.id}, %{character_id: foil.id}],
        player_character_id: author.id
      })

    chat = Chats.get_chat!(chat.id)
    book = book!(scope)
    {:ok, _} = Lore.bind_book_to_chat(book, chat.id)
    %{chat: chat, book: book, author: author}
  end

  defp character!(scope, name) do
    {:ok, character} = Characters.create_character(scope, %{name: "#{name}-#{unique()}"})
    character
  end

  defp say(scope, chat, character, content) do
    {:ok, message} = Messages.send_message(scope, chat, character.id, content)
    message
  end

  defp body_ids(messages), do: Enum.map(messages, &Message.active_body(&1).id)

  defp embedded_entries(model),
    do: Repo.all(from(e in EntryEmbedding, where: e.ai_model_id == ^model.id, select: e.lore_entry_id))

  defp unique, do: System.unique_integer([:positive])
end
