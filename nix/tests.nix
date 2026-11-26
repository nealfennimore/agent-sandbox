# The checks for this flake. Run them with `nix flake check -L`.
#
# The checks are in three tiers, from cheap to expensive:
#
#   eval-*      Module semantics, manifest shape and VM path mapping.
#               These tiers evaluate Nix code. They build nothing and
#               they download nothing.
#   sandbox-*   A sandbox wrapper, and the launcher spec it carries.
#               `sandbox-override` wraps a stub agent, so it builds the
#               sandbox closure alone. The per-agent checks wrap the
#               real agent, so each one downloads the release that
#               overlays/<agent>/manifest.json pins.
#   vm-*        Instantiation of a microVM guest. The check forces the
#               evaluation of the guest derivation and discards it, so
#               the NixOS closure is never built.
#
# The sandbox wrapper carries its launcher spec as `buildSpec`, a JSON
# file in the store. The spec is the contract between this flake and
# agent-sandbox.nix, so the sandbox checks assert on its fields. The
# spec names the proxy allowlist file, which holds the egress policy.
{
  lib,
  pkgs,
  system,
  domains,
  agents,
  sandbox,
  vm,
}:
let
  isLinux = lib.hasSuffix "-linux" system;

  manifests = {
    claude-code = lib.importJSON ../overlays/claude-code/manifest.json;
    opencode = lib.importJSON ../overlays/opencode/manifest.json;
    codex = lib.importJSON ../overlays/codex/manifest.json;
    antigravity-cli = lib.importJSON ../overlays/antigravity-cli/manifest.json;
  };

  # A stand-in for an agent package. It gives a builder a real
  # derivation with the expected binary name, and it downloads nothing.
  stubAgent = name: pkgs.writeShellScriptBin name ''echo "stub ${name}"'';

  stubClaude = stubAgent "claude";

  # The sandbox config for one agent, evaluated through the module
  # system. This is the value the builders consume.
  claudeCfg = sandbox.evalSandbox agents.claude;

  # True when the evaluation of `expr` throws. The seq forces the value
  # to weak head normal form, which is where the module system reports
  # an unknown option.
  evalFails = expr: !(builtins.tryEval (builtins.seq expr true)).success;

  # True when the deep evaluation of `expr` throws. Option type errors
  # surface inside the merged value, so the force must be deep.
  deepEvalFails = expr: !(builtins.tryEval (builtins.deepSeq expr true)).success;

  hexChecksum = checksum: builtins.match "[0-9a-f]{64}" checksum != null;

  semver = version: builtins.match "[0-9]+\\.[0-9]+\\.[0-9]+" version != null;

  # Every checksum in a manifest, as one list.
  checksumsOf = manifest: map (entry: entry.checksum) (builtins.attrValues manifest.platforms);

  # Turn a set of lib.runTests cases into a derivation. A failure
  # prints the expected value and the actual value of each failing
  # case. The report carries no string context, so a failing case
  # cannot pull a package into the closure of the check.
  mkEvalCheck =
    name: tests:
    let
      failures = lib.runTests tests;
      total = builtins.length (builtins.attrNames tests);
      report = builtins.unsafeDiscardStringContext (builtins.toJSON failures);
    in
    pkgs.runCommand "check-${name}" { inherit report; } (
      if failures == [ ] then
        ''
          echo "${name}: ${toString total} tests passed"
          touch $out
        ''
      else
        ''
          echo "${name}: failing tests:" >&2
          printf '%s\n' "$report" >&2
          exit 1
        ''
    );

  # Build a sandbox wrapper, then assert on the launcher spec it
  # carries. `assertions` is a shell fragment. It calls spec_is and
  # allowlist_is, which each take one jq expression.
  mkSandboxCheck =
    {
      name,
      drv,
      binName,
      assertions,
    }:
    pkgs.runCommand "check-${name}" { nativeBuildInputs = [ pkgs.jq ]; } ''
      set -euo pipefail
      spec=${drv.buildSpec}
      allowlist=$(jq -r '.proxy.allowlist_file' "$spec")

      spec_is() {
        if ! jq -e "$1" "$spec" > /dev/null; then
          echo "${name}: spec assertion failed: $1" >&2
          jq . "$spec" >&2
          exit 1
        fi
      }

      allowlist_is() {
        if ! jq -e "$1" "$allowlist" > /dev/null; then
          echo "${name}: allowlist assertion failed: $1" >&2
          jq . "$allowlist" >&2
          exit 1
        fi
      }

      test -x ${drv}/bin/${binName}
      # The launcher reads the spec through the path baked into the stub.
      grep -q "$spec" ${drv}/bin/${binName}

      ${assertions}

      echo "${name}: spec and allowlist assertions passed"
      touch $out
    '';

  # Force the evaluation of a derivation without building it. The seq
  # returns a plain string, so the check derivation does not depend on
  # the derivation it evaluated.
  mkInstantiateCheck =
    name: drv:
    pkgs.runCommand "check-${name}" { } ''
      echo "${name}: ${builtins.seq drv.drvPath "guest derivation evaluated"}"
      touch $out
    '';

  # The default egress policy, asserted once per agent below.
  githubAllowlistAssertions = ''
    allowlist_is '.["github.com"] == ["GET","HEAD"]'
    allowlist_is '.["api.github.com"] == ["GET","HEAD"]'
    allowlist_is '.["raw.githubusercontent.com"] == ["GET","HEAD"]'
  '';

  overlayTests = {
    # The overlay is what hooks the vendored packages into pkgs. Each
    # attribute must be the package next to this file, not the nixpkgs
    # one from the flake.lock pin.
    testClaudeCodeComesFromOverlay = {
      expr = pkgs.claude-code.drvPath == (pkgs.callPackage ../overlays/claude-code/package.nix { }).drvPath;
      expected = true;
    };
    testOpencodeComesFromOverlay = {
      expr = pkgs.opencode.drvPath == (pkgs.callPackage ../overlays/opencode/package.nix { }).drvPath;
      expected = true;
    };
    testCodexComesFromOverlay = {
      expr = pkgs.codex.drvPath == (pkgs.callPackage ../overlays/codex/package.nix { }).drvPath;
      expected = true;
    };
    testAntigravityComesFromOverlay = {
      expr =
        pkgs.antigravity-cli.drvPath
        == (pkgs.callPackage ../overlays/antigravity-cli/package.nix { }).drvPath;
      expected = true;
    };

    # Each package reports the version its manifest pins.
    testClaudeCodeVersion = {
      expr = pkgs.claude-code.version;
      expected = manifests.claude-code.version;
    };
    testOpencodeVersion = {
      expr = pkgs.opencode.version;
      expected = manifests.opencode.version;
    };
    testCodexVersion = {
      expr = pkgs.codex.version;
      expected = manifests.codex.version;
    };
    testAntigravityVersion = {
      expr = pkgs.antigravity-cli.version;
      expected = manifests.antigravity-cli.version;
    };

    # update.sh writes the manifest. These cases fail when a release
    # feed returns a version or a checksum in another shape.
    testVersionsAreSemver = {
      expr = map (m: semver m.version) (builtins.attrValues manifests);
      expected = [
        true
        true
        true
        true
      ];
    };
    testChecksumsAreSha256Hex = {
      expr = builtins.all hexChecksum (
        lib.concatMap checksumsOf (builtins.attrValues manifests)
      );
      expected = true;
    };

    # Every platform in meta.platforms needs the matching manifest key.
    # package.nix builds the key from the host platform.
    testClaudeCodePlatformKeys = {
      expr = builtins.all (key: builtins.hasAttr key manifests.claude-code.platforms) [
        "darwin-arm64"
        "linux-arm64"
        "linux-x64"
      ];
      expected = true;
    };
    testOpencodePlatformKeys = {
      expr = builtins.all (key: builtins.hasAttr key manifests.opencode.platforms) [
        "darwin-arm64"
        "linux-arm64"
        "linux-x64"
      ];
      expected = true;
    };
    testCodexPlatformKeys = {
      expr = builtins.all (key: builtins.hasAttr key manifests.codex.platforms) [
        "aarch64-apple-darwin"
        "aarch64-unknown-linux-musl"
        "x86_64-apple-darwin"
        "x86_64-unknown-linux-musl"
      ];
      expected = true;
    };

    testAntigravityPlatformKeys = {
      expr = builtins.all (key: builtins.hasAttr key manifests.antigravity-cli.platforms) [
        "darwin-arm64"
        "darwin-x64"
        "linux-arm64"
        "linux-x64"
      ];
      expected = true;
    };

    # An agent descriptor takes its package from pkgs, so the overlay
    # reaches the sandbox builders.
    testAgentPackagesComeFromOverlay = {
      expr = lib.mapAttrs (_name: agent: agent.package.drvPath) agents;
      expected = {
        antigravity = pkgs.antigravity-cli.drvPath;
        claude = pkgs.claude-code.drvPath;
        codex = pkgs.codex.drvPath;
        opencode = pkgs.opencode.drvPath;
      };
    };
    testSandboxDefaultPackage = {
      expr = (claudeCfg { }).package.drvPath;
      expected = pkgs.claude-code.drvPath;
    };

    # A manifest is an argument, so a downstream flake can track
    # another release without a copy of package.nix.
    testManifestIsOverridable = {
      expr =
        (pkgs.claude-code.override {
          manifest = manifests.claude-code // {
            version = "0.0.0";
          };
        }).version;
      expected = "0.0.0";
    };
    # The force of drvPath reaches src, which reads the platform entry.
    # A deep force is wrong here: a derivation refers to itself.
    testMissingPlatformKeyThrows = {
      expr = evalFails (
        pkgs.claude-code.override {
          manifest = manifests.claude-code // {
            platforms = { };
          };
        }
      ).drvPath;
      expected = true;
    };
  };

  sandboxTests = {
    # The defaults close the sandbox. A change here widens the attack
    # surface of every agent at once.
    testClosedDefaults = {
      expr = {
        inherit (claudeCfg { })
          allowNix
          allowUnixSockets
          allowHeadlessBrowsers
          allowedHostPorts
          publishedPorts
          extraPackages
          extraRwDirs
          extraRoDirs
          extraRwFiles
          extraRoFiles
          ;
      };
      expected = {
        allowNix = false;
        allowUnixSockets = false;
        allowHeadlessBrowsers = [ ];
        allowedHostPorts = [ ];
        publishedPorts = [ ];
        extraPackages = [ ];
        extraRwDirs = [ ];
        extraRoDirs = [ ];
        extraRwFiles = [ ];
        extraRoFiles = [ ];
      };
    };
    testDefaultAllowedDomains = {
      expr = (claudeCfg { }).allowedDomains;
      expected = domains.agentDomains;
    };

    # The extra* lists append. Two modules that define one list
    # concatenate their definitions.
    testExtraListsAppend = {
      expr = lib.sort (a: b: a < b) (claudeCfg {
        imports = [
          { extraRwDirs = [ "/one" ]; }
          { extraRwDirs = [ "/two" ]; }
        ];
      }).extraRwDirs;
      expected = [
        "/one"
        "/two"
      ];
    };

    # allowedDomains replaces the default, and then merges per key.
    testAllowedDomainsReplacesDefault = {
      expr = (claudeCfg { allowedDomains = { "only.example" = "*"; }; }).allowedDomains;
      expected = {
        "only.example" = "*";
      };
    };
    testAllowedDomainsMergePerKey = {
      expr = (claudeCfg {
        imports = [
          { allowedDomains = { "one.example" = "*"; }; }
          { allowedDomains = { "two.example" = [ "GET" ]; }; }
        ];
      }).allowedDomains;
      expected = {
        "one.example" = "*";
        "two.example" = [ "GET" ];
      };
    };

    # The object form is a path rule. methods defaults to "*".
    testAllowedDomainsPathRule = {
      expr =
        let
          rule = (claudeCfg {
            allowedDomains."buzz.example" = {
              paths = [ "/buzz/agent/mcp/fable/*" ];
            };
          }).allowedDomains."buzz.example";
        in
        {
          inherit (rule) methods paths;
        };
      expected = {
        methods = "*";
        paths = [ "/buzz/agent/mcp/fable/*" ];
      };
    };
    # A path rule needs at least one path.
    testAllowedDomainsPathRuleNeedsPaths = {
      expr = evalFails (claudeCfg {
        allowedDomains."buzz.example" = {
          paths = [ ];
        };
      }).allowedDomains."buzz.example".paths;
      expected = true;
    };

    # The agent package is a default, so one definition replaces it.
    # This is the override path for a downstream flake.
    testPackageOverride = {
      expr = (claudeCfg { package = stubClaude; }).package.drvPath;
      expected = stubClaude.drvPath;
    };
    testPkgAlias = {
      expr = (claudeCfg { pkg = stubClaude; }).package.drvPath;
      expected = stubClaude.drvPath;
    };

    # Typed options reject a typo and a bad value at evaluation time.
    testUnknownOptionRejected = {
      expr = evalFails (claudeCfg { extraPackage = [ ]; });
      expected = true;
    };
    testBadPortRejected = {
      expr = deepEvalFails (claudeCfg { publishedPorts = [ 70000 ]; }).publishedPorts;
      expected = true;
    };
    testBadBrowserRejected = {
      expr = deepEvalFails (claudeCfg { allowHeadlessBrowsers = [ "safari" ]; }).allowHeadlessBrowsers;
      expected = true;
    };

    # Both published-port forms reduce to the long form.
    testNormalizeBarePort = {
      expr = sandbox.normalizePublishedPort 3000;
      expected = {
        port = 3000;
        bindAddr = "127.0.0.1";
      };
    };
    testNormalizeLongPort = {
      expr = sandbox.normalizePublishedPort {
        port = 3000;
        bindAddr = "0.0.0.0";
      };
      expected = {
        port = 3000;
        bindAddr = "0.0.0.0";
      };
    };
  };

  vmTests = {
    # A $HOME path maps to the home of the guest user. An absolute path
    # maps to itself. Any other path is a build-time error.
    testTranslateHomePath = {
      expr = vm.translatePath "$HOME/.claude";
      expected = "${vm.guestHome}/.claude";
    };
    testTranslateAbsolutePath = {
      expr = vm.translatePath "/etc/agent";
      expected = "/etc/agent";
    };
    testTranslateRejectsOtherVariables = {
      expr = evalFails (vm.translatePath "$XDG_CONFIG_HOME/agent");
      expected = true;
    };
    testTranslateRejectsRelativePath = {
      expr = evalFails (vm.translatePath "relative/path");
      expected = true;
    };

    # A directory mounts at its translated guest path. A file mounts as
    # a read-only share of its parent directory, and the guest copies
    # the file into place at boot.
    testDirectoryShare = {
      expr = vm.sandboxShares agents.claude (claudeCfg { });
      expected = [
        {
          tag = "sbx0";
          hostPath = "$HOME/.claude";
          guestPath = "${vm.guestHome}/.claude";
          readOnly = false;
          copyTo = null;
          fileName = null;
        }
      ];
    };
    testFileShare = {
      expr = builtins.elemAt (vm.sandboxShares agents.claude (claudeCfg {
        extraRoFiles = [ "$HOME/.config/git/config" ];
      })) 1;
      expected = {
        tag = "sbx1";
        hostPath = "$HOME/.config/git";
        guestPath = "/run/agent-sandbox/sbx1";
        readOnly = true;
        copyTo = "${vm.guestHome}/.config/git/config";
        fileName = "config";
      };
    };
    testReadOnlyDirectoryShare = {
      expr = (builtins.elemAt (vm.sandboxShares agents.claude (claudeCfg {
        extraRoDirs = [ "/srv/data" ];
      })) 1).readOnly;
      expected = true;
    };

    # qemu forwards to the guest address on the SLiRP link, never to
    # guest 127.0.0.1, so the sandbox inside the guest binds 0.0.0.0.
    testGuestPublishedPortsBindAllAddresses = {
      expr = vm.guestPublishedPorts [
        {
          port = 3000;
          bindAddr = "127.0.0.1";
        }
      ];
      expected = [
        {
          port = 3000;
          bindAddr = "0.0.0.0";
        }
      ];
    };
  };
