-- Mythweaver's database as of migration 20261117223854: every earlier migration squashed into
-- one schema, plus the rows those migrations inserted (the Everyone and Administrators permission
-- groups and their default grants). The 20261117223854_structure migration runs it on an empty
-- database. A database that ran the original migrations has that version recorded already and
-- skips it. Later changes go in new migrations, never here.
--
-- Generated with pg_dump --schema-only and --data-only --column-inserts (PostgreSQL 18), then
-- stripped of pg_dump's session settings, psql meta-commands, schema_migrations, extension
-- comments and PostgreSQL 18 NOT NULL constraint names.

CREATE EXTENSION IF NOT EXISTS citext WITH SCHEMA public;

CREATE EXTENSION IF NOT EXISTS vector WITH SCHEMA public;

CREATE FUNCTION public.mythweaver_search_words(text[]) RETURNS text
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    AS $_$ SELECT array_to_string($1, ' ') $_$;

CREATE TABLE public.access_grants (
    id uuid NOT NULL,
    share_id uuid NOT NULL,
    user_id uuid NOT NULL,
    owner_id uuid NOT NULL,
    item_type character varying(255) NOT NULL,
    item_id uuid NOT NULL,
    access character varying(255) NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    visibility character varying(255) DEFAULT 'readable'::character varying NOT NULL
);

CREATE TABLE public.account_fingerprints (
    id uuid NOT NULL,
    user_id uuid NOT NULL,
    kind character varying(255) NOT NULL,
    value text NOT NULL,
    first_seen_at timestamp(0) without time zone NOT NULL,
    last_seen_at timestamp(0) without time zone NOT NULL,
    seen_count integer DEFAULT 1 NOT NULL,
    geo jsonb
);

CREATE TABLE public.ai_model_groups (
    ai_model_id uuid NOT NULL,
    group_id uuid NOT NULL
);

CREATE TABLE public.ai_models (
    id uuid NOT NULL,
    name character varying(255) NOT NULL,
    api_model_id character varying(255) NOT NULL,
    completion_mode character varying(255) DEFAULT 'chat'::character varying NOT NULL,
    context_window integer,
    supports_images boolean DEFAULT false NOT NULL,
    supports_tools boolean DEFAULT false NOT NULL,
    supports_thinking boolean DEFAULT false NOT NULL,
    prompt_cost_per_mtok numeric,
    completion_cost_per_mtok numeric,
    sampler jsonb DEFAULT '{}'::jsonb NOT NULL,
    notes text,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    extra_body jsonb DEFAULT '{}'::jsonb NOT NULL,
    reasoning_prefix character varying(255),
    reasoning_suffix character varying(255),
    continue_prefill boolean DEFAULT false NOT NULL,
    tokenizer character varying(255),
    caption_model_id uuid,
    caption_prompt_id uuid,
    caption_max_tokens integer DEFAULT 300,
    inline_image_limit integer,
    image_detail character varying(255),
    user_id uuid,
    supports_files boolean DEFAULT false NOT NULL,
    supports_audio boolean DEFAULT false NOT NULL,
    supports_video boolean DEFAULT false NOT NULL,
    chat_first_token_seconds integer,
    chat_stall_seconds integer,
    chat_deadline_seconds integer,
    background_first_token_seconds integer,
    background_stall_seconds integer,
    background_deadline_seconds integer,
    inline_audio_limit integer,
    inline_video_limit integer,
    inline_document_limit integer,
    search_vector tsvector GENERATED ALWAYS AS (((setweight(to_tsvector('simple'::regconfig, (COALESCE(name, ''::character varying))::text), 'A'::"char") || setweight(to_tsvector('simple'::regconfig, (COALESCE(api_model_id, ''::character varying))::text), 'A'::"char")) || setweight(to_tsvector('simple'::regconfig, COALESCE("left"(notes, 262144), ''::text)), 'C'::"char"))) STORED,
    site_visibility character varying(255) DEFAULT 'readable'::character varying NOT NULL,
    frozen_listing_id uuid,
    mirror_of_id uuid,
    CONSTRAINT ai_models_context_window_positive CHECK ((context_window > 0))
);

CREATE TABLE public.assistant_tool_calls (
    id uuid NOT NULL,
    chat_id uuid NOT NULL,
    message_id uuid NOT NULL,
    "position" integer NOT NULL,
    call_id character varying(255) NOT NULL,
    name character varying(255) NOT NULL,
    arguments jsonb DEFAULT '{}'::jsonb NOT NULL,
    status character varying(255) NOT NULL,
    result jsonb,
    error text,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL
);

CREATE TABLE public.attachments (
    id uuid NOT NULL,
    kind character varying(255) NOT NULL,
    source character varying(255) NOT NULL,
    status character varying(255) NOT NULL,
    storage character varying(255) NOT NULL,
    key character varying(255) NOT NULL,
    content_type character varying(255) NOT NULL,
    byte_size bigint,
    width integer,
    height integer,
    filename character varying(255),
    description text,
    caption_status character varying(255) DEFAULT 'none'::character varying NOT NULL,
    caption_error character varying(255),
    described_by_model_id uuid,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    uploaded_by_id uuid,
    text_content text,
    page_count integer,
    blurhash character varying(255)
);

CREATE TABLE public.catalog_listings (
    id uuid NOT NULL,
    item_type character varying(255) NOT NULL,
    item_id uuid NOT NULL,
    mirror_id uuid NOT NULL,
    owner_id uuid NOT NULL,
    title character varying(255) NOT NULL,
    summary text,
    tags character varying(255)[] DEFAULT ARRAY[]::character varying[] NOT NULL,
    visibility character varying(255) DEFAULT 'runtime_only'::character varying NOT NULL,
    featured boolean DEFAULT false NOT NULL,
    published_at timestamp(0) without time zone,
    hidden_at timestamp(0) without time zone,
    hidden_by_id uuid,
    current_release_id uuid,
    subscriber_count integer DEFAULT 0 NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);

CREATE TABLE public.catalog_releases (
    id uuid NOT NULL,
    listing_id uuid NOT NULL,
    version integer NOT NULL,
    notes text,
    published_by_id uuid,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);

CREATE TABLE public.character_attachments (
    id uuid NOT NULL,
    character_id uuid NOT NULL,
    attachment_id uuid NOT NULL,
    role character varying(255) NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL
);

CREATE TABLE public.character_favorites (
    id uuid NOT NULL,
    user_id uuid NOT NULL,
    character_id uuid NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL
);

CREATE TABLE public.character_locks (
    id uuid NOT NULL,
    chat_id uuid NOT NULL,
    character_id uuid NOT NULL,
    user_id uuid NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);

CREATE TABLE public.character_outfits (
    id uuid NOT NULL,
    character_id uuid NOT NULL,
    name character varying(255) NOT NULL,
    "position" integer DEFAULT 0 NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    mirror_of_id uuid
);

CREATE TABLE public.character_sprites (
    id uuid NOT NULL,
    character_id uuid NOT NULL,
    outfit_id uuid,
    attachment_id uuid NOT NULL,
    label character varying(255) NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    mirror_of_id uuid
);

CREATE TABLE public.characters (
    id uuid NOT NULL,
    name character varying(255) NOT NULL,
    description text,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    creator character varying(255),
    creator_notes text,
    character_version character varying(255),
    pronouns character varying(255),
    talkativeness double precision DEFAULT 0.5 NOT NULL,
    appearance text,
    user_id uuid,
    avatar_updates_appearance boolean,
    expression_labels character varying(255)[] DEFAULT ARRAY[]::character varying[] NOT NULL,
    fallback_expression character varying(255) DEFAULT 'neutral'::character varying NOT NULL,
    expression_profile_id uuid,
    search_vector tsvector GENERATED ALWAYS AS (((((setweight(to_tsvector('simple'::regconfig, (COALESCE(name, ''::character varying))::text), 'A'::"char") || setweight(to_tsvector('simple'::regconfig, COALESCE("left"(description, 262144), ''::text)), 'B'::"char")) || setweight(to_tsvector('simple'::regconfig, COALESCE("left"(appearance, 262144), ''::text)), 'C'::"char")) || setweight(to_tsvector('simple'::regconfig, (COALESCE(creator, ''::character varying))::text), 'D'::"char")) || setweight(to_tsvector('simple'::regconfig, COALESCE("left"(creator_notes, 262144), ''::text)), 'D'::"char"))) STORED,
    site_visibility character varying(255) DEFAULT 'readable'::character varying NOT NULL,
    cloned_from_type character varying(255),
    cloned_from_id uuid,
    frozen_listing_id uuid,
    mirror_of_id uuid,
    cloned_from_release_id uuid,
    first_message text,
    alternate_greetings text[] DEFAULT ARRAY[]::text[] NOT NULL,
    group_greetings text[] DEFAULT ARRAY[]::text[] NOT NULL,
    system_prompt text,
    post_history_instructions text,
    card_prompt_mode character varying(255) DEFAULT 'replace'::character varying NOT NULL,
    source_file character varying(255),
    "foreign" jsonb DEFAULT '{}'::jsonb NOT NULL
);

CREATE TABLE public.chat_injections (
    id uuid NOT NULL,
    chat_id uuid NOT NULL,
    key character varying(255) NOT NULL,
    content text NOT NULL,
    "position" character varying(255) NOT NULL,
    depth integer DEFAULT 4 NOT NULL,
    role character varying(255) DEFAULT 'system'::character varying NOT NULL,
    condition text,
    enabled boolean DEFAULT true NOT NULL,
    uses integer,
    remaining integer,
    "order" integer DEFAULT 100 NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL
);

CREATE TABLE public.chat_members (
    id uuid NOT NULL,
    chat_id uuid NOT NULL,
    user_id uuid NOT NULL,
    role character varying(255) NOT NULL,
    status character varying(255) DEFAULT 'pending'::character varying NOT NULL,
    invited_by_id uuid,
    accepted_at timestamp(0) without time zone,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    last_read_at timestamp without time zone,
    model_source character varying(255) DEFAULT 'owner'::character varying NOT NULL,
    ai_model_id uuid
);

CREATE TABLE public.chat_memory_settings (
    id uuid NOT NULL,
    chat_id uuid NOT NULL,
    memory_book_id uuid,
    profile_id uuid,
    highest_processed integer,
    auto_enabled boolean DEFAULT false NOT NULL,
    auto_trigger character varying(255) DEFAULT NULL::character varying,
    auto_interval integer,
    auto_buffer integer,
    auto_token_threshold integer,
    auto_hide character varying(255) DEFAULT 'none'::character varying NOT NULL,
    leave_unhidden integer DEFAULT 2 NOT NULL,
    context_entry_ids uuid[] DEFAULT ARRAY[]::uuid[] NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    side_prompt_book_ids jsonb DEFAULT '{}'::jsonb NOT NULL,
    reminder jsonb DEFAULT '{}'::jsonb NOT NULL,
    character_book_ids jsonb DEFAULT '{}'::jsonb NOT NULL,
    cast_ids uuid[] DEFAULT ARRAY[]::uuid[] NOT NULL,
    side_prompt_set_mode character varying(255) DEFAULT 'default'::character varying NOT NULL,
    side_prompt_set_id uuid
);

CREATE TABLE public.chat_participants (
    id uuid NOT NULL,
    chat_id uuid NOT NULL,
    character_id uuid NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    ai_model_id uuid,
    "position" integer DEFAULT 0 NOT NULL,
    muted boolean DEFAULT false NOT NULL,
    talkativeness double precision,
    outfit_id uuid,
    added_by_id uuid
);

CREATE TABLE public.chats (
    id uuid NOT NULL,
    name character varying(255),
    player_character_id uuid,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    ai_model_id uuid,
    reply_strategy character varying(255) DEFAULT 'manual'::character varying NOT NULL,
    allow_self_responses boolean DEFAULT false NOT NULL,
    max_turns integer,
    auto_mode_delay integer DEFAULT 5 NOT NULL,
    last_activity_at timestamp without time zone,
    last_read_at timestamp without time zone,
    user_id uuid,
    group_cards character varying(255) DEFAULT 'swap'::character varying NOT NULL,
    kind character varying(255) DEFAULT 'roleplay'::character varying NOT NULL,
    last_opened_at timestamp without time zone,
    search_vector tsvector GENERATED ALWAYS AS (setweight(to_tsvector('simple'::regconfig, (COALESCE(name, ''::character varying))::text), 'A'::"char")) STORED,
    guest_permissions jsonb DEFAULT '{}'::jsonb NOT NULL,
    guests_bring_characters boolean DEFAULT false NOT NULL,
    free_switching boolean DEFAULT false NOT NULL,
    turn_mode character varying(255) DEFAULT 'any'::character varying NOT NULL
);

CREATE TABLE public.expression_profiles (
    id uuid NOT NULL,
    name character varying(255) NOT NULL,
    user_id uuid,
    rules jsonb[] DEFAULT ARRAY[]::jsonb[] NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    frozen_listing_id uuid,
    mirror_of_id uuid
);

CREATE TABLE public.generation_jobs (
    id uuid NOT NULL,
    tag character varying(255) NOT NULL,
    origin character varying(255) NOT NULL,
    status character varying(255) NOT NULL,
    label character varying(255) NOT NULL,
    chat_id uuid,
    ai_model_id uuid,
    provider_id uuid,
    parent_id uuid,
    params jsonb DEFAULT '{}'::jsonb NOT NULL,
    result jsonb,
    raw_output text,
    error text,
    attempts integer DEFAULT 0 NOT NULL,
    range_start integer,
    range_end integer,
    usage jsonb,
    started_at timestamp without time zone,
    finished_at timestamp without time zone,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    first_token_at timestamp without time zone,
    expected_first_token_ms integer,
    user_id uuid,
    prompt_name character varying(255)
);

CREATE TABLE public.generation_stats (
    id uuid NOT NULL,
    job_id uuid,
    user_id uuid NOT NULL,
    chat_id uuid,
    ai_model_id uuid,
    provider_id uuid,
    tag character varying(255) NOT NULL,
    origin character varying(255) NOT NULL,
    status character varying(255) NOT NULL,
    prompt_tokens integer,
    completion_tokens integer,
    cost numeric,
    cost_estimated boolean DEFAULT false NOT NULL,
    started_at timestamp without time zone,
    first_token_at timestamp without time zone,
    finished_at timestamp without time zone NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    cached_tokens integer
);

CREATE TABLE public.lore_book_characters (
    id uuid NOT NULL,
    lore_book_id uuid NOT NULL,
    character_id uuid NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);

CREATE TABLE public.lore_book_chats (
    id uuid NOT NULL,
    lore_book_id uuid NOT NULL,
    chat_id uuid NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);

CREATE TABLE public.lore_book_entries (
    id uuid NOT NULL,
    lore_book_id uuid NOT NULL,
    lore_entry_id uuid NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    "order" integer DEFAULT 100 NOT NULL
);

CREATE TABLE public.lore_book_filter_tags (
    id uuid NOT NULL,
    lore_book_id uuid NOT NULL,
    tag_id uuid NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);

CREATE TABLE public.lore_book_rule_conditions (
    id uuid NOT NULL,
    lore_book_rule_id uuid NOT NULL,
    "position" integer DEFAULT 0 NOT NULL,
    kind character varying(255) NOT NULL,
    negate boolean DEFAULT false NOT NULL,
    chat_id uuid,
    character_id uuid,
    tags character varying(255)[] DEFAULT ARRAY[]::character varying[] NOT NULL,
    template text,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);

CREATE TABLE public.lore_book_rules (
    id uuid NOT NULL,
    lore_book_id uuid NOT NULL,
    "position" integer DEFAULT 0 NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);

