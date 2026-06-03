using UnityEngine;

// TRIAL/HOLDOUT RISK (trial_holdout_integrity → FAIL): interstitials are served
// through Metica (so the SmartFloor applies), but ShowExtra() shows a MaxSDK
// interstitial DIRECTLY on a path the game also uses. Those impressions skip
// Metica's floor entirely, so Trial and Holdout users get inconsistent treatment
// and the experiment measurement is biased. The deterministic floor PASSes this
// (init/privacy/callbacks/parity are all fine) — only the semantic pass catches it.
public class AdFlow : MonoBehaviour
{
    void Start()
    {
        MeticaAdsCallbacks.Interstitial.OnAdLoadSuccess += ad => Debug.Log("loaded");
        MeticaAdsCallbacks.Interstitial.OnAdLoadFailed += err => Debug.Log("failed");
        MeticaAdsCallbacks.Interstitial.OnAdRevenuePaid += ad => Debug.Log("revenue");
        MeticaAdsCallbacks.Interstitial.OnAdShowFailed += (ad, err) => MeticaSdk.Ads.LoadInterstitial("inter_main");
        MeticaAdsCallbacks.Interstitial.OnAdHidden += ad => MeticaSdk.Ads.LoadInterstitial("inter_main");

        MeticaSdk.Ads.SetHasUserConsent(true);
        MeticaSdk.Ads.SetDoNotSell(false);
        MeticaSdk.Initialize(new MeticaInitConfig("real-key", "real-app-id", "u-42"), null, response => {});
        MeticaSdk.Ads.LoadInterstitial("inter_main");
    }

    void ShowGated()
    {
        if (MeticaSdk.Ads.IsInterstitialReady("inter_main"))
            MeticaSdk.Ads.ShowInterstitial("inter_main");
    }

    // BUG: bypasses Metica — shows a MAX interstitial directly, skipping the floor.
    void ShowExtra()
    {
        MaxSdk.ShowInterstitial("max_inter_unit");
    }
}
