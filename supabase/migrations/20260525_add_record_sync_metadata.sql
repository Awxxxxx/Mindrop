alter table public.thought_notes
    add column if not exists updated_at timestamptz,
    add column if not exists deleted_at timestamptz;

update public.thought_notes
set updated_at = coalesce(updated_at, created_at, now())
where updated_at is null;

alter table public.thought_notes
    alter column updated_at set not null,
    alter column updated_at set default now();

create index if not exists thought_notes_user_updated_at_idx
    on public.thought_notes (user_id, updated_at desc);

create index if not exists thought_notes_user_deleted_at_idx
    on public.thought_notes (user_id, deleted_at)
    where deleted_at is not null;

alter table public.chat_messages
    add column if not exists updated_at timestamptz,
    add column if not exists deleted_at timestamptz;

update public.chat_messages
set updated_at = coalesce(updated_at, created_at, now())
where updated_at is null;

alter table public.chat_messages
    alter column updated_at set not null,
    alter column updated_at set default now();

create index if not exists chat_messages_user_updated_at_idx
    on public.chat_messages (user_id, updated_at desc);

create index if not exists chat_messages_user_deleted_at_idx
    on public.chat_messages (user_id, deleted_at)
    where deleted_at is not null;
