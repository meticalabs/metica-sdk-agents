# AI Agent Instructions: A/B Testing — MaxSdk vs MeticaSdk Side-by-Side

You are a Unity C# developer assistant. Your task is to set up an **A/B testing architecture** that runs both AppLovin MaxSdk 8.6.0 and MeticaSdk 2.4.0 side-by-side in the same Unity project. This lets the developer validate MeticaSdk performance (revenue, fill rates, latency) against the existing MaxSdk baseline before fully committing to the migration.

Follow every step below in order. Do not skip steps. After each step, confirm what you changed.

---

## Architecture Overview

```
┌──────────────────────────────┐
│       Game Code              │
│   (calls IAdService only)    │
└──────────┬───────────────────┘
           │
    ┌──────▼──────┐
    │ AdServiceRouter │  ← switches based on config flag
    └──┬───────┬──┘
       │       │
┌──────▼──┐ ┌──▼──────────┐
│ MaxSdk   │ │ MeticaSdk    │
│ Adapter  │ │ Adapter      │
└──────────┘ └──────────────┘
```

- **`IAdService`** — interface defining all ad operations your game uses
- **`MaxAdService`** — adapter wrapping existing MaxSdk calls (your current code, restructured)
- **`MeticaAdService`** — adapter using MeticaSdk calls
- **`AdServiceRouter`** — picks which adapter to use at runtime based on a config flag

---

## Critical Rules

1. **Both SDKs remain installed** — AppLovin MAX plugin + MeticaSdk package
2. **Only ONE SDK initializes per session** — never initialize both simultaneously
3. **Same ad unit IDs** for both — MeticaSdk reuses your existing MAX ad unit IDs
4. **MeticaSdk privacy calls BEFORE init** — `SetHasUserConsent` and `SetDoNotSell` must precede `Initialize`
5. **Track metrics for both groups** — revenue, fill rate, latency, show rate per ad format

---

## Step 0: Verify MaxSdk Version (REQUIRED)

MeticaSdk 2.4.0 requires **AppLovin MAX Unity Plugin v8.2.0 or later**. Before making any changes, verify the installed version.

### How to check:
1. Search the project for the MaxSdk version property or changelog:
   ```
   Search for: MaxSdk.Version
   Search for files: CHANGELOG.md or package.json inside the MaxSdk or AppLovin plugin folder
   ```
2. Alternatively, check `MaxSdk.Version` at runtime: `Debug.Log("MAX SDK version: " + MaxSdk.Version);`

### If version is below 8.2.0:
**STOP.** Do not proceed. The developer must update the AppLovin MAX Unity Plugin to v8.2.0+ first.

### If version is 8.2.0 or later:
Proceed to Step 1.

---

## Step 1: Create the Ad Service Interface

Create a new file `IAdService.cs`. This interface covers the ad operations your game actually uses. Adjust based on which ad formats you use.

