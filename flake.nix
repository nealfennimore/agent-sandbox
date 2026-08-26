{
  # Test flake: sandbox Claude Code, OpenCode, and Codex with agent-sandbox.nix.
  # Network egress is restricted to an explicit per-domain / per-method
  # allowlist, enforced by a private netns (pasta) + nftables + a MITM
  # filtering proxy. Everything not in `allowedDomains` is dropped.
  #
  # Layout:
  #   nix/domains.nix — domain allowlists
  #   nix/agents.nix  — per-agent descriptors (package, dirs, env, domains)
  #   nix/sandbox.nix — sandbox interface (module) and builders
  #   nix/vm.nix      — microVM interface (module) and builder
  #   nix/guest.nix   — NixOS configuration for the VM guest
  #
  # Build & enter:   nix develop .#claude
  # Then run:        claude
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    agent-sandbox.url = "github:archie-judd/agent-sandbox.nix";

    # Reuse the same agent source as the original flake for opencode.
    llm-agents.url = "github:numtide/llm-agents.nix";
    flake-utils.url = "github:numtide/flake-utils";

    # MicroVM variants: run a sandboxed agent inside a qemu microVM.
    # The submodule at modules/microvm is a local reference copy only.
    # The flake consumes this input.
    microvm.url = "github:microvm-nix/microvm.nix";
    microvm.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      nixpkgs,
      agent-sandbox,
      llm-agents,
      flake-utils,
      microvm,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = true;
        };
        lib = nixpkgs.lib;

        domains = import ./nix/domains.nix;
        agents = import ./nix/agents.nix { inherit pkgs domains; };
        sandbox = import ./nix/sandbox.nix {
          inherit
            lib
            pkgs
            agent-sandbox
            domains
            ;
        };
        vm = import ./nix/vm.nix {
          inherit
            lib
            pkgs
            system
            microvm
            sandbox
            ;
        };

        inherit (sandbox) mkAgentSandbox;
        inherit (vm) mkAgentVm mkVmLauncher;

        mkClaudeSandbox = mkAgentSandbox agents.claude;
        mkOpencodeSandbox = mkAgentSandbox agents.opencode;
        mkCodexSandbox = mkAgentSandbox agents.codex;

        claude-sandboxed = mkClaudeSandbox { };
        opencode-sandboxed = mkOpencodeSandbox { };
        codex-sandboxed = mkCodexSandbox { };

        # MicroVM outputs only make sense for Linux guests.
        isLinux = lib.hasSuffix "-linux" system;

        mkClaudeVm = mkAgentVm agents.claude;
        mkOpencodeVm = mkAgentVm agents.opencode;
        mkCodexVm = mkAgentVm agents.codex;

        claude-vm = mkClaudeVm { };
        opencode-vm = mkOpencodeVm { };
        codex-vm = mkCodexVm { };

        claude-vm-launcher = mkVmLauncher "claude" claude-vm;
        opencode-vm-launcher = mkVmLauncher "opencode" opencode-vm;
        codex-vm-launcher = mkVmLauncher "codex" codex-vm;

        onLinux = lib.optionals isLinux;
      in
      {
        lib = {
          inherit (domains) agentDomains;
          inherit
            mkAgentSandbox
            mkClaudeSandbox
            mkOpencodeSandbox
            mkCodexSandbox
            ;
        }
        // lib.optionalAttrs isLinux {
          inherit
            mkAgentVm
            mkClaudeVm
            mkOpencodeVm
            mkCodexVm
            ;
        };

        devShells = {
          claude = pkgs.mkShell {
            packages = [ claude-sandboxed ] ++ onLinux [ claude-vm-launcher ];
          };
          opencode = pkgs.mkShell {
            packages = [ opencode-sandboxed ] ++ onLinux [ opencode-vm-launcher ];
          };
          codex = pkgs.mkShell {
            packages = [ codex-sandboxed ] ++ onLinux [ codex-vm-launcher ];
          };
          default = pkgs.mkShell {
            packages = [
              claude-sandboxed
              opencode-sandboxed
              codex-sandboxed
            ]
            ++ onLinux [
              claude-vm-launcher
              opencode-vm-launcher
              codex-vm-launcher
            ];
          };
        };

        packages = {
          claude = claude-sandboxed;
          opencode = opencode-sandboxed;
          codex = codex-sandboxed;
        }
        // lib.optionalAttrs isLinux {
          inherit claude-vm opencode-vm codex-vm;
        };
      }
    );
}
