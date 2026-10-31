# fleet-claude-hook <event> - Claude Code hooks (homes/claude-settings.json)
# that push notifications to the phone with `fleet notify`, so a
# notification fires whenever its event happens, whatever the agent does.
# Packaged by the Nix module with writeShellApplication.
#
# A hook must never block or fail the agent: it hands the event JSON to a
# detached copy of itself and exits 0 at once, and that copy swallows every
# error, so a notifier outage goes unnoticed by the agent.

# Tasks that ran at least this long notify when they finish.
long_task=${FLEET_NOTIFY_LONG_TASK:-300}
state="$HOME/.cache/fleet/notify"

if [ -z "${FLEET_HOOK_INPUT:-}" ]; then
  input=$(mktemp)
  cat >"$input"
  FLEET_HOOK_INPUT=$input setsid -f "$0" "$@" </dev/null >/dev/null 2>&1 || rm -f "$input"
  exit 0
fi
input=$(cat "$FLEET_HOOK_INPUT")
rm -f "$FLEET_HOOK_INPUT"
exec >/dev/null 2>&1

field() { jq -r "$1 // empty" <<<"$input"; }

# repo/worktree of the session, such as fleet/fix-login.
where() {
  local cwd top common
  cwd=$(field .cwd)
  top=$(git -C "$cwd" rev-parse --show-toplevel) || { basename "$cwd"; return; }
  common=$(git -C "$cwd" rev-parse --path-format=absolute --git-common-dir)
  if [ "$(dirname "$common")" = "$top" ]; then
    basename "$top"
  else
    echo "$(basename "$(dirname "$common")")/$(basename "$top")"
  fi
}

# Marks that this session just notified a finished task, so the idle
# prompt that follows a minute later does not notify a second time.
marker() { echo "$state/$(field .session_id | tr -cd 'A-Za-z0-9-')"; }

# Permission, question and idle prompts: the agent is waiting for you.
notification() {
  local title priority=default
  case "$(field .notification_type)" in
    permission_prompt)  title="Needs your permission"; priority=high ;;
    elicitation_dialog) title="Question for you"; priority=high ;;
    idle_prompt)
      if [ -n "$(find "$(marker)" -mmin -5 2>/dev/null)" ]; then rm -f "$(marker)"; return; fi
      title="Waiting for you" ;;
    *) return ;;
  esac
  fleet notify "$title" "$(where): $(field .message)" --priority "$priority"
}

# Seconds since the last prompt you typed, read from the transcript.
elapsed() {
  local since
  since=$(jq -rs '
    [ .[] | select(.type == "user" and (.isMeta | not)
        and (.message.content | if type == "string" then true else any(.[]; .type == "text") end))
      | .timestamp ] | last // empty
    | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601' "$(field .transcript_path)")
  [ -n "$since" ] && echo $(($(date +%s) - since))
}

# The last thing the agent said, for the notification body.
last_message() {
  local text
  text=$(field .last_assistant_message)
  [ -n "$text" ] || text=$(jq -rs '
    [ .[] | select(.type == "assistant") | .message.content[]? | select(.type == "text") | .text ]
    | last // empty' "$(field .transcript_path)")
  tr -s '[:space:]' ' ' <<<"${text:-Finished.}" | sed 's/ $//' | cut -c1-240
}

# A long task finished: notify with a summary of the agent's last message.
stop() {
  local took
  [ "$(field .stop_hook_active)" = true ] && return
  took=$(elapsed) || return
  [ "$took" -ge "$long_task" ] || return
  fleet notify "Done in $(where) ($((took / 60)) min)" "$(last_message)"
  mkdir -p "$state" && touch "$(marker)"
}

case "${1:-}" in
  notification) notification || true ;;
  stop)         stop || true ;;
esac
exit 0
