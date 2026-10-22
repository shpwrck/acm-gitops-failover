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

# --- helpers -----------------------------------------------------------------

now() { date -u +%FT%TZ; }
event() { echo "$(now) $*" | tee -a "$LOGDIR/events.log"; }
say() { printf '\n== %s\n' "$*"; }
die() { printf '\nSTOP: %s\n' "$*" >&2; exit 1; }
not() { ! "$@"; }
confirm() {
  [ "$YES" = 1 ] && return 0
  local answer=""
  read -r -p "$1 [y/N] " answer </dev/tty || true
  [ "$answer" = y ] || [ "$answer" = Y ] || die "stopped at your request"
}
flag() { if [ "$GIT" = 1 ]; then echo " --git"; fi; }
mode_name() { if [ "$GIT" = 1 ]; then echo git-driven; else echo manual; fi; }

server() { oc config view --minify --context "$1" -o jsonpath='{.clusters[0].cluster.server}'; }
api_rc() { local rc=0; curl -sk --max-time 5 -o /dev/null "$(server "$1")/version" || rc=$?; echo "$rc"; }
# alive: any HTTP answer. dead: connection refused or timed out. A name that
# does not resolve is neither: that is DNS trouble, not proof of death.
alive() { [ "$(api_rc "$1")" = 0 ]; }
dead() { case $(api_rc "$1") in 7 | 28) return 0 ;; *) return 1 ;; esac; }

# wait_for <seconds> <command...>: retry every 5 s; non-zero on timeout
wait_for() {
  local end=$((SECONDS + $1)); shift
  until "$@" >/dev/null 2>&1; do
    [ "$SECONDS" -lt "$end" ] || return 1
    sleep 5
  done
}
# wait_until <seconds> <what> <command...>: wait_for, and stop on timeout
wait_until() {
  local limit=$1 what=$2; shift 2
  echo "   waiting for $what (up to $((limit / 60)) min)"
  wait_for "$limit" "$@" || die "timed out waiting for $what"
}

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
ready_up() {   # wait for <context>'s API, then approve certificates until its nodes are Ready (G.1's power-on note)
  local c=$1 end=$((SECONDS + 1800))
  alive "$c" || wait_until 7200 "$c's API to answer" alive "$c"
  echo "   approving pending certificate requests on $c until its nodes are Ready (up to 30 min)"
  until nodes_ready "$c" && not pending_csrs "$c"; do
    [ "$SECONDS" -lt "$end" ] || die "$c: nodes not Ready, or certificate requests still pending, after 30 min"
    approve_csrs "$c" || true
    sleep 20
  done
  echo "   $c: nodes Ready, no pending certificate requests"
}

# --- git ---------------------------------------------------------------------

git_ready() {
  [ -z "$(git status --porcelain --untracked-files=no)" ] || die "the repo at $REPO has uncommitted changes"
  git checkout -q "$BRANCH"
  git pull -q --ff-only
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
open_pr() {   # open_pr <branch> <title> <body>
  if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
    gh pr create --base "$BRANCH" --head "$1" --title "$2" --body "$3"
  else
    local url; url=$(git remote get-url origin | sed -e 's#^git@github.com:#https://github.com/#' -e 's#\.git$##')
    echo "   open the PR: $url/compare/$BRANCH...$1?expand=1"
    echo "   title: $2"
    printf '%s\n' "$3" | sed 's/^/   | /'
  fi
}
merged() { git fetch -q origin "$BRANCH" 2>/dev/null && git show "origin/$BRANCH:dr/$1/kustomization.yaml" 2>/dev/null | grep -Fx -- "  - $2" >/dev/null; }
wait_merged() {   # wait_merged <hub> <resources line the merge brings>
  local end=$((SECONDS + 7200))
  echo "   merge the PR into $BRANCH; waiting for it to land (up to 2 h)"
  until merged "$1" "$2"; do
    [ "$SECONDS" -lt "$end" ] || die "the PR did not land within 2 h"
    sleep 15
  done
  git checkout -q "$BRANCH"
  git pull -q --ff-only
}

# --- check -------------------------------------------------------------------

BAD=0
ok() { echo "   ok    $*"; }
red() { echo "   RED   $*"; BAD=1; }
note() { echo "   note  $*"; }
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
  if [ "$BAD" = 1 ]; then echo; echo "PRE-FLIGHT RED: power the clusters on, then run hack/dr.sh nodes"; return 1; fi
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
  expect "pull app answers 200 (serves $(revision "$APP_URL"))" "pull app does not answer 200" http_ok "$APP_URL"
  out=$(app_state "$MANAGED" "hello-failover-$MANAGED")
  if [ "$out" = "Synced Healthy" ]; then ok "pull app Synced Healthy on $MANAGED"; else red "pull app on $MANAGED is '$out'"; fi
  if [ -n "$PUSH_APP_URL" ]; then
    expect "push app answers 200 (serves $(revision "$PUSH_APP_URL"))" "push app does not answer 200" http_ok "$PUSH_APP_URL"
    out=$(app_state "$a" "hello-failover-push-$MANAGED")
    if [ "$out" = "Synced Healthy" ]; then ok "push app Synced Healthy on $a"; else red "push app on $a is '$out'"; fi
  fi

  echo
  if [ "$BAD" = 0 ]; then
    echo "PRE-FLIGHT GREEN: $a active, $p passive"
  else
    echo "PRE-FLIGHT RED: fix the RED lines first"
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
  PROBE_PIDS=$LOGDIR/probe.pids setsid bash "$SELF" "$@" >>"$LOGDIR/$log" 2>/dev/null </dev/null &
}
probes_running() { [ -s "$LOGDIR/probe.pids" ] && kill -0 "$(head -n 1 "$LOGDIR/probe.pids")" 2>/dev/null; }

