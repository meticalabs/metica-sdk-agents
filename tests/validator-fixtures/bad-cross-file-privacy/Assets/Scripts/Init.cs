using UnityEngine;

public class Init : MonoBehaviour
{
    void Start()
    {
        MeticaAdsCallbacks.Interstitial.OnAdLoadSuccess += ad => Debug.Log("loaded");
        MeticaAdsCallbacks.Interstitial.OnAdLoadFailed += err => Debug.Log("failed");
        MeticaSdk.Initialize(new MeticaInitConfig("KEY", "APP", null), null, r => {});
        MeticaSdk.Ads.LoadInterstitial("inter_main");
    }
    void ShowAd() { MeticaSdk.Ads.ShowInterstitial("inter_main"); }
}
