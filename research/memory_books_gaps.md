# Memory Books: what is missing or different

The current state, 2026-10-13. It replaces the October 3 inventory, which was written against
SillyTavern-MemoryBooks (STMB) v8.5.0. Since then Mythweaver has built Memory Assistance, the
noncontiguous topical clip picker, Combine Clips, the consolidation coverage check, regenerating one
consolidation candidate, memory reminders, per-character Memory Books with locks, character memory
prompts and an "Always present" cast, and Side Prompt Sets with runtime macros. Those features are
not listed here, except where they behave differently from STMB.

The reference is STMB's current *Memory Books: Complete AI Reference Manual*
(`userguides/1 Memory_Books_AI_Reference_Manual.md` on `main`; the § numbers below), checked against
the source at commit `b1e6ad2cd184eeb55800b25adac089ddace8573f`. Aiko Hanasaki's review of the
October inventory set the priorities. The built-in memory prompts in `priv/repo/seeds/memory.exs` are
STMB's own text (commits `c44cd31551b79eb6ebff3bde677691a842b18a6d` and `b1e6ad2c…`), reused with her
permission; both projects are AGPL-3.0.

Each table lists the feature, the STMB reference, what STMB does, and what Mythweaver does instead.
"Missing" means nothing equivalent exists. "Replaced" means Mythweaver covers the same need another
way. "Differs" means the feature exists but a rule or option differs from the manual.

## Group and cast memory routing

| Feature | STMB ref | STMB | Mythweaver |
|---|---|---|---|
| Participant confirmation popup, auto-accept setting, "no participants detected" warning | §11.2 | Asks who took part before every memory is written. Selecting nobody applies the memory to every group member. | Replaced. Speakers are detected (`Memory.Scene.speakers/3`), plus the chat's "Always present" cast (`chat_memory_settings.cast_ids`) and an optional "Present" override on Create a memory. When only the player speaks, every non-player character gets a copy. There is no confirmation step. |
| Locks belong to the character card | §6.5 | A lock follows the card into every compatible chat. | Differs. A lock belongs to one user and one character (`memory_character_books`), because a personal book cannot be bound to a site character (`Ownership.reference_ok?`). It applies in all of that user's chats. A lock whose book the user can no longer edit is shown as broken, and no copy is written for that character until it is unlocked. That matches STMB. |
| Copies written all-or-nothing | §11.4 | If one copy fails to save, STMB rolls back the copies already written. | Differs. Verbatim copies (no character memory prompt) are written in the shared memory's transaction. Point-of-view copies are separate background `:memory` jobs. One can fail while the shared memory and the other copies stay saved. |
| Regenerating the shared memory | §11.8, §19.1 | Asks whether to regenerate only that entry or together with its linked copies. Each copy gets its own generation and approval. | Differs. Approving a regenerated shared memory always refreshes its copies. Verbatim copies are rewritten in the same transaction. Point-of-view copies are rewritten in place by background jobs, with no review. A copy cannot be regenerated on its own (`{:error, :copy}`). A copy already consumed by a consolidation is not refreshed. |
| Copy precedence in the chat it came from | §11.4 | The character's copy takes precedence over the shared version on that character's turn. | Same rule. The prompt inspector and preview have no replying character, so they show the shared entry only. A per-chat (unlocked) character book is active in that chat for its character's turns. |
| Shared book also used as a character book | §11.4 | Stores the shared entry and the character's copy as separate entries. | Same. The copy reuses the shared entry's number and title. It is left out of the book's consolidation, memory counts and previous memories, and is switched off and restored together with the shared entry. |
| Group consolidation analysis prompt | §11.10 | Each character book runs its own consolidation stream. The group book uses a group-specific analysis prompt. | Partial. Every book that receives memories, character books included, gets its own readiness check. There is no group consolidation prompt: every book uses the profile's `consolidation_prompt_id`. |
| STLO integration | §11.6 | Hands memory entries to the SillyTavern Lorebook Ordering extension. | No equivalent concept. |
| Narrator Mode: cast manager, Active Cast drawer, cast snapshots on messages and swipes, unique books per cast member, retire/restore | §12 | Tracks a narrator-run cast and records who was present on each message, so memories route to the right books. | Missing. The per-chat "Always present" cast and the character books are the closest equivalents. Would plug into `Messages.Message` and `memory_records`. |

## Storage modes

