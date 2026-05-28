using UnityEngine;

public class MeticaBootstrap : MonoBehaviour
{
    void Start()
    {
        MeticaAdsCallbacks.Interstitial.OnAdLoadSuccess += ad => Debug.Log("loaded");
        MeticaAdsCallbacks.Interstitial.OnAdLoadFailed += err => Debug.Log("failed");
        MeticaSdk.Initialize(new MeticaInitConfig("KEY", "APP", "u-abc-123"), null, r => {});
        MeticaSdk.Ads.SetHasUserConsent(true);  // BUG: after Initialize
        MeticaSdk.Ads.SetDoNotSell(false);      // BUG: after Initialize
        MeticaSdk.Ads.LoadInterstitial("inter_main");
    }
    void ShowAd() { MeticaSdk.Ads.ShowInterstitial("inter_main"); }
}
