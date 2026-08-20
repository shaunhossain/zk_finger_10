# Backend Storage Design (Laravel)

## Where matching happens

```
ZK9500 USB sensor ──(raw image)──> Android phone
                                     ├─ libzkfp: extract → 2048B template
                                     ├─ libzkfp: merge 3 scans → enroll template
                                     ├─ ZKFingerService.identify() ← 1:N MATCH HAPPENS HERE
                                     └─ SQLite zkfinger10.db  userinfo(pin, feature)
                                            ▲                    │
                                            │ clearAndLoad       │ enroll upload
                                            │                    ▼
                                        Laravel API  ←── source of truth
```

The sensor has no CPU for matching. Laravel never matches — it stores and syncs.

## Data shape

| Field | Value |
|---|---|
| `pin` | device-local identity key, **single string** |
| `feature` | base64, `NO_WRAP`, ~2732 chars (2048 bytes decoded) |
| image | PNG, ~40–80KB — **do not store**, not needed for matching |

## The `pin` gotcha

`clearAndLoadDatabase()` takes `Map<String,String>` = `pin → feature`. One key per template, not per user. Two fingers = two rows. Encode as `{user_id}:{finger_index}`:

```
"42:1" → "Sk9GRgAB..."
"42:2" → "Sk9GRgAB..."
```

On `IDENTIFIED_SUCCESS` the `id` field returns that pin — split on `:` to get the user.

## Schema

```php
// database/migrations/xxxx_create_fingerprint_templates_table.php
Schema::create('fingerprint_templates', function (Blueprint $table) {
    $table->id();
    $table->foreignId('user_id')->constrained()->cascadeOnDelete();
    $table->unsignedTinyInteger('finger_index');       // 1..10
    $table->text('template');                          // base64, NO_WRAP
    $table->char('template_hash', 64)->index();        // sha256(template) — dedupe
    $table->string('enrolled_by_device')->nullable();
    $table->unsignedInteger('quality_score')->nullable();
    $table->timestamps();
    $table->softDeletes();                             // needed: sync must see deletes

    $table->unique(['user_id', 'finger_index']);
});
```

`text` not `binary` — keep the base64 exactly as the device produced it. Decoding and re-encoding risks whitespace/padding drift that breaks `Base64.decode(..., NO_WRAP)` on the Java side.

Devices table for scoping + sync bookkeeping:

```php
Schema::create('devices', function (Blueprint $table) {
    $table->id();
    $table->string('serial')->unique();
    $table->foreignId('site_id')->nullable()->constrained();
    $table->timestamp('last_synced_at')->nullable();
    $table->timestamps();
});
```

## Model

```php
class FingerprintTemplate extends Model
{
    use SoftDeletes;

    protected $fillable = ['user_id', 'finger_index', 'template', 'enrolled_by_device'];
    protected $hidden   = ['template'];   // never leaks into a generic toArray()

    public function pin(): string
    {
        return "{$this->user_id}:{$this->finger_index}";
    }

    protected static function booted(): void
    {
        static::saving(fn ($m) => $m->template_hash = hash('sha256', $m->template));
    }
}
```

## Endpoints

**Enroll upload** — device fires `ENROLL_SUCCESS`, app POSTs the merged template:

```php
// POST /api/fingerprints
public function store(Request $r)
{
    $data = $r->validate([
        'user_id'      => ['required', 'exists:users,id'],
        'finger_index' => ['required', 'integer', 'between:1,10'],
        'template'     => ['required', 'string', 'min:1000', 'max:8000', 'regex:/^[A-Za-z0-9+\/=]+$/'],
        'device'       => ['nullable', 'string'],
    ]);

    // cross-device duplicate check (device only knows its own local DB)
    $dupe = FingerprintTemplate::where('template_hash', hash('sha256', $data['template']))
        ->where('user_id', '!=', $data['user_id'])->first();
    if ($dupe) {
        return response()->json(['error' => 'template already enrolled by another user'], 409);
    }

    $t = FingerprintTemplate::updateOrCreate(
        ['user_id' => $data['user_id'], 'finger_index' => $data['finger_index']],
        ['template' => $data['template'], 'enrolled_by_device' => $data['device'] ?? null],
    );

    return response()->json(['id' => $t->id, 'pin' => $t->pin()], 201);
}
```

Exact-hash dedupe only catches re-uploads of the same template — it will **not** catch the same finger scanned twice (templates differ per scan). Real cross-user dupe detection needs a matcher; on device that's `ENROLL_ALREADY_EXIST`, which already fires locally.

**Sync down** — device pulls the full set, then calls `clearAndLoadDatabase()`:

```php
// GET /api/fingerprints/sync
public function sync(Request $r)
{
    $rows = FingerprintTemplate::query()
        ->when($r->site_id, fn ($q, $s) => $q->whereHas('user', fn ($u) => $u->where('site_id', $s)))
        ->get();

    return response()->json([
        'version'  => FingerprintTemplate::withTrashed()->max('updated_at'),
        'count'    => $rows->count(),
        'fingers'  => $rows->mapWithKeys(fn ($t) => [$t->pin() => $t->template]),
    ]);
}
```

Flutter side:

```dart
final res = await dio.get('/api/fingerprints/sync');
final fingers = Map<String, String>.from(res.data['fingers']);
await ZkFinger.clearAndLoadDatabase(vUserList: fingers);
```

Full replace, not delta — `clearAndLoadDatabase` wipes and reloads anyway, and at <5k users the payload is ~14MB uncompressed, ~10MB gzipped. Enable gzip on the response. If that's too heavy over mobile data, scope by `site_id` so each device only pulls its branch.

## Deletes

Soft delete on the backend, then a device resync drops it — because sync sends the full set, a removed row simply isn't in the payload. That's the whole delete mechanism; no separate tombstone endpoint needed.

## On plaintext storage

You chose plaintext base64. Workable at this scale, but three things are worth doing since they're nearly free:

1. `protected $hidden = ['template']` (above) so templates never leak through an accidental `->toJson()`.
2. Exclude `fingerprint_templates` from any log/audit/activity package that serializes model attributes.
3. TLS-only on the sync endpoint + device auth (Sanctum token per device), since the full template set moves over the wire on every sync.

Note that ZK templates are proprietary-format minutiae, not images — they can't be reversed into a usable fingerprint picture, but they are still biometric identifiers under GDPR Art. 9 / BIPA and are permanent (a leaked template can never be reissued). If this ever holds EU or Illinois subjects, revisit envelope encryption.
