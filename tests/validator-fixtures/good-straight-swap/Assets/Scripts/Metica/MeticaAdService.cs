using UnityEngine;

// Straight-swap orchestrator: no IAdService, no router. Inits MeticaSDK once
// (privacy precedes Initialize in this same file) and owns the per-format objects.
public class MeticaAdService
{
    private MeticaInterstitialAd _interstitial;

    public void Initialize()
    {
        MeticaSdk.Ads.SetHasUserConsent(true);
        MeticaSdk.Ads.SetDoNotSell(false);

        MeticaSdk.Initialize(new MeticaInitConfig("metica-api-key-abc", "metica-app-123", null), null, r =>
        {
            _interstitial = new MeticaInterstitialAd("inter_main");
            _interstitial.Load();
        });
    }

    public void ShowInterstitial() { _interstitial?.Show(); }
}
