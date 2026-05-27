using UnityEngine;

// Pre-existing dedicated Max wrapper. The straight swap rewrites the game's
// direct MaxSdk call sites to use MeticaAdService and leaves this wrapper
// untouched (now orphaned — the owner deletes it when ready). Its lingering
// MaxSdk references mean the validator auto-detects Max+Metica with no router,
// i.e. straight-swap.
public class AdManager
{
    public void Init()
    {
        MaxSdk.SetSdkKey("sdk-key");
        MaxSdk.InitializeSdk();
    }

    public void ShowInterstitial(string id) => MaxSdk.ShowInterstitial(id);
}
