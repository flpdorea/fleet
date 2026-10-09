{
  description = "fleet: firstmate + headless Orca on a NixOS VPS";

  nixConfig = {
    extra-substituters = [ "https://cache.numtide.com" ];
    extra-trusted-public-keys = [ "niks3.numtide.com-1:DTx8wZduET09hRmMtKdQDxNNthLQETkc/yaX7M4qK0g=" ];
  };

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    # Orca, Pi and Claude Code, packaged and updated daily by numtide.
    # No "follows": that way the binaries come prebuilt from their cache.
    llm-agents.url = "github:numtide/llm-agents.nix";
    # firstmate is cloned per user at the commit pinned in flake.lock.
    firstmate = {
      url = "github:kunchenguid/firstmate";
      flake = false;
    };
  };

  outputs =
    { self, nixpkgs, llm-agents, firstmate, ... }:
    {
      nixosModules.default = import ./nix/module.nix { inherit self llm-agents firstmate; };

      # Minimal machine used only by CI to evaluate the module without a real VPS.
      nixosConfigurations.ci = nixpkgs.lib.nixosSystem {
        modules = [
          self.nixosModules.default
          {
            nixpkgs.hostPlatform = "x86_64-linux";
            fleet.enable = true;
            fleet.authorizedKeys = [ "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA ci" ];
            boot.loader.grub.devices = [ "nodev" ];
            fileSystems."/" = { device = "/dev/vda1"; fsType = "ext4"; };
            system.stateVersion = "26.05";
          }
        ];
      };
    };
}
