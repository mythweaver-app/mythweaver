defmodule Mythweaver.Gettext do
  @moduledoc """
  The app's Gettext backend. Catalogs live in `priv/gettext/`: one `<domain>.pot` per app area plus
  `errors`, and one `<locale>/LC_MESSAGES/<domain>.po` per translated locale. Core contexts use it
  too (notifications, job errors), so it sits outside `MythweaverWeb`.

      use Gettext, backend: Mythweaver.Gettext

      pgettext("button: save the open form", "Save")
      dpgettext("lore", "field label: name of a lore book", "Name")

  The active locale is set per process by `Mythweaver.Locale`; extraction rules (contexts,
  placeholders, plurals) are enforced by `test/mythweaver/gettext_catalog_test.exs`.
  """
  use Gettext.Backend, otp_app: :mythweaver
end
