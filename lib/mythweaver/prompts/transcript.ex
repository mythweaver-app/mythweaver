defmodule Mythweaver.Prompts.Transcript do
  @moduledoc """
  The one place chat history becomes prompt text.

  Extracted rather than inlined because both the `:chat_history` anchor (text rendering) and the
  builder's chat-mode turn expansion need the same AI-visibility and active-body rules; duplicating
  them would let the two paths drift.

  The lore scan window (`Mythweaver.Lore.Activation`'s private `window/3`) reads `entries/3` too, so
  lore matching and prompt building see exactly the same text, image description lines included:
  a described image triggers lore the way its words would.

  An image's text form is its description line, appended to the entry's `content`; that is what
  text prompts, templates, lore and memory summaries read. The `:caption_template` option (the
  `images.caption_template` setting) renders it through `Mythweaver.Attachments.describe_line/3`;
  without one it is the built-in `[Image: a red fox]` or `[Image]`. `turns/3` with
  `attach_images: true` sends the images of the newest messages themselves instead.

  Every other ready attachment (documents, audio, video, other files) adds its
  `Mythweaver.Attachments.file_line/2` after the image lines: a document's extracted text, or an
  `[Audio: name]`-style block holding its description. With `:inline_limits` (per kind, the newest
  messages that have it), a document past its kind's limit reads as its summary instead.
  `turns/3` with `attach_files:`/`attach_audio:`/`attach_video:` sends the PDFs, audio and video
  clips within those limits themselves instead.
  """

  alias Mythweaver.Attachments
  alias Mythweaver.Attachments.Attachment
  alias Mythweaver.Characters.Character
  alias Mythweaver.Messages.Message

  @type entry :: %{
          message_id: Ecto.UUID.t(),
          role: :user | :assistant,
          name: String.t(),
          character_id: Ecto.UUID.t() | nil,
          content: String.t(),
          text: String.t(),
          images: [Attachment.t()],
          files: [Attachment.t()]
        }

  @doc """
  The AI-visible transcript of `messages`, newest last.

  A message is skipped when `visible_to_ai` is false, when it has no active body, or when that body's
  content is blank and it has no ready attachment.

  `content` is the text followed by one description line per image, then one `file_line/2` per
  other attachment; `text` is the text alone; `images` and `files` split the ready attachments.
  `opts[:caption_template]` renders each description line, with `user` the message's author and
  `char` the responder's name (`""` without one). `opts[:inline_limits]` (`within_limits/2`) makes a
  document past its limit read as its summary; without it every document is its full text, as lore,
  memory and `anchors.messages` read it. `opts[:within]`, a precomputed `within_limits/2` set (for
  a wider window than `messages`), replaces the limits' own count; `lines/2`, `turns/3` and
  `reply_media/2` take it too. `character_id` is the authoring character's, nil for a
  string author. `message_id` lets the lore scan window find the bodies it read (vector activation)
  without repeating these skip rules.

  `role` is relative to the responding character: `:assistant` for lines that `responder` authored,
  `:user` for everyone else (the player, other characters, string authors). A `nil` responder makes
  every entry `:user`.
  """
  @spec entries([Message.t()], Character.t() | nil, keyword()) :: [entry()]
  def entries(messages, responder, opts \\ []) do
    template = Keyword.get(opts, :caption_template)
    char = responder_name(responder)

    base =
      for message <- messages,
          message.visible_to_ai,
          text = Message.active_content(message) || "",
          loaded = Message.loaded_attachments(message),
          images = for(a <- loaded, a.kind == :image and a.status == :ready, do: a),
          files = for(a <- loaded, a.kind != :image and a.status == :ready, do: a),
          text != "" or images != [] or files != [] do
        %{
          message_id: message.id,
          role: role(message, responder),
          name: author_name(message),
          character_id: if(message.author_is_character, do: message.author_character_id),
          text: text,
          images: images,
          files: files
        }
      end

    # Without limits every document is its full text.
    mode =
      case {Keyword.fetch(opts, :within), Keyword.fetch(opts, :inline_limits)} do
        {{:ok, within}, _limits} ->
          fn a -> if MapSet.member?(within, a.id), do: :full, else: :summary end

        {:error, {:ok, limits}} ->
          within = within(base, limits)
          fn a -> if MapSet.member?(within, a.id), do: :full, else: :summary end

        {:error, :error} ->
          fn _attachment -> :full end
      end

    Enum.map(base, fn entry ->
      lines = Enum.map(entry.files, &Attachments.file_line(&1, mode.(&1)))
      Map.put(entry, :content, content(entry.text, entry.images, lines, template, %{user: entry.name, char: char}))
    end)
  end

  @doc """
  `entries/3` rendered as `"Name: content"` lines for a text-completion prompt; `opts` as
  `entries/3`'s.

  A message whose author is a bare string (`author_is_character == false`) uses `author_name`; a
  character-authored message uses the character's name; a message with neither uses `"Narrator"`.
  """
  @spec lines([Message.t()], keyword()) :: [String.t()]
  def lines(messages, opts \\ []) do
    messages
    |> entries(nil, opts)
    |> Enum.map(&"#{&1.name}: #{&1.content}")
  end

  @doc """
  `entries/2` as chat turns for `responder`. By default (`speaker_roles: :responder`) its own lines
  are bare `:assistant` content and every other line is `:user` prefixed `"Name: "`, so the model
  never sees another character's voice as its own. With `speaker_roles: :fixed` the roles do not
  depend on the responder: every character but the player (`opts[:player_id]`) speaks as
  `:assistant`, everyone else as `:user`, and every line is prefixed `"Name: "`, so a change of
  speaker leaves earlier turns unchanged for a provider's prompt cache.

  With `attach_images: true` (a model that `Mythweaver.AI.Model.sees_images?/1`), the images of the
  newest `inline_limits.image` messages that have images (default all, see `within_limits/2`) go
  under `:images`, every image of each, and the rest stay description lines in `content`. Without it
  every image is a description line.
  `:caption_template` renders those lines, as in `entries/3`.

  With `attach_files: true` (`Mythweaver.AI.Model.reads_files?/1`) every PDF goes under `:files`
  instead of its document line, with `attach_audio: true` (`hears_audio?/1`) every audio clip does,
  and with `attach_video: true` (`watches_video?/1`) every video clip, each only within its kind's
  `inline_limits`. Every other attachment is its `file_line/2` in `content`, a document past its
  limit as its summary.
  """
  @spec turns([Message.t()], Character.t() | nil, keyword()) :: [
          %{
            required(:role) => :user | :assistant,
            required(:content) => String.t(),
            optional(:images) => [Attachment.t()],
            optional(:files) => [Attachment.t()]
          }
        ]
  def turns(messages, responder, opts \\ []) do
    template = Keyword.get(opts, :caption_template)
    char = responder_name(responder)
    entries = entries(messages, responder, caption_template: template)
    within = Keyword.get_lazy(opts, :within, fn -> within(entries, Keyword.get(opts, :inline_limits, %{})) end)

    Enum.map(entries, fn entry ->
      {content, shown, native} = turn_parts(entry, within, opts, template, char)

      # Only the responder's own lines go bare, and only with responder roles.
      bare? = entry.role == :assistant and not fixed?(opts)
      text = if bare?, do: content, else: "#{entry.name}: #{content}"
      put_parts(%{role: turn_role(entry, opts), content: text}, shown, native)
    end)
  end

  @doc """
  Whether a chat prompt sends `attachment` as its own part rather than as a text line, inline
  limits aside: an image with `attach_images: true`, a PDF with `attach_files: true`, an audio clip
  with `attach_audio: true` and a video clip with `attach_video: true`. `opts` is a keyword list or
  a map holding those flags.
  """
  @spec native?(Attachment.t(), keyword() | map()) :: boolean()
  def native?(%Attachment{kind: :image}, opts), do: opts[:attach_images] == true
  def native?(%Attachment{content_type: "application/pdf"}, opts), do: opts[:attach_files] == true
  def native?(%Attachment{kind: :audio}, opts), do: opts[:attach_audio] == true
  def native?(%Attachment{kind: :video}, opts), do: opts[:attach_video] == true
  def native?(%Attachment{}, _opts), do: false

  # One entry's chat content, and the images and files it sends as parts.
  defp turn_parts(entry, within, opts, template, char) do
    sent? = &(native?(&1, opts) and MapSet.member?(within, &1.id))
    {shown, as_text} = Enum.split_with(entry.images, sent?)
    {native, files_as_text} = Enum.split_with(entry.files, sent?)
    content = content(entry.text, as_text, file_lines(files_as_text, within), template, %{user: entry.name, char: char})
    {content, shown, native}
  end

  defp file_lines(files, within),
    do: Enum.map(files, &Attachments.file_line(&1, if(MapSet.member?(within, &1.id), do: :full, else: :summary)))

  defp put_parts(turn, shown, native) do
    turn = if shown == [], do: turn, else: Map.put(turn, :images, shown)
    if native == [], do: turn, else: Map.put(turn, :files, native)
  end

  @doc """
  The ready attachments of `message`, the one a regenerate, continue or refine writes, without its
  text, as one more transcript item: `%{line: String.t(), turn: turn}`, or nil when it is nil,
  hidden from the AI (`visible_to_ai: false`) or has no ready attachment. `line` is what `lines/2`
  would print for it with blank text; `turn` is always a `:user` turn prefixed `"Name: "` (image
  parts on an assistant turn are not portable). `opts` as `turns/3`'s (`attach_*`,
  `inline_limits`, `caption_template`).
  """
  @spec reply_media(Message.t() | nil, keyword()) ::
          %{
            line: String.t(),
            turn: %{
              required(:role) => :user,
              required(:content) => String.t(),
              optional(:images) => [Attachment.t()],
              optional(:files) => [Attachment.t()]
            }
          }
          | nil
  def reply_media(message, opts \\ [])
  def reply_media(nil, _opts), do: nil

  def reply_media(%Message{} = message, opts) do
    case entries([message], nil) do
      [%{images: i, files: f} = entry] when i != [] or f != [] ->
        entry = %{entry | text: ""}
        template = Keyword.get(opts, :caption_template)
        within = Keyword.get_lazy(opts, :within, fn -> within([entry], Keyword.get(opts, :inline_limits, %{})) end)
        # The responder is the author.
        {line, _shown, _native} = turn_parts(entry, within, [], template, entry.name)
        {content, shown, native} = turn_parts(entry, within, opts, template, entry.name)

        %{
          line: "#{entry.name}: #{line}",
          turn: put_parts(%{role: :user, content: "#{entry.name}: #{content}"}, shown, native)
        }

      _ ->
        nil
    end
  end

  defp turn_role(entry, opts) do
    if fixed?(opts),
      do: if(entry.character_id in [nil, Keyword.get(opts, :player_id)], do: :user, else: :assistant),
      else: entry.role
  end

  defp fixed?(opts), do: Keyword.get(opts, :speaker_roles, :responder) == :fixed

  # The text, then one description line per image and the given file lines, blank lines dropped.
  defp content(text, images, file_lines, template, vars) do
    [text | Enum.map(images, &Attachments.describe_line(&1, template, vars))]
    |> Enum.concat(file_lines)
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.join("\n")
  end

  @doc """
  The ids of the ready attachments of AI-visible `messages` that go in full: for each kind in
  `limits` (`:image`, `:audio`, `:video`, `:document`), every attachment of that kind in the newest
  `limit` messages having one. A missing or nil limit keeps every attachment of that kind; `:file`
  attachments are never counted.
  """
  @spec within_limits([Message.t()], %{optional(atom()) => non_neg_integer() | nil}) :: MapSet.t(Ecto.UUID.t())
  def within_limits(messages, limits), do: messages |> entries(nil) |> within(limits)

  defp within(entries, limits) do
    for kind <- [:image, :audio, :video, :document], reduce: MapSet.new() do
      acc ->
        groups = for e <- entries, ids = kind_ids(e, kind), ids != [], do: ids
        kept = if is_integer(limits[kind]), do: Enum.take(groups, -limits[kind]), else: groups
        kept |> List.flatten() |> Enum.reduce(acc, &MapSet.put(&2, &1))
    end
  end

  defp kind_ids(entry, :image), do: Enum.map(entry.images, & &1.id)
  defp kind_ids(entry, kind), do: for(a <- entry.files, a.kind == kind, do: a.id)

  defp responder_name(%Character{name: name}) when is_binary(name), do: name
  defp responder_name(_responder), do: ""

  defp role(%Message{author_is_character: true, author_character_id: id}, %Character{id: id}) when not is_nil(id),
    do: :assistant

  defp role(_message, _responder), do: :user

  defp author_name(%Message{author_is_character: true, author_character: %{name: name}}) when is_binary(name), do: name

  defp author_name(%Message{author_name: name}) when is_binary(name) and name != "", do: name

  defp author_name(_message), do: "Narrator"
end
