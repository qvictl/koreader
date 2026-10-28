#!/usr/bin/env python3
"""Compare MuPDF store limits on Linux and verify rendered page hashes.

Example: python3 tools/bench_mupdf_memory.py --kodir /path/to/runtime --out benchmark
Use --pdf /path/to/public.pdf to test another document without copying it.
The default is a deterministic synthetic scan. Only rendering is timed;
peak RSS/PSS samples also include allocation of the strings used for hashing.
"""

import argparse
import importlib.util
import json
import os
from pathlib import Path
import statistics
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--kodir", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--pdf", type=Path)
    parser.add_argument("--samples", type=int, default=3)
    args = parser.parse_args()
    if args.samples < 1:
        parser.error("--samples must be positive")
    repo = Path(__file__).resolve().parent.parent
    runtime, out = args.kodir.resolve(), args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    pdf = args.pdf.resolve() if args.pdf else out / "scanned.pdf"
    if not args.pdf:
        spec = importlib.util.spec_from_file_location("fixtures", repo / "spec/integration/fixtures/make_fixtures.py")
        fixtures = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(fixtures)
        fixtures.write_scan_pdf(pdf)
    results = []
    for _sample in range(args.samples):
        for limit in (32, 16):
            process = subprocess.run(
                [str(runtime / "luajit"), str(repo / "tools/bench_mupdf_memory.lua"), str(limit), str(pdf)],
                cwd=runtime, env=os.environ | {"KO_HOME": str(out / "home"), "SDL_VIDEODRIVER": "dummy"},
                capture_output=True, text=True, check=True, timeout=180,
            )
            report = json.loads(next(line for line in process.stdout.splitlines() if line.startswith("{")))
            if results and report["hashes"] != results[0]["hashes"]:
                raise RuntimeError("Rendered pixels differ between store sizes or runs")
            results.append(report)
    (out / "samples.json").write_text(json.dumps(results, indent=2) + "\n")
    for limit in (32, 16):
        rows = [r for r in results if r["store_mib"] == limit]
        print(json.dumps({"store_mib": limit, "samples": len(rows), "identical_pixels": True,
                          **{key: statistics.median(r[key] for r in rows)
                             for key in ("peak_rss_kib", "peak_pss_kib", "render_ms")}}))


if __name__ == "__main__":
    main()
