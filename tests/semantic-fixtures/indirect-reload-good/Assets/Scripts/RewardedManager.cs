using UnityEngine;

// Reload-on-hidden via INDIRECTION: OnAdHidden -> RestartRewardedCycle() -> LoadRewarded.
// Grep's reload rule PASSes (OnAdHidden is subscribed and a LoadRewarded exists somewhere),
// but it cannot prove the loop actually closes. The semantic pass PASSes WITH a 3-hop
// evidence chain (entry -> hop -> terminal), so the green result is grounded, not assumed.
public class RewardedManager : MonoBehaviour
{
    bool _autoReload = true;

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
        if (_autoReload) RestartRewardedCycle();
    }

    void RestartRewardedCycle()
    {
        MeticaSdk.Ads.LoadRewarded("rw_main");
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
