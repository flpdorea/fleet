{ self, llm-agents, anthropic-skills, lavish-axi }:
{ config, lib, pkgs, ... }:

let
  cfg = config.fleet;
  agents = llm-agents.packages.${pkgs.stdenv.hostPlatform.system};
  allContexts = import ../homes/contexts.nix;
  contexts = lib.getAttrs cfg.contexts allContexts;
  forContexts = f: lib.mkMerge (lib.mapAttrsToList f contexts);

  primaryPkg = { pi = agents.pi; claude = agents.claude-code; };

  # Day-to-day command: login | pair | status for context users, the service
  # commands for both, rebuild for root, and a help message when run without
  # arguments.
  fleetCli = pkgs.writeShellApplication {
    name = "fleet";
    runtimeInputs = (with pkgs; [ coreutils gnugrep gnused jq git gh nix curl systemd ])
      ++ [ config.system.build.nixos-rebuild ];
    text = builtins.readFile ./fleet.sh;
  };

  # Claude Code hooks that notify the phone (homes/claude-settings.json).
  claudeHook = pkgs.writeShellApplication {
    name = "fleet-claude-hook";
    runtimeInputs = (with pkgs; [ coreutils findutils gnugrep gnused util-linux jq git gh ]) ++ [ fleetCli ];
    text = builtins.readFile ./claude-hook.sh;
  };

  # Notifies the phone when a pull request is ready to merge (fleet-pr-ready-<ctx>).
  prReady = pkgs.writeShellApplication {
    name = "fleet-pr-ready";
    runtimeInputs = (with pkgs; [ coreutils gnugrep gh ]) ++ [ fleetCli ];
    text = builtins.readFile ./pr-ready.sh;
  };

  # Starts an agent for each new /agent comment of yours on an issue
  # (fleet-agent-comments-<ctx>).
  agentComments = pkgs.writeShellApplication {
    name = "fleet-agent-comments";
    runtimeInputs = (with pkgs; [ coreutils gnugrep gnused jq gh ]) ++ [ agents.orca ];
    text = builtins.readFile ./agent-comments.sh;
  };

  setupScript = pkgs.writeShellApplication {
    name = "fleet-setup-user";
    runtimeInputs = (with pkgs; [ coreutils gnused gnugrep jq procps git gh bash nodejs_22 mise ]) ++ [ agents.orca agents.claude-code ];
    text = builtins.readFile ./setup-user.sh;
  };

  # Skills installed globally for Claude Code contexts: ours (homes/skills),
  # Anthropic's skill-creator and Lavish's skill, pinned by their inputs.
  claudeSkills = pkgs.runCommand "fleet-claude-skills" { } ''
    mkdir -p $out
    cp -r ${../homes/skills}/. $out/
    cp -r ${anthropic-skills}/skills/skill-creator $out/
    cp -r ${lavish-axi}/skills/lavish $out/
  '';

  # The units `fleet start|stop|restart|run` acts on, which a context user may
  # manage for its own context only (the polkit rule below). Each runs as
  # that user, so this grants nothing it could not do to its own processes.
  ctxUnits = ctx: [
    "orca-serve-${ctx}.service"
    "fleet-setup-${ctx}.service"
    "fleet-pr-ready-${ctx}.service"
    "fleet-pr-ready-${ctx}.timer"
    "fleet-agent-comments-${ctx}.service"
    "fleet-agent-comments-${ctx}.timer"
  ];

  # The ntfy server that pushes notifications to the phone.
  ntfyPort = 2586;

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

    ntfyBaseUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://fleet:${toString ntfyPort}";
      example = "http://fleet.tail1234.ts.net:${toString ntfyPort}";
      description = "Address the phone uses to reach the ntfy server, through the tailnet.";
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
      # Push notifications to the phone: one ntfy topic per context, named
      # with a secret only that user and the phone know (~/fleet/.ntfy-topic),
      # which `fleet notify` publishes to. Like Orca's, the port is not in
      # allowedTCPPorts, so only the tailnet reaches it. No attachments: no
      # one can fill the disk through it.
      services.ntfy-sh = {
        enable = true;
        settings = {
          base-url = cfg.ntfyBaseUrl;
          listen-http = ":${toString ntfyPort}";
          attachment-cache-dir = "";
        };
      };
      networking.firewall = {
        enable = true;
        allowedTCPPorts = [ 22 ];
        trustedInterfaces = [ "tailscale0" ];
      };

      # Agents install tools that have no Nix package (npm and release binaries);
      # nix-ld lets those generic Linux binaries run on NixOS.
      programs.nix-ld.enable = true;

      # Containers for agents: rootless Docker, one daemon per context user
      # (a systemd user service). Joining the docker group of a rootful daemon
      # would amount to root and let one context read the other's files.
      # Published ports are ordinary user sockets, so the firewall still applies.
      virtualisation.docker.rootless = {
        enable = true;
        setSocketVariable = true;
      };

      # Cloud images (Contabo's Ubuntu among them) leave an EFI partition on
      # the disk even though the machine boots GRUB from BIOS. systemd's
      # gpt-auto generator then tries to mount it on /boot, fails, and leaves
      # /boot dead: dbus-broker cannot set up its sandbox and GRUB cannot
      # write its menu, so nixos-rebuild can neither activate nor install.
      boot.kernelParams = [ "systemd.gpt_auto=0" ];

      environment.systemPackages =
        (with pkgs; [ git gh tmux jq curl nodejs_22 mise gcc gnumake pkg-config ])
        # agent-browser: headless browser for agents (visual-validation skill),
        # wrapped with its own Nix Chromium.
        ++ [ agents.orca agents.agent-browser fleetCli claudeHook ]
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
      environment.etc."fleet/ntfy-url".text = "http://127.0.0.1:${toString ntfyPort}";
      environment.etc."fleet/ntfy-base-url".text = cfg.ntfyBaseUrl;

      # Lets each context user start, stop and restart its own context's
      # units (ctxUnits) without sudo, through `fleet`. Nothing else.
      security.polkit.enable = true;
      security.polkit.extraConfig = lib.concatMapStrings (ctx: ''
        polkit.addRule(function (action, subject) {
          if (action.id == "org.freedesktop.systemd1.manage-units" &&
              subject.user == ${builtins.toJSON ctx} &&
              ${builtins.toJSON (ctxUnits ctx)}.indexOf(action.lookup("unit")) >= 0 &&
              ["start", "stop", "restart"].indexOf(action.lookup("verb")) >= 0) {
            return polkit.Result.YES;
          }
        });
      '') (builtins.attrNames contexts);

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
          # Starts the user's systemd manager at boot, and with it the
          # rootless Docker daemon, without anyone logging in.
          linger = true;
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
          #   fleet restart orca
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
            # The user's rootless Docker daemon. Login shells get this from
            # setSocketVariable; this service has no XDG_RUNTIME_DIR.
            export DOCKER_HOST="unix:///run/user/$(id -u)/docker.sock"
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

        # Polls GitHub for the context's pull requests that are ready to
        # merge and notifies the phone (nix/pr-ready.sh).
        "fleet-pr-ready-${ctx}" = {
          description = "fleet: notify ${ctx}'s pull requests ready to merge";
          wants = [ "network-online.target" ];
          after = [ "network-online.target" "fleet-setup-${ctx}.service" ];
          serviceConfig = {
            Type = "oneshot";
            User = ctx;
            ExecStart = lib.getExe prReady;
          };
        };

        # Polls GitHub for new /agent comments of the user on issues of the
        # repos in the context's Orca, and starts an agent in a new worktree
        # for each (nix/agent-comments.sh). Polling keeps everything on the
        # VPS: no inbound path from GitHub, no new port.
        "fleet-agent-comments-${ctx}" = {
          description = "fleet: start ${ctx}'s agents from /agent comments";
          wants = [ "network-online.target" ];
          after = [ "network-online.target" "orca-serve-${ctx}.service" ];
          environment = {
            FLEET_CONTEXT = ctx;
            FLEET_PRIMARY = c.primary;
          };
          serviceConfig = {
            Type = "oneshot";
            User = ctx;
            ExecStart = lib.getExe agentComments;
          };
        };
      });

      systemd.timers = forContexts (ctx: _: {
        "fleet-pr-ready-${ctx}" = {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnBootSec = "5min";
            OnUnitActiveSec = "5min";
          };
        };
        "fleet-agent-comments-${ctx}" = {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnBootSec = "2min";
            OnUnitActiveSec = "1min";
          };
        };
      });
    }
  ]);
}
