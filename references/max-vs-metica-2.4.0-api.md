# MaxSdk vs MeticaSdk - Public API Comparison

| SDK | Version |
|-----|---------|
| **AppLovin MAX Unity Plugin** | 8.6.0 |
| **MeticaSdk Unity Plugin** | 2.4.0 |

> Generated on: 2026-05-05
> MaxSdk source: `AppLovin SDK builds/AppLovin-MAX-Unity-Plugin-8.6.0-Android-13.6.0-iOS-13.6.0/`
> MeticaSdk source: `Metica SDK builds/MeticaSdk-2.4.0/` (extracted from `.unitypackage`)

---

## Summary Findings

### Overall Parity

MeticaSdk 2.4.0 covers the core ad lifecycle (load/show/destroy) for banners, MRECs, interstitials, and rewarded ads with near-complete parity. Gaps remain in App Open Ads, some advanced callback events, and several debugging/segmentation features.

| Category | Parity |
|----------|--------|
| Banners | ✅ Full — all core methods covered including auto-refresh, placement, extra params, width, background color, custom data |
| MRECs | ✅ Full — all core methods covered including auto-refresh, placement, extra params, custom data |
| Interstitials | ✅ Full — load/show/ready/extra params covered, plus new `MeticaAdConfig` bid floor support |
| Rewarded Ads | ✅ Full — load/show/ready/extra params covered, plus new `MeticaAdConfig` bid floor support |
| Callbacks / Events | ⚠️ Partial — core callbacks (load/fail/show/hide/click/revenue) covered; missing expanded/collapsed, display failed, expired ad reloaded, ad review creative ID events |
| Privacy / Consent | ⚠️ Partial — `SetHasUserConsent`/`SetDoNotSell` covered; read-back (`HasUserConsent`, `IsDoNotSell`, consent status checks) available via `MeticaSdk.Ads.Max`; missing `GetSdkConfiguration()` |
| App Open Ads | ❌ Not supported — no MeticaSdk equivalent for the entire ad format |
| Debugging / Testing | ⚠️ Partial — `ShowMediationDebugger` available via `MeticaSdk.Ads.Max`; missing `ShowCreativeDebugger`, `SetCreativeDebuggerEnabled`, `SetTestDeviceAdvertisingIdentifiers`, `DisableStubAds` |
| Segmentation | ❌ Not supported — `MaxSegmentCollection` / `SetSegmentCollection` have no equivalent |
| Ad Info / Error data richness | ⚠️ Partial — `MeticaAd` covers core fields; missing waterfall info, DSP name, revenue precision, network placement; `MeticaAdError` is simplified (message only, no error code enum) |

### Key API Pattern Differences

- **Namespace shift**: All ad methods move from `MaxSdk.*` static calls to `MeticaSdk.Ads.*` instance methods (e.g., `MaxSdk.LoadInterstitial(id)` → `MeticaSdk.Ads.LoadInterstitial(id)`)
- **MAX-specific functions via sub-accessor**: Privacy read-back, muted state, debugger, and CMP flow are accessed via `MeticaSdk.Ads.Max.*` (the `MeticaApplovinFunctions` interface)
- **Initialization**: MaxSdk uses `MaxSdk.InitializeSdk(string[])` with a callback event `MaxSdkCallbacks.OnSdkInitializedEvent`. MeticaSdk uses `MeticaSdk.Initialize(MeticaInitConfig, MeticaMediationInfo?, Action<MeticaInitResponse>?)` with an inline callback or async variant
- **Callback signatures**: MaxSdk callbacks pass `(string adUnitId, AdInfo)` tuples. MeticaSdk callbacks pass a single `MeticaAd` object (which contains the `adUnitId`). Error callbacks pass `MeticaAdError` instead of `(string adUnitId, ErrorInfo)`
- **Event naming**: `OnAdLoadedEvent` → `OnAdLoadSuccess`; `OnAdDisplayedEvent` → `OnAdShowSuccess`; `OnAdHiddenEvent` → `OnAdHidden`; `OnAdReceivedRewardEvent` → `OnAdRewarded`
- **Casing**: Method names use different casing — `CreateMRec` → `CreateMrec`, `ShowMRec` → `ShowMrec`
- **Ad config at load time**: MeticaSdk adds `LoadInterstitial(adUnitId, MeticaAdConfig?)` and `LoadRewarded(adUnitId, MeticaAdConfig?)` overloads supporting dynamic bid floors — a feature MaxSdk lacks
- **Banner background color**: MaxSdk accepts `UnityEngine.Color`; MeticaSdk accepts a hex color string
- **JSON extra params**: MeticaSdk adds `SetBannerLocalExtraParameterJson` and `SetMrecLocalExtraParameterJson` for passing JSON strings directly

