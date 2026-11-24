# Upstream Antigravity CLI release binaries, so we can track antigravity-cli
# releases ahead of our nixpkgs pin. Bump ./manifest.json with ./update.sh,
# then rebuild.
#
# Deviation from nixpkgs: nixpkgs (pkgs/by-name/an/antigravity-cli) installs
# the storage.googleapis.com archives, whose URLs carry a build id next to
# the version, and whose hashes need a download. We install the GitHub
# release assets instead, because the release API reports their checksums.
# The binaries are the same build, so the packaging follows nixpkgs: install
# one file as bin/agy, and patch it for the host.
#
# The glibc assets are the ones we take. Upstream also publishes musl and
# windows assets. autoPatchelfHook covers the glibc binaries on NixOS.
{
  lib,
  stdenvNoCC,
  fetchurl,
  autoPatchelfHook,
  versionCheckHook,
  writableTmpDirAsHomeHook,
  # Release metadata for this package. Override it to track another
  # release without a copy of this file:
  #   pkgs.antigravity-cli.override { manifest = lib.importJSON ./other.json; }
  manifest ? lib.importJSON ./manifest.json,
}:
let
  stdenv = stdenvNoCC;
  platformKey = "${stdenv.hostPlatform.node.platform}-${stdenv.hostPlatform.node.arch}";
  platformManifestEntry =
    manifest.platforms.${platformKey}
      or (throw "antigravity-cli: manifest.json has no release asset for platform key \"${platformKey}\"");
in
stdenv.mkDerivation (finalAttrs: {
  pname = "antigravity-cli";
  inherit (manifest) version;

  src = fetchurl {
    url = "https://github.com/google-antigravity/antigravity-cli/releases/download/${finalAttrs.version}/${platformManifestEntry.asset}";
    sha256 = platformManifestEntry.checksum;
  };

  # The archive holds a single binary at its root.
  sourceRoot = ".";

  dontConfigure = true;
  dontBuild = true;

  nativeBuildInputs = lib.optionals stdenv.hostPlatform.isElf [ autoPatchelfHook ];

  strictDeps = true;

  # Upstream names the file `antigravity` in the storage.googleapis.com
  # archives, and names the command `agy`. The name inside the GitHub
  # asset is not documented, so take either one and install it as
  # bin/agy, at the root or one level below it. Another layout fails the
  # build with the archive listing.
  installPhase = ''
    runHook preInstall

    binary=""
    for candidate in agy antigravity */agy */antigravity; do
      if [ -f "$candidate" ]; then
        binary="$candidate"
        break
      fi
    done

    if [ -z "$binary" ]; then
      echo "antigravity-cli: the release archive holds no agy or antigravity binary:" >&2
      ls -la >&2
      exit 1
    fi

    install -Dm755 "$binary" $out/bin/agy

    runHook postInstall
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
    description = "Terminal interface to the Antigravity agent harness";
    homepage = "https://antigravity.google/product/antigravity-cli";
    changelog = "https://github.com/google-antigravity/antigravity-cli/releases/tag/${finalAttrs.version}";
    license = lib.licenses.unfree;
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
    platforms = [
      "aarch64-darwin"
      "aarch64-linux"
      "x86_64-darwin"
      "x86_64-linux"
    ];
    mainProgram = "agy";
  };
})
