using UnityEngine;

// Per-format object: owns the interstitial callbacks + the show → hidden → reload loop.
public class MeticaInterstitialAd
{
    private readonly string _adUnitId;

    public MeticaInterstitialAd(string adUnitId)
    {
        _adUnitId = adUnitId;
        MeticaAdsCallbacks.Interstitial.OnAdLoadSuccess += ad => Debug.Log("[Metica] interstitial loaded");
        MeticaAdsCallbacks.Interstitial.OnAdLoadFailed += err => Debug.LogWarning("[Metica] interstitial failed");
        MeticaAdsCallbacks.Interstitial.OnAdRevenuePaid += ad => Debug.Log("[Metica] interstitial revenue");
        MeticaAdsCallbacks.Interstitial.OnAdHidden += ad => Load();
    }

    public void Load() { MeticaSdk.Ads.LoadInterstitial(_adUnitId); }

    public void Show()
    {
        if (MeticaSdk.Ads.IsInterstitialReady(_adUnitId))
            MeticaSdk.Ads.ShowInterstitial(_adUnitId);
    }
}