### Critical Gaps for Migration

1. **App Open Ads** — MaxSdk provides `LoadAppOpenAd`, `IsAppOpenAdReady`, `ShowAppOpenAd`, plus full callback support. Games using app open ads will need a completely separate ad loading strategy or must keep MaxSdk for this format.
2. **Banner/MREC Expanded & Collapsed callbacks** — MaxSdk fires `OnAdExpandedEvent` and `OnAdCollapsedEvent` for both banners and MRECs. Games relying on these to pause/resume gameplay or adjust UI layout will need alternative detection.
3. **Display Failed callbacks** — MaxSdk provides `OnAdDisplayFailedEvent` for interstitials, rewarded, and app open ads (with both `ErrorInfo` and `AdInfo`). MeticaSdk's `OnAdShowFailed` passes `(MeticaAd, MeticaAdError)` which covers interstitials and rewarded but with less error detail (no error code enum, no mediated network error info).
4. **Waterfall and detailed error data** — `MaxSdkBase.AdInfo.WaterfallInfo`, `ErrorInfo.AdLoadFailureInfo`, `ErrorInfo.MediatedNetworkErrorCode/Message`, and `AdInfo.RevenuePrecision` have no MeticaSdk equivalent. Games that log detailed waterfall analytics or troubleshoot mediation issues lose visibility.
5. **Segmentation (`MaxSegmentCollection`)** — Games using AppLovin's segment targeting have no MeticaSdk equivalent and must remove or replace this targeting approach.

---

## 1. MaxSdk Functions That Can Be Replaced With MeticaSdk

### Initialization

| MaxSdk | MeticaSdk | Notes |
|--------|-----------|-------|
| `MaxSdk.InitializeSdk(string[] adUnitIds = null)` | `MeticaSdk.Initialize(MeticaInitConfig, MeticaMediationInfo?, Action<MeticaInitResponse>?)` | MeticaSdk requires explicit config object with ApiKey/AppId/UserId; supports inline callback instead of static event; also has `InitializeAsync` returning `Task<MeticaInitResponse>` |
| `MaxSdk.IsInitialized()` | `MeticaSdk.Ads.Max.IsSuccessfullyInitialized()` | Available via the Max sub-accessor |
| `MaxSdk.Version` | `MeticaSdk.Version` | Direct equivalent |
| `MaxSdk.SetUserId(string)` | `MeticaInitConfig.UserId` | Set at initialization time via config object |
| `MaxSdkCallbacks.OnSdkInitializedEvent` | `Action<MeticaInitResponse>` callback parameter | Inline callback or async pattern replaces static event |

### Privacy

| MaxSdk | MeticaSdk | Notes |
|--------|-----------|-------|
| `MaxSdk.SetHasUserConsent(bool)` | `MeticaSdk.Ads.SetHasUserConsent(bool)` | Direct equivalent |
| `MaxSdk.SetDoNotSell(bool)` | `MeticaSdk.Ads.SetDoNotSell(bool)` | Direct equivalent |
| `MaxSdk.HasUserConsent()` | `MeticaSdk.Ads.Max.HasUserConsent()` | Available via Max sub-accessor |
| `MaxSdk.IsUserConsentSet()` | `MeticaSdk.Ads.Max.IsUserConsentSet()` | Available via Max sub-accessor |
| `MaxSdk.CmpService.ShowCmpForExistingUser(Action<MaxCmpError>)` | `MeticaSdk.Ads.Max.ShowCmpForExistingUser()` | MeticaSdk version takes no callback parameter |

### Banners

