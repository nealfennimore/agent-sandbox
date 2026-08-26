# agent-sandbox flake

Sandboxed [Claude Code](https://docs.claude.com/en/docs/claude-code),
[OpenCode](https://github.com/numtide/llm-agents.nix), and
[Codex](https://github.com/openai/codex), wrapped with
[`agent-sandbox.nix`](https://github.com/archie-judd/agent-sandbox.nix).

Network egress is restricted to an explicit per-domain / per-method allowlist,
enforced by a private netns (pasta) + nftables + a MITM filtering proxy.
Everything not in the allowlist is dropped.

## Layout

| File | Contents |
| --- | --- |
| `flake.nix` | Inputs and output wiring only |
| `nix/domains.nix` | Domain allowlists |
| `nix/agents.nix` | Per-agent descriptors (package, dirs, env, domains) |
| `nix/sandbox.nix` | Sandbox interface (module) and builders |
| `nix/vm.nix` | MicroVM interface (module) and builder |
| `nix/guest.nix` | NixOS configuration for the VM guest |

## Standalone use

```sh
nix develop .#claude      # dev shell with `claude` on PATH
nix develop .#opencode    # dev shell with `opencode` on PATH
nix develop .#codex       # dev shell with `codex` on PATH
nix develop               # all three

# or run the package directly
nix run .#claude
```

## MicroVM variants

Each sandboxed agent is also available as a qemu microVM, built with
[microvm.nix](https://github.com/microvm-nix/microvm.nix). The sandbox wrapper
runs inside the guest, so the egress allowlist still applies. The VM adds a
hardware isolation boundary on top of the namespace sandbox.

```sh
cd ~/my-project
nix run /path/to/this-flake#claude-vm      # or #opencode-vm / #codex-vm
```

The dev shells also put a launcher for each VM on the PATH:

```sh
nix develop .#claude      # provides `claude` and `claude-vm`
cd ~/my-project
claude-vm                 # boots the VM from the current directory
```

The default shell (`nix develop`) provides all three launchers: `claude-vm`,
`opencode-vm`, and `codex-vm`. The launchers exist only on Linux systems.

The runner boots a minimal NixOS guest and attaches your terminal to its
serial console. The guest logs in automatically as `root`, prints any
share warnings, and launches the agent directly in `/workspace`. When
the agent exits, the VM powers off and you are back on the host. To stop
a wedged VM, press `Ctrl-a x` on the serial console, or kill the
`microvm` process. There is no host control socket (see below).

- The launch directory is shared read-write at `/workspace` in the guest.
- Every directory and file that the sandbox declares (the agent defaults
  plus the `extra*` options) is also shared from the host. See
  "Sandbox paths inside the VM" below. An agent login on the host (for
  example `$HOME/.claude`) is therefore visible inside the guest, and a
  login made inside the guest persists back to the host.
- The guest home is ephemeral. Durable state lives in the shared
  sandbox directories on the host.
- Host environment variables do not cross the VM boundary. The shared
  sandbox directories carry the login state instead.

### Sandbox paths inside the VM

The sandbox inside the guest binds the same paths as a sandbox on the
host, so those paths must exist in the guest. The VM builders collect
them at build time — agent defaults plus `extraRwDirs`, `extraRoDirs`,
`extraRwFiles`, `extraRoFiles` — and share them from the host:

- A directory mounts at its translated guest path (`$HOME/...` maps to
  `/root/...`), read-write for the rw set and read-only for the ro
  set. Missing host directories are created before the VM starts.
- A file cannot be shared over 9p individually. Its parent directory is
  staged read-only under `/run/agent-sandbox` and the file is copied
  into place at boot. The VM version therefore has no read/write
  files: an `rwFiles` entry degrades to a read-only snapshot, guest
  writes to it are lost at shutdown, and evaluation prints a warning
  when a VM declares one. Do not declare a file directly under
  `$HOME`: that stages your whole home directory read-only in the guest.
- Only absolute paths and `$HOME`-prefixed paths are supported. Other
  shell variables in a path fail the build.
- The guest agent runs as `root`. With an unprivileged qemu, 9p
  presents the launching user's files as root inside the guest, and
  only guest root passes the client-side permission checks on them.
  The inverse mapping holds for writes: guest writes execute host-side
  as the user that launched the VM, so host files keep your ownership.
  Expect `ls` inside the guest to show `root` for your files — that is
  the mapping, not a real ownership change on the host.
- The agent command in the guest is a shim that starts the sandbox in
  a user namespace with root mapped to an unprivileged uid. The
  network sandbox (pasta) refuses to run as root. File access still
  uses the real root credentials, so the shares stay accessible.
- A `$HOME` that contains spaces is not supported by the runtime share
  attachment.
- If a share fails to attach, the guest boots anyway (`nofail`) and
  prints a warning at login instead. A missing declared path degrades
  to "no data", never to "wrong data".

Recorded tradeoffs:

- The 9p shares use `security_model=none` and are policy plumbing, not
  the isolation boundary. A compromised guest writes to the shared
  paths as the launching user — that set of paths is the accepted
  blast radius. The qemu boundary provides the isolation.
- The VM alone does not protect `.git` in the workspace: the full
  directory mounts read-write. The inner sandbox re-binds git metadata
  read-only, so the guest must always run the sandboxed wrapper, never
  the raw agent. The guest config only installs the wrapped shim.
- The guest runs with no QMP control socket (`microvm.socket = null`).
  The default socket is a relative path that would land in the
  agent-writable workspace. The kiosk powers off from inside, so the
  host-side `microvm-shutdown` command is unused. Removing the socket
  keeps a control channel out of the workspace and off the host.

Requirements: a Linux host with `/dev/kvm`. Without KVM, qemu falls back to
slow software emulation. The VM outputs exist only on Linux systems.

The `modules/microvm` submodule is a local reference copy of microvm.nix.
The flake consumes the `microvm` flake input, not the submodule.

### Security comparison

| Property | Sandbox (`nix run .#claude`) | MicroVM (`nix run .#claude-vm`) |
| --- | --- | --- |
| Isolation boundary | Unprivileged namespaces: bubblewrap mount/user namespace, pasta network namespace | qemu/KVM hardware boundary, with the same namespace sandbox inside the guest |
| Egress control | MITM proxy allowlist, enforced in the sandbox network namespace | The same allowlist, enforced by the inner sandbox inside the guest |
| Kernel attack surface | Host kernel, reachable from sandboxed code | Guest kernel. The host kernel is reachable only through a VM escape |
| Filesystem visible to the agent | Host filesystem per the sandbox bind configuration | Only the workspace, the declared sandbox paths, and the nix store. The rest of the host does not exist in the guest |
| Write blast radius | The declared read/write dirs and files on the host | The same declared paths, written through 9p as the launching user |
| Git metadata (`.git`, config, hooks) | Re-bound read-only by the sandbox | Re-bound read-only by the inner sandbox — this protection comes from the sandbox layer, not the VM |
| Host environment variables | Passed through as `"$VAR"` runtime references | Do not cross the VM boundary. Login state travels through the shared directories |
| Consequence of a sandbox escape | Code runs as your user on the host | Code runs as guest root inside a disposable VM. Host reach is limited to the shared paths, as your user |

### Threat model

The threat is a compromised agent that runs attacker-chosen commands,
for example after a prompt injection. The stack stops these attacks:

- Exfiltration to arbitrary endpoints. Egress only reaches the
  allowlisted domains, with per-method rules.
- Credential harvesting. Paths outside the declared set (`~/.ssh`,
  `~/.aws`, browser profiles) do not exist in the guest. Host
  environment variables do not cross the VM boundary.
- Code execution on the host through git metadata. The sandbox binds
  `.git`, `.git/config`, and `.git/hooks` read-only.
- Persistence. Shell rc files, crontabs, and service units are not
  reachable. The guest is ephemeral and powers off after the session.
- Escalation to the host through a kernel exploit. A namespace escape
  lands in a disposable guest. The attacker still needs a separate
  qemu/KVM escape to reach the host.
- Reaching the LAN or host-local services. Traffic exits only through
  the proxy, to allowlisted hosts.
- Supply-chain payloads, for example a malicious `npm postinstall`.
  They run inside the same confinement as the agent.

These attacks stay possible:

- Damage to the shared paths: the workspace and the declared
  read/write directories.
- Exfiltration through allowed channels, including the agent's own
  credentials in its shared config directory.
- Malicious code planted in the repository and later executed on the
  host or in CI. Review changes before you run them outside the VM.
- A qemu/KVM zero-day.

### VM builders

On Linux systems, `lib.${system}` also exports `mkAgentVm` and the per-agent
builders `mkClaudeVm`, `mkOpencodeVm`, and `mkCodexVm`. Like the sandbox
builders, the VM builders evaluate their argument with the NixOS module
system, so every option is typed and checked. The options are:

| Option | Default | Semantics |
| --- | --- | --- |
| `sandbox` | `{ }` | Submodule with the sandbox options above. Configures the agent that runs inside the guest. |
| `vcpu` | `2` | Number of virtual CPU cores. |
| `mem` | `4096` | Guest RAM in MiB. |
| `workspace` | `"."` | Host path shared at `/workspace`. A relative path resolves against the runtime working directory. |
| `extraModules` | `[ ]` | Extra NixOS modules merged into the guest. |

`mkAgentVm` is the generic form. It takes the same agent descriptor as
`mkAgentSandbox`, then the VM options: `mkAgentVm descriptor config`.

See "Example downstream flake with a VM" below for a complete consumer
flake, with launcher wrapping and kiosk override included.

Example with a customized sandbox and a forwarded port:

```nix
agentbox.lib.${system}.mkClaudeVm {
  sandbox = {
    extraPackages = [ pkgs.ripgrep ];
  };
  mem = 8192;
  extraModules = [
    {
      microvm.forwardPorts = [
        { from = "host"; host.port = 2222; guest.port = 22; }
      ];
    }
  ];
}
```

## Using this flake from another flake

This flake exposes reusable builders under `lib.${system}` so a downstream
flake can extend the sandbox without forking it:

| Output | Description |
| --- | --- |
| `lib.${system}.mkClaudeSandbox` | Builder for the Claude sandbox |
| `lib.${system}.mkOpencodeSandbox` | Builder for the OpenCode sandbox |
| `lib.${system}.mkCodexSandbox` | Builder for the Codex sandbox |
| `lib.${system}.mkAgentSandbox` | Generic builder. Takes an agent descriptor and a sandbox config. |
| `lib.${system}.agentDomains` | The default host-origin allowlist (an attrset), exported so you can merge onto it |
| `lib.${system}.mkClaudeVm` | Builder for the Claude microVM (Linux systems only) |
| `lib.${system}.mkOpencodeVm` | Builder for the OpenCode microVM (Linux systems only) |
| `lib.${system}.mkCodexVm` | Builder for the Codex microVM (Linux systems only) |
| `lib.${system}.mkAgentVm` | Generic VM builder. Takes an agent descriptor and a VM config (Linux systems only) |
| `lib.${system}.mkVmLauncher` | Wraps a VM runner in a launcher with a distinct name for dev shells (Linux systems only) |

The builders evaluate their argument with the NixOS module system. Each
argument is a typed option with a default. An unknown or mistyped argument
fails evaluation with the offending option path.

Each builder accepts these options:

| Option | Default | Semantics |
| --- | --- | --- |
| `package` | the agent package from nixpkgs | **Replace.** The agent package to wrap. |
| `allowedDomains` | `agentDomains` | **Replace.** The host-origin allowlist. Pass a new attrset, or `//`-merge onto `agentDomains`. |
| `extraPackages` | `[ ]` | **Append.** Extra packages added onto the built-in tool set (`agent-sandbox`'s `commonTools`). |
| `extraRwDirs` | `[ ]` | **Append.** Extra read/write directories added onto the defaults. |
| `extraRoDirs` | `[ ]` | **Append.** Extra read-only directories added onto the defaults. |
| `extraRwFiles` | `[ ]` | **Append.** Extra read/write files added onto the defaults. |
| `extraRoFiles` | `[ ]` | **Append.** Extra read-only files added onto the defaults. |
| `extraEnv` | `{ }` | **Merge.** Attrset `//`-merged onto the default env. Keys here win, so it can also override a default. |

`mkAgentSandbox` builds a sandbox for an agent this flake does not know
about. The descriptor holds what differs between agents:

```nix
agentbox.lib.${system}.mkAgentSandbox {
  binName = "aider";
  package = pkgs.aider-chat;
  baseDomains = { "openai.com" = "*"; };
  rwDirs = [ "$HOME/.aider" ];
  env = { OPENAI_API_KEY = "$OPENAI_API_KEY"; };
} {
  extraPackages = [ pkgs.ripgrep ];
}
```

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

### Example downstream flake with a VM

The VM builders take the VM options table above. The `sandbox` option
nests the full sandbox interface, so one call configures both layers.
The result is a runner package: `nix run` boots the VM from the current
directory.

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

      claude-vm = box.mkClaudeVm {
        # Same options as mkClaudeSandbox. Directories declared here
        # are shared from the host into the guest automatically.
        sandbox = {
          allowedDomains = box.agentDomains // {
            "internal.example.com" = "*";
          };
          extraPackages = [ pkgs.ripgrep ];
          extraRwDirs = [ "$HOME/.cache/agent" ];
          # Git identity for commits made inside the guest:
          extraEnv = {
            GIT_AUTHOR_NAME = "Agent";
            GIT_AUTHOR_EMAIL = "agent@example.com";
            GIT_COMMITTER_NAME = "Agent";
            GIT_COMMITTER_EMAIL = "agent@example.com";
          };
        };

        # VM options.
        vcpu = 4;
        mem = 8192;
        extraModules = [
          {
            microvm.forwardPorts = [
              { from = "host"; host.port = 2222; guest.port = 22; }
            ];
          }
        ];
      };
    in
    {
      # `nix run .#claude-vm` from a project directory boots the VM,
      # shares that directory at /workspace, and launches the agent.
      packages.${system}.claude-vm = claude-vm;

      # Every VM runner exposes the same bin/microvm-run, so wrap each
      # runner with mkVmLauncher when a dev shell holds more than one.
      devShells.${system}.default = pkgs.mkShell {
        packages = [ (box.mkVmLauncher "claude" claude-vm) ];
      };
    };
}
```

Notes:

- The VM builders and `mkVmLauncher` exist only on Linux systems. A
  Darwin `lib.${system}` does not contain them.
- The host needs `/dev/kvm`. Without it, qemu falls back to slow
  software emulation.
- Host environment variables do not cross the VM boundary. `"$VAR"`
  references in `extraEnv` expand to empty inside the guest. Login
  state travels through the shared sandbox directories instead — see
  "Sandbox paths inside the VM".
- The guest boots as a kiosk: it prints share warnings, launches the
  agent in `/workspace`, and powers off when the agent exits. To get a
  shell instead, override the kiosk from `extraModules`:
  `{ environment.loginShellInit = nixpkgs.lib.mkForce "cd /workspace"; }`.
- For an agent this flake does not know, pass a descriptor to
  `mkAgentVm` (same descriptor as `mkAgentSandbox`):

```nix
box.mkAgentVm {
  binName = "aider";
  package = pkgs.aider-chat;
  baseDomains = { "openai.com" = "*"; };
  rwDirs = [ "$HOME/.aider" ];
  env = { };
} {
  mem = 8192;
  sandbox.extraPackages = [ pkgs.ripgrep ];
}
```

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
