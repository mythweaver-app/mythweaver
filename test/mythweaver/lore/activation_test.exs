defmodule Mythweaver.Lore.ActivationTest do
  use Mythweaver.DataCase

  alias Mythweaver.AI.HuggingFace
  alias Mythweaver.Characters
  alias Mythweaver.Chats
  alias Mythweaver.Lore
  alias Mythweaver.Lore.Activation
  alias Mythweaver.Messages
  alias Mythweaver.Prompts.Builder
  alias Mythweaver.Prompts.ContextLimit
  alias Mythweaver.Settings
  alias Mythweaver.Tags
  alias Mythweaver.Variables

  setup do
    %{scope: scope!()}
  end

  describe "keyword activation" do
    test "an entry whose keyword appears in the scan window activates", %{scope: scope} do
      %{chat: chat, book: book, author: author} = scene(scope)
      entry = entry(scope, "Dragons", [book.id], %{keywords: ["dragon"]})
      say(scope, chat, author, "A dragon appears")

      result = resolve(scope, chat)

      assert [decision] = result.activated
      assert decision.entry.id == entry.id
      assert decision.reason == :keyword
      assert decision.pass == 1
      assert decision.slot == "before_character"
      assert result.by_slot["before_character"] == result.activated
    end

    test "an entry with no matching keyword is rejected as :no_keywords", %{scope: scope} do
      %{chat: chat, book: book, author: author} = scene(scope)
      entry = entry(scope, "Dragons", [book.id], %{keywords: ["dragon"]})
      say(scope, chat, author, "A quiet evening")

      result = resolve(scope, chat)

      assert result.activated == []
      assert rejection(result, entry).reason == :no_keywords
    end

    test "scan_depth bounds the window, so an older match no longer counts", %{scope: scope} do
      %{chat: chat, book: book, author: author} = scene(scope)
      entry = entry(scope, "Dragons", [book.id], %{keywords: ["dragon"], scan_depth: 1})

      say(scope, chat, author, "A dragon appears")
      say(scope, chat, author, "Someone orders soup")
      say(scope, chat, author, "The bard tunes up")

      result = resolve(scope, chat)

      assert result.activated == []
      assert rejection(result, entry).reason == :no_keywords
    end

    test "an image's description is scanned like the message's own words", %{scope: scope} do
      %{chat: chat, book: book, author: author} = scene(scope)
      entry = entry(scope, "Dragons", [book.id], %{keywords: ["dragon"]})

      png =
        Base.decode64!(
          "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
        )

      {:ok, image} = Mythweaver.Attachments.store_binary(png)

      image =
        image |> Ecto.Changeset.change(description: "A red dragon on a hill", caption_status: :done) |> Repo.update!()

      {:ok, _} = Messages.send_message(scope, chat, author.id, "Look at this", attachments: [image])

      assert [%{reason: :keyword} = decision] = resolve(scope, chat).activated
      assert decision.entry.id == entry.id
    end

    test "lore.word_boundary reaches keyword matching", %{scope: scope} do
      %{chat: chat, book: book, author: author} = scene(scope)
      dragon = entry(scope, "Dragon", [book.id], %{keywords: ["竜"]})
      say(scope, chat, author, "竜が来た")

      assert activated_ids(resolve(scope, chat)) == [dragon.id]

      :ok = Settings.put(scope, :user, "lore.word_boundary", :unicode)
      assert rejection(resolve(scope, chat), dragon).reason == :no_keywords
    end
  end

  describe "constant activation" do
    test "fires with no keywords and no matching text", %{scope: scope} do
      %{chat: chat, book: book, author: author} = scene(scope)
      entry = entry(scope, "House rules", [book.id], %{activation: :constant, keywords: []})
      say(scope, chat, author, "Nothing of note")

      result = resolve(scope, chat)

      assert [decision] = result.activated
      assert decision.entry.id == entry.id
      assert decision.reason == :constant
    end
  end

  describe "secondary keyword logic" do
    test ":and_all requires every secondary keyword", %{scope: scope} do
      %{chat: chat, book: book, author: author} = scene(scope)

      entry =
        entry(scope, "Red dragons", [book.id], %{
          keywords: ["dragon"],
          secondary_keywords: ["red"],
          secondary_logic: :and_all
        })

      say(scope, chat, author, "a dragon")

      result = resolve(scope, chat)
      assert result.activated == []
      assert rejection(result, entry).reason == :no_keywords
    end

    test ":and_all is satisfied once every secondary keyword is present", %{scope: scope} do
      %{chat: chat, book: book, author: author} = scene(scope)

      entry =
        entry(scope, "Red dragons", [book.id], %{
          keywords: ["dragon"],
          secondary_keywords: ["red"],
          secondary_logic: :and_all
        })

      say(scope, chat, author, "a red dragon")

      assert [decision] = resolve(scope, chat).activated
      assert decision.entry.id == entry.id
      assert decision.reason == :keyword
    end

    test ":not_any blocks activation when a secondary keyword is present", %{scope: scope} do
      %{chat: chat, book: book, author: author} = scene(scope)

      entry =
        entry(scope, "Plain dragons", [book.id], %{
          keywords: ["dragon"],
          secondary_keywords: ["red"],
          secondary_logic: :not_any
        })

      say(scope, chat, author, "a red dragon")

      result = resolve(scope, chat)
      assert result.activated == []
      assert rejection(result, entry).reason == :no_keywords
    end

    test ":not_any allows activation when no secondary keyword is present", %{scope: scope} do
      %{chat: chat, book: book, author: author} = scene(scope)

      entry =
        entry(scope, "Plain dragons", [book.id], %{
          keywords: ["dragon"],
          secondary_keywords: ["red"],
          secondary_logic: :not_any
        })

      say(scope, chat, author, "a green dragon")

      assert [decision] = resolve(scope, chat).activated
      assert decision.entry.id == entry.id
    end
  end

  describe "entries shared across books" do
    test "activate once, credited to the highest-priority book", %{scope: scope} do
      %{chat: chat, book: low, author: author} = scene(scope, %{name: "Low", priority: 1})
      {:ok, high} = Lore.create_book(scope, %{name: "High", priority: 5})
      {:ok, _} = Lore.bind_book_to_chat(high, chat.id)

      entry = entry(scope, "Dragons", [low.id, high.id], %{keywords: ["dragon"]})
      say(scope, chat, author, "A dragon appears")

      assert [decision] = resolve(scope, chat).activated
      assert decision.entry.id == entry.id
      assert decision.book.id == high.id
    end

    test "a disabled membership in a higher-priority book does not hide the entry's enabled one", %{scope: scope} do
      %{chat: chat, book: low, author: author} = scene(scope, %{name: "Low", priority: 1})
      {:ok, high} = Lore.create_book(scope, %{name: "High", priority: 5})
      {:ok, _} = Lore.bind_book_to_chat(high, chat.id)

      entry = entry(scope, "Dragons", [low.id, high.id], %{keywords: ["dragon"]})
      membership = Repo.get_by!(Lore.BookEntry, lore_book_id: high.id, lore_entry_id: entry.id)
      {:ok, _} = Lore.update_membership(membership, %{enabled: false})
      say(scope, chat, author, "A dragon appears")

      assert [decision] = resolve(scope, chat).activated
      assert decision.entry.id == entry.id
      assert decision.book.id == low.id
    end
  end

  describe "pools" do
    test "admit at most max_activations members and reject the rest as :pool_loser", %{scope: scope} do
      %{chat: chat, book: book, author: author} = scene(scope)
      {:ok, pool} = Lore.create_pool(scope, %{name: "Weather", max_activations: 2})

      members =
        for name <- ~w(Blizzard Drizzle Hailstorm) do
          e = entry(scope, name, [book.id], %{keywords: ["dragon"]})
          {:ok, :ok} = Lore.set_entry_pools(scope, e, [pool.id])
          e
        end

      member_ids = MapSet.new(members, & &1.id)
      say(scope, chat, author, "A dragon appears")

      result = resolve(scope, chat, rng: rng([0.1, 0.1]))

      assert length(result.activated) == 2
      assert Enum.all?(result.activated, &MapSet.member?(member_ids, &1.entry.id))

      losers = Enum.filter(result.rejected, &(&1.reason == :pool_loser))
      assert length(losers) == 1
      assert MapSet.member?(member_ids, hd(losers).entry.id)

      activated_ids = MapSet.new(result.activated, & &1.entry.id)
      refute MapSet.member?(activated_ids, hd(losers).entry.id)
    end

    test "the draw is weighted: a heavy member wins the low end of the range", %{scope: scope} do
      %{chat: chat, book: book, author: author} = scene(scope)
      {:ok, pool} = Lore.create_pool(scope, %{name: "Weather", max_activations: 1})
      heavy = pool_member(scope, "Heavy", book, pool, 1000)
      light = pool_member(scope, "Light", book, pool, 1)
      say(scope, chat, author, "A dragon appears")

      # Heavy owns [0, 1000] of the 1001-wide range, Light owns the sliver above it.
      assert [%{entry: %{id: id}}] = resolve(scope, chat, rng: rng([0.5])).activated
      assert id == heavy.id

      assert [%{entry: %{id: id}}] = resolve(scope, chat, rng: rng([0.9999])).activated
      assert id == light.id
    end

    test "a zero-weight member never wins a draw, even with slots to spare", %{scope: scope} do
      %{chat: chat, book: book, author: author} = scene(scope)
      {:ok, pool} = Lore.create_pool(scope, %{name: "Weather", max_activations: 2})
      heavy = pool_member(scope, "Heavy", book, pool, 100)
      zero_a = pool_member(scope, "ZeroA", book, pool, 0)
      zero_b = pool_member(scope, "ZeroB", book, pool, 0)
      say(scope, chat, author, "A dragon appears")

      result = resolve(scope, chat, rng: rng([0.0, 0.0]))

      assert Enum.map(result.activated, & &1.entry.id) == [heavy.id]
      assert rejection(result, zero_a).reason == :pool_loser
      assert rejection(result, zero_b).reason == :pool_loser
    end

    test "a member that lost one pool does not take a slot in a later pool", %{scope: scope} do
      %{chat: chat, book: book, author: author} = scene(scope)
      {:ok, pool_a} = Lore.create_pool(scope, %{name: "A", max_activations: 1})
      {:ok, pool_b} = Lore.create_pool(scope, %{name: "B", max_activations: 1})

      # Orders fix the walk: Y first (so pool A is drawn first and Y wins its low end), then X, then Z.
      y = entry(scope, "Y", [book.id], %{keywords: ["dragon"], order: 300})
      x = entry(scope, "X", [book.id], %{keywords: ["dragon"], order: 200})
      z = entry(scope, "Z", [book.id], %{keywords: ["dragon"], order: 100})
      {:ok, :ok} = Lore.set_entry_pools(scope, y, [pool_a.id])
      {:ok, :ok} = Lore.set_entry_pools(scope, x, [pool_a.id, pool_b.id])
      {:ok, :ok} = Lore.set_entry_pools(scope, z, [pool_b.id])
      say(scope, chat, author, "A dragon appears")

      result = resolve(scope, chat, rng: rng([0.1, 0.1]))

      assert Enum.sort(Enum.map(result.activated, & &1.entry.id)) == Enum.sort([y.id, z.id])
      assert rejection(result, x).reason == :pool_loser
    end

    test "one member of a one-slot pool activates", %{scope: scope} do
      %{chat: chat, book: book, author: author} = scene(scope)
      {:ok, pool} = Lore.create_pool(scope, %{name: "G", max_activations: 1})
      door_member(scope, "A", book, pool, 10)
      door_member(scope, "B", book, pool, 20)
      say(scope, chat, author, "the door")

      assert [_one] = resolve(scope, chat).activated
    end

    test "an override member always wins its pool", %{scope: scope} do
      %{chat: chat, book: book, author: author} = scene(scope)
      {:ok, pool} = Lore.create_pool(scope, %{name: "G", max_activations: 1})
      a = door_member(scope, "A", book, pool, 10, %{}, %{override: true})
      b = door_member(scope, "B", book, pool, 20)
      say(scope, chat, author, "the door")
      # One pass, so B's verdict is the pool's (a later pass finds A's slot taken).
      :ok = Settings.put(scope, :user, "lore.max_recursion_steps", 1)

      for floats <- [[0.0], [0.99]] do
        result = resolve(scope, chat, rng: rng(floats))
        assert activated_ids(result) == [a.id]
        assert rejection(result, b).detail == "pool G: an override member won"
      end

      {:ok, _} = Lore.update_entry(scope, a, %{keywords: ["window"]})
      assert activated_ids(resolve(scope, chat)) == [b.id]
    end

    test "group scoring drops members whose keys match fewer", %{scope: scope} do
      %{chat: chat, book: book, author: author} = scene(scope)
      {:ok, pool} = Lore.create_pool(scope, %{name: "G", max_activations: 1})
      a = door_member(scope, "A", book, pool, 10, %{keywords: ["door", "key"]}, %{scored: true})
      b = door_member(scope, "B", book, pool, 20, %{}, %{scored: true})
      say(scope, chat, author, "a door key")
      :ok = Settings.put(scope, :user, "lore.max_recursion_steps", 1)

      for floats <- [[0.0], [0.99]] do
        result = resolve(scope, chat, rng: rng(floats))
        assert activated_ids(result) == [a.id]
        assert rejection(result, b).detail == "lower keyword score in pool G"
      end
    end

    test "override members leave the rest of a pool's slots to the draw", %{scope: scope} do
      %{chat: chat, book: book, author: author} = scene(scope)
      {:ok, pool} = Lore.create_pool(scope, %{name: "G", max_activations: 3})
      a = door_member(scope, "A", book, pool, 10, %{}, %{override: true})
      b = door_member(scope, "B", book, pool, 20)
      c = door_member(scope, "C", book, pool, 30)
      say(scope, chat, author, "the door")
      :ok = Settings.put(scope, :user, "lore.max_recursion_steps", 1)

      assert Enum.sort(activated_ids(resolve(scope, chat))) == Enum.sort([a.id, b.id, c.id])
    end
  end

  describe "macros in keys" do
    test "a Liquid key matches as the names render", %{scope: scope} do
      %{chat: chat, book: book, author: author, foil: foil} = scene(scope)
      entry = entry(scope, "Named", [book.id], %{keywords: ["{{ anchors.character.name }}"]})
      say(scope, chat, author, "#{foil.name} waves")

      assert activated_ids(resolve(scope, chat, character: foil)) == [entry.id]
      # A preview's responder is the first participant who isn't the player (`author`).
      assert activated_ids(resolve(scope, chat)) == [entry.id]
    end
  end

  describe "empty entries" do
    test "an entry with no content activates and adds no text", %{scope: scope} do
      alias Mythweaver.Prompts

      %{chat: chat, book: book, author: author} = scene(scope)
      blank = entry(scope, "Blank", [book.id], %{keywords: ["door"], content: ""})
      say(scope, chat, author, "the door")

      assert Repo.reload!(blank).content == ""
      assert activated_ids(resolve(scope, chat)) == [blank.id]

      {:ok, prompt} = Prompts.create_prompt(scope, %{name: "P-#{System.unique_integer([:positive])}"})

      {:ok, block} =
        Prompts.create_block(scope, %{
          name: "B-#{System.unique_integer([:positive])}",
          content: "[{{ anchors.lore.before_character }}]"
        })

      {:ok, _} = Prompts.add_block(scope, prompt, block)
      context = Builder.context(scope, Chats.get_chat!(chat.id))

      assert %{segments: [%{content: "[]"}]} = Builder.build(Prompts.get_prompt!(prompt.id), context)
    end
  end

  describe "trigger-only and delay until recursion" do
    test "a trigger-only entry activates and triggers, but takes no slot or budget", %{scope: scope} do
      %{chat: chat, book: book, author: author} = scene(scope)
      a = entry(scope, "A", [book.id], %{keywords: ["door"], content: "keyhole", cooldown: 2, trigger_only: true})
      b = entry(scope, "B", [book.id], %{keywords: ["keyhole"], content: "a brass key"})
      say(scope, chat, author, "the door")

      result = resolve(scope, chat, commit: true)

      assert Enum.map(result.by_slot["before_character"], & &1.entry.id) == [b.id]
      assert [%{depth: nil} = trigger] = result.by_slot["trigger_only"]
      assert trigger.entry.id == a.id
      assert result.budget.used == Enum.find(result.activated, &(&1.entry.id == b.id)).tokens

      say(scope, chat, author, "the door again")
      assert rejection(resolve(scope, chat), a).reason == :cooldown
    end

    test "a delayed entry waits for a recursion pass", %{scope: scope} do
      %{chat: chat, book: book, author: author} = scene(scope)
      delayed = entry(scope, "Delayed", [book.id], %{keywords: ["dragon"], delay_until_recursion: 1})
      say(scope, chat, author, "a dragon")

      result = resolve(scope, chat)
      assert result.activated == []
      assert rejection(result, delayed).reason == :delayed_until_recursion

      entry(scope, "Seed", [book.id], %{activation: :constant, keywords: [], content: "a dragon sleeps"})

      assert %{^delayed => 2} = passes_by_entry(resolve(scope, chat), [delayed])
    end

    test "a pass activating only prevent_recursion entries opens no recursion pass", %{scope: scope} do
      %{chat: chat, book: book, author: author} = scene(scope)
      seed = entry(scope, "Seed", [book.id], %{keywords: ["dragon"], prevent_recursion: true})
      delayed = entry(scope, "Delayed", [book.id], %{keywords: ["dragon"], delay_until_recursion: 1})
      say(scope, chat, author, "a dragon")

      result = resolve(scope, chat)

      assert activated_ids(result) == [seed.id]
      assert rejection(result, delayed).reason == :delayed_until_recursion
    end

    test "the next delay level opens when a pass at the current one activates nothing", %{scope: scope} do
      %{chat: chat, book: book, author: author} = scene(scope)
      entry(scope, "Seed", [book.id], %{activation: :constant, keywords: [], content: "a quiet cave"})
      _never = entry(scope, "Never", [book.id], %{keywords: ["griffin"], delay_until_recursion: 1})
      late = entry(scope, "Late", [book.id], %{keywords: ["dragon"], delay_until_recursion: 2})
      say(scope, chat, author, "a dragon")

      assert %{^late => 3} = passes_by_entry(resolve(scope, chat), [late])
    end
  end

  describe "probability" do
    test "probability: 0 is rejected while probability: 100 activates", %{scope: scope} do
      %{chat: chat, book: book, author: author} = scene(scope)
      never = entry(scope, "Never", [book.id], %{keywords: ["dragon"], probability: 0})
      always = entry(scope, "Always", [book.id], %{keywords: ["dragon"], probability: 100})
      say(scope, chat, author, "A dragon appears")

      result = resolve(scope, chat, rng: rng([0.5, 0.5]))

      assert Enum.map(result.activated, & &1.entry.id) == [always.id]
      assert rejection(result, never).reason == :probability
    end

    test "probability: 0 is rejected even on a roll of exactly 0.0", %{scope: scope} do
      %{chat: chat, book: book, author: author} = scene(scope)
      never = entry(scope, "Never", [book.id], %{keywords: ["dragon"], probability: 0})
      say(scope, chat, author, "A dragon appears")

      result = resolve(scope, chat, rng: rng([0.0]))

      assert result.activated == []
      assert rejection(result, never).reason == :probability
    end

    test "a failed roll holds for the whole resolve, not just its pass", %{scope: scope} do
      %{chat: chat, book: book, author: author} = scene(scope)
      # The constant entry activates in pass 1, so pass 2 runs and re-meets the coin flip.
      _seed = entry(scope, "Seed", [book.id], %{activation: :constant, keywords: [], content: "the hoard glitters"})
      coin = entry(scope, "Coin", [book.id], %{keywords: ["dragon"], probability: 50})
      say(scope, chat, author, "A dragon appears")

      result = resolve(scope, chat, rng: rng([0.99, 0.0]))

      assert result.passes == 2
      refute Enum.any?(result.activated, &(&1.entry.id == coin.id))
      assert rejection(result, coin).reason == :probability
    end
  end

  describe "budget" do
    test "a book budget admits what fits and rejects the overflow", %{scope: scope} do
      # No model, so sizes are estimated: each 8-char entry costs ceil(8 / 3.3) = 3 tokens.
      %{chat: chat, book: book, author: author} = scene(scope, %{token_budget: 5})
      # `order` (not name) fixes the walk order: candidates sort by effective_order descending.
      first = entry(scope, "First", [book.id], %{keywords: ["dragon"], content: "AAAAAAAA", order: 200})
      second = entry(scope, "Second", [book.id], %{keywords: ["dragon"], content: "BBBBBBBB", order: 100})
      say(scope, chat, author, "A dragon appears")

      result = resolve(scope, chat)

      assert Enum.map(result.activated, & &1.entry.id) == [first.id]
      assert rejection(result, second).reason == :budget
      # A book budget rejects, but only the global budget counts as an overflow.
      refute result.budget.overflowed?
      assert result.budget.used == 3
      assert result.budget.estimated?
    end

    test "ignore_budget exempts an entry from the book budget, and its book's share", %{scope: scope} do
      %{chat: chat, book: book, author: author} = scene(scope, %{token_budget: 5})
      first = entry(scope, "First", [book.id], %{keywords: ["dragon"], content: "AAAAAAAA", order: 200})

      second =
        entry(scope, "Second", [book.id], %{
          keywords: ["dragon"],
          content: "BBBBBBBB",
          order: 150,
          ignore_budget: true
        })

      # 1 token: it fits the book's 5 only if `second`'s 3 aren't charged to the book.
      third = entry(scope, "Third", [book.id], %{keywords: ["dragon"], content: "CC", order: 100})

      say(scope, chat, author, "A dragon appears")

      result = resolve(scope, chat)

      assert Enum.sort(Enum.map(result.activated, & &1.entry.id)) ==
               Enum.sort([first.id, second.id, third.id])

      assert result.budget.used == 7
      refute result.budget.overflowed?
    end

    test "card-book entries are admitted without being charged", %{scope: scope} do
      :ok = Settings.put(scope, :user, "lore.token_budget", 100)
      %{chat: chat, book: book} = scene(scope)
      card_book = book(scope, %{kind: :card}, import: true)
      {:ok, _} = Lore.bind_book_to_chat(card_book, chat.id)

      # 330 chars and 165 chars: estimated at 100 and 50 tokens.
      lore = entry(scope, "Lore", [book.id], %{activation: :constant, content: String.duplicate("a", 330), order: 500})
      card = entry(scope, "Card", [card_book.id], %{activation: :constant, content: String.duplicate("b", 165)})

      result = resolve(scope, chat)

      assert Enum.sort(activated_ids(result)) == Enum.sort([lore.id, card.id])
      assert result.budget.used == 100
    end

    test "lore.overflow :stop closes the budget after an overflow; :fill keeps filling", %{scope: scope} do
      :ok = Settings.put(scope, :user, "lore.token_budget", 5)
      %{chat: chat, book: book} = scene(scope)
      first = entry(scope, "First", [book.id], %{activation: :constant, content: "AAAAAAAA", order: 300})
      second = entry(scope, "Second", [book.id], %{activation: :constant, content: "BBBBBBBB", order: 200})
      third = entry(scope, "Third", [book.id], %{activation: :constant, content: "CC", order: 100})

      stopped = resolve(scope, chat)
      assert activated_ids(stopped) == [first.id]
      assert rejection(stopped, second).detail == "global budget 5"
      assert rejection(stopped, third).detail == "budget closed after an overflow"

      :ok = Settings.put(scope, :user, "lore.overflow", :fill)
      filled = resolve(scope, chat)
      assert Enum.sort(activated_ids(filled)) == Enum.sort([first.id, third.id])
    end

    test "the budget is lore.token_budget_percent of the model's context", %{scope: scope} do
      %{chat: chat} = scene(scope)
      model = model!(scope, %{context_window: 1000})

      assert resolve(scope, chat, model: model).budget.limit == 250
    end

    test "lore.token_budget caps the context share", %{scope: scope} do
      :ok = Settings.put(scope, :user, "lore.token_budget", 100)
      %{chat: chat} = scene(scope)
      model = model!(scope, %{context_window: 1000})

      assert resolve(scope, chat, model: model).budget.limit == 100
    end

    test "a passed :context_limit sets the context share", %{scope: scope} do
      %{chat: chat} = scene(scope)
      limit = ContextLimit.for_reply(scope, model!(scope, %{context_window: 800}))

      assert resolve(scope, chat, context_limit: limit).budget.limit == 200
    end

    test "with no model, generation.max_context stands in for the context limit", %{scope: scope} do
      %{chat: chat} = scene(scope)
      :ok = Settings.put(scope, :user, "generation.max_context", 2000)

      assert resolve(scope, chat).budget.limit == 500
    end

    test "the responding model's tokenizer measures entries exactly", %{scope: scope} do
      File.rm_rf!(Application.fetch_env!(:mythweaver, :tokenizer_cache_dir))
      fixture = File.read!("test/support/fixtures/word_level_tokenizer.json")
      Req.Test.stub(HuggingFace, &Plug.Conn.send_resp(&1, 200, fixture))

      %{chat: chat, book: book, author: author} = scene(scope)
      _entry = entry(scope, "Greeting", [book.id], %{keywords: ["dragon"], content: "hello brave world"})
      say(scope, chat, author, "A dragon appears")

      result = resolve(scope, chat, model: model!(scope, %{tokenizer: "test/activation-word-level"}))

      assert [%{tokens: 3}] = result.activated
      assert result.budget.used == 3
      refute result.budget.estimated?
    end

    test "a book budget overflow leaves recursion and the global overflow flag alone", %{scope: scope} do
      %{chat: chat, book: tight, author: author} = scene(scope, %{token_budget: 1})
      roomy = book(scope, %{})
      {:ok, _} = Lore.bind_book_to_chat(roomy, chat.id)

      big = entry(scope, "Big", [tight.id], %{keywords: ["dragon"], content: "AAAAAAAA"})
      _x = entry(scope, "X", [roomy.id], %{keywords: ["dragon"], content: "the hoard glitters"})
      y = entry(scope, "Y", [roomy.id], %{keywords: ["hoard"], content: "gold coins everywhere"})
      say(scope, chat, author, "a dragon")

      result = resolve(scope, chat)

      assert rejection(result, big).reason == :budget
      assert %{pass: 2} = Enum.find(result.activated, &(&1.entry.id == y.id))
      refute result.budget.overflowed?
    end

    test "lore.token_budget caps the global budget", %{scope: scope} do
      :ok = Settings.put(scope, :user, "lore.token_budget", 1)
      %{chat: chat, book: book, author: author} = scene(scope)
      entry = entry(scope, "Dragons", [book.id], %{keywords: ["dragon"], content: "a long dragon tale"})
      say(scope, chat, author, "a dragon")

      result = resolve(scope, chat)

      assert result.budget.limit == 1
      assert rejection(result, entry).reason == :budget
    end

    test "a forced book ignores the user's lore budget; its neighbours do not", %{scope: admin} do
      user = scope!(%{role: :user})
      :ok = Settings.put(user, :user, "lore.token_budget", 1)
      chat = chat(user, [character(user, "Hero"), character(user, "Foil")])

      forced =
        entry(admin, "Rules", [book(admin, %{forced: true}, site: true).id], %{
          activation: :constant,
          content: "a long rule text"
        })

      plain =
        entry(admin, "Plain", [book(admin, %{global: true}, site: true).id], %{
          activation: :constant,
          content: "a long plain text"
        })

      result = resolve(user, chat)

      assert forced.id in Enum.map(result.activated, & &1.entry.id)
      assert rejection(result, plain).reason == :budget
    end
  end

  describe "ordering and outlets" do
    test "effective_order sums the membership order with the book adjustment", %{scope: scope} do
      %{chat: chat, book: book, author: author} = scene(scope, %{order_adjustment: 25})
      entry = entry(scope, "Dragons", [book.id], %{keywords: ["dragon"], order: 100})
      membership = Repo.get_by!(Lore.BookEntry, lore_book_id: book.id, lore_entry_id: entry.id)
      {:ok, _} = Lore.update_membership(membership, %{order: 107})
      say(scope, chat, author, "A dragon appears")

      assert [%{effective_order: 132}] = resolve(scope, chat).activated
    end

    test "activated is grouped by slot and ordered by effective_order ascending", %{scope: scope} do
      %{chat: chat, book: book, author: author} = scene(scope)
      low = entry(scope, "Low", [book.id], %{keywords: ["dragon"], order: 10})
      high = entry(scope, "High", [book.id], %{keywords: ["dragon"], order: 900})

      elsewhere =
        entry(scope, "Elsewhere", [book.id], %{keywords: ["dragon"], outlet: :author_note, order: 500})

      say(scope, chat, author, "A dragon appears")
      result = resolve(scope, chat)

      assert Enum.map(result.by_slot["before_character"], & &1.entry.id) == [low.id, high.id]
      assert Enum.map(result.by_slot["before_author_note"], & &1.entry.id) == [elsewhere.id]
    end

    test "a card book's entries render first in their slot", %{scope: scope} do
      %{chat: chat, book: book, author: author} = scene(scope)
      card_book = book(scope, %{kind: :card}, import: true)
      {:ok, _} = Lore.bind_book_to_chat(card_book, chat.id)

      lore = entry(scope, "Lore", [book.id], %{keywords: ["dragon"], placement: :after, order: 10})
      card = entry(scope, "Card", [card_book.id], %{keywords: ["dragon"], placement: :after, order: 900})

      say(scope, chat, author, "A dragon appears")

      assert Enum.map(resolve(scope, chat).by_slot["after_character"], & &1.entry.id) == [card.id, lore.id]
    end

    test "author notes resolve to before and after slots, and at_depth ignores placement", %{scope: scope} do
      %{chat: chat, book: book, author: author} = scene(scope)

      before_note =
        entry(scope, "Before", [book.id], %{keywords: ["dragon"], outlet: :author_note, placement: :before})

      after_note =
        entry(scope, "After", [book.id], %{keywords: ["dragon"], outlet: :author_note, placement: :after})

      # placement is stored but inert for at_depth: the depth number is the position
      deep = entry(scope, "Deep", [book.id], %{keywords: ["dragon"], outlet: :at_depth, placement: :after})

      say(scope, chat, author, "A dragon appears")
      result = resolve(scope, chat)

      assert Enum.map(result.by_slot["before_author_note"], & &1.entry.id) == [before_note.id]
      assert Enum.map(result.by_slot["after_author_note"], & &1.entry.id) == [after_note.id]
      assert Enum.map(result.by_slot["at_depth"], & &1.entry.id) == [deep.id]
      refute Map.has_key?(result.by_slot, "after_at_depth")
    end

    test "slots are ordered by injection order, not alphabetically", %{scope: scope} do
      %{chat: chat, book: book, author: author} = scene(scope)
      entry(scope, "Note", [book.id], %{keywords: ["dragon"], outlet: :author_note, placement: :after})
      entry(scope, "Char", [book.id], %{keywords: ["dragon"], outlet: :character, placement: :before})

      say(scope, chat, author, "A dragon appears")

      assert Enum.map(resolve(scope, chat).activated, & &1.slot) == ["before_character", "after_author_note"]
    end

    test "custom entries group under by_outlet by key and under by_slot as custom:<key>", %{scope: scope} do
      %{chat: chat, book: book, author: author} = scene(scope)

      a = custom(scope, "A", book, "ending")
      b = custom(scope, "B", book, "ending")
      c = custom(scope, "C", book, "ooc")

      say(scope, chat, author, "A dragon appears")
      result = resolve(scope, chat)

      assert result.by_outlet |> Map.fetch!("ending") |> Enum.map(& &1.entry.id) |> Enum.sort() ==
               Enum.sort([a.id, b.id])

      assert Enum.map(result.by_outlet["ooc"], & &1.entry.id) == [c.id]

      assert result.by_slot |> Map.fetch!("custom:ending") |> Enum.map(& &1.entry.id) |> Enum.sort() ==
               Enum.sort([a.id, b.id])

      refute Map.has_key?(result.by_slot, "before_custom")
    end

    test "outlet/3 concatenates by descending effective order", %{scope: scope} do
      %{chat: chat, book: book, author: author} = scene(scope)
      custom(scope, "Last", book, "ending", %{order: 300, content: "last line"})
      custom(scope, "First", book, "ending", %{order: 100, content: "first line"})
      say(scope, chat, author, "A dragon appears")

      assert outlet(scope, chat, "ending") == "last line\nfirst line"
    end

    test "outlet/3 breaks equal orders by name", %{scope: scope} do
      %{chat: chat, book: book, author: author} = scene(scope)
      custom(scope, "Beta", book, "ending", %{order: 100, content: "beta line"})
      custom(scope, "Alpha", book, "ending", %{order: 100, content: "alpha line"})
      say(scope, chat, author, "A dragon appears")

      assert outlet(scope, chat, "ending") == "alpha line\nbeta line"
    end

    test "outlet/3 honors the full activation flow", %{scope: scope} do
      %{chat: chat, book: book, author: author} = scene(scope)
      absent = custom(scope, "Absent", book, "ending", %{keywords: ["kraken"], content: "kraken lore"})
      never = custom(scope, "Never", book, "ending", %{probability: 0, content: "never"})
      say(scope, chat, author, "A dragon appears")

      assert outlet(scope, chat, "ending", rng: rng([1.0])) == ""
      result = resolve(scope, chat, rng: rng([1.0]))
      assert rejection(result, absent).reason == :no_keywords
      assert rejection(result, never).reason == :probability
    end

    test "outlet/3 returns an empty string for an unknown key", %{scope: scope} do
      %{chat: chat, book: book, author: author} = scene(scope)
      custom(scope, "A", book, "ending")
      say(scope, chat, author, "A dragon appears")

      assert outlet(scope, chat, "nope") == ""
    end

    test "outlets/2 omits keys with no activated entry", %{scope: scope} do
      %{chat: chat, book: book, author: author} = scene(scope)
      custom(scope, "Absent", book, "ending", %{keywords: ["kraken"]})
      custom(scope, "Present", book, "ooc", %{content: "ooc line"})
      say(scope, chat, author, "A dragon appears")

      outlets = Activation.outlets(scope, Chats.get_chat!(chat.id))

      refute Map.has_key?(outlets, "ending")
      assert outlets == %{"ooc" => "ooc line"}
    end
  end

  describe "recursion" do
    test "an entry's content can activate another entry on the next pass", %{scope: scope} do
      %{chat: chat, book: book, author: author} = scene(scope)
      x = entry(scope, "X", [book.id], %{keywords: ["dragon"], content: "the hoard glitters"})
      y = entry(scope, "Y", [book.id], %{keywords: ["hoard"], content: "gold coins everywhere"})
      say(scope, chat, author, "a dragon")

      result = resolve(scope, chat)

      # Unlimited passes (the default) run until one activates nothing: the third.
      assert result.passes == 3
      assert %{^x => 1, ^y => 2} = passes_by_entry(result, [x, y])
    end

    test "prevent_recursion keeps an entry's content out of the recursion buffer", %{scope: scope} do
      %{chat: chat, book: book, author: author} = scene(scope)

      x =
        entry(scope, "X", [book.id], %{
          keywords: ["dragon"],
          content: "the hoard glitters",
          prevent_recursion: true
        })

      y = entry(scope, "Y", [book.id], %{keywords: ["hoard"], content: "gold coins everywhere"})
      say(scope, chat, author, "a dragon")

      result = resolve(scope, chat)

      assert Enum.map(result.activated, & &1.entry.id) == [x.id]
      assert rejection(result, y).reason == :no_keywords
    end

    test "exclude_recursion blocks an entry from being activated by recursion", %{scope: scope} do
      %{chat: chat, book: book, author: author} = scene(scope)
      x = entry(scope, "X", [book.id], %{keywords: ["dragon"], content: "the hoard glitters"})

      y =
        entry(scope, "Y", [book.id], %{
          keywords: ["hoard"],
          content: "gold coins everywhere",
          exclude_recursion: true
        })

      say(scope, chat, author, "a dragon")

      result = resolve(scope, chat)

      assert Enum.map(result.activated, & &1.entry.id) == [x.id]
      assert rejection(result, y).reason == :recursion_excluded
    end

    test "recursion stops at lore.max_recursion_steps, leaving a third link unactivated", %{scope: scope} do
      :ok = Settings.put(scope, :user, "lore.max_recursion_steps", 2)
      %{chat: chat, book: book, author: author} = scene(scope)
      x = entry(scope, "X", [book.id], %{keywords: ["dragon"], content: "the hoard glitters"})
      y = entry(scope, "Y", [book.id], %{keywords: ["hoard"], content: "a crown rests on top"})
      z = entry(scope, "Z", [book.id], %{keywords: ["crown"], content: "wrought of pale gold"})
      say(scope, chat, author, "a dragon")

      result = resolve(scope, chat)

      assert result.passes == 2
      assert Enum.sort(Enum.map(result.activated, & &1.entry.id)) == Enum.sort([x.id, y.id])
      assert rejection(result, z).reason == :no_keywords
    end

    test "a user's lore.max_recursion_steps override applies to their chats", %{scope: scope} do
      :ok = Settings.put(scope, :user, "lore.max_recursion_steps", 1)
      %{chat: chat, book: book, author: author} = scene(scope)
      x = entry(scope, "X", [book.id], %{keywords: ["dragon"], content: "the hoard glitters"})
      y = entry(scope, "Y", [book.id], %{keywords: ["hoard"], content: "a crown rests on top"})
      say(scope, chat, author, "a dragon")

      result = resolve(scope, chat)

      assert result.passes == 1
      assert Enum.map(result.activated, & &1.entry.id) == [x.id]
      assert rejection(result, y).reason == :no_keywords
    end

    test "a book with recursive: false shields its entries from recursive activation", %{scope: scope} do
      %{chat: chat, book: book, author: author} = scene(scope, %{recursive: false})
      x = entry(scope, "X", [book.id], %{keywords: ["dragon"], content: "the hoard glitters"})
      y = entry(scope, "Y", [book.id], %{keywords: ["hoard"], content: "gold coins everywhere"})
      say(scope, chat, author, "a dragon")

      result = resolve(scope, chat)

      assert Enum.map(result.activated, & &1.entry.id) == [x.id]
      assert rejection(result, y).reason == :recursion_excluded
    end
  end

  describe "gates" do
    test "a disabled membership is rejected as :disabled_book", %{scope: scope} do
      %{chat: chat, book: book, author: author} = scene(scope)
      entry = entry(scope, "Dragons", [book.id], %{keywords: ["dragon"]})
      membership = Repo.get_by!(Lore.BookEntry, lore_book_id: book.id, lore_entry_id: entry.id)
      {:ok, _} = Lore.update_membership(membership, %{enabled: false})
      say(scope, chat, author, "A dragon appears")

      result = resolve(scope, chat)
      assert result.activated == []
      assert rejection(result, entry).reason == :disabled_book
    end

    test "character_filter_mode: :include needs a listed character in the chat", %{scope: scope} do
      %{chat: chat, book: book, author: author, foil: foil} = scene(scope)
      wanted = entry(scope, "Wanted", [book.id], %{keywords: ["dragon"], character_filter_mode: :include})
      {:ok, :ok} = Lore.set_entry_filter_characters(scope, wanted, [foil.id])

      absent = entry(scope, "Absent", [book.id], %{keywords: ["dragon"], character_filter_mode: :include})
      {:ok, :ok} = Lore.set_entry_filter_characters(scope, absent, [character(scope, "Stranger").id])

      say(scope, chat, author, "A dragon appears")
      result = resolve(scope, chat)

      assert Enum.map(result.activated, & &1.entry.id) == [wanted.id]
      assert rejection(result, absent).reason == :character_filtered
    end

    test "character_filter_mode: :exclude rejects when a listed character is in the chat", %{scope: scope} do
      %{chat: chat, book: book, author: author, foil: foil} = scene(scope)
      barred = entry(scope, "Barred", [book.id], %{keywords: ["dragon"], character_filter_mode: :exclude})
      {:ok, :ok} = Lore.set_entry_filter_characters(scope, barred, [foil.id])

      say(scope, chat, author, "A dragon appears")
      result = resolve(scope, chat)

      assert result.activated == []
      assert rejection(result, barred).reason == :character_filtered
    end

    test "an entry's filter tags count participants carrying them, parents included", %{scope: scope} do
      %{chat: chat, book: book, author: author, foil: foil} = scene(scope)
      {:ok, _} = Tags.create_tag(scope, %{text: "character:samus", parent_texts: ["series:metroid"]})
      wanted = entry(scope, "Wanted", [book.id], %{keywords: ["dragon"], character_filter_mode: :include})
      {:ok, :ok} = Lore.set_entry_filter_tags(scope, wanted, ["series:metroid"])
      say(scope, chat, author, "A dragon appears")

      assert rejection(resolve(scope, chat), wanted).reason == :character_filtered

      :ok = Tags.set_item_tags(scope, foil, :mine, ["character:samus"])
      assert Enum.map(resolve(scope, chat).activated, & &1.entry.id) == [wanted.id]
    end

    test "a book's tag_filter_mode: :exclude rejects its entries as :book_tag_filtered", %{scope: scope} do
      %{chat: chat, book: book, author: author, foil: foil} = scene(scope, %{tag_filter_mode: :exclude})
      {:ok, :ok} = Lore.set_book_filter_tags(scope, book, ["species:dragon"])
      entry = entry(scope, "Dragons", [book.id], %{keywords: ["dragon"]})
      :ok = Tags.set_item_tags(scope, foil, :mine, ["species:dragon"])
      say(scope, chat, author, "A dragon appears")

      result = resolve(scope, chat)
      assert result.activated == []
      assert rejection(result, entry).reason == :book_tag_filtered
    end

    test "delay holds an entry back until the chat is long enough", %{scope: scope} do
      %{chat: chat, book: book, author: author} = scene(scope)
      entry = entry(scope, "Dragons", [book.id], %{keywords: ["dragon"], delay: 2})

      say(scope, chat, author, "A dragon appears")
      result = resolve(scope, chat)
      assert result.activated == []
      assert rejection(result, entry).reason == :delayed

      say(scope, chat, author, "And a dragon again")
      assert [%{reason: :keyword}] = resolve(scope, chat).activated
    end

    test "a message hidden from the AI is not part of the scan window", %{scope: scope} do
      %{chat: chat, book: book, author: author} = scene(scope)
      entry = entry(scope, "Dragons", [book.id], %{keywords: ["dragon"]})
      message = say(scope, chat, author, "A dragon appears")
      {:ok, _} = Messages.update_message(message, %{visible_to_ai: false})

      result = resolve(scope, chat)
      assert result.activated == []
      assert rejection(result, entry).reason == :no_keywords
    end
  end

  describe "sticky and cooldown" do
    test "a committed sticky entry stays active over a non-matching turn", %{scope: scope} do
      %{chat: chat, book: book, author: author} = scene(scope)
      entry = entry(scope, "Dragons", [book.id], %{keywords: ["dragon"], sticky: 2})

      say(scope, chat, author, "A dragon appears")
      assert [%{reason: :keyword}] = resolve(scope, chat, commit: true).activated

      say(scope, chat, author, "Someone orders soup")

      assert [decision] = resolve(scope, chat).activated
      assert decision.entry.id == entry.id
      assert decision.reason == :sticky
    end

    test "an entry with no sticky does not become sticky merely by being committed", %{scope: scope} do
      %{chat: chat, book: book, author: author} = scene(scope)
      # `scan_depth: 1` so the follow-up message pushes the keyword out of the window.
      entry = entry(scope, "Dragons", [book.id], %{keywords: ["dragon"], scan_depth: 1})

      say(scope, chat, author, "A dragon appears")
      assert [%{reason: :keyword}] = resolve(scope, chat, commit: true).activated

      # Same message count, no new turn: the entry re-matches, so it must still say `:keyword`.
      assert [%{reason: :keyword}] = resolve(scope, chat).activated

      say(scope, chat, author, "Someone orders soup")

      result = resolve(scope, chat)
      assert result.activated == []
      assert rejection(result, entry).reason == :no_keywords
    end

    test "cooldown runs from the end of the sticky window, blocking a re-match after it lapses", %{scope: scope} do
      %{chat: chat, book: book, author: author} = scene(scope)
      entry = entry(scope, "Dragons", [book.id], %{keywords: ["dragon"], sticky: 1, cooldown: 5})

      say(scope, chat, author, "A dragon appears")
      assert [%{reason: :keyword}] = resolve(scope, chat, commit: true).activated

      # Turn 2 is still inside the sticky window even though nothing matches.
      say(scope, chat, author, "Someone orders soup")
      assert [%{reason: :sticky}] = resolve(scope, chat).activated

      # Turn 3 is past it, and cooldown blocks the re-match.
      say(scope, chat, author, "A dragon returns")
      result = resolve(scope, chat)

      assert result.activated == []
      assert rejection(result, entry).reason == :cooldown
    end

    test "a sticky window is not re-armed by the turns it holds the entry through", %{scope: scope} do
      %{chat: chat, book: book, author: author} = scene(scope)
      entry = entry(scope, "Dragons", [book.id], %{keywords: ["dragon"], sticky: 2, cooldown: 0, scan_depth: 1})

      say(scope, chat, author, "A dragon appears")
      assert [%{reason: :keyword}] = resolve(scope, chat, commit: true).activated

      # `sticky: 2` holds the entry through the next two turns, each resolved with `commit: true`.
      for content <- ["Someone orders soup", "The bard tunes up"] do
        say(scope, chat, author, content)
        assert [%{reason: :sticky}] = resolve(scope, chat, commit: true).activated
      end

      for content <- ["Rain on the roof", "The fire burns low"] do
        say(scope, chat, author, content)
        result = resolve(scope, chat, commit: true)
        assert result.activated == []
        assert rejection(result, entry).reason == :no_keywords
      end
    end

    test "an expired sticky window leaves the entry cooling down", %{scope: scope} do
      %{chat: chat, book: book, author: author} = scene(scope)
      entry = entry(scope, "Dragons", [book.id], %{keywords: ["dragon"], cooldown: 5})

      say(scope, chat, author, "A dragon appears")
      assert [%{reason: :keyword}] = resolve(scope, chat, commit: true).activated

      say(scope, chat, author, "Someone orders soup")
      say(scope, chat, author, "A dragon returns")

      result = resolve(scope, chat)

      assert result.activated == []
      assert rejection(result, entry).reason == :cooldown
    end

    test "commit: false leaves no turn state behind", %{scope: scope} do
      %{chat: chat, book: book, author: author} = scene(scope)
      _entry = entry(scope, "Dragons", [book.id], %{keywords: ["dragon"], sticky: 2})
      say(scope, chat, author, "A dragon appears")

      assert [_] = resolve(scope, chat).activated
      assert Lore.entry_states(Chats.get_chat!(chat.id)) == %{}
    end
  end

  describe "ownership" do
    test "only the chat owner's books and the site's apply, even when another user's book is bound to a site character",
         %{scope: admin} do
      owner = scope!(%{role: :user})
      other = scope!(%{role: :user})
      hero = character(admin, "Hero", site: true)
      foil = character(admin, "Foil", site: true)
      chat = chat(owner, [hero, foil])

      site = entry(admin, "Site", [book(admin, %{global: true}, site: true).id], %{activation: :constant})
      own = entry(owner, "Own", [book(owner, %{global: true}).id], %{activation: :constant})
      _global = entry(other, "Theirs", [book(other, %{global: true}).id], %{activation: :constant})

      bound = book(other, %{})
      {:ok, _} = Lore.bind_book_to_character(bound, foil.id)
      _bound = entry(other, "Bound", [bound.id], %{activation: :constant})

      assert MapSet.new(Lore.books_for_chat(chat), & &1.user_id) == MapSet.new([owner.user.id, nil])

      assert resolve(owner, chat).activated |> Enum.map(& &1.entry.id) |> Enum.sort() == Enum.sort([site.id, own.id])
    end
  end

  describe "group cards" do
    # A constant entry in a book bound to Bob: his "card", as an imported card's book would be.
    setup %{scope: scope} do
      player = character(scope, "Player")
      alice = character(scope, "Alice")
      bob = character(scope, "Bob")
      chat = chat(scope, [player, alice, bob])
      card = book(scope, %{})
      {:ok, _} = Lore.bind_book_to_character(card, bob.id)
      entry = entry(scope, "Bob's personality", [card.id], %{activation: :constant})

      %{chat: chat, alice: alice, bob: bob, entry: entry}
    end

    defp active?(scope, chat, responder, entry),
      do: Enum.any?(resolve(scope, chat, character: responder).activated, &(&1.entry.id == entry.id))

    test "swap applies only the responder's bound books", %{scope: scope} = ctx do
      refute active?(scope, ctx.chat, ctx.alice, ctx.entry)
      assert active?(scope, ctx.chat, ctx.bob, ctx.entry)
      # With no responder (the lore preview), every participant's book applies.
      assert Enum.any?(resolve(scope, ctx.chat).activated, &(&1.entry.id == ctx.entry.id))
    end

    test "join applies unmuted participants' books; join all applies muted ones too", %{scope: scope} = ctx do
      {:ok, _} = Chats.update_chat(scope, ctx.chat, %{group_cards: :join})
      assert active?(scope, ctx.chat, ctx.alice, ctx.entry)

      bob = Enum.find(Chats.get_chat!(ctx.chat.id).participants, &(&1.character_id == ctx.bob.id))
      {:ok, _} = Chats.update_participant(scope, bob, %{muted: true})
      refute active?(scope, ctx.chat, ctx.alice, ctx.entry)

      {:ok, _} = Chats.update_chat(scope, ctx.chat, %{group_cards: :join_all})
      assert active?(scope, ctx.chat, ctx.alice, ctx.entry)
    end

    test "joined cards give the responder's own books first claim on the budget", %{scope: scope} = ctx do
      {:ok, _} = Chats.update_chat(scope, ctx.chat, %{group_cards: :join_all})
      # Alice's card outranks Bob's, and the budget fits only one of the two equal-sized entries.
      loud = book(scope, %{priority: 5})
      {:ok, _} = Lore.bind_book_to_character(loud, ctx.alice.id)
      theirs = entry(scope, "Alice's personality", [loud.id], %{activation: :constant, content: ctx.entry.content})
      size = resolve(scope, ctx.chat).budget.used |> div(2)
      :ok = Settings.put(scope, :user, "lore.token_budget", size)

      result = resolve(scope, ctx.chat, character: ctx.bob)
      assert Enum.map(result.activated, & &1.entry.id) == [ctx.entry.id]
      assert rejection(result, theirs).reason == :budget

      # Alice's turn: her book is now the responder's, so it claims the budget first.
      result = resolve(scope, ctx.chat, character: ctx.alice)
      assert Enum.map(result.activated, & &1.entry.id) == [theirs.id]

      # With no responder (the lore preview) book priority alone decides.
      preview = resolve(scope, ctx.chat)
      assert Enum.map(preview.activated, & &1.entry.id) == [theirs.id]
    end
  end

  describe "vector activation" do
    setup %{scope: scope} do
      model = embedder!(scope)
      :ok = Settings.put(scope, :user, "lore.embedding_model", model.id)
      %{model: model}
    end

    test "a similar message activates a vector entry with no keywords", %{scope: scope, model: model} do
      %{chat: chat, book: book, author: author} = scene(scope)
      entry = vector(scope, "Dragons hoard gold", book)
      say(scope, chat, author, "A dragon lands")
      embed!(scope, chat, model, [entry])

      assert [%{reason: :vector} = decision] = resolve(scope, chat).activated
      assert decision.entry.id == entry.id
    end

    test "a dissimilar one is rejected below the threshold", %{scope: scope, model: model} do
      %{chat: chat, book: book, author: author} = scene(scope)
      entry = vector(scope, "The tavern", book)
      say(scope, chat, author, "A dragon lands")
      embed!(scope, chat, model, [entry])

      rejection = rejection(resolve(scope, chat), entry)
      assert rejection.reason == :vector_unmatched
      assert rejection.detail =~ ~r/^similarity 0% below 25%/
    end

    test "a vector entry's keywords still activate it", %{scope: scope, model: model} do
      %{chat: chat, book: book, author: author} = scene(scope)
      entry = vector(scope, "The tavern", book, %{keywords: ["lands"]})
      say(scope, chat, author, "A dragon lands")
      embed!(scope, chat, model, [entry])

      assert [%{reason: :keyword}] = resolve(scope, chat).activated
    end

    test "whatever isn't embedded yet has no vector match", %{scope: scope, model: model} do
      %{chat: chat, book: book, author: author} = scene(scope)
      dragon = vector(scope, "Dragons hoard gold", book)
      keyed = vector(scope, "Dragon lairs", book, %{keywords: ["dragon"]})
      say(scope, chat, author, "A dragon lands")
      flunk_on_embed()

      result = resolve(scope, chat)
      assert rejection(result, dragon).detail == "entry not embedded yet"
      assert [%{reason: :keyword} = decision] = result.activated
      assert decision.entry.id == keyed.id

      stub_embeddings()
      :ok = Lore.Embeddings.refresh(scope, model, [dragon], origin: :background, chat_id: nil)
      flunk_on_embed()
      assert rejection(resolve(scope, chat), dragon).detail == "recent messages not embedded yet"
    end

    test "a blank entry is never counted as unembedded", %{scope: scope, model: model} do
      %{book: book} = scene(scope)
      blank = vector(scope, "", book)
      dragon = vector(scope, "Dragons hoard gold", book)

      comparison = Lore.Embeddings.compare(model, [blank, dragon], [])

      assert comparison.unembedded == MapSet.new([dragon.id])
    end

    test "without an embedding model a vector entry is keyword-only", %{scope: scope} do
      :ok = Settings.reset(scope, :user, "lore.embedding_model")
      %{chat: chat, book: book, author: author} = scene(scope)
      entry = vector(scope, "Dragons hoard gold", book)
      say(scope, chat, author, "A dragon lands")

      assert rejection(resolve(scope, chat), entry).detail ==
               "no embedding model set (Settings › Lore › Vector matching)"
    end

    test "lore.vector_max_entries caps similarity activations", %{scope: scope, model: model} do
      :ok = Settings.put(scope, :user, "lore.vector_max_entries", 1)
      %{chat: chat, book: book, author: author} = scene(scope)
      first = vector(scope, "Dragons hoard gold", book)
      second = vector(scope, "Dragon eggs", book)
      say(scope, chat, author, "A dragon lands")
      embed!(scope, chat, model, [first, second])

      result = resolve(scope, chat)
      assert [%{reason: :vector} = decision] = result.activated
      [cut] = Enum.reject([first, second], &(&1.id == decision.entry.id))
      assert rejection(result, cut).detail =~ ~r/outside the top 1$/
    end

    test "a forced book matches with the site's model, other books with the user's", %{scope: admin} do
      site_model = embedder!(admin, site: true)
      user_model = embedder!(admin, site: true)
      :ok = Settings.put(admin, :site, "lore.embedding_model", site_model.id)

      user = scope!(%{role: :user})
      :ok = Settings.put(user, :user, "lore.embedding_model", user_model.id)
      %{chat: chat, book: book, author: author} = scene(user)
      forced = vector(admin, "Dragon law", book(admin, %{forced: true}, site: true))
      plain = vector(user, "Dragons hoard gold", book)
      say(user, chat, author, "A dragon lands")
      embed!(user, chat, site_model, [forced])
      embed!(user, chat, user_model, [plain])

      result = resolve(user, chat)

      assert Enum.sort(for %{reason: :vector, entry: e} <- result.activated, do: e.id) ==
               Enum.sort([forced.id, plain.id])

      :ok = Settings.reset(admin, :site, "lore.embedding_model")
      result = resolve(user, chat)
      assert rejection(result, forced).detail == "no site embedding model set"
      assert [%{reason: :vector, entry: %{id: id}}] = result.activated
      assert id == plain.id
    end
  end

  describe "subscriber toggles" do
    test "an entry a subscriber toggled off leaves their chat, not the owner's" do
      owner = scope!(%{role: :user})
      subscriber = scope!(%{role: :user})
      %{chat: owner_chat, book: book} = scene(owner)
      entry = entry(owner, "Shared", [book.id], %{activation: :constant})

      {:ok, share} =
        Mythweaver.Sharing.invite(owner, book, "@" <> subscriber.user.handle, role: :subscriber)

      {:ok, _share} = Mythweaver.Sharing.accept(subscriber, share.id)
      sub_chat = chat(subscriber, [character(subscriber, "Hero"), character(subscriber, "Foil")])
      {:ok, _} = Lore.bind_book_to_chat(book, sub_chat.id)

      activated = fn scope, chat -> Enum.map(resolve(scope, chat).activated, & &1.entry.id) end
      assert entry.id in activated.(subscriber, sub_chat)

      assert {:ok, _} = Mythweaver.Sharing.set_toggle(subscriber, Repo.reload!(entry), false)

      refute entry.id in activated.(subscriber, sub_chat)
      assert entry.id in activated.(owner, owner_chat)
    end
  end

  describe "activation rules" do
    test "a book activates only where a rule matches", %{scope: scope} do
      %{chat: chat, book: book, author: author} = scene(scope)
      entry = entry(scope, "House rules", [book.id], %{activation: :constant})
      ghost = character(scope, "Ghost")

      rules!(scope, book, [[%{"kind" => "character_present", "character_id" => author.id}]])
      assert entry.id in activated_ids(resolve(scope, chat))

      rules!(scope, book, [[%{"kind" => "character_present", "character_id" => ghost.id}]])
      result = resolve(scope, chat)
      assert %{reason: :book_rule_filtered, detail: "no activation rule matched"} = rejection(result, entry)
    end

    test "rules never make an unbound book live", %{scope: scope} do
      %{chat: chat} = scene(scope)
      unbound = book(scope, %{})
      entry = entry(scope, "Stray", [unbound.id], %{activation: :constant})

      rules!(scope, unbound, [[%{"kind" => "chat", "chat_id" => chat.id}]])
      result = resolve(scope, chat)

      refute entry.id in activated_ids(result)
      refute Enum.any?(result.rejected, &(&1.entry.id == entry.id))
    end

    test "any rule matching is enough", %{scope: scope} do
      %{chat: chat, book: book, foil: foil} = scene(scope)
      entry = entry(scope, "House rules", [book.id], %{activation: :constant})
      ghost = character(scope, "Ghost")

      rules!(scope, book, [
        [%{"kind" => "responder", "character_id" => foil.id}],
        [%{"kind" => "character_present", "character_id" => ghost.id}]
      ])

      assert entry.id in activated_ids(resolve(scope, chat, character: foil))
      assert rejection(resolve(scope, chat), entry).reason == :book_rule_filtered
    end

    test "Not inverts a condition", %{scope: scope} do
      %{chat: chat, book: book, foil: foil} = scene(scope)
      entry = entry(scope, "House rules", [book.id], %{activation: :constant})
      ghost = character(scope, "Ghost")

      rules!(scope, book, [[%{"kind" => "character_present", "character_id" => foil.id, "negate" => "true"}]])
      assert rejection(resolve(scope, chat), entry).reason == :book_rule_filtered

      rules!(scope, book, [[%{"kind" => "character_present", "character_id" => ghost.id, "negate" => "true"}]])
      assert entry.id in activated_ids(resolve(scope, chat))
    end

    test "tag conditions read parent-expanded tags", %{scope: scope} do
      %{chat: chat, book: book, foil: foil} = scene(scope)
      entry = entry(scope, "House rules", [book.id], %{activation: :constant})
      {:ok, _} = Tags.create_tag(scope, %{text: "character:samus", parent_texts: ["series:metroid"]})
      :ok = Tags.set_item_tags(scope, foil, :mine, ["character:samus"])

      rules!(scope, book, [[%{"kind" => "character_tag", "tags" => ["", "series:metroid"]}]])
      assert entry.id in activated_ids(resolve(scope, chat))

      rules!(scope, book, [[%{"kind" => "chat_tag", "tags" => ["series:metroid"]}]])
      assert rejection(resolve(scope, chat), entry).reason == :book_rule_filtered

      :ok = Tags.set_item_tags(scope, Chats.get_chat!(chat.id), :mine, ["series:metroid"])
      assert entry.id in activated_ids(resolve(scope, chat))
    end

    test "a template condition reads the chat's stored variables", %{scope: scope} do
      %{chat: chat, book: book} = scene(scope)
      entry = entry(scope, "House rules", [book.id], %{activation: :constant})

      :ok = Variables.put_value(scope, chat.id, "mood", "tense")
      rules!(scope, book, [[%{"kind" => "template", "template" => ~s(vars.mood == "tense")}]])
      assert entry.id in activated_ids(resolve(scope, chat))

      :ok = Variables.put_value(scope, chat.id, "mood", "calm")
      assert rejection(resolve(scope, chat), entry).reason == :book_rule_filtered
    end

    test "a deleted target matches nothing", %{scope: scope} do
      %{chat: chat, book: book} = scene(scope)
      entry = entry(scope, "House rules", [book.id], %{activation: :constant})
      ghost = character(scope, "Ghost")

      rules!(scope, book, [[%{"kind" => "character_present", "character_id" => ghost.id}]])
      assert {:ok, _} = Characters.delete_character(scope, ghost)

      assert [%{character_id: nil}] = Repo.all(Lore.BookRuleCondition)
      assert rejection(resolve(scope, chat), entry).reason == :book_rule_filtered
    end

    test "a rule-failing book does not shadow the entry's other live book", %{scope: scope} do
      %{chat: chat, book: book} = scene(scope, %{priority: 5})
      other = book(scope, %{priority: 1})
      {:ok, _} = Lore.bind_book_to_chat(other, chat.id)
      entry = entry(scope, "House rules", [book.id, other.id], %{activation: :constant})
      ghost = character(scope, "Ghost")

      rules!(scope, book, [[%{"kind" => "character_present", "character_id" => ghost.id}]])
      assert entry.id in activated_ids(resolve(scope, chat))
    end

    test "an entry whose only book fails its rules is rejected", %{scope: scope} do
      %{chat: chat, book: book} = scene(scope, %{priority: 5})
      entry = entry(scope, "House rules", [book.id], %{activation: :constant})
      ghost = character(scope, "Ghost")

      rules!(scope, book, [[%{"kind" => "character_present", "character_id" => ghost.id}]])
      assert rejection(resolve(scope, chat), entry).reason == :book_rule_filtered
    end

    test "a disabled rule does not gate", %{scope: scope} do
      %{chat: chat, book: book} = scene(scope)
      entry = entry(scope, "House rules", [book.id], %{activation: :constant})
      ghost = character(scope, "Ghost")

      params = %{
        "rules" => %{
          "0" => %{
            "enabled" => "false",
            "conditions" => %{"0" => %{"kind" => "character_present", "character_id" => ghost.id}}
          }
        }
      }

      assert {:ok, _} = Lore.set_book_rules(scope, Repo.reload!(book), params)
      assert entry.id in activated_ids(resolve(scope, chat))
    end

    test "a template condition that fails to render rejects with its error", %{scope: scope} do
      %{chat: chat, book: book} = scene(scope)
      entry = entry(scope, "House rules", [book.id], %{activation: :constant})

      rules!(scope, book, [[%{"kind" => "template", "template" => ~s(vars.mood == "tense")}]])
      # Saving validates the syntax, so a broken template only reaches render through the row.
      {1, _} = Repo.update_all(Lore.BookRuleCondition, set: [template: "vars.mood |> no_such_filter"])

      assert %{reason: :book_rule_filtered, detail: "no activation rule matched; template error: " <> _} =
               rejection(resolve(scope, chat), entry)
    end
  end

  ## Helpers

  # `rules` is a list of rules, each a list of string-keyed condition params.
  defp rules!(scope, book, rules) do
    indexed = &(&1 |> Enum.with_index() |> Map.new(fn {value, i} -> {to_string(i), value} end))

    params = %{
      "rules" =>
        rules
        |> Enum.map(&%{"enabled" => "true", "conditions" => indexed.(&1)})
        |> indexed.()
    }

    assert {:ok, _} = Lore.set_book_rules(scope, Repo.reload!(book), params)
  end

  defp activated_ids(result), do: Enum.map(result.activated, & &1.entry.id)

  # Two characters, a chat they both participate in, and a book bound to that chat.
  defp scene(scope, book_attrs \\ %{}) do
    author = character(scope, "Hero")
    foil = character(scope, "Foil")
    chat = chat(scope, [author, foil])
    book = book(scope, book_attrs)
    {:ok, _} = Lore.bind_book_to_chat(book, chat.id)

    %{chat: chat, book: book, author: author, foil: foil}
  end

  defp resolve(scope, chat, opts \\ []), do: Activation.resolve(scope, Chats.get_chat!(chat.id), opts)

  defp outlet(scope, chat, key, opts \\ []), do: Activation.outlet(scope, Chats.get_chat!(chat.id), key, opts)

  # A keyword entry on a custom outlet; `keywords: ["dragon"]` so `say(scope, chat, _, "A dragon appears")`
  # activates it by default.
  defp custom(scope, name, book, key, attrs \\ %{}) do
    defaults = %{keywords: ["dragon"], outlet: :custom, custom_outlet: key}
    entry(scope, name, [book.id], Map.merge(defaults, attrs))
  end

  defp say(scope, chat, character, content) do
    {:ok, message} = Messages.send_message(scope, chat, character.id, content)
    message
  end

  defp rejection(result, entry) do
    case Enum.find(result.rejected, &(&1.entry.id == entry.id)) do
      nil -> flunk("expected a rejection for #{entry.name}, got #{inspect(result.rejected)}")
      rejection -> rejection
    end
  end

  defp passes_by_entry(result, entries) do
    by_id = Map.new(result.activated, &{&1.entry.id, &1.pass})
    Map.new(entries, &{&1, Map.get(by_id, &1.id)})
  end

  # A deterministic stand-in for `:rand.uniform/0`: yields `floats` in order, then 0.5 forever.
  defp rng(floats) do
    agent =
      start_supervised!(
        Supervisor.child_spec({Agent, fn -> floats end},
          id: {:rng, System.unique_integer([:positive])}
        )
      )

    fn ->
      Agent.get_and_update(agent, fn
        [head | rest] -> {head, rest}
        [] -> {0.5, []}
      end)
    end
  end

  defp book(scope, attrs, opts \\ []) do
    defaults = %{name: "book-#{System.unique_integer([:positive])}"}
    {:ok, book} = Lore.create_book(scope, Map.merge(defaults, attrs), opts)
    book
  end

  # `order` is a membership field, so it is split off and applied to every book's membership.
  defp entry(scope, name, book_ids, attrs) do
    {order, attrs} = Map.pop(attrs, :order)
    defaults = %{name: name, content: "#{name} content"}
    membership = if order, do: %{order: order}, else: %{}
    {:ok, entry} = Lore.create_entry(scope, Map.merge(defaults, attrs), book_ids, membership)
    entry
  end

  defp vector(scope, content, book, attrs \\ %{}) do
    entry(
      scope,
      "V-#{System.unique_integer([:positive])}",
      [book.id],
      Map.merge(%{content: content, activation: :vector, keywords: []}, attrs)
    )
  end

  # Each text becomes `[1.0, 0.0]` if it mentions a dragon, else `[0.0, 1.0]`.
  defp stub_embeddings do
    Req.Test.stub(Mythweaver.AI, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)

      data =
        raw
        |> Jason.decode!()
        |> Map.fetch!("input")
        |> Enum.with_index()
        |> Enum.map(fn {text, i} ->
          %{"index" => i, "embedding" => if(text =~ ~r/dragon/i, do: [1.0, 0.0], else: [0.0, 1.0])}
        end)

      Req.Test.json(conn, %{"data" => data, "usage" => %{"prompt_tokens" => 7}})
    end)
  end

  # A resolve compares stored vectors only.
  defp flunk_on_embed, do: Req.Test.stub(Mythweaver.AI, fn _conn -> flunk("a resolve must not call the API") end)

  # Stores vectors for `entries` and every message under `model`, then forbids any further call.
  defp embed!(scope, chat, model, entries) do
    stub_embeddings()
    :ok = Lore.Embeddings.refresh(scope, model, entries, origin: :background, chat_id: nil)
    :ok = Lore.Embeddings.embed_messages(scope, chat, model)
    flunk_on_embed()
  end

  defp embedder!(scope, opts \\ []) do
    {:ok, provider} =
      Mythweaver.AI.create_provider(
        scope,
        %{
          name: "P-#{System.unique_integer([:positive])}",
          adapter: :openai_compatible,
          base_url: "http://localhost:8080/v1"
        },
        opts
      )

    model = model!(scope, %{api_model_id: "embed-1", completion_mode: :embedding}, opts)
    {:ok, _link} = Mythweaver.AI.link_model(scope, provider, model)
    model
  end

  defp model!(scope, attrs, opts \\ []) do
    defaults = %{name: "model-#{System.unique_integer([:positive])}", api_model_id: "test-model"}
    {:ok, model} = Mythweaver.AI.create_model(scope, Map.merge(defaults, attrs), opts)
    model
  end

  # A pool member keyed "door" at `order`; `flags` go on its membership (`override`, `scored`).
  defp door_member(scope, name, book, pool, order, attrs \\ %{}, flags \\ %{}) do
    entry = entry(scope, name, [book.id], Map.merge(%{keywords: ["door"], order: order}, attrs))
    {:ok, :ok} = Lore.set_entry_pools(scope, entry, [pool.id])
    {:ok, :ok} = Lore.set_pool_memberships(scope, entry, %{pool.id => flags})
    entry
  end

  defp pool_member(scope, name, book, pool, weight) do
    # One shared order, so the walk (and so each member's slice of the draw range) follows name.
    entry = entry(scope, name, [book.id], %{keywords: ["dragon"], order: 100})
    {:ok, :ok} = Lore.set_entry_pools(scope, entry, [pool.id])

    {:ok, :ok} = Lore.set_pool_memberships(scope, entry, %{pool.id => %{weight: weight}})

    entry
  end

  defp character(scope, name, opts \\ []) do
    {:ok, character} =
      Characters.create_character(scope, %{name: "#{name}-#{System.unique_integer([:positive])}"}, opts)

    character
  end

  defp chat(scope, [player | _] = characters) do
    {:ok, chat} =
      Chats.create_chat(scope, %{
        name: "chat-#{System.unique_integer([:positive])}",
        participants: Enum.map(characters, &%{character_id: &1.id}),
        player_character_id: player.id
      })

    Chats.get_chat!(chat.id)
  end
end
