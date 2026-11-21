defmodule Mythweaver.Scripts.Command do
  @moduledoc """
  The header of a `:command` script: its description and the parameters the command palette asks
  for, declared with LuaLS-style `---` comments at the top of the body.

      --- Has a participant speak next.
      ---@param who participant Who speaks
      ---@param mood? "happy"|"sad" Mood

  The header is the run of `---` lines after any leading blank lines; it ends at the first other
  line. `---@param name[?] type [Label]` declares a parameter (`?` makes it optional); other `@`
  tags are ignored; any other text is description. Types are `string`, `integer`, `number`,
  `boolean`, the entities `character`, `participant`, `message`, `lore_book`, `lore_entry`,
  `prompt`, `prompt_block`, `model`, `chat`, `script`, or quoted choices `"a"|"b"`.

  `cast_args/3` turns the palette's text (entity ids for entities) into `event.args`.
  """

  use Gettext, backend: Mythweaver.Gettext

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.AI
  alias Mythweaver.Characters
  alias Mythweaver.Chats
  alias Mythweaver.Chats.Chat
  alias Mythweaver.Lore
  alias Mythweaver.Messages
  alias Mythweaver.Prompts
  alias Mythweaver.Scripts
  alias Mythweaver.Scripts.API
  alias Mythweaver.Sharing.Visibility

  @type param :: %{
          name: String.t(),
          label: String.t(),
          type: atom(),
          optional?: boolean(),
          choices: [String.t()] | nil
        }

  @max_params 8

  @types %{
    "string" => :string,
    "integer" => :integer,
    "number" => :number,
    "boolean" => :boolean,
    "character" => :character,
    "participant" => :participant,
    "message" => :message,
    "lore_book" => :lore_book,
    "lore_entry" => :lore_entry,
    "prompt" => :prompt,
    "prompt_block" => :prompt_block,
    "model" => :model,
    "chat" => :chat,
    "script" => :script
  }

  @type_list ~s(string, integer, number, boolean, character, participant, message, lore_book, lore_entry, prompt, prompt_block, model, chat, script, or "a"|"b" choices)

  @param_re ~r/^@param\s+([A-Za-z_][A-Za-z0-9_]*)(\?)?\s+(.+)$/u
  @choices_re ~r/^((?:"[^"]*"|'[^']*')(?:\s*\|\s*(?:"[^"]*"|'[^']*'))*)(?:\s+(.*))?$/u
  @choice_re ~r/"([^"]*)"|'([^']*)'/u

  @doc "The parameter types that need a chat; a command using one is offered only in a chat."
  @spec chat_bound_types() :: [atom()]
  def chat_bound_types, do: [:participant, :message]

  @doc "Parses `body`'s header; every error is returned, each prefixed with its 1-based line."
  @spec parse(String.t()) :: {:ok, %{description: String.t() | nil, params: [param()]}} | {:error, [String.t()]}
  def parse(body) when is_binary(body) do
    {pieces, params, errors} =
      body
      |> String.split("\n")
      |> Enum.map(&String.trim_trailing(&1, "\r"))
      |> Enum.with_index(1)
      |> Enum.drop_while(fn {line, _n} -> String.trim(line) == "" end)
      |> Enum.take_while(fn {line, _n} -> String.starts_with?(String.trim_leading(line), "---") end)
      |> Enum.reduce({[], [], []}, &header_line/2)

    errors = Enum.reverse(errors)
    params = Enum.reverse(params)

    errors =
      if length(params) > @max_params,
        do:
          errors ++
            [
              dgettext("errors", "a command takes at most %{max_parameters} parameters",
                max_parameters: Mythweaver.Format.number(@max_params)
              )
            ],
        else: errors

    case errors do
      [] ->
        description = if pieces != [], do: pieces |> Enum.reverse() |> Enum.join(" ")
        {:ok, %{description: description, params: params}}

      errors ->
        {:error, errors}
    end
  end

  defp header_line({line, n}, {pieces, params, errors}) do
    rest = line |> String.trim_leading() |> String.replace_prefix("---", "") |> String.trim()

    cond do
      rest == "@param" or Regex.match?(~r/^@param\s/u, rest) ->
        case param(rest, n) do
          {:ok, param} ->
            if Enum.any?(params, &(&1.name == param.name)),
              do:
                {pieces, params,
                 [
                   dgettext("errors", ~S(line %{line_number}: "%{parameter_name}" is declared twice),
                     line_number: Mythweaver.Format.number(n),
                     parameter_name: param.name
                   )
                   | errors
                 ]},
              else: {pieces, [param | params], errors}

          {:error, error} ->
            {pieces, params, [error | errors]}
        end

      String.starts_with?(rest, "@") ->
        {pieces, params, errors}

      rest != "" ->
        {[rest | pieces], params, errors}

      true ->
        {pieces, params, errors}
    end
  end

  defp param(rest, n) do
    case Regex.run(@param_re, rest) do
      [_, name, optional, spec] ->
        with {:ok, type, choices, label} <- type(String.trim(spec), n) do
          label = if String.trim(label) == "", do: name, else: String.trim(label)
          {:ok, %{name: name, label: label, type: type, optional?: optional == "?", choices: choices}}
        end

      nil ->
        {:error,
         dgettext("errors", ~S(line %{line_number}: write @param as "---@param name type Label"),
           line_number: Mythweaver.Format.number(n)
         )}
    end
  end

  defp type(<<quote, _::binary>> = spec, n) when quote in [?", ?'] do
    case Regex.run(@choices_re, spec) do
      [_, choices | label] ->
        choices =
          @choice_re
          |> Regex.scan(choices, capture: :all_but_first)
          |> Enum.map(&Enum.join/1)
          |> Enum.uniq()

        if Enum.any?(choices, &(String.trim(&1) == "")),
          do:
            {:error,
             dgettext("errors", "line %{line_number}: choices cannot be blank",
               line_number: Mythweaver.Format.number(n)
             )},
          else: {:ok, :choice, choices, Enum.join(label)}

      nil ->
        {:error,
         dgettext("errors", ~S(line %{line_number}: write choices as "a"|"b"), line_number: Mythweaver.Format.number(n))}
    end
  end

  defp type(spec, n) do
    [token | label] = String.split(spec, ~r/\s+/u, parts: 2)

    case Map.fetch(@types, token) do
      {:ok, type} ->
        {:ok, type, nil, Enum.join(label)}

      :error ->
        gettext_comment(
          "Shown in the script editor. %{type_list} is the fixed list of Lua parameter type names, not translated."
        )

        {:error,
         dgettext("errors", ~S[line %{line_number}: unknown type "%{type_name}" (use %{type_list})],
           line_number: Mythweaver.Format.number(n),
           type_name: token,
           type_list: @type_list
         )}
    end
  end

  @doc """
  Casts the palette's raw values (param name → text, or an entity id) into `event.args`. A blank
  optional parameter is left out; entities become their record tables, as `scope` sees them.
  """
  @spec cast_args(Scope.t(), [param()], %{String.t() => String.t() | nil}, Chat.t() | nil) ::
          {:ok, %{String.t() => term()}} | {:error, %{String.t() => String.t()}}
  def cast_args(%Scope{} = scope, params, raw, chat) do
    {args, errors} =
      Enum.reduce(params, {%{}, %{}}, fn param, {args, errors} ->
        text = String.trim(Map.get(raw, param.name) || "")

        case cast(scope, param, text, chat) do
          :skip -> {args, errors}
          {:ok, value} -> {Map.put(args, param.name, value), errors}
          {:error, message} -> {args, Map.put(errors, param.name, message)}
        end
      end)

    if errors == %{}, do: {:ok, args}, else: {:error, errors}
  end

  defp cast(_scope, %{optional?: true}, "", _chat), do: :skip

  defp cast(_scope, _param, "", _chat),
    do: {:error, dpgettext("scripts", "status: a required palette command parameter was left blank", "Required.")}

  defp cast(_scope, %{type: :string}, text, _chat), do: {:ok, text}

  defp cast(_scope, %{type: :integer}, text, _chat) do
    case Integer.parse(text) do
      {n, ""} -> {:ok, n}
      _ -> {:error, dgettext("scripts", "Must be a whole number.")}
    end
  end

  defp cast(_scope, %{type: :number}, text, _chat) do
    case {Integer.parse(text), Float.parse(text)} do
      {{n, ""}, _} ->
        {:ok, n}

      {_, {f, ""}} ->
        {:ok, f}

      _ ->
        {:error,
         dpgettext("scripts", "status: a number palette command parameter is not a number", "Must be a number.")}
    end
  end

  defp cast(_scope, %{type: :boolean}, text, _chat) do
    case String.downcase(text) do
      "true" -> {:ok, true}
      "false" -> {:ok, false}
      _ -> {:error, dgettext("scripts", "Must be true or false.")}
    end
  end

  defp cast(_scope, %{type: :choice, choices: choices}, text, _chat) do
    if text in choices,
      do: {:ok, text},
      else: {:error, dgettext("scripts", "Must be one of: %{choice_list}", choice_list: Enum.join(choices, ", "))}
  end

  defp cast(scope, %{type: :participant}, text, chat) do
    with %Chat{participants: participants} <- chat,
         %{character: character} <- Enum.find(participants, &(&1.character_id == text)) do
      {:ok, to_table(scope, :character, character)}
    else
      _ -> {:error, dgettext("scripts", "Not a participant of this chat.")}
    end
  end

  defp cast(scope, %{type: type}, text, chat) do
    with {:ok, id} <- Ecto.UUID.cast(text),
         record when not is_nil(record) <- fetch(scope, type, id, chat) do
      {:ok, to_table(scope, type, record)}
    else
      _ -> {:error, gone_message(type)}
    end
  end

  defp gone_message(:character), do: dgettext("scripts", "That character no longer exists.")
  defp gone_message(:message), do: dgettext("scripts", "That message no longer exists.")
  defp gone_message(:lore_book), do: dgettext("scripts", "That lore book no longer exists.")
  defp gone_message(:lore_entry), do: dgettext("scripts", "That lore entry no longer exists.")
  defp gone_message(:prompt), do: dgettext("scripts", "That prompt no longer exists.")
  defp gone_message(:prompt_block), do: dgettext("scripts", "That prompt block no longer exists.")
  defp gone_message(:model), do: dgettext("scripts", "That model no longer exists.")
  defp gone_message(:chat), do: dgettext("scripts", "That chat no longer exists.")
  defp gone_message(:script), do: dgettext("scripts", "That script no longer exists.")

  defp fetch(scope, :character, id, _chat), do: Characters.get_character(scope, id)

  defp fetch(scope, :message, id, %Chat{id: chat_id}) do
    case Messages.get_message(scope, id) do
      %{chat_id: ^chat_id} = message -> message
      _ -> nil
    end
  end

  defp fetch(_scope, :message, _id, nil), do: nil
  defp fetch(scope, :lore_book, id, _chat), do: Lore.get_book(scope, id)
  defp fetch(scope, :lore_entry, id, _chat), do: Lore.get_entry(scope, id)
  defp fetch(scope, :prompt, id, _chat), do: Prompts.get_prompt(scope, id)
  defp fetch(scope, :prompt_block, id, _chat), do: Prompts.get_block(scope, id)
  defp fetch(scope, :model, id, _chat), do: AI.get_model(scope, id)
  defp fetch(scope, :chat, id, _chat), do: Chats.get_chat(scope, id)
  defp fetch(scope, :script, id, _chat), do: Scripts.get_script(scope, id)

  defp to_table(scope, :character, character),
    do: API.Characters.to_table(character, Visibility.content_hidden_for?(scope, character))

  defp to_table(_scope, :message, message), do: API.Messages.to_table(message)
  defp to_table(_scope, :lore_book, book), do: API.Lore.book_table(book)

  defp to_table(scope, :lore_entry, entry),
    do: API.Lore.entry_table(entry, nil, Visibility.entry_content_hidden_for?(scope, entry))

  defp to_table(_scope, :prompt, prompt), do: API.Prompts.to_table(prompt)
  defp to_table(_scope, :prompt_block, block), do: Map.take(block, [:id, :name, :description, :role, :kind, :enabled])
  defp to_table(_scope, :model, model), do: Map.take(model, [:id, :name, :api_model_id, :completion_mode])
  defp to_table(_scope, :chat, chat), do: %{id: chat.id, name: Chat.title(chat)}
  defp to_table(_scope, :script, script), do: Map.take(script, [:id, :name, :description, :trigger, :enabled])
end
