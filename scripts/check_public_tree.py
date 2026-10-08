#!/usr/bin/env python3
"""Scan tracked and non-ignored candidate bytes; report paths/rules only."""
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
FORBIDDEN_NAMES = {'GoogleService-Info.plist', 'google-services.json', 'key.properties',
                   '.mcp.json', 'release_manifest.json', 'AGENT-CREDENTIALS.md'}
FORBIDDEN_SUFFIXES = {'.p8', '.p12', '.pfx', '.pem', '.key', '.mobileprovision',
                      '.keystore', '.jks', '.bundle', '.sqlite', '.sqlite3', '.db',
                      '.mp3', '.m4a', '.wav', '.zip', '.ipa', '.apk', '.aab', '.log'}
ALLOWED_ROOTS = {'.github', 'android', 'assets', 'docs', 'examples', 'ios',
                 'lib', 'macos', 'scripts', 'test', 'tool'}
ALLOWED_ROOT_FILES = {'.gitignore', '.metadata', 'CHANGELOG.md', 'CONTRIBUTING.md',
                      'LICENSE', 'NOTICE', 'README.md', 'README.zh-CN.md',
                      'SECURITY.md', 'THIRD_PARTY_NOTICES.md', 'analysis_options.yaml',
                      'pubspec.yaml', 'pubspec.lock'}
PATTERNS = {
    'private-key': rb'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----',
    'personal-path': rb'/(?:Users|home)/[A-Za-z0-9_.-]+/',
    'private-volume': rb'/Volume[s]/[^\r\n\x22\x27]+',
    'production-host': rb'(?:workers\.dev|firebaseio\.com|cloudfunctions\.net|appspot\.com|awesome\-bears\.com)',
    'firebase-client-key': rb'AIza[0-9A-Za-z_-]{30,}',
    'provider-key': rb'\bsk-(?:proj-|svcacct-)?[A-Za-z0-9_-]{20,}',
    'github-token': rb'\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,})',
    'cloud-access-key': rb'\b(?:AKIA|ASIA|LTAI)[A-Za-z0-9]{16,}',
    'apple-team': rb'DEVELOPMENT_TEAM\s*=\s*[A-Z0-9]{10}\s*;',
    'private-repo': rb'WordAI\x2ddev|wordai\x2dagent\x2dstaging',
    'telemetry-dependency': rb'package:(?:firebase_[a-z_]+|cloud_firestore|sentry_flutter|amplitude_flutter)/',
}
COMPILED = {name: re.compile(pattern) for name, pattern in PATTERNS.items()}


def inspect(name, data, symlink=False):
    path = pathlib.PurePosixPath(name)
    failures = []
    if symlink:
        return ['symlink']
    if '..' in path.parts or (len(path.parts) == 1 and name not in ALLOWED_ROOT_FILES) or (len(path.parts) > 1 and path.parts[0] not in ALLOWED_ROOTS):
        failures.append('outside-public-allowlist')
    if path.name in FORBIDDEN_NAMES or path.suffix.lower() in FORBIDDEN_SUFFIXES or (path.name.startswith('.env') and path.name != '.env.example'):
        failures.append('forbidden-file')
    # UTF-8, embedded ASCII, UTF-16 and UTF-32 metadata are all scanned.
    views = [data]
    for encoding in ('utf-16-le', 'utf-16-be', 'utf-32-le', 'utf-32-be'):
        try:
            views.append(data.decode(encoding).encode('utf-8'))
        except UnicodeError:
            pass
    for rule, pattern in COMPILED.items():
        if any(pattern.search(view) for view in views):
            failures.append(rule)
    return failures


def main():
    names = subprocess.check_output(['git', 'ls-files', '-z', '--cached', '--others', '--exclude-standard'], cwd=ROOT).decode().split('\0')
    failures = []
    for name in sorted(set(filter(None, names))):
        path = ROOT / name
        if path.is_symlink():
            failures.append((name, 'symlink'))
        elif path.is_file():
            failures.extend((name, rule) for rule in inspect(name, path.read_bytes()))
    for name, rule in failures:
        print(f'{name}: {rule}')
    if failures:
        return 1
    print(f'Public-tree check passed: {len(set(filter(None, names)))} files')
    return 0


if __name__ == '__main__':
    sys.exit(main())
