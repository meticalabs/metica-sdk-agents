using UnityEngine;

public class MeticaBootstrap : MonoBehaviour
{
    void Start()
    {
        MeticaAdsCallbacks.Interstitial.OnAdLoadSuccess += ad => Debug.Log("loaded");
        MeticaAdsCallbacks.Interstitial.OnAdLoadFailed += err => Debug.Log("failed");
        MeticaAdsCallbacks.Interstitial.OnAdHidden += ad => MeticaSdk.Ads.LoadInterstitial("inter_main");
        MeticaSdk.Ads.SetHasUserConsent(true);
        MeticaSdk.Ads.SetDoNotSell(false);
        MeticaSdk.Initialize(new MeticaInitConfig("KEY", "APP", "u-abc-123"), null, r => {});
        MeticaSdk.Ads.LoadInterstitial("inter_main");
    }
    void ShowAd() { MeticaSdk.Ads.ShowInterstitial("inter_main"); }
}
