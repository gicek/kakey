# Moving cloudset to its own repository

cloudset is developed inside its first host application's repository. This directory is kept ready to be copied out as
a repository of its own; this file lists what is already true and the steps that remain.

## Ready now

- Self-contained manifest: no `workspace = true` fields, no path dependencies besides the crate itself (for the
  `testing` feature in dev-dependencies), license file included.
- No dependency on the host's crates or on FFI frameworks; no file, environment, clock or randomness access.
- Source, tests, golden files and documentation never name the host application.
- The host's core test gate copies this directory out of its workspace, appends an empty `[workspace]` table and runs
  clippy, the tests and `cargo package --list` there, offline, with the workspace's lock file. A failure means the copy
  would not stand on its own.

## Remaining preconditions

- At least three OAuth providers accepted against the real services (sign-in, reads, conditional writes, refresh,
  revocation), recorded in the host's validation notes.
- A decision to publish: creating the repository and publishing to crates.io are public actions taken by the owner.

## Steps

1. Create the repository and copy this directory to its root, keeping history if wanted
   (`git subtree split --prefix=<path to this directory>`).
2. In `Cargo.toml`: set `repository`, `documentation` and `homepage`; drop `publish = false` when ready to publish.
3. Add CI that runs `cargo fmt --check`, `cargo clippy --all-targets -- -D warnings`, `cargo test` and `cargo deny check`
   on the minimum supported Rust version and on stable. Licenses stay permissive only, as today (MIT, Apache-2.0, BSD,
   ISC, Unicode-3.0, Zlib, CC0-1.0), and advisories are checked on every run.
4. Move the `[Unreleased]` section of `CHANGELOG.md` under the first public version and tag it.
5. In the host repository, depend on the published version (or a git tag) instead of the path, delete this directory,
   and keep the host's dependency-graph check pointing at the external crate.
