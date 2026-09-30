# Personal macOS builds

This branch combines upstream Codex Vitals 1.6.3 with a borderless personal interface, explicit account switching, informational banked-reset details, and a macOS Keep awake control.

## Build and verify

```sh
swift test
.build/debug/CodexVitals --render-sanitized-screenshot
.build/debug/CodexVitals --render-sanitized-screenshot --dark
PERSONAL_BUILD=1 ./build-app.sh
codesign --verify --deep --strict dist/Headroom.app
```

`PERSONAL_BUILD=1` only adds a Personal label. It does not disable this repository's updater. `UNIVERSAL=1` builds both Apple Silicon and Intel. `VERSION=1.6.4.0` overrides the bundle version for a local bootstrap build.

The existing bundle identifier, account storage, and active authentication are preserved.

## Canonical repository and release maintenance

Use **https://github.com/TheMakerOfWorlds/codex-vitals** for changes, releases, project links, and update downloads. The original project is only a source reference; neither its release feed nor the KeystoneScience fork is an update source.

- macOS feed: `https://raw.githubusercontent.com/TheMakerOfWorlds/codex-vitals/main/updates/appcast.xml`
- Windows feed: `https://raw.githubusercontent.com/TheMakerOfWorlds/codex-vitals/main/updates/windows-appcast.xml`
- macOS signing key: Sparkle Keychain account `codex-vitals.themakerofworlds`; CI uses the repository's `SPARKLE_PRIVATE_KEY` Actions secret.

The Publish macOS update workflow tests code, builds a universal app, signs the archive, independently verifies its signature and repository URL, publishes a GitHub release, and only then updates the feed. Runtime/build changes on `main` publish automatically. Versions append the workflow run number to the base version in `Support/Info.plist`. Documentation and generated-feed commits do not trigger releases.

For a manual archive:

```bash
VERSION=1.6.4.0 UNIVERSAL=1 ./build-app.sh
ditto -c -k --sequesterRsrc --keepParent dist/Headroom.app dist/Headroom-1.6.4.0.zip
scripts/prepare-sparkle-update.sh 1.6.4.0
```

Publish the immutable archive and appcast as release assets before copying the generated feed into `updates/appcast.xml`. The private key is never written to the repository. Personal builds are ad-hoc signed and are not Apple-notarized.

Automatic checks and installation are enabled once when migrating from the old feed. Later user choices are preserved. The runtime delegate pins the feed to this repository even if older preferences contain another URL. Sparkle downloads verified updates automatically and installs them when the app quits; Check for Updates can install immediately.

## Interface and behavior

- Headroom title with the selected monochrome quota icon in the header only. The system menu-bar and application icons remain unchanged.
- Borderless rows, controls, badges, lists, and Settings cards.
- Email first, one plan badge, and meaningful aliases/workspace names below.
- Persistent Switch button with a larger target. Authenticated exhausted accounts remain switchable.
- Entire Waiting for reset group at 80% opacity, including its header and rows.
- Stacked quota bars with reset icons beside their reset times.
- Informational banked-reset counts and expiry dates without the year. Expirations within seven days also display the local time with AM/PM. Fast individual tooltips and accessibility text retain the full date, minute, and time zone. No redemption control.
- Keep awake supports timed sessions and Never, with explicit approval, startup, active, and shutdown states. Active status is confirmed against the system sleep setting. Never removes the timer; sleep is still restored when the app exits or a discharging battery reaches 15%.
- A bundled privileged helper requests macOS administrator approval, restores sleep on timeout or connection loss, and reports activation errors directly in the app.
- During an active session, the helper samples the lid every 500 milliseconds, dims only the built-in display to zero when closed, and restores the saved brightness when opened or before sleep cleanup. DisplayServices is resolved dynamically; unsupported brightness APIs leave displays alone. Failed restoration retries three times and produces a visible warning without blocking sleep restoration.
- Explicit Renews versus Plan ends, with distinct icons; neutral Cycle ends for older metadata without provenance.
- Discount expiry is not treated as renewal. Dates are not copied between accounts based on matching workspace display names.
- Calendar-day countdowns distinguish Today, Tomorrow, and Date passed.
- Upstream Claude throttling, Retry-After handling, and cached usage behavior.

## Validation

- The lid-brightness change passes 140 Swift tests locally, including repeated lid cycles, automatic brightness changes while closed, failed reads/writes, restoration retries, and every keep-awake exit path. The preceding updater release also passed 40 Windows unit tests locally and on GitHub's release runners.
- A macOS-authorized hardware test using the same brightness implementation as the privileged helper verified an actual zero-brightness write and restoration to the saved level as root. Physical lid-close/open behavior still needs a hands-on check.
- Light and dark SwiftUI renderings reviewed.
- Release build and strict code-signing verification passed.
- A one-minute administrator-approved keep-awake session confirmed that the system sleep setting became active and returned to normal at expiry. Physical lid-closed behavior was not independently tested.
- The automatic publishing workflow released `v1.6.4.2` and updated this repository's live feed. The installed `1.6.4.0` bootstrap build downloaded that release through Sparkle, verified its Ed25519 signature, installed it on quit, and relaunched as `1.6.4.2`. Active Codex authentication remained unchanged.
- Independent verification rejected a modified archive and a feed pointing to another repository. Feed-publication checks confirmed that retries and older releases do not regress the feed.
- Native UI inspection timed out; visual verification used the app renderer, with installation and live refresh verified separately.

Screenshots contain sample accounts. Private local paths, installation logs, and account data are excluded from this document.

## Project credits

App credits, bundled CREDITS.txt, package metadata, and project pages identify Keystone Science, Nathan Stone, and Jackson Stone. The header pairs the selected quota icon with the Headroom name. The existing signed update feed, credential-storage identifiers, package identities, and inherited open-source license notices remain stable.

Light and dark credit renders are available in `docs/credits.png` and `docs/credits-dark.png`. Existing account storage and active sign-ins are retained across app updates.

## Headroom rename

Headroom keeps the existing bundle identifier, account storage directories, Keychain services, Windows Store identity, and signed update feeds so existing accounts and updates remain compatible. The internal Swift targets and Python module names also remain stable. Public UI labels and newly built app bundles, executables, archives, and installers use Headroom. Historical release notes and upstream copyright notices keep their original names.

`Support/HeadroomHeader.png` and `windows/build-assets/HeadroomHeader.png` are identical copies of the selected white quota icon. Only the header loads this asset. The macOS template rendering adapts its foreground to light and dark appearances.

The rename passed 140 Swift tests and 43 Windows unit tests (including startup-shortcut migration). Light and dark SwiftUI header renders were reviewed. The `Headroom.app` release build passed strict code-signing verification, and `Headroom-1.6.5.pkg` built successfully. The installed Mac app was verified by executable and asset hashes, with five saved accounts preserved and refreshed without errors; active Codex authentication was unchanged. Native UI inspection timed out, so visual checks used the app's SwiftUI renderer. Windows installer execution was not tested on macOS.
