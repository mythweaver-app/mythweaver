defmodule Mythweaver.Scripts.Guards do
  @moduledoc """
  String-size guards the `lua` library lacks. It refuses an oversized `..` or `string.rep` before
  allocating, but `table.concat`, `string.format`, `string.gsub` and `os.date` build their result
  in one allocation of any size, which the sandbox heap cap only notices at the next garbage
  collection, too late if that one allocation is gigabytes. Each is replaced by a Lua wrapper
  that computes the result size first and raises the library's own `"resulting string too large"`.

  The wrappers keep the originals as upvalues, so the `debug` functions that reach upvalues,
  locals or a caller's function are sandboxed. `string.pack` is sandboxed too: its format
  expands several-fold and scripts have no binary data to pack.
  """

  @sandboxed [
    [:debug, :getupvalue],
    [:debug, :setupvalue],
    [:debug, :upvalueid],
    [:debug, :getlocal],
    [:debug, :setlocal],
    [:debug, :getinfo],
    [:debug, :sethook],
    [:debug, :gethook],
    [:string, :pack]
  ]

  @source "stdlib"

  # `MAX` is substituted per run. Each wrapper passes its arguments through unchanged (`...`),
  # so the original's argument errors are unchanged too.
  @prelude ~S"""
  local MAX = __MAX__
  local TOO_LARGE = "resulting string too large"
  local type, tostring, error, select, find, byte = type, tostring, error, select, string.find, string.byte
  local pack = table.pack
  local concat, format, gsub, date = table.concat, string.format, string.gsub, os.date

  table.concat = function(t, ...)
    local sep, i, j = ...
    if type(t) == "table" and (sep == nil or type(sep) == "string") then
      i = i or 1
      j = j or #t
      if type(i) == "number" and type(j) == "number" and j - i < 1e7 then
        local size, gap = 0, sep and #sep or 0
        for k = i, j do
          local v = t[k]
          size = size + (type(v) == "string" and #v or 32) + gap
          if size > MAX then error(TOO_LARGE, 2) end
        end
      end
    end
    return concat(t, ...)
  end

  string.format = function(fmt, ...)
    if type(fmt) == "string" then
      local args = pack(...)
      -- %q escapes a byte into at most four; width and precision add at most 99.
      local scale = find(fmt, "%q", 1, true) and 4 or 1
      local size = #fmt
      for k = 1, args.n do
        local v = args[k]
        local kind = type(v)
        local len = kind == "string" and #v or kind == "number" and 400 or #tostring(v)
        size = size + len * scale + 99
        if size > MAX then error(TOO_LARGE, 2) end
      end
    end
    return format(fmt, ...)
  end

  -- A strftime conversion of two bytes expands to at most 24.
  os.date = function(fmt, ...)
    if type(fmt) == "string" and #fmt * 16 > MAX then error(TOO_LARGE, 2) end
    return date(fmt, ...)
  end

  string.gsub = function(s, pattern, repl, ...)
    if type(s) ~= "string" or type(pattern) ~= "string" then return gsub(s, pattern, repl, ...) end
    local kind = type(repl)

    -- The result is the subject's unmatched text plus each replacement, so a running total of the
    -- replacements bounds it. A nil or false replacement keeps the match, already in #s.
    if kind == "function" or kind == "table" then
      local size = #s
      local counted = function(...)
        local r
        if kind == "function" then r = repl(...) else r = repl[(...)] end
        local rk = type(r)
        if rk == "string" then size = size + #r elseif rk == "number" then size = size + 32 end
        if size > MAX then error(TOO_LARGE, 0) end
        return r
      end
      return gsub(s, pattern, counted, ...)
    end

    if kind ~= "string" then return gsub(s, pattern, repl, ...) end

    -- A string replacement: its literal bytes plus, per %0-%9, the text that reference expands to.
    -- Only `%` escapes change the size, so the scan jumps between them.
    local literal, refs, counts = #repl, 0, {0, 0, 0, 0, 0, 0, 0, 0, 0, 0}
    local p = find(repl, "%", 1, true)
    while p do
      local d = byte(repl, p + 1)
      if d and d >= 48 and d <= 57 then
        counts[d - 47] = counts[d - 47] + 1
        refs = refs + 1
        literal = literal - 2
      else
        literal = literal - 1
      end
      p = find(repl, "%", p + 2, true)
    end

    -- Cheap bound: every position matches and every reference expands to the whole subject.
    if #s + (#s + 1) * (literal + refs * #s) <= MAX then return gsub(s, pattern, repl, ...) end

    -- Otherwise size the real matches, stepping like the library's gsub: an empty match right
    -- after a match is skipped, and a `^` pattern is tried once.
    local limit = ...
    if type(limit) == "number" then limit = limit // 1 else limit = nil end
    local anchored = byte(pattern, 1) == 94
    local init, skip, count, size = 1, false, 0, #s
    while init <= #s + 1 and (limit == nil or count < limit) do
      local st, en, c1, c2, c3, c4, c5, c6, c7, c8, c9 = find(s, pattern, init)
      if not st then break end
      if skip and st == init and en < st then
        init, skip = init + 1, false
      else
        count = count + 1
        local whole = en - st + 1
        local added = literal + counts[1] * whole
        for k = 1, 9 do
          if counts[k + 1] > 0 then
            local len = 0
            -- Without captures, %1 is the whole match.
            if c1 == nil and k == 1 then
              len = whole
            else
              local cap = select(k, c1, c2, c3, c4, c5, c6, c7, c8, c9)
              if type(cap) == "string" then len = #cap elseif type(cap) == "number" then len = #tostring(cap) end
            end
            added = added + counts[k + 1] * len
          end
        end
        size = size - whole + added
        if size > MAX then error(TOO_LARGE, 2) end
        if en < st then init, skip = st + 1, false else init, skip = en + 1, true end
      end
      if anchored then break end
    end
    return gsub(s, pattern, repl, ...)
  end
  """

  @doc "Installs the guards for a ceiling of `max_bytes` (`:infinity` installs none)."
  @spec install(Lua.t(), pos_integer() | :infinity) :: Lua.t()
  def install(lua, :infinity), do: lua

  def install(lua, max_bytes) when is_integer(max_bytes) do
    lua = Enum.reduce(@sandboxed, lua, &Lua.sandbox(&2, &1))
    {_, lua} = Lua.eval!(lua, String.replace(@prelude, "__MAX__", Integer.to_string(max_bytes)), source: @source)
    lua
  end

  @doc """
  `message` without positions inside the wrappers, which name lines of this prelude rather than
  of the script. The VM ignores `error`'s level argument, so a wrapper cannot point at its caller.
  """
  @spec strip_locations(String.t()) :: String.t()
  def strip_locations(message), do: String.replace(message, ~r/ \(at #{@source}:\d+\)/, "")
end
