"""L2 Unicode slug normalization."""

import re

_WHITESPACE_OR_UNDERSCORE = re.compile(r"[\s_]+")
_CONSECUTIVE_HYPHENS = re.compile(r"-+")


def normalize_slug(text):
    """Normalize text into a lowercase Unicode slug.

    Unicode whitespace is trimmed, runs of whitespace or underscores become a
    single hyphen, ASCII letters are lowercased, characters other than Unicode
    alphanumerics and hyphens are removed, and hyphens are collapsed and
    trimmed from both ends.
    """
    if not isinstance(text, str):
        raise TypeError("text must be a str")

    slug = text.strip()
    slug = _WHITESPACE_OR_UNDERSCORE.sub("-", slug)
    slug = "".join(ch.lower() if "A" <= ch <= "Z" else ch for ch in slug)
    slug = "".join(ch for ch in slug if ch == "-" or ch.isalnum())
    slug = _CONSECUTIVE_HYPHENS.sub("-", slug)
    return slug.strip("-")
