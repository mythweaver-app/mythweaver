defmodule Mythweaver.Scripts.API do
  @moduledoc """
  Installs a run's `event` global and the `mw.*` and `regex.*` host functions into a fresh VM. See
  `Mythweaver.Scripts` for the reference.

  The ctx's `scope` is the user the run acts for; every `mw.*` call checks it as that user's request would.
  Each namespace's acting and writing functions also need that user's script permission
  (`@namespaces`: e.g. `"scripts.messages"` for `mw.messages.*`); without it they return
  `nil, "no_permission"`. The reads in `@ungated`, `mw.commands.run`, `mw.roll` and `regex.*` are never
  gated: a command run through `mw.commands.run` runs in the same sandbox, so its own calls are.

  A test run (`test?: true`, `Mythweaver.Scripts.test_run/4`) has no chat and must change nothing,
  so every `mw.*` function outside `@test_safe` returns `nil, "test_run"`. A new function is
  refused there until it is listed. A real run with no chat (a command script picked off a chat
  page) refuses the chat-bound functions (`mw.messages.*`, `mw.images.*`, `mw.generation.*`,
  `mw.memory.*`, `mw.vars.*`, `mw.injections.*`, `mw.lore.set_chat_bound`,
  `mw.characters.set_avatar`) with `nil, "no_chat"`.
  """

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Chats.Chat
  alias Mythweaver.Scripts.API

  @modules [
    API.Messages,
    API.Images,
    API.Generation,
    API.Memory,
    API.Characters,
    API.Prompts,
    API.Lore,
    API.Variables,
    API.Injections,
    API.Commands,
    API.Regex,
    API.Dice
  ]

  # Read-only and independent of the chat. A command run through `mw.commands.run` inherits
  # `test?`, so its own writes are refused anyway.
  @test_safe ~w(mw.characters.list mw.characters.get mw.characters.find mw.prompts.list mw.lore.books mw.lore.book mw.globals.get mw.globals.list mw.commands.run mw.roll)

  @namespaces [
    {"mw.messages.", "scripts.messages"},
    {"mw.images.", "scripts.images"},
    {"mw.generation.", "scripts.generation"},
    {"mw.memory.", "scripts.memory"},
    {"mw.characters.", "scripts.characters"},
    {"mw.prompts.", "scripts.prompts"},
    {"mw.blocks.", "scripts.prompts"},
    {"mw.lore.", "scripts.lore"},
    {"mw.vars.", "scripts.variables"},
    {"mw.globals.", "scripts.variables"},
    {"mw.injections.", "scripts.injections"}
  ]

  @ungated ~w(
    mw.messages.list mw.messages.get mw.messages.last mw.messages.select mw.messages.versions
    mw.images.list mw.images.get mw.memory.highest mw.characters.list mw.characters.get
    mw.characters.find mw.prompts.list mw.lore.books mw.lore.book mw.vars.get mw.vars.list
    mw.globals.get mw.globals.list mw.injections.list mw.injections.get
  )

  @spec install(Lua.t(), %{
          required(:scope) => Scope.t(),
          required(:chat) => Chat.t() | nil,
          required(:trigger) => atom(),
          required(:event) => map(),
          optional(:test?) => boolean(),
          optional(:depth) => non_neg_integer()
        }) :: Lua.t()
  def install(lua, ctx) do
    {event, lua} = Lua.encode!(lua, API.Convert.to_lua(ctx.event))
    lua = Lua.set!(lua, [:event], event)
    lua = Enum.reduce(@modules, lua, & &1.install(&2, ctx))
    # First, so a test run's or a chat-less run's own refusal replaces this one.
    lua = refuse_where(lua, &missing?(&1, ctx.scope), :no_permission)

    cond do
      Map.get(ctx, :test?, false) -> refuse_where(lua, &(&1 not in @test_safe), :test_run)
      ctx.chat == nil -> refuse_where(lua, &chat_bound?/1, :no_chat)
      true -> lua
    end
  end

  # Whether `name` needs a script permission `scope` lacks.
  defp missing?(name, scope) do
    name not in @ungated and
      Enum.any?(@namespaces, fn {prefix, key} -> String.starts_with?(name, prefix) and not Scope.can?(scope, key) end)
  end

  defp refuse_where(lua, refuse?, reason) do
    for {signature, _info} <- functions(),
        name = signature |> String.split("(", parts: 2) |> hd(),
        String.starts_with?(name, "mw."),
        refuse?.(name),
        reduce: lua do
      lua -> Lua.set!(lua, String.split(name, "."), fn _args, state -> API.Convert.refuse(state, reason) end)
    end
  end

  defp chat_bound?(name) do
    String.starts_with?(name, [
      "mw.messages.",
      "mw.images.",
      "mw.generation.",
      "mw.memory.",
      "mw.vars.",
      "mw.injections."
    ]) or
      name in ["mw.lore.set_chat_bound", "mw.characters.set_avatar"]
  end

  @doc ~S|Every host function as `{signature, description}`, e.g. `{"mw.messages.get(id)", "…"}`; descriptions translated.|
  @spec functions() :: [{String.t(), String.t()}]
  def functions do
    for module <- @modules,
        {signature, info} <- Map.values(module.functions()),
        do: {signature, Gettext.dgettext(Mythweaver.Gettext, "scripts", info)}
  end

  @doc ~S|Every `mw.<namespace>` host functions sit under, without the prefix: `["blocks", "characters", …]`.|
  @spec namespaces() :: [String.t()]
  def namespaces do
    for {signature, _info} <- functions(),
        ["mw", namespace, _function] <- [signature |> String.split("(", parts: 2) |> hd() |> String.split(".")],
        uniq: true,
        do: namespace
  end
end
