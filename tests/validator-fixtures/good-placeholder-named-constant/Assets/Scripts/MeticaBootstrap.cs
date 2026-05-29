using UnityEngine;

// Regression fixture for the placeholder-grep false-positive: the user has
// refactored placeholder names into a constant and wired the REAL key value
// into the literal. The validator must check that the placeholder appears as
// a STRING LITERAL VALUE, not as an identifier name — otherwise the user is
// forced to rename a sanely-named constant.

public class MeticaBootstrap : MonoBehaviour
{
    private const string YOUR_METICA_API_KEY = "real-api-abc123";
    private const string YOUR_METICA_APP_ID  = "real-app-xyz789";

    void Start()
    {
        MeticaAdsCallbacks.Interstitial.OnAdLoadSuccess += ad => Debug.Log("loaded");
        MeticaAdsCallbacks.Interstitial.OnAdLoadFailed += err => Debug.Log("failed");
        MeticaAdsCallbacks.Interstitial.OnAdHidden += ad => MeticaSdk.Ads.LoadInterstitial("inter_main");
        MeticaAdsCallbacks.Interstitial.OnAdShowFailed += (ad, err) => MeticaSdk.Ads.LoadInterstitial("inter_main");

        MeticaSdk.Ads.SetHasUserConsent(true);
        MeticaSdk.Ads.SetDoNotSell(false);

        MeticaSdk.Initialize(new MeticaInitConfig(YOUR_METICA_API_KEY, YOUR_METICA_APP_ID, "u-abc-123"), null, response => {});

        MeticaSdk.Ads.LoadInterstitial("inter_main");
    }

    void ShowAd()
    {
        if (MeticaSdk.Ads.IsInterstitialReady("inter_main"))
            MeticaSdk.Ads.ShowInterstitial("inter_main");
    }
}
