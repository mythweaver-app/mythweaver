defmodule Mix.Tasks.Mythweaver.Import.Preview do
  @shortdoc "Parses an import file and prints the result without writing anything"

  @moduledoc """
  Parses a file the way `/import` does (`Mythweaver.Import.parse/2`) and prints what it would
  import, writing nothing.

      mix mythweaver.import.preview FILE [--json]

  Without `--json` it prints the kind, name, entry and block counts and every warning, one per
  line; with it, the whole parsed result as JSON.
  """
  use Mix.Task

  alias Mythweaver.Import.TaskSupervisor

  @impl true
  def run(args) do
    {opts, files} = OptionParser.parse!(args, strict: [json: :boolean])

    file =
      case files do
        [file] -> file
        _other -> Mix.raise("Usage: mix mythweaver.import.preview FILE [--json]")
      end

    # Config only: starting the app would run its boot work (stale-job cleanup, …) against the database.
    # `Import.parse/2` parses under its own task supervisor, so start just that.
    Mix.Task.run("app.config")
    {:ok, _} = Task.Supervisor.start_link(name: TaskSupervisor)

    case Mythweaver.Import.parse(Path.basename(file), File.read!(file)) do
      {:error, message} -> Mix.raise(message)
      {:ok, parsed} -> if opts[:json], do: IO.puts(Jason.encode!(jsonable(parsed), pretty: true)), else: summary(parsed)
    end
  end

  defp summary(parsed) do
    Mix.shell().info("kind: #{parsed.kind}")
    Mix.shell().info("name: #{parsed[:name]}")

    for {label, count} <- counts(parsed), do: Mix.shell().info("#{label}: #{count}")
    for warning <- parsed.warnings, do: Mix.shell().info("warning: #{warning}")
  end

  defp counts(parsed) do
    [
      {"card fields", parsed[:card_fields]},
      {"entries", parsed[:entries]},
      {"book entries", get_in(parsed, [:book, :entries])},
      {"blocks", parsed[:blocks]},
      {"messages", parsed[:messages]},
      {"bundle items", with(%{items: items} <- parsed[:bundle], do: items)}
    ]
    |> Enum.filter(fn {_label, list} -> is_list(list) end)
    |> Enum.map(fn {label, list} -> {label, length(list)} end)
  end

  defp jsonable(%mod{} = value) when mod in [DateTime, NaiveDateTime, Date], do: value
  defp jsonable(%_{} = struct), do: struct |> Map.from_struct() |> Map.delete(:__meta__) |> jsonable()
  defp jsonable(map) when is_map(map), do: Map.new(map, fn {key, value} -> {to_string(key), jsonable(value)} end)
  defp jsonable(list) when is_list(list), do: Enum.map(list, &jsonable/1)
  defp jsonable(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> jsonable()
  defp jsonable(value) when value in [nil, true, false], do: value
  defp jsonable(atom) when is_atom(atom), do: Atom.to_string(atom)

  defp jsonable(binary) when is_binary(binary) do
    if String.valid?(binary), do: binary, else: "<binary #{byte_size(binary)} bytes>"
  end

  defp jsonable(value), do: value
end
