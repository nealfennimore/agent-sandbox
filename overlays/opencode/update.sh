#!/usr/bin/env bash
# Bump overlays/opencode/manifest.json to the latest (or a given) release.
# Needs only curl and jq: the checksums come from the GitHub release API, so
# no nix and no download of the binaries. Then `git diff manifest.json` and
# rebuild.
#
#   ./update.sh            # latest release
#   ./update.sh 1.19.3     # a specific version
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

OWNER="anomalyco"
REPO="opencode"
API="https://api.github.com/repos/${OWNER}/${REPO}/releases"

if [[ -n "${1:-}" ]]; then
  release="$(curl -fsSL "${API}/tags/v${1#v}")"
else
  release="$(curl -fsSL "${API}/latest")"
fi

# Platform keys match stdenv.hostPlatform.node.{platform,arch} in package.nix.
jq '{
  version: (.tag_name | ltrimstr("v")),
  platforms: (
    [.assets[]
      | select(.name | test("^opencode-(linux-(x64|arm64)\\.tar\\.gz|darwin-arm64\\.zip)$"))
      | {
          key: (.name | capture("^opencode-(?<k>[a-z]+-[a-z0-9]+)\\.").k),
          value: { asset: .name, checksum: (.digest | ltrimstr("sha256:")) }
        }
    ] | from_entries
  )
}' <<<"$release" >manifest.json.new

if [[ "$(jq '.platforms | length' manifest.json.new)" -ne 3 ]]; then
  echo "expected 3 platform assets, got:" >&2
  jq '.platforms' manifest.json.new >&2
  rm manifest.json.new
  exit 1
fi

mv manifest.json.new manifest.json
echo "Updated manifest.json -> $(jq -r .version manifest.json)" >&2
