# Worker / model-profile configuration validator

A dependency-free (Python standard library only) validator for PDS-Bridge worker
configuration documents, plus a fixture pair and a `unittest` suite that pins the
behaviour of every rule below.

```
json-validator/
├── validate_config.py         # validator + CLI
├── test_validate_config.py    # 59 unittest cases
├── fixtures/
│   ├── valid.json             # valid document (3 workers, 3 model profiles)
│   └── invalid.json           # invalid document (20 defects, one per defect class)
└── README.md
```

All names in the fixtures (`nebula-chat-x1`, `Nimbus AI`, …) are fictional and
exist only to exercise the schema.

## Usage

```bash
python3 -B validate_config.py fixtures/valid.json
python3 -B validate_config.py fixtures/invalid.json
```

The CLI prints **one JSON object on stdout and nothing else**. Diagnostics never
go to stdout as free text, and no exception ever escapes the process.

## Configuration specification

### Top level

| Rule | Detail |
| --- | --- |
| Root | must be a JSON **object** (`{…}`) |
| `workers` | required, must be an **array**; every element must be an **object** |
| `model_profiles` | required, must be an **array**; every element must be an **object** |
| Unknown/extra keys | allowed everywhere, at every level, and ignored |

### `workers[]`

| Field | Required | Rule |
| --- | --- | --- |
| `id` | yes | non-empty, non-whitespace string; unique across workers |
| `level` | yes | non-empty string, exactly one of `L1`, `L2`, `L3` (case-sensitive) |
| `model_profile` | yes | non-empty, non-whitespace string; must equal some `model_profiles[].id` |
| `timeout_seconds` | yes | integer in `1..3600`; `true`/`false` and fractional values (e.g. `12.5`, `2.0`) are rejected |
| `concurrency_limit` | yes | integer in `1..8`; `true`/`false` and fractional values are rejected |

### `model_profiles[]`

| Field | Required | Rule |
| --- | --- | --- |
| `id` | yes | non-empty, non-whitespace string; unique across profiles |
| `provider` | yes | non-empty, non-whitespace string |
| `model` | yes | non-empty, non-whitespace string |

### Error reporting

Errors are **aggregated**: every independent defect in the document is reported in
a single run, not just the first one. Each entry carries at least:

```json
{"path": "$.workers[1].timeout_seconds", "code": "out_of_range", "message": "'timeout_seconds' must be between 1 and 3600, got 0"}
```

* `path` — JSONPath-like location, `$` for the document root; a field-level error
  uses the field path (`$.workers[0].level`), a container-level error uses the
  container path (`$.workers[6]`).
* `code` — stable machine-readable identifier (table below).
* `message` — human-readable explanation, including the offending value or type.

The array is sorted by `(path, code)` using a stable sort, so two runs over the
same input always produce byte-identical output. Ordering is plain lexical on the
path string, so `$.workers[10]` sorts before `$.workers[2]`.

| `code` | Meaning |
| --- | --- |
| `root_not_object` | top level is not an object |
| `workers_not_array` / `model_profiles_not_array` | the key exists but is not an array |
| `missing_field` | a required field (or required top-level key) is absent |
| `worker_not_object` / `profile_not_object` | an array element is not an object |
| `not_a_string` | a required string field holds a non-string value |
| `empty_string` | a required string is empty or whitespace-only |
| `invalid_level` | `level` is a string but not `L1`/`L2`/`L3` |
| `not_an_integer` | a numeric field holds a boolean, fractional number, string, null, array or object |
| `out_of_range` | an integer field is outside its permitted range |
| `duplicate_id` | worker or model-profile `id` already used earlier in the same array |
| `unknown_model_profile` | `worker.model_profile` matches no `model_profiles[].id` |
| `file_not_found` | input path does not exist (exit 2, path `$`) |
| `file_not_readable` | directory, permission problem, or non-UTF-8 bytes (exit 2, path `$`) |
| `invalid_json_syntax` | file is not parseable JSON (exit 2, path `$`) |
| `cli_usage_error` | not exactly one command-line argument (exit 2, path `$`) |
| `internal_error` | last-resort guard; nothing escaped to the terminal (exit 2, path `$`) |

Two deliberate design decisions, both covered by tests:

* when `model_profiles` is missing or is not an array, worker reference checks are
  skipped — the top-level defect is reported once instead of producing one
  `unknown_model_profile` per worker;
* when a required field is already invalid (missing, wrong type, blank), dependent
  checks on that value are skipped, so one bad value yields one error.

## Output examples

Valid document — `python3 -B validate_config.py fixtures/valid.json`, exit code **0**:

```json
{
  "valid": true,
  "source": "fixtures/valid.json",
  "error_count": 0,
  "errors": []
}
```

Invalid document — `python3 -B validate_config.py fixtures/invalid.json`, exit code **1**
(20 errors; abridged after the first six entries):

