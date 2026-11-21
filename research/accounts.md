# User accounts

How site and personal rows are owned, created and moved today is written up in
`research/ownership.md`.

## Status (step 1, 2026-10-10)

What exists:

- **Tables and schemas.** `users` (`email` citext unique, optional `nickname`, nullable
  `hashed_password`) and `users_tokens` (`token`, `context` `:session`, `user_id` cascading), from
  `priv/repo/migrations/20261010075400_create_users_auth_tables.exs`. Schemas:
  `lib/mythweaver/accounts/user.ex`, `user_token.ex`, and `scope.ex` (`%Scope{user:}`).
- **`Mythweaver.Accounts`** (`lib/mythweaver/accounts.ex`):
  - lookup: `list_users/0`, `get_user/1`, `any_users?/0`, `get_user_by_email_and_password/2`;
  - creation: `register_user/1`, plus `register_first_user/1`, which takes a table lock and refuses
    once any account exists;
  - auto-login: `auto_login_enabled?/0`, `auto_login_user/0`, `auto_login_available?/0`;
  - updates: `update_user_profile/3` (an email change needs the current password),
    `update_user/2` (admin), `update_user_password/3`, `reset_user_password/2` (admin);
  - deletion: `delete_user/1`. It and both password functions return the expired tokens so the
    caller can disconnect sockets;
  - session tokens: `generate_user_session_token/1`, `get_user_by_session_token/1`,
    `delete_user_session_token/1`.
- **`MythweaverWeb.UserAuth`** (`lib/mythweaver_web/user_auth.ex`), after `phx.gen.auth`'s LiveView
  variant. `fetch_current_scope_for_user` sits in `:browser`. `require_authenticated_user` resolves a
  request in this order:
  1. session (or remember-me cookie);
  2. auto-login;
  3. `/setup` when there are no accounts;
  4. `/users/log-in`, storing the GET path as `:user_return_to`.

  The LiveView guard is `on_mount {UserAuth, :require_authenticated}`. Log-out lands on
  `/users/log-in`, not `/`, which auto-login would sign straight back into.
- **Auto-login.** Set by `:auto_login`: on in `config/dev.exs`, off in `config/config.exs` and test,
  and overridden at runtime by `MYTHWEAVER_AUTO_LOGIN` (`true`/`1`). It applies only when there are 0
  or 1 accounts, whether or not that account has a password. With 0 it creates the passwordless
  `admin@localhost` "Admin" under a table lock, so concurrent first requests make exactly one. With 2
  or more it does nothing. The login page offers "Continue without logging in" while it applies.
- **Sessions.** DB tokens valid for 14 days, reissued after 7. The remember-me cookie is
  `_mythweaver_user_remember_me`, valid for 14 days. A password change, admin reset or deletion
  expires the user's tokens and disconnects their LiveViews.
- **Routes** (`lib/mythweaver_web/router.ex`):
  - Every app page is behind `require_authenticated_user`.
  - Users admin: `/users`, `/users/new` and `/users/:id/edit` (`UserLive`).
  - `/users/settings` (`UserSettingsLive`) and `POST /users/update-password`.
  - Public: `/users/log-in` (`UserLoginLive`), `/setup` (`UserSetupLive`), `POST /users/log-in` and
    `DELETE /users/log-out` (`UserSessionController`).
  - Login and setup render in `Layouts.auth`, which has no nav and no command palette.
- **Accounts have system roles** (see step 4). Nobody may delete themselves. A passwordless user must
  set a password before adding a second account, because auto-login would stop and lock them out.

## Status (step 2, chat ownership, 2026-10-10)

- **`chats.user_id`** (`priv/repo/migrations/20261010173257_add_user_id_to_chats.exs`), nullable,
  `on_delete: :nilify_all`. The migration gave every existing chat to the oldest account. NULL means
  "unowned": the owner was deleted, or the chat was created (seeds, data-layer tests) before any
  account existed. The first account (`register_first_user/1` or the auto-login admin) adopts every
  unowned chat (`Chats.adopt_unowned/1`).
- **`Mythweaver.Chats` takes the scope** where the web layer lists or resolves chats:
  `list_chats/1`, `chat_options/1` (`{title, id}`), `get_chat/2`, and
  `create_chat(scope_or_nil, attrs)`. `get_chat/1` and `get_chat!/1` remain as system lookups with
  no owner check, for workers, the conductor, scripts and reloads.
