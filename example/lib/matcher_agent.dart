import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:zkfinger10/finger_status.dart';
import 'package:zkfinger10/finger_status_type.dart';
import 'package:zkfinger10/zk_finger.dart';

/// Turns any Android device running this plugin into a **ZK template matcher**
/// for your backend (Option A - backend-side matching, no ZK server SDK needed).
///
/// `ZKFingerService.verify()` is a pure template-matching algorithm - it does
/// NOT require a fingerprint sensor to be attached. So a cheap always-on
/// Android box (or even one of your terminals) can serve as the "matcher
/// agent" your backend calls whenever it needs two templates compared.
///
/// Endpoints (all JSON):
///
///   GET  /health                     -> {ok: true}
///   POST /verify   {template1, template2}
///                                    -> {match: bool, score: double, status}
///   POST /identify {template, candidates: {userId: template}}
///                                    -> {match: bool, user_id, score, checked}
///
/// Optional auth: set [token] and clients must send `x-agent-token` header.
///
/// Verifications are serialized (one ZKFingerService call at a time) because
/// results arrive asynchronously on [ZkFinger.statusChangeStream].
class MatcherAgentServer {
  MatcherAgentServer({
    this.port = 8787,
    this.token,
    this.matchThreshold = 70,
    this.maxCandidates = 2000,
    this.verifyTimeout = const Duration(seconds: 8),
  });

  final int port;

  /// Shared secret required in the `x-agent-token` header (null = no auth).
  final String? token;

  /// SDK score threshold - the plugin treats score > 70 as "same finger".
  final double matchThreshold;

  /// Safety cap on the candidates map sent to /identify.
  final int maxCandidates;

  /// How long to wait for one ZKFingerService.verify result.
  final Duration verifyTimeout;

  HttpServer? _server;
  StreamSubscription<dynamic>? _statusSub;
  final List<Completer<FingerStatus>> _statusWaiters = [];
  Future<void> _lock = Future.value();

  /// Starts the HTTP server. Never returns normally - call from `main()`.
  Future<void> start() async {
    _statusSub ??= ZkFinger.statusChangeStream.receiveBroadcastStream().listen(
          _onRawStatus,
          onError: (Object e) => print('status stream error: $e'),
        );

    _server = await HttpServer.bind(InternetAddress.anyIPv4, port);
    print('ZK matcher agent listening on http://0.0.0.0:$port');
    print('Point your backend MATCHER_URL here (e.g. http://<this-device-ip>:$port)');

    await for (final HttpRequest request in _server!) {
      try {
        await _handle(request);
      } catch (e) {
        try {
          _json(request, 500, {'error': e.toString()});
        } catch (_) {}
      }
    }
  }

  Future<void> stop() async {
    await _server?.close();
    await _statusSub?.cancel();
    _statusSub = null;
  }

  /* ------------------------- status correlation ------------------------- */

  void _onRawStatus(dynamic event) {
    if (event is! Map) return;
    final dynamic idx = event['fingerStatus'];
    if (idx is! int || idx < 0 || idx >= FingerStatusType.values.length) return;
    final type = FingerStatusType.values[idx];

    final bool isVerifyResult = type == FingerStatusType.VERIFIED_SUCCESS ||
        type == FingerStatusType.VERIFIED_FAILED ||
        type == FingerStatusType.VERIFIED_ERROR;
    if (!isVerifyResult || _statusWaiters.isEmpty) return;

    final Completer<FingerStatus> waiter = _statusWaiters.removeAt(0);
    if (!waiter.isCompleted) {
      waiter.complete(FingerStatus(
        event['message'].toString(),
        type,
        event['id'].toString(),
        event['data'].toString(),
      ));
    }
  }

  /// Runs [task] exclusively - ZKFingerService results are matched to calls
  /// by order, so verifications must not overlap.
  Future<T> _serial<T>(Future<T> Function() task) {
    final Future<T> run = _lock.then((_) => task());
    _lock = run.then((_) {}, onError: (Object _) {});
    return run;
  }

  Future<Map<String, dynamic>> _verifyPair(String template1, String template2) {
    return _serial<Map<String, dynamic>>(() async {
      final Completer<FingerStatus> waiter = Completer<FingerStatus>();
      _statusWaiters.add(waiter);
      try {
        await ZkFinger.verify(finger1: template1, finger2: template2);
        final FingerStatus status = await waiter.future.timeout(
          verifyTimeout,
          onTimeout: () => throw TimeoutException('verify timed out'),
        );
        final double score = double.tryParse(status.data) ?? 0;
        final bool match = status.statusType == FingerStatusType.VERIFIED_SUCCESS &&
            score > matchThreshold;
        return <String, dynamic>{
          'match': match,
          'score': score,
          'status': status.statusType.name,
        };
      } finally {
        _statusWaiters.remove(waiter);
      }
    });
  }

