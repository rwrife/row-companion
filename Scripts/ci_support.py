#!/usr/bin/env python3
"""Fail-closed Xcode pin, simulator selection, and allowlisted result export.

Two evidence levels are published, both privacy-sanitized with commit provenance:

1. ``export-summary`` — allowlisted aggregate counts from the real xcresult.
2. ``export-report`` — the full sanitized test tree: suite/case structure,
   per-case results and durations, with every free-text field redacted to
   length-only markers and all internal references, attachments, and unknown
   keys dropped. The raw ``.xcresult`` bundle stays on the ephemeral runner.

Neither path publishes raw bundle bytes; unknown schema keys fail closed or are
dropped rather than copied, so private strings can never ride new fields.
"""
import argparse
import json
from pathlib import Path
import re
import subprocess
import uuid


XCODE_PIN = 'Xcode 26.0.1'
XCODE_BUILD_PIN = '17A400'

SAFE_NAME = re.compile(r'[A-Za-z0-9_.\-]{1,128}')
# Real hosted evidence on the pinned toolchain (jobs 105491046148,
# 105492551762, 105494245523): the tests tree uses a drifting label set —
# 'Test Plan' root, 'Unit test bundle'/'UI test bundle' wrappers, plain
# 'Test Case' leaves (not the documented 'Unit Test Case'). Labels are enum
# words, not free text, but they are not stable, so the sanitizer is
# shape-driven: containers are nodes with a children list, cases are
# leaves. Known labels pass through; ANY unknown label (container or case)
# is published only as a length-only redaction marker. Names are always
# pattern-checked, free text is always redacted, unknown keys are dropped,
# and the export still aborts unless the leaf tallies exactly match the
# independently exported aggregate summary. An unrecognized schema can
# therefore neither leak strings nor produce self-consistent-looking
# evidence that disagrees with the aggregate.
KNOWN_CONTAINER_TYPES = ('Test Plan', 'Suite', 'Test Suite',
                         'Unit test bundle', 'UI test bundle')
KNOWN_CASE_TYPES = ('Test Case', 'Unit Test Case', 'UI Test Case',
                    'Function Test Case', 'Container Test Case',
                    'Automation Test Case')
ALLOWED_RESULTS = ('Passed', 'Failed', 'Skipped')
REDACT_KEYS = ('failureText', 'description', 'comments')


def validate_versions(xcode, sdk):
    lines = xcode.splitlines()
    if lines[0:1] != [XCODE_PIN]:
        observed = lines[0] if lines else '(missing)'
        raise ValueError(XCODE_PIN + ' is required exactly; observed ' + observed)
    build = re.fullmatch(r'Build version (\S+)', lines[1]) if lines[1:2] else None
    if build is None or build.group(1) != XCODE_BUILD_PIN:
        raise ValueError('Xcode build ' + XCODE_BUILD_PIN + ' is required exactly; observed '
                         + (lines[1] if lines[1:] else '(missing)'))
    if not re.fullmatch(r'\d+\.\d+(?:\.\d+)?', sdk.strip()):
        raise ValueError('Invalid iOS SDK version')
    if int(sdk.split('.')[0]) < 26:
        raise ValueError('iOS SDK 26 or newer is required')


def select_simulator(payload):
    candidates = []
    for runtime, devices in payload.get('devices', {}).items():
        if not re.fullmatch(r'com\.apple\.CoreSimulator\.SimRuntime\.iOS-26-\d+(?:-\d+)?', runtime):
            continue
        for device in devices:
            if device.get('isAvailable') is not True or not device.get('name', '').startswith('iPhone'):
                continue
            try:
                udid = str(uuid.UUID(device['udid'])).upper()
            except (ValueError, KeyError, TypeError, AttributeError):
                continue
            candidates.append((runtime, device['name'], udid))
    if not candidates:
        raise ValueError('No available iOS 26 iPhone simulator with valid UDID')
    return sorted(candidates)[0][2]


