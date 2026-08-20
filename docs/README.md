# Device Data & Integration Notes

What the ZKTeco scanner actually gives you, how to see it, and how to store it.
All values here were captured from a real ZK9500 on 2026-08-19, not from docs.

| Doc | Contents |
|---|---|
| [`sample_payloads.json`](./sample_payloads.json) | Real captured events, JSON-serialized |
| [`BACKEND_STORAGE.md`](./BACKEND_STORAGE.md) | Laravel schema, sync endpoints, `pin` encoding |

---

## 1. Where the work happens

```
ZK9500 USB sensor ──(raw image)──> Android phone
                                     ├─ libzkfp: extract  → 2048B template
                                     ├─ libzkfp: merge ×3  → enroll template
                                     ├─ ZKFingerService.identify()  ← 1:N MATCH
                                     └─ SQLite zkfinger10.db  userinfo(pin, feature)
```

The sensor is a dumb capture device — no CPU for matching. Everything happens in
`libzkfp` on the phone.

Two device-side stores exist and they are **not** the same thing:

| | What it is | Used by |
|---|---|---|
| `ZKFingerService` in-memory cache | native RAM cache | **`identify()` searches this** |
| `zkfinger10.db` SQLite | plain persistence | only repopulates RAM on `startFingerSensor()` |

`identify()` never reads SQLite. The DB just replays templates into RAM at startup.

---

## 2. What comes out — two streams

### `statusChangeStream`

Not JSON. `StandardMessageCodec` binary → `Map<Object?, Object?>`:

```dart
{ 'message': String, 'fingerStatus': int, 'id': String, 'data': String }
```

`data` is **overloaded** — meaning depends on `fingerStatus`:

| statusType | `id` | `data` |
|---|---|---|
| `FINGER_EXTRACTED` (30) | `""` | base64 template, every touch |
| `ENROLL_SUCCESS` | userId | merged base64 template (3 scans) |
| `ENROLL_STARTED` / `ENROLL_CONFIRM` | `""` | remaining scan count / verify score |
| `ENROLL_ALREADY_EXIST` | matched userId | `""` |
| `IDENTIFIED_SUCCESS` (10) | userId | match score |
| `IDENTIFIED_FAILED`, `VERIFIED_*` | `""` | score |
| `STARTED_*`, `STOPPED_*`, USB perms | `""` | `""` |

Native returns `bufids` as `"MAMASODIKOV\t536"`, tab-split into `id` / `data`.

### `imageStream`

Raw `Uint8List` — no map, no envelope, **not base64**. PNG, cropped greyscale,
~40–80KB. Matching never uses it. Don't store it.

---

## 3. The template

```
magic:  "JQSS21"  (4a 51 53 53 32 31 00 00)
size:   2732 base64 chars → 2049 bytes decoded
codec:  base64, NO_WRAP
```

ZKFinger v10 proprietary minutiae format. **Fixed size** — 2732 chars regardless
of finger quality, so length tells you nothing.

Store the base64 string byte-for-byte. Don't decode and re-encode: the Java side
does `Base64.decode(..., NO_WRAP)` and is sensitive to padding/whitespace drift.

---

## 4. Gotchas

**Score is not a percentage.** `ZKFingerService.identify(template, bufids, 70, 1)`
takes 70 as a *threshold argument*, but the returned score is on the SDK's own
scale — an observed good match returned **536**. Don't build percentage UI or a
`score > 70` business rule expecting 0–100 semantics.

**Score arrives as a String.** `"536"`, not `536`. Parse before POSTing or an
`integer` validation rule will reject it.

**Every touch emits a template.** `FINGER_EXTRACTED` fires before enroll/identify
branching, with `id = ""`. If you forward these blindly you'll ship a biometric
template on every finger placement, matched or not.

**`pin` is one string per template, not per user.** `clearAndLoadDatabase()` takes
`Map<String,String>`. Two fingers = two entries. Encode `{user_id}:{finger_index}`
and split on `IDENTIFIED_SUCCESS`.

**Backend can't dedupe fingers.** Two scans of the same finger produce different
templates, so hash comparison only catches exact re-uploads. Real duplicate
detection is the device's `ENROLL_ALREADY_EXIST`.

---

## 5. Seeing the data

`example/lib/device_log.dart` + `log_screen.dart` instrument both streams and
every `ZkFinger.*` call.

**Logcat:**

```bash
adb logcat -s flutter | grep ZKLOG
```

**In-app:** terminal icon in the AppBar. Toggles for auto-scroll, full base64
(templates truncate by default), JSON mode, copy-all, clear.

Line tags: `[RAW-STATUS]` `[STATUS]` `[IMAGE]` `[CALL]` `[JSON]` `[ERROR]`.

Sample output:

```
[STATUS] type=FINGER_EXTRACTED(#30) id="" dataLen=2732 data=SlFTUzIx… message="Finger extracted OK"
  ↳ data = per-scan base64 template (2732 chars, ~2049 bytes decoded)
[STATUS] type=IDENTIFIED_SUCCESS(#10) id="MAMASODIKOV" dataLen=3 data=536
  ↳ match: userId="MAMASODIKOV" identifyScore=536 (native scale, higher=better)
```

Flags:

```dart
DeviceLog.enabled      = true;   // master switch — turn OFF in production
DeviceLog.fullTemplate = false;  // true = dump full base64
DeviceLog.jsonMode     = false;  // true = emit [JSON] line per event
```

> Leaving `enabled = true` in a release build writes biometric templates to
> logcat, readable by any process with log access. Gate it on `kDebugMode`.

---

## 6. Open items

- **`imageStream` not observed firing.** No `[IMAGE]` lines appeared during a
  successful identify. Either unconfirmed or `captureOK` isn't emitting —
  the PNG path is independent of `extractOK`. Verify before depending on it.
- **Verify vs identify score scales.** `verify()` is compared against `> 70` in
  `ZKFingerPrintHelper`, `identify()` returned 536. Whether these share a scale
  is untested — measure both before setting thresholds.
