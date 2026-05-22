using UnityEngine;

public class AdServiceRouter : MonoBehaviour
{
    public IAdService AdService;
    void Awake()
    {
        bool useMetica = false;
        AdService = useMetica ? (IAdService)new MeticaAdService() : new MaxAdService();
        AdService.Initialize();
    }
}