| MaxSdk | MeticaSdk | Notes |
|--------|-----------|-------|
| `MaxSdk.CreateBanner(string, AdViewConfiguration)` | `MeticaSdk.Ads.CreateBanner(string, MeticaAdViewConfiguration)` | Config class renamed; `MeticaAdViewConfiguration` lacks `IsAdaptive` property |
| `MaxSdk.LoadBanner(string)` | `MeticaSdk.Ads.LoadBanner(string)` | Direct equivalent |
| `MaxSdk.ShowBanner(string)` | `MeticaSdk.Ads.ShowBanner(string)` | Direct equivalent |
| `MaxSdk.HideBanner(string)` | `MeticaSdk.Ads.HideBanner(string)` | Direct equivalent |
| `MaxSdk.DestroyBanner(string)` | `MeticaSdk.Ads.DestroyBanner(string)` | Direct equivalent |
| `MaxSdk.SetBannerPlacement(string, string)` | `MeticaSdk.Ads.SetBannerPlacement(string, string?)` | Direct equivalent |
| `MaxSdk.StartBannerAutoRefresh(string)` | `MeticaSdk.Ads.StartBannerAutoRefresh(string)` | Direct equivalent |
| `MaxSdk.StopBannerAutoRefresh(string)` | `MeticaSdk.Ads.StopBannerAutoRefresh(string)` | Direct equivalent |
| `MaxSdk.SetBannerBackgroundColor(string, Color)` | `MeticaSdk.Ads.SetBannerBackgroundColor(string, string)` | MeticaSdk uses hex color string instead of `UnityEngine.Color` |
| `MaxSdk.SetBannerExtraParameter(string, string, string)` | `MeticaSdk.Ads.SetBannerExtraParameter(string, string, string?)` | Direct equivalent |
| `MaxSdk.SetBannerLocalExtraParameter(string, string, object)` | `MeticaSdk.Ads.SetBannerLocalExtraParameter(string, string, object?)` | Direct equivalent; MeticaSdk also adds `SetBannerLocalExtraParameterJson` |
| `MaxSdk.SetBannerCustomData(string, string)` | `MeticaSdk.Ads.SetBannerCustomData(string, string?)` | Direct equivalent |
| `MaxSdk.SetBannerWidth(string, float)` | `MeticaSdk.Ads.SetBannerWidth(string, float)` | Direct equivalent |

### MRECs

| MaxSdk | MeticaSdk | Notes |
|--------|-----------|-------|
| `MaxSdk.CreateMRec(string, AdViewConfiguration)` | `MeticaSdk.Ads.CreateMrec(string, MeticaAdViewConfiguration)` | Casing: `MRec` → `Mrec`; config class renamed |
| `MaxSdk.LoadMRec(string)` | `MeticaSdk.Ads.LoadMrec(string)` | Casing difference |
| `MaxSdk.ShowMRec(string)` | `MeticaSdk.Ads.ShowMrec(string)` | Casing difference |
| `MaxSdk.HideMRec(string)` | `MeticaSdk.Ads.HideMrec(string)` | Casing difference |
| `MaxSdk.DestroyMRec(string)` | `MeticaSdk.Ads.DestroyMrec(string)` | Casing difference |
| `MaxSdk.SetMRecPlacement(string, string)` | `MeticaSdk.Ads.SetMrecPlacement(string, string?)` | Casing difference |
| `MaxSdk.StartMRecAutoRefresh(string)` | `MeticaSdk.Ads.StartMrecAutoRefresh(string)` | Casing difference |
| `MaxSdk.StopMRecAutoRefresh(string)` | `MeticaSdk.Ads.StopMrecAutoRefresh(string)` | Casing difference |
| `MaxSdk.SetMRecExtraParameter(string, string, string)` | `MeticaSdk.Ads.SetMrecExtraParameter(string, string, string?)` | Casing difference |
| `MaxSdk.SetMRecLocalExtraParameter(string, string, object)` | `MeticaSdk.Ads.SetMrecLocalExtraParameter(string, string, object?)` | Casing difference; MeticaSdk also adds `SetMrecLocalExtraParameterJson` |
| `MaxSdk.SetMRecCustomData(string, string)` | `MeticaSdk.Ads.SetMrecCustomData(string, string?)` | Casing difference |

### Interstitials