| Feature | STMB ref | STMB | Mythweaver |
|---|---|---|---|
| Auto-create naming template with `{{char}}`/`{{user}}`/`{{chat}}` | §6.2 | Names the automatically created book from a template. | Replaced by the fixed `"<chat> Memories"` name in `Memory.ensure_book/2`. |
| Automatic vs Manual Lorebook Mode switch | §6.1–6.3 | Chooses between a chat-bound book STMB creates and one the user picks. | Replaced by the per-chat book select. |
| Copy Memory Books when branching | §13 | Duplicates a chat's books for a branch. | No equivalent concept (no chat branches). |

## Profiles, scenes and generation

| Feature | STMB ref | STMB | Mythweaver |
|---|---|---|---|
| Scene summary before creating | §8.3 | Create a memory shows the start, end, speakers, message count and token estimate before you confirm. | Missing. The form takes From/To/Previous and a participant override. A token count appears only after submitting, and only above `memory.token_warning_threshold`. |
| Structured output default | §7.5 | Sends a structured-output schema unless the profile opts out. | Differs. `Memory.Profile.structured_output` defaults to `false`. |
| Global max response tokens | §27.2 | One setting caps every STMB request (0 = provider default). | Differs. Only per profile (`Memory.Profile.max_tokens`). |
| STMB profile connection fields (Full Manual endpoint, reverse proxy, ChatCompletionService, Chat Completion preset) | §7.4–7.7 | Gives each profile its own endpoint, proxy, service and preset. | Replaced by Mythweaver providers and models. |
| "Number of automatic summary attempts" | §27.9 | Retries a failed summary request that many times. | Replaced by one repair retry for unparseable JSON. |
| Regeneration choices | §19.1 | Regenerating a scene memory lets you pick the profile, prompt, previous-memory count and Additional Context for that run. | Missing. Regeneration uses the chat's current profile, prompt and context and `memory.default_previous_count`. |

## Clips and topical clips

| Feature | STMB ref | STMB | Mythweaver |
|---|---|---|---|
| Turn an existing entry into a Clip | §14.4 | Adding `[STMB Clip]` to an entry's title makes it a Clip. | Missing. A clip is a `memory_records` row of kind `:clip`, and nothing creates one for an existing entry. Import does not recognise the suffix either. |
| Topical Format and Combined Format | §15.3, §27.8 | Editable templates (`{{CONTENT}}`, optional `{{TITLE}}`) wrap the body of new and updated topical and combined clips. | Missing. The model's text is saved as is (`Workers.TopicalClip.finish/3`). |
| Insertion override when saving a clip | §15.3 | Each save can override position, order and outlet name. | Missing. Placement always comes from the governing memory profile (`Memory.write_entry/8`). |
| Message picker details | §15.3 | Highlights matches, reveals the previous and next message for context, and offers "Refresh results" when a picked message has changed. | Partial. Search, Load more, Hidden only, Select loaded, Clear and selection that survives searches all exist. There is no highlighting and no previous/next context. A changed message fails the job at save time (`:changed`) instead of offering a refresh. |
| Show/hide setting for the floating clip button | §27.2 | Turns the button over selected text on or off. | Missing. |

## Memory Assistance

| Feature | STMB ref | STMB | Mythweaver |
|---|---|---|---|
| Choosing which clips to review | §16.5 | Update reviews up to five clips directly. Above five it opens a selection list (Query Selected / Query All). | Differs. Each run is a background job with nobody to ask. Every enabled clip of the book is reviewed in token batches, and the review card's keep boxes do the selecting. |
| Separate Memory Assistance settings | §27.6 | "Edit Memory Assistance" has its own Update and Topic Suggestions prompts and an optional connection profile override. | Differs. The prompts are memory profile fields (`clip_review_prompt_id`, `clip_suggestions_prompt_id`), and the model is the chat's memory model. Only the mode (`memory.assistance_mode`) is a setting of its own. |
| Confirmed topics drafted one at a time | §16.5 | Confirmed topics open the Topical Clip draft one after another. | Differs. Approving queues one draft per topic at once; each lands in Reviews. A topic stays pending (`memory_topic_suggestions`) until its topical clip is saved, and can be redrafted or dismissed from the Topical tab, as in STMB. |

## Side prompts

