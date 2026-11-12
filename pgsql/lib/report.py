"""Usage: python3 -I report.py SUITES_DIR DOWNLOAD_DIR OUT_DIR SUITE...

Reads, for each SUITE, its newest artifact in DOWNLOAD_DIR (pgsql-3p-<suite>-<sha7>-r<run>-a<n>, as
the workflow uploads it) and writes:
- OUT_DIR/<suite>/<leg>/results.json: one outcome per test (passed, failed, errored, skipped), from
  the leg's JUnit files;
- OUT_DIR/comparison.json: per leg its counts and, for each proxy leg, how every test differs from
  the same test in its direct baseline leg; labels from SUITES_DIR/<suite>/known-issues.toml.

Exit status: 0, or 2 for wrong arguments or a broken known-issues.toml.
"""
import fnmatch
import json
import re
import sys
import tomllib
import xml.etree.ElementTree as ET
from collections import Counter
from datetime import datetime
from pathlib import Path

MESSAGE_MAX = 300
LABELS = ("environment", "proxy-architecture", "unsupported-feature", "upstream-defect", "config")
# each proxy leg is compared with the direct leg that differs from it only by going through ProxySQL
BASELINE = {"proxy-plain": "direct-plain", "proxy-tls-back": "direct-plain",
            "proxy-tls": "direct-tls", "proxy-tls-front": "direct-tls"}
LEG_ORDER = ("direct-plain", "direct-tls", "proxy-plain", "proxy-tls", "proxy-tls-front", "proxy-tls-back")
CLASSES = ("proxy_regression", "both_fail", "proxy_only_pass", "skip_mismatch", "not_executed", "leg_only")
NOT_PASSED = ("failed", "errored")


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


def load_issues(path):
    """The [[issue]] entries of a known-issues.toml ([] if there is none); ValueError if one is invalid."""
    if not path.exists():
        return []
    try:
        with open(path, "rb") as f:
            issues = tomllib.load(f).get("issue", [])
    except tomllib.TOMLDecodeError as e:
        raise ValueError(f"{path}: {e}") from e
    if not isinstance(issues, list):
        raise ValueError(f"{path}: expected [[issue]] entries")
    for n, issue in enumerate(issues, 1):
        where = f"{path}: issue {n}"
        if issue.get("label") not in LABELS:
            raise ValueError(f"{where}: label must be one of {', '.join(LABELS)}")
        if not isinstance(issue.get("reason"), str) or not issue["reason"].strip():
            raise ValueError(f"{where}: reason is required")
        tests = issue.get("tests")
        if not isinstance(tests, list) or not tests or not all(isinstance(t, str) and t for t in tests):
            raise ValueError(f"{where}: tests must be a list of test id patterns")
        if not isinstance(issue.get("link", ""), str):
            raise ValueError(f"{where}: link must be a string")
        if "message" in issue:
            try:
                re.compile(issue["message"])
            except (re.error, TypeError) as e:
                raise ValueError(f"{where}: message is not a regular expression: {e}") from e
    return issues


def labels_for(test_id, message, issues):
    """Every issue whose test pattern matches the id and, if it has one, whose message regex matches."""
    return [{"label": i["label"], "reason": i["reason"], "link": i.get("link", "")} for i in issues
            if any(fnmatch.fnmatchcase(test_id, p) for p in i["tests"])
            and ("message" not in i or (message is not None and re.search(i["message"], message)))]


def classify(base, leg):
    """The comparison class of one test (None when nothing differs); leg is "not_executed" if missing."""
    if base is None:
        return "leg_only"
    if leg == "not_executed":
        return "proxy_regression" if base == "passed" else "not_executed"
    if base in NOT_PASSED:
        return "both_fail" if leg in NOT_PASSED else "proxy_only_pass" if leg == "passed" else "skip_mismatch"
    if base == "passed":
        return "proxy_regression" if leg in NOT_PASSED else "skip_mismatch" if leg == "skipped" else None
    return None if leg == "skipped" else "skip_mismatch"