in
{
  checks = {
    eval-overlays = mkEvalCheck "eval-overlays" overlayTests;
    eval-sandbox = mkEvalCheck "eval-sandbox" sandboxTests;

    # The sandbox over a stub agent. It proves that `package`
    # overrides the vendored default, and that `extend` adds to a
    # built sandbox. It downloads no agent release.
    sandbox-override = mkSandboxCheck {
      name = "sandbox-override";
      binName = "claude";
      drv = (sandbox.mkAgentSandbox agents.claude { }).extend {
        package = stubClaude;
        allowedDomains = domains.agentDomains // {
          "crates.io" = "*";
          "buzz.example" = {
            methods = [ "GET" ];
            paths = [
              "/buzz/agent/mcp/fable"
              "/buzz/agent/mcp/fable/*"
            ];
          };
        };
        extraPackages = [ pkgs.hello ];
        extraRwDirs = [ "$HOME/.cargo" ];
        extraEnv = {
          CARGO_HOME = "$HOME/.cargo";
        };
      };
      assertions = ''
        # The overriding package wins over the agent default.
        spec_is '.sandboxed_binary == "${stubClaude}/bin/claude"'
        # extraPackages reach the sandbox PATH.
        spec_is '.sandbox_path | contains("${pkgs.hello}/bin")'
        # extraRwDirs append onto the agent defaults.
        spec_is '.rw_dirs == ["$HOME/.claude","$HOME/.cargo"]'
        # extraEnv merges onto the agent env.
        spec_is '.env_keys | index("CARGO_HOME")'
        spec_is '.env_keys | index("CLAUDE_CODE_OAUTH_TOKEN")'
        # The base domains of the agent merge over allowedDomains.
        allowlist_is '.["crates.io"] == "*"'
        allowlist_is '.["anthropic.com"] == "*"'
        # A path rule reaches the proxy as an object with two keys only.
        allowlist_is '.["buzz.example"] == {"methods":["GET"],"paths":["/buzz/agent/mcp/fable","/buzz/agent/mcp/fable/*"]}'
        ${githubAllowlistAssertions}
      '';
    };

    sandbox-claude = mkSandboxCheck {
      name = "sandbox-claude";
      binName = "claude";
      drv = sandbox.mkAgentSandbox agents.claude { };
      assertions = ''
        spec_is '.sandboxed_binary == "${pkgs.claude-code}/bin/claude"'
        spec_is '.rw_dirs == ["$HOME/.claude"]'
        spec_is '.env_keys == ["CLAUDE_CODE_OAUTH_TOKEN","CLAUDE_CONFIG_DIR","GITHUB_TOKEN"]'
        spec_is '.allow_nix == false'
        spec_is '.allow_unix_sockets == false'
        spec_is '.allowed_host_ports == []'
        spec_is '.published_ports == []'
        allowlist_is '.["anthropic.com"] == "*"'
        allowlist_is '.["claude.com"] == "*"'
        ${githubAllowlistAssertions}
      '';
    };

    sandbox-opencode = mkSandboxCheck {
      name = "sandbox-opencode";
      binName = "opencode";
      drv = sandbox.mkAgentSandbox agents.opencode { };
      assertions = ''
        spec_is '.sandboxed_binary == "${pkgs.opencode}/bin/opencode"'
        spec_is '.rw_dirs == ["$HOME/.config/opencode","$HOME/.local/share/opencode","$HOME/.local/state/opencode"]'
        spec_is '.env_keys == ["OPENCODE_DISABLE_MODELS_FETCH"]'
        allowlist_is '.["anthropic.com"] == "*"'
        ${githubAllowlistAssertions}
      '';
    };

    sandbox-codex = mkSandboxCheck {
      name = "sandbox-codex";
      binName = "codex";
      drv = sandbox.mkAgentSandbox agents.codex { };
      assertions = ''
        spec_is '.sandboxed_binary == "${pkgs.codex}/bin/codex"'
        spec_is '.rw_dirs == ["$HOME/.codex"]'
        spec_is '.env_keys == ["CODEX_HOME","GITHUB_TOKEN","OPENAI_API_KEY"]'
        allowlist_is '.["openai.com"] == "*"'
        allowlist_is '.["chatgpt.com"] == "*"'
        # The codex allowlist carries no Anthropic domain.
        allowlist_is 'has("anthropic.com") == false'
        ${githubAllowlistAssertions}
      '';
    };

    sandbox-antigravity = mkSandboxCheck {
      name = "sandbox-antigravity";
      binName = "agy";
      drv = sandbox.mkAgentSandbox agents.antigravity { };
      assertions = ''
        spec_is '.sandboxed_binary == "${pkgs.antigravity-cli}/bin/agy"'
        spec_is '.rw_dirs == ["$HOME/.gemini"]'
        spec_is '.env_keys == ["GEMINI_API_KEY","GITHUB_TOKEN"]'
        allowlist_is '.["googleapis.com"] == "*"'
        allowlist_is '.["accounts.google.com"] == "*"'
        allowlist_is '.["antigravity.google"] == "*"'
        allowlist_is '.["lh3.googleusercontent.com"] == ["GET","HEAD"]'
        # The antigravity allowlist carries no Anthropic or OpenAI domain.
        allowlist_is 'has("anthropic.com") == false'
        allowlist_is 'has("openai.com") == false'
        ${githubAllowlistAssertions}
      '';
    };
  }
  // lib.optionalAttrs isLinux {
    eval-vm = mkEvalCheck "eval-vm" vmTests;
    vm-claude = mkInstantiateCheck "vm-claude" (vm.mkAgentVm agents.claude { });
    vm-opencode = mkInstantiateCheck "vm-opencode" (vm.mkAgentVm agents.opencode { });
    vm-codex = mkInstantiateCheck "vm-codex" (vm.mkAgentVm agents.codex { });
    vm-antigravity = mkInstantiateCheck "vm-antigravity" (vm.mkAgentVm agents.antigravity { });
  };
}
