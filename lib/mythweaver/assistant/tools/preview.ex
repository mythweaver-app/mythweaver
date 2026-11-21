defmodule Mythweaver.Assistant.Tools.Preview do
  @moduledoc """
  Builds the `Mythweaver.Assistant.Tool` `preview` lines: what a pending write call would touch,
  named as the rows are now, read as the user's scope. A name always comes from the database, never
  from the model's arguments, so a call cannot mislabel the row it changes.
  """

  alias Mythweaver.Accounts.Scope

  @typedoc "The current name of the row with this id, or nil when the scope cannot reach it."
  @type label :: (Scope.t(), Ecto.UUID.t() -> String.t() | nil)

  @doc "The name `label` gives `id`, or nil for a malformed or unreachable id."
  @spec name(label(), Scope.t(), term()) :: String.t() | nil
  def name(label, scope, id) do
    with true <- is_binary(id),
         {:ok, uuid} <- Ecto.UUID.cast(id),
         name when is_binary(name) <- label.(scope, uuid) do
      name
    else
      _ -> nil
    end
  end

  @doc ~s|The row's name, or "Not found: <id>".|
  @spec row(label(), Scope.t(), term()) :: String.t()
  def row(label, scope, id), do: name(label, scope, id) || "Not found: #{inspect(id)}"

  @doc ~S"""
  An update's line: the row's name and each field it changes with its new value, e.g.
  `Castle: activation "constant", keywords (2 items)`. Text is trimmed, flattened to one line and cut
  to 60 characters; a map shows only its key names, never its values; a list shows its length.
  """
  @spec change(label(), Scope.t(), map()) :: String.t()
  def change(label, scope, %{"id" => id} = args) do
    row = row(label, scope, id)

    case Map.keys(args) -- ["id"] do
      [] ->
        row

      keys ->
        "#{row}: " <>
          (keys |> Enum.sort() |> Enum.map_join(", ", &"#{String.replace(&1, "_", " ")} #{value_text(args[&1])}"))
    end
  end

  def change(_label, _scope, _args), do: "Not found: nil"

  defp value_text(value) when is_binary(value) do
    text = value |> String.trim() |> String.replace(~r/\R/, " ")
    text = if String.length(text) > 60, do: String.slice(text, 0, 60) <> "…", else: text
    inspect(text)
  end

  defp value_text(value) when is_map(value),
    do: "(" <> (value |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort() |> Enum.join(", ")) <> ")"

  defp value_text(value) when is_list(value), do: "(#{length(value)} items)"
  defp value_text(value) when is_number(value), do: to_string(value)
  defp value_text(value), do: inspect(value)

  @doc "The `preview` of a tool that changes the one row its `\"id\"` names."
  @spec update(label()) :: (Scope.t(), map() -> [String.t()])
  def update(label), do: fn scope, args -> [change(label, scope, args)] end

  @doc "The `preview` of a tool that reads or copies the one row its `\"id\"` names."
  @spec one(label()) :: (Scope.t(), map() -> [String.t()])
  def one(label), do: fn scope, args -> [row(label, scope, args["id"])] end
end
