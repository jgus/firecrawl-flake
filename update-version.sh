#!/usr/bin/env -S nix shell nixpkgs#bash nixpkgs#gh nixpkgs#jq nixpkgs#gnused nixpkgs#gnugrep nixpkgs#nix-prefetch-github nixpkgs#nix --command bash

# Pins pin.nix to a release of firecrawl/firecrawl (apps/api) and re-validates every hash.
#
#   nix run .#update-version              # re-validate the CURRENTLY pinned version
#   nix run .#update-version -- 1.15.0    # pin a specific version (no v prefix)
#
# Defaults to the version already in pin.nix, NOT the latest release: v2.5+/v3 added a RabbitMQ + custom-Postgres queue and a pnpm workspace this flake does not build. Bump the major deliberately by passing an explicit version.

set -euo pipefail

FLAKE_ROOT="${FLAKE_ROOT:-${PWD}}"
pin="${FLAKE_ROOT}/pin.nix"
repo_owner=firecrawl
repo_name=firecrawl
fake="sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

if [[ ! -f "${pin}" ]]; then
  echo "error: no pin.nix in ${FLAKE_ROOT}" >&2
  echo "Run from the flake root (where pin.nix lives), or set FLAKE_ROOT to point at it." >&2
  exit 1
fi

cur_version=$(nix eval --raw --file "${pin}" version 2>/dev/null || echo "")
cur_rev=$(nix eval --raw --file "${pin}" sourceRev 2>/dev/null || echo "")
cur_src=$(nix eval --raw --file "${pin}" sourceHash 2>/dev/null || echo "")
cur_pnpm=$(nix eval --raw --file "${pin}" pnpmDepsHash 2>/dev/null || echo "")
cur_playwright=$(nix eval --raw --file "${pin}" playwrightPnpmDepsHash 2>/dev/null || echo "")
cur_go=$(nix eval --raw --file "${pin}" goVendorHash 2>/dev/null || echo "")
cur_nodesig=$(nix eval --raw --file "${pin}" nodesigHash 2>/dev/null || echo "")

if [[ $# -ge 1 && -n "${1}" ]]; then
  ver="${1#[Vv]}"
else
  ver="${cur_version}"
  echo "No version given; re-validating the currently pinned ${ver}."
fi

# Firecrawl tags are vX.Y.Z; also try bare/V for robustness.
rev=""
for candidate in "v${ver}" "${ver}" "V${ver}"; do
  if sha=$(gh api "/repos/${repo_owner}/${repo_name}/commits/${candidate}" --jq '.sha' 2>/dev/null); then
    rev="${sha}"; break
  fi
done
if [[ -z "${rev}" ]]; then
  echo "error: could not resolve ${ver} on ${repo_owner}/${repo_name}" >&2
  exit 1
fi

echo "  current: ${cur_version} (${cur_rev:-<empty>})"
echo "  target:  ${ver} (${rev})"

src_hash=$(nix-prefetch-github --rev "${rev}" "${repo_owner}" "${repo_name}" --json | jq -r '.hash // .sha256')

# Start from the resolved source + placeholder dynamic hashes, then scrape each in dependency order (the rust/go libs are inputs to firecrawl-api, so they must be valid before the pnpm hash can surface).
pnpm_hash="${fake}"; go_hash="${fake}"; nodesig_hash="${fake}"; playwright_hash="${fake}"

write_pin() {
  cat > "${pin}" <<EOF
# Auto-managed by \`nix run .#update-version\`. Manual edits will be overwritten by the next bump.
{
  version = "${ver}";
  sourceRev = "${rev}";
  sourceHash = "${src_hash}";
  # pnpm offline-deps mirror built from apps/api/pnpm-lock.yaml at sourceRev.
  pnpmDepsHash = "${pnpm_hash}";
  # pnpm offline-deps for apps/playwright-service-ts.
  playwrightPnpmDepsHash = "${playwright_hash}";
  # Go vendored deps for the go-html-to-md c-shared lib.
  goVendorHash = "${go_hash}";
  # html-transformer's Cargo.lock pulls nodesig from git (the only non-crates.io dep).
  nodesigHash = "${nodesig_hash}";
}
EOF
}

scrape() {
  # $1 = flake attr; echoes the "got: sha256-..." fixed-output hash from a deliberately-failing build.
  local attr="$1" out h
  out=$(nix build --option post-build-hook "" "${FLAKE_ROOT}#${attr}" --no-link 2>&1 || true)
  h=$(printf '%s\n' "${out}" | grep -oE 'got:[[:space:]]+sha256-[A-Za-z0-9+/=]+' | head -n1 | sed -E 's/.*(sha256-[A-Za-z0-9+/=]+).*/\1/')
  if [[ -z "${h}" ]]; then
    echo "error: could not scrape a hash for ${attr}" >&2
    printf '%s\n' "${out}" | tail -n 25 >&2
    exit 1
  fi
  printf '%s' "${h}"
}

write_pin
echo "Resolving nodesig git-crate hash..."
nodesig_hash=$(scrape htmlTransformer); write_pin
echo "  nodesigHash = ${nodesig_hash}"
echo "Resolving Go vendor hash..."
go_hash=$(scrape goHtmlToMd); write_pin
echo "  goVendorHash = ${go_hash}"
echo "Resolving pnpm deps hash..."
pnpm_hash=$(scrape firecrawl-api); write_pin
echo "  pnpmDepsHash = ${pnpm_hash}"
echo "Resolving playwright-service pnpm deps hash..."
playwright_hash=$(scrape firecrawl-playwright); write_pin
echo "  playwrightPnpmDepsHash = ${playwright_hash}"

if [[ "${cur_version}" == "${ver}" && "${cur_rev}" == "${rev}" && "${cur_src}" == "${src_hash}" \
   && "${cur_pnpm}" == "${pnpm_hash}" && "${cur_go}" == "${go_hash}" && "${cur_nodesig}" == "${nodesig_hash}" \
   && "${cur_playwright}" == "${playwright_hash}" ]]; then
  echo "Already up to date (${ver})."
fi

echo "Verifying full build..."
nix build --option post-build-hook "" "${FLAKE_ROOT}#firecrawl-api" "${FLAKE_ROOT}#firecrawl-playwright" --no-link

echo
echo "Pinned firecrawl ${ver} (${rev})."
echo "  Commit pin.nix / flake.lock to capture."
