"""Summarize a UTF-8 CSV whose header is name,amount.

The amount column is parsed with decimal.Decimal so the summation keeps
exact decimal precision and never round-trips through float.
"""

import csv
from decimal import Decimal, InvalidOperation

ZERO = Decimal("0")


def summarize(path):
    """Return {"rows": data row count, "total": exact amount sum string}.

    The header row is not counted. Empty files and header-only files both
    yield {"rows": 0, "total": "0"}. An unparsable amount raises ValueError
    whose message carries the offending line number in the input file.
    """
    rows = 0
    total = ZERO
    with open(path, newline="", encoding="utf-8") as handle:
        reader = csv.reader(handle)
        next(reader, None)
        for row in reader:
            if not row:
                continue
            rows += 1
            raw = row[1] if len(row) > 1 else ""
            try:
                total += Decimal(raw)
            except (InvalidOperation, ValueError):
                raise ValueError(
                    "invalid amount on line %d: %r" % (reader.line_num, raw)
                )
    return {"rows": rows, "total": str(total)}
