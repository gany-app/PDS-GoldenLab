#!/usr/bin/env python3
"""Validate a PDS-Bridge worker / model-profile configuration document.

Usage:
    python3 validate_config.py <config.json>

The command writes exactly one JSON object to stdout and never lets an
exception escape.  Exit codes:

    0  the document is valid
    1  the document violates the configuration specification
    2  the document could not be read or parsed as JSON (also used for CLI misuse)

Parsing is strict: only standard JSON is accepted, so the non-standard numeric
constants ``NaN``, ``Infinity`` and ``-Infinity`` that Python's ``json`` module
tolerates by default are reported as ``invalid_json_syntax`` (exit 2) instead.
"""

from __future__ import annotations

import json
import sys
from typing import Any

ALLOWED_LEVELS = ("L1", "L2", "L3")
TIMEOUT_MIN = 1
TIMEOUT_MAX = 3600
CONCURRENCY_MIN = 1
CONCURRENCY_MAX = 8

EXIT_VALID = 0
EXIT_INVALID = 1
EXIT_FILE_ERROR = 2

WORKER_REQUIRED_FIELDS = (
    "id",
    "level",
    "model_profile",
    "timeout_seconds",
    "concurrency_limit",
)
PROFILE_REQUIRED_FIELDS = ("id", "provider", "model")

ROOT_PATH = "$"
WORKERS_PATH = "$.workers"
PROFILES_PATH = "$.model_profiles"


class ConfigFileError(Exception):
    """The configuration file could not be read or parsed."""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


# --------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------


def _error(path: str, code: str, message: str) -> dict:
    return {"path": path, "code": code, "message": message}


def _type_name(value: Any) -> str:
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "boolean"
    if isinstance(value, int):
        return "integer"
    if isinstance(value, float):
        return "number"
    if isinstance(value, str):
        return "string"
    if isinstance(value, list):
        return "array"
    if isinstance(value, dict):
        return "object"
    return type(value).__name__


def _is_int(value: Any) -> bool:
    """True only for real integers: bool is rejected despite being int's subclass."""
    return isinstance(value, int) and not isinstance(value, bool)


def _required_string(container: dict, field: str, path: str, errors: list) -> str | None:
    """Validate a required non-blank string field; return it or None if unusable."""
    field_path = "{0}.{1}".format(path, field)
    if field not in container:
        errors.append(
            _error(field_path, "missing_field", "required field '{0}' is missing".format(field))
        )
        return None
    value = container[field]
    if not isinstance(value, str):
        errors.append(
            _error(
                field_path,
                "not_a_string",
                "'{0}' must be a string, got {1}".format(field, _type_name(value)),
            )
        )
        return None
    if not value.strip():
        errors.append(
            _error(
                field_path,
                "empty_string",
                "'{0}' must not be empty or whitespace-only".format(field),
            )
        )
        return None
    return value


def _required_int(
    container: dict, field: str, path: str, low: int, high: int, errors: list
) -> int | None:
    """Validate a required bounded integer field; return it or None if unusable."""
    field_path = "{0}.{1}".format(path, field)
    if field not in container:
        errors.append(
            _error(field_path, "missing_field", "required field '{0}' is missing".format(field))
        )
        return None
    value = container[field]
    if not _is_int(value):
        errors.append(
            _error(
                field_path,
                "not_an_integer",
                "'{0}' must be an integer, got {1}".format(field, _type_name(value)),
            )
        )
        return None
    if value < low or value > high:
        errors.append(
            _error(
                field_path,
                "out_of_range",
                "'{0}' must be between {1} and {2}, got {3}".format(field, low, high, value),
            )
        )
        return None
    return value


# --------------------------------------------------------------------------
# document validation
# --------------------------------------------------------------------------


