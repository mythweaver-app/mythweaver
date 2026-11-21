defmodule Mythweaver.Scripts.API.Regex do
  @moduledoc """
  `regex.*`: PCRE regular expressions over OTP `:re`. Positions are 1-based inclusive byte offsets,
  like `string.find`. `:re` runs in the sandbox task, so its time counts toward the CPU limit.
  """

  use Gettext, backend: Mythweaver.Gettext

  import Mythweaver.Scripts.API.Convert, only: [install_functions: 4, usage!: 1]

  require Lua.API

  @functions %{
    test: {"regex.test(s, pattern [, flags])", dgettext_noop("scripts", "Whether pattern matches anywhere in s.")},
    match:
      {"regex.match(s, pattern [, flags [, init]])",
       dgettext_noop(
         "scripts",
         "The first match at or after byte init, as {text, start, finish, groups, named}; nil when none."
       )},
    match_all:
      {"regex.match_all(s, pattern [, flags [, limit]])",
       dgettext_noop("scripts", "Every match (at most limit), as an array of match tables.")},
    replace:
      {"regex.replace(s, pattern, repl [, flags [, limit]])",
       dgettext_noop(
         "scripts",
         "Replaces matches (at most limit) with a template ($1, ${name}, $$) or function(m) returning a string, or nil to keep the match. Returns the new string and the count."
       )},
    split:
      {"regex.split(s, pattern [, flags [, limit]])",
       dgettext_noop("scripts", "The pieces of s between matches (at most limit splits).")},
    escape:
      {"regex.escape(s)",
       dgettext_noop("scripts", "The string s with every regex metacharacter escaped, to match it literally.")}
  }

  @usage Map.new(@functions, fn {name, {signature, _info}} -> {name, signature} end)

  @doc "The installed functions' signatures and descriptions, by name."
  def functions, do: @functions

  @flags %{"i" => :caseless, "m" => :multiline, "s" => :dotall, "x" => :extended, "U" => :ungreedy}

  def install(lua, _ctx), do: install_functions(lua, [:regex], @functions, &call/3)

  defp call(:test, args, state) do
    [s, pattern, flags] = pad(:test, args, 3)
    s = subject!(:test, s)
    {mp, _names} = compile!(:test, pattern, flags)
    Lua.encode_list!(state, [run!(s, mp, [{:capture, :none}]) == :match])
  end

  defp call(:match, args, state) do
    [s, pattern, flags, init] = pad(:match, args, 4)
    s = subject!(:match, s)
    compiled = compile!(:match, pattern, flags)
    offset = init!(init, s)

    match =
      if offset <= byte_size(s), do: s |> find(compiled, [{:offset, offset}]) |> List.first()

    Lua.encode_list!(state, [match])
  end

  defp call(:match_all, args, state) do
    [s, pattern, flags, limit] = pad(:match_all, args, 4)
    s = subject!(:match_all, s)
    compiled = compile!(:match_all, pattern, flags)
    limit = limit!(:match_all, limit)
    Lua.encode_list!(state, [s |> find(compiled, [:global]) |> take(limit)])
  end

  defp call(:replace, args, state) do
    [s, pattern, repl, flags, limit] = pad(:replace, args, 5)
    s = subject!(:replace, s)
    compiled = compile!(:replace, pattern, flags)
    limit = limit!(:replace, limit)
    replacer = replacer!(repl)
    matches = s |> find(compiled, [:global]) |> take(limit)

    # Sized before the one allocation that builds the result, like the VM's own `..` guard: a
    # template repeating `$0`, or many matches of a long replacement, multiplies the subject.
    max = state.state.max_string_bytes

    {iodata, from, _size, state} =
      Enum.reduce(matches, {[], 0, byte_size(s), state}, fn match, {acc, from, size, state} ->
        start = match["start"] - 1
        {replacement, state} = replacement(replacer, match, state)
        size = size - byte_size(match["text"]) + IO.iodata_length(replacement)
        if size > max, do: raise(Lua.RuntimeException, "regex.replace: resulting string too large")
        {[acc, binary_part(s, from, start - from), replacement], match["finish"], size, state}
      end)

    result = IO.iodata_to_binary([iodata, binary_part(s, from, byte_size(s) - from)])
    Lua.encode_list!(state, [result, length(matches)])
  end

  defp call(:split, args, state) do
    [s, pattern, flags, limit] = pad(:split, args, 4)
    s = subject!(:split, s)
    {mp, _names} = compile!(:split, pattern, flags)
    limit = limit!(:split, limit)

    cuts =
      case run!(s, mp, [:global, {:capture, :first, :index}]) do
        :nomatch ->
          []

        {:match, found} ->
          found
          |> Enum.map(&hd/1)
          |> Enum.reject(fn {pos, len} -> len == 0 and pos in [0, byte_size(s)] end)
          |> take(limit)
      end

    {pieces, from} = Enum.map_reduce(cuts, 0, fn {pos, len}, from -> {binary_part(s, from, pos - from), pos + len} end)
    Lua.encode_list!(state, [pieces ++ [binary_part(s, from, byte_size(s) - from)]])
  end

  defp call(:escape, [s], state) when is_binary(s), do: Lua.encode_list!(state, [Regex.escape(s)])

  defp call(name, _args, _state), do: usage!(@usage[name])

  # Trailing optional arguments may be absent; Lua passes them as `nil` either way.
  defp pad(_name, args, n) when length(args) <= n, do: args ++ List.duplicate(nil, n - length(args))
  defp pad(name, _args, _n), do: usage!(@usage[name])

  defp subject!(name, s) when not is_binary(s), do: usage!(@usage[name])

  defp subject!(_name, s) do
    if String.valid?(s), do: s, else: raise(Lua.RuntimeException, "regex: subject is not valid UTF-8")
  end

  defp flags!(_name, nil), do: []

  defp flags!(_name, flags) when is_binary(flags) do
    flags
    |> String.graphemes()
    |> Enum.map(fn c ->
      Map.get(@flags, c) || raise(Lua.RuntimeException, ~s[regex: unknown flag "#{c}" (use i, m, s, x, U)])
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp flags!(name, _flags), do: usage!(@usage[name])

  defp compile!(name, pattern, flags) do
    if not (is_binary(pattern) and String.valid?(pattern)), do: usage!(@usage[name])
    opts = flags!(name, flags)
    # The sandbox task lives for exactly one heap-capped run, so this cache needs no eviction.
    key = {__MODULE__, pattern, opts}

    with nil <- Process.get(key) do
      case :re.compile(pattern, [:unicode, :ucp | opts]) do
        {:ok, mp} ->
          {:namelist, names} = :re.inspect(mp, :namelist)
          Process.put(key, {mp, names})
          {mp, names}

        {:error, {msg, pos}} ->
          raise Lua.RuntimeException, "regex: invalid pattern at position #{pos}: #{msg}"
      end
    end
  end

  # Without :report_errors, :re returns :nomatch when the match limit is hit.
  defp run!(s, mp, opts) do
    case :re.run(s, mp, [:report_errors | opts]) do
      {:error, reason} when reason in [:match_limit, :match_limit_recursion] ->
        raise Lua.RuntimeException, "regex: match limit exceeded; simplify the pattern or shorten the input"

      result ->
        result
    end
  end

  # Match tables for every match `opts` finds (one without :global).
  defp find(s, {mp, names}, opts) do
    case run!(s, mp, [{:capture, :all, :index} | opts]) do
      :nomatch ->
        []

      {:match, found} ->
        found = if :global in opts, do: found, else: [found]
        Enum.zip_with(found, named(s, mp, names, opts, length(found)), &to_match(s, &1, &2))
    end
  end

  defp named(_s, _mp, [], _opts, count), do: List.duplicate(%{}, count)

  defp named(s, mp, names, opts, _count) do
    {:match, found} = run!(s, mp, [{:capture, :all_names, :index} | opts])
    found = if :global in opts, do: found, else: [found]

    Enum.map(found, fn indexes ->
      for {name, {pos, len}} <- Enum.zip(names, indexes), pos >= 0, into: %{}, do: {name, binary_part(s, pos, len)}
    end)
  end

  # Integer group keys survive because results bypass `Convert.to_lua/1`, which stringifies keys.
  defp to_match(s, [{pos, len} | groups], named) do
    groups =
      for {{gpos, glen}, i} <- Enum.with_index(groups, 1), gpos >= 0, into: %{}, do: {i, binary_part(s, gpos, glen)}

    %{
      "text" => binary_part(s, pos, len),
      "start" => pos + 1,
      "finish" => pos + len,
      "groups" => groups,
      "named" => named
    }
  end

  defp limit!(_name, nil), do: :infinity
  defp limit!(_name, limit) when is_integer(limit) and limit >= 1, do: limit
  defp limit!(name, _limit), do: usage!(@usage[name])

  defp take(list, :infinity), do: list
  defp take(list, limit), do: Enum.take(list, limit)

  defp init!(init, _s) when init in [nil, 0], do: 0
  defp init!(init, s) when is_integer(init) and init < 0, do: boundary(s, max(byte_size(s) + init, 0))
  defp init!(init, s) when is_integer(init), do: boundary(s, init - 1)
  defp init!(_init, _s), do: usage!(@usage[:match])

  # :re raises on an offset inside a UTF-8 character; no match can start there, so skip ahead.
  defp boundary(s, offset) when offset < byte_size(s) do
    case :binary.at(s, offset) do
      byte when Bitwise.band(byte, 0xC0) == 0x80 -> boundary(s, offset + 1)
      _ -> offset
    end
  end

  defp boundary(_s, offset), do: offset

  defp replacer!(repl) when is_binary(repl), do: {:template, template(repl, [])}
  defp replacer!(repl) when Lua.API.is_lua_func(repl) or Lua.API.is_erl_func(repl), do: {:function, repl}
  defp replacer!(_repl), do: usage!(@usage[:replace])

  # `$$` is `$`, `$d` group d (one digit), `${digits}` a group, `${name}` a named group; any other
  # `$` is literal.
  defp template("", acc), do: Enum.reverse(acc)
  defp template("$$" <> rest, acc), do: template(rest, [{:text, "$"} | acc])
  defp template(<<"$", d, rest::binary>>, acc) when d in ?0..?9, do: template(rest, [{:group, d - ?0} | acc])

  defp template("${" <> rest, acc) do
    with [ref, after_ref] <- String.split(rest, "}", parts: 2),
         {:ok, part} <- reference(ref) do
      template(after_ref, [part | acc])
    else
      _ -> template("{" <> rest, [{:text, "$"} | acc])
    end
  end

  defp template("$" <> rest, acc), do: template(rest, [{:text, "$"} | acc])

  defp template(s, acc) do
    case :binary.match(s, "$") do
      :nomatch -> template("", [{:text, s} | acc])
      {i, _} -> template(binary_part(s, i, byte_size(s) - i), [{:text, binary_part(s, 0, i)} | acc])
    end
  end

  defp reference(ref) do
    cond do
      ref =~ ~r/\A\d+\z/ -> {:ok, {:group, String.to_integer(ref)}}
      ref =~ ~r/\A[A-Za-z_][A-Za-z0-9_]*\z/ -> {:ok, {:name, ref}}
      true -> :error
    end
  end

  defp replacement({:template, parts}, match, state) do
    text =
      Enum.map(parts, fn
        {:text, text} -> text
        {:group, 0} -> match["text"]
        {:group, i} -> Map.get(match["groups"], i, "")
        {:name, name} -> Map.get(match["named"], name, "")
      end)

    {text, state}
  end

  defp replacement({:function, fun}, match, state) do
    {table, state} = Lua.encode!(state, match)

    case Lua.call_function!(state, fun, [table]) do
      {[text | _], state} when is_binary(text) -> {text, state}
      {[skip | _], state} when skip in [nil, false] -> {match["text"], state}
      {[], state} -> {match["text"], state}
      _ -> raise Lua.RuntimeException, "regex.replace: replacement function must return a string, nil or false"
    end
  end
end
