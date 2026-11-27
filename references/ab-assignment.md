# AB Assignment (`com.abassignment.unity`) integration rules

AB Assignment is Metica's Unity package that splits players into a **Metica** group (ads through MeticaSDK) and a **Baseline** group (ads through the game's own MAX code), keeps the split fixed per install, and reports the group to Metica so revenue can be compared.
It has no dependency on MeticaSDK, MAX or Firebase: the game wires those, and the package only says which route a player takes.

This file is the single source of truth for how the package is wired next to MeticaSDK.
The `ab-assignment` skill (which wires the package) and the validator (`ab_assignment_*` rules) both read it. The integrator reads only "Detecting the package", to keep the game's MAX path when the package is installed.
The package's own README is the upstream reference: <https://github.com/meticalabs/ab-assignment-unity>.
The rules below follow package version 2.2.1.

## Detecting the package

- Present: `Packages/manifest.json` lists `"com.abassignment.unity"`, or `Packages/com.abassignment.unity/` exists (embedded copy). Game code uses `using AB.Assignment;` and the static class `ABAssignment`.
- Legacy: `"com.metica.assignment"` (below 2.0.0, class `MeticaAssignment`). Tell the user to move to `com.abassignment.unity` first; the shapes below use the 2.x names.
- Version: `ReportCustomId`, `SetAssignmentMode` and `ReportClientAssignment` exist from 2.2.0. A project pinned to an older 2.x version that needs its own player id or client-managed mode moves to 2.2.0 or later first.
- Mode: a `ABAssignment.SetAssignmentMode(AssignmentMode.ClientManaged)` call means **client-managed** mode (the game decides the group and reports it). Otherwise the mode is **automatic** (the package decides from the Firebase Remote Config parameter `metica_assignment`).

## Rules

| # | Rule | Why |
|---|---|---|
| 1 | Both routes ship in one build and the route is picked at runtime from `ABAssignment.Current.RunMetica`. A compile-time split (`#if`) is not an AB test. | One build has to serve both groups, and the kill switch has to work without a release. |
| 2 | `ABAssignment.Initialize(new ABAssignmentOptions(appId, apiKey))` runs once at app start, before the first scene, with the same app id and API key MeticaSDK gets. A game on a dedicated cluster sets the same `CustomDomain` it gives MeticaSDK. | Events queue on the device until `Initialize` and are sent to Metica by the package itself, for both groups. |
| 3 | The group is decided by the first read of `ABAssignment.Current`, the first `TagPlacement`, or the first `ReportAdsInit`. None of them may run at app start: they run when the game starts ads, after the Remote Config result was reported. | A read before the Firebase value arrives leaves the whole session unassigned. Once decided, the group is fixed for the session, so later reads of `Current` are safe. `ABAssignment.UserId` and `TryGetCurrent` are safe at any time. |
| 4 | Automatic mode: the game reports every Remote Config outcome with `ReportRemoteConfig` (fetch failed, activation failed, success), passes the `metica_assignment` value only when its source is the server, and sets no in-app default for it. | The package has no Firebase dependency; it only learns the value from this call. An in-app default would assign players from a value nobody published. A failure before the fetch starts needs no report: the package records a timeout itself. |
| 5 | `RunMetica == true` starts MeticaSDK only (it sets the MAX user id and starts MAX itself). `RunMetica == false` starts the game's own MAX code only. Unassigned players and a kill switch set to off also run the game's own MAX code. | Starting both double-initializes MAX. |
| 6 | Every user id given to MeticaSDK or MAX is known to the package (see "The user id rule"). | Ad revenue is matched to a player's group through this id. |
| 7 | Each route reports `ReportAdsInit(AdsInitStage.Started)` just before it starts its ad SDK, then exactly one of `Succeeded` or `Failed`. The Metica route passes MeticaSDK's own group and forced-holdout flag with `Succeeded`. | It tells Metica whether ads started on each route, and how long that took. |
| 8 | Every placement string that reaches an ad SDK goes through `ABAssignment.TagPlacement`, on both routes: interstitial and rewarded shows, and the banner / MRec placement right after the ad view is created (on the Metica route again after every re-create). | The tag (`metica\|`, `baseline\|`, `unassigned\|`) lets every revenue report be split by group. |
| 9 | `Initialize`, `ReportRemoteConfig`, `ReportAdsInit`, `SetConsentStatus`, `ReportCustomId`, `SetAssignmentMode`, `ReportClientAssignment` and the first read of `Current` run on the Unity main thread. | Off the main thread the call is logged as an error and ignored. A MAX init callback can arrive off the main thread, so its result is reported after marshalling back. Reporting after an `await` that started on the main thread, on a task the callback completes, is one accepted way. |
| 10 | A game with its own GDPR prompt calls `ABAssignment.SetConsentStatus` with the player's answer. | The answer is sent with every event. It is not the TCF / UMP ad consent. |

Client-managed mode replaces rules 3 and 4: the game calls `SetAssignmentMode(AssignmentMode.ClientManaged)` on every launch before `Initialize`, and `ReportClientAssignment(group, providerUserId)` before it starts ads.
The agents leave the game's own split untouched in this mode.

