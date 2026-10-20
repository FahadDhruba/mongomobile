# Security policy

## Reporting a vulnerability

Please report vulnerabilities privately. Do not open a public issue.

On GitHub, open the **Security** tab of this repository and choose
**Report a vulnerability** (private vulnerability reporting). Include what
you found, how to reproduce it, and the app version.

## Supported versions

Only the latest release is supported. Please check that the problem exists
in the latest release before reporting it.

## What the app stores and where it connects

- Saved connections, including passwords, SSH keys and client certificates,
  are kept in Android secure storage. Query history and favourites are
  stored encrypted on the device.
- There is no telemetry and no analytics.
- The app connects only to the servers you configure (including any SSH
  tunnel or SOCKS5 proxy, and the identity provider or AWS KMS endpoint if
  you use OIDC or in-use encryption).
- `mongodb+srv://` lookups use DNS-over-HTTPS (Google, then Cloudflare)
  because Android apps cannot query SRV records directly. Those requests
  contain the cluster's host name.
- The update check asks GitHub Releases for the latest version and downloads
  the APK from there. It can be turned off in Settings.