```csharp
using System;

/// <summary>
/// Abstraction over ad SDK to enable A/B testing between MaxSdk and MeticaSdk.
/// </summary>
public interface IAdService
{
    // Lifecycle
    void Initialize(Action onInitialized);

    // Banner
    void CreateBanner(string adUnitId, BannerPosition position);
    void LoadBanner(string adUnitId);
    void ShowBanner(string adUnitId);
    void HideBanner(string adUnitId);
    void DestroyBanner(string adUnitId);

    // Interstitial
    void LoadInterstitial(string adUnitId);
    bool IsInterstitialReady(string adUnitId);
    void ShowInterstitial(string adUnitId, string placement = null, string customData = null);

    // Rewarded
    void LoadRewarded(string adUnitId);
    bool IsRewardedReady(string adUnitId);
    void ShowRewarded(string adUnitId, string placement = null, string customData = null);

    // Privacy
    void SetHasUserConsent(bool hasConsent);
    void SetDoNotSell(bool doNotSell);

    // Events — subscribe to these in your game code
    event Action<AdEventData> OnBannerLoaded;
    event Action<AdErrorData> OnBannerLoadFailed;
    event Action<AdEventData> OnBannerRevenuePaid;

    event Action<AdEventData> OnInterstitialLoaded;
    event Action<AdErrorData> OnInterstitialLoadFailed;
    event Action<AdEventData> OnInterstitialShown;
    event Action<AdEventData> OnInterstitialHidden;
    event Action<AdEventData> OnInterstitialRevenuePaid;

    event Action<AdEventData> OnRewardedLoaded;
    event Action<AdErrorData> OnRewardedLoadFailed;
    event Action<AdEventData> OnRewardedShown;
    event Action<AdEventData> OnRewardedHidden;
    event Action<AdEventData> OnRewardedRewarded;
    event Action<AdEventData> OnRewardedRevenuePaid;
}

/// <summary>Normalized ad event data shared across both SDKs.</summary>
public class AdEventData
{
    public string AdUnitId;
    public string NetworkName;
    public double Revenue;
    public string AdFormat;
    public string Placement;
    public long LatencyMs;
    public string SdkSource; // "MaxSdk" or "MeticaSdk" — for metrics tracking
}

/// <summary>Normalized ad error data shared across both SDKs.</summary>
public class AdErrorData
{
    public string AdUnitId;
    public string Message;
    public string SdkSource;
}

public enum BannerPosition
{
    TopCenter,
    BottomCenter,
    Centered
}
```

---

## Step 2: Implement the MaxSdk Adapter

Create `MaxAdService.cs`. This wraps your existing MaxSdk calls behind the `IAdService` interface with minimal changes.

