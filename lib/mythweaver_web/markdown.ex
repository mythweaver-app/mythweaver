defmodule MythweaverWeb.Markdown do
  @moduledoc """
  Renders message prose (bodies, reasoning, scratchpads) from markdown to HTML with MDEx.

  The output is already-sanitized HTML: raw HTML in the source is allowed and passes through
  ammonia, so callers wrap the result in `Phoenix.HTML.raw/1` without further escaping.

  Source offsets: every rendered text run is `<span data-o="N">` (inline code `<code data-o="N">`),
  where N is the run's offset into the source in UTF-16 code units, the editor's position unit. A
  backslash escape or an entity makes a run shorter than its source span, so offsets within it drift
  by those few characters; the editor clamps.

  Class hooks: `.md-dialogue` wraps quoted dialogue, quote marks included (rules mirror the editor's
  `Dialogue` parser in `assets/js/hooks/rich_input/languages.ts`); `.md-caret` is the in-flight
  cursor appended with `caret: true`. A `"` written as `\"` or an entity, or straight after feet and
  inches (`6'10"`), is never a quote.

  Streaming: `streaming: true` closes syntax still open at the end, holds back trailing markup whose
  meaning the next token decides (a lone `*`, `- `, `#`, `>`), and draws an unfinished `[…` as the
  bracket text it is so far rather than a link.

  Math: `$…$`, `$$…$$` and `math`/`katex` fences become empty `.katex-inline`/`.katex-block`
  elements carrying `data-latex` and `data-math-style` (`MDExKatex`); `assets/js/katex.ts` renders
  them in the browser. Like comrak's dollar math, `$5 and $10` stays text: a closing `$` must not be
  followed by a digit.

  Styles: raw HTML keeps only `@style_properties` declarations with plain values; positioning,
  sizing, margins and `url()` are dropped, so a message cannot cover the page or load anything.

  Images: an `<img>` whose `src` is `http:`, `https:` or protocol-relative is rewritten to an
  expiring `/remote-images/` link (`MythweaverWeb.RemoteImage`), which the server proxies, redirects
  or refuses per `appearance.remote_images`. Other sources are kept as written.
  """

  alias MythweaverWeb.RemoteImage

  @sanitize Keyword.merge(MDEx.Document.default_sanitize_options(),
              add_tag_attributes: %{
                "span" => ["data-o", "class", "data-latex", "data-math-style"],
                "div" => ["class", "data-latex", "data-math-style"],
                "code" => ["data-o"]
              },
              set_tag_attribute_values: %{"a" => %{"target" => "_blank"}}
            )

  # `hardbreaks`: a single newline in role-play text is an intended line break. `unsafe`: the step's
  # own `HtmlInline` output and the user's raw HTML both need it; ammonia is the only gate.
  # Strikethrough stays off: comrak strikes single `~`, which RP text uses freely.
  @options [
    extension: [table: true, autolink: true, math_dollars: true],
    render: [hardbreaks: true, unsafe: true],
    sanitize: @sanitize
  ]

  @inline_containers [MDEx.Paragraph, MDEx.Heading, MDEx.TableCell]

  @caret %MDEx.HtmlInline{literal: ~s(<span class="md-caret"></span>)}
  @spaced_caret %MDEx.HtmlInline{literal: ~s( <span class="md-caret"></span>)}

  # `MDEx.FragmentParser`'s placeholder URL for a link still arriving.
  @incomplete_link "mdex:incomplete-link"

  # A reply still arriving may end in markup whose meaning the next token decides; drawn now, it
  # shows as literal text or an empty block for one frame and vanishes, so it is left out until text
  # follows it.
  @pending_inline ~r/[*_`\\]+\z/
  @pending_block ~r/^[ \t]*(?:[*+]|-+|=+|[#]{1,6}|>(?:[ \t]*>)*|\d{1,9}[.)])[ \t]*\z/m

  @doc """
  Sanitized HTML for `text`. `streaming: true` treats it as a reply still arriving: it closes syntax
  still open at the end, holds back trailing markup the next token decides, and draws an unfinished
  `[…` as text. `caret: true` ends the output with the in-flight cursor. `nil` renders as `""`.
  """
  @spec to_html(String.t() | nil, keyword()) :: String.t()
  def to_html(text, opts \\ [])

  def to_html(nil, opts), do: to_html("", opts)

  def to_html(text, opts) when is_binary(text) do
    streaming = Keyword.get(opts, :streaming, false)
    text = if streaming, do: hold_back(text), else: text
    lines = line_offsets(text)

    caret_node =
      cond do
        not Keyword.get(opts, :caret, false) -> nil
        String.ends_with?(text, [" ", "\t"]) -> @spaced_caret
        true -> @caret
      end

    ([markdown: text, auto_close: streaming] ++ @options)
    |> MDEx.new()
    |> MDEx.Document.append_steps(mythweaver_markdown: fn doc -> doc |> transform(lines) |> maybe_caret(caret_node) end)
    |> MDExKatex.attach(
      katex_init: "",
      katex_block_attrs: fn _ -> ~s(class="katex-block") end,
      katex_inline_attrs: fn _ -> ~s(class="katex-inline") end
    )
    |> MDEx.to_html()
    |> case do
      {:ok, html} -> html |> filter_styles() |> proxy_images()
      {:error, _} -> "<p>" <> escape(text) <> "</p>"
    end
  end

  defp hold_back(text), do: text |> String.replace(@pending_inline, "") |> String.replace(@pending_block, "")

  # -- Inline styles -------------------------------------------------------------------------------

  @style_properties ~w(color background-color font-weight font-style font-size font-family font-variant
                       text-decoration text-decoration-line text-decoration-color text-decoration-style
                       text-align text-transform text-shadow letter-spacing word-spacing line-height
                       white-space opacity border border-color border-style border-width border-radius
                       padding)
  @style_functions ~w(rgb rgba hsl hsla calc var)

  # Sound only on ammonia's output: text escapes `<` to `&lt;`, comments and script/style are
  # stripped, and every attribute is serialized as `name="value"` with `"` escaped, so these match
  # exactly the open tags and their style attributes.
  @open_tag ~r/<[a-zA-Z][a-zA-Z0-9-]*(?:\s+[^\s"'>\/=]+="[^"]*")*/
  @style_attr ~r/\sstyle="([^"]*)"/
  # No `&` (so no entity-encoded quotes), `\` (CSS escapes), `/`, `*`, `!`, `:`, `@` or `"`.
  @style_value ~r/\A[a-zA-Z0-9#%.,\s()+\-']*\z/
  @style_call ~r/([a-zA-Z-]+)\(/

  defp filter_styles(html) do
    if String.contains?(html, ~s( style=")),
      do: Regex.replace(@open_tag, html, fn tag -> Regex.replace(@style_attr, tag, &style/2) end),
      else: html
  end

  defp style(_whole, value) do
    kept =
      for declaration <- String.split(value, ";"),
          [prop, val] <- [String.split(declaration, ":", parts: 2)],
          prop = prop |> String.trim() |> String.downcase(),
          prop in @style_properties and safe_style_value?(val),
          do: "#{prop}: #{String.trim(val)}"

    if kept == [], do: "", else: ~s( style=") <> Enum.join(kept, "; ") <> ~s(")
  end

  defp safe_style_value?(val) do
    Regex.match?(@style_value, val) and
      @style_call
      |> Regex.scan(val, capture: :all_but_first)
      |> Enum.all?(fn [name] -> String.downcase(name) in @style_functions end)
  end

  # -- Remote images -------------------------------------------------------------------------------

  # Sound on ammonia's output for the reason `@open_tag`'s comment gives.
  @img_src ~r/(<img\b[^>]*?\ssrc=")([^"]*)(")/
  @url_noise ~r/[\t\n\r]|\A[\x00-\x20]+|[\x00-\x20]+\z/
  @scheme_relative ~r|\A[/\\]{2}|
  @http_url ~r/\A(https?):(.*)\z/is
  @leading_slashes ~r|\A[/\\]+|

  defp proxy_images(html) do
    if String.contains?(html, "<img"),
      do: Regex.replace(@img_src, html, fn _, open, src, close -> open <> image_src(src) <> close end),
      else: html
  end

  defp image_src(src) do
    src
    |> unescape()
    |> remote_url()
    |> case do
      nil -> src
      url -> RemoteImage.path(url)
    end
  end

  # The http(s) URL a browser would fetch for `src`, as `scheme://rest` with the scheme lowercased,
  # or nil for a local one. Like WHATWG URL parsing, it drops tabs and newlines anywhere and C0
  # controls and spaces at either end, reads the scheme case-insensitively, and takes any run of
  # `/` or `\` after it (or none) as `//`; a scheme-relative URL is https.
  defp remote_url(src) do
    url = Regex.replace(@url_noise, src, "")

    cond do
      String.match?(url, @scheme_relative) -> "https://" <> strip_slashes(url)
      match = Regex.run(@http_url, url) -> scheme_url(match)
      true -> nil
    end
  end

  defp scheme_url([_url, scheme, rest]), do: String.downcase(scheme) <> "://" <> strip_slashes(rest)

  defp strip_slashes(url), do: String.replace(url, @leading_slashes, "")

  defp unescape(value) do
    value
    |> String.replace("&quot;", ~s("))
    |> String.replace("&#39;", "'")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&amp;", "&")
  end

  # -- Source offsets ------------------------------------------------------------------------------

  # `{line_binary, utf16_start}` per `\n`-separated line, indexed by 0-based line number.
  defp line_offsets(text) do
    text
    |> String.split("\n")
    |> Enum.map_reduce(0, fn line, start -> {{line, start}, start + utf16_length(line) + 1} end)
    |> elem(0)
    |> List.to_tuple()
  end

  # `col` is MDEx's 1-based byte column.
  defp offset(lines, {line, col}) when line >= 1 and line <= tuple_size(lines) and col >= 1 do
    {bin, start} = elem(lines, line - 1)
    start + utf16_length(binary_part(bin, 0, min(col - 1, byte_size(bin))))
  end

  defp offset(_lines, _pos), do: nil

  # The source from 1-based `line` / byte `col` to the end of the text.
  defp source_from(lines, {line, col}) when line >= 1 and line <= tuple_size(lines) do
    {bin, _start} = elem(lines, line - 1)
    skip = min(max(col - 1, 0), byte_size(bin))
    later = for i <- line..(tuple_size(lines) - 1)//1, do: lines |> elem(i) |> elem(0)
    Enum.join([binary_part(bin, skip, byte_size(bin) - skip) | later], "\n")
  end

  defp source_from(_lines, _pos), do: ""

  defp utf16_length(bin), do: utf16_length(bin, 0)

  defp utf16_length(<<c::utf8, rest::binary>>, n) when c > 0xFFFF, do: utf16_length(rest, n + 2)
  defp utf16_length(<<_c::utf8, rest::binary>>, n), do: utf16_length(rest, n + 1)
  defp utf16_length(_tail, n), do: n

  # -- AST transform -------------------------------------------------------------------------------

  # comrak builds `alt` from the child text, so an image's children must stay `Text`.
  defp transform(%MDEx.Image{} = node, _lines), do: node

  defp transform(%MDEx.Text{literal: literal, sourcepos: pos}, lines),
    do: {:run, literal, pos && offset(lines, pos.start), quote_marks(lines, pos, literal)}

  defp transform(%MDEx.Code{literal: literal, num_backticks: n, sourcepos: pos}, lines) do
    open =
      case pos && offset(lines, pos.start) do
        nil -> "<code>"
        o -> ~s(<code data-o="#{o + n}">)
      end

    %MDEx.HtmlInline{literal: open <> escape(literal) <> "</code>"}
  end

  defp transform(%{nodes: nodes} = node, lines) do
    nodes =
      nodes
      |> Enum.flat_map(&unlink(&1, lines))
      |> Enum.map(&transform(&1, lines))
      |> dialogue()
      |> Enum.map(&emit/1)

    %{node | nodes: nodes}
  end

  defp transform(node, _lines), do: node

  defp emit({:run, text, nil}), do: %MDEx.HtmlInline{literal: escape(text)}

  defp emit({:run, text, o}), do: %MDEx.HtmlInline{literal: ~s(<span data-o="#{o}">) <> escape(text) <> "</span>"}

  defp emit(:open), do: %MDEx.HtmlInline{literal: ~s(<span class="md-dialogue">)}
  defp emit(:close), do: %MDEx.HtmlInline{literal: "</span>"}
  defp emit(node), do: node

  # An auto-closed `[…` is shown as the bracket text it is so far (RP's `[OOC: …]`), unless `](` has
  # arrived, which makes it a link.
  defp unlink(
         %MDEx.Link{url: @incomplete_link, nodes: children, sourcepos: %MDEx.Sourcepos{start: start}} = link,
         lines
       ) do
    rest = source_from(lines, start)

    if String.contains?(rest, "](") do
      [link]
    else
      close = if String.ends_with?(String.trim_trailing(rest), "]"), do: [%MDEx.Text{literal: "]"}], else: []
      [%MDEx.Text{literal: "[", sourcepos: %MDEx.Sourcepos{start: start, end: start}} | children] ++ close
    end
  end

  defp unlink(node, _lines), do: [node]

  # -- Dialogue ------------------------------------------------------------------------------------

  # Pairs quotes among one sibling list's runs, so the opening and closing span share a parent; a
  # nested list (an `Emph`'s children) pairs on its own. An unclosed quote closes at the end of the
  # list: multi-paragraph speech leaves each paragraph's quote open.
  defp dialogue(nodes) do
    {acc, open?} = dialogue(nodes, :none, false, [])
    acc = if open?, do: [:close | acc], else: acc
    Enum.reverse(acc)
  end

  defp dialogue([], _before, open?, acc), do: {acc, open?}

  defp dialogue([{:run, text, o, marks} | rest], before, open?, acc) do
    st = %{o: o, open?: open?, acc: acc, piece: [], start: 0, marks: marks, seen: []}
    {st, last} = quotes(text, before, first_kind(rest), 0, st)
    dialogue(rest, last, st.open?, st.acc)
  end

  defp dialogue([node | rest], _before, open?, acc), do: dialogue(rest, node_kind(node), open?, [node | acc])

  defp first_kind([]), do: :none
  defp first_kind([{:run, <<c::utf8, _::binary>>, _, _} | _]), do: char_kind(c)
  defp first_kind([{:run, _, _, _} | rest]), do: first_kind(rest)
  defp first_kind([node | _]), do: node_kind(node)

  defp node_kind(%MDEx.SoftBreak{}), do: :space
  defp node_kind(%MDEx.LineBreak{}), do: :space
  defp node_kind(_node), do: :other

  defp char_kind(c), do: if(String.match?(<<c::utf8>>, ~r/\s/u), do: :space, else: :other)

  # `prev` is the kind of the character before `c`; `i` is `c`'s UTF-16 position in the run.
  defp quotes(<<c::utf8, rest::binary>>, prev, next_kind, i, st) do
    after_kind =
      case rest do
        <<n::utf8, _::binary>> -> char_kind(n)
        _ -> next_kind
      end

    w = if c > 0xFFFF, do: 2, else: 1
    {typed?, st} = if c == ?", do: next_mark(st), else: {true, st}

    st =
      cond do
        c == ?" and (not typed? or inch?(st.seen)) -> %{st | piece: [c | st.piece]}
        c == ?" and st.open? and prev == :other -> close_quote(st, c, i + w)
        c == ?" and not st.open? and after_kind == :other -> open_quote(st, c, i)
        c == 0x201C and not st.open? -> open_quote(st, c, i)
        c == 0x201D and st.open? -> close_quote(st, c, i + w)
        true -> %{st | piece: [c | st.piece]}
      end

    quotes(rest, char_kind(c), next_kind, i + w, %{st | seen: [c | st.seen]})
  end

  defp quotes(_tail, prev, _next_kind, _i, st), do: {flush(st), prev}

  defp next_mark(%{marks: [typed? | rest]} = st), do: {typed?, %{st | marks: rest}}
  defp next_mark(st), do: {true, st}

  # An inch mark, not a quote: `"` straight after feet and inches (`6'10"`, `5′ 11"`). `seen` is the
  # run so far, reversed.
  defp inch?(seen) do
    case Enum.split_while(seen, &(&1 in ?0..?9)) do
      {[_ | _], [?\s, mark, feet | _]} -> mark in [?', 0x2032] and feet in ?0..?9
      {[_ | _], [mark, feet | _]} -> mark in [?', 0x2032] and feet in ?0..?9
      _ -> false
    end
  end

  # One entry per `"` in a run's literal, in order: `true` for a typed `"`, `false` for one written
  # as `\"` or an entity, which never opens or closes dialogue. `nil` (every `"` typed) when the
  # run's source slice is unavailable or does not line up with the literal.
  defp quote_marks(lines, %MDEx.Sourcepos{start: {line, first}, end: {line, last}}, literal)
       when line >= 1 and line <= tuple_size(lines) and first >= 1 and last >= first do
    {bin, _start} = elem(lines, line - 1)

    if last <= byte_size(bin) do
      marks =
        for [token] <-
              Regex.scan(
                ~r/\\[!-\/:-@\[-`{-~]|&(?:quot|QUOT|#0*34|#[xX]0*22);|"/,
                binary_part(bin, first - 1, last - first + 1)
              ),
            token == ~s(") or not String.starts_with?(token, "\\") or token == ~S(\"),
            do: token == ~s(")

      if length(marks) == length(:binary.matches(literal, ~s("))), do: marks
    end
  end

  defp quote_marks(_lines, _pos, _literal), do: nil

  # The quote mark stays inside the span, so copy and clip keep it.
  defp open_quote(st, c, i) do
    st = flush(st)
    %{st | acc: [:open | st.acc], open?: true, piece: [c], start: i}
  end

  defp close_quote(st, c, next_start) do
    st = flush(%{st | piece: [c | st.piece]})
    %{st | acc: [:close | st.acc], open?: false, start: next_start}
  end

  defp flush(%{piece: []} = st), do: st

  defp flush(st) do
    text = st.piece |> Enum.reverse() |> List.to_string()
    run = {:run, text, st.o && st.o + st.start}
    %{st | acc: [run | st.acc], piece: []}
  end

  # -- Caret ---------------------------------------------------------------------------------------

  defp maybe_caret(doc, nil), do: doc

  defp maybe_caret(doc, caret) do
    case caret_into(doc, caret) do
      :none -> %{doc | nodes: doc.nodes ++ [%MDEx.Paragraph{nodes: [caret]}]}
      doc -> doc
    end
  end

  defp caret_into(%mod{nodes: nodes} = node, caret) when mod in @inline_containers,
    do: %{node | nodes: nodes ++ [caret]}

  defp caret_into(%{nodes: [_ | _] = nodes} = node, caret) do
    {init, [last]} = Enum.split(nodes, -1)

    case caret_into(last, caret) do
      :none -> :none
      last -> %{node | nodes: init ++ [last]}
    end
  end

  defp caret_into(_node, _caret), do: :none

  defp escape(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
