#!/usr/bin/env bash
# DR exercise driver: runs the runbooks' commands in order and enforces
# their gates. The runbooks (docs/runbooks/) explain each step; the labels
# below (B.0, D.2, G.3, ...) point into the Manual Pull Path runbook, the
# primed ones (D'.1, F', G'.1) into the Automated Pull Path.
#
# Usage: hack/dr.sh [command] [--git] [--yes]
#
# With no command, on a terminal, it says what the exercise does and offers
# a menu: Check, Run (Manual), Run (Git), Quit. Each pick comes back to the
# menu when it ends, done or stopped; only Quit (or Ctrl-C) leaves.
#
#   run        one whole exercise: check, probes, outage, deploy, failover,
#              rejoin, summary. It opens with a page on what the run will do,
#              then stops for what only you can do: cut the active hub's
#              power, merge the PRs (--git), power it back on
#   check      read-only pre-flight of the posture the settings file names
#   nodes [CONTEXT...]
#              approve pending certificate requests until the nodes are Ready
#              (after a power-on; default: all three clusters)
#   probe start|stop|summary [N]
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
# delivery. The script never powers anything off or on. Each stage and step
# says what it does and why; a RED pre-flight line links to the section of
# the docs that explains it.
# Settings: $DR_ENV (default ~/acm-dr/dr.env; see hack/dr.env.example).
# Logs: ~/acm-dr/runs/run-$RUN/
# Output: with gum (https://github.com/charmbracelet/gum) on a terminal,
# spinners, boxes and tables, and a bell when it is your turn. During a
# run, its state stays pinned at the top while the output scrolls under
# it (DR_PIN=0 turns that off). Without gum, or with
# DR_PLAIN=1, plain text. console.log gets plain text either way.
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SELF=$REPO/hack/dr.sh
DR_ENV=${DR_ENV:-$HOME/acm-dr/dr.env}
[ -f "$DR_ENV" ] || { echo "no settings file at $DR_ENV: run hack/build.sh: its first stage writes it (docs/build.md)" >&2; exit 2; }
DR_ENV=$(readlink -f "$DR_ENV")
# shellcheck source=/dev/null
. "$DR_ENV"
: "${ACTIVE:?set ACTIVE in $DR_ENV}" "${PASSIVE:?set PASSIVE in $DR_ENV}"
if [ -z "${APP_URL:-}" ]; then
  echo "no APP_URL in $DR_ENV: run hack/build.sh and keep your settings; it reads the demo apps' URLs from their routes (or deploys the apps)" >&2
  exit 2
fi
MANAGED=${MANAGED:-spoke}
PUSH_APP_URL=${PUSH_APP_URL:-}
BRANCH=${BRANCH:-main}
RUN=${RUN:-1}
if [ -n "${KUBECONFIG:-}" ]; then export KUBECONFIG; fi
LOGDIR=$HOME/acm-dr/runs/run-$RUN
mkdir -p "$LOGDIR"
cd "$REPO"

GIT=0 YES=0
CMD=""
if [ $# -gt 0 ] && [[ $1 != --* ]]; then CMD=$1; shift; fi
ARGS=()
for a in "$@"; do
  case $a in
    --git) GIT=1 ;;
    --yes) YES=1 ;;
    *) ARGS+=("$a") ;;
  esac
done

# shellcheck source=hack/lib/common.sh
. "$REPO/hack/lib/common.sh"
LOGFILE=$LOGDIR/console.log

# --- run output ----------------------------------------------------------------

flag() { if [ "$GIT" = 1 ]; then echo " --git"; fi; }
mode_name() { if [ "$GIT" = 1 ]; then echo git-driven; else echo manual; fi; }
event() {   # a milestone: on the screen, in the log and in events.log
  local t
  t=$(now)
  bare "$t $*"$'\n' >>"$LOGDIR/events.log"
  logln "$t $*"
  kind live
  if [ "$UI" = gum ]; then printf '   %s◆ %s%s %s\n' "$C_ACC" "${t:11:8}" "$C_OFF" "$(paint "$*")"; else echo "$t $(bare "$*")"; fi
  pin_draw
}

