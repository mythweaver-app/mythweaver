import Ecto.Query

alias Mythweaver.Memory
alias Mythweaver.Memory.Profile
alias Mythweaver.Memory.SidePrompt
alias Mythweaver.Prompts
alias Mythweaver.Prompts.Block
alias Mythweaver.Prompts.Prompt
alias Mythweaver.Prompts.PromptBlock
alias Mythweaver.Repo

Code.require_file("scope.exs", __DIR__)
seed_scope = Mythweaver.Seeds.scope()

# Seed Memory Books: the built-in memory prompts, the "Default" profile, the "Plot tracker" side
# prompt and the preferences row.
#
# Runnable on its own (`mix run priv/repo/seeds/memory.exs`) and required by `priv/repo/seeds.exs`
# after the roleplay prompts. Idempotent: prompts, blocks, the profile and the side prompt are upserted
# by name, so a second run changes nothing and a run after an edit restores the built-in text.
#
# From SillyTavern-MemoryBooks by Aiko Hanasaki (AGPL-3.0), used with permission.
# https://github.com/aikohanasaki/SillyTavern-MemoryBooks at commit
# c44cd31551b79eb6ebff3bde677691a842b18a6d. Sources:
#
#   * utils.js `getBuiltInPresetPrompts()`: `summary`, `minimal`, `comprehensive`, `group`
#   * templatesArcPrompts.js `arc_default` (the consolidation analysis prompt), followed by
#     consolidationPromptDefaults.js `DEFAULT_CONSOLIDATION_KEYWORD_PROMPT` minus its last line
#     ("Return ONLY a JSON array of 15-30 strings. …"), which would contradict the analysis JSON
#   * clipPromptDefaults.js `DEFAULT_COMPACTION_PROMPT_TEMPLATE`, `DEFAULT_TOPICAL_CLIP_PROMPT_TEMPLATE`
#   * at commit b1e6ad2cd184eeb55800b25adac089ddace8573f: utils.js `getBuiltInPresetPrompts()` `char`;
#     clipPromptDefaults.js `DEFAULT_CLIP_REVIEW_PROMPT`, `DEFAULT_CLIP_SUGGESTIONS_PROMPT`;
#     clipReview.js's REQUIRED JSON RESPONSE contracts; combineClipsPolicy.js `DEFAULT_COMBINE_CLIPS_PROMPT`
#   * sidePromptsManager.js `getBuiltinTemplates()` "Plotpoints" (prompt and response format)
#   * the `:user` blocks' section headings: stmemory.js `formatSceneForAI()`, arcanalysis.js
#     `buildSummaryAnalysisPrompt()` and sidePrompts.js `buildPrompt()`, in the same order
#
# Each `:system` block is STMB's text verbatim except for these macro substitutions:
#
#   {{user}}            -> {{ anchors.player.name }}
#   {{char}}            -> {{ anchors.memory.speakers }}, except in Memory: Character, where it is
#                          {{ anchors.memory.character }}
#   {{TITLE}}           -> {{ anchors.memory.topic }} (Combine clips)
#   {{SOURCE_CLIPS}}    -> a `{% for clip in anchors.memory.sources %}` loop printing STMB's
#                          `=== SNIPPET N: title ===` blocks (Combine clips)
#   {{group}}           -> {{ anchors.memory.speakers }}
#   {{TOPIC}}           -> {{ anchors.memory.topic }}
#   {{KEYWORDS}}        -> {{ anchors.memory.keywords }}
#   {{EXISTING_CLIP}}, {{ENTRY_CONTENT}} -> {{ anchors.memory.entry.content }}
#   {{ENTRY_TITLE}}     -> {{ anchors.memory.entry.title }}
#   {{ENTRY_KIND}}      -> {{ anchors.memory.entry.kind }}
#   {{SOURCE_MEMORIES}} -> {{ anchors.memory.sources_text }}
#   {{SOURCE_MESSAGES}} -> {{ anchors.memory.scene }}
#   {{MODE}}            -> {% if anchors.memory.entry %}update{% else %}create{% endif %}
#   {{stmbtier}}        -> {{ anchors.memory.target_tier.name }}
#   {{stmbchildtier}}   -> {{ child_tier }}, assigned by a one-line `case` on the target tier number
#                          at the top of the consolidation block (the tier below the target)
#
# STMB's text contains no other `{{`/`{%` sequences, so nothing needs `{% raw %}`.

attribution = "From SillyTavern-MemoryBooks by Aiko Hanasaki (AGPL-3.0), used with permission."

memory_summary = ~S"""
You are a talented summarist skilled at capturing scenes from stories comprehensively. Analyze the following roleplay scene and return a detailed memory as JSON.

You must respond with ONLY valid JSON in this exact format:
{
  "title": "Short scene title (1-3 words)",
  "content": "Detailed beat-by-beat summary in narrative prose...",
  "keywords": ["keyword1", "keyword2", "keyword3"]
}

For the content field, create a detailed beat-by-beat summary in narrative prose. First, note the dates/time. Then capture this scene accurately without losing ANY important information EXCEPT FOR [OOC] conversation/interaction. All [OOC] conversation/interaction is not useful for summaries.
This summary will go in lorebook entry, so include:
- All important story beats/events that happened
- Key interaction highlights and character developments
- Notable details, memorable quotes, and revelations
- Outcome and anything else important for future interactions between {{ anchors.player.name }} and {{ anchors.memory.speakers }}
Capture ALL nuance without repeating verbatim. Make it comprehensive yet digestible.

For the keywords field, provide 15-30 specific, descriptive, relevant keywords for keyword retrieval via word-matching in chat context. Keywords must be concrete and scene-specific (locations, objects, proper nouns, unique actions). Do not use abstract themes (e.g., "sadness", "love") or character names.

Return ONLY the JSON, no other text.
"""

