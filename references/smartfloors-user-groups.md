# SmartFloors user groups: group-aware ad control

The Metica SmartFloors **user group** — `initResponse.SmartFloors.UserGroup` — is the single
source of truth for **how the app runs its ad loading**. (`IsForcedHoldout` is a separate boolean
flag on the same response, `true` for the holdout group; it's a convenience for the holdout-vs-not
split, not part of the group value itself — branch on whichever the SDK version exposes.)
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

The same applies **inside callbacks**: a guard like `if (ad.adUnitId != _loadedAdUnitId) return;`
at the top of a revenue/reward/lifecycle handler silently drops revenue and events whenever
Metica serves a different unit than requested. The idiom is usually copied from a MAX
integration, where a per-ad-unit guard is idiomatic — under Metica it is a bug. When per-format
routing is needed, key on the ad format / callback source, never on id equality with the
requested unit.

## Load-callback payload fields are not decision inputs

Trial mode also **decouples loading from the game**: the SDK runs internal loading loops, the
load callback (`OnAdLoadSuccess`) reports whichever internal instance resolved first — usually
the zero-floor fallback — and the SDK afterwards rotates inventory silently, firing no further
game events. So on trial the load callback's `MeticaAd` payload fields carry different semantics
than under holdout or a direct-MAX integration:

- `revenue` is **biased low** (it reflects the fallback ad that completed the awaited load, not
  the best available ad) and **stale** (the internal loop's reloads fire no game events).
- `adUnitId` is a **substituted Metica-dedicated unit** (see above).
- `networkName` attributes the fallback instance, not what will actually show.

The payload fields are therefore **analytics-only**: log them, forward them to revenue trackers,
attribute by group — but never gate showing or loading on them. An eCPM show-gate built on
stored load-callback revenue (`storedRevenue * 1000 < minimumEcpm`) suppressed shows **only for
trial users** in a shipped game while holdout passed — the trial-only-deficit class of bug.

Likewise, never feed the callback's `adUnitId` back into subsequent SDK calls (a stored
callback-derived id passed to `Load*` / `Show*` / `Is<Format>Ready`): pass the **configured
publisher ad-unit id** through unchanged. The native SDK currently neutralizes a
callback-derived id on trial, but that is an implementation detail — relying on it is
version-fragile and drifts the publisher-ad-unit-id parameter.

## Worked example — the shape of a group-aware integration

A correct group-aware integration wires the pattern like this:

- **Group read at init** — read the group from the init response inside `OnInitialized` and tag
  it to an analytics user-property (e.g. a `metica_group` tag).
- **Waterfall gated to holdout** — expose a single `IsMultipleAdsEnabled`-style predicate that is
  true only for holdout; the multi-unit waterfall runs only when it is true, and trial loads a
  single default unit.
- **Attribute callbacks by group, not by returned id** — in the load/show callbacks, log and
  attribute the impression/revenue by the group tag read at init, rather than assuming the
  returned `MeticaAd.adUnitId` matches the requested id. Don't rewrite or route on the returned
  id — attribution only.

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
