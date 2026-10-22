#!/usr/bin/env bash
# DR exercise driver: runs the runbooks' commands in order and enforces
# their gates. The runbooks (docs/runbooks/) explain each step; the labels
# below (B.0, D.2, G.3, ...) point into the Manual Pull Path runbook, the
# primed ones (D'.1, F', G'.1) into the Automated Pull Path.
#
# Usage: hack/dr.sh <command> [--git] [--yes]
#
#   run        one whole exercise: check, probes, outage, deploy, failover,
#              rejoin, summary. It stops for what only you can do: cut the
#              active hub's power, merge the PRs (--git), power it back on
#   check      read-only pre-flight of the posture the settings file names
#   nodes [CONTEXT...]
#              approve pending certificate requests until the nodes are Ready
#              (after a power-on; default: all three clusters)
#   probe start|stop|summary
#              availability, hub-pointer and revision probes, detached from the terminal (A)
#   outage     etcd backup and slot check (B.0), then wait for you to cut the power (B.1)
#   deploy     bump both apps' REVISION on $BRANCH, wait for the pull app to serve it (C)
#   failover   refuse while the active hub's API answers, then activate the passive hub (D-F)
#   rejoin     bring the old hub back as passive (G, H.1), then swap ACTIVE and PASSIVE
#              in the settings file for the next run
#
#   --git      failover and rejoin go through dr/ pull requests (the Automated paths)
#   --yes      do not ask before starting a run or a manual activation
#
# Both demo apps run side by side, so every run exercises pull and push
# delivery. The script never powers anything off or on.
# Settings: $DR_ENV (default ~/acm-dr/dr.env; see hack/dr.env.example).
# Logs: ~/acm-dr/runs/run-$RUN/
# Output: with gum (https://github.com/charmbracelet/gum) on a terminal,
# spinners, boxes and tables, and a bell when it is your turn. Without gum,
# or with DR_PLAIN=1, plain text. console.log gets plain text either way.
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SELF=$REPO/hack/dr.sh
DR_ENV=${DR_ENV:-$HOME/acm-dr/dr.env}
[ -f "$DR_ENV" ] || { echo "no settings file at $DR_ENV: copy hack/dr.env.example there and edit it" >&2; exit 2; }
DR_ENV=$(readlink -f "$DR_ENV")
# shellcheck source=/dev/null
. "$DR_ENV"
: "${ACTIVE:?set ACTIVE in $DR_ENV}" "${PASSIVE:?set PASSIVE in $DR_ENV}" "${APP_URL:?set APP_URL in $DR_ENV}"
MANAGED=${MANAGED:-spoke}
PUSH_APP_URL=${PUSH_APP_URL:-}
BRANCH=${BRANCH:-main}
RUN=${RUN:-1}
if [ -n "${KUBECONFIG:-}" ]; then export KUBECONFIG; fi
LOGDIR=$HOME/acm-dr/runs/run-$RUN
mkdir -p "$LOGDIR"
cd "$REPO"

NS=open-cluster-management-backup
GNS=openshift-gitops
RESTORE=restores.cluster.open-cluster-management.io
BSCHED=backupschedules.cluster.open-cluster-management.io
VSCHED=schedules.velero.io
VBACKUP=backups.velero.io
APP=applications.argoproj.io

GIT=0 YES=0
CMD=${1:-}
if [ $# -gt 0 ]; then shift; fi
ARGS=()
for a in "$@"; do
  case $a in
    --git) GIT=1 ;;
    --yes) YES=1 ;;
    *) ARGS+=("$a") ;;
  esac
done

# --- output ------------------------------------------------------------------
# The screen gets gum's boxes and tables, and a spinner while the script waits.
# The log (fd 3: console.log, or nowhere for check and probe) gets plain text.

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
flag() { if [ "$GIT" = 1 ]; then echo " --git"; fi; }
mode_name() { if [ "$GIT" = 1 ]; then echo git-driven; else echo manual; fi; }
dur() {   # dur <seconds>: 41s, 3m05s, 1h02m
  if [ "$1" -lt 60 ]; then echo "$1s"
  elif [ "$1" -lt 3600 ]; then printf '%dm%02ds\n' $(($1 / 60)) $(($1 % 60))
  else printf '%dh%02dm\n' $(($1 / 3600)) $(($1 % 3600 / 60)); fi
}
cols() {   # the terminal's width; 80 when it does not say
  local s
  s=$(stty size </dev/tty 2>/dev/null) || s=""
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
    for l in "$@"; do printf '   %s\n' "$l"; done
  fi
}
your_turn() {   # your_turn <what> [line...]: something only you can do; the bell calls you back
  box double 3 "YOUR TURN: $1" "${@:2}"
  if [ "$UI" = gum ]; then printf '\a'; fi
}
say() {
  logln "" "== $*"
  if [ "$UI" = gum ]; then printf '\n %s▍%s%s%s\n' "$C_ACC" "$C_B" "$*" "$C_OFF"; else printf '\n== %s\n' "$*"; fi
}
event() {   # a milestone: on the screen, in the log and in events.log
  local t
  t=$(now)
  echo "$t $*" >>"$LOGDIR/events.log"
  logln "$t $*"
  if [ "$UI" = gum ]; then printf '   %s◆ %s%s %s\n' "$C_ACC" "${t:11:8}" "$C_OFF" "$*"; else echo "$t $*"; fi
}
mark() {   # mark <plain tag> <gum mark> <text>
  logln "   $1 $3"
  if [ "$UI" = gum ]; then printf '   %s %s\n' "$2" "$3"; else printf '   %s %s\n' "$1" "$3"; fi
}
BAD=0
ok() { mark "ok   " "${C_OK}✓${C_OFF}" "$*"; }
red() { BAD=1; mark "RED  " "${C_BAD}✗${C_OFF}" "$*"; }
note() { mark "note " "${C_WARN}•${C_OFF}" "$*"; }
label() { logln "   $*"; printf '   %s%s%s\n' "$C_B" "$*" "$C_OFF"; }
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
  box thick 9 "STOP" "$*" "" "Log: $LOGDIR/console.log"
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
  rows=$(stty size </dev/tty 2>/dev/null) || rows=""
  rows=${rows%% *}
  if ! [[ $rows =~ ^[0-9]+$ ]] || [ "$rows" -lt 1 ]; then rows=50; fi
  printf '%*s' "$rows" '' | tr ' ' '\n'
  printf '\e[H'
}

