"""Behavioral tests for the immutable policy model."""

import unittest
from dataclasses import FrozenInstanceError

from fixtures.v010_m7.l3_policy import (
    ALLOW,
    DENY,
    NEEDS_HUMAN,
    Decision,
    Policy,
    Rule,
    evaluate_policy,
)


class EvaluatePolicyTests(unittest.TestCase):
    def test_allow(self):
        policy = Policy((Rule("eligible", ALLOW, "ELIGIBLE", required=True),))

        self.assertEqual(
            evaluate_policy(policy, {"eligible": True}),
            Decision(ALLOW, ("ELIGIBLE",)),
        )

    def test_explicit_deny(self):
        policy = Policy((Rule("blocked", DENY, "BLOCKED"),))

        self.assertEqual(
            evaluate_policy(policy, {"blocked": True}),
            Decision(DENY, ("BLOCKED",)),
        )

    def test_no_matching_allow_defaults_to_deny(self):
        policy = Policy((Rule("eligible", ALLOW, "ELIGIBLE"),))

        self.assertEqual(
            evaluate_policy(policy, {"eligible": False}),
            Decision(DENY, ("NO_ALLOW_MATCH",)),
        )

    def test_explicit_deny_outweighs_allow(self):
        policy = Policy(
            (
                Rule("eligible", ALLOW, "ELIGIBLE"),
                Rule("blocked", DENY, "BLOCKED"),
            )
        )

        self.assertEqual(
            evaluate_policy(policy, {"eligible": True, "blocked": True}),
            Decision(DENY, ("ELIGIBLE", "BLOCKED")),
        )

    def test_missing_and_none_required_facts_need_human(self):
        policy = Policy((Rule("verified", ALLOW, "VERIFIED", required=True),))

        for facts in ({}, {"verified": None}):
            with self.subTest(facts=facts):
                self.assertEqual(
                    evaluate_policy(policy, facts),
                    Decision(NEEDS_HUMAN, ("UNKNOWN_REQUIRED:verified",)),
                )

    def test_unknown_required_has_priority_over_triggered_rules(self):
        policy = Policy(
            (
                Rule("eligible", ALLOW, "ELIGIBLE"),
                Rule("verified", ALLOW, "VERIFIED", required=True),
                Rule("blocked", DENY, "BLOCKED"),
            )
        )

        self.assertEqual(
            evaluate_policy(policy, {"eligible": True, "blocked": True}),
            Decision(
                NEEDS_HUMAN,
                ("ELIGIBLE", "UNKNOWN_REQUIRED:verified", "BLOCKED"),
            ),
        )

    def test_reason_codes_follow_rule_order_and_keep_duplicates(self):
        policy = Policy(
            (
                Rule("first", ALLOW, "MATCH"),
                Rule("skip", ALLOW, "SKIP"),
                Rule("second", DENY, "MATCH"),
                Rule("unknown", ALLOW, "UNKNOWN", required=True),
                Rule("last", ALLOW, "LAST"),
            )
        )
        facts = {"last": True, "second": True, "skip": False, "first": True}

        self.assertEqual(
            evaluate_policy(policy, facts).reason_codes,
            ("MATCH", "MATCH", "UNKNOWN_REQUIRED:unknown", "LAST"),
        )

    def test_models_and_input_collections_are_immutable_snapshots(self):
        source_rules = [Rule("eligible", ALLOW, "ELIGIBLE")]
        policy = Policy(source_rules)
        source_rules.append(Rule("blocked", DENY, "BLOCKED"))
        source_codes = ["ELIGIBLE"]
        decision = Decision(ALLOW, source_codes)
        source_codes.append("LATER")

        self.assertEqual(len(policy.rules), 1)
        self.assertEqual(decision.reason_codes, ("ELIGIBLE",))
        for model, field, replacement in (
            (policy, "rules", ()),
            (policy.rules[0], "effect", DENY),
            (decision, "result", DENY),
            (decision, "reason_codes", ()),
        ):
            with self.subTest(model=model, field=field):
                with self.assertRaises(FrozenInstanceError):
                    setattr(model, field, replacement)

    def test_evaluation_does_not_change_policy_or_facts(self):
        policy = Policy(
            (
                Rule("eligible", ALLOW, "ELIGIBLE", required=True),
                Rule("blocked", DENY, "BLOCKED"),
            )
        )
        facts = {"eligible": True, "blocked": False, "extra": "untouched"}
        original_rules = policy.rules
        original_facts = facts.copy()

        first = evaluate_policy(policy, facts)
        second = evaluate_policy(policy, facts)

        self.assertEqual(first, second)
        self.assertEqual(policy.rules, original_rules)
        self.assertEqual(facts, original_facts)

    def test_invalid_fact_value_is_rejected(self):
        policy = Policy((Rule("eligible", ALLOW, "ELIGIBLE"),))

        with self.assertRaises(TypeError):
            evaluate_policy(policy, {"eligible": 1})


if __name__ == "__main__":
    unittest.main()
