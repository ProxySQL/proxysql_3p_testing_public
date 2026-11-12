"""Usage: python3 -I report.py SUITES_DIR DOWNLOAD_DIR OUT_DIR SUITE...

Reads, for each SUITE, its newest artifact in DOWNLOAD_DIR (pgsql-3p-<suite>-<sha7>-r<run>-a<n>, as
the workflow uploads it) and writes OUT_DIR/<suite>/<leg>/results.json: one outcome per test
(passed, failed, errored, skipped), from the leg's JUnit files.

Exit status: 0, or 2 for wrong arguments.
"""
import json
import re
import sys
import xml.etree.ElementTree as ET
from collections import Counter
from pathlib import Path

MESSAGE_MAX = 300


def find_artifact(download_dir, suite):
    """The suite's artifact folder with the highest attempt number, or None."""
    # a suite folder named "report" would clash with the report artifact's name
    pattern = re.compile(rf"pgsql-3p-{re.escape(suite)}-[0-9a-f]{{7}}-r\d+-a(\d+)")
    found = [(int(m.group(1)), d) for d in Path(download_dir).glob("*")
             if d.is_dir() and (m := pattern.fullmatch(d.name))]
    return max(found)[1] if found else None


def first_line(text):
    lines = (text or "").strip().splitlines()
    return lines[0].strip()[:MESSAGE_MAX] if lines else ""


def outcome_of(case):
    for tag, outcome in (("failure", "failed"), ("error", "errored"), ("skipped", "skipped")):
        element = case.find(tag)
        if element is not None:
            return outcome, element
    return "passed", None


def load_leg(junit_dir):
    """{"files", "files_unreadable", "tests": {id: {"outcome", "message"?}}} of one leg's JUnit files.

    The id is "classname::name"; the n-th repeat of a name in a leg (parameterized tests) gets "#n".
    PARTIAL-*.xml files (written while a run goes) are only read when there is no TEST-*.xml file.
    """
    paths = sorted(Path(junit_dir).glob("*.xml"))
    if any(p.name.startswith("TEST-") for p in paths):
        paths = [p for p in paths if not p.name.startswith("PARTIAL-")]
    files = unreadable = 0
    tests, seen = {}, Counter()
    for path in paths:
        try:
            cases = list(ET.parse(path).getroot().iter("testcase"))
        except (ET.ParseError, OSError):
            unreadable += 1
            continue
        files += 1
        for case in cases:
            base = f"{case.get('classname', '')}::{case.get('name', '')}"
            seen[base] += 1
            test_id = base if seen[base] == 1 else f"{base}#{seen[base]}"
            outcome, element = outcome_of(case)
            tests[test_id] = {"outcome": outcome}
            if outcome in ("failed", "errored"):
                tests[test_id]["message"] = first_line(element.get("message") or element.text)
    return {"files": files, "files_unreadable": unreadable, "tests": tests}


def write_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=1, sort_keys=True, ensure_ascii=False)
        f.write("\n")


def main(argv):
    if len(argv) < 4:
        print("usage: report.py SUITES_DIR DOWNLOAD_DIR OUT_DIR SUITE...", file=sys.stderr)
        return 2
    _suites_dir, download_dir, out_dir = (Path(a) for a in argv[:3])
    for suite in argv[3:]:
        artifact = find_artifact(download_dir, suite)
        if artifact is None:
            continue
        for leg_dir in sorted((artifact / "legs").glob("*")):
            write_json(out_dir / suite / leg_dir.name / "results.json", load_leg(leg_dir / "junit"))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
