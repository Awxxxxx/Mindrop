create table if not exists public.quick_voice_live_activity_tokens (
    id uuid primary key default gen_random_uuid(),
    device_id text not null,
    device_secret_hash text not null,
    push_to_start_token text not null,
    environment text not null check (environment in ('sandbox', 'production')),
    app_bundle_id text not null default 'app.mindrop.ios',
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    revoked_at timestamptz,
    unique (device_id, environment)
);

create index if not exists quick_voice_live_activity_tokens_active_idx
    on public.quick_voice_live_activity_tokens (device_id, environment)
    where revoked_at is null;

alter table public.quick_voice_live_activity_tokens enable row level security;

revoke all on public.quick_voice_live_activity_tokens from anon, authenticated;
grant all on public.quick_voice_live_activity_tokens to service_role;
