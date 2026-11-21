This is a web application written using the Phoenix web framework.

## Project guidelines

- Use `mix precommit` alias when you are done with all changes and fix any pending issues
- Use the already included and available `:req` (`Req`) library for HTTP requests, **avoid** `:httpoison`, `:tesla`, and `:httpc`. Req is included by default and is the preferred HTTP client for Phoenix apps

## Guardrails

- You must NEVER change anything outside of \workspaces\mythweaver and especially not other workspaces. Reading is allowed.
- Do not test against mythweaver_play database or the server running locally on port 4000

## This codebase, specifically

Facts that are cheap to state and expensive to rediscover. Each is verified at the cited path.

### Shape of the app

- Contexts under `lib/mythweaver/`: `AI` (providers, models, links, completions), `Prompts`
  (blocks, prompts, anchors, outlets, scope bindings), `Chats`, `Characters`, `Messages`, `Lore`,
  `Variables` (chat/global key → JSON store), `Injections` (per-chat prompt text rendered after a lore
  slot's lore, or into chat history at a depth alongside `at_depth` lore; only `Generation.Server`
  spends one, after a successful reply), `Memory` (Memory Books: profiles, preferences, per-chat
  memory settings, `memory_records` metadata on managed lore entries, side prompts; sub-contexts
  `Memory.Clips` (clips, topical clips, Memory Assistance), `Memory.Consolidation` (tier
  consolidation jobs) and `Memory.CharacterBooks` (character locks and books); built-in memory
  prompts seed from `priv/repo/seeds/memory.exs`). `Templates` is the only Solid (Liquid) caller; every
  render runs in its own heap-capped, timed task, and only `Generation.Server` commits a build's
  `{% setvar %}` writes (`Variables.apply_writes/2`).
- `Expressions` (SillyTavern Expression Images + expressions-plus): after a finished reply
  (`Generation.Server.finish/4`) and a sent or edited message, `Expressions.classify_later/5` scores
  the body's emotions 0..100 with the `expressions.classifier_model` (nil = off, the default): a
  chat/text model gets an `:expression` worker job (`Expressions.Workers.Classify`, off the chat's
  memory lane); a `completion_mode: :classifier` model (a GoEmotions sequence classifier on
  llama-server `--embedding --pooling rank`) is called directly by `Expressions.Encoder`
  (`AI.classify/2`, `embd_normalize: -1`, logits in `base_labels/0` order → sigmoid × 100, no job);
  `Expressions.Resolver` (pure) picks a label through the character's rule profile and a sprite of
  it, stored on the body (`MessageBody.expression*`, only via `expression_changeset/2`) and shown in
  place of the portrait. Sprites (`character_sprites`, linked attachments) sit in a Default set or an
  `Outfit` a participant picks; a hand-set (`:manual`) expression survives classification unless
  re-classified. Profiles and sprite writes notify `:characters`. Editors: the `CharacterLive.Expressions`
  LiveComponent and `ExpressionProfileLive` (`/characters/expression-profiles`).
- `Tags` is Hydrus-style tagging: namespaced tags (`series:metroid`), siblings (`ideal_id`, A shows as
  B) and parents (`tag_parents`, C implies P), in the site domain (`user_id` nil) or one user's own.
  Identity is the canonical text across domains (`Tag.text/1`). Items store only hard tags
  (`taggings`, one nullable FK per taggable kind, `Tagging.kind_of/1`); `Tags.graph(owner_id)`
  resolves a viewer's rules in Elixir (`Tags.Graph`, pure) and expands them on read: list filters
  (`MythweaverWeb.TagFilter`), editor fields (`MythweaverWeb.TagFields`, chip input
  `<.tag_input>` + hook `assets/js/hooks/tag_input.ts`), `anchors.*.tags` and lore tag filters.
- `Moderation` is the panel under `/moderation/*` (tabs `MythweaverWeb.ModerationNav`): `Reports`
  (listings, accounts, messages, by `reports.create` holders — Everyone unless the site denies it;
  `MythweaverWeb.ReportModal` on the catalog and chat), `Lookup`
  (any row by link/id/`@handle`/email, read-only, deleted as its owner; no browsing), `Sanctions`
  (warnings held on `/warnings`; account/device/fingerprint/IP bans checked by
  `UserSessionController`, plug `MythweaverWeb.BanGate`, on_mount `MythweaverWeb.ModerationGate`
  and `MCP.authenticate/2`), `Fingerprints` (`MythweaverWeb.Signals`: client IP via
  `MythweaverWeb.ClientIp` and `:trusted_proxies`, user agent, language, `_mythweaver_device`
  cookie, `assets/js/fingerprint.ts` hash; kept a year, `Moderation.Pruner`) and `Log` (every action
  and every look at private content). Every write calls `Moderation.broadcast_changed/0`, which the
  moderation screens reload on. `/users` and `/groups` live at `/moderation/users|groups`.
- Content moderation: per-type modes from the `"Content moderation"` permission flags
  (`Moderation.Modes`; exempt by default, owners always). Every holdable/scannable context write
  goes through `Moderation.Gate.run/5`, which returns `{:held, %Moderation.Hold{}}` (restrictive) or
  `{:error, :hold_limit}` besides the usual results, so every caller of `create_/update_character`,
  `_entry`, `_provider`, `_model`, `_prompt`, `_block`, `_outlet` and `Import.import/3` handles
  both. Holds live only in `Moderation.Store` (a global GenServer, memory only); system writers
  (memory, captions) wrap their writes in `Gate.unmoderated/1`. `Moderation.Scanner` runs
  `Moderation.Rules` (regex/webhook; webhooks stubbed via `Req.Test.stub(Mythweaver.Moderation, …)`)
  and opens `source: :rule` reports (`Reports.flag/5`); queues are tabs of `ModerationReportLive`
  (`/moderation/reports|flagged|held`). The Store is shared across tests: filter holds by user id.
- One flat router scope, `:browser` pipeline, one `live_session :app` with `on_mount`
  `[{MythweaverWeb.UserAuth, :require_authenticated}, MythweaverWeb.ModerationGate,
  MythweaverWeb.CommandPalette.Hook, MythweaverWeb.NotificationsHook]` (the palette hook
  turns the palette's flash messages into the page's flash) (`lib/mythweaver_web/router.ex`). Every
  app page needs a logged-in user, and `current_scope` (`Mythweaver.Accounts.Scope`: `user` plus
  resolved `permissions`) is assigned on every LiveView; pass it to `<Layouts.app>`. Authorization is
  permission keys (`Mythweaver.Permissions.Catalog`; groups, an implicit Everyone group and per-user
  grants resolved by `Permissions.effective/1`), read with `Scope.can?/2` / `Scope.limit/2`; roles are
  only `:owner` (holds everything) and `:user`, and there is no `Scope.admin?`. Every context
  function the web calls takes the scope first (`Mythweaver.Ownership` for owned rows — site rows
  edited by holders of the schema's site permission and usable by all, personal rows only by their
  owner; `Chats.authorize/3` — the chat's owner, or an accepted chat editor or guest
  (`Chats.Member`) per action; admins get no exception — for chat-bound ones;
  `Jobs.authorize/2` for jobs). Sensitive changes need sudo mode (`Accounts.sudo?/1`, prompted by
  `MythweaverWeb.Sudo`); quotas are `Permissions.Quota`. Runtime resolution filters by the chat owner
  (`Ownership.for_owner/2`); accounts status and gaps are in `research/accounts.md`.