```json
{
  "valid": false,
  "source": "fixtures/invalid.json",
  "error_count": 20,
  "errors": [
    {
      "path": "$.model_profiles[1].id",
      "code": "duplicate_id",
      "message": "duplicate model profile id 'nebula-standard', already used by $.model_profiles[0]"
    },
    {
      "path": "$.model_profiles[2].model",
      "code": "empty_string",
      "message": "'model' must not be empty or whitespace-only"
    },
    {
      "path": "$.model_profiles[2].provider",
      "code": "empty_string",
      "message": "'provider' must not be empty or whitespace-only"
    },
    {
      "path": "$.model_profiles[3]",
      "code": "profile_not_object",
      "message": "model profile must be an object, got string"
    },
    {
      "path": "$.workers[1].concurrency_limit",
      "code": "out_of_range",
      "message": "'concurrency_limit' must be between 1 and 8, got 12"
    },
    {
      "path": "$.workers[1].id",
      "code": "duplicate_id",
      "message": "duplicate worker id 'worker-atlas-01', already used by $.workers[0]"
    }
  ]
}
```

Missing file — `python3 -B validate_config.py fixtures/nope.json`, exit code **2**.
(This transcript is illustrative; the same shape and the `file_not_found` code are
asserted by the subprocess tests, which run the CLI against a missing path.)

```json
{
  "valid": false,
  "source": "fixtures/nope.json",
  "error_count": 1,
  "errors": [
    {
      "path": "$",
      "code": "file_not_found",
      "message": "configuration file does not exist: fixtures/nope.json"
    }
  ]
}
```

## Exit codes

| Code | Meaning | stdout |
| --- | --- | --- |
| `0` | document is valid | JSON, `"valid": true`, `"errors": []` |
| `1` | document violates the specification | JSON, `"valid": false`, populated `errors` |
| `2` | file missing/unreadable, JSON syntax error, or CLI misuse | JSON, `"valid": false`, one file/CLI-level error at path `$` |

Exit code 2 always still prints valid JSON, so callers can parse stdout
unconditionally; exit code 1 for `fixtures/invalid.json` is the expected result.

## Fixtures

`fixtures/valid.json` — 3 fictional workers (levels `L1`, `L2`, `L3`) and 3
fictional model profiles. It exercises the inclusive boundaries `1`/`3600`
(timeout), `1`/`8` (concurrency) and carries extra keys
(`schema_version`, `description`, `labels`, `context_tokens`, `notes`) to show
that additional fields are accepted.

`fixtures/invalid.json` — 20 defects covering every code in the table above:

| Location | Defect |
| --- | --- |
| `$.workers[1].id` | duplicate of `$.workers[0].id` |
| `$.workers[3].id` | whitespace-only (`"   "`) |
| `$.workers[1].level` | `"L4"` — not `L1`/`L2`/`L3` |
| `$.workers[5].level` | `2` — not a string |
| `$.workers[1].timeout_seconds` | `0` — below range |
| `$.workers[3].timeout_seconds` | `3601` — above range |
| `$.workers[2].timeout_seconds` | `12.5` — fractional |
| `$.workers[4].timeout_seconds` | `"120"` — string |
| `$.workers[1].concurrency_limit` | `12` — above range |
| `$.workers[3].concurrency_limit` | `0` — below range |
| `$.workers[2].concurrency_limit` | `true` — boolean |
| `$.workers[4].concurrency_limit` | `null` |
| `$.workers[5].concurrency_limit` | missing entirely |
| `$.workers[1].model_profile` | `"ghost-profile"` — references no existing profile |
| `$.workers[4].model_profile` | whitespace-only |
| `$.workers[6]` | element is a string, not an object |
| `$.model_profiles[1].id` | duplicate of `$.model_profiles[0].id` |
| `$.model_profiles[2].provider` | whitespace-only |
| `$.model_profiles[2].model` | empty string |
| `$.model_profiles[3]` | element is a string, not an object |

Note `$.workers[5].model_profile` is `"ghost"`, which resolves to the (otherwise
malformed) profile at `$.model_profiles[2]`: reference checking uses ids only.

## Running the tests

```bash
python3 -B -m unittest discover -p 'test_*.py' -v
```

54 tests, no third-party dependencies, no network access. Coverage:

* **fixtures** — valid fixture yields zero errors; shape, unique ids and
  resolvable references; extra fields tolerated.
* **top level** — root type, both array types, both missing keys, empty
  collections.
* **workers** — element type, each required field missing, blank strings,
  non-string values, level whitelist (all three accepted, five rejected),
  duplicate ids (2-way and 3-way).
* **numeric fields** — range violations for both fields, inclusive boundaries,
  booleans rejected, fractional values rejected, strings/null/arrays/objects
  rejected.
* **model profiles** — element type, each required field missing, blank and
  non-string `provider`/`model`, duplicate ids, referrer orphaning on rename.
* **references** — unknown reference, first-occurrence resolution for duplicated
  ids, reference checks skipped when `model_profiles` is missing/blank.
* **aggregation** — independent errors collected together, stable `(path, code)`
  ordering, error object shape, no mutation of the input document, fixture error
  count and defect-class coverage.
* **CLI** — in-process `main()` and real subprocess runs: exit `0`/`1`/`2`,
  stdout is exactly one JSON object, stderr empty, missing file, directory
  argument, non-UTF-8 bytes, malformed JSON, wrong root type, and usage errors.
