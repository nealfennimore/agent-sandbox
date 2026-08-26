# NixOS configuration for an agent microVM guest. The netns/proxy sandbox
# runs inside the guest, so the egress allowlist still applies. The VM
# adds a hardware isolation boundary on top.
{
  name, # agent binName, used for the hostname and home image
  agentPackage, # the sandboxed wrapper package to install in the guest
  cfg, # evaluated vmModule config
  sandboxShares, # share specs computed by nix/vm.nix sandboxShares
  guestUser,
}:
{ lib, pkgs, ... }:
let
  dirShares = lib.filter (s: s.copyTo == null) sandboxShares;
  fileShares = lib.filter (s: s.copyTo != null) sandboxShares;

  # pasta refuses to run as root: it drops to nobody and then cannot
  # set up its user and network namespaces. Launch the sandbox inside
  # a user namespace that maps root to an unprivileged uid. pasta then
  # takes its normal unprivileged path. Kernel permission checks still
  # use the real root credentials, so the root-mapped 9p shares stay
  # accessible, and they appear owned by the mapped uid inside.
  agentLauncher = pkgs.writeShellScriptBin name ''
    exec ${pkgs.util-linux}/bin/unshare --user --map-user=1000 --map-group=100 \
      ${agentPackage}/bin/${name} "$@"
  '';

  # Emitted by the host at launch time, so $HOME in a share source
  # expands to the invoking user's home. The output is appended to the
  # qemu command unescaped by the microvm runner. The static shares
  # below force qemu onto a PCI machine, so the device type is
  # virtio-9p-pci.
  shareArgsScript = pkgs.writeShellScript "${name}-vm-share-args" ''
    printf '%s ' ${
      lib.concatMapStringsSep " " (
        s:
        ''-fsdev "local,id=${s.tag},path=${s.hostPath},security_model=none,readonly=${
          if s.readOnly then "on" else "off"
        }" -device "virtio-9p-pci,fsdev=${s.tag},mount_tag=${s.tag}"''
      ) sandboxShares
    }
  '';