memory_minimal = ~S"""
Analyze the following roleplay scene and return a minimal memory entry as JSON.

You must respond with ONLY valid JSON in this exact format:
{
  "title": "Short scene title (1-3 words)",
  "content": "Brief 2-5 sentence summary...",
  "keywords": ["keyword1", "keyword2", "keyword3"]
}

For the content field, provide a very brief 2-5 sentence summary of what happened in this scene. [OOC] conversation/interaction is not useful for summaries and should be ignored and excluded.

For the keywords field, generate 15-30 specific, descriptive, highly relevant keywords for database retrieval - focus on the most important terms that would help find this scene later. Keywords must be concrete and scene-specific (locations, objects, proper nouns, unique actions). Do not use abstract themes (e.g., "sadness", "love") or character names.

Return ONLY the JSON, no other text.
"""

memory_comprehensive = ~S"""
Analyze the following roleplay scene in the context of previous summaries provided (if available) and return a comprehensive synopsis as JSON.

You must respond with ONLY valid JSON in this exact format:
{
  "title": "Short, descriptive scene title (3-6 words)",
  "content": "Long detailed synopsis with markdown structure...",
  "keywords": ["keyword1", "keyword2", "keyword3"]
}

For the content field, create a beat-by-beat summary of the scene that *replaces reading the full scene* while preserving all plot-relevant nuance and reads like a clean, structured scene log — concise yet complete. This summary needs to be token-efficient: exercise judgment as to whether or not an interaction is flavor-only or truly affects the plot. Flavor scenes (interaction detail that does not advance plot) may be captured through key exchanges and should be skipped when recording story beats. 

Write in **past tense**, **third-person**, and exclude all [OOC] or meta discussion.  
Use concrete nouns (e.g., “rice cooker” > “appliance”).  
Only use adjectives/adverbs when they materially affect tone, emotion, or characterization.  
Focus on **cause → intention → reaction → consequence** chains for clarity and compression.

The `content` field must use this structure:

# [Scene Title]

**Timeline**: [Most specific date and time supported by the source entries; if unspecified, state unspecified or use relative time.]

## Story Beats

* Present the major actions, revelations, decisions, and emotional or magical shifts in chronological order.
* Explain what triggered each development, why characters acted, how others reacted, and what resulted.
* Include plot-affecting interactions, meaningful shared experiences, and events that changed relationships or future continuity.
* Omit repeated gestures, room dressing, background objects, and logistical detail unless they directly affected events.

## Character Dynamics

* Explain how motives, emotions, relationships, and power dynamics changed during the summarized period.
* Capture consequential subtext, tension, vulnerability, trust, conflict, avoidance, affection, resentment, or loyalty.
* Include small or domestic experiences only when they meaningfully shaped relationship history.
* Do not repeat plot events unless needed to explain the interpersonal change they caused.

## Important Facts

* Record newly established facts likely to matter later, including plans, risks, abilities, limitations, preferences, promises, secrets, debts, injuries, magical effects, discoveries, and obligations.
* Exclude casual preferences, scenery, errands, paperwork, clothing, furniture, weather, and other incidental details unless they became continuity-relevant.

## Key Exchanges

* Include only dialogue that defined a revelation, decision, conflict, emotional shift, or relationship change.
* Attribute each quotation by speaker name.
* Include a direct quotation only when the source entries preserve its exact wording. Never reconstruct quoted dialogue from a paraphrase.
* Preserve distinctive phrases or identifiers, such as “pack for forever” or “dick-measuring contest,” only when they are memorable or relationship-relevant.
* Include no more than 8 quotations.

## Outcome & Continuity

* State the final narrative, emotional, relational, physical, or magical condition produced by the events.
* Record resulting decisions, plans, risks, promises, secrets, injuries, knowledge, and obligations that affect what happens next.
* Identify unresolved threads, pending conflicts, future consequences, and foreshadowed developments.
* Do not recap the full sequence of events again.

For the `keywords` field:

Generate **12–20 natural retrieval keywords when the material supports them**. Use fewer rather than padding the list with weak terms. Keywords are search hooks, not miniature summaries or evidence notes.

Prioritize:

1. **Stable named entities**: people other than {{ anchors.memory.speakers }} or {{ anchors.player.name }}, places, organizations, events, documents, factions, spells, or distinctive objects.
2. **Major continuity anchors**: plans, threats, secrets, discoveries, investigations, conflicts, injuries, promises, relationship changes, and unresolved threads.
3. **Memorable moments**: meaningful shared activities, gifts, food, rituals, jokes, care-taking, arguments, or domestic events.
4. **Independent secondary hooks** that retrieve a separate part of the summarized material.

### Keyword construction

Use the shortest distinctive wording likely to remain recognizable under paraphrasing or reversed word order.

Examples:

* `Gala of the Silver Rose` or `Silver Rose Gala` → `Silver Rose`
* `Bromet Response SA` → `Bromet`
* `Château D’Aramitz`, Comte D’Aramitz, or a plan involving him → `D’Aramitz`
* Keep `Althof Ledger` when both words are required to identify the object.

Prefer one central named entity when it already covers several related events:

* `D’Aramitz rescue plan` → `D’Aramitz`
* `Bromet hidden contractors` → `Bromet`
* `Althof Ledger substitution` → `Althof Ledger`

Retain a modified phrase only when it provides an independent retrieval route not covered by the central entity:

* `fake caterers`
* `ledger facsimile`
* `safehouse breakfast`
* `counter-surveillance camera`

When several clues establish one conclusion, usually tag the resulting finding rather than each supporting clue:

* Uniforms, badges, and vehicle access → `fake caterers`
* Payments and company records → `Bromet`
* A covert tactical team at the gala → `suspected assassination`
* A rental used for equipment and disguises → `staging villa`

A supporting clue may remain only when it is memorable, likely to recur, or independently useful for retrieval.

Keywords should normally:

* Contain 1–4 words.
* Use ordinary noun phrases.
* Identify genuinely distinct parts of the summary.
* Remain stable if later descriptions use different wording.

Exclude:

* Incidental scenery or props.
* Exact times, quantities, card digits, invoice wording, or administrative details.
* Generic themes such as `danger`, `romance`, or `conversation`.
* Unsupported conclusions.
* Sentence-like evidence descriptions.
* Multiple keywords that merely restate or narrow the same named entity.

Before returning the JSON, silently verify that each keyword is natural to search, continuity-relevant, stable under paraphrasing, independently useful, and no longer than necessary.

Return ONLY the JSON — no additional text.
"""

