#!/usr/bin/env python3
"""Synthetic scanner fixtures never contain real production credentials."""
import unittest
from check_public_tree import inspect


class PublicTreeTests(unittest.TestCase):
    def test_symlinks_and_unapproved_paths(self):
        self.assertIn('symlink', inspect('lib/link.dart', b'', symlink=True))
        self.assertIn('outside-public-allowlist', inspect('backups/sample.txt', b''))
        self.assertIn('forbidden-file', inspect('assets/data.db', b''))

    def test_embedded_and_wide_metadata(self):
        key = b'A' + b'Iza' + b'x' * 35
        for data in (b'\x89PNG\x00' + key, key.decode().encode('utf-16-le')):
            self.assertIn('firebase-client-key', inspect('assets/image.png', data))

    def test_service_coupling(self):
        dependency = b'package:' + b'firebase_auth/auth.dart'
        self.assertIn('telemetry-dependency', inspect('test/fixture.dart', dependency))
        host = b'https://sample.' + b'workers' + b'.dev'
        self.assertIn('production-host', inspect('lib/config.dart', host))

    def test_public_source(self):
        self.assertEqual([], inspect('lib/example.dart', b'void main() {}'))
        self.assertEqual([], inspect('LICENSE', b'Apache License'))


if __name__ == '__main__':
    unittest.main()
