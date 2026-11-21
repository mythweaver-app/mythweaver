defmodule Mythweaver.Attachments.DocumentText do
  @moduledoc """
  The text of an uploaded document (a PDF, or a plain-text/Markdown file), extracted once when it
  is stored so every model can read it.

  A PDF is parsed by `Pdf.Reader` in its own heap-capped, timed process under
  `Mythweaver.Attachments.TaskSupervisor`, the way `Mythweaver.Templates.render/3` runs a template,
  so a hostile file cannot exhaust the caller's memory or hang it. The result is trimmed and cut to
  100,000 characters.
  """

  alias Mythweaver.Attachments.TaskSupervisor

  @timeout 30_000
  @max_heap_words 50_000_000
  @max_chars 100_000

  @type result :: %{text: String.t(), page_count: pos_integer() | nil}

  @spec extract(String.t(), binary()) :: {:ok, result()} | {:error, term()}
  def extract(content_type, bytes) when is_binary(bytes) do
    task =
      Task.Supervisor.async_nolink(TaskSupervisor, fn ->
        Process.flag(:max_heap_size, %{
          size: @max_heap_words,
          kill: true,
          error_logger: false,
          include_shared_binaries: true
        })

        do_extract(content_type, bytes)
      end)

    case Task.yield(task, @timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, %{text: text} = result}} -> {:ok, %{result | text: clip(text)}}
      {:ok, {:error, reason}} -> {:error, reason}
      {:exit, :killed} -> {:error, :memory_limit}
      {:exit, reason} -> {:error, {:exit, reason}}
      nil -> {:error, :timeout}
    end
  end

  defp do_extract("application/pdf", bytes) do
    with {:ok, doc} <- Pdf.Reader.open(bytes, recover: true),
         {:ok, [_ | _] = pages, _doc} <- Pdf.Reader.read(doc, shape: :text) do
      {:ok, %{text: Enum.join(pages, "\n\n"), page_count: length(pages)}}
    else
      {:ok, [], _doc} -> {:error, :no_pages}
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_extract("text/" <> _, bytes) do
    if String.valid?(bytes), do: {:ok, %{text: bytes, page_count: nil}}, else: {:error, :invalid_utf8}
  end

  defp do_extract(type, _bytes), do: {:error, {:unsupported_type, type}}

  defp clip(text) do
    text = String.trim(text)

    if String.length(text) > @max_chars,
      do: String.slice(text, 0, @max_chars) <> "\n[…truncated]",
      else: text
  end
end
