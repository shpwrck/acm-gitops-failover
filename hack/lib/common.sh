# Shared by hack/dr.sh, hack/build.sh and hack/teardown.sh: the output (gum
# boxes, spinners and tables on a terminal, plain text otherwise), waiting,
# and the cluster checks they all need. Sourced, not run.
#
# The sourcing script sets REPO, BRANCH and YES (confirm skips its question
# when YES=1), and LOGFILE when it keeps a log: die names it. Fd 3 is that
# log; it goes nowhere until the script points it at a file.
# The colors and BAD are read, and show is given arguments, by the scripts that source this.
# shellcheck shell=bash disable=SC2034,SC2119,SC2120

# --- names -------------------------------------------------------------------

NS=open-cluster-management-backup
GNS=openshift-gitops
RESTORE=restores.cluster.open-cluster-management.io
BSCHED=backupschedules.cluster.open-cluster-management.io
VSCHED=schedules.velero.io
VBACKUP=backups.velero.io
APP=applications.argoproj.io

# --- output ------------------------------------------------------------------
# The screen gets gum's boxes and tables, and a spinner while the script waits.
# The log (fd 3) gets plain text.

UI=plain
if [ -t 1 ] && [ "${DR_PLAIN:-0}" != 1 ] && [ -z "${NO_COLOR:-}" ] && command -v gum >/dev/null; then UI=gum; fi
C_B="" C_DIM="" C_OFF="" C_OK="" C_BAD="" C_WARN="" C_ACC=""
if [ "$UI" = gum ]; then
  C_B=$'\e[1m' C_DIM=$'\e[2m' C_OFF=$'\e[0m' C_OK=$'\e[92m' C_BAD=$'\e[91m' C_WARN=$'\e[33m' C_ACC=$'\e[95m'
fi
exec 3>/dev/null

