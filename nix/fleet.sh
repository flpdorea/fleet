# fleet - this user's first mate (one Linux user per context).
# Packaged by the Nix module with writeShellApplication.

FLEET="$HOME/fleet"
FM="$FLEET/firstmate"
CTX=$(cat "$FLEET/.context" 2>/dev/null) || {
  echo "fleet: this user is not a fleet context (or its setup has not run yet)" >&2
  exit 1
}
PRIMARY=$(jq -r --arg c "$CTX" '.[$c].primary' /etc/fleet/contexts.json)
PORT=$(jq -r --arg c "$CTX" '.[$c].orcaPort' /etc/fleet/contexts.json)
LOG="/var/log/fleet/orca-$CTX.log"

usage() {
  cat >&2 <<'EOF'
usage: fleet [command]
  (none)   open (or reattach to) the first mate in a tmux session
  login    git identity, GitHub and the agent's login
  pair     link that connects the Orca app to this server
  status   setup, Orca server and first mate session
EOF
}

open() {
  if ! tmux has-session -t =firstmate 2>/dev/null; then
    tmux new-session -d -s firstmate -c "$FM" "$PRIMARY"
  fi
  if [ -n "${TMUX:-}" ]; then exec tmux switch-client -t =firstmate; fi
  exec tmux attach -t =firstmate
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
        (cd "$FM" && pi) || true
      fi
      ;;
    claude)
      if ! claude auth status >/dev/null 2>&1; then
        echo
        echo "Claude: sign in with this context's account. Then /exit."
        read -r -p "Press Enter to open Claude... " _
        (cd "$FM" && claude) || true
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
}

status() {
  printf 'setup:       '
  if [ -f "$FM/config/backend" ]; then echo "ok"; else echo "pending (systemctl status fleet-setup-$CTX)"; fi
  printf 'orca:        '
  orca status --json 2>/dev/null | jq -r '
      (.result.runtime // {}) as $r
      | if .ok == false then "error: \(.error.message // .error.code // "?")"
        elif ($r.reachable // .result.runtimeReachable) == true and ($r.state // .result.runtimeState) == "ready" then "ready"
        else "not ready (\($r.state // .result.runtimeState // "?"))" end' 2>/dev/null \
    || echo "no response (systemctl status orca-serve-$CTX)"
  printf 'first mate:  '
  if tmux has-session -t =firstmate 2>/dev/null; then echo "running (fleet)"; else echo "not running"; fi
}

case "${1:-}" in
  "")     open ;;
  login)  login ;;
  pair)   pair ;;
  status) status ;;
  help|-h|--help) usage ;;
  *)      usage; exit 1 ;;
esac
