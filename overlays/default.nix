# The nixpkgs overlay that holds the vendored agent packages.
#
# Each package tracks an upstream release through its own manifest.json,
# ahead of the nixpkgs pin in flake.lock. Bump a manifest with the
# update.sh next to it, then rebuild.
#
# The flake applies this overlay to its own nixpkgs, so nix/agents.nix
# gets the vendored packages. The flake also exports the overlay as
# `overlays.default`, so a downstream flake can apply it to its own
# nixpkgs:
#
#   pkgs = import nixpkgs {
#     inherit system;
#     config.allowUnfree = true;
#     overlays = [ agentbox.overlays.default ];
#   };
#
# To track a different release of one agent, override the manifest:
#
#   pkgs.claude-code.override { manifest = lib.importJSON ./claude-code.json; }
#
# To replace a package altogether, pass `package` to a sandbox builder
# or to `extend`. See "Agent packages" in README.md.
final: _prev: {
  claude-code = final.callPackage ./claude-code/package.nix { };
  opencode = final.callPackage ./opencode/package.nix { };
  codex = final.callPackage ./codex/package.nix { };
}
