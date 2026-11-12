"""Usage: python3 -I report.py SUITES_DIR DOWNLOAD_DIR OUT_DIR SUITE...

Reads, for each SUITE, its newest artifact in DOWNLOAD_DIR (pgsql-3p-<suite>-<sha7>-r<run>-a<n>, as
the workflow uploads it) and writes:
- OUT_DIR/<suite>/<leg>/results.json: one outcome per test (passed, failed, errored, skipped), from
  the leg's JUnit files;
- OUT_DIR/comparison.json: per leg its counts and, for each proxy leg, how every test differs from
  the same test in its direct baseline leg; labels from SUITES_DIR/<suite>/known-issues.toml;
- OUT_DIR/report.md (also the run page summary) and OUT/report.html (static, no external files).

Exit status: 0 green; 1 red (a suite or a leg could not run, or a baseline leg did not complete, so
its proxy legs cannot be compared), each reason printed as ::error::; 2 for wrong arguments or a
broken known-issues.toml.
"""
import fnmatch
import html
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
        entry["problem"] = "no results uploaded"
        return entry
    status = read_json(artifact / "suite-status.json")
    if status is not None:
        entry["problem"] = f"could not start: {status.get('reason', '')}"
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


def problems(report):
    """Why the report is red: suites or legs that could not run, proxy legs that cannot be compared."""
    out = []
    # stage 5 adds: a proxy_regression that was not there in the newest comparable earlier run
    for suite, s in report["suites"].items():
        if s["problem"]:
            out.append(f"{suite}: {s['problem']}")
        elif not s["legs"]:
            out.append(f"{suite}: no leg results")
        for leg, d in s["legs"].items():
            if d["status"] not in ("completed", "timed_out"):
                out.append(f"{suite} {leg}: {d['status']}" + (f": {d['reason']}" if d["reason"] else ""))
            base = d["baseline"]
            base_status = s["legs"].get(base, {}).get("status") if base else None
            if base and base_status != "completed":
                out.append(f"{suite} {leg}: not comparable, baseline {base} is {base_status or 'missing'}")
    return out


def fmt_duration(seconds):
    if seconds is None:
        return "-"
    if seconds >= 3600:
        return f"{seconds // 3600}h {seconds % 3600 // 60:02d}m"
    return f"{seconds // 60}m {seconds % 60:02d}s"


def class_rows(d):
    """Regressions of a proxy leg per test class: (class, failed, errored, not executed, {label: n}, entries).
    A timed-out leg's not-executed tests are left out (they are given as one "not reached" count)."""
    timed_out = d["status"] == "timed_out"
    rows = {}
    for e in d["classes"]["proxy_regression"]:
        if timed_out and e["outcome"] == "not_executed":
            continue
        row = rows.setdefault(e["id"].split("::", 1)[0], {"failed": 0, "errored": 0, "not_executed": 0,
                                                         "labels": Counter(), "entries": []})
        row[e["outcome"]] += 1
        row["labels"].update({lb["label"] for lb in e["labels"]})
        if e["outcome"] in NOT_PASSED:
            row["entries"].append(e)
    return [(c, r["failed"], r["errored"], r["not_executed"], r["labels"], r["entries"]) for c, r in sorted(rows.items())]


def not_reached(d):
    if d["status"] != "timed_out":
        return 0
    return sum(e["outcome"] == "not_executed" for e in d["classes"]["proxy_regression"])


def other_counts(d):
    c = d["classes"]
    return (f"Fails both ways: {len(c['both_fail'])} · passes only through ProxySQL: {len(c['proxy_only_pass'])}"
            f" · skipped in one leg only: {len(c['skip_mismatch'])} · only in this leg: {len(c['leg_only'])}")


def leg_cells(leg, d):
    counts = ["-"] * 5 if d["status"] == "infra_failure" else \
        [str(d["counts"][k]) for k in ("total", "passed", "failed", "errored", "skipped")]
    if d["baseline"] is None:
        compared, not_executed, regressions = "-", "-", "-"
    elif d["comparable"]:
        compared, not_executed = d["baseline"], str(d["not_executed"])
        regressions = str(len(d["classes"]["proxy_regression"]))
    else:
        compared, not_executed, regressions = f"{d['baseline']} (not comparable)", "-", "-"
    return [leg, d["status"], compared, *counts, not_executed, regressions, fmt_duration(d["duration_s"])]


def labels_text(labels):
    return "; ".join(f"{lb['label']}: {lb['reason']}" for lb in labels) or "unexplained"


