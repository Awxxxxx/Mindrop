with sample_notes(title, content, category) as (
    values
        ('买垃圾桶', '给家里买一个带盖垃圾桶，优先看厨房尺寸。', '待办提醒'),
        ('会议提醒', '开会前准备周报数据。', '待办提醒'),
        ('水支出', '餐饮分类，买了一瓶水花了 1 块钱。', '账单记录'),
        ('语音记录 App', '面向碎片念头的语音收件箱，自动总结并归档。', '灵感沉淀'),
        ('iPhone 截长图', '在 Safari 截图后切换到整页，并保存为 PDF。', '知识问答'),
        ('旧会议提醒', '已超过提醒时间 48 小时，自动进入回收站。', '回收站')
)
update public.thought_notes note
set
    deleted_at = coalesce(note.deleted_at, now()),
    updated_at = now(),
    reminder_at = null,
    reminder_notification_title = null,
    reminder_notification_body = null,
    reminder_push_sent_at = coalesce(note.reminder_push_sent_at, now()),
    reminder_push_reminder_at = coalesce(note.reminder_push_reminder_at, note.reminder_at),
    reminder_push_error = null
from sample_notes sample
where note.title = sample.title
  and note.content = sample.content
  and note.category = sample.category;

with sample_messages(role, text, category) as (
    values
        ('user', '明天下午三点提醒我开会，并准备周报数据', null),
        ('assistant', '已总结并收纳至“待办提醒”板块', '待办提醒'),
        ('user', 'iPhone 怎么截长图？', null),
        ('assistant', '可以在 Safari 或支持滚动截图的页面截图后，切换到“整页”并保存为 PDF。', '知识问答')
)
update public.chat_messages message
set
    deleted_at = coalesce(message.deleted_at, now()),
    updated_at = now()
from sample_messages sample
where message.role = sample.role
  and message.text = sample.text
  and message.category is not distinct from sample.category;

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
          and n.reminder_at >= now() - interval '6 hours'
          and not (n.title = '会议提醒' and n.content = '开会前准备周报数据。')
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