CREATE TABLE public.lore_books (
    id uuid NOT NULL,
    name character varying(255) NOT NULL,
    description text,
    global boolean DEFAULT false NOT NULL,
    priority integer DEFAULT 3 NOT NULL,
    order_adjustment integer DEFAULT 0 NOT NULL,
    token_budget integer,
    scan_depth integer,
    recursive boolean DEFAULT true NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    user_id uuid,
    site_visibility character varying(255) DEFAULT 'readable'::character varying NOT NULL,
    forced boolean DEFAULT false NOT NULL,
    tag_filter_mode character varying(255) DEFAULT 'off'::character varying NOT NULL,
    search_vector tsvector GENERATED ALWAYS AS ((setweight(to_tsvector('simple'::regconfig, (COALESCE(name, ''::character varying))::text), 'A'::"char") || setweight(to_tsvector('simple'::regconfig, COALESCE("left"(description, 262144), ''::text)), 'B'::"char"))) STORED,
    cloned_from_type character varying(255),
    cloned_from_id uuid,
    frozen_listing_id uuid,
    mirror_of_id uuid,
    cloned_from_release_id uuid,
    kind character varying(255) DEFAULT 'lore'::character varying NOT NULL,
    "foreign" jsonb DEFAULT '{}'::jsonb NOT NULL,
    CONSTRAINT lore_books_priority_range CHECK (((priority >= 1) AND (priority <= 5)))
);

CREATE TABLE public.lore_entries (
    id uuid NOT NULL,
    name character varying(255) NOT NULL,
    content text DEFAULT ''::text NOT NULL,
    activation character varying(255) DEFAULT 'keyword'::character varying NOT NULL,
    keywords character varying(255)[] DEFAULT ARRAY[]::character varying[] NOT NULL,
    secondary_keywords character varying(255)[] DEFAULT ARRAY[]::character varying[] NOT NULL,
    secondary_logic character varying(255) DEFAULT 'and_any'::character varying NOT NULL,
    case_sensitive boolean,
    match_whole_words boolean,
    scan_depth integer,
    outlet character varying(255) DEFAULT 'character'::character varying NOT NULL,
    depth integer,
    probability integer DEFAULT 100 NOT NULL,
    sticky integer,
    cooldown integer,
    delay integer,
    exclude_recursion boolean DEFAULT false NOT NULL,
    prevent_recursion boolean DEFAULT false NOT NULL,
    character_filter_mode character varying(255) DEFAULT 'off'::character varying NOT NULL,
    ignore_budget boolean DEFAULT false NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    placement character varying(255) DEFAULT 'before'::character varying NOT NULL,
    custom_outlet character varying(255),
    user_id uuid,
    search_vector tsvector GENERATED ALWAYS AS ((((setweight(to_tsvector('simple'::regconfig, (COALESCE(name, ''::character varying))::text), 'A'::"char") || setweight(to_tsvector('simple'::regconfig, COALESCE(public.mythweaver_search_words((keywords)::text[]), ''::text)), 'B'::"char")) || setweight(to_tsvector('simple'::regconfig, COALESCE(public.mythweaver_search_words((secondary_keywords)::text[]), ''::text)), 'B'::"char")) || setweight(to_tsvector('simple'::regconfig, COALESCE("left"(content, 262144), ''::text)), 'C'::"char"))) STORED,
    frozen_listing_id uuid,
    mirror_of_id uuid,
    role character varying(255) DEFAULT 'system'::character varying NOT NULL,
    trigger_only boolean DEFAULT false NOT NULL,
    delay_until_recursion integer DEFAULT 0 NOT NULL,
    "foreign" jsonb DEFAULT '{}'::jsonb NOT NULL,
    CONSTRAINT lore_entries_probability_range CHECK (((probability >= 0) AND (probability <= 100)))
);

CREATE TABLE public.lore_entry_characters (
    id uuid NOT NULL,
    lore_entry_id uuid NOT NULL,
    character_id uuid NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);

CREATE TABLE public.lore_entry_embeddings (
    id uuid NOT NULL,
    lore_entry_id uuid NOT NULL,
    ai_model_id uuid NOT NULL,
    content_hash bytea NOT NULL,
    embedding public.vector NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);

CREATE TABLE public.lore_entry_filter_tags (
    id uuid NOT NULL,
    lore_entry_id uuid NOT NULL,
    tag_id uuid NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);

CREATE TABLE public.lore_entry_states (
    id uuid NOT NULL,
    chat_id uuid NOT NULL,
    lore_entry_id uuid NOT NULL,
    sticky_until integer,
    cooldown_until integer,
    last_activated_at_count integer,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);

CREATE TABLE public.lore_pool_entries (
    id uuid NOT NULL,
    lore_pool_id uuid NOT NULL,
    lore_entry_id uuid NOT NULL,
    weight integer DEFAULT 100 NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    override boolean DEFAULT false NOT NULL,
    scored boolean DEFAULT false NOT NULL,
    CONSTRAINT lore_pool_entries_weight_positive CHECK ((weight >= 0))
);

CREATE TABLE public.lore_pools (
    id uuid NOT NULL,
    name character varying(255) NOT NULL,
    description text,
    max_activations integer DEFAULT 1 NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    user_id uuid,
    frozen_listing_id uuid,
    mirror_of_id uuid,
    CONSTRAINT lore_pools_max_activations_positive CHECK ((max_activations >= 1))
);

CREATE TABLE public.mcp_calls (
    id uuid NOT NULL,
    token_id uuid NOT NULL,
    user_id uuid NOT NULL,
    tool character varying(255) NOT NULL,
    outcome character varying(255) NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL
);

CREATE TABLE public.mcp_tokens (
    id uuid NOT NULL,
    user_id uuid NOT NULL,
    name character varying(255) NOT NULL,
    access character varying(255) NOT NULL,
    token_hash bytea NOT NULL,
    hint character varying(255) NOT NULL,
    last_used_at timestamp(0) without time zone,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);

CREATE TABLE public.memory_character_books (
    id uuid NOT NULL,
    user_id uuid NOT NULL,
    character_id uuid NOT NULL,
    lore_book_id uuid NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);

CREATE TABLE public.memory_profiles (
    id uuid NOT NULL,
    name character varying(255) NOT NULL,
    "default" boolean DEFAULT false NOT NULL,
    ai_model_id uuid,
    memory_prompt_id uuid,
    consolidation_prompt_id uuid,
    compaction_prompt_id uuid,
    topical_clip_prompt_id uuid,
    temperature double precision,
    max_tokens integer DEFAULT 4096 NOT NULL,
    structured_output boolean DEFAULT false NOT NULL,
    title_format character varying(255) DEFAULT '[000] - {{title}}'::character varying NOT NULL,
    activation character varying(255) DEFAULT 'keyword'::character varying NOT NULL,
    outlet character varying(255) DEFAULT 'character'::character varying NOT NULL,
    placement character varying(255) DEFAULT 'after'::character varying NOT NULL,
    custom_outlet character varying(255),
    depth integer,
    order_mode character varying(255) DEFAULT 'auto'::character varying NOT NULL,
    "order" integer DEFAULT 100 NOT NULL,
    prevent_recursion boolean DEFAULT false NOT NULL,
    exclude_recursion boolean DEFAULT false NOT NULL,
    character_aware boolean DEFAULT true NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    group_memory_prompt_id uuid,
    user_id uuid,
    consolidation_title_format character varying(255) DEFAULT '[{{tier}} 000] - {{title}}'::character varying NOT NULL,
    character_memory_prompt_id uuid,
    clip_review_prompt_id uuid,
    clip_suggestions_prompt_id uuid,
    combine_clips_prompt_id uuid,
    search_vector tsvector GENERATED ALWAYS AS (setweight(to_tsvector('simple'::regconfig, (COALESCE(name, ''::character varying))::text), 'A'::"char")) STORED,
    cloned_from_type character varying(255),
    cloned_from_id uuid,
    frozen_listing_id uuid,
    mirror_of_id uuid,
    cloned_from_release_id uuid,
    CONSTRAINT memory_profiles_max_tokens_non_negative CHECK ((max_tokens >= 0))
);

CREATE TABLE public.memory_record_sources (
    id uuid NOT NULL,
    record_id uuid NOT NULL,
    source_id uuid NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);

CREATE TABLE public.memory_records (
    id uuid NOT NULL,
    lore_entry_id uuid NOT NULL,
    lore_book_id uuid,
    chat_id uuid,
    kind character varying(255) NOT NULL,
    tier integer,
    sequence integer,
    range_start integer,
    range_end integer,
    scene_fingerprint character varying(255),
    written_fingerprint character varying(255),
    consolidated_into_id uuid,
    disabled_by_consolidation boolean DEFAULT false NOT NULL,
    profile_id uuid,
    prompt_id uuid,
    side_prompt_id uuid,
    version integer,
    snapshot jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    canonical_id uuid,
    side_prompt_set_row_id uuid
);

CREATE TABLE public.memory_topic_suggestions (
    id uuid NOT NULL,
    chat_id uuid NOT NULL,
    lore_book_id uuid NOT NULL,
    topic character varying(255) NOT NULL,
    keywords character varying(255)[] DEFAULT ARRAY[]::character varying[] NOT NULL,
    record_id uuid,
    message_ids uuid[] DEFAULT ARRAY[]::uuid[] NOT NULL,
    job_id uuid,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);

CREATE TABLE public.message_attachments (
    id uuid NOT NULL,
    message_id uuid NOT NULL,
    attachment_id uuid NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL
);

CREATE TABLE public.message_bodies (
    id uuid NOT NULL,
    message_id uuid NOT NULL,
    content text NOT NULL,
    active boolean DEFAULT false NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    finish_reason character varying(255),
    prompt_tokens integer,
    completion_tokens integer,
    total_tokens integer,
    cost numeric,
    provider_model_id uuid,
    generating boolean DEFAULT false NOT NULL,
    error character varying(255),
    reasoning text,
    origin character varying(255) NOT NULL,
    source_body_id uuid,
    cost_estimated boolean DEFAULT false NOT NULL,
    generation_ms integer,
    guide text,
    expression character varying(255),
    expression_scores jsonb,
    expression_source character varying(255),
    expression_sprite_id uuid,
    search_vector tsvector GENERATED ALWAYS AS (setweight(to_tsvector('simple'::regconfig, COALESCE("left"(content, 262144), ''::text)), 'C'::"char")) STORED,
    reasoning_redacted text,
    reasoning_share_redacted text
);

CREATE TABLE public.message_body_attachments (
    id uuid NOT NULL,
    message_body_id uuid NOT NULL,
    attachment_id uuid NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL
);

CREATE TABLE public.message_body_embeddings (
    id uuid NOT NULL,
    message_body_id uuid NOT NULL,
    ai_model_id uuid NOT NULL,
    content_hash bytea NOT NULL,
    embedding public.vector NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);

CREATE TABLE public.message_scratchpads (
    id uuid NOT NULL,
    content text NOT NULL,
    chat_id uuid NOT NULL,
    message_id uuid,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL
);

CREATE TABLE public.messages (
    id uuid NOT NULL,
    chat_id uuid NOT NULL,
    "position" integer,
    author_is_character boolean NOT NULL,
    author_character_id uuid,
    author_name character varying(255),
    visible_to_ai boolean DEFAULT true NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    draft boolean DEFAULT false NOT NULL,
    author_is_player boolean DEFAULT false NOT NULL,
    summary boolean DEFAULT false NOT NULL,
    author_user_id uuid,
    CONSTRAINT messages_draft_has_no_position CHECK (((draft AND ("position" IS NULL)) OR ((NOT draft) AND ("position" IS NOT NULL))))
);

CREATE TABLE public.moderation_bans (
    id uuid NOT NULL,
    kind character varying(255) NOT NULL,
    user_id uuid,
    value text,
    reason text NOT NULL,
    ends_at timestamp(0) without time zone,
    issued_by_id uuid,
    lifted_by_id uuid,
    report_id uuid,
    lifted_at timestamp(0) without time zone,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    CONSTRAINT value_matches_kind CHECK ((((kind)::text = 'account'::text) = (value IS NULL)))
);

CREATE TABLE public.moderation_log (
    id uuid NOT NULL,
    actor_id uuid,
    target_user_id uuid,
    action character varying(255) NOT NULL,
    subject_type character varying(255),
    subject_id uuid,
    details jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL
);

CREATE TABLE public.moderation_reports (
    id uuid NOT NULL,
    reporter_id uuid,
    subject_type character varying(255) NOT NULL,
    subject_id uuid NOT NULL,
    subject_user_id uuid,
    snapshot text NOT NULL,
    reason text NOT NULL,
    status character varying(255) DEFAULT 'open'::character varying NOT NULL,
    resolved_by_id uuid,
    resolved_at timestamp(0) without time zone,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    source character varying(255) DEFAULT 'user'::character varying NOT NULL,
    findings jsonb[] DEFAULT ARRAY[]::jsonb[] NOT NULL,
    CONSTRAINT reporter_matches_source CHECK ((((source)::text = 'user'::text) = (reporter_id IS NOT NULL)))
);

CREATE TABLE public.moderation_rules (
    id uuid NOT NULL,
    name text NOT NULL,
    kind character varying(255) NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    content_types character varying(255)[] DEFAULT ARRAY[]::character varying[] NOT NULL,
    pattern text,
    case_sensitive boolean DEFAULT false NOT NULL,
    regex_action character varying(255) DEFAULT 'flag'::character varying NOT NULL,
    url text,
    secret bytea,
    webhook_mode character varying(255) DEFAULT 'sync'::character varying NOT NULL,
    timeout_ms integer DEFAULT 10000 NOT NULL,
    callback_timeout_minutes integer DEFAULT 1440 NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);

CREATE TABLE public.moderation_warnings (
    id uuid NOT NULL,
    user_id uuid NOT NULL,
    issued_by_id uuid,
    report_id uuid,
    reason text NOT NULL,
    acknowledged_at timestamp(0) without time zone,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);

CREATE TABLE public.notifications (
    id uuid NOT NULL,
    user_id uuid NOT NULL,
    kind character varying(255) NOT NULL,
    title text NOT NULL,
    body text,
    icon text,
    chat_id uuid,
    message_id uuid,
    job_id uuid,
    expires_at timestamp(0) without time zone,
    inserted_at timestamp(0) without time zone NOT NULL,
    lore_book_id uuid,
    tier integer,
    share_id uuid,
    chat_member_id uuid
);

CREATE TABLE public.origins (
    id uuid NOT NULL,
    kind character varying(255) NOT NULL,
    record_id uuid NOT NULL,
    origin_id uuid NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);

CREATE TABLE public.permission_grants (
    id uuid NOT NULL,
    group_id uuid,
    user_id uuid,
    key character varying(255) NOT NULL,
    effect character varying(255),
    limit_value bigint,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    CONSTRAINT exactly_one_holder CHECK ((num_nonnulls(group_id, user_id) = 1))
);

CREATE TABLE public.permission_group_members (
    id uuid NOT NULL,
    group_id uuid NOT NULL,
    user_id uuid NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL
);

CREATE TABLE public.permission_groups (
    id uuid NOT NULL,
    name character varying(255) NOT NULL,
    description text,
    system_key character varying(255),
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);

CREATE TABLE public.prompt_bindings (
    id uuid NOT NULL,
    prompt_id uuid NOT NULL,
    scope character varying(255) NOT NULL,
    provider_id uuid,
    ai_model_id uuid,
    character_id uuid,
    chat_id uuid,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);

CREATE TABLE public.prompt_blocks (
    id uuid NOT NULL,
    name character varying(255) NOT NULL,
    description text,
    role character varying(255) DEFAULT 'system'::character varying NOT NULL,
    content text,
    enabled boolean DEFAULT true NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    kind character varying(255) DEFAULT 'template'::character varying NOT NULL,
    user_id uuid,
    speaker_roles character varying(255) DEFAULT 'responder'::character varying NOT NULL,
    search_vector tsvector GENERATED ALWAYS AS (((setweight(to_tsvector('simple'::regconfig, (COALESCE(name, ''::character varying))::text), 'A'::"char") || setweight(to_tsvector('simple'::regconfig, COALESCE("left"(description, 262144), ''::text)), 'B'::"char")) || setweight(to_tsvector('simple'::regconfig, COALESCE("left"(content, 262144), ''::text)), 'C'::"char"))) STORED,
    site_visibility character varying(255) DEFAULT 'readable'::character varying NOT NULL,
    cloned_from_type character varying(255),
    cloned_from_id uuid,
    frozen_listing_id uuid,
    mirror_of_id uuid,
    cloned_from_release_id uuid,
    role_tag character varying(255),
    forbid_overrides boolean DEFAULT false NOT NULL
);

