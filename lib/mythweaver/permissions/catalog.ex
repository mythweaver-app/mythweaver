defmodule Mythweaver.Permissions.Catalog do
  @moduledoc """
  The fixed list of permission keys groups and users are granted (`Mythweaver.Permissions`).

  A `:flag` is on or off and defaults off; a `:limit` is a non-negative integer (`unit` `:count`,
  `:cents` (US cents, entered and shown as dollars) or `:bytes`) and defaults unlimited. `all/0` is
  in display order, grouped by `category`.
  """

  use Gettext, backend: Mythweaver.Gettext

  @type kind :: :flag | :limit
  @type unit :: :count | :cents | :bytes
  @type entry :: %{
          key: String.t(),
          kind: kind(),
          category: String.t(),
          label: String.t(),
          description: String.t(),
          unit: unit() | nil
        }

  @entries [
    {dpgettext_noop("admin", "permission category", "Content"), :flag, nil,
     [
       {"content.characters.create",
        dpgettext_noop("admin", "permission name: content.characters.create", "Create own characters"),
        dpgettext_noop(
          "admin",
          "permission description: content.characters.create",
          "Keep characters only the user sees and edits."
        )},
       {"content.lore.create",
        dpgettext_noop("admin", "permission name: content.lore.create", "Create own lore (books, entries, pools)"),
        dpgettext_noop(
          "admin",
          "permission description: content.lore.create",
          "Keep lore books, entries and pools only the user sees and edits."
        )},
       {"content.prompts.create",
        dpgettext_noop("admin", "permission name: content.prompts.create", "Create own prompts, blocks and outlets"),
        dpgettext_noop(
          "admin",
          "permission description: content.prompts.create",
          "Keep prompts, prompt blocks and outlets only the user sees and edits."
        )},
       {"content.scripts.create",
        dpgettext_noop("admin", "permission name: content.scripts.create", "Create own scripts"),
        dpgettext_noop(
          "admin",
          "permission description: content.scripts.create",
          "Keep scripts only the user sees and edits."
        )},
       {"content.memory.create",
        dpgettext_noop(
          "admin",
          "permission name: content.memory.create",
          "Create own memory profiles and side prompts"
        ),
        dpgettext_noop(
          "admin",
          "permission description: content.memory.create",
          "Keep memory profiles, side prompts and side prompt sets only the user sees and edits."
        )},
       {"content.variables.create",
        dpgettext_noop("admin", "permission name: content.variables.create", "Create own global variables"),
        dpgettext_noop(
          "admin",
          "permission description: content.variables.create",
          "Keep global variables only the user sees and edits."
        )},
       {"content.tags.create", dpgettext_noop("admin", "permission name: content.tags.create", "Create own tags"),
        dpgettext_noop(
          "admin",
          "permission description: content.tags.create",
          "Keep tags, siblings and parents only the user sees, and tag anything they can see."
        )}
     ]},
    {dpgettext_noop("admin", "permission category", "AI"), :flag, nil,
     [
       {"ai.connections.create",
        dpgettext_noop("admin", "permission name: ai.connections.create", "Add own AI connections and models"),
        dpgettext_noop(
          "admin",
          "permission description: ai.connections.create",
          "Add AI connections and models that only the user sees and runs."
        )},
       {"ai.site_models.use",
        dpgettext_noop("admin", "permission name: ai.site_models.use", "Use the site's AI models"),
        dpgettext_noop(
          "admin",
          "permission description: ai.site_models.use",
          "Run the site's AI connections and models; off, only the user's own models work."
        )}
     ]},
    {dpgettext_noop("admin", "permission category", "MCP"), :flag, nil,
     [
       {"mcp.use", dpgettext_noop("admin", "permission name: mcp.use", "Connect AI tools over MCP"),
        dpgettext_noop(
          "admin",
          "permission description: mcp.use",
          "Create MCP access tokens and use Mythweaver's tools from outside AI clients (Claude, Cursor and others) with them."
        )}
     ]},
    {dpgettext_noop("admin", "permission category", "Uploads"), :flag, nil,
     [
       {"uploads.images", dpgettext_noop("admin", "permission name: uploads.images", "Upload images"),
        dpgettext_noop(
          "admin",
          "permission description: uploads.images",
          "Attach PNG, JPEG and WebP images to messages, and upload avatars."
        )},
       {"uploads.documents", dpgettext_noop("admin", "permission name: uploads.documents", "Upload documents"),
        dpgettext_noop(
          "admin",
          "permission description: uploads.documents",
          "Attach PDFs and text or Markdown files to messages; models read their text, or the PDF itself."
        )},
       {"uploads.audio", dpgettext_noop("admin", "permission name: uploads.audio", "Upload audio"),
        dpgettext_noop(
          "admin",
          "permission description: uploads.audio",
          "Attach audio clips to messages; models that hear audio get the clip."
        )},
       {"uploads.video", dpgettext_noop("admin", "permission name: uploads.video", "Upload video"),
        dpgettext_noop(
          "admin",
          "permission description: uploads.video",
          "Attach video clips to messages, played in the chat; models that watch video get the clip."
        )},
       {"uploads.files", dpgettext_noop("admin", "permission name: uploads.files", "Upload other files"),
        dpgettext_noop(
          "admin",
          "permission description: uploads.files",
          "Attach any other file to messages, offered as a download; models see only its name."
        )}
     ]},
    {dpgettext_noop("admin", "permission category", "Sharing"), :flag, nil,
     [
       {"sharing.invite", dpgettext_noop("admin", "permission name: sharing.invite", "Share own content with others"),
        dpgettext_noop(
          "admin",
          "permission description: sharing.invite",
          "Invite other accounts by handle to edit the user's characters, lore, prompts, scripts and memory items."
        )},
       {"chats.invite", dpgettext_noop("admin", "permission name: chats.invite", "Invite others to chats"),
        dpgettext_noop(
          "admin",
          "permission description: chats.invite",
          "Invite other accounts by handle into the user's chats, as chat editors or guests."
        )},
       {"sharing.ai.owner_key",
        dpgettext_noop("admin", "permission name: sharing.ai.owner_key", "Share models on own connections"),
        dpgettext_noop(
          "admin",
          "permission description: sharing.ai.owner_key",
          "Let subscribers' runs on a shared model use this user's own AI connections and spend their key."
        )},
       {"catalog.publish", dpgettext_noop("admin", "permission name: catalog.publish", "Publish to the catalog"),
        dpgettext_noop(
          "admin",
          "permission description: catalog.publish",
          "Publish the user's own characters, lore, prompts, scripts and memory items to the catalog for anyone to subscribe to."
        )}
     ]},
    {dpgettext_noop("admin", "permission category", "Administration"), :flag, nil,
     [
       {"site.content.manage",
        dpgettext_noop(
          "admin",
          "permission name: site.content.manage",
          "Manage site content (characters, lore, prompts, scripts, memory, variables)"
        ),
        dpgettext_noop(
          "admin",
          "permission description: site.content.manage",
          "Create and edit the site's shared characters, lore, prompts, scripts, memory and variables."
        )},
       {"site.ai.manage",
        dpgettext_noop("admin", "permission name: site.ai.manage", "Manage site AI connections and models"),
        dpgettext_noop(
          "admin",
          "permission description: site.ai.manage",
          "Create and edit the site's shared AI connections and models."
        )},
       {"site.settings.manage",
        dpgettext_noop("admin", "permission name: site.settings.manage", "Change site settings and lock user settings"),
        dpgettext_noop(
          "admin",
          "permission description: site.settings.manage",
          "Change site-wide setting defaults and lock settings users may not override."
        )},
       {"site.cleanup.run", dpgettext_noop("admin", "permission name: site.cleanup.run", "Clean up every user's chats"),
        dpgettext_noop(
          "admin",
          "permission description: site.cleanup.run",
          "Run the message cleanup over every chat in the app, with the site's cleanup settings."
        )},
       {"site.hidden.view",
        dpgettext_noop("admin", "permission name: site.hidden.view", "See runtime-only and hidden site content"),
        dpgettext_noop(
          "admin",
          "permission description: site.hidden.view",
          "See the protected content of site items hidden from users: runtime-only characters, prompts, blocks and scripts, and runtime-only or hidden lore."
        )},
       {"analytics.all.view",
        dpgettext_noop("admin", "permission name: analytics.all.view", "See every user's analytics"),
        dpgettext_noop(
          "admin",
          "permission description: analytics.all.view",
          "See generation analytics for every account."
        )},
       {"catalog.feature",
        dpgettext_noop("admin", "permission name: catalog.feature", "Choose featured catalog listings"),
        dpgettext_noop("admin", "permission description: catalog.feature", "Feature and unfeature catalog listings.")}
     ]},
    {dpgettext_noop("admin", "permission category", "Moderation"), :flag, nil,
     [
       {"reports.create", dpgettext_noop("admin", "permission name: reports.create", "Report content"),
        dpgettext_noop(
          "admin",
          "permission description: reports.create",
          "Report catalog listings, accounts and chat messages to the moderators. Everyone holds it by default; deny it for Everyone to turn reporting off."
        )},
       {"users.manage", dpgettext_noop("admin", "permission name: users.manage", "Manage accounts"),
        dpgettext_noop(
          "admin",
          "permission description: users.manage",
          "Create, edit, reset and delete accounts other than owners."
        )},
       {"groups.manage", dpgettext_noop("admin", "permission name: groups.manage", "Manage groups and permissions"),
        dpgettext_noop(
          "admin",
          "permission description: groups.manage",
          "Create groups, set their permissions and members, and set users' own permissions."
        )},
       {"moderation.reports", dpgettext_noop("admin", "permission name: moderation.reports", "Review reports"),
        dpgettext_noop(
          "admin",
          "permission description: moderation.reports",
          "See reported catalog listings, accounts and messages, and dismiss reports."
        )},
       {"moderation.content.view",
        dpgettext_noop("admin", "permission name: moderation.content.view", "Look up any content"),
        dpgettext_noop(
          "admin",
          "permission description: moderation.content.view",
          "Look up and read any account's chats, messages and content by link, id or handle. Every look is written to the moderation log."
        )},
       {"moderation.content.delete",
        dpgettext_noop("admin", "permission name: moderation.content.delete", "Remove content"),
        dpgettext_noop(
          "admin",
          "permission description: moderation.content.delete",
          "Delete any account's chats, messages and content, take down catalog listings, and move users' lore books to the site (with site content management)."
        )},
       {"moderation.accounts.sanction",
        dpgettext_noop("admin", "permission name: moderation.accounts.sanction", "Warn and suspend accounts"),
        dpgettext_noop(
          "admin",
          "permission description: moderation.accounts.sanction",
          "Warn accounts other than owners, suspend them for a time or for good, and lift suspensions."
        )},
       {"moderation.fingerprints",
        dpgettext_noop("admin", "permission name: moderation.fingerprints", "See and ban devices and networks"),
        dpgettext_noop(
          "admin",
          "permission description: moderation.fingerprints",
          "See an account's IP addresses, browsers, devices and the accounts that share them, and ban devices, browser fingerprints and IP addresses."
        )},
       {"moderation.log.view",
        dpgettext_noop("admin", "permission name: moderation.log.view", "Read the moderation log"),
        dpgettext_noop(
          "admin",
          "permission description: moderation.log.view",
          "See every moderation action and every look at private content."
        )},
       {"moderation.review",
        dpgettext_noop("admin", "permission name: moderation.review", "Review flagged and held content"),
        dpgettext_noop(
          "admin",
          "permission description: moderation.review",
          "See content the moderation rules flagged and content held for review; approve, reject or dismiss it."
        )},
       {"moderation.rules.manage",
        dpgettext_noop("admin", "permission name: moderation.rules.manage", "Manage moderation rules"),
        dpgettext_noop(
          "admin",
          "permission description: moderation.rules.manage",
          "Create, edit and delete the regex and webhook rules every moderated save is checked against."
        )}
     ]},
    {dpgettext_noop("admin", "permission category", "Content moderation"), :flag, nil,
     [
       {"moderation.chats.permissive",
        dpgettext_noop("admin", "permission name: moderation.chats.permissive", "Scan chats"),
        dpgettext_noop(
          "admin",
          "permission description: moderation.chats.permissive",
          "Check this account's chat names and the messages it writes against the moderation rules after saving; matches are flagged for review."
        )},
       {"moderation.characters.permissive",
        dpgettext_noop("admin", "permission name: moderation.characters.permissive", "Scan characters"),
        dpgettext_noop(
          "admin",
          "permission description: moderation.characters.permissive",
          "Check this account's characters against the moderation rules after saving; matches are flagged for review."
        )},
       {"moderation.characters.restrictive",
        dpgettext_noop("admin", "permission name: moderation.characters.restrictive", "Hold characters for review"),
        dpgettext_noop(
          "admin",
          "permission description: moderation.characters.restrictive",
          "Keep new characters and character text edits in memory, unsaved, until the rules or a moderator approve them. Wins over scanning."
        )},
       {"moderation.lore.permissive",
        dpgettext_noop("admin", "permission name: moderation.lore.permissive", "Scan lore books and entries"),
        dpgettext_noop(
          "admin",
          "permission description: moderation.lore.permissive",
          "Check this account's lore books and entries against the moderation rules after saving; matches are flagged for review."
        )},
       {"moderation.lore.restrictive",
        dpgettext_noop("admin", "permission name: moderation.lore.restrictive", "Hold lore entries for review"),
        dpgettext_noop(
          "admin",
          "permission description: moderation.lore.restrictive",
          "Keep new lore entries and lore entry text edits in memory, unsaved, until the rules or a moderator approve them; lore books are scanned. Wins over scanning."
        )},
       {"moderation.ai.permissive",
        dpgettext_noop("admin", "permission name: moderation.ai.permissive", "Scan AI connections and models"),
        dpgettext_noop(
          "admin",
          "permission description: moderation.ai.permissive",
          "Check this account's AI connections and models against the moderation rules after saving; matches are flagged for review."
        )},
       {"moderation.ai.restrictive",
        dpgettext_noop(
          "admin",
          "permission name: moderation.ai.restrictive",
          "Hold AI connections and models for review"
        ),
        dpgettext_noop(
          "admin",
          "permission description: moderation.ai.restrictive",
          "Keep new AI connections and models and their text edits in memory, unsaved, until the rules or a moderator approve them. Wins over scanning."
        )},
       {"moderation.prompts.permissive",
        dpgettext_noop("admin", "permission name: moderation.prompts.permissive", "Scan prompts, blocks and outlets"),
        dpgettext_noop(
          "admin",
          "permission description: moderation.prompts.permissive",
          "Check this account's prompts, blocks and outlets against the moderation rules after saving; matches are flagged for review."
        )},
       {"moderation.prompts.restrictive",
        dpgettext_noop(
          "admin",
          "permission name: moderation.prompts.restrictive",
          "Hold prompts, blocks and outlets for review"
        ),
        dpgettext_noop(
          "admin",
          "permission description: moderation.prompts.restrictive",
          "Keep new prompts, blocks and outlets and their text edits in memory, unsaved, until the rules or a moderator approve them. Wins over scanning."
        )}
     ]},
    {dpgettext_noop("admin", "permission category", "Scripts"), :flag, nil,
     [
       {"scripts.messages", dpgettext_noop("admin", "permission name: scripts.messages", "Scripts may change messages"),
        dpgettext_noop(
          "admin",
          "permission description: scripts.messages",
          "Let the user's scripts create, edit and delete messages."
        )},
       {"scripts.images",
        dpgettext_noop("admin", "permission name: scripts.images", "Scripts may caption and request images"),
        dpgettext_noop(
          "admin",
          "permission description: scripts.images",
          "Let the user's scripts caption images and request new ones."
        )},
       {"scripts.generation",
        dpgettext_noop("admin", "permission name: scripts.generation", "Scripts may start generations"),
        dpgettext_noop(
          "admin",
          "permission description: scripts.generation",
          "Let the user's scripts start AI replies."
        )},
       {"scripts.memory",
        dpgettext_noop(
          "admin",
          "permission name: scripts.memory",
          "Scripts may run memory jobs and change memory settings"
        ),
        dpgettext_noop(
          "admin",
          "permission description: scripts.memory",
          "Let the user's scripts run memory jobs and change a chat's memory settings."
        )},
       {"scripts.characters",
        dpgettext_noop("admin", "permission name: scripts.characters", "Scripts may change characters and avatars"),
        dpgettext_noop(
          "admin",
          "permission description: scripts.characters",
          "Let the user's scripts change characters and their avatars."
        )},
       {"scripts.prompts",
        dpgettext_noop("admin", "permission name: scripts.prompts", "Scripts may switch prompts and blocks"),
        dpgettext_noop(
          "admin",
          "permission description: scripts.prompts",
          "Let the user's scripts switch a chat's prompt and toggle its blocks."
        )},
       {"scripts.lore", dpgettext_noop("admin", "permission name: scripts.lore", "Scripts may change lore"),
        dpgettext_noop(
          "admin",
          "permission description: scripts.lore",
          "Let the user's scripts change lore books and entries."
        )},
       {"scripts.variables",
        dpgettext_noop("admin", "permission name: scripts.variables", "Scripts may change variables"),
        dpgettext_noop(
          "admin",
          "permission description: scripts.variables",
          "Let the user's scripts set and delete a chat's variables and the user's own global variables."
        )},
       {"scripts.injections",
        dpgettext_noop("admin", "permission name: scripts.injections", "Scripts may change injections"),
        dpgettext_noop(
          "admin",
          "permission description: scripts.injections",
          "Let the user's scripts create, edit and delete a chat's injections."
        )}
     ]},
    {dpgettext_noop("admin", "permission category", "Limits"), :limit, :cents,
     [
       {"quota.spend_per_day",
        dpgettext_noop(
          "admin",
          "permission name: quota.spend_per_day",
          "Spending per day on the site's AI connections"
        ),
        dpgettext_noop(
          "admin",
          "permission description: quota.spend_per_day",
          "Dollars the user's replies, jobs and lore embeddings may cost in any 24 hours on connections the site provides: the connection's reported charge, else an estimate from the model's per-Mtok prices. A run on a model with neither counts as free. Their own connections are never limited."
        )}
     ]},
    {dpgettext_noop("admin", "permission category", "Limits"), :limit, :count,
     [
       {"quota.characters", dpgettext_noop("admin", "permission name: quota.characters", "Own characters"),
        dpgettext_noop("admin", "permission description: quota.characters", "How many characters the user may own.")},
       {"quota.lore_books", dpgettext_noop("admin", "permission name: quota.lore_books", "Own lore books"),
        dpgettext_noop("admin", "permission description: quota.lore_books", "How many lore books the user may own.")},
       {"quota.prompts", dpgettext_noop("admin", "permission name: quota.prompts", "Own prompts"),
        dpgettext_noop("admin", "permission description: quota.prompts", "How many prompts the user may own.")},
       {"quota.scripts", dpgettext_noop("admin", "permission name: quota.scripts", "Own scripts"),
        dpgettext_noop("admin", "permission description: quota.scripts", "How many scripts the user may own.")},
       {"quota.chats", dpgettext_noop("admin", "permission name: quota.chats", "Own chats"),
        dpgettext_noop("admin", "permission description: quota.chats", "How many chats the user may own.")},
       {"quota.ai_connections", dpgettext_noop("admin", "permission name: quota.ai_connections", "Own AI connections"),
        dpgettext_noop(
          "admin",
          "permission description: quota.ai_connections",
          "How many AI connections the user may own."
        )},
       {"quota.ai_models", dpgettext_noop("admin", "permission name: quota.ai_models", "Own AI models"),
        dpgettext_noop("admin", "permission description: quota.ai_models", "How many AI models the user may own.")},
       {"quota.pending_invites", dpgettext_noop("admin", "permission name: quota.pending_invites", "Pending invites"),
        dpgettext_noop(
          "admin",
          "permission description: quota.pending_invites",
          "How many share and chat invites the user may have waiting for an answer."
        )}
     ]},
    {dpgettext_noop("admin", "permission category", "Limits"), :limit, :bytes,
     [
       {"quota.upload_bytes", dpgettext_noop("admin", "permission name: quota.upload_bytes", "Upload storage"),
        dpgettext_noop(
          "admin",
          "permission description: quota.upload_bytes",
          "How much the user's uploaded files may take up in total."
        )}
     ]}
  ]

  @all (for {category, kind, unit, keys} <- @entries, {key, label, description} <- keys do
          %{key: key, kind: kind, category: category, label: label, description: description, unit: unit}
        end)

  @by_key Map.new(@all, &{&1.key, &1})

  @doc "Every entry, in display order, in the current locale."
  @spec all() :: [entry()]
  def all, do: Enum.map(@all, &localize/1)

  @doc "Every key, in display order."
  @spec keys() :: [String.t()]
  def keys, do: Enum.map(@all, & &1.key)

  @doc "Every key with its kind, in display order. Untranslated: for resolution, not display."
  @spec kinds() :: [{String.t(), kind()}]
  def kinds, do: Enum.map(@all, &{&1.key, &1.kind})

  @doc """
  The keys in the categories named by their English (msgid) names, `[\"Administration\"]`.
  Untranslated, so usable at compile time.
  """
  @spec keys_in_categories([String.t()]) :: [String.t()]
  def keys_in_categories(categories), do: for(e <- @all, e.category in categories, do: e.key)

  @doc "The entry for `key`, in the current locale; raises `ArgumentError` for an unknown key."
  @spec fetch!(String.t()) :: entry()
  def fetch!(key) do
    case @by_key do
      %{^key => entry} -> localize(entry)
      _ -> raise ArgumentError, "unknown permission #{inspect(key)}"
    end
  end

  @doc "The entry for `key`, in the current locale, or nil."
  @spec get(String.t()) :: entry() | nil
  def get(key) do
    case @by_key do
      %{^key => entry} -> localize(entry)
      _ -> nil
    end
  end

  @doc "Whether `key` is an on/off flag (raises for an unknown key). Untranslated, so cheap."
  @spec flag?(String.t()) :: boolean()
  def flag?(key) do
    case @by_key do
      %{^key => entry} -> entry.kind == :flag
      _ -> raise ArgumentError, "unknown permission #{inspect(key)}"
    end
  end

  @doc """
  `{id, category, entries}` in display order, in the current locale. `id` is a slug of the
  category's English name, the same in every locale (DOM ids).
  """
  @spec categories() :: [{String.t(), String.t(), [entry()]}]
  def categories do
    @all
    |> Enum.chunk_by(& &1.category)
    |> Enum.map(fn [first | _] = entries ->
      id = first.category |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-")
      entries = Enum.map(entries, &localize/1)
      {id, hd(entries).category, entries}
    end)
  end

  # The noop texts in `@entries`, translated with the contexts they were extracted under.
  defp localize(%{key: key} = entry) do
    %{
      entry
      | category: Gettext.dpgettext(Mythweaver.Gettext, "admin", "permission category", entry.category),
        label: Gettext.dpgettext(Mythweaver.Gettext, "admin", "permission name: " <> key, entry.label),
        description:
          Gettext.dpgettext(Mythweaver.Gettext, "admin", "permission description: " <> key, entry.description)
    }
  end
end
