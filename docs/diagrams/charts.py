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

from quoin_readme import (THEMES, GREEN, BLUE, RED, M, R, CH, text, note, head, svg, arrow, tag, box, box_h,
                          pair, panels)

HERE = Path(__file__).resolve().parent
RECEIPT = HERE.parent / "runs" / "2026-09-30-m4-vs-m1.txt"
CASES = HERE.parent.parent / "cases" / "semi-deterministic.yaml"
CASE_ID = "intent-billing-question"
WRAP = 44  # characters of 12-unit mono across the 328-unit text column

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


def terminal(heading, rows, foot, title, desc, c, spread=0.0, h=0):
    """A terminal panel wrapped for a phone (memvet's helper). A row is
    [(column, text, colour key or series index)]; a series index puts a swatch
    before the word and sets the word in ink. spread opens the row gap."""
    b, y = head(heading, c)
    y -= 6
    for line in rows:
        for col, t, k in line:
            x = M + 4 + col * 12 * CH
            if isinstance(k, str):
                b.append(text(x, y, t, 12, c[k]))
                continue
            b.append(f'<rect x="{x - 8.5:g}" y="{y - 8:g}" width="6" height="6" rx="1.5" fill="{c["series"][k]}"/>')
            b.append(text(x, y, t, 12, c["ink"], weight=600))
        y += 19 + round(6 * spread)
    lines, y = note(y + 8, foot, c)
    return svg(max(y, h), title, desc, b + lines, c)


def wrapped(line, width=WRAP):
    """Split one source line into rows of at most width characters, each
    continuation indented four spaces past the line's own indent."""
    indent = len(line) - len(line.lstrip())
    rows, rest = [], line
    while len(rest) > width:
        cut = rest.rfind(" ", indent + 1, width + 1)
        cut = cut if cut > indent else width
        rows.append(rest[:cut].rstrip())
        rest = " " * (indent + 4) + rest[cut:].lstrip()
    return rows + [rest]


def case_lines():
    """The case block for CASE_ID, line for line from the case file."""
    src = CASES.read_text().splitlines()
    start = src.index(f"- id: {CASE_ID}")
    end = next(i for i in range(start + 1, len(src)) if not src[i].strip())
    return src[start:end]


def at_indent(r, key):
    """One row whose leading spaces become its column, since SVG collapses them."""
    return [(len(r) - len(r.lstrip()), r.lstrip(), key)]


def case_file(c, spread=0.0, h=0):
    rows = [at_indent(r, "ink") for line in case_lines() for r in wrapped(line)]
    return terminal("A case: what you declare", rows,
                    "Three repeats, two checks. Every response is recorded in a hash-chained JSONL file.",
                    f"cases/semi-deterministic.yaml, {CASE_ID}",
                    "The case " + CASE_ID + " from cases/semi-deterministic.yaml: " + " ".join(
                        l.strip() for l in case_lines()), c, spread, h)


CLASS_KEY = {"flip": RED, "fix": GREEN}


def diff_rows():
    """(case, check, rate A, rate B, delta, class) for the two checks of CASE_ID
    and the one flip, parsed from the receipt."""
    rows = []
    for line in RECEIPT.read_text().splitlines():
        parts = line.split()
        if len(parts) >= 8 and (parts[0] == CASE_ID or parts[-1] == "flip"):
            case, check, ra, pa, rb, pb, delta, cls = parts[0], parts[1], *parts[-6:]
            rows.append((case, check, ra, rb, delta, cls))  # the (rate) beside each count is dropped
    return rows


def sides():
    text_ = RECEIPT.read_text()
    out = []
    for side in "AB":
        line = next(l for l in text_.splitlines() if l.startswith(f"side {side}:"))
        chip = line.split("chip=")[1].split(" osBuild=")[0]
        build = line.split("osBuild=")[1].split()[0]
        out.append(f"side {side}: chip={chip} osBuild={build}")
    return out


def diff_output(c, spread=0.0, h=0):
    receipt = RECEIPT.read_text()
    rows = [[(0, s, "ink2")] for s in sides()] + [[]]
    for case, check, a, b, delta, cls in diff_rows():
        rows.append([(0, case, "ink")])
        rows += [at_indent(r, "ink2") for r in wrapped("  " + check)]
        tail = f"A {a} B {b} {delta}"
        rows.append([(2, tail, "ink2"), (len(tail) + 4, cls, CLASS_KEY.get(cls, "ink2"))])
    counts = next(l for l in receipt.splitlines() if l.startswith("counts:"))
    rows += [[]] + [at_indent(r, "ink") for r in wrapped(counts)] + [[(0, "exit: 1", "ink")]]
    desc = (" ".join(sides()) + ". " + " ".join(
        f"{case} {check}: A {a}, B {b}, {delta}, {cls}." for case, check, a, b, delta, cls in diff_rows())
        + f" {counts}. exit: 1.")
    return terminal("Its diff: what you get", rows,
                    "The two Macs run different model variants (M4 sparse_16, M1 14.4): two Macs, not a regression.",
                    "septdrift diff, M4 against M1", desc, c, spread, h)


PAIRS = [("flow", flow, "measured", measured),
         ("case-file", case_file, "diff-output", diff_output)]


def main():
    receipt = RECEIPT.read_text()
    assert "osBuild=26A434" in receipt and "counts: flips=1 degrades=0 fixes=4 unchanged=43" in receipt
    assert "exit: 1" in receipt and len(diff_rows()) == 3, diff_rows()
    assert all(len(r) <= WRAP for line in case_lines() for r in wrapped(line))
    assert all(len(f"A {a} B {b} {d}") + 4 + len(k) <= WRAP for _, _, a, b, d, k in diff_rows())
    for name, a, n, b2, m in CHANGED:  # each rate is in the receipt, M4 then M1
        assert re.search(rf"{a}/{n} \([\d.]+\)\s+{b2}/{m} \([\d.]+\)", receipt), name
    for theme, c in THEMES.items():
        for ln, lf, rn, rf in PAIRS:
            for name, s in zip((ln, rn), pair(lf, rf, c)):
                (HERE / f"{name}-{theme}.svg").write_text(s)
    print("built", ", ".join(f"{ln} | {rn}" for ln, _, rn, _ in PAIRS))


if __name__ == "__main__":
    main()
