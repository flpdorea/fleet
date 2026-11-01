# fleet-claude-hook <event> - Claude Code hooks (homes/claude-settings.json)
# that push notifications to the phone with `fleet notify` and open Lavish
# boards in Orca's browser, so they happen whenever their event does,
# whatever the agent does.
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

# Markdown as one line of plain text, secrets masked and cut at a word to 140
# characters, for a body that reads on the lock screen with the notification
# collapsed. Headings go, unless there is nothing else.
shorten() {
  redact | jq -Rrs '
    def plain(drop): (if drop then gsub("(?m)^[ \t]*#+[ \t][^\n]*"; "") else . end)
      | gsub("(?m)^[ \t]*```[^\n]*"; "") | gsub("(?m)^[ \t]*(#+|[-*+]|[0-9]+\\.|>)[ \t]+"; "")
      | gsub("\\[(?<t>[^]]*)\\]\\([^)]*\\)"; "\(.t)") | gsub("\\*\\*|__|`"; "")
      | gsub("\\s+"; " ") | ltrimstr(" ") | rtrimstr(" ");
    (plain(true) | select(. != "")) // plain(false)
    | if length <= 140 then . else .[:140] | sub(" [^ ]*$"; "") + "…" end'
}

# Masks what looks like a secret: a value after a key, flag or URL user
# that names one, and tokens with a known prefix.
redact() {
  sed -E "s/((token|secret|passw(or)?d|api[_-]?key|authorization|credential)[[:alnum:]_-]*[\"']?[[:space:]]*[=:][[:space:]]*(bearer[[:space:]]+)?)(\"[^\"]*\"|'[^']*'|[^[:space:]\"',;]+)/\1[hidden]/Ig
    s/(--?[[:alnum:]-]*(token|secret|passw(or)?d|key)[[:alnum:]-]*[[:space:]]+)(\"[^\"]*\"|'[^']*'|[^[:space:]\"'-][^[:space:]\"']*)/\1[hidden]/Ig
    s#(://[^/:@[:space:]]+:)[^/@[:space:]]+@#\1[hidden]@#g
    s/(^|[[:space:]])(-u[[:space:]]*[^[:space:]:]+:)[^[:space:]]+/\1\2[hidden]/g
    s/(gh[pousr]_|github_pat_|glpat-|xox[abpr]-|sk-|AKIA)[[:alnum:]_-]+/\1[hidden]/g
    s/eyJ[[:alnum:]_-]+\.[[:alnum:]._-]+/[hidden]/g"
}

# The tool call the agent waits on, {name, input}: the one tool_use in the
# transcript without a tool_result yet. Unknown when several are pending
# (parallel calls) or the pending one is a subagent, whose calls go to its
# own transcript.
pending_tool() {
  jq -cs '
    [ .[] | .message.content? | arrays | .[] ] as $c
    | [ $c[] | select(.type == "tool_result") | .tool_use_id ] as $done
    | [ $c[] | select(.type == "tool_use" and (.id | IN($done[]) | not)) ]
    | if length == 1 and (.[0].name | IN("Agent", "Task") | not) then .[0] else empty end' "$(field .transcript_path)"
}

# Permission, question and idle prompts: the agent is waiting for you. The
# body says what for: the command to allow, the question, or what the agent
# said last.
notification() {
  local title detail="" priority=high tool=""
  case "$(field .notification_type)" in
    permission_prompt)
      tool=$(pending_tool) || tool=""
      if [ -z "$tool" ]; then
        title="Needs your permission"
      elif [ "$(jq -r .name <<<"$tool")" = AskUserQuestion ]; then
        title="Question: $(jq -r '.input.questions[0].header // "for you"' <<<"$tool")"
        detail=$(jq -r '.input.questions[0] | "\(.question) (\(.options | length) options)"' <<<"$tool")
      else
        title="Permission: $(jq -r '.name | sub("^mcp__"; "")' <<<"$tool")"
        detail=$(jq -r '.input | .command // .file_path // .url // .pattern // .query // empty' <<<"$tool")
      fi ;;
    elicitation_dialog) title="Question for you" ;;
    idle_prompt)
      if [ -n "$(find "$(marker)" -mmin -5 2>/dev/null)" ]; then rm -f "$(marker)"; return; fi
      title="Waiting for you"; detail=$(last_message); priority=default ;;
    *) return ;;
  esac
  fleet notify "$title" "$(shorten <<<"${detail:-$(field .message)}")
