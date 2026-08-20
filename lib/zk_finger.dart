import 'dart:async';

import 'package:flutter/services.dart';

/// Output template standards supported by the ZK SDK's on-device converter.
enum ZkTemplateFormat {
  /// Raw proprietary ZK "JQSS21" template (~2732 Base64 chars). No conversion.
  zk,

  /// ANSI INCITS 378 finger minutiae record.
  ansi378,

  /// ISO/IEC 19794-2 finger minutiae record.
  iso19794_2,

  /// ISO/IEC 19794-2 compact card format.
  iso19794_2Compact,
}

extension ZkTemplateFormatCode on ZkTemplateFormat {
  /// Method-channel code understood by the Android side.
  int get code => index;
}

///TODO: Catch app lifecycles on kill (and close connection)
class ZkFinger {
  static const MethodChannel _channel = const MethodChannel('zkfinger');

  static const EventChannel statusChangeStream =
      EventChannel('com.mamasodikov.zkfinger10/status_change');
  static const EventChannel imageStream =
      EventChannel('com.mamasodikov.zkfinger10/finger_image');

  static Future<String?> get platformVersion async {
    return _channel.invokeMethod('getPlatformVersion');
  }

  static Future<bool?> openConnection() async {
    return _channel.invokeMethod('openConnection');
  }

  static Future<bool?> closeConnection() async {
    return _channel.invokeMethod('closeConnection');
  }

  static Future<bool?> startListen({String? userId}) async {
    return _channel
        .invokeMethod('startListen', <String, String?>{'id': userId});
  }

  /// Scanner mode: use the device purely as a scanner.
  ///
  /// Every finger press emits a [FingerStatusType.FINGER_EXTRACTED] event on
  /// [statusChangeStream] with the Base64 template in its `data` field (plus a
  /// PNG preview on [imageStream]). No local identify/register is performed -
  /// forward the template to your backend and let it do the matching/storage.
  ///
  /// Pass [format] to convert each captured template on-device into a standard
  /// ISO/ANSI template (default: raw ZK). Use e.g. [ZkTemplateFormat.iso19794_2]
  /// when your backend matches standard 19794-2 templates, so the emitted
  /// Base64 can be POSTed directly.
  static Future<bool?> startScanner({
    String? userId,
    ZkTemplateFormat format = ZkTemplateFormat.zk,
  }) async {
    return _channel.invokeMethod('startScanner', <String, Object?>{
      'id': userId,
      'format': format.code,
    });
  }

  static Future<bool?> stopListen() async {
    return _channel.invokeMethod('stopListen');
  }

  static Future<bool?> identify({String? userId}) async {
    return _channel.invokeMethod('identify', <String, String?>{'id': userId});
  }

  static Future<bool?> verify({String? finger1, String? finger2}) async {
    return _channel.invokeMethod(
        'verify', <String, String?>{'finger1': finger1, 'finger2': finger2});
  }

  static Future<bool?> registerFinger({String? userId}) async {
    final bool? success = await _channel
        .invokeMethod('register', <String, String?>{'id': userId});
    return success;
  }

  static Future<bool?> clearFingerDatabase() async {
    return await _channel.invokeMethod('clear');
  }

  static Future<bool?> clearAndLoadDatabase({Map<String, String>? vUserList}) async {
    return await _channel.invokeMethod('clearAndLoad', <String, Map<String, String>? >{'fingers': vUserList});
  }

  static Future<bool?> delete({String? userId}) async {
    return _channel.invokeMethod('delete', <String, String?>{'id': userId});
  }

  static Future<bool?> onDestroy() async {
    return await _channel.invokeMethod('onDestroy');
  }

  // ---------------- Template format conversion (standard ISO/ANSI) ----------

  /// Selects the output template standard used by [convertTemplate] and
  /// [startScanner] captures. Returns true when the SDK accepted it.
  static Future<bool?> setTemplateFormat(ZkTemplateFormat format) async {
    return _channel.invokeMethod(
        'setTemplateFormat', <String, Object?>{'format': format.code});
  }

  /// Converts a Base64 raw ZK template into the currently selected standard
  /// format (see [setTemplateFormat]). Returns the converted Base64 template,
  /// or null on failure (sensor service not initialized, unsupported format,
  /// or invalid input).
  static Future<String?> convertTemplate(String zkTemplate) async {
    try {
      return await _channel
          .invokeMethod('convertTemplate', <String, String?>{'data': zkTemplate});
    } catch (e) {
      return null;
    }
  }

  /// Quality score (SDK scale) of a Base64 raw ZK template, or -1 on failure.
  /// Useful to fill the `quality` field when enrolling samples to a backend.
  static Future<int?> getTemplateQuality(String zkTemplate) async {
    try {
      return await _channel
          .invokeMethod('getTemplateQuality', <String, String?>{'data': zkTemplate});
    } catch (e) {
      return -1;
    }
  }

  // New bidirectional data management methods

  /// Get fingerprint feature data for a specific user ID
  static Future<String?> getUserFeature({required String userId}) async {
    try {
      return await _channel.invokeMethod('getUserFeature', <String, String>{'id': userId});
    } catch (e) {
      return null;
    }
  }

  /// Get all users and their fingerprint data from the database
  static Future<Map<String, String>?> getAllUsers() async {
    try {
      final result = await _channel.invokeMethod('getAllUsers');
      if (result is Map) {
        return Map<String, String>.from(result);
      }
      return null;
    } catch (e) {
      return null;
    }
  }

  /// Get the total count of users in the database
  static Future<int?> getUserCount() async {
    try {
      return await _channel.invokeMethod('getUserCount');
    } catch (e) {
      return null;
    }
  }

  /// Update fingerprint feature data for an existing user
  static Future<bool?> updateUserFeature({required String userId, required String feature}) async {
    try {
      return await _channel.invokeMethod('updateUserFeature', <String, String>{
        'id': userId,
        'data': feature
      });
    } catch (e) {
      return false;
    }
  }

  /// Check if a user exists in the database
  static Future<bool?> checkUserExists({required String userId}) async {
    try {
      return await _channel.invokeMethod('checkUserExists', <String, String>{'id': userId});
    } catch (e) {
      return false;
    }
  }
}