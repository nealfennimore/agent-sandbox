# NixOS configuration for an agent microVM guest. The netns/proxy sandbox
# runs inside the guest, so the egress allowlist still applies. The VM
# adds a hardware isolation boundary on top.
{
  name, # agent binName, used for the hostname and home image
  agentPackage, # the sandboxed wrapper package to install in the guest
  cfg, # evaluated vmModule config (vcpu, mem, workspace, homeImageSize)
}:
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

  environment.systemPackages = [ agentPackage ];

  microvm = {
    hypervisor = "qemu";
    inherit (cfg) vcpu mem;
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
    # Persist /home (agent credentials, caches) across boots.
    volumes = [
      {
        image = "${name}-vm-home.img";
        mountPoint = "/home";
        size = cfg.homeImageSize;
      }
    ];
  };
}
