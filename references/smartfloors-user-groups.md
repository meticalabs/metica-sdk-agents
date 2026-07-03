# SmartFloors user groups: group-aware ad control

The Metica SmartFloors **user group** (`initResponse.SmartFloors.UserGroup`, and the
`IsForcedHoldout` flag) is the single source of truth for **how the app runs its ad loading**.
Metica's own integration guidance directs integrators to branch ad-control logic on the group,
and real shipped Metica integrations implement exactly this pattern. This doc records the
sanctioned shape so the validator and the `ad-log-monitor` skill agree on what is expected
(mirroring the role `max-metica-api-map.tsv` plays for the Max↔Metica surface).

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

## Worked example — the shape of a group-aware integration

A correct group-aware integration wires the pattern like this:

- **Group read at init** — read the group from the init response inside `OnInitialized` and tag
  it to an analytics user-property (e.g. a `metica_group` tag).
- **Waterfall gated to holdout** — expose a single `IsMultipleAdsEnabled`-style predicate that is
  true only for holdout; the multi-unit waterfall runs only when it is true, and trial loads a
  single default unit.
- **Callbacks resolve the unit id per group** — the load/show callbacks resolve the reported unit
  id by group rather than assuming the requested id was served.

Two cautions when implementing this shape (not blockers):

1. Coercing the trial callback's unit id back to the requested id (e.g. `pendingLoadId ??
   sdkUnitId`) can misrepresent what actually served, given the holdout-fallback caveat above —
   keep revenue attribution on the group tag, not on the coerced id.
2. Assuming the pending id is always set before the callback fires (logging then falling back
   silently when it is not) is fragile — handle the unset case explicitly.

## Expected differences between groups (do not flag)

When comparing trial vs holdout (e.g. in `ad-log-monitor` Phase 3):

- A **collapsed multi-unit waterfall** in the trial group is expected under Metica's managed
  loading — "one ad ready at a time" is by design, not a regression.
- **Different / Metica-dedicated ad units** in the trial group are expected — do not treat
  ad-unit divergence as a config error.
- An occasional **holdout ad unit in the trial route** is an expected connection-issue fallback,
  not a routing bug.

Compare and attribute by **group, not ad-unit id**.
