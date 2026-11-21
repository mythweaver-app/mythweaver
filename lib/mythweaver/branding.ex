defmodule Mythweaver.Branding do
  @moduledoc """
  The installation's name and logo, fixed when the app is compiled.

  `config/config.exs` reads them from `MYTHWEAVER_NAME` and `MYTHWEAVER_LOGO_PATH` (an SVG file,
  absolute or relative to the project root). Mix recompiles this module when either changes; a
  running release never sees a new value. `assets/build.ts` writes the PWA manifest's name from the
  same variable by the same rule.
  """

  @default_name "Mythweaver"
  @root Path.expand("../..", __DIR__)

  @config Application.compile_env!(:mythweaver, __MODULE__)
  @name Keyword.fetch!(@config, :name)
  @logo_path Path.expand(Keyword.fetch!(@config, :logo_path), @root)
  @external_resource @logo_path

  @logo_svg (case File.read(@logo_path) do
               {:ok, svg} ->
                 if svg =~ "<svg",
                   do: svg,
                   else: raise(ArgumentError, "MYTHWEAVER_LOGO_PATH: #{@logo_path} is not an SVG")

               {:error, reason} ->
                 raise ArgumentError,
                       "MYTHWEAVER_LOGO_PATH: cannot read #{@logo_path}: #{:file.format_error(reason)}"
             end)

  # Mix recompiles on a change to a config *file*, not to the env var a file reads; without this a
  # new MYTHWEAVER_NAME/MYTHWEAVER_LOGO_PATH fails Mix's compile-env check instead of recompiling.
  @doc false
  def __mix_recompile__?, do: Application.get_env(:mythweaver, __MODULE__) != @config

  @doc "The installation's name."
  @spec name() :: String.t()
  def name, do: @name

  @doc "Whether the name is the stock one; only then does the top bar add its α mark."
  @spec default_name?() :: boolean()
  def default_name?, do: @name == @default_name

  @doc "The logo's SVG markup, inlined by `MythweaverWeb.CoreComponents.logo/1`."
  @spec logo_svg() :: String.t()
  def logo_svg, do: @logo_svg
end