- **Everyone sees and acts on only their own chats** (2026-10-11), owners and admins included:
  `list_chats/1` returns only the scope's chats and `Chats.authorize/2` admits only the owner, so
  another user's chat does not open by URL and nobody may act on an unowned chat. The picker, Jobs
  (`Jobs.list_jobs/2` shows the jobs you started and those on your chats), prompt preview, the
  palette's chat switcher and the lore/prompt chat-binding selects all list only your own chats.
  `Lore.set_book_chats/3` keeps a book's bindings to chats the editor cannot see. Admin mode (the
  top bar toggle that widened the picker) is gone; cross-user admin tools will get their own design.

## Status (step 3, scope threading, 2026-10-10)

- **Every context function the web layer calls takes `scope` first**: AI, Characters, Prompts
  (incl. `Builder`, `Preview`, `Completions`), Lore (incl. `Activation`), Messages (incl.
  `DraftBuffer`), Variables, Injections, Memory (and submodules), Scripts, Jobs, Attachments,
  Captions, Generation, and the remaining Chats readers/writers. Changeset builders, PubSub
  helpers, pure functions and the Jobs scheduler internals stay unscoped.
- **Checks.** Global-config writes (and provider calls on their behalf) need `Scope.authorize_admin/1`.
  Chat-bound functions need `Chats.authorize/2` (the chat's owner; `nil` chat means admin). Job-bound
  ones need `Jobs.authorize/2` (initiator, or whoever may act on the job's chat). Global reads only
  match `%Scope{}`. Refusals follow the return type: `{:error, :unauthorized}`, `[]`, `nil`, or
  `Mythweaver.UnauthorizedError` (`plug_status: 403`). Web handlers flash "You're not allowed to do
  that." Tests use a user-less `%Scope{}` or `scope!(%{role: :user})` to exercise the refusals.
- **Background work carries its initiator.** `generation_jobs.user_id`
  (`priv/repo/migrations/20261010205450_add_user_id_to_generation_jobs.exs`, backfilled from the
  chat owner, then the oldest account) records who started each job, and the ticket carries the
  scope. Workers rebuild it with `Jobs.initiator_scope/1`, and fail with `:no_initiator` once that
  user is deleted. Conductor queue entries carry the requester's scope; auto mode keeps the scope of
  whoever switched it on (`auto_scope`). `Generation.Server` and Lua script ctx maps carry `scope`.
- Seeds act as `Mythweaver.Seeds.scope/0` (`priv/repo/seeds/scope.exs`): the oldest account, or a
  placeholder admin before any account exists.

## Status (step 4, system roles, 2026-10-11)

- **`users.role`** (`Ecto.Enum` `:owner | :admin | :user`, default `:user`;
  `priv/repo/migrations/20261011010630_add_role_to_users.exs`). The migration made the oldest
  account the owner and every other a user. `/setup` and the auto-login account create an owner;
  `Accounts.register_user/2` takes the role and has no actor check (setup, tests). Test helpers
  (`scope!/1`, `register_user!/1`) default to `:admin` and take `role:`.
- **Predicates.** `Scope.admin?/1` is true for an owner or admin; `Scope.owner?/1` only for an
  owner. Every existing `authorize_admin/1` check now follows the role.
- **Owner membership.** `Accounts.can_manage?/2` (owner: anyone; admin: any non-owner) gates
  `update_user/3`, `reset_user_password/3` and `delete_user/2`; `assignable_roles/1` (owner: all;
  admin: `:admin`/`:user`) gates `create_user/2` and re-roling. Nobody changes their own role
  (`:own_role`), so the last owner can never be demoted or deleted without an owner count. A role
  change disconnects the target's sockets so their LiveViews remount with the new role.
- **Users' surface** (superseded by step 2b below): the config editors mounted
  `UserAuth.on_mount(:require_admin)`. Now only `UserLive` does (memory settings moved to the
  `/settings` page, whose site level is admin-only); the
  content editors mount `MythweaverWeb.ContentAccess` and the AI editors `MythweaverWeb.AIAccess`.
- **Memory books** (superseded by step 2b): a chat-reference rule in `Memory.authorize_book/2`; now
  plain book ownership.

## Status (step 5, closing gaps, 2026-10-11)

- **Image links are signed and expire** (replacing the first cut, a session check on `/uploads`,
  which only ever covered local storage with no proxy). `Attachments.url/2` signs every link for one
  to two `link_window_seconds` (`MYTHWEAVER_IMAGE_LINK_WINDOW`, default a day), identical within a
  window so caches keep working. Who sees an image is decided where the link is rendered (only an
  owner's chat pages render its message images); the link is the access until it expires.
  - Local: `/uploads/<token>`, the key and expiry sealed with AES-256-GCM under keys derived from
    `secret_key_base` (a nonce derived from the plaintext, so a link is stable within its window),
    served by `MythweaverWeb.UploadController` without a session, so a CDN or proxy fetching it
    works too. Behind a proxy, images are the proxy's only (`Attachments.served_directly?/2`):
    refused outright with xtandard-image, which reads the files itself, and without the CDN's
    `x-mythweaver-origin-secret` with Cloudflare or Fastly.
  - S3: presigned GET links signed as of the window's start; the bucket can be private and
    `MYTHWEAVER_S3_PUBLIC_URL` is gone.
  - xtandard-image (replacing imgproxy): key, salt and encryption key are required (boot fails
    without them) and every URL signs `exp:`. The shipped compose files sign, deny unsigned URLs,
    read only the uploads dir, cap `XI_CACHE_HEADERS_TTL` at the window and publish the cache on
    loopback.
- **Chat-list events are per user.** `Chats.topic/1` (`"user:<id>:chats"`, `Chats.subscribe/1`) and
  `Messages.activity_topic/1` (`"user:<id>:chat_activity"`, `Messages.subscribe_activity/1`) carry
  only the subscriber's own chats; an unowned chat's events go nowhere.
- **Job events are per user** (2026-10-11). `Jobs.topic/1` (`"user:<id>:jobs"`,
  `Jobs.subscribe/1`) carries `{:job_changed, …}` and `{:job_progress, …}` only for a job's
  audience (`Jobs.audience/1`: its initiator and its chat's owner, the same rule as `list_jobs/2`).
  Queue positions stay global, so `Jobs.Scheduler` sends each user with a queued job
  `{:job_queue, %{job_id => position}}` for their own jobs whenever the admission order changes. A
  user can still infer that the queue moved, and how many jobs are ahead, but no other user's job.

## Status (step 2b, content ownership, 2026-10-11)

- **`Mythweaver.Ownership`** is the one rule (`lib/mythweaver/ownership.ex`), used by AI and every
  content context: `user_id` nil is the site's (admins edit, everyone uses), set is that user's own
  (only they see, edit or use it, admins included). A row references only site rows or its owner's.
  Runtime resolution filters by the **chat owner** (`for_owner/2`), not the caller.
- **Owned tables** (`priv/repo/migrations/20261011152152_add_content_owners.exs`): characters, lore
  books, entries and pools, prompts, blocks and outlets, scripts, global variables, memory profiles
  and side prompts. Names and keys are unique per owner. Existing rows stayed the site's, except
  books referenced as one owner's chats' memory or side-prompt books (and entries only they hold).
- **`"content.personal"`** (on): users create their own; the content editors open to them
  (`MythweaverWeb.ContentAccess`), listing only their own rows; pickers list usable rows (own +
  site); palette edit commands suggest editable rows only.
- **Runtime rules** (decided 2026-10-11):
  - Lore activation, script triggers, commands and quick replies, side-prompt scans and prompt
    resolution use only the chat owner's and the site's rows.
  - Prompt bindings: specificity, then the owner's own over the site's, then name. A chat's owner
    binds any prompt they may use to their chat.
  - Keyed lookups (custom outlets, `mw.commands.run` names, global variables): the owner's row
    shadows the site's with the same key.
  - Globals: templates read site globals overlaid by the chat owner's; `{% setglobalvar %}` writes
    the chat owner's own (an admin's chat included), never a site row.
  - Memory: a chat's memory book belongs to its owner; `profile_for` takes the chat's profile if
    usable, else the owner's default, else the site's.
- **Deleting a user** deletes their chats, then the user, whose content cascades.

## Status (step 2a, settings and personal AI connections, 2026-10-11)

- **`Mythweaver.Settings`** (`lib/mythweaver/settings.ex`): `get(scope, "area.name")` over static
  values; an unknown key raises. Callers pass the scope, so a later settings system can vary values
  per user or role without touching them.
- **Personal connections and models** (`providers.user_id`, `ai_models.user_id`, nullable, cascade
  on user delete; names unique per owner). nil is the site's: admins manage it. A user's own are
  seen, edited and run only by them, admins included. A link joins only same-owner rows, so site
  models never route onto a personal key and selection needs no per-user filter.
  - `"ai.personal_providers"` (on): Users may add their own; it also opens the AI editors to them
    (`MythweaverWeb.AIAccess`), listing only their own rows.
  - `"ai.shared_providers"` (on): Users may run the site's models. Enforced where a model is used
    (`AI.usable?/2`, `get_model/2`, `default_model/1`, `Generation.model_for/3`), so jobs, which
    run as their initiator, honour it too.
  - A site model's caption model is a site model; a personal one's is the site's or the owner's.
- **API keys are encrypted at rest** (Cloak, `Mythweaver.Vault`, AES-256-GCM only;
  `MYTHWEAVER_VAULT_KEY` in prod). The migration encrypted existing keys in place. Advisories
  against `cloak` (AES-CTR) and `cloak_ecto` (PBKDF2 fields) do not apply: neither cipher nor field
  type is used, and `hex.audit` will keep listing them.
- **Not built:** per-user quotas on shared connections (needs enforcement at `Jobs.Scheduler`'s slot
  grant, and a setting only once something reads it), and a tie-break between own and site
  connections (moot while links never mix owners).

## Status (step 5b, tenancy audit fixes, 2026-10-11)

- **Memory books are books the chat owner may edit** (`Memory.update_chat_settings/3`,
  `ensure_book`, `list_memory_books/1`): a user's own, a site book only for an admin. Records,
  regeneration (`record.chat_id == chat.id` plus an editable book, checked at enqueue and again at
  save), rollback and the panel's pickers follow the same rule; existing entries are rewritten only
  through `Lore.update_entry/3`. `Consolidation.check_ready` notifies only the saving owner's chats.
- **Chat bindings belong to the chat's owner**: lore `book_chats` and prompt `:chat` /
  `:character_in_chat` bindings to someone else's chat are hidden from book and prompt editors, and
  toggling or unbinding them needs `Chats.authorize/2`.
- **Script run status is recorded only for scripts the run's scope may edit**
  (`Scripts.record_results/2`), so a site script's `last_error` never carries a user's chat text.
- **Script and global-variable events are per user**: `Scripts.topic/1` (`"user:<id>:scripts"`,
  `"scripts:site"`) and `Variables.global_topic/1` (`"user:<id>:globals"`,
  `"variables:global:site"`); each subscriber joins its own topic and the site one.
- **Users page re-reads its target**: `update_user/3`, `reset_user_password/3` and `delete_user/2`
  lock and re-read the row before every role check.
- **References and stale scopes**: a job with no chat is its starter's alone (`Jobs.authorize/2`);
  chats and participants accept only models the chat owner may use; a model's caption prompt is the
  site's or its owner's; the conductor rebuilds each queued or auto turn's scope from the user row
  (`Conductor.fresh_scope/1`) and drops turns of a deleted user.
- **Staged uploads belong to their uploader** (`attachments.uploaded_by_id`, nilified on user
  delete): only the uploader may adopt or delete an unlinked image. `store_binary/2` (generated
  images, tests) sets no uploader, so nobody can adopt those by id.

## Status (step 6, groups and permissions, 2026-10-20)

Supersedes the role parts of step 4 and the three access settings of steps 2a/2b.

- **Catalog** (`Mythweaver.Permissions.Catalog`): fixed keys, on/off flags (default off) and
  `quota.*` limits (default unlimited). Content: `content.<area>.create`; AI:
  `ai.connections.create`, `ai.site_models.use`; administration: `site.content.manage`,
  `site.ai.manage`, `site.settings.manage`, `lore.hidden.view`, `analytics.all.view`,
  `catalog.feature`; moderation: `reports.create` (Everyone by default; deny it there to turn
  reporting off), `users.manage`, `groups.manage`, `moderation.reports`,
  `moderation.content.view`, `moderation.content.delete`, `moderation.accounts.sanction`,
  `moderation.fingerprints`, `moderation.log.view` (`20261110215830` split the old
  `users.data.access` and `catalog.moderate` into them); scripts: `scripts.<namespace>`.
- **Tables** (`20261020044121_create_permissions.exs`): flat `permission_groups` (system groups
  Everyone, implicit for every account, and Administrators), `permission_group_members`,
  `permission_grants` (one holder: group or user). The migration turned `content.personal`,
  `ai.personal_providers` and `ai.shared_providers` into Everyone grants (deny where the site had
  them off) and admins into Administrators members; `20261020044442` dropped `:admin` from
  `users.role` (now `:owner | :user`) and the three settings.
- **Resolution** (`Permissions.effective/1`, once per `Scope.for_user/2`): a user's own grant beats
  every group; among groups any deny beats any allow; limits take the most generous group value.
  Owners hold everything. Read with `Scope.can?/2`, `Scope.limit/2`, `Scope.authorize/2`.
- **Ownership** derives the permission from the schema (`Ownership.site_permission/1`,
  `create_permission/1`), so callers pass the schema to `new_owner/2`/`can_create?/2`.
  `ContentAccess` mounts per area (`on_mount {ContentAccess, :lore}`).
- **Management**: `/moderation/groups` (`GroupLive`) and the Users page's Groups and Overrides sections, over
  `Permissions.set_group_grants/3` & co. A non-owner may set only keys it holds and may not change a
  group or user holding one it lacks (`{:not_held, key}`). Changes disconnect the affected users'
  sessions (`UserAuth.disconnect_users/1`); an Everyone change disconnects everyone.
- **Quotas** (`Permissions.Quota`): daily tokens on site models (checked in `Generation.prepare/5`,
  `Jobs.enqueue/3`, `Jobs.retry/3`; finished runs only), counts of own rows at create, and `:ready`
  upload bytes. BYOK models, site rows, memory books and generated images are never limited.
- **Sudo mode**: `users_tokens.sudo_until`; `Accounts.enter_sudo/2` (password, 15 minutes),
  `sudo?/1` (always on a single-user auto-login install). Group/grant changes, role changes, password
  resets, user deletion, book transfers and user-data writes return `:sudo_required`;
  `MythweaverWeb.Sudo` prompts and replays the event.
- **Moderation panel** (`/moderation/*`, `Mythweaver.Moderation`): reports of listings, accounts
  and messages; lookup of any row by link, id, `@handle` or email, read-only, every look logged;
  a user's content index (`/moderation/users/:id/data`, `Accounts.UserData`); warnings (must be
  acknowledged on `/warnings`) and account/device/browser-fingerprint/IP bans checked at login, on
  every request (`BanGate`), every LiveView mount (`ModerationGate`) and MCP; account fingerprints
  kept a year after last seen; and the moderation log. Every other view still shows an admin only
  their own rows.
- **Script permissions**: `Scripts.API` refuses a namespace's acting functions with
  `"no_permission"` unless the runner holds its `scripts.*` key; reads stay open.

## Known gaps

- A `users.manage` holder can reset any non-owner's password and sign in as them. Deferred;
  the moderation lookup (logged) is the sanctioned way to look at a user's data.
- Cloudflare and Fastly have no signature on their own transformation URLs, and cache under the
  full link. Over local storage the app checks the signed source when they fetch it; Fastly with
  `base_url` (required over S3) serves unsigned URLs unless the service adds its own token check.
- A link, once rendered, works for anyone holding it until it expires (one to two windows): losing
  access (a deleted chat, later a removed guest) takes that long to reach images.
- Password recovery needs another admin, because there is no mailer. An email change is not
  verified.
- Site content can't be edited by users, only used, hidden (`/shared` Site content) or cloned when
  readable (`Sharing.Clone`).
- If auto-login is turned off, a passwordless admin is locked out unless they set a password in
  Account settings first.

## Long-term goals

- Self serve account creation: sign up and start using
- RBAC; admins set roles and assign them to users. Roles have a permission model similar to Microsoft Active Directory or Discord
  - Deny, Allow, inherit
    - inherited and explicit
    - Precedence is as follows (higher wins)
      1. Explicit Deny
      2. Explicit Allow
      3. Inherited Deny
      4. Inherited Allow
  - RBAC will also have potential other fields, like quotas, limits, etc. More forthcoming as we build them
- Site admins can change global permissions, global settings, and global defaults
- Site admins can edit all data, view all chats, etc. Superuser permissions
  - Write are gated behind a 'superuser' style prompt, like Github uses
- Users can only change _their_ settings
- Chats
  - All chats individually are _explicitly_ owned by one user
  - User can add other users to their chat, or use them alone
  - Depending on settings, "guests" in a chat may be assigned character roles, or may freely switch between them (or even a subset of characters marked as guest-able)
  - Chat roles
    - Owner
    - Admin: can do everything owner can do except delete or transfer ownership; cannot remove owner
    - Guest
  - Simple RBAC for chats, sets what each tier can do, (the settings of what guests are permitted)
- Characters, Lore books, Model settings, Prompts
  - Can be shared
    - to individual other users, a sharing system
      - read only and read-write, still belong to owner
      - can be copied to account when shared over
    - published to public registry/catalogue, for other users to browse and add to their chats (subscribing)
- Providers
  - Either set up as whole system providers, where everyone uses the same one
    - Quotas for individual use
  - BYOK provider, each user configures their own, uses their own
- Auth should support a variety of features
  - Username/Password
  - OIDC
  - Passkeys
  - 2FA
- An auto-login default that bypasses login for single user systems
- System lore books and prompt blocks, can be _forced_ into all configurations, regardless of user settings
  - Can have outputs hidden from users (the hidden from UI flag on lore)

## Next steps

Ordered by dependency; see the 2026-10-11 roadmap discussion.

1. ~~Close the current gaps: authorized `/uploads`, per-user chat topics (step 5).~~
2. ~~Content ownership (steps 2a AI, 2b content).~~
3. ~~Sharing~~ (built 2026-11-07): shares, subscribers, clone, hand-off, AI sharing and toggles;
   see `research/sharing-plan.md`.
4. ~~Admin tools: users' chats (read-only) and content (step 6).~~ Impersonation is not built.
5. ~~Sudo mode (step 6).~~
6. ~~Public registry~~ (built 2026-11-07): `Mythweaver.Catalog`, `/catalog`.
7. ~~Chat membership~~ (built 2026-11-07): `chat_members`, `Chats.authorize/3`, locks, round turns.
8. ~~Allow/deny precedence rules (step 6).~~ Chat-level roles are fixed (owner, editor, guest
   with per-chat toggles), not part of the permission catalog.
9. A mailer (recovery, email verification), then self-serve signup, OIDC, passkeys and 2FA.

## Sharing groundwork

- **In place:** `Mythweaver.Ownership` gates every owned type, so a share rule added to its query
  helpers (`editable/2`, `usable/3`, `for_owner/2`) and row checks (`authorize_edit/2`,
  `usable?/3`) reaches every editor, picker and runtime path; `user_id` on every content row with
  separate "usable" and "editable" queries (the split subscribe/edit levels need); runtime
  resolution already filters by the chat owner (`for_owner/2`), the one filter a recipient's chats
  would widen; `reference_ok?/2` fixes which references may cross owners (memberships, entry
  character filters, memory profile references); `Prompts.duplicate_prompt/2` copies to the
  duplicating scope's owner with per-owner free names (`next_copy_name/2`), the base for
  copy-to-account; names are unique per owner; `Mythweaver.Settings` can hold a sharing switch;
  signed image links let any permitted viewer load a shared avatar; editors list editable rows and
  pickers usable rows.
- **Still needed:** a grants table (recipient, level, item); `Accounts.get_user_by_email/1` (only
  `get_user_by_email_and_password/2` exists); copy logic for characters (fields + avatar link) and
  lore books (entries, memberships, filters, pools); a read-only mode for editors (`<.editor>` has
  no `readonly` attr); a decision on recipients' chats when the owner deletes or revokes —
  characters are the hard case, since `chat_participants.character_id` is `on_delete: :restrict`
  and `Characters.delete_character/2` refuses with `:in_use`.
- **Design options explored (none chosen):** live links with clone-on-revoke; copy on share with
  pushed updates via `source_id`; a single polymorphic ownership/subscription table.