| Feature | STMB ref | STMB | Mythweaver |
|---|---|---|---|
| "Allow manual run" flag | §27.6 | Hides a side prompt from manual runs so it only fires on its triggers. | Missing. Every side prompt can be run manually. |
| Macro names | §16.9 | Any `{{name}}`, including names with spaces (`{{npc name}}`). | Differs. Macros are Liquid top-level variables, so names must match `[a-z_][a-z0-9_]*` (`{{ npc_name }}`). STMB templates with spaced names need renaming. |
| Duplicating a set row | §16.7 | Set rows have duplicate and delete actions. | Missing. `SidePromptSetLive` has add, remove and move up/down. |
| Set name uniqueness | §16.7 | Sets are per user. | Same: names are unique per owner (site sets share one namespace). |
| Concurrent side prompt limit | §27.6 | A global setting (1–10) caps how many side prompts run at once. | Replaced. Memory jobs share one lane per chat, and providers cap their own concurrency (`Provider.max_concurrency`). |
| `/sideprompt…` and `/sideprompt-macroset` commands | §16.9, §28 | Run side prompts and fill their macros from the chat input. | Partial. The command palette has `chat: run side prompt` and enable/disable (one or all), and Lua has `mw.memory.*`. There is no palette command for macro values or for running a side prompt set; both are only in the Memory panel's Side tab. |
| Side prompt import/export | §31 | Saves templates to a file and loads them back. | Blocked on Phase 2 import/export. |

## Context, prompts and titles

| Feature | STMB ref | STMB | Mythweaver |
|---|---|---|---|
| Context Settings as named collections (new, duplicate, delete, import, export, "No Context" vs unset) | §20.4, §27.5 | Reusable sets of Additional Context entries shared by chats and side prompts. | Replaced by the per-chat ordered `chat_memory_settings.context_entry_ids`. |
| Prompt manager import/export, recreate and localized built-ins | §22, §31 | Moves memory prompts in and out as files and restores or translates the built-ins. | Blocked on Phase 2 import/export. |
| Dedicated regeneration-only consolidation preset | §19.2, §21.5 | Uses a separate prompt when one existing consolidation is regenerated. | Replaced by the profile's consolidation prompt. |
| More built-in summary prompts | §21.2 | Summarize, Synopsis, Sum Up, Northgate and Aelemar. | Missing. Summary, Minimal, Comprehensive, Group and Character ("Memory: Character") are seeded. The rest can be copied from STMB `utils.js` (permission already granted). |
| Title presets | §24 | A menu of ready-made title formats. | Missing. One default, `"[000] - {{title}}"`. |
| `{{groupname}}` title macro | §24.1 | The group's display name, separate from `{{char}}`. | Missing. `{{char}}` already joins the non-player names (`Memory.Title`). |
| Compound numbering tokens `#[000]`, `([000])`, `{[000]}` | §24.2 | Supported alongside `[000]`, `(000)`, `{000}`, `#000`. | Missing. `Memory.Title`'s token pattern handles only the simple forms. |
| Regex integration, outgoing and incoming | §23.3 | Runs SillyTavern regex scripts over the prompt and the reply. | Missing. Would plug into `Memory.Request.input/7` and the workers' `finish/3`. |
| Consolidation prompt's keyword line | §17.5 | The keyword prompt ends "Return ONLY a JSON array of 15-30 strings…". | Differs. That line is dropped from the seeded "Consolidation" prompt because it contradicts the analysis JSON, and the sources heading is `=== SOURCE ENTRIES ===`, not the plural of the child tier. |

## Lore entries

| Feature | STMB ref | STMB | Mythweaver |
|---|---|---|---|
| Vectorized activation | §10.2 | Activates memories by embedding similarity. | Blocked on an embedder (`Lore.Matcher` moduledoc). |
| Delay Until Recursion | §10.4, §27.4 | Keeps an entry from activating until a recursive scan pass triggers it. | Missing. `LoreEntry` has `exclude_recursion` and `prevent_recursion`, but no delay-until-recursion field. |
| Reverse insertion-order mode | §27.4 | Numbers memory order downward, so newer memories sort first. | Missing. Would plug into `Memory.Profile.order_mode`. |

## Chat UI and notifications

