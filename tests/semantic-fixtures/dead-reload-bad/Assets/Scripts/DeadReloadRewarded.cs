using UnityEngine;

// FALSE-POSITIVE trap for grep: OnAdHidden IS subscribed and a LoadRewarded call IS
// present textually, so grep's reload rule PASSes. But the reload is dead code — it sits
// behind a flag hardcoded false and never reassigned, so at runtime the loop never closes.
// The semantic pass must FAIL this: no reachable path from the hidden handler to LoadRewarded.
public class DeadReloadRewarded : MonoBehaviour
{
    bool _neverTrue = false;

    void Start()
    {
        MeticaAdsCallbacks.Rewarded.OnAdLoadSuccess += OnLoaded;
        MeticaAdsCallbacks.Rewarded.OnAdLoadFailed  += OnLoadFailed;
        MeticaAdsCallbacks.Rewarded.OnAdRewarded    += OnRewarded;
        MeticaAdsCallbacks.Rewarded.OnAdShowFailed  += OnShowFailed;
        MeticaAdsCallbacks.Rewarded.OnAdHidden      += OnRewardedHidden;

        MeticaSdk.Ads.SetHasUserConsent(true);
        MeticaSdk.Ads.SetDoNotSell(false);
        MeticaSdk.Initialize(new MeticaInitConfig("API_KEY", "APP_ID", "u-42"), null, r => {});
        MeticaSdk.Ads.LoadRewarded("rw_main");
    }

    void OnRewardedHidden(MeticaAd ad)
    {
        if (_neverTrue)
        {
            MeticaSdk.Ads.LoadRewarded("rw_main");
        }
    }

    void OnLoaded(MeticaAd ad) {}
    void OnLoadFailed(MeticaAdError e) {}
    void OnRewarded(MeticaAd ad) {}
    void OnShowFailed(MeticaAd ad, MeticaAdError e) {}

    void ShowRewarded()
    {
        if (MeticaSdk.Ads.IsRewardedReady("rw_main"))
            MeticaSdk.Ads.ShowRewarded("rw_main");
    }
}
