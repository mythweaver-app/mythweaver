defmodule MythweaverWeb.Router do
  use MythweaverWeb, :router

  import MythweaverWeb.UserAuth

  alias MythweaverWeb.CommandPalette.Hook

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug MythweaverWeb.DeviceCookie
    plug :fetch_live_flash
    plug :put_root_layout, html: {MythweaverWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
    plug MythweaverWeb.Locale
    plug MythweaverWeb.BanGate
    plug MythweaverWeb.ContentSecurityPolicy
  end

  # A stylesheet fetch, not a page: no `accepts ["html"]` (it would refuse `Accept: text/css`), no
  # CSRF, no root layout. Only the viewer, for their own sheet.
  pipeline :stylesheet do
    plug :fetch_session
    plug :fetch_current_scope_for_user
  end

  pipeline :mcp do
    plug MythweaverWeb.MCPAuth
  end

  # A webhook moderation rule's verdict: the signed token in the path is the credential, so no
  # session and no CSRF.
  pipeline :moderation_callback do
    plug :accepts, ["json"]
  end

  scope "/", MythweaverWeb do
    pipe_through [:browser, :require_authenticated_user]

    # `ModerationGate` records fingerprints, refuses banned sessions and holds a warned account on
    # `/warnings`. The hook turns the command palette's flash messages into the page's flash.
    # `NotificationsHook` delivers the user's in-app notifications on every page.
    live_session :app,
      on_mount: [
        MythweaverWeb.Locale,
        {MythweaverWeb.UserAuth, :require_authenticated},
        MythweaverWeb.ModerationGate,
        Hook,
        MythweaverWeb.NotificationsHook
      ] do
      live "/warnings", WarningLive, :index

      live "/", MainChatLive, :index
      live "/chats/:id", MainChatLive, :show
      live "/chats/:id/settings", MainChatLive, :settings
      live "/chats/:id/memory", MainChatLive, :memory

      live "/characters", CharacterLive, :index
      live "/import", ImportLive, :index
      live "/export", ExportLive, :index
      live "/characters/new", CharacterLive, :new
      live "/characters/:id/edit", CharacterLive, :edit
      live "/characters/expression-profiles", ExpressionProfileLive, :index
      live "/characters/expression-profiles/new", ExpressionProfileLive, :new
      live "/characters/expression-profiles/:id/edit", ExpressionProfileLive, :edit

      live "/lore/pools", LorePoolLive, :index
      live "/lore/pools/new", LorePoolLive, :new
      live "/lore/pools/:id/edit", LorePoolLive, :edit
      live "/lore", LoreBookLive, :index
      live "/lore/new", LoreBookLive, :new
      live "/lore/entries/new", LoreBookLive, :entry_new
      live "/lore/entries/:entry_id/edit", LoreBookLive, :entry_edit
      live "/lore/:id/edit", LoreBookLive, :edit
      live "/lore/:id/entries/new", LoreBookLive, :new_entry
      live "/lore/:id/entries/:entry_id/edit", LoreBookLive, :edit_entry

      live "/prompts", PromptLive, :index
      live "/prompts/new", PromptLive, :new
      live "/prompts/blocks", PromptBlockLive, :index
      live "/prompts/blocks/new", PromptBlockLive, :new
      live "/prompts/blocks/:id/edit", PromptBlockLive, :edit
      live "/prompts/outlets", PromptOutletLive, :index
      live "/prompts/outlets/new", PromptOutletLive, :new
      live "/prompts/outlets/:id/edit", PromptOutletLive, :edit
      live "/prompts/:id/edit", PromptLive, :edit

      live "/ai/providers", AIProviderLive, :index
      live "/ai/providers/new", AIProviderLive, :new
      live "/ai/models", AIModelLive, :index
      live "/ai/models/new", AIModelLive, :new
      live "/ai/models/:id/edit", AIModelLive, :edit
      live "/ai/providers/:id/edit", AIProviderLive, :edit
      live "/variables", GlobalVariableLive, :index
      live "/variables/new", GlobalVariableLive, :new
      live "/variables/:id/edit", GlobalVariableLive, :edit

      live "/scripts", ScriptLive, :index
      live "/scripts/new", ScriptLive, :new
      live "/scripts/:id/edit", ScriptLive, :edit
      live "/tags", TagLive, :index
      live "/tags/new", TagLive, :new
      live "/tags/:id/edit", TagLive, :edit

      live "/jobs", JobLive, :index
      live "/analytics", AnalyticsLive, :index
      live "/shared", SharedLive, :index
      live "/shared/:id", SharedLive, :show
      live "/catalog", CatalogLive, :index
      live "/catalog/:id", CatalogLive, :show

      live "/memory/profiles", MemoryProfileLive, :index
      live "/memory/profiles/new", MemoryProfileLive, :new
      live "/memory/profiles/:id/edit", MemoryProfileLive, :edit
      live "/memory/side-prompts", SidePromptLive, :index
      live "/memory/side-prompts/new", SidePromptLive, :new
      live "/memory/side-prompts/:id/edit", SidePromptLive, :edit
      live "/memory/side-prompt-sets", SidePromptSetLive, :index
      live "/memory/side-prompt-sets/new", SidePromptSetLive, :new
      live "/memory/side-prompt-sets/:id/edit", SidePromptSetLive, :edit

      live "/settings", SettingsLive, :index
      live "/settings/:category", SettingsLive, :show

      live "/users/settings", UserSettingsLive, :edit

      live "/moderation/reports", ModerationReportLive, :index
      live "/moderation/reports/:id", ModerationReportLive, :show
      live "/moderation/flagged", ModerationReportLive, :flagged
      live "/moderation/flagged/:id", ModerationReportLive, :show_flagged
      live "/moderation/held", ModerationReportLive, :held
      live "/moderation/held/:id", ModerationReportLive, :show_held
      live "/moderation/rules", ModerationRuleLive, :index
      live "/moderation/rules/new", ModerationRuleLive, :new
      live "/moderation/rules/:id/edit", ModerationRuleLive, :edit
      live "/moderation/lookup", ModerationLookupLive, :index
      live "/moderation/lookup/:type/:id", ModerationLookupLive, :show
      live "/moderation/users", UserLive, :index
      live "/moderation/users/new", UserLive, :new
      live "/moderation/users/:id/edit", UserLive, :edit
      live "/moderation/users/:id/record", ModerationAccountLive, :show
      live "/moderation/users/:id/data", UserDataLive, :show
      live "/moderation/groups", GroupLive, :index
      live "/moderation/groups/new", GroupLive, :new
      live "/moderation/groups/:id/edit", GroupLive, :edit
      live "/moderation/bans", ModerationBanLive, :index
      live "/moderation/log", ModerationLogLive, :index
      live "/submissions", SubmissionLive, :index
    end

    post "/users/update-password", UserSessionController, :update_password
    post "/export", ExportController, :create
  end

  scope "/", MythweaverWeb do
    pipe_through :browser

    live_session :public, on_mount: [MythweaverWeb.Locale, {MythweaverWeb.UserAuth, :mount_current_scope}] do
      live "/users/log-in", UserLoginLive, :new
      live "/setup", UserSetupLive, :new
    end

    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end

  scope "/styles", MythweaverWeb do
    pipe_through :stylesheet

    get "/site.css", StylesheetController, :site
    get "/user.css", StylesheetController, :user
  end

  # No pipeline: an `/uploads` link carries its own sealed credential, and a CDN or image proxy
  # fetching it has no session. No session read also means no `Set-Cookie`, so shared caches can
  # keep it.
  scope "/", MythweaverWeb do
    get "/uploads/:token", UploadController, :show
    get "/remote-images/:token", RemoteImageController, :show
  end

  scope "/", MythweaverWeb do
    pipe_through :moderation_callback

    post "/moderation/callback/:token", ModerationCallbackController, :create
  end

  # MCP clients authenticate with a bearer token, never a cookie: no session, no CSRF. No Origin
  # check either: a browser never sends the bearer header on its own, so a DNS-rebinding request
  # carries no authority.
  scope "/", MythweaverWeb do
    pipe_through :mcp

    post "/mcp", MCPController, :handle
    get "/mcp", MCPController, :not_allowed
    delete "/mcp", MCPController, :not_allowed
  end

  # Enable LiveDashboard in development
  if Application.compile_env(:mythweaver, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      # Script nonce only: a style nonce would make browsers ignore the policy's 'unsafe-inline'.
      live_dashboard "/dashboard", metrics: MythweaverWeb.Telemetry, csp_nonce_assign_key: %{script: :csp_nonce}
    end
  end
end
