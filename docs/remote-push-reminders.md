# Remote Push Reminders

Mindrop uses APNs remote push for reminders when a signed-in iOS device has uploaded a push token.

## Environment Matrix

| iOS build | APNs token environment | Vercel `APNS_ENVIRONMENT` | APNs key environment |
| --- | --- | --- | --- |
| Xcode Debug / development profile | `sandbox` | `sandbox` | `Sandbox` or `Sandbox & Production` |
| TestFlight / App Store / release profile | `production` | `production` | `Production` or `Sandbox & Production` |

If the APNs key does not include the selected environment, APNs returns `BadEnvironmentKeyInToken`.

## Vercel Variables

Required in Production:

```text
CRON_SECRET
SUPABASE_URL
SUPABASE_SERVICE_ROLE_KEY
APNS_TEAM_ID
APNS_KEY_ID
APNS_PRIVATE_KEY
APNS_BUNDLE_ID=app.mindrop.ios
APNS_ENVIRONMENT=sandbox|production
```

Optional:

```text
REMOTE_PUSH_DEBUG=1
```

Use `REMOTE_PUSH_DEBUG=1` only during diagnosis. Leave it unset or `0` normally.

## Supabase Checks

Push token registration:

```sql
select id, user_id, device_id, environment, app_bundle_id, revoked_at, updated_at
from public.push_tokens
order by updated_at desc
limit 10;
```

Reminder delivery status:

```sql
select id, title, reminder_at, reminder_push_sent_at,
       reminder_push_attempted_at, reminder_push_attempt_count,
       reminder_push_error
from public.thought_notes
where reminder_at is not null
order by reminder_at desc
limit 10;
```

## Release Checklist

1. Build the app with a release/TestFlight provisioning profile.
2. Confirm the app uploads `production` push tokens.
3. Set Vercel `APNS_ENVIRONMENT=production`.
4. Use an APNs key that includes Production.
5. Redeploy Vercel after changing environment variables.
6. Create a reminder 2-3 minutes in the future and test with the app backgrounded or the phone locked.