| MaxSdk | MeticaSdk | Notes |
|--------|-----------|-------|
| `MaxSdk.LoadInterstitial(string)` | `MeticaSdk.Ads.LoadInterstitial(string)` | Direct equivalent; MeticaSdk also offers `LoadInterstitial(string, MeticaAdConfig?)` with bid floor support |
| `MaxSdk.IsInterstitialReady(string)` | `MeticaSdk.Ads.IsInterstitialReady(string)` | Direct equivalent |
| `MaxSdk.ShowInterstitial(string, string?, string?)` | `MeticaSdk.Ads.ShowInterstitial(string, string?, string?)` | Direct equivalent |
| `MaxSdk.SetInterstitialExtraParameter(string, string, string)` | `MeticaSdk.Ads.SetInterstitialExtraParameter(string, string, string?)` | Direct equivalent |
| `MaxSdk.SetInterstitialLocalExtraParameter(string, string, object)` | `MeticaSdk.Ads.SetInterstitialLocalExtraParameter(string, string, object?)` | Direct equivalent |

### Rewarded Ads

| MaxSdk | MeticaSdk | Notes |
|--------|-----------|-------|
| `MaxSdk.LoadRewardedAd(string)` | `MeticaSdk.Ads.LoadRewarded(string)` | Renamed: `LoadRewardedAd` → `LoadRewarded`; MeticaSdk also offers `LoadRewarded(string, MeticaAdConfig?)` with bid floor support |
| `MaxSdk.IsRewardedAdReady(string)` | `MeticaSdk.Ads.IsRewardedReady(string)` | Renamed: `IsRewardedAdReady` → `IsRewardedReady` |
| `MaxSdk.ShowRewardedAd(string, string?, string?)` | `MeticaSdk.Ads.ShowRewarded(string, string?, string?)` | Renamed: `ShowRewardedAd` → `ShowRewarded` |
| `MaxSdk.SetRewardedAdExtraParameter(string, string, string)` | `MeticaSdk.Ads.SetRewardedAdExtraParameter(string, string, string?)` | Direct equivalent |
| `MaxSdk.SetRewardedAdLocalExtraParameter(string, string, object)` | `MeticaSdk.Ads.SetRewardedAdLocalExtraParameter(string, string, object?)` | Direct equivalent |

### Callbacks / Events

