defmodule Mythweaver.GettextCatalogTest do
  @moduledoc """
  Keeps the extracted catalogs (`priv/gettext/*.pot`) translatable: short strings carry a context,
  placeholders say what they hold, no msgid is a sentence fragment, and the contexts that
  `Mythweaver.Settings` and `Mythweaver.Permissions.Catalog` rebuild at runtime still match their
  `*_noop` entries. `errors.pot` follows Ecto's conventions and is skipped.
  """
  use Mythweaver.DataCase, async: true

  alias Expo.Message.Plural
  alias Expo.Message.Singular
  alias Mythweaver.Accounts
  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Permissions.Catalog
  alias Mythweaver.Settings

  @banned_placeholders ~w(count n x value name text thing item number)
  @connectors ~w(and or the a an of to with for in on by from)
  # Roles whose text is a unit, key, short state word or example, which English writes in lowercase
  # without it being a sentence fragment.
  @lowercase_ok_prefixes [
    "unit:",
    "keyboard key:",
    "progress:",
    "badge:",
    "status:",
    "option:",
    "placeholder:",
    "aria label:"
  ]

  defp entries do
    for path <- Path.wildcard("priv/gettext/*.pot"),
        Path.basename(path) != "errors.pot",
        message <- Expo.PO.parse_file!(path).messages do
      %{
        file: Path.basename(path),
        msgid: IO.iodata_to_binary(message.msgid),
        msgctxt: message.msgctxt && IO.iodata_to_binary(message.msgctxt)
      }
    end
  end

  defp describe(%{file: file, msgid: msgid, msgctxt: ctx}), do: "#{file}: #{inspect(msgid)} (msgctxt #{inspect(ctx)})"

  test "the catalogs exist" do
    assert Enum.any?(entries())
  end

  test "every msgid of four words or fewer has a context" do
    missing = for e <- entries(), length(String.split(e.msgid)) <= 4, is_nil(e.msgctxt), do: describe(e)

    assert missing == []
  end

  test "no placeholder has a generic name" do
    banned =
      for e <- entries(),
          [_, name] <- Regex.scan(~r/%\{(\w+)\}/, e.msgid),
          name in @banned_placeholders,
          do: describe(e)

    assert banned == []
  end

  # A sentence (no context) must not start lowercase or end on a connector: that is a piece of a
  # sentence built around it. A labelled role (`button:`, `field label:`, …) is a whole label, so
  # "Log in" or "Add to" before its control is fine; it may start lowercase only in the roles above.
  test "no msgid is a fragment" do
    fragments =
      for e <- entries(), lowercase_start?(e) or connector_end?(e), do: describe(e)

    assert fragments == []
  end

  test "every setting's label is in the catalog under its rebuilt context" do
    owner = owner_scope()
    entries = Settings.entries(owner, :site) ++ Settings.entries(owner, :user)
    catalog = MapSet.new(entries(), &{&1.msgctxt, &1.msgid})

    missing =
      for %{key: key, label: label} <- Enum.uniq_by(entries, & &1.key),
          not MapSet.member?(catalog, {"setting name: " <> key, label}),
          do: key

    assert missing == []
  end

  test "every permission's label is in the catalog under its rebuilt context" do
    catalog = MapSet.new(entries(), &{&1.msgctxt, &1.msgid})

    missing =
      for %{key: key, label: label} <- Catalog.all(),
          not MapSet.member?(catalog, {"permission name: " <> key, label}),
          do: key

    assert missing == []
  end

  # A translation with a placeholder its msgid lacks raises at render (missing binding); one that
  # drops a placeholder loses the value; a fuzzy one is a stale guess. An empty one is allowed: a
  # string added since the last translation pass shows in English until it is translated.
  test "every translation keeps its msgid's placeholders and none is fuzzy" do
    problems =
      for path <- translation_paths(),
          message <- Expo.PO.parse_file!(path).messages,
          problem <- translation_problems(message),
          do: "#{Path.relative_to(path, "priv/gettext")}: #{inspect(IO.iodata_to_binary(message.msgid))} #{problem}"

    assert problems == []
  end

  test "the app has a catalog for more than English, and serves it" do
    assert Enum.sort(Gettext.known_locales(Mythweaver.Gettext)) == ~w(de en es)

    for language <- ~w(de es) do
      translated =
        Gettext.with_locale(Mythweaver.Gettext, language, fn ->
          Gettext.dpgettext(Mythweaver.Gettext, "characters", "button: save the open character", "Save")
        end)

      refute translated == "Save"
    end
  end

  defp translation_paths do
    for path <- Path.wildcard("priv/gettext/*/LC_MESSAGES/*.po"),
        not String.starts_with?(path, "priv/gettext/en/"),
        do: path
  end

  defp translation_problems(%Singular{} = message) do
    fuzzy(message) ++ form_problems(message.msgstr, message.msgid)
  end

  defp translation_problems(%Plural{} = message) do
    sources = %{0 => message.msgid, 1 => message.msgid_plural}

    fuzzy(message) ++
      Enum.flat_map(sources, fn {index, source} -> form_problems(Map.get(message.msgstr, index, []), source) end)
  end

  defp fuzzy(message), do: if(Expo.Message.has_flag?(message, "fuzzy"), do: ["is fuzzy"], else: [])

  defp form_problems(msgstr, source) do
    text = IO.iodata_to_binary(msgstr)

    cond do
      String.trim(text) == "" -> []
      placeholders(text) != placeholders(IO.iodata_to_binary(source)) -> ["changes placeholders: #{inspect(text)}"]
      true -> []
    end
  end

  defp placeholders(text), do: ~r/%\{\w+\}/ |> Regex.scan(text) |> List.flatten() |> Enum.sort()

  defp lowercase_start?(%{msgid: msgid} = e), do: String.match?(msgid, ~r/^\p{Ll}/u) and not lowercase_ok?(e)

  defp lowercase_ok?(%{msgctxt: nil}), do: false
  defp lowercase_ok?(%{msgctxt: "command palette entry (area: action)"}), do: true
  defp lowercase_ok?(%{msgctxt: ctx}), do: String.starts_with?(ctx, @lowercase_ok_prefixes)

  defp connector_end?(%{msgctxt: nil, msgid: msgid}),
    do: (msgid |> String.split() |> List.last("") |> String.downcase()) in @connectors

  defp connector_end?(_entry), do: false

  defp owner_scope do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.register_user(
        %{
          email: "catalog#{n}@example.com",
          handle: "cat_" <> String.downcase(Integer.to_string(n, 36)),
          nickname: "Tester",
          password: "a long test password"
        },
        :owner
      )

    Scope.for_user(user)
  end
end
