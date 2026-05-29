using UnityEngine;

// Per-format object: MonoBehaviour so the docs-style Invoke retry works.
// Owns the interstitial callbacks + the show → hidden → reload loop.
public class MeticaInterstitialAd : MonoBehaviour
{
    private string _adUnitId;
    private int _retryAttempt = 0;
    private bool _initialized = false;

    public void Initialize(string adUnitId)
    {
        if (_initialized) return;
        _initialized = true;
        _adUnitId = adUnitId;

        MeticaAdsCallbacks.Interstitial.OnAdLoadSuccess += ad => { _retryAttempt = 0; Debug.Log("[Metica] interstitial loaded"); };
        MeticaAdsCallbacks.Interstitial.OnAdLoadFailed += err =>
        {
            _retryAttempt++;
            double delay = System.Math.Pow(2, System.Math.Min(6, _retryAttempt));
            Debug.LogWarning("[Metica] interstitial failed");
            Invoke(nameof(Load), (float)delay);
        };
        MeticaAdsCallbacks.Interstitial.OnAdRevenuePaid += ad => Debug.Log("[Metica] interstitial revenue");
        MeticaAdsCallbacks.Interstitial.OnAdHidden += ad => Load();
        MeticaAdsCallbacks.Interstitial.OnAdShowFailed += (ad, err) => Load();

        Load();
    }

    private void Load() { MeticaSdk.Ads.LoadInterstitial(_adUnitId); }

    public void Show()
    {
        if (MeticaSdk.Ads.IsInterstitialReady(_adUnitId))
            MeticaSdk.Ads.ShowInterstitial(_adUnitId);
    }
}
