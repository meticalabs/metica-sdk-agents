// Regression fixture: a user-owned ad abstraction named IAdService.cs that
// has NOTHING to do with our retired router stack. The validator must NOT
// flag this as `legacy_router_files_present` — the check looks for the
// AdServiceRouter / MeticaRolloutBinding class declarations, not the
// filename.
public interface IAdService { void ShowAd(string placementId); }
