# Upstream opencode release binaries, so we can track opencode releases ahead
# of our nixpkgs pin. Bump ./manifest.json with ./update.sh, then rebuild.
#
# Deviation from nixpkgs: nixpkgs (pkgs/by-name/op/opencode) builds from
# source with bun and a node_modules fixed-output derivation. Each bump there
# needs nix to recompute that hash, and the build reads models-dev from our
# nixpkgs pin. The release binary is the same bun --compile output, so we
# install it the way overlays/claude-code installs its bun binary. The wrapper
# matches nixpkgs: ripgrep on PATH and no self-update.
#
# The binary embeds its own models.dev snapshot. Unlike the nixpkgs build, it
# also refreshes that list from models.dev at run time.
# modules/linux/nixos/packages/opencode.nix sets OPENCODE_DISABLE_MODELS_FETCH
# in the sandbox to stop that.
{
  lib,
  stdenvNoCC,
  fetchurl,
  unzip,
  makeBinaryWrapper,
  autoPatchelfHook,
  installShellFiles,
  ripgrep,
  sysctl,
  versionCheckHook,
  writableTmpDirAsHomeHook,
}:
let
  stdenv = stdenvNoCC;
  manifest = lib.importJSON ./manifest.json;
  platformKey = "${stdenv.hostPlatform.node.platform}-${stdenv.hostPlatform.node.arch}";
  platformManifestEntry = manifest.platforms.${platformKey};
in
stdenv.mkDerivation (finalAttrs: {
  pname = "opencode";
  inherit (manifest) version;

  src = fetchurl {
    url = "https://github.com/anomalyco/opencode/releases/download/v${finalAttrs.version}/${platformManifestEntry.asset}";
    sha256 = platformManifestEntry.checksum;
  };

  # The archive holds a single opencode binary at its root.
  sourceRoot = ".";

  dontConfigure = true;
  dontBuild = true;
  # otherwise the bun runtime is executed instead of the binary
  dontStrip = true;

  nativeBuildInputs = [
    installShellFiles
    makeBinaryWrapper
    writableTmpDirAsHomeHook
  ]
  ++ lib.optionals stdenv.hostPlatform.isDarwin [ unzip ]
  ++ lib.optionals stdenv.hostPlatform.isElf [ autoPatchelfHook ];

  strictDeps = true;

  installPhase = ''
    runHook preInstall

    installBin opencode
    wrapProgram $out/bin/opencode \
      --prefix PATH : ${
        lib.makeBinPath (
          [ ripgrep ] ++ lib.optionals stdenv.hostPlatform.isDarwin [ sysctl ]
        )
      } \
      --set OPENCODE_DISABLE_AUTOUPDATE true

    runHook postInstall
  '';

  # autoPatchelfHook runs in fixupPhase, after this. Patch now so the binary
  # can run here. Otherwise <(...) swallows the exec failure and
  # installShellCompletion gets an empty file.
  # $TMPDIR and $HOME are /build, which holds the unpacked ./opencode file.
  # opencode mkdirs <tmp or home>/opencode at startup, so give it empty dirs.
  postInstall = lib.optionalString (stdenv.buildPlatform.canExecute stdenv.hostPlatform) ''
    ${lib.optionalString stdenv.hostPlatform.isElf "autoPatchelf $out"}
    export HOME=$(mktemp -d) TMPDIR=$(mktemp -d)
    installShellCompletion --cmd opencode \
      --bash <($out/bin/opencode completion) \
      --zsh <(SHELL=/bin/zsh $out/bin/opencode completion)
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
    description = "AI coding agent built for the terminal";
    homepage = "https://github.com/anomalyco/opencode";
    changelog = "https://github.com/anomalyco/opencode/releases/tag/v${finalAttrs.version}";
    license = lib.licenses.mit;
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
    platforms = [
      "aarch64-darwin"
      "aarch64-linux"
      "x86_64-linux"
    ];
    mainProgram = "opencode";
  };
})
