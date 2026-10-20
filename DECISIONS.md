# Decisions

One line per decision: what was decided and why.

## Agreed with the owner

- Driver: own OP_MSG client over Socket/SecureSocket instead of mongo_dart, for real cancel, byte caps and hello-based discovery (owner's choice).
- BSON: own lossless codec instead of the `bson` package, which crashed on user binary subtypes and lost Decimal128/regex/MinKey/MaxKey details (owner's choice).
- State: Riverpod 3 without code generation, so CI needs no build_runner step (owner's choice).
- Navigation: Connections screen → one Workspace scaffold with a drawer tree; editor and settings are pushed routes (owner's choice).
- Table view: built, at the owner's request.

## Made independently

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
- Release signing: one RSA-4096 PKCS12 key (alias `mongomobile`, 10,000-day validity) kept by the maintainer and never committed, because a key in a public repo would let anyone ship "updates" to installed copies.
- Only two secrets are required (keystore and password); alias and key password have defaults, since PKCS12 uses one password for both.
- CI checks the APK signer and fails if secrets are set but the APK is debug-signed, and the release notes state the signing certificate SHA-256, so a wrongly signed release can't slip out.
- The signing key reaches CI only as repository secrets (`ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`), which forks and pull requests from forks never see.
- Fix for the frozen splash in v0.1.2/v0.1.3: settings moved from shared_preferences to secure storage, because shared_preferences_android 2.5 goes through package:jni (classes looked up by name, which R8 can rename in release builds) and `main()` awaited it before `runApp`. Startup now uses a timeout, falls back to default settings, and shows errors on screen instead of hanging; R8 keep rules for jni and the plugin classes are added as a safeguard.
- getMore no longer sends maxTimeMS (servers reject it for non-tailable cursors); the find's own maxTimeMS already covers the cursor. Found on a real Atlas cluster with collections bigger than one batch.
- mongodb+srv strings are resolved before the credentials are set up, so the TXT record's `authSource=admin` applies even when the URI path names a database (`.../mydb`). Before, such URIs tried to log in against the path database.
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
- Generated code never includes the user's connection string (a `<connection string>` placeholder instead). The mongosh, Python, Node.js, Go and Java output was compiled/run against MongoDB 7 with the official drivers (pymongo 4.19, node driver 6.21, Go driver v2, Java sync driver 5.2); The C# output has not been compiled. Collation in Java/C#/Go covers locale and strength (plus caseLevel/numericOrdering in Java).
- Ligatures are turned off in the monospace font so `!=` and `=>` show as typed.
- Stage previews append `$limit: 10` to the pipeline up to that stage and run only while the preview is open (debounced 700 ms after edits), so typing doesn't fire a query per keystroke; `$out`/`$merge` stages are never previewed.
- Stage previews are a sideways row of small cards, as in Compass, because full-size cards made pipelines unreadable on a phone.
- Pipeline results page with an appended `$skip`/`$limit` (20 per page); aggregation output has no stable key for keyset paging.
- Editing a view runs the builder on the view's source collection and saves with `collMod {viewOn, pipeline}`; it requires write mode like other changes.
- Each collection tab's state (query, page, pipeline) is kept alive while the collection is open, so switching tabs no longer resets the Documents query.
- The field editor works on a tree of typed text (`FieldNode`) and converts to BSON only on save or on switching to JSON, so half-typed values never lose their type; binary, regex, timestamp and other rare types are shown read-only and kept as they are.
- Inline table edits fetch the full document first (the page may be projected) and write one top-level field with `$set`/`$unset`; dotted or `$` field names are left to the document editor, since `$set` would read them as paths.
- Bulk update previews are simulated on the phone for `$set`, `$unset`, `$inc`, `$mul`, `$rename`, `$currentDate`, `$push`/`$addToSet` (with `$each`), `$pull` (plain values) and `$pop`, applying paths in lexicographic order like MongoDB 5+; the simulator is checked field-for-field against a real mongo:7. Anything else (`$min`, positional paths, `$pull` conditions) says "no preview" and still runs on the server. Pipeline updates are previewed by running the stages in an aggregation on the sample. Compass previews inside an aborted transaction instead, which needs a replica set.
- Bulk update/delete use only the query's filter (not skip, limit, sort or collation), as Compass does, and show the exact match count before asking.
- Import reads the picked file through a new `ACTION_OPEN_DOCUMENT` channel in 256 KB chunks, so files larger than memory work; JSON is split into documents by a bracket-counting scanner (which handles strings and both quote styles) before each is parsed.
- Import inserts unordered batches of 1,000 by default, so one bad document doesn't stop the rest; "Stop on the first error" switches to ordered inserts and still inserts the documents read before the bad one, like `mongoimport --stopOnError`. Only the first 50 errors are kept for display.
- CSV column types are guessed from the first 64 KB (ObjectId, Boolean, Int32, Int64, Double, Date, JSON, else String) and can be changed per column; empty cells are left out by default. Headers like `items[0].sku` rebuild arrays, so a CSV export imports back to the same documents (tested).
- Create database and Create collection share one screen: MongoDB has no "create database" command, so a database is created with its first collection, as in Compass. Capped, time series and clustered are mutually exclusive choices (chips), matching what the server allows; option shapes were checked against mongo:7.
- Drop database requires typing its name, and `admin`, `local` and `config` are never offered, since dropping them can break the deployment.
- Rename is offered for collections only; the server can't rename views.
- The Schema tab samples with `$sample` after the Documents tab's filter (Compass also analyses the current query), up to 5,000 documents and 64 MB, and runs only when you tap Analyze. Value summaries look at up to 500 values per type to keep memory flat.
- Field and type percentages count documents that have the field, so nested fields are relative to their parent documents, as in Compass.
- The Validation tab finds its sample documents with the rules themselves as the filter (passes) and `{$nor: [rules]}` (fails), which is how Compass does it; generated `$jsonSchema` rules mark fields present in every sampled document as required, and were checked on mongo:7 (sample accepted, wrong types and missing fields rejected).
- The tab bar scrolls (five tabs don't fit a phone's width); Schema and Validation keep their state when you switch tabs.
- Index usage comes from `$indexStats` (counts since the server or the index started); builds in progress come from `$currentOp` matched on `createIndexes` for the collection, polled every 2 s only while a build runs. Both quietly show nothing when the user lacks the privilege, rather than an error.
- Hiding an index uses `collMod {index: {name, hidden}}` and asks first; the `_id_` index can't be hidden or dropped.
- Server activity rates use the server's own `localTime` between `serverStatus` samples, so slow replies over mobile networks don't distort them; counters that go backwards (a restart) count as zero. Two minutes (60 samples) are kept, and polling pauses on request and stops when the screen closes.
- The operations list leaves out the app's own `$currentOp` and, unless asked, system and idle operations; Kill (`killOp`) needs write mode and a confirmation, since it can leave a write half done.
- Slow queries read the latest 50 `system.profile` entries of a chosen database; changing the profiler level needs write mode. Atlas shared tiers don't allow the profiler, which shows as the server's error.
- The connection form edits the same connection string the string field shows, so both stay in step and saving keeps one source of truth; options without a field are listed and written back unchanged.
- Connection export uses Compass's "Compass Connections" v1 JSON so files work in both apps. Compass's own encrypted passwords use a scheme I could not match safely, so imports from Compass come in without passwords (the app says how many need one). MongoMobile's passwords go in a separate `mongomobile` section, encrypted with AES-256-GCM and a PBKDF2-SHA256 key (200,000 rounds, run off the UI thread); there is deliberately no plain-text option.
- Importing merges by connection id: the same file imported twice updates rather than duplicates.
- Favourites come first, then groups alphabetically, then everything else by last use. A group is a free-text name on the connection, not a separate object, so empty groups simply disappear.
- The shell is an interpreter for mongosh's MongoDB methods, not a JavaScript runtime: running real mongosh would need a JS engine with native libraries, adding size and a second language runtime for little gain on a phone. Arguments use the app's shell-syntax Extended JSON parser; unsupported input gets a clear "not JavaScript" message and `db.runCommand` covers anything else. Every command in its help was run against mongo:7 in a test.
- Shell writes follow write mode, including commands sent through `db.runCommand` (insert, update, delete, drop, create, collMod, user and profile changes, `$out`/`$merge`), so read-only means read-only everywhere.
- Shell history is kept per connection for as long as the app runs, not saved, since commands can contain sensitive values.
- Tunnels work by local port forwarding: the driver connects to a loopback port that the tunnel copies to the real host, and TLS is started over that socket with the real host name (`SecureSocket.secure`), so certificate checks are the same as without a tunnel. One forward is opened per server, so replica sets work through a tunnel. SOCKS5 is implemented in the driver (no dependency); SSH uses dartssh2 (pure Dart) in the app, keeping the driver free of SSH code.
- SSH host keys are trusted on first use and pinned in the connection; a changed key stops the connection with an explanation and a "Forget" button, the way `ssh` does with known_hosts.
- X.509 takes one PEM with the certificate and key (like `tlsCertificateKeyFile`), optionally with a key password; it was tested against a TLS-only mongod with a test CA, including through a tunnel.
- AWS IAM follows the MONGODB-AWS spec with credentials from the connection (access key as user, secret as password, `AWS_SESSION_TOKEN` property); the phone has no instance metadata or environment to fetch credentials from. The SigV4 signing was checked against AWS's documented signing-key example and botocore's signatures for the same request, and the SASL exchange against a fake server; no real Atlas IAM user was available to test with.
- OIDC uses the authorization code flow with PKCE in the system browser, redirecting to `http://localhost:27097/redirect` (Compass's registered redirect, so identity providers set up for Compass work). The token is shared by the client's connections so the user signs in once, and a pasted access token skips the browser. The flow was tested against a fake identity provider and the SASL exchange against a fake server; there was no Enterprise server with an IdP to test end to end.
- Kerberos (GSSAPI) is left out: it needs a Kerberos/GSS-API library, which Android doesn't ship, and a pure-Dart Kerberos client is a project of its own. Connection strings asking for it get a clear error.
- Exported connections keep tunnel host, port, user and host key in the clear and put tunnel passwords, keys and client certificates only in the passphrase-encrypted part.
- Several connections stay open at once: each runs in its own Riverpod `ProviderScope` and nested `Navigator`, so a connection's queries, pipelines, tabs and the screens it opened can't mix with another's, even for the same database and collection names. Providers that read the connection declare their dependencies, which Riverpod checks at runtime (a test caught the one that didn't).
- Open collections stay built as tabs in an `IndexedStack` (at most 8; the oldest closes), so switching keeps each query, page and pipeline. Renaming or dropping a collection or database updates its tabs.
- In-use encryption is client-side field level encryption (FLE1, AEAD_AES_256_CBC_HMAC_SHA_512) written in Dart: libmongocrypt is a native library with no Dart binding for Android. It was checked both ways against libmongocrypt 1.21 (pymongo): every type it encrypts decrypts here, deterministic encryption here gives libmongocrypt's exact bytes, and values encrypted here decrypt in pymongo.
- Decryption is for what the app shows and edits; saving re-encrypts exactly the fields that were encrypted (same data key and algorithm), so plaintext never goes back to the server. New fields are not encrypted automatically, since that needs the server's schema rules and query analysis (mongocryptd or crypt_shared, which don't run on Android).
- Master keys: local (96-byte key) and AWS KMS (SigV4-signed `Decrypt`, untested against real AWS). Azure, GCP and KMIP keys say they aren't supported. Queryable Encryption values are recognised and shown as stored, not decrypted: their stored format needs server-derived tokens to read.
- Atlas shared and Flex tiers refuse `$currentOp` with `allUsers` and the `profile` command. The app then lists the user's own operations (with a note saying so) and explains that the profiler isn't available, pointing to Atlas's Query Profiler, instead of showing the raw error. `admin`, `local` and `config` are left out of the profiler's database list. The same fallback applies to index build progress and the shell's `db.currentOp()`.
- Licensed under Apache-2.0: permissive, with an explicit patent grant, and it does not grant use of the project name.

## Known limits

- The release APK is built by CI. Building one locally needs the Android SDK and access to Google's Maven repository, as for any Android project.
