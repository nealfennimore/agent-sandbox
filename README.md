# agent-sandbox flake

Sandboxed [Claude Code](https://docs.claude.com/en/docs/claude-code),
[OpenCode](https://github.com/numtide/llm-agents.nix), and
[Codex](https://github.com/openai/codex), wrapped with
[`agent-sandbox.nix`](https://github.com/archie-judd/agent-sandbox.nix).

Network egress is restricted to an explicit per-domain / per-method allowlist,
enforced by a private netns (pasta) + nftables + a MITM filtering proxy.
Everything not in the allowlist is dropped.

## Standalone use

```sh
nix develop .#claude      # dev shell with `claude` on PATH
nix develop .#opencode    # dev shell with `opencode` on PATH
nix develop .#codex       # dev shell with `codex` on PATH
nix develop               # all three

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
| `lib.${system}.mkCodexSandbox` | Builder for the Codex sandbox |
| `lib.${system}.agentDomains` | The default host-origin allowlist (an attrset), exported so you can merge onto it |

Each builder accepts these optional arguments:

| Argument | Default | Semantics |
| --- | --- | --- |
| `allowedDomains` | `agentDomains` | **Replace.** The host-origin allowlist. Pass a new attrset, or `//`-merge onto `agentDomains`. |
| `extraPackages` | `[ ]` | **Append.** Extra packages added onto the built-in tool set (`agent-sandbox`'s `commonTools`). |
| `extraRwDirs` | `[ ]` | **Append.** Extra read/write directories added onto the defaults. |
| `extraRwFiles` | `[ ]` | **Append.** Extra read/write files added onto the defaults. |
| `extraEnv` | `{ }` | **Merge.** Attrset `//`-merged onto the default env. Keys here win, so it can also override a default. |

`allowedDomains` and `extraEnv` are attrsets: `allowedDomains` **replaces** the
whole allowlist (merge with `//` to keep the defaults), while `extraEnv`
**merges** onto the default env. The three `extra*` lists are **appended** onto
the built-in defaults.

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

#### Ports

A key without a port covers port 443 (HTTPS) and port 80 (plaintext HTTP). To
reach a different port, put the port in the key:

```nix
allowedDomains = {
  "internal.example.com:8443" = "*";        # HTTPS on 8443 only
  "metrics.example.com:9090" = [ "GET" ];   # read-only on 9090
};
```

Rules for a key with a port:

- The key covers that port only. `"example.com:8443"` does not allow port 443.
- The port applies to the suffix match too, so `"example.com:8443"` also covers
  `api.example.com:8443`.
- To allow both the default ports and an extra port, write two keys.
- Write an IPv6 literal in brackets: `"[::1]:8443"`.

The port support comes from `patches/proxy-ports.patch`, which this flake
applies to the `agent-sandbox.nix` input. Upstream allows port 443 for `CONNECT`
and port 80 for plaintext only.

### Example downstream flake

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    agentbox.url = "github:nealfennimore/agent-sandbox";
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

        # Merge onto the default env (runtime shell-var refs keep secrets
        # out of the /nix/store).
        extraEnv = {
          ANTHROPIC_API_KEY = "$ANTHROPIC_API_KEY";
          HTTPS_PROXY = "$HTTPS_PROXY";
        };
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
- `extraEnv` values are passed verbatim to the launcher; use `"$VAR"` shell-var
  references for secrets so they expand at runtime and stay out of the
  `/nix/store`. A key matching a default (e.g. `GITHUB_TOKEN`) overrides it.
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

export OPENAI_API_KEY=...
nix run .#codex
```

Codex can also use a ChatGPT login instead of `OPENAI_API_KEY`. The login
credentials live in `$HOME/.codex`, which the sandbox mounts read/write. If the
browser login flow does not work inside the sandbox, run `codex login` outside
the sandbox first.
