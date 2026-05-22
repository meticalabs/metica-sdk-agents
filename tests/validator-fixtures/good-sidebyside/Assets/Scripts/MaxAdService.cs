using UnityEngine;

public class MaxAdService : IAdService
{
    public void Initialize() { MaxSdk.InitializeSdk(); }
    public void LoadInterstitial(string id) { MaxSdk.LoadInterstitial(id); }
    public void ShowInterstitial(string id) { MaxSdk.ShowInterstitial(id); }
}