now() { date -u +%FT%TZ; }
logln() { printf '%s\n' "$@" >&3; }
line() { printf '%s\n' "$*"; logln "$*"; }
not() { ! "$@"; }
dur() {   # dur <seconds>: 41s, 3m05s, 1h02m
  if [ "$1" -lt 60 ]; then echo "$1s"
  elif [ "$1" -lt 3600 ]; then printf '%dm%02ds\n' $(($1 / 60)) $(($1 % 60))
  else printf '%dh%02dm\n' $(($1 / 3600)) $(($1 % 3600 / 60)); fi
}
cols() {   # the terminal's width; 80 when it does not say
  local s
  s=$(stty size 2>/dev/null </dev/tty) || s=""
  s=${s#* }
  if [[ $s =~ ^[0-9]+$ ]] && [ "$s" -ge 40 ]; then echo "$s"; else echo 80; fi
}
# gum's colors survive the pipe of $(...), which also spares the terminal gum's color queries
gumc() { CLICOLOR_FORCE=1 gum "$@"; }

box() {   # box <border> <color> <title> [line...]: a framed message with gum, plain lines without
  local border=$1 color=$2 title=$3 l w
  shift 3
  logln "" "== $title"
  for l in "$@"; do logln "   $l"; done
  if [ "$UI" = gum ]; then
    w=$(cols)
    w=$((w > 80 ? 76 : w - 4))
    printf '\n%s\n' "$(gumc style --border "$border" --border-foreground "$color" --padding '0 2' --margin '0 1' --width "$w" \
      "$(gumc style --bold --foreground "$color" "$title")" "$@")"
  else
    printf '\n== %s\n' "$title"
    for l in "$@"; do printf '%s\n' "$l" | fold -s -w 76 | sed 's/ *$//; s/^/   /'; done
  fi
}
your_turn() {   # your_turn <what> [line...]: something only you can do; the bell calls you back
  box double 3 "YOUR TURN: $1" "${@:2}"
  if [ "$UI" = gum ]; then printf '\a'; fi
}
say() {
  HELP_SHOWN=""
  logln "" "== $*"
  if [ "$UI" = gum ]; then printf '\n %s▍%s%s%s\n' "$C_ACC" "$C_B" "$*" "$C_OFF"; else printf '\n== %s\n' "$*"; fi
}
mark() {   # mark <plain tag> <gum mark> <text>
  logln "   $1 $3"
  if [ "$UI" = gum ]; then printf '   %s %s\n' "$2" "$3"; else printf '   %s %s\n' "$1" "$3"; fi
}
BAD=0
ok() { mark "ok   " "${C_OK}✓${C_OFF}" "$*"; }
HELP="" HELP_SHOWN=""
help_at() { HELP=$1; }   # help_at <doc#anchor>: the section that explains the RED lines after it
doc_url() {   # doc_url <path in the repo>: a web link into your copy of the repo, or the local file
  local base
  base=$(repo_url 2>/dev/null || true)
  if [[ $base == https://github.com/* ]]; then echo "$base/blob/$BRANCH/$1"; else echo "$REPO/$1"; fi
}
link() {   # link <url>: the url, clickable where the terminal supports it
  # shellcheck disable=SC1003 # the \\ ends the escape sequence, it does not escape a quote
  if [ "$UI" = gum ]; then printf '\e]8;;%s\e\\%s\e]8;;\e\\' "$1" "$1"; else printf '%s' "$1"; fi
}
red() {   # a failed check, then (once per section) where the docs explain what could be wrong
  local u
  BAD=1
  mark "RED  " "${C_BAD}✗${C_OFF}" "$*"
  if [ -n "$HELP" ] && [ "$HELP" != "$HELP_SHOWN" ]; then
    HELP_SHOWN=$HELP
    u=$(doc_url "$HELP")
    logln "        what could be wrong: $u"
    if [ "$UI" = gum ]; then
      printf '     %s↳ what could be wrong:%s %s\n' "$C_DIM" "$C_OFF" "$(link "$u")"
    else
      printf '        what could be wrong: %s\n' "$u"
    fi
  fi
}
note() { mark "note " "${C_WARN}•${C_OFF}" "$*"; }
label() { logln "   $*"; printf '   %s%s%s\n' "$C_B" "$*" "$C_OFF"; }
explain() {   # explain <text>: what a step does and why, wrapped under its heading
  local w
  w=$(cols)
  w=$((w > 84 ? 76 : w - 8))
  logln "$(printf '%s\n' "$*" | fold -s -w 76 | sed 's/ *$//; s/^/   /')"
  printf '%s\n' "$*" | fold -s -w "$w" | sed 's/ *$//; s/^/   /'
}
finished() {   # finished <text>: a step that went through
  logln "   $*"
  if [ "$UI" = gum ]; then printf '   %s✓%s %s%s%s\n' "$C_OK" "$C_OFF" "$C_DIM" "$*" "$C_OFF"; else echo "   $*"; fi
}
verdict() {   # verdict ok|bad <text>
  local color=9
  if [ "$1" = ok ]; then color=10; fi
  logln "" "$2"
  if [ "$UI" = gum ]; then
    printf '\n%s\n' "$(gumc style --border rounded --border-foreground "$color" --foreground "$color" --bold --padding '0 1' --margin '0 1' "$2")"
  else
    printf '\n%s\n' "$2"
  fi
}
show() {   # show [command...]: its output (or stdin), indented and dim, on the screen and in the log
  local out rc=0 l
  if [ $# -gt 0 ]; then out=$("$@" 2>&1) || rc=$?; else out=$(cat); fi
  if [ -n "$out" ]; then
    while IFS= read -r l; do
      logln "     $l"
      printf '     %s%s%s\n' "$C_DIM" "$l" "$C_OFF"
    done <<<"$out"
  fi
  return "$rc"
}
quiet() {   # quiet <command...>: with gum its output goes to the log only, unless it fails
  local out rc=0
  out=$("$@" 2>&1) || rc=$?
  if [ -z "$out" ]; then return "$rc"; fi
  if [ "$UI" = gum ] && [ "$rc" = 0 ]; then logln "$out"; else show <<<"$out"; fi
  return "$rc"
}
to_log() { if [ "$UI" = gum ]; then cat >&3; else show; fi; }   # stdin, like quiet

align() {   # tab-separated rows in aligned columns
  awk -F'\t' '{ for (i = 1; i <= NF; i++) { c[NR, i] = $i; if (length($i) > w[i]) w[i] = length($i) } if (NF > n) n = NF }
    END { for (r = 1; r <= NR; r++) { s = ""; for (i = 1; i <= n; i++) s = s sprintf("%-" (w[i] + 2) "s", c[r, i]); sub(/ +$/, "", s); print "   " s } }'
}
table() {   # table: tab-separated rows on stdin, the first one the header
  local rows
  rows=$(cat)
  align <<<"$rows" >&3
  if [ "$UI" = gum ]; then
    # gum 0.17's --print leaves the header plain (and bolds the first row), so the header is colored here
    rows=$(awk -F'\t' -v OFS='\t' -v a="$C_B$C_ACC" -v z="$C_OFF" 'NR == 1 { for (i = 1; i <= NF; i++) $i = a $i z } 1' <<<"$rows")
    printf '%s\n' "$(gumc table --print --separator $'\t' --border rounded --border.foreground 8 --selected.foreground '' \
      --lazy-quotes <<<"$rows" | sed 's/^/  /')"
  else
    align <<<"$rows"
  fi
}

DIED=0
die() {
  spin_stop
  DIED=1
  box thick 9 "STOP" "$*" ${LOGFILE:+"" "Log: $LOGFILE"}
  exit 1
}
confirm() {
  [ "$YES" = 1 ] && return 0
  local answer=""
  if [ "$UI" = gum ]; then
    echo
    if gum confirm --default=false "$1" </dev/tty >/dev/tty 2>/dev/tty; then
      finished "$1 yes"
      return 0
    fi
    logln "$1 no"
    die "stopped at your request"
  fi
  read -r -p "$1 [y/N] " answer </dev/tty || true
  logln "$1 [y/N] $answer"
  [ "$answer" = y ] || [ "$answer" = Y ] || die "stopped at your request"
}

# The spinner: one status line, redrawn ten times a second while the script
# waits. Checks run in the background so it keeps turning.
SPIN="" SPIN_T0=0 SPIN_N=0 SPIN_W=60 POLL_PID=""
FRAMES=(⣾ ⣽ ⣻ ⢿ ⡿ ⣟ ⣯ ⣷)
spin_begin() {   # spin_begin <title>
  spin_stop
  logln "   $1"
  if [ "$UI" = gum ]; then
    SPIN=$1 SPIN_T0=$SECONDS SPIN_W=$(($(cols) - 14))
    if [ "$SPIN_W" -lt 20 ]; then SPIN_W=20; fi
    printf '\e[?25l'
    spin_draw
  else
    echo "   $1"
  fi
}
spin_draw() {
  local e=$((SECONDS - SPIN_T0))
  SPIN_N=$(((SPIN_N + 1) % ${#FRAMES[@]}))
  printf '\r\e[K   %s%s%s %s %s%d:%02d%s' "$C_ACC" "${FRAMES[SPIN_N]}" "$C_OFF" "${SPIN:0:SPIN_W}" "$C_DIM" $((e / 60)) $((e % 60)) "$C_OFF"
}
spin_stop() { if [ -n "$SPIN" ]; then printf '\r\e[K\e[?25h'; SPIN=""; fi; }
nap() { sleep 0.1; }   # not read -t: bash 5.2 can crash when Ctrl-C lands in one
pause() {   # pause <seconds>: sleep, keeping the spinner turning
  local i
  if [ -z "$SPIN" ]; then sleep "$1"; return 0; fi
  for ((i = 0; i < $1 * 10; i++)); do spin_draw; nap; done
}
spin_wait() {   # spin_wait <pid>: keep the spinner turning until <pid> exits; its exit status
  local rc=0
  POLL_PID=$1
  while kill -0 "$1" 2>/dev/null; do spin_draw; nap; done
  wait "$1" || rc=$?
  POLL_PID=""
  return "$rc"
}
poll() {   # poll <command...>: run a check quietly, keeping the spinner turning
  if [ -z "$SPIN" ]; then "$@" >/dev/null 2>&1; return; fi
  "$@" >/dev/null 2>&1 &
  spin_wait $!
}

# wait_for <seconds> <command...>: retry every ${EVERY:-5} s; non-zero on timeout
wait_for() {
  local end=$((SECONDS + $1))
  shift
  until poll "$@"; do
    [ "$SECONDS" -lt "$end" ] || return 1
    pause "${EVERY:-5}"
  done
}
upto() { if [ $(($1 % 3600)) = 0 ]; then echo "$(($1 / 3600)) h"; else echo "$(($1 / 60)) min"; fi; }
# try_until <seconds> <what> <command...>: wait_for under a spinner; non-zero on timeout
try_until() {
  local limit=$1 what=$2 t0=$SECONDS
  shift 2
  spin_begin "waiting for $what (up to $(upto "$limit"))"
  if wait_for "$limit" "$@"; then
    spin_stop
    finished "waited $(dur $((SECONDS - t0))) for $what"
  else
    spin_stop
    return 1
  fi
}
# wait_until <seconds> <what> <command...>: try_until, and stop on timeout
wait_until() { try_until "$@" || die "timed out waiting for $2"; }
spin_cmd() {   # spin_cmd <title> <command...>: a slow command; its output goes to the log, and to the screen if it fails
  local title=$1 t0=$SECONDS out rc=0
  shift
  out=$(mktemp)
  spin_begin "$title"
  if [ -n "$SPIN" ]; then
    "$@" >"$out" 2>&1 &
    spin_wait $! || rc=$?
  else
    "$@" >"$out" 2>&1 || rc=$?
  fi
  spin_stop
  if [ "$rc" = 0 ]; then
    logln "$(cat "$out")"
    finished "$title: $(dur $((SECONDS - t0)))"
  else
    show <"$out"
  fi
  rm -f "$out"
  return "$rc"
}

fresh_screen() {   # scroll what the screen shows into the scrollback, then write from the top
  local rows
  rows=$(stty size 2>/dev/null </dev/tty) || rows=""
  rows=${rows%% *}
  if ! [[ $rows =~ ^[0-9]+$ ]] || [ "$rows" -lt 1 ]; then rows=50; fi
  printf '%*s' "$rows" '' | tr ' ' '\n'
  printf '\e[H'
}

# --- cluster checks ------------------------------------------------------------

server() { oc config view --minify --context "$1" -o jsonpath='{.clusters[0].cluster.server}'; }
api_rc() { local rc=0; curl -sk --max-time 5 -o /dev/null "$(server "$1")/version" || rc=$?; echo "$rc"; }
# alive: any HTTP answer. dead: connection refused or timed out. A name that
# does not resolve is neither: that is DNS trouble, not proof of death.
alive() { [ "$(api_rc "$1")" = 0 ]; }
dead() { case $(api_rc "$1") in 7 | 28) return 0 ;; *) return 1 ;; esac; }

# none / some <context> <oc get args...>: the query worked and found nothing / something
none() { local out; out=$(oc --context "$1" get "${@:2}" --ignore-not-found -o name 2>/dev/null) && [ -z "$out" ]; }
some() { local out; out=$(oc --context "$1" get "${@:2}" --ignore-not-found -o name 2>/dev/null) && [ -n "$out" ]; }
nodes_ready() {
  local out; out=$(oc --context "$1" get nodes --no-headers 2>/dev/null) && [ -n "$out" ] && [ -z "$(awk '$2 !~ /^Ready/' <<<"$out")" ]
}
pending_csr_names() {
  oc --context "$1" get csr -o go-template='{{range .items}}{{if not .status}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}' 2>/dev/null || true
}
pending_csrs() { [ -n "$(pending_csr_names "$1")" ]; }
approve_csrs() { pending_csr_names "$1" | xargs -r oc --context "$1" adm certificate approve; }
settled() { nodes_ready "$1" && not pending_csrs "$1"; }

phase() { oc --context "$1" get "$2" "$3" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null || true; }
restore_finished() { [[ $(phase "$1" "$RESTORE" "$2") == Finished* ]]; }
restore_enabled() { [ "$(phase "$1" "$RESTORE" "$2")" = Enabled ]; }
schedule_enabled() { [ "$(phase "$1" "$BSCHED" schedule-acm)" = Enabled ]; }
mc_available() {   # mc_available <context> True|Unknown
  [ "$(oc --context "$1" get managedcluster "$MANAGED" \
    -o jsonpath='{.status.conditions[?(@.type=="ManagedClusterConditionAvailable")].status}' 2>/dev/null)" = "$2" ]
}
addons_available() {
  oc --context "$1" get managedclusteraddon -n "$MANAGED" -o json 2>/dev/null | jq -e '
    [.items[] | ((.status.conditions // []) | map(select(.type == "Available")) | .[0].status) == "True"]
    | length > 0 and all' >/dev/null
}
# backup_set_after <context> <time>: one backup of each kind started at or after <time> has Completed
backup_set_after() {
  oc --context "$1" get "$VBACKUP" -n "$NS" -o json 2>/dev/null | jq -e --arg t "$2" '
    ["acm-credentials-schedule-", "acm-managed-clusters-schedule-", "acm-resources-schedule-"] as $kinds
    | [.items[] | select(.status.phase == "Completed" and (.status.startTimestamp // "") >= $t) | .metadata.name] as $done
    | all($kinds[]; . as $k | any($done[]; startswith($k)))' >/dev/null
}
http_ok() { [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$1")" = 200 ]; }
app_state() {   # app_state <context> <Application name>: "Synced Healthy" when all is well
  oc --context "$1" get "$APP" -A --field-selector "metadata.name=$2" \
    -o jsonpath='{.items[0].status.sync.status} {.items[0].status.health.status}' 2>/dev/null || true
}
has_dr_role() { some "$1" "$APP" dr-role -n "$GNS"; }
dr_role_state() { oc --context "$1" get "$APP" dr-role -n "$GNS" -o jsonpath='{.status.sync.status} {.status.health.status}' 2>/dev/null || true; }
dr_role_synced() { [ "$(dr_role_state "$1")" = "Synced Healthy" ]; }
msa_token() {
  oc --context "$1" get managedserviceaccount auto-import-account -n "$MANAGED" \
    -o jsonpath='{.status.conditions[?(@.type=="TokenReported")].status} {.status.expirationTimestamp}' 2>/dev/null || true
}
msa_fresh() { local t; t=$(msa_token "$1"); [ "${t%% *}" = True ] && [[ ${t#* } > $(date -u -d '+24 hours' +%FT%TZ) ]]; }

repo_url() { git remote get-url origin | sed -e 's#^git@github.com:#https://github.com/#' -e 's#\.git$##'; }
