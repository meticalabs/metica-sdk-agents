using UnityEngine;

public class PrivacyLater : MonoBehaviour
{
    void OnUserConsentDecided(bool granted)
    {
        // Privacy is set in a different file than the Initialize call — runtime
        // ordering is undefined; validator should flag this as FAIL.
        MeticaSdk.Ads.SetHasUserConsent(granted);
        MeticaSdk.Ads.SetDoNotSell(false);
    }
}
