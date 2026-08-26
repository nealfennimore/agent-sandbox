{
  # Test flake: sandbox Claude Code, OpenCode, and Codex with agent-sandbox.nix.
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

    # MicroVM variants: run a sandboxed agent inside a qemu microVM.
    # The submodule at modules/microvm is a local reference copy only.
    # The flake consumes this input.
    microvm.url = "github:microvm-nix/microvm.nix";
    microvm.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      nixpkgs,
      agent-sandbox,
      llm-agents,
      flake-utils,
      microvm,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = true;
        };
        # agent-sandbox.nix builds its MITM proxy from its own source tree and
        # exposes no override for it. The patch teaches that proxy to accept a
        # port in an allowlist key ("host:port"). Upstream accepts port 443 for
        # CONNECT and port 80 for plaintext only. See patches/proxy-ports.patch.
        # The patched tree keeps the same interface, so `default.nix` gives the
        # same `mkSandbox` and `commonTools` as `agent-sandbox.lib.${system}`.
        sbxSrc = pkgs.applyPatches {
          name = "agent-sandbox-patched";
          src = agent-sandbox;
          patches = [ ./patches/proxy-ports.patch ];
        };
        sbx = import sbxSrc { inherit pkgs; };

        # Bare minimum domain to get Claude working
        baseDomains = {
          "anthropic.com" = "*";
          "claude.com" = "*";
        };

        # Bare minimum domains to get Codex working. "openai.com" also covers
        # api.openai.com and auth.openai.com (suffix match); chatgpt.com is
        # used by ChatGPT-plan auth and its backend API.
        codexBaseDomains = {
          "openai.com" = "*";
          "chatgpt.com" = "*";
        };

        # Domains the agent is allowed to reach. "*" = all HTTP methods;
        # a list restricts to those methods (read-only access to GitHub here).
        # A key without a port covers ports 80 and 443. To reach another port,
        # add the port to the key: "internal.example.com:8443" = "*";
        agentDomains = {
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

        # Builders that accept an overridable host-origin allowlist plus
        # append-style extensions for packages and read/write paths.
        # Downstream flakes call these via `lib.${system}`:
        #   - allowedDomains: replace wholesale, or `//`-merge onto the
        #     exported `agentDomains` default.
        #   - extraPackages / extraRwDirs / extraRwFiles: lists appended
        #     onto the built-in defaults.
        #   - extraEnv: attrset `//`-merged onto the default env (later
        #     keys win, so it can also override defaults).
        mkClaudeSandbox =
          {
            claude-code ? pkgs.claude-code,
            allowedDomains ? agentDomains,
            extraPackages ? [ ],
            extraRwDirs ? [ ],
            extraRoDirs ? [ ],
            extraRwFiles ? [ ],
            extraRoFiles ? [ ],
            extraEnv ? { },
          }:
          sbx.mkSandbox {
            pkg = claude-code;
            binName = "claude";
            outName = "claude";
            allowedPackages = sbx.commonTools ++ extraPackages;
            rwDirs = [ "$HOME/.claude" ] ++ extraRwDirs;
            rwFiles = [ ] ++ extraRwFiles;
            roDirs = [ ] ++ extraRoDirs;
            roFiles = [ ] ++ extraRoFiles;
            # Bind host gitconfig read-only for git identity (optional):
            # roFiles = [ "$HOME/.config/git/config" ];
            env = {
              # Secrets are passed as runtime shell-var references so they
              # expand in the shell, never landing in the /nix/store.
              CLAUDE_CODE_OAUTH_TOKEN = "$CLAUDE_CODE_OAUTH_TOKEN";
              GITHUB_TOKEN = "$GITHUB_TOKEN";
              CLAUDE_CONFIG_DIR = "$HOME/.claude";
            }
            // extraEnv;
            allowedDomains = allowedDomains // baseDomains;
          };

        mkOpencodeSandbox =
          {
            opencode ? pkgs.opencode,
            allowedDomains ? agentDomains,
            extraPackages ? [ ],
            extraRwDirs ? [ ],
            extraRoDirs ? [ ],
            extraRwFiles ? [ ],
            extraRoFiles ? [ ],
            extraEnv ? { },
          }:
          sbx.mkSandbox {
            pkg = opencode;
            binName = "opencode";
            outName = "opencode";
            allowedPackages = sbx.commonTools ++ extraPackages;
            rwDirs = [
              "$HOME/.config/opencode"
              "$HOME/.local/share/opencode"
              "$HOME/.local/state/opencode"
            ]
            ++ extraRwDirs;
            rwFiles = [ ] ++ extraRwFiles;
            roDirs = [ ] ++ extraRoDirs;
            roFiles = [ ] ++ extraRoFiles;
            env = {
              # Add whatever provider key opencode is configured to use, e.g.:
              # ANTHROPIC_API_KEY = "$ANTHROPIC_API_KEY";
            }
            // extraEnv;
            allowedDomains = allowedDomains // baseDomains;
          };

        mkCodexSandbox =
          {
            codex ? pkgs.codex,
            allowedDomains ? agentDomains,
            extraPackages ? [ ],
            extraRwDirs ? [ ],
            extraRoDirs ? [ ],
            extraRwFiles ? [ ],
            extraRoFiles ? [ ],
            extraEnv ? { },
          }:
          sbx.mkSandbox {
            pkg = codex;
            binName = "codex";
            outName = "codex";
            allowedPackages = sbx.commonTools ++ extraPackages;
            rwDirs = [ "$HOME/.codex" ] ++ extraRwDirs;
            rwFiles = [ ] ++ extraRwFiles;
            roDirs = [ ] ++ extraRoDirs;
            roFiles = [ ] ++ extraRoFiles;
            env = {
              # Secrets are passed as runtime shell-var references so they
              # expand in the shell, never landing in the /nix/store.
              OPENAI_API_KEY = "$OPENAI_API_KEY";
              GITHUB_TOKEN = "$GITHUB_TOKEN";
              CODEX_HOME = "$HOME/.codex";
            }
            // extraEnv;
            allowedDomains = allowedDomains // codexBaseDomains;
          };

        claude-sandboxed = mkClaudeSandbox { };
        opencode-sandboxed = mkOpencodeSandbox { };
        codex-sandboxed = mkCodexSandbox { };

        # MicroVM outputs only make sense for Linux guests.
        isLinux = nixpkgs.lib.hasSuffix "-linux" system;

        # Wrap a sandboxed agent in a qemu microVM. The netns/proxy sandbox
        # runs inside the guest, so the egress allowlist still applies. The
        # VM adds a hardware isolation boundary on top.
        #
        # Launch from a project directory: the CWD is shared read-write at
        # /workspace (9p with a relative source resolves against the runtime
        # CWD of microvm-run), and a per-agent home image (<name>-vm-home.img)
        # is created in the CWD on first run so agent logins persist. Host
        # environment variables do not cross the VM boundary — log the agent
        # in once inside the guest instead.
        mkAgentVm =
          {
            name, # "claude" | "opencode" | "codex"
            agent, # the sandboxed wrapper package to install in the guest
            vcpu ? 2,
            mem ? 4096, # MiB
            workspace ? ".", # host path; relative resolves against runtime CWD
            homeImageSize ? 2048, # MiB
            extraModules ? [ ], # extra NixOS modules merged into the guest
          }:
          (nixpkgs.lib.nixosSystem {
            inherit system;
            modules = [
              microvm.nixosModules.microvm
              (
                { lib, ... }:
                {
                  system.stateVersion = lib.trivial.release;
                  networking.hostName = "${name}-vm";

                  # Match the common host uid so the 9p workspace share is
                  # writable without remapping.
                  users.users.agent = {
                    isNormalUser = true;
                    uid = 1000;
                    initialPassword = "";
                  };
                  services.getty.autologinUser = "agent";
                  # Land in the shared workspace on login.
                  environment.loginShellInit = "cd /workspace 2>/dev/null || true";

                  environment.systemPackages = [ agent ];

                  microvm = {
                    hypervisor = "qemu";
                    inherit vcpu mem;
                    # SLiRP user networking: no root or host setup required.
                    interfaces = [
                      {
                        type = "user";
                        id = "eth0";
                        mac = "02:00:00:00:00:01";
                      }
                    ];
                    shares = [
                      {
                        tag = "ro-store";
                        source = "/nix/store";
                        mountPoint = "/nix/.ro-store";
                        proto = "9p";
                      }
                      {
                        tag = "workspace";
                        source = workspace;
                        mountPoint = "/workspace";
                        proto = "9p";
                      }
                    ];
                    # Persist /home (agent credentials, caches) across boots.
                    volumes = [
                      {
                        image = "${name}-vm-home.img";
                        mountPoint = "/home";
                        size = homeImageSize;
                      }
                    ];
                  };
                }
              )
            ]
            ++ extraModules;
          }).config.microvm.declaredRunner;

        # Per-agent VM builders. `sandbox` takes the same arguments as the
        # corresponding mk*Sandbox builder; the rest are mkAgentVm knobs.
        mkClaudeVm =
          {
            sandbox ? { },
            vcpu ? 2,
            mem ? 4096,
            workspace ? ".",
            homeImageSize ? 2048,
            extraModules ? [ ],
          }:
          mkAgentVm {
            name = "claude";
            agent = mkClaudeSandbox sandbox;
            inherit
              vcpu
              mem
              workspace
              homeImageSize
              extraModules
              ;
          };

        mkOpencodeVm =
          {
            sandbox ? { },
            vcpu ? 2,
            mem ? 4096,
            workspace ? ".",
            homeImageSize ? 2048,
            extraModules ? [ ],
          }:
          mkAgentVm {
            name = "opencode";
            agent = mkOpencodeSandbox sandbox;
            inherit
              vcpu
              mem
              workspace
              homeImageSize
              extraModules
              ;
          };

        mkCodexVm =
          {
            sandbox ? { },
            vcpu ? 2,
            mem ? 4096,
            workspace ? ".",
            homeImageSize ? 2048,
            extraModules ? [ ],
          }:
          mkAgentVm {
            name = "codex";
            agent = mkCodexSandbox sandbox;
            inherit
              vcpu
              mem
              workspace
              homeImageSize
              extraModules
              ;
          };

        claude-vm = mkClaudeVm { };
        opencode-vm = mkOpencodeVm { };
        codex-vm = mkCodexVm { };

        # Every microvm runner exposes the same bin/microvm-run, so the
        # runners cannot share a dev shell PATH directly. Wrap each runner
        # in a launcher with a distinct name (claude-vm, opencode-vm, ...).
        mkVmLauncher =
          name: runner:
          pkgs.writeShellScriptBin "${name}-vm" ''
            exec ${runner}/bin/microvm-run "$@"
          '';

        claude-vm-launcher = mkVmLauncher "claude" claude-vm;
        opencode-vm-launcher = mkVmLauncher "opencode" opencode-vm;
        codex-vm-launcher = mkVmLauncher "codex" codex-vm;

        onLinux = nixpkgs.lib.optionals isLinux;
      in
      {
        # Reusable builders for downstream flakes. See README.md for the
        # full extension guide. Example:
        #   agentbox.lib.${system}.mkClaudeSandbox {
        #     allowedDomains = agentbox.lib.${system}.agentDomains // {
        #       "internal.example.com" = "*";
        #     };
        #     extraPackages = [ pkgs.ripgrep ];
        #     extraRwDirs   = [ "$HOME/.cache/agent" ];
        #     extraRwFiles  = [ "$HOME/.netrc" ];
        #     extraEnv      = { ANTHROPIC_API_KEY = "$ANTHROPIC_API_KEY"; };
        #   }
        lib = {
          inherit
            agentDomains
            mkClaudeSandbox
            mkOpencodeSandbox
            mkCodexSandbox
            ;
        }
        // nixpkgs.lib.optionalAttrs isLinux {
          inherit
            mkAgentVm
            mkClaudeVm
            mkOpencodeVm
            mkCodexVm
            ;
        };

        devShells = {
          claude = pkgs.mkShell {
            packages = [ claude-sandboxed ] ++ onLinux [ claude-vm-launcher ];
          };
          opencode = pkgs.mkShell {
            packages = [ opencode-sandboxed ] ++ onLinux [ opencode-vm-launcher ];
          };
          codex = pkgs.mkShell {
            packages = [ codex-sandboxed ] ++ onLinux [ codex-vm-launcher ];
          };
          default = pkgs.mkShell {
            packages = [
              claude-sandboxed
              opencode-sandboxed
              codex-sandboxed
            ]
            ++ onLinux [
              claude-vm-launcher
              opencode-vm-launcher
              codex-vm-launcher
            ];
          };
        };

        packages = {
          claude = claude-sandboxed;
          opencode = opencode-sandboxed;
          codex = codex-sandboxed;
        }
        // nixpkgs.lib.optionalAttrs isLinux {
          inherit claude-vm opencode-vm codex-vm;
        };
      }
    );
}
