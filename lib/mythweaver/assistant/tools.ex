defmodule Mythweaver.Assistant.Tools do
  @moduledoc """
  The assistant's tool catalog (one module per domain under `Mythweaver.Assistant.Tools.*`, each
  with `tools/0`) and the one place a tool runs.
  """

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Assistant.Tool
  alias Mythweaver.Assistant.Tools.AI
  alias Mythweaver.Assistant.Tools.Analytics
  alias Mythweaver.Assistant.Tools.Args
  alias Mythweaver.Assistant.Tools.Characters
  alias Mythweaver.Assistant.Tools.Chats
  alias Mythweaver.Assistant.Tools.Docs
  alias Mythweaver.Assistant.Tools.Expressions
  alias Mythweaver.Assistant.Tools.Injections
  alias Mythweaver.Assistant.Tools.Jobs
  alias Mythweaver.Assistant.Tools.Lore
  alias Mythweaver.Assistant.Tools.Memory
  alias Mythweaver.Assistant.Tools.Navigation
  alias Mythweaver.Assistant.Tools.Prompts
  alias Mythweaver.Assistant.Tools.Results
  alias Mythweaver.Assistant.Tools.Scripts
  alias Mythweaver.Assistant.Tools.Search
  alias Mythweaver.Assistant.Tools.Settings
  alias Mythweaver.Assistant.Tools.Tags
  alias Mythweaver.Assistant.Tools.Variables

  @modules [
    Characters,
    Lore,
    Chats,
    AI,
    Settings,
    Prompts,
    Tags,
    Search,
    Memory,
    Variables,
    Injections,
    Scripts,
    Expressions,
    Jobs,
    Analytics,
    Navigation,
    Docs,
    Results
  ]

  @doc "Every tool, in catalog order."
  @spec all() :: [Tool.t()]
  def all, do: Enum.flat_map(@modules, & &1.tools())

  @doc "The tool named `name`."
  @spec fetch(String.t()) :: {:ok, Tool.t()} | :error
  def fetch(name) do
    case Enum.find(all(), &(&1.name == name)) do
      nil -> :error
      tool -> {:ok, tool}
    end
  end

  @doc """
  Runs `tool` as `scope`. A missing `"required"` argument is refused before the tool sees it.
  """
  @spec run(Scope.t(), Tool.t(), map()) :: {:ok, map()} | {:error, map()}
  def run(%Scope{} = scope, %Tool{} = tool, args) when is_map(args) do
    missing = Args.missing(tool.parameters, args)

    if missing,
      do: {:error, %{"error" => "missing argument: #{missing}"}},
      else: tool.run.(scope, args)
  end
end
