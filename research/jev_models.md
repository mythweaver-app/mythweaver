# Jev (System One) models: where they could fit

Research note, 2026-10-21. Nothing here is built. It answers the README to-do "uses for JEV models?".

## What Jev is

Jev is TypeSafe AI's proprietary "System One" model. It has been in limited early access since
2026-09-15. It is discriminative: it never generates text. A request is a **state** (a string, a JSON
object, or an array of strings) plus typed **questions**. The response is one discrete probability
distribution per question. There are three question types, all multiple-choice:

- **choice**: pick one of N candidates.
- **noul**: judge whether a proposition is true (two candidates, false and true).
- **score**: rate on an ordered scale.

The API also returns `choice`, `score` and `confidence`, computed from each distribution by fixed
formulas. For choice and noul, confidence is $(p_{\max} - 1/n)/(1 - 1/n)$. For score, the score is the
expected level index and confidence comes from mean absolute deviation.

Limits that shape any integration:

- Input is capped at 64k tokens, of which state plus the longest question may use 32k.
- All questions in a request are answered in parallel. If one question depends on another's answer,
  that takes two sequential requests.
- Questions take their categories at inference time (zero-shot), so no per-task training is needed.

Open versions exist: Kotoba Labs' Open-Jev, Laya (mmBERT encoder), Zefan Cai's Open-Jev (Qwen
backbone), Kev, Nimble and Chinese-Jev. Chinese-Jev (about 322M parameters) reports roughly 15 ms per
decision against the hosted API.

