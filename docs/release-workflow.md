# Mindrop Release Workflow

## Branches

- `main`: App Store and production-safe code. Only merge tested releases or hotfixes.
- `develop`: Daily integration branch for tested feature work.
- `feature/*`: One branch per feature. Open from `develop` when available, or from `main` before `develop` exists.
- `hotfix/*`: Urgent production fixes opened from `main`, then merged back into `develop`.

## Vercel Environments

- Production should point at production Supabase, production APNs, and production model keys.
- Preview/Staging should use separate environment variables whenever possible.
- For APNs, TestFlight/App Store builds require `APNS_ENVIRONMENT=production`; Xcode Debug builds require `sandbox`.
- Keep feature flags off in Production until the matching client build is ready for review.

Current thinking-mode test backend:

- Preview branch: `feature/thinking-mode-toggle`
- Preview alias: `https://mindrop-git-feature-thinking-mode-toggle-xxxs-projects-551c2398.vercel.app`
- Custom staging domain: `https://staging.mindrop.chat`

The custom staging domain requires this DNS record at the domain provider:

```text
A staging.mindrop.chat 76.76.21.21
```

## Feature Flags

Remote flags are returned by `/api/app-config`.

| Flag | Environment variable | Default | Purpose |
| --- | --- | --- | --- |
| `features.aiThinkingModeToggle` | `FEATURE_AI_THINKING_MODE_TOGGLE` | `false` | Shows the chat screen Fast/Thinking mode switch. |

Client behavior should stay backward compatible:

- Missing flags fall back to the client default.
- New request fields are optional.
- Existing response fields must not be renamed, removed, or type-changed.

## Release Checklist

1. Work on a `feature/*` branch, not directly on `main`.
2. Keep server request/response changes additive and backward compatible.
3. Run iOS build checks and Node syntax checks.
4. Push the feature branch to GitHub.
5. Use Vercel Preview/Staging for server validation.
6. Merge to `develop` for integration testing.
7. Merge to `main` only after release validation.
8. Push GitHub first, then deploy/sync Vercel.
