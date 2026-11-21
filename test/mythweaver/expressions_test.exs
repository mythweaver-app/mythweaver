defmodule Mythweaver.ExpressionsTest do
  use Mythweaver.DataCase

  alias Mythweaver.AI
  alias Mythweaver.Analytics.GenerationStat
  alias Mythweaver.Attachments
  alias Mythweaver.Characters
  alias Mythweaver.Chats
  alias Mythweaver.Expressions
  alias Mythweaver.Expressions.Sprite
  alias Mythweaver.Jobs
  alias Mythweaver.Messages
  alias Mythweaver.Messages.Message
  alias Mythweaver.Messages.MessageBody
  alias Mythweaver.Settings

  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
       )

  setup do
    %{scope: scope!()}
  end

  defp character!(scope, name) do
    {:ok, character} = Characters.create_character(scope, %{name: name})
    character
  end

  defp sprite!(scope, character, label, outfit_id \\ nil) do
    {:ok, attachment} = Attachments.store_binary(@png, filename: "#{label}.png")
    {:ok, %{sprites: [sprite]}} = Expressions.add_sprites(scope, character, outfit_id, [{label, attachment}])
    sprite
  end

  defp chat!(scope, characters) do
    {:ok, chat} =
      Chats.create_chat(scope, %{name: "Scene", participants: Enum.map(characters, &%{character_id: &1.id})})

    chat
  end

  defp active_body(scope, message), do: Message.active_body(Messages.get_message!(scope, message.id))

  describe "label_from_filename/1" do
    test "reads SillyTavern's sprite names" do
      assert Expressions.label_from_filename("Joy.png") == {:ok, "joy"}
      assert Expressions.label_from_filename("joy-2.webp") == {:ok, "joy"}
      assert Expressions.label_from_filename("armor/joy.alt.png") == {:ok, "joy"}
      assert Expressions.label_from_filename("bad name!.png") == :error
    end
  end

  describe "add_sprites/4" do
    test "an unknown label becomes a custom label; a known one does not", %{scope: scope} do
      aqua = character!(scope, "Aqua")
      sprite!(scope, aqua, "joy")
      sprite!(scope, aqua, "smug")

      assert Characters.get_character!(aqua.id).expression_labels == ["smug"]
    end

    test "refuses an outfit of another character", %{scope: scope} do
      aqua = character!(scope, "Aqua")
      kazuma = character!(scope, "Kazuma")
      {:ok, outfit} = Expressions.create_outfit(scope, kazuma, "Armor")
      {:ok, attachment} = Attachments.store_binary(@png, filename: "joy.png")

      assert Expressions.add_sprites(scope, aqua, outfit.id, [{"joy", attachment}]) == {:error, :invalid_outfit}
    end
  end

  describe "import_pack/4" do
    defp zip!(entries) do
      {:ok, {_name, bin}} = :zip.create(~c"p.zip", entries, [:memory])
      path = Path.join(System.tmp_dir!(), "pack-#{System.unique_integer([:positive])}.zip")
      File.write!(path, bin)
      on_exit(fn -> File.rm(path) end)
      path
    end

    test "root files go to the target set, one folder deep to that outfit", %{scope: scope} do
      aqua = character!(scope, "Aqua")

      path =
        zip!([
          {~c"joy.png", @png},
          {~c"armor/anger-1.png", @png},
          {~c"__MACOSX/x", "x"},
          {~c"notes.txt", "x"}
        ])

      assert {:ok, %{added: 2, outfits: ["armor"], skipped: ["notes.txt"]}} =
               Expressions.import_pack(scope, aqua, path, nil)

      [armor] = Expressions.list_outfits(scope, aqua)
      sprites = Expressions.list_sprites(scope, aqua)

      assert Enum.sort(for(s <- sprites, do: {s.label, s.outfit_id})) == [{"anger", armor.id}, {"joy", nil}]
    end

    test "a file that is not a ZIP is refused", %{scope: scope} do
      aqua = character!(scope, "Aqua")
      path = Path.join(System.tmp_dir!(), "not-a-zip-#{System.unique_integer([:positive])}.zip")
      File.write!(path, "hello")
      on_exit(fn -> File.rm(path) end)

      assert Expressions.import_pack(scope, aqua, path, nil) == {:error, :invalid_zip}
    end
  end

  test "deleting a character deletes its sprite files", %{scope: scope} do
    aqua = character!(scope, "Aqua")
    sprite = sprite!(scope, aqua, "joy")

    {:ok, _} = Characters.delete_character(scope, aqua)

    refute Repo.get(Sprite, sprite.id)
    refute Repo.get(Attachments.Attachment, sprite.attachment_id)
  end

  describe "classification" do
    setup %{scope: scope} = context do
      Req.Test.set_req_test_to_shared(context)

      {:ok, provider} =
        AI.create_provider(scope, %{name: "Local", adapter: :openai_compatible, base_url: "http://x/v1"}, site: true)

      {:ok, model} = AI.create_model(scope, %{name: "Rater", api_model_id: "rater"}, site: true)
      {:ok, _} = AI.link_model(scope, provider, model)

      aqua = character!(scope, "Aqua")
      kazuma = character!(scope, "Kazuma")
      chat = chat!(scope, [aqua, kazuma])
      :ok = Jobs.subscribe(scope)

      %{model: model, aqua: aqua, kazuma: kazuma, chat: chat}
    end

    defp stub_reply(text) do
      test = self()

      Req.Test.stub(Mythweaver.AI, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test, {:classify_body, Jason.decode!(raw)})
        frame = Jason.encode!(%{"choices" => [%{"index" => 0, "delta" => %{"content" => text}}]})
        conn = Plug.Conn.send_chunked(conn, 200)

        Enum.reduce(["data: #{frame}\n\n", "data: [DONE]\n\n"], conn, fn chunk, conn ->
          {:ok, conn} = Plug.Conn.chunk(conn, chunk)
          conn
        end)
      end)
    end

    defp turn_on(scope, model), do: :ok = Settings.put(scope, :site, "expressions.classifier_model", model.id)

    test "a sent message gets the sprite of its strongest emotion", %{
      scope: scope,
      model: model,
      aqua: aqua,
      chat: chat
    } do
      turn_on(scope, model)
      sprite = sprite!(scope, aqua, "joy")
      stub_reply(~s({"scores": {"joy": 90, "Anger ": 5}}))

      {:ok, message} = Messages.send_message(scope, chat, aqua.id, "Yay, a party!")

      assert_receive {:classify_body, body}, 2_000

      assert [%{"role" => "system", "content" => instruction}, %{"role" => "user", "content" => "Yay, a party!"}] =
               body["messages"]

      assert instruction =~ ~s({"scores":)
      assert instruction =~ "admiration, amusement"
      assert_receive {:job_changed, %{tag: :expression, status: :completed}}, 2_000

      assert %MessageBody{expression: "joy", expression_source: :classified, expression_sprite_id: sprite_id} =
               body = active_body(scope, message)

      assert sprite_id == sprite.id
      assert body.expression_scores["anger"] == 5
    end

    test "nothing is queued without a classifier model", %{scope: scope, aqua: aqua, chat: chat} do
      sprite!(scope, aqua, "joy")
      {:ok, _message} = Messages.send_message(scope, chat, aqua.id, "Yay")

      assert Jobs.list_jobs(scope, tags: [:expression]) == []
    end

    test "a hand-set expression survives a later classification", %{scope: scope, model: model, aqua: aqua, chat: chat} do
      sprite!(scope, aqua, "joy")
      sad = sprite!(scope, aqua, "sadness")
      {:ok, message} = Messages.send_message(scope, chat, aqua.id, "Yay")
      message = Messages.get_message!(scope, message.id)

      assert {:ok, _} = Expressions.set_manual(scope, message, "sadness")

      assert %{expression: "sadness", expression_source: :manual, expression_sprite_id: sad_id} =
               active_body(scope, message)

      assert sad_id == sad.id
      assert Expressions.set_manual(scope, message, "fear") == {:error, :no_sprite}

      turn_on(scope, model)
      stub_reply(~s({"scores": {"joy": 90}}))
      :ok = Expressions.classify_later(scope, chat.id, message.id, active_body(scope, message).id)

      assert_receive {:job_changed, %{tag: :expression, status: :completed, id: job_id}}, 2_000
      assert %{result: %{"skipped" => "manual"}} = Repo.get!(Jobs.Job, job_id)
      assert %{expression: "sadness"} = active_body(scope, message)

      # Classify again overrides it.
      :ok = Expressions.reclassify(scope, Messages.get_message!(scope, message.id))
      assert_receive {:job_changed, %{tag: :expression, status: :completed}}, 2_000
      assert %{expression: "joy", expression_source: :classified} = active_body(scope, message)
    end

    test "reattributing a message clears its expression", %{scope: scope, aqua: aqua, kazuma: kazuma, chat: chat} do
      sprite!(scope, aqua, "joy")
      {:ok, message} = Messages.send_message(scope, chat, aqua.id, "Yay")
      {:ok, message} = Expressions.set_manual(scope, Messages.get_message!(scope, message.id), "joy")

      chat = Chats.get_chat!(chat.id)
      {:ok, _} = Messages.reattribute_message(scope, chat, message, {:character, kazuma.id})

      assert %{expression: nil, expression_source: nil, expression_sprite_id: nil} = active_body(scope, message)
    end

    test "an unparseable reply is repaired once, then the job fails", %{
      scope: scope,
      model: model,
      aqua: aqua,
      chat: chat
    } do
      turn_on(scope, model)
      sprite!(scope, aqua, "joy")
      stub_reply("I feel happy")

      {:ok, message} = Messages.send_message(scope, chat, aqua.id, "Yay")

      assert_receive {:classify_body, _}, 2_000
      assert_receive {:classify_body, _}, 2_000
      assert_receive {:job_changed, %{tag: :expression, status: :failed, id: job_id}}, 2_000
      assert Repo.get!(Jobs.Job, job_id).error =~ "unparseable"
      assert %{expression: nil} = active_body(scope, message)
    end
  end

  describe "classification by a classifier model" do
    setup %{scope: scope} = context do
      Req.Test.set_req_test_to_shared(context)

      {:ok, provider} =
        AI.create_provider(scope, %{name: "Local", adapter: :openai_compatible, base_url: "http://x/v1"}, site: true)

      {:ok, model} =
        AI.create_model(scope, %{name: "GoEmotions", api_model_id: "go-emotions", completion_mode: :classifier},
          site: true
        )

      {:ok, _} = AI.link_model(scope, provider, model)
      :ok = Settings.put(scope, :site, "expressions.classifier_model", model.id)

      aqua = character!(scope, "Aqua")
      %{aqua: aqua, chat: chat!(scope, [aqua, character!(scope, "Kazuma")])}
    end

    # Answers `/embeddings` with `logits` (GoEmotions order), sending each request body to the test.
    defp stub_logits(logits) do
      test = self()

      Req.Test.stub(Mythweaver.AI, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test, {:classify_body, conn.request_path, Jason.decode!(raw)})
        Req.Test.json(conn, %{"data" => [%{"index" => 0, "embedding" => logits}], "usage" => %{"prompt_tokens" => 5}})
      end)
    end

    # Every label far below zero but `hot`, each at its logit.
    defp logits(hot) do
      for label <- Expressions.base_labels(), do: Map.get(hot, label, -9.0)
    end

    test "the sprite follows the classifier's sigmoid scores, with no job", %{scope: scope, aqua: aqua, chat: chat} do
      sprite = sprite!(scope, aqua, "joy")
      sprite!(scope, aqua, "excitement")
      stub_logits(logits(%{"excitement" => 1.0, "joy" => 2.0}))

      {:ok, message} = Messages.send_message(scope, chat, aqua.id, "Yay, a party!")

      assert_received {:classify_body, "/v1/embeddings", %{"input" => ["Yay, a party!"], "embd_normalize" => -1}}

      assert %MessageBody{
               expression: "joy",
               expression_source: :classified,
               expression_scores: scores,
               expression_sprite_id: id
             } =
               active_body(scope, message)

      assert id == sprite.id
      assert {scores["joy"], scores["excitement"], scores["sadness"]} == {88, 73, 0}
      assert Jobs.list_jobs(scope, tags: [:expression]) == []

      assert [%GenerationStat{tag: :expression, job_id: nil, status: :completed, prompt_tokens: 5}] =
               Repo.all(GenerationStat)
    end

    test "a long message is classified by its end", %{scope: scope, aqua: aqua, chat: chat} do
      sprite!(scope, aqua, "joy")
      stub_logits(logits(%{"joy" => 2.0}))
      text = String.duplicate("a", 5_000) <> "THE END"

      {:ok, _message} = Messages.send_message(scope, chat, aqua.id, text)

      assert_received {:classify_body, _path, %{"input" => [sent]}}
      assert String.length(sent) == 4_000
      assert String.ends_with?(sent, "THE END")
    end

    @tag :capture_log
    test "a model answering fewer than 28 outputs sets nothing", %{scope: scope, aqua: aqua, chat: chat} do
      sprite!(scope, aqua, "joy")
      stub_logits([2.0, 1.0])

      {:ok, message} = Messages.send_message(scope, chat, aqua.id, "Yay")

      assert %{expression: nil, expression_scores: nil} = active_body(scope, message)
    end
  end
end
