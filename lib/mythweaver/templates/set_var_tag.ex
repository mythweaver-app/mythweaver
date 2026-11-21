defmodule Mythweaver.Templates.SetVarTag do
  @moduledoc """
  `{% setvar key = value %}` and `{% setglobalvar key = value %}`: write a chat or global variable.

  Modeled on `Solid.Tags.AssignTag`. The write lands in the `Mythweaver.Templates.State` held in the
  context's registers and is visible to the rest of this render and to later templates; only
  `Mythweaver.Generation.Server` persists it. A `nil` value deletes the variable.
  """

  @behaviour Solid.Tag

  use Gettext, backend: Mythweaver.Gettext

  alias Mythweaver.Templates.State
  alias Mythweaver.Templates.Value
  alias Solid.Argument

  @enforce_keys [:loc, :scope, :key, :object]
  defstruct [:loc, :scope, :key, :object]

  # `Mythweaver.Variables.Variable`'s key rule, so every write can be stored.
  @key ~r/\A[A-Za-z_][A-Za-z0-9_]{0,63}\z/

  @impl true
  def parse(tag, loc, context) when tag in ["setvar", "setglobalvar"] do
    with {:ok, tokens, context} <- Solid.Lexer.tokenize_tag_end(context),
         {:ok, argument, tokens} <- Argument.parse(tokens),
         {:key, key} when is_binary(key) <- {:key, plain_key(argument)},
         [{:assignment, _} | tokens] <- tokens,
         {:ok, object, [{:end, _}]} <- Solid.Object.parse(tokens) do
      {:ok, %__MODULE__{loc: loc, scope: scope(tag), key: key, object: object}, context}
    else
      {:key, nil} ->
        {:error,
         dgettext("prompts", "Variable name must be a plain identifier of at most %{max_characters} characters",
           max_characters: Mythweaver.Format.number(64)
         ), %{line: loc.line, column: loc.column}}

      {:error, reason, _rest, loc} ->
        {:error, reason, loc}

      error ->
        error
    end
  end

  defp scope("setvar"), do: :chat
  defp scope("setglobalvar"), do: :global

  # Only a bare variable name: a literal such as `true` would otherwise stringify to a legal key.
  defp plain_key(%Solid.Variable{} = argument) do
    key = to_string(argument)
    if Regex.match?(@key, key), do: key
  end

  defp plain_key(_argument), do: nil

  defimpl Solid.Renderable do
    def render(tag, context, options) do
      {:ok, value, context} =
        Solid.Argument.get(tag.object.argument, context, tag.object.filters, options)

      state = State.put(context.registers.templates, tag.scope, tag.key, Value.to_json(value))

      # Merged rather than rebuilt so `{% increment %}` counters, which also live here, survive.
      counter_vars = Map.merge(context.counter_vars, State.variable_hash(state))
      registers = Map.put(context.registers, :templates, state)

      {[], %{context | counter_vars: counter_vars, registers: registers}}
    end
  end

  defimpl Solid.Block do
    def blank?(_), do: true
  end
end
