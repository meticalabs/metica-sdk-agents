using UnityEngine;

// Otherwise-valid integration, but the SmartFloors property is written in the
// camelCase (uncompilable) docs form: isForcedHoldout. The SDK property is
// PascalCase IsForcedHoldout.
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

        MeticaSdk.Initialize(new MeticaInitConfig("API_KEY", "APP_ID", "u-abc-123"), null, response =>
        {
            Debug.Log($"holdout: {response.SmartFloors.isForcedHoldout}");
        });

        MeticaSdk.Ads.LoadInterstitial("inter_main");
    }

    void ShowAd()
    {
        if (MeticaSdk.Ads.IsInterstitialReady("inter_main"))
            MeticaSdk.Ads.ShowInterstitial("inter_main");
    }
}
