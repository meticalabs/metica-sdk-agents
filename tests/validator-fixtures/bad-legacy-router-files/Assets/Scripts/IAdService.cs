// Stale router-stack artifact left over from a v0.4.x integration. The v0.5.0
// validator must flag this — the router stack was retired in v0.5.0 and a
// project carrying both this AND the new MeticaAdService ships with two ad
// code paths active at runtime. The validator identifies the retired stack
// by the AdServiceRouter / MeticaRolloutBinding class declarations (unique
// to our retired codegen), not by filename — so user-owned ad abstractions
// named IAdService.cs do NOT false-positive.
public interface IAdService { void Initialize(); }

public class AdServiceRouter {
    public static AdServiceRouter Instance = new AdServiceRouter();
    public void Initialize() { }
}