def matched(s):
    """Per issue (label, reason): the number of (leg, test) entries it labels in this suite."""
    hits = {}
    for leg, d in s["legs"].items():
        entries = d["baseline_failures"] + [e for c in (d["classes"] or {}).values() for e in c]
        for e in entries:
            for lb in e["labels"]:
                hits.setdefault((lb["label"], lb["reason"]), set()).add((leg, e["id"]))
    return hits


def suite_meta(s):
    m = s["metadata"] or {}
    version = (m.get("proxysql") or {}).get("version")
    up = m.get("upstream") or {}
    parts = [f"ProxySQL {version}"] if version else []
    if up.get("ref"):
        parts.append(f"upstream {up['ref']} ({(up.get('sha') or '')[:7]})")
    return " · ".join(parts)


def md(text):
    """Text safe in a Markdown line or table cell."""
    return html.escape(" ".join(str(text).split()), quote=False).replace("|", "\\|")


def render_md(report):
    out = ["# PostgreSQL 3rd-party tests: report", ""]
    out.append("**Result: red**" if report["red"] else "**Result: green**")
    out += [""] + [f"- {md(p)}" for p in report["problems"]] + ([""] if report["problems"] else [])
    out += ["No comparison with earlier runs yet.", ""]
    for suite, s in report["suites"].items():
        out += [f"## {md(suite)}", ""]
        if suite_meta(s):
            out += [md(suite_meta(s)), ""]
        if s["problem"]:
            out += [md(f"{suite}: {s['problem']}"), ""]
        if not s["legs"]:
            continue
        out += ["| Leg | Status | Compared with | Total | Passed | Failed | Errored | Skipped | Not executed | Regressions | Duration |",
                "|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|"]
        out += ["| " + " | ".join(md(c) for c in leg_cells(leg, d)) + " |" for leg, d in s["legs"].items()]
        out.append("")
        out += [f"{md(leg)}: {d['files_unreadable']} JUnit files could not be read."
                for leg, d in s["legs"].items() if d["files_unreadable"]]
        for leg, d in s["legs"].items():
            if not d["comparable"]:
                continue
            n = len(d["classes"]["proxy_regression"])
            out += ["", f"### {md(leg)}: {n} tests pass directly but not through ProxySQL", ""]
            rows = class_rows(d)
            if rows:
                out += ["| Class | Failed | Errored | Not executed | Labels |", "|---|---:|---:|---:|---|"]
                out += [f"| {md(c)} | {f} | {e} | {ne} | " + md(", ".join(f"{k} ({v})" for k, v in sorted(lbs.items()))) + " |"
                        for c, f, e, ne, lbs, _ in rows]
                out.append("")
            if not_reached(d):
                out += [f"Not reached before the time limit: {not_reached(d)}", ""]
            out.append(other_counts(d))
        out += ["", "### Direct baseline failures", ""]
        lines = [f"- {md(leg)}: {md(e['id'])} ({e['outcome']}): {md(labels_text(e['labels']))}"
                 for leg, d in s["legs"].items() for e in d["baseline_failures"]]
        out += (lines or ["None."]) + [""]
        if s["issues"]:
            hits = matched(s)
            out += ["### Known issues", "", "| Label | Reason | Link | Tests matched |", "|---|---|---|---:|"]
            out += [f"| {md(i['label'])} | {md(i['reason'])} | {md(i.get('link', ''))} | "
                    f"{len(hits.get((i['label'], i['reason']), ()))} |" for i in s["issues"]]
            out.append("")
    return "\n".join(out) + "\n"


def h(text):
    return html.escape(str(text))


def entry_items(entries):
    return "".join(f"<li><code>{h(e['id'])}</code> {h(e['outcome'])}"
                   + (f": {h(e['message'])}" if e.get("message") else "")
                   + f" <em>{h(labels_text(e['labels']))}</em></li>" for e in entries)


def details(title, entries):
    return f"<details><summary>{h(title)} ({len(entries)})</summary><ul>{entry_items(entries)}</ul></details>" if entries else ""


STYLE = """body{font:14px/1.45 system-ui,sans-serif;margin:1.5em auto;max-width:1200px;padding:0 16px;color:#1a1a1a;background:#fff}
table{border-collapse:collapse;margin:.5em 0}th,td{border:1px solid #ccc;padding:3px 8px;text-align:left;vertical-align:top}
td.n{text-align:right}.red{color:#fff;background:#b3261e;padding:4px 10px}.green{color:#fff;background:#1e6b2e;padding:4px 10px}
code{font-size:12px}em{color:#555}details{margin:.2em 0}
@media (prefers-color-scheme:dark){body{color:#e6e6e6;background:#161616}th,td{border-color:#444}em{color:#aaa}}"""


