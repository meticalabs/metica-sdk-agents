# Third-party-analytics (3PA) ad-revenue forwarders

Canonical shapes for forwarding a MeticaSDK ad-revenue event to a third-party analytics
provider, used by the integrator's **"3PA revenue forwarders"** patch pass (integrator.md
Step 5) and referenced by the validator's `threepa_forwarder_in_revenue_paid` rule.

**Single rule that governs all of them:** the forwarder call lives **inside the per-format
`MeticaAdsCallbacks.<Format>.OnAdRevenuePaid` handler** — never `OnAdHidden`, a dismissal
hook, or any other lifecycle event. Forwarding on dismissal loses every click-through user
(they never dismiss). All forwarders dispatch through Unity's main thread
(`SynchronizationContext.Post`), so even correct placement carries the click-through-no-return
caveat surfaced in the Step 7 report.

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
    new Firebase.Analytics.Parameter("value",        ad.revenue),
    new Firebase.Analytics.Parameter("currency",     "USD"),
};
Firebase.Analytics.FirebaseAnalytics.LogEvent("ad_impression", p);

// Adjust — use the game's existing AdjustAdRevenue wiring if present
var adjustRevenue = new AdjustAdRevenue("applovin_max_sdk");
adjustRevenue.SetRevenue(ad.revenue, "USD");
adjustRevenue.AdRevenueNetwork = ad.networkName;
adjustRevenue.AdRevenueUnit    = ad.adUnitId;
Adjust.TrackAdRevenue(adjustRevenue);

// AppMetrica
AppMetrica.Instance.ReportAdRevenue(new Io.AppMetrica.AdRevenue(ad.revenue, "USD") {
    AdType    = Io.AppMetrica.AdType.Other,
    AdNetwork = ad.networkName,
    AdUnitId  = ad.adUnitId,
});

// AppsFlyer
AppsFlyer.sendEvent("af_ad_revenue", new Dictionary<string, string> {
    { "af_revenue",  ad.revenue.ToString() },
    { "af_currency", "USD" },
    { "af_ad_network", ad.networkName },
});
```

Mirror the same handler shape for `OnBannerRevenuePaid`, `OnRewardedRevenuePaid`, and
`OnMrecRevenuePaid` — every used format that the project forwards.

> These signatures track the providers' SDKs as of the Ragdoll investigation (2026-06); when a
> game ships a different major version, relocate **its** calls rather than forcing these. Keep
> this file in sync if the integrator's generated fallback changes.
