# fleet - day-to-day command on the VPS (one Linux user per context, plus root).
# Packaged by the Nix module with writeShellApplication.

usage() {
  cat <<'EOF'
fleet - coding agents on this server, run by Orca and followed from the Orca app.

Usage: fleet <command>

As a context user (personal, work):
  login     set up the git identity, GitHub and the agent's login
  pair      print the links that connect the Orca app and the ntfy app to this server
  status    show whether setup ran and whether the Orca server is ready
  notify    push a notification to the phone: <title> <message>
            [--url <link>] [--priority min|low|default|high|max]

Services (orca, setup, pr-ready, agent-comments) of your context, or as root
of every context, or of the one given with --context <ctx>:
  services           list them: state, and for pr-ready and agent-comments
                     the last and next runs
  start <service>    start it; for pr-ready and agent-comments, resume polling
  stop <service>     stop it; for pr-ready and agent-comments, pause polling
                     until the next boot or fleet rebuild
  restart <service>  restart it; restarting orca kills the agents running in
                     it, so it asks first (--force does not)
  run <service>      run pr-ready or agent-comments once, now

As root:
  rebuild   update to the latest release (or the branch it follows) and apply it
            --ref <tag|branch>  switch to another release or branch

  help      show this message
EOF
}

# Loads this user's context. Every command needs it but help, rebuild and,
# as root, the service commands.
context() {
  FLEET="$HOME/fleet"
  CTX=$(cat "$FLEET/.context" 2>/dev/null) || {
    echo "fleet: this user is not a fleet context (or its setup has not run yet)" >&2
    exit 1
  }
  PRIMARY=$(jq -r --arg c "$CTX" '.[$c].primary' /etc/fleet/contexts.json)
  PORT=$(jq -r --arg c "$CTX" '.[$c].orcaPort' /etc/fleet/contexts.json)
  LOG="/var/log/fleet/orca-$CTX.log"
}

# The services a context runs, by the names fleet takes for them.
SERVICES="orca setup pr-ready agent-comments"

# unit <ctx> <service>: the systemd unit fleet acts on for a service. The
# polled services act on their timer, so stopping one pauses the polling.
unit() {
  case "$2" in
    orca)  echo "orca-serve-$1.service" ;;
    setup) echo "fleet-setup-$1.service" ;;
    pr-ready|agent-comments) echo "fleet-$2-$1.timer" ;;
    *) echo "fleet: unknown service: $2 (one of: $SERVICES)" >&2; return 1 ;;
  esac
}

# Parses the arguments of the service commands into SVC, FORCE and CTXS, the
# contexts to act on: the user's own; as root, the one given with --context,
# or else every context.
targets() {
  local ctx=""
  SVC="" FORCE=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --context) ctx=${2:?usage: --context <ctx>}; shift 2 ;;
      --force)   FORCE=1; shift ;;
      -*) echo "fleet: unknown option: $1" >&2; exit 1 ;;
      *)
        [ -z "$SVC" ] || { echo "fleet: unexpected argument: $1" >&2; exit 1; }
        SVC=$1; shift ;;
    esac
  done
  if [ "$(id -u)" -eq 0 ]; then
    if [ -n "$ctx" ]; then
      jq -e --arg c "$ctx" 'has($c)' /etc/fleet/contexts.json >/dev/null ||
        { echo "fleet: no context $ctx on this machine" >&2; exit 1; }
      CTXS=("$ctx")
    else
      mapfile -t CTXS < <(jq -r 'keys[]' /etc/fleet/contexts.json)
    fi
  else
    context
    [ -z "$ctx" ] || [ "$ctx" = "$CTX" ] ||
      { echo "fleet: as $CTX, you can only manage $CTX's services" >&2; exit 1; }
    CTXS=("$CTX")
  fi
}

