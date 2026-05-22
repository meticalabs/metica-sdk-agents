using UnityEngine;

public class MeticaAdService : IAdService
{
    public void Initialize()
    {
        MeticaAdsCallbacks.Interstitial.OnAdLoadSuccess += ad => Debug.Log("loaded");
        MeticaAdsCallbacks.Interstitial.OnAdLoadFailed += err => Debug.Log("failed");
        MeticaAdsCallbacks.Interstitial.OnAdRevenuePaid += ad => Debug.Log("revenue");

        MeticaSdk.Ads.SetHasUserConsent(true);
        MeticaSdk.Ads.SetDoNotSell(false);
        MeticaSdk.Initialize(new MeticaInitConfig("KEY", "APP", null), null, r => {});
    }
    public void LoadInterstitial(string id) { MeticaSdk.Ads.LoadInterstitial(id); }
    public void ShowInterstitial(string id) { MeticaSdk.Ads.ShowInterstitial(id); }
}
