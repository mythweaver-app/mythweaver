# Sharing and chat membership: design plan

Status: design, agreed in an interview on 2026-10-20 and revised on 2026-11-06 (share visibility,
no automatic copies, owner-only publishing, site-gated owner-key AI shares, handles); phases 0
(handles) and 1 (1a editor shares, 1b site visibility and subscribers, 1c lifecycle) built; the
rest not built. Since 1a,
everything anyone creates is personal by default; a site item is an explicit choice of a site
manager (`Ownership.new_owner/3`, `site: true`).
It replaces today's site/personal model, which `research/ownership.md` describes (read that first:
this plan says what changes).

## Decisions

| Area | Decision |
|---|---|
| Shareable types | Lore books, characters, prompts, AI models, scripts; also memory profiles, side prompts / sets, and prompt blocks and outlets on their own. Lore entries, pools and global variables travel only inside a closure. |
| Roles | One **owner** (the creator), any number of **editors** and **subscribers**. |
| Editors | Edit, invite subscribers, uninvite subscribers, receive ownership. They cannot delete the item, invite or remove editors, or publish, release or unpublish it in the catalog. |
| Subscribers | Use, never edit. Whether they may inspect, export or clone depends on the share's visibility. Under either visibility they get personal on/off toggles (lore entries, blocks, scripts) without cloning. |
| Visibility | Every share, catalog listing and site item has a visibility. **Readable**: subscribers may inspect, export and clone the item and its closure. **Runtime-only**: subscribers may use it (chats, prompt build, lore activation, scripts, memory) but never see its protected content, export it or clone it. New invites and listings default to Runtime-only. Only the owner creates a Readable share or changes a visibility; editors invite Runtime-only subscribers only. Owners and editors always read everything. A user's share has no admin bypass. |
| Runtime-only limits | Protected values reach templates only as placeholder tokens, swapped for their text in the final request, and every read surface hides them, the prompt/response inspector included. The aim is to close every easy leak, not all of them: the model still receives the text, so careful prompting can coax it into repeating part. The share dialog says so whenever Runtime-only is selected. |
| Site content | Kept, as **site-owned items every account is subscribed to**, plus ordinary catalog items admins publish. Users may opt out of a site item unless an admin marks it forced. Site managers (`site.*.manage`) act as its editors. Admins keep **move to site** (a user's item becomes site-owned). A site item has its own visibility (`site_visibility`, default Readable); hidden site lore stays a lore-only extra. |
| Dependencies | Sharing gives the same people the same access, at the share's visibility, to the item's whole **closure** (everything it references), tracked as part of that share. |
| Editor's own items | Referencing an item the owner cannot use asks the editor to share it to the owner first. |
| AI models | Sharing a model always allows **bring your own** (subscriber links it to their own connection). **Run on my connection** (owner pays; optional per-subscriber token limit) is offered only to an owner holding `sharing.ai.owner_key`, which no group has by default, so a BYOK site never lets one user's runs spend another user's key. |
| Updates | Invited subscribers see edits live. Catalog items publish **releases**; a release freezes the item and its whole closure; subscribers follow the latest release. |
| Identity | Every account has a unique **handle** (`@name`, how others find and name it) and an optional **nickname** (display text). Email is private: only the account itself and `users.manage` holders ever see it, and nothing looks a user up by email. Built first (phase 0); every later surface names users by nickname and handle. |
| Invites | By handle, into an in-app inbox (accept/reject). Pending invites sent are limited (spam guard). |
| Revocation | Uninvite, unpublish, takedown, owner removal or deletion: the subscriber loses access at once, and **nothing is copied**. Their dependents are **frozen**: a character leaves their chats the way a deleted character would, and its messages keep their text under its name. Every other reference to the item is removed. The owner sees per-kind counts before confirming, and each affected subscriber gets an inbox notice. Nothing comes back if the item is shared again. |
| Clones | Only by a subscriber's explicit action under a Readable share, never automatic. Deep: the readable part of the closure is copied, and closure members the subscriber holds only Runtime-only are referenced, not copied. A clone records `cloned_from` (source and release/version), is the subscriber's own row (owner-count quotas apply) and survives retraction. |
| Owner deletes / leaves | Ownership passes to an editor first (owner picks; default the longest-standing editor). With no editor, every subscriber's dependents are frozen, then the item is deleted under today's rules (a character in the owner's own chats is still refused). Account deletion does this for every owned item. |
| Catalog | Only the item's owner publishes, cuts releases and unpublishes, and publishing needs `catalog.publish`. Admin takedown (`catalog.moderate`), user reports, tags, featured items. A listing shows the publisher's nickname and handle and a subscriber count, never who subscribed. |
| Scripts | A subscribed script is **off until the subscriber enables it**, after seeing which `mw.*` namespaces it calls. A Runtime-only subscriber sees the namespace list, never the body. |
| Chats | One owner; guests invited by handle, with role guest or chat editor; never cloned to guests. |
| Chat editors | Add/remove participants, character locks, turn policy and auto mode, invite/remove guests, edit or delete anyone's messages. |
| Guest view | Transcript and participant list only: no prompt, lore, memory panel, inspector, variables or jobs. |
| Guest limits (per-chat toggles) | Edit only own messages, delete only own messages, swipe/regenerate AI replies, trigger AI replies, run commands and inline scripts, attach images. |
| Characters in chats | Locks are shared: a user may play several characters and a character may have several players. Managers set each player's characters; free switching (opt-in) lets anyone take any character and release their own one at a time. A player holding several picks who they post as per tab ("Post as"). Guests may bring their own characters if the owner allows it per chat; when the guest leaves, the character leaves and its messages keep their text as a detached author. |
| AI cost in chats | Always the chat owner's models and quota, whoever triggers the reply. |
| Turns | Per chat: any human message triggers the turn policy, or AI waits until each human with a locked character has posted (as any of their characters) or skipped. |

## Data model

- **Users**: `users.handle` (required, unique case-insensitively, `[a-z0-9_]`, 3–20 characters;
  shown as `@handle`). The user may change it; every reference is by id, so a rename rewrites
  nothing. `nickname` stays optional display text. `User.display_name/1` is nickname, else
  `@handle`, never the email. The migration backfills handles from each nickname, normalized (else
  `user`), with a `_2`, `_3`… suffix on collision; never from the email, whose local part would
  become public. The forms that take a nickname (`user_setup_live.ex`, `user_settings_live.ex`,
  `user_live.ex`) take the handle too. `Accounts.get_user_by_handle/1` is the lookup invites use
  (added with phase 1, its first caller).
- **Owner stays `user_id`** on every item table (nil = the site). Ownership transfer is an update of
  that column.
- **`shares`** (one table, polymorphic): `item_type` (`Ecto.Enum`), `item_id`, `role`
  (`:editor | :subscriber`), `status` (`:pending | :accepted | :rejected`), `user_id`,
  `invited_by_id`, `ai_mode` (`:owner_key | :own_key`, models only), `token_limit_per_day`
  (owner-key models), `visibility` (`Ecto.Enum` `:readable | :runtime_only`, default
  `:runtime_only`; ignored for `role: :editor`), timestamps. The changeset refuses `:readable`
  unless the actor is the item's owner, and `:owner_key` unless the owner holds
  `sharing.ai.owner_key`. Unique per (item, user). No database foreign key to the item; the
  sharing context keeps it consistent and cleans up on item delete.
  Built in 1a with `role` `:editor` only, `status` `:pending | :accepted | :declined` and an
  `owner_id` (the item's owner, for "every share of this user's items"); the subscriber,
  visibility and AI columns come with their phases.
- **`access_grants`** (derived, rebuilt by `Sharing.Closure`): `user_id`, `item_type`, `item_id`,
  `role`, `share_id`, `visibility` (copied from the share). A row per item a user may reach through
  a share's closure. Rebuilt for a share when it is accepted or revoked, and for every share of an
  item when its references change. This is what `Ownership` queries join, so runtime resolution
  stays one indexed join, not a graph walk. A user's **effective visibility** on an item is Readable
  when they own it, edit it, or hold any accepted Readable grant on it; otherwise it is
  Runtime-only.
  Built in 1a as `{user_id, owner_id, item_type, item_id, access :edit | :use, share_id}`;
  `Sharing.after_change/1` rebuilds an owner's accepted shares after every content write
  (`Changes.broadcast/2`).
- **Site items**: every shareable table gains `site_visibility` (`:readable | :runtime_only`,
  default `:readable`). Lore books' `user_visibility` becomes `site_visibility` with values
  `:readable | :runtime_only | :hidden`:
  - `:visible` maps to `:readable`, `:names_only` to `:runtime_only`, and `:hidden` stays (lore
    only: unlisted and runtime-only).
  - The `user_visibility` wire keys become `site_visibility`: `mw.lore` tables
    (`scripts/api/lore.ex`, the `scripts.ex` docs), the assistant lore tool
    (`assistant/tools/lore.ex`), the bundle codec (`bundle/codec.ex`) and the book editor field
    (`lore_book_live.ex`).
  - Bundle import still reads a legacy `user_visibility` key from older files and maps it the same
    way (`import/bundle_writer.ex`).
- **Site subscriptions**: implicit. `site_opt_outs` (`user_id`, `item_type`, `item_id`) records
  opt-outs; `forced` (today on lore books) extends to any site item that may not be opted out of.
- **`subscriber_toggles`**: `user_id`, `item_type` (`lore_entry | block | script`), `item_id`,
  `enabled`. Read by lore activation, the prompt builder and script triggers for the chat owner.
- **Lineage**: `cloned_from_type`, `cloned_from_id`, `cloned_from_release_id` on each item table.
- **Catalog**: `catalog_listings` (`item_type`, `item_id`, `owner_id`, `published_at`,
  `hidden_at`/`hidden_by_id` for takedown, `featured`, `tags`, `current_release_id`, cached
  `subscriber_count`, `visibility`; grants to catalog subscribers copy it); `catalog_releases`
  (`listing_id`, `version`, `published_by_id`, timestamps); `catalog_subscriptions` (`listing_id`,
  `user_id`); `catalog_reports` (`listing_id`, `reporter_id`, `reason`, `status`).
- **Release rows**: a release deep-copies the closure into ordinary rows marked
  `release_id` (frozen: no editor lists them, every write refuses them). A catalog subscriber's
  access grants point at the current release's rows. Subscriber references are stored against the
  **live item id**; runtime maps live id → current release row through the release, so moving a
  subscriber to the next release is a pointer change, not a rewrite of their chats and items.
- **Chats**: `chat_members` (`chat_id`, `user_id`, `role :editor | :guest`, `status`, invited_by);
  chat settings gain `guest_permissions` (the six toggles), `guests_bring_characters`,
  `free_switching`, `turn_mode (:any | :round)`; `character_locks` (`chat_id`, `character_id`
  unique, `user_id`); `chat_participants.added_by_id` (a guest-brought character).

## Rules

- **Visibility** (`Mythweaver.Sharing.Visibility`): `Mythweaver.Lore.Access`
  (`lib/mythweaver/lore/access.ex`, today "the one rule for hidden lore") generalizes into the one
  content-visibility rule for every shareable type.
  - `content_hidden_for?(scope, row)` says whether the scope's effective visibility is
    Runtime-only. A site row is hidden by its `site_visibility` unless the scope holds
    `site.hidden.view`.
  - `readable(query, scope)` and `listed(query, scope)` are query narrowing.
  - `protected?(row, owner_id)` decides tokens during a build for the chat owner.
  - Every current `Lore.Access` caller moves to it: `export.ex:107`; `export/collect.ex:421,448,
    1009-1012`; `generation/server.ex:669-671`; `memory.ex:208`; `memory/workers/scene.ex:153`;
    `scripts/command.ex:268`; `scripts/api/lore.ex:88`; `lore.ex:70,78,214,237,685,708`;
    `messages/prompt_snapshot.ex:169-170,196-197,227`; `prompts/builder.ex:789`.
  - `Mythweaver.Lore.Protected` (`lib/mythweaver/lore/protected.ex`, token
    `\u{E000}<uuid>\u{E001}`) becomes `Mythweaver.Sharing.Protected`, with tokens for any protected
    value, not only entry text. `Prompts.Builder.build/2` still reveals tokens only after every
    template has rendered (`builder.ex:144-197`).
- **Protected fields**: what a Runtime-only subscriber sees, and what is protected.

  | Type | Shown to Runtime-only subscribers | Protected |
  |---|---|---|
  | Character | name, avatar, sprites and outfits, creator, creator_notes, character_version, pronouns, tags, talkativeness | description, appearance |
  | Lore book | book name and description, entry names (today's `:names_only`) | entry content, keywords, secondary keywords |
  | Prompt, block | prompt and block names and descriptions, block order, role, enabled | block content (its rendered output is redacted in the inspector) |
  | Outlet | everything (key, name, description) | nothing |
  | Script | name, description, trigger, the `mw.*` namespaces its body calls | body; run errors show the line number only |
  | AI model | name, completion_mode, context_window, `supports_*`, costs | api_model_id, sampler, extra_body, reasoning_prefix/suffix, tokenizer, notes, timeouts, caption prompt |
  | Memory profile, side prompt, set | name, description | nothing on the row itself; its prompts follow the prompt rule |

- **Read surfaces**: these must apply `content_hidden_for?/2`; no other surface may read protected
  fields.
  - Editors: a Readable subscriber gets the item's edit page read-only with Clone and Export. A
    Runtime-only subscriber gets a card of the shown fields only.
  - Prompt inspector, Preview and snapshots: `PromptSnapshot.redacted/2` keyed on per-value flags
    recorded at build time, over everything it covers today (sections, injections, template
    errors, the request) plus the `response`: its text and reasoning have every protected value
    the build revealed scrubbed wherever it appears verbatim, so a model echoing one shows only
    the placeholder there. A value whose item the viewer can no longer use is redacted too, so
    retraction covers stored snapshots.
  - `Builder.render_user_text/4` strips tokens, as it does today (`builder.ex:391-392`).
  - The scripts API: `mw.characters` description/appearance and `mw.lore` content/keywords are nil.
  - Assistant tools and the MCP server.
  - Export and `Export.Collect`: Runtime-only rows are never exported and become name references,
    as hidden lore does today.
  - Activated-lore reports (`Generation.Server`) and memory workers (`readable_entries`).
- **`Mythweaver.Ownership` keeps its API**, widened:
  - `editable/2`: own rows, site rows for a site manager, rows with an editor grant.
  - `usable/3` and `for_owner/2`: own rows, site rows the owner has not opted out of (forced ones
    always), rows with an accepted grant (subscriber or editor), catalog release rows.
  - `authorize_edit/2`: owner or editor grant (site rows: site permission); delete stays owner-only
    (`authorize_delete/2`).
  - `reference_ok?(owner_id, target)`: `target` is usable by `owner_id`. Saving a reference the
    item's owner cannot use is refused with a "share it to the owner first" error the editor UI
    turns into a share prompt.
- **Closure** (`Sharing.Closure.of(item)`): the item plus everything it references, by type:
  prompt → blocks, outlets; lore book → entries (and pools holding only its entries); character →
  bound lore books, avatar attachment, character memory books; memory profile → its prompts and
  model; side prompt → prompt, profile, target book; script → dependencies; AI model → caption
  model and, for owner-key shares, the connections it runs on (key never exposed). A share's
  closure carries the share's visibility; closure members owned by an editor are shared to the
  owner first at a visibility the owner of those members picks.
  As built in 1a: the item and its parts (a book's entries, the pools holding only its entries)
  take the share's access; every reference is `:use` only (an editor of a character uses its
  bound books, never edits them). Only the share owner's own rows travel; AI models, memory-book
  locks (each user's own memories), prompt bindings and outlets (referenced by key) never do.
  Runtime auto-selection (enabled scripts, automatic side prompts, the default memory profile)
  ignores shared rows (`Ownership.owned_or_site/2`).
- **Revocation** (`Sharing.revoke/2`, also used by unpublish, takedown, owner removal, item deletion
  and account deletion). In one transaction it:
  1. Computes the grants the subscriber actually loses: items no longer reachable through another
     accepted grant, their own rows or the site.
  2. Applies the fallout below.
  3. Deletes the share and rebuilds its grants.
  4. Sends the inbox notice.

  `impact/2` gives the owner's per-kind counts beforehand. Fallout for the losing user:
  - **Chats they own**:
    - A lost character runs `Messages.detach_character/2`, scoped to those chats: drafts deleted,
      `author_name` snapshot (`author_is_character: false`; today's `detach_character/1` does this
      for every chat). The bodies' expression fields are cleared through
      `MessageBody.expression_changeset/2`.
    - Its participant row is deleted, bypassing the two-participant minimum
      (`Chats.remove_participant/2`'s `:minimum_participants`), and `player_character_id` is
      cleared. A chat left with fewer than two participants keeps its transcript and cannot
      generate until one is added.
    - Chat and participant `ai_model_id` naming a lost model are cleared, so the normal model
      resolution applies.
    - Chat bindings to lost lore books or prompts are deleted.
    - Lost characters' keys are dropped from `chat_memory_settings.character_book_ids` and
      `cast_ids`.
    - Character locks (phase 5) are deleted.
  - **Their own rows**: the reference clean-ups `Lore.Transfer` and `AI.Transfer` apply today to
    "other owners" run for exactly this user. That covers entry character filters, book character
    bindings, profile references, caption models, prompt bindings, and the `ai.default_model` /
    `images.default_caption_model` settings. Their `memory_character_books` rows for lost
    characters are deleted; the books are theirs and stay.
  - **Untouched**: their explicit clones, and memories in their own books.
- **AI**: an own-key share lets a subscriber link the shared model to their own connection; that
  link is the subscriber's, the one place links cross owners. An owner-key share lets the
  subscriber's runs use the owner's links. Each owner-key run checks the owner still holds
  `sharing.ai.owner_key`; once it is withdrawn, those runs refuse with a clear error until the
  owner switches the share to own-key or regains it (the share itself stays). `Quota.check_spend/2`
  moves from "site model" to "who owns the connection", plus the share's own per-subscriber limit.
- **Scripts**: subscription creates a disabled `subscriber_toggles` row for each subscribed script;
  enabling shows `Scripts.API` namespaces the script's body calls.
- **Chat authorization**: `Chats.authorize/2` becomes `Chats.authorize(scope, chat, action)` with
  actions (`:read`, `:post`, `:edit_message`, `:delete_message`, `:regenerate`, `:generate`,
  `:run_scripts`, `:attach`, `:manage`). The owner may do everything; chat editors everything but
  delete the chat; guests what the toggles allow, own messages only where restricted. Every current
  caller (`grep Chats.authorize`) picks its action. Runtime resolution and generation keep using
  the **chat owner** as the scope for resources, models and quota; a job records its initiator
  separately for the Jobs page and audit.
- **Guest-brought characters** get a chat-scoped grant to the chat owner (usable only in that chat),
  removed when the guest leaves; their messages switch to a detached `author_name`.

## Permissions to add (catalog keys)

`sharing.invite` (send invites), `sharing.ai.owner_key` ("Share models on own connections":
subscribers' runs spend the owner's key; off for every group by default), `catalog.publish`,
`catalog.moderate` (takedown, reports, featured), `chats.invite` (invite guests),
`quota.pending_invites` (limit). Existing `content.*.create` and quotas keep governing what a user
owns; subscriptions are not counted.

`lore.hidden.view` is renamed `site.hidden.view` ("See runtime-only and hidden site content"), and
stored grants are migrated. It never applies to a user's shares.

## Phases

Each phase leaves the app working and `mix precommit` green.

0. **Handles**: `users.handle` with its backfill, the handle field on setup, settings and the
   admin user form, and `display_name/1` without the email fallback (which also takes emails out
   of the group member picker, `group_live.ex`). The admin user list (`user_live.ex`) keeps the
   email, behind `users.manage`.
1. **Sharing core**, in three parts:
   - **1a (built): editor shares.** `shares`, invites by handle into an inbox
     (`Mythweaver.Notifications`, Accept/Decline), `access_grants` and `Sharing.Closure`, the
     widened `Ownership` (`authorize_delete/2` owner-only), a Share panel on each item editor
     (invite, remove with impact counts), revocation with freeze (`Sharing.Fallout`) on removal,
     item deletion, account deletion and move to site.
   - **1b-i (built): site visibility.** `site_visibility` on characters, prompts, prompt blocks,
     scripts and lore books (the `user_visibility` cutover; `lore.hidden.view` renamed
     `site.hidden.view`), `Sharing.Visibility` and `Sharing.Protected` replacing
     `Lore.Access`/`Lore.Protected`. Runtime-only characters reach templates as tokens; snapshots
     record the build's protected values (`prompt_snapshots.protected`) and scrub them, and
     hidden blocks' sections, from sections, injections, errors, the request and the response's
     reasoning. Chat reasoning keeps a scrubbed copy (`message_bodies.reasoning_redacted`) and the
     Jobs page's live reasoning is scrubbed; reply text never is. Assistant/MCP tools, the scripts
     API and export hide protected fields. AI models get no visibility until phase 3; memory
     profiles, side prompts and sets none (nothing on them is protected). Export links dropped
     rows by ref (`%{"kind", "uid", "name"}`), which the importer re-matches by origin, then name.
   - **1b-ii (built): subscribers.** `shares.role` `:subscriber` and `shares.visibility`
     (`access_grants.visibility` copied), `Sharing.invite/4` (editors invite Runtime-only
     subscribers), `set_visibility/3`, `leave/2`; share-protected values (`Visibility.share_protected?/2`)
     are always scrubbed, `site.hidden.view` included (`reasoning_share_redacted`). Subscribed items
     are read on `/shared` (`MythweaverWeb.SharedLive`): a card of shown fields, plus the
     protected ones when Readable; not as a read-only editor page.
   - **1c (built): lifecycle.** `Sharing.Clone` (Readable only; lineage `cloned_from_*`; files
     copied; members the cloner may only use are linked, not copied), `Sharing.hand_off/3` (a
     delete with editors gives the item to the chosen or oldest editor; account deletion too),
     site opt-out (`site_opt_outs`, forced books excepted; `/shared` Site content), and site →
     personal moves retired.
2. **Subscriber tweaks (built)**: `subscriber_toggles` (`Sharing.set_toggle/3`) in lore activation,
   prompt build and script triggers/commands; shared scripts off until enabled, with the
   capability list (`Scripts.capabilities/1`); switches on `/shared` cards.
3. **AI sharing (built)**: `:ai_model` is a root type; `shares.ai_mode` (`:own_key` default,
   `:owner_key` gated by `sharing.ai.owner_key`) and `token_limit_per_day`; link selection is
   scoped to the run's chat owner (`AI.next_provider_model/3`); a subscriber's own connection may
   link a shared own-key model (`AI.link_model/4`, the one cross-owner link); spend counts by
   connection owner (`Quota.check_spend/3`); `/shared` model cards connect or show the owner's key.
4. **Catalog (built)**: `Mythweaver.Catalog`. A listing's **mirror** is a frozen copy of the
   closure (rows marked `frozen_listing_id` + `mirror_of_id`, invisible as rows to everyone but
   grant holders), updated in place by each release, so subscribers follow the latest without
   rewriting and no old release rows are kept (`catalog_releases` keeps version metadata). A
   subscription is a subscriber share on the mirror (`shares.catalog_listing_id`), so grants,
   fallout, toggles, cards and clone apply unchanged. `/catalog`, `/catalog/:id`,
   `/catalog/moderation`; publish, release, visibility and unpublish in each editor's Share panel.
5. **Chat membership (built)**: `chat_members` (editor/guest, inbox invites), `Chats.authorize/3`
   with actions, guest toggles (`chats.guest_permissions`), `character_locks` with free switching,
   guest-brought characters (`chat_participants.added_by_id`), `turn_mode: :round` with skips,
   generation and memory jobs resolved as the chat owner (`Chats.run_scope/2`; jobs record the
   initiator), drafts owner-only, the guest-facing chat view and the Members settings tab.
  Limits: a guest-brought character's bound lore does not apply. Read state is per person: the
  owner's cursor is `chats.last_read_at`, each accepted member's `chat_members.last_read_at` (nil:
  their `accepted_at`).

## Resolved (2026-11-07)

- Hand-off when the owner is gone (account deleted) and several editors exist: the oldest editor
  (earliest `accepted_at`) receives ownership.
- Release retention: keep only release rows still referenced (a current release, or one a
  subscriber's chat or item still points at); older unreferenced releases are deleted.
- A guest discovers chats they were invited to through the inbox (an invite notification with
  Accept/Decline, like share invites).
- Chat editors may change the chat's prompt, lore and model; guests ("members") may not.