- `Layouts.app` renders the command palette LiveComponent (`MythweaverWeb.CommandPalette`) on every
  page; only `MainChatLive` passes `chat`, which enables chat commands, and its one
  `{MythweaverWeb.CommandPalette, :chat_event, event, params}` `handle_info` replays them through
  its own `handle_event/3`.
- 8 LiveViews: `MainChatLive` (`/`, `/chats/:id`) is the only non-admin surface. The rest are two-pane
  editors: `CharacterLive`, `LoreBookLive`, `PromptLive`/`PromptBlockLive`/
  `PromptOutletLive`, `AIProviderLive`/`AIModelLive`. A lore book's or prompt's child sections
  (bindings, entries, blocks) sit under its form on its own edit page; there are no show pages.
  `LoreBookLive`'s left pane is a book/entry tree (external hook `assets/js/hooks/lore_tree.ts`), and
  its right pane also hosts the full entry editor (`/lore/entries/new`, `/lore/entries/:entry_id/edit`).
- Lore order is per book: `BookEntry.order` (effective order = `order + book.order_adjustment`); entries
  have no `order` of their own. An entry may belong to no book ("Unlinked", never activates), so
  deleting a book leaves its exclusive entries unlinked.
- Vector lore (`activation: :vector`) never calls the API while a reply is built: `Lore.Embeddings`
  embeds entries and every message body in the background (`sync_chat_later/1`, one pass per chat
  via `Lore.EmbeddingRegistry`, triggered by the `Messages` broadcasts and `MainChatLive` mount), and
  `Activation` only compares stored pgvector rows (`lore_entry_embeddings`, `message_body_embeddings`;
  score = best match over the scan window). Embedding models are `AI.Model` `completion_mode:
  :embedding`; classifier models `:classifier`. Only `Model.text_modes/0` (chat, text) run
  chats/participants/profiles/jobs; a model changes mode only while every use accepts the new one
  (`AI.mode_switch_blockers/2`, settings via `Settings.accepted_modes/1`), and leaving embedding
  deletes its vectors. Discovery's "Add as embedding"/"Add as classifier" cover backends that don't report it.
  Embedding and classifier calls are `generation_stats` rows (tag `:embedding`/`:expression`, `job_id`
  nil, `Analytics.record_call/1`) and count toward `quota.spend_per_day`. Background tasks are off in
  test (`:lore_embeddings_in_background`, `:expressions_in_background`).
- **`Mythweaver.Generation` is the orchestrator.** `generation.ex` is the public API
  (`generate/4`, `regenerate/4`, `respond/2`, `cancel/2`, `generating?/2`, `model_for/3`, …, all scope-first);
  `generation/conductor.ex` is one GenServer per chat (the reply queue, the single in-flight reply,
  auto mode), named by chat id through `Mythweaver.Generation.Registry` under
  `Mythweaver.Generation.Supervisor`, so a generation outlives its LiveView; `generation/server.ex`
  is the temporary GenServer that runs one reply. Sending a player message calls `Generation.respond/2`, and
  `Generation.TurnPolicy` (pure; `:manual`/`:list`/`:pooled`/`:natural`, ported from SillyTavern's
  `group-chats.js`) picks who replies from participant `position`, `muted` and `talkativeness` and the
  chat's `reply_strategy`, `allow_self_responses` and `max_turns`.
- Writes to owned rows announce `{Mythweaver.Changes, kind}` on the owner's topic
  (`Changes.notify/2,3` after the write's own transaction; a caller's outer transaction re-broadcasts
  after commit, e.g. `Import.import/3`). Every editor `LiveSync.attach_editor/3`s in `mount/3` and
  re-syncs through `LiveSync.sync_open/3`: an untouched form reloads, an edited one keeps its edits
  and shows `<.changed_elsewhere>`, a vanished row patches to the index. Other views use
  `LiveSync.attach/3`. A new write path to an owned row needs a notify, or open views go stale.
- Streaming reaches other tabs only over `Messages.topic/1`: `{:body_delta, %{message_id:, body_id:,
  content:, reasoning:}}` carries the *accumulated* text (not the delta), then `{:generation_finished, message_id}`.
  Both are plain `broadcast/3`, unlike the typing tuples' `broadcast_from/4`, because the generation runs
  in a GenServer and every tab — including the originating one — must receive them.
- A streamed body starts blank: `MessageBody.streaming_changeset/2` (blank content legal,
  `generating: true`) and `finalize_changeset/2` are separate from `initial_changeset/2`, which still
  requires content for player messages. `Message.generating_changeset/2` exists because
  `create_changeset/2`'s `cast_assoc` is hard-wired to `initial_changeset/2`.
- Streamed text lives in `Generation.Server` state, not the DB, per token: `Messages.save_streamed_body/3`
  runs on a debounce (`Messages.write_debounce_ms/0`, 3s; 1h in `config/test.exs` so it never fires in
  tests) and stop/error finalizes carry the buffer in. `MainChatLive` patches a cached struct
  (`streaming_messages`) from the payload instead of re-reading per token. Composer drafts go through
  `Messages.DraftBuffer` on the same debounce; tests call `DraftBuffer.flush/2` to persist.
- Every generation goes through `Mythweaver.Jobs` (`Jobs.stream_async/5` for chat replies, returning
  `{:ok, ref, job_id}`); `Jobs.Scheduler` grants provider slots and cancels by killing the task —
  Req's streaming `into:` fold has no cooperative abort. Only `AI.test_link/2`, `AI.embed/2` and `AI.classify/2` bypass the queue.
  Each job row records its initiator (`user_id`); workers act as `Jobs.initiator_scope/1`.
- Model for a reply: `Generation.model_for/3` → participant `ai_model_id` → chat `ai_model_id` →
  `AI.default_model/1` (the `ai.default_model` setting, user over site; else the sole *reachable* model
  the scope may run; `{:error, :ambiguous_model}` when several). A rung naming a model the scope may
  not run (`AI.usable?/2`) counts as unset.
  `Prompts.Binding`'s scope table cannot serve this: its `prompt_id` FK is non-nullable.
- AI connections and models are the site's (`user_id` nil) or one user's own ("bring your own
  provider"); a link joins only same-owner rows, and `api_key` is encrypted by `Mythweaver.Vault`
  (Cloak, AES-GCM). Ownership rules live in the `Mythweaver.AI` moduledoc.
- Settings are `Mythweaver.Settings.get(scope, "area.name")`: definitions and defaults in
  `settings.ex`'s `@categories`, overrides in the `settings` table (site row `user_id` nil, one row per
  user), cascading default → site → user; `can_edit?/3` is the only access rule (site level:
  `"site.settings.manage"`; user level: keys whose `levels` include `:user`, unless locked). The `/settings` page
  (`SettingsLive`) edits them; memory settings are `memory.*`, read through `Memory.preferences/1`.
  Search a key to find every caller.