Sources:
- [Jev (AI model), Wikipedia](https://en.wikipedia.org/wiki/Jev_(AI_model))
- [Chinese-Jev: Bringing System One Model to Chinese-Language Tasks, arXiv 2609.36965](https://arxiv.org/html/2609.36965)
- [Evaluating and Benchmarking the System One Model Jev, arXiv 2609.37647](https://arxiv.org/pdf/2609.37647)
  (zero-shot jev-1.13.0 on 37 datasets, compared with Qwen3.8-27B and Gemma-4-E4B)

## Where it fits

Jev suits places where Mythweaver now decides something with a heuristic, or would otherwise need a
full chat-model call to get back one word.

| Use case | Question type | Replaces / plugs into |
|---|---|---|
| Who speaks next | choice over participants | `Generation.TurnPolicy` `:natural`, which today takes characters named in the last message, then a talkativeness roll (`lib/mythweaver/generation/turn_policy.ex:13`, `:77-86`). Use the distribution as weights. When `confidence` is low, fall back to the current roll. |
| Stop auto mode / hand the turn to the player | noul: "the last reply asks the player something or waits for them to act" | `Generation.Conductor` auto mode, which today is capped only by `max_turns`. |
| Character expressions (README to-do) | choice over expression labels | SillyTavern uses a trained classifier for this. Jev handles the same job zero-shot with whatever labels each character defines, but it is not clearly more accurate. See [Expressions: Jev or a classifier](#expressions-jev-or-a-classifier). |
| Memory auto-trigger at scene breaks | noul: "the scene ended here", or score | `memory.auto_trigger` is only `:messages \| :tokens` (`Memory.auto_settings/2`, `lib/mythweaver/memory.ex:145-150`). A `:scene` trigger would cut memories at story boundaries instead of every N messages. |
| Lore relevance | one noul per entry: "this entry matters to the current scene" | A new `activation` value next to `:keyword \| :constant \| :vector` (`lib/mythweaver/lore/lore_entry.ex:43`). Many entries fit in one request, because questions run in parallel. |
| Reply quality gate | noul: "speaks or acts for the player"; score: in character, repetition | Flag a swipe or regenerate it automatically. Sits next to the existing repetition guard. |
| State tracking into `Variables` | choice (location, time of day), score (affinity) | A decision pass after a reply updates typed variables, which is more reliable than asking the chat model to emit `{% setvar %}`. Only `Generation.Server` commits writes today (`Variables.apply_writes/2`), so the pass belongs there. |
| Tag suggestions (README Tags to-do) | noul per candidate tag | Suggest namespaced tags (`color:purple`) for characters, memories and chats. |

## Expressions: Jev or a classifier

Jev probably does not beat a trained classifier on a fixed label set. What it offers instead is
per-character labels, scene context and calibrated confidence. Whether that matters more than
accuracy in role-play has not been measured.

### What SillyTavern runs

- **Local (default):** `Cohee/distilbert-base-uncased-go-emotions-onnx`, a DistilBERT trained on
  GoEmotions with 28 fixed labels. It runs in-process (about 100 MB), reads only the latest message
  (trimmed to 2000 characters) and takes the top label. A 6-label option,
  `Cohee/bert-base-uncased-emotion-onnx`, is set in `config.yaml`.
- **Custom expressions** are not supported by Local. SillyTavern's docs say to switch the source to
  Main API or WebLLM, which costs a full LLM call per message.

Sources: [SillyTavern: Character Expressions](https://docs.sillytavern.app/extensions/expression-images/),
[TavernSprite classifier playground](https://tavernsprite.com/tools/sillytavern-expression-classifier/).

### Benchmark evidence

From arXiv 2609.37647, all zero-shot:

| Dataset | Jev | Qwen3.8-27B | Classifier trained on that dataset |
|---|---|---|---|
| Emotion (6 labels, accuracy) | 0.585 | 0.571 | about 0.93, `bert-base-uncased-emotion` (SillyTavern's 6-label option) |
| GoEmotions (28 labels, macro-F1) | 0.243 | 0.255 | about 0.46, fine-tuned BERT in the GoEmotions paper |

The classifier figures are recalled, not re-checked. Confirm them on the model card and in the
GoEmotions paper before relying on them.

The paper names emotion as one of Jev's weak spots: the labels are noisy (Emotion's come from
hashtags), and a trained model learns a dataset's quirks where a zero-shot model cannot. Two caveats
limit how far these numbers transfer:

- **GoEmotions was posed differently.** The paper asked 28 independent nouls per text, thresholded at
  0.5. SillyTavern takes the single top label, which for Jev is one choice question. The paper also
  finds that Jev's noul probabilities rank well but sit badly against a fixed 0.5 threshold.
- **The domain is different.** GoEmotions is Reddit comments and Emotion is tweets. Role-play prose
  is long, often third person, and mixes narration with dialogue. Neither score says how either model
  does on that.

### Where Jev should beat the local classifier

| Classifier limitation | Jev |
|---|---|
| A fixed set of 28 labels, no custom expressions | Labels are supplied per request, with descriptions, so each character's own sprite set is the option list. |
| Reads one message with no context, so sarcasm and dry humour land on the wrong label | The state can include the character card, the previous message and the reply (32k token budget). |
| A group-chat or narrated message mixes several characters' feelings | The question can name the character: "what does `speaker` feel at the end of `reply`". |
| Falls back to neutral when no label scores high | The paper finds choice confidence well calibrated, so low confidence can keep the current sprite instead. |
| Custom labels need an LLM call | Priced at $0.042 per million input tokens; a 2k-token state costs about $0.0001. |

### Where the classifier wins

- It is local, free, private and works offline. The hosted Jev sends role-play text to a third-party
  early-access API. A self-hosted open version (Laya, Open-Jev) would remove that, but their emotion
  quality is unchecked.
- It never fails because a provider is down.

### Settling it

Run an offline comparison on Mythweaver's own chats before building the feature:

1. Take about 200 character messages and hand-label each against a realistic sprite set.
2. Score the SillyTavern DistilBERT, Jev (one choice question per message, with context) and a main
   chat model against those labels.
3. Report top-1 accuracy, plus accuracy on the most confident 80% of messages. The second figure
   tests whether holding the current sprite at low confidence helps.

Running DistilBERT from Elixir needs an ONNX runtime such as Ortex or Bumblebee, neither of which is
in deps. Running it from a script outside the app avoids adding one.

## Design constraints

- **Model shape.** A decision model would be another `AI.Model` `completion_mode`, modelled on
  `:embedding`: it can't be switched to or from, and it is refused as a chat, participant or profile
  model. Calls record `generation_stats` rows under their own tag and count toward
  `quota.spend_per_day`.
- **Latency on lore.** Vector lore deliberately never calls the API while a reply is built
  (`Lore.Embeddings` syncs in the background). Lore decisions should follow suit: run after each
  message, store the result, and have `Activation` read stored rows. Turn choice and expressions run
  between replies, so they can call the model inline. That split is a judgement, not a measurement.
- **Follow-up questions.** A question that needs another's answer, such as "is this a scene break"
  and then "which memory profile", takes two sequential requests.
- **Provider risk.** The hosted Jev is proprietary and in early access. A self-hosted open version
  behind its own adapter would keep the feature optional. None of the open versions' API formats have
  been checked.

## Suggested order

1. Character expressions or `:natural` turn choice. Both are bounded choice questions with an obvious
   fallback, and neither touches `Prompts.Builder`. For expressions, run the comparison above first.
2. The scene-break memory trigger and the auto-mode stop check, which reuse the same adapter.
3. Lore relevance, which is the most valuable but needs background sync and stored results, like
   vector lore.
