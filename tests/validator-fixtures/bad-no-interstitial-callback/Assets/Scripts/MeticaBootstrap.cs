using UnityEngine;

public class MeticaBootstrap : MonoBehaviour
{
    void Start()
    {
        MeticaAdsCallbacks.Interstitial.OnAdLoadSuccess += ad => Debug.Log("loaded");
        MeticaSdk.Ads.SetHasUserConsent(true);
        MeticaSdk.Ads.SetDoNotSell(false);
        MeticaSdk.Initialize(new MeticaInitConfig("KEY", "APP", null), null, r => {});
        MeticaSdk.Ads.LoadInterstitial("inter_main");
    }
    void ShowAd() { MeticaSdk.Ads.ShowInterstitial("inter_main"); }
}
