# Feishu User-Owned Bot Single Chat

Mindrop only supports Feishu/Lark bot single chats. Group messages are ignored.

The product model is user-owned enterprise custom apps: each Mindrop user creates their own Feishu self-built app and bot, then connects that bot to their Mindrop account. Mindrop does not keep a global Feishu App ID or App Secret in Vercel.

## User Flow

1. User logs in to Mindrop.
2. User tells 小落:

```text
飞书配对
```

3. Mindrop explains the whole setup flow and lists the 4 required values.
4. Mindrop asks for each value one at a time, with the Feishu console location:

```text
App ID
App Secret
Verification Token
Encrypt Key
```

Each user reply in this pairing flow is intercepted before normal chat storage. Mindrop stores only masked chat text such as `App Secret 已填写（已隐藏）`, sends the collected credentials to `/api/feishu/connections`, and stores them encrypted in Supabase.

5. When all 4 values are collected, Mindrop returns a per-connection callback URL:

```text
https://www.mindrop.chat/api/feishu/events?connection=...
```

6. User pastes that URL into Feishu event subscription and subscribes only:

```text
im.message.receive_v1
```

7. User sends the returned pairing command to their Feishu bot:

```text
绑定 ABCD2345
```

After binding, only that Feishu `open_id` can write into the linked Mindrop account through this connection.

## Vercel Variables

Required:

```text
SUPABASE_URL
SUPABASE_SERVICE_ROLE_KEY
ARK_API_KEY
ARK_ENDPOINT
ARK_MODEL
```

Recommended:

```text
FEISHU_CREDENTIALS_KEY
MINDROP_PUBLIC_URL=https://www.mindrop.chat
```

`FEISHU_CREDENTIALS_KEY` is a single server-side encryption key for all stored Feishu credentials. Generate it with:

```bash
openssl rand -base64 32
```

If it is absent, the server derives the encryption key from `SUPABASE_SERVICE_ROLE_KEY` so the feature still works, but a dedicated key is better for rotation.

## Feishu App Setup

For every user-owned bot:

1. Create an enterprise custom app in Feishu Open Platform.
2. Enable Bot.
3. In event subscription, use the callback URL returned by Mindrop.
4. Enable Encrypt Key and keep the Verification Token / Encrypt Key from the app's event settings.
5. Subscribe to `im.message.receive_v1`.
6. Grant the minimum message permissions needed for receiving and replying to bot messages.
7. Grant `im:message.reactions:write_only` if you want Mindrop to show and remove the temporary `Typing` reaction while AI is processing a message.

Do not subscribe to `app_ticket`. That event is for store apps and is not used by this architecture.

## Supabase Checks

Connections:

```sql
select user_id, app_id, status, paired_open_id, tenant_key, last_event_at, revoked_at, updated_at
from public.feishu_bot_connections
order by updated_at desc
limit 20;
```

Event processing:

```sql
select event_id, connection_id, event_type, status, error, received_at, processed_at
from public.feishu_message_events
order by received_at desc
limit 20;
```

## Notes

- Feishu retries events when the server does not return HTTP 200 quickly enough. `feishu_message_events.event_id` prevents duplicate note creation.
- The callback URL contains an unguessable connection token so the server can pick the correct Encrypt Key before decrypting the event.
- Users can unbind by sending `解绑` to their Feishu bot. This revokes that connection.
