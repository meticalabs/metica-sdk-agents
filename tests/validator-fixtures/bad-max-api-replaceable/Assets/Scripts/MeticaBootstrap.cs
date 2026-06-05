using UnityEngine;

// Reproduces the Merge Art Canvas pattern: a Metica integration mechanically
// forked from an AppLovin one, with surviving MaxSdk.Set*ExtraParameter calls
// that no-op because Metica owns the live AppLovinSdk instance.
public class MeticaBootstrap : MonoBehaviour
{
    void Start()
    {
        MeticaAdsCallbacks.Interstitial.OnAdLoadSuccess += ad => Debug.Log("loaded");
        MeticaAdsCallbacks.Interstitial.OnAdLoadFailed += err => Debug.Log("failed");
        MeticaAdsCallbacks.Interstitial.OnAdRevenuePaid += ad => Debug.Log("revenue");
        MeticaAdsCallbacks.Interstitial.OnAdHidden += ad => MeticaSdk.Ads.LoadInterstitial("inter_main");
        MeticaAdsCallbacks.Interstitial.OnAdShowFailed += (ad, err) => MeticaSdk.Ads.LoadInterstitial("inter_main");

        MeticaSdk.Ads.SetHasUserConsent(true);
        MeticaSdk.Ads.SetDoNotSell(false);

        MeticaSdk.Initialize(new MeticaInitConfig("API_KEY", "APP_ID", "u-abc-123"), null, response => {});

        // BUG: this calls the publisher's MaxSdk static, which Metica never
        // initialised. Silently no-ops; the live MAX instance Metica owns
        // sees no parameter change. Validator must catch this.
        MaxSdk.SetInterstitialExtraParameter("inter_main", "disable_auto_retries", "true");

        MeticaSdk.Ads.LoadInterstitial("inter_main");
    }

    void ShowAd()
    {
        if (MeticaSdk.Ads.IsInterstitialReady("inter_main"))
            MeticaSdk.Ads.ShowInterstitial("inter_main");
    }
}
