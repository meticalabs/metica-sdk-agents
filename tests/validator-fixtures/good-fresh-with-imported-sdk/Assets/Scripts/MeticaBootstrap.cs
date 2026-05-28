using UnityEngine;
public class MeticaBootstrap : MonoBehaviour {
    void Start() {
        MeticaAdsCallbacks.Interstitial.OnAdLoadSuccess += ad => Debug.Log("loaded");
        MeticaAdsCallbacks.Interstitial.OnAdLoadFailed += err => Debug.LogWarning("failed");
        MeticaAdsCallbacks.Interstitial.OnAdHidden += ad => MeticaSdk.Ads.LoadInterstitial("inter");
        MeticaSdk.Ads.SetHasUserConsent(true);
        MeticaSdk.Ads.SetDoNotSell(false);
        MeticaSdk.Initialize(new MeticaInitConfig("K", "A", "u-abc-123"), null, r => {});
        MeticaSdk.Ads.LoadInterstitial("inter");
    }
    void Show() { MeticaSdk.Ads.ShowInterstitial("inter"); }
}
