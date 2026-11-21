defmodule Mythweaver.Attachments.Storage.Local do
  @moduledoc """
  Attachment bytes on the local filesystem under `local.root`, served by
  `MythweaverWeb.UploadController` at `/uploads/<token>`. The link is the credential, not a session,
  so an image proxy or CDN fetching it from the app works too.

  The token seals the storage key and the expiry with AES-256-GCM (`open/1`), under keys derived
  from the endpoint's `secret_key_base`: the link reveals neither, and changing a byte of it fails
  the tag. The nonce is derived from what it seals (an HMAC), not random, so one key gives one link
  per link window and caches can keep it; two different plaintexts never share a nonce. No
  browser-direct uploads: LiveView streams the bytes.
  """

  @behaviour Mythweaver.Attachments.Storage

  alias Mythweaver.Attachments
  alias Plug.Crypto.KeyGenerator
  alias Plug.Crypto.Keys

  @doc "The absolute storage root."
  def root, do: Path.expand(Attachments.config()[:local][:root])

  @doc "The file holding `key`'s bytes."
  def path(key), do: Path.join(root(), key)

  @aad "mythweaver attachment link v1"

  @doc """
  The storage key and expiry (unix seconds) a `signed_url/3` token seals, or `:error` for a token
  that is malformed, forged, altered or expired.
  """
  @spec open(String.t()) :: {:ok, String.t(), integer()} | :error
  def open(token) when is_binary(token) do
    with {:ok, <<nonce::binary-12, tag::binary-16, ciphertext::binary>>} <- Base.url_decode64(token, padding: false),
         <<expires_at::64, key::binary>> <-
           :crypto.crypto_one_time_aead(:aes_256_gcm, cipher_key(), nonce, ciphertext, @aad, tag, false),
         true <- expires_at > System.os_time(:second) do
      {:ok, key, expires_at}
    else
      _ -> :error
    end
  end

  @impl true
  def put_file(key, path, _content_type) do
    dest = path(key)
    File.mkdir_p!(Path.dirname(dest))
    File.cp(path, dest)
  end

  @impl true
  def put_binary(key, binary, _content_type) do
    dest = path(key)
    File.mkdir_p!(Path.dirname(dest))
    File.write(dest, binary)
  end

  @impl true
  def read(key), do: File.read(path(key))

  @impl true
  def read_head(key, bytes) do
    with {:ok, io} <- File.open(path(key), [:read, :binary]) do
      try do
        case IO.binread(io, bytes) do
          data when is_binary(data) -> {:ok, data}
          :eof -> {:ok, ""}
          {:error, reason} -> {:error, reason}
        end
      after
        File.close(io)
      end
    end
  end

  @impl true
  def stat(key) do
    case File.stat(path(key)) do
      {:ok, %File.Stat{size: size}} -> {:ok, %{byte_size: size}}
      {:error, :enoent} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def delete(key) do
    case File.rm(path(key)) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def signed_url(key, _signed_at, expires_at), do: "/uploads/" <> seal(key, expires_at)

  defp seal(key, expires_at) do
    plaintext = <<expires_at::64, key::binary>>
    nonce = :hmac |> :crypto.mac(:sha256, nonce_key(), plaintext) |> binary_part(0, 12)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, cipher_key(), nonce, plaintext, @aad, 16, true)

    Base.url_encode64(nonce <> tag <> ciphertext, padding: false)
  end

  defp cipher_key, do: derive("attachment links cipher")
  defp nonce_key, do: derive("attachment links nonce")

  defp derive(salt) do
    :mythweaver
    |> Application.fetch_env!(MythweaverWeb.Endpoint)
    |> Keyword.fetch!(:secret_key_base)
    |> KeyGenerator.generate(salt, cache: Keys)
  end

  @impl true
  def presign_upload(_key, _content_type, _max_bytes), do: {:error, :unsupported}
end
