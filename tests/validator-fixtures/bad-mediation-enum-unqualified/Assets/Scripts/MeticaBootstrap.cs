using UnityEngine;

// Otherwise-valid integration, but the mediation enum is written with the bare
// (uncompilable) form from the docs page: MeticaMediationType.MAX. It is a
// NESTED enum and must be qualified MeticaMediationInfo.MeticaMediationType.MAX.
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

        MeticaSdk.Initialize(new MeticaInitConfig("API_KEY", "APP_ID", "u-abc-123"),
            new MeticaMediationInfo(MeticaMediationType.MAX, "max-key-99"), response => {});

        MeticaSdk.Ads.LoadInterstitial("inter_main");
    }

    void ShowAd()
    {
        if (MeticaSdk.Ads.IsInterstitialReady("inter_main"))
            MeticaSdk.Ads.ShowInterstitial("inter_main");
    }
}
