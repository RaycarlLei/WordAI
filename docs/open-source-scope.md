# Open-source boundary

The public repository maintains an independently runnable local-learning core and
example app. The private product is maintained separately. No private branch or
Git history is merged into this repository.

| Included | Excluded |
|---|---|
| Learning state, question generation, flash cards and regression tests | Accounts, cloud sync, billing, analytics and production AI services |
| SQLite storage, S6 parsing and original example words | Production dictionaries and pre-generated audio collections |
| Cached pronunciation and an optional gateway protocol | Provider credentials, signing material and deployment configuration |

Updates select reusable changes in a separate workspace, remove service coupling,
retain attribution and licenses, and pass tests, platform builds and public-tree
checks before publication. Private Git objects, audit reports, backups and logs
must not be published.

The default app does not contact production services or automatically download
paid resources. Open-source software does not include hosted compute or third-party
speech service credits. See the [Chinese version](open-source-scope.zh-CN.md).

## Local feature updates

Word books, learned-word admission, seven-day trash and recovery are adapted to
one local SQLite profile. Hosted catalogs, accounts, synchronization, assistant
connections, production identifiers and deployment resources are excluded.
Updates preserve the public repository history and select source capabilities
without importing private Git objects. Public checks include path allowlists,
secret scanning, binary metadata scanning and offline regression scenarios.
