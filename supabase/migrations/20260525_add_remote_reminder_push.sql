alter table public.thought_notes
    add column if not exists reminder_push_sent_at timestamptz,
    add column if not exists reminder_push_reminder_at timestamptz,
    add column if not exists reminder_push_attempted_at timestamptz,
    add column if not exists reminder_push_attempt_count integer not null default 0,
    add column if not exists reminder_push_error text;

update public.thought_notes
set
    reminder_push_sent_at = coalesce(reminder_push_sent_at, now()),
    reminder_push_reminder_at = coalesce(reminder_push_reminder_at, reminder_at)
where reminder_at is not null
  and reminder_at <= now()
  and reminder_push_sent_at is null;

create index if not exists thought_notes_due_remote_push_idx
    on public.thought_notes (reminder_at, reminder_push_reminder_at)
    where reminder_at is not null
      and deleted_at is null
      and category = '待办提醒';

create table if not exists public.push_tokens (
    id uuid primary key default gen_random_uuid(),
    user_id uuid not null references auth.users(id) on delete cascade,
    device_id text not null,
    token text not null,
    platform text not null default 'ios',
    environment text not null check (environment in ('sandbox', 'production')),
    app_bundle_id text not null default 'app.mindrop.ios',
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    revoked_at timestamptz,
    unique (user_id, device_id, environment)
);

create index if not exists push_tokens_user_active_idx
    on public.push_tokens (user_id, environment)
    where revoked_at is null;

alter table public.push_tokens enable row level security;

drop policy if exists push_tokens_select_own on public.push_tokens;
drop policy if exists push_tokens_insert_own on public.push_tokens;
drop policy if exists push_tokens_update_own on public.push_tokens;

create policy push_tokens_select_own
    on public.push_tokens
    for select
    using (auth.uid() = user_id);

create policy push_tokens_insert_own
    on public.push_tokens
    for insert
    with check (auth.uid() = user_id);

create policy push_tokens_update_own
    on public.push_tokens
    for update
    using (auth.uid() = user_id)
    with check (auth.uid() = user_id);

create or replace function public.claim_due_reminder_pushes(max_count integer default 50)
returns table (
    id uuid,
    user_id uuid,
    title text,
    content text,
    reminder_at timestamptz,
    reminder_notification_title text,
    reminder_notification_body text
)
language sql
security definer
set search_path = public
as $$
    with due as (
        select n.id
        from public.thought_notes n
        where n.category = '待办提醒'
          and n.deleted_at is null
          and n.reminder_at is not null
          and n.reminder_at <= now()
          and (
              n.reminder_push_reminder_at is null
              or n.reminder_push_reminder_at is distinct from n.reminder_at
          )
          and (
              n.reminder_push_attempted_at is null
              or n.reminder_push_attempted_at < now() - interval '5 minutes'
          )
          and coalesce(n.reminder_push_attempt_count, 0) < 5
        order by n.reminder_at asc
        limit greatest(1, least(coalesce(max_count, 50), 100))
        for update skip locked
    ),
    claimed as (
        update public.thought_notes n
        set
            reminder_push_attempted_at = now(),
            reminder_push_attempt_count = coalesce(n.reminder_push_attempt_count, 0) + 1,
            reminder_push_error = null
        from due
        where n.id = due.id
        returning
            n.id,
            n.user_id,
            n.title,
            n.content,
            n.reminder_at,
            n.reminder_notification_title,
            n.reminder_notification_body
    )
    select * from claimed;
$$;

revoke all on function public.claim_due_reminder_pushes(integer) from public;
grant execute on function public.claim_due_reminder_pushes(integer) to service_role;