CREATE TABLE public.prompt_outlets (
    id uuid NOT NULL,
    key character varying(255) NOT NULL,
    name character varying(255) NOT NULL,
    description text,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    user_id uuid,
    search_vector tsvector GENERATED ALWAYS AS (((setweight(to_tsvector('simple'::regconfig, (COALESCE(name, ''::character varying))::text), 'A'::"char") || setweight(to_tsvector('simple'::regconfig, (COALESCE(key, ''::character varying))::text), 'A'::"char")) || setweight(to_tsvector('simple'::regconfig, COALESCE("left"(description, 262144), ''::text)), 'B'::"char"))) STORED,
    cloned_from_type character varying(255),
    cloned_from_id uuid,
    frozen_listing_id uuid,
    mirror_of_id uuid,
    cloned_from_release_id uuid
);

CREATE TABLE public.prompt_prompt_blocks (
    id uuid NOT NULL,
    prompt_id uuid NOT NULL,
    block_id uuid NOT NULL,
    "position" integer NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);

CREATE TABLE public.prompt_snapshots (
    id uuid NOT NULL,
    message_body_id uuid NOT NULL,
    ai_model_id uuid,
    tokenizer character varying(255),
    sections jsonb[] DEFAULT ARRAY[]::jsonb[] NOT NULL,
    lore jsonb DEFAULT '{}'::jsonb NOT NULL,
    request jsonb,
    response jsonb,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    variable_writes jsonb[] DEFAULT ARRAY[]::jsonb[] NOT NULL,
    template_errors character varying(255)[] DEFAULT ARRAY[]::character varying[] NOT NULL,
    injections jsonb[] DEFAULT ARRAY[]::jsonb[] NOT NULL,
    context jsonb,
    protected jsonb[] DEFAULT ARRAY[]::jsonb[] NOT NULL
);

CREATE TABLE public.prompts (
    id uuid NOT NULL,
    name character varying(255) NOT NULL,
    description text,
    enabled boolean DEFAULT true NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    purpose character varying(255) DEFAULT 'roleplay'::character varying NOT NULL,
    user_id uuid,
    thinking character varying(255),
    search_vector tsvector GENERATED ALWAYS AS ((setweight(to_tsvector('simple'::regconfig, (COALESCE(name, ''::character varying))::text), 'A'::"char") || setweight(to_tsvector('simple'::regconfig, COALESCE("left"(description, 262144), ''::text)), 'B'::"char"))) STORED,
    site_visibility character varying(255) DEFAULT 'readable'::character varying NOT NULL,
    cloned_from_type character varying(255),
    cloned_from_id uuid,
    frozen_listing_id uuid,
    mirror_of_id uuid,
    cloned_from_release_id uuid
);

CREATE TABLE public.provider_models (
    id uuid NOT NULL,
    provider_id uuid NOT NULL,
    ai_model_id uuid NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    api_model_id_override character varying(255),
    weight integer DEFAULT 1 NOT NULL,
    last_used_at timestamp without time zone,
    use_count integer DEFAULT 0 NOT NULL,
    selection_deadline double precision DEFAULT 0.0 NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    extra_body jsonb DEFAULT '{}'::jsonb NOT NULL,
    thinking_dialect character varying(255),
    sampler_dialect character varying(255),
    CONSTRAINT provider_models_weight_positive CHECK ((weight >= 1))
);

CREATE TABLE public.providers (
    id uuid NOT NULL,
    name character varying(255) NOT NULL,
    adapter character varying(255) NOT NULL,
    base_url character varying(255) NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    priority integer DEFAULT 3 NOT NULL,
    extra_headers jsonb DEFAULT '{}'::jsonb NOT NULL,
    extra_body jsonb DEFAULT '{}'::jsonb NOT NULL,
    request_timeout_ms integer DEFAULT 120000 NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    thinking_dialect character varying(255),
    max_concurrency integer DEFAULT 1 NOT NULL,
    prompt_progress boolean DEFAULT false NOT NULL,
    user_id uuid,
    api_key bytea,
    sampler_dialect character varying(255),
    search_vector tsvector GENERATED ALWAYS AS ((setweight(to_tsvector('simple'::regconfig, (COALESCE(name, ''::character varying))::text), 'A'::"char") || setweight(to_tsvector('simple'::regconfig, (COALESCE(base_url, ''::character varying))::text), 'D'::"char"))) STORED,
    CONSTRAINT providers_max_concurrency_positive CHECK ((max_concurrency >= 1)),
    CONSTRAINT providers_priority_range CHECK (((priority >= 1) AND (priority <= 5))),
    CONSTRAINT providers_request_timeout_positive CHECK ((request_timeout_ms > 0))
);

CREATE TABLE public.push_subscriptions (
    id uuid NOT NULL,
    user_id uuid NOT NULL,
    endpoint text NOT NULL,
    p256dh bytea NOT NULL,
    auth bytea NOT NULL,
    label character varying(255) NOT NULL,
    last_success_at timestamp(0) without time zone,
    last_failure character varying(255),
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);

CREATE TABLE public.script_dependencies (
    script_id uuid NOT NULL,
    dependency_id uuid NOT NULL,
    CONSTRAINT script_dependencies_not_self CHECK ((script_id <> dependency_id))
);

CREATE TABLE public.scripts (
    id uuid NOT NULL,
    name character varying(255) NOT NULL,
    description text,
    priority integer DEFAULT 0 NOT NULL,
    trigger character varying(255) DEFAULT 'ai_generation'::character varying NOT NULL,
    body text DEFAULT ''::text NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    last_error text,
    last_error_at timestamp(0) without time zone,
    last_success_at timestamp(0) without time zone,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    user_id uuid,
    search_vector tsvector GENERATED ALWAYS AS (((setweight(to_tsvector('simple'::regconfig, (COALESCE(name, ''::character varying))::text), 'A'::"char") || setweight(to_tsvector('simple'::regconfig, COALESCE("left"(description, 262144), ''::text)), 'B'::"char")) || setweight(to_tsvector('simple'::regconfig, COALESCE("left"(body, 262144), ''::text)), 'C'::"char"))) STORED,
    site_visibility character varying(255) DEFAULT 'readable'::character varying NOT NULL,
    cloned_from_type character varying(255),
    cloned_from_id uuid,
    frozen_listing_id uuid,
    mirror_of_id uuid,
    cloned_from_release_id uuid
);

CREATE TABLE public.settings (
    id uuid NOT NULL,
    user_id uuid,
    "values" jsonb DEFAULT '{}'::jsonb NOT NULL,
    locked_keys character varying(255)[] DEFAULT ARRAY[]::character varying[] NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);

CREATE TABLE public.shares (
    id uuid NOT NULL,
    item_type character varying(255) NOT NULL,
    item_id uuid NOT NULL,
    role character varying(255) DEFAULT 'editor'::character varying NOT NULL,
    status character varying(255) DEFAULT 'pending'::character varying NOT NULL,
    owner_id uuid NOT NULL,
    user_id uuid NOT NULL,
    invited_by_id uuid,
    accepted_at timestamp(0) without time zone,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    visibility character varying(255) DEFAULT 'runtime_only'::character varying NOT NULL,
    ai_mode character varying(255),
    token_limit_per_day integer,
    catalog_listing_id uuid
);

CREATE TABLE public.side_prompt_checkpoints (
    id uuid NOT NULL,
    chat_id uuid NOT NULL,
    side_prompt_id uuid NOT NULL,
    last_position integer NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    side_prompt_set_row_id uuid
);

CREATE TABLE public.side_prompt_set_rows (
    id uuid NOT NULL,
    side_prompt_set_id uuid NOT NULL,
    side_prompt_id uuid NOT NULL,
    "position" integer NOT NULL,
    label character varying(255),
    macro_values jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    mirror_of_id uuid
);

CREATE TABLE public.side_prompt_sets (
    id uuid NOT NULL,
    name character varying(255) NOT NULL,
    user_id uuid,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    cloned_from_type character varying(255),
    cloned_from_id uuid,
    frozen_listing_id uuid,
    mirror_of_id uuid,
    cloned_from_release_id uuid
);

CREATE TABLE public.side_prompts (
    id uuid NOT NULL,
    name character varying(255) NOT NULL,
    prompt_id uuid NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    run_after_memory boolean DEFAULT false NOT NULL,
    run_on_interval boolean DEFAULT false NOT NULL,
    "interval" integer DEFAULT 20 NOT NULL,
    previous_memories integer DEFAULT 0 NOT NULL,
    use_context boolean DEFAULT false NOT NULL,
    target_book_id uuid,
    title character varying(255),
    keywords character varying(255)[] DEFAULT ARRAY[]::character varying[] NOT NULL,
    activation character varying(255) DEFAULT 'constant'::character varying NOT NULL,
    outlet character varying(255) DEFAULT 'character'::character varying NOT NULL,
    placement character varying(255) DEFAULT 'after'::character varying NOT NULL,
    custom_outlet character varying(255),
    depth integer,
    "order" integer DEFAULT 100 NOT NULL,
    prevent_recursion boolean DEFAULT false NOT NULL,
    exclude_recursion boolean DEFAULT false NOT NULL,
    ignore_budget boolean DEFAULT false NOT NULL,
    profile_id uuid,
    save_versions boolean DEFAULT false NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    user_id uuid,
    macros character varying(255)[] DEFAULT ARRAY[]::character varying[] NOT NULL,
    search_vector tsvector GENERATED ALWAYS AS (((setweight(to_tsvector('simple'::regconfig, (COALESCE(name, ''::character varying))::text), 'A'::"char") || setweight(to_tsvector('simple'::regconfig, (COALESCE(title, ''::character varying))::text), 'B'::"char")) || setweight(to_tsvector('simple'::regconfig, COALESCE(public.mythweaver_search_words((keywords)::text[]), ''::text)), 'B'::"char"))) STORED,
    cloned_from_type character varying(255),
    cloned_from_id uuid,
    frozen_listing_id uuid,
    mirror_of_id uuid,
    cloned_from_release_id uuid
);

CREATE TABLE public.site_opt_outs (
    id uuid NOT NULL,
    user_id uuid NOT NULL,
    item_type character varying(255) NOT NULL,
    item_id uuid NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL
);

CREATE TABLE public.subscriber_toggles (
    id uuid NOT NULL,
    user_id uuid NOT NULL,
    item_type character varying(255) NOT NULL,
    item_id uuid NOT NULL,
    enabled boolean NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    consent_hash character varying(255)
);

CREATE TABLE public.tag_parents (
    id uuid NOT NULL,
    tag_id uuid NOT NULL,
    parent_tag_id uuid NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    CONSTRAINT tag_parents_not_self CHECK ((tag_id <> parent_tag_id))
);

CREATE TABLE public.taggings (
    id uuid NOT NULL,
    tag_id uuid NOT NULL,
    character_id uuid,
    chat_id uuid,
    lore_entry_id uuid,
    lore_book_id uuid,
    prompt_id uuid,
    prompt_block_id uuid,
    script_id uuid,
    ai_model_id uuid,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    CONSTRAINT taggings_one_target CHECK ((num_nonnulls(character_id, chat_id, lore_entry_id, lore_book_id, prompt_id, prompt_block_id, script_id, ai_model_id) = 1))
);

CREATE TABLE public.tags (
    id uuid NOT NULL,
    user_id uuid,
    namespace character varying(255) DEFAULT ''::character varying NOT NULL,
    name character varying(255) NOT NULL,
    ideal_id uuid,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    CONSTRAINT tags_ideal_not_self CHECK ((ideal_id <> id))
);

CREATE TABLE public.users (
    id uuid NOT NULL,
    email public.citext NOT NULL,
    nickname character varying(255),
    hashed_password character varying(255),
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    role character varying(255) DEFAULT 'user'::character varying NOT NULL,
    handle character varying(255) NOT NULL,
    browser_locale character varying(255)
);

CREATE TABLE public.users_tokens (
    id uuid NOT NULL,
    user_id uuid NOT NULL,
    token bytea NOT NULL,
    context character varying(255) NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    sudo_until timestamp(0) without time zone
);

CREATE TABLE public.variables (
    id uuid NOT NULL,
    chat_id uuid,
    key character varying(255) NOT NULL,
    value jsonb NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    user_id uuid
);

ALTER TABLE ONLY public.access_grants
    ADD CONSTRAINT access_grants_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.account_fingerprints
    ADD CONSTRAINT account_fingerprints_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.ai_models
    ADD CONSTRAINT ai_models_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.assistant_tool_calls
    ADD CONSTRAINT assistant_tool_calls_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.attachments
    ADD CONSTRAINT attachments_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.catalog_listings
    ADD CONSTRAINT catalog_listings_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.catalog_releases
    ADD CONSTRAINT catalog_releases_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.character_attachments
    ADD CONSTRAINT character_attachments_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.character_favorites
    ADD CONSTRAINT character_favorites_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.character_locks
    ADD CONSTRAINT character_locks_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.character_outfits
    ADD CONSTRAINT character_outfits_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.character_sprites
    ADD CONSTRAINT character_sprites_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.characters
    ADD CONSTRAINT characters_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.chat_injections
    ADD CONSTRAINT chat_injections_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.chat_members
    ADD CONSTRAINT chat_members_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.chat_memory_settings
    ADD CONSTRAINT chat_memory_settings_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.chat_participants
    ADD CONSTRAINT chat_participants_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.chats
    ADD CONSTRAINT chats_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.expression_profiles
    ADD CONSTRAINT expression_profiles_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.generation_jobs
    ADD CONSTRAINT generation_jobs_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.generation_stats
    ADD CONSTRAINT generation_stats_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.lore_book_characters
    ADD CONSTRAINT lore_book_characters_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.lore_book_chats
    ADD CONSTRAINT lore_book_chats_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.lore_book_entries
    ADD CONSTRAINT lore_book_entries_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.lore_book_filter_tags
    ADD CONSTRAINT lore_book_filter_tags_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.lore_book_rule_conditions
    ADD CONSTRAINT lore_book_rule_conditions_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.lore_book_rules
    ADD CONSTRAINT lore_book_rules_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.lore_books
    ADD CONSTRAINT lore_books_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.lore_entries
    ADD CONSTRAINT lore_entries_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.lore_entry_characters
    ADD CONSTRAINT lore_entry_characters_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.lore_entry_embeddings
    ADD CONSTRAINT lore_entry_embeddings_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.lore_entry_filter_tags
    ADD CONSTRAINT lore_entry_filter_tags_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.lore_entry_states
    ADD CONSTRAINT lore_entry_states_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.lore_pool_entries
    ADD CONSTRAINT lore_pool_entries_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.lore_pools
    ADD CONSTRAINT lore_pools_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.mcp_calls
    ADD CONSTRAINT mcp_calls_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.mcp_tokens
    ADD CONSTRAINT mcp_tokens_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.memory_character_books
    ADD CONSTRAINT memory_character_books_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.memory_profiles
    ADD CONSTRAINT memory_profiles_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.memory_record_sources
    ADD CONSTRAINT memory_record_sources_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.memory_records
    ADD CONSTRAINT memory_records_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.memory_topic_suggestions
    ADD CONSTRAINT memory_topic_suggestions_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.message_attachments
    ADD CONSTRAINT message_attachments_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.message_bodies
    ADD CONSTRAINT message_bodies_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.message_body_attachments
    ADD CONSTRAINT message_body_attachments_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.message_body_embeddings
    ADD CONSTRAINT message_body_embeddings_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.message_scratchpads
    ADD CONSTRAINT message_scratchpads_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.messages
    ADD CONSTRAINT messages_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.moderation_bans
    ADD CONSTRAINT moderation_bans_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.moderation_log
    ADD CONSTRAINT moderation_log_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.moderation_reports
    ADD CONSTRAINT moderation_reports_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.moderation_rules
    ADD CONSTRAINT moderation_rules_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.moderation_warnings
    ADD CONSTRAINT moderation_warnings_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT notifications_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.origins
    ADD CONSTRAINT origins_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.permission_grants
    ADD CONSTRAINT permission_grants_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.permission_group_members
    ADD CONSTRAINT permission_group_members_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.permission_groups
    ADD CONSTRAINT permission_groups_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.prompt_bindings
    ADD CONSTRAINT prompt_bindings_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.prompt_blocks
    ADD CONSTRAINT prompt_blocks_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.prompt_outlets
    ADD CONSTRAINT prompt_outlets_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.prompt_prompt_blocks
    ADD CONSTRAINT prompt_prompt_blocks_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.prompt_snapshots
    ADD CONSTRAINT prompt_snapshots_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.prompts
    ADD CONSTRAINT prompts_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.provider_models
    ADD CONSTRAINT provider_models_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.providers
    ADD CONSTRAINT providers_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.push_subscriptions
    ADD CONSTRAINT push_subscriptions_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.scripts
    ADD CONSTRAINT scripts_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.settings
    ADD CONSTRAINT settings_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.shares
    ADD CONSTRAINT shares_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.side_prompt_checkpoints
    ADD CONSTRAINT side_prompt_checkpoints_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.side_prompt_set_rows
    ADD CONSTRAINT side_prompt_set_rows_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.side_prompt_sets
    ADD CONSTRAINT side_prompt_sets_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.side_prompts
    ADD CONSTRAINT side_prompts_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.site_opt_outs
    ADD CONSTRAINT site_opt_outs_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.subscriber_toggles
    ADD CONSTRAINT subscriber_toggles_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.tag_parents
    ADD CONSTRAINT tag_parents_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.taggings
    ADD CONSTRAINT taggings_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.tags
    ADD CONSTRAINT tags_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.users_tokens
    ADD CONSTRAINT users_tokens_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.variables
    ADD CONSTRAINT variables_pkey PRIMARY KEY (id);

