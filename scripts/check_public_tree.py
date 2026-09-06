#!/usr/bin/env python3
"""Check tracked and not-ignored candidate files; never print matched secrets."""
import pathlib, re, subprocess, sys
root = pathlib.Path(__file__).resolve().parents[1]
files = subprocess.check_output(['git','ls-files','-z','--cached','--others','--exclude-standard'], cwd=root).decode().split('\0')
forbidden_names = {'GoogleService-Info.plist','google-services.json','key.properties'}
forbidden_extensions = {'.p8','.p12','.pfx','.pem','.key','.mobileprovision','.keystore','.jks','.bundle','.sqlite','.db'}
patterns = {
 'private-key': re.compile(r'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----'),
 'personal-path': re.compile(r'/(?:Users|home)/[A-Za-z0-9_.-]+/'),
 'production-host': re.compile(r'https?://[^\s\x27\x22<>]*(?:workers\.dev|firebaseio\.com|cloudfunctions\.net|appspot\.com)'),
 'firebase-client-key': re.compile(r'AIza[0-9A-Za-z_-]{30,}'),
 'provider-key': re.compile(r'\bsk-(?:proj-|svcacct-)?[A-Za-z0-9_-]{20,}'),
 'apple-team': re.compile(r'DEVELOPMENT_TEAM\s*=\s*[A-Z0-9]{10}\s*;'),
}
failures=[]
for name in sorted(set(filter(None,files))):
 path=root/name
 if path.is_symlink():
  failures.append((name,'symlink')); continue
 if path.name in forbidden_names or path.suffix.lower() in forbidden_extensions or (path.name.startswith('.env') and path.name != '.env.example'):
  failures.append((name,'forbidden-file'))
 if not path.is_file(): continue
 try: contents=path.read_text(encoding='utf-8')
 except UnicodeDecodeError: continue
 for rule,pattern in patterns.items():
  if pattern.search(contents): failures.append((name,rule))
for name,rule in failures: print(f'{name}: {rule}')
if failures: sys.exit(1)
print(f'Public-tree check passed: {len(set(filter(None,files)))} files')
