#!/usr/bin/env bash
# Build: from three OpenShift clusters to the DR exercise hack/dr.sh runs,
# the steps of docs/build.md in order. docs/build.md explains each stage.
#
# Usage: hack/build.sh [--check] [--yes]
#
# With no options, on a terminal, it shows a menu: Check, Build, Quit. Each
# pick comes back to the menu when it ends; only Quit (or Ctrl-C) leaves.
#
#   (default)  build: ACM on both hubs (pinned to one version), OpenShift
#              GitOps on all three clusters, backup storage, the import of
#              the workload cluster, the demo apps, the backup roles and the
#              git-driven dr-role applications; then hack/dr.sh check
#   --check    the pre-flight, read-only on the clusters: what the build
#              would install, reuse or refuse, and why
#   --yes      use the settings file as it is, and do not ask before installing
#
# It reuses an ACM or OpenShift GitOps that is already installed (docs/build.md
# "A hub that already runs ACM"), and it can run again after a stop: every
# stage skips what is already in place. hack/teardown.sh undoes it.
# Settings: $DR_ENV (default ~/acm-dr/dr.env; see hack/dr.env.example). On a
# terminal, the build and the check start with a Settings stage. With no file
# yet, it asks which contexts are the hubs and the workload cluster, the branch
# and the bucket, and writes it, with a kubeconfig next to it in which those
# contexts are named hub-x, hub-y and spoke; with a file, it shows it, to keep
# or change. The build writes APP_URL and PUSH_APP_URL there once the demo
# apps answer.
# S3: S3_URL, S3_BUCKET, S3_PREFIX, S3_REGION and S3_CA_FILE from the settings
# file (or asked for). The access key and secret key are asked for, or read
# from S3_ACCESS_KEY and S3_SECRET_KEY in the environment; they go into a
# secret on each hub and are written nowhere else.
# Log: ~/acm-dr/logs/build-<time>.log
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SELF=$REPO/hack/build.sh
DR_ENV=${DR_ENV:-$HOME/acm-dr/dr.env}
cd "$REPO"

CHECK=0 YES=0 ARGC=$#
for a in "$@"; do
  case $a in
    --check) CHECK=1 ;;
    --yes) YES=1 ;;
    *) sed -n '2,/^set -euo/{/^set -euo/d;s/^# \{0,1\}//;p}' "$SELF"; exit 2 ;;
  esac
done

# shellcheck source=hack/lib/common.sh
. "$REPO/hack/lib/common.sh"

# --- settings ----------------------------------------------------------------------

