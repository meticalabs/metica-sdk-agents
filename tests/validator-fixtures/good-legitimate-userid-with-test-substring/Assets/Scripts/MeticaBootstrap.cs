using UnityEngine;

// Regression fixture for the test-value substring false-positive that the
// pre-fix regex tripped on. "contest-user-42" contains the letters "test" but
// not as a delimited word, so the validator must PASS — not flag.

public class MeticaBootstrap : MonoBehaviour
{
    void Start()
    {
        MeticaAdsCallbacks.Interstitial.OnAdLoadSuccess += ad => Debug.Log("loaded");
        MeticaAdsCallbacks.Interstitial.OnAdLoadFailed += err => Debug.Log("failed");
        MeticaAdsCallbacks.Interstitial.OnAdHidden += ad => MeticaSdk.Ads.LoadInterstitial("inter_main");

        MeticaSdk.Ads.SetHasUserConsent(true);
        MeticaSdk.Ads.SetDoNotSell(false);

        MeticaSdk.Initialize(new MeticaInitConfig("real-api", "real-app", "contest-user-42"), null, response => {});

        MeticaSdk.Ads.LoadInterstitial("inter_main");
    }

    void ShowAd()
    {
        if (MeticaSdk.Ads.IsInterstitialReady("inter_main"))
            MeticaSdk.Ads.ShowInterstitial("inter_main");
    }
}