def sanitize_summary(payload):
    fields = ('totalTestCount', 'passedTests', 'failedTests', 'skippedTests')
    clean = {}
    for field in fields:
        value = payload.get(field)
        if type(value) is not int or value < 0:
            raise ValueError('Missing or invalid xcresult count: ' + field)
        clean[field] = value
    if clean['totalTestCount'] == 0:
        raise ValueError('xcresult contains no tests')
    if sum(clean[key] for key in fields[1:]) != clean['totalTestCount']:
        raise ValueError('Inconsistent xcresult test counts')
    result = payload.get('result')
    if result not in ('Passed', 'Failed', 'Skipped'):
        raise ValueError('Unrecognized xcresult result')
    if result == 'Passed' and (clean['failedTests'] or clean['passedTests'] == 0):
        raise ValueError('Inconsistent passed xcresult')
    if result == 'Failed' and clean['failedTests'] == 0:
        raise ValueError('Failed xcresult has no failed tests; cannot attest aggregate')
    if result == 'Skipped' and clean['skippedTests'] != clean['totalTestCount']:
        raise ValueError('Inconsistent skipped xcresult')
    clean['result'] = result
    return clean


def _redact(value):
    return {'redacted': True, 'length': len(json.dumps(value))}


def _walk_node(node, stats):
    if not isinstance(node, dict):
        raise ValueError('xcresult test node must be an object')
    node_type = node.get('nodeType')
    children = node.get('children')
    clean: dict = {}
    if isinstance(children, dict) or children is not None and not isinstance(children, list):
        raise ValueError('xcresult node children must be a list')
    if isinstance(children, list):
        known = KNOWN_CONTAINER_TYPES
    else:
        known = KNOWN_CASE_TYPES
    if node_type in known:
        clean['nodeType'] = node_type
    else:
        clean['nodeType'] = _redact(node_type)
        stats['redacted'] += 1
    result = node.get('result')
    if result is None:
        # Real hosted evidence (runs 35656419607 / 35661673966 / 35662926491,
        # Xcode 26.0.1): nodes can omit `result` entirely — the Test Plan
        # root, empty wrappers, and even a test-case leaf (aggregate summary
        # counted 57/57 Passed while the tree carried 56 verdicts, so the
        # resultless leaf was one of those passing cases). Tolerate exactly
        # None; such a node is published without its own verdict, and if it
        # is leaf-shaped it is tallied under its enclosing bundle/suite's
        # unique verdict (see _count_cases). Unknown NON-null results still
        # fail closed.
        pass
    elif result not in ALLOWED_RESULTS:
        raise ValueError('Unexpected xcresult node result: ' + repr(result))
    else:
        clean['result'] = result
    name = node.get('name')
    if isinstance(name, str) and SAFE_NAME.fullmatch(name):
        clean['name'] = name
    else:
        clean['name'] = _redact(name)
        stats['redacted'] += 1
    duration = node.get('duration')
    if duration is not None:
        if type(duration) in (int, float) and not isinstance(duration, bool) and duration >= 0:
            clean['duration'] = duration
        else:
            # Duration shape is decoration, not an invariant (no-leak and
            # tally-match still hold); an unrecognized form is dropped.
            stats['dropped'] += 1
    for key in REDACT_KEYS:
        if key in node:
            clean[key] = _redact(node[key])
            stats['redacted'] += 1
    known = {'nodeType', 'result', 'name', 'duration', 'children'} | set(REDACT_KEYS)
    for key in node:
        if key not in known:
            stats['dropped'] += 1
    if isinstance(children, list):
        clean['children'] = [_walk_node(child, stats) for child in children]
    return clean


def _count_cases(node, tallies, ancestor_verdicts=()):
    if 'children' in node:
        verdicts = tuple(ancestor_verdicts)
        if 'result' in node:
            verdicts = verdicts + (node['result'],)
        return sum(_count_cases(child, tallies, verdicts)
                   for child in node['children'])
    if 'result' not in node:
        # Structural node or a test-case leaf published WITHOUT its own
        # verdict (runs 35656419607 / 35661673966 / 35662926491, Xcode
        # 26.0.1: the aggregate summary counted 57/57 Passed while the
        # tree carried only 56 verdicts — the resultless leaf is one of
        # those counted cases). Tally it only when every enclosing
        # container shares exactly one verdict, so the inherited verdict
        # is unambiguous; otherwise the tree cannot attest this leaf and
        # the export fails closed.
        unique = set(ancestor_verdicts)
        if len(unique) != 1:
            raise ValueError(
                'Resultless xcresult leaf has no unique enclosing verdict: '
                + json.dumps(sorted(unique)))
        tallies[next(iter(unique))] += 1
        return 1
    # Shape-driven: every leaf with a verdict is a test case. A schema that
    # produced only containers would yield zero cases and fail the
    # aggregate-count match.
    tallies[node['result']] += 1
    return 1