| MaxSdk | MeticaSdk | Notes |
|--------|-----------|-------|
| **Banner Events** | | |
| `MaxSdkCallbacks.Banner.OnAdLoadedEvent` `Action<string, AdInfo>` | `MeticaAdsCallbacks.Banner.OnAdLoadSuccess` `Action<MeticaAd>` | Renamed; single `MeticaAd` param instead of `(string, AdInfo)` tuple |
| `MaxSdkCallbacks.Banner.OnAdLoadFailedEvent` `Action<string, ErrorInfo>` | `MeticaAdsCallbacks.Banner.OnAdLoadFailed` `Action<MeticaAdError>` | Renamed; `MeticaAdError` contains `adUnitId` |
| `MaxSdkCallbacks.Banner.OnAdClickedEvent` `Action<string, AdInfo>` | `MeticaAdsCallbacks.Banner.OnAdClicked` `Action<MeticaAd>` | Renamed |
| `MaxSdkCallbacks.Banner.OnAdRevenuePaidEvent` `Action<string, AdInfo>` | `MeticaAdsCallbacks.Banner.OnAdRevenuePaid` `Action<MeticaAd>` | Renamed |
| **MREC Events** | | |
| `MaxSdkCallbacks.MRec.OnAdLoadedEvent` `Action<string, AdInfo>` | `MeticaAdsCallbacks.Mrec.OnAdLoadSuccess` `Action<MeticaAd>` | Renamed; casing `MRec` → `Mrec` |
| `MaxSdkCallbacks.MRec.OnAdLoadFailedEvent` `Action<string, ErrorInfo>` | `MeticaAdsCallbacks.Mrec.OnAdLoadFailed` `Action<MeticaAdError>` | Renamed |
| `MaxSdkCallbacks.MRec.OnAdClickedEvent` `Action<string, AdInfo>` | `MeticaAdsCallbacks.Mrec.OnAdClicked` `Action<MeticaAd>` | Renamed |
| `MaxSdkCallbacks.MRec.OnAdRevenuePaidEvent` `Action<string, AdInfo>` | `MeticaAdsCallbacks.Mrec.OnAdRevenuePaid` `Action<MeticaAd>` | Renamed |
| **Interstitial Events** | | |
| `MaxSdkCallbacks.Interstitial.OnAdLoadedEvent` `Action<string, AdInfo>` | `MeticaAdsCallbacks.Interstitial.OnAdLoadSuccess` `Action<MeticaAd>` | Renamed |
| `MaxSdkCallbacks.Interstitial.OnAdLoadFailedEvent` `Action<string, ErrorInfo>` | `MeticaAdsCallbacks.Interstitial.OnAdLoadFailed` `Action<MeticaAdError>` | Renamed |
| `MaxSdkCallbacks.Interstitial.OnAdDisplayedEvent` `Action<string, AdInfo>` | `MeticaAdsCallbacks.Interstitial.OnAdShowSuccess` `Action<MeticaAd>` | Renamed: Displayed → ShowSuccess |
| `MaxSdkCallbacks.Interstitial.OnAdDisplayFailedEvent` `Action<string, ErrorInfo, AdInfo>` | `MeticaAdsCallbacks.Interstitial.OnAdShowFailed` `Action<MeticaAd, MeticaAdError>` | Renamed; param order reversed (ad first, error second) |
| `MaxSdkCallbacks.Interstitial.OnAdHiddenEvent` `Action<string, AdInfo>` | `MeticaAdsCallbacks.Interstitial.OnAdHidden` `Action<MeticaAd>` | Renamed |
| `MaxSdkCallbacks.Interstitial.OnAdClickedEvent` `Action<string, AdInfo>` | `MeticaAdsCallbacks.Interstitial.OnAdClicked` `Action<MeticaAd>` | Renamed |
| `MaxSdkCallbacks.Interstitial.OnAdRevenuePaidEvent` `Action<string, AdInfo>` | `MeticaAdsCallbacks.Interstitial.OnAdRevenuePaid` `Action<MeticaAd>` | Renamed |
| **Rewarded Events** | | |
| `MaxSdkCallbacks.Rewarded.OnAdLoadedEvent` `Action<string, AdInfo>` | `MeticaAdsCallbacks.Rewarded.OnAdLoadSuccess` `Action<MeticaAd>` | Renamed |
| `MaxSdkCallbacks.Rewarded.OnAdLoadFailedEvent` `Action<string, ErrorInfo>` | `MeticaAdsCallbacks.Rewarded.OnAdLoadFailed` `Action<MeticaAdError>` | Renamed |
| `MaxSdkCallbacks.Rewarded.OnAdDisplayedEvent` `Action<string, AdInfo>` | `MeticaAdsCallbacks.Rewarded.OnAdShowSuccess` `Action<MeticaAd>` | Renamed: Displayed → ShowSuccess |
| `MaxSdkCallbacks.Rewarded.OnAdDisplayFailedEvent` `Action<string, ErrorInfo, AdInfo>` | `MeticaAdsCallbacks.Rewarded.OnAdShowFailed` `Action<MeticaAd, MeticaAdError>` | Renamed; param order reversed |
| `MaxSdkCallbacks.Rewarded.OnAdHiddenEvent` `Action<string, AdInfo>` | `MeticaAdsCallbacks.Rewarded.OnAdHidden` `Action<MeticaAd>` | Renamed |
| `MaxSdkCallbacks.Rewarded.OnAdClickedEvent` `Action<string, AdInfo>` | `MeticaAdsCallbacks.Rewarded.OnAdClicked` `Action<MeticaAd>` | Renamed |
| `MaxSdkCallbacks.Rewarded.OnAdRevenuePaidEvent` `Action<string, AdInfo>` | `MeticaAdsCallbacks.Rewarded.OnAdRevenuePaid` `Action<MeticaAd>` | Renamed |
| `MaxSdkCallbacks.Rewarded.OnAdReceivedRewardEvent` `Action<string, Reward, AdInfo>` | `MeticaAdsCallbacks.Rewarded.OnAdRewarded` `Action<MeticaAd>` | Simplified: no separate `Reward` struct with label/amount |