CREATE INDEX access_grants_owner_id_index ON public.access_grants USING btree (owner_id);

CREATE UNIQUE INDEX access_grants_share_id_item_type_item_id_index ON public.access_grants USING btree (share_id, item_type, item_id);

CREATE INDEX access_grants_user_id_item_type_item_id_index ON public.access_grants USING btree (user_id, item_type, item_id);

CREATE INDEX account_fingerprints_kind_value_index ON public.account_fingerprints USING btree (kind, value);

CREATE INDEX account_fingerprints_last_seen_at_index ON public.account_fingerprints USING btree (last_seen_at);

CREATE UNIQUE INDEX account_fingerprints_user_id_kind_value_index ON public.account_fingerprints USING btree (user_id, kind, value);

CREATE UNIQUE INDEX ai_model_groups_ai_model_id_group_id_index ON public.ai_model_groups USING btree (ai_model_id, group_id);

CREATE INDEX ai_model_groups_group_id_index ON public.ai_model_groups USING btree (group_id);

CREATE INDEX ai_models_api_model_id_index ON public.ai_models USING btree (api_model_id);

CREATE INDEX ai_models_caption_model_id_index ON public.ai_models USING btree (caption_model_id);

CREATE INDEX ai_models_caption_prompt_id_index ON public.ai_models USING btree (caption_prompt_id);

CREATE INDEX ai_models_frozen_listing_id_index ON public.ai_models USING btree (frozen_listing_id);

CREATE INDEX ai_models_search_vector_index ON public.ai_models USING gin (search_vector);

CREATE UNIQUE INDEX ai_models_user_id_name_index ON public.ai_models USING btree (user_id, name) NULLS NOT DISTINCT WHERE (frozen_listing_id IS NULL);

CREATE INDEX assistant_tool_calls_chat_id_index ON public.assistant_tool_calls USING btree (chat_id);

CREATE UNIQUE INDEX assistant_tool_calls_message_id_position_index ON public.assistant_tool_calls USING btree (message_id, "position");

CREATE INDEX attachments_described_by_model_id_index ON public.attachments USING btree (described_by_model_id);

CREATE UNIQUE INDEX attachments_key_index ON public.attachments USING btree (key);

CREATE INDEX attachments_uploaded_by_id_index ON public.attachments USING btree (uploaded_by_id);

CREATE UNIQUE INDEX catalog_listings_item_type_item_id_index ON public.catalog_listings USING btree (item_type, item_id);

CREATE INDEX catalog_listings_owner_id_index ON public.catalog_listings USING btree (owner_id);

CREATE UNIQUE INDEX catalog_releases_listing_id_version_index ON public.catalog_releases USING btree (listing_id, version);

CREATE INDEX character_attachments_attachment_id_index ON public.character_attachments USING btree (attachment_id);

CREATE UNIQUE INDEX character_attachments_character_id_attachment_id_index ON public.character_attachments USING btree (character_id, attachment_id);

CREATE UNIQUE INDEX character_attachments_one_avatar_index ON public.character_attachments USING btree (character_id) WHERE ((role)::text = 'avatar'::text);

CREATE INDEX character_favorites_character_id_index ON public.character_favorites USING btree (character_id);

CREATE UNIQUE INDEX character_favorites_user_id_character_id_index ON public.character_favorites USING btree (user_id, character_id);

CREATE UNIQUE INDEX character_locks_chat_id_character_id_user_id_index ON public.character_locks USING btree (chat_id, character_id, user_id);

CREATE UNIQUE INDEX character_outfits_character_id_name_index ON public.character_outfits USING btree (character_id, name);

CREATE UNIQUE INDEX character_sprites_attachment_id_index ON public.character_sprites USING btree (attachment_id);

CREATE INDEX character_sprites_character_id_outfit_id_label_index ON public.character_sprites USING btree (character_id, outfit_id, label);

CREATE INDEX character_sprites_outfit_id_index ON public.character_sprites USING btree (outfit_id);

CREATE INDEX characters_expression_profile_id_index ON public.characters USING btree (expression_profile_id);

CREATE INDEX characters_frozen_listing_id_index ON public.characters USING btree (frozen_listing_id);

CREATE INDEX characters_search_vector_index ON public.characters USING gin (search_vector);

CREATE INDEX characters_user_id_index ON public.characters USING btree (user_id);

CREATE UNIQUE INDEX chat_injections_chat_id_key_index ON public.chat_injections USING btree (chat_id, key);

CREATE INDEX chat_members_ai_model_id_index ON public.chat_members USING btree (ai_model_id);

CREATE UNIQUE INDEX chat_members_chat_id_user_id_index ON public.chat_members USING btree (chat_id, user_id);

CREATE INDEX chat_members_invited_by_id_status_index ON public.chat_members USING btree (invited_by_id, status);

CREATE INDEX chat_members_user_id_status_index ON public.chat_members USING btree (user_id, status);

CREATE UNIQUE INDEX chat_memory_settings_chat_id_index ON public.chat_memory_settings USING btree (chat_id);

CREATE INDEX chat_memory_settings_memory_book_id_index ON public.chat_memory_settings USING btree (memory_book_id);

CREATE INDEX chat_memory_settings_profile_id_index ON public.chat_memory_settings USING btree (profile_id);

CREATE INDEX chat_memory_settings_side_prompt_set_id_index ON public.chat_memory_settings USING btree (side_prompt_set_id);

CREATE INDEX chat_participants_ai_model_id_index ON public.chat_participants USING btree (ai_model_id);

CREATE INDEX chat_participants_character_id_index ON public.chat_participants USING btree (character_id);

CREATE UNIQUE INDEX chat_participants_chat_id_character_id_index ON public.chat_participants USING btree (chat_id, character_id);

CREATE INDEX chat_participants_chat_id_position_index ON public.chat_participants USING btree (chat_id, "position");

CREATE INDEX chat_participants_outfit_id_index ON public.chat_participants USING btree (outfit_id);

CREATE INDEX chats_ai_model_id_index ON public.chats USING btree (ai_model_id);

CREATE INDEX chats_player_character_id_index ON public.chats USING btree (player_character_id);

CREATE INDEX chats_search_vector_index ON public.chats USING gin (search_vector);

CREATE INDEX chats_user_id_index ON public.chats USING btree (user_id);

CREATE INDEX expression_profiles_frozen_listing_id_index ON public.expression_profiles USING btree (frozen_listing_id);

CREATE UNIQUE INDEX expression_profiles_user_id_name_index ON public.expression_profiles USING btree (user_id, name) NULLS NOT DISTINCT WHERE (frozen_listing_id IS NULL);

CREATE INDEX generation_jobs_ai_model_id_index ON public.generation_jobs USING btree (ai_model_id);

CREATE INDEX generation_jobs_chat_id_status_index ON public.generation_jobs USING btree (chat_id, status);

CREATE INDEX generation_jobs_parent_id_index ON public.generation_jobs USING btree (parent_id);

CREATE INDEX generation_jobs_provider_id_ai_model_id_tag_started_at_index ON public.generation_jobs USING btree (provider_id, ai_model_id, tag, started_at);

CREATE INDEX generation_jobs_status_index ON public.generation_jobs USING btree (status);

CREATE INDEX generation_jobs_user_id_index ON public.generation_jobs USING btree (user_id);

CREATE INDEX generation_stats_finished_at_index ON public.generation_stats USING btree (finished_at);

CREATE INDEX generation_stats_user_id_finished_at_index ON public.generation_stats USING btree (user_id, finished_at);

CREATE INDEX lore_book_characters_character_id_index ON public.lore_book_characters USING btree (character_id);

CREATE UNIQUE INDEX lore_book_characters_lore_book_id_character_id_index ON public.lore_book_characters USING btree (lore_book_id, character_id);

CREATE INDEX lore_book_chats_chat_id_index ON public.lore_book_chats USING btree (chat_id);

CREATE UNIQUE INDEX lore_book_chats_lore_book_id_chat_id_index ON public.lore_book_chats USING btree (lore_book_id, chat_id);

CREATE UNIQUE INDEX lore_book_entries_lore_book_id_lore_entry_id_index ON public.lore_book_entries USING btree (lore_book_id, lore_entry_id);

CREATE INDEX lore_book_entries_lore_entry_id_index ON public.lore_book_entries USING btree (lore_entry_id);

CREATE UNIQUE INDEX lore_book_filter_tags_lore_book_id_tag_id_index ON public.lore_book_filter_tags USING btree (lore_book_id, tag_id);

CREATE INDEX lore_book_filter_tags_tag_id_index ON public.lore_book_filter_tags USING btree (tag_id);

CREATE INDEX lore_book_rule_conditions_character_id_index ON public.lore_book_rule_conditions USING btree (character_id);

CREATE INDEX lore_book_rule_conditions_chat_id_index ON public.lore_book_rule_conditions USING btree (chat_id);

CREATE INDEX lore_book_rule_conditions_lore_book_rule_id_index ON public.lore_book_rule_conditions USING btree (lore_book_rule_id);

CREATE INDEX lore_book_rules_lore_book_id_index ON public.lore_book_rules USING btree (lore_book_id);

CREATE INDEX lore_books_frozen_listing_id_index ON public.lore_books USING btree (frozen_listing_id);

CREATE INDEX lore_books_search_vector_index ON public.lore_books USING gin (search_vector);

CREATE INDEX lore_books_user_id_index ON public.lore_books USING btree (user_id);

CREATE UNIQUE INDEX lore_books_user_id_name_index ON public.lore_books USING btree (user_id, name) NULLS NOT DISTINCT WHERE (frozen_listing_id IS NULL);

CREATE INDEX lore_entries_activation_index ON public.lore_entries USING btree (activation);

CREATE INDEX lore_entries_custom_outlet_index ON public.lore_entries USING btree (custom_outlet);

CREATE INDEX lore_entries_frozen_listing_id_index ON public.lore_entries USING btree (frozen_listing_id);

CREATE INDEX lore_entries_search_vector_index ON public.lore_entries USING gin (search_vector);

CREATE INDEX lore_entries_user_id_index ON public.lore_entries USING btree (user_id);

CREATE INDEX lore_entry_characters_character_id_index ON public.lore_entry_characters USING btree (character_id);

CREATE UNIQUE INDEX lore_entry_characters_lore_entry_id_character_id_index ON public.lore_entry_characters USING btree (lore_entry_id, character_id);

CREATE INDEX lore_entry_embeddings_ai_model_id_index ON public.lore_entry_embeddings USING btree (ai_model_id);

CREATE UNIQUE INDEX lore_entry_embeddings_lore_entry_id_ai_model_id_index ON public.lore_entry_embeddings USING btree (lore_entry_id, ai_model_id);

CREATE UNIQUE INDEX lore_entry_filter_tags_lore_entry_id_tag_id_index ON public.lore_entry_filter_tags USING btree (lore_entry_id, tag_id);

CREATE INDEX lore_entry_filter_tags_tag_id_index ON public.lore_entry_filter_tags USING btree (tag_id);

CREATE UNIQUE INDEX lore_entry_states_chat_id_lore_entry_id_index ON public.lore_entry_states USING btree (chat_id, lore_entry_id);

CREATE INDEX lore_entry_states_lore_entry_id_index ON public.lore_entry_states USING btree (lore_entry_id);

CREATE INDEX lore_pool_entries_lore_entry_id_index ON public.lore_pool_entries USING btree (lore_entry_id);

CREATE UNIQUE INDEX lore_pool_entries_lore_pool_id_lore_entry_id_index ON public.lore_pool_entries USING btree (lore_pool_id, lore_entry_id);

CREATE INDEX lore_pools_frozen_listing_id_index ON public.lore_pools USING btree (frozen_listing_id);

CREATE INDEX lore_pools_user_id_index ON public.lore_pools USING btree (user_id);

CREATE UNIQUE INDEX lore_pools_user_id_name_index ON public.lore_pools USING btree (user_id, name) NULLS NOT DISTINCT WHERE (frozen_listing_id IS NULL);

CREATE INDEX mcp_calls_inserted_at_index ON public.mcp_calls USING btree (inserted_at);

CREATE INDEX mcp_calls_token_id_inserted_at_index ON public.mcp_calls USING btree (token_id, inserted_at);

CREATE INDEX mcp_calls_user_id_index ON public.mcp_calls USING btree (user_id);

CREATE UNIQUE INDEX mcp_tokens_token_hash_index ON public.mcp_tokens USING btree (token_hash);

CREATE UNIQUE INDEX mcp_tokens_user_id_name_index ON public.mcp_tokens USING btree (user_id, name);

CREATE INDEX memory_character_books_lore_book_id_index ON public.memory_character_books USING btree (lore_book_id);

CREATE UNIQUE INDEX memory_character_books_user_id_character_id_index ON public.memory_character_books USING btree (user_id, character_id);

CREATE INDEX memory_profiles_ai_model_id_index ON public.memory_profiles USING btree (ai_model_id);

CREATE INDEX memory_profiles_character_memory_prompt_id_index ON public.memory_profiles USING btree (character_memory_prompt_id);

CREATE INDEX memory_profiles_clip_review_prompt_id_index ON public.memory_profiles USING btree (clip_review_prompt_id);

CREATE INDEX memory_profiles_clip_suggestions_prompt_id_index ON public.memory_profiles USING btree (clip_suggestions_prompt_id);

CREATE INDEX memory_profiles_combine_clips_prompt_id_index ON public.memory_profiles USING btree (combine_clips_prompt_id);

CREATE INDEX memory_profiles_compaction_prompt_id_index ON public.memory_profiles USING btree (compaction_prompt_id);

CREATE INDEX memory_profiles_consolidation_prompt_id_index ON public.memory_profiles USING btree (consolidation_prompt_id);

CREATE INDEX memory_profiles_frozen_listing_id_index ON public.memory_profiles USING btree (frozen_listing_id);

CREATE INDEX memory_profiles_group_memory_prompt_id_index ON public.memory_profiles USING btree (group_memory_prompt_id);

CREATE INDEX memory_profiles_memory_prompt_id_index ON public.memory_profiles USING btree (memory_prompt_id);

CREATE UNIQUE INDEX memory_profiles_one_default ON public.memory_profiles USING btree (user_id) NULLS NOT DISTINCT WHERE "default";

CREATE INDEX memory_profiles_search_vector_index ON public.memory_profiles USING gin (search_vector);