```csharp
using System;
using UnityEngine;

public class MaxAdService : IAdService
{
    private const string SDK_SOURCE = "MaxSdk";

    public event Action<AdEventData> OnBannerLoaded;
    public event Action<AdErrorData> OnBannerLoadFailed;
    public event Action<AdEventData> OnBannerRevenuePaid;
    public event Action<AdEventData> OnInterstitialLoaded;
    public event Action<AdErrorData> OnInterstitialLoadFailed;
    public event Action<AdEventData> OnInterstitialShown;
    public event Action<AdEventData> OnInterstitialHidden;
    public event Action<AdEventData> OnInterstitialRevenuePaid;
    public event Action<AdEventData> OnRewardedLoaded;
    public event Action<AdErrorData> OnRewardedLoadFailed;
    public event Action<AdEventData> OnRewardedShown;
    public event Action<AdEventData> OnRewardedHidden;
    public event Action<AdEventData> OnRewardedRewarded;
    public event Action<AdEventData> OnRewardedRevenuePaid;

    private readonly string _maxSdkKey;
    private Action _onInitialized;

    public MaxAdService(string maxSdkKey)
    {
        _maxSdkKey = maxSdkKey;
    }

    // --- Lifecycle ---

    public void Initialize(Action onInitialized)
    {
        _onInitialized = onInitialized;
        MaxSdkCallbacks.OnSdkInitializedEvent += OnSdkInitialized;
        MaxSdk.SetSdkKey(_maxSdkKey);
        MaxSdk.InitializeSdk();
    }

    private void OnSdkInitialized(MaxSdkBase.SdkConfiguration config)
    {
        SubscribeCallbacks();
        _onInitialized?.Invoke();
    }

    private void SubscribeCallbacks()
    {
        // Banner
        MaxSdkCallbacks.Banner.OnAdLoadedEvent += (id, info) =>
            OnBannerLoaded?.Invoke(ToEventData(id, info));
        MaxSdkCallbacks.Banner.OnAdLoadFailedEvent += (id, err) =>
            OnBannerLoadFailed?.Invoke(ToErrorData(id, err));
        MaxSdkCallbacks.Banner.OnAdRevenuePaidEvent += (id, info) =>
            OnBannerRevenuePaid?.Invoke(ToEventData(id, info));

        // Interstitial
        MaxSdkCallbacks.Interstitial.OnAdLoadedEvent += (id, info) =>
            OnInterstitialLoaded?.Invoke(ToEventData(id, info));
        MaxSdkCallbacks.Interstitial.OnAdLoadFailedEvent += (id, err) =>
            OnInterstitialLoadFailed?.Invoke(ToErrorData(id, err));
        MaxSdkCallbacks.Interstitial.OnAdDisplayedEvent += (id, info) =>
            OnInterstitialShown?.Invoke(ToEventData(id, info));
        MaxSdkCallbacks.Interstitial.OnAdHiddenEvent += (id, info) =>
            OnInterstitialHidden?.Invoke(ToEventData(id, info));
        MaxSdkCallbacks.Interstitial.OnAdRevenuePaidEvent += (id, info) =>
            OnInterstitialRevenuePaid?.Invoke(ToEventData(id, info));

        // Rewarded
        MaxSdkCallbacks.Rewarded.OnAdLoadedEvent += (id, info) =>
            OnRewardedLoaded?.Invoke(ToEventData(id, info));
        MaxSdkCallbacks.Rewarded.OnAdLoadFailedEvent += (id, err) =>
            OnRewardedLoadFailed?.Invoke(ToErrorData(id, err));
        MaxSdkCallbacks.Rewarded.OnAdDisplayedEvent += (id, info) =>
            OnRewardedShown?.Invoke(ToEventData(id, info));
        MaxSdkCallbacks.Rewarded.OnAdHiddenEvent += (id, info) =>
            OnRewardedHidden?.Invoke(ToEventData(id, info));
        MaxSdkCallbacks.Rewarded.OnAdReceivedRewardEvent += (id, reward, info) =>
            OnRewardedRewarded?.Invoke(ToEventData(id, info));
        MaxSdkCallbacks.Rewarded.OnAdRevenuePaidEvent += (id, info) =>
            OnRewardedRevenuePaid?.Invoke(ToEventData(id, info));
    }

    // --- Banner ---

    public void CreateBanner(string adUnitId, BannerPosition position)
    {
        var config = new MaxSdkBase.AdViewConfiguration(ToMaxPosition(position));
        MaxSdk.CreateBanner(adUnitId, config);
    }

    public void LoadBanner(string adUnitId) => MaxSdk.LoadBanner(adUnitId);
    public void ShowBanner(string adUnitId) => MaxSdk.ShowBanner(adUnitId);
    public void HideBanner(string adUnitId) => MaxSdk.HideBanner(adUnitId);
    public void DestroyBanner(string adUnitId) => MaxSdk.DestroyBanner(adUnitId);

    // --- Interstitial ---

    public void LoadInterstitial(string adUnitId) => MaxSdk.LoadInterstitial(adUnitId);
    public bool IsInterstitialReady(string adUnitId) => MaxSdk.IsInterstitialReady(adUnitId);
    public void ShowInterstitial(string adUnitId, string placement = null, string customData = null)
        => MaxSdk.ShowInterstitial(adUnitId, placement, customData);

    // --- Rewarded ---

    public void LoadRewarded(string adUnitId) => MaxSdk.LoadRewardedAd(adUnitId);
    public bool IsRewardedReady(string adUnitId) => MaxSdk.IsRewardedAdReady(adUnitId);
    public void ShowRewarded(string adUnitId, string placement = null, string customData = null)
        => MaxSdk.ShowRewardedAd(adUnitId, placement, customData);

    // --- Privacy ---

    public void SetHasUserConsent(bool hasConsent) => MaxSdk.SetHasUserConsent(hasConsent);
    public void SetDoNotSell(bool doNotSell) => MaxSdk.SetDoNotSell(doNotSell);

    // --- Helpers ---

    private static MaxSdkBase.AdViewPosition ToMaxPosition(BannerPosition pos) => pos switch
    {
        BannerPosition.TopCenter => MaxSdkBase.AdViewPosition.TopCenter,
        BannerPosition.BottomCenter => MaxSdkBase.AdViewPosition.BottomCenter,
        BannerPosition.Centered => MaxSdkBase.AdViewPosition.Centered,
        _ => MaxSdkBase.AdViewPosition.BottomCenter
    };

    private AdEventData ToEventData(string adUnitId, MaxSdkBase.AdInfo info) => new AdEventData
    {
        AdUnitId = adUnitId,
        NetworkName = info.NetworkName,
        Revenue = info.Revenue,
        AdFormat = info.AdFormat,
        Placement = info.Placement,
        LatencyMs = info.LatencyMillis,
        SdkSource = SDK_SOURCE
    };

    private AdErrorData ToErrorData(string adUnitId, MaxSdkBase.ErrorInfo err) => new AdErrorData
    {
        AdUnitId = adUnitId,
        Message = err.Message,
        SdkSource = SDK_SOURCE
    };
}
```

