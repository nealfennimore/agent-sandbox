# Agent descriptors: everything that differs between the agents, in one
# place. The public builders are partial applications over these
# descriptors, so a downstream flake can add a new agent by calling
# mkAgentSandbox / mkAgentVm with its own descriptor.
{ pkgs, domains }:
{
  claude = {
    binName = "claude";
    package = pkgs.claude-code;
    baseDomains = domains.baseDomains;
    rwDirs = [ "$HOME/.claude" ];
    # Bind host gitconfig read-only for git identity (optional):
    # roFiles = [ "$HOME/.config/git/config" ];
    env = {
      # Secrets are passed as runtime shell-var references so they
      # expand in the shell, never landing in the /nix/store.
      CLAUDE_CODE_OAUTH_TOKEN = "$CLAUDE_CODE_OAUTH_TOKEN";
      GITHUB_TOKEN = "$GITHUB_TOKEN";
      CLAUDE_CONFIG_DIR = "$HOME/.claude";
    };
  };

  opencode = {
    binName = "opencode";
    package = pkgs.opencode;
    baseDomains = domains.baseDomains;
    rwDirs = [
      "$HOME/.config/opencode"
      "$HOME/.local/share/opencode"
      "$HOME/.local/state/opencode"
    ];
    # Add whatever provider key opencode is configured to use via
    # extraEnv, e.g. ANTHROPIC_API_KEY = "$ANTHROPIC_API_KEY";
    env = { };
  };

  codex = {
    binName = "codex";
    package = pkgs.codex;
    baseDomains = domains.codexBaseDomains;
    rwDirs = [ "$HOME/.codex" ];
    env = {
      # Secrets are passed as runtime shell-var references so they
      # expand in the shell, never landing in the /nix/store.
      OPENAI_API_KEY = "$OPENAI_API_KEY";
      GITHUB_TOKEN = "$GITHUB_TOKEN";
      CODEX_HOME = "$HOME/.codex";
    };
  };
}