def validate_document(document: Any) -> list:
    """Validate a decoded JSON document and return errors sorted by (path, code)."""
    errors: list = []

    if not isinstance(document, dict):
        errors.append(
            _error(
                ROOT_PATH,
                "root_not_object",
                "top level must be a JSON object, got {0}".format(_type_name(document)),
            )
        )
        return errors

    workers = document.get("workers")
    if "workers" not in document:
        errors.append(_error(WORKERS_PATH, "missing_field", "required field 'workers' is missing"))
        workers = []
    elif not isinstance(workers, list):
        errors.append(
            _error(
                WORKERS_PATH,
                "workers_not_array",
                "'workers' must be an array, got {0}".format(_type_name(workers)),
            )
        )
        workers = []

    profiles = document.get("model_profiles")
    profiles_usable = True
    if "model_profiles" not in document:
        errors.append(
            _error(PROFILES_PATH, "missing_field", "required field 'model_profiles' is missing")
        )
        profiles = []
        profiles_usable = False
    elif not isinstance(profiles, list):
        errors.append(
            _error(
                PROFILES_PATH,
                "model_profiles_not_array",
                "'model_profiles' must be an array, got {0}".format(_type_name(profiles)),
            )
        )
        profiles = []
        profiles_usable = False

    worker_ids: dict = {}
    profile_ids: dict = {}
    pending_references: list = []

    for index, worker in enumerate(workers):
        path = "{0}[{1}]".format(WORKERS_PATH, index)
        if not isinstance(worker, dict):
            errors.append(
                _error(
                    path,
                    "worker_not_object",
                    "worker must be an object, got {0}".format(_type_name(worker)),
                )
            )
            continue

        worker_id = _required_string(worker, "id", path, errors)
        level = _required_string(worker, "level", path, errors)
        if level is not None and level not in ALLOWED_LEVELS:
            errors.append(
                _error(
                    "{0}.level".format(path),
                    "invalid_level",
                    "'level' must be one of {0}, got {1!r}".format(
                        ", ".join(ALLOWED_LEVELS), level
                    ),
                )
            )
        profile_reference = _required_string(worker, "model_profile", path, errors)
        _required_int(worker, "timeout_seconds", path, TIMEOUT_MIN, TIMEOUT_MAX, errors)
        _required_int(worker, "concurrency_limit", path, CONCURRENCY_MIN, CONCURRENCY_MAX, errors)

        if worker_id is not None:
            if worker_id in worker_ids:
                errors.append(
                    _error(
                        "{0}.id".format(path),
                        "duplicate_id",
                        "duplicate worker id {0!r}, already used by {1}[{2}]".format(
                            worker_id, WORKERS_PATH, worker_ids[worker_id]
                        ),
                    )
                )
            else:
                worker_ids[worker_id] = index

        if profile_reference is not None:
            pending_references.append(("{0}.model_profile".format(path), profile_reference))

    for index, profile in enumerate(profiles):
        path = "{0}[{1}]".format(PROFILES_PATH, index)
        if not isinstance(profile, dict):
            errors.append(
                _error(
                    path,
                    "profile_not_object",
                    "model profile must be an object, got {0}".format(_type_name(profile)),
                )
            )
            continue

        profile_id = _required_string(profile, "id", path, errors)
        _required_string(profile, "provider", path, errors)
        _required_string(profile, "model", path, errors)

        if profile_id is not None:
            if profile_id in profile_ids:
                errors.append(
                    _error(
                        "{0}.id".format(path),
                        "duplicate_id",
                        "duplicate model profile id {0!r}, already used by {1}[{2}]".format(
                            profile_id, PROFILES_PATH, profile_ids[profile_id]
                        ),
                    )
                )
            else:
                profile_ids[profile_id] = index

    if profiles_usable:
        for reference_path, reference in pending_references:
            if reference not in profile_ids:
                errors.append(
                    _error(
                        reference_path,
                        "unknown_model_profile",
                        "model_profile {0!r} does not match any model_profiles[].id".format(
                            reference
                        ),
                    )
                )

    errors.sort(key=lambda item: (item["path"], item["code"]))
    return errors


# --------------------------------------------------------------------------
# file loading / CLI
# --------------------------------------------------------------------------