memory_group = ~S"""
Analyze the following roleplay scene and create a memory entry from an omniscient POV.

You must respond with ONLY valid JSON in this exact format:
{
  "title": "Short, descriptive scene title (3-6 words)",
  "content": "Structured memory summary...",
  "keywords": ["keyword1", "keyword2", "keyword3"]
}

- Write the memory as continuity relevant to the target group as a shared unit.
- Include shared events, mutual decisions, group plans, promises, conflicts, secrets, relationship shifts, unresolved tensions, and facts that affect the group dynamic.
- Include individual actions or emotions only when they changed the shared group state.
- Do not create a merged personality for the group. Keep attribution clear: Alice did X, Bob thought Y, both agreed Z.
- If only one member knows something, say so. Do not imply shared knowledge unless the scene supports it.

For the content field, use this markdown structure:

# [Scene Title]
**Timeline**: (date/day/time, if known)

## Target-Relevant Events
- Summarize the events that matter to this group in chronological order.
- Use cause -> intention -> reaction -> consequence logic.
- Exclude flavor-only details unless they reveal a lasting character or relationship change.

## Attribution
- Clearly state who did what.
- Clearly state who knew what.
- Clearly state who felt, believed, suspected, misunderstood, or intended what.
- Do not assign private thoughts or emotions to a character unless the scene text supports them.

## Continuity Impact
- Record what should matter in future scenes: decisions, injuries, promises, secrets, changed relationships, new knowledge, unresolved threads, practical consequences, emotional shifts, or altered trust.
- Separate shared knowledge from member-specific knowledge.

## Exclusions
- Ignore and exclude all [OOC] or meta discussion.
- Do not include unsupported assumptions.
- Do not collapse multiple characters into vague phrases like "they felt" unless every target member clearly felt it.

For the keywords field:
- Generate 15-30 standalone topical keywords for retrieval.
- Keywords must be concrete and scene-specific: locations, objects, proper nouns, unique actions, repeated motifs, plans, injuries, named events, or distinctive phrases.
- Do not use abstract themes.
- Do not use these major character names as keywords: {{ anchors.memory.speakers }}. NPC names may be used if the NPC played a major role.
- Prefer keywords that would fire if the user later mentions the noun/action alone.

Return ONLY the JSON, no additional text.
"""

