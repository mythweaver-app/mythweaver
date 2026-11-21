defmodule Mythweaver.Tokenizer do
  @moduledoc """
  Counts tokens with a model's own Hugging Face tokenizer, falling back to an estimate.

  A model names its tokenizer by Hugging Face repo id (`Model.tokenizer`). The repo's
  `tokenizer.json` is downloaded once into `cache_dir/0` and survives restarts; the parsed
  tokenizer is a NIF handle kept in an ETS table for the VM's lifetime. A failed load is cached
  for five minutes, so an offline or gated repo costs one request per window, not one per count.

  `Tokenizers.Tokenizer.from_pretrained/2` is deliberately not used: it makes a request to
  Hugging Face on every load, so a restart without network would fall back to estimates even
  with the file on disk. To re-download a tokenizer, delete its file and restart.
  """

  alias Mythweaver.AI.HuggingFace
  alias Mythweaver.AI.Model
  alias Tokenizers.Encoding
  alias Tokenizers.Tokenizer, as: HF

  require Logger

  @table :mythweaver_tokenizers
  @error_ttl_ms 300_000
  @max_tokenizer_bytes 64 * 1024 * 1024

  @doc "Creates the in-memory cache; called once at application start."
  @spec create_cache() :: :ok
  def create_cache do
    _ = :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    :ok
  end

  @doc """
  Counts `text` in `model`'s tokenizer. `:exact` when the model's tokenizer loaded, otherwise
  `:estimate` (`estimate/1`). Blank text is exactly zero.
  """
  @spec count(Model.t() | nil, String.t() | nil) :: {non_neg_integer(), :exact | :estimate}
  def count(_model, text) when text in [nil, ""], do: {0, :exact}

  def count(model, text) do
    case tokenizer(model) do
      {:ok, tok} ->
        {:ok, encoding} = HF.encode(tok, text, add_special_tokens: false)
        {Encoding.n_tokens(encoding), :exact}

      :error ->
        {estimate(text), :estimate}
    end
  end

  @doc "Whether `count/2` is exact for `model`, i.e. its tokenizer loads."
  @spec exact?(Model.t() | nil) :: boolean()
  def exact?(model), do: match?({:ok, _}, tokenizer(model))

  @doc "ceil(chars / 3.3): SillyTavern's estimate when a model has no tokenizer."
  @spec estimate(String.t()) :: non_neg_integer()
  def estimate(text), do: estimate_length(String.length(text))

  @doc "`estimate/1` from a character count already known, for a running total."
  @spec estimate_length(non_neg_integer()) :: non_neg_integer()
  def estimate_length(length), do: div(length * 10 + 32, 33)

  @doc """
  Returns the parsed tokenizer for a Hugging Face repo id, loading it from disk or downloading
  it on a cache miss. Loading runs in the calling process.
  """
  @spec fetch(String.t()) :: {:ok, HF.t()} | {:error, term()}
  def fetch(repo) do
    case :ets.lookup(@table, repo) do
      [{^repo, {:ok, tok}}] ->
        {:ok, tok}

      [{^repo, {:error, reason, at}}] ->
        if now() - at < @error_ttl_ms, do: {:error, reason}, else: load_and_store(repo)

      [] ->
        load_and_store(repo)
    end
  end

  @doc "Loads a tokenizer now, ignoring a cached failure. Used for explicit user actions."
  @spec ensure(String.t()) :: {:ok, HF.t()} | {:error, term()}
  def ensure(repo), do: load_and_store(repo)

  @doc "Directory holding downloaded `tokenizer.json` files, one per repo."
  @spec cache_dir() :: Path.t()
  def cache_dir do
    Application.get_env(
      :mythweaver,
      :tokenizer_cache_dir,
      Path.join(:filename.basedir(:user_cache, "mythweaver"), "tokenizers")
    )
  end

  defp tokenizer(%Model{tokenizer: repo}) when is_binary(repo) and repo != "" do
    case fetch(repo) do
      {:ok, tok} -> {:ok, tok}
      {:error, _} -> :error
    end
  end

  defp tokenizer(_model), do: :error

  defp load_and_store(repo) do
    case load(repo) do
      {:ok, tok} ->
        :ets.insert(@table, {repo, {:ok, tok}})
        {:ok, tok}

      {:error, reason} ->
        Logger.warning("Tokenizer #{repo} unavailable: #{inspect(reason)}")
        :ets.insert(@table, {repo, {:error, reason, now()}})
        {:error, reason}
    end
  end

  defp load(repo) do
    path = Path.join(cache_dir(), String.replace(repo, "/", "--") <> ".json")

    if File.exists?(path) do
      from_file(path)
    else
      with :ok <- download(repo, path), do: from_file(path)
    end
  end

  # A file that does not parse is deleted so the next load downloads it again.
  defp from_file(path) do
    case HF.from_file(path) do
      {:ok, tok} ->
        {:ok, tok}

      {:error, reason} ->
        _ = File.rm(path)
        {:error, {:invalid_tokenizer, reason}}
    end
  end

  # Streamed to a per-call `.part` file and renamed, so a killed download never leaves a truncated
  # `tokenizer.json` for the next boot and two concurrent loads never write one temp file. The body
  # is capped at `max_bytes/0`; past it the download halts with `{:error, :too_large}`. Req follows
  # Hugging Face's CDN redirect and drops `authorization` when the redirect changes host.
  defp download(repo, path) do
    tmp = path <> ".#{System.unique_integer([:positive])}.part"

    with :ok <- io(File.mkdir_p(Path.dirname(path))),
         {:ok, file} <- io(File.open(tmp, [:write, :binary])),
         :ok <- fetch_into(repo, file),
         :ok <- io(File.rename(tmp, path)) do
      :ok
    else
      error ->
        _ = File.rm(tmp)
        error
    end
  end

  defp fetch_into(repo, file) do
    result =
      HuggingFace.get("https://huggingface.co/#{repo}/resolve/main/tokenizer.json",
        decode_body: false,
        into: writer(file, max_bytes())
      )

    _ = File.close(file)

    case result do
      {:ok, %{status: 200} = resp} ->
        resp |> Req.Response.get_private(:download_error) |> download_result()

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, exception} ->
        {:error, {:transport_error, Exception.message(exception)}}
    end
  end

  # Only a 200 body is written; an error page is dropped. Byte count and failure ride in
  # `resp.private`, the one channel `into: fun` threads through the fold.
  defp writer(file, max) do
    fn
      {:data, chunk}, {req, %{status: 200} = resp} ->
        bytes = Req.Response.get_private(resp, :download_bytes, 0) + byte_size(chunk)

        with true <- bytes <= max || :too_large,
             :ok <- :file.write(file, chunk) do
          {:cont, {req, Req.Response.put_private(resp, :download_bytes, bytes)}}
        else
          :too_large -> {:halt, {req, Req.Response.put_private(resp, :download_error, :too_large)}}
          {:error, reason} -> {:halt, {req, Req.Response.put_private(resp, :download_error, {:io_error, reason})}}
        end

      {:data, _chunk}, acc ->
        {:cont, acc}
    end
  end

  defp download_result(nil), do: :ok
  defp download_result(:too_large), do: {:error, :too_large}
  defp download_result({:io_error, _reason} = error), do: {:error, error}

  defp io(:ok), do: :ok
  defp io({:ok, value}), do: {:ok, value}
  defp io({:error, reason}), do: {:error, {:io_error, reason}}

  defp max_bytes, do: Application.get_env(:mythweaver, :tokenizer_max_bytes, @max_tokenizer_bytes)

  defp now, do: System.monotonic_time(:millisecond)
end
