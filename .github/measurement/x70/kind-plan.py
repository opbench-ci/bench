#!/usr/bin/env python3
"""Assign directories to a runner's two kind slots.

Usage: kind-plan.py --dirs FILE --table dirs.tsv --out PREFIX [--slots 2] [--bringup-s 83]

Writes PREFIX-s<i>.tsv (one per slot, possibly empty), each row
`<installation group>\t<invocation job>\t<directory>`, and prints a JSON summary.

A slot is one persistent kind cluster per installation group, running its
directories one at a time. Rules (frozen with the protocol; the same code plans
the consolidated-kind arm and the fallback phase of the hybrid arm):

  * Several installation groups: each group is one unit (cost = cluster
    bring-up + its directories' estimated time), never split, assigned to the
    least-loaded slot in descending cost order (LPT).
  * One group: split across the slots by LPT over directory estimates only if
    its estimated test time exceeds one bring-up; otherwise one slot (a second
    cluster would cost more than it saves).
  * Within a slot, groups run in assignment order and each group's rows are
    ordered by invocation job, then directory. The invocation job is the first
    upstream shard of the directory's suite (dirs.tsv column 3): every shard of
    a suite shares its test path, suite configuration and quarantine list, so
    a slot starts one chainsaw process per suite, not per upstream shard.
Ties break by name, so the plan is a pure function of its inputs.
"""
import argparse, collections, json, statistics


def load_table(path):
    t = {}
    for line in open(path):
        if not line.strip() or line.startswith("#"):
            continue
        d, _job, inv, group, est = line.rstrip("\n").split("\t")
        t[d] = (inv, group, float(est))
    return t


def plan(dirs, table, slots=2, bringup_s=83.0):
    """Return a list of `slots` lists of (group, job, dir) rows."""
    missing = [d for d in dirs if d not in table]
    if missing:
        raise SystemExit(f"directories not in table: {missing[:5]}")
    groups = collections.defaultdict(list)
    for d in sorted(set(dirs)):
        groups[table[d][1]].append(d)
    out = [[] for _ in range(slots)]
    load = [0.0] * slots
    if not groups:
        return out, load
    if len(groups) == 1:
        (g, ds), = groups.items()
        total = sum(table[d][2] for d in ds)
        if total <= bringup_s or slots == 1:
            out[0] = [(g, table[d][0], d) for d in ds]
            load[0] = bringup_s + total
        else:
            load = [bringup_s] * slots
            for d in sorted(ds, key=lambda d: (-table[d][2], d)):
                i = min(range(slots), key=lambda i: (load[i], i))
                out[i].append((g, table[d][0], d))
                load[i] += table[d][2]
    else:
        units = sorted(groups.items(), key=lambda kv: (-(bringup_s + sum(table[d][2] for d in kv[1])), kv[0]))
        for g, ds in units:
            i = min(range(slots), key=lambda i: (load[i], i))
            out[i] += [(g, table[d][0], d) for d in ds]
            load[i] += bringup_s + sum(table[d][2] for d in ds)
    for i in range(slots):
        order = list(dict.fromkeys(g for g, _, _ in out[i]))
        out[i].sort(key=lambda r: (order.index(r[0]), r[1], r[2]))
    return out, load


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--dirs", required=True)
    p.add_argument("--table", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--slots", type=int, default=2)
    p.add_argument("--bringup-s", type=float, default=83.0)
    a = p.parse_args()
    dirs = [l.strip() for l in open(a.dirs) if l.strip()]
    table = load_table(a.table)
    out, load = plan(dirs, table, a.slots, a.bringup_s)
    for i, rows in enumerate(out):
        with open(f"{a.out}-s{i}.tsv", "w") as fh:
            for r in rows:
                fh.write("\t".join(r) + "\n")
    print(json.dumps({"dirs": len(set(dirs)), "slots": [
        {"slot": i, "dirs": len(rows), "groups": sorted({g for g, _, _ in rows}),
         "jobs": len({(g, j) for g, j, _ in rows}), "predicted_s": round(load[i], 1)}
        for i, rows in enumerate(out)]}, sort_keys=True))


if __name__ == "__main__":
    main()
