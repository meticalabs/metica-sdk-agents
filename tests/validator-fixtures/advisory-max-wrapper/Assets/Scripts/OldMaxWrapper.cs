using UnityEngine;

// A side-by-side dedicated Max wrapper file. No MeticaSdk references here —
// the wrapper predates the Metica integration. The validator should treat
// MaxSdk.* calls in this file as ADVISORY (the calls no-op under Metica's
// init, but the wrapper might still be intentionally kept; let the user
// decide rather than blocking the integration).
public class OldMaxWrapper
{
    public void ShowInterstitial(string id)
    {
        MaxSdk.LoadInterstitial(id);
    }
}
