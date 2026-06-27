{
  # Test flake: sandbox Claude Code (and OpenCode) with agent-sandbox.nix.
  # Network egress is restricted to an explicit per-domain / per-method
  # allowlist, enforced by a private netns (pasta) + nftables + a MITM
  # filtering proxy. Everything not in `allowedDomains` is dropped.
  #
  # Build & enter:   nix develop ./test-flake.nix#claude
  #   (or rename to flake.nix and `nix develop .#claude`)
  # Then run:        claude-sandboxed
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    agent-sandbox.url = "github:archie-judd/agent-sandbox.nix";

    # Reuse the same agent source as the original flake for opencode.
    llm-agents.url = "github:numtide/llm-agents.nix";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      nixpkgs,
      agent-sandbox,
      llm-agents,
      flake-utils,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = true;
        };
        sbx = agent-sandbox.lib.${system};

        # Domains the agent is allowed to reach. "*" = all HTTP methods;
        # a list restricts to those methods (read-only access to GitHub here).
        agentDomains = {
          "anthropic.com" = "*";
          "claude.com" = "*";
          "raw.githubusercontent.com" = [
            "GET"
            "HEAD"
          ];
          "api.github.com" = [
            "GET"
            "HEAD"
          ];
          "github.com" = [
            "GET"
            "HEAD"
          ];
        };

        claude-sandboxed = sbx.mkSandbox {
          pkg = pkgs.claude-code;
          binName = "claude";
          outName = "claude-sandboxed";
          allowedPackages = sbx.commonTools;
          rwDirs = [ "$HOME/.claude" ];
          rwFiles = [ ];
          # Bind host gitconfig read-only for git identity (optional):
          # roFiles = [ "$HOME/.config/git/config" ];
          env = {
            # Secrets are passed as runtime shell-var references so they
            # expand in the shell, never landing in the /nix/store.
            CLAUDE_CODE_OAUTH_TOKEN = "$CLAUDE_CODE_OAUTH_TOKEN";
            GITHUB_TOKEN = "$GITHUB_TOKEN";
            CLAUDE_CONFIG_DIR = "$HOME/.claude";
          };
          allowedDomains = agentDomains;
        };

        opencode-sandboxed = sbx.mkSandbox {
          pkg = llm-agents.packages.${system}.opencode;
          binName = "opencode";
          outName = "opencode-sandboxed";
          allowedPackages = sbx.commonTools;
          rwDirs = [
            "$HOME/.config/opencode"
            "$HOME/.local/share/opencode"
            "$HOME/.local/state/opencode"
          ];
          rwFiles = [ ];
          env = {
            # Add whatever provider key opencode is configured to use, e.g.:
            # ANTHROPIC_API_KEY = "$ANTHROPIC_API_KEY";
          };
          allowedDomains = agentDomains;
        };
      in
      {
        devShells = {
          claude = pkgs.mkShell { packages = [ claude-sandboxed ]; };
          opencode = pkgs.mkShell { packages = [ opencode-sandboxed ]; };
          default = pkgs.mkShell {
            packages = [
              claude-sandboxed
              opencode-sandboxed
            ];
            shellHook = ''
              export CLAUDE_CODE_OAUTH_TOKEN="$(op read 'op://Private/Claude OAUTH/credential')"
            '';
          };
        };

        packages = {
          claude = claude-sandboxed;
          opencode = opencode-sandboxed;
        };
      }
    );
}
