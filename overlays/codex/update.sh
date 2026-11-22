#!/usr/bin/env bash
# Bump overlays/codex/manifest.json to the latest (or a given) release.
# Needs only curl and jq: the checksums come from the GitHub release API, so
# no nix and no download of the binaries. Then `git diff manifest.json` and
# rebuild.
#
#   ./update.sh            # latest release
#   ./update.sh 0.164.0    # a specific version
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

OWNER="openai"
REPO="codex"
API="https://api.github.com/repos/${OWNER}/${REPO}/releases"

if [[ -n "${1:-}" ]]; then
  release="$(curl -fsSL "${API}/tags/rust-v${1#rust-v}")"
else
  release="$(curl -fsSL "${API}/latest")"
fi

# Keys are the Rust target triples in the asset names. package.nix builds
# the same key from the host CPU and OS.
jq '{
  version: (.tag_name | ltrimstr("rust-v")),
  platforms: (
    [.assets[]
      | select(.name | test("^codex-package-(x86_64|aarch64)-(unknown-linux-musl|apple-darwin)\\.tar\\.gz$"))
      | {
          key: (.name | capture("^codex-package-(?<k>.+)\\.tar\\.gz$").k),
          value: { asset: .name, checksum: (.digest | ltrimstr("sha256:")) }
        }
    ] | from_entries
  )
}' <<<"$release" >manifest.json.new

if [[ "$(jq '.platforms | length' manifest.json.new)" -ne 4 ]]; then
  echo "expected 4 platform assets, got:" >&2
  jq '.platforms' manifest.json.new >&2
  rm manifest.json.new
  exit 1
fi

mv manifest.json.new manifest.json
echo "Updated manifest.json -> $(jq -r .version manifest.json)" >&2