---

## Step 3: Implement the MeticaSdk Adapter

Create `MeticaAdService.cs`. This implements the same interface using MeticaSdk calls.

```csharp
using System;
using Metica;
using Metica.Ads;
using UnityEngine;

public class MeticaAdService : IAdService
{
    private const string SDK_SOURCE = "MeticaSdk";

    public event Action<AdEventData> OnBannerLoaded;
    public event Action<AdErrorData> OnBannerLoadFailed;
    public event Action<AdEventData> OnBannerRevenuePaid;
    public event Action<AdEventData> OnInterstitialLoaded;
    public event Action<AdErrorData> OnInterstitialLoadFailed;
    public event Action<AdEventData> OnInterstitialShown;
    public event Action<AdEventData> OnInterstitialHidden;
    public event Action<AdEventData> OnInterstitialRevenuePaid;
    public event Action<AdEventData> OnRewardedLoaded;
    public event Action<AdErrorData> OnRewardedLoadFailed;
    public event Action<AdEventData> OnRewardedShown;
    public event Action<AdEventData> OnRewardedHidden;
    public event Action<AdEventData> OnRewardedRewarded;
    public event Action<AdEventData> OnRewardedRevenuePaid;

    private readonly string _apiKey;
    private readonly string _appId;
    private readonly string _maxSdkKey;
    private readonly string _userId;

    public MeticaAdService(string apiKey, string appId, string maxSdkKey, string userId = null)
    {
        _apiKey = apiKey;
        _appId = appId;
        _maxSdkKey = maxSdkKey;
        _userId = userId;
    }

    // --- Lifecycle ---

    public void Initialize(Action onInitialized)
    {
        SubscribeCallbacks();

        var config = new MeticaInitConfig(_apiKey, _appId, _userId);
        var mediationInfo = new MeticaMediationInfo(
            MeticaMediationInfo.MeticaMediationType.MAX,
            _maxSdkKey
        );

        MeticaSdk.Initialize(config, mediationInfo, initResponse =>
        {
            Debug.Log($"[MeticaAdService] Init success. SmartFloors group: {initResponse.SmartFloors.UserGroup}, forced holdout: {initResponse.SmartFloors.IsForcedHoldout}");
            onInitialized?.Invoke();
        });
    }

    private void SubscribeCallbacks()
    {
        // Banner
        MeticaAdsCallbacks.Banner.OnAdLoadSuccess += ad =>
            OnBannerLoaded?.Invoke(ToEventData(ad));
        MeticaAdsCallbacks.Banner.OnAdLoadFailed += err =>
            OnBannerLoadFailed?.Invoke(ToErrorData(err));
        MeticaAdsCallbacks.Banner.OnAdRevenuePaid += ad =>
            OnBannerRevenuePaid?.Invoke(ToEventData(ad));

        // Interstitial
        MeticaAdsCallbacks.Interstitial.OnAdLoadSuccess += ad =>
            OnInterstitialLoaded?.Invoke(ToEventData(ad));
        MeticaAdsCallbacks.Interstitial.OnAdLoadFailed += err =>
            OnInterstitialLoadFailed?.Invoke(ToErrorData(err));
        MeticaAdsCallbacks.Interstitial.OnAdShowSuccess += ad =>
            OnInterstitialShown?.Invoke(ToEventData(ad));
        MeticaAdsCallbacks.Interstitial.OnAdHidden += ad =>
            OnInterstitialHidden?.Invoke(ToEventData(ad));
        MeticaAdsCallbacks.Interstitial.OnAdRevenuePaid += ad =>
            OnInterstitialRevenuePaid?.Invoke(ToEventData(ad));

        // Rewarded
        MeticaAdsCallbacks.Rewarded.OnAdLoadSuccess += ad =>
            OnRewardedLoaded?.Invoke(ToEventData(ad));
        MeticaAdsCallbacks.Rewarded.OnAdLoadFailed += err =>
            OnRewardedLoadFailed?.Invoke(ToErrorData(err));
        MeticaAdsCallbacks.Rewarded.OnAdShowSuccess += ad =>
            OnRewardedShown?.Invoke(ToEventData(ad));
        MeticaAdsCallbacks.Rewarded.OnAdHidden += ad =>
            OnRewardedHidden?.Invoke(ToEventData(ad));
        MeticaAdsCallbacks.Rewarded.OnAdRewarded += ad =>
            OnRewardedRewarded?.Invoke(ToEventData(ad));
        MeticaAdsCallbacks.Rewarded.OnAdRevenuePaid += ad =>
            OnRewardedRevenuePaid?.Invoke(ToEventData(ad));
    }

    // --- Banner ---

    public void CreateBanner(string adUnitId, BannerPosition position)
    {
        var config = new MeticaAdViewConfiguration(ToMeticaPosition(position));
        MeticaSdk.Ads.CreateBanner(adUnitId, config);
    }

    public void LoadBanner(string adUnitId) => MeticaSdk.Ads.LoadBanner(adUnitId);
    public void ShowBanner(string adUnitId) => MeticaSdk.Ads.ShowBanner(adUnitId);
    public void HideBanner(string adUnitId) => MeticaSdk.Ads.HideBanner(adUnitId);
    public void DestroyBanner(string adUnitId) => MeticaSdk.Ads.DestroyBanner(adUnitId);

    // --- Interstitial ---

    public void LoadInterstitial(string adUnitId) => MeticaSdk.Ads.LoadInterstitial(adUnitId);
    public bool IsInterstitialReady(string adUnitId) => MeticaSdk.Ads.IsInterstitialReady(adUnitId);
    public void ShowInterstitial(string adUnitId, string placement = null, string customData = null)
        => MeticaSdk.Ads.ShowInterstitial(adUnitId, placement, customData);

    // --- Rewarded ---

    public void LoadRewarded(string adUnitId) => MeticaSdk.Ads.LoadRewarded(adUnitId);
    public bool IsRewardedReady(string adUnitId) => MeticaSdk.Ads.IsRewardedReady(adUnitId);
    public void ShowRewarded(string adUnitId, string placement = null, string customData = null)
        => MeticaSdk.Ads.ShowRewarded(adUnitId, placement, customData);

    // --- Privacy ---

    public void SetHasUserConsent(bool hasConsent) => MeticaSdk.Ads.SetHasUserConsent(hasConsent);
    public void SetDoNotSell(bool doNotSell) => MeticaSdk.Ads.SetDoNotSell(doNotSell);

    // --- Helpers ---

    private static MeticaAdViewPosition ToMeticaPosition(BannerPosition pos) => pos switch
    {
        BannerPosition.TopCenter => MeticaAdViewPosition.TopCenter,
        BannerPosition.BottomCenter => MeticaAdViewPosition.BottomCenter,
        BannerPosition.Centered => MeticaAdViewPosition.Centered,
        _ => MeticaAdViewPosition.BottomCenter
    };

    private AdEventData ToEventData(MeticaAd ad) => new AdEventData
    {
        AdUnitId = ad.adUnitId,
        NetworkName = ad.networkName,
        Revenue = ad.revenue ?? 0,
        AdFormat = ad.adFormat,
        Placement = ad.placementTag,
        LatencyMs = ad.latency ?? 0,
        SdkSource = SDK_SOURCE
    };

    private AdErrorData ToErrorData(MeticaAdError err) => new AdErrorData
    {
        AdUnitId = err.adUnitId,
        Message = err.message,
        SdkSource = SDK_SOURCE
    };
}
```

