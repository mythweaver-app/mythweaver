defmodule Mythweaver.Assistant.Tools.Batch do
  @moduledoc """
  The write tools that act on rows, in one shape: a call names 1 to 100 rows (`ids/2`) or carries
  1 to 100 objects (`items/2`), and one approval covers them all, so a request like "delete all the
  entries" is one card. Each row goes through the given `run`, one at a time and with no
  transaction, as the web's bulk actions do (`MythweaverWeb.Bulk`): every per-row rule runs, and a
  partial success is reported rather than rolled back. `each/2` is that loop, for a batch tool with
  its own shape (`add_models`).

  The result is `%{"done" => [row results], "failed" => [%{"index", "id" | "name", "error"}]}`, a
  failed row named as it still is; a batch in which nothing succeeded fails with the same lists.
  The summary counts the rows and the card's `preview` names each one (`Preview`).
  """

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Assistant.Tool
  alias Mythweaver.Assistant.Tools.Args
  alias Mythweaver.Assistant.Tools.Preview

  @max 100

  @type row_run :: (Scope.t(), map() -> {:ok, map()} | {:error, map()})

  @doc """
  A tool taking `{"ids": [...]}`; `run` gets `%{"id" => id}` for each. Options: `:description`,
  `:verb` and `:noun` (`{one, many}`) for the summary, e.g. "Delete 3 lore entries", `:label`
  (`t:Preview.label/0`) and `:run` (`t:row_run/0`).
  """
  @spec ids(String.t(), keyword()) :: Tool.t()
  def ids(name, opts) do
    {_one, many} = noun = Keyword.fetch!(opts, :noun)
    verb = Keyword.fetch!(opts, :verb)
    label = Keyword.fetch!(opts, :label)
    run = Keyword.fetch!(opts, :run)

    %Tool{
      name: name,
      description: description(opts),
      parameters: %{
        "type" => "object",
        "properties" => %{"ids" => array(%{"type" => "string"}, "The #{many}' ids.")},
        "required" => ["ids"]
      },
      kind: :write,
      summary: &count(verb, &1["ids"], noun),
      preview: fn scope, args -> Enum.map(list(args["ids"]), &Preview.row(label, scope, &1)) end,
      run: fn scope, args ->
        with {:ok, ids} <- fetch_list(args, "ids"),
             do: each(Enum.uniq(ids), &named(run.(scope, %{"id" => &1}), label, scope, &1))
      end
    }
  end

  @doc """
  A tool taking `{"items": [...]}`, each item an object matching `:item` (a JSON Schema object,
  whose `"required"` keys are checked per item) passed to `:run`. Options as `ids/2`; `:label`
  names an item with an `"id"` (an update) and is left out when items create rows, which are
  named by their `:name_key` (default `"name"`).
  """
  @spec items(String.t(), keyword()) :: Tool.t()
  def items(name, opts) do
    {one, _many} = noun = Keyword.fetch!(opts, :noun)
    verb = Keyword.fetch!(opts, :verb)
    item = Keyword.fetch!(opts, :item)
    label = Keyword.get(opts, :label)
    name_key = Keyword.get(opts, :name_key, "name")
    run = Keyword.fetch!(opts, :run)

    %Tool{
      name: name,
      description: description(opts),
      parameters: %{
        "type" => "object",
        "properties" => %{"items" => array(item, "One object per #{one}.")},
        "required" => ["items"]
      },
      kind: :write,
      summary: &count(verb, &1["items"], noun),
      preview: fn scope, args -> Enum.map(list(args["items"]), &item_line(label, name_key, scope, &1)) end,
      run: fn scope, args ->
        with {:ok, items} <- fetch_list(args, "items"),
             do: each(items, &run_item(&1, item, label, name_key, scope, run))
      end
    }
  end

  @doc "Runs `fun` on each of `list` in order and gathers the batch result; see the moduledoc."
  @spec each([term()], (term() -> {:ok, map()} | {:error, map()})) :: {:ok, map()} | {:error, map()}
  def each(list, fun) do
    {done, failed} =
      list
      |> Enum.with_index()
      |> Enum.reduce({[], []}, fn {item, index}, {done, failed} ->
        case fun.(item) do
          {:ok, result} -> {[result | done], failed}
          {:error, error} -> {done, [Map.merge(identify(item, index), error) | failed]}
        end
      end)

    result = %{"done" => Enum.reverse(done), "failed" => Enum.reverse(failed)}

    if done == [],
      do: {:error, Map.put(result, "error", "Nothing was done: every item failed.")},
      else: {:ok, result}
  end

  @doc "The list under `key` when it holds 1 to #{@max} entries, or an error map."
  @spec fetch_list(map(), String.t()) :: {:ok, list()} | {:error, map()}
  def fetch_list(args, key) do
    case args[key] do
      [_ | _] = list when length(list) <= @max -> {:ok, list}
      _ -> {:error, %{"error" => "#{key} must be a list of 1 to #{@max} entries"}}
    end
  end

  @doc "The JSON Schema of a batch's list of 1 to #{@max} `items`."
  @spec array(map(), String.t()) :: map()
  def array(items, description),
    do: %{"type" => "array", "items" => items, "minItems" => 1, "maxItems" => @max, "description" => description}

  @doc ~s|E.g. "Delete 3 lore entries".|
  @spec count(String.t(), term(), {String.t(), String.t()}) :: String.t()
  def count(verb, list, {one, many}) do
    n = length(list(list))
    "#{verb} #{n} #{if n == 1, do: one, else: many}"
  end

  @doc "The sentence every batch tool's description ends with."
  @spec rule() :: String.t()
  def rule, do: "Takes 1 to #{@max} at once under one approval; one failing does not stop the rest."

  defp description(opts), do: "#{Keyword.fetch!(opts, :description)} #{rule()}"

  defp run_item(item, schema, label, name_key, scope, run) when is_map(item) do
    case Args.missing(schema, item) do
      nil ->
        if label && is_map_key(item, "id"),
          do: named(run.(scope, item), label, scope, item["id"]),
          else: scope |> run.(item) |> new_named(item[name_key])

      key ->
        {:error, %{"error" => "missing argument: #{key}"}}
    end
  end

  defp run_item(_item, _schema, _label, _name_key, _scope, _run),
    do: {:error, %{"error" => "Each item must be an object."}}

  defp list(list) when is_list(list), do: list
  defp list(_), do: []

  # A failed row still exists, so its name says which one it was.
  defp named({:error, error}, label, scope, id) do
    case Preview.name(label, scope, id) do
      nil -> {:error, error}
      name -> {:error, Map.put_new(error, "name", name)}
    end
  end

  defp named(ok, _label, _scope, _id), do: ok

  # A row that failed to be created is named as the call named it.
  defp new_named({:error, error}, name) when is_binary(name), do: {:error, Map.put_new(error, "name", name)}
  defp new_named(result, _name), do: result

  defp item_line(label, _name_key, scope, %{"id" => _} = item) when is_function(label, 2),
    do: Preview.change(label, scope, item)

  defp item_line(_label, name_key, _scope, item) when is_map(item) do
    case item[name_key] do
      name when is_binary(name) -> name
      _ -> "Untitled"
    end
  end

  defp item_line(_label, _name_key, _scope, _item), do: "Not an object"

  defp identify(item, index) when is_binary(item), do: %{"index" => index, "id" => item}
  defp identify(%{"id" => id}, index), do: %{"index" => index, "id" => id}
  defp identify(%{"name" => name}, index), do: %{"index" => index, "name" => name}
  defp identify(_item, index), do: %{"index" => index}
end