## The user id rule

The package must know every user id the ad stack uses.

- **The game has no stable player id of its own:** pass `ABAssignment.UserId` to `MeticaInitConfig` on the Metica route and to `MaxSdk.SetUserId` (before `MaxSdk.InitializeSdk`) on the MAX route. `AssignmentResult.UserId` (for example `ABAssignment.Current.UserId`) is the same value.
- **The game has its own stable player id:** pass that same id on both routes, and report it with `ABAssignment.ReportCustomId(id)`. An id that is created later is reported as soon as it exists.
- **Client-managed mode:** the id is reported with `ReportClientAssignment(group, providerUserId)` instead. On the Metica route a `null` user id is acceptable there only because `MeticaInitResponse.UserId` is reported once init returns.

Observed on a device (MeticaSDK 2.45.6, AppLovin MAX Android SDK 13.6.4):

- With a `null` user id, MeticaSDK generates its own id and hands the same id to MAX. That id differs from `ABAssignment.UserId`, so the package does not know it.
- Without `MaxSdk.SetUserId`, MAX holds no user id at all.
- With an id passed, MeticaSDK and MAX both hold exactly that id.

## Code shapes

`<AdsUserId>` is `ABAssignment.UserId`, or the game's own id expression when the user chose one.
All shapes need `using AB.Assignment;`.

App start, before the first scene:

```csharp
[RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.BeforeSceneLoad)]
private static void InitializeAbAssignment()
{
    ABAssignment.Initialize(new ABAssignmentOptions("<METICA_APP_ID>", "<METICA_API_KEY>"));
}
```

Remote Config (automatic mode), added to the game's existing fetch; report before the game's other handlers:

```csharp
// fetch faulted, cancelled, or LastFetchStatus != Success:
ABAssignment.ReportRemoteConfig(RemoteConfigStatus.FetchFailed, null, "fetch failed");
// ActivateAsync faulted or cancelled (returning false is not a failure):
ABAssignment.ReportRemoteConfig(RemoteConfigStatus.ActivationFailed, null, "activate failed");
// fetch and activation fine: pass the value only when it came from the server.
ConfigValue value = FirebaseRemoteConfig.DefaultInstance.GetValue("metica_assignment");
ABAssignment.ReportRemoteConfig(RemoteConfigStatus.Success,
    value.Source == ValueSource.RemoteValue ? value.StringValue : null, null);
```

Ads start: decide once, where the game starts ads (after its consent flow), never at app start. With the integrator's switchable gate, assign the switch; with a branch the studio wrote, branch on the stored value:

```csharp
MeticaAdService.UseMetica = ABAssignment.Current.RunMetica;   // integrator's switchable gate
bool runMetica = ABAssignment.Current.RunMetica;             // hand-written branch: if (runMetica) ... else ...
```

Metica route, in the class that owns the MeticaSDK init:

```csharp
var config = new MeticaInitConfig("<METICA_API_KEY>", "<METICA_APP_ID>", <AdsUserId>);
ABAssignment.ReportAdsInit(AdsInitStage.Started);          // just before MeticaSdk.Initialize
// in OnInitialized, or after an awaited InitializeAsync (MeticaSDK reports a failed init as a forced
// holdout, so this is Succeeded; report Failed only from a catch around an unexpected exception):
ABAssignment.ReportAdsInit(AdsInitStage.Succeeded, null,
    response.SmartFloors?.UserGroup.ToString(), response.SmartFloors?.IsForcedHoldout);
```

MAX route, the game's original bootstrap on the other branch:

```csharp
MaxSdk.SetUserId(<AdsUserId>);                              // before InitializeSdk
ABAssignment.ReportAdsInit(AdsInitStage.Started);
MaxSdk.InitializeSdk();
// in the game's OnSdkInitializedEvent handler, on the Unity main thread:
if (configuration.IsSuccessfullyInitialized) ABAssignment.ReportAdsInit(AdsInitStage.Succeeded);
else ABAssignment.ReportAdsInit(AdsInitStage.Failed, "MAX failed to initialize");
```

Placements, on both routes:

```csharp
string tagged = ABAssignment.TagPlacement(placement);
MeticaSdk.Ads.ShowInterstitial(adUnitId, tagged);           // Metica route (rewarded: ShowRewarded)
MaxSdk.ShowInterstitial(adUnitId, tagged);                  // MAX route (rewarded: ShowRewardedAd)
MeticaSdk.Ads.SetBannerPlacement(adUnitId, ABAssignment.TagPlacement("banner"));   // after CreateBanner
MaxSdk.SetBannerPlacement(adUnitId, ABAssignment.TagPlacement("banner"));          // after CreateBanner
```

The game's own id, when it has one:

```csharp
ABAssignment.ReportCustomId(<AdsUserId>, "player_id");      // any time on the main thread; the label is optional
```

## What stays with the user

- Publishing the `metica_assignment` Remote Config parameter (JSON, no conditions, no in-app default) and stopping any other test that decides Metica on or off.
- The kill switch: publishing the same value with `"enabled": false`.
- `SetConsentStatus`, when the game has its own GDPR prompt.
- The MAX SDK key for the MAX route stays where the game already configures it.
