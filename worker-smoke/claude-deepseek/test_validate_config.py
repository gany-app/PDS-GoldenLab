#!/usr/bin/env python3
"""Unit tests for validate_config.py.

Run from the project root with:

    python3 -B -m unittest discover -p 'test_*.py' -v
"""

from __future__ import annotations

import copy
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stdout

import validate_config as vc

MODULE_DIR = os.path.dirname(os.path.abspath(__file__))
VALID_FIXTURE = os.path.join(MODULE_DIR, "fixtures", "valid.json")
INVALID_FIXTURE = os.path.join(MODULE_DIR, "fixtures", "invalid.json")

# Total number of defects deliberately planted in fixtures/invalid.json.
INVALID_FIXTURE_ERROR_COUNT = 20


def load_fixture(path):
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)


def valid_document():
    """A pristine copy of fixtures/valid.json for mutation-based tests."""
    return copy.deepcopy(load_fixture(VALID_FIXTURE))


def error_keys(errors):
    return sorted((error["path"], error["code"]) for error in errors)


def errors_at(errors, path, code=None):
    return [
        error
        for error in errors
        if error["path"] == path and (code is None or error["code"] == code)
    ]


class FixtureTestCase(unittest.TestCase):
    """Shared helper: validate a document dict."""

    def validate(self, document):
        return vc.validate_document(document)


# --------------------------------------------------------------------------
# fixtures
# --------------------------------------------------------------------------


class TestValidFixture(FixtureTestCase):
    def test_valid_fixture_produces_no_errors(self):
        self.assertEqual(self.validate(load_fixture(VALID_FIXTURE)), [])

    def test_valid_fixture_shape(self):
        document = load_fixture(VALID_FIXTURE)
        self.assertGreaterEqual(len(document["workers"]), 3)
        self.assertGreaterEqual(len(document["model_profiles"]), 2)

    def test_valid_fixture_worker_ids_are_unique(self):
        document = load_fixture(VALID_FIXTURE)
        worker_ids = [worker["id"] for worker in document["workers"]]
        self.assertEqual(len(worker_ids), len(set(worker_ids)))

    def test_valid_fixture_references_resolve(self):
        document = load_fixture(VALID_FIXTURE)
        profile_ids = {profile["id"] for profile in document["model_profiles"]}
        for worker in document["workers"]:
            self.assertIn(worker["model_profile"], profile_ids)

    def test_extra_fields_are_allowed(self):
        document = valid_document()
        document["extra_top_level"] = {"anything": [1, 2, 3]}
        document["workers"][0]["extra_worker_field"] = "ignored"
        document["model_profiles"][0]["extra_profile_field"] = 42
        self.assertEqual(self.validate(document), [])


# --------------------------------------------------------------------------
# top level structure
# --------------------------------------------------------------------------


class TestTopLevel(FixtureTestCase):
    def test_root_must_be_object(self):
        for value in ([], "workers", 7, None, True):
            with self.subTest(root=value):
                errors = self.validate(value)
                self.assertEqual(error_keys(errors), [("$", "root_not_object")])

    def test_workers_must_be_array(self):
        document = valid_document()
        document["workers"] = {"id": "worker-atlas-01"}
        errors = self.validate(document)
        self.assertEqual(error_keys(errors), [("$.workers", "workers_not_array")])

    def test_model_profiles_must_be_array(self):
        document = valid_document()
        document["model_profiles"] = "nebula-standard"
        errors = self.validate(document)
        self.assertEqual(error_keys(errors), [("$.model_profiles", "model_profiles_not_array")])

    def test_missing_workers_key(self):
        document = valid_document()
        del document["workers"]
        errors = self.validate(document)
        self.assertEqual(error_keys(errors), [("$.workers", "missing_field")])

    def test_missing_model_profiles_key(self):
        document = valid_document()
        del document["model_profiles"]
        errors = self.validate(document)
        self.assertEqual(error_keys(errors), [("$.model_profiles", "missing_field")])

    def test_empty_collections_are_valid(self):
        self.assertEqual(self.validate({"workers": [], "model_profiles": []}), [])


# --------------------------------------------------------------------------
# worker entries
# --------------------------------------------------------------------------