in
{
  system.stateVersion = lib.trivial.release;
  networking.hostName = "${name}-vm";

  # The guest agent runs as root. Unprivileged 9p presents the host
  # user's files as root inside the guest, so guest root is the peer of
  # the host user that launched the VM: its writes execute host-side as
  # that user, and host file ownership stays unchanged.
  services.getty.autologinUser = guestUser;
  # The VM is serial-console only (-nographic): a getty on the virtual
  # console would autologin too, run the kiosk with no real terminal,
  # fail, and power the VM off from under the serial session.
  systemd.services."getty@tty1".enable = false;
  systemd.services."autovt@tty1".enable = false;
  # Kiosk console: surface share warnings, then launch the agent in
  # the shared workspace. When the agent exits, the VM powers off —
  # the guest is not meant to be explored interactively. Gate on the
  # serial console so no other login path can trigger the kiosk.
  environment.loginShellInit = ''
    case "$(tty)" in /dev/ttyS0 | /dev/ttyAMA0 | /dev/hvc0) kiosk=1 ;; *) kiosk= ;; esac
    if [ -n "$kiosk" ]; then
      if [ -s /run/agent-sandbox/warnings ]; then
        cat /run/agent-sandbox/warnings
      fi
      cd /workspace 2>/dev/null || true
      ${agentLauncher}/bin/${name}
      echo "${name} exited; powering off"
      poweroff
    fi
  '';

  # Install only the shim-wrapped, sandboxed agent. Never install the
  # raw agent package: the VM alone does not protect the workspace (the
  # full directory, including .git, mounts read-write). The inner
  # sandbox provides the read-only binds on git metadata and the
  # egress allowlist. The 9p shares are policy plumbing, not the
  # isolation boundary — the qemu boundary is.
  environment.systemPackages = [ agentLauncher ];

  # pasta opens /dev/net/tun inside the sandbox network namespace.
  boot.kernelModules = [ "tun" ];

  # Sandbox-declared paths, shared from the host. The matching
  # -fsdev/-device arguments come from microvm.extraArgsScript below.
  # For /workspace, microvm.nix hardcodes msize=65536; 9p round trips
  # dominate bulk I/O there, so force a larger buffer. The kernel
  # clamps msize to the transport maximum when needed.
  fileSystems = {
    "/workspace".options = lib.mkForce [
      "trans=virtio"
      "version=9p2000.L"
      "msize=1048576"
      "cache=mmap"
      "x-systemd.after=systemd-modules-load.service"
    ];
  }
  // lib.listToAttrs (
    map (s: {
      name = s.guestPath;
      value = {
        device = s.tag;
        fsType = "9p";
        options = [
          "trans=virtio"
          "version=9p2000.L"
          "msize=1048576"
          # SQLite WAL databases (for example the codex state DB in
          # $HOME/.codex) need shared writable mmap, which 9p only
          # provides with cache=mmap. Without it SQLite fails with
          # SQLITE_IOERR_SHMMAP, reported as "disk I/O error".
          "cache=mmap"
          "nofail"
          "x-systemd.after=systemd-modules-load.service"
        ]
        ++ lib.optional s.readOnly "ro";
      };
    }) sandboxShares
  );

  # Verify the share mounts and stage the declared files. The mounts
  # are nofail, so a failed attach degrades silently at the fs layer;
  # this service records a warning that the login shell prints, which
  # turns "confusing runtime symptom" into a visible boot message.
  #
  # Files cannot be shared over 9p individually. The parent directory
  # is staged read-only under /run/agent-sandbox and the file is
  # copied into place at boot. Writes inside the guest do not
  # propagate back.
  systemd.services.agent-sandbox-shares = lib.mkIf (sandboxShares != [ ]) {
    description = "Verify sandbox shares and stage declared files";
    wantedBy = [ "multi-user.target" ];
    after = [ "local-fs.target" ];
    # Warnings must be written and files staged before the console
    # logs in and launches the agent. Ordering against a getty unit
    # that does not exist on this arch is ignored, so list both.
    before = [
      "serial-getty@ttyS0.service"
      "serial-getty@ttyAMA0.service"
    ];
    path = [ pkgs.util-linux ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script =
      ''
        mkdir -p /run/agent-sandbox
        warn() {
          echo "agent-sandbox: WARNING: $*" >> /run/agent-sandbox/warnings
        }
      ''
      + lib.concatMapStrings (s: ''
        mountpoint -q ${lib.escapeShellArg s.guestPath} \
          || warn ${lib.escapeShellArg "share ${s.tag} (host ${s.hostPath}) is not mounted at ${s.guestPath}"}
      '') dirShares
      + lib.concatMapStrings (s: ''
        if [ -e ${lib.escapeShellArg "${s.guestPath}/${s.fileName}"} ]; then
          install -d -m 755 ${lib.escapeShellArg (dirOf s.copyTo)}
          install -m 600 \
            ${lib.escapeShellArg "${s.guestPath}/${s.fileName}"} \
            ${lib.escapeShellArg s.copyTo}
        else
          warn ${lib.escapeShellArg "declared file ${s.hostPath}/${s.fileName} did not arrive in its staging share; ${s.copyTo} is absent"}
        fi
      '') fileShares;
  };

  microvm = {
    hypervisor = "qemu";
    inherit (cfg) vcpu mem;
    # Create missing host-side share sources before the VM starts, so
    # qemu does not fail on a first run.
    preStart = lib.concatMapStrings (s: ''
      mkdir -p "${s.hostPath}"
    '') sandboxShares;
    # Attach the sandbox shares at runtime, when $HOME is known.
    extraArgsScript = if sandboxShares != [ ] then "${shareArgsScript}" else null;
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
        source = cfg.workspace;
        mountPoint = "/workspace";
        proto = "9p";
      }
    ];
  };
}
