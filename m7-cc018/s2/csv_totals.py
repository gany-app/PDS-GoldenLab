"""Summarize a UTF-8 CSV with a ``name,amount`` header using Decimal."""

from __future__ import annotations

import csv
from decimal import Decimal, InvalidOperation


def summarize(path):
    """Return ``{"rows": <int>, "total": <str>}`` for the CSV at *path*.

    The first line is the ``name,amount`` header and is never counted in
    ``rows``.  Amounts are parsed and summed with :class:`decimal.Decimal`
    so no binary floating point rounding is introduced; ``total`` is the
    decimal string form of the sum (``"0"`` for an empty or header-only
    file).

    Raises:
        ValueError: if a data row does not have exactly two columns or its
            ``amount`` is not a finite decimal number.  The message contains
            the 1-based line number of the offending row in the source CSV.
    """
    total = Decimal("0")
    rows = 0
    with open(path, "r", encoding="utf-8", newline="") as handle:
        reader = csv.reader(handle)
        next(reader, None)  # consume the header on line 1
        for row in reader:
            lineno = reader.line_num
            if not row or all(cell.strip() == "" for cell in row):
                continue
            if len(row) != 2:
                raise ValueError(
                    "line {}: expected 2 columns, got {}".format(lineno, len(row))
                )
            raw = row[1].strip()
            try:
                amount = Decimal(raw)
            except InvalidOperation:
                raise ValueError(
                    "line {}: invalid amount {!r}".format(lineno, row[1])
                ) from None
            if not amount.is_finite():
                raise ValueError(
                    "line {}: invalid amount {!r}".format(lineno, row[1])
                )
            total += amount
            rows += 1
    return {"rows": rows, "total": str(total)}