class TestWorkers(FixtureTestCase):
    def test_worker_must_be_object(self):
        document = valid_document()
        document["workers"].append("worker-not-an-object")
        errors = self.validate(document)
        self.assertEqual(error_keys(errors), [("$.workers[3]", "worker_not_object")])

    def test_missing_required_worker_fields(self):
        required = ("id", "level", "model_profile", "timeout_seconds", "concurrency_limit")
        for field in required:
            with self.subTest(field=field):
                document = valid_document()
                del document["workers"][1][field]
                errors = self.validate(document)
                self.assertEqual(error_keys(errors), [("$.workers[1]." + field, "missing_field")])

    def test_blank_worker_strings_rejected(self):
        for field in ("id", "level", "model_profile"):
            for blank in ("", "   ", "\t\n"):
                with self.subTest(field=field, value=repr(blank)):
                    document = valid_document()
                    document["workers"][0][field] = blank
                    errors = self.validate(document)
                    self.assertEqual(
                        error_keys(errors), [("$.workers[0]." + field, "empty_string")]
                    )

    def test_non_string_worker_fields_rejected(self):
        for field in ("id", "level", "model_profile"):
            for value in (12, None, ["a"], {"id": "a"}):
                with self.subTest(field=field, value=value):
                    document = valid_document()
                    document["workers"][0][field] = value
                    errors = self.validate(document)
                    self.assertEqual(
                        error_keys(errors), [("$.workers[0]." + field, "not_a_string")]
                    )

    def test_level_must_be_one_of_l1_l2_l3(self):
        for level in ("L4", "L0", "l1", "L2 ", "HIGH"):
            with self.subTest(level=level):
                document = valid_document()
                document["workers"][0]["level"] = level
                errors = self.validate(document)
                self.assertEqual(error_keys(errors), [("$.workers[0].level", "invalid_level")])

    def test_all_allowed_levels_accepted(self):
        for level in vc.ALLOWED_LEVELS:
            with self.subTest(level=level):
                document = valid_document()
                for index in range(len(document["workers"])):
                    document["workers"][index]["level"] = level
                self.assertEqual(self.validate(document), [])

    def test_duplicate_worker_id_reported_on_second_entry(self):
        document = valid_document()
        document["workers"][2]["id"] = document["workers"][0]["id"]
        errors = self.validate(document)
        self.assertEqual(error_keys(errors), [("$.workers[2].id", "duplicate_id")])
        self.assertIn("worker-atlas-01", errors[0]["message"])
        self.assertIn("$.workers[0]", errors[0]["message"])

    def test_three_way_duplicate_reports_two_errors(self):
        document = valid_document()
        for index in (1, 2):
            document["workers"][index]["id"] = document["workers"][0]["id"]
        errors = self.validate(document)
        self.assertEqual(
            error_keys(errors),
            [("$.workers[1].id", "duplicate_id"), ("$.workers[2].id", "duplicate_id")],
        )


# --------------------------------------------------------------------------
# numeric worker fields
# --------------------------------------------------------------------------


class TestNumericFields(FixtureTestCase):
    def test_timeout_out_of_range(self):
        for value in (0, 3601, -1, 10 ** 6):
            with self.subTest(value=value):
                document = valid_document()
                document["workers"][0]["timeout_seconds"] = value
                errors = self.validate(document)
                self.assertEqual(
                    error_keys(errors), [("$.workers[0].timeout_seconds", "out_of_range")]
                )

    def test_concurrency_out_of_range(self):
        for value in (0, 9, -3, 100):
            with self.subTest(value=value):
                document = valid_document()
                document["workers"][0]["concurrency_limit"] = value
                errors = self.validate(document)
                self.assertEqual(
                    error_keys(errors), [("$.workers[0].concurrency_limit", "out_of_range")]
                )

    def test_boundary_values_are_accepted(self):
        document = valid_document()
        document["workers"][0]["timeout_seconds"] = 1
        document["workers"][0]["concurrency_limit"] = 1
        document["workers"][1]["timeout_seconds"] = 3600
        document["workers"][1]["concurrency_limit"] = 8
        document["workers"][2]["timeout_seconds"] = 1800
        document["workers"][2]["concurrency_limit"] = 4
        self.assertEqual(self.validate(document), [])

    def test_bool_is_not_an_integer(self):
        for value in (True, False):
            with self.subTest(value=value):
                document = valid_document()
                document["workers"][0]["timeout_seconds"] = value
                document["workers"][0]["concurrency_limit"] = value
                errors = self.validate(document)
                self.assertEqual(
                    error_keys(errors),
                    [
                        ("$.workers[0].concurrency_limit", "not_an_integer"),
                        ("$.workers[0].timeout_seconds", "not_an_integer"),
                    ],
                )

    def test_fractional_numbers_are_not_integers(self):
        for value in (12.5, 2.0, 1.0, 0.5):
            with self.subTest(value=value):
                document = valid_document()
                document["workers"][0]["concurrency_limit"] = value
                errors = self.validate(document)
                self.assertEqual(
                    error_keys(errors),
                    [("$.workers[0].concurrency_limit", "not_an_integer")],
                )

    def test_non_numeric_values_are_rejected(self):
        for value in ("120", None, [120], {"value": 120}):
            with self.subTest(value=value):
                document = valid_document()
                document["workers"][0]["timeout_seconds"] = value
                errors = self.validate(document)
                self.assertEqual(
                    error_keys(errors), [("$.workers[0].timeout_seconds", "not_an_integer")]
                )