def compare(base, leg, issues):
    """{class: [entry]} for every test that differs between a baseline leg and a proxy leg."""
    classes = {c: [] for c in CLASSES}
    b, l = base["tests"], leg["tests"]
    for test_id in sorted(b.keys() | l.keys()):
        base_outcome = b[test_id]["outcome"] if test_id in b else None
        outcome = l[test_id]["outcome"] if test_id in l else "not_executed"
        cls = classify(base_outcome, outcome)
        if cls:
            message = l.get(test_id, {}).get("message", b.get(test_id, {}).get("message"))
            entry = {"id": test_id, "baseline": base_outcome, "outcome": outcome,
                     "labels": labels_for(test_id, message, issues)}
            if message is not None:
                entry["message"] = message
            classes[cls].append(entry)
    return classes


def read_json(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def duration(info):
    try:
        start, end = (datetime.fromisoformat(info[k]) for k in ("started_at", "ended_at"))
    except (KeyError, TypeError, ValueError):
        return None
    return int((end - start).total_seconds())


def leg_key(name):
    return (LEG_ORDER.index(name), "") if name in LEG_ORDER else (len(LEG_ORDER), name)


def suite_report(suites_dir, download_dir, out_dir, suite):
    issues = load_issues(suites_dir / suite / "known-issues.toml")
    artifact = find_artifact(download_dir, suite)
    entry = {"artifact": artifact.name if artifact else None, "problem": None, "issues": issues,
             "metadata": read_json(artifact / "metadata.json") if artifact else None, "legs": {}}
    if artifact is None:
        return entry
    results = {}
    for leg_dir in sorted((artifact / "legs").glob("*"), key=lambda d: leg_key(d.name)):
        leg = leg_dir.name
        info = read_json(leg_dir / "leg.json") or {}
        results[leg] = load_leg(leg_dir / "junit")
        write_json(out_dir / suite / leg / "results.json", results[leg])
        counts = Counter(t["outcome"] for t in results[leg]["tests"].values())
        entry["legs"][leg] = {
            "status": info.get("status", "no leg.json"), "reason": info.get("reason", ""),
            "duration_s": duration(info), "files_unreadable": results[leg]["files_unreadable"],
            "counts": {"total": len(results[leg]["tests"]),
                       **{k: counts[k] for k in ("passed", "failed", "errored", "skipped")}},
            "baseline": BASELINE.get(leg), "comparable": False, "not_executed": None, "classes": None,
            "baseline_failures": []}
    legs = entry["legs"]
    for leg, data in legs.items():
        if leg in BASELINE.values():
            data["baseline_failures"] = [
                {"id": i, "outcome": t["outcome"], "message": t["message"],
                 "labels": labels_for(i, t["message"], issues)}
                for i, t in sorted(results[leg]["tests"].items()) if t["outcome"] in NOT_PASSED]
        base = data["baseline"]
        if base and legs.get(base, {}).get("status") == "completed" and data["status"] in ("completed", "timed_out"):
            data["comparable"] = True
            data["classes"] = compare(results[base], results[leg], issues)
            data["not_executed"] = sum(e["outcome"] == "not_executed" for c in ("proxy_regression", "not_executed")
                                       for e in data["classes"][c])
    return entry


def write_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=1, sort_keys=True, ensure_ascii=False)
        f.write("\n")


def main(argv):
    if len(argv) < 4:
        print("usage: report.py SUITES_DIR DOWNLOAD_DIR OUT_DIR SUITE...", file=sys.stderr)
        return 2
    suites_dir, download_dir, out_dir = (Path(a) for a in argv[:3])
    report = {"red": False, "problems": [], "history": None, "suites": {}}
    try:
        for suite in argv[3:]:
            report["suites"][suite] = suite_report(suites_dir, download_dir, out_dir, suite)
    except ValueError as e:
        print(f"::error::{e}", file=sys.stderr)
        return 2
    write_json(out_dir / "comparison.json", report)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
