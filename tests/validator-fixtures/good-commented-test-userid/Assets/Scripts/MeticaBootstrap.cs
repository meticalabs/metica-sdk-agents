using UnityEngine;

// A commented-out example must NOT trip the credential/user-id checks:
//   e.g. new MeticaInitConfig("a", "b", "test-user");  set YOUR_METICA_API_KEY first
public class MeticaBootstrap : MonoBehaviour
{
    private string _userId;

    void Start()
    {
        _userId = SystemInfo.deviceUniqueIdentifier;

        MeticaAdsCallbacks.Interstitial.OnAdLoadSuccess += ad => Debug.Log("loaded");
        MeticaAdsCallbacks.Interstitial.OnAdLoadFailed += err => Debug.Log("failed");
        MeticaAdsCallbacks.Interstitial.OnAdHidden += ad => MeticaSdk.Ads.LoadInterstitial("inter_main");

        MeticaSdk.Ads.SetHasUserConsent(true);
        MeticaSdk.Ads.SetDoNotSell(false);

        MeticaSdk.Initialize(new MeticaInitConfig("real-api-key", "real-app-id", _userId), null, r => {});

        MeticaSdk.Ads.LoadInterstitial("inter_main");
    }

    void ShowAd()
    {
        if (MeticaSdk.Ads.IsInterstitialReady("inter_main"))
            MeticaSdk.Ads.ShowInterstitial("inter_main");
    }
}