# --------------------------------------------------------------------------
# model profiles
# --------------------------------------------------------------------------


class TestModelProfiles(FixtureTestCase):
    def test_profile_must_be_object(self):
        document = valid_document()
        document["model_profiles"].append(None)
        errors = self.validate(document)
        self.assertEqual(error_keys(errors), [("$.model_profiles[3]", "profile_not_object")])

    def test_missing_required_profile_fields(self):
        # Deliberately uses a worker-free document so that dropping a profile id
        # cannot also surface as a dangling worker reference.
        for field in ("id", "provider", "model"):
            with self.subTest(field=field):
                document = {
                    "workers": [],
                    "model_profiles": [
                        {"id": "profile-01", "provider": "Fictional Provider", "model": "fictional-model-1"}
                    ],
                }
                del document["model_profiles"][0][field]
                errors = self.validate(document)
                self.assertEqual(
                    error_keys(errors), [("$.model_profiles[0]." + field, "missing_field")]
                )

    def test_blank_provider_and_model_rejected(self):
        for field in ("provider", "model"):
            with self.subTest(field=field):
                document = valid_document()
                document["model_profiles"][0][field] = "  "
                errors = self.validate(document)
                self.assertEqual(
                    error_keys(errors), [("$.model_profiles[0]." + field, "empty_string")]
                )

    def test_non_string_provider_and_model_rejected(self):
        for field in ("provider", "model"):
            with self.subTest(field=field):
                document = valid_document()
                document["model_profiles"][0][field] = 7
                errors = self.validate(document)
                self.assertEqual(
                    error_keys(errors), [("$.model_profiles[0]." + field, "not_a_string")]
                )

    def test_duplicate_profile_id(self):
        document = valid_document()
        document["model_profiles"][1]["id"] = "nebula-standard"
        # keep the reference of the renaming worker resolvable, so the only defect
        # under test is the duplicate profile id itself
        document["workers"][1]["model_profile"] = "nebula-standard"
        errors = self.validate(document)
        self.assertEqual(error_keys(errors), [("$.model_profiles[1].id", "duplicate_id")])

    def test_renaming_a_profile_id_orphans_its_referrers(self):
        document = valid_document()
        document["model_profiles"][1]["id"] = "nebula-renamed"
        errors = self.validate(document)
        self.assertEqual(
            error_keys(errors), [("$.workers[1].model_profile", "unknown_model_profile")]
        )


# --------------------------------------------------------------------------
# cross references
# --------------------------------------------------------------------------


class TestReferences(FixtureTestCase):
    def test_unknown_model_profile_reference(self):
        document = valid_document()
        document["workers"][1]["model_profile"] = "no-such-profile"
        errors = self.validate(document)
        self.assertEqual(
            error_keys(errors), [("$.workers[1].model_profile", "unknown_model_profile")]
        )

    def test_reference_resolves_against_first_duplicated_id(self):
        document = valid_document()
        document["model_profiles"][1]["id"] = "nebula-standard"
        document["workers"][0]["model_profile"] = "nebula-standard"
        document["workers"][1]["model_profile"] = "nebula-standard"
        errors = self.validate(document)
        self.assertEqual(error_keys(errors), [("$.model_profiles[1].id", "duplicate_id")])

    def test_reference_check_skipped_when_profiles_missing(self):
        document = valid_document()
        del document["model_profiles"]
        errors = self.validate(document)
        self.assertEqual(error_keys(errors), [("$.model_profiles", "missing_field")])

    def test_reference_check_skipped_for_blank_reference(self):
        document = valid_document()
        document["workers"][0]["model_profile"] = "   "
        errors = self.validate(document)
        self.assertEqual(error_keys(errors), [("$.workers[0].model_profile", "empty_string")])


