import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:zkfinger10/finger_status.dart';
import 'package:zkfinger10/finger_status_type.dart';
import 'package:zkfinger10/zk_finger.dart';

/// Ready-made glue between the ZK finger device (used as a pure scanner)
/// and your backend.
///
/// Flow:
///   1. [connect]  - opens the USB sensor
///   2. [start]    - `ZkFinger.startScanner()` + listens to `statusChangeStream`
///   3. finger press -> `FINGER_EXTRACTED` -> debounced -> POST template
///      to [scanUrl] -> response forwarded to [onResult]
///
/// The device does NOT identify/enroll locally in scanner mode. It only
/// produces a Base64 template (ZK "JQSS21" format, ~2049 bytes) per press.
/// Your backend stores/matches it.
///
/// NOTE: ZK templates can only be matched by ZK's algorithm. If your backend
/// cannot run a ZK-compatible matcher, use the hybrid flow instead:
/// backend stores templates -> app pulls them with
/// `ZkFinger.clearAndLoadDatabase()` -> device matches locally.
class FingerScannerClient {
  FingerScannerClient({
    required this.scanUrl,
    this.purpose = 'identify',
    this.debounce = const Duration(milliseconds: 1200),
    this.deviceName,
    this.extraBody = const {},
    Dio? dio,
    void Function(FingerScanResult result)? onResult,
    this.onError,
  })  : _dio = dio ?? Dio(),
        _onResult = onResult;

  /// Backend endpoint that receives every scan, e.g.
  /// `https://api.example.com/api/fingerprints/scan`.
  final String scanUrl;

  /// Sent to the backend so it knows what to do with the template:
  /// `'identify'` (default) or `'enroll'`.
  final String purpose;

  /// Minimum time between two HTTP calls. Holding a finger on the sensor
  /// produces several `FINGER_EXTRACTED` events - this collapses them into one.
  final Duration debounce;

  /// Optional label for the scanning terminal (e.g. 'gate-1').
  final String? deviceName;

  /// Extra fields merged into the POST body (e.g. location, token-based ids).
  final Map<String, dynamic> extraBody;

  final Dio _dio;
  final void Function(FingerScanResult result)? _onResult;
  final void Function(Object error)? onError;

  StreamSubscription? _statusSub;
  DateTime _lastSent = DateTime.fromMillisecondsSinceEpoch(0);
  bool _busy = false;

  /// Latest raw status from the device (useful for UI indicators).
  final StreamController<FingerStatus> _statusController =
      StreamController.broadcast();
  Stream<FingerStatus> get statusStream => _statusController.stream;

  /// Connect (and ask USB permission for) the sensor.
  Future<bool?> connect() => ZkFinger.openConnection();

  /// Start scanner mode. Every finger press now posts one template.
  Future<bool?> start({String? userId}) {
    _statusSub ??= ZkFinger.statusChangeStream.receiveBroadcastStream().listen(
          _onStatus,
          onError: onError,
        );
    return ZkFinger.startScanner(userId: userId);
  }

  /// Stop posting scans (device keeps running until [stopDevice]/dispose).
  Future<void> stopListening() async {
    await _statusSub?.cancel();
    _statusSub = null;
  }

  /// Fully stop and disconnect the sensor.
  Future<void> stopDevice() async {
    await stopListening();
    await ZkFinger.stopListen();
  }

  /// Release everything. Call from `dispose()`.
  Future<void> dispose() async {
    await stopDevice();
    await _statusController.close();
  }

  void _onStatus(dynamic value) {
    if (value is! Map) return;
    final map = value as Map<dynamic, dynamic>;
    final FingerStatusType type =
        FingerStatusType.values[map['fingerStatus'] as int];
    final status = FingerStatus(
      (map['message'] ?? '') as String,
      type,
      (map['id'] ?? '') as String,
      (map['data'] ?? '') as String,
    );
    _statusController.add(status);

    if (type == FingerStatusType.FINGER_EXTRACTED) {
      final template = status.data;
      if (template.isNotEmpty) _debouncedSend(template);
    }
  }

  Future<void> _debouncedSend(String template) async {
    final now = DateTime.now();
    if (now.difference(_lastSent) < debounce || _busy) return;
    _lastSent = now;
    _busy = true;
    try {
      final response = await _dio.post<Map>(
        scanUrl,
        data: jsonEncode({
          'purpose': purpose,
          'template': template,
          'template_format': 'JQSS21',
          'template_encoding': 'base64',
          'device': deviceName,
          'captured_at': now.toUtc().toIso8601String(),
          ...extraBody,
        }),
        options: Options(headers: {'Content-Type': 'application/json'}),
      );
      _onResult?.call(
        FingerScanResult.ok(
          template: template,
          statusCode: response.statusCode ?? 0,
          body: response.data,
        ),
      );
    } on DioException catch (e) {
      final body = e.response?.data;
      onError?.call(e);
      _onResult?.call(
        FingerScanResult.error(
          template: template,
          statusCode: e.response?.statusCode ?? 0,
          body: body is Map ? body : null,
          error: e,
        ),
      );
    } catch (e) {
      onError?.call(e);
      _onResult?.call(FingerScanResult.error(template: template, error: e));
    } finally {
      _busy = false;
    }
  }
}

/// Result of one scanned finger POSTed to the backend.
class FingerScanResult {
  FingerScanResult({
    required this.template,
    required this.ok,
    this.statusCode = 0,
    this.body,
    this.error,
  });

  factory FingerScanResult.ok({
    required String template,
    required int statusCode,
    Map? body,
  }) =>
      FingerScanResult(
        template: template,
        ok: true,
        statusCode: statusCode,
        body: body,
      );

  factory FingerScanResult.error({
    required String template,
    int statusCode = 0,
    Map? body,
    Object? error,
  }) =>
      FingerScanResult(
        template: template,
        ok: false,
        statusCode: statusCode,
        body: body,
        error: error,
      );

  /// The Base64 template that was captured (and sent).
  final String template;

  /// Whether the backend answered with 2xx.
  final bool ok;

  final int statusCode;

  /// Decoded backend response, e.g.
  /// `{ "match": true, "user_id": "42", "score": 536 }`.
  final Map? body;

  /// Set when the request failed.
  final Object? error;

  /// Convenience for identify-style backends.
  bool get matched => ok && (body?['match'] == true);

  String? get userId => body == null ? null : body!['user_id']?.toString();

  @override
  String toString() => 'FingerScanResult(ok: $ok, statusCode: $statusCode, '
      'matched: $matched, userId: $userId${error != null ? ', error: $error' : ''})';
}

/* ------------------------------ usage -----------------------------------

  final scanner = FingerScannerClient(
    scanUrl: 'https://api.example.com/api/fingerprints/scan',
    purpose: 'identify',            // or 'enroll'
    deviceName: 'gate-1',
    extraBody: {'location_id': 7},
    onResult: (r) => print(r),      // backend answer per finger press
    onError: (e) => print(e),
  );

  await scanner.connect();
  await scanner.start();            // scanner mode - no local matching

  // ... on dispose():
  await scanner.dispose();

------------------------------------------------------------------------- */