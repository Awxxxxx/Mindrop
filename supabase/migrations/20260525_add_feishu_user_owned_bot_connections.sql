create table if not exists public.feishu_bot_connections (
    id uuid primary key default gen_random_uuid(),
    user_id uuid not null references auth.users(id) on delete cascade,
    callback_token text not null unique,
    app_id text not null,
    app_secret_encrypted text not null,
    verification_token_encrypted text not null,
    encrypt_key_encrypted text not null,
    pairing_code text,
    pairing_expires_at timestamptz,
    paired_open_id text,
    paired_chat_id text,
    tenant_key text,
    time_zone text not null default 'Asia/Shanghai',
    status text not null default 'configured',
    last_event_at timestamptz,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    revoked_at timestamptz
);

alter table public.feishu_bot_connections
    add column if not exists callback_token text;

alter table public.feishu_bot_connections
    add column if not exists app_secret_encrypted text;

alter table public.feishu_bot_connections
    add column if not exists verification_token_encrypted text;

alter table public.feishu_bot_connections
    add column if not exists encrypt_key_encrypted text;

alter table public.feishu_bot_connections
    add column if not exists pairing_code text;

alter table public.feishu_bot_connections
    add column if not exists pairing_expires_at timestamptz;

alter table public.feishu_bot_connections
    add column if not exists paired_open_id text;

alter table public.feishu_bot_connections
    add column if not exists paired_chat_id text;

alter table public.feishu_bot_connections
    add column if not exists tenant_key text;

alter table public.feishu_bot_connections
    add column if not exists time_zone text not null default 'Asia/Shanghai';

alter table public.feishu_bot_connections
    add column if not exists status text not null default 'configured';

alter table public.feishu_bot_connections
    add column if not exists last_event_at timestamptz;

alter table public.feishu_bot_connections
    add column if not exists revoked_at timestamptz;

create unique index if not exists feishu_bot_connections_callback_token_key
    on public.feishu_bot_connections (callback_token);

create index if not exists feishu_bot_connections_user_idx
    on public.feishu_bot_connections (user_id, updated_at desc);

create index if not exists feishu_bot_connections_active_idx
    on public.feishu_bot_connections (user_id, status)
    where revoked_at is null;

alter table public.feishu_bot_connections enable row level security;

create table if not exists public.feishu_message_events (
    event_id text primary key,
    event_type text,
    tenant_key text,
    open_id text,
    chat_id text,
    message_id text,
    user_id uuid references auth.users(id) on delete set null,
    status text not null default 'received',
    error text,
    received_at timestamptz not null default now(),
    processed_at timestamptz
);

alter table public.feishu_message_events
    add column if not exists connection_id uuid references public.feishu_bot_connections(id) on delete set null;

alter table public.feishu_message_events enable row level security;

create index if not exists feishu_message_events_connection_idx
    on public.feishu_message_events (connection_id, received_at desc);

create index if not exists feishu_message_events_user_idx
    on public.feishu_message_events (user_id, received_at desc);

grant usage on schema public to service_role;
grant select, insert, update, delete on table public.feishu_bot_connections to service_role;
grant select, insert, update, delete on table public.feishu_message_events to service_role;
grant select, insert, update on table public.thought_notes to service_role;
grant select, insert, update on table public.chat_messages to service_role;