# --------------------------------------------------------------------------
# aggregation, sorting and error shape
# --------------------------------------------------------------------------


class TestAggregationAndOrdering(FixtureTestCase):
    def test_independent_errors_are_aggregated(self):
        document = valid_document()
        document["workers"][0]["level"] = "L9"
        document["workers"][0]["timeout_seconds"] = 99999
        document["workers"][1]["concurrency_limit"] = True
        document["model_profiles"][2]["provider"] = ""
        errors = self.validate(document)
        self.assertEqual(
            error_keys(errors),
            [
                ("$.model_profiles[2].provider", "empty_string"),
                ("$.workers[0].level", "invalid_level"),
                ("$.workers[0].timeout_seconds", "out_of_range"),
                ("$.workers[1].concurrency_limit", "not_an_integer"),
            ],
        )

    def test_errors_sorted_by_path_then_code_and_stable(self):
        document = valid_document()
        document["workers"][2]["id"] = "worker-atlas-01"
        document["workers"][2]["level"] = "L7"
        document["workers"][2]["timeout_seconds"] = 0
        errors = self.validate(document)
        self.assertEqual(error_keys(errors), error_keys(sorted(errors, key=lambda e: (e["path"], e["code"]))))
        paths = [error["path"] for error in errors]
        self.assertEqual(paths, sorted(paths))
        # repeated runs must be byte-for-byte identical
        self.assertEqual(
            json.dumps(self.validate(document)), json.dumps(self.validate(document))
        )

    def test_every_error_carries_path_code_message(self):
        for fixture in (VALID_FIXTURE, INVALID_FIXTURE):
            document = load_fixture(fixture)
            for error in self.validate(document):
                with self.subTest(error=error):
                    self.assertEqual(set(error), {"path", "code", "message"})
                    self.assertIsInstance(error["path"], str)
                    self.assertTrue(error["path"].startswith("$"))
                    self.assertIsInstance(error["code"], str)
                    self.assertIsInstance(error["message"], str)
                    self.assertNotEqual(error["message"].strip(), "")

    def test_validation_does_not_mutate_the_document(self):
        document = load_fixture(INVALID_FIXTURE)
        before = json.dumps(document, sort_keys=True)
        self.validate(document)
        self.assertEqual(json.dumps(document, sort_keys=True), before)

    def test_invalid_fixture_error_count(self):
        errors = self.validate(load_fixture(INVALID_FIXTURE))
        self.assertEqual(len(errors), INVALID_FIXTURE_ERROR_COUNT)

    def test_invalid_fixture_covers_every_required_defect_class(self):
        errors = self.validate(load_fixture(INVALID_FIXTURE))
        codes = {error["code"] for error in errors}
        for code in (
            "duplicate_id",
            "invalid_level",
            "out_of_range",
            "not_an_integer",
            "unknown_model_profile",
            "missing_field",
            "empty_string",
            "not_a_string",
            "worker_not_object",
            "profile_not_object",
        ):
            with self.subTest(code=code):
                self.assertIn(code, codes)


# --------------------------------------------------------------------------
# CLI behaviour (in-process: exit code + stdout content)
# --------------------------------------------------------------------------


class TestMainFunction(unittest.TestCase):
    def run_main(self, arguments):
        buffer = io.StringIO()
        with redirect_stdout(buffer):
            exit_code = vc.main(arguments)
        raw = buffer.getvalue()
        return exit_code, raw, json.loads(raw)

    def test_valid_fixture_in_process(self):
        exit_code, raw, payload = self.run_main([VALID_FIXTURE])
        self.assertEqual(exit_code, 0)
        self.assertTrue(payload["valid"])
        self.assertEqual(payload["errors"], [])
        self.assertEqual(payload["error_count"], 0)

    def test_invalid_fixture_in_process(self):
        exit_code, raw, payload = self.run_main([INVALID_FIXTURE])
        self.assertEqual(exit_code, 1)
        self.assertFalse(payload["valid"])
        self.assertEqual(payload["error_count"], INVALID_FIXTURE_ERROR_COUNT)
        self.assertEqual(len(payload["errors"]), INVALID_FIXTURE_ERROR_COUNT)

    def test_missing_file_in_process(self):
        exit_code, raw, payload = self.run_main([os.path.join(MODULE_DIR, "no-such-file.json")])
        self.assertEqual(exit_code, 2)
        self.assertFalse(payload["valid"])
        self.assertEqual(payload["errors"][0]["code"], "file_not_found")

    def test_usage_error_in_process(self):
        for arguments in ([], [VALID_FIXTURE, INVALID_FIXTURE]):
            with self.subTest(arguments=arguments):
                exit_code, raw, payload = self.run_main(arguments)
                self.assertEqual(exit_code, 2)
                self.assertEqual(payload["errors"][0]["code"], "cli_usage_error")

    def test_stdout_is_exactly_one_json_object(self):
        for arguments in ([VALID_FIXTURE], [INVALID_FIXTURE]):
            with self.subTest(arguments=arguments):
                exit_code, raw, payload = self.run_main(arguments)
                self.assertTrue(raw.endswith("\n"))
                self.assertEqual(raw.strip(), json.dumps(payload, ensure_ascii=False, indent=2))


