defmodule Mythweaver.Notifications.Text do
  @moduledoc """
  The translated notification texts whose wording depends on an item type or memory tier, one whole
  sentence per case (`Mythweaver.Notifications` builds them in the recipient's locale).
  """
  use Gettext, backend: Mythweaver.Gettext

  alias Mythweaver.Accounts.User

  def invite_title(:character, :edit, inviter, item_name) do
    gettext_comment("Notification title in the inbox when someone invites the user to share one of their items.")

    dgettext("notifications", "%{inviter_name} (@%{inviter_handle}) invited you to edit the character “%{item_name}”",
      inviter_name: User.display_name(inviter),
      inviter_handle: inviter.handle,
      item_name: item_name
    )
  end

  def invite_title(:character, :use, inviter, item_name) do
    gettext_comment("Notification title in the inbox when someone invites the user to share one of their items.")

    dgettext("notifications", "%{inviter_name} (@%{inviter_handle}) invited you to use the character “%{item_name}”",
      inviter_name: User.display_name(inviter),
      inviter_handle: inviter.handle,
      item_name: item_name
    )
  end

  def invite_title(:character, :use_read_only, inviter, item_name) do
    gettext_comment("Notification title in the inbox when someone invites the user to share one of their items.")

    dgettext(
      "notifications",
      "%{inviter_name} (@%{inviter_handle}) invited you to use the character “%{item_name}” (read-only)",
      inviter_name: User.display_name(inviter),
      inviter_handle: inviter.handle,
      item_name: item_name
    )
  end

  def invite_title(:lore_book, :edit, inviter, item_name) do
    gettext_comment("Notification title in the inbox when someone invites the user to share one of their items.")

    dgettext("notifications", "%{inviter_name} (@%{inviter_handle}) invited you to edit the lore book “%{item_name}”",
      inviter_name: User.display_name(inviter),
      inviter_handle: inviter.handle,
      item_name: item_name
    )
  end

  def invite_title(:lore_book, :use, inviter, item_name) do
    gettext_comment("Notification title in the inbox when someone invites the user to share one of their items.")

    dgettext("notifications", "%{inviter_name} (@%{inviter_handle}) invited you to use the lore book “%{item_name}”",
      inviter_name: User.display_name(inviter),
      inviter_handle: inviter.handle,
      item_name: item_name
    )
  end

  def invite_title(:lore_book, :use_read_only, inviter, item_name) do
    gettext_comment("Notification title in the inbox when someone invites the user to share one of their items.")

    dgettext(
      "notifications",
      "%{inviter_name} (@%{inviter_handle}) invited you to use the lore book “%{item_name}” (read-only)",
      inviter_name: User.display_name(inviter),
      inviter_handle: inviter.handle,
      item_name: item_name
    )
  end

  def invite_title(:prompt, :edit, inviter, item_name) do
    gettext_comment("Notification title in the inbox when someone invites the user to share one of their items.")

    dgettext("notifications", "%{inviter_name} (@%{inviter_handle}) invited you to edit the prompt “%{item_name}”",
      inviter_name: User.display_name(inviter),
      inviter_handle: inviter.handle,
      item_name: item_name
    )
  end

  def invite_title(:prompt, :use, inviter, item_name) do
    gettext_comment("Notification title in the inbox when someone invites the user to share one of their items.")

    dgettext("notifications", "%{inviter_name} (@%{inviter_handle}) invited you to use the prompt “%{item_name}”",
      inviter_name: User.display_name(inviter),
      inviter_handle: inviter.handle,
      item_name: item_name
    )
  end

  def invite_title(:prompt, :use_read_only, inviter, item_name) do
    gettext_comment("Notification title in the inbox when someone invites the user to share one of their items.")

    dgettext(
      "notifications",
      "%{inviter_name} (@%{inviter_handle}) invited you to use the prompt “%{item_name}” (read-only)",
      inviter_name: User.display_name(inviter),
      inviter_handle: inviter.handle,
      item_name: item_name
    )
  end

  def invite_title(:block, :edit, inviter, item_name) do
    gettext_comment("Notification title in the inbox when someone invites the user to share one of their items.")

    dgettext(
      "notifications",
      "%{inviter_name} (@%{inviter_handle}) invited you to edit the prompt block “%{item_name}”",
      inviter_name: User.display_name(inviter),
      inviter_handle: inviter.handle,
      item_name: item_name
    )
  end

  def invite_title(:block, :use, inviter, item_name) do
    gettext_comment("Notification title in the inbox when someone invites the user to share one of their items.")

    dgettext("notifications", "%{inviter_name} (@%{inviter_handle}) invited you to use the prompt block “%{item_name}”",
      inviter_name: User.display_name(inviter),
      inviter_handle: inviter.handle,
      item_name: item_name
    )
  end

  def invite_title(:block, :use_read_only, inviter, item_name) do
    gettext_comment("Notification title in the inbox when someone invites the user to share one of their items.")

    dgettext(
      "notifications",
      "%{inviter_name} (@%{inviter_handle}) invited you to use the prompt block “%{item_name}” (read-only)",
      inviter_name: User.display_name(inviter),
      inviter_handle: inviter.handle,
      item_name: item_name
    )
  end

  def invite_title(:outlet, :edit, inviter, item_name) do
    gettext_comment("Notification title in the inbox when someone invites the user to share one of their items.")

    dgettext("notifications", "%{inviter_name} (@%{inviter_handle}) invited you to edit the outlet “%{item_name}”",
      inviter_name: User.display_name(inviter),
      inviter_handle: inviter.handle,
      item_name: item_name
    )
  end

  def invite_title(:outlet, :use, inviter, item_name) do
    gettext_comment("Notification title in the inbox when someone invites the user to share one of their items.")

    dgettext("notifications", "%{inviter_name} (@%{inviter_handle}) invited you to use the outlet “%{item_name}”",
      inviter_name: User.display_name(inviter),
      inviter_handle: inviter.handle,
      item_name: item_name
    )
  end

  def invite_title(:outlet, :use_read_only, inviter, item_name) do
    gettext_comment("Notification title in the inbox when someone invites the user to share one of their items.")

    dgettext(
      "notifications",
      "%{inviter_name} (@%{inviter_handle}) invited you to use the outlet “%{item_name}” (read-only)",
      inviter_name: User.display_name(inviter),
      inviter_handle: inviter.handle,
      item_name: item_name
    )
  end

  def invite_title(:script, :edit, inviter, item_name) do
    gettext_comment("Notification title in the inbox when someone invites the user to share one of their items.")

    dgettext("notifications", "%{inviter_name} (@%{inviter_handle}) invited you to edit the script “%{item_name}”",
      inviter_name: User.display_name(inviter),
      inviter_handle: inviter.handle,
      item_name: item_name
    )
  end

  def invite_title(:script, :use, inviter, item_name) do
    gettext_comment("Notification title in the inbox when someone invites the user to share one of their items.")

    dgettext("notifications", "%{inviter_name} (@%{inviter_handle}) invited you to use the script “%{item_name}”",
      inviter_name: User.display_name(inviter),
      inviter_handle: inviter.handle,
      item_name: item_name
    )
  end

  def invite_title(:script, :use_read_only, inviter, item_name) do
    gettext_comment("Notification title in the inbox when someone invites the user to share one of their items.")

    dgettext(
      "notifications",
      "%{inviter_name} (@%{inviter_handle}) invited you to use the script “%{item_name}” (read-only)",
      inviter_name: User.display_name(inviter),
      inviter_handle: inviter.handle,
      item_name: item_name
    )
  end

  def invite_title(:memory_profile, :edit, inviter, item_name) do
    gettext_comment("Notification title in the inbox when someone invites the user to share one of their items.")

    dgettext(
      "notifications",
      "%{inviter_name} (@%{inviter_handle}) invited you to edit the memory profile “%{item_name}”",
      inviter_name: User.display_name(inviter),
      inviter_handle: inviter.handle,
      item_name: item_name
    )
  end

  def invite_title(:memory_profile, :use, inviter, item_name) do
    gettext_comment("Notification title in the inbox when someone invites the user to share one of their items.")

    dgettext(
      "notifications",
      "%{inviter_name} (@%{inviter_handle}) invited you to use the memory profile “%{item_name}”",
      inviter_name: User.display_name(inviter),
      inviter_handle: inviter.handle,
      item_name: item_name
    )
  end

  def invite_title(:memory_profile, :use_read_only, inviter, item_name) do
    gettext_comment("Notification title in the inbox when someone invites the user to share one of their items.")

    dgettext(
      "notifications",
      "%{inviter_name} (@%{inviter_handle}) invited you to use the memory profile “%{item_name}” (read-only)",
      inviter_name: User.display_name(inviter),
      inviter_handle: inviter.handle,
      item_name: item_name
    )
  end

  def invite_title(:side_prompt, :edit, inviter, item_name) do
    gettext_comment("Notification title in the inbox when someone invites the user to share one of their items.")

    dgettext("notifications", "%{inviter_name} (@%{inviter_handle}) invited you to edit the side prompt “%{item_name}”",
      inviter_name: User.display_name(inviter),
      inviter_handle: inviter.handle,
      item_name: item_name
    )
  end

  def invite_title(:side_prompt, :use, inviter, item_name) do
    gettext_comment("Notification title in the inbox when someone invites the user to share one of their items.")

    dgettext("notifications", "%{inviter_name} (@%{inviter_handle}) invited you to use the side prompt “%{item_name}”",
      inviter_name: User.display_name(inviter),
      inviter_handle: inviter.handle,
      item_name: item_name
    )
  end

  def invite_title(:side_prompt, :use_read_only, inviter, item_name) do
    gettext_comment("Notification title in the inbox when someone invites the user to share one of their items.")

    dgettext(
      "notifications",
      "%{inviter_name} (@%{inviter_handle}) invited you to use the side prompt “%{item_name}” (read-only)",
      inviter_name: User.display_name(inviter),
      inviter_handle: inviter.handle,
      item_name: item_name
    )
  end

  def invite_title(:side_prompt_set, :edit, inviter, item_name) do
    gettext_comment("Notification title in the inbox when someone invites the user to share one of their items.")

    dgettext(
      "notifications",
      "%{inviter_name} (@%{inviter_handle}) invited you to edit the side prompt set “%{item_name}”",
      inviter_name: User.display_name(inviter),
      inviter_handle: inviter.handle,
      item_name: item_name
    )
  end

  def invite_title(:side_prompt_set, :use, inviter, item_name) do
    gettext_comment("Notification title in the inbox when someone invites the user to share one of their items.")

    dgettext(
      "notifications",
      "%{inviter_name} (@%{inviter_handle}) invited you to use the side prompt set “%{item_name}”",
      inviter_name: User.display_name(inviter),
      inviter_handle: inviter.handle,
      item_name: item_name
    )
  end

  def invite_title(:side_prompt_set, :use_read_only, inviter, item_name) do
    gettext_comment("Notification title in the inbox when someone invites the user to share one of their items.")

    dgettext(
      "notifications",
      "%{inviter_name} (@%{inviter_handle}) invited you to use the side prompt set “%{item_name}” (read-only)",
      inviter_name: User.display_name(inviter),
      inviter_handle: inviter.handle,
      item_name: item_name
    )
  end

  def invite_title(:ai_model, :edit, inviter, item_name) do
    gettext_comment("Notification title in the inbox when someone invites the user to share one of their items.")

    dgettext("notifications", "%{inviter_name} (@%{inviter_handle}) invited you to edit the AI model “%{item_name}”",
      inviter_name: User.display_name(inviter),
      inviter_handle: inviter.handle,
      item_name: item_name
    )
  end

  def invite_title(:ai_model, :use, inviter, item_name) do
    gettext_comment("Notification title in the inbox when someone invites the user to share one of their items.")

    dgettext("notifications", "%{inviter_name} (@%{inviter_handle}) invited you to use the AI model “%{item_name}”",
      inviter_name: User.display_name(inviter),
      inviter_handle: inviter.handle,
      item_name: item_name
    )
  end

  def invite_title(:ai_model, :use_read_only, inviter, item_name) do
    gettext_comment("Notification title in the inbox when someone invites the user to share one of their items.")

    dgettext(
      "notifications",
      "%{inviter_name} (@%{inviter_handle}) invited you to use the AI model “%{item_name}” (read-only)",
      inviter_name: User.display_name(inviter),
      inviter_handle: inviter.handle,
      item_name: item_name
    )
  end

  def ended_title(:character, :edit, item_name) do
    gettext_comment("Notification title in the inbox when the user loses access to a shared item.")
    dgettext("notifications", "You can no longer edit the character “%{item_name}”", item_name: item_name)
  end

  def ended_title(:character, :use, item_name) do
    gettext_comment("Notification title in the inbox when the user loses access to a shared item.")
    dgettext("notifications", "You can no longer use the character “%{item_name}”", item_name: item_name)
  end

  def ended_title(:lore_book, :edit, item_name) do
    gettext_comment("Notification title in the inbox when the user loses access to a shared item.")
    dgettext("notifications", "You can no longer edit the lore book “%{item_name}”", item_name: item_name)
  end

  def ended_title(:lore_book, :use, item_name) do
    gettext_comment("Notification title in the inbox when the user loses access to a shared item.")
    dgettext("notifications", "You can no longer use the lore book “%{item_name}”", item_name: item_name)
  end

  def ended_title(:prompt, :edit, item_name) do
    gettext_comment("Notification title in the inbox when the user loses access to a shared item.")
    dgettext("notifications", "You can no longer edit the prompt “%{item_name}”", item_name: item_name)
  end

  def ended_title(:prompt, :use, item_name) do
    gettext_comment("Notification title in the inbox when the user loses access to a shared item.")
    dgettext("notifications", "You can no longer use the prompt “%{item_name}”", item_name: item_name)
  end

  def ended_title(:block, :edit, item_name) do
    gettext_comment("Notification title in the inbox when the user loses access to a shared item.")
    dgettext("notifications", "You can no longer edit the prompt block “%{item_name}”", item_name: item_name)
  end

  def ended_title(:block, :use, item_name) do
    gettext_comment("Notification title in the inbox when the user loses access to a shared item.")
    dgettext("notifications", "You can no longer use the prompt block “%{item_name}”", item_name: item_name)
  end

  def ended_title(:outlet, :edit, item_name) do
    gettext_comment("Notification title in the inbox when the user loses access to a shared item.")
    dgettext("notifications", "You can no longer edit the outlet “%{item_name}”", item_name: item_name)
  end

  def ended_title(:outlet, :use, item_name) do
    gettext_comment("Notification title in the inbox when the user loses access to a shared item.")
    dgettext("notifications", "You can no longer use the outlet “%{item_name}”", item_name: item_name)
  end

  def ended_title(:script, :edit, item_name) do
    gettext_comment("Notification title in the inbox when the user loses access to a shared item.")
    dgettext("notifications", "You can no longer edit the script “%{item_name}”", item_name: item_name)
  end

  def ended_title(:script, :use, item_name) do
    gettext_comment("Notification title in the inbox when the user loses access to a shared item.")
    dgettext("notifications", "You can no longer use the script “%{item_name}”", item_name: item_name)
  end

  def ended_title(:memory_profile, :edit, item_name) do
    gettext_comment("Notification title in the inbox when the user loses access to a shared item.")
    dgettext("notifications", "You can no longer edit the memory profile “%{item_name}”", item_name: item_name)
  end

  def ended_title(:memory_profile, :use, item_name) do
    gettext_comment("Notification title in the inbox when the user loses access to a shared item.")
    dgettext("notifications", "You can no longer use the memory profile “%{item_name}”", item_name: item_name)
  end

  def ended_title(:side_prompt, :edit, item_name) do
    gettext_comment("Notification title in the inbox when the user loses access to a shared item.")
    dgettext("notifications", "You can no longer edit the side prompt “%{item_name}”", item_name: item_name)
  end

  def ended_title(:side_prompt, :use, item_name) do
    gettext_comment("Notification title in the inbox when the user loses access to a shared item.")
    dgettext("notifications", "You can no longer use the side prompt “%{item_name}”", item_name: item_name)
  end

  def ended_title(:side_prompt_set, :edit, item_name) do
    gettext_comment("Notification title in the inbox when the user loses access to a shared item.")
    dgettext("notifications", "You can no longer edit the side prompt set “%{item_name}”", item_name: item_name)
  end

  def ended_title(:side_prompt_set, :use, item_name) do
    gettext_comment("Notification title in the inbox when the user loses access to a shared item.")
    dgettext("notifications", "You can no longer use the side prompt set “%{item_name}”", item_name: item_name)
  end

  def ended_title(:ai_model, :edit, item_name) do
    gettext_comment("Notification title in the inbox when the user loses access to a shared item.")
    dgettext("notifications", "You can no longer edit the AI model “%{item_name}”", item_name: item_name)
  end

  def ended_title(:ai_model, :use, item_name) do
    gettext_comment("Notification title in the inbox when the user loses access to a shared item.")
    dgettext("notifications", "You can no longer use the AI model “%{item_name}”", item_name: item_name)
  end

  def owned_title(:character, item_name) do
    gettext_comment("Notification title in the inbox when another user hands an item over to the user.")
    dgettext("notifications", "You now own the character “%{item_name}”", item_name: item_name)
  end

  def owned_title(:lore_book, item_name) do
    gettext_comment("Notification title in the inbox when another user hands an item over to the user.")
    dgettext("notifications", "You now own the lore book “%{item_name}”", item_name: item_name)
  end

  def owned_title(:prompt, item_name) do
    gettext_comment("Notification title in the inbox when another user hands an item over to the user.")
    dgettext("notifications", "You now own the prompt “%{item_name}”", item_name: item_name)
  end

  def owned_title(:block, item_name) do
    gettext_comment("Notification title in the inbox when another user hands an item over to the user.")
    dgettext("notifications", "You now own the prompt block “%{item_name}”", item_name: item_name)
  end

  def owned_title(:outlet, item_name) do
    gettext_comment("Notification title in the inbox when another user hands an item over to the user.")
    dgettext("notifications", "You now own the outlet “%{item_name}”", item_name: item_name)
  end

  def owned_title(:script, item_name) do
    gettext_comment("Notification title in the inbox when another user hands an item over to the user.")
    dgettext("notifications", "You now own the script “%{item_name}”", item_name: item_name)
  end

  def owned_title(:memory_profile, item_name) do
    gettext_comment("Notification title in the inbox when another user hands an item over to the user.")
    dgettext("notifications", "You now own the memory profile “%{item_name}”", item_name: item_name)
  end

  def owned_title(:side_prompt, item_name) do
    gettext_comment("Notification title in the inbox when another user hands an item over to the user.")
    dgettext("notifications", "You now own the side prompt “%{item_name}”", item_name: item_name)
  end

  def owned_title(:side_prompt_set, item_name) do
    gettext_comment("Notification title in the inbox when another user hands an item over to the user.")
    dgettext("notifications", "You now own the side prompt set “%{item_name}”", item_name: item_name)
  end

  def owned_title(:ai_model, item_name) do
    gettext_comment("Notification title in the inbox when another user hands an item over to the user.")
    dgettext("notifications", "You now own the AI model “%{item_name}”", item_name: item_name)
  end

  def ready_title(1, chat_title) do
    gettext_comment(
      "Notification title in the inbox when enough memory entries exist to consolidate into the named higher tier."
    )

    dgettext("notifications", "Ready to consolidate an Arc — %{chat_title}", chat_title: chat_title)
  end

  def ready_title(2, chat_title) do
    gettext_comment(
      "Notification title in the inbox when enough memory entries exist to consolidate into the named higher tier."
    )

    dgettext("notifications", "Ready to consolidate a Chapter — %{chat_title}", chat_title: chat_title)
  end

  def ready_title(3, chat_title) do
    gettext_comment(
      "Notification title in the inbox when enough memory entries exist to consolidate into the named higher tier."
    )

    dgettext("notifications", "Ready to consolidate a Book — %{chat_title}", chat_title: chat_title)
  end

  def ready_title(4, chat_title) do
    gettext_comment(
      "Notification title in the inbox when enough memory entries exist to consolidate into the named higher tier."
    )

    dgettext("notifications", "Ready to consolidate a Legend — %{chat_title}", chat_title: chat_title)
  end

  def ready_title(5, chat_title) do
    gettext_comment(
      "Notification title in the inbox when enough memory entries exist to consolidate into the named higher tier."
    )

    dgettext("notifications", "Ready to consolidate a Series — %{chat_title}", chat_title: chat_title)
  end

  def ready_title(6, chat_title) do
    gettext_comment(
      "Notification title in the inbox when enough memory entries exist to consolidate into the named higher tier."
    )

    dgettext("notifications", "Ready to consolidate an Epic — %{chat_title}", chat_title: chat_title)
  end

  def ready_body(1, book_name) do
    gettext_comment("Notification body under a consolidation-ready title; the book name is a memory book.")
    dgettext("notifications", "%{book_name}: enough memories for a new Arc.", book_name: book_name)
  end

  def ready_body(2, book_name) do
    gettext_comment("Notification body under a consolidation-ready title; the book name is a memory book.")
    dgettext("notifications", "%{book_name}: enough arcs for a new Chapter.", book_name: book_name)
  end

  def ready_body(3, book_name) do
    gettext_comment("Notification body under a consolidation-ready title; the book name is a memory book.")
    dgettext("notifications", "%{book_name}: enough chapters for a new Book.", book_name: book_name)
  end

  def ready_body(4, book_name) do
    gettext_comment("Notification body under a consolidation-ready title; the book name is a memory book.")
    dgettext("notifications", "%{book_name}: enough books for a new Legend.", book_name: book_name)
  end

  def ready_body(5, book_name) do
    gettext_comment("Notification body under a consolidation-ready title; the book name is a memory book.")
    dgettext("notifications", "%{book_name}: enough legends for a new Series.", book_name: book_name)
  end

  def ready_body(6, book_name) do
    gettext_comment("Notification body under a consolidation-ready title; the book name is a memory book.")
    dgettext("notifications", "%{book_name}: enough series for a new Epic.", book_name: book_name)
  end
end
