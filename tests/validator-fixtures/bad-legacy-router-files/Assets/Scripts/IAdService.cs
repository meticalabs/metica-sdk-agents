// Stale router-stack artifact left over from a v0.4.x integration. The v0.5.0
// validator must flag this — the router stack was retired in v0.5.0 and a
// project carrying both this AND the new MeticaAdService ships with two ad
// code paths active at runtime.
public interface IAdService { void Initialize(); }
