import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:imagyn/core/failure.dart';
import 'package:imagyn/core/studio.dart';

RequestOptions options() => RequestOptions(path: '/v1/images/generations');

void main() {
  test('a refusal is named instead of leaving an empty message', () {
    final failure = DioException(
      requestOptions: options(),
      type: DioExceptionType.connectionError,
      error: SocketException(
        'Connection refused',
        osError: const OSError('Connection refused', 111),
      ),
    );
    final detail = errorDetailOf(failure);
    expect(detail, contains('connection_refused'));
    expect(detail, isNot(isEmpty));
  });

  test('a timeout is a different code, and both carry the elapsed time', () {
    final refused = DioException(
      requestOptions: options(),
      error: SocketException(
        'Connection refused',
        osError: const OSError('Connection refused', 111),
      ),
    );
    final timedOut = DioException(
      requestOptions: options(),
      type: DioExceptionType.connectionTimeout,
    );
    expect(
      errorDetailOf(refused, elapsed: const Duration(milliseconds: 8)),
      allOf(contains('connection_refused'), contains('8 ms')),
    );
    expect(
      errorDetailOf(timedOut, elapsed: const Duration(milliseconds: 15000)),
      allOf(contains('timeout'), contains('15000 ms')),
    );
    // A closed port is not worth repeating; a deadline is.
    expect(FailureCode.connectionRefused.retryable, isFalse);
    expect(FailureCode.timeout.retryable, isTrue);
  });

  test('a gateway sentence becomes a business code of its own', () {
    expect(
      providerCodeOf(503, '{"error":"No available compatible accounts"}'),
      FailureCode.providerNoAccount,
    );
    expect(providerCodeOf(503, 'service busy'), FailureCode.providerUpstream);
    expect(providerCodeOf(401, 'nope'), FailureCode.auth);
    expect(providerCodeOf(429, 'slow down'), FailureCode.rateLimit);
    expect(providerCodeOf(502, 'bad gateway'), FailureCode.providerUpstream);
    expect(providerCodeOf(200, 'fine'), isNull);
  });

  test('the gateway request id and retry hint travel with the failure', () {
    final response = Response<dynamic>(
      requestOptions: options(),
      statusCode: 503,
      data: 'No available compatible accounts',
      headers: Headers.fromMap({
        'x-request-id': ['abc123'],
      }),
    );
    final detail = errorDetailOf(
      DioException(
        requestOptions: options(),
        response: response,
        type: DioExceptionType.badResponse,
      ),
    );
    expect(detail, contains('provider_no_account'));
    expect(detail, contains('retryable'));
    expect(detail, contains('HTTP 503'));
    expect(detail, contains('req abc123'));
  });

  test('a gateway can veto a retry that the code would have allowed', () {
    final response = Response<dynamic>(
      requestOptions: options(),
      statusCode: 503,
      data: 'No available compatible accounts',
      headers: Headers.fromMap({
        'x-should-retry': ['false'],
      }),
    );
    final detail = errorDetailOf(
      DioException(
        requestOptions: options(),
        response: response,
        type: DioExceptionType.badResponse,
      ),
    );
    expect(detail, contains('provider_no_account'));
    expect(detail, isNot(contains('retryable')));
  });
}