consolidation = ~S"""
{%- case anchors.memory.target_tier.number -%}{%- when 2 -%}{%- assign child_tier = "Arc" -%}{%- when 3 -%}{%- assign child_tier = "Chapter" -%}{%- when 4 -%}{%- assign child_tier = "Book" -%}{%- when 5 -%}{%- assign child_tier = "Legend" -%}{%- when 6 -%}{%- assign child_tier = "Series" -%}{%- else -%}{%- assign child_tier = "Memory" -%}{%- endcase -%}
You are an expert narrative analyst and memory-engine assistant.
Your task is to combine multiple {{ child_tier }} entries into one or more coherent {{ anchors.memory.target_tier.name }} summaries.

You will receive:
- An optional PREVIOUS {{ anchors.memory.target_tier.name }} block, which is canon and must not be rewritten.
- A block of {{ child_tier }} entries in chronological order.

Return JSON only:
{
  "summaries": [
    {
      "title": "Short descriptive {{ anchors.memory.target_tier.name }} title (3-6 words)",
      "summary": "Structured {{ anchors.memory.target_tier.name }} summary as a single string.",
      "keywords": ["keyword1", "keyword2"],
      "member_ids": ["<ID>", "..."]
    }
  ],
  "unassigned_items": [
    { "id": "item-id", "reason": "Why this item does not fit the produced summaries." }
  ]
}

Rules:
- Respect chronology.
- Produce the smallest coherent number of {{ anchors.memory.target_tier.name }} summaries based on the content.
- If an item does not fit, place it in unassigned_items with a short reason.
- Do not repeat the PREVIOUS {{ anchors.memory.target_tier.name }} text verbatim.

Each summary must:
- Very clearly trace cause-effect in order to make the plot and continuity understandable.
- Be token-efficient and plot-accurate.
- Preserve important changes, decisions, conflicts, consequences, and continuity.
- Ignore OOC and flavor-only detail unless it affects future continuity.
- Use the structure below inside the summary string:

# [{{ anchors.memory.target_tier.name }} Title]
Time period: ...

{{ anchors.memory.target_tier.name }} Premise: One sentence describing what this {{ anchors.memory.target_tier.name }} is about.

## Major Beats
- 3-7 bullets focused on plot-changing events

## Character Dynamics
- 1-2 short paragraphs on relationship, emotional, or motive changes

## Key Exchanges
- Up to 8 short exact quotes only if materially important

## Outcome & Continuity
- 4-8 bullets covering decisions, promises, unresolved threads, permanent consequences, and foreshadowed next steps

The `summary` field must use this structure:

# [Scene Title]

**Timeline**: [Most specific date and time supported by the source entries; if unspecified, state unspecified or use relative time.]

## Story Beats

* Present the major actions, revelations, decisions, and emotional or magical shifts in chronological order.
* Explain what triggered each development, why characters acted, how others reacted, and what resulted.
* Include plot-affecting interactions, meaningful shared experiences, and events that changed relationships or future continuity.
* Omit repeated gestures, room dressing, background objects, and logistical detail unless they directly affected events.

## Character Dynamics

* Explain how motives, emotions, relationships, and power dynamics changed during the summarized period.
* Capture consequential subtext, tension, vulnerability, trust, conflict, avoidance, affection, resentment, or loyalty.
* Include small or domestic experiences only when they meaningfully shaped relationship history.
* Do not repeat plot events unless needed to explain the interpersonal change they caused.

## Important Facts

* Record newly established facts likely to matter later, including plans, risks, abilities, limitations, preferences, promises, secrets, debts, injuries, magical effects, discoveries, and obligations.
* Exclude casual preferences, scenery, errands, paperwork, clothing, furniture, weather, and other incidental details unless they became continuity-relevant.

## Key Exchanges

* Include only dialogue that defined a revelation, decision, conflict, emotional shift, or relationship change.
* Attribute each quotation by speaker name.
* Include a direct quotation only when the source entries preserve its exact wording. Never reconstruct quoted dialogue from a paraphrase.
* Preserve distinctive phrases or identifiers, such as “pack for forever” or “dick-measuring contest,” only when they are memorable or relationship-relevant.
* Include no more than 8 quotations.

## Outcome & Continuity

* State the final narrative, emotional, relational, physical, or magical condition produced by the events.
* Record resulting decisions, plans, risks, promises, secrets, injuries, knowledge, and obligations that affect what happens next.
* Identify unresolved threads, pending conflicts, future consequences, and foreshadowed developments.
* Do not recap the full sequence of events again.

For the `keywords` field:

Generate **12–20 natural retrieval keywords when the material supports them**. Use fewer rather than padding the list with weak terms. Keywords are search hooks, not miniature summaries or evidence notes.

Prioritize:

1. **Stable named entities**: people other than {{ anchors.memory.speakers }} or {{ anchors.player.name }}, places, organizations, events, documents, factions, spells, or distinctive objects.
2. **Major continuity anchors**: plans, threats, secrets, discoveries, investigations, conflicts, injuries, promises, relationship changes, and unresolved threads.
3. **Memorable moments**: meaningful shared activities, gifts, food, rituals, jokes, care-taking, arguments, or domestic events.
4. **Independent secondary hooks** that retrieve a separate part of the summarized material.

### Keyword construction

Use the shortest distinctive wording likely to remain recognizable under paraphrasing or reversed word order.

Examples:

* `Gala of the Silver Rose` or `Silver Rose Gala` → `Silver Rose`
* `Bromet Response SA` → `Bromet`
* `Château D’Aramitz`, Comte D’Aramitz, or a plan involving him → `D’Aramitz`
* Keep `Althof Ledger` when both words are required to identify the object.

Prefer one central named entity when it already covers several related events:

* `D’Aramitz rescue plan` → `D’Aramitz`
* `Bromet hidden contractors` → `Bromet`
* `Althof Ledger substitution` → `Althof Ledger`

Retain a modified phrase only when it provides an independent retrieval route not covered by the central entity:

* `fake caterers`
* `ledger facsimile`
* `safehouse breakfast`
* `counter-surveillance camera`

When several clues establish one conclusion, usually tag the resulting finding rather than each supporting clue:

* Uniforms, badges, and vehicle access → `fake caterers`
* Payments and company records → `Bromet`
* A covert tactical team at the gala → `suspected assassination`
* A rental used for equipment and disguises → `staging villa`

A supporting clue may remain only when it is memorable, likely to recur, or independently useful for retrieval.

Keywords should normally:

* Contain 1–4 words.
* Use ordinary noun phrases.
* Identify genuinely distinct parts of the summary.
* Remain stable if later descriptions use different wording.

Exclude:

* Incidental scenery or props.
* Exact times, quantities, card digits, invoice wording, or administrative details.
* Generic themes such as `danger`, `romance`, or `conversation`.
* Unsupported conclusions.
* Sentence-like evidence descriptions.
* Multiple keywords that merely restate or narrow the same named entity.

Before returning the JSON, silently verify that each keyword is natural to search, continuity-relevant, stable under paraphrasing, independently useful, and no longer than necessary.

Based on this {{ anchors.memory.target_tier.name }} summary, generate 15–30 standalone topical keywords that function as retrieval tags, not micro-summaries.
Keywords must be:
- Concrete and scene-specific (locations, objects, proper nouns, unique actions, repeated motifs).
- One concept per keyword — do NOT combine multiple ideas into one keyword.
- Useful for retrieval if the user later mentions that noun or action alone, not only in a specific context.
- Not {{ anchors.memory.speakers }}'s or {{ anchors.player.name }}'s names.
- Not thematic, emotional, or abstract. Stop-list: intimacy, vulnerability, trust, dominance, submission, power dynamics, boundaries, jealousy, aftercare, longing, consent, emotional connection.

Avoid:
- Overly specific compound keywords (“David Tokyo marriage”).
- Narrative or plot-summary style keywords (“art dealer date fail”).
- Keywords that contain multiple facts or descriptors.
- Keywords that only make sense when the whole scene is remembered.

Prefer:
- Proper nouns (e.g., "Chinatown", "Ritz-Carlton bar").
- Specific physical objects ("CPAP machine", "chocolate chip cookies").
- Distinctive actions ("cookie baking", "piano apology").
- Unique phrases or identifiers from the scene used by characters ("pack for forever", "dick-measuring contest").

Your goal: keywords should fire when the noun/action is mentioned alone, not only when paired with a specific person or backstory.
"""

