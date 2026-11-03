# Contributing to Kakey

Thanks for your interest in Kakey. This guide covers what you need before opening an issue or a pull request.

## Before You Start

- Read [AGENTS.md](AGENTS.md) for the repository rules. They apply to human and AI contributors alike.
- Check [docs/PROJECT.md](docs/PROJECT.md) for the product scope and non-goals. Features listed as out of scope (for example cloud accounts, telemetry, browser autofill, or widgets) won't be accepted without a prior design discussion.
- For larger changes, open an issue first so the approach can be agreed on before you write code.

## Development Setup

[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) lists the toolchain and every build step. In short:

```bash
make help    # list all commands
make test    # core, Mac, iOS, and Android tests
```

All build output goes to `Build/`. Machine-specific settings go in `local.mk` (copied from `local.mk.example`), which is never committed.

## Documentation Map

| Document | Contents |
|---|---|
| [AGENTS.md](AGENTS.md) | Repository rules: architecture, build output, security, localization, tests |
| [docs/PROJECT.md](docs/PROJECT.md) | Product definition, scope, non-goals, confirmed decisions |
| [docs/DESIGN.md](docs/DESIGN.md) | Interaction, settings, and persistence |
| [docs/TECHNICAL.md](docs/TECHNICAL.md) | Stack, layers, data contracts, test strategy |
| [docs/SECURITY.md](docs/SECURITY.md) | Threat model and security rules |
| [docs/ROADMAP.md](docs/ROADMAP.md) · [docs/PLAN.md](docs/PLAN.md) | Phases and direction · current batch and tech debt |
| [docs/VALIDATION.md](docs/VALIDATION.md) | Implementation and verification status |
| [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) | Toolchain, commands, build output, signing, and release |
| [docs/LOCALIZATION.md](docs/LOCALIZATION.md) | Localization contract and glossary |
| [Core/golden/README.md](Core/golden/README.md) | Golden vectors shared by all platform tests |
| Component docs | Implementation notes for [Core](Core/docs/TECHNICAL.md), [Mac](Apple/Mac/docs/TECHNICAL.md), [iOS](Apple/iOS/docs/TECHNICAL.md), and [Android](Android/docs/TECHNICAL.md); each component's `docs/CHANGELOG.md` |

## Pull Requests

- Keep each pull request to one logical change, and use [Conventional Commits](https://www.conventionalcommits.org/) for commit messages, for example `fix(core): reject zero-length secrets`.
- Run `make test` (or at least the test target of every platform you touched) and make sure it passes.
- Shared logic belongs in the Rust core (`Core/`), not in platform code. A change in observable core behavior updates `Core/golden/` and `Core/docs/CHANGELOG.md` in the same commit.
- User-visible strings go into `Apple/Shared/Resources/Localizable.xcstrings` with English, Simplified Chinese, and Traditional Chinese filled in. The localization guard in the test targets enforces this.
- Update the docs that describe what you changed: interaction and settings in `docs/DESIGN.md`, data contracts in `docs/TECHNICAL.md`, user-visible changes in the component's `docs/CHANGELOG.md`.
- Changes to encryption, locking, import and export, sync, or networking must follow [docs/SECURITY.md](docs/SECURITY.md); explain any trade-off in the pull request.
- New dependencies need a pinned version, a compatible license (no GPL), and an entry in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Reporting Security Issues

Don't open a public issue for a vulnerability. See [.github/SECURITY.md](.github/SECURITY.md).

## License

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
