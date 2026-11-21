formatters =
  if System.get_env("CI"), do: [JUnitFormatter, ExUnit.CLIFormatter], else: [ExUnit.CLIFormatter]

ExUnit.start(formatters: formatters)
# The fixture GeoLite2 databases (`config/test.exs`) load in the background at boot.
:ok = Mythweaver.Moderation.GeoIP.await(30_000)
Ecto.Adapters.SQL.Sandbox.mode(Mythweaver.Repo, :manual)