---

## Step 4: Create the Router and Switching Mechanism

Create `AdServiceRouter.cs` — a MonoBehaviour that picks the correct adapter at startup.

```csharp
using UnityEngine;

public class AdServiceRouter : MonoBehaviour
{
    [Header("Credentials")]
    [SerializeField] private string meticaApiKey = "YOUR_API_KEY";
    [SerializeField] private string meticaAppId = "YOUR_APP_ID";
    [SerializeField] private string maxSdkKey = "YOUR_MAX_SDK_KEY";

    [Header("A/B Test Config")]
    [Tooltip("true = use MeticaSdk, false = use MaxSdk (control group)")]
    [SerializeField] private bool useMeticaSdk = false;

    [Tooltip("If > 0, randomly assign this percentage of users to MeticaSdk (overrides useMeticaSdk toggle)")]
    [Range(0, 100)]
    [SerializeField] private int meticaRolloutPercent = 0;

    public static AdServiceRouter Instance { get; private set; }
    public IAdService AdService { get; private set; }
    public string ActiveSdk { get; private set; }

    void Awake()
    {
        if (Instance != null) { Destroy(gameObject); return; }
        Instance = this;
        DontDestroyOnLoad(gameObject);

        bool shouldUseMetica = DetermineGroup();
        ActiveSdk = shouldUseMetica ? "MeticaSdk" : "MaxSdk";

        if (shouldUseMetica)
        {
            AdService = new MeticaAdService(meticaApiKey, meticaAppId, maxSdkKey);
        }
        else
        {
            AdService = new MaxAdService(maxSdkKey);
        }

        Debug.Log($"[AdServiceRouter] A/B group: {ActiveSdk}");
    }

    private bool DetermineGroup()
    {
        if (meticaRolloutPercent > 0)
        {
            // Persistent assignment: hash the user/device ID for consistent grouping
            int hash = Mathf.Abs(SystemInfo.deviceUniqueIdentifier.GetHashCode());
            return (hash % 100) < meticaRolloutPercent;
        }
        return useMeticaSdk;
    }
}
```