GUM_PAD="1 0 0 0"   # top right bottom left: a blank line above each question
ask() {   # ask <prompt> <secret 0|1> [default]: a line from the terminal, with only its printable characters, in ANSWER
  local v="" e=$'\e' b=$'\a' rc=0
  if [ "$UI" = gum ]; then
    # no placeholder: its first letter, under the cursor, reads as typed text. gum draws on
    # stderr, which goes to the log too: straight to the terminal instead, so it redraws
    # cleanly and what you type stays out of the log. Its top padding, a blank line above
    # the question, goes away with the prompt, so answered questions leave no gaps
    if [ "$2" = 1 ]; then v=$(gum input --password --placeholder "" --padding "$GUM_PAD" --header "$1" </dev/tty 2>/dev/tty) || rc=$?
    else v=$(gum input --placeholder "" --padding "$GUM_PAD" --value "${3:-}" --header "$1" </dev/tty 2>/dev/tty) || rc=$?; fi
    gum_stop "$rc"
  else
    kind live
    if [ "$2" = 1 ]; then read -rsp "$1: " v </dev/tty; echo >/dev/tty; else read -rp "$1${3:+ [$3]}: " v </dev/tty; v=${v:-${3:-}}; fi
  fi
  # a pasted line break comes back as a space, and a terminal can slip in escape sequences:
  # none of them belong in a URL or a key
  ANSWER=$(printf '%s' "$v" | LC_ALL=C sed -E "s#${e}\[[0-9;:?<=>]*[ -/]*[@-~]##g; s#${e}[]P^_X][^${e}${b}]*(${b}|${e}\\\\)?##g; s#\[20[01]~##g" |
    LC_ALL=C tr -cd '[:graph:]')
}
pick() {   # pick <question> <preselected> <choice...>: one of the choices, picked on the terminal, in ANSWER
  local rc=0
  if [ "$UI" = gum ]; then
    ANSWER=$(gum choose --padding "$GUM_PAD" --header "$1" ${2:+--selected "$2"} "${@:3}" </dev/tty 2>/dev/tty) || rc=$?
    gum_stop "$rc"
    return 0
  fi
  kind live
  PS3="$1 "
  select ANSWER in "${@:3}"; do if [ -n "$ANSWER" ]; then return 0; fi; done </dev/tty
  die "stopped at your request"
}
url_ok() { [[ $1 =~ ^https?://[^/#[:space:]]+(/[^#[:space:]]*)?$ ]]; }   # url_ok <text>: an http(s) URL the settings file can hold
set_setting() {   # set_setting <name> <value>: in the settings file
  if grep -q "^$1=" "$DR_ENV"; then sed -i "s#^$1=.*#$1=$2#" "$DR_ENV"; else echo "$1=$2" >>"$DR_ENV"; fi
}
load_settings() {   # the settings file, into the names the stages use
  DR_ENV=$(readlink -f "$DR_ENV")
  # shellcheck source=/dev/null
  . "$DR_ENV"
  : "${ACTIVE:?set ACTIVE in $DR_ENV}" "${PASSIVE:?set PASSIVE in $DR_ENV}"
  MANAGED=${MANAGED:-spoke}
  BRANCH=${BRANCH:-main}
  S3_URL=${S3_URL-}
  S3_BUCKET=${S3_BUCKET:-acm-backups}
  S3_PREFIX=${S3_PREFIX:-acm}
  S3_REGION=${S3_REGION:-us-east-1}
  S3_CA_FILE=${S3_CA_FILE:-}
  if [ -n "${KUBECONFIG:-}" ]; then export KUBECONFIG; fi
  HUBS=("$ACTIVE" "$PASSIVE")
  CLUSTERS=("$ACTIVE" "$PASSIVE" "$MANAGED")
}
settings_title() {   # the header's first line, once the settings are known
  STEPS_TITLE="Build$(if [ "$CHECK" = 1 ]; then echo " check"; fi) · $(cl "$ACTIVE") active, $(cl "$PASSIVE") passive, $(cl "$MANAGED") workload"
}
settings_show() {   # what the settings file holds
  local at="at ${S3_URL:-AWS S3}" k=${KUBECONFIG:-$HOME/.kube/config}
  if [ -z "$S3_URL" ] && ! grep -q '^S3_URL=' "$DR_ENV"; then at="endpoint not set yet"; fi
  line "     kubeconfig  ${k//$HOME/\~}"
  line "     hubs        $(cl "$ACTIVE") active, $(cl "$PASSIVE") passive"
  line "     workload    $(cl "$MANAGED")"
  line "     branch      $BRANCH"
  line "     storage     s3://$S3_BUCKET/$S3_PREFIX in $S3_REGION, $at${S3_CA_FILE:+, CA file $S3_CA_FILE}"
  line "     demo apps   ${APP_URL:-not deployed yet (the build saves their URLs)}"
  line "     next run    ${RUN:-1}"
}
settings_routes() {   # settings without the demo apps' URLs, on an exercise that has the apps: the URLs from their routes
  local h
  if [ -n "${APP_URL:-}" ]; then return 0; fi
  h=$(oc --context "$MANAGED" get routes.route.openshift.io -n hello-failover -o jsonpath='{.items[0].spec.host}' 2>/dev/null || true)
  if [ -z "$h" ]; then return 0; fi   # not deployed yet: the Demo apps stage saves them
  APP_URL=https://$h
  set_setting APP_URL "$APP_URL"
  h=$(oc --context "$MANAGED" get routes.route.openshift.io -n hello-failover-push -o jsonpath='{.items[0].spec.host}' 2>/dev/null || true)
  if [ -n "$h" ]; then PUSH_APP_URL=https://$h; set_setting PUSH_APP_URL "$PUSH_APP_URL"; fi
  finished "APP_URL and PUSH_APP_URL from the demo apps' routes on $(cl "$MANAGED"), saved"
}
ask_settings() {   # ask_settings new|change: ask for the settings, from the file's values (change) or the usual ones (new); write them and the kubeconfig
  local mode=$1 src ctxs a p m kc tmp branch bucket prefix region url ca n=0 act=hub-x pas=hub-y
  kc=$(dirname "$DR_ENV")/kubeconfig
  src=${KUBECONFIG:-$HOME/.kube/config}
  while [ "$n" -lt 3 ]; do
    ask "Your kubeconfig" 0 "${src/#$HOME/\~}"; src=$ANSWER
    src=${src/#\~/$HOME}
    ctxs=$(KUBECONFIG=$src oc config get-contexts -o name 2>/dev/null) || ctxs=""
    n=$(grep -c . <<<"$ctxs" || true)
    if [ "$n" -lt 3 ]; then note "${src/#$HOME/\~} has $n contexts: the exercise needs three, two hubs and a workload cluster"; fi
  done
  if [ "$mode" = change ]; then branch=$BRANCH; else branch=$(git branch --show-current 2>/dev/null || echo main); fi
  while :; do
    ask "Branch the clusters pull from (the targetRevision in your copy)" 0 "$branch"; branch=$ANSWER
    git fetch -q origin "$branch" 2>/dev/null || true
    if git rev-parse -q --verify "origin/$branch" >/dev/null; then break; fi
    note "no branch $branch on origin: push it first, or name another"
  done
  # dr/ on the branch says which hub starts active: hub-x in a fresh copy, hub-y once a failover to it is committed there
  local BRANCH=$branch
  if [[ $(git_role hub-y) == active* ]]; then act=hub-y pas=hub-x; fi
  # shellcheck disable=SC2086 # one context per word
  pick "Which context is the hub that starts active ($act)?" "$act" $ctxs; a=$ANSWER
  # shellcheck disable=SC2046 # one context per word
  pick "Which context is the hub that starts passive ($pas)?" "$pas" $(grep -vx -- "$a" <<<"$ctxs"); p=$ANSWER
  # shellcheck disable=SC2046 # one context per word
  pick "Which context is the workload cluster (spoke)?" spoke $(grep -vx -e "$a" -e "$p" <<<"$ctxs"); m=$ANSWER
  if [ "$(readlink -f "$src")" = "$(readlink -f "$kc")" ] && [ "$a" = "$act" ] && [ "$p" = "$pas" ] && [ "$m" = spoke ]; then
    finished "${kc/#$HOME/\~}: as it was"
  else
    if [ "$mode" = new ] && [ -e "$kc" ]; then confirm "Replace ${kc/#$HOME/\~}?"; fi
    mkdir -p "$(dirname "$DR_ENV")"
    tmp=$(mktemp)
    chmod 600 "$tmp"   # it holds cluster credentials
    KUBECONFIG=$src oc config view --flatten >"$tmp"
    # through placeholder names, so that picking hub-y as hub-x (or the like) cannot collide
    KUBECONFIG=$tmp oc config rename-context "$a" "dr-new-$act" >/dev/null
    KUBECONFIG=$tmp oc config rename-context "$p" "dr-new-$pas" >/dev/null
    KUBECONFIG=$tmp oc config rename-context "$m" dr-new-spoke >/dev/null
    for n in hub-x hub-y spoke; do
      KUBECONFIG=$tmp oc config delete-context "$n" >/dev/null 2>&1 || true   # one you did not pick, under a name the exercise needs
      KUBECONFIG=$tmp oc config rename-context "dr-new-$n" "$n" >/dev/null
    done
    KUBECONFIG=$tmp oc config use-context "$act" >/dev/null
    mv "$tmp" "$kc"
    finished "${kc/#$HOME/\~}: a copy of your kubeconfig, with three contexts renamed"
    line "     $(cl "$act")  the active hub, your $a"
    line "     $(cl "$pas")  the passive hub, your $p"
    line "     $(cl spoke)  the workload cluster, your $m"
  fi
  ask "S3 bucket for the backups" 0 "${S3_BUCKET:-acm-backups}"; bucket=$ANSWER
  ask "Prefix in the bucket" 0 "${S3_PREFIX:-acm}"; prefix=$ANSWER
  ask "S3 region" 0 "${S3_REGION:-us-east-1}"; region=$ANSWER
  url=${S3_URL:-}
  while :; do
    ask "S3 endpoint URL (e.g. https://s3.example.com; empty for AWS S3)" 0 "$url"; url=$ANSWER
    url=${url%/}
    if [ -z "$url" ] || url_ok "$url"; then break; fi
    note "'$url' is not an http(s) URL: enter the endpoint only"
  done
  ca=${S3_CA_FILE:-}
  while :; do
    ask "CA file (PEM) of the S3 endpoint; empty if its certificate is publicly trusted" 0 "$ca"; ca=$ANSWER
    if [ -z "$ca" ] || [ -f "${ca/#\~/$HOME}" ]; then break; fi
    note "no file at $ca"
  done
  if [ "$mode" = new ]; then
    # the build writes the demo apps' routes once they answer
    sed -e '/^# routes of the two demo apps/,/^$/d' -e 's/^# S3_URL=.*/S3_URL=/' "$REPO/hack/dr.env.example" >"$DR_ENV"
    # the next run's number: after the runs whose logs are in ~/acm-dr/runs
    n=$(find "$HOME/acm-dr/runs" -maxdepth 1 -name 'run-*' -printf '%f\n' 2>/dev/null | sed -n 's/^run-\([0-9][0-9]*\)$/\1/p' | sort -n | tail -n 1)
    set_setting RUN $((${n:-0} + 1))
  fi
  set_setting KUBECONFIG "${kc/#$HOME/\~}"
  set_setting ACTIVE "$act"
  set_setting PASSIVE "$pas"
  set_setting MANAGED spoke
  set_setting BRANCH "$branch"
  set_setting S3_URL "$url"
  set_setting S3_BUCKET "$bucket"
  set_setting S3_PREFIX "$prefix"
  set_setting S3_REGION "$region"
  set_setting S3_CA_FILE "$ca"
  finished "${DR_ENV/#$HOME/\~}, saved:"
}
stage_settings() {   # on a terminal, the first stage: write the settings file, or show it and keep or change it
  if [ ! -f "$DR_ENV" ]; then
    stage Settings "There is no settings file at ${DR_ENV/#$HOME/\~} yet. Answer a few questions and the build writes it, together with $(dirname "${DR_ENV/#$HOME/\~}")/kubeconfig: a copy of your kubeconfig in which the two hubs and the workload cluster are named hub-x, hub-y and spoke, the names the repo's manifests and dr/ use. Your own kubeconfig stays as it is. hack/dr.sh and hack/teardown.sh read the same file. Nothing changes on the clusters in this stage."
    ask_settings new
  else
    stage Settings "The settings file, ${DR_ENV/#$HOME/\~}, names the clusters, the branch they pull from and the backup storage; hack/dr.sh and hack/teardown.sh read it too. Keep it, or change it: the questions start from what it holds. Nothing changes on the clusters in this stage."
    echo
    settings_show
    pick "Use these settings?" "" Keep Change
    if [ "$ANSWER" = Keep ]; then
      logln "   kept"
      settings_routes
      return 0
    fi
    if [ "$PIN" = 1 ]; then pin_clear; stage_head Settings; fi   # the questions on an empty window
    explain "Each question starts from what the settings file holds: Enter keeps it."
    ask_settings change
  fi
  load_settings
  settings_routes
  settings_title
  pin_draw
  settings_show
  go_on "$(stage_name 2 Pre-flight)"
}
if [ -f "$DR_ENV" ]; then load_settings; fi

PV=acm-gitops-failover
SUB=subscriptions.operators.coreos.com
CSV=clusterserviceversions.operators.coreos.com
IPLAN=installplans.operators.coreos.com
MCH=multiclusterhubs.operator.open-cluster-management.io
A_BACKUP=acm-gitops-failover/cluster-backup
A_APPROVAL=acm-gitops-failover/install-plan-approval
TMP=""   # made after the menu: a menu's own process runs nothing that needs it

# --- what is there -----------------------------------------------------------------

sub_of() {   # sub_of <context> <package>: "<namespace> <name>" of the Subscription that installs it
  oc --context "$1" get "$SUB" -A -o json 2>/dev/null |
    jq -r --arg p "$2" 'first(.items[] | select(.spec.name == $p) | "\(.metadata.namespace) \(.metadata.name)") // empty'
}
sub_get() { oc --context "$1" get "$SUB" "${2#* }" -n "${2% *}" -o jsonpath="$3" 2>/dev/null || true; }
labeled() { [ "$(oc --context "$1" get "${@:2}" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/part-of}' 2>/dev/null)" = "$PV" ]; }
csv_ok() {   # csv_ok <context> <namespace> <csv>: installed and Succeeded
  [ "$(oc --context "$1" get "$CSV" "$3" -n "$2" -o jsonpath='{.status.phase}' 2>/dev/null)" = Succeeded ]
}
any_csv() {   # any_csv <context> <namespace> <package>: some CSV of that package is in the namespace
  oc --context "$1" get "$CSV" -n "$2" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -q "^$3\."
}
channel_has() {   # channel_has <context> <package> <channel> <csv>: the cluster's catalog offers that version in that channel
  oc --context "$1" get packagemanifests.packages.operators.coreos.com "$2" -n openshift-marketplace -o json 2>/dev/null |
    jq -e --arg c "$3" --arg v "$4" '.status.channels[] | select(.name == $c) | [.currentCSV, (.entries[]?.name)] | index($v)' >/dev/null
}
channel_head() {   # channel_head <context> <package> <channel>: the newest version the catalog offers
  oc --context "$1" get packagemanifests.packages.operators.coreos.com "$2" -n openshift-marketplace -o json 2>/dev/null |
    jq -r --arg c "$3" '.status.channels[] | select(.name == $c) | .currentCSV' 2>/dev/null || true
}
mch_phase() { oc --context "$1" get "$MCH" -A -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true; }
mch_ref() {   # mch_ref <context>: "<namespace> <name>" of the MultiClusterHub
  oc --context "$1" get "$MCH" -A -o json 2>/dev/null | jq -r 'first(.items[] | "\(.metadata.namespace) \(.metadata.name)") // empty'
}
backup_on() {   # backup_on <context>: the MultiClusterHub has cluster-backup enabled
  [ "$(oc --context "$1" get "$MCH" -A -o json 2>/dev/null |
    jq -r '[.items[0].spec.overrides.components[]? | select(.name == "cluster-backup") | .enabled] | first // false')" = true ]
}
mc_joined() {
  [ "$(oc --context "$1" get managedcluster "$MANAGED" \
    -o jsonpath='{.status.conditions[?(@.type=="ManagedClusterJoined")].status}' 2>/dev/null)" = True ] && mc_available "$1" True
}
argocd_ready() { [ "$(oc --context "$1" get argocds.argoproj.io openshift-gitops -n "$GNS" -o jsonpath='{.status.phase}' 2>/dev/null)" = Available ]; }
app_done() {   # app_done <context> <application>: synced once, Synced and Healthy
  [ "$(oc --context "$1" get "$APP" "$2" -n "$GNS" -o jsonpath='{.status.operationState.phase} {.status.sync.status} {.status.health.status}' 2>/dev/null)" = "Succeeded Synced Healthy" ]
}
manifest_value() { awk -v k="$2:" '$1 == k {print $2; exit}' "$1"; }   # manifest_value <file> <key>: its first value

# --- doing it --------------------------------------------------------------------

act() {   # act <what> <command...>: do it; stop if it fails
  local out rc=0
  out=$("${@:2}" 2>&1) || rc=$?
  if [ "$rc" != 0 ]; then
    show <<<"$out"
    die "could not $1 (its output is above)"
  fi
  if [ -n "$out" ]; then logln "$out"; fi
  finished "$1"
}
apply() {   # apply <context> <file> [what]
  act "$(cl "$1"): apply ${3:-$2}" oc --context "$1" apply -f "$2"
}
pinned() {   # pinned <manifest> <channel> <csv> <out>: a copy of the Subscription with Manual approval, starting at <csv>
  sed -e "s/^  channel: .*/  channel: $2/" \
    -e "s/^  installPlanApproval: Automatic\$/  installPlanApproval: Manual\n  startingCSV: $3/" "$1" >"$4"
  grep -q "^  startingCSV: $3\$" "$4" || die "could not pin $1 to $3"
}
own_plan() {   # own_plan <context> <package> <CSV name prefix> [csv]: the InstallPlan its Subscription waits on, if all of it is that
  # operator's (and holds <csv>, when given). One Subscription on Manual approval makes OLM hold every plan in its namespace,
  # and a plan can carry other operators' changes too: such a plan is never this build's to approve.
  local s ip
  s=$(sub_of "$1" "$2")
  if [ -z "$s" ]; then return 0; fi
  ip=$(sub_get "$1" "$s" '{.status.installPlanRef.name}')
  if [ -z "$ip" ]; then return 0; fi
  oc --context "$1" get "$IPLAN" "$ip" -n "${s% *}" -o json 2>/dev/null | jq -r --arg p "$3." --arg v "${4:-}" \
    'select(.spec.approved == false and (.spec.clusterServiceVersionNames | length > 0 and all(startswith($p)) and ($v == "" or any(. == $v))))
      | "\(.metadata.namespace) \(.metadata.name)"' || true
}
approve_own() {   # approve_own <context> <package> <CSV name prefix> [csv]: approve own_plan, if one waits
  local ip
  ip=$(own_plan "$@")
  if [ -n "$ip" ]; then
    oc --context "$1" patch "$IPLAN" "${ip#* }" -n "${ip% *}" --type merge -p '{"spec":{"approved":true}}' >/dev/null &&
      logln "   $1: approved InstallPlan ${ip#* } (${4:-the first install of $2})"
  fi
}
approve_first() {   # approve_first <context> <namespace> <package> <CSV name prefix>: approve its first InstallPlan, never an upgrade
  if any_csv "$1" "$2" "$4"; then return 0; fi
  approve_own "$1" "$3" "$4"
}
acm_installed() {   # acm_installed <hub>: approve the pinned ACM InstallPlan until the CSV Succeeds
  approve_own "$1" advanced-cluster-management advanced-cluster-management "$ACM_CSV"
  csv_ok "$1" "${ACM_NS[$1]}" "$ACM_CSV"
}
mch_running() {   # mch_running <hub>: approve the engine's and OADP's first InstallPlans until the hub is Running
  approve_first "$1" multicluster-engine multicluster-engine multicluster-engine
  approve_first "$1" "$NS" redhat-oadp-operator oadp-operator
  [ "$(mch_phase "$1")" = Running ]
}
gitops_installed() {   # gitops_installed <context>: the operator Succeeded and its Argo CD instance is Available
  # a pinned install waits for approval by design; any other waits when a neighbour in openshift-operators is on Manual
  if [ -n "${GITOPS_PIN[$1]:-}" ]; then approve_own "$1" openshift-gitops-operator openshift-gitops-operator "${GITOPS_PIN[$1]}"
  else approve_first "$1" openshift-operators openshift-gitops-operator openshift-gitops-operator; fi
  any_csv "$1" openshift-operators openshift-gitops-operator && argocd_ready "$1"
}
held_plan() {   # held_plan <context> <package>: why its Subscription still waits, when a plan it cannot approve holds it
  local s ip
  s=$(sub_of "$1" "$2")
  ip=$(if [ -n "$s" ]; then sub_get "$1" "$s" '{.status.installPlanRef.name}'; fi)
  if [ -z "$ip" ]; then return 0; fi
  oc --context "$1" get "$IPLAN" "$ip" -n "${s% *}" -o json 2>/dev/null |
    jq -r 'select(.spec.approved == false) | "InstallPlan \(.metadata.name) in \(.metadata.namespace) waits for approval and installs \(.spec.clusterServiceVersionNames | join(", "))"' || true
}
manual_neighbours() {   # manual_neighbours <context> <namespace> <package>: the other Subscriptions there on Manual approval
  oc --context "$1" get "$SUB" -n "$2" -o json 2>/dev/null |
    jq -r --arg p "$3" '[.items[] | select(.spec.name != $p and .spec.installPlanApproval == "Manual") | .metadata.name] | join(", ")' || true
}
bsl_available() { [ "$(oc --context "$1" get backupstoragelocation -n "$NS" -o jsonpath='{.items[0].status.phase}' 2>/dev/null)" = Available ]; }
manual_approval() {   # manual_approval <context> "<namespace> <name>": mark the old approval for the teardown, then set Manual
  oc --context "$1" annotate "$SUB" "${2#* }" -n "${2% *}" "$A_APPROVAL=$(sub_get "$1" "$2" '{.spec.installPlanApproval}')" --overwrite &&
    oc --context "$1" patch "$SUB" "${2#* }" -n "${2% *}" --type merge -p '{"spec":{"installPlanApproval":"Manual"}}'
}
s3_secret() {   # s3_secret <context>: the secret with the S3 key; the key file exists only in this pipe
  printf '[default]\naws_access_key_id=%s\naws_secret_access_key=%s\n' "$S3_ACCESS_KEY" "$S3_SECRET_KEY" |
    oc --context "$1" create secret generic cloud-credentials -n "$NS" --from-file=cloud=/dev/stdin --dry-run=client -o json |
    jq --arg v "$PV" '.metadata.labels["app.kubernetes.io/part-of"] = $v' | oc --context "$1" apply -f -
}
import_secret() {   # import_secret: the auto-import secret, straight from the managed cluster's kubeconfig
  oc --context "$MANAGED" config view --flatten --minify |
    oc --context "$ACTIVE" create secret generic auto-import-secret -n "$MANAGED" --from-file=kubeconfig=/dev/stdin
}
apply_import() { oc --context "$ACTIVE" apply -f "$1"; }

# --- pre-flight ---------------------------------------------------------------------

STAGES=() STAGE=0 PRE=1   # PRE: the pre-flight's stage number
stage() {   # stage <title> <what and why>
  if [ "$STAGE" -gt "$PRE" ]; then go_on "$(stage_name $((STAGE + 1)) "$1")"; fi   # after the settings, its own; after the pre-flight, the build's confirm
  STAGE=$((STAGE + 1))
  logln "" "#### Stage $STAGE/${#STAGES[@]}: $1"
  if [ "$STAGE" -gt 1 ]; then pin_clear; else pin_draw; fi   # under the header, each stage starts on an empty window
  stage_head "$1"
  explain "$2"
}
stage_head() {   # stage_head <title>: the current stage's heading
  blank
  if [ "$UI" = gum ]; then
    printf ' %s── %s%s\n' "$C_B$C_ACC" "$(paint "$(stage_name "$STAGE" "$1")" "$C_B$C_ACC")" "$C_OFF"
  else
    printf '#### %s\n' "$(bare "$(stage_name "$STAGE" "$1")")"
  fi
  LAST=heading
}

declare -A ACM_NS ACM_HAS GITOPS_HAS GITOPS_PIN
ACM_CHANNEL=$(manifest_value manifests/10-acm-operator.yaml channel)
GITOPS_CHANNEL=$(manifest_value manifests/60-gitops-operator.yaml channel)
ACM_CSV="" PLAN_ROWS="" SPOKE_HAD=0 STORAGE_DONE=0
row() { PLAN_ROWS+="$1"$'\t'"$2"$'\t'"$3"$'\n'; }

co_unsettled() {   # co_unsettled < "oc get clusteroperators --no-headers": the operators not Available or Degraded, then (a line) those Progressing
  awk '$4 == "True" {r = r rs $1; rs = ", "}
    $3 != "True" {b = b bs $1 " not Available"; bs = ", "; next}
    $5 != "False" {b = b bs $1 " Degraded"; bs = ", "}
    END {print b; print r}'
}
preflight() {
  local c s v="" x t url origin rev
  BAD=0
  stage "Pre-flight (read-only)" "Checks that the three clusters are healthy, that your copy of the repo is what the clusters will pull from, and what is installed already. It decides what the build installs and what it reuses, and refuses what would break: a hub that another hub manages, $(cl "$MANAGED") managed by some other hub, or two hubs on different ACM versions. Nothing changes in this stage."

  sec_begin "Clusters"
  explain "All three must answer, with nodes Ready, no certificate requests waiting, and every cluster operator Available and not Degraded. A cluster that has just been installed or powered on takes 10 to 20 minutes to settle."
  help_at docs/build.md#clusters
  for c in "${CLUSTERS[@]}"; do
    if alive "$c"; then ok "$(cl "$c") API answers"; else red "$(cl "$c") API does not answer"; continue; fi
    expect "$(cl "$c") nodes Ready, no pending certificate requests" "$(cl "$c") has nodes not Ready or pending certificate requests (hack/dr.sh nodes $(cl "$c"))" settled "$c"
    t=$(oc --context "$c" get clusteroperators --no-headers 2>/dev/null || true)
    x=$(co_unsettled <<<"$t")
    if [ -z "${x%%$'\n'*}" ]; then
      ok "$(cl "$c") cluster operators Available, none Degraded"
    else
      logln "$(awk '$3 != "True" || $4 != "False" || $5 != "False"' <<<"$t")"
      if [ -n "${x#*$'\n'}" ]; then
        red "$(cl "$c") cluster operators not settled: ${x%%$'\n'*}. Rolling out: ${x#*$'\n'}; wait for them (10 to 20 minutes after a power-on), then run it again"
      else
        red "$(cl "$c") cluster operators not settled: ${x%%$'\n'*}"
      fi
    fi
  done
  sec_end "APIs answer, nodes Ready, cluster operators settled"
  if [ "$BAD" = 1 ]; then HELP=""; verdict bad "BUILD RED: the clusters must be up and settled first"; return 1; fi

  sec_begin "Your copy of the repo"
  explain "The demo apps and the dr-role applications pull from the repoURL and targetRevision in the manifests, so they must name your copy and the branch the settings file names. dr/ in git must give $(cl "$ACTIVE") the active role and $(cl "$PASSIVE") the passive one, as the settings file does: each hub's dr-role application applies exactly what git says."
  help_at README.md#getting-started
  git fetch -q origin "$BRANCH" 2>/dev/null || true
  if git rev-parse -q --verify "origin/$BRANCH" >/dev/null; then ok "origin/$BRANCH exists"; else red "no branch $BRANCH on origin (BRANCH in $DR_ENV)"; fi
  url=$(sed -n 's/^ *repoURL: *//p' manifests/62-appset-pull.yaml | head -n 1)
  origin=$(repo_url 2>/dev/null || true)
  if [ "${url%.git}" = "${origin%.git}" ]; then ok "the manifests pull from $url, your origin"; else red "the manifests pull from $url, but your origin is ${origin:-unset}"; fi
  for x in manifests/62-appset-pull.yaml manifests/63-appset-push.yaml dr/bootstrap/dr-role-hub-x.yaml dr/bootstrap/dr-role-hub-y.yaml; do
    rev=$(sed -n 's/^ *targetRevision: *//p' "$x" | head -n 1)
    if [ "$rev" = "$BRANCH" ]; then ok "$x tracks $BRANCH"; else red "$x tracks '$rev', not $BRANCH"; fi
  done
  help_at dr/README.md
  for c in "${HUBS[@]}"; do
    if [ ! -f "dr/bootstrap/dr-role-$c.yaml" ]; then red "no dr/bootstrap/dr-role-$c.yaml: the hubs' contexts must be named hub-x and hub-y"; fi
  done
  x=$(git_role "$ACTIVE")
  if [ "$x" = active ]; then ok "dr/$ACTIVE is active on origin/$BRANCH"
  elif [[ $x == "active with "* ]]; then
    help_at docs/build.md#7-git-driven-paths-only-bootstrap-dr
    red "dr/$ACTIVE still lists ${x#active with }, the last failover's activation one-shot: $(cl "$ACTIVE")'s new dr-role would apply it next to the BackupSchedule. hack/teardown.sh --reset resets dr/ on $BRANCH and keeps ACM and OpenShift GitOps; or remove the file and its entry there by hand"
    help_at dr/README.md
  else red "dr/$ACTIVE is $x on origin/$BRANCH, but the settings file makes $(cl "$ACTIVE") active (hack/teardown.sh --reset resets dr/)"; fi
  x=$(git_role "$PASSIVE")
  if [ "$x" = passive ]; then ok "dr/$PASSIVE is passive on origin/$BRANCH"; else red "dr/$PASSIVE is $x on origin/$BRANCH, but the settings file makes $(cl "$PASSIVE") passive (hack/teardown.sh --reset resets dr/)"; fi
  sec_end "tracks $BRANCH on your origin; dr/ has $(cl "$ACTIVE") active, $(cl "$PASSIVE") passive"

  sec_begin "What is installed"
  explain "An ACM or OpenShift GitOps that is already there is reused, not installed again. Both hubs must end up on the same ACM version (a backup does not restore on an older one), so the build pins both to one version with Manual approval: the installed one if a hub has ACM, otherwise the newest in channel $ACM_CHANNEL."
  help_at docs/build.md#1-hubs-acm-with-the-backup-component
  for c in "${HUBS[@]}"; do
    s=$(sub_of "$c" advanced-cluster-management)
    if [ -n "$s" ]; then
      ACM_NS[$c]=${s% *} ACM_HAS[$c]=$(sub_get "$c" "$s" '{.status.installedCSV}')
      if labeled "$c" "$SUB" "${s#* }" -n "${s% *}"; then
        ok "$(cl "$c"): ACM ${ACM_HAS[$c]#advanced-cluster-management.} (this build's, from an earlier attempt)"
        row "$(cl "$c")" ACM "continue: ${ACM_HAS[$c]#advanced-cluster-management.} (this build's)"
      else
        ok "$(cl "$c"): ACM ${ACM_HAS[$c]#advanced-cluster-management.} already installed: reused"
        row "$(cl "$c")" ACM "reuse ${ACM_HAS[$c]#advanced-cluster-management.}$(if [ "$(sub_get "$c" "$s" '{.spec.installPlanApproval}')" != Manual ]; then echo ", approval set to Manual"; fi)$(if ! backup_on "$c"; then echo ", cluster-backup turned on"; fi)"
        if [ "$(oc --context "$c" get operatorgroups.operators.coreos.com -n "${s% *}" -o name 2>/dev/null | wc -l)" -gt 1 ]; then
          red "$(cl "$c"): more than one OperatorGroup in ${s% *} (OLM fails every operator there: TooManyOperatorGroups)"
        fi
      fi
      if [ -z "${ACM_HAS[$c]}" ]; then red "$(cl "$c"): the ACM Subscription has no installed version yet; let it finish, or remove it"; fi
    else
      ACM_NS[$c]=$(manifest_value manifests/10-acm-operator.yaml namespace) ACM_HAS[$c]=""
      x=$(klusterlet_hub "$c")
      help_at docs/build.md#a-cluster-that-is-managed-by-another-hub
      if orphan_agent "$c"; then red "$(cl "$c") still runs the ACM agent of its own former hub (local-cluster), left by an uninstall: hack/teardown.sh --full removes it"
      elif [ -n "$x" ]; then red "$(cl "$c") is managed by the hub at $x: detach it from that hub first"
      else ok "$(cl "$c"): no ACM, not managed by another hub"; fi
      help_at docs/build.md#1-hubs-acm-with-the-backup-component
    fi
  done
  if [ -n "${ACM_HAS[$ACTIVE]}" ] && [ -n "${ACM_HAS[$PASSIVE]}" ] && [ "${ACM_HAS[$ACTIVE]}" != "${ACM_HAS[$PASSIVE]}" ]; then
    red "the hubs run different ACM versions (${ACM_HAS[$ACTIVE]} and ${ACM_HAS[$PASSIVE]}): upgrade the older one first"
  fi
  ACM_CSV=${ACM_HAS[$ACTIVE]:-${ACM_HAS[$PASSIVE]:-}}
  if [ -z "$ACM_CSV" ]; then ACM_CSV=$(channel_head "$ACTIVE" advanced-cluster-management "$ACM_CHANNEL"); fi
  for c in "${HUBS[@]}"; do
    if [ -n "${ACM_HAS[$c]}" ]; then continue; fi
    if [ -n "$ACM_CSV" ] && channel_has "$c" advanced-cluster-management "$ACM_CHANNEL" "$ACM_CSV"; then
      ok "$(cl "$c"): its catalog offers $ACM_CSV in $ACM_CHANNEL"
      row "$(cl "$c")" ACM "install ${ACM_CSV#advanced-cluster-management.} (Manual approval) and the MultiClusterHub"
    else
      red "$(cl "$c"): its catalog does not offer '${ACM_CSV:-any ACM}' in channel $ACM_CHANNEL"
    fi
  done

  help_at docs/build.md#2-all-clusters-openshift-gitops
  for c in "${CLUSTERS[@]}"; do
    s=$(sub_of "$c" openshift-gitops-operator)
    GITOPS_HAS[$c]=$(if [ -n "$s" ]; then sub_get "$c" "$s" '{.status.installedCSV}'; fi)
    if [ -n "$s" ] && labeled "$c" "$SUB" "${s#* }" -n "${s% *}"; then
      ok "$(cl "$c"): OpenShift GitOps ${GITOPS_HAS[$c]#openshift-gitops-operator.} (this build's, from an earlier attempt)"
      row "$(cl "$c")" "OpenShift GitOps" "continue: ${GITOPS_HAS[$c]#openshift-gitops-operator.} (this build's)"
    elif [ -n "$s" ]; then
      ok "$(cl "$c"): OpenShift GitOps ${GITOPS_HAS[$c]#openshift-gitops-operator.} already installed: reused"
      row "$(cl "$c")" "OpenShift GitOps" "reuse ${GITOPS_HAS[$c]#openshift-gitops-operator.}"
    fi
  done
  for c in "${HUBS[@]}"; do
    if [ -n "${GITOPS_HAS[$c]}" ]; then continue; fi
    for x in "${HUBS[@]}"; do
      if [ "$x" != "$c" ] && [ -n "${GITOPS_HAS[$x]}" ]; then GITOPS_PIN[$c]=${GITOPS_HAS[$x]}; fi
    done
    if [ -n "${GITOPS_PIN[$c]:-}" ]; then
      x=$(sub_get "$ACTIVE" "$(sub_of "$ACTIVE" openshift-gitops-operator)" '{.spec.channel}')
      if [ -z "$x" ]; then x=$(sub_get "$PASSIVE" "$(sub_of "$PASSIVE" openshift-gitops-operator)" '{.spec.channel}'); fi
      GITOPS_CHANNEL_PIN=${x:-$GITOPS_CHANNEL}
      if channel_has "$c" openshift-gitops-operator "$GITOPS_CHANNEL_PIN" "${GITOPS_PIN[$c]}"; then
        row "$(cl "$c")" "OpenShift GitOps" "install ${GITOPS_PIN[$c]#openshift-gitops-operator.} to match the other hub (Manual approval)"
      else
        red "$(cl "$c"): its catalog does not offer ${GITOPS_PIN[$c]} in channel $GITOPS_CHANNEL_PIN, the other hub's version"
      fi
    else
      row "$(cl "$c")" "OpenShift GitOps" "install from channel $GITOPS_CHANNEL"
    fi
  done
  if [ -z "${GITOPS_HAS[$MANAGED]}" ]; then row "$(cl "$MANAGED")" "OpenShift GitOps" "install from channel $GITOPS_CHANNEL"; fi
  for c in "${CLUSTERS[@]}"; do
    x=$(if [ -z "${GITOPS_HAS[$c]}" ]; then manual_neighbours "$c" openshift-operators openshift-gitops-operator; fi)
    if [ -n "$x" ]; then
      note "$(cl "$c"): $x in openshift-operators is on Manual approval, so OLM holds OpenShift GitOps' InstallPlan there too; the build approves it if it installs OpenShift GitOps alone"
    fi
  done
  if [ -n "${GITOPS_HAS[$ACTIVE]}" ] && [ -n "${GITOPS_HAS[$PASSIVE]}" ] && [ "${GITOPS_HAS[$ACTIVE]}" != "${GITOPS_HAS[$PASSIVE]}" ]; then
    note "the hubs run different OpenShift GitOps versions (${GITOPS_HAS[$ACTIVE]} and ${GITOPS_HAS[$PASSIVE]}); the restore hub should carry the same operators"
  fi
  sec_end "nothing in the way; the plan below lists what is reused"

  sec_begin "$(cl "$MANAGED")"
  explain "$(cl "$MANAGED") must be managed by $(cl "$ACTIVE") or by no hub at all, and the passive hub must not list it: one cluster, one hub."
  help_at docs/build.md#4-active-hub-import-the-spoke
  x=$(klusterlet_hub "$MANAGED")
  if [ -z "$x" ]; then
    ok "$(cl "$MANAGED") is not managed by any hub yet"
    v="not managed by any hub yet"
    row "$(cl "$MANAGED")" "ACM import" "import into $(cl "$ACTIVE")"
  elif orphan_agent "$MANAGED"; then
    help_at docs/build.md#a-cluster-that-is-managed-by-another-hub
    red "$(cl "$MANAGED") still runs the ACM agent of its own former hub (local-cluster), left by an uninstall: hack/teardown.sh --full removes it"
  elif [ -n "${ACM_HAS[$ACTIVE]}" ] && mc_available "$ACTIVE" True; then
    SPOKE_HAD=1
    ok "$(cl "$MANAGED") is already managed by $(cl "$ACTIVE"): kept"
    v="already managed by $ACTIVE: kept"
    row "$(cl "$MANAGED")" "ACM import" "already managed by $(cl "$ACTIVE"): kept"
  else
    help_at docs/build.md#a-cluster-that-is-managed-by-another-hub
    red "$(cl "$MANAGED") is managed by the hub at $x, not by $(cl "$ACTIVE"): detach it there first"
  fi
  if [ -n "${ACM_HAS[$PASSIVE]}" ] && some "$PASSIVE" managedcluster "$MANAGED"; then
    red "$(cl "$PASSIVE") also lists $(cl "$MANAGED"): two hubs would claim it"
  fi
  help_at docs/build.md#shared-clusters
  for c in "${HUBS[@]}"; do
    if [ -z "${ACM_HAS[$c]}" ]; then continue; fi
    x=$(oc --context "$c" get managedclusters -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' |
      grep -vx -e local-cluster -e "$MANAGED" | paste -sd' ' - || true)
    if [ -n "$x" ]; then red "$(cl "$c") also manages $x: manifests/61 binds the default cluster set, so Argo CD would register them too"; fi
  done
  help_at docs/build.md#build-time-gotchas
  for c in "${CLUSTERS[@]}"; do
    if some "$c" crd routes.route.openshift.io; then red "$(cl "$c") has a stray routes.route.openshift.io CRD (gotcha 3)"; fi
  done
  sec_end "$v; no other hub claims it"

  sec_begin "Backup storage"
  explain "Both hubs write to and read from one S3 bucket. The endpoint and bucket come from the settings file; the keys are asked for when the build starts."
  help_at docs/build.md#3-hubs-backup-storage
  if [ -n "${ACM_HAS[$ACTIVE]}" ] && [ -n "${ACM_HAS[$PASSIVE]}" ] &&
    [ "$(oc --context "$ACTIVE" get backupstoragelocation -n "$NS" -o jsonpath='{.items[0].status.phase}' 2>/dev/null)" = Available ] &&
    [ "$(oc --context "$PASSIVE" get backupstoragelocation -n "$NS" -o jsonpath='{.items[0].status.phase}' 2>/dev/null)" = Available ]; then
    STORAGE_DONE=1
    ok "both hubs already reach the bucket: kept"
    v="both hubs already reach the bucket: kept"
    row "$(cl "$ACTIVE"), $(cl "$PASSIVE")" "backup storage" "already connected: kept"
  elif [ -n "$S3_URL" ] && ! url_ok "$S3_URL"; then
    red "S3_URL in $DR_ENV is '$S3_URL', not an http(s) URL: fix the line, or delete it to be asked again"
  else
    ok "bucket s3://$S3_BUCKET/$S3_PREFIX in $S3_REGION at ${S3_URL:-(asked for at the start)}"
    v="s3://$S3_BUCKET/$S3_PREFIX at ${S3_URL:-AWS S3}"
    row "$(cl "$ACTIVE"), $(cl "$PASSIVE")" "backup storage" "connect to s3://$S3_BUCKET/$S3_PREFIX"
  fi
  row "$(cl "$ACTIVE")" "demo apps, backups" "pull and push apps on $(cl "$MANAGED"), BackupSchedule"
  row "$(cl "$PASSIVE")" "backups" "continuous passive restore"
  row "$(cl "$ACTIVE"), $(cl "$PASSIVE")" "dr/ roles" "each hub's dr-role application adopts its role"
  sec_end "$v"

  HELP=""
  say "The plan"
  printf 'Cluster\tWhat\tPlan\n%s' "$PLAN_ROWS" | table
  if [ "$BAD" = 1 ]; then
    verdict bad "BUILD RED: nothing was installed; fix the RED lines (each links to the section that explains it) and run it again"
    return 1
  fi
  verdict ok "PRE-FLIGHT GREEN: $(cl "$ACTIVE") active, $(cl "$PASSIVE") passive, ACM ${ACM_CSV#advanced-cluster-management.}"
}

expect() {   # expect <ok text> <red text> <command...>: one pre-flight line
  local good=$1 bad=$2; shift 2
  if "$@" >/dev/null 2>&1; then ok "$good"; else red "$bad"; fi
}

# --- S3 ------------------------------------------------------------------------------

S3_ACCESS_KEY=${S3_ACCESS_KEY:-} S3_SECRET_KEY=${S3_SECRET_KEY:-}
s3_inputs() {
  if [ "$STORAGE_DONE" = 1 ]; then return 0; fi
  say "S3 access"
  explain "The keys go into a secret on each hub and nowhere else: not into a file, not into the log."
  if [ -z "$S3_URL" ] && ! grep -q '^S3_URL=' "$DR_ENV"; then
    ask "S3 endpoint URL (e.g. https://s3.example.com; empty for AWS S3)" 0; S3_URL=$ANSWER
    S3_URL=${S3_URL%/}
    if [ -n "$S3_URL" ] && ! url_ok "$S3_URL"; then die "'$S3_URL' is not an http(s) URL: run it again and enter the endpoint only"; fi
    set_setting S3_URL "$S3_URL"
    finished "S3_URL=${S3_URL:-(AWS S3)} saved in $DR_ENV"
  fi
  if [ -z "$S3_ACCESS_KEY" ]; then
    ask "S3 access key" 0; S3_ACCESS_KEY=$ANSWER
    finished "S3 access key: ${#S3_ACCESS_KEY} characters, ending in ${S3_ACCESS_KEY: -4}"
  fi
  if [ -z "$S3_SECRET_KEY" ]; then
    ask "S3 secret key" 1; S3_SECRET_KEY=$ANSWER ANSWER=""
    finished "S3 secret key: ${#S3_SECRET_KEY} characters"
  fi
  if [ -z "$S3_ACCESS_KEY" ] || [ -z "$S3_SECRET_KEY" ]; then die "the S3 keys are empty"; fi
  if [ -z "$S3_URL" ]; then
    note "AWS S3: the bucket check is left to the BackupStorageLocation"
  elif [ "$(curl --version | awk 'NR == 1 {split($2, v, "."); print v[1]}')" -lt 8 ]; then
    note "curl $(curl --version | awk 'NR == 1 {print $2}') cannot sign S3 requests correctly (build.md); the BackupStorageLocation checks the bucket instead"
  else
    local code
    # the keys reach curl on stdin, so they never show in the process list
    code=$(printf 'user = "%s:%s"\n' "$S3_ACCESS_KEY" "$S3_SECRET_KEY" |
      curl -sS -K - -o /dev/null -w '%{http_code}' ${S3_CA_FILE:+--cacert "$S3_CA_FILE"} \
        --aws-sigv4 "aws:amz:$S3_REGION:s3" "$S3_URL/$S3_BUCKET?list-type=2" 2>&1 || true)
    help_at docs/build.md#3-hubs-backup-storage
    if [ "$code" = 200 ]; then ok "the keys list s3://$S3_BUCKET (HTTP 200)"; else red "listing s3://$S3_BUCKET returned '$code', not 200"; die "the S3 endpoint, bucket or keys do not work"; fi
    HELP=""
  fi
}

# --- stages --------------------------------------------------------------------------

stage_acm() {
  local c s mch x t0
  stage ACM "Installs ACM where it is missing, pinned to ${ACM_CSV#advanced-cluster-management.} with Manual approval, so neither hub upgrades alone: a backup does not restore on a hub that runs an older ACM. Then the MultiClusterHub with the cluster-backup component, which brings the multicluster engine and OADP (Velero). On an ACM that was already there, it turns cluster-backup on in place and sets Manual approval, and marks both changes so hack/teardown.sh can undo them. This takes 10 to 20 minutes per hub; the hubs install side by side."
  pinned manifests/10-acm-operator.yaml "$ACM_CHANNEL" "$ACM_CSV" "$TMP/10-acm-operator.yaml"
  for c in "${HUBS[@]}"; do
    say "$(cl "$c")"
    s=$(sub_of "$c" advanced-cluster-management)
    if [ -z "$s" ]; then
      apply "$c" "$TMP/10-acm-operator.yaml" "manifests/10-acm-operator.yaml pinned to $ACM_CSV"
    elif ! labeled "$c" "$SUB" "${s#* }" -n "${s% *}" && [ "$(sub_get "$c" "$s" '{.spec.installPlanApproval}')" != Manual ]; then
      act "$(cl "$c"): set the existing ACM subscription to Manual approval (and mark it, so the teardown can set it back)" manual_approval "$c" "$s"
    fi
  done
  for c in "${HUBS[@]}"; do
    wait_until 1800 "$(cl "$c"): $ACM_CSV to install" acm_installed "$c"
    mch=$(mch_ref "$c")
    if [ -z "$mch" ]; then
      apply "$c" manifests/20-multiclusterhub.yaml
    elif ! backup_on "$c"; then
      x=$(oc --context "$c" get "$MCH" "${mch#* }" -n "${mch% *}" -o json | jq -c --arg a "$A_BACKUP" '{metadata: {annotations: {($a): "enabled-by-build"}},
        spec: {overrides: {components: ((.spec.overrides.components // [] | map(select(.name != "cluster-backup"))) + [{name: "cluster-backup", enabled: true}])}}}')
      act "$(cl "$c"): turn cluster-backup on in the existing MultiClusterHub (keeping every other component)" \
        oc --context "$c" patch "$MCH" "${mch#* }" -n "${mch% *}" --type merge -p "$x"
    fi
  done
  for c in "${HUBS[@]}"; do
    t0=$SECONDS
    wait_until 2700 "$(cl "$c"): the MultiClusterHub to reach Running (approving the engine's and OADP's first InstallPlans)" mch_running "$c"
    wait_until 600 "$(cl "$c"): the backup operator's namespace" some "$c" ns "$NS"
    if none "$c" ns open-cluster-management-global-set; then
      act "$(cl "$c"): create namespace open-cluster-management-global-set (gotcha 1: without it no add-on reaches any cluster)" \
        oc --context "$c" create ns open-cluster-management-global-set
    fi
    finished "$(cl "$c"): ACM $(oc --context "$c" get "$SUB" -A -o json | jq -r 'first(.items[] | select(.spec.name == "advanced-cluster-management")) | .status.installedCSV') Running ($(dur $((SECONDS - t0))) after the install)"
  done
}

stage_gitops() {
  local c x
  stage "OpenShift GitOps" "Installs the OpenShift GitOps operator where it is missing: on both hubs, whose Argo CD instances deliver the push app and apply each hub's DR role, and on $(cl "$MANAGED"), whose own Argo CD syncs the pull app straight from git. A hub that gets it next to a hub that already runs it is pinned to the same version. Each install ends when the default Argo CD instance in openshift-gitops is Available."
  for c in "${CLUSTERS[@]}"; do
    if [ -n "${GITOPS_HAS[$c]}" ]; then continue; fi
    if [ -n "${GITOPS_PIN[$c]:-}" ]; then
      pinned manifests/60-gitops-operator.yaml "$GITOPS_CHANNEL_PIN" "${GITOPS_PIN[$c]}" "$TMP/60-gitops-operator-$c.yaml"
      apply "$c" "$TMP/60-gitops-operator-$c.yaml" "manifests/60-gitops-operator.yaml pinned to ${GITOPS_PIN[$c]}"
    else
      apply "$c" manifests/60-gitops-operator.yaml
    fi
  done
  for c in "${CLUSTERS[@]}"; do
    if ! try_until 1500 "$(cl "$c"): OpenShift GitOps and its Argo CD instance" gitops_installed "$c"; then
      x=$(held_plan "$c" openshift-gitops-operator)
      help_at docs/build.md#2-all-clusters-openshift-gitops
      if [ -n "$x" ]; then red "$(cl "$c"): $x. The build approves only a plan that installs OpenShift GitOps alone: approve this one yourself if those changes are wanted, then run it again"; fi
      die "$(cl "$c"): OpenShift GitOps is not installed after 25 min"
    fi
  done
}

stage_storage() {
  local c dpa
  stage "Backup storage" "Gives both hubs the same S3 bucket: a secret with the key, and a DataProtectionApplication that points Velero at s3://$S3_BUCKET/$S3_PREFIX. The stage ends when each hub's BackupStorageLocation is Available, which proves the endpoint, the bucket and the key from inside the cluster."
  if [ "$STORAGE_DONE" = 1 ]; then finished "both hubs already reach the bucket"; return 0; fi
  dpa=$TMP/50-dpa.yaml
  sed -e "s#^          bucket: acm-backups\$#          bucket: $S3_BUCKET#" -e "s#^          prefix: acm\$#          prefix: $S3_PREFIX#" \
    -e "s#^          region: us-east-1\$#          region: $S3_REGION#" manifests/50-dpa.yaml >"$dpa"
  if [ -n "$S3_URL" ]; then
    sed -i "s#^          s3Url: https://s3.example.com\$#          s3Url: $S3_URL#" "$dpa"
  else
    sed -i '/^          s3Url: /d; /^          s3ForcePathStyle: /d' "$dpa"
  fi
  if [ -n "$S3_CA_FILE" ]; then
    sed -i "s#^          prefix: \(.*\)\$#          prefix: \1\n          caCert: $(base64 -w0 <"$S3_CA_FILE")#" "$dpa"
  fi
  for c in "${HUBS[@]}"; do
    say "$(cl "$c")"
    act "$(cl "$c"): create or update secret cloud-credentials (the S3 key)" s3_secret "$c"
    apply "$c" "$dpa" "manifests/50-dpa.yaml for s3://$S3_BUCKET/$S3_PREFIX"
  done
  for c in "${HUBS[@]}"; do
    wait_until 600 "$(cl "$c"): its BackupStorageLocation to be Available" bsl_available "$c"
  done
}

stage_import() {
  stage "Import $(cl "$MANAGED")" "Makes $(cl "$MANAGED") a managed cluster of $(cl "$ACTIVE"): the ManagedCluster and its add-ons from manifests/40-import-spoke.yaml, and an auto-import secret holding $(cl "$MANAGED")'s kubeconfig, which the hub uses once to install its agent and then deletes. It ends when $(cl "$MANAGED") is Joined and Available and its add-ons (among them the managed service account and the cluster proxy) are Available."
  if [ "$SPOKE_HAD" = 1 ]; then
    if labeled "$ACTIVE" managedcluster "$MANAGED"; then
      apply "$ACTIVE" manifests/40-import-spoke.yaml
    else
      # managed before the build: it gets the clusterset, the name label and the add-ons, but not this repo's label
      sed '/app.kubernetes.io\/part-of: acm-gitops-failover/d' manifests/40-import-spoke.yaml >"$TMP/40-import-spoke.yaml"
      apply "$ACTIVE" "$TMP/40-import-spoke.yaml" "manifests/40-import-spoke.yaml (without this repo's label: $MANAGED was managed before)"
    fi
    if [ -n "$(oc --context "$ACTIVE" get secret auto-import-secret -n "$MANAGED" --ignore-not-found \
      -o jsonpath='{.metadata.annotations.managedcluster-import-controller\.open-cluster-management\.io/keeping-auto-import-secret}' 2>/dev/null)" ]; then
      act "$(cl "$ACTIVE"): delete the kept auto-import-secret (the backups' managed service account token is the import credential)" \
        oc --context "$ACTIVE" delete secret auto-import-secret -n "$MANAGED"
    fi
  else
    # the KlusterletAddonConfig needs the namespace the ManagedCluster creates: apply again until it lands
    wait_until 180 "$(cl "$ACTIVE"): manifests/40-import-spoke.yaml to apply (the ManagedCluster first, then its add-on config)" \
      apply_import manifests/40-import-spoke.yaml
    if none "$ACTIVE" secret auto-import-secret -n "$MANAGED" && ! mc_joined "$ACTIVE"; then
      act "$(cl "$ACTIVE"): create auto-import-secret from $(cl "$MANAGED")'s kubeconfig" import_secret
    fi
  fi
  wait_until 1200 "$(cl "$MANAGED") to be Joined and Available on $(cl "$ACTIVE")" mc_joined "$ACTIVE"
  wait_until 900 "$(cl "$MANAGED")'s add-ons to be Available" addons_available "$ACTIVE"
  oc --context "$ACTIVE" get managedclusteraddon -n "$MANAGED" 2>&1 | to_log
}

stage_demo() {
  local c a url push
  stage "Demo apps" "Registers $(cl "$MANAGED") with $(cl "$ACTIVE")'s Argo CD (GitOpsCluster and placements) and creates the two ApplicationSets: the pull app, which ACM hands to $(cl "$MANAGED")'s own Argo CD, and the push app, which $(cl "$ACTIVE")'s Argo CD syncs through the cluster proxy. These objects come before the backups start, so the first backup set already carries them to $(cl "$PASSIVE"). It ends when both apps are synced and healthy and answer on their routes; their URLs go into the settings file for hack/dr.sh."
  apply "$ACTIVE" manifests/61-gitops-integration.yaml
  apply "$ACTIVE" manifests/62-appset-pull.yaml
  apply "$ACTIVE" manifests/63-appset-push.yaml
  for a in "$MANAGED/hello-failover-$MANAGED" "$ACTIVE/hello-failover-push-$MANAGED"; do
    c=${a%%/*}
    wait_until 900 "${a#*/} to sync and be healthy on $(cl "$c")" app_done "$c" "${a#*/}"
  done
  url=https://$(oc --context "$MANAGED" get routes.route.openshift.io -n hello-failover -o jsonpath='{.items[0].spec.host}')
  push=https://$(oc --context "$MANAGED" get routes.route.openshift.io -n hello-failover-push -o jsonpath='{.items[0].spec.host}')
  wait_until 300 "the pull app to answer at $url" http_ok "$url"
  wait_until 300 "the push app to answer at $push" http_ok "$push"
  if [ "${APP_URL:-}" != "$url" ] || [ "${PUSH_APP_URL:-}" != "$push" ]; then
    set_setting APP_URL "$url"
    set_setting PUSH_APP_URL "$push"
    finished "APP_URL and PUSH_APP_URL saved in $DR_ENV"
  fi
}

stage_backups() {
  local t
  stage "Backup roles" "Makes $(cl "$ACTIVE") the active hub: its BackupSchedule writes a backup set to the bucket every 30 minutes, the first one right away, and keeps a managed service account token for $(cl "$MANAGED") in it, which is what lets the other hub re-import $(cl "$MANAGED"). Once the first set has completed, $(cl "$PASSIVE") starts its continuous passive restore, so it always holds the newest set and is ready to take over."
  if none "$ACTIVE" "$BSCHED" -n "$NS"; then apply "$ACTIVE" manifests/55-backupschedule.yaml; fi
  # the cluster's clock, not this workstation's, decides which backups are new
  t=$(oc --context "$ACTIVE" get "$BSCHED" schedule-acm -n "$NS" -o jsonpath='{.metadata.creationTimestamp}')
  wait_until 1800 "the first backup set on $(cl "$ACTIVE") to complete" backup_set_after "$ACTIVE" "$t"
  wait_until 300 "$(cl "$ACTIVE")'s BackupSchedule to be Enabled" schedule_enabled "$ACTIVE"
  wait_until 600 "the managed service account token for $(cl "$MANAGED")" msa_fresh "$ACTIVE"
  if none "$PASSIVE" "$RESTORE" restore-acm-passive-sync -n "$NS"; then apply "$PASSIVE" manifests/56-restore-passive.yaml; fi
  wait_until 900 "$(cl "$PASSIVE")'s passive restore to be Enabled" restore_enabled "$PASSIVE" restore-acm-passive-sync
}

stage_roles() {
  local c before after obj
  stage "dr/ roles" "Hands each hub's role to git (Automated Pull Path, Phase P): the RBAC that lets each hub's Argo CD manage its BackupSchedule and Restores, then each hub's dr-role application, which reconciles dr/<hub> from $BRANCH. It adopts the BackupSchedule and the passive restore the last stage created rather than re-creating them. From here on the git-driven runs change roles through pull requests; the manual runs pause dr-role first (D.0)."
  for c in "${HUBS[@]}"; do
    say "$(cl "$c")"
    apply "$c" dr/bootstrap/dr-role-rbac.yaml
    BAD=0
    help_at docs/runbooks/dr-failover-pull-gitops/README.md#p0-rbac-first--the-grant-that-makes-git-driven-dr-possible
    expect "$(cl "$c"): the Argo CD controller may manage backup schedules (P.0)" "$(cl "$c"): the Argo CD controller may not patch backupschedules (P.0)" \
      oc --context "$c" auth can-i patch "$BSCHED" -n "$NS" --as=system:serviceaccount:openshift-gitops:openshift-gitops-argocd-application-controller
    HELP=""
    if [ "$BAD" = 1 ]; then die "the dr-role RBAC does not take effect on $(cl "$c")"; fi
    if [ "$c" = "$ACTIVE" ]; then obj="$BSCHED schedule-acm"; else obj="$RESTORE restore-acm-passive-sync"; fi
    # shellcheck disable=SC2086 # obj is a kind and a name
    before=$(oc --context "$c" get $obj -n "$NS" -o jsonpath='{.metadata.creationTimestamp}')
    apply "$c" "dr/bootstrap/dr-role-$c.yaml"
    wait_until 600 "dr-role on $(cl "$c") to sync" app_done "$c" dr-role
    # shellcheck disable=SC2086
    after=$(oc --context "$c" get $obj -n "$NS" -o jsonpath='{.metadata.creationTimestamp}')
    if [ "$before" = "$after" ]; then ok "$(cl "$c"): dr-role adopted ${obj#* } (created $before)"; else note "$(cl "$c"): dr-role re-created ${obj#* } instead of adopting it"; fi
  done
}

stage_check() {
  stage Check "Runs hack/dr.sh check, the pre-flight every exercise starts with, against what was just built."
  if DR_CLEAR=0 bash "$REPO/hack/dr.sh" check; then
    steps_end
    box rounded 10 "Build done in $(dur $((SECONDS - T0))): $(cl "$ACTIVE") active, $(cl "$PASSIVE") passive" \
      "Next: hack/dr.sh, then pick a run from the menu (docs/runbooks)." "Log: $LOGFILE"
  else
    die "the build finished, but hack/dr.sh check is RED: fix what it names, then run hack/dr.sh check again"
  fi
}

usage() { sed -n '2,/^set -euo/{/^set -euo/d;s/^# \{0,1\}//;p}' "$SELF"; }
menu() {
  local choice items
  intro "Build the ACM hub DR exercise" \
    "Sets up two ACM hubs, one active and one passive, and a workload cluster they take turns managing. It installs ACM and OpenShift GitOps where they are missing, connects both hubs to the S3 bucket for backups, imports the workload cluster, deploys the two demo apps and hands each hub's role to git." \
    "" \
    "It takes 40 to 60 minutes and asks for the S3 keys at the start."
  items=(Check Build Quit)
  echo
  if [ "$UI" = gum ]; then
    choice=$(gum choose --header "What would you like to do?" "${items[@]}" </dev/tty 2>/dev/tty) || choice=Quit
  else
    PS3="What would you like to do? "
    select choice in "${items[@]}"; do if [ -n "$choice" ]; then break; fi; done </dev/tty
  fi
  case $choice in
    Check) menu_run --check ;;
    Build) menu_run ;;
    *) exit 0 ;;
  esac
}

ERR_AT=""
on_err() {
  local f where=""
  for f in "${FUNCNAME[@]:1}"; do if [ "$f" != main ]; then where+="${where:+ < }$f"; fi; done
  ERR_AT="in ${where:-main}"
  if [[ $1 != return* ]]; then ERR_AT+=": $1"; fi
}
on_exit() {
  local rc=$?
  rm -rf "$TMP"
  if [ -n "$POLL_PID" ]; then kill "$POLL_PID" 2>/dev/null || true; fi
  spin_stop
  pin_off
  if [ "$rc" = 0 ] || [ "$DIED" = 1 ]; then return 0; fi
  if [ "$rc" = 130 ]; then
    box thick 9 "STOP" "interrupted: run it again to carry on; every stage skips what is already in place" ${LOGFILE:+"" "Log: $LOGFILE"}
  else
    box thick 9 "STOP" "hack/build.sh stopped on a failed command ${ERR_AT:-} (exit $rc). Its output, if any, is above." ${LOGFILE:+"" "Log: $LOGFILE"}
  fi
}

trap on_exit EXIT
start_screen
if [ "$ARGC" = 0 ] && [ "${DR_MENU:-0}" = 0 ]; then   # a menu pick runs as its own hack/build.sh
  if [ -t 0 ] && [ -t 1 ]; then menu; else usage; DIED=1; exit 2; fi
fi
TMP=$(mktemp -d)
ASK=0   # on a terminal, the settings are the first stage
if [ "$YES" = 0 ] && [ -t 0 ] && [ -t 1 ]; then ASK=1; fi
if [ ! -f "$DR_ENV" ] && [ "$ASK" = 0 ]; then
  die "no settings file at $DR_ENV: run hack/build.sh on a terminal, without --yes, and it asks for them (docs/build.md)"
fi
mkdir -p "$HOME/acm-dr/logs"
LOGFILE=$HOME/acm-dr/logs/build$(if [ "$CHECK" = 1 ]; then echo -check; fi)-$(date -u +%Y%m%dT%H%M%SZ).log
# shellcheck disable=SC2094 # both append
exec 3>>"$LOGFILE" 2> >(tee -a "$LOGFILE" >&2)
logln "#### $(now) hack/build.sh$(if [ "$CHECK" = 1 ]; then echo " --check"; fi)"
trap 'exit 130' INT TERM
set -E
trap 'on_err "$BASH_COMMAND"' ERR
T0=$SECONDS
# --check runs only the pre-flight: its plan says what the other stages would do
if [ "$CHECK" = 1 ]; then STAGES=(Pre-flight); else STAGES=(Pre-flight ACM "OpenShift GitOps" "Backup storage" "Import ${MANAGED:-spoke}" "Demo apps" "Backup roles" "dr/ roles" Check); fi
if [ "$ASK" = 1 ]; then STAGES=(Settings "${STAGES[@]}") PRE=2; fi
if [ -f "$DR_ENV" ]; then settings_title; else STEPS_TITLE="Build$(if [ "$CHECK" = 1 ]; then echo " check"; fi) · new settings"; fi
steps_pin   # the stages stay at the top, and the output stays in the window under them

if [ "$ASK" = 1 ]; then stage_settings; fi
for c in "${CLUSTERS[@]}"; do
  grep -qx -- "$c" <<<"$(oc config get-contexts -o name)" || die "no kubeconfig context named '$c' (KUBECONFIG=${KUBECONFIG:-default})"
done
if [ "$ACTIVE" = "$PASSIVE" ] || [ "$ACTIVE" = "$MANAGED" ] || [ "$PASSIVE" = "$MANAGED" ]; then
  die "ACTIVE, PASSIVE and MANAGED must be three different contexts ($DR_ENV)"
fi

if ! preflight; then DIED=1; exit 1; fi
if [ "$CHECK" = 1 ]; then
  steps_end
  finished "pre-flight only: nothing changed on the clusters. Log: ${LOGFILE/#$HOME/\~}"
  exit 0
fi
confirm "Build it: install and configure what the plan lists on $(cl "$ACTIVE"), $(cl "$PASSIVE") and $(cl "$MANAGED")?"
s3_inputs
stage_acm
stage_gitops
stage_storage
S3_ACCESS_KEY="" S3_SECRET_KEY=""
stage_import
stage_demo
stage_backups
stage_roles
stage_check