$(where)" --priority "$priority"
}

# Seconds since the last prompt you typed, read from the transcript.
elapsed() {
  local since
  since=$(jq -rs '
    [ .[] | select(.type == "user" and (.isMeta or .isCompactSummary or .isVisibleInTranscriptOnly | not)
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
  echo "${text:-Finished.}"
}

# A long task finished: notify with a summary of the agent's last message.
stop() {
  local took body
  [ "$(field .stop_hook_active)" = true ] && return
  took=$(elapsed) || return
  [ "$took" -ge "$long_task" ] || return
  body=$(last_message | shorten)
  fleet notify "Done: $(where) ($((took / 60)) min)" "${body:-Finished.}"
  mkdir -p "$state" && touch "$(marker)"
}

# Opens a Lavish board in a tab of Orca's built-in browser, in the
# session's worktree, unless a tab already shows it: lavish-axi prints
# "opened" every time a board is re-run, not only the first.
browser_tab() {
  local url=$1 top
  local wt=()
  top=$(git -C "$(field .cwd)" rev-parse --show-toplevel) && wt=(--worktree "path:$top")
  orca tab list --worktree all --json </dev/null \
    | jq -e --arg url "$url" 'any(.result.tabs[]; .url == $url)' >/dev/null && return 0
  orca tab create --url "$url" "${wt[@]}" --json </dev/null
}

# A Bash command opened a Lavish board (a plan, an issue draft, an
# escalation) or a pull request: open the board in Orca's browser and
# notify with its link. lavish-axi prints the session's Tailscale URL; gh
# prints the URL of each PR it creates.
bash_tool() {
  local cmd out url file title pr
  local run='(^|[;&|(]|&&)[[:space:]]*'
  cmd=$(field .tool_input.command)
  out=$(jq -r '[.tool_response.stdout, .tool_response.stderr] | map(select(.)) | join("\n")' <<<"$input")
  if [[ $cmd =~ ${run}(npx[[:space:]]+(-y[[:space:]]+)?)?lavish-axi[[:space:]] ]]; then
    grep -qE '^ *status: (opened|reopened|ready)$' <<<"$out" || return 0
    url=$(sed -n 's/^ *url: "\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' <<<"$out" | head -1)
    file=$(sed -n 's/^ *file: "\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' <<<"$out" | head -1)
    [ -n "$url" ] || return 0
    browser_tab "$url"
    title=$(sed -n 's:.*<title>\([^<]*\)</title>.*:\1:p' "$file" 2>/dev/null | head -1)
    fleet notify "Review: ${title:-$(basename "$file" .html)}" "$(where)" --url "$url" --priority high
  elif [[ $cmd =~ ${run}gh[[:space:]]+(pr[[:space:]]+create|stack[[:space:]]+submit) ]]; then
    mkdir -p "$state"
    # Parallel hooks must not both notify the same PR.
    exec 9>>"$state/prs"
    flock 9
    while read -r pr; do
      [ -n "$pr" ] || continue
      grep -qxF "$pr" "$state/prs" && continue
      echo "$pr" >>"$state/prs"
      title=$(timeout 10 gh pr view "$pr" --json title -q .title </dev/null) || title=$pr
      fleet notify "PR opened: $title" "${pr#https://github.com/}" --url "$pr" </dev/null
    done < <(grep -oE 'https://github\.com/[^/ ]+/[^/ ]+/pull/[0-9]+' <<<"$out" | sort -u)
  fi
}

case "${1:-}" in
  notification) notification || true ;;
  stop)         stop || true ;;
  bash)         bash_tool || true ;;
esac
exit 0
