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
