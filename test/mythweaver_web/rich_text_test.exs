defmodule MythweaverWeb.RichTextTest do
  use ExUnit.Case, async: true

  import MythweaverWeb.RichText

  alias Gettext.Interpolation.Default

  defp html(safe), do: Phoenix.HTML.safe_to_string(safe)

  # What a translation that moves the placeholder renders to.
  defp translated(template, bindings), do: Default.runtime_interpolate(template, bindings)

  test "the code goes wherever the translation puts its placeholder" do
    {:ok, text} = translated("Mit %{logic} geprüft.", %{logic: code("AND ANY")})

    assert html(rich(text)) == "Mit <code>AND ANY</code> geprüft."
  end

  test "both the sentence and the marked text are escaped" do
    text = "a <b> & " <> em("<script>") <> " c"

    assert html(rich(text)) == "a &lt;b&gt; &amp; <em>&lt;script&gt;</em> c"
  end

  test "every wrapper renders its element and leaves no marker behind" do
    text = Enum.join([code("c"), em("e"), strong("s"), kbd("k"), navigate_link("go", "/chats?a=1&b=2")], " ")
    out = html(rich(text))

    assert out ==
             ~s(<code>c</code> <em>e</em> <strong>s</strong> <kbd>k</kbd> ) <>
               ~s(<a href="/chats?a=1&amp;b=2" data-phx-link="redirect" data-phx-link-state="push">go</a>)

    refute out =~ ~r/[\x{F0000}-\x{F0002}]/u
  end
end