  /* ----------------------------- HTTP layer ----------------------------- */

  Future<void> _handle(HttpRequest request) async {
    // CORS (handy when testing from a web dashboard)
    if (request.method == 'OPTIONS') {
      request.response.statusCode = 204;
      request.response.headers.set('Access-Control-Allow-Origin', '*');
      request.response.headers.set('Access-Control-Allow-Headers', '*');
      request.response.headers.set('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
      await request.response.close();
      return;
    }

    if (!_authed(request)) {
      _json(request, 401, {'error': 'bad or missing x-agent-token'});
      return;
    }

    final String path = request.uri.path;

    if (request.method == 'GET' && path == '/health') {
      _json(request, 200, {'ok': true, 'port': port});
      return;
    }

    if (request.method == 'POST' && path == '/verify') {
      final Map<String, dynamic> body = await _readJson(request);
      final dynamic t1 = body['template1'];
      final dynamic t2 = body['template2'];
      if (t1 is! String || t2 is! String || t1.isEmpty || t2.isEmpty) {
        _json(request, 400, {'error': 'template1 and template2 (base64) required'});
        return;
      }
      final Map<String, dynamic> result = await _verifyPair(t1, t2);
      _json(request, 200, result);
      return;
    }

    if (request.method == 'POST' && path == '/identify') {
      final Map<String, dynamic> body = await _readJson(request);
      final dynamic probe = body['template'];
      final dynamic rawCandidates = body['candidates'];
      if (probe is! String || probe.isEmpty || rawCandidates is! Map) {
        _json(request, 400, {'error': 'template and candidates {userId: template} required'});
        return;
      }
      if (rawCandidates.length > maxCandidates) {
        _json(request, 413, {'error': 'too many candidates (max $maxCandidates)'});
        return;
      }

      String? bestId;
      double bestScore = 0;
      int checked = 0;
      for (final MapEntry<dynamic, dynamic> e in rawCandidates.entries) {
        if (e.value is! String) continue;
        checked++;
        try {
          final Map<String, dynamic> r = await _verifyPair(probe, e.value as String);
          final double score = (r['score'] as num?)?.toDouble() ?? 0;
          if (score > bestScore) {
            bestScore = score;
            bestId = e.key.toString();
          }
        } catch (_) {
          // skip candidate on timeout/decode error, keep scanning
        }
      }

      final bool match = bestScore > matchThreshold;
      _json(request, 200, <String, dynamic>{
        'match': match,
        'user_id': match ? bestId : null,
        'score': bestScore,
        'checked': checked,
      });
      return;
    }

    _json(request, 404, {'error': 'not found', 'path': path});
  }

  bool _authed(HttpRequest request) =>
      token == null || request.headers.value('x-agent-token') == token;

  Future<Map<String, dynamic>> _readJson(HttpRequest request,
      {int limit = 64 * 1024 * 1024}) async {
    final List<int> bytes = <int>[];
    await for (final List<int> chunk in request) {
      bytes.addAll(chunk);
      if (bytes.length > limit) {
        throw const HttpException('request body too large');
      }
    }
    if (bytes.isEmpty) return <String, dynamic>{};
    final dynamic decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map) {
      throw const HttpException('body must be a JSON object');
    }
    return Map<String, dynamic>.from(decoded);
  }

  void _json(HttpRequest request, int code, Map<String, dynamic> obj) {
    request.response.statusCode = code;
    request.response.headers.contentType = ContentType.json;
    request.response.headers.set('Access-Control-Allow-Origin', '*');
    request.response.write(jsonEncode(obj));
    request.response.close();
  }
}

/* ------------------------------ usage -----------------------------------

Run on any Android device that has this plugin (a sensor is NOT required):

  cd example
  flutter run -t lib/matcher_agent_main.dart -d <android-device-id>

Then on your backend set:

  MATCHER_URL=http://<device-ip>:8787

The matcher agent keeps the ZK matching algorithm on Android (where the ZK
SDK is licensed) while your backend owns storage, users and business logic.

------------------------------------------------------------------------- */