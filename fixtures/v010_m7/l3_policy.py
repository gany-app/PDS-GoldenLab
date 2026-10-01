"""Small, immutable policy model with deterministic boolean fact evaluation.

Each rule names a fact, an effect (ALLOW or DENY), and a reason code. A fact is
known only when its value is exactly True or False. True triggers the rule;
False does not. A missing fact or None is unknown. An unknown fact on a rule
marked required requires human review.

Results have this priority: unknown required fact -> NEEDS_HUMAN, triggered
DENY -> DENY, triggered ALLOW -> ALLOW, otherwise -> DENY. Every triggered
rule and unknown required fact contributes a reason in policy rule order,
regardless of the final result. The fallback DENY adds NO_ALLOW_MATCH.
"""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass


ALLOW = "ALLOW"
DENY = "DENY"
NEEDS_HUMAN = "NEEDS_HUMAN"
_MISSING = object()


@dataclass(frozen=True, slots=True)
class Rule:
    fact: str
    effect: str
    reason_code: str
    required: bool = False

    def __post_init__(self) -> None:
        if not isinstance(self.fact, str) or not self.fact.strip():
            raise ValueError("fact must be a nonempty string")
        if self.effect not in (ALLOW, DENY):
            raise ValueError("effect must be ALLOW or DENY")
        if not isinstance(self.reason_code, str) or not self.reason_code.strip():
            raise ValueError("reason_code must be a nonempty string")
        if type(self.required) is not bool:
            raise TypeError("required must be a bool")


@dataclass(frozen=True, slots=True)
class Policy:
    rules: tuple[Rule, ...]

    def __post_init__(self) -> None:
        rules = tuple(self.rules)
        if any(not isinstance(rule, Rule) for rule in rules):
            raise TypeError("rules must contain only Rule instances")
        object.__setattr__(self, "rules", rules)


@dataclass(frozen=True, slots=True)
class Decision:
    result: str
    reason_codes: tuple[str, ...]

    def __post_init__(self) -> None:
        if self.result not in (ALLOW, DENY, NEEDS_HUMAN):
            raise ValueError("result must be ALLOW, DENY, or NEEDS_HUMAN")
        codes = tuple(self.reason_codes)
        if any(not isinstance(code, str) or not code.strip() for code in codes):
            raise ValueError("reason_codes must contain nonempty strings")
        object.__setattr__(self, "reason_codes", codes)


def evaluate_policy(policy: Policy, facts: Mapping[str, bool | None]) -> Decision:
    """Evaluate a snapshot of facts without changing either input.

    Unknown optional facts do not trigger a rule. Invalid values on referenced
    facts raise TypeError rather than relying on Python truthiness.
    """
    if not isinstance(policy, Policy):
        raise TypeError("policy must be a Policy")
    if not isinstance(facts, Mapping):
        raise TypeError("facts must be a mapping")

    fact_snapshot = dict(facts)
    reasons: list[str] = []
    unknown_required = False
    has_deny = False
    has_allow = False

    for rule in policy.rules:
        value = fact_snapshot.get(rule.fact, _MISSING)
        if value is _MISSING or value is None:
            if rule.required:
                unknown_required = True
                reasons.append(f"UNKNOWN_REQUIRED:{rule.fact}")
            continue
        if type(value) is not bool:
            raise TypeError(f"fact {rule.fact!r} must be True, False, or None")
        if value:
            reasons.append(rule.reason_code)
            if rule.effect == DENY:
                has_deny = True
            else:
                has_allow = True

    if unknown_required:
        result = NEEDS_HUMAN
    elif has_deny:
        result = DENY
    elif has_allow:
        result = ALLOW
    else:
        result = DENY
        reasons.append("NO_ALLOW_MATCH")
    return Decision(result, tuple(reasons))