# Lists each target context's services: whether they run and since when, and
# for the polled ones how the last run went and when the next one is.
services() {
  local ctx svc u state detail job last next
  printf '%-10s %-15s %-8s %s\n' CONTEXT SERVICE STATE DETAIL
  for ctx in "${CTXS[@]}"; do
    for svc in $SERVICES; do
      u=$(unit "$ctx" "$svc")
      state=$(systemctl show -P ActiveState "$u")
      case "$u" in
        *.timer)
          job="${u%.timer}.service"
          if [ "$(systemctl show -P ActiveState "$job")" = activating ]; then state=running
          elif [ "$state" = active ]; then state=polling
          else state=paused; fi
          last=$(systemctl show -P LastTriggerUSec "$u")
          next=$(systemctl list-timers --all --output=json "$u" | jq -r '.[0].next // 0')
          if [ -n "$last" ]; then detail="last $last ($(systemctl show -P Result "$job"))"
          else detail="never ran"; fi
          [ "$next" -eq 0 ] || detail+=", next $(date -d "@$((next / 1000000))" '+%a %F %T %Z')"
          ;;
        *)
          detail="$(systemctl show -P SubState "$u") since $(systemctl show -P StateChangeTimestamp "$u")"
          ;;
      esac
      printf '%-10s %-15s %-8s %s\n' "$ctx" "$svc" "$state" "$detail"
    done
  done
}

# manage <start|stop|restart> <service>: acts on the service's unit in each
# target context. A context user may do it for its own units only, which
# polkit allows (nix/module.nix).
manage() {
  local verb=$1 ctx answer
  shift
  targets "$@"
  [ -n "$SVC" ] || { echo "usage: fleet $verb <service> (one of: $SERVICES)" >&2; exit 1; }
  unit "${CTXS[0]}" "$SVC" >/dev/null
  if [ "$SVC" = orca ] && [ "$verb" != start ] && [ -z "$FORCE" ]; then
    echo "fleet: this kills the agents running in the Orca server of: ${CTXS[*]}"
    read -r -p "Go on? [y/N] " answer || answer=
    [ "$answer" = y ] || { echo "fleet: nothing done (--force skips this question)" >&2; exit 1; }
  fi
  # A failure in one context does not skip the others.
  local status=0
  for ctx in "${CTXS[@]}"; do
    echo "fleet: $verb $(unit "$ctx" "$SVC")"
    systemctl "$verb" "$(unit "$ctx" "$SVC")" || status=1
  done
  return "$status"
}

# run <service>: runs a polled service once, now, and waits for it to end.
run() {
  local ctx job
  targets "$@"
  case "$SVC" in
    pr-ready|agent-comments) ;;
    *) echo "usage: fleet run pr-ready|agent-comments" >&2; exit 1 ;;
  esac
  local status=0
  for ctx in "${CTXS[@]}"; do
    job="fleet-$SVC-$ctx.service"
    echo "fleet: run $job"
    systemctl start "$job" || status=1
  done
  return "$status"
}

# The release series a tag belongs to: below 1.0 a minor bump can break
# things (cliff.toml), above it only a major one. v0.4.2 -> v0.4, v1.3.0 -> v1.
series() {
  case "$1" in
    v0.*) echo "${1%.*}" ;;
    *) echo "${1%%.*}" ;;
  esac
}