STAGES=(Pre-flight Outage Deploy Failover Rejoin Summary)
IN_RUN=0 RUN_T0=0 STAGE_EV=0 STAGE_N=1
run_rule() {   # run_rule <width>: the run's title line, with the time since it started
  local rule fill b
  rule="── Run $RUN · $(mode_name) · $(cl "$ACTIVE") goes down, $(cl "$PASSIVE") takes over · $(dur $((SECONDS - RUN_T0))) "
  b=$(bare "$rule")
  printf -v fill '%*s' $(($1 - ${#b} > 0 ? $1 - ${#b} : 0)) ''
  paint "$rule${fill// /─}" "$C_DIM"
}
declare -A HUB_URL
probe_counts() {   # probe_counts <log>: "<samples> <not 200>"
  if [ -f "$1" ]; then awk '{n++} $2 != "200" {f++} END {printf "%d %d", n, f}' "$1"; else echo "0 0"; fi
}
run_header() {   # run_header <width>: the pinned lines of a run: where it stands, and what the probes see
  local w=$(($1 > 80 ? 78 : $1)) n f c h t u x="" fill
  printf ' %s%s%s\n' "$C_DIM" "$(run_rule "$w")" "$C_OFF"
  printf ' %s\n' "$(crumbs "$STAGE_N")"
  if [ ! -f "$LOGDIR/probe.log" ]; then x="   the probes start when the run does, after the pre-flight"; fi
  for c in pull push; do
    [ -f "$LOGDIR/probe.log" ] || break
    if [ "$c" = pull ]; then u=$LOGDIR/probe.log; else u=$LOGDIR/probe-push.log; [ -n "$PUSH_APP_URL" ] || continue; fi
    read -r n f <<<"$(probe_counts "$u")"
    if [ "$f" = 0 ]; then h=$C_OK; else h=$C_BAD$C_B; fi
    x+="   $c app ${n} samples, ${h}${f} not 200${C_OFF}"
  done
  printf '%s\n' "$x"
  read -r t u <<<"$(awk '$2 != last {t = $1; last = $2} END {print t, last}' "$LOGDIR/hub-pointer.log" 2>/dev/null || true)"
  h=${u:-(read failed)}
  for c in "${!HUB_URL[@]}"; do if [ -n "$u" ] && [ "${u%/}" = "${HUB_URL[$c]%/}" ]; then h=$(cl "$c"); fi; done
  x="$(cl "$MANAGED") reports to $h${t:+ since ${t:11:8}}"
  if [ ! -f "$LOGDIR/hub-pointer.log" ]; then x="$(cl "$MANAGED") reports to $(cl "$ACTIVE"), as the settings file says"; fi
  u=$(tail -n 1 "$LOGDIR/revisions.log" 2>/dev/null | cut -d' ' -f2- || true)
  printf '   %s\n' "$(fit $((w - 3)) "$x${u:+ · serving $u}")"
  read -r t u <<<"$(tail -n 1 "$LOGDIR/events.log" 2>/dev/null || true)"
  if [ -n "$t" ]; then printf '   %s◆ %s%s %s\n' "$C_ACC" "${t:11:8}" "$C_OFF" "$(fit $((w - 14)) "$u")"; else echo; fi
  printf -v fill '%*s' "$w" ''
  printf ' %s%s%s\n' "$C_DIM" "${fill// /─}" "$C_OFF"
}
stage() {   # stage <n>: where the run stands. With gum, each stage after the first starts on a clear screen (under the pinned header, when there is one)
  local i s w recap="" n t=$PAUSED p0
  if [ "$1" -gt 2 ]; then   # stage 2 follows the run's own confirm
    p0=$(now)
    go_on "$(stage_name "$1" "${STAGES[$1 - 1]}")"
    if [ "$PAUSED" -gt "$t" ]; then echo "$p0 $((PAUSED - t))" >>"$LOGDIR/pauses.log"; fi   # left out of the timings
  fi
  n=$(wc -l 2>/dev/null <"$LOGDIR/events.log" || echo 0)
  if [ "$1" -gt 1 ] && [ "$n" -gt "$STAGE_EV" ]; then recap=$(sed -n "$((STAGE_EV + 1)),\$p" "$LOGDIR/events.log" | tail -n 3); fi
  STAGE_EV=$n STAGE_N=$1
  logln "" "#### Stage $1/${#STAGES[@]}: ${STAGES[$1 - 1]}"
  if [ "$UI" != gum ]; then
    blank
    printf '#### Stage %d/%d: %s\n' "$1" "${#STAGES[@]}" "${STAGES[$1 - 1]}"
    LAST=heading
    explain "$(stage_text "$1")"
    return 0
  fi
  if [ "$1" = "${#STAGES[@]}" ]; then pin_off; fi   # the summary scrolls, so the scrollback keeps it
  if [ "$PIN" = 1 ]; then
    if [ "$1" -gt 1 ]; then pin_clear; else pin_draw; fi
  else
    if [ "$1" -gt 1 ]; then fresh_screen; fi
    w=$(cols)
    w=$((w > 80 ? 78 : w - 2))
    blank
    printf ' %s%s%s\n %s\n' "$C_DIM" "$(run_rule "$w")" "$C_OFF" "$(crumbs "$1")"
    LAST=heading
  fi
  if [ -n "$recap" ]; then   # the end of the last stage, so the clear screen keeps some context
    blank
    printf '   %s%s ended with:%s\n' "$C_DIM" "${STAGES[$1 - 2]}" "$C_OFF"
    w=$(cols)
    w=$((w > 80 ? 78 : w - 2))
    while read -r i s; do printf '   %s◆ %s %s%s\n' "$C_DIM" "${i:11:8}" "$(fit $((w - 14)) "$s")" "$C_OFF"; done <<<"$recap"
    LAST=live
  fi
  blank
  explain "$(stage_text "$1")"
}
stage_text() {   # stage_text <n>: what the stage does and why
  local a=$ACTIVE p=$PASSIVE
  case $1 in
    1) echo "Read-only checks that the lab is in the posture the settings file names, so the outage tests DR and not a broken lab. Nothing on the clusters changes here. A section that is all green collapses to its heading, a ✓ and what it found; one with a RED line or a note shows in full." ;;
    2) echo "The probes start: every 10 s until the summary they record both apps' HTTP status, which hub $(cl "$MANAGED") reports to, and what each app serves. Then an etcd backup of $(cl "$a") as a lab safety net, a wait for a cut time clear of the :00/:30 backup slots, and your power cut. The apps on $(cl "$MANAGED") should not notice." ;;
    3) echo "With no hub alive, the script commits a new REVISION of both apps to $BRANCH. The pull app is delivered by $(cl "$MANAGED")'s own Argo CD straight from git, so it updates with no hub at all, within one Argo poll (up to about 6.5 min). The push app is delivered by a hub's Argo CD, so it stays on the old revision until $(cl "$p") is active: that wait is the push model's delivery RTO." ;;
    4)
      if [ "$GIT" = 1 ]; then
        echo "First the death gate: $(cl "$a") must stay unreachable, because activating $(cl "$p") while $(cl "$a") lives would leave two hubs claiming $(cl "$MANAGED"). Then the failover goes through git (Automated Pull Path). PR-A puts an activation restore in dr/$p; when you merge it, $(cl "$p")'s own Argo CD applies it, $(cl "$p") restores the newest backup and re-imports $(cl "$MANAGED"). Once the claim is verified, PR-B makes $(cl "$p") fully active, which starts its backups. The script writes both PRs and waits for your merges."
      else
        echo "First the death gate: $(cl "$a") must stay unreachable, because activating $(cl "$p") while $(cl "$a") lives would leave two hubs claiming $(cl "$MANAGED"). Then the script activates $(cl "$p") as the Manual Pull Path does: it pauses $(cl "$p")'s dr-role automation, replaces the continuous passive restore with the activation restore, and watches $(cl "$p") re-import $(cl "$MANAGED"). It then checks the addons, the import token and push delivery, and starts backups on $(cl "$p"), which makes $(cl "$p") the active hub."
      fi
      ;;
    5)
      if [ "$GIT" = 1 ]; then
        echo "$(cl "$a") comes back as the new passive hub instead of taking its role back. The demote PR goes first, so that $(cl "$a") boots into the passive role. Once you power it on, the script removes its old backup schedule before it can write to the shared bucket, waits until $(cl "$a")'s view of $(cl "$MANAGED") goes stale (deleting the claim earlier would uninstall $(cl "$MANAGED")'s agent), deletes that stale claim and checks the passive restore. At the end the settings file swaps ACTIVE and PASSIVE for the next run."
      else
        echo "$(cl "$a") comes back as the new passive hub instead of taking its role back. Once you power it on, the script pauses its dr-role automation, removes its old backup schedule before it can write to the shared bucket, waits until $(cl "$a")'s view of $(cl "$MANAGED") goes stale (deleting the claim earlier would uninstall $(cl "$MANAGED")'s agent), deletes that stale claim and starts the passive restore. Then it commits the new roles to dr/ and turns automation back on. At the end the settings file swaps ACTIVE and PASSIVE for the next run."
      fi
      ;;
    6) echo "The probes stop. The summary shows everything they recorded: each app's availability before and after the power cut, when $(cl "$MANAGED") switched hubs, when each app served each revision, and how long each step took." ;;
  esac
}

# --- cluster checks ------------------------------------------------------------

backup_running() { oc --context "$1" get "$VBACKUP" -n "$NS" -o jsonpath='{.items[*].status.phase}' 2>/dev/null | grep -qwE 'New|InProgress'; }
recent_backups() {   # recent_backups <context>: the newest backup in one line; the log (and plain output) gets the last six
  local out n p t
  out=$(oc --context "$1" get "$VBACKUP" -n "$NS" --sort-by=.status.startTimestamp \
    -o custom-columns='NAME:.metadata.name,PHASE:.status.phase,START:.status.startTimestamp' | tail -n 6)
  to_log <<<"$out"
  read -r n p t <<<"$(tail -n 1 <<<"$out")"
  if [ "$UI" = gum ]; then finished "newest backup on $(cl "$1"): $p, started ${t:11:8} (${n%-*})"; fi
}
hub_name() {   # hub_name <API url>: the context name of that hub, or the url
  local c
  for c in "${!HUB_URL[@]}"; do if [ -n "$1" ] && [ "${1%/}" = "${HUB_URL[$c]%/}" ]; then cl "$c"; return 0; fi; done
  echo "${1:-(not read yet)}"
}

revision() {   # the REVISION an app's route serves, or ? when it does not answer
  local rev; rev=$(curl -s --max-time 5 "$1" 2>/dev/null | grep -o 'REVISION v[0-9]*' | head -n 1 | cut -d' ' -f2 || true)
  echo "${rev:-?}"
}
serves() { [ "$(revision "$1")" = "$2" ]; }

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

token_adopted() {
  [ "$(msa_token "$1" | cut -d' ' -f1)" = True ] &&
    [ "$(oc --context "$1" get secret auto-import-account -n "$MANAGED" \
      -o jsonpath='{.metadata.ownerReferences[0].kind}' 2>/dev/null)" = ManagedServiceAccount ]
}

