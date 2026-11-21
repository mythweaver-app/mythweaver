# Ownership (as built, 2026-10-20)

How content and AI rows are owned today. This is a snapshot for whoever replaces it with sharing:
the sharing design is expected to rework ownership and moves, so treat this as the "before" and
the list of what any replacement must keep or consciously drop. Accounts, permissions and sudo
mode are in `research/accounts.md`.

## The model

- **One column.** Every owned row has `user_id`: nil is **the site's**, a value is **that user's
  own** ("personal"). There is no other owner type, no co-owner and no share table. Deleting a
  user cascades their rows (`on_delete: :delete_all`).
- **Owned tables.** Content (`20261011152152_add_content_owners.exs`): `characters`, `lore_books`,
  `lore_entries`, `lore_pools`, `prompts`, `prompt_blocks`, `prompt_outlets`, `scripts`,
  `variables` (globals only; a chat variable has `chat_id` instead), `memory_profiles`,
  `side_prompts` (and side prompt sets). AI (`20261011060721_…_add_owners.exs`): `providers`,
  `ai_models`.
- **Names are unique per owner**, the site counting as one owner (`unique_index([:user_id, name],
  nulls_distinct: false)`; global variables by key; one default memory profile per owner).
- **Chats** are owned too (`chats.user_id`), but by a different rule: only the owner and the
  accounts it invited (`chat_members`, as chat editors or guests) ever see or act on a chat, per
  action (`Chats.authorize/3`); nobody else does, admins included.

## The rule: `Mythweaver.Ownership` (`lib/mythweaver/ownership.ex`)

Every context goes through this one module; nothing else decides ownership.

| Function | Meaning |
|---|---|
| `site_permission(schema)` | The permission that edits the schema's site rows: `"site.ai.manage"` for `AI.Provider`/`AI.Model`, `"site.content.manage"` for every content schema. Unknown schema raises. |
| `create_permission(schema)` | The permission that creates a user's own rows: `content.characters.create`, `content.lore.create` (books, entries, pools), `content.prompts.create` (prompts, blocks, outlets), `content.scripts.create`, `content.variables.create`, `content.memory.create` (profiles, side prompts, sets), `ai.connections.create` (connections, models). |
| `new_owner(scope, schema, opts)` | Owner of a row `scope` creates: its own when it holds the create permission, else the site when it holds the site permission, else `{:error, :unauthorized}`. With `site: true`, the site (needs the site permission). **What anyone creates is their own by default, site managers included.** |
| `can_create?(scope, schema)` | `new_owner/2` succeeds. Drives the editors' access hooks (`ContentAccess`, `AIAccess`), nav links and palette commands. |
| `authorize_edit(scope, row)` | A site row: the schema's site permission. An own row: its owner only. The site permission grants **no** access to other users' rows. |
| `editable(query, scope)` | Own rows, plus site rows for a site-permission holder. Editor lists. The schema is read off the query's `from`. |
| `usable(query, scope, site?)` / `usable?/3` | Own rows plus site rows when `site?` (content: always; AI models: `site.ai.manage` or `ai.site_models.use`). Pickers and `get_*` used by chats. |
| `for_owner(query, owner_id)` | Site rows plus `owner_id`'s. **Runtime resolution** (generation, prompt build, lore activation, script triggers, memory jobs) filters by the **chat owner**, never by the caller. |
| `owned_exactly(query, owner_id)` | Exactly one owner's rows (nil: the site's). |
| `reference_ok?(owner_id, target)` | A row owned by `owner_id` may reference `target` only if `target` is the site's or `owner_id`'s. Used for memberships, entry character filters, profile references, caption models and the like. |

Consequences worth keeping in mind:

- An admin never sees another user's rows in editors, pickers or chats. The single, deliberate
  exception is the moderation panel (`Mythweaver.Moderation.Lookup`, `moderation.content.view`,
  every look logged; `/moderation/users/:id/data` lists a user's content), which reads any row and
  deletes it as its owner (`moderation.content.delete`) or moves a lore book to the site.
- Because of `reference_ok?/2`, references never point "sideways" between two users, and a site row
  never references a personal one. Every move below exists to restore that invariant.
- **AI links**: a `ProviderModel` only joins a connection and a model of the same owner
  (`AI.link_model/4`), so a site model only runs on site connections and a user's model only on
  that user's connections. Quotas rely on this (`Permissions.Quota.check_spend/2` skips any model
  with an owner).
- Lookups by key resolve the owner's row before the site's (custom outlets, `mw.commands.run`
  names, global variables, prompt bindings at equal specificity).

## Choosing the owner at creation

Every create function takes `opts` with `site: true` for a site row (`Ownership.new_owner/3`);
without it the row is the creator's own. Seeds pass `site: true` explicitly; imports (bundles)
follow the default.