| Feature | STMB ref | STMB | Mythweaver |
|---|---|---|---|
| Draggable jump-to-boundary button | §9.4 | A movable button that scrolls to the processed-message boundary. | Missing. Only the divider exists (`memory.boundary_indicator`). |
| Separate "unhide before generation" toggle with re-hide after save | §9.3 | Unhides hidden messages for the memory request and hides them again after saving. | Replaced by `memory.include_hidden`. |
| Reminder lifecycle | §27.3 | The reminder clears on chat switch, boundary change or mode change; it can be postponed; checks also run when memory work goes idle. | Differs. A reminder is an ordinary flash that stays until closed or replaced by another flash. There is no postpone. Checks run after each message and each finished reply (`Memory.Auto.check/2`). |
| Disabled Regenerate with a reason | §29.11 | A disabled control explains why on hover. | Differs. The button is hidden when regeneration isn't possible. |
| Notifications toggle | §27.2 | Turns STMB's toasts on or off. | Missing. |
| Slash commands (`/creatememory`, `/scenememory`, `/nextmemory`, `/stmb-catchup`, `/stmb-highest`, `/stmb-set-highest`, `/stmb-stop`) | §28 | Runs memory, catch-up, boundary and stop actions from the chat input. | Replaced by command palette commands (`chat: create memory`, `… scene memory`, `… next memory`, `catch up memories`, show/set/clear processed boundary, `consolidate memories`) and Lua `mw.memory.*`. There is no `/stmb-stop` equivalent for memory work: `chat: stop generation` stops a chat reply, and memory jobs are stopped on `/jobs`. |

## Consolidation and review

| Feature | STMB ref | STMB | Mythweaver |
|---|---|---|---|
| Edits to left-out sources | §17.5 | — | Differs. An unattended save checks and row-locks every source. An approval checks only the sources the kept candidates claim. Left-out sources are listed above the candidates, and Save asks for confirmation when any are left out. |
| Consolidation recovery checkpoints | §25 | Saves a partly committed consolidation so it can resume. | Replaced by single-transaction saves. |

## Rollback

| Feature | STMB ref | STMB | Mythweaver |
|---|---|---|---|
| Full/Affected/Cancel prompt on a middle deletion | §27.2 | Asks how far to roll back each time a middle message is deleted. | Replaced by the `memory.rollback_scope` preference. |
| Branch/checkpoint rollback | §27.2 | Rolls memories back when moving to a branch or an earlier checkpoint. | No equivalent concept. |

## Job queue

| Feature | STMB ref | STMB | Mythweaver |
|---|---|---|---|
| Retry scopes | §25 | Retry (one job), Retry All (the memory and its after-memory side prompts, resuming from an already-saved memory) and Retry Memory (skips the side prompts). | Missing. `Jobs.retry/2` reruns one job. A retried memory runs its after-memory side prompts again when it saves. |
| UI for per-tag deadlines and guards | §27.6 | Sets job timeouts and guards in the app. | Missing. App config only (`config :mythweaver, Mythweaver.Jobs`). |
| Loop guard for chat replies | — | — | Off by default (`Jobs.tag_options/1` `reply:`); memory jobs have it. |
| Pending-progress records for chats closed mid-job | §25 | Remembers in-flight work so it can finish when the chat reopens. | No equivalent concept; jobs run and write server-side. |
| Aikobots idempotent operation receipts | — | Records each write under an operation id so a retry applies once. | Replaced by Postgres transactions. |

## Interop

| Feature | STMB ref | STMB | Mythweaver |
|---|---|---|---|
| Import of STMB books | §31 | Brings books in with their STMB metadata. | Partial. World info import adopts `stmemorybooks` entries as memories of their book and STMB summaries as consolidations of their tier, linked to their sources (`Mythweaver.Import`, `Memory.adopt_memories/3`). `STMB_start`/`STMB_end`/`STMB_chatId` are not mapped, so imported memories have no chat or range and can't be regenerated. `[STMB Clip]` entries are not adopted as clips. |
| Export with STMB metadata | §31 | Writes books out with `stmemorybooks`, ranges, chat ids and `disabledBySummaryId`. | Blocked on Phase 2 import/export. Would read `memory_records` (`consolidated_into_id`, `disabled_by_consolidation`) and `lore_book_entries.enabled` (`Memory.record_enabled?/1`). |

## Implementation notes that are not gaps

- The material blocks of the seeded memory prompts (the scene, sources and clips) are `:user` messages; the instructions are `:system`.
- The "Side: Plot tracker" response format sits at the end of its user block under `=== RESPONSE FORMAT ===`, in STMB `buildPrompt()` order, so the system block holds only the instruction.
- Interval side prompts run even with automatic memories off, at the cost of one side-prompt query per message.
- Topical clip change detection compares a sha256 of each source entry's current content, because manual lore edits don't update `written_fingerprint`.
- STMB's memory-count macros (`{{memtier0}}`…, `{{memclips}}`, `{{memside}}`) are `anchors.memory_counts.*`.