ready_up() {   # wait for <context>'s API, then approve certificates until its nodes are Ready (G.1's power-on note)
  local c=$1 t0 end=$((SECONDS + 1800))
  alive "$c" || wait_until 7200 "$(cl "$c")'s API to answer" alive "$c"
  t0=$SECONDS
  spin_begin "approving pending certificate requests on $(cl "$c") until its nodes are Ready (up to 30 min)"
  until poll settled "$c"; do
    [ "$SECONDS" -lt "$end" ] || die "$(cl "$c"): nodes not Ready, or certificate requests still pending, after 30 min"
    approve_csrs "$c" 2>&1 | to_log || true
    pause 20
  done
  spin_stop
  finished "$(cl "$c"): nodes Ready, no pending certificate requests ($(dur $((SECONDS - t0))))"
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
  local a=${1:-$ACTIVE} p=${2:-$PASSIVE} c out newest rp="" rq=""
  BAD=0
  sec_begin "Clusters"
  explain "All three clusters must be up and settled: an API that answers, nodes Ready and no certificate requests waiting (a cluster that was powered off for a while usually has some)."
  help_at docs/build.md#clusters
  for c in "$a" "$p" "$MANAGED"; do
    expect "$(cl "$c") API answers" "$(cl "$c") API does not answer" alive "$c"
  done
  if [ "$BAD" = 1 ]; then sec_end; HELP=""; verdict bad "PRE-FLIGHT RED: power the clusters on, then run hack/dr.sh nodes"; return 1; fi
  for c in "$a" "$p" "$MANAGED"; do
    expect "$(cl "$c") nodes Ready" "$(cl "$c") has nodes not Ready (hack/dr.sh nodes $(cl "$c"))" nodes_ready "$c"
    expect "$(cl "$c") has no pending certificate requests" "$(cl "$c") has pending certificate requests (hack/dr.sh nodes $(cl "$c"))" not pending_csrs "$c"
  done
  sec_end "APIs answer, nodes Ready, no pending certificates"

  sec_begin "Posture: $(cl "$a") active, $(cl "$p") passive (0.1)"
  explain "Exactly one hub may be active. $(cl "$a") must be taking backups and managing $(cl "$MANAGED"); $(cl "$p") must be restoring those backups continuously, with no backup schedule of its own and no claim on $(cl "$MANAGED")."
  help_at docs/runbooks/dr-failover-pull-manual/README.md#01-posture-sanity
  expect "$(cl "$a") schedule-acm Enabled" "$(cl "$a") schedule-acm is '$(phase "$a" "$BSCHED" schedule-acm)'" schedule_enabled "$a"
  expect "$(cl "$a") has no passive restore" "$(cl "$a") has a restore-acm-passive-sync" none "$a" "$RESTORE" restore-acm-passive-sync -n "$NS"
  expect "$(cl "$MANAGED") Available on $(cl "$a")" "$(cl "$MANAGED") not Available on $(cl "$a")" mc_available "$a" True
  expect "$(cl "$p") restore-acm-passive-sync Enabled" "$(cl "$p") passive restore is '$(phase "$p" "$RESTORE" restore-acm-passive-sync)'" \
    restore_enabled "$p" restore-acm-passive-sync
  expect "$(cl "$p") does not list $(cl "$MANAGED")" "$(cl "$p") also lists $(cl "$MANAGED") (two hubs claim it)" none "$p" managedcluster "$MANAGED"
  expect "$(cl "$p") has no BackupSchedule" "$(cl "$p") has a BackupSchedule" none "$p" "$BSCHED" -n "$NS"
  expect "$(cl "$p") has no Velero schedules" "$(cl "$p") has Velero schedules (Manual Pull Path G.2)" none "$p" "$VSCHED" -n "$NS"
  if some "$p" "$RESTORE" restore-acm-activate -n "$NS"; then
    note "$(cl "$p") still holds a fixed-name restore-acm-activate: a manual failover deletes it first (D.2)"
  fi
  sec_end "$(cl "$a") backing up, $(cl "$p") restoring, $(cl "$MANAGED") on $(cl "$a") only"

  sec_begin "MSA token chain (0.2)"
  explain "The new hub re-imports $(cl "$MANAGED") with the auto-import token it restores from the backups. The token must be valid and rotating, or the failover stalls in Pending Import."
  help_at docs/runbooks/dr-failover-pull-manual/README.md#02-msa-token-chain--the-load-bearing-check
  expect "auto-import-account on $(cl "$a"): $(msa_token "$a")" \
    "auto-import-account on $(cl "$a"): '$(msa_token "$a")' (want True and an expiry more than a day out; 0.2)" msa_fresh "$a"
  out=$(msa_token "$a")
  sec_end "valid until ${out:5:10} ${out:16:5}"

  sec_begin "Backups (0.3)"
  explain "A failover restores the newest backup set, so one must have completed recently (sets run at :00 and :30)."
  help_at docs/runbooks/dr-failover-pull-manual/README.md#03-a-backup-newer-than-every-fix
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
  sec_end "newest set Completed, started ${out:21:8}"

  sec_begin "Passive hub readiness (0.4)"
  explain "Things that would only break at activation: the addon namespace, a stray Route CRD, $(cl "$p")'s Argo CD, and both hubs' access to the backup bucket."
  help_at docs/runbooks/dr-failover-pull-manual/README.md#04-remaining-static-checks
  expect "$(cl "$p") has namespace open-cluster-management-global-set" "$(cl "$p") lacks namespace open-cluster-management-global-set" \
    some "$p" ns open-cluster-management-global-set
  expect "$(cl "$p") has no stray Route CRD" "$(cl "$p") has a stray routes.route.openshift.io CRD" none "$p" crd routes.route.openshift.io
  out=$(oc --context "$p" get pods -n "$GNS" --no-headers 2>/dev/null | awk '$3 != "Running" && $3 != "Completed" {print $1, $3}' || true)
  if [ -z "$out" ]; then ok "$(cl "$p") Argo CD pods Running"; else red "$(cl "$p") Argo CD pods not Running: $out"; fi
  help_at docs/build.md#3-hubs-backup-storage
  for c in "$a" "$p"; do
    out=$(oc --context "$c" get backupstoragelocation -n "$NS" -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)
    if [ "$out" = Available ]; then ok "$(cl "$c") BSL Available"; else red "$(cl "$c") BSL is '$out'"; fi
  done
  sec_end "$(cl "$p") ready to activate; both hubs reach the bucket"

  if has_dr_role "$a" || has_dr_role "$p"; then
    sec_begin "Git-driven roles (Automated Pull Path P.2 and pre-flight)"
    explain "Each hub's own Argo CD (the dr-role app) applies its role from dr/ in git. Both must be in sync with automation on, and dr-role must never be in a backup, or a restore would hand the other hub the wrong role."
    help_at docs/runbooks/dr-failover-pull-gitops/README.md#p1-bootstrap-each-hubs-dr-role-application
    for c in "$a" "$p"; do
      expect "$(cl "$c") dr-role Synced Healthy" "$(cl "$c") dr-role is '$(dr_role_state "$c")'" dr_role_synced "$c"
      expect "$(cl "$c") dr-role automation on" "$(cl "$c") dr-role automation is off (finish H.1)" dr_role_automated "$c"
    done
    newest=$(oc --context "$a" get "$VBACKUP" -n "$NS" -o json 2>/dev/null | jq -r '
      [.items[] | select((.metadata.name | startswith("acm-resources-schedule-")) and .status.phase == "Completed")]
      | sort_by(.status.startTimestamp) | last | .metadata.name // ""' || true)
    help_at docs/runbooks/dr-failover-pull-gitops/README.md#p2-confirm-the-backup-exclusion-works
    out=$(oc --context "$a" -n "$NS" exec deploy/velero -- /velero backup describe "$newest" --details 2>/dev/null |
      awk '/v1alpha1\/Application:/ {f = 1; next} f && /^ *- / {print $2; next} f {exit}' || true)
    if [ -z "$out" ]; then
      red "could not list the Applications in backup '$newest' (P.2)"
    elif grep -q '/dr-role$' <<<"$out"; then
      red "backup $newest contains dr-role: a restore would deliver the wrong role (P.2)"
    else
      ok "backup $newest holds $(wc -l <<<"$out") Applications and no dr-role"
    fi
    sec_end "dr-role synced and automated on both hubs, kept out of backups"
  fi

  sec_begin "Workload"
  explain "The two demo apps on $(cl "$MANAGED"): the pull app, delivered by $(cl "$MANAGED")'s own Argo CD, and the push app, delivered by $(cl "$a")'s Argo CD. Both must answer and be in sync before the outage, or the probes prove nothing."
  help_at docs/build.md#5-active-hub-gitops-wiring-and-the-demo-apps
  rp=$(revision "$APP_URL")
  expect "pull app answers 200 (serves $rp)" "pull app does not answer 200 (tried for 30 s)" wait_for 30 http_ok "$APP_URL"
  help_at docs/build.md#build-time-gotchas
  out=$(app_state "$MANAGED" "hello-failover-$MANAGED")
  if [ "$out" = "Synced Healthy" ]; then ok "pull app Synced Healthy on $(cl "$MANAGED")"; else red "pull app on $(cl "$MANAGED") is '$out'"; fi
  if [ -n "$PUSH_APP_URL" ]; then
    help_at docs/build.md#5-active-hub-gitops-wiring-and-the-demo-apps
    rq=$(revision "$PUSH_APP_URL")
    expect "push app answers 200 (serves $rq)" "push app does not answer 200 (tried for 30 s)" wait_for 30 http_ok "$PUSH_APP_URL"
    help_at docs/build.md#build-time-gotchas
    out=$(app_state "$a" "hello-failover-push-$MANAGED")
    if [ "$out" = "Synced Healthy" ]; then ok "push app Synced Healthy on $(cl "$a")"; else red "push app on $(cl "$a") is '$out'"; fi
  fi
  sec_end "pull app $rp${rq:+ and push app $rq} answer 200, Synced Healthy"

  HELP=""
  if [ "$BAD" = 0 ]; then
    verdict ok "PRE-FLIGHT GREEN: $(cl "$a") active, $(cl "$p") passive"
  else
    verdict bad "PRE-FLIGHT RED: fix the RED lines first; each links to the section that explains it"
    return 1
  fi
}

cmd_nodes() {
  local c
  [ ${#ARGS[@]} -gt 0 ] || ARGS=("$ACTIVE" "$PASSIVE" "$MANAGED")
  for c in "${ARGS[@]}"; do ready_up "$c"; done
}

# --- probes (A) --------------------------------------------------------------

probe_http() {   # every 10 s: time and HTTP status; a sample that is not 200 adds curl's exit code and timings (s), so a client-side DNS or connect stall shows as one
  local t r rc
  while true; do
    t=$(now) rc=0
    r=$(curl -s -o /dev/null -w '%{http_code} dns=%{time_namelookup} connect=%{time_connect} tls=%{time_appconnect} total=%{time_total}' --max-time 5 "$1") || rc=$?
    if [ "${r%% *}" = 200 ]; then echo "$t 200"; else echo "$t $r curl-exit=$rc"; fi
    sleep 10
  done
}
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

stale_probes() {   # stop the probes another run left running: one that stopped and was never carried on
  local f pid n
  for f in "$HOME"/acm-dr/runs/run-*/probe.pids; do
    if [ ! -f "$f" ] || [ "$f" = "$LOGDIR/probe.pids" ]; then continue; fi
    n=0
    while read -r pid; do   # only a dr.sh probe: after a reboot the number may be another process's
      if ps -o args= -p "$pid" 2>/dev/null | grep -q 'dr\.sh _probe-'; then
        kill -- "-$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
        n=$((n + 1))
      fi
    done <"$f"
    rm -f "$f"
    if [ "$n" = 1 ]; then note "stopped a probe that $(basename "$(dirname "$f")") left running"
    elif [ "$n" -gt 1 ]; then note "stopped $n probes that $(basename "$(dirname "$f")") left running"; fi
  done
}
probe_start() {
  local f
  if probes_running; then note "probes already running for run $RUN"; return 0; fi
  stale_probes
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
  done | to_log
  if [ "$UI" = gum ]; then
    f=$(tail -n 1 "$LOGDIR/probe.log" 2>/dev/null | cut -d' ' -f2)
    finished "probes running: pull app ${f:-?}$(if [ -n "$PUSH_APP_URL" ]; then echo ", push app $(tail -n 1 "$LOGDIR/probe-push.log" 2>/dev/null | cut -d' ' -f2)"; fi), $(cl "$MANAGED") reports to $(hub_name "$(tail -n 1 "$LOGDIR/hub-pointer.log" 2>/dev/null | cut -d' ' -f2)")"
  fi
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
span() { span_t "$1" "$(ev "$2")" "$(ev "$3")"; }   # span <label> <from event> <to event>
span_t() {   # span_t <label> <from time> <to time>: a timing row when both are known, less the time at Continue prompts
  if [ -n "$2" ] && [ -n "$3" ]; then
    printf '%s\t%s\n' "$1" "$(dur $(($(date -u -d "$3" +%s) - $(date -u -d "$2" +%s) - $(paused_in "$2" "$3"))))"
  fi
}
paused_in() {   # paused_in <from time> <to time>: seconds spent at Continue prompts in between
  awk -v a="$1" -v b="$2" '$1 >= a && $1 < b {s += $2} END {print s + 0}' "$LOGDIR/pauses.log" 2>/dev/null || echo 0
}
first_served() {   # first_served <pull|push> <n>: when revisions.log first shows that app serving vN
  awk -v r="$1=v$2" '{for (i = 2; i <= NF; i++) if ($i == r) {print $1; exit}}' "$LOGDIR/revisions.log" 2>/dev/null || true
}
push_back() {   # when the push app first served the mid-outage revision: E' or the revision probe, whichever saw it first
  local e r np
  e=$(ev " E' push delivery back")
  [ -s "$LOGDIR/deploy.rev" ] && np=$(cut -d' ' -f2 "$LOGDIR/deploy.rev") && r=$(first_served push "$np")
  if [ -z "$e" ] || { [ -n "${r:-}" ] && [[ $r < $e ]]; }; then e=${r:-}; fi
  echo "$e"
}
timings() {
  local act=" D.2 activation applied" from=Activation pb
  pb=$(push_back)
  if [ -n "$(ev " D'.2 PR-A merged")" ]; then act=" D'.2 PR-A merged" from="PR-A merge"; fi
  printf 'Measure\tTime\n'
  span "Hub dead to $MANAGED claimed on the new hub" " B.1 .* API dead" " D.3 claim landed"
  span "Pull deploy: pushed to served, no hub" " C deploy pushed" " C pull app serves"
  span_t "Push deploy: pushed to served (push delivery RTO)" "$(ev " C deploy pushed")" "$pb"
  span "Death gate to activation" " B .*death gate passed" " D.2 activation applied"
  span "PR-A: pushed to merged" " D'.1 PR-A branch" " D'.2 PR-A merged"
  span "$from to claim (D.3)" "$act" " D.3 claim landed"
  span "$from to all addons Available (E.1)" "$act" " E.1 all addons Available"
  span "$from to the first backup set (F.1)" "$act" " F.1 first backup set Completed"
  span_t "$from to push delivery back (E')" "$(ev "$act")" "$pb"
  span "PR-B: pushed to merged" " F' PR-B branch" " F' PR-B merged"
  span "Demote PR: pushed to merged" " G'.1 demote branch" " G'.1 demote PR merged"
  span "Old hub back to its lease running out (G.1)" " G .* API answers" " G.1 .* Unknown"
  span "Whole run: start to rejoin done" " run [0-9]+ started" " rejoin done"
  if [ -s "$LOGDIR/pauses.log" ]; then printf 'At the Continue prompts (left out of the times above)\t%s\n' "$(dur "$(awk '{s += $2} END {print s + 0}' "$LOGDIR/pauses.log")")"; fi
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
    label "Hub pointer (which hub $(cl "$MANAGED") reports to)"
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
  local a=$ACTIVE node n f
  alive "$a" || die "$(cl "$a")'s API does not answer: is it already down?"
  say "B.0: lab safety net, an etcd backup of $(cl "$a")"
  explain "A copy of $(cl "$a")'s control plane, kept on its node, in case a lab hub does not come back cleanly from a hard power-off. It is not part of DR."
  node=$(oc --context "$a" get nodes -l node-role.kubernetes.io/master -o jsonpath='{.items[0].metadata.name}')
  spin_cmd "etcd backup on $node" \
    oc --context "$a" debug "node/$node" -- chroot /host /usr/local/bin/cluster-backup.sh /home/core/assets/backup ||
    die "the etcd backup on $node failed: its output is above"
  event "B.0 etcd backup saved on $(cl "$a") ($node:/home/core/assets/backup)"
  explain "A cut in the middle of a backup would leave a partial set in the bucket, so the script waits until 5 to 26 minutes past a :00 or :30 slot, with no backup running."
  wait_until 1800 "a cut time clear of the :00/:30 backup slots, with no backup in progress" slot_clear "$a"
  recent_backups "$a"

  say "B.1: the outage"
  explain "A hard power-off is the realistic disaster: no clean shutdown and no chance to hand anything over. From now on $(cl "$a") is the failed hub."
  your_turn "cut $(cl "$a")'s power now" \
    "Hold the power button about 5 s (a short press is a graceful shutdown), pull the plug, or use a hard power-off." \
    "The script carries on when $(cl "$a")'s API stops answering."
  wait_until 1800 "$(cl "$a")'s API to stop answering" dead "$a"
  event "B.1 $(cl "$a") API dead (power cut by hand)"
  say "B.2: the workload does not care"
  explain "$(cl "$MANAGED") runs its workloads by itself; a hub only manages it, so the probes should keep answering 200."
  spin_begin "letting the probes sample the outage"
  pause 20
  spin_stop
  if [ -s "$LOGDIR/probe.log" ]; then
    tail -n 3 "$LOGDIR"/probe*.log | to_log
    read -r n f <<<"$(cat "$LOGDIR"/probe*.log | awk -v c="$(ev " B.1 .* API dead")" '$1 >= c {n++; if ($2 != "200") f++} END {printf "%d %d", n, f}')"
    if [ "$f" = 0 ]; then ok "both apps answered 200 at all $n samples since the cut"; else note "$f of $n samples since the cut were not 200 (the summary lists them)"; fi
  else
    note "no availability probe running (hack/dr.sh probe start)"
  fi
}

# --- deploy (C) --------------------------------------------------------------

rev_of() { grep -o 'REVISION v[0-9]*' "$1" | head -n 1 | grep -o '[0-9]*$'; }

cmd_deploy() {
  local f=apps/hello-failover/configmap.yaml fp=apps/hello-failover-push/configmap.yaml n np
  git_ready
  n=$(($(rev_of "$f") + 1))
  np=$(($(rev_of "$fp") + 1))
  say "C: push pull v$n and push v$np with $(cl "$ACTIVE") down"
  explain "One commit changes the REVISION text both apps serve. The script waits for the pull app to serve v$n, which proves a deploy needs no hub; the push app is checked again after the failover (E')."
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
  explain "$(cl "$p") uses the restored import token to re-import $(cl "$MANAGED"): the agent on $(cl "$MANAGED") switches to $(cl "$p"), and $(cl "$MANAGED") reads Available there."
  wait_until 300 "the restored ManagedCluster $(cl "$MANAGED") on $(cl "$p")" some "$p" managedcluster "$MANAGED"
  EVERY=1 wait_until 900 "$MANAGED to be Available on $p" mc_available "$p" True
  event "D.3 claim landed: $(cl "$MANAGED") Available on $(cl "$p")"
  show oc --context "$p" get managedclusters
  say "E.1: addons"
  explain "The addons are $(cl "$MANAGED")'s agents for applications, policies, search and the cluster proxy. Push delivery needs the cluster proxy and the application-manager account, so they must all re-register with $(cl "$p")."
  wait_until 900 "every addon on $(cl "$MANAGED") to be Available" addons_available "$p"
  event "E.1 all addons Available"
  show oc --context "$p" get managedclusteraddon -n "$MANAGED"
  say "E.2: re-home evidence"
  explain "The hub-pointer probe shows when $(cl "$MANAGED")'s agent switched hubs; the availability probe shows whether the pull app noticed."
  if [ -s "$LOGDIR/hub-pointer.log" ]; then
    awk '{s = $2 == "" ? "(read failed)" : $2} s != last {print $1, s; last = s}' "$LOGDIR/hub-pointer.log" | tail -n 3 | show
  fi
  n=$(grep -c -v ' 200$' "$LOGDIR/probe.log" 2>/dev/null || true)
  if [ "${n:-0}" = 0 ]; then ok "the pull app answered 200 at every availability sample so far"; else note "$n availability samples were not 200"; fi
  say "E.3: the restored MSA secret"
  explain "The restored import token has to keep rotating on $(cl "$p"), or the next failover fails in Pending Import. ACM 2.17.3 adopts and rotates it; older versions froze it, and then the script deletes it so a fresh one is minted."
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
  wait_until 600 "schedule-acm Enabled on $(cl "$p")" schedule_enabled "$p"
  t=$(oc --context "$p" get "$BSCHED" schedule-acm -n "$NS" -o jsonpath='{.metadata.creationTimestamp}')
  wait_until 900 "the first full backup set on $(cl "$p")" backup_set_after "$p" "$t"
  event "F.1 first backup set Completed on $(cl "$p")"
  recent_backups "$p"
  say "F.2: GitOps wiring"
  explain "The GitOpsCluster, Placements and ApplicationSets came back with the restore, so $(cl "$p")'s Argo CD now delivers the push app."
  show oc --context "$p" get gitopscluster,placement,applicationset -n "$GNS"
  show oc --context "$p" get "$APP" -n "$GNS"
}

push_resurrection() {   # E': the push app serving the mid-outage revision is push delivery back
  local np t
  if [ -z "$PUSH_APP_URL" ] || [ ! -s "$LOGDIR/deploy.rev" ]; then return 0; fi
  np=$(cut -d' ' -f2 "$LOGDIR/deploy.rev")
  say "E': push delivery"
  explain "The push app updates only when the new hub's Argo CD pushes to $(cl "$MANAGED"). The time from the deploy to the new revision is the push model's delivery RTO."
  show oc --context "$PASSIVE" get secret -n "$GNS" -l apps.open-cluster-management.io/acm-cluster=true
  if try_until 1200 "the push app to serve v$np" serves "$PUSH_APP_URL" "v$np"; then
    t=$(first_served push "$np")
    event "E' push delivery back: push app serves v$np${t:+ (the revision probe saw it first at ${t:11:8})}"
  else
    event "E' push app still not serving v$np after 20 min"
    note "see the Manual Push Path E' failure modes"
  fi
}

failover_manual() {
  local p=$PASSIVE
  say "D: activate $(cl "$p") by hand"
  explain "D.0 pauses $(cl "$p")'s dr-role app, which would otherwise put the passive restore straight back. D.1 deletes the continuous passive restore. D.2 applies restore-acm-activate, which restores the managed-cluster data from the newest backup, including $(cl "$MANAGED")'s import token."
  confirm "Activate $(cl "$p") now?"
  if has_dr_role "$p"; then
    suspend_dr_role "$p"
    not dr_role_automated "$p" || die "could not suspend dr-role on $(cl "$p")"
    event "D.0 dr-role automation suspended on $(cl "$p")"
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
  say "F.1: start backups on $(cl "$p")"
  explain "$(cl "$p") becomes the only hub writing to the shared bucket. Its first full backup set runs right away, without waiting for a slot."
  quiet oc --context "$p" apply -f manifests/55-backupschedule.yaml
  event "F.1 BackupSchedule applied on $(cl "$p")"
  promote_checks
}

failover_git() {
  local p=$PASSIVE stamp
  has_dr_role "$p" || die "no dr-role on $(cl "$p"): dr/ was never bootstrapped, so use the manual path"
  dr_role_automated "$p" || die "dr-role automation is off on $(cl "$p"): finish the last run's re-align (H.1) first"
  git_ready
  [ "$(overlay "$p")" = ../roles/passive ] || die "dr/$p lists '$(overlay "$p")', not ../roles/passive"
  stamp=$(new_stamp failover)
  echo "$stamp" >"$LOGDIR/stamp"

  say "D'.1: the activation PR (PR-A)"
  explain "PR-A changes dr/$p/kustomization.yaml: the passive role makes way for a time-stamped activation restore. Nothing happens on the clusters until you merge it."
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
  explain "Reviewing PR-A is where a person confirms $(cl "$ACTIVE") is really dead. Merging it is the failover decision."
  open_pr "failover-$stamp" "FAILOVER: activate $p" \
    "Activation only (PR-A). Review gate: $ACTIVE is dead; hack/dr.sh found its API refusing connections at $(now). Merging is the failover decision." \
    "The review is the death gate: confirm $ACTIVE is dead with the check below the link." \
    "Merging is the failover decision."
  line "   death check: curl -sk --max-time 5 $(server "$ACTIVE")/version || echo DEAD"
  wait_merged "$p" "restore-activate-$stamp.yaml"
  event "D'.2 PR-A merged"
  if not dead "$ACTIVE"; then note "$(cl "$ACTIVE") no longer reads dead: if it is back, you now have two live hubs (B.1 failure)"; fi

  say "D'.3: $(cl "$p") executes"
  explain "$(cl "$p")'s own Argo CD syncs the merge: it prunes the passive restore and creates the activation restore. The backup operator often sees the new restore before the old one is gone and ignores it; the script then deletes it, and Argo creates it again (the D'.3 race)."
  refresh_dr_role "$p" normal
  activation_restore "restore-acm-activate-$stamp"
  claim_and_verify

  say "F': the promotion PR (PR-B)"
  explain "PR-B adds the active role to dr/$p, which starts $(cl "$p")'s backups. It comes only after the claim is verified, so a failed activation can never overwrite the bucket's newest backup with an empty fleet."
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
  explain "Activating $(cl "$PASSIVE") while $(cl "$ACTIVE") still runs would give $(cl "$MANAGED") two hubs. The gate needs $(cl "$ACTIVE")'s API to refuse connections or time out twice, 10 s apart, while $(cl "$PASSIVE") and $(cl "$MANAGED") both answer, so a network problem on this machine is not mistaken for a dead hub."
  alive "$PASSIVE" || die "$(cl "$PASSIVE") does not answer either"
  alive "$MANAGED" || die "$(cl "$MANAGED") does not answer: the network path is in doubt, so $(cl "$ACTIVE")'s silence proves nothing"
  if alive "$ACTIVE"; then
    die "$(cl "$ACTIVE")'s API still answers. Activating $(cl "$PASSIVE") now would leave two live hubs claiming $(cl "$MANAGED"). Cut its power first."
  fi
  dead "$ACTIVE" || die "$(cl "$ACTIVE")'s API name does not resolve: that is DNS trouble, not proof of death"
  spin_begin "checking that $(cl "$ACTIVE") stays dead"
  pause 10
  spin_stop
  dead "$ACTIVE" || die "$(cl "$ACTIVE")'s API answered again"
  event "B $(cl "$ACTIVE") API refuses connections or times out (death gate passed)"
  if [ "$GIT" = 1 ]; then failover_git; else failover_manual; fi
  push_resurrection
  event "failover done: $(cl "$PASSIVE") active"
  say "Failover done: $(cl "$PASSIVE") is active and backing up"
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
  spin_begin "deleting $(cl "$a")'s BackupSchedule and Velero schedules (up to 30 min)"
  until poll defuse "$a"; do
    [ "$SECONDS" -lt "$end" ] || die "could not delete $(cl "$a")'s schedules within 30 min"
    approve_csrs "$a" >/dev/null 2>&1 || true
    pause 10
  done
  spin_stop
  event "G.2 $(cl "$a") has no BackupSchedule and no Velero schedules"
  if ! schedule_enabled "$PASSIVE"; then
    note "$(cl "$PASSIVE") schedule-acm is '$(phase "$PASSIVE" "$BSCHED" schedule-acm)', not Enabled (Manual Pull Path G.2 failure)"
  fi
}
break_glass() {   # G.0: suspend dr-role on <context>, retrying while its API settles
  wait_until 1800 "the dr-role patch to land on $(cl "$1")" suspend_dr_role "$1"
  event "G.0 dr-role automation suspended on $(cl "$1")"
}

demote_git() {   # G'.1: the demote PR, mergeable while the hub is still down
  local a=$ACTIVE stamp
  git_ready
  if [ "$(overlay "$a")" = ../roles/passive ]; then note "dr/$a already lists ../roles/passive"; return 0; fi
  stamp=$(new_stamp demote)
  say "G'.1: the demote PR"
  explain "The demote PR makes dr/$a passive. Merge it while $(cl "$a") is still down: it then boots into the passive role, and its Argo CD removes its backup schedule."
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
  explain "The manual path changed the roles by hand, so dr/ in git still describes the old ones. The script commits the new roles to $BRANCH, waits until both hubs' Argo CD sees that commit, and turns automation back on."
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
    wait_until 300 "dr-role on $(cl "$c") to compare against ${rev:0:7}" dr_role_has "$c" "$rev"
  done
  for c in "$a" "$p"; do resume_dr_role "$c"; done
  for c in "$a" "$p"; do wait_until 300 "dr-role Synced Healthy on $(cl "$c")" dr_role_synced "$c"; done
  event "H.1 dr/ re-aligned at ${rev:0:7}; dr-role automation back on both hubs"
  for c in "$a" "$p"; do
    line "   $(cl "$c"):"
    show oc --context "$c" get "$BSCHED,$RESTORE" -n "$NS" \
      -o custom-columns='KIND:.kind,NAME:.metadata.name,CREATED:.metadata.creationTimestamp'
  done
}

cmd_rejoin() {
  local a=$ACTIVE p=$PASSIVE rev="" early=0
  if [ "$GIT" = 1 ]; then
    if alive "$a"; then
      # back before its demote merged: git still calls it active, so break glass as on the manual path
      note "$(cl "$a") answers before its demote merged: suspending its dr-role until the demote lands"
      early=1
      break_glass "$a"
      defuse_now "$a"
    fi
    demote_git
    rev=$(git rev-parse HEAD)
  fi

  say "G: $(cl "$a") comes back"
  explain "$(cl "$a") comes back as the new passive hub. After a long power-off its nodes usually wait for certificate approvals; the script approves them. Its old backup schedule is removed first thing, before it can write to the bucket that $(cl "$p") now owns."
  your_turn "power $(cl "$a") back on now" \
    "The script carries on when its API answers: it approves certificate requests until the nodes are Ready, then makes $(cl "$a") passive."
  wait_until 7200 "$(cl "$a")'s API to answer" alive "$a"
  event "G $(cl "$a") API answers"
  if [ "$GIT" = 0 ] && has_dr_role "$a"; then break_glass "$a"; fi
  defuse_now "$a"
  ready_up "$a"
  event "G $(cl "$a") nodes Ready"

  if [ "$GIT" = 1 ]; then
    say "G'.1: $(cl "$a") boots into the demote"
    explain "$(cl "$a")'s Argo CD syncs the merged demote: the passive restore replaces its old role."
    refresh_dr_role "$a" hard
    wait_until 900 "dr-role on $(cl "$a") to compare against ${rev:0:7}" dr_role_has "$a" "$rev"
    if [ "$early" = 1 ]; then resume_dr_role "$a"; event "G'.1 dr-role automation back on $(cl "$a")"; fi
    wait_until 900 "dr-role Synced Healthy on $(cl "$a")" dr_role_synced "$a"
    defuse_now "$a"   # the pruned schedule's Velero schedules can outlive it after a boot
    quiet oc --context "$a" delete "$RESTORE" restore-acm-activate -n "$NS" --ignore-not-found   # untracked residue of a manual activation
  fi

  if some "$a" managedcluster "$MANAGED"; then
    say "G.1: wait out the lease"
    explain "$(cl "$a") still lists $(cl "$MANAGED") as its own until the agent's lease, last renewed before the outage, runs out (usually 2 to 4 minutes after boot). Deleting the claim while it still reads True would uninstall $(cl "$MANAGED")'s agent and its hub-delivered workloads."
    wait_until 1800 "$(cl "$MANAGED") to read Available=Unknown on $(cl "$a")" mc_available "$a" Unknown
    event "G.1 $(cl "$MANAGED") Unknown on $(cl "$a")"
    say "G.3: drop the stale claim"
    explain "Now that it reads Unknown, deleting $(cl "$a")'s stale ManagedCluster is safe: $(cl "$MANAGED") keeps reporting to $(cl "$p")."
    spin_cmd "deleting the stale ManagedCluster $(cl "$MANAGED") on $(cl "$a")" oc --context "$a" delete managedcluster "$MANAGED" --timeout=5m ||
      die "could not delete the stale ManagedCluster $(cl "$MANAGED") on $(cl "$a") (Manual Pull Path G.3)"
    event "G.3 stale claim on $(cl "$a") deleted"
  fi

  say "G.4: $(cl "$a") as passive"
  explain "The continuous passive restore makes $(cl "$a") follow $(cl "$p")'s backups, ready for the next failover."
  if [ "$GIT" = 0 ]; then quiet oc --context "$a" apply -f manifests/56-restore-passive.yaml; fi
  wait_until 900 "restore-acm-passive-sync Enabled on $(cl "$a")" restore_enabled "$a" restore-acm-passive-sync
  event "G.4 $(cl "$a") passive sync Enabled"
  if [ "$GIT" = 0 ]; then
    say "G.5: the stale activation restores"
    explain "Restores are one-shot: $(cl "$a")'s old activation restores have done their job and would only get in the way of a later activation."
    oc --context "$a" get "$RESTORE" -n "$NS" -o name | { grep restore-acm-activate || true; } |
      xargs -r -n1 oc --context "$a" delete -n "$NS" 2>&1 | to_log
    event "G.5 old activation restores on $(cl "$a") deleted"
    if has_dr_role "$a" && has_dr_role "$p"; then realign_git; fi
  fi
  show oc --context "$a" get "$RESTORE" -n "$NS"

  sed -i -e "s/^ACTIVE=.*/ACTIVE=$p/" -e "s/^PASSIVE=.*/PASSIVE=$a/" "$DR_ENV"
  if grep -q '^RUN=' "$DR_ENV"; then sed -i "s/^RUN=.*/RUN=$((RUN + 1))/" "$DR_ENV"; else echo "RUN=$((RUN + 1))" >>"$DR_ENV"; fi
  event "rejoin done: $(cl "$p") active, $(cl "$a") passive (settings file: ACTIVE=$(cl "$p") PASSIVE=$(cl "$a") RUN=$((RUN + 1)))"
  cmd_check "$p" "$a" || note "the new posture is not green yet: rerun hack/dr.sh check in a few minutes"
}

# --- run ---------------------------------------------------------------------

RUN_MOVED=""
run_number() {   # a run number whose folder holds a finished run (a settings file written afresh, say) moves on to the next free one
  local n
  if ! grep -q ' rejoin done:' "$LOGDIR/events.log" 2>/dev/null; then return 0; fi
  n=$(find "$HOME/acm-dr/runs" -maxdepth 1 -name 'run-*' -printf '%f\n' | sed -n 's/^run-\([0-9][0-9]*\)$/\1/p' | sort -n | tail -n 1)
  RUN_MOVED="Run $RUN finished earlier (${LOGDIR/#$HOME/\~}), so this is run $((n + 1)), the next free number. The settings file says so now."
  RUN=$((n + 1)) LOGDIR=$HOME/acm-dr/runs/run-$((n + 1))
  mkdir -p "$LOGDIR"
  if grep -q '^RUN=' "$DR_ENV"; then sed -i "s/^RUN=.*/RUN=$RUN/" "$DR_ENV"; else echo "RUN=$RUN" >>"$DR_ENV"; fi
}
run_started() {   # a run started again after a stop carries on in the same folder
  local k
  k=$(grep -c -E ' run [0-9]+ started' "$LOGDIR/events.log" 2>/dev/null || true)
  if [ "${k:-0}" -gt 0 ]; then event "run $RUN started (attempt $((k + 1)))"; else event "run $RUN started"; fi
}

run_step() {   # run_step <n> <text> [step...]: a stage of the overview under its name in the progress header, then its numbered steps
  local w i=0 t l first=1 pre
  w=$(cols)
  w=$((w > 84 ? 76 : w - 8))
  logln "   $1 ${STAGES[$1 - 1]}: $2"
  kind text
  for t in "$2" "${@:3}"; do
    pre="" first=1
    if [ "$i" -gt 0 ]; then pre="$i. "; logln "      $pre$t"; fi
    while IFS= read -r l; do
      if [ "$i" = 0 ] && [ "$first" = 1 ]; then printf '   %s%-12s%s%s\n' "$C_B" "${STAGES[$1 - 1]}" "$C_OFF" "$(paint "$l")"
      elif [ "$first" = 1 ]; then printf '   %12s%s%s\n' "" "$pre" "$(paint "$l")"
      else printf '   %12s%*s%s\n' "" "${#pre}" "" "$(paint "$l")"; fi
      first=0
    done < <(printf '%s\n' "$t" | fold -s -w $((w - 12 - ${#pre})) | sed 's/ *$//')
    i=$((i + 1))
  done
}
run_overview() {   # what the run will do, before anything starts; returns 1 for Back to the menu
  local a=$ACTIVE p=$PASSIVE m=$MANAGED act prom rj you choice
  if [ "$LAST" != top ]; then start_screen; fi   # a page of its own, after the menu
  run_number
  if [ "$GIT" = 1 ]; then
    act="You merge PR-A to dr/$p, and $(cl "$p")'s own Argo CD swaps its standby restore for an activation restore: $(cl "$a")'s newest backup again, this time with $(cl "$m")'s import token."
    prom="You merge PR-B, and $(cl "$p") starts writing its own backups. Only now, so a failed activation never overwrites $(cl "$a")'s last good backup."
    rj="You merge the demote PR to dr/$a, then power $(cl "$a") back on. It comes back as the passive hub."
    you="cut $(cl "$a")'s power, merge 3 PRs, and power $(cl "$a") back on"
  else
    act="You confirm, and the script swaps $(cl "$p")'s standby restore for an activation restore: $(cl "$a")'s newest backup again, this time with $(cl "$m")'s import token."
    prom="The script starts $(cl "$p")'s own backups. Only now, so a failed activation never overwrites $(cl "$a")'s last good backup."
    rj="You power $(cl "$a") back on; the script makes it the passive hub."
    you="cut $(cl "$a")'s power, confirm the activation, and power $(cl "$a") back on"
  fi
  box double 13 "Run $RUN · $(mode_name): $(cl "$a") goes down, $(cl "$p") takes over" ${RUN_MOVED:+"$RUN_MOVED"} \
    "$(cl "$a") is the active ACM hub, $(cl "$p") the passive one. $(cl "$m")'s own Argo CD syncs a pull app from git; the active hub's Argo CD pushes a push app. Probes record whether both keep answering, and when each gets a new revision."
  blank
  run_step 1 "Read-only checks. Nothing changes before \"Start run $RUN?\"."
  run_step 2 "The probes start, then you cut $(cl "$a")'s power."
  run_step 3 "With no hub up, the script commits a new revision of both apps to $BRANCH. The pull app gets it; the push app waits for a hub."
  run_step 4 "$(cl "$p") has been a warm standby, restoring each of $(cl "$a")'s backups except the managed clusters. To take over:" \
    "Death gate: $(cl "$a")'s API must stay down, so $(cl "$m") never answers to two hubs." \
    "$act" \
    "$(cl "$p") re-imports $(cl "$m") with that token. $(cl "$m")'s agent and addons switch to $(cl "$p"), its apps keep running, and $(cl "$p")'s Argo CD delivers the new revision to the push app." \
    "$prom"
  run_step 5 "$rj"
  run_step 6 "The probes stop, and the script shows what they recorded."
  blank
  explain "Your part: $you; the script stops for each. At the end $(cl "$p") is active and $(cl "$a") passive, so the next run fails over the other way. Past runs: 12 to 33 min plus your pauses. Logs: ${LOGDIR/#$HOME/\~}"
  if [ "$YES" = 1 ] || ! { : </dev/tty; } 2>/dev/null; then return 0; fi
  blank
  if [ "$UI" = gum ]; then
    choice=$(gum choose --header "Next: Pre-flight (read-only)" Continue "Back to the menu" </dev/tty 2>/dev/tty) || if [ $? = 130 ]; then exit 130; fi
  else
    PS3="Next: Pre-flight (read-only). "
    select choice in Continue "Back to the menu"; do if [ -n "$choice" ]; then break; fi; done </dev/tty
  fi
  [ "$choice" = Continue ]
}

cmd_run() {
  local c pinned
  IN_RUN=1 RUN_T0=$SECONDS
  if [ "$UI" = gum ]; then
    for c in "$ACTIVE" "$PASSIVE"; do HUB_URL[$c]=$(server "$c" 2>/dev/null || true); done
    pin_on 6 run_header   # the run's state stays at the top until the summary
  fi
  stage 1
  if ! cmd_check; then
    pinned=$PIN
    pin_off
    if [ "$pinned" = 1 ] && [ ${#RED_LIST[@]} -gt 0 ]; then   # the RED lines may have scrolled off
      label "The pre-flight's RED lines:"
      for c in "${RED_LIST[@]}"; do mark "RED  " "${C_BAD}✗${C_OFF}" "$c"; done
    fi
    die "pre-flight is red: fix it, then run again"
  fi
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
  box rounded 10 "Run $RUN finished in $(dur $((SECONDS - RUN_T0))): $(cl "$PASSIVE") is active, $(cl "$ACTIVE") passive" \
    "Run hack/dr.sh again for run $((RUN + 1)), which fails over the other way."
}

check_alone() {   # hack/dr.sh check: the pre-flight on its own, under a header as build.sh --check has
  STAGES=(Pre-flight) STAGE=1 T0=$SECONDS
  STEPS_TITLE="Check · $(cl "$ACTIVE") active, $(cl "$PASSIVE") passive, $(cl "$MANAGED") workload"
  steps_pin
  if [ "$PIN" = 0 ]; then say "$STEPS_TITLE"; fi
  blank
  explain "$(stage_text 1)"
  cmd_check || return 1
  steps_end
}

# --- main --------------------------------------------------------------------

usage() { sed -n '2,/^set -euo/{/^set -euo/d;s/^# \{0,1\}//;p}' "$SELF"; }
menu() {   # no command on a terminal: say what the exercise does, then pick what to do
  local choice items
  intro "Run the ACM hub DR exercise" \
    "Tests losing the active ACM hub. You cut its power, and the passive hub takes over the workload cluster while probes record whether the two demo apps keep answering and how fast a new git revision reaches them. The hub you cut then rejoins as the new passive hub, so each run fails over the other way." \
    "" \
    "Run (Manual): the script runs the failover commands." \
    "Run (Git): you merge 3 PRs in dr/ for the failover and the return."
  items=(Check "Run (Manual)" "Run (Git)" Quit)
  echo
  if [ "$UI" = gum ]; then
    choice=$(gum choose --header "What would you like to do?" "${items[@]}" </dev/tty 2>/dev/tty) || choice=Quit
  else
    PS3="What would you like to do? "
    select choice in "${items[@]}"; do if [ -n "$choice" ]; then break; fi; done </dev/tty
  fi
  case $choice in
    Check) menu_run check ;;
    "Run (Manual)") GIT=0; run_overview || menu_again; menu_run run ;;
    "Run (Git)") GIT=1; run_overview || menu_again; menu_run run --git ;;
    *) exit 0 ;;
  esac
}

sanity() {
  local c ctxs
  ctxs=$(oc config get-contexts -o name)
  for c in "$ACTIVE" "$PASSIVE" "$MANAGED"; do
    grep -qx -- "$c" <<<"$ctxs" || die "no kubeconfig context named '$(cl "$c")' (KUBECONFIG=${KUBECONFIG:-default})"
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
  sec_flush
  pin_off
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

case $CMD in _probe-*) ;; *) start_screen ;; esac
if [ -z "$CMD" ]; then
  if [ -t 0 ] && [ -t 1 ]; then menu; else usage; exit 2; fi
fi
# a run starts with what it will do (a run picked from the menu showed it there)
if [ "$CMD" = run ] && [ "${DR_MENU:-0}" = 0 ] && ! run_overview; then menu_again; fi
case $CMD in
  _probe-http) echo $$ >>"$PROBE_PIDS"; probe_http "${ARGS[0]}" ;;
  _probe-pointer) echo $$ >>"$PROBE_PIDS"; probe_pointer "${ARGS[0]}" ;;
  _probe-revision) echo $$ >>"$PROBE_PIDS"; probe_revision ;;
  check | nodes | probe | outage | deploy | failover | rejoin | run)
    if [ "$CMD" = run ]; then run_number; fi   # a run from the menu: its page did this already
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
    if [ "$CMD" = check ]; then check_alone || { DIED=1; exit 1; }; else "cmd_$CMD"; fi
    ;;
  *) usage; exit 2 ;;
esac
