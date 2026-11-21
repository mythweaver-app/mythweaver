defmodule Mythweaver.Encrypted.Binary do
  @moduledoc "An Ecto type stored as a `:binary` column, encrypted by `Mythweaver.Vault` and decrypted on load."

  use Cloak.Ecto.Binary, vault: Mythweaver.Vault
end
