defmodule Mythweaver.Locale do
  @moduledoc """
  The language and regional format text is built in, and the process state that carries them.

  The two are chosen separately, first non-nil wins (`resolve/2`):

    * **language**, the UI text (`Mythweaver.Gettext`): the user's `appearance.language`, the first
      `Accept-Language` tag the app has a catalog for, the site's `appearance.default_language`,
      then `"en"`. Only languages with a catalog (`language_options/0`) can be chosen. Stored as a
      Gettext locale id (`"en"`, `"pt_BR"`).
    * **regional format**, how numbers, dates, money and units are written (Localize and
      `Mythweaver.Format`): the user's `appearance.locale`, the browser's best CLDR match, the
      site's `appearance.default_locale`, then `Localize.default_locale/0` (`:en`). Any supported
      CLDR locale (`format_options/0`). Stored as `id/1`'s form (`"de"`, `"pt-PT"`).

  Text built for someone other than the viewer (notifications, push, background job errors) uses
  `for_user/1`, which stands in their last browser match (`users.browser_locale`) for the header:
  its regional format, and its language when the app has a catalog for it.

  `put/1` sets both process states; `with_locale/2` and `with_user_locale/2` scope both to a
  function; `carry/1` takes the caller's into a task.
  """

  alias Localize.Locale.LocaleDisplay
  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Accounts.User
  alias Mythweaver.Repo
  alias Mythweaver.Settings

  @enforce_keys [:language, :format]
  defstruct [:language, :format]

  @typedoc "A language (Gettext locale id) and a regional format (CLDR locale); nil when unknown."
  @type t :: %__MODULE__{language: String.t() | nil, format: Localize.LanguageTag.t() | nil}

  @doc """
  What a browser asks for in its `Accept-Language` header: the first tag the app has a catalog for
  and the best supported CLDR match, each nil when none (or no header).
  """
  @spec from_accept_language(String.t() | nil) :: t()
  def from_accept_language(header) when is_binary(header) do
    {:ok, results} = Localize.AcceptLanguage.parse(header)

    format =
      case Localize.AcceptLanguage.best_match(header) do
        {:ok, tag} -> tag
        {:error, _} -> nil
      end

    language =
      results
      |> Enum.sort_by(&elem(&1, 0), :desc)
      |> Enum.find_value(fn
        {_quality, {:ok, tag}} -> catalog_language(tag)
        {_quality, {:error, _}} -> nil
      end)

    %__MODULE__{language: language, format: format}
  end

  def from_accept_language(nil), do: %__MODULE__{language: nil, format: nil}

  @doc "The language and regional format for `scope`'s viewer, whose browser asked for `browser`."
  @spec resolve(Scope.t() | nil, t()) :: t()
  def resolve(scope, %__MODULE__{} = browser) do
    settings =
      Settings.get_many(scope || %Scope{}, [
        "appearance.language",
        "appearance.default_language",
        "appearance.locale",
        "appearance.default_locale"
      ])

    %__MODULE__{
      language: settings["appearance.language"] || browser.language || settings["appearance.default_language"] || "en",
      format:
        validated(settings["appearance.locale"]) || browser.format ||
          validated(settings["appearance.default_locale"]) || Localize.default_locale()
    }
  end

  @doc "The language and regional format for text built for `user` outside their own request."
  @spec for_user(User.t() | Ecto.UUID.t() | nil) :: t()
  def for_user(%User{} = user) do
    format = validated(user.browser_locale)
    resolve(%Scope{user: user}, %__MODULE__{language: format && catalog_language(format), format: format})
  end

  def for_user(nil), do: resolve(nil, from_accept_language(nil))
  def for_user(user_id) when is_binary(user_id), do: for_user(Repo.get(User, user_id))

  @doc "The process's current language and regional format."
  @spec current() :: t()
  def current, do: %__MODULE__{language: Gettext.get_locale(Mythweaver.Gettext), format: Localize.get_locale()}

  @doc "Sets the process's Gettext and Localize locales."
  @spec put(t()) :: :ok
  def put(%__MODULE__{language: language, format: %Localize.LanguageTag{} = format}) when is_binary(language) do
    {:ok, _} = Localize.put_locale(format)
    _ = Gettext.put_locale(Mythweaver.Gettext, language)
    :ok
  end

  @doc "Runs `fun` in `locale`, restoring both process states afterwards."
  @spec with_locale(t(), (-> result)) :: result when result: term()
  def with_locale(%__MODULE__{language: language, format: format}, fun) when is_function(fun, 0) do
    Localize.with_locale(format, fn -> Gettext.with_locale(Mythweaver.Gettext, language, fun) end)
  end

  @doc "Runs `fun` in the locale of `who`: a user, user id or scope (its initiator), or nil (the site's)."
  @spec with_user_locale(User.t() | Ecto.UUID.t() | Scope.t() | nil, (-> result)) :: result when result: term()
  def with_user_locale(%Scope{} = scope, fun), do: with_user_locale(Scope.initiator_id(scope), fun)
  def with_user_locale(who, fun), do: with_locale(for_user(who), fun)

  @doc "`fun`, wrapped to run in the caller's current locale wherever it runs (a task, `start_async`)."
  @spec carry((-> result)) :: (-> result) when result: term()
  def carry(fun) when is_function(fun, 0) do
    locale = current()
    fn -> with_locale(locale, fun) end
  end

  @doc ~s(The stored form of a regional format: its CLDR locale id, `"de"`, `"pt-PT"`.)
  @spec id(Localize.LanguageTag.t()) :: String.t()
  def id(%Localize.LanguageTag{cldr_locale_id: id}), do: Atom.to_string(id)

  @doc "The current language as a BCP 47 tag, for `<html lang>`: `en`, `pt-BR`."
  @spec html_lang() :: String.t()
  def html_lang, do: Mythweaver.Gettext |> Gettext.get_locale() |> bcp47()

  @doc "The current regional format as a BCP 47 tag, for `<html data-locale>` (`Intl`): `en`, `de-DE`."
  @spec format_tag() :: String.t()
  def format_tag, do: Localize.LanguageTag.to_string(Localize.get_locale())

  @doc "The current language as a `Localize.LanguageTag`, for its plural rules and names."
  @spec language_tag() :: Localize.LanguageTag.t()
  def language_tag, do: validated(html_lang()) || Localize.default_locale()

  @doc "A language's or locale's name in the current language: `German` in en."
  @spec display_name(Localize.LanguageTag.t() | atom() | String.t()) :: String.t()
  def display_name(locale) when is_binary(locale),
    do: LocaleDisplay.display_name!(bcp47(locale), locale: language_tag())

  def display_name(locale), do: LocaleDisplay.display_name!(locale, locale: language_tag())

  @doc """
  Every language the app has a catalog for as `{gettext_id, label}`, sorted by label: its own name
  for itself, followed by its name in the current language when that differs (`Deutsch (German)`).
  """
  @spec language_options() :: [{String.t(), String.t()}]
  def language_options do
    cached(:languages, fn here ->
      for id <- Gettext.known_locales(Mythweaver.Gettext), do: {id, label(bcp47(id), here)}
    end)
  end

  @doc "Every supported regional format as `{id, label}`, labeled and sorted like `language_options/0`."
  @spec format_options() :: [{String.t(), String.t()}]
  def format_options do
    cached(:formats, fn here ->
      for id <- Localize.supported_locales(), id != :und, do: {Atom.to_string(id), label(id, here)}
    end)
  end

  defp cached(kind, build) do
    here = language_tag()
    key = {__MODULE__, kind, id(here), Gettext.known_locales(Mythweaver.Gettext)}

    case :persistent_term.get(key, nil) do
      nil ->
        options = here |> build.() |> Enum.sort_by(&elem(&1, 1))
        :persistent_term.put(key, options)
        options

      options ->
        options
    end
  end

  defp label(id, here) do
    native = LocaleDisplay.display_name!(id, locale: id)
    named_here = LocaleDisplay.display_name!(id, locale: here)
    if native == named_here, do: native, else: "#{native} (#{named_here})"
  end

  # The catalog for `tag`'s language, or nil. `gettext_locale_id/2` falls back across languages
  # (`de` → `en`), which would hide the next browser choice, so the match must keep the language.
  defp catalog_language(tag) do
    with {:ok, id} <- Localize.Locale.gettext_locale_id(tag, Mythweaver.Gettext),
         true <- id |> String.split(["_", "-"]) |> hd() == Atom.to_string(tag.language) do
      id
    else
      _ -> nil
    end
  end

  defp bcp47(gettext_id), do: String.replace(gettext_id, "_", "-")

  defp validated(nil), do: nil

  defp validated(id) when is_binary(id) do
    case Localize.validate_locale(id) do
      {:ok, tag} -> tag
      {:error, _} -> nil
    end
  end
end
