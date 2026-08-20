import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:zkfinger10/finger_status_type.dart';

/// Dumps everything the ZKFinger device pushes over the two EventChannels.
/// Filter in logcat with:  adb logcat -s flutter | grep ZKLOG
class DeviceLog {
  static bool enabled = true;

  /// Print full base64 templates instead of a truncated preview.
  static bool fullTemplate = false;

  /// In-memory ring buffer so the UI can show the same lines.
  static final List<String> buffer = <String>[];
  static const int _maxBuffer = 500;

  static void _out(String line) {
    if (!enabled) return;
    final String stamped = '${DateTime.now().toIso8601String()} $line';
    buffer.add(stamped);
    if (buffer.length > _maxBuffer) buffer.removeAt(0);
    debugPrint('ZKLOG $stamped');
  }

  static String _preview(String? s) {
    if (s == null) return 'null';
    if (s.isEmpty) return '""';
    if (fullTemplate || s.length <= 64) return s;
    return '${s.substring(0, 32)}…${s.substring(s.length - 16)} (len=${s.length})';
  }

  /// Emit each status event as a JSON line too (copy-paste ready).
  static bool jsonMode = false;

  /// Raw map straight off `statusChangeStream`, before any parsing.
  static void rawStatus(dynamic value) {
    _out('[RAW-STATUS] runtimeType=${value.runtimeType} value=$value');
  }

  /// The event as JSON — this is NOT the wire format, the channel is binary
  /// StandardMessageCodec. This is what you'd actually POST to a backend.
  static Map<String, dynamic> toJson(Map<dynamic, dynamic> m) {
    final int idx = m['fingerStatus'] is int ? m['fingerStatus'] as int : -1;
    final String type = (idx >= 0 && idx < FingerStatusType.values.length)
        ? FingerStatusType.values[idx].name
        : 'OUT_OF_RANGE($idx)';
    final String data = (m['data'] ?? '').toString();
    final String id = (m['id'] ?? '').toString();

    final Map<String, dynamic> out = <String, dynamic>{
      'type': type,
      'statusIndex': idx,
      'userId': id.isEmpty ? null : id,
      'message': m['message'],
      'at': DateTime.now().toUtc().toIso8601String(),
    };

    switch (type) {
      case 'FINGER_EXTRACTED':
      case 'ENROLL_SUCCESS':
        out['template'] = <String, dynamic>{
          'encoding': 'base64',
          'variant': 'NO_WRAP',
          'magic': data.startsWith('SlFTUzIx') ? 'JQSS21' : 'unknown',
          'charLength': data.length,
          'byteLength': (data.length * 3 / 4).round(),
          'value': fullTemplate ? data : '${data.substring(0, 16)}…',
        };
        break;
      case 'IDENTIFIED_SUCCESS':
      case 'IDENTIFIED_FAILED':
      case 'VERIFIED_SUCCESS':
      case 'VERIFIED_FAILED':
        out['score'] = num.tryParse(data);
        out['scoreScale'] = 'native, not 0-100';
        break;
      default:
        if (data.isNotEmpty) out['data'] = data;
    }
    return out;
  }

  /// Decoded status event.
  static void status(Map<dynamic, dynamic> m) {
    final int idx = m['fingerStatus'] is int ? m['fingerStatus'] as int : -1;
    final String type = (idx >= 0 && idx < FingerStatusType.values.length)
        ? FingerStatusType.values[idx].name
        : 'OUT_OF_RANGE($idx)';
    final String data = (m['data'] ?? '').toString();

    _out('[STATUS] type=$type(#$idx) '
        'id="${m['id'] ?? ''}" '
        'dataLen=${data.length} '
        'data=${_preview(data)} '
        'message="${m['message'] ?? ''}"');

    // Interpretation of the overloaded `data` field.
    switch (type) {
      case 'FINGER_EXTRACTED':
        _out('  ↳ data = per-scan base64 template (${data.length} chars, '
            '~${(data.length * 3 / 4).round()} bytes decoded)');
        break;
      case 'ENROLL_SUCCESS':
        _out('  ↳ data = MERGED base64 template for id="${m['id']}" '
            '(${data.length} chars)');
        break;
      case 'ENROLL_STARTED':
      case 'ENROLL_CONFIRM':
        _out('  ↳ data = remaining scans / verify score = "$data"');
        break;
      case 'IDENTIFIED_SUCCESS':
        // NOT 0-100. Native identify() is called with threshold=70 but returns
        // a similarity score on its own scale (observed: 536 on a good match).
        _out('  ↳ match: userId="${m['id']}" identifyScore=$data '
            '(native scale, higher=better; SDK threshold arg=70)');
        break;
      case 'IDENTIFIED_FAILED':
      case 'VERIFIED_SUCCESS':
      case 'VERIFIED_FAILED':
        _out('  ↳ score=$data');
        break;
      case 'ENROLL_ALREADY_EXIST':
        _out('  ↳ finger already enrolled by id="${m['id']}"');
        break;
    }

    if (jsonMode) {
      _out('[JSON] ${const JsonEncoder().convert(toJson(m))}');
    }
  }

  /// Raw bytes off `imageStream`.
  static void image(dynamic bytes) {
    if (bytes is Uint8List) {
      final String head = bytes
          .take(8)
          .map((int b) => b.toRadixString(16).padLeft(2, '0'))
          .join(' ');
      final bool isPng = bytes.length > 8 &&
          bytes[0] == 0x89 &&
          bytes[1] == 0x50 &&
          bytes[2] == 0x4E &&
          bytes[3] == 0x47;
      _out('[IMAGE] ${bytes.length} bytes  magic=[$head]  '
          'png=$isPng  b64Len=${base64Encode(bytes).length}');
    } else {
      _out('[IMAGE] unexpected type=${bytes.runtimeType} value=$bytes');
    }
  }

  /// MethodChannel call + result.
  static void call(String method, Object? result, {Object? args}) {
    String r;
    if (result is Map) {
      r = 'Map(${result.length}) keys=${result.keys.take(5).toList()}';
    } else if (result is String) {
      r = _preview(result);
    } else {
      r = '$result';
    }
    _out('[CALL] $method(${args ?? ''}) -> $r');
  }

  static void error(String where, Object e, [StackTrace? st]) {
    _out('[ERROR] $where: $e${st != null ? '\n$st' : ''}');
  }

  static String dump() => buffer.join('\n');

  static void clear() => buffer.clear();
}
