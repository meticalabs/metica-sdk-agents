# Third-party-analytics (3PA) ad-revenue forwarders

Canonical shapes for forwarding a MeticaSDK ad-revenue event to a third-party analytics
provider, used by the integrator's **"3PA revenue forwarders"** patch pass (integrator.md
Step 5) and referenced by the validator's `threepa_forwarder_in_revenue_paid` rule.

**Single rule that governs all of them:** the forwarder call lives **inside the per-format
`MeticaAdsCallbacks.<Format>.OnAdRevenuePaid` handler** — never `OnAdHidden`, a dismissal
hook, or any other lifecycle event. Forwarding on dismissal loses every click-through user
(they never dismiss). On **SDK < 2.4.2** all forwarders dispatch through Unity's main thread
(`SynchronizationContext.Post`) — which is paused while a fullscreen ad is shown — so even correct
placement carries the click-through-no-return / app-closed-mid-ad caveat surfaced in the Step 7
report.

On **SDK ≥ 2.4.2** set `MeticaAds.RevenueCallbackDelivery` (once, before `MeticaSdk.Initialize`) to
**match the MaxSDK callback-threading model the forwarder was written for** — the forwarder that
lands in `OnAdRevenuePaid` began life as a MAX callback and inherits MAX's thread contract:

- **MAX at its default** (`InvokeEventsOnUnityMainThread` unset/false — MAX invokes callbacks on the
  **native** thread) → `CallbackDelivery.NativeThread`. The fullscreen (interstitial/rewarded)
  `OnAdRevenuePaid` handler — and the forwarder inside it — then runs synchronously on the native
  callback thread and the revenue event survives the app closing mid-ad. The trade-off: the handler
  is then **off** the Unity main thread, so the forwarder calls below must be **thread-safe** — the
  native provider SDK calls (Firebase `LogEvent`, `Adjust.TrackAdRevenue`, `AppMetrica.ReportAdRevenue`,
  `AppsFlyer.sendEvent`) are fine, but do **not** touch Unity APIs (`PlayerPrefs`, `GameObject`,
  `Time.*`) anywhere in the handler's call chain — even a helper that reads `PlayerPrefs` internally
  throws, and the SDK catches handler exceptions, so everything after the throwing line (often the
  forwarder itself) silently never runs. This matches a relocated MAX forwarder, which was already
  native-thread code.
- **MAX with `InvokeEventsOnUnityMainThread = true`** (`MaxSdkBase.InvokeEventsOnUnityMainThread`, or
  the AppLovin Integration Manager toggle) → `CallbackDelivery.UnityMainThread`. The relocated
  forwarder was written to run on the Unity main thread and may touch Unity APIs, so `NativeThread`
  would break it; `UnityMainThread` matches MAX and keeps it correct. The app-close-mid-ad loss
  window remains — but it is the one the game already lived with under MAX.

Banner/MRec revenue is unaffected (always delivered on the main thread).

**Do not wrap the forwarder in a main-thread marshal.** Under NativeThread, posting the reporting
call to the main thread (`UnityMainThreadDispatcher`, `SynchronizationContext.Post`, a custom
`RunOnMainThread`, a coroutine/action queue) defeats the whole point: the Unity player loop is
paused while a fullscreen ad shows, so the posted work sits unpumped until the ad closes — and is
lost entirely if the user kills the app mid-ad. Report **first, directly on the native thread**;
marshal only genuinely Unity-dependent work to the main thread, **after** the reporting calls:

```csharp
MeticaAdsCallbacks.Interstitial.OnAdRevenuePaid += ad =>
{
    // Thread-safe: report immediately, on the native thread.
    Adjust.TrackAdRevenue(BuildAdjustRevenue(ad));

    // Unity-dependent work goes to the main thread — after reporting.
    RunOnMainThread(() => UpdateRevenueUI(ad.revenue));
};
```

**Prefer relocation over generation.** When the game already calls these providers (it almost
always does), move its **existing** calls into the handler — they are version-correct for the
SDK versions the project ships. The snippets below are the fallback when the game had none.
There is **no App-Open forwarder** — App Open Ads are `drop` in `max-metica-api-map.tsv`.

The handler receives a `MeticaAd` (`ad.revenue`, `ad.networkName`, `ad.adUnitId`,
`ad.adFormat`, `ad.placementTag`). `ad.revenue` is the impression revenue in USD.

```csharp
// Inside each used format's named handler, e.g. OnInterstitialRevenuePaid(MeticaAd ad):

// Firebase Analytics
var p = new[] {
    new Firebase.Analytics.Parameter("ad_platform",  "AppLovin"),
    new Firebase.Analytics.Parameter("ad_source",    ad.networkName),
    new Firebase.Analytics.Parameter("ad_unit_name", ad.adUnitId),
    new Firebase.Analytics.Parameter("ad_format",    ad.adFormat),
    new Firebase.Analytics.Parameter("value",        ad.revenue ?? 0.0),
    new Firebase.Analytics.Parameter("currency",     "USD"),
};
Firebase.Analytics.FirebaseAnalytics.LogEvent("ad_impression", p);

// Adjust — use the game's existing AdjustAdRevenue wiring if present
var adjustRevenue = new AdjustAdRevenue("applovin_max_sdk");
adjustRevenue.SetRevenue(ad.revenue ?? 0.0, "USD");
adjustRevenue.AdRevenueNetwork = ad.networkName;
adjustRevenue.AdRevenueUnit    = ad.adUnitId;
Adjust.TrackAdRevenue(adjustRevenue);

// AppMetrica
AppMetrica.Instance.ReportAdRevenue(new Io.AppMetrica.AdRevenue(ad.revenue ?? 0.0, "USD") {
    AdType    = Io.AppMetrica.AdType.Other,
    AdNetwork = ad.networkName,
    AdUnitId  = ad.adUnitId,
});

// AppsFlyer
AppsFlyer.sendEvent("af_ad_revenue", new Dictionary<string, string> {
    { "af_revenue",  (ad.revenue ?? 0.0).ToString(System.Globalization.CultureInfo.InvariantCulture) },
    { "af_currency", "USD" },
    { "af_ad_network", ad.networkName },
});
```

> `ad.revenue` is `double?` (the SDK marks impression revenue as optional). The `?? 0.0` is
> required — Firebase / Adjust / AppMetrica / AppsFlyer all take `double`, not `double?`. Don't
> remove. `ad.networkName` and `ad.adFormat` are `string?` but their consumers here are `string`
> parameters / `Dictionary<string,string>` values, which accept `null` in C#, so they need no
> coalesce; `ad.adUnitId` is non-nullable `string`. `ad.placementTag` (`string?`) isn't passed to
> any consumer in these snippets.

Mirror the same handler shape for `OnBannerRevenuePaid`, `OnRewardedRevenuePaid`, and
`OnMrecRevenuePaid` — every used format that the project forwards.

> These signatures track the providers' SDKs as of 2026-06; when a
> game ships a different major version, relocate **its** calls rather than forcing these. Keep
> this file in sync if the integrator's generated fallback changes.
