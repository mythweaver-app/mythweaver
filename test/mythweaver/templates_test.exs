defmodule Mythweaver.TemplatesTest do
  use ExUnit.Case, async: true

  alias Mythweaver.Templates
  alias Mythweaver.Templates.State

  defp state(data \\ %{}, vars \\ %{chat: %{}, global: %{}}, seed \\ "c1"), do: State.new(data, vars, seed)

  describe "render/3" do
    test "standard filters work next to the custom ones" do
      assert {"Hi ANN", _, []} =
               Templates.render(
                 "Hi {{ anchors.character.name | upcase }}",
                 state(%{"anchors" => %{"character" => %{"name" => "Ann"}}})
               )
    end

    test "char and user render empty without anchors" do
      assert {"[]", _, []} = Templates.render("[{{char}}{{user}}]", state())
    end

    test "iterates lists" do
      data = %{"anchors" => %{"chat" => %{"members" => [%{"name" => "A"}, %{"name" => "B"}]}}}

      source =
        "{% for p in anchors.chat.members %}{{ p.name }}{% unless forloop.last %}, {% endunless %}{% endfor %}"

      assert {"A, B", _, []} = Templates.render(source, state(data))
    end

    test "setvar is visible in the same and later renders, and nil deletes" do
      {text, state, []} = Templates.render(~s({% setvar mood = "calm" %}{{ vars.mood }}), state())

      assert text == "calm"
      assert State.writes(state) == [%{"scope" => "chat", "key" => "mood", "value" => "calm"}]
      assert {"calm", _, []} = Templates.render("{{ vars.mood }}", state)

      {"", state, []} = Templates.render("{% setvar mood = nil %}", state)
      refute Map.has_key?(state.chat_vars, "mood")
      assert List.last(State.writes(state)) == %{"scope" => "chat", "key" => "mood", "value" => nil}
    end

    test "a chat variable shadows a global one in vars but not in globals" do
      {_, state, []} = Templates.render("{% setglobalvar g = 1 %}{% setvar g = 2 %}", state())

      assert {"2/1", _, []} = Templates.render("{{ vars.g }}/{{ globals.g }}", state)
      assert [%{"scope" => "global"}, %{"scope" => "chat"}] = State.writes(state)
    end

    test "assign carries across renders" do
      {_, state, []} = Templates.render("{% assign x = 3 %}", state())
      assert {"3", _, []} = Templates.render("{{ x }}", state)
    end

    test "a non-identifier setvar key is a syntax error" do
      assert {_, _, ["Template syntax error: " <> _]} =
               Templates.render("{% setvar true = 1 %}", state())
    end

    test "a syntax error returns the raw source and the input state" do
      input = state()

      assert {"{% if %}", ^input, ["Template syntax error: line 1" <> _]} =
               Templates.render("{% if %}", input)
    end

    test "a slow template times out" do
      source = "{% for i in (1..100000000) %}x{% endfor %}"
      input = state()

      assert {^source, ^input, ["Template took longer than 50 ms."]} =
               Templates.render(source, input, timeout: 50, max_heap_words: 10_000_000)
    end

    test "a memory-hungry template is killed" do
      source = "{% for i in (1..100000000) %}x{% endfor %}"
      input = state()

      assert {^source, ^input, ["Template exceeded its memory limit."]} =
               Templates.render(source, input, timeout: 5_000, max_heap_words: 50_000)
    end

    test "pick is stable for the same seed and source" do
      data = %{"list" => Enum.to_list(1..100)}
      source = "{{ list | pick }}"

      {first, _, []} = Templates.render(source, state(data))
      assert {^first, _, []} = Templates.render(source, state(data))
    end

    test "roll sums dice and reports bad dice" do
      {text, _, []} = Templates.render(~s({{ "1d6" | roll }}), state())
      assert String.to_integer(text) in 1..6

      {text, _, []} = Templates.render(~s({{ "2d1+3" | roll }}), state())
      assert text == "5"

      {text, _, []} = Templates.render(~s({{ "d1+2" | roll }}), state())
      assert text == "3"

      {text, _, []} = Templates.render(~s({{ "D1" | roll }}), state())
      assert text == "1"

      assert {_, _, [error]} = Templates.render(~s({{ "x" | roll }}), state())
      assert error =~ "roll expects dice"
    end

    test "push appends, starting from nil" do
      assert {"1,2", _, []} =
               Templates.render(~s({% assign l = nil | push: 1 | push: 2 %}{{ l | join: "," }}), state())
    end

    test "to_sentence joins with a serial comma, and two items with a bare and" do
      render = fn list -> Templates.render("{{ l | to_sentence }}", state(%{"l" => list})) end

      assert {"a, b, c, and d", _, []} = render.(["a", "b", "c", "d"])
      assert {"a, b, and c", _, []} = render.(["a", "b", "c"])
      assert {"a and b", _, []} = render.(["a", "b"])
      assert {"a", _, []} = render.(["a"])
      assert {"", _, []} = render.([])
      assert {"1, 2, and 3", _, []} = render.([1, 2, 3])
      assert {"", _, []} = Templates.render("{{ missing | to_sentence }}", state())
      assert {_, _, [error]} = render.("abc")
      assert error =~ "to_sentence expects an array"
    end

    test "render tag is disabled" do
      assert {_, _, ["Template syntax error: " <> _]} = Templates.render(~s({% render "x" %}), state())
    end

    test "plain text is returned as is" do
      refute Templates.template?("plain text")
      assert {"plain text", _, []} = Templates.render("plain text", state())
    end
  end

  describe "render_many/3" do
    test "renders each source against the same state, in order; assigns don't carry over" do
      assert [{"X", []}, {"plain", []}, {"1", []}, {"", []}] =
               Templates.render_many(
                 ["{{ x }}", "plain", "{% assign y = 1 %}{{ y }}", "{{ y }}"],
                 state(%{"x" => "X"})
               )
    end

    test "a syntax error fails only its own source" do
      assert [{"{% if %}", ["Template syntax error: line 1" <> _]}, {"ok", []}] =
               Templates.render_many(["{% if %}", "{{ 'ok' }}"], state())
    end

    test "a timeout fails every template source in the batch" do
      slow = "{% for i in (1..100000000) %}x{% endfor %}"
      error = "Template took longer than 50 ms."

      assert [{^slow, [^error]}, {"{{ 1 }}", [^error]}, {"plain", []}] =
               Templates.render_many([slow, "{{ 1 }}", "plain"], state(), timeout: 50, max_heap_words: 10_000_000)
    end
  end
end
