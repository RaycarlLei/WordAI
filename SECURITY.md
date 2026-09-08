# Security

Never commit provider keys, signing certificates, provisioning profiles, real service configuration, user databases, cached audio or production logs. Use dummy fixtures and configuration with empty defaults.

Learning backups contain vocabulary and review history as readable JSON. Keep
them out of issues, test fixtures and commits. The [backup format](docs/learning-backup.md)
validates size, structure and references; it does not authenticate the author or
encrypt the content. Use a private destination when exporting personal data.

Before publishing, run the public-tree check and Gitleaks with redaction. These checks supplement manual review; they cannot prove that no sensitive information exists.

If you find a secret, do not post it in a public issue. Use GitHub private vulnerability reporting when enabled. Revoke or rotate an exposed credential with its provider; deleting a file alone does not erase Git history or copies.
