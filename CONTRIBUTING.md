# Contributing to AudioRouterNow

Thank you for considering a contribution — it means a lot for a solo project.

## Bug reports

The fastest way to get a bug fixed is to include a diagnostic report:

1. Open AudioRouterNow → **Help → Save Diagnostic Report…**
2. Open a [GitHub Issue](../../issues/new?template=bug_report.md) and attach the report
3. Describe what happened and how to reproduce it

## Feature requests

Open a [GitHub Issue](../../issues/new?template=feature_request.md) and describe your use case. I read everything, though response time varies (this is a side project).

## Code contributions

1. **Fork** the repo and create a branch (`git checkout -b fix/my-fix`)
2. Make your changes
3. Open a **Pull Request** with a clear description of what you changed and why

### Code style

- **C code** — C11, no external dependencies, clang-tidy clean
- **Python** — compatible with Python 3.10+, no new third-party dependencies without prior discussion
- **Commit messages** — conventional commits preferred (`fix:`, `feat:`, `chore:`)

### Architecture notes

The project has three components that interact closely:

| Component | Location | Language |
|-----------|----------|----------|
| HAL Audio Driver | `driver/` | C |
| Audio Routing Daemon | `helper/` | C |
| Menu Bar App | `engine/` | Python |

Changes to the shared-memory ring buffer (`helper/shared_ring.h`) or IPC protocol affect all three — please open an issue first to discuss before touching those.

## Development tooling

Development uses AI tooling (Claude Code by Anthropic) for code review, documentation, and implementation support.

## License

By submitting a pull request, you agree that your contribution will be licensed under the **GPL-3.0 License** that covers this project.