### Settings / Configuration

| MaxSdk | MeticaSdk | Notes |
|--------|-----------|-------|
| `MaxSdk.SetMuted(bool)` | `MeticaSdk.Ads.Max.SetMuted(bool)` | Available via Max sub-accessor |
| `MaxSdk.IsMuted()` | `MeticaSdk.Ads.Max.IsMuted()` | Available via Max sub-accessor |
| `MaxSdk.SetExtraParameter(string, string)` | `MeticaSdk.Ads.Max.SetExtraParameter(string, string?)` | Available via Max sub-accessor |
| `MaxSdk.SetVerboseLogging(bool)` | `MeticaSdk.SetLogEnabled(bool)` | Different name; MeticaSdk controls its own logging level |
| `MaxSdk.ShowMediationDebugger()` | `MeticaSdk.Ads.Max.ShowMediationDebugger()` | Available via Max sub-accessor |

### Ad Info Models

| MaxSdk (`MaxSdkBase.AdInfo`) | MeticaSdk (`MeticaAd`) | Notes |
|------------------------------|------------------------|-------|
| `AdUnitIdentifier` (string) | `adUnitId` (string) | Renamed; field vs property |
| `Revenue` (double) | `revenue` (double?) | Nullable in MeticaSdk |
| `NetworkName` (string) | `networkName` (string?) | Nullable in MeticaSdk |
| `Placement` (string) | `placementTag` (string?) | Renamed |
| `AdFormat` (string) | `adFormat` (string?) | Nullable in MeticaSdk |
| `CreativeIdentifier` (string) | `creativeId` (string?) | Renamed, nullable |
| `LatencyMillis` (long) | `latency` (long?) | Renamed, nullable |
| `NetworkPlacement` (string) | — | Not available |
| `RevenuePrecision` (string) | — | Not available |
| `WaterfallInfo` (WaterfallInfo) | — | Not available |
| `DspName` (string) | — | Not available |

### Error Models

| MaxSdk (`MaxSdkBase.ErrorInfo`) | MeticaSdk (`MeticaAdError`) | Notes |
|---------------------------------|-----------------------------|-------|
| `Code` (ErrorCode enum) | — | No error code in MeticaSdk |
| `Message` (string) | `message` (string) | Direct equivalent |
| — | `adUnitId` (string?) | MeticaSdk includes ad unit ID in error |
| `MediatedNetworkErrorCode` (int) | — | Not available |
| `MediatedNetworkErrorMessage` (string) | — | Not available |
| `AdLoadFailureInfo` (string) | — | Not available |
| `WaterfallInfo` (WaterfallInfo) | — | Not available |
| `LatencyMillis` (long) | — | Not available |

### Position Enums

| MaxSdk (`AdViewPosition`) | MeticaSdk (`MeticaAdViewPosition`) | Notes |
|---------------------------|-------------------------------------|-------|
| `TopLeft` | `TopLeft` | Identical |
| `TopCenter` | `TopCenter` | Identical |
| `TopRight` | `TopRight` | Identical |
| `Centered` | `Centered` | Identical |
| `CenterLeft` | `CenterLeft` | Identical |
| `CenterRight` | `CenterRight` | Identical |
| `BottomLeft` | `BottomLeft` | Identical |
| `BottomCenter` | `BottomCenter` | Identical |
| `BottomRight` | `BottomRight` | Identical |

### Additional MeticaSdk-Only Features

