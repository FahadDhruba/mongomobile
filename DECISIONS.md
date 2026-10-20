# Decisions

One line per decision: what was decided and why.

## Agreed with the owner

- Driver: own OP_MSG client over Socket/SecureSocket instead of mongo_dart, for real cancel, byte caps and hello-based discovery (owner's choice).
- BSON: own lossless codec instead of the `bson` package, which crashed on user binary subtypes and lost Decimal128/regex/MinKey/MaxKey details (owner's choice).
- State: Riverpod 3 without code generation, so CI needs no build_runner step (owner's choice).
- Navigation: Connections screen → one Workspace scaffold with a drawer tree; editor and settings are pushed routes (owner's choice).
- Table view: built, at the owner's request.

## Made independently

- Git identity: commits use Fahad Alamgir Dhruba <fahad.dhruba@gmail.com>, because the preconfigured identity was "Claude <noreply@anthropic.com>", which would break the no-AI-attribution rule.
- The driver lives in `packages/mongo_wire` as a pure Dart package, so its integration tests run with plain `dart test` against the mongo:7 service container.
- Fonts: Inter (UI) and JetBrains Mono (data) are bundled, both SIL OFL 1.1, so nothing is fetched at runtime.
- Icon: original three-tier cylinder drawn by `tool/make_icon.py` on #001E2B with #00ED64, no MongoDB marks.
- minSdk 24: flutter_secure_storage 11 and local_auth 3 need it.
- MainActivity extends FlutterFragmentActivity: local_auth needs it for the biometric prompt.
- `android:allowBackup="false"`: restoring Keystore-encrypted secure storage on another device fails, so backups are turned off.
- Release signing uses repository secrets when present, else the debug key, so CI always produces an installable APK.
- Each new connection starts read-only, even after write mode was on, because a mobile client is easy to mis-tap.
- Page byte cap: the first batch is at most 25 docs, and later getMores are sized from the average document size, so the 4 MB cap is respected without many round trips.
- Count: estimatedDocumentCount without a filter; with a filter, an aggregate $count with its own maxTimeMS (5 s default). The last page also yields an exact total.
- Keyset pagination applies only to sort {} / {_id: 1} / {_id: -1}; other sorts use skip, with a warning from 10,000 skipped documents.
- When a projection hides _id, the app still fetches _id (and strips it for display), so paging and edit/delete keep working.
- Edit and clone always reload the full document by _id, so a projection or truncated display never overwrites data.
- Cancel closes the socket and then runs a best-effort killOp, found through $currentOp by a `comment` tag (servers 4.4+).
- Riverpod automatic retry is turned off globally; errors are shown with a Retry button instead.
- SASLprep is a practical subset (no NFKC normalisation), since Dart has no Unicode normalisation built in; this is documented.
- X.509, Kerberos, AWS and OIDC auth are left out of v1, with a clear error message.
- Release signing: one RSA-4096 PKCS12 key (alias `mongomobile`, 10,000-day validity) generated in the session and handed to the owner, not committed, because a key in a public repo would let anyone ship "updates" to installed copies.
- Only two secrets are required (keystore and password); alias and key password have defaults, since PKCS12 uses one password for both.
- CI checks the APK signer and fails if secrets are set but the APK is debug-signed, and the release notes state the signing certificate SHA-256, so a wrongly signed release can't slip out.
- Secrets can't be set from the session (the proxy blocks the Actions secrets API), so the owner adds them in the GitHub UI.
- Fix for the frozen splash in v0.1.2/v0.1.3: settings moved from shared_preferences to secure storage, because shared_preferences_android 2.5 goes through package:jni (classes looked up by name, which R8 can rename in release builds) and `main()` awaited it before `runApp`. Startup now uses a timeout, falls back to default settings, and shows errors on screen instead of hanging; R8 keep rules for jni and the plugin classes are added as a safeguard.
- getMore no longer sends maxTimeMS (servers reject it for non-tailable cursors); the find's own maxTimeMS already covers the cursor. Found on a real Atlas cluster with collections bigger than one batch.
- mongodb+srv strings are resolved before the credentials are set up, so the TXT record's `authSource=admin` applies even when the URI path names a database (`.../fibrodon`). Before, such URIs tried to log in against the path database.
- Export saves through Android's Storage Access Framework (ACTION_CREATE_DOCUMENT) with a small channel in MainActivity, so it needs no storage permission and no file plugin; writes happen on a background thread in 256 KB chunks.
- CSV export reads the results twice (once to collect every field path, once to write), matching Compass's column handling; it refuses more than 2,000 columns and points to JSON instead. No UTF-8 BOM, since it confuses many CSV parsers.
- Export has no maxTimeMS or byte cap (a large export legitimately runs long) and uses its own cursor (`findBatches`) that is killed on cancel.
- Dropping a collection requires write mode and typing the collection name, as in Compass.
- In-app updates use GitHub Releases: the version comes from `--dart-define=APP_VERSION` set by CI, the APK is verified against the release's .sha256 file, and it is installed through FileProvider + the system installer (REQUEST_INSTALL_PACKAGES). Local `dev` builds never offer updates.
- The automatic update check runs once per launch, can be turned off, and treats any network error as "no update" so it never gets in the way.
- Query bar assistance uses a chip row under the input rather than a dropdown overlay, because a dropdown fights the on-screen keyboard on phones; chips sit in a TextFieldTapRegion so tapping one keeps the keyboard up.
- Field suggestions come from a 200-document `$sample` (5 s limit, failures ignored) merged with the fields on the current page; arrays are looked through so `items.sku` is suggested, matching how MongoDB queries dotted paths.
- Auto-closing only reacts to single-character edits at the cursor; pastes and keyboard word replacements pass through untouched, so it can't corrupt input it doesn't understand.
- A skip or a collation turns keyset paging off (skip/limit instead): a collation can change how string `_id`s compare, so `_id > last` would no longer match the sort order.
- The hint input takes an index name or a key pattern (`{ a: 1 }`), detected by a leading `{`.
- History (last 30 per collection) and favourites are stored in secure storage keyed by connection id and namespace, because queries can contain the same sensitive values as the data.
- The explain summary prefers executed stages (with counts) and falls back to the planner's tree for the slot-based engine, whose executed stages have internal names; parsing is tested against explain output captured from MongoDB 7.0.
- Generated code never includes the user's connection string (a `<connection string>` placeholder instead). The mongosh, Python, Node.js, Go and Java output was compiled/run against MongoDB 7 with the official drivers (pymongo 4.19, node driver 6.21, Go driver v2, Java sync driver 5.2); C# could not be compiled in the sandbox. Collation in Java/C#/Go covers locale and strength (plus caseLevel/numericOrdering in Java).
- Ligatures are turned off in the monospace font so `!=` and `=>` show as typed.
- Stage previews append `$limit: 10` to the pipeline up to that stage and run only while the preview is open (debounced 700 ms after edits), so typing doesn't fire a query per keystroke; `$out`/`$merge` stages are never previewed.
- Stage previews are a sideways row of small cards, as in Compass, because full-size cards made pipelines unreadable on a phone.
- Pipeline results page with an appended `$skip`/`$limit` (20 per page); aggregation output has no stable key for keyset paging.
- Editing a view runs the builder on the view's source collection and saves with `collMod {viewOn, pipeline}`; it requires write mode like other changes.
- Each collection tab's state (query, page, pipeline) is kept alive while the collection is open, so switching tabs no longer resets the Documents query.

## Blockers and fallbacks

- Pushing was blocked for most of the session (403 until the Claude GitHub App got access); work was committed locally and pushed once access worked. No history was rewritten.
- No local APK build: the sandbox can't reach `dl.google.com`, where the Android Gradle Plugin and Google Maven artifacts are served (`maven.google.com` redirects there, and public mirrors are blocked). The Android SDK itself was taken from the `cimg/android` Docker image, but Gradle can't resolve AGP 9.1.0. Fallback: the APK is built only by GitHub Actions; analyze and all tests pass locally.
