defmodule MythweaverWeb.Uploads do
  @moduledoc """
  LiveView uploads, the same way on every screen: images only (`allow_images/4`, avatars and the
  palette) or any file (`allow_files/4`, the chat composer).

  With local storage LiveView streams the file to a temp path and `consume_image/2`/`consume_file/2`
  store it; with the S3 backend the browser posts straight to the bucket through a presigned form
  (the `S3` uploader in `assets/js/uploaders.ts`) and the same calls check what arrived.
  """

  use Gettext, backend: Mythweaver.Gettext

  import Phoenix.LiveView

  alias Mythweaver.Attachments
  alias Mythweaver.Attachments.Attachment
  alias Phoenix.LiveView.Socket
  alias Phoenix.LiveView.UploadEntry

  @doc """
  Allows `max_entries` images under `name`, uploading as soon as they are picked. `opts` passes
  through to `allow_upload/3` (e.g. `:progress`, to consume each entry as it finishes).
  """
  def allow_images(socket, name, max_entries, opts \\ []),
    do:
      allow(
        socket,
        name,
        Keyword.merge([accept: ~w(.png .jpg .jpeg .webp), max_entries: max_entries], opts),
        &presign_image/2
      )

  @doc """
  Allows `max_entries` files of any type under `name`, like `allow_images/4`. What each file is
  decides how it is stored and shown (`Mythweaver.Attachments.FileInfo`), and whether the user may
  upload it (`Mythweaver.Attachments.upload_permission/1`).
  """
  def allow_files(socket, name, max_entries, opts \\ []),
    do: allow(socket, name, Keyword.merge([accept: :any, max_entries: max_entries], opts), &presign_file/2)

  defp allow(socket, name, opts, presign) do
    opts = Keyword.merge([max_file_size: Attachments.max_upload_bytes(), auto_upload: true], opts)
    opts = if Attachments.presigned_uploads?(), do: Keyword.put(opts, :external, presign), else: opts
    allow_upload(socket, name, opts)
  end

  @doc false
  def presign_image(entry, socket), do: presign(entry, socket, [:image])

  @doc false
  def presign_file(entry, socket), do: presign(entry, socket, Attachment.kinds())

  defp presign(entry, socket, kinds) do
    case Attachments.prepare_presigned_upload(socket.assigns.current_scope, entry.client_type, entry.client_size,
           filename: entry.client_name,
           kinds: kinds
         ) do
      {:ok, m} -> {:ok, %{uploader: "S3", url: m.url, fields: m.fields, attachment_id: m.attachment_id}, socket}
      {:error, reason} -> {:error, %{reason: reason}, socket}
    end
  end

  @doc """
  Consumes every finished image entry of `name` into attachments. Returns the stored attachments
  and the client names of the entries that could not be stored.
  """
  @spec consume_images(Socket.t(), atom()) :: {[Attachment.t()], [String.t()]}
  def consume_images(socket, name) do
    socket
    |> consume_uploaded_entries(name, fn meta, entry ->
      {:ok, {entry.client_name, store(socket, meta, entry, [:image])}}
    end)
    |> Enum.reduce({[], []}, fn
      {_name, {:ok, attachment}}, {ok, failed} -> {[attachment | ok], failed}
      {client_name, {:error, _reason}}, {ok, failed} -> {ok, [client_name | failed]}
    end)
    |> then(fn {ok, failed} -> {Enum.reverse(ok), Enum.reverse(failed)} end)
  end

  @doc """
  Consumes one finished entry into an image attachment (for an `allow_images/4` `:progress`
  callback); anything else is refused with `:unsupported_type`.
  """
  @spec consume_image(Socket.t(), UploadEntry.t()) ::
          {:ok, Attachment.t()} | {:error, term()}
  def consume_image(socket, entry),
    do: consume_uploaded_entry(socket, entry, &{:ok, store(socket, &1, entry, [:image])})

  @doc "Consumes one finished entry into an attachment of any kind (for an `allow_files/4` callback)."
  @spec consume_file(Socket.t(), UploadEntry.t()) ::
          {:ok, Attachment.t()} | {:error, term()}
  def consume_file(socket, entry),
    do: consume_uploaded_entry(socket, entry, &{:ok, store(socket, &1, entry, Attachment.kinds())})

  defp store(socket, %{path: path}, entry, kinds),
    do: Attachments.store_file(socket.assigns.current_scope, path, filename: entry.client_name, kinds: kinds)

  # A presigned row's kind was checked against the input's kinds when it was prepared, but one
  # upload can be consumed more narrowly (a composer file taken as an avatar), so check again.
  defp store(socket, %{attachment_id: id}, entry, kinds) do
    scope = socket.assigns.current_scope

    case Attachments.finalize_presigned_upload(scope, id, entry.client_name) do
      {:ok, %Attachment{kind: kind} = attachment} ->
        if kind in kinds do
          {:ok, attachment}
        else
          Attachments.delete_unlinked(scope, [attachment.id])
          {:error, :unsupported_type}
        end

      error ->
        error
    end
  end

  @doc "The message shown for an upload error."
  def error_text(:too_large) do
    limit = Mythweaver.Format.megabytes(div(Attachments.max_upload_bytes(), 1_000_000))
    gettext_comment("Upload error; the placeholder is a file size with its unit, e.g. \"20 MB\".")
    gettext("File is larger than %{size_limit}", size_limit: limit)
  end

  def error_text(:not_accepted), do: gettext("Only PNG, JPEG and WebP images can be attached")
  def error_text(:too_many_files), do: pgettext("status: upload error, too many files picked", "Too many files")
  def error_text(:unsupported_type), do: gettext("That file type can't be attached here")
  def error_text(:not_permitted), do: gettext("You don't have permission to upload that kind of file")
  def error_text(:quota_exceeded), do: gettext("You've used your upload storage")
  def error_text(_other), do: pgettext("status: a file upload", "Upload failed")
end
