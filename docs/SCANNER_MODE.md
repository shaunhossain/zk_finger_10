# Scanner Mode — ZK Device as a Pure Fingerprint Scanner + Backend

Use the ZKTeco reader **only to capture** fingerprints. Every finger press
produces a **Base64 template** (~2049 bytes, ZK "JQSS21" format) that your app
POSTs to your backend. The backend then **stores / matches / decides** what to
do — the device does no local identification or enrollment.

```
finger press ──> USB sensor ──> Base64 template ──> POST /api/fingerprints/scan ──> your backend
                (capture only)   (FINGER_EXTRACTED)        (one per press)          (storage & matching)
```

---

## 1. App side (Flutter) — 3 calls

```dart
import 'package:zkfinger10/zk_finger.dart';
import 'package:zkfinger10/finger_status.dart';
import 'package:zkfinger10/finger_status_type.dart';
import 'package:dio/dio.dart';

// 1) listen for scanned templates BEFORE connecting
ZkFinger.statusChangeStream.receiveBroadcastStream().listen((event) {
  final map = event as Map<dynamic, dynamic>;
  final type = FingerStatusType.values[map['fingerStatus'] as int];

  if (type == FingerStatusType.FINGER_EXTRACTED) {
    final base64Template = map['data'] as String;   // <-- THE scan data
    sendToBackend(base64Template);
  }
});

// 2) connect the device (also triggers the USB permission dialog)
await ZkFinger.openConnection();

// 3) scanner mode: capture only, no local identify
await ZkFinger.startScanner();      // no userId needed in this mode
```

That's it. No `identify()`, no `registerFinger()`, no local DB needed.

Or use the ready-made client in `example/lib/scanner_client.dart`, which adds
debouncing, error handling, and a typed result:

```dart
final scanner = FingerScannerClient(
  scanUrl: 'https://api.example.com/api/fingerprints/scan',
  deviceName: 'gate-1',
  onResult: (r) => print('${r.matched} ${r.userId}'),
);
await scanner.connect();
await scanner.start();
```

---

## 2. Backend side — REST contract

### `POST /api/fingerprints/scan`  (every finger press)

Request:

```json
{
  "purpose": "identify",
  "template": "SlFTUzIxAAADEhAECAUHCc7QAAAvE5EBAABGgj8Y0BKzAIpX0g...",
  "template_format": "JQSS21",
  "template_encoding": "base64",
  "device": "gate-1",
  "captured_at": "2026-08-20T05:10:44.123456Z"
}
```

Response (your backend decides — example for identify):

```json
{
  "match": true,
  "user_id": "42",
  "score": 536
}
```

or `"match": false` when unknown finger, or HTTP 4xx/5xx on error.

### `GET /api/fingerprints/users`  (optional — hybrid mode)

Returns `{ "userId": "<base64 template>", ... }` so terminals can load the
backend's templates into the device for **offline** local matching:

```dart
final users = await dio.get('.../users');
await ZkFinger.clearAndLoadDatabase(vUserList: users);
```

---

## 3. IMPORTANT — how the backend can actually "match"

ZK templates are proprietary (JQSS21). A normal backend **cannot compare two
base64 strings**. Pick one:

| Option | How matching works | When to choose |
|---|---|---|
| **A. Backend matcher (true scanner)** | Backend runs a ZK-compatible matcher (SourceAFIS won't work; you'd need ZK's server SDK or call each enrolled user's template back to a device/agent that verifies via `ZKFingerService.verify`) | Backend must make the decision |
| **B. Hybrid (recommended default)** | Backend is the *source of truth* for templates; each terminal syncs them down via `clearAndLoadDatabase()` and the device matches locally (`IDENTIFIED_SUCCESS` carries userId + score); results are then reported to the backend | Terminals are the app's own devices; needs offline capability |

With **Option B** you still use `startListen()` + `identify()` after loading,
and POST the identification *result* to the backend:

```json
{ "user_id": "42", "score": "536", "device": "gate-1", "at": "..." }
```

---

## 4. What one scan contains

| Field | Where | Value |
|---|---|---|
| Template | `statusMap['data']` on `FINGER_EXTRACTED` | Base64 string, ~2732 chars, decodes to ~2049 bytes starting with `JQSS21` |
| Preview image | `imageStream` | Raw `Uint8List` PNG (~70 KB) — optional, only for UI |
| Timestamp | your app | `DateTime.now().toUtc().toIso8601String()` |
| Device | your app | e.g. serial from logs, or a configured name |

Template size guard: a good scan is ~2700–2800 base64 chars. Anything much
shorter is a failed/partial extraction — reject before POSTing.

---

## 5. Production checklist

- **HTTPS only** — templates are biometric PII (hash/encrypt at rest, restrict access).
- **Debounce** (~1.2 s) — one press emits multiple `FINGER_EXTRACTED` events.
- **Auth** — attach device token to the POST (see `extraBody` in `scanner_client.dart`).
- **Offline queue** — queue scans when network is down, retry later.
- **No local DB needed** — in pure scanner mode you may never call
  `registerFinger`/`getAllUsers`; the plugin's SQLite DB stays empty.
- **Reconnection** — USB replug auto re-requests permission in the plugin; watch
  `STARTED_SUCCESS` / `STARTED_FAILED` statuses to restore scanner mode.