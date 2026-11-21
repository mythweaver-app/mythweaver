defmodule Mythweaver.AI.HuggingFace do
  @moduledoc """
  Hugging Face Hub access: repo-id parsing, the one HTTP helper every Hub request goes through, and
  the metadata lookup behind the model form's "Fill from Hugging Face".

  `lookup/1` reads only the model API, `config.json` and `generation_config.json`, never weights.
  GGUF/quant repos usually ship no `tokenizer.json`, so the lookup follows `cardData.base_model` to
  the repo that does.

  Capability flags are only ever proposed as `true`: a template without a `tools` marker is not
  evidence the model cannot call tools, so Hugging Face never proposes switching one off.
  """

  use Gettext, backend: Mythweaver.Gettext

  alias Mythweaver.AI.Model
  alias Mythweaver.AI.Provider.Adapter

  @hub "https://huggingface.co"
  @max_base_hops 3
  @reserved_prefixes ~w[datasets spaces models]
  @reasoning_pairs [{"<think>", "</think>"}, {"[THINK]", "[/THINK]"}, {"<thinking>", "</thinking>"}]
  @image_pipelines ~w[image-text-to-text image-to-text visual-question-answering]
  @sampler_keys [:temperature, :top_p, :top_k, :min_p, :repetition_penalty, :typical_p]

  defp sampler_label(:temperature), do: dpgettext("ai", "field label: sampler temperature", "Temperature")
  defp sampler_label(:top_p), do: dpgettext("ai", "field label: sampler nucleus sampling cutoff", "Top P")
  defp sampler_label(:top_k), do: dpgettext("ai", "field label: sampler top-k cutoff", "Top K")
  defp sampler_label(:min_p), do: dpgettext("ai", "field label: sampler min-p cutoff", "Min P")

  defp sampler_label(:repetition_penalty),
    do: dpgettext("ai", "field label: sampler repetition penalty", "Repetition penalty")

  defp sampler_label(:typical_p), do: dpgettext("ai", "field label: sampler typical-p cutoff", "Typical P")

  @type metadata :: %{
          source: String.t(),
          tokenizer: String.t(),
          name: String.t(),
          completion_mode: :chat | :text,
          context_window: pos_integer() | nil,
          supports_images: true | nil,
          supports_tools: true | nil,
          supports_thinking: true | nil,
          reasoning_tags: {String.t(), String.t()} | nil,
          sampler: %{
            optional(:temperature | :top_p | :top_k | :min_p | :repetition_penalty | :typical_p) => number()
          }
        }

  @type lookup_error ::
          :invalid_repo
          | {:not_found, String.t()}
          | {:http_error, String.t(), pos_integer()}
          | {:transport_error, String.t()}
          | {:no_tokenizer, String.t()}
          | {:invalid_tokenizer, String.t()}
          | {:too_large, String.t()}
          | {:io_error, String.t()}

  @type row :: %{
          key: String.t(),
          label: String.t(),
          current: term(),
          hf: term(),
          apply?: boolean()
        }

  @doc "The `owner/name` shape of a Hugging Face repo id."
  @spec repo_format() :: Regex.t()
  def repo_format, do: ~r{\A[\w.\-]+/[\w.\-]+\z}

  @doc """
  Extracts `owner/name` from a repo id or a `huggingface.co`/`hf.co` model page URL (any subpath,
  query or fragment). Dataset and Space URLs are not models and return `:error`, as do `.`/`..`
  segments, which would traverse the Hub URL the repo is interpolated into.
  """
  @spec parse_repo(String.t() | nil) :: {:ok, String.t()} | :error
  def parse_repo(input) when is_binary(input) do
    rest =
      input
      |> String.trim()
      |> String.replace(~r{\Ahttps?://}i, "")
      |> String.replace(~r{\Awww\.}i, "")
      |> String.replace(~r{\A(huggingface\.co|hf\.co)/}i, "")

    [path | _] = String.split(rest, ["?", "#"], parts: 2)

    case String.split(path, "/", trim: true) do
      [first | _] when first in @reserved_prefixes ->
        :error

      [owner, name | _] when owner not in [".", ".."] and name not in [".", ".."] ->
        repo = owner <> "/" <> name
        if Regex.match?(repo_format(), repo), do: {:ok, repo}, else: :error

      _ ->
        :error
    end
  end

  def parse_repo(_input), do: :error

  @doc "The parsed repo id of `input`, or `input` unchanged when it does not parse."
  @spec normalize_repo(String.t()) :: String.t()
  def normalize_repo(input) do
    case parse_repo(input) do
      {:ok, repo} -> repo
      :error -> input
    end
  end

  @doc """
  GETs a Hub URL with the `HF_TOKEN` bearer (when set) and retries off. `:hf_req_options` merges
  last so tests can route every Hub request through one `Req.Test` stub.
  """
  @spec get(String.t(), keyword()) :: {:ok, Req.Response.t()} | {:error, Exception.t()}
  def get(url, opts) do
    Req.get(
      Keyword.merge(
        [url: url, headers: auth_headers(), user_agent: Adapter.user_agent(), retry: false] ++
          opts,
        Application.get_env(:mythweaver, :hf_req_options, [])
      )
    )
  end

  @doc """
  Resolves the repo holding `tokenizer.json` (following `base_model`), loads that tokenizer into
  the cache, and gathers every model setting the Hub exposes without downloading weights.

  Only the repo walk and the tokenizer load can fail the lookup; a failed `config.json` or
  `generation_config.json` request just leaves its fields unset.
  """
  @spec lookup(String.t()) :: {:ok, metadata()} | {:error, lookup_error()}
  def lookup(input) do
    with {:ok, repo} <- parse_or_error(input),
         {:ok, chain} <- chain(repo, repo, @max_base_hops, []),
         {tokenizer_repo, _info} = List.last(chain),
         :ok <- ensure_tokenizer(tokenizer_repo) do
      {:ok, metadata(repo, tokenizer_repo, chain)}
    end
  end

  @doc """
  One comparison row per setting Hugging Face supplies, in form order. A row is pre-applied when
  the form's value is blank; the tokenizer row always is, since the user asked for it.
  """
  @spec compare(metadata(), Model.t()) :: [row()]
  def compare(meta, %Model{} = model) do
    sampler = model.sampler

    # An embedding or classifier model can't switch to a generating mode, so the fill never proposes one.
    mode_row =
      if model.completion_mode in [:embedding, :classifier],
        do: [],
        else: [
          {"completion_mode", dpgettext("ai", "field label: AI model completion mode", "Completion mode"),
           model.completion_mode, meta.completion_mode}
        ]

    fields =
      [
        {"tokenizer", dpgettext("ai", "field label: Hugging Face repo of an AI model's tokenizer", "Tokenizer"),
         model.tokenizer, meta.tokenizer},
        {"name", dpgettext("ai", "field label: display name of an AI model", "Name"), model.name, meta.name}
      ] ++
        mode_row ++
        [
          {"context_window",
           dpgettext("ai", "field label: how many tokens an AI model reads at once", "Context window"),
           model.context_window, meta.context_window},
          {"supports_images", dpgettext("ai", "field label: AI model reads images itself", "Supports images"),
           model.supports_images, meta.supports_images},
          {"supports_tools", dpgettext("ai", "field label: AI model can call tools", "Supports tools"),
           model.supports_tools, meta.supports_tools},
          {"supports_thinking",
           dpgettext("ai", "field label: AI model returns separate reasoning", "Separate reasoning"),
           model.supports_thinking, meta.supports_thinking},
          {"reasoning_tags", dpgettext("ai", "field label: tags that wrap an AI model's reasoning", "Reasoning tags"),
           Model.reasoning_tags(model), meta.reasoning_tags}
        ]

    samplers =
      for key <- @sampler_keys, Map.has_key?(meta.sampler, key) do
        {"sampler.#{key}", sampler_label(key), sampler && Map.get(sampler, key), meta.sampler[key]}
      end

    for {key, label, current, hf} <- fields ++ samplers, not is_nil(hf) do
      %{
        key: key,
        label: label,
        current: current,
        hf: hf,
        apply?: key == "tokenizer" or blank?(current)
      }
    end
  end

  @doc "Unset for the purpose of pre-applying: `nil`, `\"\"`, and a boolean's `false` default."
  @spec blank?(term()) :: boolean()
  def blank?(value), do: value in [nil, "", false]

  @doc "Whether the row's two sides display differently."
  @spec changed?(row()) :: boolean()
  def changed?(row), do: display(row.current) != display(row.hf)

  @doc "A value as the compare modal shows it."
  @spec display(term()) :: String.t()
  def display(nil), do: "—"
  def display(true), do: dpgettext("ai", "status: a Hugging Face comparison value is on", "Yes")
  def display(false), do: dpgettext("ai", "status: a Hugging Face comparison value is off", "No")
  def display({prefix, suffix}), do: "#{prefix} … #{suffix}"
  def display(value) when is_atom(value), do: Atom.to_string(value)
  def display(value) when is_number(value), do: Mythweaver.Format.number(value)
  def display(value) when is_binary(value), do: value

  @doc "A form-params patch (string keys and values, as the form posts) of applied, changed rows."
  @spec form_params([row()]) :: map()
  def form_params(rows) do
    for row <- rows, row.apply? and changed?(row), reduce: %{} do
      acc -> put_param(row, acc)
    end
  end

  defp put_param(%{key: "sampler." <> key, hf: value}, acc) do
    Map.update(acc, "sampler", %{key => to_string(value)}, &Map.put(&1, key, to_string(value)))
  end

  defp put_param(%{key: "reasoning_tags", hf: {prefix, suffix}}, acc) do
    Map.merge(acc, %{"reasoning_prefix" => prefix, "reasoning_suffix" => suffix})
  end

  defp put_param(%{key: key, hf: true}, acc), do: Map.put(acc, key, "true")
  defp put_param(%{key: key, hf: value}, acc) when is_atom(value), do: Map.put(acc, key, Atom.to_string(value))
  defp put_param(%{key: key, hf: value}, acc) when is_integer(value), do: Map.put(acc, key, Integer.to_string(value))
  defp put_param(%{key: key, hf: value}, acc), do: Map.put(acc, key, value)

  defp parse_or_error(input) do
    case parse_repo(input) do
      {:ok, repo} -> {:ok, repo}
      :error -> {:error, :invalid_repo}
    end
  end

  # `[{repo, info}, …]` from the input repo to the first one shipping `tokenizer.json`.
  defp chain(source, repo, hops, acc) do
    with {:ok, info} <- model_info(repo) do
      acc = [{repo, info} | acc]

      cond do
        "tokenizer.json" in siblings(info) ->
          {:ok, Enum.reverse(acc)}

        (base = base_model(info)) && hops > 0 && not List.keymember?(acc, base, 0) ->
          chain(source, base, hops - 1, acc)

        true ->
          {:error, {:no_tokenizer, source}}
      end
    end
  end

  defp model_info(repo) do
    case get("#{@hub}/api/models/#{repo}", []) do
      {:ok, %{status: 200, body: body}} ->
        case json_map(body) do
          {:ok, map} -> {:ok, map}
          :error -> {:error, {:http_error, repo, 200}}
        end

      {:ok, %{status: status}} when status in [401, 404] ->
        {:error, {:not_found, repo}}

      {:ok, %{status: status}} ->
        {:error, {:http_error, repo, status}}

      {:error, exception} ->
        {:error, {:transport_error, Exception.message(exception)}}
    end
  end

  # A JSON file served with a non-JSON content type arrives as a binary.
  defp fetch_json(repo, file) do
    case get("#{@hub}/#{repo}/resolve/main/#{file}", []) do
      {:ok, %{status: 200, body: body}} -> json_map(body)
      _ -> :error
    end
  end

  defp json_map(body) when is_map(body), do: {:ok, body}

  defp json_map(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> :error
    end
  end

  defp json_map(_body), do: :error

  defp ensure_tokenizer(repo) do
    case Mythweaver.Tokenizer.ensure(repo) do
      {:ok, _tok} -> :ok
      {:error, :not_found} -> {:error, {:not_found, repo}}
      {:error, {:http_error, 401}} -> {:error, {:not_found, repo}}
      {:error, {:http_error, status}} -> {:error, {:http_error, repo, status}}
      {:error, {:transport_error, _message} = error} -> {:error, error}
      {:error, {:invalid_tokenizer, _reason}} -> {:error, {:invalid_tokenizer, repo}}
      {:error, :too_large} -> {:error, {:too_large, repo}}
      {:error, {:io_error, _reason}} -> {:error, {:io_error, repo}}
    end
  end

  defp metadata(source, tokenizer_repo, chain) do
    template = template(chain)
    reasoning_tags = Enum.find(@reasoning_pairs, &both_in?(&1, template))

    %{
      source: source,
      tokenizer: tokenizer_repo,
      name: tokenizer_repo |> String.split("/") |> List.last(),
      completion_mode: if(template == "", do: :text, else: :chat),
      context_window: context_window(chain),
      supports_images: true_or_nil(Enum.any?(chain, &images?/1)),
      supports_tools: true_or_nil(Regex.match?(~r/\btools\b/, template)),
      supports_thinking:
        true_or_nil(reasoning_tags != nil or String.contains?(template, ["enable_thinking", "reasoning_content"])),
      reasoning_tags: reasoning_tags,
      sampler: sampler(chain)
    }
  end

  defp both_in?({prefix, suffix}, template),
    do: String.contains?(template, prefix) and String.contains?(template, suffix)

  defp true_or_nil(true), do: true
  defp true_or_nil(false), do: nil

  defp template(chain) do
    Enum.find_value(chain, "", fn {_repo, info} ->
      case repo_template(info) do
        "" -> nil
        template -> template
      end
    end)
  end

  defp repo_template(info) do
    [
      info |> get_in(["config", "tokenizer_config", "chat_template"]) |> template_text(),
      info |> get_in(["config", "chat_template_jinja"]) |> template_text(),
      info |> get_in(["gguf", "chat_template"]) |> template_text()
    ]
    |> Enum.join()
  end

  defp template_text(text) when is_binary(text), do: text

  defp template_text(list) when is_list(list) do
    Enum.map_join(list, fn
      %{"template" => text} when is_binary(text) -> text
      _ -> ""
    end)
  end

  defp template_text(_other), do: ""

  defp images?({_repo, info}) do
    files = siblings(info)

    info["pipeline_tag"] in @image_pipelines or "preprocessor_config.json" in files or
      Enum.any?(files, &Regex.match?(~r/mmproj.*\.gguf\z/i, &1))
  end

  defp context_window(chain) do
    Enum.find_value(chain, fn {_repo, info} -> positive(get_in(info, ["gguf", "context_length"])) end) ||
      Enum.find_value(chain, fn {repo, info} ->
        with true <- "config.json" in siblings(info),
             {:ok, config} <- fetch_json(repo, "config.json") do
          positive(config["max_position_embeddings"]) ||
            positive(get_in(config, ["text_config", "max_position_embeddings"]))
        else
          _ -> nil
        end
      end)
  end

  defp positive(n) when is_integer(n) and n > 0, do: n
  defp positive(_other), do: nil

  defp sampler(chain) do
    with {repo, _info} <-
           Enum.find(chain, fn {_repo, info} -> "generation_config.json" in siblings(info) end),
         {:ok, config} <- fetch_json(repo, "generation_config.json"),
         false <- config["do_sample"] == false do
      for key <- @sampler_keys,
          value = config[Atom.to_string(key)],
          is_number(value),
          into: %{},
          do: {key, value}
    else
      _ -> %{}
    end
  end

  defp siblings(info) do
    for %{"rfilename" => name} <- info["siblings"] || [], is_binary(name), do: name
  end

  # `cardData` is free-form repo metadata: the candidate must parse as a repo before it is
  # interpolated into a token-bearing Hub URL and the cache filename.
  defp base_model(%{"cardData" => %{} = card}) do
    candidate =
      case card["base_model"] do
        base when is_binary(base) -> base
        list when is_list(list) -> Enum.find(list, &is_binary/1)
        _ -> nil
      end

    case parse_repo(candidate) do
      {:ok, repo} -> repo
      :error -> nil
    end
  end

  defp base_model(_info), do: nil

  defp auth_headers do
    case Application.get_env(:mythweaver, :hf_token) do
      token when is_binary(token) and token != "" -> [{"authorization", "Bearer " <> token}]
      _ -> []
    end
  end
end
