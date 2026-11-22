# Upstream codex release packages, so we can track codex releases ahead of
# our nixpkgs pin. Bump ./manifest.json with ./update.sh, then rebuild.
#
# Deviation from nixpkgs: nixpkgs (pkgs/by-name/co/codex) builds from source
# with cargo and a prebuilt librusty_v8, and each bump there needs new hashes.
# We install the codex-package-<target> release archive instead. The Linux
# binaries are static musl builds and run on NixOS without patching.
#
# codex refuses to start ("this CLI has no complete local package") unless it
# runs from a complete package tree: codex-package.json, bin/codex,
# bin/codex-code-mode-host, codex-path/rg and, on Linux,
# codex-resources/bwrap. So $out is that tree as it ships. Do not wrap
# bin/codex: the app-server daemon compares the staged executable with the
# running one, and a wrapper fails that check (see the nixpkgs recipe).
{
  lib,
  stdenvNoCC,
  fetchurl,
  installShellFiles,
  versionCheckHook,
  writableTmpDirAsHomeHook,
  # Release metadata for this package. Override it to track another
  # release without a copy of this file:
  #   pkgs.codex.override { manifest = lib.importJSON ./other.json; }
  manifest ? lib.importJSON ./manifest.json,
}:
let
  stdenv = stdenvNoCC;
  platformKey =
    stdenv.hostPlatform.parsed.cpu.name
    + (if stdenv.hostPlatform.isDarwin then "-apple-darwin" else "-unknown-linux-musl");
  platformManifestEntry =
    manifest.platforms.${platformKey}
      or (throw "codex: manifest.json has no release asset for platform key \"${platformKey}\"");
in
stdenv.mkDerivation (finalAttrs: {
  pname = "codex";
  inherit (manifest) version;

  src = fetchurl {
    url = "https://github.com/openai/codex/releases/download/rust-v${finalAttrs.version}/${platformManifestEntry.asset}";
    sha256 = platformManifestEntry.checksum;
  };

  # The archive holds the package tree at its root.
  sourceRoot = ".";

  dontConfigure = true;
  dontBuild = true;
  dontStrip = true;
  dontPatchELF = true;

  nativeBuildInputs = [ installShellFiles ];

  strictDeps = true;

  installPhase = ''
    runHook preInstall

    mkdir -p $out
    cp -a . $out/
    rm -f $out/env-vars
    # The upstream installer adds this entrypoint link to each release.
    ln -sf bin/codex $out/codex

    runHook postInstall
  '';

  postInstall = lib.optionalString (stdenv.buildPlatform.canExecute stdenv.hostPlatform) ''
    export HOME=$(mktemp -d)
    installShellCompletion --cmd codex \
      --bash <($out/bin/codex completion bash) \
      --fish <($out/bin/codex completion fish) \
      --zsh <($out/bin/codex completion zsh)
  '';

  doInstallCheck = true;
  nativeInstallCheckInputs = [
    writableTmpDirAsHomeHook
    versionCheckHook
  ];
  versionCheckKeepEnvironment = [ "HOME" ];
  versionCheckProgramArg = "--version";

  passthru.updateScript = ./update.sh;

  meta = {
    description = "Lightweight coding agent that runs in your terminal";
    homepage = "https://github.com/openai/codex";
    changelog = "https://github.com/openai/codex/releases/tag/rust-v${finalAttrs.version}";
    license = lib.licenses.asl20;
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
    platforms = [
      "aarch64-darwin"
      "aarch64-linux"
      "x86_64-darwin"
      "x86_64-linux"
    ];
    mainProgram = "codex";
  };
})
