# Metica Unity SDK 2.4.0 — Canonical API Surface

> TODO: distil from https://docs.metica.com/api/unity-sdk/unity-sdk-2
> Used by the validator to know what to grep for, and by the integrator as a code-generation reference.

## Initialization

```csharp
MeticaSdk.Initialize(config, mediationInfo, initResponse => { ... });
```

- `MeticaInitConfig(apiKey, appId, userId?)`
- `MeticaMediationInfo(MeticaMediationType.MAX, maxSdkKey)`

## Privacy (must precede Initialize)

```csharp
MeticaSdk.Ads.SetHasUserConsent(bool);
MeticaSdk.Ads.SetDoNotSell(bool);
```

## Banner

```csharp
MeticaSdk.Ads.CreateBanner(adUnitId, MeticaAdViewConfiguration(position));
MeticaSdk.Ads.LoadBanner(adUnitId);
MeticaSdk.Ads.ShowBanner(adUnitId);
MeticaSdk.Ads.HideBanner(adUnitId);
MeticaSdk.Ads.DestroyBanner(adUnitId);
```

## Interstitial

```csharp
MeticaSdk.Ads.LoadInterstitial(adUnitId);
MeticaSdk.Ads.IsInterstitialReady(adUnitId);
MeticaSdk.Ads.ShowInterstitial(adUnitId, placement?, customData?);
```

## Rewarded

```csharp
MeticaSdk.Ads.LoadRewarded(adUnitId);
MeticaSdk.Ads.IsRewardedReady(adUnitId);
MeticaSdk.Ads.ShowRewarded(adUnitId, placement?, customData?);
```

## Callbacks

```csharp
MeticaAdsCallbacks.Banner.OnAdLoadSuccess         += ad => ...;
MeticaAdsCallbacks.Banner.OnAdLoadFailed          += err => ...;
MeticaAdsCallbacks.Banner.OnAdRevenuePaid         += ad => ...;

MeticaAdsCallbacks.Interstitial.OnAdLoadSuccess   += ad => ...;
MeticaAdsCallbacks.Interstitial.OnAdLoadFailed    += err => ...;
MeticaAdsCallbacks.Interstitial.OnAdShowSuccess   += ad => ...;
MeticaAdsCallbacks.Interstitial.OnAdHidden        += ad => ...;
MeticaAdsCallbacks.Interstitial.OnAdRevenuePaid   += ad => ...;

MeticaAdsCallbacks.Rewarded.OnAdLoadSuccess       += ad => ...;
MeticaAdsCallbacks.Rewarded.OnAdLoadFailed        += err => ...;
MeticaAdsCallbacks.Rewarded.OnAdShowSuccess       += ad => ...;
MeticaAdsCallbacks.Rewarded.OnAdHidden            += ad => ...;
MeticaAdsCallbacks.Rewarded.OnAdRewarded          += ad => ...;
MeticaAdsCallbacks.Rewarded.OnAdRevenuePaid       += ad => ...;
```

## Event payloads

- `MeticaAd { adUnitId, networkName, revenue?, adFormat, placementTag, latency? }`
- `MeticaAdError { adUnitId, message }`

## Init response

- `initResponse.SmartFloors.UserGroup`
- `initResponse.SmartFloors.IsForcedHoldout`
