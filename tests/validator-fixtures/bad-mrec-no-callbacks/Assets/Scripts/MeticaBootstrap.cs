using UnityEngine;

public class MeticaBootstrap : MonoBehaviour
{
    void Start()
    {
        MeticaSdk.Ads.SetHasUserConsent(true);
        MeticaSdk.Ads.SetDoNotSell(false);

        MeticaSdk.Initialize(new MeticaInitConfig("API_KEY", "APP_ID", "u-abc-123"), null, response => {});

        // BUG: MRec loaded but no callbacks subscribed and no ShowMrec.
        MeticaSdk.Ads.LoadMrec("mrec_main");
    }
}