---

## Step 5: Add Metrics Tracking

Create `AdMetricsTracker.cs` to log performance data per SDK for comparison.

```csharp
using System;
using System.Collections.Generic;
using UnityEngine;

public class AdMetricsTracker
{
    // Call this to wire up tracking to whichever IAdService is active
    public static void Attach(IAdService adService)
    {
        adService.OnBannerLoaded += ad => LogMetric("banner_loaded", ad);
        adService.OnBannerLoadFailed += err => LogError("banner_load_failed", err);
        adService.OnBannerRevenuePaid += ad => LogRevenue("banner", ad);

        adService.OnInterstitialLoaded += ad => LogMetric("interstitial_loaded", ad);
        adService.OnInterstitialLoadFailed += err => LogError("interstitial_load_failed", err);
        adService.OnInterstitialShown += ad => LogMetric("interstitial_shown", ad);
        adService.OnInterstitialRevenuePaid += ad => LogRevenue("interstitial", ad);

        adService.OnRewardedLoaded += ad => LogMetric("rewarded_loaded", ad);
        adService.OnRewardedLoadFailed += err => LogError("rewarded_load_failed", err);
        adService.OnRewardedShown += ad => LogMetric("rewarded_shown", ad);
        adService.OnRewardedRewarded += ad => LogMetric("rewarded_reward_granted", ad);
        adService.OnRewardedRevenuePaid += ad => LogRevenue("rewarded", ad);
    }

    private static void LogMetric(string eventName, AdEventData ad)
    {
        Debug.Log($"[AdMetrics] {ad.SdkSource} | {eventName} | unit={ad.AdUnitId} | net={ad.NetworkName} | latency={ad.LatencyMs}ms");

        // TODO: Send to your analytics backend with ad.SdkSource as a dimension
        // Example: Analytics.LogEvent(eventName, new Dictionary<string, string> {
        //     { "sdk", ad.SdkSource },
        //     { "ad_unit", ad.AdUnitId },
        //     { "network", ad.NetworkName },
        //     { "latency_ms", ad.LatencyMs.ToString() }
        // });
    }

    private static void LogRevenue(string adFormat, AdEventData ad)
    {
        Debug.Log($"[AdMetrics] {ad.SdkSource} | revenue | format={adFormat} | ${ad.Revenue} | net={ad.NetworkName}");

        // TODO: Send revenue event to your analytics backend
        // CRITICAL: Tag with ad.SdkSource so you can compare MaxSdk vs MeticaSdk revenue
    }

    private static void LogError(string eventName, AdErrorData err)
    {
        Debug.LogWarning($"[AdMetrics] {err.SdkSource} | {eventName} | unit={err.AdUnitId} | msg={err.Message}");
    }
}
```

