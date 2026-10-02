#!/usr/bin/env python3
"""Hybrid arm: which of this runner's directories run on kind.

Usage: h-route.py --routed ROUTED.dirs --planned G1.dirs[,G2.dirs...] --results 'result-g-*.jsonl' --out KIND.dirs

Frozen routing (decided from earlier runs, before any hybrid result):
  routed    the runner's directories on the frozen routing list (known harness
            gaps and directories with an unexplained failure on this substrate
            only) go to kind without a substrate attempt;
  fallback  every other planned directory whose substrate outcome is not
            `pass` or `pass-vacuous` (fail, error, timeout, gap-harness,
            upstream-incompatible, not-run, any other bucket) or that has no
            outcome row at all (a baseline that never came up) runs again on
            kind. Both executions are kept and counted.
Writes KIND.dirs and prints one JSON record (`h-route.json`) naming every
routed and fallback directory with the substrate bucket that sent it.
"""
import argparse, glob, json

PASSING = {"pass", "pass-vacuous"}


def route(routed, planned, rows):
    seen = {}
    for r in rows:
        seen[r["dir"]] = r.get("bucket", "missing")
    fallback = {d: seen.get(d, "missing") for d in planned if seen.get(d, "missing") not in PASSING}
    return sorted(set(routed)), dict(sorted(fallback.items()))


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--routed", required=True)
    p.add_argument("--planned", required=True)
    p.add_argument("--results", required=True)
    p.add_argument("--out", required=True)
    a = p.parse_args()
    read = lambda f: [l.strip() for l in open(f) if l.strip()]
    routed = read(a.routed)
    planned = [d for f in a.planned.split(",") if f for d in read(f)]
    rows = []
    for f in sorted(glob.glob(a.results)):
        rows += [json.loads(l) for l in open(f) if l.strip()]
    routed, fallback = route(routed, planned, rows)
    with open(a.out, "w") as fh:
        for d in sorted(set(routed) | set(fallback)):
            fh.write(d + "\n")
    print(json.dumps({"routed": routed, "fallback": fallback}, sort_keys=True))


if __name__ == "__main__":
    main()
