# Contributing

Thanks for helping. Bug reports, fixes and small features are all welcome.
For anything large, open an issue first so we can agree on the approach.

## Build and test

You need Flutter 3.47.7 (the version CI uses), JDK 17, and the Android SDK
if you want to build an APK.

```sh
flutter pub get
(cd packages/mongo_wire && dart pub get)
flutter analyze
flutter test
cd packages/mongo_wire && dart test
```

`dart test` in `packages/mongo_wire` runs the driver's unit tests. Its
integration tests need a real server and are skipped unless `MONGO_URI` is
set. To run them against a local MongoDB:

```sh
docker run -d --name mongo7 -p 27017:27017 \
  -e MONGO_INITDB_ROOT_USERNAME=root -e MONGO_INITDB_ROOT_PASSWORD=secret mongo:7
cd packages/mongo_wire
MONGO_URI='mongodb://root:secret@localhost:27017/?authSource=admin' dart test
```

Some tests run only when their environment variables are set:

- `MONGO_URI`: driver integration tests, tunnel tests, and the app's update
  preview server test.
- `MONGO_TLS_URI` and `MONGO_TLS_CERTS`: X.509 and TLS tests against a
  TLS-only `mongod`.
- `SSH_TEST` (plus `SSH_TEST_USER`, `SSH_TEST_PASSWORD`, `SSH_TEST_KEY`,
  `SSH_TEST_PASSPHRASE`): SSH tunnel tests against an SSH server.

You do not need these for a normal pull request; CI runs the `MONGO_URI`
tests against `mongo:7`.

## Expectations

- Run `dart format` on the Dart files you change.
- `flutter analyze` must report no issues.
- Add or update tests for behaviour changes.
- Keep commits small and focused, with plain messages.
- Open pull requests against `main`.
- [DECISIONS.md](DECISIONS.md) records design decisions, one line each. If
  you make a significant new decision, add a line there.

## CI

CI analyses, tests and builds an APK for every pull request. Pull request
builds are signed with a throwaway debug key. Release signing secrets are
never available to forks.

By contributing you agree that your work is licensed under the
[Apache License 2.0](LICENSE). Please follow the
[Code of Conduct](CODE_OF_CONDUCT.md), and report security problems as
described in [SECURITY.md](SECURITY.md).
