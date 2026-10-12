# fb for macOS

The native app targets Apple Silicon and macOS 26 or later. SwiftUI hosts the
existing web interface in WebKit. The Go rendering engine is linked into the
app as a C archive; the app does not launch an HTTP server or use localhost.
Pandoc 3.12.1 is bundled as a private converter executable. End users need
neither Homebrew nor a separate Pandoc installation.

## Build locally

The developer machine needs Xcode, XcodeGen 2.44 or later, and the Go version
specified by the repository's `go.mod`. From the repository root:

```sh
macos/Scripts/build.sh
open macos/.build/xcode/Build/Products/Debug/fb.app
```

The script downloads the pinned official Pandoc ZIP into the ignored `.build`
directory and verifies its SHA-256, signature, architecture, version, and library
dependencies. It builds the Go archive, generates `FB.xcodeproj`, and builds the
Swift app. `project.yml` is the source of truth; do not commit the generated
project. The initial download requires a network connection; ordinary use of
local content does not.

Local builds select the first available Apple Development identity, falling
back to an ad-hoc signature. Override with `FB_SIGN_IDENTITY='…'`, or use
`FB_SIGN_IDENTITY=-` for an explicit ad-hoc build. These signatures are for local
development and do not establish a notarized public download. The app enables
the hardened runtime and is not sandboxed in this direct-download version.

```sh
CONFIGURATION=Release macos/Scripts/build.sh
```

Additional arguments are forwarded to `xcodebuild`. The generated project can
be opened in Xcode after the first script build; the Go archive must be rebuilt
with the script when Go sources change.

## Redeploy locally

"Redeploy" means build the latest source and install the resulting app to
`~/Applications/fb.app`:

```sh
macos/Scripts/deploy.sh
```

This runs an incremental Release build, stages and verifies the complete bundle,
then replaces the installed copy with rollback on failure. Only a running app
at that installed path is asked to quit; it reopens after installation. Running
Debug copies are left alone. The source revision appears in About fb; builds
from an uncommitted working tree carry a `-dirty` suffix. Commit before deploying
when the installed app should identify a clean revision. The build script also
accepts an explicit `FB_BUILD_REVISION` override.

Local redeployment uses the available development signature. Developer ID
distribution signing and notarization remain pending until cloud signing or a
local Developer ID identity is available; deploying does not contact those
services or publish the app.

## Opening files and folders

Use File → Open (⌘O), Finder's Open With, or drop files and folders directly
onto the document view. The first dropped item opens in the current window;
additional items open in separate windows. These actions use the original
filesystem URLs and never upload or copy the dropped documents. Conversion
caches may use temporary files. Browsing and SQL queries remain read-only.

The toolbar and menus provide Back/Forward, Reload, Reveal in Finder, Find
(⌘F), zoom, and Save a Copy (⇧⌘S). External links open in the default browser.
Save a Copy writes only to a destination explicitly selected in the save panel.
The most recent filesystem location is remembered across launches.

This direct-download build uses the current user's filesystem permissions and
normal macOS privacy prompts. It is not a sandboxed Mac App Store build. Git
annotations are optional and omitted when Git/developer tools are unavailable;
ordinary document viewing does not require them.

## Verification

```sh
go test ./...
go test -race -tags fbmac ./...
go vet -tags fbmac ./...
macos/Scripts/smoke-test.sh
```

The last command needs a logged-in graphical Mac session and Python 3. It
creates disposable fixtures under `.build/smoke`, compiles the actual Swift/Go
bridge, and exercises WebKit loading, Pandoc, math, relative resources, native
file/folder pasteboard URLs, SQL form submission and script requests, archive
members, HTML script sandboxing, audio metadata, and PDF navigation. A temporary
window is required because WebKit defers media loading for unattached views.

## Signing and packaging

The intended public channels are a notarized GitHub Release download and
`brew install --cask xoba/tap/fb`. The cask is not published yet. See
[Distribution.md](Distribution.md) for the concrete release workflow and
legacy-server migration. Local redeployment is separate from publication.