- UI text is Gettext (`Mythweaver.Gettext`, catalogs `priv/gettext/<domain>.pot` + `en`, `de`, `es`
  `LC_MESSAGES`; `de` and `es` are an unreviewed machine translation, header `Language-Team`). New
  or changed msgids merge into them empty and show in English until translated; a translation must
  keep its msgid's placeholders exactly (catalog test). One
  domain per area (`chat`, `lore`, `ai`, … plus `errors` and `default`), a `msgctxt` `"<role>: <subject>"`
  on every msgid of ≤ 4 words, whole sentences only (inline markup via `MythweaverWeb.RichText.rich/1`,
  never a translated word spliced into another sentence), named placeholders bound with
  `Mythweaver.Format` (numbers, money, durations, dates, lists in the CLDR locale). Rules and role list:
  `test/mythweaver/gettext_catalog_test.exs`; `mix precommit` runs `gettext.extract
  --check-up-to-date`, so run `mix gettext.extract --merge --no-fuzzy` after changing text. Language
  (UI text: `appearance.language` → first `Accept-Language` tag with a catalog →
  `appearance.default_language` → `"en"`; only languages with a catalog are offered) and regional
  format (numbers/dates/money: `appearance.locale` → `Accept-Language` best CLDR match →
  `appearance.default_locale` → `:en`) resolve separately (`Mythweaver.Locale.resolve/2`, a
  `%Mythweaver.Locale{language:, format:}`), set by `MythweaverWeb.Locale` (plug + first `on_mount`);
  `<html lang>` is the language, `<html data-locale>` the format JS's `Intl` uses. Tasks take both
  with `Mythweaver.Locale.carry/1`, text built for another user with `Locale.with_user_locale/2`.
  JS text comes from `MythweaverWeb.ClientStrings` (`assets/js/i18n.ts`).
  LLM-facing text (prompts, memory workers, assistant tools, MCP) stays literal English.
- `Prompts.Builder.render/3` output is already exactly `AI.stream/3`'s `input`
  (`lib/mythweaver/prompts/builder.ex:12-14`).
- `Prompts.Builder.context/3` defaults lore to `commit: false` so inspection does not advance
  sticky/cooldown state; a real generation must resolve with `commit: true` and pass that result in
  (`builder.ex:78-80`).
- `reference/` holds developer notes (`colocated_css_guide.md`, `weighted_selection.md`); `docs/` is
  user documentation only.

### The two-pane editor pattern (copy it, do not invent a new one)