| MeticaSdk Feature | Details |
|-------------------|---------|
| `MeticaSdk.InitializeAnalytics(MeticaInitConfig)` | Analytics-only initialization (no ads) |
| `MeticaSdk.InitializeAsync(MeticaInitConfig, MeticaMediationInfo?)` | Async/await initialization |
| `MeticaSdk.Ads.LoadInterstitial(string, MeticaAdConfig?)` | Load with dynamic bid floor |
| `MeticaSdk.Ads.LoadRewarded(string, MeticaAdConfig?)` | Load with dynamic bid floor |
| `MeticaSdk.Ads.Max.GetAdaptiveBannerHeight(double)` | Get adaptive banner height for width |
| `MeticaSdk.Ads.Max.IsTablet()` | Device form factor check |
| `MeticaSdk.Ads.Max.GetConsentFlowUserGeography()` | Get user geography for consent |
| `MeticaSdk.Ads.Max.CountryCode()` | Get country code from MAX |
| `MeticaSdk.Ads.Max.ConsentDialogState()` | Get consent dialog state |
| `MeticaSdk.Offers.*` | Offer management (not in MaxSdk) |
| `MeticaSdk.SmartConfig.*` | Remote config (not in MaxSdk) |
| `MeticaSdk.Events.*` | Event tracking/analytics (not in MaxSdk) |
| `MeticaInitResponse.SmartFloors` | Smart floor pricing data on init |
| `MeticaAdConfig.OverrideBidFloor` | Per-load bid floor override |

---

## 2. MaxSdk Functionality Missing From MeticaSdk

### Ad Formats

| Missing Feature | MaxSdk API | Details |
|-----------------|-----------|---------|
| **App Open Ads** | `LoadAppOpenAd(string)`, `IsAppOpenAdReady(string)`, `ShowAppOpenAd(string, string?, string?)`, `SetAppOpenAdExtraParameter(string, string, string)`, `SetAppOpenAdLocalExtraParameter(string, string, object)` | Entire ad format not supported; includes full callback suite (`MaxSdkCallbacks.AppOpen.*`) |

### Banner Features

| Missing Feature | MaxSdk API | Details |
|-----------------|-----------|---------|
| **Update banner position** | `UpdateBannerPosition(string, AdViewPosition)`, `UpdateBannerPosition(string, float, float)` | Cannot reposition after creation; must destroy and recreate |
| **Get banner layout** | `GetBannerLayout(string)` → `Rect` | No way to query the banner's on-screen position/size |
| **Adaptive banner flag** | `AdViewConfiguration.IsAdaptive` | `MeticaAdViewConfiguration` has no `IsAdaptive` property |

### MREC Features

| Missing Feature | MaxSdk API | Details |
|-----------------|-----------|---------|
| **Update MREC position** | `UpdateMRecPosition(string, AdViewPosition)`, `UpdateMRecPosition(string, float, float)` | Cannot reposition after creation; must destroy and recreate |
| **Get MREC layout** | `GetMRecLayout(string)` → `Rect` | No way to query the MREC's on-screen position/size |

### Interstitial Features

| Missing Feature | MaxSdk API | Details |
|-----------------|-----------|---------|
| — | — | Core functionality fully covered |

### Rewarded Ad Features

| Missing Feature | MaxSdk API | Details |
|-----------------|-----------|---------|
| **Reward details** | `MaxSdkBase.Reward` struct with `Label` and `Amount` | `MeticaAdsCallbacks.Rewarded.OnAdRewarded` passes only `MeticaAd`; no reward label/amount info |

### Privacy / Consent

| Missing Feature | MaxSdk API | Details |
|-----------------|-----------|---------|
| **Do Not Sell read-back** | `MaxSdk.IsDoNotSell()`, `MaxSdk.IsDoNotSellSet()` | No MeticaSdk equivalent to check do-not-sell state |
| **SDK configuration object** | `MaxSdk.GetSdkConfiguration()` → `SdkConfiguration` | No single configuration object; individual properties available via `MeticaSdk.Ads.Max` |
| **CMP completion callback** | `MaxCmpService.ShowCmpForExistingUser(Action<MaxCmpError>)` | `MeticaSdk.Ads.Max.ShowCmpForExistingUser()` takes no callback |
| **Has Supported CMP** | `MaxCmpService.HasSupportedCmp` | No MeticaSdk equivalent |

### Debugging / Testing

| Missing Feature | MaxSdk API | Details |
|-----------------|-----------|---------|
| **Creative Debugger** | `MaxSdk.ShowCreativeDebugger()` | Not available |
| **Creative Debugger toggle** | `MaxSdk.SetCreativeDebuggerEnabled(bool)` | Not available |
| **Test device IDs** | `MaxSdk.SetTestDeviceAdvertisingIdentifiers(string[])` | Not available |
| **Disable stub ads** | `MaxSdk.DisableStubAds()` | Not available (editor testing feature) |
| **Verbose logging check** | `MaxSdk.IsVerboseLoggingEnabled()` | No read-back for log state |