probe_start() {
  if probes_running; then note "probes already running for run $RUN"; return 0; fi
  rm -f "$LOGDIR/probe.pids"
  spawn probe.log _probe-http "$APP_URL"
  if [ -n "$PUSH_APP_URL" ]; then spawn probe-push.log _probe-http "$PUSH_APP_URL"; fi
  spawn hub-pointer.log _probe-pointer "$MANAGED"
  spawn revisions.log _probe-revision
  event "A probes started (logs in $LOGDIR)"
  sleep 15
  tail -n 1 "$LOGDIR"/probe*.log "$LOGDIR/hub-pointer.log" "$LOGDIR/revisions.log"
}
probe_stop() {
  local pid
  if [ ! -s "$LOGDIR/probe.pids" ]; then note "no probes recorded for run $RUN"; return 0; fi
  while read -r pid; do kill -- "-$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true; done <"$LOGDIR/probe.pids"
  rm -f "$LOGDIR/probe.pids"
  event "A probes stopped"
}
probe_summary() {
  local f
  say "Run $RUN summary ($LOGDIR)"
  for f in "$LOGDIR"/probe*.log; do
    [ -f "$f" ] || continue
    echo "$(basename "$f"): $(head -n 1 "$f" | cut -d' ' -f1) to $(tail -n 1 "$f" | cut -d' ' -f1)," \
      "$(wc -l <"$f") samples, $(grep -c -v ' 200$' "$f" || true) not 200"
    grep -v ' 200$' "$f" | head -n 5 || true
  done
  if [ -f "$LOGDIR/hub-pointer.log" ]; then
    echo "hub pointer:"
    awk '{s = $2 == "" ? "(read failed)" : $2} s != last {print "  " $1, s; last = s}' "$LOGDIR/hub-pointer.log"
  fi
  if [ -f "$LOGDIR/revisions.log" ]; then echo "served revisions:"; sed 's/^/  /' "$LOGDIR/revisions.log"; fi
  if [ -f "$LOGDIR/events.log" ]; then echo "events:"; sed 's/^/  /' "$LOGDIR/events.log"; fi
}

cmd_probe() {
  case ${ARGS[0]:-} in
    start) probe_start ;;
    stop) probe_stop ;;
    summary) probe_summary ;;
    *) die "usage: hack/dr.sh probe start|stop|summary" ;;
  esac
}

# --- outage (B) --------------------------------------------------------------

