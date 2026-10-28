# Security Policy

## Supported versions

| Version | Supported |
| --- | --- |
| Latest `0.2.x` release | Yes |
| Older releases | No — please upgrade first |

## Reporting a vulnerability

Please use GitHub's private vulnerability reporting (Security Advisories) on this repository:

https://github.com/kakadex/MusicOrganizer/security/advisories/new

Do **not** open a public issue for security-sensitive reports (path traversal, file overwrite,
credential leakage, unsafe archive handling, etc.).

## What to include

- Affected version (Settings → About shows the full build string)
- Platform (Android / Windows) and the exact steps to reproduce
- Impact assessment: what an attacker could read, overwrite or delete
- A minimal sample file if the issue is format-specific (never send private music files)

## Response

We aim to acknowledge a report within 7 days and, when reproducible, ship a fix in the next
patch release. Credit is given in the release notes unless you ask to stay anonymous.
