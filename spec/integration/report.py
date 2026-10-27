#!/usr/bin/env python3
"""Integration test results: per-scenario status line, summary, JUnit XML, coverage merge.

Usage:
    report.py --one OUT_DIR RUN_NAME        print the status of one scenario run
    report.py OUT_DIR [--coverage KODIR]    summary (stdout + OUT_DIR/summary.md),
                                            OUT_DIR/junit.xml, OUT_DIR/timings.json,
                                            merged luacov stats (OUT_DIR/integration.stats.out);
                                            exit code 1 if any scenario failed
"""

import glob
import json
import os
import sys
from xml.sax.saxutils import escape, quoteattr


def load(out_dir, run_name):
    res_file = os.path.join(out_dir, "results", run_name + ".json")
    exit_file = os.path.join(out_dir, "results", run_name + ".exit.json")
    log_file = os.path.join(out_dir, "logs", run_name + ".log")
    try:
        with open(res_file, encoding="utf-8") as f:
            res = json.load(f)
    except (OSError, ValueError) as e:
        res = {"scenario": run_name, "status": "crashed",
               "failures": [{"msg": "no result written (%s)" % e}]}
    try:
        with open(exit_file, encoding="utf-8") as f:
            ex = json.load(f)
    except (OSError, ValueError):
        ex = {"exit_code": -1, "wall_s": 0}
    for k in ("budgets", "metrics"):
        if not isinstance(res.get(k), dict):
            res[k] = {}
    for k in ("checks", "failures", "log"):
        if not isinstance(res.get(k), list):
            res[k] = []
    res["run_name"] = run_name
    res["exit_code"] = ex["exit_code"]
    res["wall_s"] = ex["wall_s"]
    res.setdefault("failures", [])
    if res.get("status") == "running":
        res["status"] = "crashed"
        res["failures"].append({"msg": "KOReader exited (code %d) before the scenario finished" % ex["exit_code"]})
    elif res.get("status") == "passed" and ex["exit_code"] != 0:
        res["status"] = "failed"
        res["failures"].append({"msg": "KOReader exit code %d" % ex["exit_code"]})
    if res["status"] != "passed":
        try:
            with open(log_file, encoding="utf-8", errors="replace") as f:
                lines = f.readlines()
            # Lua errors / tracebacks are what matters.
            interesting = [l for l in lines if "rror" in l or "traceback" in l or l.startswith("\t")]
            res["log_tail"] = "".join((interesting or lines)[-40:])
        except OSError:
            res["log_tail"] = ""
    return res


def status_line(res):
    budgets = res.get("budgets", {})
    worst = ""
    if budgets:
        name, b = max(budgets.items(), key=lambda kv: (kv[1]["value"] / kv[1]["max"]) if kv[1]["max"] else 0)
        worst = " (max budget use: %s %.0f%%)" % (name, 100.0 * b["value"] / b["max"] if b["max"] else 0)
    return "%-8s %6.1f s%s" % (res["status"].upper(), res["wall_s"], worst)


def merge_luacov(files, out_file):
    """Sums luacov stats files (format: "max:filename\\nhits hits …\\n")."""
    merged = {}
    for path in files:
        with open(path, encoding="utf-8", errors="surrogateescape") as f:
            while True:
                header = f.readline()
                if not header:
                    break
                header = header.rstrip("\n")
                if not header:
                    continue
                max_line, filename = header.split(":", 1)
                hits = [int(h) for h in f.readline().split()]
                cur = merged.setdefault(filename, [])
                if len(cur) < len(hits):
                    cur.extend([0] * (len(hits) - len(cur)))
                for i, h in enumerate(hits):
                    cur[i] += h
                del max_line
    with open(out_file, "w", encoding="utf-8", errors="surrogateescape") as f:
        for filename in sorted(merged):
            hits = merged[filename]
            f.write("%d:%s\n%s\n" % (len(hits), filename, " ".join(str(h) for h in hits)))
    return len(merged)