slot_clear() {   # 5 to 26 min past a :00/:30 slot, and no backup in progress
  local m=$((10#$(date -u +%M) % 30))
  [ "$m" -ge 5 ] && [ "$m" -le 26 ] && not backup_running "$1"
}

cmd_outage() {
  local a=$ACTIVE node
  alive "$a" || die "$a's API does not answer: is it already down?"
  say "B.0: lab safety net, an etcd backup of $a"
  node=$(oc --context "$a" get nodes -l node-role.kubernetes.io/master -o jsonpath='{.items[0].metadata.name}')
  oc --context "$a" debug "node/$node" -- chroot /host /usr/local/bin/cluster-backup.sh /home/core/assets/backup
  event "B.0 etcd backup saved on $a ($node:/home/core/assets/backup)"
  wait_until 1800 "a cut time clear of the :00/:30 backup slots, with no backup in progress" slot_clear "$a"
  oc --context "$a" get "$VBACKUP" -n "$NS" --sort-by=.status.startTimestamp \
    -o custom-columns='NAME:.metadata.name,PHASE:.status.phase,START:.status.startTimestamp' | tail -n 6

  say "B.1: cut $a's power now"
  echo "   hold the power button about 5 s (a short press is a graceful shutdown), pull the plug, or use a hard power-off"
  wait_until 1800 "$a's API to stop answering" dead "$a"
  event "B.1 $a API dead (power cut by hand)"
  say "B.2: the workload does not care"
  sleep 20
  tail -n 3 "$LOGDIR/probe.log" 2>/dev/null || note "no availability probe running (hack/dr.sh probe start)"
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
  git add "$f" "$fp"
  git commit -q -m "REVISION pull v$n, push v$np (DR run $RUN, mid-outage deploy)"
  git push -q
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
      oc --context "$p" delete "$RESTORE" "$name" -n "$NS"
      sleep 15
      wait_until 600 "the re-created $name to finish" restore_finished "$p" "$name"
    fi
  fi
  if [ "$(phase "$p" "$RESTORE" "$name")" != Finished ]; then
    oc --context "$p" describe "$RESTORE" "$name" -n "$NS" | tail -n 25
    die "$name ended $(phase "$p" "$RESTORE" "$name"): read the message above (Manual Pull Path D.2 failure modes)"
  fi
  event "D.2 $name Finished"
}

claim_and_verify() {   # D.3, E.1, E.2, E.3 on the new hub
  local p=$PASSIVE
  say "D.3: the claim"
  wait_until 300 "the restored ManagedCluster $MANAGED on $p" some "$p" managedcluster "$MANAGED"
  oc --context "$p" wait "managedcluster/$MANAGED" --for=condition=ManagedClusterConditionAvailable --timeout=15m
  event "D.3 claim landed: $MANAGED Available on $p"
  oc --context "$p" get managedclusters
  say "E.1: addons"
  wait_until 900 "every addon on $MANAGED to be Available" addons_available "$p"
  event "E.1 all addons Available"
  oc --context "$p" get managedclusteraddon -n "$MANAGED"
  say "E.2: re-home evidence"
  awk '{s = $2 == "" ? "(read failed)" : $2} s != last {print "   " $1, s; last = s}' "$LOGDIR/hub-pointer.log" 2>/dev/null | tail -n 3 || true
  echo "   availability samples not 200: $(grep -c -v ' 200$' "$LOGDIR/probe.log" 2>/dev/null || true)"
  say "E.3: the restored MSA secret"
  if wait_for 120 token_adopted "$p"; then
    event "E.3 restored token adopted and rotated by the controller ($(msa_token "$p"))"
  else
    oc --context "$p" delete secret auto-import-account -n "$MANAGED"
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
  oc --context "$p" get "$VBACKUP" -n "$NS" --sort-by=.status.startTimestamp \
    -o custom-columns='NAME:.metadata.name,PHASE:.status.phase,START:.status.startTimestamp' | tail -n 6
  say "F.2: GitOps wiring"
  oc --context "$p" get gitopscluster,placement,applicationset -n "$GNS"
  oc --context "$p" get "$APP" -n "$GNS"
}

push_resurrection() {   # E': the push app serving the mid-outage revision is push delivery back
  local np
  if [ -z "$PUSH_APP_URL" ] || [ ! -s "$LOGDIR/deploy.rev" ]; then return 0; fi
  np=$(cut -d' ' -f2 "$LOGDIR/deploy.rev")
  say "E': push delivery"
  oc --context "$PASSIVE" get secret -n "$GNS" -l apps.open-cluster-management.io/acm-cluster=true
  if wait_for 1200 serves "$PUSH_APP_URL" "v$np"; then
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
  oc --context "$p" delete "$RESTORE" restore-acm-activate -n "$NS" --ignore-not-found
  oc --context "$p" delete "$RESTORE" restore-acm-passive-sync -n "$NS" --ignore-not-found
  wait_until 120 "the passive restore to be gone" none "$p" "$RESTORE" restore-acm-passive-sync -n "$NS"
  event "D.1 passive restore deleted"
  oc --context "$p" apply -f manifests/57-restore-activate.yaml
  event "D.2 activation applied"
  activation_restore restore-acm-activate
  claim_and_verify
  say "F.1: start backups on $p"
  oc --context "$p" apply -f manifests/55-backupschedule.yaml
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
  git checkout -q -b "failover-$stamp"
  cp dr/templates/restore-activate.template.yaml "dr/$p/restore-activate-$stamp.yaml"
  sed -i "s/<UTCSTAMP>/$stamp/" "dr/$p/restore-activate-$stamp.yaml"
  sed -i "s#^  - ../roles/passive\$#  - restore-activate-$stamp.yaml#" "dr/$p/kustomization.yaml"
  [ "$(overlay "$p")" = "restore-activate-$stamp.yaml" ] || die "dr/$p lists '$(overlay "$p")'"
  git add dr/
  git commit -q -m "FAILOVER: activate $p ($ACTIVE dead $(now))"
  git push -q -u origin HEAD
  event "D'.1 PR-A branch failover-$stamp pushed"
  open_pr "failover-$stamp" "FAILOVER: activate $p" \
    "Activation only (PR-A). Review gate: $ACTIVE is dead; hack/dr.sh found its API refusing connections at $(now). Merging is the failover decision."
  git checkout -q "$BRANCH"
  say "D'.2: review = the death gate, merge = the decision"
  echo "   the reviewer's death check: curl -sk --max-time 5 $(server "$ACTIVE")/version || echo DEAD"
  wait_merged "$p" "restore-activate-$stamp.yaml"
  event "D'.2 PR-A merged"
  if not dead "$ACTIVE"; then note "$ACTIVE no longer reads dead: if it is back, you now have two live hubs (B.1 failure)"; fi

  say "D'.3: $p executes"
  refresh_dr_role "$p" normal
  activation_restore "restore-acm-activate-$stamp"
  claim_and_verify

  say "F': the promotion PR (PR-B)"
  git_ready
  git checkout -q -b "promote-$stamp"
  sed -i "s#^  - restore-activate-$stamp.yaml\$#  - ../roles/active\n  - restore-activate-$stamp.yaml#" "dr/$p/kustomization.yaml"
  [ "$(overlay "$p")" = "../roles/active restore-activate-$stamp.yaml" ] || die "dr/$p lists '$(overlay "$p")'"
  git add dr/
  git commit -q -m "PROMOTE: $p to full active (claim verified)"
  git push -q -u origin HEAD
  event "F' PR-B branch promote-$stamp pushed"
  open_pr "promote-$stamp" "PROMOTE: $p to full active" \
    "Promotion (PR-B). Review gate: $MANAGED is claimed on $p:
$(oc --context "$p" get managedclusters -o custom-columns='NAME:.metadata.name,AVAILABLE:.status.conditions[?(@.type=="ManagedClusterConditionAvailable")].status')"
  git checkout -q "$BRANCH"
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
  sleep 10
  dead "$ACTIVE" || die "$ACTIVE's API answered again"
  event "B $ACTIVE API refuses connections or times out (death gate passed)"
  if [ "$GIT" = 1 ]; then failover_git; else failover_manual; fi
  push_resurrection
  event "failover done: $PASSIVE active"
  say "Failover done: $PASSIVE is active and backing up"
  echo "Next: hack/dr.sh rejoin$(flag)"
}

# --- rejoin (G, H.1) ---------------------------------------------------------

defuse() {   # G.2: the returned hub's BackupSchedule and the Velero schedules it owned
  oc --context "$1" delete "$BSCHED" schedule-acm -n "$NS" --ignore-not-found &&
    oc --context "$1" delete "$VSCHED" -n "$NS" --all &&
    none "$1" "$BSCHED" -n "$NS" && none "$1" "$VSCHED" -n "$NS"
}
defuse_now() {   # retry while the returned hub settles, approving certificates meanwhile
  local a=$1 end=$((SECONDS + 1800))
  until defuse "$a" >/dev/null 2>&1; do
    [ "$SECONDS" -lt "$end" ] || die "could not delete $a's schedules within 30 min"
    approve_csrs "$a" >/dev/null 2>&1 || true
    sleep 10
  done
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
  git checkout -q -b "demote-$stamp"
  sed -i 's#^  - ../roles/active$#  - ../roles/passive#; /^  - restore-activate-.*\.yaml$/d' "dr/$a/kustomization.yaml"
  git rm -q --ignore-unmatch "dr/$a"/restore-activate-*.yaml
  [ "$(overlay "$a")" = ../roles/passive ] || die "dr/$a lists '$(overlay "$a")'"
  git add -A dr/
  git commit -q -m "DEMOTE: $a to passive"
  git push -q -u origin HEAD
  event "G'.1 demote branch demote-$stamp pushed"
  open_pr "demote-$stamp" "DEMOTE: $a to passive" \
    "Demote the failed hub. Review gate: posture correctness ($PASSIVE is active and backing up). Safe to merge while $a is down: it boots into this."
  git checkout -q "$BRANCH"
  wait_merged "$a" "../roles/passive"
  event "G'.1 demote PR merged"
}

realign_git() {   # H.1, after a manual failover
  local a=$ACTIVE p=$PASSIVE rev c
  say "H.1: re-align dr/ with the new roles, then re-enable automation"
  git_ready
  sed -i 's#^  - ../roles/active$#  - ../roles/passive#; /^  - restore-activate-.*\.yaml$/d' "dr/$a/kustomization.yaml"
  git rm -q --ignore-unmatch "dr/$a"/restore-activate-*.yaml
  sed -i 's#^  - ../roles/passive$#  - ../roles/active#' "dr/$p/kustomization.yaml"
  if [ "$(overlay "$a")" != ../roles/passive ] || [ "$(overlay "$p")" != ../roles/active ]; then
    die "unexpected overlays after the re-align: dr/$a lists '$(overlay "$a")', dr/$p lists '$(overlay "$p")'"
  fi
  if [ -n "$(git status --porcelain dr/)" ]; then
    git add -A dr/
    git commit -q -m "Re-align dr/: $p active, $a passive (manual failover)"
    git push -q
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
    echo "   $c:"
    oc --context "$c" get "$BSCHED,$RESTORE" -n "$NS" \
      -o custom-columns='KIND:.kind,NAME:.metadata.name,CREATED:.metadata.creationTimestamp' | sed 's/^/     /'
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

  say "G: power $a back on now"
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
    oc --context "$a" delete "$RESTORE" restore-acm-activate -n "$NS" --ignore-not-found   # untracked residue of a manual activation
  fi

  if some "$a" managedcluster "$MANAGED"; then
    say "G.1: wait out the lease (deleting the claim while it reads True would uninstall $MANAGED's agent)"
    wait_until 1800 "$MANAGED to read Available=Unknown on $a" mc_available "$a" Unknown
    event "G.1 $MANAGED Unknown on $a"
    say "G.3: drop the stale claim"
    oc --context "$a" delete managedcluster "$MANAGED" --timeout=5m
    event "G.3 stale claim on $a deleted"
  fi

  say "G.4: $a as passive"
  if [ "$GIT" = 0 ]; then oc --context "$a" apply -f manifests/56-restore-passive.yaml; fi
  wait_until 900 "restore-acm-passive-sync Enabled on $a" restore_enabled "$a" restore-acm-passive-sync
  event "G.4 $a passive sync Enabled"
  if [ "$GIT" = 0 ]; then
    say "G.5: the stale activation restores"
    oc --context "$a" get "$RESTORE" -n "$NS" -o name | { grep restore-acm-activate || true; } |
      xargs -r -n1 oc --context "$a" delete -n "$NS"
    event "G.5 old activation restores on $a deleted"
    if has_dr_role "$a" && has_dr_role "$p"; then realign_git; fi
  fi
  oc --context "$a" get "$RESTORE" -n "$NS"

  sed -i -e "s/^ACTIVE=.*/ACTIVE=$p/" -e "s/^PASSIVE=.*/PASSIVE=$a/" "$DR_ENV"
  if grep -q '^RUN=' "$DR_ENV"; then sed -i "s/^RUN=.*/RUN=$((RUN + 1))/" "$DR_ENV"; else echo "RUN=$((RUN + 1))" >>"$DR_ENV"; fi
  event "rejoin done: $p active, $a passive; $DR_ENV now says ACTIVE=$p PASSIVE=$a RUN=$((RUN + 1))"
  cmd_check "$p" "$a" || note "the new posture is not green yet: rerun hack/dr.sh check in a few minutes"
}

# --- run ---------------------------------------------------------------------

cmd_run() {
  say "Run $RUN ($(mode_name)): $ACTIVE dies, $PASSIVE takes over"
  cmd_check || die "pre-flight is red: fix it, then run again"
  confirm "Start run $RUN?"
  probe_start
  cmd_outage
  cmd_deploy
  cmd_failover
  cmd_rejoin
  probe_stop
  probe_summary
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

case $CMD in
  _probe-http) echo $$ >>"$PROBE_PIDS"; probe_http "${ARGS[0]}" ;;
  _probe-pointer) echo $$ >>"$PROBE_PIDS"; probe_pointer "${ARGS[0]}" ;;
  _probe-revision) echo $$ >>"$PROBE_PIDS"; probe_revision ;;
  check | nodes | probe | outage | deploy | failover | rejoin | run)
    sanity
    case $CMD in
      check | probe) "cmd_$CMD" ;;
      *) "cmd_$CMD" 2>&1 | tee -a "$LOGDIR/console.log" ;;
    esac
    ;;
  *) sed -n '2,/^set -euo/{/^set -euo/d;s/^# \{0,1\}//;p}' "$0"; exit 2 ;;
esac
