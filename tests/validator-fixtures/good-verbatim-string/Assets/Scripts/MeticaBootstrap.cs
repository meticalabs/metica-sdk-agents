using UnityEngine;

public class MeticaBootstrap : MonoBehaviour
{
    // Verbatim and interpolated strings containing the pattern must NOT count.
    private const string Docs = @"This documents MeticaSdk.Initialize(cfg, info, cb);
    and also mentions MaxSdk.Initialize() across lines without escapes.";
    private string Interp = $"Calling MeticaSdk.Ads.LoadInterstitial( from logs";

    void Start()
    {
        MeticaAdsCallbacks.Interstitial.OnAdLoadSuccess += ad => Debug.Log("loaded");
        MeticaAdsCallbacks.Interstitial.OnAdLoadFailed += err => Debug.Log("failed");
        MeticaSdk.Ads.SetHasUserConsent(true);
        MeticaSdk.Ads.SetDoNotSell(false);
        MeticaSdk.Initialize(new MeticaInitConfig("KEY", "APP", null), null, r => {});
        MeticaSdk.Ads.LoadInterstitial("inter_main");
    }
    void ShowAd() { MeticaSdk.Ads.ShowInterstitial("inter_main"); }
}
