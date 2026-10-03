#!/usr/bin/env python3
"""Draw the README pictures as light and dark SVG.

Usage: python3 docs/diagrams/charts.py
Writes two pictures as <name>-light.svg and <name>-dark.svg, one pair of equal
height: how septdrift catches drift, beside the measured run on two Macs.
Every figure is copied from docs/runs/2026-09-30-m4-vs-m1.txt, and main()
checks that each rate still appears there. The drawing code is quoin_readme.py,
a copy of the Quoin README module.
"""
import re
from pathlib import Path

from quoin_readme import (THEMES, GREEN, BLUE, RED, M, R, text, note, head, svg, arrow, tag, box, box_h,
                          pair, panels)

HERE = Path(__file__).resolve().parent
RECEIPT = HERE.parent / "runs" / "2026-09-30-m4-vs-m1.txt"

FLOW_DESC = ("You declare cases with checks in cases/*.yaml. septdrift run sends each case to the "
             "on-device model and writes a hash-chained recording whose header names the chip, OS "
             "build, and model asset IDs. Record once before an OS update and once after, or on two "
             "Macs. septdrift diff scores both recordings check by check and classes each as flip, "
             "degrade, fix, or unchanged. It exits 0 when nothing flipped and 1 when a check that "
             "passed now fails.")

# (case and check, M4 passes, M4 runs, M1 passes, M1 runs): the five checks
# whose rate differs in the receipt; the other 43 are unchanged.
CHANGED = [
    ("intent-renewal-risk", 0, 3, 3, 3),
    ("intent-billing-question", 0, 3, 3, 3),
    ("deal-owning-specialist", 0, 3, 3, 3),
    ("status-summary format", 0, 1, 1, 1),
    ("facts-absent fail-closed", 3, 3, 2, 3),
]
MEASURED_DESC = ("One OS build, 26A434, on two Macs, warm, three repeats for most cases. 48 checks: "
                 "43 unchanged, 4 pass only on the M1, and 1 passes less on the M1. "
                 + " ".join(f"{name}: M4 {a} of {n}, M1 {b} of {m}." for name, a, n, b, m in CHANGED)
                 + " The model variants differ (M4 sparse_16, M1 14.4), so this records two Macs, "
                   "not a regression.")


def flow(c, spread=0.0, h=0):
    """Cases, run, recordings, diff, exit. spread opens the gaps between steps."""
    g = round(14 * spread)
    steps = [("Cases: cases/*.yaml", "prompt, instructions, checks", None),
             ("septdrift run", "on-device model or fixtures", "hash-chained recording"),
             ("Recording A, recording B", "before and after an update,", "or two Macs"),
             ("septdrift diff A B", "pass rate per check, then", "flip, degrade, fix, unchanged")]
    b, y = head("How septdrift catches drift", c)
    y -= 10
    for i, (label, sub, extra) in enumerate(steps):
        bh = box_h(sub, extra, R - M)
        b += box(M, y, R - M, bh, label, sub, extra, "backend" if i == 1 else "database", c)
        y += bh
        if i < len(steps) - 1:
            b.append(arrow([((M + R) / 2, y + 2), ((M + R) / 2, y + 26 + g)], c["ink2"], c))
            y += 30 + g
    ends = [("exit 0", "no check flipped", None, "backend"), ("exit 1", "a check that passed now fails", None, "security")]
    eh = max(box_h(s, e, 156) for _, s, e, _ in ends)
    b.append(arrow([(94, y + 2), (94, y + 34 + g)], c["series"][GREEN], c, width=2))
    b.append(arrow([(266, y + 2), (266, y + 34 + g)], c["series"][RED], c, dashed=True))
    y += 36 + g
    for (label, sub, extra, k), x in zip(ends, (16, 188)):
        b += box(x, y, 156, eh, label, sub, extra, k, c)
    lines, y = note(y + eh + 26, "The hash chain is unsigned: verify proves a recording is whole, not where it came from.", c)
    return svg(max(y, h), "How septdrift catches drift", FLOW_DESC, b + lines, c)


def measured(c, spread=0.0, h=0):
    """The five checks whose pass rate differs between the two Macs, on one scale."""
    return panels(dict(
        title="One OS build, two Macs",
        sub="Build 26A434, warm. 48 checks: 43 unchanged, these 5 differ.",
        panels=[(name, [GREEN, BLUE], [("M4", a / n, f"{a} of {n}"), ("M1", b2 / m, f"{b2} of {m}")])
                for name, a, n, b2, m in CHANGED],
        notes=["The model variants differ (M4 sparse_16, M1 14.4), so this records two Macs, not a regression."],
        desc=MEASURED_DESC), c, spread, h)


PAIRS = [("flow", flow, "measured", measured)]


def main():
    receipt = RECEIPT.read_text()
    assert "osBuild=26A434" in receipt and "counts: flips=1 degrades=0 fixes=4 unchanged=43" in receipt
    for name, a, n, b2, m in CHANGED:  # each rate is in the receipt, M4 then M1
        assert re.search(rf"{a}/{n} \([\d.]+\)\s+{b2}/{m} \([\d.]+\)", receipt), name
    for theme, c in THEMES.items():
        for ln, lf, rn, rf in PAIRS:
            for name, s in zip((ln, rn), pair(lf, rf, c)):
                (HERE / f"{name}-{theme}.svg").write_text(s)
    print("built", ", ".join(f"{ln} | {rn}" for ln, _, rn, _ in PAIRS))


if __name__ == "__main__":
    main()