---

## Step 6: Update Game Code to Use the Interface

Replace all direct MaxSdk calls in your game code with calls through `AdServiceRouter.Instance.AdService`.

### Search for these patterns and replace:
```
MaxSdk.LoadInterstitial(     →  AdServiceRouter.Instance.AdService.LoadInterstitial(
MaxSdk.IsInterstitialReady(  →  AdServiceRouter.Instance.AdService.IsInterstitialReady(
MaxSdk.ShowInterstitial(     →  AdServiceRouter.Instance.AdService.ShowInterstitial(
MaxSdk.LoadRewardedAd(       →  AdServiceRouter.Instance.AdService.LoadRewarded(
MaxSdk.IsRewardedAdReady(    →  AdServiceRouter.Instance.AdService.IsRewardedReady(
MaxSdk.ShowRewardedAd(       →  AdServiceRouter.Instance.AdService.ShowRewarded(
MaxSdk.CreateBanner(         →  AdServiceRouter.Instance.AdService.CreateBanner(
MaxSdk.ShowBanner(           →  AdServiceRouter.Instance.AdService.ShowBanner(
MaxSdk.HideBanner(           →  AdServiceRouter.Instance.AdService.HideBanner(
MaxSdk.DestroyBanner(        →  AdServiceRouter.Instance.AdService.DestroyBanner(
```

### Replace callback subscriptions:
Instead of subscribing to `MaxSdkCallbacks.*` events directly, subscribe to `AdServiceRouter.Instance.AdService.*` events.

### Example — before/after for an ad manager class:

**BEFORE:**
```csharp
void Start()
{
    MaxSdkCallbacks.Interstitial.OnAdLoadedEvent += OnAdLoaded;
    MaxSdkCallbacks.Interstitial.OnAdHiddenEvent += OnAdHidden;
    MaxSdk.LoadInterstitial(adUnitId);
}

void OnAdLoaded(string adUnitId, MaxSdkBase.AdInfo adInfo) { ... }
void OnAdHidden(string adUnitId, MaxSdkBase.AdInfo adInfo) { ... }

void ShowAd()
{
    if (MaxSdk.IsInterstitialReady(adUnitId))
        MaxSdk.ShowInterstitial(adUnitId);
}
```

