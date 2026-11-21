defmodule Mythweaver.Templates do
  @moduledoc """
  Liquid templating for prompt text, through Solid. The only module that calls Solid.

  Templates are untrusted (they will be shared), so `render/3` runs each one in its own process under
  `Mythweaver.Templates.TaskSupervisor`, with a heap cap and a deadline. Any failure (syntax, memory,
  time, crash) returns the raw source and the input state unchanged, plus one error string, so a
  broken template never blocks a generation.

  Tags are Liquid's standard set minus `render` (no file-system includes), plus `setvar` and
  `setglobalvar` (`Mythweaver.Templates.SetVarTag`). Filters are Solid's standard set plus
  `Mythweaver.Templates.Filters`.
  """

  use Gettext, backend: Mythweaver.Gettext

  alias Ecto.Changeset
  alias Mythweaver.Templates.Filters
  alias Mythweaver.Templates.SetVarTag
  alias Mythweaver.Templates.State

  @timeout 1_000
  # Words, not bytes: about 32 MB on a 64-bit VM.
  @max_heap_words 4_000_000

  @doc "Whether `source` contains any Liquid markup; text without it is never parsed or rendered."
  @spec template?(String.t()) :: boolean()
  def template?(source), do: String.contains?(source, ["{{", "{%"])

  @spec parse(String.t()) :: {:ok, Solid.Template.t()} | {:error, String.t()}
  def parse(source) do
    case Solid.parse(source, tags: tags()) do
      {:ok, template} ->
        {:ok, template}

      {:error, %Solid.TemplateError{errors: [%Solid.ParserError{} = error | _]}} ->
        {:error,
         dgettext("errors", "line %{line_number}, column %{column_number}: %{parser_reason}",
           line_number: Mythweaver.Format.number(error.meta[:line]),
           column_number: Mythweaver.Format.number(error.meta[:column]),
           parser_reason: error.reason
         )}
    end
  end

  @doc """
  Adds an error to `field` when its change is a template that does not parse.
  """
  @spec validate(Changeset.t(), atom()) :: Changeset.t()
  def validate(changeset, field) do
    case syntax_error(Changeset.get_change(changeset, field)) do
      {:error, detail} ->
        Changeset.add_error(changeset, field, dgettext_noop("errors", "has invalid template syntax: %{detail}"),
          detail: detail
        )

      nil ->
        changeset
    end
  end

  @doc "`validate/2` for a list of templates: each entry must parse; the error names its 1-based position."
  @spec validate_each(Changeset.t(), atom()) :: Changeset.t()
  def validate_each(changeset, field) do
    Changeset.validate_change(changeset, field, fn ^field, sources ->
      for {source, index} <- Enum.with_index(sources, 1),
          {:error, detail} <- [syntax_error(source)],
          do:
            {field,
             {dgettext_noop("errors", "entry %{index} has invalid template syntax: %{detail}"),
              index: index, detail: detail}}
    end)
  end

  @doc "Adds an error to `field` when its change is a Liquid condition expression that does not parse."
  @spec validate_condition(Changeset.t(), atom()) :: Changeset.t()
  def validate_condition(changeset, field) do
    with condition when is_binary(condition) <- Changeset.get_change(changeset, field),
         {:error, detail} <- parse("{% if " <> condition <> " %}{% endif %}") do
      Changeset.add_error(changeset, field, dgettext_noop("errors", "is not a valid Liquid condition: %{detail}"),
        detail: detail
      )
    else
      _ -> changeset
    end
  end

  @doc """
  Evaluates the Liquid condition `expression` against `state`. The state the render leaves behind
  is discarded.
  """
  @spec condition(String.t(), State.t()) :: {:ok, boolean()} | {:error, [String.t()]}
  def condition(expression, %State{} = state) do
    case render("{% if " <> expression <> " %}1{% endif %}", state) do
      {_text, _state, [_ | _] = errors} -> {:error, errors}
      {text, _state, []} -> {:ok, String.trim(text) == "1"}
    end
  end

  # `{:error, detail}` for a template `source` that does not parse, else nil.
  defp syntax_error(source) do
    if is_binary(source) and template?(source) do
      case parse(source) do
        {:error, _detail} = error -> error
        {:ok, _template} -> nil
      end
    end
  end

  @doc """
  Renders `source` against `state`, returning the text, the state for the next template, and any
  render errors.

  Options: `timeout:` in ms (default #{@timeout}) and `max_heap_words:` (default #{@max_heap_words}).
  """
  @spec render(String.t(), State.t(), keyword()) :: {String.t(), State.t(), [String.t()]}
  def render(source, %State{} = state, opts \\ []) do
    if template?(source) do
      case run_limited(fn -> render_in_task(source, state) end, opts) do
        {:ok, {:ok, result}} -> result
        {:ok, {:error, message}} -> failed(source, state, syntax_error_text(message))
        {:error, error} -> failed(source, state, error)
      end
    else
      {source, state, []}
    end
  end

  @doc """
  Renders each of `sources` against the same `state` (no source sees another's assigns), returning
  `{text, errors}` per source in order, as `render/3` would for each alone. All of them run in one
  task under `render/3`'s limits, which apply to the whole batch: when it fails, every template
  source gets that error and renders as itself.
  """
  @spec render_many([String.t()], State.t(), keyword()) :: [{String.t(), [String.t()]}]
  def render_many(sources, %State{} = state, opts \\ []) do
    if Enum.any?(sources, &template?/1) do
      batch = fn ->
        Enum.map(sources, fn source ->
          if template?(source) do
            case render_in_task(source, state) do
              {:ok, {text, _state, errors}} -> {text, errors}
              {:error, message} -> {source, [syntax_error_text(message)]}
            end
          else
            {source, []}
          end
        end)
      end

      case run_limited(batch, opts) do
        {:ok, results} -> results
        {:error, error} -> Enum.map(sources, &if(template?(&1), do: {&1, [error]}, else: {&1, []}))
      end
    else
      Enum.map(sources, &{&1, []})
    end
  end

  # Runs `fun` in a supervised task with the heap cap and timeout: `{:ok, result}` or
  # `{:error, message}`.
  defp run_limited(fun, opts) do
    timeout = Keyword.get(opts, :timeout, @timeout)
    max_heap_words = Keyword.get(opts, :max_heap_words, @max_heap_words)

    task =
      Task.Supervisor.async_nolink(
        __MODULE__.TaskSupervisor,
        Mythweaver.Locale.carry(fn ->
          Process.flag(:max_heap_size, %{
            size: max_heap_words,
            kill: true,
            error_logger: false,
            include_shared_binaries: true
          })

          fun.()
        end)
      )

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        {:ok, result}

      {:exit, :killed} ->
        {:error, dgettext("prompts", "Template exceeded its memory limit.")}

      nil ->
        {:error,
         dgettext("prompts", "Template took longer than %{time_limit_ms} ms.",
           time_limit_ms: Mythweaver.Format.number(timeout)
         )}

      {:exit, reason} ->
        gettext_comment("The placeholder is the raw Erlang exit reason, untranslated.")

        {:error,
         dpgettext("prompts", "status: a template's render process crashed", "Template failed: %{exit_reason}",
           exit_reason: Exception.format_exit(reason)
         )}
    end
  end

  defp failed(source, state, error), do: {source, state, [error]}

  defp syntax_error_text(message) do
    gettext_comment(
      "Shown in the prompt preview and inspector. The placeholder is the parser's detail: a line and column and the engine's own (English) reason."
    )

    dpgettext("prompts", "status: a template does not parse", "Template syntax error: %{syntax_detail}",
      syntax_detail: message
    )
  end

  defp render_in_task(source, state) do
    with {:ok, template} <- parse(source) do
      context = %Solid.Context{
        counter_vars: State.to_liquid(state),
        vars: state.assigns,
        registers: %{templates: state},
        matcher_module: Solid.Matcher,
        tags: template.tags
      }

      filters = &Filters.apply(&1, &2, state.seed, source)

      {result, context} =
        try do
          Solid.render(template.parsed_template, context, custom_filters: filters)
        catch
          {exp, result, context} when exp in [:break_exp, :continue_exp] -> {result, context}
        end

      errors =
        context.errors
        |> Enum.reverse()
        |> Enum.reject(&is_struct(&1, Solid.UndefinedVariableError))
        |> Enum.map(&Exception.message/1)

      state = %{context.registers.templates | assigns: context.vars}
      {:ok, {IO.iodata_to_binary(result), state, errors}}
    end
  end

  defp tags do
    Solid.Tag.default_tags()
    |> Map.delete("render")
    |> Map.merge(%{"setvar" => SetVarTag, "setglobalvar" => SetVarTag})
  end
end