def main(argv):
    if len(argv) >= 3 and argv[0] == "--one":
        res = load(argv[1], argv[2])
        print(status_line(res))
        for fl in res["failures"]:
            print("    - %s" % fl["msg"])
        return 0
    if not argv:
        sys.exit(__doc__)
    out_dir = argv[0]
    coverage_kodir = argv[argv.index("--coverage") + 1] if "--coverage" in argv else None
    runs = sorted(os.path.basename(p)[:-len(".exit.json")]
                  for p in glob.glob(os.path.join(out_dir, "results", "*.exit.json")))
    results = [load(out_dir, r) for r in runs]
    failed = [r for r in results if r["status"] != "passed"]

    # Summary (markdown).
    md = ["## Emulator integration tests%s" % (" (coverage run)" if coverage_kodir else ""), ""]
    md.append("%d scenario run(s), %d passed, %d failed." % (len(results), len(results) - len(failed), len(failed)))
    md.append("")
    md.append("| Scenario | Status | Wall time | Startup | Checks | Budgets |")
    md.append("|---|---|---:|---:|---:|---|")
    for r in results:
        checks = r.get("checks", [])
        budgets = r.get("budgets", {})
        btxt = "<br>".join("%s %s: %s / %s %s" % ("✅" if b["ok"] else "⚠️", k, fmt(b["value"]), fmt(b["max"]), b.get("unit") or "")
                           for k, b in sorted(budgets.items()))
        md.append("| %s | %s | %.1f s | %s | %d/%d | %s |" % (
            r["run_name"], "✅ passed" if r["status"] == "passed" else "❌ " + r["status"],
            r["wall_s"], ("%.1f s" % (r["startup_ms"] / 1000.0)) if r.get("startup_ms") else "–",
            sum(1 for c in checks if c["ok"]), len(checks), btxt or "–"))
    for r in failed:
        md.append("")
        md.append("### ❌ %s" % r["run_name"])
        md.append("")
        for fl in r["failures"]:
            md.append("- %s" % fl["msg"])
        md.append("")
        md.append("<details><summary>details</summary>\n")
        md.append("```")
        for fl in r["failures"]:
            if fl.get("where"):
                md.append(fl["where"].strip())
        if r.get("log_tail"):
            md.append("--- log ---")
            md.append(r["log_tail"].rstrip())
        md.append("```\n</details>")
    summary = "\n".join(md) + "\n"
    with open(os.path.join(out_dir, "summary.md"), "w", encoding="utf-8") as f:
        f.write(summary)
    print()
    print(summary)

    # Timings & metrics.
    timings = {r["run_name"]: {
        "status": r["status"], "wall_s": r["wall_s"], "startup_ms": r.get("startup_ms"),
        "metrics": r.get("metrics", {}), "budgets": r.get("budgets", {}),
    } for r in results}
    with open(os.path.join(out_dir, "timings.json"), "w", encoding="utf-8") as f:
        json.dump(timings, f, indent=1, sort_keys=True, ensure_ascii=False)

    # JUnit.
    xml = ['<?xml version="1.0" encoding="UTF-8"?>',
           '<testsuite name="integration" tests="%d" failures="%d" time="%.3f">' % (
               len(results), len(failed), sum(r["wall_s"] for r in results))]
    for r in results:
        xml.append('  <testcase classname="integration" name=%s time="%.3f">' % (quoteattr(r["run_name"]), r["wall_s"]))
        if r["status"] != "passed":
            msg = "; ".join(fl["msg"] for fl in r["failures"]) or r["status"]
            body = "\n".join((fl.get("where") or "") for fl in r["failures"]) + "\n" + r.get("log_tail", "")
            xml.append('    <failure message=%s>%s</failure>' % (quoteattr(msg), escape(body)))
        xml.append('    <system-out>%s</system-out>' % escape("\n".join(r.get("log", []))))
        xml.append('  </testcase>')
    xml.append('</testsuite>')
    with open(os.path.join(out_dir, "junit.xml"), "w", encoding="utf-8") as f:
        f.write("\n".join(xml) + "\n")

    # Coverage.
    if coverage_kodir:
        stats = sorted(glob.glob(os.path.join(out_dir, "coverage", "*.stats.out")))
        n = merge_luacov(stats, os.path.join(out_dir, "integration.stats.out"))
        print("coverage: merged %d stats file(s), %d source file(s)" % (len(stats), n))

    return 1 if failed else 0


def fmt(v):
    if isinstance(v, float):
        return "%.1f" % v
    return str(v)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
