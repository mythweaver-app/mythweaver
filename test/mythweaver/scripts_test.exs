defmodule Mythweaver.ScriptsTest do
  # Not `async: true`: each script runs in a supervised task that reaches the DB through the shared
  # sandbox (`test/support/data_case.ex:42`).
  use Mythweaver.DataCase

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Characters
  alias Mythweaver.Chats
  alias Mythweaver.Injections
  alias Mythweaver.Lore
  alias Mythweaver.Messages
  alias Mythweaver.Messages.Message
  alias Mythweaver.Prompts
  alias Mythweaver.Prompts.Builder
  alias Mythweaver.Scripts
  alias Mythweaver.Scripts.API
  alias Mythweaver.Scripts.CallbackStore
  alias Mythweaver.Scripts.Inline
  alias Mythweaver.Scripts.Sandbox
  alias Mythweaver.Variables

  # Failed script runs log a warning by design.
  @moduletag :capture_log

  setup do
    scope = scope!()
    player = character!(scope, "Player")
    bot = character!(scope, "Bot")
    %{scope: scope, chat: chat!(scope, [player, bot]), player: player, bot: bot}
  end

  defp script!(scope, attrs, opts \\ []) do
    attrs =
      attrs
      |> Map.new()
      |> Map.put_new(:name, "Script-#{System.unique_integer([:positive])}")
      |> Map.put_new(:trigger, :user_message)

    {:ok, script} = Scripts.create_script(scope, attrs, opts)
    script
  end

  defp character!(scope, name) do
    {:ok, character} = Characters.create_character(scope, %{name: "#{name}-#{System.unique_integer([:positive])}"})
    character
  end

  defp chat!(scope, [player | _] = characters) do
    {:ok, chat} =
      Chats.create_chat(scope, %{
        name: "chat-#{System.unique_integer([:positive])}",
        participants: Enum.map(characters, &%{character_id: &1.id}),
        player_character_id: player.id
      })

    Chats.get_chat!(chat.id)
  end

  # Runs `body` as the only new script, then deletes it so a later run in the same test skips it.
  defp run(scope, chat, body, event \\ %{"text" => "x"}) do
    script = script!(scope, body: body)
    result = Scripts.run(scope, :user_message, chat, event)
    script = Scripts.get_script!(scope, script.id)
    {:ok, _} = Scripts.delete_script(scope, script)
    {result, script}
  end

  describe "validation" do
    test "rejects a body that does not parse", %{scope: scope} do
      assert {:error, changeset} = Scripts.create_script(scope, %{name: "Bad", body: "local x ="})
      assert errors_on(changeset).body != []
    end

    test "rejects a body over 64 KB", %{scope: scope} do
      body = "-- " <> String.duplicate("x", 64 * 1024)
      assert {:error, changeset} = Scripts.create_script(scope, %{name: "Big", body: body})
      assert errors_on(changeset).body == ["should be at most 65536 byte(s)"]
    end

    test "rejects dependencies on another trigger, on itself, and in a cycle", %{scope: scope} do
      a = script!(scope, trigger: :user_message)
      other = script!(scope, trigger: :ai_generation)

      assert {:error, changeset} =
               Scripts.create_script(scope, %{name: "B", trigger: :user_message, dependency_ids: [other.id]})

      assert ["must share this script's trigger: " <> _] = errors_on(changeset).dependency_ids

      assert {:error, changeset} =
               Scripts.update_script(scope, Scripts.get_script!(scope, a.id), %{dependency_ids: [a.id]})

      assert "cannot include the script itself" in errors_on(changeset).dependency_ids

      b = script!(scope, trigger: :user_message, dependency_ids: [a.id])

      assert {:error, changeset} =
               Scripts.update_script(scope, Scripts.get_script!(scope, a.id), %{dependency_ids: [b.id]})

      assert "would create a dependency cycle" in errors_on(changeset).dependency_ids
    end

    test "refuses a trigger change while other scripts depend on the script", %{scope: scope} do
      a = script!(scope, trigger: :user_message)
      b = script!(scope, trigger: :user_message, dependency_ids: [a.id])

      assert {:error, changeset} =
               Scripts.update_script(scope, Scripts.get_script!(scope, a.id), %{trigger: :ai_generation})

      assert errors_on(changeset).trigger == ["other scripts depend on this one: #{b.name}"]
    end

    test "a blank dependency entry clears every dependency", %{scope: scope} do
      a = script!(scope, trigger: :user_message)
      b = script!(scope, trigger: :user_message, dependency_ids: [a.id])

      assert {:ok, b} = Scripts.update_script(scope, Scripts.get_script!(scope, b.id), %{dependency_ids: [""]})
      assert Scripts.get_script!(scope, b.id).dependency_ids == []
    end

    test "a command script's header must parse; other triggers ignore it", %{scope: scope} do
      body = "---@param a foo\nreturn 1"
      assert {:error, changeset} = Scripts.create_script(scope, %{name: "Cmd", trigger: :command, body: body})
      assert [~s(line 1: unknown type "foo") <> _] = errors_on(changeset).body
      assert {:ok, _} = Scripts.create_script(scope, %{name: "Msg", trigger: :user_message, body: body})
    end
  end

  describe "run/3" do
    test "runs higher priority first, after dependencies, chaining text", %{scope: scope, chat: chat} do
      a = script!(scope, name: "A", priority: 0, body: ~s(return event.text .. "a"))
      script!(scope, name: "B", priority: 5, body: ~s(return event.text .. "b"))
      script!(scope, name: "C", priority: 9, body: ~s(return event.text .. "c"), dependency_ids: [a.id])

      assert %{text: "xbac", errors: []} = Scripts.run(scope, :user_message, chat, %{"text" => "x"})
    end

    test "nil keeps the text; a non-string is an error that keeps the text", %{scope: scope, chat: chat} do
      assert {%{text: "x", errors: []}, %{last_success_at: %DateTime{}}} = run(scope, chat, "return nil")

      assert {%{text: "x", errors: [error]}, script} = run(scope, chat, "return 5")
      assert error =~ "must return a string or nil"
      assert script.last_error == "Script must return a string or nil."
      assert script.last_success_at == nil
    end

    test "printed lines join the errors before failures, and are not failures", %{scope: scope, chat: chat} do
      assert {%{text: "x", errors: [line]}, script} = run(scope, chat, ~S|print("seen", 2)|)
      assert line =~ ~s(printed: seen\t2)
      assert script.last_error == nil
      assert %DateTime{} = script.last_success_at

      assert {%{errors: [printed, failed]}, _} = run(scope, chat, ~S|print("first") error("boom")|)
      assert printed =~ "printed: first"
      assert failed =~ "failed: " and failed =~ "boom"
    end

    test "a failing dependency skips its dependent", %{scope: scope, chat: chat} do
      failing = script!(scope, name: "Failing", body: ~s[error("boom")])
      dependent = script!(scope, name: "Dependent", body: ~s(return "never"), dependency_ids: [failing.id])
      fine = script!(scope, name: "Fine", body: ~s(return event.text .. "!"))

      assert %{text: "x!", errors: errors} = Scripts.run(scope, :user_message, chat, %{"text" => "x"})
      assert [_, _] = errors

      assert Scripts.get_script!(scope, dependent.id).last_error =~ "did not succeed"
      assert Scripts.get_script!(scope, dependent.id).last_success_at == nil
      assert Scripts.get_script!(scope, failing.id).last_error =~ "boom"
      assert %DateTime{} = Scripts.get_script!(scope, fine.id).last_success_at
    end

    test "disabled and command scripts never run", %{scope: scope, chat: chat} do
      script!(scope, body: ~s(return "disabled"), enabled: false)
      script!(scope, body: ~s(return "command"), trigger: :command)

      assert %{text: "x", errors: []} = Scripts.run(scope, :user_message, chat, %{"text" => "x"})
    end

    test "the event carries trigger and chat_id", %{scope: scope, chat: chat} do
      assert {%{text: text}, _} = run(scope, chat, ~s(return event.trigger .. ":" .. event.chat_id))
      assert text == "user_message:" <> chat.id
    end
  end

  describe "run_command/3" do
    test "passes args, returns the notice and records success", %{scope: scope, chat: chat} do
      script = script!(scope, trigger: :command, body: ~S|return "n=" .. event.args.n|)

      assert {:ok, "n=2", []} = Scripts.run_command(scope, script.id, chat, %{"n" => 2})
      assert %DateTime{} = Scripts.get_script!(scope, script.id).last_success_at
    end

    test "with no chat, chat-bound functions refuse no_chat", %{scope: scope} do
      script = script!(scope, trigger: :command, body: "return select(2, mw.messages.last())")
      assert {:ok, "no_chat", []} = Scripts.run_command(scope, script.id, nil, %{})
    end

    test "may start generations", %{scope: scope, chat: chat} do
      script =
        script!(scope, trigger: :command, body: ~S|return select(2, mw.generation.generate("not-a-participant"))|)

      assert {:ok, "not_in_chat", []} = Scripts.run_command(scope, script.id, chat, %{})
    end

    test "a disabled or non-command script is refused; a failure is recorded", %{scope: scope} do
      disabled = script!(scope, trigger: :command, body: "return 1", enabled: false)
      other = script!(scope, trigger: :user_message, body: "return 1")
      failing = script!(scope, name: "Boom", trigger: :command, body: ~S|print("p") error("boom")|)

      assert {:error, "That command script no longer exists or is disabled.", []} =
               Scripts.run_command(scope, disabled.id, nil, %{})

      assert {:error, _, []} = Scripts.run_command(scope, other.id, nil, %{})

      assert {:error, ~s(Script "Boom" failed: ) <> _, [~s(Script "Boom" printed: p)]} =
               Scripts.run_command(scope, failing.id, nil, %{})

      assert Scripts.get_script!(scope, failing.id).last_error =~ "boom"
    end

    test "a scope that may not act creates nothing; an admin's run writes", %{scope: scope} do
      name = "B-#{System.unique_integer([:positive])}"
      script = script!(scope, trigger: :command, body: ~s|return mw.lore.create_book({name = "#{name}"}).name|)
      created? = fn -> Enum.any?(Lore.list_books(scope), &(&1.name == name)) end

      assert {:error, "You're not allowed to do that.", []} = Scripts.run_command(%Scope{}, script.id, nil, %{})
      refute created?.()

      assert {:ok, ^name, []} = Scripts.run_command(scope, script.id, nil, %{})
      assert created?.()
    end
  end

  describe "mw.commands.run" do
    defp command!(scope, name, body), do: script!(scope, name: name, trigger: :command, body: body)

    test "casts named args, entities by id or record table, and returns every value", %{
      scope: scope,
      chat: chat,
      bot: bot
    } do
      command!(
        scope,
        "Double",
        "---@param n integer N\n---@param who? character Who\nreturn event.args.n * 2, {name = event.args.who and event.args.who.name}"
      )

      assert {%{text: text, errors: []}, _} =
               run(
                 scope,
                 chat,
                 ~s|local a, b = mw.commands.run("Double", {n = 21, who = "#{bot.id}"}) return tostring(a) .. b.name|
               )

      assert text == "42" <> bot.name

      assert {%{text: text, errors: []}, _} =
               run(
                 scope,
                 chat,
                 ~s|local a, b = mw.commands.run("Double", {n = 2, who = mw.characters.get("#{bot.id}")}) return a .. b.name|
               )

      assert text == "4" <> bot.name
    end

    test "the called command keeps the caller's trigger, so a generation script cannot start one", %{
      scope: scope,
      chat: chat
    } do
      command!(scope, "Gen", ~s|return mw.generation.generate("x")|)

      script!(scope,
        trigger: :ai_generation,
        body: ~s|local a, b = mw.commands.run("Gen") return tostring(a) .. ":" .. b|
      )

      assert %{text: "nil:not_allowed", errors: []} = Scripts.run(scope, :ai_generation, chat, %{"text" => "x"})
    end

    test "refusals: no such command, a bad argument, and too deep a call chain", %{scope: scope, chat: chat} do
      command!(scope, "Num", "---@param n integer N\nreturn event.args.n")
      command!(scope, "Self", ~s|return mw.commands.run("Self")|)

      assert {%{text: "not_found"}, _} = run(scope, chat, ~s|return select(2, mw.commands.run("Nope"))|)

      assert {%{text: "n: Must be a whole number."}, _} =
               run(scope, chat, ~s|return select(2, mw.commands.run("Num", {n = "abc"}))|)

      assert {%{text: "too_deep", errors: []}, _} = run(scope, chat, ~s|return select(2, mw.commands.run("Self"))|)
    end

    test "an unknown parameter and a failing command fail the caller", %{scope: scope, chat: chat} do
      command!(scope, "Num", "---@param n integer N\nreturn event.args.n")
      failing = command!(scope, "Boom", ~s|error("boom")|)

      assert {%{errors: [error]}, _} = run(scope, chat, ~s|mw.commands.run("Num", {n = 1, zzz = 2})|)
      assert error =~ ~s("Num" has no parameter "zzz")

      assert {%{text: text, errors: []}, _} =
               run(scope, chat, ~s|local ok, err = pcall(mw.commands.run, "Boom") return err|)

      assert text =~ "failed: " and text =~ "boom"
      assert Scripts.get_script!(scope, failing.id).last_error =~ "boom"
    end

    test "the called command's printed lines show as the caller's, prefixed with its name", %{scope: scope, chat: chat} do
      command!(scope, "Talk", ~s|print("hi") return 1|)

      assert {%{errors: [line]}, script} = run(scope, chat, ~s|mw.commands.run("Talk") return nil|)
      assert line == ~s(Script "#{script.name}" printed: [Talk] hi)
    end
  end

  describe "run_quick_reply/3" do
    defp quick_reply!(scope, body, attrs \\ []),
      do: script!(scope, Keyword.merge([trigger: :quick_reply, body: body], attrs))

    test "a string replaces the composer text, {\"message\", text} sends, nil does nothing", %{scope: scope, chat: chat} do
      upper = quick_reply!(scope, "return event.text:upper()")
      message = quick_reply!(scope, ~s|return {"message", "x"}|)
      none = quick_reply!(scope, "return nil")
      clear = quick_reply!(scope, ~s|return {"clear"}|)
      clear_extra = quick_reply!(scope, ~s|return {"clear", "x"}|)

      assert {:ok, {:input, "HI"}, []} = Scripts.run_quick_reply(scope, upper.id, chat, "hi")
      assert {:ok, {:message, "x"}, []} = Scripts.run_quick_reply(scope, message.id, chat, "hi")
      assert {:ok, nil, []} = Scripts.run_quick_reply(scope, none.id, chat, "hi")
      assert {:ok, :clear, []} = Scripts.run_quick_reply(scope, clear.id, chat, "hi")
      assert {:error, _, []} = Scripts.run_quick_reply(scope, clear_extra.id, chat, "hi")
      assert %DateTime{} = Scripts.get_script!(scope, upper.id).last_success_at
    end

    test "any other return fails; a disabled script is refused", %{scope: scope, chat: chat} do
      bad = quick_reply!(scope, "return {1, 2}")
      disabled = quick_reply!(scope, "return 1", enabled: false)

      assert {:error, ~s(Script ") <> _, []} = Scripts.run_quick_reply(scope, bad.id, chat, "hi")
      assert Scripts.get_script!(scope, bad.id).last_error =~ ~s({"message", text})

      {:ok, renamed} = Scripts.update_script(scope, Scripts.get_script!(scope, bad.id), %{name: "Renamed"})
      assert renamed.last_error =~ ~s({"message", text})

      {:ok, fixed} = Scripts.update_script(scope, renamed, %{body: ~s|return {"clear"}|})
      assert {nil, nil, nil} == {fixed.last_error, fixed.last_error_at, fixed.last_success_at}

      assert {:error, "That quick reply no longer exists or is disabled.", []} =
               Scripts.run_quick_reply(scope, disabled.id, chat, "hi")
    end

    test "list_quick_replies/0 orders enabled ones by priority, then name", %{scope: scope} do
      quick_reply!(scope, "return nil", name: "B")
      quick_reply!(scope, "return nil", name: "A")
      quick_reply!(scope, "return nil", name: "Z", priority: 5)
      quick_reply!(scope, "return nil", name: "Off", enabled: false)

      assert ["Z", "A", "B"] = Enum.map(Scripts.list_quick_replies(scope), & &1.name)
    end
  end

  describe "ownership" do
    setup %{scope: admin} do
      user = scope!(%{role: :user})
      player = character!(user, "UP")
      bot = character!(user, "UB")
      %{admin: admin, user: user, user_chat: chat!(user, [player, bot])}
    end

    test "a user creates their own; others and admins can't see or edit it; site is usable not editable",
         %{admin: admin, user: user} do
      other = scope!(%{role: :user})
      own = script!(user, name: "Mine", trigger: :command, body: "return 1")
      site = script!(admin, [name: "Site", trigger: :command, body: "return 2"], site: true)

      assert own.user_id == user.user.id
      assert Enum.map(Scripts.list_scripts(user), & &1.id) == [own.id]
      assert Scripts.list_scripts(other) == []
      refute Enum.any?(Scripts.list_scripts(admin), &(&1.id == own.id))
      assert Scripts.get_script(admin, own.id) == nil
      assert Scripts.get_script(user, site.id) == nil
      assert Scripts.update_script(user, site, %{name: "x"}) == {:error, :unauthorized}
      assert Scripts.delete_script(admin, own) == {:error, :unauthorized}

      assert Enum.map(Scripts.list_commands(user), & &1.script.id) |> Enum.sort() == Enum.sort([own.id, site.id])
      refute Enum.any?(Scripts.list_commands(other), &(&1.script.id == own.id))
    end

    test "mw.lore.book gives a user no content of a names-only book and no hidden book at all",
         %{admin: admin, user: user, user_chat: user_chat} do
      {:ok, names_only} = Lore.create_book(admin, %{name: "Atlas", site_visibility: :runtime_only}, site: true)
      {:ok, hidden} = Lore.create_book(admin, %{name: "Vault", site_visibility: :hidden}, site: true)
      {:ok, _} = Lore.create_entry(admin, %{name: "Fact", content: "SECRET", keywords: ["fact"]}, [names_only.id])

      read = ~s|return tostring(mw.lore.book("#{names_only.id}").entries[1].content)|
      assert Scripts.run_inline(user, user_chat, [{1, read}], %{}) == {:ok, %{1 => "nil"}, []}

      missing = ~s|return select(2, mw.lore.book("#{hidden.id}"))|
      assert Scripts.run_inline(user, user_chat, [{1, missing}], %{}) == {:ok, %{1 => "not_found"}, []}
    end

    test "dependencies only on site scripts or the same owner's", %{admin: admin, user: user} do
      other = scope!(%{role: :user})
      site = script!(admin, [body: "return nil"], site: true)
      foreign = script!(other, body: "return nil")
      own = script!(user, body: "return nil")

      assert {:ok, _} =
               Scripts.create_script(user, %{name: "Dep", trigger: :user_message, dependency_ids: [site.id, own.id]})

      assert {:error, cs} =
               Scripts.create_script(user, %{name: "Bad", trigger: :user_message, dependency_ids: [foreign.id]})

      assert "includes a script you can't depend on" in errors_on(cs).dependency_ids

      assert {:error, _} =
               Scripts.create_script(admin, %{name: "SiteBad", trigger: :user_message, dependency_ids: [own.id]},
                 site: true
               )

      ids = Enum.map(Scripts.dependency_options(user, Scripts.new_script(user), :user_message), &elem(&1, 1))
      assert site.id in ids and own.id in ids
      refute foreign.id in ids
    end

    test "a user's script fires only in their chats; site scripts fire everywhere",
         %{admin: admin, user: user, user_chat: user_chat, chat: admin_chat} do
      script!(user, body: ~S|return event.text .. "+user"|, priority: 1)
      script!(admin, [body: ~S|return event.text .. "+site"|], site: true)

      assert %{text: "x+user+site"} = Scripts.run(user, :user_message, user_chat, %{"text" => "x"})
      assert %{text: "x+site"} = Scripts.run(admin, :user_message, admin_chat, %{"text" => "x"})
    end

    test "a site script failing in a user's chat records nothing; in an admin's chat it records",
         %{admin: admin, user: user, user_chat: user_chat, chat: admin_chat} do
      site = script!(admin, [body: "error(event.text)"], site: true)
      Mythweaver.Changes.subscribe(admin, [:scripts])

      assert %{errors: [error]} = Scripts.run(user, :user_message, user_chat, %{"text" => "secret"})
      assert error =~ "secret"
      unchanged = Scripts.get_script!(admin, site.id)
      assert is_nil(unchanged.last_error) and is_nil(unchanged.last_error_at) and is_nil(unchanged.last_success_at)
      refute_receive {Mythweaver.Changes, :scripts}, 100

      assert %{errors: [_]} = Scripts.run(admin, :user_message, admin_chat, %{"text" => "mine"})
      recorded = Scripts.get_script!(admin, site.id)
      assert recorded.last_error =~ "mine"
      assert recorded.last_error_at
      assert_receive {Mythweaver.Changes, :scripts}
    end

    test "a user's own script run is announced only on that user's topic",
         %{user: user, user_chat: user_chat} do
      other = scope!(%{role: :user})
      own = script!(user, body: "return nil")
      Mythweaver.Changes.subscribe(other, [:scripts])

      Scripts.run(user, :user_message, user_chat, %{"text" => "x"})
      assert Scripts.get_script!(user, own.id).last_success_at
      refute_receive {Mythweaver.Changes, :scripts}, 100

      Mythweaver.Changes.subscribe(user, [:scripts])
      Scripts.run(user, :user_message, user_chat, %{"text" => "x"})
      assert_receive {Mythweaver.Changes, :scripts}
    end

    test "run_command refuses another owner's script in a chat", %{user: user, user_chat: user_chat} do
      own = script!(scope!(%{role: :user}), trigger: :command, body: "return 1")
      user_own = script!(user, trigger: :command, body: "return 2")

      assert {:error, "That command script no longer exists or is disabled.", []} =
               Scripts.run_command(user, own.id, user_chat, %{})

      assert {:ok, "2", []} = Scripts.run_command(user, user_own.id, user_chat, %{})
    end

    test "mw.commands.run prefers the chat owner's command over the site's of that name",
         %{admin: admin, user: user, user_chat: user_chat, chat: admin_chat} do
      other = scope!(%{role: :user})
      script!(admin, name: "Greet", trigger: :command, body: ~S|return "site"|)
      script!(user, name: "Greet", trigger: :command, body: ~S|return "user"|)
      script!(other, name: "Hidden", trigger: :command, body: ~S|return "other"|)

      assert {%{text: "user"}, _} = run(user, user_chat, ~S|return (mw.commands.run("Greet"))|)
      assert {%{text: "not_found"}, _} = run(user, user_chat, ~S|return select(2, mw.commands.run("Hidden"))|)

      assert {%{text: "site"}, _} = run(admin, admin_chat, ~S|return (mw.commands.run("Greet"))|)
    end

    test "test_run is open to a user who may create scripts", %{user: user} do
      assert %{result: {:ok, "hi"}} = Scripts.test_run(user, ~S|return "hi"|, :user_message, "x")
    end
  end

  describe "Sandbox.run/3 limits" do
    defp no_trace_messages do
      {:messages, messages} = Process.info(self(), :messages)
      refute Enum.any?(messages, &match?({:trace_ts, _, _, _, _}, &1))
    end

    test "every deny-listed library function stays sandboxed" do
      calls = [
        "io.stdin()",
        "io.stdout()",
        "io.stderr()",
        "io.read()",
        "io.write()",
        "io.open()",
        "io.close()",
        "io.lines()",
        "io.popen()",
        "io.tmpfile()",
        "io.output()",
        "io.input()",
        "io.flush()",
        "io.type()",
        "file()",
        "os.execute()",
        "os.exit()",
        "os.getenv()",
        "os.remove()",
        "os.rename()",
        "os.tmpname()",
        "package()",
        "load()",
        "loadfile()",
        "require()",
        "dofile()",
        "loadstring()"
      ]

      for call <- calls do
        assert {:error, message, _} = Sandbox.run(call, & &1, Sandbox.limits())
        assert message =~ "sandboxed", "#{call}: #{message}"
      end
    end

    test "stops a busy loop at the CPU limit" do
      {us, result} = :timer.tc(fn -> Sandbox.run("while true do end", & &1, max_cpu_ms: 200) end)
      assert {:error, message, []} = result
      assert message =~ "CPU time limit"
      assert us < 2_000_000
      no_trace_messages()
    end

    test "does not charge time spent waiting, but bounds it by the wall clock" do
      setup = &Lua.set!(&1, [:nap], fn _ -> Process.sleep(300) && [] end)
      assert {:ok, ["done"], []} = Sandbox.run("nap() return 'done'", setup, max_cpu_ms: 200)

      assert {:error, message, []} = Sandbox.run("while true do nap() end", setup, max_cpu_ms: 200, max_wall_ms: 500)
      assert message == "Script exceeded its time limit of 500 ms."
      no_trace_messages()
    end

    test "kills a script at the memory limit" do
      assert {:error, message, []} =
               Sandbox.run("local t = {} for i = 1, 1e8 do t[i] = i end", & &1,
                 max_memory_bytes: 8 * 1024 * 1024,
                 max_cpu_ms: :infinity
               )

      assert message =~ "memory limit"
    end

    test "caps call depth and keeps the deny-list" do
      assert {:error, message, []} =
               Sandbox.run("local function f(n) return f(n + 1) + 1 end return f(1)", & &1, max_call_depth: 128)

      assert message =~ "stack overflow"

      assert {:error, message, []} = Sandbox.run(~s[os.execute("ls")], & &1, [])
      assert message =~ "sandboxed"
      no_trace_messages()
    end

    test "a raise through nested host callbacks names its location once" do
      setup = &API.Regex.install(&1, nil)
      body = ~S|local function f() regex.replace("a", "a", function() f() end) end f()|
      assert {:error, "Lua runtime error: stack overflow (at script:1)", []} = Sandbox.run(body, setup, [])
    end

    # 4 MB pieces under the default 32 MB heap: each result is 12 MB, over the 8 MB string ceiling
    # but small enough that only a size check, not the heap cap, can refuse it.
    test "refuses an oversized string before building it" do
      piece = ~S|local s = string.rep("x", 4 * 1024 * 1024) |

      for body <- [
            "return table.concat({s, s, s})",
            ~S|return string.format("%s%s%s", s, s, s)|,
            ~S|return (string.gsub("aaa", "a", s))|,
            ~S|return (string.gsub("aaa", "a", function() return s end))|,
            ~S|return (string.gsub("aaa", "a", {a = s}))|,
            ~S|return os.date(string.rep("%c", 512 * 1024))|,
            ~S|return (regex.replace("aaa", "a", s))|
          ] do
        assert {:error, message, []} = Sandbox.run(piece <> body, &API.Regex.install(&1, nil), [])
        assert message =~ "resulting string too large", body
        refute message =~ "stdlib", body
      end
    end

    test "sizes a gsub template by its real matches" do
      # Default 8 MB ceiling: 15,000 matches of a template expanding %0 100 times build 1.5 MB, and
      # 600 times 9 MB. The cheap bound (any position, the whole subject per %0) refuses both.
      subject = ~S|local s = string.rep("ab", 15000) |

      assert {:ok, [1_515_000], []} = Sandbox.run(subject <> ~S|return #(s:gsub("a", string.rep("%0", 100)))|, & &1, [])
      assert {:error, message, []} = Sandbox.run(subject <> ~S|return #(s:gsub("a", string.rep("%0", 600)))|, & &1, [])
      assert message =~ "resulting string too large"
    end

    test "the wrapped functions behave as before, and their originals stay out of reach" do
      body = ~S"""
      return table.concat({"a", "b", 3}, ", ") .. "|" .. table.concat({"x", "y", "z"}, "-", 2) .. "|" ..
        string.format("%5.2f/%d/%q", 3.14159, 42, "a") .. "|" .. (("hello world"):gsub("(%w+)", "<%1>")) .. "|" ..
        (("abc"):gsub("", "-")) .. "|" .. (("aaa"):gsub("^a", "b")) .. "|" .. (("x y"):gsub("%w", {x = "X"})) .. "|" ..
        os.date("!%Y", 0)
      """

      assert {:ok, [~S[a, b, 3|y-z| 3.14/42/"a"|<hello> <world>|-a-b-c-|baa|X y|1970]], []} =
               Sandbox.run(body, & &1, [])

      for body <- ["return debug.getupvalue(table.concat, 1)", ~S|return string.pack("i4", 1)|] do
        assert {:error, message, []} = Sandbox.run(body, & &1, [])
        assert message =~ "is sandboxed"
      end
    end

    test "returns printed lines, also from a failed run, up to the cap" do
      assert {:ok, ["ok"], ["a\t1\tnil"]} = Sandbox.run(~S|print("a", 1, nil) return "ok"|, & &1, [])
      assert {:error, _, ["before"]} = Sandbox.run(~S|print("before") error("boom")|, & &1, [])

      assert {:ok, [], lines} = Sandbox.run("for i = 1, 30 do print(i) end", & &1, [])
      assert length(lines) == 21
      assert List.last(lines) == "(further print output omitted)"
    end

    test "parses a pathological body without exhausting the caller" do
      body = "return " <> String.duplicate("(", 1_000_000) <> "1" <> String.duplicate(")", 1_000_000)
      assert {:error, [message]} = Sandbox.parse(body)
      assert message =~ "too complex"
      assert Sandbox.parse("return 1") == {:ok, nil}
    end
  end

  describe "capabilities/1" do
    test "lists each mw namespace the body reaches, sorted" do
      body = """
      local books = mw.lore.books()
      mw.messages.last()
      mw.lore.book(books[1])
      return mw.roll("1d6")
      """

      assert Scripts.capabilities(body) == ["mw.lore", "mw.messages"]
    end

    test "is empty for a body that does not parse" do
      assert Scripts.capabilities("return (") == []
    end
  end

  describe "check/2" do
    test "warns when a returning trigger's body can end without return" do
      for body <- [
            "local x = event.text",
            "if x then return 1 end",
            "if x then return 1 elseif y then local z = 1 else return 2 end"
          ] do
        assert %{errors: [], warnings: [warning]} = Scripts.check(body, :user_message), body
        assert warning =~ "does not end with return"
      end

      for body <- ["return event.text", "if x then return 1 else return 2 end", "do return nil end"] do
        assert Scripts.check(body, :ai_generation) == %{errors: [], warnings: []}, body
      end

      assert Scripts.check("local x = 1", :lore_activated) == %{errors: [], warnings: []}
    end

    test "reports parse and compile errors" do
      assert %{errors: ["Expected expression"], warnings: []} = Scripts.check("local x =", :user_message)
      assert %{errors: [error], warnings: []} = Scripts.check("goto nowhere", :user_message)
      assert error =~ "no visible label"
    end
  end

  describe "test_run/3" do
    test "runs against the sample text and reports what a real run keeps", %{scope: scope} do
      assert %{result: {:ok, "HI"}, lines: ["new\tfalse\tnil"]} =
               Scripts.test_run(
                 scope,
                 ~S|print(event.mode, event.script_triggered, event.message_id) return event.text:upper()|,
                 :ai_generation,
                 "hi"
               )

      assert %{result: {:ok, "kept"}} = Scripts.test_run(scope, "local x = 1", :user_message, "kept")

      assert %{result: {:error, "Script must return a string or nil."}} =
               Scripts.test_run(scope, "return 5", :user_message, "x")
    end

    test "mw.roll is allowed and raises on malformed dice", %{scope: scope} do
      assert %{result: {:ok, "3"}} =
               Scripts.test_run(scope, ~S|return tostring(mw.roll("2d1+1"))|, :user_message, "x")

      assert %{result: {:error, error}} = Scripts.test_run(scope, ~S|return mw.roll("x")|, :user_message, "x")
      assert error =~ "usage: mw.roll(dice)"
    end

    test "changes nothing: chat and write functions refuse, reads still work", %{scope: scope} do
      {:ok, book} = Lore.create_book(scope, %{name: "Book-#{System.unique_integer([:positive])}"})

      body = ~S"""
      local _, created = mw.lore.create_book({name = "Never"})
      local _, listed = mw.messages.list()
      return created .. " " .. listed .. " " .. mw.lore.book(event.text).name
      """

      assert %{result: {:ok, result}} = Scripts.test_run(scope, body, :user_message, book.id)
      assert result == "test_run test_run #{book.name}"
      assert [_] = Lore.list_books(scope)
    end
  end

  describe "permissions" do
    test "a denied namespace refuses its writes but keeps its reads" do
      :ok = Mythweaver.Permissions.put_grant!(:everyone, "scripts.messages", :deny)
      user = scope!(%{role: :user})
      player = character!(user, "Player")
      chat = chat!(user, [player, character!(user, "Bot")])
      create = ~s|return select(2, mw.messages.create(event.character_id, "hi"))|

      assert Scripts.run_inline(user, chat, [{1, create}, {2, "return #mw.messages.list()"}], %{
               "character_id" => player.id
             }) == {:ok, %{1 => "no_permission", 2 => "0"}, []}
    end

    test "variables and injections writes are open by default and refused when denied, reads kept" do
      allowed = scope!(%{role: :user})
      allowed_chat = chat!(allowed, [character!(allowed, "P"), character!(allowed, "B")])
      set = ~s|return tostring(mw.vars.set("k", 1))|
      assert {:ok, %{1 => "true"}, []} = Scripts.run_inline(allowed, allowed_chat, [{1, set}], %{})

      :ok = Mythweaver.Permissions.put_grant!(:everyone, "scripts.variables", :deny)
      :ok = Mythweaver.Permissions.put_grant!(:everyone, "scripts.injections", :deny)
      user = scope!(%{role: :user})
      chat = chat!(user, [character!(user, "Player"), character!(user, "Bot")])

      blocks = [
        {1, ~s|return select(2, mw.vars.set("k", 1))|},
        {2, ~s|return select(2, mw.injections.create({key = "k", content = "c"}))|},
        {3, ~s|return tostring(mw.vars.get("k")) .. #mw.injections.list()|}
      ]

      assert Scripts.run_inline(user, chat, blocks, %{}) ==
               {:ok, %{1 => "no_permission", 2 => "no_permission", 3 => "nil0"}, []}
    end

    test "inline scripts need content.scripts.create" do
      user = scope!(%{role: :user})
      chat = chat!(user, [character!(user, "Player"), character!(user, "Bot")])
      :ok = Mythweaver.Permissions.put_grant!(user.user, "content.scripts.create", :deny)
      user = user.user.id |> Mythweaver.Accounts.get_user() |> Scope.for_user()

      assert {:error, _, []} = Scripts.run_inline(user, chat, [{1, "return 1"}], %{})
    end
  end

  describe "member posts" do
    test "another member's message runs none of the owner's scripts", %{scope: owner, chat: chat} do
      script!(owner, body: ~s(return "owned"))
      guest = scope!(%{role: :user})
      {:ok, member} = Chats.invite(owner, chat, guest.user.handle, :guest)
      {:ok, _} = Chats.accept_invite(guest, member.id)

      assert Scripts.run(guest, :user_message, chat, %{"text" => "x"}) == %{text: "x", errors: []}
      assert %{text: "owned"} = Scripts.run(owner, :user_message, chat, %{"text" => "x"})
    end
  end

  describe "run_inline/3" do
    test "returns each block's value by index, numbers as strings and nothing as blank", %{scope: scope, chat: chat} do
      assert Scripts.run_inline(scope, chat, [{1, ~s(return "x")}, {3, "return 2"}, {4, "local _ = 1"}], %{}) ==
               {:ok, %{1 => "x", 3 => "2", 4 => ""}, []}
    end

    test "event carries the trigger, index and caller's fields; prints are labelled", %{
      scope: scope,
      chat: chat,
      player: player
    } do
      body = ~s|print(event.trigger) return event.index .. event.character_id .. event.chat_id|

      assert Scripts.run_inline(scope, chat, [{2, body}], %{"character_id" => player.id}) ==
               {:ok, %{2 => "2#{player.id}#{chat.id}"}, ["Inline script 2 printed: inline"]}
    end

    test "a runtime error stops before later blocks", %{scope: scope, chat: chat, player: player} do
      create = ~s[mw.messages.create("#{player.id}", "ran")]

      assert {:error, "inline script 1 failed: " <> message, []} =
               Scripts.run_inline(scope, chat, [{1, ~s[error("boom")]}, {2, create}], %{})

      refute message =~ "already ran"
      assert Messages.list_messages(chat) == []

      assert {:error, "inline script 2 failed: " <> message, _} =
               Scripts.run_inline(scope, chat, [{1, create}, {2, ~s[error("boom")]}], %{})

      assert message =~ "Inline scripts before it already ran."
      assert [_] = Messages.list_messages(chat)
    end

    test "a table is not a block value", %{scope: scope, chat: chat} do
      assert {:error, "inline script 1 failed: must return a string, a number or nil.", []} =
               Scripts.run_inline(scope, chat, [{1, "return {}"}], %{})
    end

    test "may start generations", %{scope: scope, chat: chat} do
      assert {:ok, %{1 => "not_in_chat"}, []} =
               Scripts.run_inline(scope, chat, [{1, ~s[local _, r = mw.generation.generate("nope") return r]}], %{})
    end

    test "markers survive the message's template render", %{scope: scope, chat: chat, player: player} do
      {:ok, %{template: template}} = Inline.prepare("{{ 'a' }} {! return 'b' !}")
      assert {:ok, rendered, _} = Builder.render_user_text(scope, chat, player.id, template)
      assert Inline.present(rendered, 1) == [1]
    end
  end

  describe "host API" do
    test "mw.messages create, edit and get", %{scope: scope, chat: chat, player: player} do
      assert {%{errors: []}, _} = run(scope, chat, ~s[assert(mw.messages.create("#{player.id}", "hi"))])
      assert [message] = Messages.list_messages(chat)
      assert Message.active_content(message) == "hi"

      assert {%{errors: []}, _} = run(scope, chat, ~s[assert(mw.messages.edit("#{message.id}", "new"))])
      assert Messages.get_message!(scope, message.id) |> Message.active_content() == "new"

      other = chat!(scope, [character!(scope, "Other"), character!(scope, "Another")])
      {:ok, foreign} = Messages.post_message(scope, other, {:character, other.player_character_id}, "elsewhere")

      body = ~s[local m, reason = mw.messages.get("#{foreign.id}") return tostring(m) .. ":" .. reason]
      assert {%{text: "nil:not_found"}, _} = run(scope, chat, body)
    end

    test "mw.messages.create refuses a character outside the chat and a blank name", %{scope: scope, chat: chat} do
      outsider = character!(scope, "Outsider")

      for {author, reason} <- [{~s("#{outsider.id}"), "not_in_chat"}, {~s({name = " "}), "blank_name"}] do
        body = ~s[local _, reason = mw.messages.create(#{author}, "hi") return reason]
        assert {%{text: ^reason}, _} = run(scope, chat, body)
      end

      assert Messages.list_messages(chat) == []
    end

    test "mw.messages.create posts as a name with no character, or as another message's author",
         %{scope: scope, chat: chat, bot: bot} do
      body =
        ~s[local m = mw.messages.create({name = " Narrator "}, "Night falls.") return tostring(m.author.id) .. "|" .. m.author.name]

      assert {%{text: "nil|Narrator"}, _} = run(scope, chat, body)

      assert [%{author_is_character: false, author_name: "Narrator", author_character_id: nil, author_is_player: false}] =
               Messages.list_messages(chat)

      {:ok, by_bot} = Messages.post_message(scope, chat, {:character, bot.id}, "hi")
      copy = ~s[return mw.messages.create(mw.messages.get("#{by_bot.id}").author, "again").author.id]
      assert {%{text: id}, _} = run(scope, chat, copy)
      assert id == bot.id
    end

    test "mw.messages.last is the newest message, nil in an empty chat", %{
      scope: scope,
      chat: chat,
      player: player,
      bot: bot
    } do
      body =
        ~s[local m = mw.messages.last() return m and (m.text .. "|" .. m.author.id .. "|" .. m.author.name) or "none"]

      assert {%{text: "none"}, _} = run(scope, chat, body)

      {:ok, _} = Messages.post_message(scope, chat, {:character, player.id}, "first")
      {:ok, _} = Messages.post_message(scope, chat, {:character, bot.id}, "second")
      assert {%{text: text}, _} = run(scope, chat, body)
      assert text == "second|#{bot.id}|#{bot.name}"
    end

    test "a message's author is the character's current name, or a detached name with no id",
         %{scope: scope, chat: chat, bot: bot} do
      {:ok, message} = Messages.post_message(scope, chat, {:character, bot.id}, "hi")
      {:ok, _} = Characters.update_character(scope, bot, %{name: "Renamed"})

      body = ~s[local a = mw.messages.get("#{message.id}").author return tostring(a.id) .. "|" .. a.name]
      assert {%{text: text}, _} = run(scope, chat, body)
      assert text == "#{bot.id}|Renamed"

      {:ok, _} =
        Messages.reattribute_message(scope, chat, Messages.get_message!(scope, message.id), {:name, "Narrator"})

      assert {%{text: "nil|Narrator"}, _} = run(scope, chat, body)
    end

    test "mw.messages.set_author takes a name, a character id or another message's author",
         %{scope: scope, chat: chat, player: player, bot: bot} do
      {:ok, message} = Messages.post_message(scope, chat, {:character, bot.id}, "hi")
      {:ok, by_player} = Messages.post_message(scope, chat, {:character, player.id}, "me")
      author_of = fn -> Messages.get_message!(scope, message.id) end

      assert {%{errors: [], text: "Narrator"}, _} =
               run(scope, chat, ~s[return mw.messages.set_author("#{message.id}", {name = " Narrator "}).author.name])

      assert %{author_is_character: false, author_name: "Narrator", bodies: [_]} = author_of.()

      assert {%{errors: []}, _} = run(scope, chat, ~s[assert(mw.messages.set_author("#{message.id}", "#{bot.id}"))])
      assert %{author_is_character: true, author_character_id: bot_id} = author_of.()
      assert bot_id == bot.id

      copy = ~s[assert(mw.messages.set_author("#{message.id}", mw.messages.get("#{by_player.id}").author))]
      assert {%{errors: []}, _} = run(scope, chat, copy)
      assert author_of.().author_character_id == player.id
    end

    test "mw.messages.set_author refuses an outsider and a blank name", %{scope: scope, chat: chat, bot: bot} do
      {:ok, message} = Messages.post_message(scope, chat, {:character, bot.id}, "hi")
      outsider = character!(scope, "Outsider")

      for {author, reason} <- [{~s("#{outsider.id}"), "not_in_chat"}, {~s({name = "  "}), "blank_name"}] do
        body = ~s[local _, reason = mw.messages.set_author("#{message.id}", #{author}) return reason]
        assert {%{text: ^reason}, _} = run(scope, chat, body)
      end

      assert Messages.get_message!(scope, message.id).author_character_id == bot.id
    end

    test "mw.messages.list reads a number range; messages carry player, version and time",
         %{scope: scope, chat: chat, player: player, bot: bot} do
      {:ok, first} = Messages.post_message(scope, chat, {:character, player.id}, "a")
      {:ok, _} = Messages.post_message(scope, chat, {:character, bot.id}, "b")
      {:ok, _} = Messages.post_message(scope, chat, {:character, bot.id}, "c")
      {:ok, _} = Messages.add_edited_body(scope, first, %{"content" => "a2"})

      texts =
        ~s[local t = {} for _, m in ipairs(mw.messages.list(%s)) do table.insert(t, m.text) end return table.concat(t, ",")]

      # A new chat's first message is #1, as the chat shows it.
      assert {%{text: "a2,b,c"}, _} = run(scope, chat, String.replace(texts, "%s", ""))
      assert {%{text: "b,c"}, _} = run(scope, chat, String.replace(texts, "%s", "2"))
      assert {%{text: "a2,b"}, _} = run(scope, chat, String.replace(texts, "%s", "1, 2"))

      body = ~s"""
      local m = mw.messages.list(1, 1)[1]
      return m.number .. "|" .. m.position .. "|" .. tostring(m.author_is_player) .. "|" .. m.version .. "/" .. m.version_count .. "|" .. m.created_at
      """

      assert {%{text: text}, _} = run(scope, chat, body)
      assert [_, _, _, _, created_at] = String.split(text, "|")
      assert {:ok, _, _} = DateTime.from_iso8601(created_at)
      assert text =~ ~r/^1\|1\|true\|2\/2\|/
      assert {%{text: "3"}, _} = run(scope, chat, "return tostring(mw.messages.last().number)")
    end

    test "mw.messages.versions lists swipes and set_version picks one", %{scope: scope, chat: chat, bot: bot} do
      {:ok, message} = Messages.post_message(scope, chat, {:character, bot.id}, "one")
      {:ok, _} = Messages.add_edited_body(scope, message, %{"content" => "two"})

      list =
        ~s[local t = {} for _, v in ipairs(mw.messages.versions("#{message.id}")) do
        table.insert(t, v.index .. ":" .. v.text .. ":" .. v.origin .. ":" .. tostring(v.active)) end return table.concat(t, ",")]

      assert {%{text: "1:one:original:false,2:two:edit:true"}, _} = run(scope, chat, list)

      assert {%{text: "one"}, _} = run(scope, chat, ~s[return mw.messages.set_version("#{message.id}", 1).text])
      assert Messages.get_message!(scope, message.id) |> Message.active_content() == "one"

      body = ~s[local _, reason = mw.messages.set_version("#{message.id}", 3) return reason]
      assert {%{text: "not_found"}, _} = run(scope, chat, body)
    end

    test "mw.messages.merge joins consecutive messages and refuses a gap", %{scope: scope, chat: chat, bot: bot} do
      {:ok, a} = Messages.post_message(scope, chat, {:character, bot.id}, "a")
      {:ok, b} = Messages.post_message(scope, chat, {:character, bot.id}, "b")
      {:ok, c} = Messages.post_message(scope, chat, {:character, bot.id}, "c")

      gap = ~s[local _, reason = mw.messages.merge({"#{a.id}", "#{c.id}"}) return reason]
      assert {%{text: "not_contiguous"}, _} = run(scope, chat, gap)
      bad = ~s[local _, reason = mw.messages.merge({"#{a.id}", "nope"}) return reason]
      assert {%{text: "not_found"}, _} = run(scope, chat, bad)

      assert {%{text: "a\n\nb"}, _} = run(scope, chat, ~s[return mw.messages.merge({"#{a.id}", "#{b.id}"}).text])
      assert chat |> Messages.list_messages() |> Enum.map(&Message.active_content/1) == ["a\n\nb", "c"]
    end

    test "mw.messages.split cuts before the first matching paragraph, or every one with multi",
         %{scope: scope, chat: chat, bot: bot} do
      text = "B: start\n\nmiddle\n\nB: next\n\nend\n\nB: last"

      split = fn multi ->
        {:ok, message} = Messages.post_message(scope, chat, {:character, bot.id}, text)
        body = ~s[local t = {} for _, m in ipairs(mw.messages.split("#{message.id}", "B:"#{multi})) do
          table.insert(t, m.text) end return table.concat(t, "|")]

        run(scope, chat, body)
      end

      # The first paragraph matches too, but a marker can only go after it.
      assert {%{text: "B: start\n\nmiddle|B: next\n\nend\n\nB: last"}, _} = split.("")
      assert {%{text: "B: start\n\nmiddle|B: next\n\nend|B: last"}, _} = split.(", true")

      {:ok, plain} = Messages.post_message(scope, chat, {:character, bot.id}, "B: only\n\nnothing here")
      body = ~s[local _, reason = mw.messages.split("#{plain.id}", "B:", true) return reason]
      assert {%{text: "no_match"}, _} = run(scope, chat, body)
    end

    defp post!(scope, chat, bot, texts),
      do: Enum.map(texts, &elem(Messages.post_message(scope, chat, {:character, bot.id}, &1), 1))

    defp texts(chat), do: chat |> Messages.list_messages() |> Enum.map(&Message.active_content/1)

    test "mw.messages.delete takes an id, a number, a range of numbers, or a list of them", %{
      scope: scope,
      chat: chat,
      bot: bot
    } do
      [_, _, m3, _, _, m6 | _] = post!(scope, chat, bot, Enum.map(1..11, &"m#{&1}"))

      # Both ends of a range count: 7-11 is #7 through #11.
      assert {%{text: "5"}, _} = run(scope, chat, ~s[return tostring(mw.messages.delete("7-11"))])
      assert texts(chat) == ~w(m1 m2 m3 m4 m5 m6)

      assert {%{text: "true"}, _} = run(scope, chat, ~s[return tostring(mw.messages.delete(1))])
      assert {%{text: "not_found"}, _} = run(scope, chat, ~s[return select(2, mw.messages.delete(1))])
      assert {%{text: "true"}, _} = run(scope, chat, ~s[return tostring(mw.messages.delete("#{m6.id}"))])

      body = ~s[return tostring(mw.messages.delete({2, "4-5", "#{m3.id}", 999}))]
      assert {%{text: "4"}, _} = run(scope, chat, body)
      assert texts(chat) == []

      assert {%{errors: [error]}, _} = run(scope, chat, ~s[mw.messages.delete("5-2")])
      assert error =~ "usage: mw.messages.delete(target)"
    end

    test "mw.messages.delete deletes nothing when any target is generating", %{scope: scope, chat: chat, bot: bot} do
      [m1] = post!(scope, chat, bot, ["m1"])
      {:ok, generating} = Messages.create_generating_message(chat, bot.id)

      body = ~s[return select(2, mw.messages.delete("#{m1.position + 1}-#{generating.position + 1}"))]
      assert {%{text: "generating"}, _} = run(scope, chat, body)
      assert length(Messages.list_messages(chat)) == 2
    end

    test "mw.messages.set_visible takes the same targets; a list ignores other chats' ids", %{
      scope: scope,
      chat: chat,
      bot: bot
    } do
      [_a, b, _c] = post!(scope, chat, bot, ~w(a b c))
      other = chat!(scope, [character!(scope, "Other"), character!(scope, "Another")])
      {:ok, foreign} = Messages.post_message(scope, other, {:character, other.player_character_id}, "elsewhere")

      assert {%{text: "a"}, _} = run(scope, chat, ~s[return mw.messages.set_visible(1, false).text])

      body = ~s[return tostring(#mw.messages.set_visible({"#{b.id}", "#{foreign.id}", "junk", 1}, false))]
      assert {%{text: "1"}, _} = run(scope, chat, body)
      assert Messages.get_message!(scope, foreign.id).visible_to_ai

      assert {%{text: "2"}, _} = run(scope, chat, ~s[return tostring(#mw.messages.set_visible("1-3", true))])
      assert chat |> Messages.list_messages() |> Enum.map(& &1.visible_to_ai) == [true, true, true]
    end

    test "mw.messages.select returns the targeted messages in order", %{scope: scope, chat: chat, bot: bot} do
      [_a, _b, _c, d] = post!(scope, chat, bot, ~w(a b c d))

      select =
        &~s[local t = {} for _, m in ipairs(mw.messages.select(#{&1})) do table.insert(t, m.position .. m.text) end return table.concat(t, ",")]

      assert {%{text: "1a,3c,4d"}, _} = run(scope, chat, select.(~s[{"#{d.id}", "3-3", 1}]))
      assert {%{text: "2b"}, _} = run(scope, chat, select.(2))
      assert {%{text: ""}, _} = run(scope, chat, select.(~s["#{Mythweaver.Schema.generate_id()}"]))
    end

    test "mw.characters.update persists", %{scope: scope, chat: chat, bot: bot} do
      assert {%{errors: []}, _} = run(scope, chat, ~s[assert(mw.characters.update("#{bot.id}", {name = "Renamed"}))])
      assert Characters.get_character!(bot.id).name == "Renamed"
    end

    test "mw.characters.set_appearance saves the appearance and tells an open editor", %{
      scope: scope,
      chat: chat,
      bot: bot
    } do
      Phoenix.PubSub.subscribe(Mythweaver.PubSub, Mythweaver.Attachments.character_topic(bot.id))

      assert {%{text: "Tall, grey eyes"}, _} =
               run(
                 scope,
                 chat,
                 ~s[return mw.characters.set_appearance({id = "#{bot.id}"}, "Tall, grey eyes").appearance]
               )

      assert Characters.get_character!(bot.id).appearance == "Tall, grey eyes"
      bot_id = bot.id
      assert_received {:appearance_updated, ^bot_id}

      unknown = Mythweaver.Schema.generate_id()

      assert {%{text: "not_found"}, _} =
               run(scope, chat, ~s[return select(2, mw.characters.set_appearance("#{unknown}", "x"))])
    end

    test "mw.characters.set_avatar asks the chat for the character's avatar", %{scope: scope, chat: chat, bot: bot} do
      :ok = Mythweaver.Attachments.subscribe(chat.id)

      assert {%{text: "true"}, _} =
               run(scope, chat, ~s[return tostring(mw.characters.set_avatar("#{bot.id}", "Smile!", false))])

      bot_id = bot.id
      assert_received {:image_requested, %{prompt: "Smile!", avatar: %{character_id: ^bot_id, describe?: false}}}

      unknown = Mythweaver.Schema.generate_id()
      assert {%{text: "not_found"}, _} = run(scope, chat, ~s[return select(2, mw.characters.set_avatar("#{unknown}"))])
      refute_received {:image_requested, _}

      command = script!(scope, trigger: :command, body: ~s[return select(2, mw.characters.set_avatar("#{bot.id}"))])
      assert {:ok, "no_chat", []} = Scripts.run_command(scope, command.id, nil, %{})
    end

    test "mw.characters.find matches the whole name, ignoring case and spaces; the oldest wins", %{
      scope: scope,
      chat: chat
    } do
      name = "Geralt-#{System.unique_integer([:positive])}"
      {:ok, oldest} = Characters.create_character(scope, %{name: name})
      {:ok, _newer} = Characters.create_character(scope, %{name: name})
      find = &~s[local c, reason = mw.characters.find("#{&1}") return c and c.id or reason]

      assert {%{text: id}, _} = run(scope, chat, find.("  #{String.upcase(name)} "))
      assert id == oldest.id
      assert {%{text: "not_found"}, _} = run(scope, chat, find.(String.slice(name, 0, 6)))
    end

    test "mw.prompts.set_block_enabled flips the membership", %{scope: scope, chat: chat} do
      {:ok, prompt} = Prompts.create_prompt(scope, %{name: "Prompt-#{System.unique_integer([:positive])}"})
      {:ok, block} = Prompts.create_block(scope, %{name: "Block-#{System.unique_integer([:positive])}", content: "c"})
      {:ok, _} = Prompts.add_block(scope, prompt, block)

      body = ~s[assert(mw.prompts.set_block_enabled("#{prompt.id}", "#{block.id}", false))]
      assert {%{errors: []}, _} = run(scope, chat, body)
      assert [%{enabled: false}] = Prompts.list_prompt_blocks(prompt)
    end

    test "mw.lore.create_entry adds an entry to the book", %{scope: scope, chat: chat} do
      {:ok, book} = Lore.create_book(scope, %{name: "Book-#{System.unique_integer([:positive])}"})

      body = ~s[local e = assert(mw.lore.create_entry("#{book.id}", {name = "E", content = "c", keywords = {"k"}}))
                return e.book_id]

      assert {%{text: book_id, errors: []}, _} = run(scope, chat, body)
      assert book_id == book.id
      assert [%{name: "E", keywords: ["k"]}] = Lore.list_entries_in_book(scope, book)
    end

    test "mw.images lists a message's images, sets a description, and refuses to caption without a captioner",
         %{scope: scope, chat: chat, player: player} do
      png =
        Base.decode64!(
          "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
        )

      {:ok, image} = Mythweaver.Attachments.store_binary(png)
      {:ok, message} = Messages.send_message(scope, chat, player.id, "Look", attachments: [image])

      body = """
      local images = assert(mw.images.list("#{message.id}"))
      local updated = assert(mw.images.set_description(images[1].id, "A red fox"))
      local _, reason = mw.images.caption(images[1].id)
      return #images .. ":" .. updated.description .. ":" .. updated.caption_status .. ":" .. reason
      """

      assert {%{text: "1:A red fox:done:no_captioner", errors: []}, _} = run(scope, chat, body)
      assert Repo.reload!(image).description == "A red fox"
    end

    test "a user_message script reaches the images being sent through event.images, and no others",
         %{scope: scope, chat: chat} do
      png =
        Base.decode64!(
          "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
        )

      {:ok, staged} = Mythweaver.Attachments.store_binary(png)
      {:ok, elsewhere} = Mythweaver.Attachments.store_binary(png)

      body = """
      local image = assert(mw.images.get(event.images[1]))
      local _, foreign = mw.images.get("#{elsewhere.id}")
      local _, captioned = mw.images.caption(image.id, {tag = "outfit"})
      return tostring(image.message_id) .. ":" .. foreign .. ":" .. captioned
      """

      assert {%{text: "nil:not_found:no_captioner", errors: []}, _} =
               run(scope, chat, body, %{"text" => "x", "images" => [staged.id]})
    end

    test "mw.images.request asks the chat's tabs for an image, with its tag and data held for the result",
         %{scope: scope, chat: chat} do
      :ok = Mythweaver.Attachments.subscribe(chat.id)

      body =
        ~S'return tostring(mw.images.request("Show the letter.", {tag = "letter", data = {who = "Geralt", n = 2}}))'

      assert {%{text: "true", errors: []}, _} = run(scope, chat, body)

      assert_received {:image_requested, %{prompt: "Show the letter.", callback: callback}}
      assert %{tag: "letter", data: %{"who" => "Geralt", "n" => 2}} = CallbackStore.fetch(callback)

      script!(scope,
        trigger: :lore_activated,
        body: ~S'local _, reason = mw.images.request() assert(reason == "not_allowed")'
      )

      assert %{errors: []} = Scripts.run(scope, :lore_activated, chat, %{"entries" => [], "books" => []})
      refute_received {:image_requested, _}
    end

    test "opts.data must be plain data and at most 64 KB", %{scope: scope, chat: chat} do
      assert {%{errors: [error]}, _} = run(scope, chat, ~S'mw.images.request(nil, {data = {f = function() end}})')
      assert error =~ "usage: mw.images.request(prompt?, opts?)"

      big = ~S'local _, reason = mw.images.request(nil, {data = string.rep("x", 70000)}) return reason'
      assert {%{text: "data_too_large", errors: []}, _} = run(scope, chat, big)
    end

    test "a malformed call fails the script", %{scope: scope, chat: chat} do
      assert {%{errors: [error]}, _} = run(scope, chat, "mw.messages.get(5)")
      assert error =~ "usage: mw.messages.get(id)"
    end
  end

  describe "mw.vars, mw.globals and mw.injections" do
    test "mw.vars sets, reads and deletes the chat's variables", %{scope: scope, chat: chat} do
      body = ~S"""
      assert(mw.vars.set("hp", 10))
      assert(mw.vars.set("bag", {"rope", "lamp"}))
      assert(mw.vars.set("gone", "x"))
      assert(mw.vars.set("gone", nil))
      local all = mw.vars.list()
      return mw.vars.get("hp") .. ":" .. mw.vars.get("bag")[2] .. ":" .. tostring(all.gone) .. ":" .. tostring(mw.vars.get("missing"))
      """

      assert {%{text: "10:lamp:nil:nil", errors: []}, _} = run(scope, chat, body)
      assert Variables.values(chat.id).chat == %{"hp" => 10, "bag" => ["rope", "lamp"]}
    end

    test "mw.vars.set refuses a malformed key and raises on a value that is not plain data", %{
      scope: scope,
      chat: chat
    } do
      assert {%{text: "key: must start" <> _, errors: []}, _} =
               run(scope, chat, ~S|return select(2, mw.vars.set("no spaces", 1))|)

      assert {%{errors: [error]}, _} = run(scope, chat, ~S|mw.vars.set("f", function() end)|)
      assert error =~ "usage: mw.vars.set(key, value)"
      assert Variables.values(chat.id).chat == %{}
    end

    test "mw.globals reads site globals under the user's own and writes only the user's own", %{
      scope: scope,
      chat: chat
    } do
      {:ok, %{user_id: nil} = site} =
        Variables.create_variable(scope, nil, %{key: "weather", value: "rain"}, site: true)

      body = ~S"""
      local before = mw.globals.get("weather")
      assert(mw.globals.set("weather", "snow"))
      return before .. ":" .. mw.globals.get("weather") .. ":" .. mw.globals.list().weather
      """

      assert {%{text: "rain:snow:snow", errors: []}, _} = run(scope, chat, body)
      assert Repo.reload!(site).value == "rain"
      user_id = scope.user.id
      assert [%{user_id: ^user_id, value: "snow"}] = Enum.filter(Variables.list_global_variables(scope), & &1.user_id)
    end

    test "mw.injections creates, edits, toggles and deletes by key or id", %{scope: scope, chat: chat} do
      body = ~S"""
      local i = assert(mw.injections.create({key = "mood", content = "Rain falls.", uses = 2, position = "at_depth", depth = 1}))
      assert(mw.injections.update("mood", {uses = false, role = "user"}))
      assert(mw.injections.set_enabled(i.id, false))
      local got = assert(mw.injections.get("mood"))
      return got.position .. ":" .. got.role .. ":" .. tostring(got.uses) .. ":" .. tostring(got.enabled) .. ":" .. tostring(got.active)
      """

      assert {%{text: "at_depth:user:nil:false:false", errors: []}, _} = run(scope, chat, body)
      assert [%{key: "mood", uses: nil, depth: 1, enabled: false}] = Injections.list_injections(scope, chat.id)

      body = ~S"""
      local _, missing = mw.injections.delete("nope")
      assert(mw.injections.delete("mood"))
      return missing .. ":" .. #mw.injections.list()
      """

      assert {%{text: "not_found:0", errors: []}, _} = run(scope, chat, body)
    end

    test "mw.injections.rearm restores a spent injection and clean_up deletes the spent ones", %{
      scope: scope,
      chat: chat
    } do
      {:ok, a} = Injections.create_injection(scope, chat.id, %{key: "a", content: "A", uses: 1})
      {:ok, b} = Injections.create_injection(scope, chat.id, %{key: "b", content: "B", uses: 1})
      :ok = Injections.spend(chat.id, [a.id, b.id])

      body =
        ~S|local r = assert(mw.injections.rearm("a")) return r.remaining .. ":" .. tostring(r.active) .. ":" .. mw.injections.clean_up()|

      assert {%{text: "1:true:1", errors: []}, _} = run(scope, chat, body)
      assert [%{key: "a", remaining: 1}] = Injections.list_injections(scope, chat.id)
    end

    test "off a chat mw.vars and mw.injections refuse no_chat; a test run reads globals but writes none", %{
      scope: scope
    } do
      body = ~S|return select(2, mw.vars.get("x")) .. ":" .. select(2, mw.injections.list())|
      script = script!(scope, trigger: :command, body: body)
      assert {:ok, "no_chat:no_chat", []} = Scripts.run_command(scope, script.id, nil, %{})

      {:ok, _} = Variables.create_variable(scope, nil, %{key: "w", value: "rain"})
      body = ~S|local _, refused = mw.globals.set("w", "snow") return mw.globals.get("w") .. ":" .. refused|
      assert %{result: {:ok, "rain:test_run"}} = Scripts.test_run(scope, body, :user_message, "x")
      assert Variables.global_values(scope) == %{"w" => "rain"}
    end
  end

  describe "mw.memory" do
    alias Mythweaver.AI
    alias Mythweaver.Jobs
    alias Mythweaver.Memory

    setup %{scope: scope, chat: chat, player: player, bot: bot} = context do
      # Queued jobs run in scheduler-spawned tasks, outside the test's `$callers` chain; the stub
      # fails each one quickly, and `settle/1` waits for that before the sandbox goes away.
      Req.Test.set_req_test_to_shared(context)
      Req.Test.stub(Mythweaver.AI, &Plug.Conn.send_resp(&1, 500, "stubbed"))
      :ok = Jobs.subscribe(scope)

      {:ok, model} = AI.create_model(scope, %{name: "Memory model", api_model_id: "memory-model"})

      {:ok, provider} =
        AI.create_provider(scope, %{name: "Local", adapter: :openai_compatible, base_url: "http://localhost/v1"})

      {:ok, _} = AI.link_model(scope, provider, model)
      {:ok, prompt} = Prompts.create_prompt(scope, %{name: "Memory: Script", purpose: :memory})
      {:ok, block} = Prompts.create_block(scope, %{name: "Scene", role: :user, content: "{{ anchors.memory.scene }}"})
      {:ok, _} = Prompts.add_block(scope, prompt, block)

      {:ok, profile} =
        Memory.create_profile(scope, %{name: "Script", ai_model_id: model.id, memory_prompt_id: prompt.id})

      {:ok, _} = Memory.set_default_profile(scope, profile)

      {:ok, side_prompt_prompt} = Prompts.create_prompt(scope, %{name: "Side: Script", purpose: :side_prompt})
      {:ok, _} = Prompts.add_block(scope, side_prompt_prompt, block)
      {:ok, tracker} = Memory.create_side_prompt(scope, %{name: "Tracker", prompt_id: side_prompt_prompt.id})
      {:ok, cast} = Memory.create_side_prompt(scope, %{name: "Cast", prompt_id: side_prompt_prompt.id, enabled: false})

      for i <- 1..6 do
        author = if rem(i, 2) == 1, do: player.id, else: bot.id
        {:ok, _} = Messages.post_message(scope, chat, {:character, author}, "line #{i}")
      end

      %{chat: Chats.get_chat!(chat.id), tracker: tracker, cast: cast}
    end

    defp job_ranges(scope, chat, tag) do
      scope
      |> Jobs.list_jobs(chat_id: chat.id)
      |> Enum.filter(&(&1.tag == tag))
      |> Enum.map(&{&1.range_start, &1.range_end})
    end

    defp settle(scope, chat) do
      if Jobs.active_count(scope, chat.id) > 0 do
        receive do
          {:job_changed, _job} -> settle(scope, chat)
        after
          2000 -> flunk("memory jobs never finished")
        end
      end
    end

    test "create queues a scene in display numbers and returns its job", %{scope: scope, chat: chat} do
      body =
        ~S|local j = mw.memory.create(2, 4) return j.tag .. " " .. j.range_start .. "-" .. j.range_end .. " " .. j.label|

      assert {%{text: "memory 2-4 Memory #2–#4", errors: []}, _} = run(scope, chat, body)
      assert [{1, 3}] = job_ranges(scope, chat, :memory)
      settle(scope, chat)
    end

    test "next queues every unprocessed message, then refuses empty_scene", %{scope: scope, chat: chat} do
      {:ok, _} = Memory.set_highest_processed(scope, chat, 1)

      assert {%{text: "3-6"}, _} =
               run(scope, chat, ~S|local j = mw.memory.next() return j.range_start .. "-" .. j.range_end|)

      assert [{2, 5}] = job_ranges(scope, chat, :memory)
      settle(scope, chat)

      {:ok, _} = Memory.set_highest_processed(scope, chat, 5)
      assert {%{text: "empty_scene"}, _} = run(scope, chat, "return select(2, mw.memory.next())")
    end

    test "catch_up queues chunked jobs and passes context refusals through", %{scope: scope, chat: chat} do
      body = ~S|local js = mw.memory.catch_up(1, 6, 5) return #js .. " " .. js[1].range_end .. " " .. js[2].range_start|
      assert {%{text: "2 5 6"}, _} = run(scope, chat, body)
      assert [{0, 4}, {5, 5}] = job_ranges(scope, chat, :memory) |> Enum.sort()
      settle(scope, chat)

      assert {%{text: "invalid_chunk"}, _} = run(scope, chat, "return select(2, mw.memory.catch_up(1, 6, 2))")
    end

    test "run_side_prompt queues explicit and default ranges; an unknown id is not_found",
         %{scope: scope, chat: chat, tracker: tracker} do
      body =
        ~s[local j = mw.memory.run_side_prompt("#{tracker.id}", 2, 3) return j.tag .. " " .. j.range_start .. "-" .. j.range_end]

      assert {%{text: "side_prompt 2-3"}, _} = run(scope, chat, body)

      default = ~s[local j = mw.memory.run_side_prompt("#{tracker.id}") return j.range_start .. "-" .. j.range_end]
      assert {%{text: "1-6"}, _} = run(scope, chat, default)
      assert [{0, 5}, {1, 2}] = job_ranges(scope, chat, :side_prompt) |> Enum.sort()

      assert Enum.all?(
               Jobs.list_jobs(scope, chat_id: chat.id),
               &(&1.origin == :background and &1.params["trigger"] == "script")
             )

      settle(scope, chat)

      missing = ~s[return select(2, mw.memory.run_side_prompt("#{Mythweaver.Schema.generate_id()}"))]
      assert {%{text: "not_found"}, _} = run(scope, chat, missing)
      assert {%{text: "not_found"}, _} = run(scope, chat, ~S|return select(2, mw.memory.run_side_prompt("nope"))|)
    end

    test "set_side_prompt_enabled changes one prompt or all, counting only changes",
         %{scope: scope, chat: chat, tracker: tracker, cast: cast} do
      assert {%{text: "1"}, _} =
               run(scope, chat, ~s[return tostring(mw.memory.set_side_prompt_enabled("#{tracker.id}", false))])

      refute Memory.get_side_prompt(scope, tracker.id).enabled

      assert {%{text: "0"}, _} =
               run(scope, chat, ~s[return tostring(mw.memory.set_side_prompt_enabled("#{tracker.id}", false))])

      assert {%{text: "2"}, _} = run(scope, chat, ~S|return tostring(mw.memory.set_side_prompt_enabled("all", true))|)
      assert Memory.get_side_prompt(scope, tracker.id).enabled and Memory.get_side_prompt(scope, cast.id).enabled

      unknown = ~s[return select(2, mw.memory.set_side_prompt_enabled("#{Mythweaver.Schema.generate_id()}", true))]
      assert {%{text: "not_found"}, _} = run(scope, chat, unknown)

      for side_prompt <- Memory.list_side_prompts(scope), do: {:ok, _} = Memory.delete_side_prompt(scope, side_prompt)
      assert {%{text: "0"}, _} = run(scope, chat, ~S|return tostring(mw.memory.set_side_prompt_enabled("all", false))|)
    end

    test "highest and set_highest use display numbers and nil clears", %{scope: scope, chat: chat} do
      assert {%{text: "nil"}, _} = run(scope, chat, "return tostring(mw.memory.highest())")
      assert {%{text: "4"}, _} = run(scope, chat, "mw.memory.set_highest(4) return tostring(mw.memory.highest())")
      assert Memory.chat_settings(scope, chat).highest_processed == 3

      assert {%{text: "true nil"}, _} =
               run(scope, chat, "return tostring(mw.memory.set_highest(nil)) .. ' ' .. tostring(mw.memory.highest())")

      assert Memory.chat_settings(scope, chat).highest_processed == nil
    end

    test "malformed numbers and ranges raise usage", %{scope: scope, chat: chat, tracker: tracker} do
      for {call, usage} <- [
            {"mw.memory.create(0, 2)", "mw.memory.create(start, finish)"},
            {"mw.memory.create(3, 2)", "mw.memory.create(start, finish)"},
            {"mw.memory.create(1.5, 2)", "mw.memory.create(start, finish)"},
            {"mw.memory.catch_up(1, 6)", "mw.memory.catch_up(start, finish, chunk)"},
            {~s[mw.memory.run_side_prompt("#{tracker.id}", 4, 2)], "mw.memory.run_side_prompt("},
            {~S|mw.memory.set_side_prompt_enabled("all", "yes")|, "mw.memory.set_side_prompt_enabled("},
            {"mw.memory.set_highest(0)", "mw.memory.set_highest(number_or_nil)"},
            {"mw.memory.set_highest(2147483648)", "mw.memory.set_highest(number_or_nil)"},
            {"mw.memory.create(1, 2147483648)", "mw.memory.create(start, finish)"}
          ] do
        assert {%{errors: [error]}, _} = run(scope, chat, call)
        assert error =~ "usage: " <> usage
      end

      assert Jobs.list_jobs(scope, chat_id: chat.id) == []
    end

    test "the queueing functions refuse inside a generation; boundary changes still work", %{scope: scope, chat: chat} do
      script!(scope,
        trigger: :ai_generation,
        body: ~S|mw.memory.set_highest(2) return select(2, mw.memory.next()) .. select(2, mw.memory.create(1, 2))|
      )

      assert %{text: "not_allowednot_allowed", errors: []} = Scripts.run(scope, :ai_generation, chat, %{"text" => "x"})
      assert Memory.chat_settings(scope, chat).highest_processed == 1
      assert Jobs.list_jobs(scope, chat_id: chat.id) == []
    end

    test "off a chat it refuses no_chat; a test run refuses test_run without writing", %{scope: scope, tracker: tracker} do
      script = script!(scope, trigger: :command, body: "return select(2, mw.memory.highest())")
      assert {:ok, "no_chat", []} = Scripts.run_command(scope, script.id, nil, %{})

      body = ~s[return select(2, mw.memory.set_side_prompt_enabled("#{tracker.id}", false))]
      assert %{result: {:ok, "test_run"}} = Scripts.test_run(scope, body, :user_message, "x")
      assert Memory.get_side_prompt(scope, tracker.id).enabled
    end
  end

  describe "regex" do
    test "match, match_all, replace, split, test and escape", %{scope: scope, chat: chat} do
      for {body, expected} <- [
            {~S'local m = regex.match("on 2026-10 ok", "(?<y>\\d{4})-(\\d\\d)(x)?")
                return m.text .. "|" .. m.start .. "|" .. m.finish .. "|" .. m.groups[2] .. "|" .. m.named.y .. "|" .. tostring(m.groups[3])',
             "2026-10|4|10|10|2026|nil"},
            {~S'local s, n = regex.replace("a1b22", "(\\d+)", "<$1>") return s .. n', "a<1>b<22>2"},
            {~S'return (regex.replace("ann-bob", "(?<n>\\w+)", "${n}!", nil, 1))', "ann!-bob"},
            {~S'return (regex.replace("ab", "(a)", "$$$0${1}$9${x}$"))', "$aa$b"},
            {~S'return (regex.replace("x y", "\\w", function(m) return m.text:upper() end))', "X Y"},
            {~S'return tostring(regex.test("HELLO", "hello", "i")) .. tostring(regex.test("HELLO", "hello"))',
             "truefalse"},
            {~S'return table.concat(regex.split("a, b,c", ",\\s*"), "|") .. "/" .. #regex.split("a,b,c", ",", nil, 1)',
             "a|b|c/2"},
            {~S'return table.concat(regex.split(",a", ","), "|") .. "/" .. #regex.split("ab", "")', "|a/2"},
            {~S'local m = regex.match("café!", "\\w+") return m.text .. m.finish', "café5"},
            {~S'return #regex.match_all("a1b2c3", "\\d") .. regex.match("a1b2", "\\d", nil, 3).text', "32"},
            {~S'return regex.match("éa", "\\w", nil, 2).text .. tostring(regex.match("a", "a", nil, 3))', "anil"},
            {~S'return regex.escape("a.b*")', ~S"a\.b\*"}
          ] do
        assert {%{text: ^expected, errors: []}, _} = run(scope, chat, body)
      end
    end

    test "a replacement function's upvalue writes and errors reach the script", %{scope: scope, chat: chat} do
      body = ~S'local n = 0 regex.replace("aaa", "a", function() n = n + 1 end) return tostring(n)'
      assert {%{text: "3", errors: []}, _} = run(scope, chat, body)

      body =
        ~S'local ok, err = pcall(regex.replace, "a", "a", function() error("inner") end) return tostring(ok) .. err'

      assert {%{text: "false" <> err, errors: []}, _} = run(scope, chat, body)
      assert err =~ "inner"
    end

    test "bad patterns, flags and arguments and match-limit overruns fail the script", %{scope: scope, chat: chat} do
      for {body, message} <- [
            {~S'regex.match("x", "(")', "regex: invalid pattern"},
            {~S'regex.test(string.rep("a", 28) .. "b", "(a+)+$")', "match limit exceeded"},
            {~S'regex.test("x", "x", "q")', ~s(unknown flag "q")},
            {~S'regex.replace("x", "x", 5)', "usage: regex.replace"}
          ] do
        assert {%{errors: [_]}, script} = run(scope, chat, body)
        assert script.last_error =~ message
      end
    end
  end
end
