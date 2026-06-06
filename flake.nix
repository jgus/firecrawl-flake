{
  description = "Firecrawl self-hosted web scraper (firecrawl/firecrawl, apps/api). Polyglot build — Node/pnpm app + 3 Rust cdylibs + 1 Go c-shared lib dlopen'd via koffi at runtime.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pin = import ./pin.nix;
        inherit (pin) version sourceRev sourceHash;
        pkgs = import nixpkgs { inherit system; };
        inherit (pkgs) lib;

        src = pkgs.fetchFromGitHub {
          owner = "firecrawl";
          repo = "firecrawl";
          rev = sourceRev;
          hash = sourceHash;
        };
        apiSrc = src + "/apps/api";

        # Each sharedLibs/<dir> is a standalone crate with its own Cargo.lock → hashless importCargoLock, except html-transformer which pulls `nodesig` from git (needs an outputHash).
        mkRustLib = { dir, soName, outputHashes ? { } }:
          pkgs.rustPlatform.buildRustPackage {
            pname = "firecrawl-${dir}";
            inherit version;
            src = src + "/apps/api/sharedLibs/${dir}";
            cargoLock = {
              lockFile = src + "/apps/api/sharedLibs/${dir}/Cargo.lock";
              inherit outputHashes;
            };
            doCheck = false;
            # cdylib (no bins): replace the default cargo-install with a copy of the .so.
            installPhase = ''
              runHook preInstall
              install -Dm755 "target/${pkgs.stdenv.hostPlatform.rust.rustcTarget}/release/${soName}" "$out/lib/${soName}" 2>/dev/null \
                || install -Dm755 "target/release/${soName}" "$out/lib/${soName}"
              runHook postInstall
            '';
          };

        htmlTransformer = mkRustLib {
          dir = "html-transformer";
          soName = "libhtml_transformer.so";
          outputHashes = { "nodesig-1.0.0" = pin.nodesigHash; };
        };
        pdfParser = mkRustLib { dir = "pdf-parser"; soName = "libpdf_parser.so"; };
        crawler = mkRustLib { dir = "crawler"; soName = "libcrawler.so"; };

        goHtmlToMd = pkgs.buildGoModule {
          pname = "firecrawl-go-html-to-md";
          inherit version;
          src = src + "/apps/api/sharedLibs/go-html-to-md";
          vendorHash = pin.goVendorHash;
          env.CGO_ENABLED = "1";
          buildPhase = ''
            runHook preBuild
            go build -buildmode=c-shared -o html-to-markdown.so html-to-markdown.go
            runHook postBuild
          '';
          installPhase = ''
            runHook preInstall
            install -Dm755 html-to-markdown.so "$out/lib/html-to-markdown.so"
            runHook postInstall
          '';
          doCheck = false;
        };

        # Pin pnpm 9 into the top-level hook/fetcher (their default is the latest pnpm).
        pnpmConfigHook = pkgs.pnpmConfigHook.overrideAttrs (prev: {
          propagatedBuildInputs = (prev.propagatedBuildInputs or [ ]) ++ [ pkgs.pnpm_9 ];
        });
        fetchPnpmDeps = args: pkgs.fetchPnpmDeps (args // { pnpm = pkgs.pnpm_9; });

        firecrawl-api = pkgs.stdenv.mkDerivation (finalAttrs: {
          pname = "firecrawl-api";
          inherit version;
          src = apiSrc;

          nativeBuildInputs = [
            pkgs.nodejs_22
            pnpmConfigHook
            pkgs.python3 # node-gyp fallback for any non-prebuilt native dep
            pkgs.makeWrapper
            pkgs.patchelfUnstable # 0.18: --clear-execstack (stable patchelf 0.15 lacks it)
          ];

          pnpmDeps = fetchPnpmDeps {
            inherit (finalAttrs) pname version src;
            fetcherVersion = 3;
            hash = pin.pnpmDepsHash;
          };

          buildPhase = ''
            runHook preBuild
            pnpm run build
            runHook postBuild
          '';

          # Native libs are dlopen'd via koffi from process.cwd()-relative paths, so the app must run with cwd = the assembled root that holds both dist/ and sharedLibs/<lib>/.../*.so.
          installPhase = ''
            runHook preInstall
            app="$out/share/firecrawl-api"
            mkdir -p "$app" "$out/bin"
            cp -r dist package.json node_modules "$app/"

            # koffi ships a prebuilt .node marked with an executable stack (which NixOS rejects) and with no rpath for libstdc++. Clear the exec-stack flag and point it at gcc's libs so it dlopen's.
            find "$app/node_modules" -path '*/koffi/build/koffi/linux_x64/koffi.node' -exec \
              patchelf --clear-execstack --set-rpath ${lib.makeLibraryPath [ pkgs.stdenv.cc.cc.lib ]} {} +

            install -Dm755 ${htmlTransformer}/lib/libhtml_transformer.so "$app/sharedLibs/html-transformer/target/release/libhtml_transformer.so"
            install -Dm755 ${pdfParser}/lib/libpdf_parser.so "$app/sharedLibs/pdf-parser/target/release/libpdf_parser.so"
            install -Dm755 ${crawler}/lib/libcrawler.so "$app/sharedLibs/crawler/target/release/libcrawler.so"
            install -Dm755 ${goHtmlToMd}/lib/html-to-markdown.so "$app/sharedLibs/go-html-to-md/html-to-markdown.so"

            makeWrapper ${pkgs.nodejs_22}/bin/node "$out/bin/firecrawl-api" \
              --add-flags "--max-old-space-size=8192" \
              --add-flags "$app/dist/src/index.js" \
              --chdir "$app" \
              --prefix PATH : ${lib.makeBinPath [ pkgs.git ]} \
              --prefix LD_LIBRARY_PATH : ${lib.makeLibraryPath [ pkgs.stdenv.cc.cc.lib ]}

            makeWrapper ${pkgs.nodejs_22}/bin/node "$out/bin/firecrawl-worker" \
              --add-flags "$app/dist/src/services/queue-worker.js" \
              --chdir "$app" \
              --prefix PATH : ${lib.makeBinPath [ pkgs.git ]} \
              --prefix LD_LIBRARY_PATH : ${lib.makeLibraryPath [ pkgs.stdenv.cc.cc.lib ]}

            makeWrapper ${pkgs.nodejs_22}/bin/node "$out/bin/firecrawl-index-worker" \
              --add-flags "$app/dist/src/services/indexing/index-worker.js" \
              --chdir "$app" \
              --prefix PATH : ${lib.makeBinPath [ pkgs.git ]} \
              --prefix LD_LIBRARY_PATH : ${lib.makeLibraryPath [ pkgs.stdenv.cc.cc.lib ]}

            runHook postInstall
          '';

          dontStrip = true; # node_modules ships prebuilt JS + native .node
          meta.mainProgram = "firecrawl-api";
        });

        # Headless-Chromium scraper sidecar (apps/playwright-service-ts) for JS-heavy pages. The npm `playwright` (1.45) doesn't match nixpkgs' playwright-driver (1.59), so rather than reconcile the bundled-browser revision we drive nixpkgs' chromium directly via executablePath.
        firecrawl-playwright = pkgs.stdenv.mkDerivation (finalAttrs: {
          pname = "firecrawl-playwright";
          inherit version;
          src = src + "/apps/playwright-service-ts";

          nativeBuildInputs = [
            pkgs.nodejs_22
            pnpmConfigHook
            pkgs.makeWrapper
          ];

          # playwright's postinstall would fetch its own Chromium build; we don't use it.
          env.PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD = "1";

          pnpmDeps = fetchPnpmDeps {
            inherit (finalAttrs) pname version src;
            fetcherVersion = 3;
            hash = pin.playwrightPnpmDepsHash;
          };

          # Launch nixpkgs' chromium (CHROMIUM_EXECUTABLE_PATH) instead of playwright's bundled browser. Also drop --single-process/--no-zygote: web search scrapes ~5 URLs at once, and single-process chromium serializes them and times out (4/5 fail). Multi-process lets concurrent page loads actually run.
          postPatch = ''
            substituteInPlace api.ts \
              --replace-fail 'headless: true,' 'headless: true, executablePath: process.env.CHROMIUM_EXECUTABLE_PATH,' \
              --replace-fail "'--single-process'," "" \
              --replace-fail "'--no-zygote'," ""
          '';

          buildPhase = ''
            runHook preBuild
            pnpm run build
            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall
            app="$out/share/firecrawl-playwright"
            mkdir -p "$app" "$out/bin"
            cp -r dist node_modules package.json "$app/"
            makeWrapper ${pkgs.nodejs_22}/bin/node "$out/bin/firecrawl-playwright" \
              --add-flags "$app/dist/api.js" \
              --chdir "$app" \
              --set-default CHROMIUM_EXECUTABLE_PATH "${lib.getExe pkgs.chromium}"
            runHook postInstall
          '';

          dontStrip = true;
          meta.mainProgram = "firecrawl-playwright";
        });

        # Bespoke (not flake-lib's mkUpdateVersion): defaults to re-validating the current pin rather than the latest release (v2.5+/v3 changed the queue/build), and resolves four vendored hashes (nodesig git-crate, Go vendor, two pnpm mirrors) in dependency order across separate build attrs, which flake-lib's single-sourceHash path can't do.
        update-version = pkgs.writeShellApplication {
          name = "update-version";
          text = ''exec ${./update-version.sh} "$@"'';
        };
      in
      {
        packages = {
          inherit firecrawl-api firecrawl-playwright update-version;
          inherit htmlTransformer pdfParser crawler goHtmlToMd; # exposed for debugging individual builds
          default = firecrawl-api;
        };
      });
}
