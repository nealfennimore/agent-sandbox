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
    # extraEnv, for example ANTHROPIC_API_KEY = "$ANTHROPIC_API_KEY";
    env = {
      # The release binary refreshes its model list from models.dev at
      # startup. That domain is not in the allowlist, so stop the fetch.
      OPENCODE_DISABLE_MODELS_FETCH = "true";
    };
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

  # Antigravity CLI. The binary is `agy`, and the package is vendored in
  # overlays/antigravity-cli. See "Agent packages" in README.md.
  antigravity = {
    binName = "agy";
    package = pkgs.antigravity-cli;
    baseDomains = domains.antigravityBaseDomains;
    # Settings, conversations and the file-based credential store live
    # under $HOME/.gemini. The client prefers the system keyring. The
    # sandbox exposes no D-Bus session, so the client falls back to its
    # own file storage in this directory.
    rwDirs = [ "$HOME/.gemini" ];
    # The client also reads cross-tool Agent Skills from
    # $HOME/.agents/skills (optional):
    # roDirs = [ "$HOME/.agents/skills" ];
    env = {
      # Secrets are passed as runtime shell-var references so they
      # expand in the shell, never landing in the /nix/store. A sign-in
      # held in $HOME/.gemini needs no key here.
      GEMINI_API_KEY = "$GEMINI_API_KEY";
      GITHUB_TOKEN = "$GITHUB_TOKEN";
    };
  };
}
