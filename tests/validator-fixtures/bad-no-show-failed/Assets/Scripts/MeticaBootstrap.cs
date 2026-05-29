using UnityEngine;

// Fixture: interstitial integration that subscribes the canonical reload-on-hidden
// loop but NOT OnAdShowFailed. Without OnAdShowFailed, a single show-failure
// (network blip, ad expired, mediated SDK failure) stalls the loop — OnAdHidden
// does not fire, so the next ad is never loaded.

public class MeticaBootstrap : MonoBehaviour
{
    void Start()
    {
        MeticaAdsCallbacks.Interstitial.OnAdLoadSuccess += ad => Debug.Log("loaded");
        MeticaAdsCallbacks.Interstitial.OnAdLoadFailed += err => Debug.Log("failed");
        MeticaAdsCallbacks.Interstitial.OnAdHidden += ad => MeticaSdk.Ads.LoadInterstitial("inter_main");
        // BUG: OnAdShowFailed not subscribed — the reload loop stalls on show-failure.

        MeticaSdk.Ads.SetHasUserConsent(true);
        MeticaSdk.Ads.SetDoNotSell(false);

        MeticaSdk.Initialize(new MeticaInitConfig("real-api", "real-app", "u-abc-123"), null, response => {});

        MeticaSdk.Ads.LoadInterstitial("inter_main");
    }

    void ShowAd()
    {
        if (MeticaSdk.Ads.IsInterstitialReady("inter_main"))
            MeticaSdk.Ads.ShowInterstitial("inter_main");
    }
}
