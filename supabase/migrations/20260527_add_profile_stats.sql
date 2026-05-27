create table if not exists public.profile_note_stats (
    id uuid primary key,
    user_id uuid not null references auth.users(id) on delete cascade,
    created_at timestamptz not null,
    updated_at timestamptz not null default now(),
    stats_category text not null,
    expense_amount numeric,
    expense_category text
);

create index if not exists profile_note_stats_user_created_at_idx
    on public.profile_note_stats (user_id, created_at desc);

alter table public.profile_note_stats enable row level security;

drop policy if exists profile_note_stats_select_own on public.profile_note_stats;
drop policy if exists profile_note_stats_insert_own on public.profile_note_stats;
drop policy if exists profile_note_stats_update_own on public.profile_note_stats;

create policy profile_note_stats_select_own
    on public.profile_note_stats
    for select
    using (auth.uid() = user_id);

create policy profile_note_stats_insert_own
    on public.profile_note_stats
    for insert
    with check (auth.uid() = user_id);

create policy profile_note_stats_update_own
    on public.profile_note_stats
    for update
    using (auth.uid() = user_id)
    with check (auth.uid() = user_id);

grant select, insert, update on public.profile_note_stats to authenticated;

create table if not exists public.profile_message_stats (
    id uuid primary key,
    user_id uuid not null references auth.users(id) on delete cascade,
    created_at timestamptz not null,
    updated_at timestamptz not null default now()
);

create index if not exists profile_message_stats_user_created_at_idx
    on public.profile_message_stats (user_id, created_at asc);

alter table public.profile_message_stats enable row level security;

drop policy if exists profile_message_stats_select_own on public.profile_message_stats;
drop policy if exists profile_message_stats_insert_own on public.profile_message_stats;
drop policy if exists profile_message_stats_update_own on public.profile_message_stats;

create policy profile_message_stats_select_own
    on public.profile_message_stats
    for select
    using (auth.uid() = user_id);

create policy profile_message_stats_insert_own
    on public.profile_message_stats
    for insert
    with check (auth.uid() = user_id);

create policy profile_message_stats_update_own
    on public.profile_message_stats
    for update
    using (auth.uid() = user_id)
    with check (auth.uid() = user_id);

grant select, insert, update on public.profile_message_stats to authenticated;

with normalized_notes as (
    select
        id,
        user_id,
        coalesce(created_at, now()) as created_at,
        coalesce(updated_at, created_at, now()) as updated_at,
        case
            when category <> '回收站' then category
            when category_before_recycle is not null and category_before_recycle <> '回收站' then category_before_recycle
            when expense_amount is not null or expense_category is not null then '账单记录'
            when reminder_at is not null then '待办提醒'
            else '灵感沉淀'
        end as stats_category,
        expense_amount,
        expense_category,
        title,
        content,
        category
    from public.thought_notes
)
insert into public.profile_note_stats (
    id,
    user_id,
    created_at,
    updated_at,
    stats_category,
    expense_amount,
    expense_category
)
select
    id,
    user_id,
    created_at,
    updated_at,
    stats_category,
    case when stats_category = '账单记录' then expense_amount else null end,
    case when stats_category = '账单记录' then coalesce(expense_category, '其他') else null end
from normalized_notes
where not (
    (title = '买垃圾桶' and content = '给家里买一个带盖垃圾桶，优先看厨房尺寸。' and category = '待办提醒')
    or (title = '会议提醒' and content = '开会前准备周报数据。' and category = '待办提醒')
    or (title = '水支出' and content = '餐饮分类，买了一瓶水花了 1 块钱。' and category = '账单记录')
    or (title = '语音记录 App' and content = '面向碎片念头的语音收件箱，自动总结并归档。' and category = '灵感沉淀')
    or (title = 'iPhone 截长图' and content = '在 Safari 截图后切换到整页，并保存为 PDF。' and category = '知识问答')
    or (title = '旧会议提醒' and content in ('已超过提醒时间 48 小时，自动进入回收站。', '已超过提醒时间 24 小时，自动进入回收站。') and category = '回收站')
)
on conflict (id) do update
set
    created_at = excluded.created_at,
    updated_at = excluded.updated_at,
    stats_category = excluded.stats_category,
    expense_amount = excluded.expense_amount,
    expense_category = excluded.expense_category
where excluded.updated_at >= profile_note_stats.updated_at;

insert into public.profile_message_stats (
    id,
    user_id,
    created_at,
    updated_at
)
select
    id,
    user_id,
    coalesce(created_at, now()),
    coalesce(updated_at, created_at, now())
from public.chat_messages
where role = 'user'
  and text not in ('明天下午三点提醒我开会，并准备周报数据', 'iPhone 怎么截长图？')
on conflict (id) do update
set
    created_at = excluded.created_at,
    updated_at = excluded.updated_at
where excluded.updated_at >= profile_message_stats.updated_at;