compaction = ~S"""
Please aggressively make this lorebook entry more token-efficient while retaining as much useful information as possible.

Rules:
- Preserve all important facts, preferences, relationships, names, unresolved plot points, promises, secrets, constraints, and character-specific details.
- Remove redundancy, filler, repeated phrasing, and low-value wording.
- Merge overlapping bullets where possible.
- Keep the entry readable as a lorebook entry.
- Do not add new facts.
- Do not invent explanations.
- Do not change names, pronouns, macros, or proper nouns.
- Preserve wrapper headings and end markers exactly if present.
- Return only the revised entry content.

Entry type:
{{ anchors.memory.entry.kind }}

Entry title:
{{ anchors.memory.entry.title }}

Entry content:
{{ anchors.memory.entry.content }}
"""

topical_clip = ~S"""
SYSTEM: You are a memory compiler. You are writing a focused memory entry (lorebook/Clip) about a SINGLE topic.

Mode: {% if anchors.memory.entry %}update{% else %}create{% endif %}
Topic: {{ anchors.memory.topic }}
Keywords: {{ anchors.memory.keywords }}

Existing Clip content (if updating):
{{ anchors.memory.entry.content }}

Source memories:
{{ anchors.memory.sources_text }}

Source chat messages:
{{ anchors.memory.scene }}

---

TASK:
Produce a finished memory entry containing ONLY information directly relevant to {{ anchors.memory.topic }}.
Organize the output by sub-topic or attribute — NOT by chronology or narrative order.
Each piece of information should stand on its own as a discrete, retrievable fact.

OUTPUT FORMAT:
Write in tight, factual prose, bullet points, or labeled attribute blocks (your choice, whichever is denser).

CONTENT RULES:
- Gather all facts concerning this topic.
Include: concrete facts, names, relationships, preferences, places, constraints, promises, secrets, unresolved issues, and meaningful changes over time from either source section.
- Exclude: events, context, or details unrelated to {{ anchors.memory.topic }} even if they appear in the source memories.
- Resolve later information against earlier information. Distinguish current state, completed events, decisions, unresolved issues, and future plans.
- Conflicts: if source memories contradict each other, first review if it is a correction or a true contradiction. Corrections can be made directly. If contradictory information is found, note the conflict explicitly (e.g. "Claimed X in one account, Y in another") rather than silently picking one.
- Preserve objective details where available.
- Token-efficiency is important: prefer concise phrasing, avoid filler, and remove redundancy. Be as concise and informationally dense as possible.

IF UPDATING AN EXISTING CLIP:
- Preserve useful existing content unless source memories clearly correct or supersede it.
- Merge in new relevant details; remove redundancy.
- Do not regress — the result should be strictly more useful than the existing Clip.

Return only the finished entry content. No JSON, no title field, no keyword field, no wrapper markers.

CRITICAL:
- Do not greet the user.
- Do not ask clarifying questions.
- Do not offer alternative directions or options.
- Do not explain what you are about to do.
- Begin your response with the first word of the memory entry itself.
- If the source memories contain insufficient information to write an entry, return only: [INSUFFICIENT DATA: <one sentence reason>]
- Any response that is not the finished entry or the insufficient-data marker is a failure.
"""

