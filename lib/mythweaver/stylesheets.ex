defmodule Mythweaver.Stylesheets do
  @moduledoc """
  The custom stylesheets every page loads, from the `appearance.*` settings: the site's
  (`appearance.site_css`, served as written) and the viewer's own (`appearance.user_css`). A user's
  sheet is held to `Mythweaver.Stylesheets.Policy` as `restriction/1` says: not at all while
  `appearance.restrict_user_css` is off, else with font-provider `@import`s permitted while
  `appearance.allow_third_party_fonts` is on. One saved under a looser restriction is not served
  once a stricter one is in force.

  Both are delivered as files (`MythweaverWeb.StylesheetController`), `@import`ed by the root layout
  into the `userstyles.site` and `userstyles.user` cascade layers, at URLs carrying `versions/1`.

  Every function takes a scope; pass `%Scope{}` when signed out (no user sheet).
  """

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Settings
  alias Mythweaver.Stylesheets.Policy

  @restriction_keys ["appearance.restrict_user_css", "appearance.allow_third_party_fonts"]

  @doc "The site stylesheet, `\"\"` when none is set."
  @spec site(Scope.t()) :: String.t()
  def site(%Scope{} = scope), do: Settings.get(scope, "appearance.site_css") || ""

  @doc "`scope`'s own stylesheet as served: `\"\"` when none is set or it breaks the restriction now on."
  @spec user(Scope.t()) :: String.t()
  def user(%Scope{} = scope) do
    %{"appearance.user_css" => css} =
      values = Settings.get_many(scope, ["appearance.user_css" | @restriction_keys])

    if css && not blocked?(css, restriction_of(values)), do: css, else: ""
  end

  @doc """
  The rules `scope`'s own sheet is held to: `nil` while `appearance.restrict_user_css` is off, else
  `Policy.check/2`'s options.
  """
  @spec restriction(Scope.t()) :: Policy.options() | nil
  def restriction(%Scope{} = scope), do: scope |> Settings.get_many(@restriction_keys) |> restriction_of()

  @doc """
  A short hash of each sheet's settings, for its URL, or `nil` when the sheet is unset. The user
  version covers the restriction too, so toggling it changes the URL. Runs no policy check: it is
  read on every page render.
  """
  @spec versions(Scope.t()) :: %{site: String.t() | nil, user: String.t() | nil}
  def versions(%Scope{} = scope) do
    %{"appearance.site_css" => site_css, "appearance.user_css" => user_css} =
      values = Settings.get_many(scope, ["appearance.site_css", "appearance.user_css" | @restriction_keys])

    %{site: version(site_css), user: user_css && version({user_css, restriction_of(values)})}
  end

  @doc "Whether `css` is set but not served, because it breaks `restriction` (`restriction/1`)."
  @spec blocked?(String.t() | nil, Policy.options() | nil) :: boolean()
  def blocked?(_css, nil), do: false
  def blocked?(css, restriction), do: is_binary(css) and Policy.check(css, restriction) != :ok

  defp restriction_of(%{"appearance.restrict_user_css" => false}), do: nil
  defp restriction_of(%{"appearance.allow_third_party_fonts" => fonts?}), do: [webfonts: fonts?]

  defp version(nil), do: nil

  defp version(term) do
    :sha256
    |> :crypto.hash(:erlang.term_to_binary(term))
    |> binary_part(0, 9)
    |> Base.url_encode64(padding: false)
  end
end