CREATE INDEX memory_profiles_topical_clip_prompt_id_index ON public.memory_profiles USING btree (topical_clip_prompt_id);

CREATE INDEX memory_profiles_user_id_index ON public.memory_profiles USING btree (user_id);

CREATE UNIQUE INDEX memory_profiles_user_id_name_index ON public.memory_profiles USING btree (user_id, name) NULLS NOT DISTINCT WHERE (frozen_listing_id IS NULL);

CREATE UNIQUE INDEX memory_record_sources_record_id_source_id_index ON public.memory_record_sources USING btree (record_id, source_id);

CREATE INDEX memory_record_sources_source_id_index ON public.memory_record_sources USING btree (source_id);

CREATE INDEX memory_records_canonical_id_index ON public.memory_records USING btree (canonical_id);

CREATE INDEX memory_records_chat_id_kind_index ON public.memory_records USING btree (chat_id, kind);

CREATE INDEX memory_records_consolidated_into_id_index ON public.memory_records USING btree (consolidated_into_id);

CREATE INDEX memory_records_lore_book_id_kind_tier_index ON public.memory_records USING btree (lore_book_id, kind, tier);

CREATE UNIQUE INDEX memory_records_lore_entry_id_index ON public.memory_records USING btree (lore_entry_id);

CREATE INDEX memory_records_profile_id_index ON public.memory_records USING btree (profile_id);

CREATE INDEX memory_records_prompt_id_index ON public.memory_records USING btree (prompt_id);

CREATE INDEX memory_records_side_prompt_id_index ON public.memory_records USING btree (side_prompt_id);

CREATE INDEX memory_records_side_prompt_set_row_id_index ON public.memory_records USING btree (side_prompt_set_row_id);

CREATE UNIQUE INDEX memory_topic_suggestions_book_topic_index ON public.memory_topic_suggestions USING btree (lore_book_id, lower((topic)::text));

CREATE INDEX memory_topic_suggestions_chat_id_index ON public.memory_topic_suggestions USING btree (chat_id);

CREATE INDEX message_attachments_attachment_id_index ON public.message_attachments USING btree (attachment_id);

CREATE UNIQUE INDEX message_attachments_message_id_attachment_id_index ON public.message_attachments USING btree (message_id, attachment_id);

CREATE UNIQUE INDEX message_bodies_active_message_id_index ON public.message_bodies USING btree (message_id) WHERE active;

CREATE INDEX message_bodies_expression_sprite_id_index ON public.message_bodies USING btree (expression_sprite_id);

CREATE INDEX message_bodies_message_id_index ON public.message_bodies USING btree (message_id);

CREATE INDEX message_bodies_provider_model_id_index ON public.message_bodies USING btree (provider_model_id);

CREATE INDEX message_bodies_search_vector_index ON public.message_bodies USING gin (search_vector);

CREATE INDEX message_bodies_source_body_id_index ON public.message_bodies USING btree (source_body_id);

CREATE INDEX message_body_attachments_attachment_id_index ON public.message_body_attachments USING btree (attachment_id);

CREATE UNIQUE INDEX message_body_attachments_message_body_id_attachment_id_index ON public.message_body_attachments USING btree (message_body_id, attachment_id);

CREATE INDEX message_body_embeddings_ai_model_id_index ON public.message_body_embeddings USING btree (ai_model_id);

CREATE UNIQUE INDEX message_body_embeddings_message_body_id_ai_model_id_index ON public.message_body_embeddings USING btree (message_body_id, ai_model_id);

CREATE INDEX message_scratchpads_chat_id_index ON public.message_scratchpads USING btree (chat_id);

CREATE INDEX messages_author_character_id_index ON public.messages USING btree (author_character_id);

CREATE UNIQUE INDEX messages_chat_id_position_index ON public.messages USING btree (chat_id, "position");

CREATE UNIQUE INDEX messages_draft_chat_index ON public.messages USING btree (chat_id) WHERE draft;

CREATE INDEX moderation_bans_inserted_at_index ON public.moderation_bans USING btree (inserted_at);

CREATE INDEX moderation_bans_kind_value_index ON public.moderation_bans USING btree (kind, value) WHERE (lifted_at IS NULL);

CREATE INDEX moderation_bans_user_id_index ON public.moderation_bans USING btree (user_id);

CREATE INDEX moderation_log_actor_id_index ON public.moderation_log USING btree (actor_id);

CREATE INDEX moderation_log_inserted_at_index ON public.moderation_log USING btree (inserted_at);

CREATE INDEX moderation_log_target_user_id_index ON public.moderation_log USING btree (target_user_id);

CREATE UNIQUE INDEX moderation_reports_one_open_index ON public.moderation_reports USING btree (reporter_id, subject_type, subject_id) WHERE ((status)::text = 'open'::text);

CREATE UNIQUE INDEX moderation_reports_one_open_rule_index ON public.moderation_reports USING btree (subject_type, subject_id) WHERE (((status)::text = 'open'::text) AND ((source)::text = 'rule'::text));

CREATE INDEX moderation_reports_reporter_id_index ON public.moderation_reports USING btree (reporter_id);

CREATE INDEX moderation_reports_status_inserted_at_index ON public.moderation_reports USING btree (status, inserted_at);

CREATE INDEX moderation_reports_subject_type_subject_id_status_index ON public.moderation_reports USING btree (subject_type, subject_id, status);

CREATE INDEX moderation_reports_subject_user_id_index ON public.moderation_reports USING btree (subject_user_id);

CREATE INDEX moderation_warnings_user_id_acknowledged_at_index ON public.moderation_warnings USING btree (user_id, acknowledged_at);

CREATE INDEX notifications_chat_id_index ON public.notifications USING btree (chat_id);

CREATE INDEX notifications_chat_member_id_index ON public.notifications USING btree (chat_member_id);

CREATE UNIQUE INDEX notifications_consolidation_ready_index ON public.notifications USING btree (user_id, lore_book_id, tier) WHERE ((kind)::text = 'consolidation_ready'::text);

CREATE INDEX notifications_expires_at_index ON public.notifications USING btree (expires_at);

CREATE INDEX notifications_job_id_index ON public.notifications USING btree (job_id);

CREATE INDEX notifications_lore_book_id_index ON public.notifications USING btree (lore_book_id);

CREATE INDEX notifications_message_id_index ON public.notifications USING btree (message_id);

CREATE INDEX notifications_share_id_index ON public.notifications USING btree (share_id);

CREATE INDEX notifications_user_id_inserted_at_index ON public.notifications USING btree (user_id, inserted_at);

CREATE INDEX origins_kind_origin_id_index ON public.origins USING btree (kind, origin_id);

CREATE UNIQUE INDEX origins_kind_record_id_index ON public.origins USING btree (kind, record_id);

CREATE UNIQUE INDEX permission_grants_group_id_key_index ON public.permission_grants USING btree (group_id, key) WHERE (group_id IS NOT NULL);

CREATE UNIQUE INDEX permission_grants_user_id_key_index ON public.permission_grants USING btree (user_id, key) WHERE (user_id IS NOT NULL);

CREATE UNIQUE INDEX permission_group_members_group_id_user_id_index ON public.permission_group_members USING btree (group_id, user_id);

CREATE INDEX permission_group_members_user_id_index ON public.permission_group_members USING btree (user_id);

CREATE UNIQUE INDEX permission_groups_lower_name_index ON public.permission_groups USING btree (lower((name)::text));

CREATE UNIQUE INDEX permission_groups_system_key_index ON public.permission_groups USING btree (system_key);

CREATE INDEX prompt_bindings_ai_model_id_index ON public.prompt_bindings USING btree (ai_model_id);

CREATE INDEX prompt_bindings_character_id_index ON public.prompt_bindings USING btree (character_id);

CREATE INDEX prompt_bindings_chat_id_index ON public.prompt_bindings USING btree (chat_id);

CREATE INDEX prompt_bindings_prompt_id_index ON public.prompt_bindings USING btree (prompt_id);

CREATE INDEX prompt_bindings_provider_id_index ON public.prompt_bindings USING btree (provider_id);

CREATE INDEX prompt_bindings_scope_index ON public.prompt_bindings USING btree (scope);

CREATE UNIQUE INDEX prompt_bindings_scope_target_index ON public.prompt_bindings USING btree (scope, prompt_id, provider_id, ai_model_id, character_id, chat_id) NULLS NOT DISTINCT;

CREATE INDEX prompt_blocks_frozen_listing_id_index ON public.prompt_blocks USING btree (frozen_listing_id);

CREATE INDEX prompt_blocks_search_vector_index ON public.prompt_blocks USING gin (search_vector);

CREATE INDEX prompt_blocks_user_id_index ON public.prompt_blocks USING btree (user_id);

CREATE UNIQUE INDEX prompt_blocks_user_id_name_index ON public.prompt_blocks USING btree (user_id, name) NULLS NOT DISTINCT WHERE (frozen_listing_id IS NULL);

CREATE INDEX prompt_outlets_frozen_listing_id_index ON public.prompt_outlets USING btree (frozen_listing_id);

CREATE INDEX prompt_outlets_search_vector_index ON public.prompt_outlets USING gin (search_vector);

CREATE INDEX prompt_outlets_user_id_index ON public.prompt_outlets USING btree (user_id);

CREATE UNIQUE INDEX prompt_outlets_user_id_key_index ON public.prompt_outlets USING btree (user_id, key) NULLS NOT DISTINCT WHERE (frozen_listing_id IS NULL);

CREATE INDEX prompt_prompt_blocks_block_id_index ON public.prompt_prompt_blocks USING btree (block_id);

CREATE UNIQUE INDEX prompt_prompt_blocks_prompt_id_block_id_index ON public.prompt_prompt_blocks USING btree (prompt_id, block_id);

CREATE UNIQUE INDEX prompt_prompt_blocks_prompt_id_position_index ON public.prompt_prompt_blocks USING btree (prompt_id, "position");

CREATE INDEX prompt_snapshots_ai_model_id_index ON public.prompt_snapshots USING btree (ai_model_id);

CREATE UNIQUE INDEX prompt_snapshots_message_body_id_index ON public.prompt_snapshots USING btree (message_body_id);

CREATE INDEX prompts_frozen_listing_id_index ON public.prompts USING btree (frozen_listing_id);

CREATE INDEX prompts_search_vector_index ON public.prompts USING gin (search_vector);

CREATE INDEX prompts_user_id_index ON public.prompts USING btree (user_id);

CREATE UNIQUE INDEX prompts_user_id_name_index ON public.prompts USING btree (user_id, name) NULLS NOT DISTINCT WHERE (frozen_listing_id IS NULL);

CREATE INDEX provider_models_ai_model_id_selection_deadline_index ON public.provider_models USING btree (ai_model_id, selection_deadline);

CREATE UNIQUE INDEX provider_models_provider_id_ai_model_id_index ON public.provider_models USING btree (provider_id, ai_model_id);

CREATE INDEX providers_search_vector_index ON public.providers USING gin (search_vector);

CREATE UNIQUE INDEX providers_user_id_name_index ON public.providers USING btree (user_id, name) NULLS NOT DISTINCT;

CREATE UNIQUE INDEX push_subscriptions_endpoint_index ON public.push_subscriptions USING btree (endpoint);

CREATE INDEX push_subscriptions_user_id_index ON public.push_subscriptions USING btree (user_id);

CREATE INDEX script_dependencies_dependency_id_index ON public.script_dependencies USING btree (dependency_id);

CREATE UNIQUE INDEX script_dependencies_script_id_dependency_id_index ON public.script_dependencies USING btree (script_id, dependency_id);

CREATE INDEX scripts_frozen_listing_id_index ON public.scripts USING btree (frozen_listing_id);

CREATE INDEX scripts_search_vector_index ON public.scripts USING gin (search_vector);

CREATE INDEX scripts_trigger_index ON public.scripts USING btree (trigger);

CREATE INDEX scripts_user_id_index ON public.scripts USING btree (user_id);

CREATE UNIQUE INDEX scripts_user_id_name_index ON public.scripts USING btree (user_id, name) NULLS NOT DISTINCT WHERE (frozen_listing_id IS NULL);

CREATE UNIQUE INDEX settings_user_id_index ON public.settings USING btree (user_id) NULLS NOT DISTINCT;

CREATE INDEX shares_catalog_listing_id_index ON public.shares USING btree (catalog_listing_id);

CREATE INDEX shares_invited_by_id_status_index ON public.shares USING btree (invited_by_id, status);

CREATE UNIQUE INDEX shares_item_type_item_id_user_id_index ON public.shares USING btree (item_type, item_id, user_id);

CREATE INDEX shares_owner_id_status_index ON public.shares USING btree (owner_id, status);

CREATE INDEX shares_user_id_index ON public.shares USING btree (user_id);

CREATE UNIQUE INDEX side_prompt_checkpoints_chat_side_prompt_row_index ON public.side_prompt_checkpoints USING btree (chat_id, side_prompt_id, side_prompt_set_row_id) NULLS NOT DISTINCT;

CREATE INDEX side_prompt_checkpoints_side_prompt_id_index ON public.side_prompt_checkpoints USING btree (side_prompt_id);

CREATE INDEX side_prompt_set_rows_side_prompt_id_index ON public.side_prompt_set_rows USING btree (side_prompt_id);

CREATE INDEX side_prompt_set_rows_side_prompt_set_id_position_index ON public.side_prompt_set_rows USING btree (side_prompt_set_id, "position");

CREATE INDEX side_prompt_sets_frozen_listing_id_index ON public.side_prompt_sets USING btree (frozen_listing_id);

CREATE UNIQUE INDEX side_prompt_sets_user_id_name_index ON public.side_prompt_sets USING btree (user_id, name) NULLS NOT DISTINCT WHERE (frozen_listing_id IS NULL);

CREATE INDEX side_prompts_frozen_listing_id_index ON public.side_prompts USING btree (frozen_listing_id);

CREATE INDEX side_prompts_profile_id_index ON public.side_prompts USING btree (profile_id);

CREATE INDEX side_prompts_prompt_id_index ON public.side_prompts USING btree (prompt_id);

CREATE INDEX side_prompts_search_vector_index ON public.side_prompts USING gin (search_vector);

CREATE INDEX side_prompts_target_book_id_index ON public.side_prompts USING btree (target_book_id);

CREATE INDEX side_prompts_user_id_index ON public.side_prompts USING btree (user_id);

CREATE UNIQUE INDEX side_prompts_user_id_name_index ON public.side_prompts USING btree (user_id, name) NULLS NOT DISTINCT WHERE (frozen_listing_id IS NULL);

CREATE UNIQUE INDEX site_opt_outs_user_id_item_type_item_id_index ON public.site_opt_outs USING btree (user_id, item_type, item_id);

CREATE UNIQUE INDEX subscriber_toggles_user_id_item_type_item_id_index ON public.subscriber_toggles USING btree (user_id, item_type, item_id);

CREATE INDEX tag_parents_parent_tag_id_index ON public.tag_parents USING btree (parent_tag_id);

CREATE UNIQUE INDEX tag_parents_tag_id_parent_tag_id_index ON public.tag_parents USING btree (tag_id, parent_tag_id);

CREATE INDEX taggings_ai_model_id_index ON public.taggings USING btree (ai_model_id);

CREATE INDEX taggings_character_id_index ON public.taggings USING btree (character_id);

CREATE INDEX taggings_chat_id_index ON public.taggings USING btree (chat_id);

CREATE INDEX taggings_lore_book_id_index ON public.taggings USING btree (lore_book_id);

CREATE INDEX taggings_lore_entry_id_index ON public.taggings USING btree (lore_entry_id);

CREATE INDEX taggings_prompt_block_id_index ON public.taggings USING btree (prompt_block_id);

CREATE INDEX taggings_prompt_id_index ON public.taggings USING btree (prompt_id);

CREATE INDEX taggings_script_id_index ON public.taggings USING btree (script_id);

CREATE UNIQUE INDEX taggings_tag_id_ai_model_id_index ON public.taggings USING btree (tag_id, ai_model_id);

CREATE UNIQUE INDEX taggings_tag_id_character_id_index ON public.taggings USING btree (tag_id, character_id);