def _reject_non_standard_number(name: str) -> Any:
    """Reject NaN / Infinity / -Infinity: valid in Python, not valid JSON.

    Used as ``json.loads(..., parse_constant=...)``.  The raised ValueError is
    turned into ConfigFileError("invalid_json_syntax", ...) by load_document().
    """
    raise ValueError(
        "non-standard JSON number {0!r} is not allowed "
        "(NaN, Infinity and -Infinity are not valid JSON)".format(name)
    )


def load_document(path: str) -> Any:
    """Read and decode a JSON document; raise ConfigFileError when impossible.

    The document is parsed as strict JSON: Python's default acceptance of the
    NaN, Infinity and -Infinity literals is disabled via ``parse_constant``.
    """
    try:
        with open(path, "r", encoding="utf-8") as handle:
            raw = handle.read()
    except FileNotFoundError as exc:
        raise ConfigFileError(
            "file_not_found", "configuration file does not exist: {0}".format(path)
        ) from exc
    except IsADirectoryError as exc:
        raise ConfigFileError(
            "file_not_readable", "configuration path is a directory, not a file: {0}".format(path)
        ) from exc
    except PermissionError as exc:
        raise ConfigFileError(
            "file_not_readable", "configuration file is not readable: {0}".format(path)
        ) from exc
    except UnicodeDecodeError as exc:
        raise ConfigFileError(
            "file_not_readable", "configuration file is not valid UTF-8 text: {0}".format(path)
        ) from exc
    except OSError as exc:
        raise ConfigFileError(
            "file_not_readable",
            "configuration file could not be read: {0} ({1})".format(path, exc.strerror),
        ) from exc

    try:
        return json.loads(raw, parse_constant=_reject_non_standard_number)
    except json.JSONDecodeError as exc:
        raise ConfigFileError(
            "invalid_json_syntax",
            "configuration file is not valid JSON: {0} (line {1}, column {2})".format(
                exc.msg, exc.lineno, exc.colno
            ),
        ) from exc
    except (RecursionError, ValueError) as exc:
        raise ConfigFileError(
            "invalid_json_syntax",
            "configuration file is not valid JSON: {0}".format(exc),
        ) from exc


def build_result(valid: bool, errors: list, source: Any) -> dict:
    return {
        "valid": valid,
        "source": source,
        "error_count": len(errors),
        "errors": errors,
    }


def _emit(payload: dict, exit_code: int) -> int:
    sys.stdout.write(json.dumps(payload, ensure_ascii=False, indent=2) + "\n")
    sys.stdout.flush()
    return exit_code


def main(argv: Any = None) -> int:
    """Run the CLI and return the process exit code. Never raises."""
    arguments = list(sys.argv[1:] if argv is None else argv)

    try:
        if len(arguments) != 1:
            errors = [
                _error(
                    ROOT_PATH,
                    "cli_usage_error",
                    "expected exactly one argument: the path to a configuration file",
                )
            ]
            return _emit(build_result(False, errors, None), EXIT_FILE_ERROR)

        source = arguments[0]
        document = load_document(source)
    except ConfigFileError as exc:
        errors = [_error(ROOT_PATH, exc.code, exc.message)]
        return _emit(build_result(False, errors, arguments[0] if arguments else None), EXIT_FILE_ERROR)
    except Exception as exc:  # pragma: no cover - last-resort safety net
        errors = [
            _error(
                ROOT_PATH,
                "internal_error",
                "unexpected failure while reading configuration: {0}".format(exc),
            )
        ]
        return _emit(build_result(False, errors, arguments[0] if arguments else None), EXIT_FILE_ERROR)

    try:
        errors = validate_document(document)
    except Exception as exc:  # pragma: no cover - last-resort safety net
        errors = [
            _error(
                ROOT_PATH,
                "internal_error",
                "unexpected failure while validating configuration: {0}".format(exc),
            )
        ]
        return _emit(build_result(False, errors, source), EXIT_FILE_ERROR)

    return _emit(build_result(not errors, errors, source), EXIT_VALID if not errors else EXIT_INVALID)


if __name__ == "__main__":
    sys.exit(main())
