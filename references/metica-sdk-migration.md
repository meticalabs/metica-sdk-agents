# MeticaSDK version migration map

The single source of truth for **what changes between MeticaSDK versions** at the
integration-facing API surface. Read by:

- **`unity-integrator`** (upgrade sub-flow) — to know which symbols in an existing integration to
  migrate when bumping the installed SDK to a newer version.
- **`unity-validator`** (`metica_deprecated_api` rule) — to flag leftover use of obsoleted or
  signature-changed symbols after an upgrade (the Unity compile only *warns* on `[Obsolete]`, so
  `compiles_cleanly` does not catch it).

This is a **reasoning doc, not a regex table**: each symbol carries a behavioral question, the
change class, and the migration action. When the SDK bumps, extend the matching section (or add a
new `<from> → <to>` section) rather than rewriting it.

## Change classes

| Class | Meaning | Integration action |
|-------|---------|---------------------|
| **unchanged** | Same signature and behavior. | None. |
| **behavior-changed** | Same signature, different runtime behavior. | Confirm the new behavior is compatible with the existing code; usually no edit. |
| **obsoleted** | Symbol still compiles but is `[Obsolete]`. | Migrate reads/writes to the replacement; obsolete usage is a warning, never a hard break. |
| **signature-changed** | A parameter/constructor changed shape. | Adjust the call site (and any caller relying on the old parameter meaning). |
| **new-optional** | A net-new capability; nothing existing breaks. | Surface as available; adopt only when the project wants it. |

When verifying a verdict that turns on SDK behavior, read the vendored SDK source under
`Assets/MeticaSdk/Runtime/...` to confirm rather than guess.

---

## 2.4.x → 2.45.0

Source-of-truth diff: `metica-unity` `v2.4.3 → v2.45.0` (Android native `2.4.x → 2.5.0`).
Additive at the Unity API surface; one native behavior change lifts a former integration bug.

| Symbol | Class | Question / detail | Migration action |
|--------|-------|-------------------|------------------|
| `MeticaSdk.Ads.GetBannerLayout(adUnitId)` / `MeticaSdk.Ads.GetMrecLayout(adUnitId)` | new-optional | Returns the native banner/MRec on-screen layout (screen-space position + size) so the game can lay out surrounding UI around the ad view. | Adopt only when the game needs to reserve/adapt UI space around a banner or MRec. |
| `MeticaSdk.Ads.Max.TrackEvent(event)` | new-optional | Forwards a game event to Metica's MAX integration for tracking. | Adopt only if the game already emits events to MAX and wants Metica to receive them. |
| `MeticaSdk.Ads.Max.SetAdReviewCreativeIdListener(listener)` | new-optional | Subscribes to AppLovin's Ad Review Creative-ID pushes; the listener receives the creative ID for each shown ad. | Adopt if the game already consumes MAX's Ad Review Creative-ID stream. |
| `MeticaAdConfig.OverrideBidFloor` | new-optional | Per-request bid floor override on the config passed to `Load*` calls. | Adopt only if the game wants to override the server-side bid floor per request. |
| Additional `MeticaAd.AdInfo` / `MeticaAd.ErrorInfo` fields | new-optional | Newly-exposed diagnostic fields on the ad response and error objects (additional network / waterfall metadata). | Read as needed for diagnostics; no existing reads break. |
| Banner/MRec pre-create **value-setter** buffering (Android) | behavior-changed | `SetBannerExtraParameter` / `SetBannerLocalExtraParameter` / `SetBannerCustomData` (and `SetMrec*` equivalents) called **before** `CreateBanner`/`CreateMrec` were previously dropped by the native bridge (wrapper logged `BANNER not found for adUnitId`); they are now buffered per `adUnitId` and applied when `Create*` runs (`UnityBanners.kt` @ v2.5.0 → `applyBufferedConfiguration`). No C# API change. **Scope:** only the three value-setter families above buffer; `SetBanner/MrecPlacement`, `SetBannerBackgroundColor`, and `SetBannerWidth` still `warn + return` pre-create, and `Show` / `Load` without a preceding `Create` still no-ops. | Pre-create use of the three buffered value-setter families that was a silent bug on `< 2.45.0` is now correct on `≥ 2.45.0`. The validator's `banner_setter_after_create` / `mrec_setter_after_create` rules PASS those specific calls on `≥ 2.45.0`; the same rules still FAIL pre-create `SetBanner/MrecPlacement`, `SetBannerBackgroundColor`, `SetBannerWidth`, and any `Show`/`Load` without a `Create`. |

---

## 2.2.x → 2.4.x

Source-of-truth diff: `metica-unity` `v2.2.7 → v2.4.3`. The upgrade is **mostly additive**; an
existing MAX integration that uses only the 3-arg `Initialize`, the privacy setters, and the
per-format `Load`/`Show`/callbacks compiles and runs unchanged. The one real source-level change
is `MeticaSmartFloors`.

