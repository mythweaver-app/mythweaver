defmodule Mythweaver.Lore.MatcherTest do
  use ExUnit.Case, async: true

  alias Mythweaver.Lore.Matcher

  describe "match?/3 with literal keywords" do
    test "whole-word, case-insensitive keyword matches a differently cased word" do
      assert Matcher.match?("the Dragon roars", "dragon",
               case_sensitive: false,
               whole_words: true
             )
    end

    test "case_sensitive: true rejects a differently cased word" do
      refute Matcher.match?("the Dragon roars", "dragon",
               case_sensitive: true,
               whole_words: true
             )
    end

    test "whole_words: true rejects a keyword embedded in a longer word" do
      refute Matcher.match?("dragonfly", "dragon", case_sensitive: false, whole_words: true)
    end

    test "whole_words: false accepts a keyword embedded in a longer word" do
      assert Matcher.match?("dragonfly", "dragon", case_sensitive: false, whole_words: false)
    end

    test "multi-word keyword with whole_words: true falls back to substring matching" do
      assert Matcher.match?("a red dragon", "red dragon",
               case_sensitive: false,
               whole_words: true
             )
    end

    test "the ASCII boundary matches a CJK key inside a sentence; the Unicode one doesn't" do
      assert Matcher.match?("この竜は強い", "竜", whole_words: true, boundary: :ascii)
      refute Matcher.match?("この竜は強い", "竜", whole_words: true, boundary: :unicode)
    end

    test "the ASCII boundary still keeps a key out of a longer ASCII word" do
      refute Matcher.match?("two dragons", "dragon", whole_words: true, boundary: :ascii)
    end
  end

  describe "match?/3 with /regex/flags keywords" do
    test "the regex's own flags override both case_sensitive and whole_words options" do
      # `case_sensitive: true` and `whole_words: true` would both reject this if they applied:
      # the haystack capitalises the word and suffixes it with "s!".
      assert Matcher.match?("Dragons!", "/dr[ao]gon/i",
               case_sensitive: true,
               whole_words: true
             )
    end
  end

  describe "compile/2" do
    test "compiles a /source/flags keyword to a regex" do
      assert {:regex, %Regex{}} = Matcher.compile("/dragon/i", [])
    end

    test "an uncompilable regex keyword degrades to a literal instead of raising" do
      assert {:literal, "/(/"} = Matcher.compile("/(/", [])
    end

    test "a key with an unescaped slash inside is a literal, as in SillyTavern" do
      assert Matcher.parse_regex("/r/roleplay") == :literal
      assert Matcher.match?("see /r/roleplay", "/r/roleplay", whole_words: true)
    end

    test "JavaScript's g and y flags are dropped" do
      assert {:ok, regex} = Matcher.parse_regex("/dragon/gi")
      assert Regex.match?(regex, "A DRAGON")
      assert {:ok, _regex} = Matcher.parse_regex("/dragon/y")
    end

    test "a key with flags JavaScript lacks is a literal, as in SillyTavern" do
      assert Matcher.parse_regex("/x/v") == :literal
      assert Matcher.parse_regex("/dragon/q") == :literal
      assert Matcher.parse_regex("/x/1") == :literal
    end
  end
end