# --------------------------------------------------------------------------
# CLI behaviour (subprocess: real process + real exit codes)
# --------------------------------------------------------------------------


class TestCliSubprocess(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tempdir = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.tempdir.cleanup)

    def write_temp(self, name, text, binary=False):
        path = os.path.join(self.tempdir.name, name)
        if binary:
            with open(path, "wb") as handle:
                handle.write(text)
        else:
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(text)
        return path

    def run_cli(self, *arguments):
        return subprocess.run(
            [sys.executable, "-B", "validate_config.py", *arguments],
            cwd=MODULE_DIR,
            capture_output=True,
            text=True,
        )

    def test_valid_fixture_exit_0(self):
        completed = self.run_cli("fixtures/valid.json")
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(completed.stderr, "")
        payload = json.loads(completed.stdout)
        self.assertTrue(payload["valid"])
        self.assertEqual(payload["errors"], [])
        self.assertEqual(payload["source"], "fixtures/valid.json")

    def test_invalid_fixture_exit_1(self):
        completed = self.run_cli("fixtures/invalid.json")
        self.assertEqual(completed.returncode, 1, completed.stderr)
        self.assertEqual(completed.stderr, "")
        payload = json.loads(completed.stdout)
        self.assertFalse(payload["valid"])
        self.assertEqual(payload["error_count"], INVALID_FIXTURE_ERROR_COUNT)

    def test_missing_file_exit_2(self):
        completed = self.run_cli("fixtures/does-not-exist.json")
        self.assertEqual(completed.returncode, 2, completed.stderr)
        payload = json.loads(completed.stdout)
        self.assertFalse(payload["valid"])
        self.assertEqual(payload["errors"][0]["code"], "file_not_found")

    def test_malformed_json_exit_2(self):
        path = self.write_temp("broken.json", '{"workers": [')
        completed = self.run_cli(path)
        self.assertEqual(completed.returncode, 2, completed.stderr)
        payload = json.loads(completed.stdout)
        self.assertEqual(payload["errors"][0]["code"], "invalid_json_syntax")

    def test_directory_argument_exit_2(self):
        completed = self.run_cli("fixtures")
        self.assertEqual(completed.returncode, 2, completed.stderr)
        payload = json.loads(completed.stdout)
        self.assertEqual(payload["errors"][0]["code"], "file_not_readable")

    def test_non_utf8_file_exit_2(self):
        path = self.write_temp("latin1.json", b'{"workers": [], "model_profiles": [], "x": "\xff\xfe"}', binary=True)
        completed = self.run_cli(path)
        self.assertEqual(completed.returncode, 2, completed.stderr)
        payload = json.loads(completed.stdout)
        self.assertEqual(payload["errors"][0]["code"], "file_not_readable")

    def test_usage_error_exit_2(self):
        completed = self.run_cli()
        self.assertEqual(completed.returncode, 2)
        payload = json.loads(completed.stdout)
        self.assertEqual(payload["errors"][0]["code"], "cli_usage_error")

    def test_invalid_json_payload_still_exit_1(self):
        path = self.write_temp("wrong_types.json", json.dumps([1, 2, 3]))
        completed = self.run_cli(path)
        self.assertEqual(completed.returncode, 1)
        payload = json.loads(completed.stdout)
        self.assertEqual(payload["errors"][0]["code"], "root_not_object")


if __name__ == "__main__":
    unittest.main(verbosity=2)
