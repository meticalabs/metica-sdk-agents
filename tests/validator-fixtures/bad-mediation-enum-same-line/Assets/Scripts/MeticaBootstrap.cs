using UnityEngine;

// Edge case for mediation_enum_qualified: a single line carries BOTH a bare
// (uncompilable) MeticaMediationType.MAX and a correctly-qualified
// MeticaMediationInfo.MeticaMediationType.MAX. Occurrence counting (not line
// counting) must still flag the bare reference as FAIL.
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

        var bad = MeticaMediationType.MAX; var good = MeticaMediationInfo.MeticaMediationType.MAX;
        MeticaSdk.Initialize(new MeticaInitConfig("API_KEY", "APP_ID", "u-abc-123"),
            new MeticaMediationInfo(good, "max-key-99"), response => {});

        MeticaSdk.Ads.LoadInterstitial("inter_main");
    }

    void ShowAd()
    {
        if (MeticaSdk.Ads.IsInterstitialReady("inter_main"))
            MeticaSdk.Ads.ShowInterstitial("inter_main");
    }
}
