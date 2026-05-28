grant usage on schema public to service_role;

do $$
begin
    if to_regclass('public.app_snapshots') is not null then
        grant select, delete on table public.app_snapshots to service_role;
    end if;

    if to_regclass('public.profiles') is not null then
        grant select, delete on table public.profiles to service_role;
    end if;

    if to_regclass('public.user_settings') is not null then
        grant select, delete on table public.user_settings to service_role;
    end if;

    if to_regclass('public.thought_notes') is not null then
        grant select, delete on table public.thought_notes to service_role;
    end if;

    if to_regclass('public.chat_messages') is not null then
        grant select, delete on table public.chat_messages to service_role;
    end if;

    if to_regclass('public.profile_note_stats') is not null then
        grant select, delete on table public.profile_note_stats to service_role;
    end if;

    if to_regclass('public.profile_message_stats') is not null then
        grant select, delete on table public.profile_message_stats to service_role;
    end if;

    if to_regclass('public.push_tokens') is not null then
        grant select, delete on table public.push_tokens to service_role;
    end if;

    if to_regclass('public.feishu_bot_connections') is not null then
        grant select, delete on table public.feishu_bot_connections to service_role;
    end if;

    if to_regclass('public.feishu_message_events') is not null then
        grant select, delete on table public.feishu_message_events to service_role;
    end if;
end $$;
