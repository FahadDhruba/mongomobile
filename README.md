# MongoMobile

A serverless MongoDB client for Android, built with Flutter. It talks to
your database directly from the phone over the MongoDB wire protocol, with
no backend in between, and looks and feels like MongoDB Compass.

MongoMobile is an independent project and is not affiliated with or
endorsed by MongoDB, Inc. "MongoDB" is a trademark of MongoDB, Inc.

<p>
  <img src="docs/screenshots/02-connections.png" width="200" alt="Saved connections">
  <img src="docs/screenshots/05-drawer.png" width="200" alt="Database and collection drawer">
  <img src="docs/screenshots/07-documents-expanded.png" width="200" alt="Documents as cards">
  <img src="docs/screenshots/09-json-view.png" width="200" alt="JSON view">
  <img src="docs/screenshots/09b-table-view.png" width="200" alt="Table view">
</p>

## Install the APK

1. On your Android phone (Android 7.0 or newer), open the
   [latest release](https://github.com/FahadDhruba/mongomobile/releases/latest).
2. Under **Assets**, tap `mongomobile-0.1.N.apk` to download it.
3. Open the downloaded file. If Android asks, allow your browser or file
   manager to **install unknown apps** (Settings → Apps → Special app access
   → Install unknown apps), then go back and tap **Install**.
4. Open **MongoMobile** and tap **New connection**.

Each release also has a `.sha256` file if you want to check the download:
`sha256sum -c mongomobile-0.1.N.apk.sha256`.

**Updating:** unless the repository has release signing set up (see
[Signing](#release-signing)), each build is signed with a different debug
key. Android then refuses to install a new version over an old one, so
uninstall the old version first. Saved connections are removed with it.

**Atlas and other hosted clusters:** add your phone's IP address (or
`0.0.0.0/0` while testing) to the cluster's network access list.

## Features

- **Connections:** any number of saved connections, stored encrypted in
  Android secure storage. `mongodb://` and `mongodb+srv://` strings, TLS
  (with an optional custom CA or "allow invalid certificates"),
  SCRAM-SHA-256, SCRAM-SHA-1 and PLAIN. A **Test connection** button
  reports the server version, topology and round trip. Optional biometric
  lock.
- **Browsing:** a drawer with the connection, then databases and their
  collections with document counts and sizes, plus search. Database and
  server overviews.
- **Documents:** Compass-style cards with `field: value` lines in a
  monospace font, colours per type (string, number, boolean, date,
  ObjectId, null and others), and nested objects and arrays that expand in
  place. A JSON view with syntax colouring, and a Table view with one
  column per field (tap a cell for its full value). Long strings, big arrays and
  wide documents are cut with **show more** controls.
- **Query bar:** Filter, Project, Sort and Limit in a monospace font with a
  green **Find** button and **Reset**. Accepts Extended JSON and shell
  syntax such as `{ _id: ObjectId('…'), createdAt: { $gt: ISODate('2024-01-01') } }`.
- **Pagination built for big collections:** pages of 10, 25, 50 or 100
  with a label like `1 – 25 of ~2.4M` and previous/next buttons. Only the
  current page is kept in memory.
  - Sorting by `_id` (the default) uses keyset pagination
    (`_id > last` / `_id < first`), so page 10,000 is as fast as page 1.
  - Other sorts use skip and limit, with a warning past 10,000 skipped
    documents.
  - The total is `estimatedDocumentCount` without a filter. With a filter,
    an exact count runs in the background with its own time limit and shows
    "count unavailable" if it takes too long. The list never waits for it.
  - Every query has a `maxTimeMS` (10 s by default, configurable) and a
    **Cancel** button that closes the socket and asks the server to kill the
    operation.
  - Each page stops reading at a size cap (4 MB by default).
- **Editing:** a JSON editor with live validation for insert (one document
  or an array), edit and clone; delete asks for confirmation. Extended JSON
  types (ObjectId, Date, Int64, Decimal128, Binary, UUID, Timestamp, regex
  and more) survive a round trip unchanged.
- **Indexes:** list with sizes and flags (unique, sparse, TTL, partial,
  hidden, text, geo), create and drop.
- **Safety:** every connection opens in read-only mode; writes need an
  explicit switch to write mode.
- Dark theme by default, plus a light theme. Bundled Inter and JetBrains
  Mono fonts.

## How it works

There is no server component. The app contains its own MongoDB driver,
[`packages/mongo_wire`](packages/mongo_wire), written in Dart:

- OP_MSG over `Socket` / `SecureSocket`, with a small connection pool.
- A lossless BSON codec: every BSON type, including user-defined binary
  subtypes, MinKey/MaxKey and Decimal128, decodes and re-encodes byte for
  byte.
- An Extended JSON v2 reader and writer that also reads mongosh syntax.
- SCRAM-SHA-256 / SCRAM-SHA-1 authentication.
- `mongodb+srv` SRV and TXT lookups over DNS-over-HTTPS (Google, then
  Cloudflare), since Android apps can't query SRV records directly.
- Primary discovery from `hello` replies, with `directConnection` and
  `readPreference` support for connecting to secondaries.

The app talks to the driver through the `MongoClient` interface, so another
transport can be added without touching the UI. State is managed with
Riverpod.

```
lib/
  models/      connection profiles and settings
  services/    secure storage, preferences, biometrics
  state/       Riverpod providers and the paging controller
  theme/       colours, fonts and shared buttons
  ui/          screens and widgets
packages/mongo_wire/
  lib/src/bson/    BSON types and codec
  lib/src/ejson/   Extended JSON reader and writer
  lib/src/wire/    connection, OP_MSG, SCRAM, SRV, discovery, pool
```

## Development

Requirements: Flutter 3.47 (stable), JDK 17, and the Android SDK for APK
builds.

```sh
flutter pub get
(cd packages/mongo_wire && dart pub get)
flutter analyze
flutter test                         # app unit and widget tests
cd packages/mongo_wire && dart test  # driver unit tests
```

The driver's integration tests run against a real server when `MONGO_URI`
is set:

```sh
docker run -d --name mongo7 -p 27017:27017 \
  -e MONGO_INITDB_ROOT_USERNAME=root -e MONGO_INITDB_ROOT_PASSWORD=secret mongo:7
cd packages/mongo_wire
MONGO_URI='mongodb://root:secret@localhost:27017/?authSource=admin' dart test
```

To review the screens, the widget test can save screenshots:
`SCREENSHOT_DIR=/tmp/shots flutter test test/screens_test.dart`.

Build a release APK with `flutter build apk --release`.

The app icon is drawn by `tool/make_icon.py` (needs Pillow):
`python3 tool/make_icon.py .`

## CI

`.github/workflows/ci.yml` runs on every push and pull request:
`flutter analyze`, the driver tests (including integration tests against a
`mongo:7` service container), the app tests, then
`flutter build apk --release`. The APK is uploaded as a workflow artifact,
and pushes to `main` publish it as a GitHub Release tagged
`v0.1.<run number>`.

### Release signing

Without secrets the APK is signed with the runner's debug key. To sign
releases with your own key (so updates install over older versions), create
a keystore once:

```sh
keytool -genkey -v -keystore release.jks -keyalg RSA -keysize 2048 \
  -validity 10000 -alias mongomobile
base64 -w0 release.jks   # copy the output
```

Then add these repository secrets (Settings → Secrets and variables →
Actions): `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`,
`ANDROID_KEY_ALIAS` and `ANDROID_KEY_PASSWORD`.

## Licences

The app bundles [Inter](https://github.com/rsms/inter) and
[JetBrains Mono](https://github.com/JetBrains/JetBrainsMono), both under the
SIL Open Font License 1.1 (see `assets/fonts/`).
