defmodule MythweaverWeb.CommandPalette.Command do
  @moduledoc """
  One command palette entry. `params` use `Mythweaver.Scripts.Command.param/0`'s shape; built-ins
  may also use `:bot` (a participant other than the player; `panel_order?: true` lists bots in the
  participants panel's order instead of moving muted ones last), `:image` (an image the palette
  uploads; its value is the stored attachment's id), `:ai_provider`, `:prompt_outlet`,
  `:global_variable`, `:memory_profile`, `:side_prompt` and `:tag`. `run` takes the values by param
  name (ids for entities, `nil` when blank) and the open chat, and returns what the palette does:

    * `{:navigate, path}`
    * `{:chat_event, event, params}`: handled by `MainChatLive`'s own `handle_event/3`
    * `{:script, script_id}`: runs a command script with the cast values
    * `{:error, message}`: shown as an error flash
    * `{:task, fun}`: runs `fun` off the palette's process; its `{:ok, message}`/`{:error, message}`
      becomes an info/error flash
  """

  alias Mythweaver.Chats.Chat
  alias Mythweaver.Scripts.Command

  @type action ::
          {:navigate, String.t()}
          | {:chat_event, String.t(), map()}
          | {:script, Ecto.UUID.t()}
          | {:error, String.t()}
          | {:task, (-> {:ok, String.t()} | {:error, String.t()})}

  @type t :: %__MODULE__{
          id: String.t(),
          title: String.t(),
          description: String.t() | nil,
          params: [Command.param()],
          chat?: boolean(),
          run: (%{String.t() => String.t() | nil}, Chat.t() | nil -> action())
        }

  defstruct [:id, :title, :description, :run, params: [], chat?: false]
end
