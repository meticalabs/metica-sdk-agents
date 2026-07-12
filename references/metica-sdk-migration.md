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
| `MeticaAds.RevenueCallbackDelivery` (+ `CallbackDelivery` / `RevenueCallbackDeliverySettings`) | new-optional (recommended ≥2.4.2) | MET-11567. Set once, **before** `MeticaSdk.Initialize`, to **match the game's MaxSDK callback-threading model** — a 3PA forwarder relocated into `OnAdRevenuePaid` inherits MAX's thread contract. **MAX at its default** (`MaxSdk.InvokeEventsOnUnityMainThread` unset/false — native-thread callbacks) → `= CallbackDelivery.NativeThread`: delivers fullscreen (interstitial/rewarded) `OnAdRevenuePaid` **synchronously on the native callback thread** instead of posting it to the Unity main thread — which is paused while a fullscreen ad is shown, so a main-thread-posted callback (and any 3PA forwarder inside it) is lost if the process dies first. **Trade-off:** the handler then runs **off** the Unity main thread, so it must be thread-safe (no Unity-main-thread-only APIs anywhere in its call chain) — and the forwarder must **not** be wrapped in a main-thread dispatcher inside the handler, which re-introduces the exact loss NativeThread exists to prevent (report first on the native thread; marshal Unity work after — see `references/3pa-forwarders.md`). **MAX with `MaxSdk.InvokeEventsOnUnityMainThread = true`** (set in game code) → `= CallbackDelivery.UnityMainThread`: the relocated forwarder was written for the main thread and may touch Unity APIs, so NativeThread would break it; matching to UnityMainThread keeps it correct (the app-close-mid-ad loss window remains — the one the game already lived with under MAX). Banner/MRec revenue is unaffected (still main thread). The validator's `threepa_forwarder_in_revenue_paid` rule ADVISORYs a 2.4.2+ project whose delivery mode does not match its MAX threading. | Surface as the recommended way to keep fullscreen impression revenue (and 3PA forwarders) from being lost on app-closed-mid-ad; adopt when the project forwards revenue to a 3PA SDK, matching the mode to MAX's threading and confirming the handler is thread-safe under NativeThread. |
| Banner/MRec `Create<Format>` → `Show<Format>` lifecycle (Android) | signature-changed (behavior, 2.4.2) | Banner/MRec **creation and display are now separate steps**: the client must call `CreateBanner`/`CreateMrec` and then `ShowBanner`/`ShowMrec` for the same `adUnitId` — a `Show`/`Load` with no preceding `Create` displays nothing. Canonical lifecycle `Create → Show` (the SDK loads + auto-refreshes; an explicit `Load` is only manual refresh after `Stop*AutoRefresh`). | Migrate existing banner/MRec code that shows without a preceding `Create` (or collapses the two) to the `Create → Show` order. The validator's `banner_setter_after_create` / `mrec_setter_after_create` rules FAIL a `Show`/`Load` not preceded by a `Create` on ≥2.4.2. |
| `MeticaMediationInfo.MeticaMediationType.LevelPlay` | new-optional | ironSource LevelPlay mediation, compiled only under `#if METICA_LEVELPLAY`. `MAX` is unchanged. | None for a MAX integration. |
| MET-11632 (IL2CPP + managed stripping → forced HOLDOUT) | behavior-changed | Fixed at **≥2.4.2**. Upgrading from `<2.4.2` resolves the forced-holdout bug; `compat-checker`'s `managed_stripping` WARN no longer applies. | Note the resolution in the upgrade report. |

Internal platform refactors (the `INativeBridge` / `AndroidNativeBridgeImpl` / `IOSNativeBridgeImpl`
split, callback-proxy consolidation) are **not** integration-facing and require no migration.
