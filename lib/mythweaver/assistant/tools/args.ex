defmodule Mythweaver.Assistant.Tools.Args do
  @moduledoc """
  Helpers the tool modules share: id casting, the error maps a model reads, and attribute
  allowlists. Every error is `%{"error" => message}` (plus `"fields"` for a changeset).
  """

  alias Ecto.Changeset
  alias Mythweaver.Moderation.Hold

  @list_limit 100
  @cut 300

  @doc "The UUID under `key`, or an error map: context `get_*` functions raise on non-UUID strings."
  @spec uuid(map(), String.t()) :: {:ok, Ecto.UUID.t()} | {:error, map()}
  def uuid(args, key) do
    case Ecto.UUID.cast(args[key]) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, %{"error" => "#{key} is not a valid id"}}
    end
  end

  @doc "Every id in the array under `key` (nil is `[]`), or an error map naming the key."
  @spec uuid_list(map(), String.t()) :: {:ok, [Ecto.UUID.t()]} | {:error, map()}
  def uuid_list(args, key) do
    case args[key] || [] do
      list when is_list(list) ->
        list
        |> Enum.reduce_while({:ok, []}, fn id, {:ok, acc} ->
          case is_binary(id) && Ecto.UUID.cast(id) do
            {:ok, uuid} -> {:cont, {:ok, [uuid | acc]}}
            _ -> {:halt, {:error, %{"error" => "#{key} has an id that is not a valid id"}}}
          end
        end)
        |> case do
          {:ok, acc} -> {:ok, Enum.reverse(acc)}
          error -> error
        end

      _ ->
        {:error, %{"error" => "#{key} must be a list of ids"}}
    end
  end

  @doc ~s|The first key in the object `schema`'s "required" list that `args` lacks or holds nil for, or nil.|
  @spec missing(map(), map()) :: String.t() | nil
  def missing(schema, args), do: Enum.find(schema["required"] || [], &is_nil(args[&1]))

  @doc "A changeset's errors, interpolated, by field."
  @spec changeset_error(Changeset.t()) :: map()
  def changeset_error(%Changeset{} = changeset) do
    fields =
      Changeset.traverse_errors(changeset, fn {msg, opts} ->
        Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
          opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
        end)
      end)

    %{"error" => "invalid", "fields" => fields}
  end

  @doc "The error map for a context's error atom, changeset or message."
  @spec error(term()) :: map()
  def error(%Changeset{} = changeset), do: changeset_error(changeset)
  def error(:unauthorized), do: %{"error" => "You are not allowed to do that."}
  def error(:quota_exceeded), do: %{"error" => "Quota reached."}
  def error(:hold_limit), do: %{"error" => "Too much of this user's content is waiting for review."}
  def error(:not_found), do: %{"error" => "Not found."}
  def error(:in_use), do: %{"error" => "It is in use by a chat."}
  def error(%{"error" => _} = error), do: error

  def error(:sudo_required),
    do: %{"error" => "This needs sudo mode: confirm your password in the app, then approve again."}

  def error(:same_owner), do: %{"error" => "It already has that owner."}

  def error({:name_taken, names}), do: %{"error" => "The new owner already has rows named: #{Enum.join(names, ", ")}."}

  def error(:not_a_permutation),
    do: %{"error" => "The ids must list every current item exactly once, in the new order."}

  def error(:not_a_member), do: %{"error" => "The entry is not in that book."}
  def error({:invalid, text, reason}), do: %{"error" => "#{text}: #{reason}"}
  def error(:minimum_participants), do: %{"error" => "A chat must keep at least two participants."}
  def error(:not_roleplay), do: %{"error" => "Only a roleplay prompt can be bound."}

  def error({:needs_share, %{name: name}}),
    do: %{"error" => "It has editors, and the one it would go to cannot use its prompt '#{name}': share that first."}

  def error(:no_model), do: %{"error" => "The job has no model to retry with."}
  def error(:not_retryable), do: %{"error" => "That job cannot be retried."}
  def error(message) when is_binary(message), do: %{"error" => message}
  def error(other), do: %{"error" => inspect(other)}

  @doc """
  Wraps a context result: `{:error, reason}` becomes `{:error, error(reason)}`. A delete that gave the
  item to one of its editors instead (`Mythweaver.Sharing.hand_off_or/4`) reads `"deleted" => false`
  with whom it went to; a write held for moderator review reads `held/1`.
  """
  @spec wrap({:ok, term()} | {:held, Hold.t()} | {:error, term()}, (term() -> map())) :: {:ok, map()} | {:error, map()}
  def wrap({:held, hold}, _fun), do: {:ok, held(hold)}

  def wrap({:ok, {:handed_off, %{handle: handle}}}, _fun),
    do:
      {:ok,
       %{"deleted" => false, "handed_off_to" => "@" <> handle, "note" => "It had editors, so @#{handle} owns it now."}}

  def wrap({:ok, value}, fun), do: {:ok, fun.(value)}
  def wrap({:error, reason}, _fun), do: {:error, error(reason)}

  @doc "The result of a write held for moderator review (`Mythweaver.Moderation.Holds`)."
  @spec held(Hold.t()) :: map()
  def held(hold) do
    %{
      "held_for_review" => true,
      "hold_id" => hold.id,
      "title" => hold.title,
      "note" => "Saved for moderator review; it appears once approved."
    }
  end

  @doc "Only the allowed string keys of `args`, so a tool can never set a non-cast field."
  @spec attrs(map(), [String.t()]) :: map()
  def attrs(args, allowed_keys), do: Map.take(args, allowed_keys)

  @doc "At most #{@list_limit} rows plus the total, the list result shape."
  @spec list(String.t(), [map()]) :: map()
  def list(key, rows), do: %{key => Enum.take(rows, @list_limit), "total" => length(rows)}

  @doc "The `query` JSON Schema property every list tool takes; see `by_name/3`."
  @spec query_property() :: map()
  def query_property do
    %{
      "type" => "string",
      "description" =>
        "Only rows whose name contains this text, case-insensitively; a row named exactly this comes first."
    }
  end

  @doc """
  The rows whose `key` contains `query`, ignoring case, with exact (case-insensitive) matches
  first and the rest in their given order. A nil or blank query keeps every row.
  """
  @spec by_name([map()], term(), String.t()) :: [map()]
  def by_name(rows, query, key \\ "name")

  def by_name(rows, query, key) when is_binary(query) do
    query
    |> String.trim()
    |> String.downcase()
    |> case do
      "" ->
        rows

      q ->
        rows
        |> Enum.filter(&(is_binary(&1[key]) and String.contains?(String.downcase(&1[key]), q)))
        |> Enum.sort_by(&(String.downcase(&1[key]) != q))
    end
  end

  def by_name(rows, _query, _key), do: rows

  @doc "Text over #{@cut} characters, cut to #{@cut} plus an ellipsis; lists only."
  @spec cut(String.t() | nil) :: String.t() | nil
  def cut(text) when is_binary(text) do
    if String.length(text) > @cut, do: String.slice(text, 0, @cut) <> "…", else: text
  end

  def cut(other), do: other

  @doc ~s|"site" for a site row, "personal" for a user's own.|
  @spec owner(%{user_id: Ecto.UUID.t() | nil}) :: String.t()
  def owner(%{user_id: nil}), do: "site"
  def owner(%{}), do: "personal"
end
