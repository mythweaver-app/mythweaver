defmodule Mythweaver.Attachments.Storage do
  @moduledoc """
  Behaviour every attachment byte store satisfies, and the registry of them.

  A key is an opaque, immutable object path (`"attachments/<uuid>.png"`); a backend never invents
  one. The active backend comes from `config :mythweaver, Mythweaver.Attachments, storage: …`, but a
  row records the backend it was written to, so reads always go through `module_for(row.storage)`.

  Add a backend by writing the module, adding one `{atom, module}` pair to `@backends` below, and
  adding the same atom to `Mythweaver.Attachments.Attachment`'s `:storage` enum.
  """

  alias Mythweaver.Attachments
  alias Mythweaver.Attachments.Storage.Local
  alias Mythweaver.Attachments.Storage.S3

  @callback put_file(key :: String.t(), path :: Path.t(), content_type :: String.t()) :: :ok | {:error, term()}
  @callback put_binary(key :: String.t(), binary(), content_type :: String.t()) :: :ok | {:error, term()}
  @callback read(key :: String.t()) :: {:ok, binary()} | {:error, term()}
  @callback read_head(key :: String.t(), bytes :: pos_integer()) :: {:ok, binary()} | {:error, term()}
  @callback stat(key :: String.t()) :: {:ok, %{byte_size: non_neg_integer()}} | {:error, :not_found | term()}
  @callback delete(key :: String.t()) :: :ok | {:error, term()}
  @doc """
  A link a browser (or an image proxy) fetches the object at, valid from `signed_at` until
  `expires_at` (unix seconds) and no longer. May be relative to this app's origin.
  """
  @callback signed_url(key :: String.t(), signed_at :: integer(), expires_at :: integer()) :: String.t()
  @doc "A browser-direct upload form, for backends that support one."
  @callback presign_upload(key :: String.t(), content_type :: String.t(), max_bytes :: pos_integer()) ::
              {:ok, %{url: String.t(), fields: [{String.t(), String.t()}]}} | {:error, :unsupported}

  @backends %{local: Local, s3: S3}

  @doc "The implementation module for a registered backend atom."
  def module_for(backend) when is_map_key(@backends, backend), do: Map.fetch!(@backends, backend)

  @doc "The full `%{atom => module}` registry."
  def backends, do: @backends

  @doc "The backend new attachments are written to."
  def active, do: Attachments.config()[:storage]
end