def sanitize_report(payload, summary):
    """Full sanitized test tree from `xcresulttool get test-results tests`.

    Shape-driven sanitizer: containers are nodes with a children list, cases
    are leaves. Known type labels pass through, unknown labels and any
    non-identifier name become length-only redaction markers; free text,
    internal ids, attachments, and unknown keys are dropped and counted.
    Structural drift (wrong root, non-list children, unknown result value)
    aborts, as does any disagreement with the aggregate summary.
    """
    clean_summary = sanitize_summary(summary)
    if isinstance(payload, dict):
        roots = payload.get('testNodes')
    else:
        roots = payload
    if not isinstance(roots, list):
        raise ValueError('Unexpected xcresult tests schema: missing testNodes list')
    stats = {'redacted': 0, 'dropped': 0}
    nodes = [_walk_node(node, stats) for node in roots]
    tallies = {'Passed': 0, 'Failed': 0, 'Skipped': 0}
    case_count = sum(_count_cases(node, tallies) for node in nodes)
    if (case_count != clean_summary['totalTestCount']
            or tallies['Passed'] != clean_summary['passedTests']
            or tallies['Failed'] != clean_summary['failedTests']
            or tallies['Skipped'] != clean_summary['skippedTests']):
        raise ValueError('Sanitized test tree and aggregate counts disagree: '
                         + json.dumps(tallies) + ' vs ' + json.dumps(clean_summary))
    return {'aggregate': clean_summary, 'caseCount': case_count,
            'testNodes': nodes, 'redactedFields': stats['redacted'],
            'droppedFields': stats['dropped']}


def _attach_provenance(output):
    output['tested_commit'] = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
    output['xcode'] = subprocess.check_output(['xcodebuild', '-version'], text=True).strip()
    output['iphoneos_sdk'] = subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-version'], text=True).strip()
    validate_versions(output['xcode'], output['iphoneos_sdk'])
    return output


def _write_json(output, path):
    destination = Path(path)
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(json.dumps(output, indent=2) + '\n')
    return destination


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    sub.add_parser('check-toolchain')
    sub.add_parser('select-simulator')
    export = sub.add_parser('export-summary')
    export.add_argument('--result-bundle', required=True)
    export.add_argument('--output', required=True)
    report = sub.add_parser('export-report')
    report.add_argument('--result-bundle', required=True)
    report.add_argument('--output', required=True)
    args = parser.parse_args()
    if args.command == 'check-toolchain':
        xcode = subprocess.check_output(['xcodebuild', '-version'], text=True).strip()
        sdk = subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-version'], text=True).strip()
        print(xcode, flush=True)
        print('iphoneos SDK: ' + sdk, flush=True)
        validate_versions(xcode, sdk)
    elif args.command == 'select-simulator':
        raw = subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', 'available', '--json'], text=True)
        print(select_simulator(json.loads(raw)))
    elif args.command == 'export-summary':
        raw = subprocess.check_output(['xcrun', 'xcresulttool', 'get', 'test-results', 'summary',
                                       '--path', args.result_bundle], text=True)
        output = sanitize_summary(json.loads(raw))
        _attach_provenance(output)
        output['evidence_kind'] = 'allowlisted-xcresult-summary-not-full-bundle'
        destination = _write_json(output, args.output)
        print('Sanitized aggregate test evidence: ' + str(destination))
    else:
        raw_summary = subprocess.check_output(['xcrun', 'xcresulttool', 'get', 'test-results', 'summary',
                                               '--path', args.result_bundle], text=True)
        raw_tests = subprocess.check_output(['xcrun', 'xcresulttool', 'get', 'test-results', 'tests',
                                             '--path', args.result_bundle], text=True)
        output = sanitize_report(json.loads(raw_tests), json.loads(raw_summary))
        _attach_provenance(output)
        output['evidence_kind'] = 'sanitized-full-xcresult-test-tree-not-raw-bundle'
        destination = _write_json(output, args.output)
        print('Sanitized full test-tree evidence: ' + str(destination))


if __name__ == '__main__':
    main()
