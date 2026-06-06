# Auto-managed by `nix run .#update-version`. Manual edits will be overwritten by the next bump.
{
  version = "1.15.0";
  sourceRev = "21a5c8a9ebccf0dbf6e94e9c7fd8f06edfa6d22f";
  sourceHash = "sha256-GIde8FiU1/gS3oFfTf7f7Tc4KvDVL873VE5kjyh33Is=";
  # pnpm offline-deps mirror built from apps/api/pnpm-lock.yaml at sourceRev.
  pnpmDepsHash = "sha256-FGD11o3neBf/dHskbNpmyf+revAMX51WwS3C55qwUK0=";
  # pnpm offline-deps for apps/playwright-service-ts.
  playwrightPnpmDepsHash = "sha256-sB5by74Xc3yw74a57VlVpgzoma/26afV3zERa0+09xk=";
  # Go vendored deps for the go-html-to-md c-shared lib.
  goVendorHash = "sha256-NIY+QpMO3OHll5eob/wre77Y1d+op46pC9VEaVyPQDo=";
  # html-transformer's Cargo.lock pulls nodesig from git (the only non-crates.io dep).
  nodesigHash = "sha256-5n3SSEVqtRU5IyISk82jrQ9R1vRZFeBjfhP/GPL+5G4=";
}
