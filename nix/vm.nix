# The VM interface and builder. Wraps a sandboxed agent in a qemu microVM
# built with microvm.nix.
#
# Launch from a project directory: the CWD is shared read-write at
# /workspace (9p with a relative source resolves against the runtime
# CWD of microvm-run), and a per-agent home image (<name>-vm-home.img)
# is created in the CWD on first run so agent logins persist. Host
# environment variables do not cross the VM boundary — log the agent
# in once inside the guest instead.
{
  lib,
  pkgs,
  system,
  microvm, # the microvm.nix flake input
  sandbox, # the imported nix/sandbox.nix set
}:
rec {
  # The VM interface, also defined as a module. `sandbox` embeds the
  # sandbox interface as a submodule, so one nested attrset configures
  # the agent that runs inside the guest.
  vmModule = agent: {
    options = {
      sandbox = lib.mkOption {
        type = lib.types.submodule (sandbox.sandboxModule agent);
        default = { };
        description = "Sandbox configuration for the agent inside the guest.";
      };
      vcpu = lib.mkOption {
        type = lib.types.ints.positive;
        default = 2;
        description = "Number of virtual CPU cores.";
      };
      mem = lib.mkOption {
        type = lib.types.ints.positive;
        default = 4096;
        description = "Guest RAM in MiB.";
      };
      workspace = lib.mkOption {
        type = lib.types.str;
        default = ".";
        description = "Host path shared at /workspace. A relative path resolves against the runtime working directory.";
      };
      homeImageSize = lib.mkOption {
        type = lib.types.ints.positive;
        default = 2048;
        description = "Size in MiB of the persistent /home image.";
      };
      extraModules = lib.mkOption {
        type = with lib.types; listOf deferredModule;
        default = [ ];
        description = "Extra NixOS modules merged into the guest.";
      };
    };
  };

  mkAgentVm =
    agent: config:
    let
      cfg =
        (lib.evalModules {
          modules = [
            (vmModule agent)
            config
          ];
        }).config;
    in
    (lib.nixosSystem {
      inherit system;
      modules = [
        microvm.nixosModules.microvm
        (import ./guest.nix {
          name = agent.binName;
          agentPackage = sandbox.buildSandbox agent cfg.sandbox;
          inherit cfg;
        })
      ]
      ++ cfg.extraModules;
    }).config.microvm.declaredRunner;

  # Every microvm runner exposes the same bin/microvm-run, so the
  # runners cannot share a dev shell PATH directly. Wrap each runner
  # in a launcher with a distinct name (claude-vm, opencode-vm, ...).
  mkVmLauncher =
    name: runner:
    pkgs.writeShellScriptBin "${name}-vm" ''
      exec ${runner}/bin/microvm-run "$@"
    '';
}
