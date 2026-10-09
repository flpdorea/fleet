{ self, llm-agents, firstmate }:
{ config, lib, pkgs, ... }:

let
  cfg = config.fleet;
  agents = llm-agents.packages.${pkgs.stdenv.hostPlatform.system};
  allContexts = import ../homes/contexts.nix;
  contexts = lib.getAttrs cfg.contexts allContexts;
  forContexts = f: lib.mkMerge (lib.mapAttrsToList f contexts);

  primaryPkg = { pi = agents.pi; claude = agents.claude-code; };

  # Day-to-day command for each context user: fleet | login | pair | status
  fleetCli = pkgs.writeShellApplication {
    name = "fleet";
    runtimeInputs = with pkgs; [ coreutils gnugrep gnused jq tmux git gh ];
    text = builtins.readFile ./fleet.sh;
  };

  # For root: pull the latest version of this repo and apply it.
  fleetRebuild = pkgs.writeShellApplication {
    name = "fleet-rebuild";
    runtimeInputs = [ config.system.build.nixos-rebuild pkgs.nix pkgs.git ];
    text = ''
      [ "$(id -u)" -eq 0 ] || { echo "fleet-rebuild: run as root" >&2; exit 1; }
      nix flake update fleet --flake /etc/nixos
      exec nixos-rebuild switch --flake /etc/nixos#fleet "$@"
    '';
  };

  setupScript = pkgs.writeShellApplication {
    name = "fleet-setup-user";
    runtimeInputs = with pkgs; [ coreutils gnugrep gnused git gh jq curl bash nodejs_22 ];
    text = builtins.readFile ./setup-user.sh;
  };

  userPath = ctx: "/home/${ctx}/.local/bin:/home/${ctx}/.npm-global/bin:/run/wrappers/bin:/run/current-system/sw/bin";
in
{
  options.fleet = {
    enable = lib.mkEnableOption "fleet (firstmate + headless Orca)";

    contexts = lib.mkOption {
      type = lib.types.listOf (lib.types.enum (builtins.attrNames allContexts));
      default = builtins.attrNames allContexts;
      description = "Contexts to create on this machine.";
    };

    authorizedKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "SSH public keys accepted for the context users.";
    };

    tailscaleAuthKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "File holding a Tailscale auth key (kept outside the Nix store).";
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      nix.settings = {
        experimental-features = [ "nix-command" "flakes" ];
        extra-substituters = [ "https://cache.numtide.com" ];
        extra-trusted-public-keys = [ "niks3.numtide.com-1:DTx8wZduET09hRmMtKdQDxNNthLQETkc/yaX7M4qK0g=" ];
      };
      nix.gc = {
        automatic = true;
        dates = "weekly";
        options = "--delete-older-than 14d";
      };
      nixpkgs.config.allowUnfree = true;

      # Only SSH is open to the internet; Orca is reachable through the tailnet only.
      services.openssh = {
        enable = true;
        settings.PasswordAuthentication = false;
        settings.KbdInteractiveAuthentication = false;
      };
      services.tailscale = {
        enable = true;
        authKeyFile = cfg.tailscaleAuthKeyFile;
        extraUpFlags = [ "--hostname=fleet" ];
      };
      networking.firewall = {
        enable = true;
        allowedTCPPorts = [ 22 ];
        trustedInterfaces = [ "tailscale0" ];
      };

      # firstmate installs no-mistakes and the *-axi tools on its own (they have
      # no Nix package); nix-ld lets those generic Linux binaries run on NixOS.
      programs.nix-ld.enable = true;

      environment.systemPackages =
        (with pkgs; [ git gh tmux jq curl nodejs_22 ])
        ++ [ agents.orca fleetCli fleetRebuild ]
        ++ lib.unique (lib.mapAttrsToList (_: c: primaryPkg.${c.primary}) contexts);

      # Per-user PATH and global npm prefix, no sudo needed.
      environment.extraInit = ''
        export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"
        export NPM_CONFIG_PREFIX="$HOME/.npm-global"
      '';

      environment.etc."fleet/contexts.json".text = builtins.toJSON contexts;

      systemd.tmpfiles.rules = [ "d /var/log/fleet 0711 root root -" ];
    }

    (forContexts (ctx: c: {
      users.users.${ctx} = {
        isNormalUser = true;
        openssh.authorizedKeys.keys = cfg.authorizedKeys;
      };

      systemd.tmpfiles.rules = [ "f /var/log/fleet/orca-${ctx}.log 0600 ${ctx} users -" ];

      # Prepares the user's firstmate: clone at the pinned commit, config from
      # this repo, and the toolchain firstmate itself asks for. Runs at boot
      # and on every rebuild that changes the repo or the firstmate pin.
      systemd.services."fleet-setup-${ctx}" = {
        description = "fleet: prepare firstmate for ${ctx}";
        wantedBy = [ "multi-user.target" ];
        wants = [ "network-online.target" ];
        after = [ "network-online.target" ];
        restartTriggers = [ firstmate.rev self.outPath ];
        environment = {
          FLEET_CONTEXT = ctx;
          FLEET_PRIMARY = c.primary;
          FLEET_CONFIG_SRC = "${self}/homes/${ctx}/config";
          FIRSTMATE_REV = firstmate.rev;
          NPM_CONFIG_PREFIX = "/home/${ctx}/.npm-global";
        };
        path = [ setupScript ];
        script = ''
          export PATH="${userPath ctx}:$PATH"
          exec fleet-setup-user
        '';
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          User = ctx;
        };
      };

      # The context's headless Orca server. It waits for the Tailscale IP so
      # the pairing address it advertises is reachable from the tailnet only.
      systemd.services."orca-serve-${ctx}" = {
        description = "Orca server (${ctx})";
        wantedBy = [ "multi-user.target" ];
        wants = [ "network-online.target" "fleet-setup-${ctx}.service" ];
        after = [ "network-online.target" "tailscaled.service" "fleet-setup-${ctx}.service" ];
        # Restarting the server kills the workers in flight. After a rebuild
        # that updates Orca, restart it at a quiet moment:
        #   systemctl restart orca-serve-${ctx}
        restartIfChanged = false;
        environment = {
          NPM_CONFIG_PREFIX = "/home/${ctx}/.npm-global";
          LIBGL_ALWAYS_SOFTWARE = "1";
        };
        path = [ agents.orca pkgs.tailscale pkgs.coreutils ];
        script = ''
          ip=""
          for _ in $(seq 60); do
            ip=$(tailscale ip -4 2>/dev/null | head -1) && [ -n "$ip" ] && break
            sleep 5
          done
          if [ -z "$ip" ]; then
            echo "no Tailscale IP; as root, run: tailscale up" >&2
            exit 1
          fi
          # Agents inherit this PATH: the harness, git, gh and the user's own tools.
          export PATH="${userPath ctx}:$PATH"
          cd "$HOME"
          exec orca-ide serve --port ${toString c.orcaPort} --pairing-address "$ip"
        '';
        serviceConfig = {
          User = ctx;
          Restart = "on-failure";
          RestartSec = 10;
          StandardOutput = "append:/var/log/fleet/orca-${ctx}.log";
          StandardError = "append:/var/log/fleet/orca-${ctx}.log";
        };
      };
    }))
  ]);
}