# The machine follows a branch of the fleet repo, or its releases when
# inputs.fleet.url in /etc/nixos/flake.nix points at a v* tag. On a tag,
# rebuild moves to the latest release, asking first when it may break things;
# --ref <tag|branch> moves to any other tag or branch.
rebuild() {
  [ "$(id -u)" -eq 0 ] || { echo "fleet rebuild: run as root" >&2; exit 1; }
  local flake=/etc/nixos/flake.nix url repo ref target answer
  url=$(sed -n 's/^ *inputs\.fleet\.url = "\(.*\)";$/\1/p' "$flake")
  [[ $url =~ ^github:([^/]+/[^/]+)/(.+)$ ]] ||
    { echo "fleet rebuild: cannot read inputs.fleet.url in $flake" >&2; exit 1; }
  repo=${BASH_REMATCH[1]} ref=${BASH_REMATCH[2]} target=${BASH_REMATCH[2]}

  if [ "${1:-}" = --ref ]; then
    target=${2:?usage: fleet rebuild --ref <tag|branch>}
    shift 2
  elif [[ $ref == v* ]]; then
    target=$(curl -fsSL "https://api.github.com/repos/$repo/releases/latest" | jq -r .tag_name)
    if [ "$(series "$target")" != "$(series "$ref")" ]; then
      echo "fleet: $target may need manual steps; read https://github.com/$repo/releases first."
      read -r -p "Move from $ref to $target? [y/N] " answer || answer=
      [ "$answer" = y ] || target=$ref
    fi
  fi

  if [ "$target" != "$ref" ]; then
    git ls-remote --exit-code "https://github.com/$repo" "refs/tags/$target" "refs/heads/$target" >/dev/null ||
      { echo "fleet rebuild: $repo has no tag or branch $target" >&2; exit 1; }
    echo "fleet: $ref -> $target"
    sed -i "s|^\( *inputs\.fleet\.url = \"github:$repo/\).*\";$|\1$target\";|" "$flake"
  fi
  local status=0 rev
  { nix flake update fleet --flake /etc/nixos && nixos-rebuild switch --flake /etc/nixos#fleet "$@"; } || status=$?
  rev=$(jq -r '.nodes.fleet.locked.rev // "?" | .[0:7]' /etc/nixos/flake.lock 2>/dev/null || echo "?")
  if [ "$status" -eq 0 ]; then
    announce "Deploy succeeded" "fleet $target ($rev) is live." 3
  else
    announce "Deploy failed" "fleet rebuild to $target ($rev) exited with $status; check it on the VPS." 4
  fi
  return "$status"
}

# Tells every context's phone how a rebuild went. Best effort: a notifier
# outage, or a context whose setup has not run yet, never fails the rebuild.
announce() {
  local ctx topic
  for ctx in $(jq -r 'keys[]' /etc/fleet/contexts.json 2>/dev/null); do
    topic=$(cat "/home/$ctx/fleet/.ntfy-topic" 2>/dev/null) || continue
    publish "$topic" "$1" "$2" "" "$3" || true
  done
}

login() {
  local name email
  printf '\n\033[1m--- %s ---\033[0m\n' "$CTX"
  if [ -z "$(git config --global user.email || true)" ]; then
    read -r -p "Commit author name ($CTX): " name
    read -r -p "Commit author email ($CTX): " email
    git config --global user.name "$name"
    git config --global user.email "$email"
  fi

  if ! gh auth status >/dev/null 2>&1; then
    echo "GitHub ($CTX): open the link, enter the code and sign in with this context's account."
    gh auth login --hostname github.com --git-protocol https --web
  fi
  gh auth setup-git >/dev/null

  case "$PRIMARY" in
    pi)
      if ! pi auth check --provider openai-codex --json --no-refresh >/dev/null 2>&1; then
        echo
        echo "Pi: run /login, choose the ChatGPT subscription (openai-codex), open the link"
        echo "in your browser and paste the final URL back. Then /quit."
        read -r -p "Press Enter to open Pi... " _
        (cd "$HOME" && pi) || true
      fi
      ;;
    claude)
      if ! claude auth status >/dev/null 2>&1; then
        echo
        echo "Claude: sign in with this context's account. Then /exit."
        read -r -p "Press Enter to open Claude... " _
        (cd "$HOME" && claude) || true
      fi
      ;;
  esac
}

