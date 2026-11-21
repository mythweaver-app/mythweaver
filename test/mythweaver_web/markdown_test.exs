defmodule MythweaverWeb.MarkdownTest do
  use ExUnit.Case, async: true

  alias MythweaverWeb.Markdown

  defp doc(text, opts \\ []), do: text |> Markdown.to_html(opts) |> LazyHTML.from_fragment()

  defp texts(doc, selector), do: doc |> LazyHTML.query(selector) |> Enum.map(&LazyHTML.text/1)

  defp present?(doc, selector), do: doc |> LazyHTML.query(selector) |> Enum.any?()

  describe "dialogue" do
    test "a quote spans nested emphasis, quote marks included" do
      d = doc(~s(She said "hi *there*" and left.))

      assert texts(d, ".md-dialogue") == [~s("hi there")]
      assert present?(d, ".md-dialogue em")
    end

    test "an unclosed quote closes at the end of its paragraph" do
      d = doc(~s("Run!\n\nShe ran.))

      assert texts(d, "p:nth-of-type(1) .md-dialogue") == [~s("Run!)]
      refute present?(d, "p:nth-of-type(2) .md-dialogue")
    end

    test "a straight quote after a non-space does not open; curly quotes pair" do
      refute present?(doc(~s(He is 5" tall)), ".md-dialogue")
      assert texts(doc("“hi”"), ".md-dialogue") == ["“hi”"]
    end

    test "an inch mark after feet and inches neither closes nor opens a quote" do
      assert texts(doc(~S|"She said he was 6'10", very tall if you ask me"|), ".md-dialogue") ==
               [~S|"She said he was 6'10", very tall if you ask me"|]

      assert texts(doc(~S|"About 5′ 11" barefoot" she said|), ".md-dialogue") == [~S|"About 5′ 11" barefoot"|]
      assert texts(doc(~S|"He's 6'10""|), ".md-dialogue") == [~S|"He's 6'10""|]
    end

    test "an escaped or entity quote is literal, while an escaped backslash before one is not" do
      assert texts(doc(~S|"A 10\" blade, he said"|), ".md-dialogue") == [~S|"A 10" blade, he said"|]
      assert texts(doc(~S|"A 10&quot; blade" it was|), ".md-dialogue") == [~S|"A 10" blade"|]
      assert texts(doc(~S|"path C:\\" ok|), ".md-dialogue") == [~S|"path C:\"|]
    end
  end

  describe "source offsets" do
    test "runs carry UTF-16 offsets across lines and multibyte characters" do
      d = doc("Él\n*wörld*")

      assert texts(d, "span[data-o='0']") == ["Él"]
      assert texts(d, "em span[data-o='4']") == ["wörld"]
    end

    test "inline code offsets point past the backticks, counting astral characters as two" do
      assert texts(doc("a 😀 `x`"), "code[data-o='6']") == ["x"]
    end
  end

  describe "raw HTML" do
    test "is sanitized: scripts, handlers and javascript: hrefs go, safe styles stay, links open new tabs" do
      # The script needs a paragraph of its own: text after it on its line joins its HTML block.
      d = doc("<script>x</script>\n\n" <> ~S|<span onclick="x" style="color:red">y</span> [l](javascript:x)|)

      refute present?(d, "script")
      refute present?(d, "[onclick]")
      assert present?(d, "span[style]")
      assert present?(d, "a[target='_blank']")
      refute present?(d, "a[href]")
    end

    test "keeps classed blocks" do
      assert present?(doc(~s(<div class="status">HP 10</div>)), "div.status")
    end

    test "styles keep only safe properties with plain values" do
      d = doc(~S|<span style="position:fixed;top:0;color:red;background:url(https://x.test/a)">y</span>|)
      assert present?(d, "span[style='color: red']")

      refute present?(doc(~S|<div style="background-image:url(x)">z</div>|), "[style]")
      refute present?(doc(~S|<span style="color:\72 ed">z</span>|), "[style]")
    end
  end

  describe "streaming" do
    test "closes open syntax" do
      assert present?(doc("**bo", streaming: true), "strong")
      refute present?(doc("**bo"), "strong")
    end

    test "holds back trailing markup the next token decides" do
      for {input, visible, absent} <- [
            {"_", "", nil},
            {"Hi **", "Hi", nil},
            {~s("Hello," *), ~s("Hello,"), nil},
            {"a\n\n*", "a", "ul"},
            {"a\n\n- ", "a", "ul"},
            {"a\n\n#", "a", "h1"},
            {"a\n\n1.", "a", nil},
            {"a\n-", "a", "h2"},
            {"> ", "", "blockquote"},
            {"a\\", "a", nil}
          ] do
        d = doc(input, streaming: true)
        assert String.trim(LazyHTML.text(d)) == visible, "#{inspect(input)} showed #{inspect(LazyHTML.text(d))}"
        if absent, do: refute(present?(d, absent), "#{inspect(input)} rendered #{absent}")
      end
    end

    test "holds nothing back once the text is final" do
      assert present?(doc("a\n\n- "), "ul")
      assert present?(doc("a\n-"), "h2")
    end

    test "an unfinished bracket stays text until `](` makes it a link" do
      d = doc("[OOC: hello", streaming: true)
      assert LazyHTML.text(d) == "[OOC: hello"
      refute present?(d, "a")

      assert LazyHTML.text(doc("[OOC: hello]", streaming: true)) == "[OOC: hello]"
      assert present?(doc("[a](htt", streaming: true), "a")
    end

    test "the caret keeps a trailing space before it" do
      assert LazyHTML.text(doc("word ", streaming: true, caret: true)) == "word "
      assert LazyHTML.text(doc("word", streaming: true, caret: true)) == "word"
    end
  end

  test "the caret lands in the last inline container, or a paragraph of its own" do
    assert present?(doc("a\n\n- b", caret: true), "li .md-caret")
    assert present?(doc("", caret: true), "p > .md-caret")
    assert Markdown.to_html(nil) == ""
  end

  test "single tildes are not strikethrough" do
    refute present?(doc("Hey~ there~"), "del")
  end

  test "math survives sanitizing as KaTeX placeholders; prices stay text" do
    d = doc("Euler $e^{i}$ paid $5 and $10\n\n```math\nE=mc^2\n```")
    assert present?(d, ~s(span.katex-inline[data-math-style="inline"][data-latex="e^{i}"]))
    assert present?(d, ~s(div.katex-block[data-math-style="display"][data-latex="E=mc^2"]))
    assert d |> LazyHTML.query(".katex-inline") |> Enum.count() == 1
    refute present?(d, "script, link")
  end

  describe "remote images" do
    defp src(doc), do: doc |> LazyHTML.query("img") |> LazyHTML.attribute("src") |> hd()

    test "a markdown image goes through the proxy" do
      assert present?(doc("![a](https://x.test/i.png)"), "img[src^='/remote-images/']")
    end

    test "a raw image's entities are decoded before sealing" do
      d = doc(~s(<img src="https://x.test/a.png?x=1&amp;y=2">))
      assert present?(d, "img[src^='/remote-images/']")
      "/remote-images/" <> token = src(d)
      assert {:ok, "https://x.test/a.png?x=1&y=2", _expires_at} = MythweaverWeb.RemoteImage.open(token)
    end

    test "the scheme is read case-insensitively and sealed lowercased" do
      for {raw, url} <- [
            {"HTTPS://x.test/a.png", "https://x.test/a.png"},
            {"Http://x.test/a.png", "http://x.test/a.png"},
            {"//x.test/a.png", "https://x.test/a.png"}
          ] do
        "/remote-images/" <> token = src(doc(~s(<img src="#{raw}">)))
        assert {:ok, ^url, _expires_at} = MythweaverWeb.RemoteImage.open(token), raw
      end
    end

    test "a local image is unchanged" do
      assert src(doc(~s(<img src="/local.png">))) == "/local.png"
    end
  end
end
