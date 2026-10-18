import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Retains the TCP socket throughout TLS negotiation so cancellation closes
/// even a peer which accepts TCP and never completes the TLS handshake.
Future<ConnectionTask<Socket>> startPinnedTlsConnection(
  InternetAddress address,
  Uri uri,
  SecurityContext? context,
) async {
  final tcp = await RawSocket.startConnect(address, uri.port);
  RawSocket? transport;
  RawSecureSocket? tls;
  var cancelled = false;
  void cancel() {
    cancelled = true;
    tcp.cancel();
    transport?.close();
    tls?.close();
  }

  final socket = tcp.socket.then<Socket>((raw) async {
    transport = raw;
    if (cancelled) {
      await raw.close();
      throw const SocketException('Connection attempt cancelled');
    }
    try {
      final secure = await RawSecureSocket.secure(
        raw,
        host: uri.host,
        context: context,
      );
      tls = secure;
      if (cancelled) {
        await secure.close();
        throw const SocketException('Connection attempt cancelled');
      }
      return _TlsSocket(secure);
    } catch (_) {
      await raw.close();
      rethrow;
    }
  });
  return ConnectionTask.fromSocket(socket, cancel);
}

/// Stream/IOSink adapter over public RawSecureSocket APIs. HttpClient consumes
/// Socket; retaining the raw TCP handle above gives handshake cancellation an
/// explicit owner without platform-specific handles or private SDK APIs.
class _TlsSocket extends Stream<Uint8List> implements SecureSocket {
  _TlsSocket(this._raw) {
    _input = StreamController<Uint8List>(
      sync: true,
      onPause: () => _raw.readEventsEnabled = false,
      onResume: () => _raw.readEventsEnabled = true,
      onCancel: destroy,
    );
    _sink = IOSink(_TlsWriter(this));
    // Consumers may observe done, while forced cancellation must also be safe
    // when the HttpClient is waiting on its response stream instead.
    _sink.done.ignore();
    _raw.readEventsEnabled = false;
    _raw.writeEventsEnabled = false;
    _events = _raw.listen(_onEvent, onError: _onError, onDone: destroy);
  }

  final RawSecureSocket _raw;
  late final StreamController<Uint8List> _input;
  late final IOSink _sink;
  late final StreamSubscription<RawSocketEvent> _events;
  Completer<void>? _writable;
  bool _destroyed = false;

  void _onEvent(RawSocketEvent event) {
    if (_destroyed) return;
    if (event == RawSocketEvent.read) {
      final data = _raw.read();
      if (data != null) _input.add(data);
    } else if (event == RawSocketEvent.write) {
      _raw.writeEventsEnabled = false;
      final waiter = _writable;
      _writable = null;
      waiter?.complete();
    } else if (event == RawSocketEvent.readClosed) {
      _input.close();
    } else if (event == RawSocketEvent.closed) {
      destroy();
    }
  }

  void _onError(Object error, StackTrace stack) {
    if (_destroyed) return;
    if (!_input.isClosed) _input.addError(error, stack);
    destroy();
  }

  Future<void> _write(List<int> bytes) async {
    var offset = 0;
    while (offset < bytes.length) {
      if (_destroyed) throw const SocketException('Socket closed');
      offset += _raw.write(bytes, offset, bytes.length - offset);
      if (offset < bytes.length) {
        final waiter = Completer<void>();
        _writable = waiter;
        _raw.writeEventsEnabled = true;
        await waiter.future;
      }
    }
  }

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    final subscription = _input.stream.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
    if (!_destroyed) _raw.readEventsEnabled = true;
    return subscription;
  }

  @override
  void destroy() {
    if (_destroyed) return;
    _destroyed = true;
    final waiter = _writable;
    _writable = null;
    waiter?.completeError(const SocketException('Socket closed'));
    _events.cancel();
    _raw.close();
    _input.close();
  }

  @override
  InternetAddress get address => _raw.address;
  @override
  int get port => _raw.port;
  @override
  InternetAddress get remoteAddress => _raw.remoteAddress;
  @override
  int get remotePort => _raw.remotePort;
  @override
  X509Certificate? get peerCertificate => _raw.peerCertificate;
  @override
  String? get selectedProtocol => _raw.selectedProtocol;
  @override
  bool setOption(SocketOption option, bool enabled) =>
      _raw.setOption(option, enabled);
  @override
  Uint8List getRawOption(RawSocketOption option) => _raw.getRawOption(option);
  @override
  void setRawOption(RawSocketOption option) => _raw.setRawOption(option);
  @override
  Encoding get encoding => _sink.encoding;
  @override
  set encoding(Encoding value) => _sink.encoding = value;
  @override
  void add(List<int> data) => _sink.add(data);
  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _sink.addError(error, stackTrace);
  @override
  Future<void> addStream(Stream<List<int>> stream) => _sink.addStream(stream);
  @override
  Future<void> flush() => _sink.flush();
  @override
  Future<void> close() => _sink.close();
  @override
  Future<void> get done => _sink.done;
  @override
  void write(Object? object) => _sink.write(object);
  @override
  void writeAll(Iterable<dynamic> objects, [String separator = '']) =>
      _sink.writeAll(objects, separator);
  @override
  void writeCharCode(int charCode) => _sink.writeCharCode(charCode);
  @override
  void writeln([Object? object = '']) => _sink.writeln(object);
  @override
  void renegotiate({
    bool useSessionCache = true,
    bool requestClientCertificate = false,
    bool requireClientCertificate = false,
  }) {
    throw UnsupportedError('TLS renegotiation is not supported');
  }
}

class _TlsWriter implements StreamConsumer<List<int>> {
  _TlsWriter(this.socket);
  final _TlsSocket socket;

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final bytes in stream) {
      await socket._write(bytes);
    }
  }

  @override
  Future<void> close() async {
    if (!socket._destroyed) socket._raw.shutdown(SocketDirection.send);
  }
}
