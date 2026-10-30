{
  description = "fleet: headless Orca and its orchestration skills on a NixOS VPS";

  nixConfig = {
    extra-substituters = [ "https://cache.numtide.com" ];
    extra-trusted-public-keys = [ "niks3.numtide.com-1:DTx8wZduET09hRmMtKdQDxNNthLQETkc/yaX7M4qK0g=" ];
  };

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    # Orca, Pi and Claude Code, packaged and updated daily by numtide.
    # No "follows": that way the binaries come prebuilt from their cache.
    llm-agents.url = "github:numtide/llm-agents.nix";
    # Anthropic's public skills; fleet installs skill-creator from it.
    anthropic-skills = {
      url = "github:anthropics/skills";
      flake = false;
    };
    # Lavish, the browser editor for HTML artifacts; fleet installs its skill.
    lavish-axi = {
      url = "github:kunchenguid/lavish-axi";
      flake = false;
    };
  };

  outputs =
    { self, nixpkgs, llm-agents, anthropic-skills, lavish-axi, ... }:
    {
      nixosModules.default = import ./nix/module.nix { inherit self llm-agents anthropic-skills lavish-axi; };

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
