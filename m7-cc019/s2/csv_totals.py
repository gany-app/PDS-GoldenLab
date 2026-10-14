"""Summarize a UTF-8 CSV whose header is name,amount.

The amount column is parsed with decimal.Decimal so the summation keeps
exact decimal precision and never round-trips through float.
"""

import csv
from decimal import Decimal, InvalidOperation


def _accumulate(total, amount):
    """Add amount to an exact (coeff, scale) total.

    Both operands are represented as ``coeff * 10 ** -scale``. Summing the
    integer coefficients keeps every digit, so the result never depends on
    (and is never silently rounded by) the default Decimal context precision.
    """
    coeff, scale = total
    sign, digits, exponent = amount.as_tuple()
    value = int("".join(map(str, digits)) or "0")
    if sign:
        value = -value
    if exponent >= 0:
        value *= 10 ** exponent
        exponent = 0
    new_scale = max(scale, -exponent)
    coeff *= 10 ** (new_scale - scale)
    coeff += value * 10 ** (new_scale + exponent)
    return coeff, new_scale


def _render(coeff, scale):
    """Render an exact (coeff, scale) total the way Decimal str() would."""
    text = str(abs(coeff))
    if scale:
        text = text.rjust(scale + 1, "0")
        text = "%s.%s" % (text[:-scale], text[-scale:])
    if coeff < 0:
        text = "-" + text
    return text


def summarize(path):
    """Return {"rows": data row count, "total": exact amount sum string}.

    The header row is not counted. Empty files and header-only files both
    yield {"rows": 0, "total": "0"}. An unparsable or non-finite amount
    raises ValueError whose message carries the offending physical line
    number in the input file (so the header never offsets it).
    """
    rows = 0
    total = (0, 0)
    with open(path, newline="", encoding="utf-8") as handle:
        reader = csv.reader(handle)
        next(reader, None)
        for row in reader:
            if not row:
                continue
            rows += 1
            raw = row[1] if len(row) > 1 else ""
            try:
                amount = Decimal(raw)
            except (InvalidOperation, ValueError):
                amount = None
            if amount is None or not amount.is_finite():
                raise ValueError(
                    "invalid amount on line %d: %r" % (reader.line_num, raw)
                )
            total = _accumulate(total, amount)
    return {"rows": rows, "total": _render(*total)}