CREATE UNIQUE INDEX taggings_tag_id_chat_id_index ON public.taggings USING btree (tag_id, chat_id);

CREATE UNIQUE INDEX taggings_tag_id_lore_book_id_index ON public.taggings USING btree (tag_id, lore_book_id);

CREATE UNIQUE INDEX taggings_tag_id_lore_entry_id_index ON public.taggings USING btree (tag_id, lore_entry_id);

CREATE UNIQUE INDEX taggings_tag_id_prompt_block_id_index ON public.taggings USING btree (tag_id, prompt_block_id);

CREATE UNIQUE INDEX taggings_tag_id_prompt_id_index ON public.taggings USING btree (tag_id, prompt_id);

CREATE UNIQUE INDEX taggings_tag_id_script_id_index ON public.taggings USING btree (tag_id, script_id);

CREATE INDEX tags_ideal_id_index ON public.tags USING btree (ideal_id);

CREATE UNIQUE INDEX tags_user_id_namespace_name_index ON public.tags USING btree (user_id, namespace, name) NULLS NOT DISTINCT;

CREATE UNIQUE INDEX users_email_index ON public.users USING btree (email);

CREATE UNIQUE INDEX users_handle_index ON public.users USING btree (handle);

CREATE UNIQUE INDEX users_tokens_context_token_index ON public.users_tokens USING btree (context, token);

CREATE INDEX users_tokens_user_id_index ON public.users_tokens USING btree (user_id);

CREATE UNIQUE INDEX variables_chat_key_index ON public.variables USING btree (chat_id, key) WHERE (chat_id IS NOT NULL);

CREATE UNIQUE INDEX variables_global_key_index ON public.variables USING btree (user_id, key) NULLS NOT DISTINCT WHERE (chat_id IS NULL);

