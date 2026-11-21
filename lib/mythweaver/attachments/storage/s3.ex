defmodule Mythweaver.Attachments.Storage.S3 do
  @moduledoc """
  Attachment bytes in an S3-compatible bucket (AWS S3, Tigris, MinIO), configured under
  `config :mythweaver, Mythweaver.Attachments, s3: [...]`.

  Objects are read through presigned GET links (`signed_url/3`), so the bucket can stay private; its
  CORS (allowing `POST` from the app origin, for `presign_upload/3`) is the admin's to configure.
  Browser uploads use an S3 POST policy, which enforces the size and content type server-side.

  `:attachments_req_options` is the `Req.Test` seam: `config/test.exs` sets
  `plug: {Req.Test, Mythweaver.Attachments.Storage.S3}`.
  """

  @behaviour Mythweaver.Attachments.Storage

  alias Mythweaver.Attachments

  @impl true
  def put_file(key, path, content_type) do
    with {:ok, body} <- File.read(path), do: put_binary(key, body, content_type)
  end

  @impl true
  def put_binary(key, binary, content_type) do
    client()
    |> Req.put(url: url(key), body: binary, headers: [{"content-type", content_type}])
    |> status(fn _ -> :ok end)
  end

  @impl true
  def read(key) do
    client()
    |> Req.get(url: url(key), decode_body: false)
    |> status(fn resp -> {:ok, resp.body} end)
  end

  @impl true
  def read_head(key, bytes) do
    client()
    |> Req.get(url: url(key), decode_body: false, headers: [{"range", "bytes=0-#{bytes - 1}"}])
    |> status(fn resp -> {:ok, resp.body} end)
  end

  @impl true
  def stat(key) do
    case Req.head(client(), url: url(key)) do
      {:ok, %{status: 404}} ->
        {:error, :not_found}

      result ->
        status(result, fn resp ->
          size = resp |> Req.Response.get_header("content-length") |> List.first("0") |> String.to_integer()
          {:ok, %{byte_size: size}}
        end)
    end
  end

  @impl true
  def delete(key) do
    case Req.delete(client(), url: url(key)) do
      {:ok, %{status: 404}} -> :ok
      result -> status(result, fn _ -> :ok end)
    end
  end

  # Signed as of `signed_at` (the window's start, not now), so every link issued in one window is the
  # same string and stays cacheable. S3 caps a presigned link at 7 days (`validate_config!/0`).
  @impl true
  def signed_url(key, signed_at, expires_at) do
    ReqS3.presign_url(
      [key: key, datetime: DateTime.from_unix!(signed_at), expires: expires_at - signed_at] ++ presign_opts()
    )
  end

  @impl true
  def presign_upload(key, content_type, max_bytes) do
    form =
      ReqS3.presign_form(
        [key: key, content_type: content_type, max_size: max_bytes, expires_in: to_timeout(minute: 30)] ++
          presign_opts()
      )

    {:ok, form}
  end

  defp presign_opts do
    cfg = cfg()

    [
      bucket: cfg[:bucket],
      region: cfg[:region],
      endpoint_url: cfg[:endpoint_url],
      access_key_id: cfg[:access_key_id],
      secret_access_key: cfg[:secret_access_key]
    ]
  end

  defp status({:ok, %Req.Response{status: s} = resp}, fun) when s in 200..299, do: fun.(resp)
  defp status({:ok, %Req.Response{status: s}}, _fun), do: {:error, {:http_error, s}}
  defp status({:error, reason}, _fun), do: {:error, reason}

  defp url(key), do: "s3://#{cfg()[:bucket]}/#{key}"

  defp cfg, do: Attachments.config()[:s3] || []

  # Retries off: a failed write is reported, not silently repeated.
  defp client do
    cfg = cfg()

    [retry: false]
    |> Req.new()
    |> ReqS3.attach(
      aws_sigv4: [
        access_key_id: cfg[:access_key_id],
        secret_access_key: cfg[:secret_access_key],
        region: cfg[:region]
      ],
      aws_endpoint_url_s3: cfg[:endpoint_url]
    )
    |> Req.merge(Application.get_env(:mythweaver, :attachments_req_options, []))
  end
end
