# The VM interface and builder. Wraps a sandboxed agent in a qemu microVM
# built with microvm.nix.
#
# Launch from a project directory: the CWD is shared read-write at
# /workspace (9p with a relative source resolves against the runtime
# CWD of microvm-run). Host environment variables do not cross the VM
# boundary; login state travels through the shared sandbox directories.
#
# Every directory and file the sandbox declares (agent defaults plus
# extra*) is also shared from the host into the guest, so the sandbox
# inside the guest sees the same data as a sandbox on the host.
#
# Sandbox publishedPorts become qemu host-to-guest forwards as well.
# The guest publishes each port on 0.0.0.0 and qemu forwards it to the
# host address in bindAddr.
{
  lib,
  pkgs,
  system,
  microvm, # the microvm.nix flake input
  sandbox, # the imported nix/sandbox.nix set
}:
rec {
  # The guest agent runs as root. With an unprivileged qemu, 9p presents
  # the qemu owner's files as root inside the guest, and a non-root
  # guest user fails the client-side permission checks on them. Guest
  # root is the natural peer of the host user: its writes execute
  # host-side as the user that launched the VM, so host files keep
  # their ownership. The VM boundary and the in-guest sandbox still
  # confine the agent.
  guestUser = "root";
  guestHome = "/root";

  # Translate a sandbox path declaration to its guest location. The
  # sandbox launcher expands $HOME at runtime; inside the guest that
  # is the agent user's home.
  translatePath =
    p:
    if lib.hasPrefix "$HOME/" p then
      "${guestHome}/${lib.removePrefix "$HOME/" p}"
    else if lib.hasPrefix "/" p && !lib.hasInfix "$" p then
      p
    else
      throw "agent-sandbox VM: cannot mount \"${p}\". Only absolute paths and $HOME-prefixed paths are supported.";

  # Compute the host shares that bubble a sandbox config up to the VM.
  # The share sources must be known at build time, so the agent defaults
  # and the extra* lists are collected here:
  #   - directories mount at their translated guest path, read-only for
  #     the ro sets;
  #   - files cannot be shared over 9p individually. The parent
  #     directory is staged read-only under /run/agent-sandbox and the
  #     file is copied into place at boot. The VM version therefore has
  #     no read/write files: an rwFiles entry degrades to a read-only
  #     snapshot, and guest writes to it are lost at shutdown.
  sandboxShares =
    agent: sandboxCfg:
    let
      entries =
        map (p: {
          kind = "dir";
          path = p;
          readOnly = false;
        }) (agent.rwDirs ++ sandboxCfg.extraRwDirs)
        ++ map (p: {
          kind = "dir";
          path = p;
          readOnly = true;
        }) ((agent.roDirs or [ ]) ++ sandboxCfg.extraRoDirs)
        ++ map (p: {
          kind = "file";
          path = p;
        }) ((agent.rwFiles or [ ]) ++ sandboxCfg.extraRwFiles)
        ++ map (p: {
          kind = "file";
          path = p;
        }) ((agent.roFiles or [ ]) ++ sandboxCfg.extraRoFiles);
    in
    lib.imap0 (
      i: entry:
      let
        tag = "sbx${toString i}";
      in
      if entry.kind == "dir" then
        {
          inherit tag;
          inherit (entry) readOnly;
          hostPath = entry.path;
          guestPath = translatePath entry.path;
          copyTo = null;
          fileName = null;
        }
      else
        {
          inherit tag;
          readOnly = true;
          hostPath = dirOf entry.path;
          guestPath = "/run/agent-sandbox/${tag}";
          copyTo = translatePath entry.path;
          fileName = baseNameOf entry.path;
        }
    ) entries;

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
      extraModules = lib.mkOption {
        type = with lib.types; listOf deferredModule;
        default = [ ];
        description = "Extra NixOS modules merged into the guest.";
      };
    };
  };

  # Translate the sandbox publishedPorts into the attrset form the VM
  # needs, and into the address the guest must bind.
  #
  # qemu forwards a host connection to the guest address on the SLiRP
  # link, never to guest 127.0.0.1, so a sandbox that published on the
  # default 127.0.0.1 inside the guest would stay unreachable. Inside
  # the guest the sandbox therefore publishes on 0.0.0.0, and bindAddr
  # becomes the host address that qemu listens on. The service the
  # agent runs inside the sandbox must also listen on 0.0.0.0: pasta
  # delivers a non-local peer with its real source address.
  guestPublishedPorts = map (p: {
    inherit (p) port;
    bindAddr = "0.0.0.0";
  });

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
      rwFiles = (agent.rwFiles or [ ]) ++ cfg.sandbox.extraRwFiles;
      publishedPorts = map sandbox.normalizePublishedPort cfg.sandbox.publishedPorts;
      # allowNix is dropped rather than passed down. The guest runs no
      # nix daemon, so the launcher inside the guest would refuse to
      # start and the kiosk VM would power off at once. Dropping it
      # degrades the VM the way an rwFiles entry degrades: the
      # warning below names what the VM did not honor.
      guestSandboxCfg = cfg.sandbox // {
        allowNix = false;
        publishedPorts = guestPublishedPorts publishedPorts;
      };
      # Configurations the VM cannot honor. Each one degrades to a
      # runtime symptom, so name it at evaluation time instead.
      warnings =
        lib.optional (rwFiles != [ ])
          "agent-sandbox VM (${agent.binName}): the VM version has no read/write files. Declared rwFiles (${lib.concatStringsSep ", " rwFiles}) become read-only snapshots, and guest writes to them are lost at shutdown."
        ++ lib.optional cfg.sandbox.allowNix "agent-sandbox VM (${agent.binName}): the VM version has no nix support. allowNix is dropped for the guest sandbox: the guest nix store is a read-only share from the host and the guest runs no nix daemon. Use the host sandbox for nix work.";
      runner =
        (lib.nixosSystem {
          inherit system;
          modules = [
            microvm.nixosModules.microvm
            (import ./guest.nix {
              name = agent.binName;
              agentPackage = sandbox.buildSandbox agent guestSandboxCfg;
              sandboxShares = sandboxShares agent cfg.sandbox;
              inherit cfg guestUser publishedPorts;
            })
          ]
          ++ cfg.extraModules;
        }).config.microvm.declaredRunner;
    in
    lib.foldl' (value: message: lib.warn message value) runner warnings;

  # Every microvm runner exposes the same bin/microvm-run, so the
  # runners cannot share a dev shell PATH directly. Wrap each runner
  # in a launcher with a distinct name (claude-vm, opencode-vm, ...).
  mkVmLauncher =
    name: runner:
    pkgs.writeShellScriptBin "${name}" ''
      exec ${runner}/bin/microvm-run "$@"
    '';
}