| Area | API | UI |
|---|---|---|
| Content (characters, lore books and pools, prompts, blocks, outlets, scripts, global variables, expression and memory profiles, side prompts and sets) | `create_*(scope, attrs, site: true)` | Owner select on the new-item form, default "Personal", shown to `site.content.manage` holders: `MythweaverWeb.CoreComponents.OwnerSelect.owner_select/1` (`<item>-form-owner`). |
| Tags | `Tags.create_tag(scope, attrs, site: true)` | Owner select on the new tag form (`TagLive`). |
| AI connections, models | `AI.create_provider/3`, `AI.create_model/3` with `site: true` (`AI.new_owner/2`; needs `site.ai.manage`) | Owner select on the new form when `AI.owner_choice?/1` (both permissions held) (`MythweaverWeb.AIOwnership.owner_select/1`). |

Rows created on someone else's behalf take that owner without a choice: a chat's memory book
(`Lore.create_chat_book/3`) is the chat owner's; a model added from a connection's discovery list
(`AI.create_discovered_model/3`) is the connection's owner's; a new lore entry takes its books'
owner; a block created for a prompt (`Prompts.create_block(scope, attrs, for_prompt: prompt)`, from
the prompt's "Create new block") is the prompt owner's, so an editor of a shared prompt can add it.

Badges: site managers see a mixed list, so personal rows are tagged ("Personal" in the lore tree,
a `personal` badge in the AI lists). Plain users see only their own rows and get no badge.

## Moving a row to the site

Moves are the only way ownership changes after creation, and they go one way: a personal row
becomes the site's, never the reverse (sharing phase 1c retired "make personal"; a user who wants
their own copy of a site item clones it). Each move is a transfer module that computes the
**fallout** (every reference a site row may not hold), shows it as an `impact` count per kind in a
confirmation dialog, and removes it in the same transaction as the move. All moves need sudo mode
(`Accounts.sudo?/1`).

| What | Entry point | Who | Moves together | Removed / cleared on the way |
|---|---|---|---|---|
| Lore book | `Lore.transfer_book(scope, book, :site)` (`Lore.Transfer`) | `site.content.manage`, its own book | its entries | entries' memberships in other books and pools; entry character filters and book character bindings naming personal characters; tag filters naming personal tags; side prompts writing into it; its shares (`Sharing.drop_all/2`) |
| A user's lore book → site | `UserData.move_book_to_site/3` (`Lore.Transfer.run/2`, `clear_memory_of:`) | `moderation.content.view` + `moderation.content.delete` + `site.content.manage` | its entries | as above, plus that user's own memory settings, locks and topic suggestions when they cannot edit site books |
| AI connection | `AI.transfer(scope, row, :site)` (`AI.Transfer`) | `site.ai.manage`, a row it may edit | every model linked to it | those models' links to the old owner's other connections; then the model fallout below |
| AI model | `AI.transfer(scope, row, :site)` | same | — | all of its links (relink to a site connection) |
| AI model fallout (both) | | | | caption models that are not the site's |

A move to the site strands nobody else (a site row is everyone's to reference). Removed links stay
removed.

UI: `LoreBookLive` ("Make site book", `lore-book-transfer-modal`), `AIProviderLive` /
`AIModelLive` via `MythweaverWeb.AIOwnership` (`*-owner-transfer`, `*-transfer-modal`), on
personal rows only; `UserDataLive` ("Move to site").

## Known gaps

- **Some rows can't be moved.** Only lore books and AI connections/models move to the site; a
  character, prompt, script or memory row keeps the owner it was created with.
- **Lore transfers don't check names.** `AI.Transfer` refuses a move onto a name the site already
  uses (`{:error, {:name_taken, names}}`); `Lore.Transfer` does not, and would hit the
  `[user_id, name]` unique index.
- **No move between two users**, and none from the site to a user; only the acting user → site
  (and an admin's user → site via user data).
- **Moves are destructive.** They delete or clear references rather than keeping them pending,
  and an undo does not bring them back.
- **Ownership is invisible to plain users**, and to admins only through the badges above.
- **`authorize_edit/2` needs a struct.** The site permission is read from `row.__struct__`, so a
  query selecting a bare `%{user_id: …}` map raises; owner checks select `struct(r, [:id, :user_id])`.

## For the sharing redesign

What the current code would have to change, or what a replacement has to cover:

- `Ownership` is the single choke point: a share rule added to `editable/2`, `usable/3`,
  `for_owner/2`, `authorize_edit/2` and `usable?/3` reaches every editor, picker and runtime path
  (see "Sharing groundwork" in `research/accounts.md`).
- `reference_ok?/2` is what every transfer exists to protect. Shared rows may be referenced across
  owners, so moves need less fallout, but revocation (`research/sharing-plan.md`) reuses the same
  fallout queries for the subscriber who loses access. Keep `Lore.Transfer`'s and `AI.Transfer`'s
  fallout reusable rather than deleting it with the moves.
- The same-owner link rule for AI and the "site model = site connection" equivalence carry the
  spending quota; changing either needs `Quota.check_spend/2` to count by connection.
- The site-vs-personal choice and the two transfer flows are UI on top of `user_id` alone, so
  removing them means deleting `MythweaverWeb.AIOwnership`, `AI.Transfer`, `Lore.Transfer`, the
  `personal:` options and their dialogs, plus `UserData.move_book_to_site/3`.
- Hidden site lore (`Lore.Access`, `Lore.Protected`, `PromptSnapshot.redacted/2`) is the existing
  runtime-only mechanism; the sharing design generalizes it to every shareable type.
