# WebFetch security review — 2026-10-18

This change carries the standalone executor from PR #14 forward onto current
`main`, with the security fixes below. The reviewed original revision was
`7a77a0ba4b62dc2029858f461a9a362de86dc14b`.

## Scope and integration

`fetchTool` is declared alongside the existing tool schemas. The current image
and deck tools keep their existing order and behavior. Enabling `fetch_url` in
the conversation loop requires a separate executor-dispatch integration; the
new schema is available for that follow-up. This PR exercises the standalone
executor directly and avoids advertising an unhandled tool to the model.

## Confirmed findings and fixes

- HTTPS used `Socket.startConnect`, which sent plaintext HTTP for an HTTPS URL
  and accepted a plaintext HTTP response in a local reproduction. HTTPS now
  uses TLS with the original URI hostname for SNI and certificate verification;
  the TCP destination is the already-validated InternetAddress.
- Dart 3.13.5's `SecureSocket.startConnect` cancellation left a TCP-connected,
  stalled TLS handshake open after the caller timed out. The connection factory
  now retains the original RawSocket through TLS negotiation and closes it on
  cancellation. A small Socket/IOSink adapter makes that owned TLS transport
  available to HttpClient using public Dart APIs. Regression tests verify peer
  EOF after timeout, TLS writes under backpressure, response reads and truncation.
- IPv6 multicast, deprecated compatible private destinations, NAT64 and
  site-local addresses passed the old address policy. Deny multicast `ff00::/8`,
  site-local `fec0::/10`, NAT64 `64:ff9b::/96` and local-use `64:ff9b:1::/48`.
  Apply the IPv4 rules to mapped, compatible and translated forms, including
  hexadecimal spellings. Native public IPv6 suffixes remain unrestricted by
  the embedded IPv4 rules. Reachability of previously accepted special ranges
  depends on the network's actual routing/translation configuration.
- Shared HttpClient injection skipped pinning and could reuse socket/auth state.
  The unused `client:` parameter is removed. Each fetch owns a fresh direct
  client with connection reuse disabled and one total deadline.
- Dart builds Basic Authorization automatically from URL userinfo. Initial and
  redirected URLs now reject userinfo before any request. Scheme checks also
  run for every redirect when a custom policy is supplied.
- DNS/policy resolution and discarded responses could outlive the deadline.
  `Stream.take(65536)` counted chunks. Unwanted bodies are cancelled immediately;
  DNS, redirects, headers and body reads share one deadline. Late policy results
  cannot start a connection after timeout.
- A 1 MiB input of repeated unclosed `<script>` tags exceeded an 8-second process
  limit. Cleanup alternatives now consume through their terminator or EOF,
  avoiding the reproduced quadratic scans. The adversarial cases complete in
  milliseconds in local tests.

## Verification

The 36 WebFetch tests cover private/public address controls, mixed DNS answers,
redirects, Host and credential isolation, proxies, whole-operation timeout,
TLS chain/hostname verification, plaintext-peer rejection, stalled handshake
cleanup, TLS backpressure, truncation and malformed HTML.

Local Dart SDK 3.13.5 analysis and these tests pass. The temporary standalone
runner adapts only the flutter_test import to package:test; production source
and test bodies are unchanged. The independent cleanup diagnostic now exits 0:

```sh
dart run tool/check_webfetch_tls_cleanup.dart
```

The repository's normal CI runs Flutter analysis and the complete Flutter suite
on the PR revision. Local Flutter initialization had previously been blocked by
automatic approval review after unexpected cloud-metadata access; that path was
stopped. Exact-revision CI results are recorded on the pull request.

## Explicit boundaries

- Known NAT64 prefixes are intentionally denied, including public IPv4 tails.
  This conservative policy limits some IPv6-only/DNS64 networks. Supporting
  translation requires a separately reviewed policy and deployment tests.
- `policy`, `lookup`, `securityContext` and global network overrides are trusted
  application configuration. Never accept them from model/tool-controlled input.
- Prefix rules cannot discover arbitrary network-specific NAT64, VPN remapping,
  or globally numbered services intentionally routed internally. The filter is
  not an exhaustive IANA registry; deployment egress controls can narrow it.
- HTML cleanup is a text reducer. Rendering and prompt-injection defense require
  their own boundaries. Real device networking and unusual translation/tunneling
  deployments remain outside these controlled local transport tests.

## Primary references

- https://api.dart.dev/dart-io/HttpClient/connectionFactory.html
- https://api.dart.dev/dart-io/RawSecureSocket/secure.html
- https://api.dart.dev/dart-io/ConnectionTask/fromSocket.html
- https://www.rfc-editor.org/rfc/rfc6052.html
- https://www.rfc-editor.org/rfc/rfc8215.html
