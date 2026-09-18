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
ALLOWED_NODE_TYPES = ('Suite', 'Unit Test Case', 'UI Test Case')
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
    if node_type not in ALLOWED_NODE_TYPES:
        raise ValueError('Unexpected xcresult node type: ' + repr(node_type))
    result = node.get('result')
    if result not in ALLOWED_RESULTS:
        raise ValueError('Unexpected xcresult node result: ' + repr(result))
    clean = {'nodeType': node_type, 'result': result}
    name = node.get('name')
    if isinstance(name, str) and SAFE_NAME.fullmatch(name):
        clean['name'] = name
    else:
        clean['name'] = _redact(name)
        stats['redacted'] += 1
    duration = node.get('duration')
    if duration is not None:
        if type(duration) not in (int, float) or isinstance(duration, bool) or duration < 0:
            raise ValueError('Invalid xcresult node duration')
        clean['duration'] = duration
    for key in REDACT_KEYS:
        if key in node:
            clean[key] = _redact(node[key])
            stats['redacted'] += 1
    known = {'nodeType', 'result', 'name', 'duration', 'children'} | set(REDACT_KEYS)
    for key in node:
        if key not in known:
            stats['dropped'] += 1
    if 'children' in node:
        children = node['children']
        if not isinstance(children, list):
            raise ValueError('xcresult node children must be a list')
        clean['children'] = [_walk_node(child, stats) for child in children]
    return clean


def _count_cases(node, tallies):
    if node['nodeType'].endswith('Test Case'):
        if 'children' in node:
            raise ValueError('xcresult test case must not have children')
        tallies[node['result']] += 1
        return 1
    if 'children' not in node:
        raise ValueError('xcresult suite must have children')
    return sum(_count_cases(child, tallies) for child in node['children'])


def sanitize_report(payload, summary):
    """Full sanitized test tree from `xcresulttool get test-results tests`.

    Keeps structure, results, and durations only. Names that are not plain
    identifiers and all free text become length-only redaction markers;
    internal ids, attachments, and unknown keys are dropped and counted.
    Fails closed on schema drift or any disagreement with the aggregate.
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
