defmodule MythweaverWeb.RichText do
  @moduledoc """
  Inline markup inside a translated sentence, so a sentence stays one msgid however much markup it
  holds. The marked-up text goes in as a binding wrapped by `code/1`, `em/1`, `strong/1`, `kbd/1`
  or `navigate_link/2`; `rich/1` escapes the translation and renders each wrapped binding as its
  element:

      {rich(dgettext("lore", "Checked with %{logic} against the second key list.",
        logic: em(dpgettext("lore", "field label: lore entry secondary key logic", "Logic"))))}

  Translators see `Checked with %{logic} against the second key list.` and put `%{logic}` wherever
  their grammar needs it. A wrapped binding is meaningful only to `rich/1`: never pass one to an
  attribute or plain `{…}` render, which would show the marker characters.
  """

  # Supplementary private-use characters: never in a translation, a path or an icon font.
  @open "\u{F0000}"
  @close "\u{F0001}"
  @sep "\u{F0002}"

  @doc "`text` rendered as `<code>` inside a `rich/1` sentence; pass it as a binding."
  @spec code(String.Chars.t()) :: String.t()
  def code(text), do: mark("code", "", text)

  @doc "`text` rendered as `<em>` inside a `rich/1` sentence."
  @spec em(String.Chars.t()) :: String.t()
  def em(text), do: mark("em", "", text)

  @doc "`text` rendered as `<strong>` inside a `rich/1` sentence."
  @spec strong(String.Chars.t()) :: String.t()
  def strong(text), do: mark("strong", "", text)

  @doc "`text` rendered as `<kbd>` inside a `rich/1` sentence."
  @spec kbd(String.Chars.t()) :: String.t()
  def kbd(text), do: mark("kbd", "", text)

  @doc "`text` rendered as a LiveView navigate link to `path` (what `<.link navigate>` renders)."
  @spec navigate_link(String.Chars.t(), String.t()) :: String.t()
  def navigate_link(text, path), do: mark("a", path, text)

  @doc "A translated sentence, escaped, with its wrapped bindings rendered as elements."
  @spec rich(String.t()) :: Phoenix.HTML.safe()
  def rich(text) do
    parts =
      ~r/\x{F0000}(code|em|strong|kbd|a)\x{F0002}([^\x{F0002}]*)\x{F0002}([^\x{F0001}]*)\x{F0001}/u
      |> Regex.split(text, include_captures: true, trim: true)
      |> Enum.map(&part/1)

    {:safe, parts}
  end

  defp mark(tag, attr, text), do: @open <> tag <> @sep <> attr <> @sep <> to_string(text) <> @close

  defp part(@open <> marked) do
    [tag, attr, inner] = marked |> String.trim_trailing(@close) |> String.split(@sep, parts: 3)
    element(tag, attr, escape(inner))
  end

  defp part(plain), do: escape(plain)

  defp element("a", path, inner),
    do: [~s(<a href="), escape(path), ~s(" data-phx-link="redirect" data-phx-link-state="push">), inner, "</a>"]

  defp element(tag, "", inner), do: ["<", tag, ">", inner, "</", tag, ">"]

  defp escape(text) do
    {:safe, iodata} = Phoenix.HTML.html_escape(text)
    iodata
  end
end
