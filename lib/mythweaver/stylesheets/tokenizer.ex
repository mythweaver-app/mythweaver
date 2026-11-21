defmodule Mythweaver.Stylesheets.Tokenizer do
  @moduledoc """
  A CSS Syntax Level 3 tokenizer (https://drafts.csswg.org/css-syntax/#tokenization), used to
  check a stylesheet (`Mythweaver.Stylesheets.Policy`), never to rewrite one.

  It follows §4's "consume …" algorithms code point for code point, so it splits a sheet exactly
  where a browser does: tokenization does not depend on context, which is what makes checking
  these tokens sound. Names and values come back with their escapes decoded (`\\75 rl(` is
  `{:function, "url"}`). Numbers carry no value, only their extent; a dimension keeps its unit.
  Comments are dropped.
  """

  @type token ::
          {:ident | :function | :at_keyword | :hash | :string | :url | :dimension, String.t()}
          | {:delim, non_neg_integer()}
          | :bad_string
          | :bad_url
          | :number
          | :percentage
          | :whitespace
          | :cdo
          | :cdc
          | :colon
          | :semicolon
          | :comma
          | :open_paren
          | :close_paren
          | :open_bracket
          | :close_bracket
          | :open_brace
          | :close_brace

  defguardp is_digit(c) when c in ?0..?9
  defguardp is_hex(c) when c in ?0..?9 or c in ?a..?f or c in ?A..?F
  defguardp is_ident_start(c) when c in ?a..?z or c in ?A..?Z or c == ?_ or c >= 0x80
  defguardp is_ident_char(c) when is_ident_start(c) or is_digit(c) or c == ?-
  defguardp is_ws(c) when c in [?\s, ?\t, ?\n]

  defguardp is_non_printable(c)
            when c in 0x00..0x08 or c == 0x0B or c in 0x0E..0x1F or c == 0x7F

  @simple %{
    ?( => :open_paren,
    ?) => :close_paren,
    ?[ => :open_bracket,
    ?] => :close_bracket,
    ?{ => :open_brace,
    ?} => :close_brace,
    ?, => :comma,
    ?: => :colon,
    ?; => :semicolon
  }

  @doc """
  Tokenizes `css`, after §3.3's preprocessing (newlines normalized, NUL to U+FFFD). Bytes that are
  not UTF-8 become U+FFFD first, as a browser decoding the sheet as UTF-8 would.
  """
  @spec tokenize(String.t()) :: [token()]
  def tokenize(css) when is_binary(css) do
    css
    |> String.replace_invalid()
    |> String.replace(["\r\n", "\r", "\f"], "\n")
    |> String.replace(<<0>>, "\uFFFD")
    |> consume([])
  end

  # §4.3.1 consume a token
  defp consume("", acc), do: Enum.reverse(acc)
  defp consume("/*" <> rest, acc), do: consume(skip_comment(rest), acc)
  defp consume(<<c, _::binary>> = s, acc) when is_ws(c), do: consume(skip_ws(s), [:whitespace | acc])

  defp consume(<<q, rest::binary>>, acc) when q in [?", ?'] do
    {token, rest} = string(rest, q, [])
    consume(rest, [token | acc])
  end

  defp consume(<<?#, rest::binary>>, acc) do
    if hash_start?(rest) do
      {name, rest} = ident_sequence(rest, [])
      consume(rest, [{:hash, name} | acc])
    else
      consume(rest, [{:delim, ?#} | acc])
    end
  end

  defp consume(<<c, rest::binary>> = s, acc) when c in [?+, ?.] do
    if starts_number?(s), do: numeric(s, acc), else: consume(rest, [{:delim, c} | acc])
  end

  defp consume(<<?-, rest::binary>> = s, acc) do
    cond do
      starts_number?(s) -> numeric(s, acc)
      match?("->" <> _, rest) -> consume(binary_part(rest, 2, byte_size(rest) - 2), [:cdc | acc])
      starts_ident?(s) -> ident_like(s, acc)
      true -> consume(rest, [{:delim, ?-} | acc])
    end
  end

  defp consume("<!--" <> rest, acc), do: consume(rest, [:cdo | acc])

  defp consume(<<?@, rest::binary>>, acc) do
    if starts_ident?(rest) do
      {name, rest} = ident_sequence(rest, [])
      consume(rest, [{:at_keyword, name} | acc])
    else
      consume(rest, [{:delim, ?@} | acc])
    end
  end

  defp consume(<<?\\, rest::binary>> = s, acc) do
    if valid_escape?(s), do: ident_like(s, acc), else: consume(rest, [{:delim, ?\\} | acc])
  end

  defp consume(<<c, rest::binary>>, acc) when is_map_key(@simple, c), do: consume(rest, [Map.fetch!(@simple, c) | acc])

  defp consume(<<c, _::binary>> = s, acc) when is_digit(c), do: numeric(s, acc)
  defp consume(<<c, _::binary>> = s, acc) when is_ident_start(c) and c < 0x80, do: ident_like(s, acc)

  defp consume(<<c::utf8, rest::binary>> = s, acc) do
    if is_ident_start(c), do: ident_like(s, acc), else: consume(rest, [{:delim, c} | acc])
  end

  defp skip_comment(s) do
    case :binary.match(s, "*/") do
      {pos, 2} -> binary_part(s, pos + 2, byte_size(s) - pos - 2)
      :nomatch -> ""
    end
  end

  defp skip_ws(<<c, rest::binary>>) when is_ws(c), do: skip_ws(rest)
  defp skip_ws(s), do: s

  # §4.3.8 two code points are a valid escape
  defp valid_escape?(<<?\\, ?\n, _::binary>>), do: false
  defp valid_escape?(<<?\\, _::binary>>), do: true
  defp valid_escape?(_), do: false

  defp hash_start?(<<c::utf8, _::binary>>) when is_ident_char(c), do: true
  defp hash_start?(s), do: valid_escape?(s)

  # §4.3.9 three code points would start an ident sequence
  defp starts_ident?(<<?-, c, _::binary>>) when is_ident_start(c) or c == ?-, do: true
  defp starts_ident?(<<?-, rest::binary>>), do: valid_escape?(rest)
  defp starts_ident?(<<c, _::binary>>) when is_ident_start(c), do: true
  defp starts_ident?(s), do: valid_escape?(s)

  # §4.3.10 three code points would start a number
  defp starts_number?(<<s, d, _::binary>>) when s in [?+, ?-] and is_digit(d), do: true
  defp starts_number?(<<s, ?., d, _::binary>>) when s in [?+, ?-] and is_digit(d), do: true
  defp starts_number?(<<?., d, _::binary>>) when is_digit(d), do: true
  defp starts_number?(<<d, _::binary>>) when is_digit(d), do: true
  defp starts_number?(_), do: false

  # §4.3.7 consume an escaped code point; `s` follows the backslash.
  defp escape(""), do: {0xFFFD, ""}

  defp escape(<<h, _::binary>> = s) when is_hex(h) do
    {hex, rest} = hex_digits(s, [], 0)
    rest = with <<c, r::binary>> when is_ws(c) <- rest, do: r
    cp = String.to_integer(hex, 16)
    {if(cp == 0 or cp in 0xD800..0xDFFF or cp > 0x10FFFF, do: 0xFFFD, else: cp), rest}
  end

  defp escape(<<c::utf8, rest::binary>>), do: {c, rest}

  defp hex_digits(<<h, rest::binary>>, acc, n) when is_hex(h) and n < 6, do: hex_digits(rest, [acc, h], n + 1)

  defp hex_digits(rest, acc, _n), do: {IO.iodata_to_binary(acc), rest}

  # §4.3.11 consume an ident sequence
  defp ident_sequence(<<c::utf8, rest::binary>>, acc) when is_ident_char(c),
    do: ident_sequence(rest, [acc, <<c::utf8>>])

  defp ident_sequence(<<?\\, rest::binary>> = s, acc) do
    if valid_escape?(s) do
      {cp, rest} = escape(rest)
      ident_sequence(rest, [acc, <<cp::utf8>>])
    else
      {IO.iodata_to_binary(acc), s}
    end
  end

  defp ident_sequence(s, acc), do: {IO.iodata_to_binary(acc), s}

  # §4.3.3 consume a numeric token; §4.3.12 consume a number
  defp numeric(s, acc) do
    rest = number(s)

    cond do
      starts_ident?(rest) ->
        {unit, rest} = ident_sequence(rest, [])
        consume(rest, [{:dimension, unit} | acc])

      match?("%" <> _, rest) ->
        consume(binary_part(rest, 1, byte_size(rest) - 1), [:percentage | acc])

      true ->
        consume(rest, [:number | acc])
    end
  end

  defp number(s) do
    s =
      case s do
        <<c, rest::binary>> when c in [?+, ?-] -> rest
        _ -> s
      end

    s =
      case digits(s) do
        <<?., d, rest::binary>> when is_digit(d) -> digits(rest)
        s -> s
      end

    case s do
      <<e, d, rest::binary>> when e in [?e, ?E] and is_digit(d) -> digits(rest)
      <<e, sign, d, rest::binary>> when e in [?e, ?E] and sign in [?+, ?-] and is_digit(d) -> digits(rest)
      _ -> s
    end
  end

  defp digits(<<d, rest::binary>>) when is_digit(d), do: digits(rest)
  defp digits(s), do: s

  # §4.3.4 consume an ident-like token
  defp ident_like(s, acc) do
    {name, rest} = ident_sequence(s, [])

    case rest do
      "(" <> rest ->
        if String.downcase(name, :ascii) == "url" do
          rest = skip_double_ws(rest)

          case rest do
            <<q, _::binary>> when q in [?", ?'] ->
              consume(rest, [{:function, name} | acc])

            <<w, q, _::binary>> when is_ws(w) and q in [?", ?'] ->
              consume(rest, [{:function, name} | acc])

            _ ->
              {token, rest} = url(skip_ws(rest), [])
              consume(rest, [token | acc])
          end
        else
          consume(rest, [{:function, name} | acc])
        end

      _ ->
        consume(rest, [{:ident, name} | acc])
    end
  end

  defp skip_double_ws(<<a, b, _::binary>> = s) when is_ws(a) and is_ws(b),
    do: skip_double_ws(binary_part(s, 1, byte_size(s) - 1))

  defp skip_double_ws(s), do: s

  # §4.3.6 consume a url token; leading whitespace already consumed
  defp url("", acc), do: {{:url, IO.iodata_to_binary(acc)}, ""}
  defp url(")" <> rest, acc), do: {{:url, IO.iodata_to_binary(acc)}, rest}

  defp url(<<c, _::binary>> = s, acc) when is_ws(c) do
    case skip_ws(s) do
      "" -> {{:url, IO.iodata_to_binary(acc)}, ""}
      ")" <> rest -> {{:url, IO.iodata_to_binary(acc)}, rest}
      rest -> bad_url(rest)
    end
  end

  defp url(<<c, _::binary>> = s, _acc) when c in [?", ?', ?(] or is_non_printable(c), do: bad_url(s)

  defp url(<<?\\, rest::binary>> = s, acc) do
    if valid_escape?(s) do
      {cp, rest} = escape(rest)
      url(rest, [acc, <<cp::utf8>>])
    else
      bad_url(rest)
    end
  end

  defp url(<<c::utf8, rest::binary>>, acc), do: url(rest, [acc, <<c::utf8>>])

  # §4.3.14 consume the remnants of a bad url
  defp bad_url(""), do: {:bad_url, ""}
  defp bad_url(")" <> rest), do: {:bad_url, rest}

  defp bad_url(<<?\\, rest::binary>> = s) do
    if valid_escape?(s) do
      {_cp, rest} = escape(rest)
      bad_url(rest)
    else
      bad_url(rest)
    end
  end

  defp bad_url(<<_, rest::binary>>), do: bad_url(rest)

  # §4.3.5 consume a string token; `s` follows the opening quote.
  defp string("", _q, acc), do: {{:string, IO.iodata_to_binary(acc)}, ""}
  defp string(<<q, rest::binary>>, q, acc), do: {{:string, IO.iodata_to_binary(acc)}, rest}
  defp string("\n" <> _ = s, _q, _acc), do: {:bad_string, s}
  defp string("\\", _q, acc), do: {{:string, IO.iodata_to_binary(acc)}, ""}
  defp string("\\\n" <> rest, q, acc), do: string(rest, q, acc)

  defp string("\\" <> rest, q, acc) do
    {cp, rest} = escape(rest)
    string(rest, q, [acc, <<cp::utf8>>])
  end

  defp string(<<c::utf8, rest::binary>>, q, acc), do: string(rest, q, [acc, <<c::utf8>>])
end
