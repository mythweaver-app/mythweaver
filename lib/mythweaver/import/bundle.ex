defmodule Mythweaver.Import.Bundle do
  @moduledoc """
  Parses a native `.mythweaver` file (`Mythweaver.Bundle.decode/1`) into the import's parsed shape;
  `Mythweaver.Import.Review` and `Mythweaver.Import.BundleWriter` take it from there.
  """

  alias Mythweaver.Bundle

  @spec parse(binary()) :: {:ok, Mythweaver.Import.bundle()} | {:error, String.t()}
  def parse(bytes) when is_binary(bytes) do
    with {:ok, %Bundle{} = bundle} <- Bundle.decode(bytes) do
      {:ok, %{kind: :bundle, name: bundle.meta["title"], bundle: bundle, warnings: []}}
    end
  end
end
