/// One failure, classified.
///
/// The same complaint always arrives the same way — a refused port, a name
/// that does not resolve, a gateway with no account behind it — and folding
/// them into "failed" throws away the only part that says where to look. Each
/// value carries a stable id for reports, whether trying again could help, and
/// the short phrase a person reads.
enum FailureCode {
  connectionRefused('connection_refused', retryable: false),
  dnsFailure('dns_failure', retryable: false),
  tlsFailure('tls_failure', retryable: false),
  connectionReset('connection_reset', retryable: true),
  hostUnreachable('host_unreachable', retryable: false),
  socketError('socket_error', retryable: false),
  timeout('timeout', retryable: true),
  auth('auth', retryable: false),
  quota('quota', retryable: false),
  rateLimit('rate_limit', retryable: true),
  providerNoAccount('provider_no_account', retryable: true),
  providerUpstream('provider_upstream', retryable: true),
  httpStatus('http_status', retryable: false),
  unknown('unknown', retryable: false);

  const FailureCode(this.id, {required this.retryable});

  /// Stable, snake_case, safe to grep for in a log or paste into a report.
  final String id;

  /// Whether sending the same request again could plausibly work, as opposed
  /// to needing a different key, a topped-up balance or a fixed address.
  final bool retryable;

  @override
  String toString() => id;
}
