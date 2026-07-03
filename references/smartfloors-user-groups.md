# SmartFloors user groups: group-aware ad control

The Metica SmartFloors **user group** (`initResponse.SmartFloors.UserGroup`, and the
`IsForcedHoldout` flag) is the single source of truth for **how the app runs its ad loading**.
Metica's own integration guidance directs integrators to branch ad-control logic on the group,
and a real shipped integration (`.../sciplay/Advertisement/MeticaService`) implements exactly
this pattern. This doc records the sanctioned shape so the validator and the `ad-log-monitor`
skill agree on what is expected (mirroring the role `max-metica-api-map.tsv` plays for the
Max↔Metica surface).

## The sanctioned pattern

After init, read `initResponse.SmartFloors.UserGroup` once and branch on it:

- **Holdout** → run the game's existing **multi-ad-unit waterfall**: load N units in parallel
  and show the highest CPM/revenue winner, exactly as a direct-Max integration would. This is
  the control arm and should behave like the game's baseline.
- **Trial** → issue a **single ad call per format** and let Metica's internal optimization pick
  the unit. **Disable the app-side waterfall** — do not load N units in parallel; the SDK
  manages loading internally.

Attribute revenue (and every A/B metric) by **group**, never by ad-unit id.

## Why you must branch on group, not on ad-unit id

- Trial serves **Metica-dedicated ad units regardless of the `adUnitId` the app requested**, so
  the callback's `MeticaAd.adUnitId` frequently differs from the id you passed to `Load*`.
- Even trial users are **sometimes served the holdout ad unit as a connection-issue fallback**,
  so an ad unit seen in the trial route is not proof of routing state.

Because of both, **ad-unit-based routing/analysis is unreliable**. App code must pass the
configured id through unchanged, never second-guess what comes back, and attribute by the group
tag it read at init.

## Worked example — the sciplay integration

The `.../sciplay/Advertisement/MeticaService` integration correctly implements the pattern:

- **Group read at init** — `MeticaInitializeService.cs:83` reads the group from the init
  response and tags it to analytics at `:88`.
- **Waterfall gated to holdout** — `MeticaInfoProvider.cs:17-26` exposes `IsMultipleAdsEnabled`,
  true only for holdout; trial loads a single default unit.
- **Callbacks resolve the unit id per group** — `IMeticaThreadSafeEvents.cs:171-181` (and the
  per-format handlers) resolve the reported unit id by group rather than assuming the requested
  id was served.

Two advisory notes on that integration (not blockers):

1. The trial id-coercion (`_pendingLoadUnitId ?? sdkUnitId`) can misrepresent what actually
   served, given the holdout-fallback caveat above — keep revenue attribution on the
   `metica_group` tag they already set, not on the coerced id.
2. The `_pendingLoadUnitId == null` path logs-then-falls-back silently, assuming the pending id
   is always set before the callback fires.

## Expected differences between groups (do not flag)

When comparing trial vs holdout (e.g. in `ad-log-monitor` Phase 3):

- A **collapsed multi-unit waterfall** in the trial group is expected under Metica's managed
  loading — "one ad ready at a time" is by design, not a regression.
- **Different / Metica-dedicated ad units** in the trial group are expected — do not treat
  ad-unit divergence as a config error.
- An occasional **holdout ad unit in the trial route** is an expected connection-issue fallback,
  not a routing bug.

Compare and attribute by **group, not ad-unit id**.
