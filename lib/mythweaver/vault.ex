defmodule Mythweaver.Vault do
  @moduledoc """
  Encrypts secrets at rest (`Mythweaver.Encrypted.Binary`): today, AI connection API keys.

  AES-256-GCM only, which authenticates each ciphertext, so a tampered value fails to decrypt
  instead of decrypting to something else. The key is `config :mythweaver, Mythweaver.Vault, key:`, a
  base64 string of 32 bytes: fixed and public in dev and test, `MYTHWEAVER_VAULT_KEY` in prod
  (`config/runtime.exs`). Losing it loses every stored key; changing it means adding the new key as
  the default cipher, keeping the old one under its own tag, and re-encrypting.
  """

  use Cloak.Vault, otp_app: :mythweaver

  alias Cloak.Ciphers.AES.GCM

  @impl GenServer
  def init(config) do
    key = config |> Keyword.fetch!(:key) |> Base.decode64!()
    if byte_size(key) != 32, do: raise(ArgumentError, "the vault key must be 32 bytes, base64-encoded")

    {:ok, Keyword.put(config, :ciphers, default: {GCM, tag: "AES.GCM.V1", key: key, iv_length: 12})}
  end
end
