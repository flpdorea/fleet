{ self, llm-agents, anthropic-skills }:
{ config, lib, pkgs, ... }:

let
  cfg = config.fleet;
  agents = llm-agents.packages.${pkgs.stdenv.hostPlatform.system};
  allContexts = import ../homes/contexts.nix;
  contexts = lib.getAttrs cfg.contexts allContexts;
  forContexts = f: lib.mkMerge (lib.mapAttrsToList f contexts);

  primaryPkg = { pi = agents.pi; claude = agents.claude-code; };

  # Day-to-day command: login | pair | status for context users, rebuild for
  # root, and a help message when run without arguments.
  fleetCli = pkgs.writeShellApplication {
    name = "fleet";
    runtimeInputs = (with pkgs; [ coreutils gnugrep gnused jq git gh nix ])
      ++ [ config.system.build.nixos-rebuild ];
    text = builtins.readFile ./fleet.sh;
  };

  setupScript = pkgs.writeShellApplication {
    name = "fleet-setup-user";
    runtimeInputs = (with pkgs; [ coreutils gnused gnugrep jq procps git bash nodejs_22 mise ]) ++ [ agents.orca ];
    text = builtins.readFile ./setup-user.sh;
  };

  # Skills installed globally for Claude Code contexts: ours (homes/skills)
  # and Anthropic's skill-creator, pinned by the anthropic-skills input.
  claudeSkills = pkgs.runCommand "fleet-claude-skills" { } ''
    mkdir -p $out
    cp -r ${../homes/skills}/. $out/
    cp -r ${anthropic-skills}/skills/skill-creator $out/
  '';

  # mise shims come first so project and default runtimes win over nodejs_22.
  userPath = ctx: "/home/${ctx}/.local/share/mise/shims:/home/${ctx}/.local/bin:/home/${ctx}/.npm-global/bin:/run/wrappers/bin:/run/current-system/sw/bin";
in
{
  options.fleet = {
    enable = lib.mkEnableOption "fleet (headless Orca + its orchestration skills)";

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

      # Agents install tools that have no Nix package (npm and release binaries);
      # nix-ld lets those generic Linux binaries run on NixOS.
      programs.nix-ld.enable = true;

      # Cloud images (Contabo's Ubuntu among them) leave an EFI partition on
      # the disk even though the machine boots GRUB from BIOS. systemd's
      # gpt-auto generator then tries to mount it on /boot, fails, and leaves
      # /boot dead: dbus-broker cannot set up its sandbox and GRUB cannot
      # write its menu, so nixos-rebuild can neither activate nor install.
      boot.kernelParams = [ "systemd.gpt_auto=0" ];

      environment.systemPackages =
        (with pkgs; [ git gh tmux jq curl nodejs_22 mise gcc gnumake pkg-config ])
        ++ [ agents.orca fleetCli ]
        ++ lib.unique (lib.mapAttrsToList (_: c: primaryPkg.${c.primary}) contexts);

      # Per-user PATH (mise shims first) and global npm prefix, no sudo needed.
      environment.extraInit = ''
        export PATH="$HOME/.local/share/mise/shims:$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"
        export NPM_CONFIG_PREFIX="$HOME/.npm-global"
      '';

      # Language runtimes: mise, configured system-wide (homes/mise.toml) and
      # installed per user by fleet-setup-<ctx>. gcc and make are for native
      # extensions and for linking Rust.
      environment.etc."mise/config.toml".source = ../homes/mise.toml;

      environment.etc."fleet/contexts.json".text = builtins.toJSON contexts;

      systemd.tmpfiles.rules = [
        "d /var/log/fleet 0711 root root -"
        # Shared by every context's Xvfb; sticky so no user can remove another's socket.
        "d /tmp/.X11-unix 1777 root root -"
      ];
    }

    # The attribute names at this level must not depend on cfg: the module
    # system reads them to find which options are defined, before cfg exists.
    # So the per-context loop goes inside each option's value.
    {
      users.users = forContexts (ctx: _: {
        ${ctx} = {
          isNormalUser = true;
          openssh.authorizedKeys.keys = cfg.authorizedKeys;
        };
      });

      systemd.tmpfiles.rules =
        lib.mapAttrsToList (ctx: _: "f /var/log/fleet/orca-${ctx}.log 0600 ${ctx} users -") contexts;

      systemd.services = forContexts (ctx: c: {
        # Prepares the user: installs Orca's orca-cli and orchestration skills
        # globally for the context's harness. Runs at boot and on every rebuild
        # that changes the repo or Orca, so the skills follow Orca updates.
        "fleet-setup-${ctx}" = {
          description = "fleet: prepare ${ctx}";
          wantedBy = [ "multi-user.target" ];
          wants = [ "network-online.target" ];
          after = [ "network-online.target" ];
          restartTriggers = [ agents.orca self.outPath claudeSkills ];
          environment = {
            FLEET_CONTEXT = ctx;
            FLEET_PRIMARY = c.primary;
            FLEET_CLAUDE_SETTINGS = "${../homes/claude-settings.json}";
            FLEET_CLAUDE_MD = "${../homes/CLAUDE.md}";
            FLEET_CLAUDE_SKILLS = "${claudeSkills}";
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
        "orca-serve-${ctx}" = {
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
          path = [ agents.orca pkgs.tailscale pkgs.coreutils pkgs.xvfb ];
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
            # orca-ide serve needs an X display and, without one, starts its own
            # Xvfb on the fixed display :99. Every context would then share
            # :99: a restart in one takes the other's display down, and stale
            # files left by a crash belong to one user, so the sticky /tmp
            # stops the other from taking :99 over. Each context gets its own
            # display instead (port 6768 -> :68), which Orca accepts as is.
            # Nothing else uses that number, so leftovers here are ours.
            d=${toString (c.orcaPort - 6700)}
            rm -f "/tmp/.X$d-lock" "/tmp/.X11-unix/X$d"
            Xvfb ":$d" -screen 0 1280x1024x24 -nolisten tcp &
            for _ in $(seq 50); do [ -S "/tmp/.X11-unix/X$d" ] && break; sleep 0.1; done
            [ -S "/tmp/.X11-unix/X$d" ] || { echo "Xvfb did not start on :$d" >&2; exit 1; }
            export DISPLAY=":$d"

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
      });
    }
  ]);
}
