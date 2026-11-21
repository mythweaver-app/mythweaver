defmodule Mythweaver.Generation.StopStrings do
  @moduledoc """
  The stop strings a chat reply adds to its model's own, following SillyTavern's
  `getStoppingStrings`: every other participant's name as a line start (`"\\nBob:"`, the player's
  included) with `generation.names_as_stop_strings`, and a bare line break with
  `generation.single_line`.

  All of them end the reply locally (`Request.stop`, `Mythweaver.AI.StopScanner`), in both modes.
  Only a text-completion request also sends them on the wire, as SillyTavern does: a chat endpoint
  gets only the model's own stop sequences, since OpenAI caps `stop` at four entries and a chat
  model rarely writes a name prefix the scanner would not catch anyway.
  """

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.AI.Model
  alias Mythweaver.Characters.Character
  alias Mythweaver.Chats.Chat
  alias Mythweaver.Settings

  @doc "The strings `responder`'s reply in `chat` ends at, besides the model's own."
  @spec for_reply(Scope.t(), Chat.t(), Character.t()) :: [String.t()]
  def for_reply(%Scope{} = scope, %Chat{} = chat, %Character{} = responder) do
    values = Settings.get_many(scope, ["generation.names_as_stop_strings", "generation.single_line"])
    names = if values["generation.names_as_stop_strings"], do: name_strings(chat, responder), else: []
    line = if values["generation.single_line"], do: ["\n"], else: []
    Enum.uniq(line ++ names)
  end

  @doc """
  `input` (a rendered prompt for `model`) with `strings` added: as `:stop` for every mode, and as the
  sampler's sent `stop_sequences` in text mode.
  """
  @spec put(map(), Model.t(), [String.t()]) :: map()
  def put(input, _model, []), do: input

  def put(input, %Model{completion_mode: :text} = model, strings) do
    sent = Enum.uniq(model.sampler.stop_sequences ++ strings)

    input
    |> Map.put(:stop, strings)
    |> Map.update(:sampler, %{stop_sequences: sent}, &Map.put(&1, :stop_sequences, sent))
  end

  def put(input, %Model{}, strings), do: Map.put(input, :stop, strings)

  # SillyTavern skips a member who shares the responder's name: stopping there would end the reply
  # at its own speaker's line.
  defp name_strings(chat, responder) do
    for %Character{id: id, name: name} <- Chat.characters(chat),
        id != responder.id,
        is_binary(name),
        String.trim(name) != "",
        name != responder.name,
        do: "\n#{name}:"
  end
end
