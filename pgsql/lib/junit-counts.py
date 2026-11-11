"""Usage: python3 -I junit-counts.py DIR

Prints the summed test counts of the JUnit XML files in DIR as one JSON object
({"total", "failures", "errors", "skipped", "files", "files_unreadable"}), or null if DIR has no
*.xml. Handles <testsuite> and <testsuites> roots. A file that cannot be parsed (for example cut off
when a runner was killed) is counted in files_unreadable and otherwise ignored.
"""
import glob
import json
import os
import sys
import xml.etree.ElementTree as ET

KEYS = ("tests", "failures", "errors", "skipped")


def suites(root):
    if root.tag == "testsuite":
        return [root]
    return root.findall("testsuite") if root.tag == "testsuites" else []


def main(directory):
    paths = sorted(glob.glob(os.path.join(directory, "*.xml")))
    if not paths:
        print("null")
        return
    totals = dict.fromkeys(KEYS, 0)
    files = unreadable = 0
    for path in paths:
        try:
            root = ET.parse(path).getroot()
        except (ET.ParseError, OSError):
            unreadable += 1
            continue
        files += 1
        for suite in suites(root):
            for key in KEYS:
                totals[key] += int(suite.get(key) or 0)
    print(json.dumps({"total": totals["tests"], "failures": totals["failures"], "errors": totals["errors"],
                      "skipped": totals["skipped"], "files": files, "files_unreadable": unreadable}))


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: junit-counts.py DIR")
    main(sys.argv[1])
