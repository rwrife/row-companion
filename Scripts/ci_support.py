#!/usr/bin/env python3
"""Fail-closed Xcode pin, simulator selection, and allowlisted result export.

Only a sanitized aggregate xcresult summary is published. The raw bundle stays
on the ephemeral CI runner; this is not a sanitized full-bundle archive.
"""
import argparse
import json
from pathlib import Path
import re
import subprocess
import uuid


XCODE_PIN = 'Xcode 26.0.1'
XCODE_BUILD_PIN = '17A400'


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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    sub.add_parser('check-toolchain')
    sub.add_parser('select-simulator')
    export = sub.add_parser('export-summary')
    export.add_argument('--result-bundle', required=True)
    export.add_argument('--output', required=True)
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
    else:
        raw = subprocess.check_output(['xcrun', 'xcresulttool', 'get', 'test-results', 'summary',
                                       '--path', args.result_bundle], text=True)
        output = sanitize_summary(json.loads(raw))
        output['tested_commit'] = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
        output['xcode'] = subprocess.check_output(['xcodebuild', '-version'], text=True).strip()
        output['iphoneos_sdk'] = subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-version'], text=True).strip()
        validate_versions(output['xcode'], output['iphoneos_sdk'])
        output['evidence_kind'] = 'allowlisted-xcresult-summary-not-full-bundle'
        destination = Path(args.output)
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(json.dumps(output, indent=2) + '\n')
        print('Sanitized aggregate test evidence: ' + str(destination))


if __name__ == '__main__':
    main()