plot_tracker = ~S"""
Analyze the accompanying scene for plot threads, story arcs, and other narrative movements. The previous scenes are there to provide context. Generate a story thread report. If a report already exists in context, update it instead of recreating.
"""

plot_tracker_format = ~S"""
=== Plot Points ===
(as of [point in the story when this analysis was done])

[Overarching Plot Arc]
(2-3 sentence summary of the superobjective or major plot)

[Thread #1 Title]
- Summary: (1 sentence)
- Status: (active / on hold)
- At Stake: (how resolution will affect the ongoing story)
- Last Known: (location or time)
- Key Characters: ...


[Thread #2 Title]
- Summary: (1 sentence)
- Status: (active / on hold)
- At Stake: (how resolution will affect the ongoing story)
- Last Known: (location or time)
- Key Characters: ...

...

-- Plot Hooks --
- (new or potential plot hooks)

-- Character Dynamics --
- current status of {{ anchors.player.name }}'s/{{ anchors.memory.speakers }}'s relationships with NPCs

===End Plot Points===
"""

# The material STMB appends to the prompt programmatically, as Liquid over `anchors.memory`. Section
# headings are STMB's own, marking what is reference only and what is the target.
memory_material = ~S"""
{% if anchors.memory.context != blank %}=== ADDITIONAL CONTEXT FOR REFERENCE ===
{{ anchors.memory.context }}

=== END ADDITIONAL CONTEXT FOR REFERENCE ===

{% endif %}{% if anchors.memory.previous_text != blank %}=== PREVIOUS SCENE CONTEXT (DO NOT PROCESS) ===
These are previous memories for context only. Do NOT include them in your new memory:

{{ anchors.memory.previous_text }}

=== END PREVIOUS SCENE CONTEXT - PROCESS ONLY THE SCENE BELOW ===

{% endif %}=== SCENE TRANSCRIPT ===
{{ anchors.memory.scene }}

=== END SCENE ===
"""

consolidation_material = ~S"""
Target tier: {{ anchors.memory.target_tier.name }}

{% if anchors.memory.previous_summary %}=== PREVIOUS {{ anchors.memory.target_tier.name | upcase }} (CANON — DO NOT REWRITE, DO NOT INCLUDE IN YOUR NEW SUMMARY) ===
{{ anchors.memory.previous_summary.title }}
{{ anchors.memory.previous_summary.content }}
=== END PREVIOUS {{ anchors.memory.target_tier.name | upcase }} ===

{% endif %}=== SOURCE ENTRIES ===
{{ anchors.memory.sources_text }}

=== END SOURCE ENTRIES ===
"""

plot_tracker_material = ~S"""
{% if anchors.memory.entry.content != blank %}=== PRIOR ENTRY ===
{{ anchors.memory.entry.content }}

{% endif %}{% if anchors.memory.previous_text != blank %}=== PREVIOUS SCENE CONTEXT (DO NOT PROCESS) ===
These are previous memories for context only. Do NOT include them in your new output.

{{ anchors.memory.previous_text }}

=== END PREVIOUS SCENE CONTEXT ===

{% endif %}{% if anchors.memory.context != blank %}=== ADDITIONAL CONTEXT FOR REFERENCE ===
{{ anchors.memory.context }}

=== END ADDITIONAL CONTEXT FOR REFERENCE ===

{% endif %}=== SCENE TEXT ===
{{ anchors.memory.scene }}

=== RESPONSE FORMAT ===
"""

memory_character = ~S"""
Analyze the following scene and create a memory entry written with {{ anchors.memory.character }} as the focus.

You must respond with ONLY valid JSON in this exact format:
{
  "title": "Short, descriptive scene title (3-6 words)",
  "content": "Structured memory summary...",
  "keywords": ["keyword1", "keyword2", "keyword3"]
}

Important: This is NOT a general scene summary. This is a targeted memory entry.
- Write the memory as continuity relevant to {{ anchors.memory.character }}.
- Include what {{ anchors.memory.character }} did, said, thought, felt, noticed, learned, decided, promised, concealed, misunderstood, or was affected by.
- Include other characters depending on how their actions, words, emotions, or decisions matter to {{ anchors.memory.character }}'s future continuity.
- Do not include information {{ anchors.memory.character }} could not know unless it directly affects future continuity and is clearly marked as external scene knowledge.
- Attribute all actions, thoughts, emotions, and knowledge clearly. Do not blur characters together.

For the content field, use this markdown structure:

# [Scene Title]
**Timeline**: (date/day/time, if known)

## Target-Relevant Events
- Summarize the events that matter to {{ anchors.memory.character }} in chronological order.
- Use cause -> intention -> reaction -> consequence logic.
- Exclude flavor-only details unless they reveal a lasting character or relationship change.

## Attribution
- Clearly state who did what.
- Clearly state who knew what.
- Clearly state who felt, believed, suspected, misunderstood, or intended what.
- Do not assign private thoughts or emotions to a character unless the scene text supports them.

## Continuity Impact
- Record what should matter in future scenes: decisions, injuries, promises, secrets, changed relationships, new knowledge, unresolved threads, practical consequences, emotional shifts, or altered trust.
- Separate shared knowledge from member-specific knowledge.

## Exclusions
- Ignore and exclude all [OOC] or meta discussion.
- Do not summarize the whole scene if it is not relevant to {{ anchors.memory.character }}.
- Do not include unsupported assumptions.

For the keywords field, generate 15-30 specific, descriptive, highly relevant keywords for database retrieval - focus on the most important topical terms. Keywords must be concrete and scene-specific (locations, objects, proper nouns, unique actions). No compound keywords unless they are proper nouns. Do not use abstract themes (e.g., "sadness", "love") or character names.

Return ONLY the JSON, no additional text.
"""

