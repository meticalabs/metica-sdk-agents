using UnityEngine;

// userId passed as null — NOT a failure: the SDK substitutes its own stable id
// (anonymous mode), treated identically to "". Must report user_id_not_test_value PASS.
public class MeticaBootstrap : MonoBehaviour
{
    void Start()
    {
        MeticaAdsCallbacks.Interstitial.OnAdLoadSuccess += ad => Debug.Log("loaded");
        MeticaAdsCallbacks.Interstitial.OnAdLoadFailed += err => Debug.Log("failed");
        MeticaAdsCallbacks.Interstitial.OnAdShowFailed += (ad, err) => MeticaSdk.Ads.LoadInterstitial("inter_main");
        MeticaAdsCallbacks.Interstitial.OnAdHidden += ad => MeticaSdk.Ads.LoadInterstitial("inter_main");

        MeticaSdk.Ads.SetHasUserConsent(true);
        MeticaSdk.Ads.SetDoNotSell(false);

        MeticaSdk.Initialize(new MeticaInitConfig("real-key", "real-app-id", null), null, response => {});

        MeticaSdk.Ads.LoadInterstitial("inter_main");
    }

    void ShowAd()
    {
        if (MeticaSdk.Ads.IsInterstitialReady("inter_main"))
            MeticaSdk.Ads.ShowInterstitial("inter_main");
    }
}
