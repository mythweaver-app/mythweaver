defmodule Mythweaver.Prompts.Standard do
  @moduledoc """
  The Liquid of Mythweaver's own functional prompt blocks (lore slots, character cards, guide,
  refine, author's note, …). The seeds and the SillyTavern preset importer share these, so both
  build the same blocks.
  """

  @doc "SillyTavern's World Info (before)."
  @spec lore_before() :: String.t()
  def lore_before do
    ~S"""
    {{ anchors.lore.before_character }}
    """
  end

  @doc "The responding character's card."
  @spec character() :: String.t()
  def character do
    ~S"""
    {% if anchors.character %}
    Character name: {{ anchors.character.name }}
    {% if anchors.character.pronouns %}Character pronouns: {{ anchors.character.pronouns }}
    {% endif %}{% if anchors.character.description %}Character description: {{ anchors.character.description }}
    {% endif %}{% if anchors.character.appearance %}Character appearance: {{ anchors.character.appearance }}{% endif %}
    {% endif %}
    """
  end

  @doc """
  Every card the reply sees (`anchors.cards`), one after another in participant order, each as the
  character card's lines and a blank line after it (a block's text is trimmed, so the last one's
  goes). The same text whoever replies under Join, so it caches.
  """
  @spec cards() :: String.t()
  def cards do
    ~S"""
    {% for card in anchors.cards %}Character name: {{ card.name }}
    {% if card.pronouns %}Character pronouns: {{ card.pronouns }}
    {% endif %}{% if card.description %}Character description: {{ card.description }}
    {% endif %}{% if card.appearance %}Character appearance: {{ card.appearance }}
    {% endif %}
    {% endfor %}
    """
  end

  @doc "The player character's card; skipped when the AI speaks for the player."
  @spec player() :: String.t()
  def player do
    ~S"""
    {% if anchors.player and anchors.character.player != true %}
    Player name: {{ anchors.player.name }}
    {% if anchors.player.pronouns %}Player pronouns: {{ anchors.player.pronouns }}
    {% endif %}{% if anchors.player.description %}Player description: {{ anchors.player.description }}
    {% endif %}{% if anchors.player.appearance %}Player appearance: {{ anchors.player.appearance }}{% endif %}
    {% endif %}
    """
  end

  @doc "SillyTavern's World Info (after)."
  @spec lore_after() :: String.t()
  def lore_after do
    ~S"""
    {{ anchors.lore.after_character }}
    """
  end

  @doc "Chat examples from the examples lore slots, introduced by `header`."
  @spec example_dialogue(String.t()) :: String.t()
  def example_dialogue(header) do
    "{% if anchors.lore.before_examples or anchors.lore.after_examples %}\n" <>
      header <>
      "\n{% if anchors.lore.before_examples %}{{ anchors.lore.before_examples }}\n" <>
      "{% endif %}{{ anchors.lore.after_examples }}\n" <>
      "{% endif %}\n"
  end

  @doc "`new_chat` in a two-person chat, `new_group_chat` when more characters share it."
  @spec start_of_chat(String.t(), String.t()) :: String.t()
  def start_of_chat(new_chat, new_group_chat) do
    "{% if anchors.chat.participants.size > 2 %}" <>
      new_group_chat <> "{% else %}" <> new_chat <> "{% endif %}\n"
  end

  @doc "A guided generation's outline. Renders nothing without a guide."
  @spec guide() :: String.t()
  def guide do
    ~S"""
    {% if anchors.guide %}[Guide for {{ anchors.character.name }}'s {% if anchors.guide.continue %}continuation of their last message{% else %}next message{% endif %}, written by the user. It is an outline of what happens, not story text: do not copy it word for word, and do not pick up where its last sentence ends. {% if anchors.guide.continue %}Write the rest of the message{% else %}Write {{ anchors.character.name }}'s whole message from its first line{% endif %} so it covers these beats in order, in {{ anchors.character.name }}'s voice and the chat's established person and tense, adding your own detail, dialogue and description. The message must not start with the outline's first sentence.
    Outline: {{ anchors.guide.text }}]{% endif %}
    """
  end

  @doc "A refine's editing instructions and the message being rewritten."
  @spec refine() :: String.t()
  def refine do
    ~S"""
    {% if anchors.refine %}This turn is an edit, not a new reply. Rewrite {{ anchors.character.name }}'s last message, shown below, applying the user's editing instructions and keeping everything they do not ask to change: the same voice, tense, point of view, formatting and length unless the instructions say otherwise. Ignore any earlier instruction to write the next reply, and do not continue the scene past the point where the message ends.

    Your entire response replaces the message as-is. Start directly with its first word. Do not acknowledge the request, explain or list your changes, label the text, or wrap it in brackets, quotation marks or tags.

    Editing instructions:
    <instructions>
    {{ anchors.refine.instructions }}
    </instructions>

    Message to rewrite:
    <message>
    {{ anchors.refine.text }}
    </message>{% endif %}
    """
  end

  @doc "World Info before/after the author's note."
  @spec author_note() :: String.t()
  def author_note do
    ~S"""
    {% if anchors.lore.before_author_note %}{{ anchors.lore.before_author_note }}
    {% endif %}{{ anchors.lore.after_author_note }}
    """
  end

  @doc "The `post_history` custom outlet."
  @spec post_history() :: String.t()
  def post_history do
    ~S"""
    {{ outlets.post_history }}
    """
  end

  @doc """
  Splits a trailing `post_history` outlet off `content`: `{own, suffix}`, where `suffix` is
  `"\\n" <> outlet` when the content ends with the outlet line (or is only it), else `""`.
  """
  @spec split_post_history(String.t()) :: {String.t(), String.t()}
  def split_post_history(content) do
    outlet = String.trim(post_history())
    trimmed = String.trim_trailing(content)

    cond do
      String.trim(content) == outlet -> {"", "\n" <> outlet}
      String.ends_with?(trimmed, "\n" <> outlet) -> {String.replace_suffix(trimmed, "\n" <> outlet, ""), "\n" <> outlet}
      true -> {content, ""}
    end
  end

  @doc "`text`, left out of a refine."
  @spec group_nudge(String.t()) :: String.t()
  def group_nudge(text) do
    "{% unless anchors.refine %}" <> text <> "{% endunless %}\n"
  end
end