Every manager screen is the same shape — `CharacterLive` and `AIModelLive` are the canonical copies.
Layout pieces come from `MythweaverWeb.Pane` (`components/pane.ex`: `pane_layout`, `pane_header`,
`pane_actions` (the slot-only control cluster under a list's header), `pane_items`, `pane_delete`), which owns all list CSS. Headings come from
`MythweaverWeb.CoreComponents.Header` (`components/core_components/header.ex`) and are styled only
there: `panel_header` is the uppercase bar atop every panel (an editor's is
`<.panel_header sticky>`), `section_header` a heading inside one; both take the title as the inner
block and trailing controls in `:actions`. Every control that *looks* like a button — a filled or
outlined rectangle — is `<.button>` (`components/core_components/button.ex`: `variant`
`primary`|`secondary`, `danger`, `icon`, `size="sm"`, `block`; `navigate`/`patch`/`href` render a
link). Cancels are secondary `<.button>`s (links when they navigate); borderless toolbar icons are not
buttons in that sense and keep their own CSS. Its styles are global (`MythweaverWeb.ColocatedCSS`,
since a `<.link>` root gets no scope marker); a caller's `class` is a layout hook only, reachable from
a `lower-bound="none"`/`"inclusive"` block. Each screen then follows this shape:

- `mount/3` assigns (incl. `selected_id: nil`), `stream_configure(:things, dom_id: &"things-#{&1.id}")`
  and a private `stream_things/1`.
- `handle_params/3` delegates to `apply_action/3` with `:index`/`:new`/`:edit` heads. `:index` selects
  nothing: it clears the form, the editing item and `selected_id`, re-streams the list, and the editor
  slot renders `<.pane_placeholder id="<thing>-placeholder">` instead of the form. Save patches to the
  item's `/edit`; delete patches to the index.
- `handle_event` names are per-screen (`"validate"`/`"save"`/`"delete"`, or suffixed like
  `"validate_link"`/`"save_link"` where one LiveView owns two forms); the form is reached by
  `<.link patch=…>`, never `navigate`.
- Ids are predictable and tests depend on them: form `#<thing>-form`, fields `#<thing>-form-<field>`,
  stream container `<ul id="<things>" phx-update="stream">`, rows `<things>-<uuid>` (e.g.
  `ai-models-<id>`, `lore-books-<id>`).
- Streams have no count or empty state, so every one of these also assigns a `<things>_empty?` boolean
  and passes it to `pane_items`' `empty?`.

`<.input>` (`lib/mythweaver_web/components/core_components.ex:170-173`) accepts exactly these `type`
values: `checkbox color date datetime-local email file month number password search select tel text
time url week hidden`. Its `:rest` allowlist includes `disabled required readonly min max step
rows cols placeholder pattern multiple` — pass those straight through rather than editing the component.

Every multi-line field is `<.editor>` (`components/core_components/editor.ex`, hook
`assets/js/hooks/rich_input/`), a CodeMirror 6 source editor with `language` `markdown`|`liquid`|`json`;
`liquid` call sites pass `completions={Mythweaver.Prompts.Completions.template(chat_id)}`. Its named
`<textarea>` sits inside a `phx-update="ignore"` div, so LiveViewTest sees only the first-rendered text
there; assert a later server value with `#<id>[data-value='…']`.

A settings form whose edits apply only on Save/Apply carries `phx-hook="UnsavedChanges"`
(`assets/js/hooks/unsaved_changes.ts`) and `data-saved={is_nil(@form.action)}` (a form with no
`phx-change` always shows saved values: a bare `data-saved`). The hook marks edited fields
(`[data-unsaved]`, styled in `<.input>`'s and `<.editor>`'s global CSS) and asks before link
navigation, back/forward, tab close and dismissing the surrounding `<.modal>` (`modal:before-close`).
So a fresh form after load or save must carry no `action`, and a validate/refused one must. A Cancel
inside a modal that only closes it dispatches `modal:close` to the modal, so it is asked about too.
Its Save/Cancel row is `<.form_actions>` (`components/core_components/form_actions.ex`), the form's
last child: inner block right-aligned (Cancel, then submit), `:start` for left-pinned extras
(Delete, Test). While any field is unsaved the hook sets `data-unsaved` on the `<form>`, and the row
turns into a sticky "Unsaved changes" bar at the bottom of the scroll container. Don't write
per-screen `*-form-actions` CSS.

Every tab bar is `<.tabs>` (`components/core_components/tabs.ex`, which owns all tab CSS), one
repeated `<:tab name=…>` per tab whose inner block is the label. A tab with `patch` is a link (the
URL holds the tab: the memory panel, `/settings`' User/Site); one with `navigate` links to another
LiveView (the moderation panel's sections, `MythweaverWeb.ModerationNav`); one with neither is a button sending
`on_select` with `%{"tab" => name}` (an assign holds it: chat settings, whose form a patch would
reset). Ids are `<id>-tabs`, `<id>-tab-<name>`, and `<.tab_panel tabs={id} name=… active=…>` is
`<id>-panel-<name>` (`hidden` unless active; pass `panels` to `<.tabs>` only when every panel renders).

Every list of select checkboxes gets shift-click range selection from `phx-hook="RangeSelect"`
(`assets/js/hooks/range_select.ts`) on its container, with `data-range-id={id}` on each box that
takes part. Shift-clicking an unchecked box checks every box from it to the nearest other checked
one (DOM order, ties to the earlier); anything else is a plain toggle. A server-kept selection
(`phx-click` boxes) adds `data-range-event`, which receives `{"ids" => range}` in one event; boxes in
a form need nothing more, since the form's `phx-change`/submit carries the checked range.

Every drag in the app is `sortable/2` in `assets/js/hooks/sortable_list.ts` (SortableJS in fallback
mode). A reorderable list is `phx-hook="SortableList"` with `data-sortable-event` (the server
receives `{"ids" => full_dom_order}`) and optional `data-sortable-disabled`, over rows carrying
`data-id`. Each row drags only by `<.drag_handle>` (`components/core_components/drag_handle.ex`,
which also holds every drag style: ghost, cursors, hidden handles). The lore tree (`LoreTree`)
builds its cross-folder move/copy on the same `sortable/2`. Don't add another drag setup or
per-screen handle or ghost CSS.

### Testing

- `mix test` auto-runs `ecto.create --quiet` + `ecto.migrate --quiet` (`mix.exs:79`); no manual DB setup.
- `mix precommit` = `compile --warnings-as-errors`, `gettext.extract --check-up-to-date` (in its own
  `_build/gettext`), oxlint, `deps.unlock --unused`, `format`, `credo --strict`, `test` (`mix.exs`
  `aliases/0`). Dialyzer is not wired in.
- Sandbox is shared unless the case says `async: true` (`test/support/data_case.ex:42`). A LiveView test
  using `start_async`/`Task` needs the non-async (shared) default so the spawned process can reach the DB.
- `errors_on/1` is in `DataCase` (`test/support/data_case.ex:56`). Assert changeset errors with it.
- **No factory library.** Convention is a private bang constructor per test file (`defp provider!/2`,
  `defp model!/2`) wrapping the real context call — see `test/mythweaver/ai_test.exs:38-49`. Follow it;
  do not add ExMachina or a shared factory module.
- AI HTTP is stubbed through one seam: `config :mythweaver, ai_req_options: [plug: {Req.Test,
  Mythweaver.AI}]` (`config/test.exs:33`), read at
  `lib/mythweaver/ai/adapters/openai_compatible.ex:250`. In tests call
  `Req.Test.stub(Mythweaver.AI, fn conn -> ... end)`. It resolves through `$callers`, so a stub set in
  the test process is visible inside a LiveView `start_async` task — no `Req.Test.allow/3` needed.
- LiveView async assertions: `render_async(view)` after the click, never `render(view)` immediately.

### User documentation

- `docs/` is Markdown user and admin documentation, published by `docs_site/` (a standalone Tableau
  Mix project: HEEx layouts, MDEx + Lumis, MiniSearch) to GitHub Pages by
  `.github/workflows/docs.yml`. Preview with `mise run docs:server` (http://localhost:4999); build
  with `mise run docs:build`.
- Layout rules:
  - `docs/index.md`: home page, permalink `/`. Front matter: `title` (required).
  - `docs/<section>/index.md`: required for every section directory, permalink `/<section>/`.
    Front matter: `title` (required string), `order` (required integer).
  - `docs/<section>/<slug>.md`: pages, permalink `/<section>/<slug>/`. Front matter: `title`
    (required string), `order` (required integer), `description` (optional string on any page,
    shown under the title and used as `<meta name="description">`).
  - Any other front matter key is an error (it catches typos). `section` and `slug` must match
    `~r/\A[a-z0-9]+(-[a-z0-9]+)*\z/`. A `.md` file deeper than `docs/<section>/` is an error.
    Non-`.md` files (images) may live anywhere under `docs/` (convention: `docs/<section>/images/`)
    and are copied verbatim.
  - The body must not contain an H1 (`# `): the layout renders `title` as the page's H1.
  - Links between pages are relative `.md` paths (`../lore/entries.md`, `entries.md#sticky`), so
    they also work on GitHub and in editors. Images are relative paths. External links are absolute
    `https://` URLs.
  - Nav order: sections by `order`, pages in a section by `{order, title}`. Duplicate `order`
    values are allowed; `title` breaks the tie.
  - Fenced code may use only these languages: `liquid lua json bash yaml css html javascript
    markdown`, plus `text`/no label (`docs_site/mix.exs` lists the Lumis grammars).
- Writing rules:
  - Audience: people using or running Mythweaver, not developers. Second person, present tense,
    whole sentences, English only.
  - Name screens by their UI label and path (**Lore** at `/lore`) and controls by their visible
    label in bold. Never name modules, functions, schemas, tables or source paths.
  - Each page opens with one or two sentences on what the feature is for, then tasks ("To …" steps
    as numbered lists), then reference (fields/options as tables: `| Field | What it does |`).
  - Use alerts (`> [!NOTE]`, `> [!WARNING]`) for gotchas, such as data loss or settings that need a
    rebuild.
  - Before writing a page, confirm behavior in the code (the LiveView, its context, the gettext
    msgids for exact labels). Use the UI labels from `priv/gettext/*.pot` / templates, not guesses.
- When: any change to a user-visible behavior, label, setting, permission or environment variable
  updates the page that covers it in the same change, and a new feature adds or extends a page.
  `test/mythweaver/docs_test.exs` checks structure and links. `test/mythweaver/prompts/anchor_test.exs`
  holds `docs/prompts/templates.md` to `Anchor.catalog/0`. The site build additionally fails on a
  link to a missing heading.
- The app also compiles `docs/` in (`Mythweaver.Docs`, recompiled when a page is added, removed or
  edited) for the assistant's `list_docs`/`search_docs`/`read_doc` tools
  (`Assistant.Tools.Docs`), which its system prompt tells it to use for how-to questions. The
  Dockerfile copies `docs/` before `mix compile`; `yaml_elixir` is a runtime dependency for it.
- `docs_site/` has its own `mix test`. It is not part of `mix precommit`; run `mise run docs:build`
  after editing `docs_site/` or doc links with fragments.

### Icons

- Icons come from the **Iconex** dep (`{:iconex, "~> 0.1.0"}`, `mix.exs`), which serves Lucide and IBM
  Carbon from one sprite. `<.lucide name="…" />` is `Iconex.lucide/1`, imported in `html_helpers`
  (`lib/mythweaver_web.ex:78`) and in `core_components.ex`. `<.carbon name="…" />` (`Iconex.carbon/1`)
  is also enabled but not imported: add `import Iconex, only: [carbon: 1]` or write `<Iconex.carbon>`.
  There is no local icon module, `icon/1` wrapper or `@icons` list: any name from
  https://lucide.dev/icons/ works with no registration step. Don't wrap `lucide/1` in a local
  component; the compiler only sees direct (or imported) `Iconex.lucide`/`Iconex.carbon` calls.
- The `:iconex` compiler (last in `compilers:`, `mix.exs:13`) scans compiled modules for literal icon
  names and writes a pruned sprite to `priv/static/images/iconex.svg` (gitignored). An unknown literal
  name fails compilation. `Iconex.lucide/1` also raises `ArgumentError` at render for an unknown name.
- **A name computed at runtime is invisible to the compiler**, e.g.
  `name={if @x, do: "pause", else: "play"}`. List every possible value with
  `Iconex.hint(:lucide, ~w[…])` (literal set atom, literal list) at the top of the function component,
  or the icon renders blank from the pruned sprite. Existing examples:
  `components/chat/participants.ex:68` and `components/chat/messages.ex:113`.
- Delivery: dev uses `config :iconex, delivery: :inline` (`config/dev.exs:6`, read at compile time:
  `mix deps.compile iconex --force` after changing it). Other envs use the default `:external` sprite
  file. `{Iconex.sprite_tag()}` sits once in `layouts/root.html.heex`.
- Sizing: `.iconex` in `assets/css/base.css:52` makes every icon (either set) 1em. Icons render
  `class="iconex iconex-lucide"` and use `stroke="currentColor"`, so size and color them from the
  parent's `font-size`/`color`; target `.iconex` in selectors. Don't pass Tailwind `class` values; the
  `size`/`stroke_width` attrs exist but the 1em CSS overrides `size`.
- No Heroicons in this app. Ignore the generic Phoenix `hero-*` icon guidance below.

### CSS

- Semantic tokens live in `assets/css/tokens.css`: `--background --foreground --card --muted --primary
  --primary-accent --guide --destructive --border --border-grey --input --ring --surface-1..10
  --elevation-xs..2xl --panel-gap`. `--primary` is a *fill* only: a background paired with
  `--primary-foreground` text. Primary as text, border, tint or indicator on a surface is
  `--primary-accent` — in dark mode no single value passes WCAG AA in both roles. `--guide` (the
  accent, hue -130) tints controls a composer guide will steer.
  `--surface-1` is the most recessed step (inputs, insets) and `--surface-10` the most raised; each
  scheme climbs away from its background, so light mode darkens and dark mode lightens with the step.
  Scale tokens `--size-1..7,9 --radius-1..3,round --font-size-00..6 --font-weight-6
  --font-monospace-code` are in `tokens.css` (formerly Open Props; there is no palette, so no
  `--gray-N`). The reset is `assets/css/reset.css` (layer `reset`), ported from Open Props' normalize
  without its text-width caps. Prefer a semantic token when one exists.
- `lower-bound="none"` on a colocated `<style>` makes every element carrying the scope marker a scope
  root, so root rules must be tag-qualified (`div:scope`, `nav:scope`), never a bare class. Use it only
  to reach inside a nested component's root (e.g. `<.input>`'s internals).
- Root-attached pseudo-elements need the scope root too: `dialog:scope::backdrop`, never `::backdrop`.
- Content passed into a component's slot (e.g. `pane_layout`'s `<:editor>`) gets the caller's scope
  marker only on its own root *tags*; a `<.form>` there carries none and falls outside the caller's
  styles. Each two-pane LiveView therefore wraps its editor slot in one
  `<div class="<thing>-editor-body">` styled `div.<thing>-editor-body:scope { display: contents; }`.
- Breakpoints are saved custom media (`assets/css/media.css`): `@media (--phone)` (≤ 50rem, so a
  foldable's ~791px inner screen is a phone),
  `(--tablet)` (≤ 64rem), `(--laptop)` (≤ 87rem; only the top bar's menu drawer), `(--touch)`
  (hover: none), `(--coarse)` (pointer: coarse; size hit areas
  with `var(--touch-target)`). Never write the literals; `assets/build.ts` resolves the names with
  LightningCSS, and an unknown name fails the build. Phones get a 16px root.
- Narrow-screen rails are drawers (`MythweaverWeb.CoreComponents.Drawer`, Popover API): the panel
  itself carries `popover` + `drawer drawer--start|end|bottom drawer--phone|tablet`, opened by
  `<.drawer_toggle>`; `assets/js/drawers.ts` closes it when a link inside is followed. `pane_layout`,
  the chat picker (a drawer at `--tablet`) and participants rail (at `--phone`; tablets keep it
  beside the chat), the top-bar menu and the chat's ⋯ tool sheet already use it.
  `data-drawer-swipe` on a side drawer also opens it on a sideways flick (the picker, participants
  and pane lists opt in).
- Phone chrome that hides at a screen edge with a few pixels showing (the top bar, the chat
  composer) uses the external `EdgeReveal` hook (`assets/js/hooks/edge_reveal.ts`): the element's
  CSS sets `--edge-reveal: on` inside `(--phone)` and reveals from `:root[data-reveal-top|bottom]`.

### Schema conventions

- **Every persisted schema starts `use Mythweaver.Schema`, never `use Ecto.Schema`.** That macro
  (`lib/mythweaver/schema.ex`) sets `@primary_key {:id, Ecto.UUID, autogenerate: [version: 7, precision:
  :monotonic]}` and `@foreign_key_type Ecto.UUID`, so ids are time-ordered **UUID v7**. Do not write the
  two attributes by hand and do not reintroduce `{:id, :binary_id, autogenerate: true}` — that form
  delegates to the adapter and silently yields random v4. `mix phx.gen.*` emits the v4 form because
  `generators: [binary_id: true]` (`config/config.exs`) has no schema-attribute option: replace it in
  generated code. Embedded schemas (`AI.SamplerParams`, `@primary_key false`) keep `use Ecto.Schema`.
- `precision: :monotonic` is critical, not decoration: `Messages`' `bodies_query/0` orders swipes
  `[asc: inserted_at, asc: id]` and `AI.next_provider_model/1` breaks equal deadlines with `asc: pm.id`,
  so plain `:millisecond` v7 (random `rand_a`) would scramble both within one millisecond.
  `test/mythweaver/schema_test.exs` fails if the precision is dropped.
- Any hand-built id — a `Repo.insert_all/3` row, or a test's "unknown id" — must come from
  `Mythweaver.Schema.generate_id/0`, **never** `Ecto.UUID.generate/0`, whose default is v4.
  `Ecto.UUID` as a *type* (fields, schemaless types, `Ecto.UUID.t()` specs) is fine.
- **Migrations through 20261117223854 are squashed** into `priv/repo/structure.sql`, which
  `priv/repo/migrations/20261117223854_structure.exs` runs on an empty database as one PL/pgSQL
  `EXECUTE` (the release has no psql). It holds the schema plus the seeded permission groups and
  grants. Never edit it, and never run `mix ecto.dump`/`ecto.load` (they write and read that same
  path through psql). Every schema or data change is a new `mix ecto.gen.migration`. Databases
  migrated before the squash still list the 136 other versions in `mix ecto.migrations` with no
  file. They are harmless.
- Every enum-like field is `field :x, Ecto.Enum, values: [...]`. There are no custom `Ecto.Type`
  modules; do not add one for an enum.
- `Lore.LoreEntry.outlet`'s value list must stay in literal lockstep with `Lore.Settings.outlets/0` —
  `Ecto.Enum` needs a compile-time literal, so only a test enforces it.
- A prompt block is `kind: :template` (Liquid reading `anchors.*`/`outlets.*`/`vars.*`/`globals.*`) or
  `:chat_history`. `Prompts.Anchor.data/2` is the only place `anchors` data is assembled;
  `Prompts.Builder` renders descriptions, then lore, then blocks through one `Templates.State`.
  Human-typed message text renders once through `Builder.render_user_text/2` and the *rendered* text
  is stored.
- Counters and scheduling fields are deliberately not castable and are set only by their context —
  e.g. `ProviderModel.last_used_at`/`use_count`/`selection_deadline`
  (`lib/mythweaver/ai/provider_model.ex:7-9`).

### Deliberate refusals — do not "fix" these

- One prompt builder, not two. `render/3` is the only place chat and text wire formats diverge;
  `Model.completion_mode` alone decides the shape (`prompts/builder.ex:5-10`).
- Req retries are off on completions: a completion is non-idempotent in cost terms and a retry would
  double-bill (`ai/adapters/openai_compatible.ex:6-9`).
- Duplicating a prompt does not copy its bindings, because two prompts bound at equal specificity would
  make `resolve_prompt/1` a name tie-break (`lib/mythweaver/prompts.ex:96-97`).
- A model's "inference" capability flag was dropped on purpose; the meaningful flag is whether the
  response carries *separate* reasoning content (`supports_thinking`).

## Project Priorities

### Phase 1 (current)

**Workable alpha: an AI-driven role-play with multiple characters in one group chat.**
`Mythweaver.Generation` (orchestration), per-participant/chat model selection, the chat-UI
generate/stop/regenerate controls, and most of the multi-character turn policy (`TurnPolicy`,
`Conductor`, auto mode) are built. Real message roles in the seeded prompt are deferred: every seeded
block is still `:system`, so `Builder.render/3` collapses the whole prompt into one system message.
SillyTavern (`public/scripts/group-chats.js`) is the reference for group turn-taking.

### Phases 2+ (future) - Ignore for now

- import/export functionality
- compatability with other RP/CVV standards


### Phoenix v1.8 guidelines

- **Always** begin your LiveView templates with `<Layouts.app flash={@flash} ...>` which wraps all inner content
- The `MyAppWeb.Layouts` module is aliased in the `my_app_web.ex` file, so you can use it without needing to alias it again
- Anytime you run into errors with no `current_scope` assign:
  - You failed to follow the Authenticated Routes guidelines, or you failed to pass `current_scope` to `<Layouts.app>`
  - **Always** fix the `current_scope` error by moving your routes to the proper `live_session` and ensure you pass `current_scope` as needed
- Phoenix v1.8 moved the `<.flash_group>` component to the `Layouts` module. You are **forbidden** from calling `<.flash_group>` outside of the `layouts.ex` module
- **Always** use the `<.lucide>` component for icons (Lucide names via Iconex; see "Icons" above), **never** use `Heroicons` modules or similar
- **Always** use the imported `<.input>` component for form inputs from `core_components.ex` when available. `<.input>` is imported and using it will save steps and prevent errors
- If you override the default input classes (`<.input class="myclass px-2 py-1 rounded-lg">)`) class with your own values, no default classes are inherited, so your
custom classes must fully style the input

### JS and CSS guidelines

- **NEVER use TailwindCSS.** No tailwind utility classes (`px-2`, `w-5`, `h-5`, `flex`, `rounded-lg`, etc.), no `@apply`, no tailwind config or directives — anywhere, ever. If you encounter tailwind classes in existing markup, prefer replacing them with colocated CSS as you touch the code.
- **Prioritize colocated CSS.** Styling **must** live in a colocated `<style>` block inside the component/LiveView via `MythweaverWeb.ColocatedScopedCSS` (component-scoped, the default choice) or `MythweaverWeb.ColocatedCSS` (global utilities only). See `reference/colocated_css_guide.md`.
  - Order of preference: **scoped colocated CSS** first, then **global colocated CSS** only when reuse demands it, then global `app.css` **only if necessary**. Inline `style="..."` attributes are avoided unless absolutely necessary (e.g. dynamic values computed from Elixir).
  - **`MythweaverWeb.ColocatedScopedCSS` wraps rules in `@scope ([phx-css-…]) to ([phx-r])`. The scope root — the component's outermost element — is EXCLUDED by a bare class/tag selector; those only match descendants.** To style the root element itself (e.g. positioning a `popover`/notice container, overriding UA `[popover]` defaults), you **must** target it with the `:scope` pseudo-class, not its class name. A `.root-class { … }` rule silently no-ops on the root and UA/global styles win.
- **Prioritize colocated JS.** Client-side behavior **must** live in a colocated JS hook (`<script :type={Phoenix.LiveView.ColocatedHook} name=".MyHook">`) defined inside the HEEx template, for both `phx-hook` behavior and general JS state. Reach for an external `assets/js/` hook only when the hook must be shared across many templates.
- Out of the box **only the app.js and app.css bundles are supported**
  - You cannot reference an external vendor'd script `src` or link `href` in the layouts
  - You must import the vendor deps into app.js and app.css to use them


<!-- usage-rules-start -->

<!-- phoenix:elixir-start -->
## Elixir guidelines

- Elixir lists **do not support index based access via the access syntax**

  **Never do this (invalid)**:

      i = 0
      mylist = ["blue", "green"]
      mylist[i]

  Instead, **always** use `Enum.at`, pattern matching, or `List` for index based list access, ie:

      i = 0
      mylist = ["blue", "green"]
      Enum.at(mylist, i)

- Elixir variables are immutable, but can be rebound, so for block expressions like `if`, `case`, `cond`, etc
  you *must* bind the result of the expression to a variable if you want to use it and you CANNOT rebind the result inside the expression, ie:

      # INVALID: we are rebinding inside the `if` and the result never gets assigned
      if connected?(socket) do
        socket = assign(socket, :val, val)
      end

      # VALID: we rebind the result of the `if` to a new variable
      socket =
        if connected?(socket) do
          assign(socket, :val, val)
        end

- **Never** nest multiple modules in the same file as it can cause cyclic dependencies and compilation errors
- **Never** use map access syntax (`changeset[:field]`) on structs as they do not implement the Access behaviour by default. For regular structs, you **must** access the fields directly, such as `my_struct.field` or use higher level APIs that are available on the struct if they exist, `Ecto.Changeset.get_field/2` for changesets
- Elixir's standard library has everything necessary for date and time manipulation. Familiarize yourself with the common `Time`, `Date`, `DateTime`, and `Calendar` interfaces by accessing their documentation as necessary. **Never** install additional dependencies unless asked or for date/time parsing (which you can use the `date_time_parser` package)
- Don't use `String.to_atom/1` on user input (memory leak risk)
- Predicate function names should not start with `is_` and should end in a question mark. Names like `is_thing` should be reserved for guards
- Elixir's builtin OTP primitives like `DynamicSupervisor` and `Registry`, require names in the child spec, such as `{DynamicSupervisor, name: MyApp.MyDynamicSup}`, then you can use `DynamicSupervisor.start_child(MyApp.MyDynamicSup, child_spec)`
- Use `Task.async_stream(collection, callback, options)` for concurrent enumeration with back-pressure. The majority of times you will want to pass `timeout: :infinity` as option

## Mix guidelines

- Read the docs and options before using tasks (by using `mix help task_name`)
- To debug test failures, run tests in a specific file with `mix test test/my_test.exs` or run all previously failed tests with `mix test --failed`
- `mix deps.clean --all` is **almost never needed**. **Avoid** using it unless you have good reason

## Test guidelines

- **Always use `start_supervised!/1`** to start processes in tests as it guarantees cleanup between tests
- **Avoid** `Process.sleep/1` and `Process.alive?/1` in tests
  - Instead of sleeping to wait for a process to finish, **always** use `Process.monitor/1` and assert on the DOWN message:

      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

   - Instead of sleeping to synchronize before the next call, **always** use `_ = :sys.get_state/1` to ensure the process has handled prior messages
<!-- phoenix:elixir-end -->

<!-- phoenix:phoenix-start -->
## Phoenix guidelines

- Remember Phoenix router `scope` blocks include an optional alias which is prefixed for all routes within the scope. **Always** be mindful of this when creating routes within a scope to avoid duplicate module prefixes.

- You **never** need to create your own `alias` for route definitions! The `scope` provides the alias, ie:

      scope "/admin", AppWeb.Admin do
        pipe_through :browser

        live "/users", UserLive, :index
      end

  the UserLive route would point to the `AppWeb.Admin.UserLive` module

- `Phoenix.View` no longer is needed or included with Phoenix, don't use it
<!-- phoenix:phoenix-end -->

<!-- phoenix:ecto-start -->
## Ecto Guidelines

- **Always** preload Ecto associations in queries when they'll be accessed in templates, ie a message that needs to reference the `message.user.email`
- Remember `import Ecto.Query` and other supporting modules when you write `seeds.exs`
- `Ecto.Schema` fields always use the `:string` type, even for `:text`, columns, ie: `field :name, :string`
- `Ecto.Changeset.validate_number/2` **DOES NOT SUPPORT the `:allow_nil` option**. By default, Ecto validations only run if a change for the given field exists and the change value is not nil, so such as option is never needed
- You **must** use `Ecto.Changeset.get_field(changeset, :field)` to access changeset fields
- Fields which are set programmatically, such as `user_id`, must not be listed in `cast` calls or similar for security purposes. Instead they must be explicitly set when creating the struct
- **Always** invoke `mix ecto.gen.migration migration_name_using_underscores` when generating migration files, so the correct timestamp and conventions are applied
<!-- phoenix:ecto-end -->

<!-- phoenix:html-start -->
## Phoenix HTML guidelines

- Phoenix templates **always** use `~H` or .html.heex files (known as HEEx), **never** use `~E`
- **Always** use the imported `Phoenix.Component.form/1` and `Phoenix.Component.inputs_for/1` function to build forms. **Never** use `Phoenix.HTML.form_for` or `Phoenix.HTML.inputs_for` as they are outdated
- When building forms **always** use the already imported `Phoenix.Component.to_form/2` (`assign(socket, form: to_form(...))` and `<.form for={@form} id="msg-form">`), then access those forms in the template via `@form[:field]`
- **Always** add unique DOM IDs to key elements (like forms, buttons, etc) when writing templates, these IDs can later be used in tests (`<.form for={@form} id="product-form">`)
- For "app wide" template imports, you can import/alias into the `my_app_web.ex`'s `html_helpers` block, so they will be available to all LiveViews, LiveComponent's, and all modules that do `use MyAppWeb, :html` (replace "my_app" by the actual app name)

- Elixir supports `if/else` but **does NOT support `if/else if` or `if/elsif`**. **Never use `else if` or `elseif` in Elixir**, **always** use `cond` or `case` for multiple conditionals.

  **Never do this (invalid)**:

      <%= if condition do %>
        ...
      <% else if other_condition %>
        ...
      <% end %>

  Instead **always** do this:

      <%= cond do %>
        <% condition -> %>
          ...
        <% condition2 -> %>
          ...
        <% true -> %>
          ...
      <% end %>

- HEEx require special tag annotation if you want to insert literal curly's like `{` or `}`. If you want to show a textual code snippet on the page in a `<pre>` or `<code>` block you *must* annotate the parent tag with `phx-no-curly-interpolation`:

      <code phx-no-curly-interpolation>
        let obj = {key: "val"}
      </code>

  Within `phx-no-curly-interpolation` annotated tags, you can use `{` and `}` without escaping them, and dynamic Elixir expressions can still be used with `<%= ... %>` syntax

- HEEx class attrs support lists, but you must **always** use list `[...]` syntax. You can use the class list syntax to conditionally add classes, **always do this for multiple class values**:

      <a class={[
        "px-2 text-white",
        @some_flag && "py-5",
        if(@other_condition, do: "border-red-500", else: "border-blue-100"),
        ...
      ]}>Text</a>

  and **always** wrap `if`'s inside `{...}` expressions with parens, like done above (`if(@other_condition, do: "...", else: "...")`)

  and **never** do this, since it's invalid (note the missing `[` and `]`):

      <a class={
        "px-2 text-white",
        @some_flag && "py-5"
      }> ...
      => Raises compile syntax error on invalid HEEx attr syntax

- **Never** use `<% Enum.each %>` or non-for comprehensions for generating template content, instead **always** use `<%= for item <- @collection do %>`
- HEEx HTML comments use `<%!-- comment --%>`. **Always** use the HEEx HTML comment syntax for template comments (`<%!-- comment --%>`)
- HEEx allows interpolation via `{...}` and `<%= ... %>`, but the `<%= %>` **only** works within tag bodies. **Always** use the `{...}` syntax for interpolation within tag attributes, and for interpolation of values within tag bodies. **Always** interpolate block constructs (if, cond, case, for) within tag bodies using `<%= ... %>`.

  **Always** do this:

      <div id={@id}>
        {@my_assign}
        <%= if @some_block_condition do %>
          {@another_assign}
        <% end %>
      </div>

  and **Never** do this – the program will terminate with a syntax error:

      <%!-- THIS IS INVALID NEVER EVER DO THIS --%>
      <div id="<%= @invalid_interpolation %>">
        {if @invalid_block_construct do}
        {end}
      </div>
<!-- phoenix:html-end -->

<!-- phoenix:liveview-start -->
## Phoenix LiveView guidelines

- **Never** use the deprecated `live_redirect` and `live_patch` functions, instead **always** use the `<.link navigate={href}>` and  `<.link patch={href}>` in templates, and `push_navigate` and `push_patch` functions LiveViews
- **Avoid LiveComponent's** unless you have a strong, specific need for them
- LiveViews should be named like `AppWeb.WeatherLive`, with a `Live` suffix. When you go to add LiveView routes to the router, the default `:browser` scope is **already aliased** with the `AppWeb` module, so you can just do `live "/weather", WeatherLive`

### LiveView streams

- **Always** use LiveView streams for collections for assigning regular lists to avoid memory ballooning and runtime termination with the following operations:
  - basic append of N items - `stream(socket, :messages, [new_msg])`
  - resetting stream with new items - `stream(socket, :messages, [new_msg], reset: true)` (e.g. for filtering items)
  - prepend to stream - `stream(socket, :messages, [new_msg], at: -1)`
  - deleting items - `stream_delete(socket, :messages, msg)`

- When using the `stream/3` interfaces in the LiveView, the LiveView template must 1) always set `phx-update="stream"` on the parent element, with a DOM id on the parent element like `id="messages"` and 2) consume the `@streams.stream_name` collection and use the id as the DOM id for each child. For a call like `stream(socket, :messages, [new_msg])` in the LiveView, the template would be:

      <div id="messages" phx-update="stream">
        <div :for={{id, msg} <- @streams.messages} id={id}>
          {msg.text}
        </div>
      </div>

- LiveView streams are *not* enumerable, so you cannot use `Enum.filter/2` or `Enum.reject/2` on them. Instead, if you want to filter, prune, or refresh a list of items on the UI, you **must refetch the data and re-stream the entire stream collection, passing reset: true**:

      def handle_event("filter", %{"filter" => filter}, socket) do
        # re-fetch the messages based on the filter
        messages = list_messages(filter)

        {:noreply,
         socket
         |> assign(:messages_empty?, messages == [])
         # reset the stream with the new messages
         |> stream(:messages, messages, reset: true)}
      end

- LiveView streams *do not support counting or empty states*. If you need to display a count, you must track it using a separate assign. For empty states, you can use Tailwind classes:

      <div id="tasks" phx-update="stream">
        <div class="hidden only:block">No tasks yet</div>
        <div :for={{id, task} <- @streams.tasks} id={id}>
          {task.name}
        </div>
      </div>

  The above only works if the empty state is the only HTML block alongside the stream for-comprehension.

- When updating an assign that should change content inside any streamed item(s), you MUST re-stream the items
  along with the updated assign:

      def handle_event("edit_message", %{"message_id" => message_id}, socket) do
        message = Chat.get_message!(message_id)
        edit_form = to_form(Chat.change_message(message, %{content: message.content}))

        # re-insert message so @editing_message_id toggle logic takes effect for that stream item
        {:noreply,
         socket
         |> stream_insert(:messages, message)
         |> assign(:editing_message_id, String.to_integer(message_id))
         |> assign(:edit_form, edit_form)}
      end

  And in the template:

      <div id="messages" phx-update="stream">
        <div :for={{id, message} <- @streams.messages} id={id} class="flex group">
          {message.username}
          <%= if @editing_message_id == message.id do %>
            <%!-- Edit mode --%>
            <.form for={@edit_form} id="edit-form-#{message.id}" phx-submit="save_edit">
              ...
            </.form>
          <% end %>
        </div>
      </div>

- **Never** use the deprecated `phx-update="append"` or `phx-update="prepend"` for collections

### LiveView JavaScript interop

- Remember anytime you use `phx-hook="MyHook"` and that JS hook manages its own DOM, you **must** also set the `phx-update="ignore"` attribute
- **Always** provide an unique DOM id alongside `phx-hook` otherwise a compiler error will be raised

LiveView hooks come in two flavors, 1) colocated js hooks for "inline" scripts defined inside HEEx,
and 2) external `phx-hook` annotations where JavaScript object literals are defined and passed to the `LiveSocket` constructor.

#### Inline colocated js hooks

**Never** write raw embedded `<script>` tags in heex as they are incompatible with LiveView.
Instead, **always use a colocated js hook script tag (`:type={Phoenix.LiveView.ColocatedHook}`)
when writing scripts inside the template**:

    <input type="text" name="user[phone_number]" id="user-phone-number" phx-hook=".PhoneNumber" />
    <script :type={Phoenix.LiveView.ColocatedHook} name=".PhoneNumber">
      export default {
        mounted() {
          this.el.addEventListener("input", e => {
            let match = this.el.value.replace(/\D/g, "").match(/^(\d{3})(\d{3})(\d{4})$/)
            if(match) {
              this.el.value = `${match[1]}-${match[2]}-${match[3]}`
            }
          })
        }
      }
    </script>

- colocated hooks are automatically integrated into the app.js bundle
- colocated hooks names **MUST ALWAYS** start with a `.` prefix, i.e. `.PhoneNumber`

#### External phx-hook

External JS hooks (`<div id="myhook" phx-hook="MyHook">`) must be placed in `assets/js/` and passed to the
LiveSocket constructor:

    const MyHook = {
      mounted() { ... }
    }
    let liveSocket = new LiveSocket("/live", Socket, {
      hooks: { MyHook }
    });

#### Pushing events between client and server

Use LiveView's `push_event/3` when you need to push events/data to the client for a phx-hook to handle.
**Always** return or rebind the socket on `push_event/3` when pushing events:

    # re-bind socket so we maintain event state to be pushed
    socket = push_event(socket, "my_event", %{...})

    # or return the modified socket directly:
    def handle_event("some_event", _, socket) do
      {:noreply, push_event(socket, "my_event", %{...})}
    end

Pushed events can then be picked up in a JS hook with `this.handleEvent`:

    mounted() {
      this.handleEvent("my_event", data => console.log("from server:", data));
    }

Clients can also push an event to the server and receive a reply with `this.pushEvent`:

    mounted() {
      this.el.addEventListener("click", e => {
        this.pushEvent("my_event", { one: 1 }, reply => console.log("got reply from server:", reply));
      })
    }

Where the server handled it via:

    def handle_event("my_event", %{"one" => 1}, socket) do
      {:reply, %{two: 2}, socket}
    end

### LiveView tests

- `Phoenix.LiveViewTest` module and `LazyHTML` (included) for making your assertions
- Form tests are driven by `Phoenix.LiveViewTest`'s `render_submit/2` and `render_change/2` functions
- Come up with a step-by-step test plan that splits major test cases into small, isolated files. You may start with simpler tests that verify content exists, gradually add interaction tests
- **Always reference the key element IDs you added in the LiveView templates in your tests** for `Phoenix.LiveViewTest` functions like `element/2`, `has_element/2`, selectors, etc
- **Never** tests again raw HTML, **always** use `element/2`, `has_element/2`, and similar: `assert has_element?(view, "#my-form")`
- Instead of relying on testing text content, which can change, favor testing for the presence of key elements
- Focus on testing outcomes rather than implementation details
- Be aware that `Phoenix.Component` functions like `<.form>` might produce different HTML than expected. Test against the output HTML structure, not your mental model of what you expect it to be
- When facing test failures with element selectors, add debug statements to print the actual HTML, but use `LazyHTML` selectors to limit the output, ie:

      html = render(view)
      document = LazyHTML.from_fragment(html)
      matches = LazyHTML.filter(document, "your-complex-selector")
      IO.inspect(matches, label: "Matches")

### Form handling

#### Creating a form from params

If you want to create a form based on `handle_event` params:

    def handle_event("submitted", params, socket) do
      {:noreply, assign(socket, form: to_form(params))}
    end

When you pass a map to `to_form/1`, it assumes said map contains the form params, which are expected to have string keys.

You can also specify a name to nest the params:

    def handle_event("submitted", %{"user" => user_params}, socket) do
      {:noreply, assign(socket, form: to_form(user_params, as: :user))}
    end

#### Creating a form from changesets

When using changesets, the underlying data, form params, and errors are retrieved from it. The `:as` option is automatically computed too. E.g. if you have a user schema:

    defmodule MyApp.Users.User do
      use Ecto.Schema
      ...
    end

And then you create a changeset that you pass to `to_form`:

    %MyApp.Users.User{}
    |> Ecto.Changeset.change()
    |> to_form()

Once the form is submitted, the params will be available under `%{"user" => user_params}`.

In the template, the form form assign can be passed to the `<.form>` function component:

    <.form for={@form} id="todo-form" phx-change="validate" phx-submit="save">
      <.input field={@form[:field]} type="text" />
    </.form>

Always give the form an explicit, unique DOM ID, like `id="todo-form"`.

#### Avoiding form errors

**Always** use a form assigned via `to_form/2` in the LiveView, and the `<.input>` component in the template. In the template **always access forms this**:

    <%!-- ALWAYS do this (valid) --%>
    <.form for={@form} id="my-form">
      <.input field={@form[:field]} type="text" />
    </.form>

And **never** do this:

    <%!-- NEVER do this (invalid) --%>
    <.form for={@changeset} id="my-form">
      <.input field={@changeset[:field]} type="text" />
    </.form>

- You are FORBIDDEN from accessing the changeset in the template as it will cause errors
- **Never** use `<.form let={f} ...>` in the template, instead **always use `<.form for={@form} ...>`**, then drive all form references from the form assign as in `@form[:field]`. The UI should **always** be driven by a `to_form/2` assigned in the LiveView module that is derived from a changeset
<!-- phoenix:liveview-end -->

<!-- usage-rules-end -->
