#!/bin/sh
# Split readiness for cloudset (docs/ROADMAP.md, Core/crates/cloudset/RELEASING.md): copy the crate out of the workspace
# exactly as it is, then build, lint and test it as its own package. Fails if the crate leans on anything outside its own
# directory (workspace inheritance, paths, shared lints) or mentions the host application.
#
# Usage: Core/scripts/cloudset-standalone.sh <scratch dir under Build/>. Runs offline with the workspace lock file, so it
# only needs crates already fetched by the workspace build.
set -eu

repo=$(cd "$(dirname "$0")/../.." && pwd)
crate="$repo/Core/crates/cloudset"
scratch=${1:?usage: cloudset-standalone.sh <scratch dir>}

if grep -rqi "kakey" "$crate"; then
    echo "cloudset mentions the host application:"
    grep -rli "kakey" "$crate"
    exit 1
fi

rm -rf "$scratch"
mkdir -p "$scratch"
scratch=$(cd "$scratch" && pwd)
cp -R "$crate" "$scratch/cloudset"
cp "$repo/Core/Cargo.lock" "$scratch/cloudset/Cargo.lock"
# An empty [workspace] table makes the copy its own workspace root, as it will be in its own repository.
printf '\n[workspace]\n' >> "$scratch/cloudset/Cargo.toml"

cd "$scratch/cloudset"
export CARGO_TARGET_DIR="$scratch/target"
cargo clippy --offline --all-targets -- -D warnings
cargo test --offline
cargo package --offline --allow-dirty --no-verify --list > /dev/null
echo "cloudset builds and passes its tests outside the workspace"
