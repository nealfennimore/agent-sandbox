# agent-sandbox flake

Sandboxed [Claude Code](https://docs.claude.com/en/docs/claude-code) and
[OpenCode](https://github.com/numtide/llm-agents.nix), wrapped with
[`agent-sandbox.nix`](https://github.com/archie-judd/agent-sandbox.nix).

Network egress is restricted to an explicit per-domain / per-method allowlist,
enforced by a private netns (pasta) + nftables + a MITM filtering proxy.
Everything not in the allowlist is dropped.

## Standalone use

```sh
nix develop .#claude      # dev shell with `claude` on PATH
nix develop .#opencode    # dev shell with `opencode` on PATH
nix develop               # both

# or run the package directly
nix run .#claude
```

## Using this flake from another flake

This flake exposes reusable builders under `lib.${system}` so a downstream
flake can extend the sandbox without forking it:

| Output | Description |
| --- | --- |
| `lib.${system}.mkClaudeSandbox` | Builder for the Claude sandbox |
| `lib.${system}.mkOpencodeSandbox` | Builder for the OpenCode sandbox |
| `lib.${system}.agentDomains` | The default host-origin allowlist (an attrset), exported so you can merge onto it |

Each builder accepts these optional arguments:

| Argument | Default | Semantics |
| --- | --- | --- |
| `allowedDomains` | `agentDomains` | **Replace.** The host-origin allowlist. Pass a new attrset, or `//`-merge onto `agentDomains`. |
| `extraPackages` | `[ ]` | **Append.** Extra packages added onto the built-in tool set (`agent-sandbox`'s `commonTools`). |
| `extraRwDirs` | `[ ]` | **Append.** Extra read/write directories added onto the defaults. |
| `extraRwFiles` | `[ ]` | **Append.** Extra read/write files added onto the defaults. |

`allowedDomains` **replaces** the whole allowlist; the three `extra*` lists are
**appended** onto the built-in defaults.

### `allowedDomains` format

An attrset mapping each host origin to the HTTP methods allowed for it. Use
`"*"` for all methods, or a list to restrict. Domains suffix-match, so
`"anthropic.com"` also covers `*.anthropic.com`.

```nix
allowedDomains = {
  "anthropic.com" = "*";
  "github.com" = [ "GET" "HEAD" ];
};
```

### Example downstream flake

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    agentbox.url = "github:you/test-opencode";
  };

  outputs =
    { nixpkgs, agentbox, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; config.allowUnfree = true; };
      box = agentbox.lib.${system};
    in
    {
      packages.${system}.claude = box.mkClaudeSandbox {
        # Merge onto the default allowlist (or replace it wholesale).
        allowedDomains = box.agentDomains // {
          "internal.example.com" = "*";
          "pypi.org" = [ "GET" "HEAD" ];
        };

        # Append to the built-in defaults.
        extraPackages = [ pkgs.ripgrep pkgs.jq ];
        extraRwDirs = [ "$HOME/.cache/agent" "$HOME/project/scratch" ];
        extraRwFiles = [ "$HOME/.netrc" ];
      };

      devShells.${system}.default = pkgs.mkShell {
        packages = [ (box.mkClaudeSandbox { }) ];  # defaults, unchanged
      };
    };
}
```

Notes:

- `$HOME` (and other shell vars) in `extraRwDirs` / `extraRwFiles` are expanded
  at runtime by the sandbox launcher, so they resolve to the invoking user's
  paths rather than being baked into the `/nix/store`.
- `extraPackages` takes derivations — reference them from your own `pkgs`
  (matching `system`).
- Replacing `allowedDomains` entirely (without `// agentDomains`) drops the
  default Anthropic/GitHub origins, so the agent won't be able to reach them.
  Pass `[ ]` to block all egress.

### Secrets

Secrets are passed as runtime shell-var references (e.g.
`CLAUDE_CODE_OAUTH_TOKEN = "$CLAUDE_CODE_OAUTH_TOKEN"`) so they expand in the
calling shell and never land in the `/nix/store`. Export them before launching:

```sh
export CLAUDE_CODE_OAUTH_TOKEN=...
export GITHUB_TOKEN=...
nix run .#claude
```