def render_html(report):
    out = ["<!doctype html>", '<html lang="en"><head><meta charset="utf-8">',
           '<meta name="viewport" content="width=device-width, initial-scale=1">',
           "<title>PostgreSQL 3rd-party tests</title>", f"<style>{STYLE}</style></head><body>",
           "<h1>PostgreSQL 3rd-party tests: report</h1>",
           f'<p><span class="{"red" if report["red"] else "green"}">Result: {"red" if report["red"] else "green"}</span></p>']
    if report["problems"]:
        out.append("<ul>" + "".join(f"<li>{h(p)}</li>" for p in report["problems"]) + "</ul>")
    out.append("<p>No comparison with earlier runs yet.</p>")
    head = ("Leg", "Status", "Compared with", "Total", "Passed", "Failed", "Errored", "Skipped",
            "Not executed", "Regressions", "Duration")
    for suite, s in report["suites"].items():
        out.append(f"<h2>{h(suite)}</h2>")
        if suite_meta(s):
            out.append(f"<p>{h(suite_meta(s))}</p>")
        if s["problem"]:
            out.append(f"<p>{h(suite)}: {h(s['problem'])}</p>")
        if not s["legs"]:
            continue
        out.append("<table><tr>" + "".join(f"<th>{c}</th>" for c in head) + "</tr>")
        out += ["<tr>" + "".join(f'<td{" class=n" if i >= 3 else ""}>{h(c)}</td>' for i, c in enumerate(leg_cells(leg, d)))
                + "</tr>" for leg, d in s["legs"].items()]
        out.append("</table>")
        out += [f"<p>{h(leg)}: {d['files_unreadable']} JUnit files could not be read.</p>"
                for leg, d in s["legs"].items() if d["files_unreadable"]]
        for leg, d in s["legs"].items():
            if not d["comparable"]:
                continue
            c = d["classes"]
            out.append(f"<h3>{h(leg)}: {len(c['proxy_regression'])} tests pass directly but not through ProxySQL</h3>")
            rows = class_rows(d)
            if rows:
                out.append("<table><tr><th>Class</th><th>Failed</th><th>Errored</th><th>Not executed</th><th>Labels</th></tr>")
                out += [f"<tr><td>{details(cls, entries) or h(cls)}</td><td class=n>{f}</td><td class=n>{e}</td>"
                        f"<td class=n>{ne}</td><td>{h(', '.join(f'{k} ({v})' for k, v in sorted(lbs.items())))}</td></tr>"
                        for cls, f, e, ne, lbs, entries in rows]
                out.append("</table>")
            if not_reached(d):
                out.append(f"<p>Not reached before the time limit: {not_reached(d)}</p>")
            out.append(f"<p>{h(other_counts(d))}</p>")
            out.append(details("Fails both ways", c["both_fail"]) + details("Passes only through ProxySQL", c["proxy_only_pass"])
                       + details("Skipped in one leg only", c["skip_mismatch"])
                       + details("Only in this leg, not passed", [e for e in c["leg_only"] if e["outcome"] != "passed"]))
        out.append("<h3>Direct baseline failures</h3>")
        items = "".join(f"<li>{h(leg)}: <code>{h(e['id'])}</code> ({h(e['outcome'])}): {h(e['message'])} "
                        f"<em>{h(labels_text(e['labels']))}</em></li>"
                        for leg, d in s["legs"].items() for e in d["baseline_failures"])
        out.append(f"<ul>{items}</ul>" if items else "<p>None.</p>")
        if s["issues"]:
            hits = matched(s)
            out.append("<h3>Known issues</h3><table><tr><th>Label</th><th>Reason</th><th>Link</th><th>Tests matched</th></tr>")
            out += [f"<tr><td>{h(i['label'])}</td><td>{h(i['reason'])}</td><td>"
                    + (f'<a href="{h(i["link"])}">{h(i["link"])}</a>' if i.get("link") else "")
                    + f"</td><td class=n>{len(hits.get((i['label'], i['reason']), ()))}</td></tr>" for i in s["issues"]]
            out.append("</table>")
    out.append("</body></html>")
    return "\n".join(out) + "\n"


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
    report["problems"] = problems(report)
    report["red"] = bool(report["problems"])
    write_json(out_dir / "comparison.json", report)
    (out_dir / "report.md").write_text(render_md(report), encoding="utf-8")
    (out_dir / "report.html").write_text(render_html(report), encoding="utf-8")
    for problem in report["problems"]:
        print(f"::error::{problem}", file=sys.stderr)
    return 1 if report["red"] else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