STAGES=(Pre-flight Outage Deploy Failover Rejoin Summary)
IN_RUN=0 RUN_T0=0 STAGE_EV=0
stage() {   # stage <n>: where the run stands; with gum, each stage after the first starts on a clear screen
  local i s="" rule w fill recap="" n
  n=$(wc -l 2>/dev/null <"$LOGDIR/events.log" || echo 0)
  if [ "$1" -gt 1 ] && [ "$n" -gt "$STAGE_EV" ]; then recap=$(sed -n "$((STAGE_EV + 1)),\$p" "$LOGDIR/events.log" | tail -n 3); fi
  STAGE_EV=$n
  logln "" "#### Stage $1/${#STAGES[@]}: ${STAGES[$1 - 1]}"
  if [ "$UI" != gum ]; then
    printf '\n#### Stage %d/%d: %s\n' "$1" "${#STAGES[@]}" "${STAGES[$1 - 1]}"
    return 0
  fi
  if [ "$1" -gt 1 ]; then fresh_screen; fi
  for i in "${!STAGES[@]}"; do
    if [ "$i" -gt 0 ]; then s+="${C_DIM} › ${C_OFF}"; fi
    if [ "$i" -lt $(($1 - 1)) ]; then
      s+="${C_OK}✓ ${STAGES[i]}${C_OFF}"
    elif [ "$i" = $(($1 - 1)) ]; then
      s+="${C_B}${C_ACC}● ${STAGES[i]}${C_OFF}"
    else
      s+="${C_DIM}○ ${STAGES[i]}${C_OFF}"
    fi
  done
  w=$(cols)
  w=$((w > 80 ? 78 : w - 2))
  rule="── Run $RUN · $(mode_name) · $ACTIVE dies, $PASSIVE takes over · $(dur $((SECONDS - RUN_T0))) "
  printf -v fill '%*s' $((w - ${#rule} > 0 ? w - ${#rule} : 0)) ''
  printf '\n %s%s%s\n %s\n' "$C_DIM" "$rule${fill// /─}" "$C_OFF" "$s"
  if [ -n "$recap" ]; then   # the end of the last stage, so the clear screen keeps some context
    printf '\n   %s%s ended with:%s\n' "$C_DIM" "${STAGES[$1 - 2]}" "$C_OFF"
    while read -r i s; do printf '   %s◆ %s %s%s\n' "$C_DIM" "${i:11:8}" "$s" "$C_OFF"; done <<<"$recap"
  fi
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
backup_running() { oc --context "$1" get "$VBACKUP" -n "$NS" -o jsonpath='{.items[*].status.phase}' 2>/dev/null | grep -qwE 'New|InProgress'; }
recent_backups() {
  oc --context "$1" get "$VBACKUP" -n "$NS" --sort-by=.status.startTimestamp \
    -o custom-columns='NAME:.metadata.name,PHASE:.status.phase,START:.status.startTimestamp' | tail -n 6 | show
}

revision() {   # the REVISION an app's route serves, or ? when it does not answer
  local rev; rev=$(curl -s --max-time 5 "$1" 2>/dev/null | grep -o 'REVISION v[0-9]*' | head -n 1 | cut -d' ' -f2 || true)
  echo "${rev:-?}"
}
serves() { [ "$(revision "$1")" = "$2" ]; }
http_ok() { [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$1")" = 200 ]; }
app_state() {   # app_state <context> <Application name>: "Synced Healthy" when all is well
  oc --context "$1" get "$APP" -A --field-selector "metadata.name=$2" \
    -o jsonpath='{.items[0].status.sync.status} {.items[0].status.health.status}' 2>/dev/null || true
}

has_dr_role() { some "$1" "$APP" dr-role -n "$GNS"; }
dr_role_state() { oc --context "$1" get "$APP" dr-role -n "$GNS" -o jsonpath='{.status.sync.status} {.status.health.status}' 2>/dev/null || true; }
dr_role_synced() { [ "$(dr_role_state "$1")" = "Synced Healthy" ]; }
dr_role_automated() { [ -n "$(oc --context "$1" get "$APP" dr-role -n "$GNS" -o jsonpath='{.spec.syncPolicy.automated}' 2>/dev/null)" ]; }
dr_role_has() {   # dr-role on <context> compares against <rev> or a later commit
  local cur; cur=$(oc --context "$1" get "$APP" dr-role -n "$GNS" -o jsonpath='{.status.sync.revision}' 2>/dev/null) || return 1
  [ -n "$cur" ] && { [ "$cur" = "$2" ] || git merge-base --is-ancestor "$2" "$cur" 2>/dev/null; }
}
suspend_dr_role() { oc --context "$1" patch "$APP" dr-role -n "$GNS" --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}' >/dev/null; }
resume_dr_role() {
  oc --context "$1" patch "$APP" dr-role -n "$GNS" --type merge \
    -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}' >/dev/null
}
refresh_dr_role() { oc --context "$1" annotate "$APP" dr-role -n "$GNS" "argocd.argoproj.io/refresh=$2" --overwrite >/dev/null; }

msa_token() {
  oc --context "$1" get managedserviceaccount auto-import-account -n "$MANAGED" \
    -o jsonpath='{.status.conditions[?(@.type=="TokenReported")].status} {.status.expirationTimestamp}' 2>/dev/null || true
}
msa_fresh() { local t; t=$(msa_token "$1"); [ "${t%% *}" = True ] && [[ ${t#* } > $(date -u -d '+24 hours' +%FT%TZ) ]]; }
token_adopted() {
  [ "$(msa_token "$1" | cut -d' ' -f1)" = True ] &&
    [ "$(oc --context "$1" get secret auto-import-account -n "$MANAGED" \
      -o jsonpath='{.metadata.ownerReferences[0].kind}' 2>/dev/null)" = ManagedServiceAccount ]
}

nodes_ready() {
  local out; out=$(oc --context "$1" get nodes --no-headers 2>/dev/null) && [ -n "$out" ] && [ -z "$(awk '$2 !~ /^Ready/' <<<"$out")" ]
}
pending_csr_names() {
  oc --context "$1" get csr -o go-template='{{range .items}}{{if not .status}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}' 2>/dev/null || true
}
pending_csrs() { [ -n "$(pending_csr_names "$1")" ]; }
approve_csrs() { pending_csr_names "$1" | xargs -r oc --context "$1" adm certificate approve; }
settled() { nodes_ready "$1" && not pending_csrs "$1"; }
ready_up() {   # wait for <context>'s API, then approve certificates until its nodes are Ready (G.1's power-on note)
  local c=$1 t0 end=$((SECONDS + 1800))
  alive "$c" || wait_until 7200 "$c's API to answer" alive "$c"
  t0=$SECONDS
  spin_begin "approving pending certificate requests on $c until its nodes are Ready (up to 30 min)"
  until poll settled "$c"; do
    [ "$SECONDS" -lt "$end" ] || die "$c: nodes not Ready, or certificate requests still pending, after 30 min"
    approve_csrs "$c" 2>&1 | to_log || true
    pause 20
  done
  spin_stop
  finished "$c: nodes Ready, no pending certificate requests ($(dur $((SECONDS - t0))))"
}

# --- git ---------------------------------------------------------------------

git_ready() {
  [ -z "$(git status --porcelain --untracked-files=no)" ] || die "the repo at $REPO has uncommitted changes"
  quiet git checkout -q "$BRANCH"
  quiet git pull -q --ff-only
}
overlay() { sed -n 's/^  - //p' "dr/$1/kustomization.yaml" | paste -sd' ' -; }
new_stamp() {   # new_stamp <branch prefix>: a UTC minute stamp no branch of that name uses yet
  local s
  while s=$(date -u +%Y%m%d%H%M) &&
    { git rev-parse -q --verify "refs/heads/$1-$s" >/dev/null || git ls-remote --exit-code -q origin "refs/heads/$1-$s" >/dev/null 2>&1; }; do
    sleep 20
  done
  echo "$s"
}
repo_url() { git remote get-url origin | sed -e 's#^git@github.com:#https://github.com/#' -e 's#\.git$##'; }
uri() { jq -rn --arg s "$1" '$s | @uri'; }
open_pr() {   # open_pr <branch> <title> <body> [line...]: a PR for you to review and merge
  local url
  logln "PR title: $2" "PR body:"
  printf '%s\n' "$3" | sed 's/^/   | /' >&3
  if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
    url=$(gh pr create --base "$BRANCH" --head "$1" --title "$2" --body "$3" 2>&3) || die "gh pr create failed (the log has its message)"
    url=$(tail -n 1 <<<"$url")
  else
    # the compare page with the title and body filled in
    url="$(repo_url)/compare/$BRANCH...$1?expand=1&title=$(uri "$2")&body=$(uri "$3")"
  fi
  your_turn "review and merge \"$2\"" "${@:4}"
  # outside the box, so the terminal keeps the link in one piece (and with gum, an OSC 8 link too)
  logln "   $url"
  if [ "$UI" = gum ]; then
    printf '   \e]8;;%s\e\\%s%s%s\e]8;;\e\\\n' "$url" "$C_ACC" "$url" "$C_OFF"
  else
    echo "   $url"
  fi
}
merged() { git fetch -q origin "$BRANCH" 2>/dev/null && git show "origin/$BRANCH:dr/$1/kustomization.yaml" 2>/dev/null | grep -Fx -- "  - $2" >/dev/null; }
wait_merged() {   # wait_merged <hub> <resources line the merge brings>
  EVERY=15 wait_until 7200 "the PR to land on $BRANCH" merged "$1" "$2"
  quiet git checkout -q "$BRANCH"
  quiet git pull -q --ff-only
}

# --- check -------------------------------------------------------------------

expect() {   # expect <ok text> <red text> <command...>: one pre-flight line
  local good=$1 bad=$2; shift 2
  if "$@" >/dev/null 2>&1; then ok "$good"; else red "$bad"; fi
}

cmd_check() {
  local a=${1:-$ACTIVE} p=${2:-$PASSIVE} c out newest
  BAD=0
  say "Clusters"
  for c in "$a" "$p" "$MANAGED"; do
    expect "$c API answers" "$c API does not answer" alive "$c"
  done
  if [ "$BAD" = 1 ]; then verdict bad "PRE-FLIGHT RED: power the clusters on, then run hack/dr.sh nodes"; return 1; fi
  for c in "$a" "$p" "$MANAGED"; do
    expect "$c nodes Ready" "$c has nodes not Ready (hack/dr.sh nodes $c)" nodes_ready "$c"
    expect "$c has no pending certificate requests" "$c has pending certificate requests (hack/dr.sh nodes $c)" not pending_csrs "$c"
  done

  say "Posture: $a active, $p passive (0.1)"
  expect "$a schedule-acm Enabled" "$a schedule-acm is '$(phase "$a" "$BSCHED" schedule-acm)'" schedule_enabled "$a"
  expect "$a has no passive restore" "$a has a restore-acm-passive-sync" none "$a" "$RESTORE" restore-acm-passive-sync -n "$NS"
  expect "$MANAGED Available on $a" "$MANAGED not Available on $a" mc_available "$a" True
  expect "$p restore-acm-passive-sync Enabled" "$p passive restore is '$(phase "$p" "$RESTORE" restore-acm-passive-sync)'" \
    restore_enabled "$p" restore-acm-passive-sync
  expect "$p does not list $MANAGED" "$p also lists $MANAGED (two hubs claim it)" none "$p" managedcluster "$MANAGED"
  expect "$p has no BackupSchedule" "$p has a BackupSchedule" none "$p" "$BSCHED" -n "$NS"
  expect "$p has no Velero schedules" "$p has Velero schedules (Manual Pull Path G.2)" none "$p" "$VSCHED" -n "$NS"
  if some "$p" "$RESTORE" restore-acm-activate -n "$NS"; then
    note "$p still holds a fixed-name restore-acm-activate: a manual failover deletes it first (D.2)"
  fi

  say "MSA token chain (0.2)"
  expect "auto-import-account on $a: $(msa_token "$a")" \
    "auto-import-account on $a: '$(msa_token "$a")' (want True and an expiry more than a day out; 0.2)" msa_fresh "$a"

  say "Backups (0.3)"
  out=$(oc --context "$a" get "$VBACKUP" -n "$NS" -o json 2>/dev/null | jq -r '
    [.items[] | select(.metadata.name | startswith("acm-credentials-schedule-"))]
    | sort_by(.status.startTimestamp // "") | last // {} | "\(.status.phase // "none") \(.status.startTimestamp // "-")"' || true)
  if [ "${out%% *}" = Completed ] && [[ ${out#* } > $(date -u -d '-40 minutes' +%FT%TZ) ]]; then
    ok "newest credentials backup Completed, started ${out#* }"
  else
    red "newest credentials backup: '$out' (want Completed, started in the last 40 min)"
    newest=$(oc --context "$a" get "$VBACKUP" -n "$NS" -o json 2>/dev/null | jq -r '
      [.items[] | select((.metadata.name | startswith("acm-credentials-schedule-")) and .status.phase == "Completed")]
      | sort_by(.status.startTimestamp) | last | .status.startTimestamp // ""' || true)
    if [ -n "$newest" ]; then
      note "the newest Completed one started $newest. Right after a power-on a failed set is usually transient: check again after the next set at $(next_slot)"
    fi
  fi

  say "Passive hub readiness (0.4)"
  expect "$p has namespace open-cluster-management-global-set" "$p lacks namespace open-cluster-management-global-set" \
    some "$p" ns open-cluster-management-global-set
  expect "$p has no stray Route CRD" "$p has a stray routes.route.openshift.io CRD" none "$p" crd routes.route.openshift.io
  out=$(oc --context "$p" get pods -n "$GNS" --no-headers 2>/dev/null | awk '$3 != "Running" && $3 != "Completed" {print $1, $3}' || true)
  if [ -z "$out" ]; then ok "$p Argo CD pods Running"; else red "$p Argo CD pods not Running: $out"; fi
  for c in "$a" "$p"; do
    out=$(oc --context "$c" get backupstoragelocation -n "$NS" -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)
    if [ "$out" = Available ]; then ok "$c BSL Available"; else red "$c BSL is '$out'"; fi
  done

  if has_dr_role "$a" || has_dr_role "$p"; then
    say "Git-driven roles (Automated Pull Path P.2 and pre-flight)"
    for c in "$a" "$p"; do
      expect "$c dr-role Synced Healthy" "$c dr-role is '$(dr_role_state "$c")'" dr_role_synced "$c"
      expect "$c dr-role automation on" "$c dr-role automation is off (finish H.1)" dr_role_automated "$c"
    done
    newest=$(oc --context "$a" get "$VBACKUP" -n "$NS" -o json 2>/dev/null | jq -r '
      [.items[] | select((.metadata.name | startswith("acm-resources-schedule-")) and .status.phase == "Completed")]
      | sort_by(.status.startTimestamp) | last | .metadata.name // ""' || true)
    out=$(oc --context "$a" -n "$NS" exec deploy/velero -- /velero backup describe "$newest" --details 2>/dev/null |
      awk '/v1alpha1\/Application:/ {f = 1; next} f && /^ *- / {print $2; next} f {exit}' || true)
    if [ -z "$out" ]; then
      red "could not list the Applications in backup '$newest' (P.2)"
    elif grep -q '/dr-role$' <<<"$out"; then
      red "backup $newest contains dr-role: a restore would deliver the wrong role (P.2)"
    else
      ok "backup $newest holds $(wc -l <<<"$out") Applications and no dr-role"
    fi
  fi

  say "Workload"
  expect "pull app answers 200 (serves $(revision "$APP_URL"))" "pull app does not answer 200 (tried for 30 s)" wait_for 30 http_ok "$APP_URL"
  out=$(app_state "$MANAGED" "hello-failover-$MANAGED")
  if [ "$out" = "Synced Healthy" ]; then ok "pull app Synced Healthy on $MANAGED"; else red "pull app on $MANAGED is '$out'"; fi
  if [ -n "$PUSH_APP_URL" ]; then
    expect "push app answers 200 (serves $(revision "$PUSH_APP_URL"))" "push app does not answer 200 (tried for 30 s)" wait_for 30 http_ok "$PUSH_APP_URL"
    out=$(app_state "$a" "hello-failover-push-$MANAGED")
    if [ "$out" = "Synced Healthy" ]; then ok "push app Synced Healthy on $a"; else red "push app on $a is '$out'"; fi
  fi

  if [ "$BAD" = 0 ]; then
    verdict ok "PRE-FLIGHT GREEN: $a active, $p passive"
  else
    verdict bad "PRE-FLIGHT RED: fix the RED lines first"
    return 1
  fi
}

cmd_nodes() {
  local c
  [ ${#ARGS[@]} -gt 0 ] || ARGS=("$ACTIVE" "$PASSIVE" "$MANAGED")
  for c in "${ARGS[@]}"; do ready_up "$c"; done
}

# --- probes (A) --------------------------------------------------------------

probe_http() { while true; do echo "$(now) $(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$1")"; sleep 10; done; }
probe_pointer() {
  while true; do
    echo "$(now) $(oc --context "$1" get secret bootstrap-hub-kubeconfig -n open-cluster-management-agent \
      -o jsonpath='{.data.kubeconfig}' --request-timeout=5s 2>/dev/null | base64 -d 2>/dev/null | awk '/server:/ {print $2}')"
    sleep 10
  done
}
probe_revision() {   # one line each time an app's served revision changes
  local last="" cur
  while true; do
    cur="pull=$(revision "$APP_URL")"
    if [ -n "$PUSH_APP_URL" ]; then cur="$cur push=$(revision "$PUSH_APP_URL")"; fi
    if [[ $cur != *'?'* ]] && [ "$cur" != "$last" ]; then echo "$(now) $cur"; last=$cur; fi
    sleep 10
  done
}

spawn() {   # spawn <log> <internal command> [arg]: a probe in its own session, so it outlives the terminal
  local log=$1; shift
  PROBE_PIDS=$LOGDIR/probe.pids setsid bash "$SELF" "$@" >>"$LOGDIR/$log" 2>/dev/null </dev/null 3>&- &
}
probes_running() { [ -s "$LOGDIR/probe.pids" ] && kill -0 "$(head -n 1 "$LOGDIR/probe.pids")" 2>/dev/null; }

probe_start() {
  local f
  if probes_running; then note "probes already running for run $RUN"; return 0; fi
  rm -f "$LOGDIR/probe.pids"
  spawn probe.log _probe-http "$APP_URL"
  if [ -n "$PUSH_APP_URL" ]; then spawn probe-push.log _probe-http "$PUSH_APP_URL"; fi
  spawn hub-pointer.log _probe-pointer "$MANAGED"
  spawn revisions.log _probe-revision
  event "A probes started"
  spin_begin "waiting for the probes' first samples"
  pause 15
  spin_stop
  for f in "$LOGDIR"/probe*.log "$LOGDIR/hub-pointer.log" "$LOGDIR/revisions.log"; do
    if [ -s "$f" ]; then echo "$(basename "$f"): $(tail -n 1 "$f")"; else echo "$(basename "$f"): no sample yet"; fi
  done | show
}
probe_stop() {
  local pid
  if [ ! -s "$LOGDIR/probe.pids" ]; then note "no probes recorded for run $RUN"; return 0; fi
  while read -r pid; do kill -- "-$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true; done <"$LOGDIR/probe.pids"
  rm -f "$LOGDIR/probe.pids"
  event "A probes stopped"
}

# the time of the last event matching <regex>, or nothing
ev() { awk -v re="$1" '$0 ~ re {t = $1} END {print t}' "$LOGDIR/events.log" 2>/dev/null || true; }
span() {   # span <label> <from event> <to event>: a timing row when both happened
  local a b
  a=$(ev "$2")
  b=$(ev "$3")
  if [ -n "$a" ] && [ -n "$b" ]; then
    printf '%s\t%s\n' "$1" "$(dur $(($(date -u -d "$b" +%s) - $(date -u -d "$a" +%s))))"
  fi
}
timings() {
  local act=" D.2 activation applied" from=Activation
  if [ -n "$(ev " D'.2 PR-A merged")" ]; then act=" D'.2 PR-A merged" from="PR-A merge"; fi
  printf 'Measure\tTime\n'
  span "Hub dead to $MANAGED claimed on the new hub" " B.1 .* API dead" " D.3 claim landed"
  span "Pull deploy: pushed to served, no hub" " C deploy pushed" " C pull app serves"
  span "Push deploy: pushed to served (push delivery RTO)" " C deploy pushed" " E' push delivery back"
  span "Death gate to activation" " B .*death gate passed" " D.2 activation applied"
  span "PR-A: pushed to merged" " D'.1 PR-A branch" " D'.2 PR-A merged"
  span "$from to claim (D.3)" "$act" " D.3 claim landed"
  span "$from to all addons Available (E.1)" "$act" " E.1 all addons Available"
  span "$from to the first backup set (F.1)" "$act" " F.1 first backup set Completed"
  span "PR-B: pushed to merged" " F' PR-B branch" " F' PR-B merged"
  span "Demote PR: pushed to merged" " G'.1 demote branch" " G'.1 demote PR merged"
  span "Old hub back to its lease running out (G.1)" " G .* API answers" " G.1 .* Unknown"
  span "Whole run: start to rejoin done" " run [0-9]+ started" " rejoin done"
}
avail_rows() {   # avail_rows <name> <probe log> [cut time]: one table row, or two split at the cut
  awk -v n="$1" -v c="${3:-}" '
    function row(label, w) { printf "%s\t%d\t%d\t%s to %s\n", label, s[w], f[w], substr(a[w], 12, 8), substr(b[w], 12, 8) }
    { w = (c != "" && $1 < c) ? 1 : 2; s[w]++; if ($2 != "200") f[w]++; if (!(w in a)) a[w] = $1; b[w] = $1 }
    END {
      if (c == "") { if (s[2]) row(n, 2); exit }
      if (s[1]) row(n " before the cut", 1)
      if (s[2]) row(n " from the cut on", 2)
    }' "$2"
}
summary() {   # the tables come last, so they are what stays on the screen
  local f n cut
  cut=$(ev " B.1 .* API dead")
  say "Run $RUN summary ($LOGDIR)"
  if [ -s "$LOGDIR/events.log" ]; then label "Events"; show <"$LOGDIR/events.log"; fi
  if [ -f "$LOGDIR/hub-pointer.log" ]; then
    label "Hub pointer (which hub $MANAGED reports to)"
    awk '{s = $2 == "" ? "(read failed)" : $2} s != last {print $1, s; last = s}' "$LOGDIR/hub-pointer.log" | show
  fi
  if [ -s "$LOGDIR/revisions.log" ]; then label "Served revisions"; show <"$LOGDIR/revisions.log"; fi
  if compgen -G "$LOGDIR/probe*.log" >/dev/null; then
    for f in "$LOGDIR"/probe*.log; do
      if grep -q -v ' 200$' "$f"; then   # up to 3 from before the cut, up to 5 from the cut on
        label "$(basename "$f"), samples not 200:"
        awk -v c="$cut" '$2 == "200" {next} c != "" && $1 < c {if (b++ < 3) print $0 "   (before the cut)"; next} a++ < 5' "$f" | show
      fi
    done
    {
      printf 'Availability\tSamples\tNot 200\tSampled (UTC)\n'
      for f in "$LOGDIR/probe.log" "$LOGDIR/probe-push.log"; do
        [ -f "$f" ] || continue
        if [ "$(basename "$f")" = probe.log ]; then n="pull app"; else n="push app"; fi
        avail_rows "$n" "$f" "$cut"
      done
    } | table
  fi
  if [ -s "$LOGDIR/events.log" ]; then timings | table; fi
}

cmd_probe() {
  case ${ARGS[0]:-} in
    start) probe_start ;;
    stop) probe_stop ;;
    summary)
      if [ -n "${ARGS[1]:-}" ]; then   # an earlier run's summary, from its logs
        [[ ${ARGS[1]} =~ ^[0-9]+$ ]] || die "usage: hack/dr.sh probe summary [run number]"
        RUN=${ARGS[1]} LOGDIR=$HOME/acm-dr/runs/run-${ARGS[1]}
        [ -d "$LOGDIR" ] || die "no logs for run $RUN in $LOGDIR"
      fi
      summary
      ;;
    *) die "usage: hack/dr.sh probe start|stop|summary [run number]" ;;
  esac
}

# --- outage (B) --------------------------------------------------------------

next_slot() {   # the next :00/:30 backup slot, as HH:MMZ
  local h m
  h=$(date -u +%H) m=$((10#$(date -u +%M)))
  if [ "$m" -lt 30 ]; then echo "$h:30Z"; else printf '%02d:00Z\n' $(((10#$h + 1) % 24)); fi
}
slot_clear() {   # 5 to 26 min past a :00/:30 slot, and no backup in progress
  local m=$((10#$(date -u +%M) % 30))
  [ "$m" -ge 5 ] && [ "$m" -le 26 ] && not backup_running "$1"
}

cmd_outage() {
  local a=$ACTIVE node
  alive "$a" || die "$a's API does not answer: is it already down?"
  say "B.0: lab safety net, an etcd backup of $a"
  node=$(oc --context "$a" get nodes -l node-role.kubernetes.io/master -o jsonpath='{.items[0].metadata.name}')
  spin_cmd "etcd backup on $node" \
    oc --context "$a" debug "node/$node" -- chroot /host /usr/local/bin/cluster-backup.sh /home/core/assets/backup ||
    die "the etcd backup on $node failed: its output is above"
  event "B.0 etcd backup saved on $a ($node:/home/core/assets/backup)"
  wait_until 1800 "a cut time clear of the :00/:30 backup slots, with no backup in progress" slot_clear "$a"
  recent_backups "$a"

  say "B.1: the outage"
  your_turn "cut $a's power now" \
    "Hold the power button about 5 s (a short press is a graceful shutdown), pull the plug, or use a hard power-off." \
    "The script carries on when $a's API stops answering."
  wait_until 1800 "$a's API to stop answering" dead "$a"
  event "B.1 $a API dead (power cut by hand)"
  say "B.2: the workload does not care"
  spin_begin "letting the probes sample the outage"
  pause 20
  spin_stop
  if [ -s "$LOGDIR/probe.log" ]; then tail -n 3 "$LOGDIR/probe.log" | show; else note "no availability probe running (hack/dr.sh probe start)"; fi
}

# --- deploy (C) --------------------------------------------------------------

rev_of() { grep -o 'REVISION v[0-9]*' "$1" | head -n 1 | grep -o '[0-9]*$'; }

cmd_deploy() {
  local f=apps/hello-failover/configmap.yaml fp=apps/hello-failover-push/configmap.yaml n np
  git_ready
  n=$(($(rev_of "$f") + 1))
  np=$(($(rev_of "$fp") + 1))
  say "C: push pull v$n and push v$np with $ACTIVE down"
  sed -i "s/REVISION v[0-9]*/REVISION v$n/" "$f"
  sed -i "s/REVISION v[0-9]*/REVISION v$np/" "$fp"
  quiet git add "$f" "$fp"
  quiet git commit -q -m "REVISION pull v$n, push v$np (DR run $RUN, mid-outage deploy)"
  quiet git push -q
  echo "$n $np" >"$LOGDIR/deploy.rev"
  event "C deploy pushed: pull v$n, push v$np"
  wait_until 900 "the pull app to serve v$n" serves "$APP_URL" "v$n"
  event "C pull app serves v$n"
  if [ -n "$PUSH_APP_URL" ]; then
    note "push app serves $(revision "$PUSH_APP_URL") (C': it stays on the old revision until a hub pushes again)"
  fi
}

# --- failover (D-F) ----------------------------------------------------------

activation_restore() {   # wait for <name> to finish; one retry for the git-driven race (D'.3)
  local p=$PASSIVE name=$1 msg
  wait_until 600 "$name to finish" restore_finished "$p" "$name"
  if [ "$(phase "$p" "$RESTORE" "$name")" != Finished ] && [ "$GIT" = 1 ]; then
    msg=$(oc --context "$p" get "$RESTORE" "$name" -n "$NS" -o jsonpath='{.status.lastMessage}' || true)
    if [[ $msg == *"currently active"* ]]; then
      event "D'.3 $name was ignored while another restore or schedule was active: deleting it for selfHeal to re-create"
      quiet oc --context "$p" delete "$RESTORE" "$name" -n "$NS"
      spin_begin "giving selfHeal a moment to re-create $name"
      pause 15
      spin_stop
      wait_until 600 "the re-created $name to finish" restore_finished "$p" "$name"
    fi
  fi
  if [ "$(phase "$p" "$RESTORE" "$name")" != Finished ]; then
    oc --context "$p" describe "$RESTORE" "$name" -n "$NS" | tail -n 25 | show || true
    die "$name ended $(phase "$p" "$RESTORE" "$name"): read the message above (Manual Pull Path D.2 failure modes)"
  fi
  event "D.2 $name Finished"
}

claim_and_verify() {   # D.3, E.1, E.2, E.3 on the new hub
  local p=$PASSIVE n
  say "D.3: the claim"
  wait_until 300 "the restored ManagedCluster $MANAGED on $p" some "$p" managedcluster "$MANAGED"
  EVERY=1 wait_until 900 "$MANAGED to be Available on $p" mc_available "$p" True
  event "D.3 claim landed: $MANAGED Available on $p"
  show oc --context "$p" get managedclusters
  say "E.1: addons"
  wait_until 900 "every addon on $MANAGED to be Available" addons_available "$p"
  event "E.1 all addons Available"
  show oc --context "$p" get managedclusteraddon -n "$MANAGED"
  say "E.2: re-home evidence"
  if [ -s "$LOGDIR/hub-pointer.log" ]; then
    awk '{s = $2 == "" ? "(read failed)" : $2} s != last {print $1, s; last = s}' "$LOGDIR/hub-pointer.log" | tail -n 3 | show
  fi
  n=$(grep -c -v ' 200$' "$LOGDIR/probe.log" 2>/dev/null || true)
  if [ "${n:-0}" = 0 ]; then ok "the pull app answered 200 at every availability sample so far"; else note "$n availability samples were not 200"; fi
  say "E.3: the restored MSA secret"
  if try_until 120 "the controller to adopt the restored token" token_adopted "$p"; then
    event "E.3 restored token adopted and rotated by the controller ($(msa_token "$p"))"
  else
    note "the restored token was not adopted within 2 min: deleting it so the controller mints a fresh one"
    quiet oc --context "$p" delete secret auto-import-account -n "$MANAGED"
    wait_until 300 "the token to be re-minted" token_adopted "$p"
    event "E.3 frozen restored token deleted and re-minted ($(msa_token "$p"))"
  fi
}

promote_checks() {   # F.1's gate and F.2
  local p=$PASSIVE t
  wait_until 600 "schedule-acm Enabled on $p" schedule_enabled "$p"
  t=$(oc --context "$p" get "$BSCHED" schedule-acm -n "$NS" -o jsonpath='{.metadata.creationTimestamp}')
  wait_until 900 "the first full backup set on $p" backup_set_after "$p" "$t"
  event "F.1 first backup set Completed on $p"
  recent_backups "$p"
  say "F.2: GitOps wiring"
  show oc --context "$p" get gitopscluster,placement,applicationset -n "$GNS"
  show oc --context "$p" get "$APP" -n "$GNS"
}

push_resurrection() {   # E': the push app serving the mid-outage revision is push delivery back
  local np
  if [ -z "$PUSH_APP_URL" ] || [ ! -s "$LOGDIR/deploy.rev" ]; then return 0; fi
  np=$(cut -d' ' -f2 "$LOGDIR/deploy.rev")
  say "E': push delivery"
  show oc --context "$PASSIVE" get secret -n "$GNS" -l apps.open-cluster-management.io/acm-cluster=true
  if try_until 1200 "the push app to serve v$np" serves "$PUSH_APP_URL" "v$np"; then
    event "E' push delivery back: push app serves v$np"
  else
    event "E' push app still not serving v$np after 20 min"
    note "see the Manual Push Path E' failure modes"
  fi
}

failover_manual() {
  local p=$PASSIVE
  say "D: activate $p by hand"
  confirm "Activate $p now?"
  if has_dr_role "$p"; then
    suspend_dr_role "$p"
    not dr_role_automated "$p" || die "could not suspend dr-role on $p"
    event "D.0 dr-role automation suspended on $p"
  fi
  # a Finished restore under the same name would make D.2's apply a silent no-op
  quiet oc --context "$p" delete "$RESTORE" restore-acm-activate -n "$NS" --ignore-not-found
  quiet oc --context "$p" delete "$RESTORE" restore-acm-passive-sync -n "$NS" --ignore-not-found
  wait_until 120 "the passive restore to be gone" none "$p" "$RESTORE" restore-acm-passive-sync -n "$NS"
  event "D.1 passive restore deleted"
  quiet oc --context "$p" apply -f manifests/57-restore-activate.yaml
  event "D.2 activation applied"
  activation_restore restore-acm-activate
  claim_and_verify
  say "F.1: start backups on $p"
  quiet oc --context "$p" apply -f manifests/55-backupschedule.yaml
  event "F.1 BackupSchedule applied on $p"
  promote_checks
}

failover_git() {
  local p=$PASSIVE stamp
  has_dr_role "$p" || die "no dr-role on $p: dr/ was never bootstrapped, so use the manual path"
  dr_role_automated "$p" || die "dr-role automation is off on $p: finish the last run's re-align (H.1) first"
  git_ready
  [ "$(overlay "$p")" = ../roles/passive ] || die "dr/$p lists '$(overlay "$p")', not ../roles/passive"
  stamp=$(new_stamp failover)
  echo "$stamp" >"$LOGDIR/stamp"

  say "D'.1: the activation PR (PR-A)"
  quiet git checkout -q -b "failover-$stamp"
  cp dr/templates/restore-activate.template.yaml "dr/$p/restore-activate-$stamp.yaml"
  sed -i "s/<UTCSTAMP>/$stamp/" "dr/$p/restore-activate-$stamp.yaml"
  sed -i "s#^  - ../roles/passive\$#  - restore-activate-$stamp.yaml#" "dr/$p/kustomization.yaml"
  [ "$(overlay "$p")" = "restore-activate-$stamp.yaml" ] || die "dr/$p lists '$(overlay "$p")'"
  quiet git add dr/
  quiet git commit -q -m "FAILOVER: activate $p ($ACTIVE dead $(now))"
  quiet git push -q -u origin HEAD
  event "D'.1 PR-A branch failover-$stamp pushed"
  quiet git checkout -q "$BRANCH"
  say "D'.2: review = the death gate, merge = the decision"
  open_pr "failover-$stamp" "FAILOVER: activate $p" \
    "Activation only (PR-A). Review gate: $ACTIVE is dead; hack/dr.sh found its API refusing connections at $(now). Merging is the failover decision." \
    "The review is the death gate: confirm $ACTIVE is dead with the check below the link." \
    "Merging is the failover decision."
  line "   death check: curl -sk --max-time 5 $(server "$ACTIVE")/version || echo DEAD"
  wait_merged "$p" "restore-activate-$stamp.yaml"
  event "D'.2 PR-A merged"
  if not dead "$ACTIVE"; then note "$ACTIVE no longer reads dead: if it is back, you now have two live hubs (B.1 failure)"; fi

  say "D'.3: $p executes"
  refresh_dr_role "$p" normal
  activation_restore "restore-acm-activate-$stamp"
  claim_and_verify

  say "F': the promotion PR (PR-B)"
  git_ready
  quiet git checkout -q -b "promote-$stamp"
  sed -i "s#^  - restore-activate-$stamp.yaml\$#  - ../roles/active\n  - restore-activate-$stamp.yaml#" "dr/$p/kustomization.yaml"
  [ "$(overlay "$p")" = "../roles/active restore-activate-$stamp.yaml" ] || die "dr/$p lists '$(overlay "$p")'"
  quiet git add dr/
  quiet git commit -q -m "PROMOTE: $p to full active (claim verified)"
  quiet git push -q -u origin HEAD
  event "F' PR-B branch promote-$stamp pushed"
  quiet git checkout -q "$BRANCH"
  open_pr "promote-$stamp" "PROMOTE: $p to full active" \
    "Promotion (PR-B). Review gate: $MANAGED is claimed on $p:
$(oc --context "$p" get managedclusters -o custom-columns='NAME:.metadata.name,AVAILABLE:.status.conditions[?(@.type=="ManagedClusterConditionAvailable")].status')" \
    "The review gate: $MANAGED is claimed on $p (the PR body shows it)." \
    "Merging makes $p fully active: it starts taking backups."
  wait_merged "$p" "../roles/active"
  event "F' PR-B merged"
  refresh_dr_role "$p" normal
  promote_checks
}

cmd_failover() {
  say "B: the death gate"
  alive "$PASSIVE" || die "$PASSIVE does not answer either"
  alive "$MANAGED" || die "$MANAGED does not answer: the network path is in doubt, so $ACTIVE's silence proves nothing"
  if alive "$ACTIVE"; then
    die "$ACTIVE's API still answers. Activating $PASSIVE now would leave two live hubs claiming $MANAGED. Cut its power first."
  fi
  dead "$ACTIVE" || die "$ACTIVE's API name does not resolve: that is DNS trouble, not proof of death"
  spin_begin "checking that $ACTIVE stays dead"
  pause 10
  spin_stop
  dead "$ACTIVE" || die "$ACTIVE's API answered again"
  event "B $ACTIVE API refuses connections or times out (death gate passed)"
  if [ "$GIT" = 1 ]; then failover_git; else failover_manual; fi
  push_resurrection
  event "failover done: $PASSIVE active"
  say "Failover done: $PASSIVE is active and backing up"
  if [ "$IN_RUN" = 0 ]; then line "Next: hack/dr.sh rejoin$(flag)"; fi
}

# --- rejoin (G, H.1) ---------------------------------------------------------

defuse() {   # G.2: the returned hub's BackupSchedule and the Velero schedules it owned
  oc --context "$1" delete "$BSCHED" schedule-acm -n "$NS" --ignore-not-found &&
    oc --context "$1" delete "$VSCHED" -n "$NS" --all &&
    none "$1" "$BSCHED" -n "$NS" && none "$1" "$VSCHED" -n "$NS"
}
defuse_now() {   # retry while the returned hub settles, approving certificates meanwhile
  local a=$1 end=$((SECONDS + 1800))
  spin_begin "deleting $a's BackupSchedule and Velero schedules (up to 30 min)"
  until poll defuse "$a"; do
    [ "$SECONDS" -lt "$end" ] || die "could not delete $a's schedules within 30 min"
    approve_csrs "$a" >/dev/null 2>&1 || true
    pause 10
  done
  spin_stop
  event "G.2 $a has no BackupSchedule and no Velero schedules"
  if ! schedule_enabled "$PASSIVE"; then
    note "$PASSIVE schedule-acm is '$(phase "$PASSIVE" "$BSCHED" schedule-acm)', not Enabled (Manual Pull Path G.2 failure)"
  fi
}
break_glass() {   # G.0: suspend dr-role on <context>, retrying while its API settles
  wait_until 1800 "the dr-role patch to land on $1" suspend_dr_role "$1"
  event "G.0 dr-role automation suspended on $1"
}

demote_git() {   # G'.1: the demote PR, mergeable while the hub is still down
  local a=$ACTIVE stamp
  git_ready
  if [ "$(overlay "$a")" = ../roles/passive ]; then note "dr/$a already lists ../roles/passive"; return 0; fi
  stamp=$(new_stamp demote)
  say "G'.1: the demote PR"
  quiet git checkout -q -b "demote-$stamp"
  sed -i 's#^  - ../roles/active$#  - ../roles/passive#; /^  - restore-activate-.*\.yaml$/d' "dr/$a/kustomization.yaml"
  quiet git rm -q --ignore-unmatch "dr/$a"/restore-activate-*.yaml
  [ "$(overlay "$a")" = ../roles/passive ] || die "dr/$a lists '$(overlay "$a")'"
  quiet git add -A dr/
  quiet git commit -q -m "DEMOTE: $a to passive"
  quiet git push -q -u origin HEAD
  event "G'.1 demote branch demote-$stamp pushed"
  quiet git checkout -q "$BRANCH"
  open_pr "demote-$stamp" "DEMOTE: $a to passive" \
    "Demote the failed hub. Review gate: posture correctness ($PASSIVE is active and backing up). Safe to merge while $a is down: it boots into this." \
    "The review gate: $PASSIVE is active and backing up." \
    "Merge it while $a is still down: it boots into this."
  wait_merged "$a" "../roles/passive"
  event "G'.1 demote PR merged"
}

realign_git() {   # H.1, after a manual failover
  local a=$ACTIVE p=$PASSIVE rev c
  say "H.1: re-align dr/ with the new roles, then re-enable automation"
  git_ready
  sed -i 's#^  - ../roles/active$#  - ../roles/passive#; /^  - restore-activate-.*\.yaml$/d' "dr/$a/kustomization.yaml"
  quiet git rm -q --ignore-unmatch "dr/$a"/restore-activate-*.yaml
  sed -i 's#^  - ../roles/passive$#  - ../roles/active#' "dr/$p/kustomization.yaml"
  if [ "$(overlay "$a")" != ../roles/passive ] || [ "$(overlay "$p")" != ../roles/active ]; then
    die "unexpected overlays after the re-align: dr/$a lists '$(overlay "$a")', dr/$p lists '$(overlay "$p")'"
  fi
  if [ -n "$(git status --porcelain dr/)" ]; then
    quiet git add -A dr/
    quiet git commit -q -m "Re-align dr/: $p active, $a passive (manual failover)"
    quiet git push -q
  fi
  rev=$(git rev-parse HEAD)
  for c in "$a" "$p"; do
    refresh_dr_role "$c" hard
    wait_until 300 "dr-role on $c to compare against ${rev:0:7}" dr_role_has "$c" "$rev"
  done
  for c in "$a" "$p"; do resume_dr_role "$c"; done
  for c in "$a" "$p"; do wait_until 300 "dr-role Synced Healthy on $c" dr_role_synced "$c"; done
  event "H.1 dr/ re-aligned at ${rev:0:7}; dr-role automation back on both hubs"
  for c in "$a" "$p"; do
    line "   $c:"
    show oc --context "$c" get "$BSCHED,$RESTORE" -n "$NS" \
      -o custom-columns='KIND:.kind,NAME:.metadata.name,CREATED:.metadata.creationTimestamp'
  done
}

cmd_rejoin() {
  local a=$ACTIVE p=$PASSIVE rev="" early=0
  if [ "$GIT" = 1 ]; then
    if alive "$a"; then
      # back before its demote merged: git still calls it active, so break glass as on the manual path
      note "$a answers before its demote merged: suspending its dr-role until the demote lands"
      early=1
      break_glass "$a"
      defuse_now "$a"
    fi
    demote_git
    rev=$(git rev-parse HEAD)
  fi

  say "G: $a comes back"
  your_turn "power $a back on now" \
    "The script carries on when its API answers: it approves certificate requests until the nodes are Ready, then makes $a passive."
  wait_until 7200 "$a's API to answer" alive "$a"
  event "G $a API answers"
  if [ "$GIT" = 0 ] && has_dr_role "$a"; then break_glass "$a"; fi
  defuse_now "$a"
  ready_up "$a"
  event "G $a nodes Ready"

  if [ "$GIT" = 1 ]; then
    say "G'.1: $a boots into the demote"
    refresh_dr_role "$a" hard
    wait_until 900 "dr-role on $a to compare against ${rev:0:7}" dr_role_has "$a" "$rev"
    if [ "$early" = 1 ]; then resume_dr_role "$a"; event "G'.1 dr-role automation back on $a"; fi
    wait_until 900 "dr-role Synced Healthy on $a" dr_role_synced "$a"
    defuse_now "$a"   # the pruned schedule's Velero schedules can outlive it after a boot
    quiet oc --context "$a" delete "$RESTORE" restore-acm-activate -n "$NS" --ignore-not-found   # untracked residue of a manual activation
  fi

  if some "$a" managedcluster "$MANAGED"; then
    say "G.1: wait out the lease (deleting the claim while it reads True would uninstall $MANAGED's agent)"
    wait_until 1800 "$MANAGED to read Available=Unknown on $a" mc_available "$a" Unknown
    event "G.1 $MANAGED Unknown on $a"
    say "G.3: drop the stale claim"
    spin_cmd "deleting the stale ManagedCluster $MANAGED on $a" oc --context "$a" delete managedcluster "$MANAGED" --timeout=5m ||
      die "could not delete the stale ManagedCluster $MANAGED on $a (Manual Pull Path G.3)"
    event "G.3 stale claim on $a deleted"
  fi

  say "G.4: $a as passive"
  if [ "$GIT" = 0 ]; then quiet oc --context "$a" apply -f manifests/56-restore-passive.yaml; fi
  wait_until 900 "restore-acm-passive-sync Enabled on $a" restore_enabled "$a" restore-acm-passive-sync
  event "G.4 $a passive sync Enabled"
  if [ "$GIT" = 0 ]; then
    say "G.5: the stale activation restores"
    oc --context "$a" get "$RESTORE" -n "$NS" -o name | { grep restore-acm-activate || true; } |
      xargs -r -n1 oc --context "$a" delete -n "$NS" 2>&1 | to_log
    event "G.5 old activation restores on $a deleted"
    if has_dr_role "$a" && has_dr_role "$p"; then realign_git; fi
  fi
  show oc --context "$a" get "$RESTORE" -n "$NS"

  sed -i -e "s/^ACTIVE=.*/ACTIVE=$p/" -e "s/^PASSIVE=.*/PASSIVE=$a/" "$DR_ENV"
  if grep -q '^RUN=' "$DR_ENV"; then sed -i "s/^RUN=.*/RUN=$((RUN + 1))/" "$DR_ENV"; else echo "RUN=$((RUN + 1))" >>"$DR_ENV"; fi
  event "rejoin done: $p active, $a passive (settings file: ACTIVE=$p PASSIVE=$a RUN=$((RUN + 1)))"
  cmd_check "$p" "$a" || note "the new posture is not green yet: rerun hack/dr.sh check in a few minutes"
}

# --- run ---------------------------------------------------------------------

run_started() {   # a run started again after a stop carries on in the same folder
  local k
  k=$(grep -c -E ' run [0-9]+ started' "$LOGDIR/events.log" 2>/dev/null || true)
  if [ "${k:-0}" -gt 0 ]; then event "run $RUN started (attempt $((k + 1)))"; else event "run $RUN started"; fi
}

cmd_run() {
  local stops="cut $ACTIVE's power and power it back on"
  IN_RUN=1 RUN_T0=$SECONDS
  if [ "$GIT" = 1 ]; then stops="cut $ACTIVE's power, merge three PRs, and power $ACTIVE back on"; fi
  box double 13 "DR run $RUN ($(mode_name)): $ACTIVE dies, $PASSIVE takes over" \
    "The script stops for what only you can do: $stops." \
    "Logs: $LOGDIR"
  stage 1
  cmd_check || die "pre-flight is red: fix it, then run again"
  confirm "Start run $RUN?"
  RUN_T0=$SECONDS
  run_started
  probe_start
  stage 2
  cmd_outage
  stage 3
  cmd_deploy
  stage 4
  cmd_failover
  stage 5
  cmd_rejoin
  stage 6
  probe_stop
  summary
  box rounded 10 "Run $RUN done in $(dur $((SECONDS - RUN_T0))): $PASSIVE active, $ACTIVE passive" \
    "The settings file now names run $((RUN + 1)). Next: hack/dr.sh check, then hack/dr.sh run (add --git for a git-driven run)."
}

# --- main --------------------------------------------------------------------

sanity() {
  local c ctxs
  ctxs=$(oc config get-contexts -o name)
  for c in "$ACTIVE" "$PASSIVE" "$MANAGED"; do
    grep -qx -- "$c" <<<"$ctxs" || die "no kubeconfig context named '$c' (KUBECONFIG=${KUBECONFIG:-default})"
  done
  if [ "$ACTIVE" = "$PASSIVE" ] || [ "$ACTIVE" = "$MANAGED" ] || [ "$PASSIVE" = "$MANAGED" ]; then
    die "ACTIVE, PASSIVE and MANAGED must be three different contexts"
  fi
}

ERR_AT=""
on_err() {   # remember where a command failed, for on_exit
  local f where=""
  for f in "${FUNCNAME[@]:1}"; do if [ "$f" != main ]; then where+="${where:+ < }$f"; fi; done
  ERR_AT="in ${where:-main}"
  if [[ $1 != return* ]]; then ERR_AT+=": $1"; fi
}
on_exit() {   # put the terminal back, and say why the script stopped if die did not
  local rc=$?
  if [ -n "$POLL_PID" ]; then kill "$POLL_PID" 2>/dev/null || true; fi
  spin_stop
  if [ "$rc" = 0 ]; then return 0; fi
  if [ "$DIED" = 0 ]; then
    if [ "$rc" = 130 ]; then
      box thick 9 "STOP" "interrupted" "" "Log: $LOGDIR/console.log"
    else
      box thick 9 "STOP" "hack/dr.sh stopped on a failed command ${ERR_AT:-} (exit $rc). Its output, if any, is above." "" "Log: $LOGDIR/console.log"
    fi
  fi
  if [ "$CMD" = run ] && probes_running; then note "the probes are still running: hack/dr.sh probe stop ends them"; fi
}

case $CMD in
  _probe-http) echo $$ >>"$PROBE_PIDS"; probe_http "${ARGS[0]}" ;;
  _probe-pointer) echo $$ >>"$PROBE_PIDS"; probe_pointer "${ARGS[0]}" ;;
  _probe-revision) echo $$ >>"$PROBE_PIDS"; probe_revision ;;
  check | nodes | probe | outage | deploy | failover | rejoin | run)
    if [ "$CMD" != check ] && [ "$CMD" != probe ]; then
      # both append, so the plain copy and any stray error output share console.log
      # shellcheck disable=SC2094
      exec 3>>"$LOGDIR/console.log" 2> >(tee -a "$LOGDIR/console.log" >&2)
      logln "" "#### $(now) hack/dr.sh $CMD${ARGS[*]:+ ${ARGS[*]}}$(flag)"
    fi
    trap on_exit EXIT
    trap 'exit 130' INT TERM
    set -E
    trap 'on_err "$BASH_COMMAND"' ERR
    sanity
    if [ "$CMD" = check ]; then cmd_check || { DIED=1; exit 1; }; else "cmd_$CMD"; fi
    ;;
  *) sed -n '2,/^set -euo/{/^set -euo/d;s/^# \{0,1\}//;p}' "$0"; exit 2 ;;
esac
