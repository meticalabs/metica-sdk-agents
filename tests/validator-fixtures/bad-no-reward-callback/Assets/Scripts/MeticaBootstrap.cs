using UnityEngine;

public class MeticaBootstrap : MonoBehaviour
{
    void Start()
    {
        MeticaAdsCallbacks.Rewarded.OnAdLoadSuccess += ad => Debug.Log("loaded");
        MeticaAdsCallbacks.Rewarded.OnAdLoadFailed += err => Debug.Log("failed");
        MeticaSdk.Ads.SetHasUserConsent(true);
        MeticaSdk.Ads.SetDoNotSell(false);
        MeticaSdk.Initialize(new MeticaInitConfig("KEY", "APP", "u-abc-123"), null, r => {});
        MeticaSdk.Ads.LoadRewarded("rewarded_main");
    }
    void ShowAd() { MeticaSdk.Ads.ShowRewarded("rewarded_main"); }
}
