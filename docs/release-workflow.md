# Mindrop Release Workflow

## Branches

- `main`: App Store and production-safe code. Only merge tested releases or hotfixes.
- `develop`: Daily integration branch for tested feature work.
- `hotfix/*`: Urgent production fixes opened from `main`, then merged back into `develop`.

## Vercel Environments

- Production should point at production Supabase, production APNs, and production model keys.
- Develop/Preview should use separate environment variables whenever possible.
- For APNs, TestFlight/App Store builds require `APNS_ENVIRONMENT=production`; Xcode Debug builds require `sandbox`.
- Keep feature flags off in Production until the matching client build is ready for review.

Current develop backend:

- Preview branch: `develop`
- Preview alias: `https://mindrop-git-develop-xxxs-projects-551c2398.vercel.app`
- Custom develop domain: `https://develop.mindrop.chat`

The custom develop domain requires this DNS record at the domain provider:

```text
A develop.mindrop.chat 76.76.21.21
```

Vercel preview URLs are protected by Vercel Authentication, while custom domains are public.
After a new `develop` Preview deployment is created, point `develop.mindrop.chat` at the latest Preview deployment before testing client builds:

```text
vercel alias set <latest-develop-preview>.vercel.app develop.mindrop.chat
```

## Feature Flags

Remote flags are returned by `/api/app-config`.

| Flag | Environment variable | Default | Purpose |
| --- | --- | --- | --- |
| `features.aiThinkingModeToggle` | `FEATURE_AI_THINKING_MODE_TOGGLE` | `true` | Shows the chat screen Fast/Thinking mode switch. |

Client behavior should stay backward compatible:

- Missing flags fall back to the client default.
- New request fields are optional.
- Existing response fields must not be renamed, removed, or type-changed.

## Release Checklist

1. Work on `develop`, not directly on `main`.
2. Keep server request/response changes additive and backward compatible.
3. Run iOS build checks and Node syntax checks.
4. Push `develop` to GitHub and validate the Vercel Preview.
5. Update `develop.mindrop.chat` to the latest `develop` Preview deployment.
6. Merge to `main` only after release validation.
7. Push GitHub first, then deploy/sync Vercel.