clip_review = ~S"""
SYSTEM: You review existing Memory Book Clips against one newly processed chat scene.

For each supplied Clip, gather all facts concerning this topic. Resolve later information against earlier information. Distinguish current state, completed events, decisions, unresolved issues, and future plans. Preserve exact details where available.

Rules:
- Use only facts directly supported by the supplied scene.
- For an ordinary Clip, suggest one exact excerpt from a single source message; never rewrite or remove its existing content.
- For a Topical Clip, return a complete revised body that preserves useful existing information, merges relevant new facts, removes redundancy, and notes genuine conflicts.
- Refer to entries only by their supplied UID.
- Repetition, paraphrase, or merely related discussion does not require an update.
- Omit entries that do not need an update.
- Do not greet, explain the task, or return Markdown fences.
"""

clip_review_material = ~S"""
=== NEW SCENE ===
{{ anchors.memory.scene }}

=== EXISTING CLIPS ===
{{ anchors.memory.clips_text }}

=== REQUIRED JSON RESPONSE ===
Return one JSON object that maps each Clip UID needing an update to one suggestion string.
For an ordinary Clip, the string must be one exact excerpt copied from a single message in NEW SCENE.
For a Topical Clip, the string must be the complete revised Clip body.
Omit Clips that do not need an update. If no Clips need an update, return {}.
Return only JSON. Do not return an array, Markdown fence, reason, message ID, or explanation.
"""

clip_suggestions = ~S"""
SYSTEM: Review the supplied chat scene and suggest new Topical Clips based on the scene.

1. Review the scene and identify concrete topics at discussion. Concisely classify 0-5 topics identified in the scene.
2. Compare the identified topics against the supplied existing Topical Clips list. ONLY suggest new Topical Clips if a topic is not already covered by an existing Topical Clip.
3. Limit your suggestions to topics that are directly supported and substantially discussed. Do not suggest topics that are only tangentially related or not mentioned in the scene.

Rules:
- Use only facts directly supported by the supplied scene.
- Prefer objective details over subjective impressions.
- Repetition, paraphrase, or merely related discussion does not require an update.
- Omit entries that do not need an update.
- Do not greet, explain the task, or return Markdown fences.
"""

clip_suggestions_material = ~S"""
=== NEW SCENE ===
{{ anchors.memory.scene }}

=== EXISTING TOPICAL CLIPS ===
{{ anchors.memory.clips_text }}

=== REQUIRED JSON RESPONSE ===
Return one JSON object with a "topics" array containing zero to five new Topical Clip suggestions.
Each item must contain "topic" as a non-empty string and "keywords" as an array of activation-keyword strings.
If no new topics are needed, return {"topics":[]}.
Return only JSON. Do not return Markdown fences, reasons, message IDs, or explanations.
"""

combine_clips = ~S"""
Here are multiple information snippets covering related topics.

Analyze and consolidate them into a single coherent informational entry.

- Preserve all unique, relevant information.
- Remove redundancies and repeated details.
- Rephrase for clarity, accuracy, and consistency.
- Combine overlapping information rather than repeating it.
- If snippets conflict, prefer information explicitly established as a correction or update. Otherwise, preserve the conflicting claims concisely; do not invent a resolution.
- Do not add facts that are not supported by the source snippets.
- Condense wording aggressively for token efficiency while preserving unique facts, qualifications, and meaningful distinctions.

New entry title: {{ anchors.memory.topic }}

{% for clip in anchors.memory.sources %}=== SNIPPET {{ forloop.index }}: {{ clip.title }} ===
{{ clip.content }}
=== END SNIPPET {{ forloop.index }} ===

{% endfor %}

Return only the consolidated entry body, without a title or wrapper markers.
"""

upsert_block = fn name, role, content, description ->
  attrs = %{name: name, role: role, kind: :template, content: String.trim(content), description: description}

  {:ok, block} =
    case Repo.get_by(Block, name: name) do
      nil -> Prompts.create_block(seed_scope, attrs, site: true)
      block -> Prompts.update_block(seed_scope, block, attrs)
    end

  block
end

