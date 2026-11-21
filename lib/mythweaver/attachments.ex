defmodule Mythweaver.Attachments do
  @moduledoc """
  Files attached to things: images, documents, audio, video and other files sent with chat
  messages, and character avatars.

  An `Attachment` row records where its bytes live (`Storage`, a pluggable byte store) and what they
  are (sniffed by `FileInfo`, never trusted from the client). Owners link through join tables
  (`@link_schemas`); an attachment no owner links is an orphan, deleted by `delete_unlinked/2` when
  an owner lets go of it and by `sweep_orphans/0` at boot for everything else (composer uploads
  never sent, abandoned presigned uploads, owners deleted wholesale).

  Image URLs go through `url/2`, which asks the active image `Proxy` for a named preset size, so
  the app never resizes an image itself; every other kind links to its bytes directly.

  Two ways bytes arrive:

    * `store_file/3` / `store_binary/2`: the bytes are already here (a LiveView upload on local
      storage, an AI-generated image).
    * `prepare_presigned_upload/3` then `finalize_presigned_upload/3`: with the S3 backend the
      browser posts straight to the bucket; the row is `:pending` until finalize re-checks the object.

  Configuration: `config :mythweaver, Mythweaver.Attachments` (set from env vars in
  `config/runtime.exs`), checked at boot by `validate_config!/0`.
  """

  import Ecto.Query

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.AI.Model
  alias Mythweaver.AI.Request
  alias Mythweaver.Attachments.Attachment
  alias Mythweaver.Attachments.BodyAttachment
  alias Mythweaver.Attachments.Captions
  alias Mythweaver.Attachments.CharacterAttachment
  alias Mythweaver.Attachments.DocumentText
  alias Mythweaver.Attachments.FileInfo
  alias Mythweaver.Attachments.MessageAttachment
  alias Mythweaver.Attachments.Proxy
  alias Mythweaver.Attachments.Storage
  alias Mythweaver.Attachments.TaskSupervisor
  alias Mythweaver.Changes
  alias Mythweaver.Characters.Character
  alias Mythweaver.Chats
  alias Mythweaver.Expressions.Sprite
  alias Mythweaver.Messages.Message
  alias Mythweaver.Messages.MessageBody
  alias Mythweaver.Ownership
  alias Mythweaver.Permissions.Quota
  alias Mythweaver.Prompts.AttachmentRef
  alias Mythweaver.Repo
  alias Mythweaver.Templates.State
  alias Mythweaver.Tokenizer

  require Logger

  @content_types ~w(image/png image/jpeg image/webp)
  @head_bytes 262_144
  # Every join table an owner links attachments through; a new owner type adds its schema here.
  @link_schemas [MessageAttachment, CharacterAttachment, BodyAttachment, Sprite]
  @orphan_grace_seconds 86_400

  @type store_error ::
          :unsupported_type | :not_permitted | :too_large | :quota_exceeded | {:storage, term()} | Ecto.Changeset.t()

  @upload_permissions %{
    image: "uploads.images",
    document: "uploads.documents",
    audio: "uploads.audio",
    video: "uploads.video",
    file: "uploads.files"
  }

  @doc "The attachments config keyword list."
  def config, do: Application.get_env(:mythweaver, __MODULE__, [])

  @doc "The largest accepted file, in bytes."
  def max_upload_bytes, do: config()[:max_upload_bytes]

  @doc "Whether uploads go browser-direct to the bucket (`prepare_presigned_upload/3`)."
  def presigned_uploads?, do: Storage.active() == :s3

  @doc "The permission key that lets a user upload attachments of `kind`."
  @spec upload_permission(Attachment.kind()) :: String.t()
  def upload_permission(kind), do: Map.fetch!(@upload_permissions, kind)

  @doc "The attachment kinds `scope` may upload (`upload_permission/1`), in `Attachment.kinds/0` order."
  @spec uploadable_kinds(Scope.t()) :: [Attachment.kind()]
  def uploadable_kinds(%Scope{} = scope), do: Enum.filter(Attachment.kinds(), &Scope.can?(scope, upload_permission(&1)))

  @doc """
  Stores the file at `path` and records it, uploaded by `scope`'s user (the only one who may adopt
  or delete it while it is unlinked). `opts`: `:filename` (the client's name, display only, and how
  a text document is told from an unknown file), `:source` (`:upload` default, or `:generated`) and
  `:kinds` (the `Attachment` kinds accepted, default `[:image]`; anything else is refused with
  `:unsupported_type`). A kind `scope` may not upload (`upload_permission/1`) is refused with
  `:not_permitted`. A `:document`'s text is extracted into `text_content` (`DocumentText`); a
  failed extraction is logged and the upload still succeeds. Refused with `:quota_exceeded` past
  the user's upload storage (`Mythweaver.Permissions.Quota.check_upload/2`).
  """
  @spec store_file(Scope.t(), Path.t(), keyword()) :: {:ok, Attachment.t()} | {:error, store_error()}
  def store_file(%Scope{} = scope, path, opts \\ []),
    do:
      store({:file, path}, opts |> Keyword.put(:uploaded_by_id, uploader_id(scope)) |> Keyword.put(:quota_scope, scope))

  @doc """
  Like `store_file/3`, for bytes in memory, with no uploader. This is the entry point for AI-generated
  images, which are linked as they are stored.
  """
  @spec store_binary(binary(), keyword()) :: {:ok, Attachment.t()} | {:error, store_error()}
  def store_binary(binary, opts \\ []) when is_binary(binary),
    do: store({:binary, binary}, Keyword.delete(opts, :uploaded_by_id))

  @doc """
  Like `store_file/3`, for bytes in memory: an upload of `scope`'s user, held to its upload
  permissions and storage. What imports store their avatars and blobs with.
  """
  @spec store_upload(Scope.t(), binary(), keyword()) :: {:ok, Attachment.t()} | {:error, store_error()}
  def store_upload(%Scope{} = scope, binary, opts \\ []) when is_binary(binary),
    do:
      store(
        {:binary, binary},
        opts |> Keyword.put(:uploaded_by_id, uploader_id(scope)) |> Keyword.put(:quota_scope, scope)
      )

  @doc """
  Stores a copy of `attachment`'s file as a new upload of `scope`'s user, keeping its filename and
  description: what `Mythweaver.Sharing.Clone` gives a cloned character's avatar and sprites. Held
  to the user's upload permissions and storage like `store_file/3`.
  """
  @spec copy(Scope.t(), Attachment.t()) :: {:ok, Attachment.t()} | {:error, store_error()}
  def copy(%Scope{} = scope, %Attachment{} = attachment) do
    with {:ok, bytes} <- read_for_copy(attachment),
         {:ok, copy} <-
           store({:binary, bytes},
             filename: attachment.filename,
             kinds: [attachment.kind],
             uploaded_by_id: uploader_id(scope),
             quota_scope: scope
           ) do
      restore_description(copy, attachment.description)
    end
  end

  defp read_for_copy(attachment) do
    case read(attachment) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, reason} -> {:error, {:storage, reason}}
    end
  end

  defp uploader_id(%Scope{user: %{id: id}}), do: id
  defp uploader_id(%Scope{}), do: nil

  defp store(source, opts) do
    with {:ok, size} <- size_of(source),
         :ok <- check_size(size),
         :ok <- Quota.check_upload(opts[:quota_scope], size),
         {:ok, head} <- head_of(source),
         {:ok, info} <- FileInfo.parse(head, opts[:filename]),
         :ok <- check_kind(info.kind, opts) do
      id = Mythweaver.Schema.generate_id()
      key = key_for(id, info.content_type)
      backend = Storage.active()
      mod = Storage.module_for(backend)

      case put(mod, source, key, info.content_type) do
        :ok ->
          %Attachment{id: id}
          |> Attachment.changeset(
            Map.merge(
              %{
                kind: info.kind,
                source: opts[:source] || :upload,
                status: :ready,
                storage: backend,
                key: key,
                content_type: info.content_type,
                width: info.width,
                height: info.height,
                byte_size: size,
                filename: opts[:filename],
                uploaded_by_id: opts[:uploaded_by_id]
              },
              document_text(info, fn -> bytes_of(source) end)
            )
          )
          |> Repo.insert()
          |> tap(fn
            {:ok, attachment} -> blurhash_later(attachment)
            {:error, _} -> mod.delete(key)
          end)

        {:error, reason} ->
          {:error, {:storage, reason}}
      end
    end
  end

  # Only an upload (`store_file/3`, with a scope) is held to the uploader's permissions.
  defp check_kind(kind, opts) do
    cond do
      kind not in Keyword.get(opts, :kinds, [:image]) -> {:error, :unsupported_type}
      opts[:quota_scope] && not Scope.can?(opts[:quota_scope], upload_permission(kind)) -> {:error, :not_permitted}
      true -> :ok
    end
  end

  defp bytes_of({:file, path}), do: File.read(path)
  defp bytes_of({:binary, bin}), do: {:ok, bin}

  # The `text_content`/`page_count` attrs of a document, `%{}` for any other kind or a failed read.
  defp document_text(%{kind: :document, content_type: type}, read_bytes) do
    with {:ok, bytes} <- read_bytes.(),
         {:ok, %{text: text, page_count: pages}} <- DocumentText.extract(type, bytes) do
      %{text_content: text, page_count: pages}
    else
      {:error, reason} ->
        Logger.warning("could not extract text from a #{type} upload: #{inspect(reason)}")
        %{}
    end
  end

  defp document_text(_info, _read_bytes), do: %{}

  defp size_of({:file, path}) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} -> {:ok, size}
      {:error, reason} -> {:error, {:storage, reason}}
    end
  end

  defp size_of({:binary, bin}), do: {:ok, byte_size(bin)}

  defp head_of({:binary, bin}), do: {:ok, binary_part(bin, 0, min(byte_size(bin), @head_bytes))}

  defp head_of({:file, path}) do
    case File.open(path, [:read, :binary], &IO.binread(&1, @head_bytes)) do
      {:ok, data} when is_binary(data) -> {:ok, data}
      {:ok, _eof_or_error} -> {:error, :unsupported_type}
      {:error, reason} -> {:error, {:storage, reason}}
    end
  end

  defp put(mod, {:file, path}, key, type), do: mod.put_file(key, path, type)
  defp put(mod, {:binary, bin}, key, type), do: mod.put_binary(key, bin, type)

  defp check_size(size), do: if(size > max_upload_bytes(), do: {:error, :too_large}, else: :ok)

  defp key_for(id, content_type) do
    ext =
      case MIME.extensions(content_type) do
        [ext | _] -> ext
        [] -> "bin"
      end

    "attachments/#{id}.#{ext}"
  end

  @doc """
  Reserves a `:pending` row and a browser-direct upload form for a file the client says is
  `client_type`, `client_size` bytes. `opts`: `:filename` and `:kinds` (default `[:image]`), as for
  `store_file/3`, permissions included. The claim (`FileInfo.claimed/2`) is re-checked against the
  object itself by `finalize_presigned_upload/3`; the POST policy already caps size and fixes the
  type, always the server's choice, so an unknown file is stored as `application/octet-stream`.
  """
  @spec prepare_presigned_upload(Scope.t(), String.t(), non_neg_integer(), keyword()) ::
          {:ok, %{attachment_id: Ecto.UUID.t(), url: String.t(), fields: %{String.t() => String.t()}}}
          | {:error,
             :unsupported_type | :not_permitted | :too_large | :quota_exceeded | :unsupported | Ecto.Changeset.t()}
  def prepare_presigned_upload(%Scope{} = scope, client_type, client_size, opts \\ []) do
    {kind, type} = FileInfo.claimed(client_type, opts[:filename])

    cond do
      kind not in Keyword.get(opts, :kinds, [:image]) ->
        {:error, :unsupported_type}

      not Scope.can?(scope, upload_permission(kind)) ->
        {:error, :not_permitted}

      client_size > max_upload_bytes() ->
        {:error, :too_large}

      Quota.check_upload(scope, client_size) != :ok ->
        {:error, :quota_exceeded}

      true ->
        id = Mythweaver.Schema.generate_id()
        key = key_for(id, type)

        insert =
          %Attachment{id: id}
          |> Attachment.changeset(%{
            kind: kind,
            source: :upload,
            status: :pending,
            storage: :s3,
            key: key,
            content_type: type,
            uploaded_by_id: uploader_id(scope)
          })
          |> Repo.insert()

        with {:ok, attachment} <- insert,
             {:ok, %{url: url, fields: fields}} <-
               Storage.module_for(:s3).presign_upload(key, type, max_upload_bytes()) do
          {:ok, %{attachment_id: attachment.id, url: url, fields: Map.new(fields)}}
        end
    end
  end

  @doc """
  Checks a browser-direct upload against what was claimed: the object exists, fits the size limit,
  and sniffs as the claimed type (a `:file` takes any bytes, but not bytes of a kind the uploader
  may not upload: `:not_permitted`). On success the row becomes `:ready`, with a document's text
  extracted as `store_file/3` does; on failure the object and the row are both deleted. Only the
  user who prepared the upload may finalize it; anyone else gets `:not_found`.
  """
  @spec finalize_presigned_upload(Scope.t(), Ecto.UUID.t(), String.t() | nil) ::
          {:ok, Attachment.t()}
          | {:error,
             :not_found | :unsupported_type | :not_permitted | :too_large | :quota_exceeded | {:storage, term()}}
  def finalize_presigned_upload(%Scope{} = scope, attachment_id, filename) do
    case uploaded_by(scope, attachment_id) do
      %Attachment{status: :pending} = attachment ->
        mod = Storage.module_for(attachment.storage)

        case verify_object(mod, attachment, scope, filename) do
          {:ok, size, info} ->
            attachment
            |> Attachment.changeset(
              Map.merge(
                %{status: :ready, byte_size: size, width: info.width, height: info.height, filename: filename},
                document_text(attachment, fn -> read(attachment) end)
              )
            )
            |> Repo.update()
            |> tap(fn
              {:ok, ready} -> blurhash_later(ready)
              _ -> :ok
            end)

          {:error, reason} ->
            _ = mod.delete(attachment.key)
            Repo.delete(attachment, allow_stale: true)
            {:error, reason}
        end

      _ ->
        {:error, :not_found}
    end
  end

  defp uploaded_by(%Scope{user: %{id: user_id}}, attachment_id) do
    case Ecto.UUID.cast(attachment_id) do
      {:ok, id} -> Repo.get_by(Attachment, id: id, uploaded_by_id: user_id)
      :error -> nil
    end
  end

  defp uploaded_by(%Scope{}, _attachment_id), do: nil

  defp verify_object(mod, %Attachment{key: key, kind: kind, content_type: claimed}, scope, filename) do
    with {:ok, %{byte_size: size}} <- storage_call(mod.stat(key)),
         :ok <- check_size(size),
         :ok <- Quota.check_upload(scope, size),
         {:ok, head} <- storage_call(mod.read_head(key, @head_bytes)),
         {:ok, info} <- FileInfo.parse(head, filename) do
      cond do
        kind == :file and not Scope.can?(scope, upload_permission(info.kind)) -> {:error, :not_permitted}
        kind == :file or info.content_type == claimed -> {:ok, size, info}
        true -> {:error, :unsupported_type}
      end
    end
  end

  defp storage_call({:error, :not_found}), do: {:error, :not_found}
  defp storage_call({:error, reason}), do: {:error, {:storage, reason}}
  defp storage_call(ok), do: ok

  @doc """
  Restores an imported attachment's `description` (its caption from another instance): a non-blank
  one is saved with `caption_status: :done`, so no caption job runs for it. Blank leaves it as is.
  """
  @spec restore_description(Attachment.t(), String.t() | nil) :: {:ok, Attachment.t()}
  def restore_description(%Attachment{} = attachment, description) do
    if is_binary(description) and String.trim(description) != "" do
      attachment |> Attachment.changeset(%{description: description, caption_status: :done}) |> Repo.update()
    else
      {:ok, attachment}
    end
  end

  @doc "Links `ready` attachments to a message. Run inside the caller's transaction."
  def link_message!(%Message{id: message_id}, attachments) do
    now = DateTime.utc_now()

    rows =
      Enum.map(attachments, fn %Attachment{status: :ready, id: id} ->
        link_row(now, message_id: message_id, attachment_id: id)
      end)

    if rows != [], do: Repo.insert_all(MessageAttachment, rows)
    :ok
  end

  @doc "Removes the links of `attachment_ids` from `message`. Run inside the caller's transaction."
  def unlink_message!(%Message{id: message_id}, attachment_ids) do
    Repo.delete_all(
      from l in MessageAttachment, where: l.message_id == ^message_id and l.attachment_id in ^attachment_ids
    )

    :ok
  end

  @doc """
  Links the ready attachments among `attachments` that still exist to `body` (a guided swipe or a
  refine's media). Idempotent.
  """
  @spec link_body!(MessageBody.t(), [Attachment.t()]) :: :ok
  def link_body!(_body, []), do: :ok

  def link_body!(%MessageBody{id: body_id}, attachments) do
    ids = for %Attachment{status: :ready, id: id} <- attachments, do: id

    now = DateTime.utc_now()

    rows =
      Repo.all(from a in Attachment, where: a.id in ^ids, select: a.id)
      |> Enum.map(&link_row(now, message_body_id: body_id, attachment_id: &1))

    if rows != [],
      do:
        Repo.insert_all(BodyAttachment, rows,
          on_conflict: :nothing,
          conflict_target: [:message_body_id, :attachment_id]
        )

    :ok
  end

  defp link_row(now, fields) do
    Map.new(fields) |> Map.merge(%{id: Mythweaver.Schema.generate_id(), inserted_at: now, updated_at: now})
  end

  @doc "Moves every attachment link of `from_message_ids` onto `to_message_id` (message merges)."
  def move_message_links([], _to), do: {0, nil}

  def move_message_links(from_message_ids, to_message_id) do
    MessageAttachment
    |> where([l], l.message_id in ^from_message_ids)
    |> Repo.update_all(set: [message_id: to_message_id])
  end

  @doc "The ids of the attachments linked to a message."
  def message_attachment_ids(message_id) do
    Repo.all(from l in MessageAttachment, where: l.message_id == ^message_id, select: l.attachment_id)
  end

  @doc """
  Deletes each of `attachment_ids` that no owner links and `scope`'s user uploaded: its bytes, then
  its row. Ids of linked attachments, or of another user's uploads, are skipped. A failed storage
  delete is logged and keeps the row, so the next sweep retries it.
  """
  @spec delete_unlinked(Scope.t(), [Ecto.UUID.t()]) :: :ok
  def delete_unlinked(%Scope{user: %{id: user_id}}, [_ | _] = attachment_ids) do
    from(a in Attachment, as: :attachment, where: a.id in ^attachment_ids and a.uploaded_by_id == ^user_id)
    |> delete_unlinked_rows()
  end

  def delete_unlinked(%Scope{}, _attachment_ids), do: :ok

  @doc """
  Deletes each of `attachment_ids` that no owner links any more, whoever uploaded it. Only for ids
  the caller just unlinked from a row it was authorized to delete (`Mythweaver.Messages.delete_message/2`),
  never for client-supplied ids: those go through `delete_unlinked/2`.
  """
  @spec delete_orphaned([Ecto.UUID.t()]) :: :ok
  def delete_orphaned([]), do: :ok

  def delete_orphaned(attachment_ids) do
    from(a in Attachment, as: :attachment, where: a.id in ^attachment_ids)
    |> delete_unlinked_rows()
  end

  defp delete_unlinked_rows(query) do
    query
    |> unlinked()
    |> Repo.all()
    |> Enum.each(&delete_attachment/1)
  end

  @doc "Deletes every attachment older than a day that no owner links. Returns how many went."
  def sweep_orphans do
    cutoff = DateTime.add(DateTime.utc_now(), -@orphan_grace_seconds, :second)

    from(a in Attachment, as: :attachment, where: a.inserted_at < ^cutoff)
    |> unlinked()
    |> Repo.all()
    |> Enum.count(&(delete_attachment(&1) == :ok))
  end

  defp unlinked(query) do
    Enum.reduce(@link_schemas, query, fn schema, q ->
      where(q, [], not exists(from l in schema, where: l.attachment_id == parent_as(:attachment).id))
    end)
  end

  defp delete_attachment(%Attachment{} = attachment) do
    case Storage.module_for(attachment.storage).delete(attachment.key) do
      :ok ->
        Repo.delete(attachment, allow_stale: true)
        :ok

      {:error, reason} ->
        Logger.warning("could not delete attachment #{attachment.key}: #{inspect(reason)}")
        :error
    end
  end

  @doc """
  Makes `attachment` the character's only avatar; a replaced avatar is deleted. The new avatar is
  described by the site default caption model when `describe:` is true, or, when it is `nil` or
  omitted, when the scope's `images.auto_caption` setting is on and the description would become
  the character's Appearance (`Captions.updates_appearance?/2`); a non-blank `instruction:`
  replaces the caption prompt. That description becomes the character's `appearance` unless
  someone wrote their own (`Captions.request_avatar/5`). Needs edit rights on the character
  (`Mythweaver.Ownership.authorize_edit/2`).
  """
  @spec set_avatar(Scope.t(), Character.t(), Attachment.t(), [
          {:describe, boolean() | nil} | {:instruction, String.t() | nil}
        ]) :: :ok | {:error, term()}
  def set_avatar(%Scope{} = scope, %Character{} = character, %Attachment{status: :ready} = avatar, opts \\ []) do
    with :ok <- Ownership.authorize_edit(scope, character) do
      scope
      |> replace_avatar(character, avatar, opts)
      |> Changes.notify(:characters, character.user_id)
    end
  end

  defp replace_avatar(scope, %Character{id: character_id} = character, %Attachment{id: attachment_id} = avatar, opts) do
    transaction =
      Repo.transaction(fn ->
        {_, old_ids} = Repo.delete_all(avatar_links(character_id))
        Repo.insert!(%CharacterAttachment{character_id: character_id, attachment_id: attachment_id, role: :avatar})

        previous =
          Repo.one(from(a in Attachment, where: a.id in ^old_ids, select: a.description, limit: 1))

        {old_ids, previous}
      end)

    with {:ok, {old_ids, previous}} <- transaction do
      :ok = delete_orphaned(old_ids -- [attachment_id])

      describe? =
        case Keyword.get(opts, :describe) do
          nil ->
            Mythweaver.Settings.get(scope, "images.auto_caption") and
              Captions.updates_appearance?(scope, character)

          value ->
            value
        end

      if describe?,
        do: Captions.request_avatar(scope, character, avatar, previous, instruction: opts[:instruction]),
        else: :ok
    end
  end

  @doc "Removes and deletes the character's avatar, if any; needs edit rights on the character."
  @spec remove_avatar(Scope.t(), Character.t()) :: :ok | {:error, :unauthorized}
  def remove_avatar(%Scope{} = scope, %Character{id: character_id} = character) do
    with :ok <- Ownership.authorize_edit(scope, character) do
      {_, ids} = Repo.delete_all(avatar_links(character_id))
      ids |> delete_orphaned() |> Changes.notify(:characters, character.user_id)
    end
  end

  defp avatar_links(character_id) do
    from l in CharacterAttachment,
      where: l.character_id == ^character_id and l.role == :avatar,
      select: l.attachment_id
  end

  @doc """
  The URL that shows `attachment`: an image at a `Proxy` preset (`:avatar`, `:portrait`, `:sprite`, `:thumb`,
  `:inline`, `:full`, `:model`) or, with `:original`, as its stored bytes, unresized (`Proxy`
  `original_url/4`: through the proxy when it can pass bytes through, else the storage link); any
  other kind as its stored bytes whatever the preset. `nil` for no attachment or one still
  uploading. It is for browsers; the server fetches through `model_image/1` and `read/1`.

  The link is signed and expires: whoever renders it decides who sees it, and holding it is all the
  access a browser (or a proxy fetching on its behalf) needs. Every link issued in one
  `link_window_seconds` window is identical, so browsers and proxies can cache it, and it stays valid
  until the end of the next window: one to two windows after it is issued.
  """
  @spec url(Attachment.t() | nil, atom()) :: String.t() | nil
  def url(nil, _preset), do: nil
  def url(%Attachment{status: :pending}, _preset), do: nil

  def url(%Attachment{kind: kind} = attachment, _preset) when kind != :image do
    {source, _expires_at} = signed_source(attachment, config())
    source
  end

  def url(%Attachment{} = attachment, :original) do
    config = config()
    {source, expires_at} = signed_source(attachment, config)
    Proxy.module_for(config[:proxy]).original_url(source, attachment.key, expires_at, config[config[:proxy]] || [])
  end

  def url(%Attachment{} = attachment, preset) do
    config = config()
    proxy_url(attachment, preset, config, config[config[:proxy]] || [])
  end

  @doc """
  The `srcset` for an image `attachment` at `preset`'s srcset widths (`Proxy.srcset_sizes/1`):
  `"<url> 192w, <url> 300w, …"`, the first candidate equal to `url(attachment, preset)`. `nil` for
  no attachment, one still uploading, a non-image, and the `:none` proxy (every candidate would
  be the same original).
  """
  @spec srcset(Attachment.t() | nil, atom()) :: String.t() | nil
  def srcset(%Attachment{status: status, kind: :image} = attachment, preset) when status != :pending do
    config = config()

    if config[:proxy] != :none do
      proxy = Proxy.module_for(config[:proxy])
      proxy_config = config[config[:proxy]] || []
      {source, expires_at} = signed_source(attachment, config)

      Enum.map_join(Proxy.srcset_sizes(preset), ", ", fn {width, size} ->
        "#{proxy.url(source, attachment.key, size, expires_at, proxy_config)} #{width}w"
      end)
    end
  end

  def srcset(_attachment, _preset), do: nil

  @doc """
  A still of `attachment` at a `Proxy` preset, when the proxy renders stills (`Proxy` `stills?/0`):
  a frame of a video (the proxy picks a representative one) or the first page of a PDF. `nil` for
  every other attachment, one still uploading, and proxies that cannot.
  """
  @spec still_url(Attachment.t() | nil, atom()) :: String.t() | nil
  def still_url(%Attachment{status: :ready, kind: kind, content_type: type} = attachment, preset)
      when kind == :video or type == "application/pdf" do
    config = config()

    if Proxy.module_for(config[:proxy]).stills?(),
      do: proxy_url(attachment, preset, config, config[config[:proxy]] || [])
  end

  def still_url(_attachment, _preset), do: nil

  defp proxy_url(attachment, preset, config, proxy_config) do
    {source, expires_at} = signed_source(attachment, config)
    Proxy.module_for(config[:proxy]).url(source, attachment.key, Proxy.preset!(preset), expires_at, proxy_config)
  end

  # The attachment's signed storage link for the current window, and when it expires.
  defp signed_source(attachment, config) do
    {signed_at, expires_at} = window(config)
    {Storage.module_for(attachment.storage).signed_url(attachment.key, signed_at, expires_at), expires_at}
  end

  defp window(config) do
    window = config[:link_window_seconds]
    signed_at = div(System.os_time(:second), window) * window
    {signed_at, signed_at + 2 * window}
  end

  @doc """
  The origins outside the app a browser loads attachments from or uploads them to, for the
  Content-Security-Policy: the image proxy's or CDN's, and storage's own (its signed links, also
  the S3 presigned-POST target). Links relative to the app (local storage, `:none` proxy) add none.
  `[]`, logged, when the links can't be built: a page never fails over its policy.
  """
  @spec browser_origins() :: [String.t()]
  def browser_origins do
    config = config()
    {signed_at, expires_at} = window(config)

    probe = %Attachment{
      key: "csp-probe",
      storage: config[:storage],
      kind: :image,
      status: :ready,
      content_type: "image/png"
    }

    [url(probe, :full), Storage.module_for(probe.storage).signed_url(probe.key, signed_at, expires_at)]
    |> Enum.flat_map(&url_origin/1)
    |> Enum.uniq()
  rescue
    e ->
      Logger.warning("CSP: attachment origins unavailable: #{Exception.message(e)}")
      []
  end

  defp url_origin(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, port: port} when is_binary(scheme) and is_binary(host) and host != "" ->
        port = if port == URI.default_port(scheme), do: "", else: ":#{port}"
        [String.downcase("#{scheme}://#{host}#{port}")]

      _ ->
        []
    end
  end

  @doc """
  The attachment row, or `nil`. One linked to a message, or to a guided swipe, needs a scope that may
  act on that message's chat; anything else (an unlinked upload, an avatar) is returned as is.
  """
  @spec get_attachment(Scope.t(), Ecto.UUID.t()) :: Attachment.t() | nil
  def get_attachment(%Scope{} = scope, id) do
    with %Attachment{} = attachment <- Repo.get(Attachment, id) do
      chat_id = message_chat_id(attachment.id) || body_chat_id(attachment.id)

      if is_nil(chat_id) or Chats.authorize(scope, chat_id, :read) == :ok, do: attachment
    end
  end

  defp message_chat_id(attachment_id) do
    Repo.one(
      from(l in MessageAttachment,
        join: m in Message,
        on: m.id == l.message_id,
        where: l.attachment_id == ^attachment_id,
        select: m.chat_id,
        limit: 1
      )
    )
  end

  defp body_chat_id(attachment_id) do
    Repo.one(
      from(l in BodyAttachment,
        join: b in MessageBody,
        on: b.id == l.message_body_id,
        join: m in Message,
        on: m.id == b.message_id,
        where: l.attachment_id == ^attachment_id,
        select: m.chat_id,
        limit: 1
      )
    )
  end

  @doc """
  The ready, locally stored attachment at storage `key`, or `nil`. No scope: `/uploads` links are
  their own credential (`Storage.Local.open/1`), checked before this lookup.
  """
  @spec get_local_by_key(String.t()) :: Attachment.t() | nil
  def get_local_by_key(key), do: Repo.get_by(Attachment, key: key, storage: :local, status: :ready)

  @doc """
  Whether `/uploads` may hand `attachment` to a request whose `x-mythweaver-origin-secret` header is
  `origin_secret`. Only images are held back, and only where a proxy serves them: never with
  `:xtandard`, which reads the files itself (every image link points at it); with `:cloudflare` or
  `:fastly` only to a request carrying `uploads_origin_secret`, which the CDN adds to what it
  forwards, so the origin cannot be fetched around it. Every other kind, and every image with no
  proxy, is for browsers.
  """
  @spec served_directly?(Attachment.t(), String.t() | nil) :: boolean()
  def served_directly?(%Attachment{kind: :image}, origin_secret) do
    config = config()

    case config[:proxy] do
      :xtandard ->
        false

      proxy when proxy in [:cloudflare, :fastly] ->
        secret = config[:uploads_origin_secret]
        is_binary(origin_secret) and is_binary(secret) and Plug.Crypto.secure_compare(origin_secret, secret)

      _ ->
        true
    end
  end

  def served_directly?(%Attachment{}, _origin_secret), do: true

  @doc """
  A stored image no owner links yet (a fresh upload) that `scope`'s user uploaded, or `nil`, also for
  a malformed id. Lets a caller that only holds an id adopt it without being able to take another
  owner's or another user's image.
  """
  @spec get_unlinked_image(Scope.t(), String.t()) :: Attachment.t() | nil
  def get_unlinked_image(%Scope{user: %{id: user_id}}, id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} ->
        from(a in Attachment,
          as: :attachment,
          where: a.id == ^id and a.kind == :image and a.status == :ready and a.uploaded_by_id == ^user_id
        )
        |> unlinked()
        |> Repo.one()

      :error ->
        nil
    end
  end

  def get_unlinked_image(%Scope{}, _id), do: nil

  @doc "The attachments among `ids` that still exist, by id."
  @spec get_attachments(Scope.t(), [Ecto.UUID.t()]) :: %{optional(Ecto.UUID.t()) => Attachment.t()}
  def get_attachments(%Scope{}, []), do: %{}

  def get_attachments(%Scope{}, ids),
    do: from(a in Attachment, where: a.id in ^ids) |> Repo.all() |> Map.new(&{&1.id, &1})

  @doc "The attachment's bytes."
  @spec read(Attachment.t()) :: {:ok, binary()} | {:error, term()}
  def read(%Attachment{storage: storage, key: key}), do: Storage.module_for(storage).read(key)

  @doc """
  The image as a vision model is sent it: scaled by the image proxy into the `:model` preset (2048 px
  box, never enlarged), so a 20 MB photo does not become a 27 MB request or thousands of image
  tokens. With no proxy, or when the proxy fails or answers with a type no vision API takes, the
  original bytes are sent instead. Only PNG, JPEG and WebP are ever sent.

  The server reaches xi at `xtandard.internal_url` when set (needed whenever the browser's
  `base_url` is relative, as in dev's `/img`, or names a host the app cannot reach), else at
  `xtandard.base_url`.
  """
  @spec model_image(Attachment.t()) ::
          {:ok, %{media_type: String.t(), data: binary()}} | {:error, :unsupported_type | term()}
  def model_image(%Attachment{content_type: type} = attachment) when type in @content_types do
    case fetch_scaled(attachment) do
      {:ok, image} ->
        {:ok, image}

      :no_proxy ->
        original(attachment)

      {:error, reason} ->
        Logger.warning("image proxy failed for #{attachment.key}, sending the original: #{inspect(reason)}")
        original(attachment)
    end
  end

  def model_image(%Attachment{}), do: {:error, :unsupported_type}

  defp original(attachment) do
    with {:ok, bytes} <- read(attachment), do: {:ok, %{media_type: attachment.content_type, data: bytes}}
  end

  defp fetch_scaled(attachment) do
    config = config()

    case config[:proxy] do
      :none ->
        :no_proxy

      proxy ->
        attachment
        |> proxy_url(:model, config, server_config(config[proxy] || []))
        |> get_scaled()
    end
  end

  # The proxy config with `base_url` pointing where the server, not the browser, reaches it.
  defp server_config(proxy_config) do
    if internal = proxy_config[:internal_url],
      do: Keyword.put(proxy_config, :base_url, internal),
      else: proxy_config
  end

  # No `Accept`, so xi negotiates no AVIF/WebP: it answers JPEG for an opaque source and keeps PNG
  # for one with alpha, both sendable. Retries off: a failure falls back to the original rather than
  # waiting.
  defp get_scaled(url) do
    case proxy_get(url) do
      {:ok, type, body} when type in @content_types -> {:ok, %{media_type: type, data: body}}
      {:ok, type, _body} -> {:error, {:content_type, type}}
      {:error, reason} -> {:error, reason}
    end
  end

  # The proxy's answer at `url`, as its bare content type and body.
  defp proxy_get(url) do
    [url: url, decode_body: false, retry: false, receive_timeout: 30_000]
    |> Req.new()
    |> Req.merge(Application.get_env(:mythweaver, :image_proxy_req_options, []))
    |> Req.get()
    |> case do
      {:ok, %Req.Response{status: 200, body: body} = resp} ->
        {:ok, resp |> Req.Response.get_header("content-type") |> List.first("") |> String.split(";") |> hd(), body}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Whether `png/1` can give `attachment` as a PNG: it is one, or it is a ready image and the image
  proxy re-encodes to PNG (`Proxy` `png_url/4`).
  """
  @spec png?(Attachment.t()) :: boolean()
  def png?(%Attachment{content_type: "image/png"}), do: true
  def png?(%Attachment{} = attachment), do: png_url(attachment, config()) != nil

  @doc """
  The image as PNG bytes at its own size: a PNG's stored bytes, else the image proxy's re-encoding,
  fetched where the server reaches the proxy (`xtandard.internal_url`, as `model_image/1`).
  `{:error, :unsupported}` when `png?/1` is false; a proxy failure, or an answer that isn't a PNG,
  is logged and returned.
  """
  @spec png(Attachment.t()) :: {:ok, binary()} | {:error, term()}
  def png(%Attachment{content_type: "image/png"} = attachment), do: read(attachment)

  def png(%Attachment{} = attachment) do
    config = config()
    config = Keyword.put(config, config[:proxy], server_config(config[config[:proxy]] || []))

    case png_url(attachment, config) do
      nil ->
        {:error, :unsupported}

      url ->
        case proxy_get(url) do
          {:ok, "image/png", <<137, "PNG", 13, 10, 26, 10, _rest::binary>> = body} -> {:ok, body}
          {:ok, type, _body} -> png_failed(attachment, {:content_type, type})
          {:error, reason} -> png_failed(attachment, reason)
        end
    end
  end

  defp png_url(%Attachment{kind: :image, status: :ready} = attachment, config) do
    {signed_at, expires_at} = window(config)
    source = Storage.module_for(attachment.storage).signed_url(attachment.key, signed_at, expires_at)
    Proxy.module_for(config[:proxy]).png_url(source, attachment.key, expires_at, config[config[:proxy]] || [])
  end

  defp png_url(%Attachment{}, _config), do: nil

  defp png_failed(attachment, reason) do
    Logger.warning("image proxy couldn't make #{attachment.key} a PNG: #{inspect(reason)}")
    {:error, reason}
  end

  @doc """
  Asks the proxy for `attachment`'s blurhash (xi's `/info`, 4×3 components) and stores it, so
  inline images can paint a placeholder while they load. Only images, only with `:xtandard`;
  anything else is `:skipped`. A failure is logged and leaves `blurhash` nil.
  """
  @spec refresh_blurhash(Attachment.t()) :: {:ok, Attachment.t()} | :skipped | {:error, term()}
  def refresh_blurhash(%Attachment{kind: :image, status: :ready} = attachment) do
    config = config()
    if config[:proxy] == :xtandard, do: fetch_blurhash(attachment, config), else: :skipped
  end

  def refresh_blurhash(%Attachment{}), do: :skipped

  defp fetch_blurhash(attachment, config) do
    cfg = server_config(config[:xtandard] || [])
    {signed_at, expires_at} = window(config)
    source = Storage.module_for(attachment.storage).signed_url(attachment.key, signed_at, expires_at)
    url = Proxy.Xtandard.info_url(source, attachment.key, "bh:4:3", expires_at, cfg)

    [url: url, retry: false, receive_timeout: 30_000]
    |> Req.new()
    |> Req.merge(Application.get_env(:mythweaver, :image_proxy_req_options, []))
    |> Req.get()
    |> case do
      {:ok, %Req.Response{status: 200, body: %{"blurhash" => hash}}} when is_binary(hash) ->
        attachment |> Attachment.changeset(%{blurhash: hash}) |> Repo.update()

      {:ok, %Req.Response{status: status, body: body}} ->
        blurhash_failed(attachment, {:http_error, status, body})

      {:error, reason} ->
        blurhash_failed(attachment, reason)
    end
  end

  defp blurhash_failed(attachment, reason) do
    Logger.warning("blurhash failed for #{attachment.key}: #{inspect(reason)}")
    {:error, reason}
  end

  # Off in test (`:attachment_blurhash_in_background`), where no task may outlive the sandbox.
  defp blurhash_later(%Attachment{kind: :image} = attachment) do
    if Application.get_env(:mythweaver, :attachment_blurhash_in_background, true) do
      {:ok, _} = Task.Supervisor.start_child(TaskSupervisor, fn -> refresh_blurhash(attachment) end)
    end

    :ok
  end

  defp blurhash_later(%Attachment{}), do: :ok

  @doc """
  An estimate of the prompt tokens a vision model spends on `attachment`, by OpenAI's documented
  rule (other backends differ; it is always an estimate): fit the image in 2048×2048, shrink its
  short side to 768, then 170 tokens per 512 px tile plus 85. An image within 512×512, or any image
  sent with `detail: :low`, costs 85. Unknown dimensions count as a 768 px square (765).
  """
  @spec image_tokens(Attachment.t(), :low | :auto | :high | nil) :: pos_integer()
  def image_tokens(attachment, detail \\ nil)

  def image_tokens(%Attachment{}, :low), do: 85

  def image_tokens(%Attachment{width: w, height: h}, _detail) when is_integer(w) and is_integer(h) do
    if w <= 512 and h <= 512 do
      85
    else
      fit = min(1.0, 2048 / max(w, h))
      {w, h} = {w * fit, h * fit}
      short = min(1.0, 768 / min(w, h))
      {w, h} = {w * short, h * short}
      ceil(w / 512) * ceil(h / 512) * 170 + 85
    end
  end

  def image_tokens(%Attachment{}, _detail), do: 765

  @doc "The text a model that cannot see the image reads in its place."
  @spec describe_line(Attachment.t()) :: String.t()
  def describe_line(%Attachment{description: d}) when is_binary(d) do
    case String.trim(d) do
      "" -> "[Image]"
      text -> "[Image: #{text}]"
    end
  end

  def describe_line(%Attachment{}), do: "[Image]"

  @doc """
  The text a model reads for a non-image attachment, in its message's content. `mode` `:full` (the
  default) gives a document's extracted text between `[Document: name]` and `[/Document]` (or a
  no-readable-text line); `:summary` gives its description between `[Document: name (summary)]` and
  `[/Document]`, falling back to the full text until it has one. Audio and video are an
  `[Audio: name]`/`[Video: name]` block holding their description in either mode, or the bare line
  without one; anything else is a `[File: name]` line. Fixed: `images.caption_template` shapes only
  image lines.
  """
  @spec file_line(Attachment.t(), :full | :summary) :: String.t()
  def file_line(%Attachment{kind: kind, filename: filename} = attachment, mode \\ :full) do
    name = filename || "untitled"
    description = attachment.description && String.trim(attachment.description)

    case {kind, description} do
      {:document, summary} when mode == :summary and summary not in [nil, ""] ->
        "[Document: #{name} (summary)]\n#{summary}\n[/Document]"

      {:document, _} ->
        case attachment.text_content && String.trim(attachment.text_content) do
          text when text not in [nil, ""] -> "[Document: #{name}]\n#{text}\n[/Document]"
          _ -> "[Document: #{name} (no readable text)]"
        end

      {:audio, text} when text not in [nil, ""] ->
        "[Audio: #{name}]\n#{text}\n[/Audio]"

      {:audio, _} ->
        "[Audio: #{name}]"

      {:video, text} when text not in [nil, ""] ->
        "[Video: #{name}]\n#{text}\n[/Video]"

      {:video, _} ->
        "[Video: #{name}]"

      _ ->
        "[File: #{name}]"
    end
  end

  @doc """
  The image's text form rendered through `template` (the `images.caption_template` setting), whose
  data is `caption` (the trimmed description, `nil` until described), `user` (the sender's name) and
  `char` (the responder's). A `nil` template, or one whose render fails, gives `describe_line/1`'s
  built-in line, so template source never leaks into a prompt.
  """
  @spec describe_line(Attachment.t(), String.t() | nil, %{user: String.t(), char: String.t()}) :: String.t()
  def describe_line(%Attachment{} = attachment, nil, _vars), do: describe_line(attachment)

  def describe_line(%Attachment{} = attachment, template, %{user: user, char: char}) do
    caption = attachment.description && String.trim(attachment.description)
    data = %{"caption" => if(caption != "", do: caption), "user" => user, "char" => char}
    state = State.new(data, %{chat: %{}, global: %{}}, attachment.id)

    case Mythweaver.Templates.render(template, state) do
      {text, _state, []} -> String.trim(text)
      {_source, _state, _errors} -> describe_line(attachment)
    end
  end

  @doc """
  Swaps every `Mythweaver.Prompts.AttachmentRef` part of a rendered chat prompt for the part the
  adapter's request contract wants: an image as `model` is sent it (`model_image/1`, with the
  model's `image_detail`), a PDF as a `Request.File`, an audio clip as a `Request.Audio` and a
  video clip as a `Request.Video`, all three their stored bytes. One that cannot be read becomes
  its text line (`describe_line/1`, `file_line/1`). A text prompt carries no parts and is returned
  unchanged.
  """
  def inline_attachments(%{messages: messages} = input, model) do
    %{input | messages: Enum.map(messages, &inline_message(&1, model))}
  end

  def inline_attachments(input, _model), do: input

  defp inline_message(%{content: parts} = message, model) when is_list(parts),
    do: %{message | content: Enum.map(parts, &inline_part(&1, model))}

  defp inline_message(message, _model), do: message

  defp inline_part(%AttachmentRef{attachment: %Attachment{} = a}, model) do
    case model_part(a, model) do
      {:ok, part} ->
        part

      {:error, reason} ->
        Logger.warning("attachment #{a.key} unavailable for a prompt: #{inspect(reason)}")
        %Request.Text{text: if(a.kind == :image, do: describe_line(a), else: file_line(a))}
    end
  end

  defp inline_part(part, _model), do: part

  @doc "The adapter part `model` is sent for `attachment`: an image, PDF, audio or video part."
  @spec model_part(Attachment.t(), Model.t()) :: {:ok, struct()} | {:error, term()}
  def model_part(%Attachment{kind: :image} = a, model), do: image_part(a, model)

  def model_part(%Attachment{content_type: "application/pdf"} = a, _model) do
    with {:ok, bytes} <- read(a),
         do: {:ok, %Request.File{media_type: "application/pdf", filename: a.filename || "document.pdf", data: bytes}}
  end

  def model_part(%Attachment{kind: :audio} = a, _model) do
    with {:ok, bytes} <- read(a), do: {:ok, %Request.Audio{format: audio_format(a.content_type), data: bytes}}
  end

  def model_part(%Attachment{kind: :video} = a, _model) do
    with {:ok, bytes} <- read(a), do: {:ok, %Request.Video{media_type: a.content_type, data: bytes}}
  end

  def model_part(%Attachment{}, _model), do: {:error, :unsupported_type}

  defp audio_format("audio/mpeg"), do: "mp3"
  defp audio_format("audio/wav"), do: "wav"
  defp audio_format("audio/ogg"), do: "ogg"
  defp audio_format("audio/flac"), do: "flac"
  defp audio_format("audio/mp4"), do: "m4a"

  @doc """
  An estimate of the prompt tokens a model spends on a natively sent PDF, audio clip or video
  clip; providers differ and do not document it, so it is only ever an estimate. A PDF counts its
  extracted text plus 500 per page (page images, for providers that send them); audio counts 1
  token per 500 bytes (about 32 tokens a second at 128 kbps). A video counts a flat 2,000: its cost
  follows its length and the frames the backend samples, and neither is stored (a 2-second
  320×240 clip cost llama.cpp about 650). Anything else is 0.
  """
  @spec file_tokens(Attachment.t(), Model.t() | nil) :: non_neg_integer()
  def file_tokens(%Attachment{content_type: "application/pdf"} = a, model),
    do: elem(Tokenizer.count(model, a.text_content), 0) + 500 * (a.page_count || 1)

  def file_tokens(%Attachment{kind: :audio, byte_size: size}, _model), do: div(size || 0, 500)
  def file_tokens(%Attachment{kind: :video}, _model), do: 2_000
  def file_tokens(%Attachment{}, _model), do: 0

  @doc "The adapter image part `model` is sent for `attachment`: `model_image/1` plus its `image_detail`."
  @spec image_part(Attachment.t(), Model.t()) :: {:ok, Request.Image.t()} | {:error, term()}
  def image_part(%Attachment{} = attachment, model) do
    with {:ok, %{media_type: type, data: bytes}} <- model_image(attachment) do
      {:ok, %Request.Image{media_type: type, data: bytes, detail: model.image_detail}}
    end
  end

  @doc """
  Replaces the payload of every base64 `data:` URL in `term` with a byte count, and the base64
  `data` of every `input_audio` part likewise, so a stored request snapshot never carries image,
  file or audio bytes.
  """
  def scrub_data_urls(%{"input_audio" => %{"data" => data} = audio} = term) when is_binary(data) do
    term
    |> Map.delete("input_audio")
    |> scrub_data_urls()
    |> Map.put("input_audio", %{scrub_data_urls(audio) | "data" => "[#{byte_size(data)} bytes omitted]"})
  end

  def scrub_data_urls(term) when is_map(term) and not is_struct(term),
    do: Map.new(term, fn {k, v} -> {k, scrub_data_urls(v)} end)

  def scrub_data_urls(term) when is_list(term), do: Enum.map(term, &scrub_data_urls/1)

  def scrub_data_urls(term) when is_binary(term) do
    case Regex.run(~r/\Adata:([\w.+\/-]+);base64,/, term) do
      [_, media_type] -> "data:#{media_type};base64,[#{byte_size(term)} bytes omitted]"
      nil -> term
    end
  end

  def scrub_data_urls(term), do: term

  @doc "The PubSub topic caption results for a chat's attachments go out on."
  def topic(chat_id), do: "attachments:#{chat_id}"

  def subscribe(chat_id), do: Phoenix.PubSub.subscribe(Mythweaver.PubSub, topic(chat_id))

  def unsubscribe(chat_id), do: Phoenix.PubSub.unsubscribe(Mythweaver.PubSub, topic(chat_id))

  @doc """
  Asks whoever has `chat_id` open for an image: every open tab of the chat shows a dialog with
  `prompt` and a Choose image button (a browser opens a file picker only from a click, so a script
  cannot open one itself). The first image attached in any tab fulfils the request and closes it
  everywhere. It goes to the composer like any upload, and the tag and data under `callback` (a
  `Mythweaver.Scripts.CallbackStore` key) come back on its `image_described` run. With `avatar:
  %{character_id:, name:, describe?:}` it instead becomes that character's avatar
  (`set_avatar/3`, `describe:` from `describe?`). A newer request replaces an open one. Nothing is
  stored: a tab opened later does not see it.

  Broadcasts `{:image_requested, %{id:, prompt:, callback:, avatar:}}` on `topic/1`; returns the
  request id.
  """
  @spec request_image(Ecto.UUID.t(), String.t() | nil, String.t() | nil, avatar: map()) :: Ecto.UUID.t()
  def request_image(chat_id, prompt, callback, opts \\ []) do
    id = Mythweaver.Schema.generate_id()
    request = %{id: id, prompt: prompt, callback: callback, avatar: opts[:avatar]}
    Phoenix.PubSub.broadcast(Mythweaver.PubSub, topic(chat_id), {:image_requested, request})
    id
  end

  @doc "Closes image request `id` in every tab of the chat (fulfilled or dismissed)."
  @spec close_image_request(Ecto.UUID.t(), Ecto.UUID.t()) :: :ok
  def close_image_request(chat_id, id),
    do: Phoenix.PubSub.broadcast(Mythweaver.PubSub, topic(chat_id), {:image_request_closed, id})

  @doc "The PubSub topic a character's avatar description (`{:appearance_updated, id}`) goes out on."
  def character_topic(character_id), do: "attachments:character:#{character_id}"

  @doc "Tells an open character editor that `character_id`'s `appearance` changed."
  @spec broadcast_appearance_updated(Ecto.UUID.t()) :: :ok
  def broadcast_appearance_updated(character_id),
    do: Phoenix.PubSub.broadcast(Mythweaver.PubSub, character_topic(character_id), {:appearance_updated, character_id})

  @doc """
  Raises `ArgumentError`, naming the env var to set, when the configured storage or proxy is missing
  a setting it needs. Called first thing at boot.
  """
  def validate_config! do
    config = config()
    window = config[:link_window_seconds]

    if !(is_integer(window) and window > 0),
      do: raise(ArgumentError, "MYTHWEAVER_IMAGE_LINK_WINDOW must be a positive number of seconds")

    if config[:storage] == :s3 do
      s3 = config[:s3] || []

      for {field, var} <- [
            bucket: "MYTHWEAVER_S3_BUCKET (or BUCKET_NAME)",
            access_key_id: "AWS_ACCESS_KEY_ID",
            secret_access_key: "AWS_SECRET_ACCESS_KEY"
          ],
          blank?(s3[field]) do
        raise ArgumentError, "S3 attachment storage needs #{var}"
      end

      # A link lives up to two windows, and S3 refuses a presigned link valid for over 7 days.
      if 2 * window > 604_800,
        do: raise(ArgumentError, "with S3 storage MYTHWEAVER_IMAGE_LINK_WINDOW must be at most 302400 (3.5 days)")
    end

    case config[:proxy] do
      :xtandard ->
        validate_xtandard!(config[:xtandard] || [], config[:storage])

      :cloudflare ->
        if blank?(config[:cloudflare][:zone_url]),
          do: raise(ArgumentError, "the Cloudflare image proxy needs MYTHWEAVER_CLOUDFLARE_ZONE_URL")

      :fastly ->
        if config[:storage] == :s3 and blank?(config[:fastly][:base_url]),
          do: raise(ArgumentError, "the Fastly image proxy over S3 storage needs MYTHWEAVER_FASTLY_BASE_URL")

      _ ->
        :ok
    end

    if config[:storage] == :local and config[:proxy] in [:cloudflare, :fastly] and
         blank?(config[:uploads_origin_secret]) do
      raise ArgumentError,
            "the #{config[:proxy]} image proxy over local storage needs MYTHWEAVER_UPLOADS_ORIGIN_SECRET, " <>
              "sent by the CDN as x-mythweaver-origin-secret on what it forwards to /uploads"
    end

    :ok
  end

  defp validate_xtandard!(cfg, storage) do
    if blank?(cfg[:base_url]), do: raise(ArgumentError, "the xtandard image proxy needs MYTHWEAVER_XI_URL")

    if storage == :local and blank?(cfg[:source_prefix]) do
      raise ArgumentError,
            "xtandard-image cannot fetch locally stored images by URL; set MYTHWEAVER_XI_SOURCE_PREFIX (e.g. xi://uploads/)"
    end

    if !(hex?(cfg[:key]) and hex?(cfg[:salt])) do
      raise ArgumentError,
            "the xtandard image proxy needs hex MYTHWEAVER_XI_KEY and MYTHWEAVER_XI_SALT " <>
              "(and xi's XI_SIGNING_KEYS/XI_SIGNING_SALTS set to the same values)"
    end

    if !(hex?(cfg[:encryption_key]) and
           byte_size(Base.decode16!(cfg[:encryption_key], case: :mixed)) in [16, 24, 32]) do
      raise ArgumentError,
            "the xtandard image proxy needs MYTHWEAVER_XI_ENCRYPTION_KEY: hex of 16, 24 or 32 bytes " <>
              "(and xi's XI_ENCRYPTION_KEYS set to the same value)"
    end
  end

  defp hex?(value), do: is_binary(value) and value != "" and match?({:ok, _}, Base.decode16(value, case: :mixed))

  defp blank?(value), do: value in [nil, ""]
end