pair() {
  local url
  url=$(grep -oE '[a-z][a-z0-9+.-]*://[^[:space:]"]+' "$LOG" 2>/dev/null \
    | grep -v -E '://(127\.0\.0\.1|localhost)' | tail -1 || true)
  if [ -n "$url" ]; then
    printf '%s (port %s):\n  %s\n  Treat this link like a password.\n' "$CTX" "$PORT" "$url"
  else
    echo "$CTX: the Orca server has not printed a link yet. See: tail -n 50 $LOG"
  fi
  if [ -s "$FLEET/.ntfy-topic" ]; then
    printf 'Notifications: in the ntfy app, subscribe to\n  topic %s on server %s\n  Treat the topic like a password.\n' \
      "$(cat "$FLEET/.ntfy-topic")" "$(cat /etc/fleet/ntfy-base-url)"
  fi
}

status() {
  printf 'setup: '
  if [ -f "$FLEET/.ready" ]; then echo "ok"; else echo "pending (systemctl status fleet-setup-$CTX)"; fi
  printf 'orca:  '
  orca status --json 2>/dev/null | jq -r '
      (.result.runtime // {}) as $r
      | if .ok == false then "error: \(.error.message // .error.code // "?")"
        elif ($r.reachable // .result.runtimeReachable) == true and ($r.state // .result.runtimeState) == "ready" then "ready"
        else "not ready (\($r.state // .result.runtimeState // "?"))" end' 2>/dev/null \
    || echo "no response (systemctl status orca-serve-$CTX)"
}

# Pushes a notification to this context's secret ntfy topic, which the phone
# subscribes to. Hooks and scripts call it, never the agents themselves.
notify() {
  local title="" message="" url="" priority=3
  local use="usage: fleet notify <title> <message> [--url <link>] [--priority <p>]"
  while [ $# -gt 0 ]; do
    case "$1" in
      --url)      url=${2:?$use}; shift 2 ;;
      --priority) priority=${2:?$use}; shift 2 ;;
      *)
        if [ -z "$title" ]; then title=$1; elif [ -z "$message" ]; then message=$1
        else echo "fleet notify: unexpected argument: $1" >&2; exit 1; fi
        shift ;;
    esac
  done
  [ -n "$title" ] && [ -n "$message" ] ||
    { echo "$use" >&2; exit 1; }
  case "$priority" in
    min) priority=1 ;; low) priority=2 ;; default) priority=3 ;; high) priority=4 ;; max|urgent) priority=5 ;;
    [1-5]) ;;
    *) echo "fleet notify: priority is 1-5 or min, low, default, high, max" >&2; exit 1 ;;
  esac
  local topic
  topic=$(cat "$FLEET/.ntfy-topic") || { echo "fleet notify: no ntfy topic yet (systemctl status fleet-setup-$CTX)" >&2; exit 1; }
  publish "$topic" "$title" "$message" "$url" "$priority"
}

# publish <topic> <title> <message> <click url or ""> <priority 1-5>
publish() {
  local topic=$1 title=$2 message=$3 url=$4 priority=$5 body
  body=$(jq -n --arg topic "$topic" --arg title "$title" --arg message "$message" \
    --arg click "$url" --argjson priority "$priority" \
    '{topic: $topic, title: $title, message: $message, priority: $priority}
     + (if $click == "" then {} else {click: $click} end)')
  curl -fsS --max-time 10 --retry 2 --retry-connrefused -o /dev/null -H 'Content-Type: application/json' \
    -d "$body" "$(cat /etc/fleet/ntfy-url)"
}

case "${1:-}" in
  ""|help|-h|--help) usage ;;
  login)   context; login ;;
  pair)    context; pair ;;
  status)  context; status ;;
  notify)  shift; context; notify "$@" ;;
  rebuild) shift; rebuild "$@" ;;
  services) shift; targets "$@"; services ;;
  start|stop|restart) manage "$@" ;;
  run)     shift; run "$@" ;;
  *)       echo "fleet: unknown command: $1" >&2; usage >&2; exit 1 ;;
esac
