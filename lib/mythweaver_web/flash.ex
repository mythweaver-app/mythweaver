defmodule MythweaverWeb.Flash do
  @moduledoc """
  Flash messages shared by every LiveView (imported through `MythweaverWeb`'s `html_helpers`).
  """

  use Gettext, backend: Mythweaver.Gettext

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Format
  alias Mythweaver.Permissions.Catalog

  @doc "The text of a refused action."
  def unauthorized_message do
    gettext_comment("Flash or form error shown when the user tries an action they lack permission for.")
    gettext("You're not allowed to do that.")
  end

  @doc "Flashes that `hold`'s content waits for moderator review (`Mythweaver.Moderation.Holds`)."
  def flash_held(socket, hold) do
    gettext_comment("Flash shown after saving content that now waits for a moderator's decision.")

    Phoenix.LiveView.put_flash(
      socket,
      :info,
      gettext("“%{content_title}” is waiting for moderator review. You'll be notified when it is decided.",
        content_title: hold.title
      )
    )
  end

  @doc "Flashes that the user has too much content waiting for review."
  def flash_hold_limit(socket) do
    gettext_comment("Flash shown when the user's content held for moderator review has reached its limit.")

    Phoenix.LiveView.put_flash(
      socket,
      :error,
      gettext(
        "You have too much waiting for review. Withdraw something on the Submissions page or wait for a decision."
      )
    )
  end

  @doc "Flashes the refused-action error on `socket`."
  def flash_unauthorized(socket), do: Phoenix.LiveView.put_flash(socket, :error, unauthorized_message())

  @doc "The flash text after the viewer clones `item` as `copy`."
  def cloned_message(item, copy) do
    gettext_comment("Flash after the viewer clones a catalog, shared or site item; the editor of the copy opens.")

    dpgettext("sharing", "status: item cloned", "Cloned %{item_name} as %{copy_name}",
      item_name: item.name,
      copy_name: copy.name
    )
  end

  @doc "The flash text when cloning is refused or fails for `reason`."
  def clone_error_message(:unauthorized) do
    gettext_comment("Flash when the viewer may not clone a shared item.")
    dpgettext("sharing", "status: cloning a shared item refused", "You can't clone this.")
  end

  def clone_error_message(:quota_exceeded) do
    gettext_comment("Flash when cloning a shared item would exceed the viewer's quotas.")
    dgettext("sharing", "Cloning this would go over your limits.")
  end

  def clone_error_message(_reason) do
    gettext_comment("Flash when cloning a shared item fails.")
    dpgettext("sharing", "status: cloning a shared item failed", "Could not clone this.")
  end

  @doc """
  The text of a refused action over the limit `key` (`Mythweaver.Permissions.Quota`), with the
  scope's own limit in it.
  """
  @spec quota_text(Scope.t(), String.t()) :: String.t()
  def quota_text(scope, "quota.spend_per_day" = key) do
    amount = with n when is_integer(n) <- limit(scope, key), do: Format.money(n / 100)

    gettext_comment(
      "Flash shown when the user's daily AI spending limit is used up; the placeholder is a money amount."
    )

    gettext("You've spent today's %{spend_limit} on the site's AI connections.", spend_limit: amount)
  end

  def quota_text(scope, "quota.upload_bytes" = key) do
    mib = with n when is_integer(n) <- limit(scope, key), do: Format.number(div(n, 1_048_576))

    gettext_comment("Flash shown when the user's upload storage quota is full.")
    gettext("You've used your upload storage (%{limit_mebibytes} MiB).", limit_mebibytes: mib)
  end

  def quota_text(scope, key) do
    quota_name = key |> Catalog.fetch!() |> Map.fetch!(:label) |> String.downcase()
    limit = with n when is_integer(n) <- limit(scope, key), do: Format.number(n)

    gettext_comment(
      "Flash shown when the user has reached a count limit; %{quota_name} is the limit's lowercased permission name, e.g. \"characters\"."
    )

    gettext("You've reached your limit of %{limit_amount} %{quota_name}.", limit_amount: limit, quota_name: quota_name)
  end

  @doc "Flashes `quota_text/2` for `key` on `socket`."
  def flash_quota(socket, key),
    do: Phoenix.LiveView.put_flash(socket, :error, quota_text(socket.assigns.current_scope, key))

  defp limit(scope, key), do: Scope.limit(scope, key)
end