ALTER TABLE ONLY public.access_grants
    ADD CONSTRAINT access_grants_owner_id_fkey FOREIGN KEY (owner_id) REFERENCES public.users(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.access_grants
    ADD CONSTRAINT access_grants_share_id_fkey FOREIGN KEY (share_id) REFERENCES public.shares(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.access_grants
    ADD CONSTRAINT access_grants_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.account_fingerprints
    ADD CONSTRAINT account_fingerprints_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.ai_model_groups
    ADD CONSTRAINT ai_model_groups_ai_model_id_fkey FOREIGN KEY (ai_model_id) REFERENCES public.ai_models(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.ai_model_groups
    ADD CONSTRAINT ai_model_groups_group_id_fkey FOREIGN KEY (group_id) REFERENCES public.permission_groups(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.ai_models
    ADD CONSTRAINT ai_models_caption_model_id_fkey FOREIGN KEY (caption_model_id) REFERENCES public.ai_models(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.ai_models
    ADD CONSTRAINT ai_models_caption_prompt_id_fkey FOREIGN KEY (caption_prompt_id) REFERENCES public.prompts(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.ai_models
    ADD CONSTRAINT ai_models_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.assistant_tool_calls
    ADD CONSTRAINT assistant_tool_calls_chat_id_fkey FOREIGN KEY (chat_id) REFERENCES public.chats(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.assistant_tool_calls
    ADD CONSTRAINT assistant_tool_calls_message_id_fkey FOREIGN KEY (message_id) REFERENCES public.messages(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.attachments
    ADD CONSTRAINT attachments_described_by_model_id_fkey FOREIGN KEY (described_by_model_id) REFERENCES public.ai_models(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.attachments
    ADD CONSTRAINT attachments_uploaded_by_id_fkey FOREIGN KEY (uploaded_by_id) REFERENCES public.users(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.catalog_listings
    ADD CONSTRAINT catalog_listings_hidden_by_id_fkey FOREIGN KEY (hidden_by_id) REFERENCES public.users(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.catalog_listings
    ADD CONSTRAINT catalog_listings_owner_id_fkey FOREIGN KEY (owner_id) REFERENCES public.users(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.catalog_releases
    ADD CONSTRAINT catalog_releases_listing_id_fkey FOREIGN KEY (listing_id) REFERENCES public.catalog_listings(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.catalog_releases
    ADD CONSTRAINT catalog_releases_published_by_id_fkey FOREIGN KEY (published_by_id) REFERENCES public.users(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.character_attachments
    ADD CONSTRAINT character_attachments_attachment_id_fkey FOREIGN KEY (attachment_id) REFERENCES public.attachments(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.character_attachments
    ADD CONSTRAINT character_attachments_character_id_fkey FOREIGN KEY (character_id) REFERENCES public.characters(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.character_favorites
    ADD CONSTRAINT character_favorites_character_id_fkey FOREIGN KEY (character_id) REFERENCES public.characters(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.character_favorites
    ADD CONSTRAINT character_favorites_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.character_locks
    ADD CONSTRAINT character_locks_character_id_fkey FOREIGN KEY (character_id) REFERENCES public.characters(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.character_locks
    ADD CONSTRAINT character_locks_chat_id_fkey FOREIGN KEY (chat_id) REFERENCES public.chats(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.character_locks
    ADD CONSTRAINT character_locks_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.character_outfits
    ADD CONSTRAINT character_outfits_character_id_fkey FOREIGN KEY (character_id) REFERENCES public.characters(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.character_sprites
    ADD CONSTRAINT character_sprites_attachment_id_fkey FOREIGN KEY (attachment_id) REFERENCES public.attachments(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.character_sprites
    ADD CONSTRAINT character_sprites_character_id_fkey FOREIGN KEY (character_id) REFERENCES public.characters(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.character_sprites
    ADD CONSTRAINT character_sprites_outfit_id_fkey FOREIGN KEY (outfit_id) REFERENCES public.character_outfits(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.characters
    ADD CONSTRAINT characters_expression_profile_id_fkey FOREIGN KEY (expression_profile_id) REFERENCES public.expression_profiles(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.characters
    ADD CONSTRAINT characters_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.chat_injections
    ADD CONSTRAINT chat_injections_chat_id_fkey FOREIGN KEY (chat_id) REFERENCES public.chats(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.chat_members
    ADD CONSTRAINT chat_members_ai_model_id_fkey FOREIGN KEY (ai_model_id) REFERENCES public.ai_models(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.chat_members
    ADD CONSTRAINT chat_members_chat_id_fkey FOREIGN KEY (chat_id) REFERENCES public.chats(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.chat_members
    ADD CONSTRAINT chat_members_invited_by_id_fkey FOREIGN KEY (invited_by_id) REFERENCES public.users(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.chat_members
    ADD CONSTRAINT chat_members_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.chat_memory_settings
    ADD CONSTRAINT chat_memory_settings_chat_id_fkey FOREIGN KEY (chat_id) REFERENCES public.chats(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.chat_memory_settings
    ADD CONSTRAINT chat_memory_settings_memory_book_id_fkey FOREIGN KEY (memory_book_id) REFERENCES public.lore_books(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.chat_memory_settings
    ADD CONSTRAINT chat_memory_settings_profile_id_fkey FOREIGN KEY (profile_id) REFERENCES public.memory_profiles(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.chat_memory_settings
    ADD CONSTRAINT chat_memory_settings_side_prompt_set_id_fkey FOREIGN KEY (side_prompt_set_id) REFERENCES public.side_prompt_sets(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.chat_participants
    ADD CONSTRAINT chat_participants_added_by_id_fkey FOREIGN KEY (added_by_id) REFERENCES public.users(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.chat_participants
    ADD CONSTRAINT chat_participants_ai_model_id_fkey FOREIGN KEY (ai_model_id) REFERENCES public.ai_models(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.chat_participants
    ADD CONSTRAINT chat_participants_character_id_fkey FOREIGN KEY (character_id) REFERENCES public.characters(id) ON DELETE RESTRICT;

ALTER TABLE ONLY public.chat_participants
    ADD CONSTRAINT chat_participants_chat_id_fkey FOREIGN KEY (chat_id) REFERENCES public.chats(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.chat_participants
    ADD CONSTRAINT chat_participants_outfit_id_fkey FOREIGN KEY (outfit_id) REFERENCES public.character_outfits(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.chats
    ADD CONSTRAINT chats_ai_model_id_fkey FOREIGN KEY (ai_model_id) REFERENCES public.ai_models(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.chats
    ADD CONSTRAINT chats_player_character_id_fkey FOREIGN KEY (player_character_id) REFERENCES public.characters(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.chats
    ADD CONSTRAINT chats_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.expression_profiles
    ADD CONSTRAINT expression_profiles_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.generation_jobs
    ADD CONSTRAINT generation_jobs_ai_model_id_fkey FOREIGN KEY (ai_model_id) REFERENCES public.ai_models(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.generation_jobs
    ADD CONSTRAINT generation_jobs_chat_id_fkey FOREIGN KEY (chat_id) REFERENCES public.chats(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.generation_jobs
    ADD CONSTRAINT generation_jobs_parent_id_fkey FOREIGN KEY (parent_id) REFERENCES public.generation_jobs(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.generation_jobs
    ADD CONSTRAINT generation_jobs_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES public.providers(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.generation_jobs
    ADD CONSTRAINT generation_jobs_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.generation_stats
    ADD CONSTRAINT generation_stats_ai_model_id_fkey FOREIGN KEY (ai_model_id) REFERENCES public.ai_models(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.generation_stats
    ADD CONSTRAINT generation_stats_chat_id_fkey FOREIGN KEY (chat_id) REFERENCES public.chats(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.generation_stats
    ADD CONSTRAINT generation_stats_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES public.providers(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.generation_stats
    ADD CONSTRAINT generation_stats_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.lore_book_characters
    ADD CONSTRAINT lore_book_characters_character_id_fkey FOREIGN KEY (character_id) REFERENCES public.characters(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.lore_book_characters
    ADD CONSTRAINT lore_book_characters_lore_book_id_fkey FOREIGN KEY (lore_book_id) REFERENCES public.lore_books(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.lore_book_chats
    ADD CONSTRAINT lore_book_chats_chat_id_fkey FOREIGN KEY (chat_id) REFERENCES public.chats(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.lore_book_chats
    ADD CONSTRAINT lore_book_chats_lore_book_id_fkey FOREIGN KEY (lore_book_id) REFERENCES public.lore_books(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.lore_book_entries
    ADD CONSTRAINT lore_book_entries_lore_book_id_fkey FOREIGN KEY (lore_book_id) REFERENCES public.lore_books(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.lore_book_entries
    ADD CONSTRAINT lore_book_entries_lore_entry_id_fkey FOREIGN KEY (lore_entry_id) REFERENCES public.lore_entries(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.lore_book_filter_tags
    ADD CONSTRAINT lore_book_filter_tags_lore_book_id_fkey FOREIGN KEY (lore_book_id) REFERENCES public.lore_books(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.lore_book_filter_tags
    ADD CONSTRAINT lore_book_filter_tags_tag_id_fkey FOREIGN KEY (tag_id) REFERENCES public.tags(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.lore_book_rule_conditions
    ADD CONSTRAINT lore_book_rule_conditions_character_id_fkey FOREIGN KEY (character_id) REFERENCES public.characters(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.lore_book_rule_conditions
    ADD CONSTRAINT lore_book_rule_conditions_chat_id_fkey FOREIGN KEY (chat_id) REFERENCES public.chats(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.lore_book_rule_conditions
    ADD CONSTRAINT lore_book_rule_conditions_lore_book_rule_id_fkey FOREIGN KEY (lore_book_rule_id) REFERENCES public.lore_book_rules(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.lore_book_rules
    ADD CONSTRAINT lore_book_rules_lore_book_id_fkey FOREIGN KEY (lore_book_id) REFERENCES public.lore_books(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.lore_books
    ADD CONSTRAINT lore_books_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.lore_entries
    ADD CONSTRAINT lore_entries_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.lore_entry_characters
    ADD CONSTRAINT lore_entry_characters_character_id_fkey FOREIGN KEY (character_id) REFERENCES public.characters(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.lore_entry_characters
    ADD CONSTRAINT lore_entry_characters_lore_entry_id_fkey FOREIGN KEY (lore_entry_id) REFERENCES public.lore_entries(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.lore_entry_embeddings
    ADD CONSTRAINT lore_entry_embeddings_ai_model_id_fkey FOREIGN KEY (ai_model_id) REFERENCES public.ai_models(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.lore_entry_embeddings
    ADD CONSTRAINT lore_entry_embeddings_lore_entry_id_fkey FOREIGN KEY (lore_entry_id) REFERENCES public.lore_entries(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.lore_entry_filter_tags
    ADD CONSTRAINT lore_entry_filter_tags_lore_entry_id_fkey FOREIGN KEY (lore_entry_id) REFERENCES public.lore_entries(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.lore_entry_filter_tags
    ADD CONSTRAINT lore_entry_filter_tags_tag_id_fkey FOREIGN KEY (tag_id) REFERENCES public.tags(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.lore_entry_states
    ADD CONSTRAINT lore_entry_states_chat_id_fkey FOREIGN KEY (chat_id) REFERENCES public.chats(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.lore_entry_states
    ADD CONSTRAINT lore_entry_states_lore_entry_id_fkey FOREIGN KEY (lore_entry_id) REFERENCES public.lore_entries(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.lore_pool_entries
    ADD CONSTRAINT lore_pool_entries_lore_entry_id_fkey FOREIGN KEY (lore_entry_id) REFERENCES public.lore_entries(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.lore_pool_entries
    ADD CONSTRAINT lore_pool_entries_lore_pool_id_fkey FOREIGN KEY (lore_pool_id) REFERENCES public.lore_pools(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.lore_pools
    ADD CONSTRAINT lore_pools_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.mcp_calls
    ADD CONSTRAINT mcp_calls_token_id_fkey FOREIGN KEY (token_id) REFERENCES public.mcp_tokens(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.mcp_calls
    ADD CONSTRAINT mcp_calls_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.mcp_tokens
    ADD CONSTRAINT mcp_tokens_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.memory_character_books
    ADD CONSTRAINT memory_character_books_character_id_fkey FOREIGN KEY (character_id) REFERENCES public.characters(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.memory_character_books
    ADD CONSTRAINT memory_character_books_lore_book_id_fkey FOREIGN KEY (lore_book_id) REFERENCES public.lore_books(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.memory_character_books
    ADD CONSTRAINT memory_character_books_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.memory_profiles
    ADD CONSTRAINT memory_profiles_ai_model_id_fkey FOREIGN KEY (ai_model_id) REFERENCES public.ai_models(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.memory_profiles
    ADD CONSTRAINT memory_profiles_character_memory_prompt_id_fkey FOREIGN KEY (character_memory_prompt_id) REFERENCES public.prompts(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.memory_profiles
    ADD CONSTRAINT memory_profiles_clip_review_prompt_id_fkey FOREIGN KEY (clip_review_prompt_id) REFERENCES public.prompts(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.memory_profiles
    ADD CONSTRAINT memory_profiles_clip_suggestions_prompt_id_fkey FOREIGN KEY (clip_suggestions_prompt_id) REFERENCES public.prompts(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.memory_profiles
    ADD CONSTRAINT memory_profiles_combine_clips_prompt_id_fkey FOREIGN KEY (combine_clips_prompt_id) REFERENCES public.prompts(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.memory_profiles
    ADD CONSTRAINT memory_profiles_compaction_prompt_id_fkey FOREIGN KEY (compaction_prompt_id) REFERENCES public.prompts(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.memory_profiles
    ADD CONSTRAINT memory_profiles_consolidation_prompt_id_fkey FOREIGN KEY (consolidation_prompt_id) REFERENCES public.prompts(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.memory_profiles
    ADD CONSTRAINT memory_profiles_group_memory_prompt_id_fkey FOREIGN KEY (group_memory_prompt_id) REFERENCES public.prompts(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.memory_profiles
    ADD CONSTRAINT memory_profiles_memory_prompt_id_fkey FOREIGN KEY (memory_prompt_id) REFERENCES public.prompts(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.memory_profiles
    ADD CONSTRAINT memory_profiles_topical_clip_prompt_id_fkey FOREIGN KEY (topical_clip_prompt_id) REFERENCES public.prompts(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.memory_profiles
    ADD CONSTRAINT memory_profiles_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.memory_record_sources
    ADD CONSTRAINT memory_record_sources_record_id_fkey FOREIGN KEY (record_id) REFERENCES public.memory_records(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.memory_record_sources
    ADD CONSTRAINT memory_record_sources_source_id_fkey FOREIGN KEY (source_id) REFERENCES public.memory_records(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.memory_records
    ADD CONSTRAINT memory_records_canonical_id_fkey FOREIGN KEY (canonical_id) REFERENCES public.memory_records(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.memory_records
    ADD CONSTRAINT memory_records_chat_id_fkey FOREIGN KEY (chat_id) REFERENCES public.chats(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.memory_records
    ADD CONSTRAINT memory_records_consolidated_into_id_fkey FOREIGN KEY (consolidated_into_id) REFERENCES public.memory_records(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.memory_records
    ADD CONSTRAINT memory_records_lore_book_id_fkey FOREIGN KEY (lore_book_id) REFERENCES public.lore_books(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.memory_records
    ADD CONSTRAINT memory_records_lore_entry_id_fkey FOREIGN KEY (lore_entry_id) REFERENCES public.lore_entries(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.memory_records
    ADD CONSTRAINT memory_records_profile_id_fkey FOREIGN KEY (profile_id) REFERENCES public.memory_profiles(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.memory_records
    ADD CONSTRAINT memory_records_prompt_id_fkey FOREIGN KEY (prompt_id) REFERENCES public.prompts(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.memory_records
    ADD CONSTRAINT memory_records_side_prompt_id_fkey FOREIGN KEY (side_prompt_id) REFERENCES public.side_prompts(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.memory_records
    ADD CONSTRAINT memory_records_side_prompt_set_row_id_fkey FOREIGN KEY (side_prompt_set_row_id) REFERENCES public.side_prompt_set_rows(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.memory_topic_suggestions
    ADD CONSTRAINT memory_topic_suggestions_chat_id_fkey FOREIGN KEY (chat_id) REFERENCES public.chats(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.memory_topic_suggestions
    ADD CONSTRAINT memory_topic_suggestions_job_id_fkey FOREIGN KEY (job_id) REFERENCES public.generation_jobs(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.memory_topic_suggestions
    ADD CONSTRAINT memory_topic_suggestions_lore_book_id_fkey FOREIGN KEY (lore_book_id) REFERENCES public.lore_books(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.memory_topic_suggestions
    ADD CONSTRAINT memory_topic_suggestions_record_id_fkey FOREIGN KEY (record_id) REFERENCES public.memory_records(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.message_attachments
    ADD CONSTRAINT message_attachments_attachment_id_fkey FOREIGN KEY (attachment_id) REFERENCES public.attachments(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.message_attachments
    ADD CONSTRAINT message_attachments_message_id_fkey FOREIGN KEY (message_id) REFERENCES public.messages(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.message_bodies
    ADD CONSTRAINT message_bodies_expression_sprite_id_fkey FOREIGN KEY (expression_sprite_id) REFERENCES public.character_sprites(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.message_bodies
    ADD CONSTRAINT message_bodies_message_id_fkey FOREIGN KEY (message_id) REFERENCES public.messages(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.message_bodies
    ADD CONSTRAINT message_bodies_provider_model_id_fkey FOREIGN KEY (provider_model_id) REFERENCES public.provider_models(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.message_bodies
    ADD CONSTRAINT message_bodies_source_body_id_fkey FOREIGN KEY (source_body_id) REFERENCES public.message_bodies(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.message_body_attachments
    ADD CONSTRAINT message_body_attachments_attachment_id_fkey FOREIGN KEY (attachment_id) REFERENCES public.attachments(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.message_body_attachments
    ADD CONSTRAINT message_body_attachments_message_body_id_fkey FOREIGN KEY (message_body_id) REFERENCES public.message_bodies(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.message_body_embeddings
    ADD CONSTRAINT message_body_embeddings_ai_model_id_fkey FOREIGN KEY (ai_model_id) REFERENCES public.ai_models(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.message_body_embeddings
    ADD CONSTRAINT message_body_embeddings_message_body_id_fkey FOREIGN KEY (message_body_id) REFERENCES public.message_bodies(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.message_scratchpads
    ADD CONSTRAINT message_scratchpads_chat_id_fkey FOREIGN KEY (chat_id) REFERENCES public.chats(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.message_scratchpads
    ADD CONSTRAINT message_scratchpads_message_id_fkey FOREIGN KEY (message_id) REFERENCES public.messages(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.messages
    ADD CONSTRAINT messages_author_character_id_fkey FOREIGN KEY (author_character_id) REFERENCES public.characters(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.messages
    ADD CONSTRAINT messages_author_user_id_fkey FOREIGN KEY (author_user_id) REFERENCES public.users(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.messages
    ADD CONSTRAINT messages_chat_id_fkey FOREIGN KEY (chat_id) REFERENCES public.chats(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.moderation_bans
    ADD CONSTRAINT moderation_bans_issued_by_id_fkey FOREIGN KEY (issued_by_id) REFERENCES public.users(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.moderation_bans
    ADD CONSTRAINT moderation_bans_lifted_by_id_fkey FOREIGN KEY (lifted_by_id) REFERENCES public.users(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.moderation_bans
    ADD CONSTRAINT moderation_bans_report_id_fkey FOREIGN KEY (report_id) REFERENCES public.moderation_reports(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.moderation_bans
    ADD CONSTRAINT moderation_bans_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.moderation_log
    ADD CONSTRAINT moderation_log_actor_id_fkey FOREIGN KEY (actor_id) REFERENCES public.users(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.moderation_log
    ADD CONSTRAINT moderation_log_target_user_id_fkey FOREIGN KEY (target_user_id) REFERENCES public.users(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.moderation_reports
    ADD CONSTRAINT moderation_reports_reporter_id_fkey FOREIGN KEY (reporter_id) REFERENCES public.users(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.moderation_reports
    ADD CONSTRAINT moderation_reports_resolved_by_id_fkey FOREIGN KEY (resolved_by_id) REFERENCES public.users(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.moderation_reports
    ADD CONSTRAINT moderation_reports_subject_user_id_fkey FOREIGN KEY (subject_user_id) REFERENCES public.users(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.moderation_warnings
    ADD CONSTRAINT moderation_warnings_issued_by_id_fkey FOREIGN KEY (issued_by_id) REFERENCES public.users(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.moderation_warnings
    ADD CONSTRAINT moderation_warnings_report_id_fkey FOREIGN KEY (report_id) REFERENCES public.moderation_reports(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.moderation_warnings
    ADD CONSTRAINT moderation_warnings_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT notifications_chat_id_fkey FOREIGN KEY (chat_id) REFERENCES public.chats(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT notifications_chat_member_id_fkey FOREIGN KEY (chat_member_id) REFERENCES public.chat_members(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT notifications_job_id_fkey FOREIGN KEY (job_id) REFERENCES public.generation_jobs(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT notifications_lore_book_id_fkey FOREIGN KEY (lore_book_id) REFERENCES public.lore_books(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT notifications_message_id_fkey FOREIGN KEY (message_id) REFERENCES public.messages(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT notifications_share_id_fkey FOREIGN KEY (share_id) REFERENCES public.shares(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT notifications_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.permission_grants
    ADD CONSTRAINT permission_grants_group_id_fkey FOREIGN KEY (group_id) REFERENCES public.permission_groups(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.permission_grants
    ADD CONSTRAINT permission_grants_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.permission_group_members
    ADD CONSTRAINT permission_group_members_group_id_fkey FOREIGN KEY (group_id) REFERENCES public.permission_groups(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.permission_group_members
    ADD CONSTRAINT permission_group_members_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.prompt_bindings
    ADD CONSTRAINT prompt_bindings_ai_model_id_fkey FOREIGN KEY (ai_model_id) REFERENCES public.ai_models(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.prompt_bindings
    ADD CONSTRAINT prompt_bindings_character_id_fkey FOREIGN KEY (character_id) REFERENCES public.characters(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.prompt_bindings
    ADD CONSTRAINT prompt_bindings_chat_id_fkey FOREIGN KEY (chat_id) REFERENCES public.chats(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.prompt_bindings
    ADD CONSTRAINT prompt_bindings_prompt_id_fkey FOREIGN KEY (prompt_id) REFERENCES public.prompts(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.prompt_bindings
    ADD CONSTRAINT prompt_bindings_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES public.providers(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.prompt_blocks
    ADD CONSTRAINT prompt_blocks_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.prompt_outlets
    ADD CONSTRAINT prompt_outlets_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.prompt_prompt_blocks
    ADD CONSTRAINT prompt_prompt_blocks_block_id_fkey FOREIGN KEY (block_id) REFERENCES public.prompt_blocks(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.prompt_prompt_blocks
    ADD CONSTRAINT prompt_prompt_blocks_prompt_id_fkey FOREIGN KEY (prompt_id) REFERENCES public.prompts(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.prompt_snapshots
    ADD CONSTRAINT prompt_snapshots_ai_model_id_fkey FOREIGN KEY (ai_model_id) REFERENCES public.ai_models(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.prompt_snapshots
    ADD CONSTRAINT prompt_snapshots_message_body_id_fkey FOREIGN KEY (message_body_id) REFERENCES public.message_bodies(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.prompts
    ADD CONSTRAINT prompts_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.provider_models
    ADD CONSTRAINT provider_models_ai_model_id_fkey FOREIGN KEY (ai_model_id) REFERENCES public.ai_models(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.provider_models
    ADD CONSTRAINT provider_models_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES public.providers(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.providers
    ADD CONSTRAINT providers_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.push_subscriptions
    ADD CONSTRAINT push_subscriptions_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.script_dependencies
    ADD CONSTRAINT script_dependencies_dependency_id_fkey FOREIGN KEY (dependency_id) REFERENCES public.scripts(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.script_dependencies
    ADD CONSTRAINT script_dependencies_script_id_fkey FOREIGN KEY (script_id) REFERENCES public.scripts(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.scripts
    ADD CONSTRAINT scripts_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.settings
    ADD CONSTRAINT settings_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.shares
    ADD CONSTRAINT shares_catalog_listing_id_fkey FOREIGN KEY (catalog_listing_id) REFERENCES public.catalog_listings(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.shares
    ADD CONSTRAINT shares_invited_by_id_fkey FOREIGN KEY (invited_by_id) REFERENCES public.users(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.shares
    ADD CONSTRAINT shares_owner_id_fkey FOREIGN KEY (owner_id) REFERENCES public.users(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.shares
    ADD CONSTRAINT shares_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.side_prompt_checkpoints
    ADD CONSTRAINT side_prompt_checkpoints_chat_id_fkey FOREIGN KEY (chat_id) REFERENCES public.chats(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.side_prompt_checkpoints
    ADD CONSTRAINT side_prompt_checkpoints_side_prompt_id_fkey FOREIGN KEY (side_prompt_id) REFERENCES public.side_prompts(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.side_prompt_checkpoints
    ADD CONSTRAINT side_prompt_checkpoints_side_prompt_set_row_id_fkey FOREIGN KEY (side_prompt_set_row_id) REFERENCES public.side_prompt_set_rows(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.side_prompt_set_rows
    ADD CONSTRAINT side_prompt_set_rows_side_prompt_id_fkey FOREIGN KEY (side_prompt_id) REFERENCES public.side_prompts(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.side_prompt_set_rows
    ADD CONSTRAINT side_prompt_set_rows_side_prompt_set_id_fkey FOREIGN KEY (side_prompt_set_id) REFERENCES public.side_prompt_sets(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.side_prompt_sets
    ADD CONSTRAINT side_prompt_sets_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.side_prompts
    ADD CONSTRAINT side_prompts_profile_id_fkey FOREIGN KEY (profile_id) REFERENCES public.memory_profiles(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.side_prompts
    ADD CONSTRAINT side_prompts_prompt_id_fkey FOREIGN KEY (prompt_id) REFERENCES public.prompts(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.side_prompts
    ADD CONSTRAINT side_prompts_target_book_id_fkey FOREIGN KEY (target_book_id) REFERENCES public.lore_books(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.side_prompts
    ADD CONSTRAINT side_prompts_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.site_opt_outs
    ADD CONSTRAINT site_opt_outs_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.subscriber_toggles
    ADD CONSTRAINT subscriber_toggles_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.tag_parents
    ADD CONSTRAINT tag_parents_parent_tag_id_fkey FOREIGN KEY (parent_tag_id) REFERENCES public.tags(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.tag_parents
    ADD CONSTRAINT tag_parents_tag_id_fkey FOREIGN KEY (tag_id) REFERENCES public.tags(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.taggings
    ADD CONSTRAINT taggings_ai_model_id_fkey FOREIGN KEY (ai_model_id) REFERENCES public.ai_models(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.taggings
    ADD CONSTRAINT taggings_character_id_fkey FOREIGN KEY (character_id) REFERENCES public.characters(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.taggings
    ADD CONSTRAINT taggings_chat_id_fkey FOREIGN KEY (chat_id) REFERENCES public.chats(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.taggings
    ADD CONSTRAINT taggings_lore_book_id_fkey FOREIGN KEY (lore_book_id) REFERENCES public.lore_books(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.taggings
    ADD CONSTRAINT taggings_lore_entry_id_fkey FOREIGN KEY (lore_entry_id) REFERENCES public.lore_entries(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.taggings
    ADD CONSTRAINT taggings_prompt_block_id_fkey FOREIGN KEY (prompt_block_id) REFERENCES public.prompt_blocks(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.taggings
    ADD CONSTRAINT taggings_prompt_id_fkey FOREIGN KEY (prompt_id) REFERENCES public.prompts(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.taggings
    ADD CONSTRAINT taggings_script_id_fkey FOREIGN KEY (script_id) REFERENCES public.scripts(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.taggings
    ADD CONSTRAINT taggings_tag_id_fkey FOREIGN KEY (tag_id) REFERENCES public.tags(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.tags
    ADD CONSTRAINT tags_ideal_id_fkey FOREIGN KEY (ideal_id) REFERENCES public.tags(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.tags
    ADD CONSTRAINT tags_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.users_tokens
    ADD CONSTRAINT users_tokens_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.variables
    ADD CONSTRAINT variables_chat_id_fkey FOREIGN KEY (chat_id) REFERENCES public.chats(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.variables
    ADD CONSTRAINT variables_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;

INSERT INTO public.permission_groups (id, name, description, system_key, inserted_at, updated_at) VALUES ('5755b338-31ae-4461-b2fb-e11e0eb9f43f', 'Everyone', 'Every account, implicitly.', 'everyone', '2026-11-21 17:14:35', '2026-11-21 17:14:35');
INSERT INTO public.permission_groups (id, name, description, system_key, inserted_at, updated_at) VALUES ('32e43169-2ded-4d1f-a44b-275c0a3ef8f9', 'Administrators', 'Site administration.', 'administrators', '2026-11-21 17:14:35', '2026-11-21 17:14:35');
INSERT INTO public.permission_grants (id, group_id, user_id, key, effect, limit_value, inserted_at, updated_at) VALUES ('1c023792-c870-4551-99ff-6e2929507f17', '5755b338-31ae-4461-b2fb-e11e0eb9f43f', NULL, 'content.characters.create', 'allow', NULL, '2026-11-21 17:14:35', '2026-11-21 17:14:35');
INSERT INTO public.permission_grants (id, group_id, user_id, key, effect, limit_value, inserted_at, updated_at) VALUES ('b86e6f83-464e-463e-9591-baf01916f550', '5755b338-31ae-4461-b2fb-e11e0eb9f43f', NULL, 'content.lore.create', 'allow', NULL, '2026-11-21 17:14:35', '2026-11-21 17:14:35');
INSERT INTO public.permission_grants (id, group_id, user_id, key, effect, limit_value, inserted_at, updated_at) VALUES ('35e56ae2-3316-4934-bdc3-0c1a2fdbc96e', '5755b338-31ae-4461-b2fb-e11e0eb9f43f', NULL, 'content.prompts.create', 'allow', NULL, '2026-11-21 17:14:35', '2026-11-21 17:14:35');
INSERT INTO public.permission_grants (id, group_id, user_id, key, effect, limit_value, inserted_at, updated_at) VALUES ('b48b319f-2745-4672-bcdc-c1bce1e0b9c6', '5755b338-31ae-4461-b2fb-e11e0eb9f43f', NULL, 'content.scripts.create', 'allow', NULL, '2026-11-21 17:14:35', '2026-11-21 17:14:35');
INSERT INTO public.permission_grants (id, group_id, user_id, key, effect, limit_value, inserted_at, updated_at) VALUES ('4425a314-6e62-4e2e-b71b-4c2bb5ceade3', '5755b338-31ae-4461-b2fb-e11e0eb9f43f', NULL, 'content.memory.create', 'allow', NULL, '2026-11-21 17:14:35', '2026-11-21 17:14:35');
INSERT INTO public.permission_grants (id, group_id, user_id, key, effect, limit_value, inserted_at, updated_at) VALUES ('2ffbc933-41df-4385-b8ac-3294381809c7', '5755b338-31ae-4461-b2fb-e11e0eb9f43f', NULL, 'content.variables.create', 'allow', NULL, '2026-11-21 17:14:35', '2026-11-21 17:14:35');
INSERT INTO public.permission_grants (id, group_id, user_id, key, effect, limit_value, inserted_at, updated_at) VALUES ('ad1dfa2c-223d-4f82-8d99-cd7376198e9b', '5755b338-31ae-4461-b2fb-e11e0eb9f43f', NULL, 'ai.connections.create', 'allow', NULL, '2026-11-21 17:14:35', '2026-11-21 17:14:35');
INSERT INTO public.permission_grants (id, group_id, user_id, key, effect, limit_value, inserted_at, updated_at) VALUES ('1cf403f0-b57b-433a-a927-cfa355d599b2', '5755b338-31ae-4461-b2fb-e11e0eb9f43f', NULL, 'ai.site_models.use', 'allow', NULL, '2026-11-21 17:14:35', '2026-11-21 17:14:35');
INSERT INTO public.permission_grants (id, group_id, user_id, key, effect, limit_value, inserted_at, updated_at) VALUES ('986b2d0d-2dbd-4198-8ef7-c5e863523fa0', '5755b338-31ae-4461-b2fb-e11e0eb9f43f', NULL, 'scripts.messages', 'allow', NULL, '2026-11-21 17:14:35', '2026-11-21 17:14:35');
INSERT INTO public.permission_grants (id, group_id, user_id, key, effect, limit_value, inserted_at, updated_at) VALUES ('302fc2db-ce09-4fcc-a61a-8432f41020d5', '5755b338-31ae-4461-b2fb-e11e0eb9f43f', NULL, 'scripts.images', 'allow', NULL, '2026-11-21 17:14:35', '2026-11-21 17:14:35');
INSERT INTO public.permission_grants (id, group_id, user_id, key, effect, limit_value, inserted_at, updated_at) VALUES ('d4e3f648-e941-480a-8b95-3055d8db3578', '5755b338-31ae-4461-b2fb-e11e0eb9f43f', NULL, 'scripts.generation', 'allow', NULL, '2026-11-21 17:14:35', '2026-11-21 17:14:35');
INSERT INTO public.permission_grants (id, group_id, user_id, key, effect, limit_value, inserted_at, updated_at) VALUES ('9bd64021-8aed-4bea-9b0d-179362903088', '5755b338-31ae-4461-b2fb-e11e0eb9f43f', NULL, 'scripts.memory', 'allow', NULL, '2026-11-21 17:14:35', '2026-11-21 17:14:35');
INSERT INTO public.permission_grants (id, group_id, user_id, key, effect, limit_value, inserted_at, updated_at) VALUES ('8700304d-61be-43e0-a1f7-1934746a281b', '5755b338-31ae-4461-b2fb-e11e0eb9f43f', NULL, 'scripts.characters', 'allow', NULL, '2026-11-21 17:14:35', '2026-11-21 17:14:35');
INSERT INTO public.permission_grants (id, group_id, user_id, key, effect, limit_value, inserted_at, updated_at) VALUES ('0573da4a-e988-4bce-9dfe-0f85792527c9', '5755b338-31ae-4461-b2fb-e11e0eb9f43f', NULL, 'scripts.prompts', 'allow', NULL, '2026-11-21 17:14:35', '2026-11-21 17:14:35');
INSERT INTO public.permission_grants (id, group_id, user_id, key, effect, limit_value, inserted_at, updated_at) VALUES ('e3fb8514-a46c-40d1-b97e-55a5b03c4869', '5755b338-31ae-4461-b2fb-e11e0eb9f43f', NULL, 'scripts.lore', 'allow', NULL, '2026-11-21 17:14:35', '2026-11-21 17:14:35');
INSERT INTO public.permission_grants (id, group_id, user_id, key, effect, limit_value, inserted_at, updated_at) VALUES ('16816c5f-a40a-45ea-8729-e3633084985d', '32e43169-2ded-4d1f-a44b-275c0a3ef8f9', NULL, 'site.content.manage', 'allow', NULL, '2026-11-21 17:14:35', '2026-11-21 17:14:35');
INSERT INTO public.permission_grants (id, group_id, user_id, key, effect, limit_value, inserted_at, updated_at) VALUES ('46aa151e-a271-483e-b511-1db1275930a8', '32e43169-2ded-4d1f-a44b-275c0a3ef8f9', NULL, 'site.ai.manage', 'allow', NULL, '2026-11-21 17:14:35', '2026-11-21 17:14:35');
INSERT INTO public.permission_grants (id, group_id, user_id, key, effect, limit_value, inserted_at, updated_at) VALUES ('94720da4-0275-44aa-abfb-5554acd88ffe', '32e43169-2ded-4d1f-a44b-275c0a3ef8f9', NULL, 'site.settings.manage', 'allow', NULL, '2026-11-21 17:14:35', '2026-11-21 17:14:35');
INSERT INTO public.permission_grants (id, group_id, user_id, key, effect, limit_value, inserted_at, updated_at) VALUES ('818324ef-cc52-43cb-90b5-9c188a6de0af', '32e43169-2ded-4d1f-a44b-275c0a3ef8f9', NULL, 'users.manage', 'allow', NULL, '2026-11-21 17:14:35', '2026-11-21 17:14:35');
INSERT INTO public.permission_grants (id, group_id, user_id, key, effect, limit_value, inserted_at, updated_at) VALUES ('b9856479-bed8-4308-9635-63afe2984df5', '32e43169-2ded-4d1f-a44b-275c0a3ef8f9', NULL, 'groups.manage', 'allow', NULL, '2026-11-21 17:14:35', '2026-11-21 17:14:35');
INSERT INTO public.permission_grants (id, group_id, user_id, key, effect, limit_value, inserted_at, updated_at) VALUES ('ad0bb9ec-33d5-4a01-91e1-90420b430eb4', '32e43169-2ded-4d1f-a44b-275c0a3ef8f9', NULL, 'analytics.all.view', 'allow', NULL, '2026-11-21 17:14:35', '2026-11-21 17:14:35');
INSERT INTO public.permission_grants (id, group_id, user_id, key, effect, limit_value, inserted_at, updated_at) VALUES ('03da0da1-efc5-416c-b589-886280f9028b', '5755b338-31ae-4461-b2fb-e11e0eb9f43f', NULL, 'uploads.images', 'allow', NULL, '2026-11-21 17:14:35', '2026-11-21 17:14:35');
INSERT INTO public.permission_grants (id, group_id, user_id, key, effect, limit_value, inserted_at, updated_at) VALUES ('37365ee4-5352-41b8-aa09-1ec4a3cb337d', '5755b338-31ae-4461-b2fb-e11e0eb9f43f', NULL, 'uploads.documents', 'allow', NULL, '2026-11-21 17:14:35', '2026-11-21 17:14:35');
INSERT INTO public.permission_grants (id, group_id, user_id, key, effect, limit_value, inserted_at, updated_at) VALUES ('deb64627-95f4-4f34-99ad-9d78a593959b', '5755b338-31ae-4461-b2fb-e11e0eb9f43f', NULL, 'uploads.audio', 'allow', NULL, '2026-11-21 17:14:35', '2026-11-21 17:14:35');
INSERT INTO public.permission_grants (id, group_id, user_id, key, effect, limit_value, inserted_at, updated_at) VALUES ('805392b6-0ba9-4e03-a88e-2e18447ecf20', '5755b338-31ae-4461-b2fb-e11e0eb9f43f', NULL, 'uploads.video', 'allow', NULL, '2026-11-21 17:14:35', '2026-11-21 17:14:35');
INSERT INTO public.permission_grants (id, group_id, user_id, key, effect, limit_value, inserted_at, updated_at) VALUES ('c2efc765-28bb-465e-a925-1a4462fd7b27', '5755b338-31ae-4461-b2fb-e11e0eb9f43f', NULL, 'uploads.files', 'allow', NULL, '2026-11-21 17:14:35', '2026-11-21 17:14:35');
INSERT INTO public.permission_grants (id, group_id, user_id, key, effect, limit_value, inserted_at, updated_at) VALUES ('66110430-c163-4120-b4fc-2941816869bd', '5755b338-31ae-4461-b2fb-e11e0eb9f43f', NULL, 'scripts.variables', 'allow', NULL, '2026-11-21 17:14:35', '2026-11-21 17:14:35');
INSERT INTO public.permission_grants (id, group_id, user_id, key, effect, limit_value, inserted_at, updated_at) VALUES ('bcac3098-5de1-4328-ac59-78f598fbae37', '5755b338-31ae-4461-b2fb-e11e0eb9f43f', NULL, 'scripts.injections', 'allow', NULL, '2026-11-21 17:14:35', '2026-11-21 17:14:35');
INSERT INTO public.permission_grants (id, group_id, user_id, key, effect, limit_value, inserted_at, updated_at) VALUES ('75ebff25-d3d2-4857-b39d-f09c3a088862', '5755b338-31ae-4461-b2fb-e11e0eb9f43f', NULL, 'content.tags.create', 'allow', NULL, '2026-11-21 17:14:35', '2026-11-21 17:14:35');
INSERT INTO public.permission_grants (id, group_id, user_id, key, effect, limit_value, inserted_at, updated_at) VALUES ('c7d29ac6-e721-4a90-8ae3-b7e879119350', '5755b338-31ae-4461-b2fb-e11e0eb9f43f', NULL, 'mcp.use', 'allow', NULL, '2026-11-21 17:14:35', '2026-11-21 17:14:35');
INSERT INTO public.permission_grants (id, group_id, user_id, key, effect, limit_value, inserted_at, updated_at) VALUES ('3d016565-6f24-4c7f-8566-6dd2ce47c67e', '5755b338-31ae-4461-b2fb-e11e0eb9f43f', NULL, 'sharing.invite', 'allow', NULL, '2026-11-21 17:14:35', '2026-11-21 17:14:35');
INSERT INTO public.permission_grants (id, group_id, user_id, key, effect, limit_value, inserted_at, updated_at) VALUES ('40a9e321-fa48-43e8-8e4e-50631896b140', '32e43169-2ded-4d1f-a44b-275c0a3ef8f9', NULL, 'site.hidden.view', 'allow', NULL, '2026-11-21 17:14:35', '2026-11-21 17:14:35');
INSERT INTO public.permission_grants (id, group_id, user_id, key, effect, limit_value, inserted_at, updated_at) VALUES ('68197aa9-e892-4a5c-8760-1d6258cb9d89', '5755b338-31ae-4461-b2fb-e11e0eb9f43f', NULL, 'chats.invite', 'allow', NULL, '2026-11-21 17:14:35', '2026-11-21 17:14:35');
INSERT INTO public.permission_grants (id, group_id, user_id, key, effect, limit_value, inserted_at, updated_at) VALUES ('8bec71fc-d5b4-4863-8d8e-bd502e06491d', '5755b338-31ae-4461-b2fb-e11e0eb9f43f', NULL, 'catalog.publish', 'allow', NULL, '2026-11-21 17:14:35', '2026-11-21 17:14:35');
INSERT INTO public.permission_grants (id, group_id, user_id, key, effect, limit_value, inserted_at, updated_at) VALUES ('56b77bcb-6a68-4e11-b1d2-81879fb72869', '32e43169-2ded-4d1f-a44b-275c0a3ef8f9', NULL, 'moderation.reports', 'allow', NULL, '2026-11-21 17:14:35', '2026-11-21 17:14:35');
INSERT INTO public.permission_grants (id, group_id, user_id, key, effect, limit_value, inserted_at, updated_at) VALUES ('5c160e1a-9d93-4254-8fa3-3f2daec95219', '32e43169-2ded-4d1f-a44b-275c0a3ef8f9', NULL, 'moderation.content.delete', 'allow', NULL, '2026-11-21 17:14:35', '2026-11-21 17:14:35');
INSERT INTO public.permission_grants (id, group_id, user_id, key, effect, limit_value, inserted_at, updated_at) VALUES ('76266558-1966-4256-8efb-97125bc5111b', '32e43169-2ded-4d1f-a44b-275c0a3ef8f9', NULL, 'moderation.content.view', 'allow', NULL, '2026-11-21 17:14:35', '2026-11-21 17:14:35');
INSERT INTO public.permission_grants (id, group_id, user_id, key, effect, limit_value, inserted_at, updated_at) VALUES ('aea1420c-2467-4c5d-aaa8-8dbc3b7647fe', '32e43169-2ded-4d1f-a44b-275c0a3ef8f9', NULL, 'catalog.feature', 'allow', NULL, '2026-11-21 17:14:35', '2026-11-21 17:14:35');
INSERT INTO public.permission_grants (id, group_id, user_id, key, effect, limit_value, inserted_at, updated_at) VALUES ('45d6832d-e9f8-47fc-b282-81a11924f36d', '32e43169-2ded-4d1f-a44b-275c0a3ef8f9', NULL, 'moderation.accounts.sanction', 'allow', NULL, '2026-11-21 17:14:35', '2026-11-21 17:14:35');
INSERT INTO public.permission_grants (id, group_id, user_id, key, effect, limit_value, inserted_at, updated_at) VALUES ('f64beeac-efd1-471f-aaad-9ff9e5cef121', '32e43169-2ded-4d1f-a44b-275c0a3ef8f9', NULL, 'moderation.fingerprints', 'allow', NULL, '2026-11-21 17:14:35', '2026-11-21 17:14:35');
INSERT INTO public.permission_grants (id, group_id, user_id, key, effect, limit_value, inserted_at, updated_at) VALUES ('2d735e24-15c8-4e3e-95ae-3defea44a7b6', '32e43169-2ded-4d1f-a44b-275c0a3ef8f9', NULL, 'moderation.log.view', 'allow', NULL, '2026-11-21 17:14:35', '2026-11-21 17:14:35');
INSERT INTO public.permission_grants (id, group_id, user_id, key, effect, limit_value, inserted_at, updated_at) VALUES ('287e0b84-51ea-4a1b-aca2-d2c8a39203e7', '5755b338-31ae-4461-b2fb-e11e0eb9f43f', NULL, 'reports.create', 'allow', NULL, '2026-11-21 17:14:35', '2026-11-21 17:14:35');
INSERT INTO public.permission_grants (id, group_id, user_id, key, effect, limit_value, inserted_at, updated_at) VALUES ('6552c539-a5d0-4736-80c2-c4e1920ece87', '32e43169-2ded-4d1f-a44b-275c0a3ef8f9', NULL, 'moderation.review', 'allow', NULL, '2026-11-21 17:14:36', '2026-11-21 17:14:36');
INSERT INTO public.permission_grants (id, group_id, user_id, key, effect, limit_value, inserted_at, updated_at) VALUES ('7d4b9496-4b3c-40da-bd83-a346ed9cbd32', '32e43169-2ded-4d1f-a44b-275c0a3ef8f9', NULL, 'moderation.rules.manage', 'allow', NULL, '2026-11-21 17:14:36', '2026-11-21 17:14:36');