# Upserts the prompt and replaces its block list, so the result is the same however often it runs.
upsert_prompt = fn name, purpose, blocks ->
  attrs = %{name: name, purpose: purpose, description: attribution}

  {:ok, prompt} =
    case Repo.get_by(Prompt, name: name) do
      nil -> Prompts.create_prompt(seed_scope, attrs, site: true)
      prompt -> Prompts.update_prompt(seed_scope, prompt, attrs)
    end

  Repo.delete_all(from(pb in PromptBlock, where: pb.prompt_id == ^prompt.id))
  Enum.each(blocks, fn block -> {:ok, _} = Prompts.add_block(seed_scope, prompt, block) end)
  prompt
end

described = fn what -> "#{what} #{attribution}" end

memory_material_block =
  upsert_block.(
    "Memory: Scene material",
    :user,
    memory_material,
    described.("The Additional Context, previous memories (reference only) and the scene to summarize.")
  )

memory_prompts =
  for {name, text, source} <- [
        {"Memory: Summary", memory_summary, "summary"},
        {"Memory: Minimal", memory_minimal, "minimal"},
        {"Memory: Comprehensive", memory_comprehensive, "comprehensive"},
        {"Memory: Group", memory_group, "group"},
        {"Memory: Character", memory_character, "char"}
      ] do
    block = upsert_block.(name, :system, text, described.("STMB's `#{source}` memory prompt."))
    upsert_prompt.(name, :memory, [block, memory_material_block])
  end

consolidation_prompt =
  upsert_prompt.("Consolidation", :consolidation, [
    upsert_block.(
      "Consolidation",
      :system,
      consolidation,
      described.("STMB's `arc_default` consolidation analysis prompt with its consolidation keyword rules.")
    ),
    upsert_block.(
      "Consolidation: Sources",
      :user,
      consolidation_material,
      described.("The target tier, the previous summary (canon, not source) and the entries to consolidate.")
    )
  ])

# Both templates already embed every macro, so each prompt is its one block.
compaction_prompt =
  upsert_prompt.("Compaction", :compaction, [
    upsert_block.("Compaction", :system, compaction, described.("STMB's compaction prompt."))
  ])

topical_clip_prompt =
  upsert_prompt.("Topical clip", :topical_clip, [
    upsert_block.("Topical clip", :system, topical_clip, described.("STMB's topical clip prompt."))
  ])

clip_review_prompt =
  upsert_prompt.("Memory assistance", :clip_review, [
    upsert_block.("Memory assistance", :system, clip_review, described.("STMB's clip review prompt.")),
    upsert_block.(
      "Memory assistance material",
      :user,
      clip_review_material,
      described.("The new scene, the clips under review and STMB's clip review response contract.")
    )
  ])

clip_suggestions_prompt =
  upsert_prompt.("Memory assistance: topics", :clip_suggestions, [
    upsert_block.("Memory assistance: topics", :system, clip_suggestions, described.("STMB's clip suggestions prompt.")),
    upsert_block.(
      "Memory assistance: topics material",
      :user,
      clip_suggestions_material,
      described.("The new scene, the existing topical clips and STMB's topic suggestions response contract.")
    )
  ])

combine_clips_prompt =
  upsert_prompt.("Combine clips", :combine_clips, [
    upsert_block.("Combine clips", :system, combine_clips, described.("STMB's combine clips prompt."))
  ])

plot_tracker_prompt =
  upsert_prompt.("Side: Plot tracker", :side_prompt, [
    upsert_block.("Side: Plot tracker", :system, plot_tracker, described.("STMB's Plotpoints side prompt.")),
    upsert_block.(
      "Side: Plot tracker material",
      :user,
      plot_tracker_material <> plot_tracker_format,
      described.(
        "The prior tracker, previous memories and context (reference only), the scene, and STMB's Plotpoints response format."
      )
    )
  ])

profile_attrs = %{
  name: "Default",
  memory_prompt_id: hd(memory_prompts).id,
  group_memory_prompt_id: Enum.find(memory_prompts, &(&1.name == "Memory: Group")).id,
  consolidation_prompt_id: consolidation_prompt.id,
  compaction_prompt_id: compaction_prompt.id,
  topical_clip_prompt_id: topical_clip_prompt.id,
  clip_review_prompt_id: clip_review_prompt.id,
  clip_suggestions_prompt_id: clip_suggestions_prompt.id,
  combine_clips_prompt_id: combine_clips_prompt.id
}

{:ok, profile} =
  case Repo.get_by(Profile, name: "Default") do
    nil -> Memory.create_profile(seed_scope, profile_attrs, site: true)
    profile -> Memory.update_profile(seed_scope, profile, profile_attrs)
  end

# A default chosen since the last run is kept.
if Memory.default_profile(seed_scope) == nil, do: {:ok, _} = Memory.set_default_profile(seed_scope, profile)

{:ok, _} =
  case Repo.get_by(SidePrompt, name: "Plot tracker") do
    nil ->
      Memory.create_side_prompt(
        seed_scope,
        %{name: "Plot tracker", prompt_id: plot_tracker_prompt.id, enabled: false},
        site: true
      )

    side_prompt -> Memory.update_side_prompt(seed_scope, side_prompt, %{prompt_id: plot_tracker_prompt.id})
  end

Memory.preferences(seed_scope)

IO.puts("Seeded 12 memory prompts, the Default memory profile, the Plot tracker side prompt and memory preferences")
