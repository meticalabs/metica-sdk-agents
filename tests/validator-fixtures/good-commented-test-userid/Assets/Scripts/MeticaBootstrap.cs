using UnityEngine;

public class MeticaBootstrap : MonoBehaviour
{
    void Start()
    {
        MeticaAdsCallbacks.Interstitial.OnAdLoadSuccess += ad => Debug.Log("loaded");
        MeticaAdsCallbacks.Interstitial.OnAdLoadFailed += err => Debug.Log("failed");
        MeticaAdsCallbacks.Interstitial.OnAdHidden += ad => MeticaSdk.Ads.LoadInterstitial("inter_main");
        MeticaAdsCallbacks.Interstitial.OnAdShowFailed += (ad, err) => MeticaSdk.Ads.LoadInterstitial("inter_main");

        MeticaSdk.Ads.SetHasUserConsent(true);
        MeticaSdk.Ads.SetDoNotSell(false);

        // Old debugging line — commented out, must NOT trigger user_id_not_test_value:
        // MeticaSdk.Initialize(new MeticaInitConfig("KEY", "APP", "test"), null, r => {});

        /* Block comment with a placeholder reference:
           MeticaSdk.Initialize(new MeticaInitConfig("YOUR_METICA_API_KEY", "...", null), ...);
           Must NOT trigger placeholder_ids_replaced either. */

        MeticaSdk.Initialize(new MeticaInitConfig("real-key", "real-app", "u-abc-123"), null, response => {});

        MeticaSdk.Ads.LoadInterstitial("inter_main");
    }

    void ShowAd()
    {
        if (MeticaSdk.Ads.IsInterstitialReady("inter_main"))
            MeticaSdk.Ads.ShowInterstitial("inter_main");
    }
}
