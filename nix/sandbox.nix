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
    patches = [ ../patches/proxy-ports.patch ];
  };
  sbx = import sbxSrc { inherit pkgs; };

  # The user-facing sandbox interface, defined as a module so every
  # knob is a typed option with a default. An unknown or mistyped
  # attribute fails evaluation with the offending option path.
  # Semantics per option:
  #   - allowedDomains: replace wholesale, or `//`-merge onto the
  #     exported `agentDomains` default. The agent base domains are
  #     always merged on top.
  #   - extraPackages / extraR{w,o}{Dirs,Files}: lists appended
  #     onto the built-in defaults.
  #   - extraEnv: attrset `//`-merged onto the default env (later
  #     keys win, so it can also override defaults).
  sandboxModule = agent: {
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
        description = "Read/write files appended onto the defaults.";
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
      rwFiles = cfg.extraRwFiles;
      roDirs = cfg.extraRoDirs;
      roFiles = cfg.extraRoFiles;
      env = agent.env // cfg.extraEnv;
      allowedDomains = cfg.allowedDomains // agent.baseDomains;
    };

  evalSandbox =
    agent: config:
    (lib.evalModules {
      modules = [
        (sandboxModule agent)
        config
      ];
    }).config;

  mkAgentSandbox = agent: config: buildSandbox agent (evalSandbox agent config);
}
