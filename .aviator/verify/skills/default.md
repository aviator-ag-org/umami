---
description: How to drive the umami preview — signing in with the admin secrets, where things live, what demo data exists, and what a preview cannot exercise. Load before writing or running any scenario against this app.
---

# Driving the umami preview

umami is a self-hosted, privacy-focused web analytics app (an alternative to
Google Analytics). The preview serves the full Next.js UI, backed by a
PostgreSQL database running on the same sandbox.

Everything except `/login` requires authentication. Sign in first.

## Signing in

1. Navigate to the preview URL. You will be redirected to `/login`.
2. Fill the **Username** field (`[data-test="input-username"]`) with
   `{{ secrets.umami_admin_username }}`.
3. Fill the **Password** field (`[data-test="input-password"]`) with
   `{{ secrets.umami_admin_password }}`.
4. Click **Log in** (`[data-test="button-submit"]`).

You land on `/`, which is a client-side redirect to `/websites` — the websites
list. It renders `null` for a beat first, so wait for `/websites` rather than
asserting on `/`.

Carry the `{{ secrets.* }}` placeholders into the sign-in step verbatim. The
collector substitutes the real values at call time and fences them to the
preview origin. Never put a literal credential in a scenario.

The session token is kept in **localStorage**, not a cookie, and is sent as an
`Authorization: Bearer` header. A page reload keeps you signed in; clearing site
data or opening a fresh browser context does not — sign in again.

## Getting around

The left nav covers the main areas. Useful routes:

| Route | What is there |
| --- | --- |
| `/websites` | The websites list — the post-login landing page |
| `/websites/<id>` | One site's overview, and the parent of everything below |
| `/websites/<id>/{realtime,sessions,events,replays,segments,cohorts,compare}` | Per-site views |
| `/websites/<id>/{funnels,retention,journeys,goals,revenue,attribution,breakdown,utm,performance,heatmaps}` | The reports. Note they are **per-website** — there is no top-level `/reports` |
| `/dashboard` | The cross-website dashboard |
| `/boards` | Custom boards |
| `/links` , `/pixels` | Short links and tracking pixels |
| `/settings/{preferences,profile,websites,teams}` | Settings (`/settings` redirects to `/settings/preferences`) |
| `/admin/{users,websites,teams}` | Admin management (`/admin` redirects to `/admin/users`) |
| `/teams` | Teams |

Website ids are uuids assigned at seed time, so read them off the websites list
rather than hardcoding one.

## Demo data, and the date-range trap

The preview image seeds two websites so the charts are not empty:

- **Demo Blog** — `blog.example.com`, low traffic, with `newsletter_signup`,
  `share_click` and `scroll_depth` events.
- **Demo SaaS** — `app.example.com`, higher traffic, with a signup funnel
  (`signup_started` / `signup_completed`), `purchase` revenue events,
  `demo_requested`, `feature_viewed`, `cta_click` and `docs_search`.

**Read this before concluding "no data":** the seed covers the 30 days *before
the preview image was built*, and umami's default date range is **Last 24
hours**. If the image is more than a day old, every view opens empty. That is
the image's age, not a bug in the branch. Widen the date range (the picker in
the page header — pick something like *Last 90 days*) before judging any chart,
table or report as broken.

Realtime views are the exception: nothing is generating live traffic, so they
are genuinely and permanently empty. Do not write scenarios against them.

## What is observable as evidence

This is a real app driven through a browser, so the DOM, rendered text, computed
styles, network responses from `/api/*`, and browser console output are all fair
game. Data written through the UI (creating a website, editing a report, adding
a user) persists in PostgreSQL for the life of the sandbox, so multi-step
scenarios work.

## What a preview does NOT exercise

Do not write scenarios that depend on any of these — they cannot pass here:

- **Incoming tracking traffic.** `/script.js` is served, but no external site
  loads it, and the agent's browser is fenced to the preview origin. All
  analytics you see is seeded, not live.
- **ClickHouse, Redis, Kafka.** Unset, so umami runs in its plain PostgreSQL
  mode. Clustered/cloud-only code paths are inactive.
- **Email and outbound integrations.** Nothing is configured.
- **Telemetry and update checks.** `DISABLE_TELEMETRY` and `DISABLE_UPDATES` are
  set, so the update banner never appears.
- **Accurate geolocation.** The GeoLite2 database is present, but seeded
  locations are synthetic.
- **Anything at a second origin** — OAuth, embeds, external redirects.