### SDK Information

| Missing Feature | MaxSdk API | Details |
|-----------------|-----------|---------|
| **Available mediated networks** | `MaxSdk.GetAvailableMediatedNetworks()` → `List<MediatedNetworkInfo>` | No equivalent to list configured networks and their init status |
| **Ad value lookup** | `MaxSdk.GetAdValue(string, string)` | No arbitrary ad value retrieval |
| **Safe area insets** | `MaxSdk.GetSafeAreaInsets()` → `SafeAreaInsets` | Not available |
| **Main thread event control** | `MaxSdk.InvokeEventsOnUnityMainThread` | No all-events equivalent; on SDK ≥ 2.4.2 its value selects `MeticaAds.RevenueCallbackDelivery` for revenue callbacks (`true` → `UnityMainThread`, default → `NativeThread`) |

### Settings

| Missing Feature | MaxSdk API | Details |
|-----------------|-----------|---------|
| **Exception handler toggle** | `MaxSdk.SetExceptionHandlerEnabled(bool)` | Not available |

### Event Tracking

| Missing Feature | MaxSdk API | Details |
|-----------------|-----------|---------|
| **AppLovin event tracking** | `MaxSdk.TrackEvent(string, IDictionary<string, string>)` | Not available (MeticaSdk has its own event system via `MeticaSdk.Events.*`) |

### Segmentation

| Missing Feature | MaxSdk API | Details |
|-----------------|-----------|---------|
| **Segment collection** | `MaxSdk.SetSegmentCollection(MaxSegmentCollection)` | No equivalent; `MaxSegmentCollection`, `MaxSegment` classes have no MeticaSdk counterpart |

### Callback Differences

| Missing Feature | MaxSdk API | Details |
|-----------------|-----------|---------|
| **Banner expanded/collapsed** | `MaxSdkCallbacks.Banner.OnAdExpandedEvent`, `OnAdCollapsedEvent` | Not available |
| **MREC expanded/collapsed** | `MaxSdkCallbacks.MRec.OnAdExpandedEvent`, `OnAdCollapsedEvent` | Not available |
| **Expired ad reloaded** | `MaxSdkCallbacks.Interstitial.OnExpiredAdReloadedEvent`, `MaxSdkCallbacks.Rewarded.OnExpiredAdReloadedEvent`, `MaxSdkCallbacks.AppOpen.OnExpiredAdReloadedEvent` | Not available |
| **Ad Review Creative ID** | `MaxSdkCallbacks.*.OnAdReviewCreativeIdGeneratedEvent` (all formats) | Not available |
| **Application state changed** | `MaxSdkCallbacks.OnApplicationStateChangedEvent` | Not available |

### Data Models

| Missing Feature | MaxSdk Type | Details |
|-----------------|-------------|---------|
| **Waterfall info** | `WaterfallInfo` (Name, TestName, NetworkResponses, LatencyMillis) | Not available in `MeticaAd` |
| **Network response info** | `NetworkResponseInfo` (AdLoadState, MediatedNetwork, Credentials, IsBidding, LatencyMillis, Error) | Not available |
| **Mediated network info** | `MediatedNetworkInfo` (Name, AdapterClassName, AdapterVersion, SdkVersion, InitializationStatus) | Not available |
| **Detailed error codes** | `MaxSdkBase.ErrorCode` enum (NoFill, AdLoadFailed, AdDisplayFailed, NetworkError, etc.) | `MeticaAdError` has message string only |
| **Revenue precision** | `AdInfo.RevenuePrecision` | Not available |
| **DSP name** | `AdInfo.DspName` | Not available |
| **Network placement** | `AdInfo.NetworkPlacement` | Not available |
| **CMP error model** | `MaxCmpError` (Code, Message, CmpCode, CmpMessage) | Not available |
| **SDK configuration model** | `SdkConfiguration` (IsSuccessfullyInitialized, CountryCode, AppTrackingStatus, IsTestModeEnabled, ConsentFlowUserGeography) | Individual properties available via `MeticaSdk.Ads.Max` but no unified model |