Packaging requires an installed **Developer ID Application** certificate with
its matching private key. It does not create certificates or change the Apple
developer account. App Store Connect credentials are not required for a direct
download. With an existing identity:

```sh
DEVELOPER_ID_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
  macos/Scripts/package.sh
```

This builds Release, signs Pandoc before signing the containing app, verifies
the signatures, and writes a ZIP and checksum under `.build/distribution`.
The file is explicitly named `signed` until notarization succeeds.

To submit to Apple's notarization service using credentials you have already
stored in Keychain, supply the profile name:

```sh
DEVELOPER_ID_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
NOTARY_PROFILE='your-existing-profile' macos/Scripts/package.sh
```

The script submits the ZIP, waits for acceptance, staples and validates the
ticket, checks Gatekeeper, and emits a separate `notarized` ZIP. It never
submits without `NOTARY_PROFILE` and does not publish or upload a release.

### Cloud Developer ID signing

If the Mac has no local Developer ID private key, Xcode's archive/export workflow
can use Apple's cloud-managed Developer ID certificate. This is separate from
the `codesign`-based packaging script above. Sign into Xcode > Settings >
Accounts with the Account Holder, or an account granted cloud Developer ID
access. The script can also authenticate with an existing team API key that has
the required cloud Developer ID permission; successful iOS signing alone does
not prove that permission.

After a local build has prepared the Go archive, Pandoc, and generated project,
create a development-signed archive locally:

```sh
xcodebuild archive -project macos/FB.xcodeproj -scheme FB \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath macos/.build/xcode -archivePath macos/.build/FB.xcarchive \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY='Apple Development' \
  DEVELOPMENT_TEAM=3288VRMQE7
```

Then export using the account already signed into Xcode:

```sh
macos/Scripts/export-cloud.sh --xcode-account macos/.build/FB.xcarchive
```

This mode does not require, read, or pass API key settings. As an alternative,
use an existing team API key that is authorized for cloud Developer ID signing:

```sh
ASC_RELEASE_KEY_PATH=/absolute/path/to/AuthKey_6B7NTN43DS.p8 \
  macos/Scripts/export-cloud.sh --api-key macos/.build/FB.xcarchive
```

Key ID, issuer, and team can be overridden; see `--help`. This invokes
`xcodebuild -exportArchive` with `method=developer-id`, `destination=export`, and
automatic distribution signing. Running it contacts Apple and can create
managed certificates/profiles. It does not publish the app or upload it to App
Store Connect. Xcode 27 permits automatic export from a manually signed archive;
the installed `xcodebuild -help` documents these options.

The script verifies the app **and the bundled Pandoc executable** have the
expected team's Developer ID signatures, hardened runtime, and secure
timestamps. It produces a signed ZIP, with notarization still a separate step.
An Apple permission error is preserved in the export log without retries that
change the account or credentials. See Apple's [cloud-managed certificates
guide](https://developer.apple.com/help/account/certificates/cloud-managed-certificates/)
and [macOS distribution-signing
workflow](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac/).

Before public distribution, assemble and publish the complete corresponding
Pandoc source and required component notices alongside the app; see
[`Dependencies/NOTICE.md`](Dependencies/NOTICE.md). The app includes its pinned
binary provenance and Pandoc GPL license, while `package.sh` copies those
notices next to the archive. It does not assemble a complete dependency source
distribution.

## Updating Pandoc

Update `Dependencies/pandoc.json` deliberately, including the asset digest from
the official GitHub release API. Update the corresponding notices and source
materials at the same time. Then rebuild and exercise the Markdown/document
viewers. Never substitute a Homebrew executable: it can link libraries outside
the bundle.

The initially verified 3.12.1 arm64 binary is about 192 MB uncompressed and links
only macOS system libraries. Its official download is about 42 MB. The binary
includes Pandoc's data files; it does not include TeX or user-provided filters.