**AFTER:**
```csharp
void Start()
{
    var ads = AdServiceRouter.Instance.AdService;
    ads.OnInterstitialLoaded += OnAdLoaded;
    ads.OnInterstitialHidden += OnAdHidden;
    ads.LoadInterstitial(adUnitId);
}

void OnAdLoaded(AdEventData ad) { ... }
void OnAdHidden(AdEventData ad) { ... }

void ShowAd()
{
    var ads = AdServiceRouter.Instance.AdService;
    if (ads.IsInterstitialReady(adUnitId))
        ads.ShowInterstitial(adUnitId);
}
```

### Wire up initialization and metrics in your main game manager:

```csharp
public class GameManager : MonoBehaviour
{
    void Start()
    {
        var router = AdServiceRouter.Instance;
        var ads = router.AdService;

        // Attach metrics tracking
        AdMetricsTracker.Attach(ads);

        // Set privacy before init
        ads.SetHasUserConsent(true);
        ads.SetDoNotSell(false);

        // Initialize the selected SDK
        ads.Initialize(() =>
        {
            Debug.Log($"[GameManager] {router.ActiveSdk} initialized. Loading ads...");
            ads.LoadInterstitial("YOUR_INTERSTITIAL_ID");
            ads.LoadRewarded("YOUR_REWARDED_ID");
            ads.CreateBanner("YOUR_BANNER_ID", BannerPosition.BottomCenter);
            ads.ShowBanner("YOUR_BANNER_ID");
        });
    }
}
```

---

## Step 7: Verification & Rollback Plan

### 7a. Compile and test both paths
1. Set `useMeticaSdk = false` in AdServiceRouter → build and test → confirm MaxSdk path works
2. Set `useMeticaSdk = true` in AdServiceRouter → build and test → confirm MeticaSdk path works
3. Verify metrics logging shows correct `SdkSource` for each group

### 7b. Deploy with gradual rollout
1. Start with `meticaRolloutPercent = 10` (10% of users get MeticaSdk)
2. Monitor metrics dashboard for 3-7 days
3. Compare: revenue per user, fill rate, ad latency, crash rate
4. If MeticaSdk matches or exceeds baseline → increase to 50%, then 100%
5. If issues detected → set `meticaRolloutPercent = 0` to rollback instantly

### 7c. Key metrics to compare

| Metric | How to Measure | What to Compare |
|--------|---------------|-----------------|
| **Revenue / DAU** | Sum of `ad.Revenue` from revenue callbacks | MeticaSdk group vs MaxSdk group |
| **Fill Rate** | `loaded_count / load_attempt_count` per format | Should be equal or higher |
| **Ad Latency** | `ad.LatencyMs` from load callbacks | Should be similar |
| **Show Rate** | `shown_count / loaded_count` | Should be equal |
| **Error Rate** | `load_failed_count / load_attempt_count` | Should be equal or lower |
| **Smart Floors Impact** | Revenue delta for MeticaSdk TRIAL vs HOLDOUT groups | New MeticaSdk benefit |

### 7d. When A/B test is complete
Once you're confident in MeticaSdk performance:
1. Remove `MaxAdService.cs` and `AdServiceRouter.cs`
2. Remove all MaxSdk direct references (follow `migrate-complete-replacement.md`)
3. Or keep the `IAdService` abstraction if you want flexibility for future SDK changes

### 7e. Runtime test checklist
- [ ] MaxSdk group: all ad formats load, show, and track revenue
- [ ] MeticaSdk group: all ad formats load, show, and track revenue
- [ ] Metrics logged with correct `SdkSource` tag
- [ ] Rollout percentage produces consistent user assignment (same user always in same group)
- [ ] Test on both iOS and Android
- [ ] Setting `meticaRolloutPercent = 0` correctly routes all users to MaxSdk
