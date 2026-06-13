# Security Policy

## Supported versions

Only the latest release receives security fixes.

| Version | Supported |
|---------|-----------|
| 3.4.x (latest) | ✅ |
| < 3.4 | ❌ |

## Reporting a vulnerability

**Please do not report security vulnerabilities as public GitHub Issues.**

Send a description to **m.moraisdacunha@pm.me** with:

- A description of the vulnerability
- Steps to reproduce
- Potential impact

I'll acknowledge within **72 hours** and aim to release a fix within **30 days** depending on severity. If you'd like to be credited in the release notes, let me know.

## Scope

In scope:

- HAL Audio Driver (`driver/`)
- C Audio Routing Daemon (`helper/`)
- Python Menu Bar App (`engine/`)
- Installation scripts (`installer/`)

Out of scope:

- Vulnerabilities in third-party dependencies (report upstream)
- macOS system-level issues
- Issues requiring physical access to the machine