| Symbol | Class | Question / detail | Migration action |
|--------|-------|-------------------|------------------|
| `MeticaSdk.Initialize(config, mediationInfo, callback)` (3-arg) | unchanged | Still the canonical entry point. | None. |
| `MeticaSdk.Initialize` re-init behavior | behavior-changed | A second `Initialize` is now **idempotent** (`if (Sdk != null) return;`) instead of warn-and-replace; the native layer keeps the originally-stored config and logs a warning on a differing config. | None — matches the idempotent `Initialize()` pattern the integrator generates. |
| `MeticaSmartFloors.IsSuccess` | obsoleted | `[Obsolete("Use UserGroup and IsForcedHoldout instead")]`. Still present, computed as `!isForcedHoldout`. | Migrate reads to `IsForcedHoldout` (and branch on `UserGroup` where appropriate). Compiles with a warning until migrated. |
| `MeticaSmartFloors(MeticaUserGroup, bool isSuccess)` ctor | signature-changed | Constructor's second arg is now `bool isForcedHoldout` (inverted meaning). Game code almost never constructs this (the SDK does) — flag only if the project does. | If constructed by the project, invert the boolean to `isForcedHoldout` semantics. |
| `MeticaSmartFloors.IsForcedHoldout` | new-optional | New property; the forced-holdout flag. | Prefer over `IsSuccess` going forward. |
| `MeticaSdk.InitializeAnalytics(config)` | new-optional | Analytics-only init (no ads); `Initialize` can later upgrade to full mode. | Adopt only for analytics-only entry points. |
| `MeticaSdk.Initialize(config, mediationInfo, callback, onCmpFlowComplete)` (4-arg) + `MeticaInitConfig(apiKey, appId, userId, cmpFlowSettings)` + `MeticaCmpFlowSettings` | new-optional | Drives the AppLovin MAX CMP terms-and-privacy-policy flow during MAX init; `onCmpFlowComplete` fires once when AppLovin reports the flow finished. The 3-arg overload and 3-arg config ctor are unchanged. | Adopt only when the app wants the MAX-managed CMP flow. |
| `MeticaSdk.InitializeAsync(...)` overloads | new-optional | `Task`-returning init, with a CMP-flow variant. | Adopt only if the project prefers async init. |
| `MeticaAds.RevenueCallbackDelivery` (+ `CallbackDelivery` / `RevenueCallbackDeliverySettings`) | new-optional (recommended ≥2.4.2) | MET-11567. Set once, **before** `MeticaSdk.Initialize`, matched to the game's MaxSDK callback-threading model so fullscreen revenue (and any 3PA forwarder) survives app-close-mid-ad. **The mode-selection rule and its thread-safety trade-offs live in `references/3pa-forwarders.md` (source of truth); don't restate them here.** Banner/MRec revenue is unaffected. The validator's `threepa_forwarder_in_revenue_paid` rule ADVISORYs a 2.4.2+ project whose delivery mode doesn't match its MAX threading. | Adopt on ≥2.4.2 to match MAX threading for any fullscreen `OnAdRevenuePaid` handler (3PA revenue forwarding is the common motivator, but it applies to any handler use); the integrator applies it automatically on fresh codegen. Pick the mode per `references/3pa-forwarders.md`. |
| Banner/MRec `Create<Format>` → `Show<Format>` lifecycle (Android) | signature-changed (behavior, 2.4.2) | Banner/MRec **creation and display are now separate steps**: the client must call `CreateBanner`/`CreateMrec` and then `ShowBanner`/`ShowMrec` for the same `adUnitId` — a `Show`/`Load` with no preceding `Create` displays nothing. Canonical lifecycle `Create → Show` (the SDK loads + auto-refreshes; an explicit `Load` is only manual refresh after `Stop*AutoRefresh`). | Migrate existing banner/MRec code that shows without a preceding `Create` (or collapses the two) to the `Create → Show` order. The validator's `banner_setter_after_create` / `mrec_setter_after_create` rules FAIL a `Show`/`Load` not preceded by a `Create` on ≥2.4.2. |
| `MeticaAds.UpdateBannerPosition` / `UpdateBannerPositionCoordinates` / `UpdateMrecPosition` / `UpdateMrecPositionCoordinates` | new-optional (2.4.1) | Reposition a live banner/MREC without destroy + recreate — maps `MaxSdk.UpdateBannerPosition` / `UpdateMRecPosition` per `references/max-metica-api-map.tsv`. The coordinate variants take `double` x/y. | Adopt where the game repositions ad views; restores any repositioning previously dropped for lack of an equivalent. |
| `MeticaSdk.Ads.Max.HasSupportedCmp()` + `ShowCmpForExistingUser(Action<string?>)` overload | new-optional (2.4.1) | CMP capability check (post-init only — pre-init returns `false` with a warning) and a completion-callback CMP flow (`null` on success, AppLovin error message on failure). | Adopt where the game checked `MaxCmpService.HasSupportedCmp` or used the MAX CMP completion callback. |
| `MeticaSdk.Ads.Max.GetTcfVendorConsentStatus` / `GetAdditionalConsentStatus` / `GetPurposeConsentStatus` / `GetSpecialFeatureOptInStatus` | new-optional (2.4.1) | TCF consent status read-back (`bool?`); MaxSdk has no Unity API for these. | Adopt only if the project reads TCF consent state. |
| `MeticaMediationInfo.MeticaMediationType.LevelPlay` | new-optional | ironSource LevelPlay mediation, compiled only under `#if METICA_LEVELPLAY`. `MAX` is unchanged. | None for a MAX integration. |
| MET-11632 (IL2CPP + managed stripping → forced HOLDOUT) | behavior-changed | Fixed at **≥2.4.2**. Upgrading from `<2.4.2` resolves the forced-holdout bug; `compat-checker`'s `managed_stripping` WARN no longer applies. | Note the resolution in the upgrade report. |

Internal platform refactors (the `INativeBridge` / `AndroidNativeBridgeImpl` / `IOSNativeBridgeImpl`
split, callback-proxy consolidation) are **not** integration-facing and require no migration.
