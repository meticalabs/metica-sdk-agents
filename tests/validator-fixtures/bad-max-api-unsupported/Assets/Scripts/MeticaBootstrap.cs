using UnityEngine;

// Metica integration that still references AppLovin's App Open Ads — a feature
// MeticaSdk 2.4.0 does not support at all. Validator must flag as unsupported.
public class MeticaBootstrap : MonoBehaviour
{
    void Start()
    {
        MeticaAdsCallbacks.Interstitial.OnAdLoadSuccess += ad => Debug.Log("loaded");
        MeticaAdsCallbacks.Interstitial.OnAdLoadFailed += err => Debug.Log("failed");
        MeticaAdsCallbacks.Interstitial.OnAdRevenuePaid += ad => Debug.Log("revenue");
        MeticaAdsCallbacks.Interstitial.OnAdHidden += ad => MeticaSdk.Ads.LoadInterstitial("inter_main");
        MeticaAdsCallbacks.Interstitial.OnAdShowFailed += (ad, err) => MeticaSdk.Ads.LoadInterstitial("inter_main");

        MeticaSdk.Ads.SetHasUserConsent(true);
        MeticaSdk.Ads.SetDoNotSell(false);

        MeticaSdk.Initialize(new MeticaInitConfig("API_KEY", "APP_ID", "u-abc-123"), null, response => {});

        MeticaSdk.Ads.LoadInterstitial("inter_main");

        // BUG: App Open Ads are not in MeticaSdk's surface — this call has no
        // Metica counterpart. The validator's max_api_unsupported rule must
        // FAIL on this line.
        MaxSdk.LoadAppOpenAd("appopen_main");
    }

    void ShowAd()
    {
        if (MeticaSdk.Ads.IsInterstitialReady("inter_main"))
            MeticaSdk.Ads.ShowInterstitial("inter_main");
    }
}
