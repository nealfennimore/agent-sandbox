# The sandbox interface and builders.
#
# agent-sandbox.nix builds its MITM proxy from its own source tree and
# exposes no override for it. The patch teaches that proxy to accept a
# port in an allowlist key ("host:port"). Upstream accepts port 443 for
# CONNECT and port 80 for plaintext only. See patches/proxy-ports.patch.
# The patched tree keeps the same interface, so `default.nix` gives the
# same `mkSandbox` and `commonTools` as `agent-sandbox.lib.${system}`.
{
  lib,
  pkgs,
  agent-sandbox,
  domains,
}:
rec {
  sbxSrc = pkgs.applyPatches {
    name = "agent-sandbox-patched";
    src = agent-sandbox;
    patches = [
      ../patches/proxy-ports.patch
      # Upstream (v3 through v5.6.3) refuses to launch when a declared env expression
      # references an unset variable. This patch downgrades that to a
      # warning: the variable is skipped and the agent falls back to its
      # own stored credentials. See patches/unresolved-env-warn.patch.
      ../patches/unresolved-env-warn.patch
    ];
  };
  sbx = import sbxSrc { inherit pkgs; };

  # One entry of publishedPorts in its long form. A bare port number is
  # also accepted; bindAddr defaults here instead.
  publishedPortModule = {
    options = {
      port = lib.mkOption {
        type = lib.types.ints.between 1 65535;
        description = "TCP port forwarded into the sandbox. The number is the same on both sides.";
      };
      bindAddr = lib.mkOption {
        type = lib.types.str;
        default = "127.0.0.1";
        description = "IPv4 address the forward listens on, outside the sandbox.";
      };
    };
  };

  # Reduce either entry form to the long form, so a caller that acts on
  # the port and the address reads one shape. nix/vm.nix uses this to
  # build the qemu forwards.
  normalizePublishedPort =
    entry:
    if builtins.isInt entry then
      {
        port = entry;
        bindAddr = "127.0.0.1";
      }
    else
      {
        inherit (entry) port bindAddr;
      };

  # The user-facing sandbox interface, defined as a module so every
  # knob is a typed option with a default. An unknown or mistyped
  # attribute fails evaluation with the offending option path.
  # Semantics per option:
  #   - allowedDomains: replace wholesale, or `//`-merge onto the
  #     exported `agentDomains` default. The agent base domains are
  #     always merged on top.
  #   - extraPackages / extraR{w,o}{Dirs,Files}: lists appended
  #     onto the built-in defaults.
  #   - allowNix / allowUnixSockets / allowHeadlessBrowsers /
  #     allowedHostPorts / publishedPorts: passed to agent-sandbox.nix
  #     unchanged. See its README for the semantics of each.
  #   - extraEnv: attrset `//`-merged onto the default env (later
  #     keys win, so it can also override defaults).
  sandboxModule = agent: {
    # `pkg` is an accepted alias for `package`. The alias applies to
    # every user of this module: the host sandboxes and the VM
    # `sandbox` submodule.
    imports = [ (lib.mkAliasOptionModule [ "pkg" ] [ "package" ]) ];
    options = {
      package = lib.mkOption {
        type = lib.types.package;
        default = agent.package;
        description = "Agent package to wrap.";
      };
      allowedDomains = lib.mkOption {
        type = with lib.types; attrsOf (either str (listOf str));
        default = domains.agentDomains;
        description = "Host-origin allowlist. \"*\" or a list of HTTP methods per key.";
      };
      allowNix = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Expose the host nix daemon socket and the whole nix store, and add pkgs.nix to PATH. Requires allowUnixSockets = true and a running nix-daemon. The microVM builders drop this option: the guest runs no nix daemon.";
      };
      allowUnixSockets = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Permit AF_UNIX sockets. The agent connects in directories it can read, and binds in directories it can write.";
      };
      allowHeadlessBrowsers = lib.mkOption {
        type = with lib.types; listOf (enum [ "chromium" "firefox" ]);
        default = [ ];
        description = "Headless browser engines the sandbox accommodates. On Linux this requires allowUnixSockets = true. Put the browser and its driver in extraPackages.";
      };
      allowedHostPorts = lib.mkOption {
        type = with lib.types; nullOr (listOf (ints.between 1 65535));
        default = [ ];
        description = "Host-local TCP ports the sandbox can reach. null allows every host-local TCP port. In the microVM these are the guest's own ports, not the host's.";
      };
      publishedPorts = lib.mkOption {
        type =
          with lib.types;
          listOf (either (ints.between 1 65535) (submodule publishedPortModule));
        default = [ ];
        description = "TCP ports forwarded into the sandbox, so a service the agent runs is reachable from outside. An entry is a port number, which binds 127.0.0.1, or { port, bindAddr }.";
      };
      extraPackages = lib.mkOption {
        type = with lib.types; listOf package;
        default = [ ];
        description = "Packages appended onto agent-sandbox commonTools.";
      };
      extraRwDirs = lib.mkOption {
        type = with lib.types; listOf str;
        default = [ ];
        description = "Read/write directories appended onto the defaults.";
      };
      extraRoDirs = lib.mkOption {
        type = with lib.types; listOf str;
        default = [ ];
        description = "Read-only directories appended onto the defaults.";
      };
      extraRwFiles = lib.mkOption {
        type = with lib.types; listOf str;
        default = [ ];
        description = "Read/write files appended onto the defaults. Read/write applies to the sandbox binds on a host. The microVM version has no read/write file support: the file is copied into the guest at boot, and guest writes are lost at shutdown.";
      };
      extraRoFiles = lib.mkOption {
        type = with lib.types; listOf str;
        default = [ ];
        description = "Read-only files appended onto the defaults.";
      };
      extraEnv = lib.mkOption {
        type = with lib.types; attrsOf str;
        default = { };
        description = "Environment merged onto the agent default env. Keys here win.";
      };
    };
  };

  # Build the wrapper from an agent descriptor and an evaluated
  # sandbox config (the submodule output, or evalSandbox below).
  buildSandbox =
    agent: cfg:
    sbx.mkSandbox {
      pkg = cfg.package;
      binName = agent.binName;
      outName = agent.binName;
      allowedPackages = sbx.commonTools ++ cfg.extraPackages;
      rwDirs = agent.rwDirs ++ cfg.extraRwDirs;
      rwFiles = (agent.rwFiles or [ ]) ++ cfg.extraRwFiles;
      roDirs = (agent.roDirs or [ ]) ++ cfg.extraRoDirs;
      roFiles = (agent.roFiles or [ ]) ++ cfg.extraRoFiles;
      env = agent.env // cfg.extraEnv;
      allowedDomains = cfg.allowedDomains // agent.baseDomains;
      inherit (cfg)
        allowNix
        allowUnixSockets
        allowHeadlessBrowsers
        allowedHostPorts
        publishedPorts
        ;
    };

  evalSandbox =
    agent: config:
    (lib.evalModules {
      modules = [
        (sandboxModule agent)
        config
      ];
    }).config;

  # The builder attaches `extend` and `sandboxConfig` to the wrapper, so
  # a downstream flake can add to a built sandbox without calling a
  # builder itself:
  #
  #   agentbox.packages.${system}.claude.extend {
  #     extraPackages = [ pkgs.cargo ];
  #     allowedDomains."crates.io" = "*";
  #   }
  #
  # `extend` evaluates everything again, with the extra module imported
  # next to the base module, so the module system does the merging:
  # lists concatenate and attrsets merge per key. The result carries
  # `extend` again, so the calls chain.
  #
  # The attributes live in `passthru`, which a later `overrideAttrs`
  # keeps. `buildSpec` travels with them: agent-sandbox.nix attaches it
  # with `//` after `runCommand`, and `overrideAttrs` rebuilds the
  # derivation from its own arguments, which drops it.
  mkAgentSandbox =
    agent: config:
    let
      drv = buildSandbox agent (evalSandbox agent config);
    in
    drv.overrideAttrs (prev: {
      passthru = (prev.passthru or { }) // {
        inherit (drv) buildSpec;
        sandboxConfig = config;
        extend = extra: mkAgentSandbox agent { imports = [ config extra ]; };
      };
    });
}
