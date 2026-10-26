#!/usr/bin/env bash
# Teardown: removes the DR exercise from the three clusters, the reverse of
# docs/build.md and hack/build.sh. docs/build.md ("Tearing it down") explains
# each stage, and what stays.
#
# Usage: hack/teardown.sh [--dry-run] [--reset | --full] [--yes]
#
# With no options, on a terminal, it shows a menu: a check (dry run) or a
# teardown, with --reset or --full. Each pick comes back to the menu when it
# ends; only Quit (or Ctrl-C) leaves.
#
#   (default)  remove what this repo put on the clusters: everything that
#              carries the label app.kubernetes.io/part-of=acm-gitops-failover
#              (every manifest in manifests/ and dr/ does), including ACM and
#              OpenShift GitOps when the build installed them, and undo the two
#              changes the build makes to an ACM that was there before it
#   --reset     reset the exercise, not the platform: remove the DR roles and
#              the demo apps, and reset dr/ in git, but keep ACM, OpenShift
#              GitOps, the backup storage and the workload cluster's import,
#              so the next hack/build.sh reuses them and takes minutes
#   --full     remove ACM, OpenShift GitOps and the demo whoever installed
#              them, and detach the workload cluster: afterwards none of the
#              three clusters runs ACM or OpenShift GitOps
#   --dry-run  read-only: what would be removed and what stays
#   --yes      do not ask before removing
#
# Other operators and workloads stay. So do the S3 bucket and its backups,
# and the settings file. In git, it resets dr/ on BRANCH to the roles the
# build starts from (ACTIVE active, PASSIVE passive, no activation one-shot),
# and deletes the branches hack/dr.sh pushed once BRANCH has merged them.
# It refuses (and says why) when removing ACM or
# OpenShift GitOps would take something else with it: another managed
# cluster, or Argo CD applications this repo did not create.
# Settings: $DR_ENV (default ~/acm-dr/dr.env; see hack/dr.env.example).
# Log: ~/acm-dr/logs/teardown-<time>.log
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SELF=$REPO/hack/teardown.sh
DR_ENV=${DR_ENV:-$HOME/acm-dr/dr.env}
[ -f "$DR_ENV" ] || { echo "no settings file at $DR_ENV: run hack/build.sh: its first stage writes it (docs/build.md)" >&2; exit 2; }
# shellcheck source=/dev/null
. "$DR_ENV"
: "${ACTIVE:?set ACTIVE in $DR_ENV}" "${PASSIVE:?set PASSIVE in $DR_ENV}"
MANAGED=${MANAGED:-spoke}
BRANCH=${BRANCH:-main}
if [ -n "${KUBECONFIG:-}" ]; then export KUBECONFIG; fi
cd "$REPO"

DRY=0 FULL=0 RESET=0 YES=0 ARGC=$#
for a in "$@"; do
  case $a in
    --dry-run) DRY=1 ;;
    --full) FULL=1 ;;
    --reset) RESET=1 ;;
    --yes) YES=1 ;;
    *) sed -n '2,/^set -euo/{/^set -euo/d;s/^# \{0,1\}//;p}' "$SELF"; exit 2 ;;
  esac
done

# shellcheck source=hack/lib/common.sh
. "$REPO/hack/lib/common.sh"

PV=acm-gitops-failover
SUB=subscriptions.operators.coreos.com
CSV=clusterserviceversions.operators.coreos.com
APPSET=applicationsets.argoproj.io
HUBS=("$ACTIVE" "$PASSIVE")
CLUSTERS=("$ACTIVE" "$PASSIVE" "$MANAGED")
# the build's marks on an ACM that was there before it (docs/build.md, "A hub that already runs ACM")
A_BACKUP=acm-gitops-failover/cluster-backup
A_APPROVAL=acm-gitops-failover/install-plan-approval

# --- what is there, and whose ----------------------------------------------------

labeled() {   # labeled <context> <oc get args...>: carries this repo's part-of label
  [ "$(oc --context "$1" get "${@:2}" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/part-of}' 2>/dev/null)" = "$PV" ]
}
mine() {   # mine <context> <oc get args...>: there, and this teardown's to remove (with --full, anything there)
  some "$@" && { [ "$FULL" = 1 ] || labeled "$@"; }
}
sub_of() {   # sub_of <context> <package>: "<namespace> <name>" of the Subscription that installs it
  oc --context "$1" get "$SUB" -A -o json 2>/dev/null |
    jq -r --arg p "$2" 'first(.items[] | select(.spec.name == $p) | "\(.metadata.namespace) \(.metadata.name)") // empty'
}
sub_get() {   # sub_get <context> "<namespace> <name>" <jsonpath>
  oc --context "$1" get "$SUB" "${2#* }" -n "${2% *}" -o jsonpath="$3" 2>/dev/null || true
}
operator_plan() {   # operator_plan <context> <package>: remove, keep, or none (not installed)
  local s
  s=$(sub_of "$1" "$2")
  if [ -z "$s" ]; then echo none
  elif [ "$RESET" = 1 ]; then echo keep
  elif [ "$FULL" = 1 ] || [ "$(sub_get "$1" "$s" '{.metadata.labels.app\.kubernetes\.io/part-of}')" = "$PV" ]; then echo remove
  else echo keep; fi
}
kept_why() { if [ "$RESET" = 1 ]; then echo "--reset keeps it"; else echo "there before the build"; fi; }
mode_flag() { if [ "$FULL" = 1 ]; then echo " --full"; elif [ "$RESET" = 1 ]; then echo " --reset"; fi; }
mch_of() {   # mch_of <context>: "<namespace> <name>" of the MultiClusterHub
  oc --context "$1" get multiclusterhubs.operator.open-cluster-management.io -A -o json 2>/dev/null |
    jq -r 'first(.items[] | "\(.metadata.namespace) \(.metadata.name)") // empty'
}
mch_get() { oc --context "$1" get multiclusterhubs.operator.open-cluster-management.io "${2#* }" -n "${2% *}" -o jsonpath="$3" 2>/dev/null || true; }
other_managed() {   # other_managed <hub>: managed clusters besides local-cluster and the ones this teardown detaches
  local mc out=""
  for mc in $(oc --context "$1" get managedclusters -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    if [ "$mc" = local-cluster ] || { [ "$mc" = "$MANAGED" ] && mine "$1" managedcluster "$MANAGED"; }; then continue; fi
    out+="${out:+ }$mc"
  done
  echo "$out"
}
argo_strangers() {   # argo_strangers <context>: Argo CD objects this repo did not create, as kind/namespace/name
  {
    oc --context "$1" get "$APP" -A -o json 2>/dev/null |
      jq -r --arg m "$MANAGED" '.items[] | select(.metadata.name as $n | ["dr-role", "hello-failover-\($m)", "hello-failover-push-\($m)"] | index($n) | not)
        | "Application \(.metadata.namespace)/\(.metadata.name)"'
    oc --context "$1" get "$APPSET" -A -o json 2>/dev/null |
      jq -r '.items[] | select(.metadata.name as $n | ["hello-failover", "hello-failover-push"] | index($n) | not)
        | "ApplicationSet \(.metadata.namespace)/\(.metadata.name)"'
    oc --context "$1" get argocds.argoproj.io -A -o json 2>/dev/null |
      jq -r --arg g "$GNS" '.items[] | select(.metadata.namespace != $g) | "ArgoCD \(.metadata.namespace)/\(.metadata.name)"'
  } || true
}

want_role() { if [ "$1" = "$ACTIVE" ]; then echo active; else echo passive; fi; }   # want_role <hub>: the role the build starts it in
run_branch() { [[ $1 =~ ^(failover|promote|demote)-[0-9]{12}$ ]]; }   # a branch hack/dr.sh pushes for a pull request
merged() { git merge-base --is-ancestor "$1" "origin/$BRANCH" 2>/dev/null; }   # merged <commit>: $BRANCH on origin has it

# --- doing it --------------------------------------------------------------------

act() {   # act "<where>: <verb> <what>" <command...>: do it, then "deleted hub-x: <what>"; with --dry-run, "would delete hub-x: <what>"
  local out rc=0 where=${1%%: *} v=${1#*: } what
  what=${v#* } v=${v%% *}
  if [ "$DRY" = 1 ]; then mark "would" "${C_WARN}○${C_OFF} would" "$v $where: $what"; return 0; fi
  out=$("${@:2}" 2>&1) || rc=$?
  if [ "$rc" != 0 ]; then
    show <<<"$out"
    die "could not $v $where: $what (its output is above)"
  fi
  if [ -n "$out" ]; then logln "$out"; fi
  case $v in delete | disable | update) v+="d" ;; clear) v+="ed" ;; esac   # set and reset read the same
  finished "$v $where: $what"
}
del() {   # del <context> <kind> <name> [namespace]: delete it if it is there and mine; note it if it stays
  local c=$1 k=$2 n=$3 ns=${4:-} where
  where=$k/$n${ns:+ in $ns}
  if mine "$c" "$k" "$n" ${ns:+-n "$ns"}; then
    act "$(cl "$c"): delete $where" oc --context "$c" delete "$k" "$n" ${ns:+-n "$ns"} --ignore-not-found --wait=false
  elif some "$c" "$k" "$n" ${ns:+-n "$ns"}; then
    note "$(cl "$c"): kept $where (it does not carry this repo's label; --full removes it)"
  fi
}
gone() {   # gone <context> <seconds> <what> <oc get args...>: wait until it is gone
  if [ "$DRY" = 1 ]; then return 0; fi
  if some "$1" "${@:4}"; then
    try_until "$2" "$3 to be gone from $(cl "$1")" none "$1" "${@:4}" || die "$(cl "$1"): $3 still there after $(upto "$2")"
  fi
}
ns_gone() {   # ns_gone <context> <namespace> [seconds]: delete a namespace and wait; on a stall, say what holds it
  local c=$1 n=$2 limit=${3:-900}
  if none "$c" ns "$n"; then return 0; fi
  act "$(cl "$c"): delete namespace $n" oc --context "$c" delete ns "$n" --ignore-not-found --wait=false
  if [ "$DRY" = 1 ]; then return 0; fi
  if ! try_until "$limit" "namespace $n to be gone from $(cl "$c")" none "$c" ns "$n"; then
    oc --context "$c" get ns "$n" -o json 2>/dev/null |
      jq -r '.status.conditions[]? | select(.status == "True") | "\(.type): \(.message)"' | show
    help_at docs/build.md#a-namespace-that-does-not-go
    red "$(cl "$c"): namespace $n is still terminating after $(upto "$limit")"
    die "namespace $n on $(cl "$c") does not go away: the lines above name what holds it"
  fi
}

# --- stages -------------------------------------------------------------------------

STAGES=(Pre-flight "DR roles" "Demo apps" Detach "Backup storage" ACM "OpenShift GitOps" Git Summary)
STAGE=0
stage() {   # stage <title> <what and why>
  if [ "$STAGE" -ge 2 ] || { [ "$STAGE" = 1 ] && [ "$DRY" = 1 ]; }; then go_on "$(stage_name $((STAGE + 1)) "$1")"; fi   # a real run confirms after the pre-flight
  STAGE=$((STAGE + 1))
  logln "" "#### Stage $STAGE/${#STAGES[@]}: $1"
  if [ "$STAGE" -gt 1 ]; then pin_clear; else pin_draw; fi   # under the header, each stage starts on an empty window
  blank
  if [ "$UI" = gum ]; then
    printf ' %s── %s%s\n' "$C_B$C_ACC" "$(paint "$(stage_name "$STAGE" "$1")" "$C_B$C_ACC")" "$C_OFF"
  else
    printf '#### %s\n' "$(bare "$(stage_name "$STAGE" "$1")")"
  fi
  LAST=heading
  explain "$2"
}

declare -A ACM_PLAN GITOPS_PLAN OP_NS ORPHAN
DETACH=0 DEMO=0 PLAN_ROWS="" GIT_OK=0 GIT_RESET="" RUN_BRANCHES="" LOCAL_BRANCHES=""
row() { PLAN_ROWS+="$1"$'\t'"$2"$'\t'"$3"$'\t'"$4"$'\n'; }

git_plan() {   # git_plan: rows for dr/ on $BRANCH and for hack/dr.sh's branches
  local c x v why sha ref kept=0 n
  if ! git fetch -q origin "$BRANCH" 2>/dev/null || ! git rev-parse -q --verify "origin/$BRANCH" >/dev/null; then
    row git "dr/ on $BRANCH" keep "could not fetch $BRANCH from origin"
    return 0
  fi
  GIT_OK=1
  for c in "${HUBS[@]}"; do
    x=$(git_role "$c") v=$(want_role "$c")
    if [ "$x" = "$v" ]; then continue; fi
    if [ "$x" = missing ]; then row git "dr/$c on $BRANCH" keep "there is no dr/$c/kustomization.yaml"; continue; fi
    if some "$c" "$APP" dr-role -n "$GNS" && ! mine "$c" "$APP" dr-role -n "$GNS"; then
      row git "dr/$c on $BRANCH" keep "it is $x; $(cl "$c")'s dr-role stays and would apply a change"
      continue
    fi
    GIT_RESET+="${GIT_RESET:+ }$c"
    if [ "$v" = active ] && [[ $x == "active with "* ]]; then why="drop the last failover's ${x#active with }"
    else why="it is $x; the next build starts $c $v"; fi
    row git "dr/$c on $BRANCH" "reset to $v" "$why"
  done
  while read -r sha ref; do
    ref=${ref#refs/heads/}
    if ! run_branch "$ref"; then continue; fi
    if merged "$sha"; then RUN_BRANCHES+="${RUN_BRANCHES:+ }$ref"; else kept=$((kept + 1)); fi
  done < <(git ls-remote --heads origin 2>/dev/null || true)
  while read -r ref; do
    if run_branch "$ref" && [ "$ref" != "$(git branch --show-current)" ] && merged "$ref"; then LOCAL_BRANCHES+="${LOCAL_BRANCHES:+ }$ref"; fi
  done < <(git for-each-ref --format='%(refname:short)' refs/heads/)
  n=$(wc -w <<<"$RUN_BRANCHES")
  if [ "$n" -gt 0 ]; then row git "$(branches "$n") on origin" remove "merged into $BRANCH"; fi
  if [ "$kept" -gt 0 ]; then row git "$(branches "$kept") on origin" keep "not merged into $BRANCH"; fi
  n=$(wc -w <<<"$LOCAL_BRANCHES")
  if [ "$n" -gt 0 ]; then row git "$(branches "$n") in your checkout" remove "merged into $BRANCH"; fi
}
branches() { if [ "$1" = 1 ]; then echo "1 hack/dr.sh branch"; else echo "$1 hack/dr.sh branches"; fi; }

preflight() {
  local c s v x mch blockers=0 had
  stage "Pre-flight (read-only)" "Reads what is on $(cl "$ACTIVE"), $(cl "$PASSIVE") and $(cl "$MANAGED") and decides what goes. $(if [ "$FULL" = 1 ]; then
    echo "With --full, ACM and OpenShift GitOps go wherever they are installed, whoever installed them, and $(cl "$MANAGED") is detached from its hub."
  elif [ "$RESET" = 1 ]; then
    echo "With --reset, only the exercise goes: the DR roles and the demo apps. ACM, OpenShift GitOps, the backup storage and $(cl "$MANAGED")'s import stay, for the next hack/build.sh to reuse."
  else
    echo "Without --full, only what carries this repo's label goes (every manifest in manifests/ and dr/ has it), plus ACM and OpenShift GitOps where hack/build.sh installed them. An ACM or OpenShift GitOps that was there before the build stays, and so does everything else on the clusters."
  fi) It refuses when removing ACM or OpenShift GitOps would take something that is not this repo's with it. Nothing changes in this stage."
  sec_begin "Clusters"
  help_at docs/build.md#clusters
  for c in "${CLUSTERS[@]}"; do
    if alive "$c"; then ok "$(cl "$c") API answers"; else red "$(cl "$c") API does not answer"; blockers=1; fi
  done
  sec_end "all three APIs answer"
  if [ "$blockers" = 1 ]; then verdict bad "TEARDOWN RED: every cluster must answer; power them on and run it again"; return 1; fi

  say "What is there"
  spin_begin "reading the three clusters"
  for c in "${HUBS[@]}" "$MANAGED"; do
    ACM_PLAN[$c]=none
    if [ "$c" != "$MANAGED" ]; then
      ACM_PLAN[$c]=$(operator_plan "$c" advanced-cluster-management)
      s=$(sub_of "$c" advanced-cluster-management) && OP_NS[$c/acm]=${s% *}
      s=$(sub_of "$c" multicluster-engine) && OP_NS[$c/mce]=${s% *}
    fi
    GITOPS_PLAN[$c]=$(operator_plan "$c" openshift-gitops-operator)
  done
  for c in "${HUBS[@]}"; do
    if mine "$c" managedcluster "$MANAGED"; then DETACH=1; fi
    if mine "$c" "$APPSET" hello-failover -n "$GNS" || mine "$c" "$APPSET" hello-failover-push -n "$GNS"; then DEMO=1; fi
  done
  if [ "$FULL" = 1 ]; then DEMO=1; fi
  if [ "$RESET" = 1 ]; then DETACH=0; fi
  spin_stop

  for c in "${HUBS[@]}"; do
    s=$(sub_of "$c" advanced-cluster-management)
    v=$(if [ -n "$s" ]; then sub_get "$c" "$s" '{.status.installedCSV}'; fi)
    case ${ACM_PLAN[$c]} in
      none) row "$(cl "$c")" ACM "-" "not installed" ;;
      remove) row "$(cl "$c")" "ACM ${v#advanced-cluster-management.}" remove "$(if [ "$FULL" = 1 ]; then echo "--full"; else echo "hack/build.sh installed it"; fi)" ;;
      keep)
        row "$(cl "$c")" "ACM ${v#advanced-cluster-management.}" keep "$(kept_why)"
        if [ "$RESET" = 0 ]; then   # with --reset, the build's changes to it stay too, for the next build
          mch=$(mch_of "$c")
          if [ -n "$mch" ] && [ "$(mch_get "$c" "$mch" "{.metadata.annotations.$A_BACKUP}")" = enabled-by-build ]; then
            row "$(cl "$c")" "  cluster-backup" "turn off" "the build turned it on"
          fi
          x=$(sub_get "$c" "$s" "{.metadata.annotations.$A_APPROVAL}")
          if [ -n "$x" ]; then row "$(cl "$c")" "  ACM approval" "back to $x" "the build set Manual"; fi
        fi
        ;;
    esac
    s=$(sub_of "$c" openshift-gitops-operator)
    v=$(if [ -n "$s" ]; then sub_get "$c" "$s" '{.status.installedCSV}'; fi)
    case ${GITOPS_PLAN[$c]} in
      none) row "$(cl "$c")" "OpenShift GitOps" "-" "not installed" ;;
      remove) row "$(cl "$c")" "OpenShift GitOps ${v#openshift-gitops-operator.}" remove "$(if [ "$FULL" = 1 ]; then echo "--full"; else echo "hack/build.sh installed it"; fi)" ;;
      keep) row "$(cl "$c")" "OpenShift GitOps ${v#openshift-gitops-operator.}" keep "$(kept_why)" ;;
    esac
    if some "$c" managedcluster "$MANAGED"; then
      if [ "$RESET" = 1 ]; then row "$(cl "$c")" "ManagedCluster $(cl "$MANAGED")" keep "--reset keeps the import"
      elif mine "$c" managedcluster "$MANAGED"; then row "$(cl "$c")" "ManagedCluster $(cl "$MANAGED")" detach "$(if [ "$FULL" = 1 ]; then echo "--full"; else echo "the build imported it"; fi)"
      else row "$(cl "$c")" "ManagedCluster $(cl "$MANAGED")" keep "managed before the build"; fi
    fi
    had=0
    for x in "$APP dr-role -n $GNS" "$BSCHED schedule-acm -n $NS" "$RESTORE restore-acm-passive-sync -n $NS" \
      "dataprotectionapplications.oadp.openshift.io acm-dpa -n $NS" "$APPSET hello-failover -n $GNS" "$APPSET hello-failover-push -n $GNS"; do
      # shellcheck disable=SC2086 # x is a kind, a name and a namespace flag
      if mine "$c" $x; then had=1; fi
    done
    if [ "$had" = 1 ]; then row "$(cl "$c")" "DR roles, backups, demo wiring" remove "this repo's"; fi
    if [ "$RESET" = 1 ] && mine "$c" dataprotectionapplications.oadp.openshift.io acm-dpa -n "$NS"; then
      row "$(cl "$c")" "backup storage (DPA, S3 key)" keep "--reset keeps it"
    fi
  done
  if some "$MANAGED" ns hello-failover || some "$MANAGED" ns hello-failover-push; then
    if [ "$DEMO" = 1 ]; then row "$(cl "$MANAGED")" "demo apps" remove "with their ApplicationSets"; else row "$(cl "$MANAGED")" "demo apps" keep "their ApplicationSets stay"; fi
  fi
  case ${GITOPS_PLAN[$MANAGED]} in
    none) row "$(cl "$MANAGED")" "OpenShift GitOps" "-" "not installed" ;;
    remove) row "$(cl "$MANAGED")" "OpenShift GitOps" remove "$(if [ "$FULL" = 1 ]; then echo "--full"; else echo "hack/build.sh installed it"; fi)" ;;
    keep) row "$(cl "$MANAGED")" "OpenShift GitOps" keep "$(kept_why)" ;;
  esac
  for c in "${CLUSTERS[@]}"; do
    if [ "${ACM_PLAN[$c]}" = none ] && orphan_agent "$c"; then
      if [ "$FULL" = 1 ]; then ORPHAN[$c]=1; row "$(cl "$c")" "ACM agent of its own former hub" remove "no hub left on $(cl "$c") (--full)"
      else row "$(cl "$c")" "ACM agent of its own former hub" keep "--full removes it"; fi
    fi
  done
  if some "$MANAGED" klusterlets.operator.open-cluster-management.io klusterlet && ! orphan_agent "$MANAGED"; then
    if [ "$DETACH" = 1 ]; then row "$(cl "$MANAGED")" "ACM agent (klusterlet)" remove "the detach removes it"; else row "$(cl "$MANAGED")" "ACM agent (klusterlet)" keep "$(cl "$MANAGED") stays managed"; fi
  fi
  git_plan
  printf 'Cluster\tWhat\tPlan\tWhy\n%s' "$PLAN_ROWS" | table

  if [ "$RESET" = 1 ]; then HELP=""; return 0; fi   # ACM and OpenShift GitOps stay
  sec_begin "Would removing ACM or OpenShift GitOps take anything else with it?"
  explain "Removing ACM detaches every cluster it manages, and removing OpenShift GitOps deletes every Argo CD application on that cluster. So both must find nothing that is not this repo's."
  help_at docs/build.md#what-the-teardown-refuses
  for c in "${HUBS[@]}"; do
    if [ "${ACM_PLAN[$c]}" = remove ]; then
      x=$(other_managed "$c")
      if [ -z "$x" ]; then ok "$(cl "$c"): ACM manages nothing else"; else red "$(cl "$c"): ACM also manages $x: detach it first, or keep ACM"; blockers=1; fi
      if [ "$FULL" = 0 ]; then
        for x in discoveryconfigs.discovery.open-cluster-management.io agentserviceconfigs.agent-install.openshift.io multiclusterobservabilities.observability.open-cluster-management.io; do
          if some "$c" "$x" -A; then red "$(cl "$c"): ACM runs a ${x%%.*} this repo did not create; remove it first, or use --full"; blockers=1; fi
        done
      fi
    fi
  done
  for c in "${CLUSTERS[@]}"; do
    if [ "${GITOPS_PLAN[$c]}" = remove ]; then
      x=$(argo_strangers "$c")
      if [ -z "$x" ]; then ok "$(cl "$c"): Argo CD runs nothing else"
      else
        red "$(cl "$c"): OpenShift GitOps also runs what this repo did not create:"
        show <<<"$x"
        blockers=1
      fi
    fi
  done
  if [ "$DETACH" = 0 ] && some "$MANAGED" klusterlets.operator.open-cluster-management.io klusterlet && [ "$FULL" = 1 ] && ! orphan_agent "$MANAGED"; then
    note "$(cl "$MANAGED") runs an ACM agent but neither hub lists it: its hub is elsewhere; detach it there"
  fi
  sec_end "what goes takes nothing that is not this repo's with it"
  HELP=""
  if [ "$blockers" = 1 ]; then
    verdict bad "TEARDOWN RED: nothing was removed; fix the RED lines (each links to why) and run it again"
    return 1
  fi
}

cmd_roles() {
  local c n
  stage "DR roles" "Stops the DR machinery first, so nothing re-creates what the later stages delete: each hub's dr-role application (its own Argo CD would put the role back), the role it applied (the active hub's BackupSchedule, the passive hub's continuous restore, any activation restore), and the RBAC that let it."
  for c in "${HUBS[@]}"; do
    say "$(cl "$c")"
    del "$c" "$APP" dr-role "$GNS"
    if some "$c" "$APP" dr-role -n "$GNS" && ! mine "$c" "$APP" dr-role -n "$GNS"; then
      note "$(cl "$c"): dr-role stays, so the role it applies stays too (its own Argo CD would put it back)"
      continue
    fi
    gone "$c" 120 "application dr-role" "$APP" dr-role -n "$GNS"
    del "$c" "$BSCHED" schedule-acm "$NS"
    for n in $(oc --context "$c" get "$RESTORE" -n "$NS" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true); do
      if [[ $n == restore-acm-* ]]; then del "$c" "$RESTORE" "$n" "$NS"; fi
    done
    del "$c" rolebinding dr-role-backup-operator "$NS"
    del "$c" role dr-role-backup-operator "$NS"
    gone "$c" 300 "the backup schedule" "$BSCHED" schedule-acm -n "$NS"
  done
}

cmd_demo() {
  local c n
  stage "Demo apps" "Removes what delivers the demo apps: the ApplicationSets and the applications they made, the GitOpsCluster that registers $(cl "$MANAGED") with each hub's Argo CD, its placements and cluster secrets. Then the apps themselves on $(cl "$MANAGED"). The passive hub has copies too: its continuous restore brought them over from the active hub."
  for c in "${HUBS[@]}"; do
    say "$(cl "$c")"
    del "$c" "$APPSET" hello-failover "$GNS"
    del "$c" "$APPSET" hello-failover-push "$GNS"
    for n in "hello-failover-$MANAGED" "hello-failover-push-$MANAGED"; do
      # the ApplicationSets made these (they carry no label of their own) and take them along
      if [ "$DEMO" = 1 ] && some "$c" "$APP" "$n" -n "$GNS"; then
        act "$(cl "$c"): delete $APP/$n in $GNS" oc --context "$c" delete "$APP" "$n" -n "$GNS" --ignore-not-found --wait=false
      fi
    done
    del "$c" gitopsclusters.apps.open-cluster-management.io gitops-cluster "$GNS"
    del "$c" placements.cluster.open-cluster-management.io hello-failover-placement "$GNS"
    del "$c" placements.cluster.open-cluster-management.io gitops-clusters "$GNS"
    del "$c" managedclustersetbindings.cluster.open-cluster-management.io default "$GNS"
    del "$c" configmap acm-placement "$GNS"
    if [ "$DEMO" = 1 ]; then
      for n in $(oc --context "$c" get secret -n "$GNS" -l apps.open-cluster-management.io/acm-cluster=true \
        -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true); do
        if [[ $n == "$MANAGED"-* ]]; then
          act "$(cl "$c"): delete secret/$n in $GNS (the GitOpsCluster's cluster secret)" \
            oc --context "$c" delete secret "$n" -n "$GNS" --ignore-not-found --wait=false
        fi
      done
    fi
  done
  say "$(cl "$MANAGED")"
  if [ "$DEMO" = 0 ]; then
    if some "$MANAGED" ns hello-failover || some "$MANAGED" ns hello-failover-push; then note "the demo apps stay: their ApplicationSets do"; fi
    return 0
  fi
  if some "$MANAGED" "$APP" "hello-failover-$MANAGED" -n "$GNS"; then
    # the hub's work agent removes the pull app's copy when its ApplicationSet goes; delete it if that has not happened
    if [ "$DRY" = 0 ] && ! try_until 120 "the pull app's copy on $(cl "$MANAGED") to go with its ApplicationSet" \
      none "$MANAGED" "$APP" "hello-failover-$MANAGED" -n "$GNS"; then
      note "it is still there: deleting it directly"
    fi
    if some "$MANAGED" "$APP" "hello-failover-$MANAGED" -n "$GNS"; then
      act "$(cl "$MANAGED"): delete $APP/hello-failover-$MANAGED in $GNS" \
        oc --context "$MANAGED" delete "$APP" "hello-failover-$MANAGED" -n "$GNS" --ignore-not-found --wait=false
      gone "$MANAGED" 120 "the pull app" "$APP" "hello-failover-$MANAGED" -n "$GNS"
    fi
  fi
  ns_gone "$MANAGED" hello-failover 600
  ns_gone "$MANAGED" hello-failover-push 600
}

cmd_detach() {
  local c order=() t0
  stage "Detach $(cl "$MANAGED")" "Deletes the ManagedCluster $(cl "$MANAGED"). A hub that can still reach $(cl "$MANAGED") then removes its ACM agent (the klusterlet) and the add-ons, which takes a few minutes. A hub whose copy is stale (Unknown) goes first: deleting it there touches nothing on $(cl "$MANAGED")."
  if [ "$DETACH" = 0 ]; then
    if some "$ACTIVE" managedcluster "$MANAGED" || some "$PASSIVE" managedcluster "$MANAGED"; then note "$(cl "$MANAGED") stays managed: it was managed before the build (--full detaches it)"; fi
    return 0
  fi
  for c in "${HUBS[@]}"; do
    if some "$c" managedcluster "$MANAGED" && [ "$(oc --context "$c" get managedcluster "$MANAGED" \
      -o jsonpath='{.status.conditions[?(@.type=="ManagedClusterConditionAvailable")].status}' 2>/dev/null)" != True ]; then
      order=("$c" "${order[@]}")
    else
      order+=("$c")
    fi
  done
  for c in "${order[@]}"; do
    if some "$c" managedcluster "$MANAGED"; then
      act "$(cl "$c"): delete managedcluster/$MANAGED" oc --context "$c" delete managedcluster "$MANAGED" --ignore-not-found --wait=false
      gone "$c" 900 "managedcluster $MANAGED" managedcluster "$MANAGED"
    fi
  done
  if [ "$DRY" = 1 ]; then return 0; fi
  t0=$SECONDS
  if some "$MANAGED" klusterlets.operator.open-cluster-management.io klusterlet || some "$MANAGED" ns open-cluster-management-agent; then
    help_at docs/build.md#a-cluster-that-is-managed-by-another-hub
    if ! try_until 900 "the ACM agent to leave $(cl "$MANAGED")" not some "$MANAGED" ns open-cluster-management-agent; then
      red "$(cl "$MANAGED") still has namespace open-cluster-management-agent after 15 min"
      die "the detach did not remove $(cl "$MANAGED")'s ACM agent: see the link above"
    fi
  fi
  finished "$(cl "$MANAGED") is detached ($(dur $((SECONDS - t0))))"
}

cmd_storage() {
  local c
  stage "Backup storage" "Deletes each hub's DataProtectionApplication (Velero and its connection to the S3 bucket) and the secret with the S3 key. The bucket and the backups in it stay: empty it with your S3 tool if the next build should start from nothing."
  for c in "${HUBS[@]}"; do
    say "$(cl "$c")"
    del "$c" dataprotectionapplications.oadp.openshift.io acm-dpa "$NS"
    del "$c" secret cloud-credentials "$NS"
    gone "$c" 300 "the DataProtectionApplication" dataprotectionapplications.oadp.openshift.io acm-dpa -n "$NS"
  done
}

cleanup_script() {   # cleanup_script <context>: ACM's "Cleaning up artifacts before reinstalling" script, after its first line
  local c=$1
  oc --context "$c" delete apiservice v1.admission.cluster.open-cluster-management.io v1.admission.work.open-cluster-management.io --ignore-not-found
  oc --context "$c" delete clusterimageset --all --ignore-not-found || true   # its CRD may already be gone with the engine
  oc --context "$c" delete clusterrole open-cluster-management:cert-policy-controller open-cluster-management:cluster-manager-admin \
    open-cluster-management:config-policy-controller open-cluster-management:endpoint-observability-operator \
    open-cluster-management:governance-policy-framework open-cluster-management:governance-policy-framework-kube-rbac-proxy \
    multiclusterengines.multicluster.openshift.io-v1-admin multiclusterengines.multicluster.openshift.io-v1-crdview \
    multiclusterengines.multicluster.openshift.io-v1-edit multiclusterengines.multicluster.openshift.io-v1-view \
    open-cluster-management:addons:application-manager open-cluster-management:admin-aggregate \
    open-cluster-management:cert-policy-controller-hub open-cluster-management:cluster-manager-admin-aggregate \
    open-cluster-management:config-policy-controller-hub open-cluster-management:edit-aggregate \
    open-cluster-management:policy-framework-hub open-cluster-management:view-aggregate --ignore-not-found
  oc --context "$c" delete crd klusterletaddonconfigs.agent.open-cluster-management.io placementbindings.policy.open-cluster-management.io \
    policies.policy.open-cluster-management.io userpreferences.console.open-cluster-management.io \
    discoveredclusters.discovery.open-cluster-management.io discoveryconfigs.discovery.open-cluster-management.io --ignore-not-found
  oc --context "$c" delete mutatingwebhookconfiguration ocm-mutating-webhook managedclustermutators.admission.cluster.open-cluster-management.io \
    multicluster-observability-operator --ignore-not-found
  oc --context "$c" delete validatingwebhookconfiguration channels.apps.open.cluster.management.webhook.validator application-webhook-validator \
    multiclusterhub-operator-validating-webhook ocm-validating-webhook multicluster-observability-operator \
    multiclusterengines.multicluster.openshift.io --ignore-not-found
}

remove_own_agent() {   # remove_own_agent <context>: a hub's own agent (local-cluster) that the uninstall left, the documented way
  local c=$1
  help_at docs/build.md#a-cluster-that-is-managed-by-another-hub
  if some "$c" klusterlets.operator.open-cluster-management.io klusterlet; then
    act "$(cl "$c"): delete klusterlet/klusterlet (the hub's own agent for local-cluster; its operator cleans up after it)" \
      oc --context "$c" delete klusterlets.operator.open-cluster-management.io klusterlet --ignore-not-found --wait=false
    if [ "$DRY" = 0 ] && ! try_until 300 "$(cl "$c")'s klusterlet to finish its cleanup" none "$c" klusterlets.operator.open-cluster-management.io klusterlet; then
      if some "$c" deployments.apps klusterlet -n open-cluster-management-agent; then
        red "$(cl "$c"): the klusterlet is still there after 5 min, with its operator running"
        die "$(cl "$c")'s klusterlet does not finish its cleanup: see the link above"
      fi
      act "$(cl "$c"): clear the klusterlet's finalizer (its operator, which would clear it, is gone)" oc --context "$c" patch \
        klusterlets.operator.open-cluster-management.io klusterlet --type merge -p '{"metadata":{"finalizers":null}}'
      gone "$c" 120 "the klusterlet" klusterlets.operator.open-cluster-management.io klusterlet
    fi
  fi
  ns_gone "$c" open-cluster-management-agent-addon
  ns_gone "$c" open-cluster-management-agent
}

remove_operator() {   # remove_operator <context> <package>: its Subscription, then its CSVs
  local c=$1 s ns csvs
  s=$(sub_of "$c" "$2")
  if [ -z "$s" ]; then return 0; fi
  ns=${s% *}
  csvs=$(oc --context "$c" get "$CSV" -n "$ns" -o json 2>/dev/null |
    jq -r --arg p "$2." '.items[] | select(.metadata.name | startswith($p)) | .metadata.name' | paste -sd' ' -)
  act "$(cl "$c"): delete subscription ${s#* } in $ns (no more installs or upgrades of $2)" \
    oc --context "$c" delete "$SUB" "${s#* }" -n "$ns" --ignore-not-found
  if [ -n "$csvs" ]; then
    # shellcheck disable=SC2086 # one CSV name per word
    act "$(cl "$c"): delete $csvs in $ns (the operator itself)" oc --context "$c" delete "$CSV" $csvs -n "$ns" --ignore-not-found --wait=false
    # shellcheck disable=SC2086
    gone "$c" 300 "the $2 operator" "$CSV" $csvs -n "$ns"
  fi
}

cmd_acm() {
  local c mch x n
  stage "ACM" "Where ACM goes, it goes the documented way: the MultiClusterHub first (it takes the multicluster engine, the add-ons and the backup operator with it, which takes 5 to 15 minutes), then the ACM operator, then what ACM's own cleanup script lists and the namespaces ACM made, and last the hub's own agent for local-cluster if the uninstall left it. Where ACM stays, the two changes the build made to it are undone."
  for c in "${HUBS[@]}"; do
    case ${ACM_PLAN[$c]} in
      none) continue ;;
      keep)
        say "$(cl "$c"): ACM stays"
        mch=$(mch_of "$c")
        if [ -n "$mch" ] && [ "$(mch_get "$c" "$mch" "{.metadata.annotations.$A_BACKUP}")" = enabled-by-build ]; then
          x=$(oc --context "$c" get multiclusterhubs.operator.open-cluster-management.io "${mch#* }" -n "${mch% *}" -o json |
            jq -c --arg a "$A_BACKUP" '{metadata: {annotations: {($a): null}}, spec: {overrides: {components:
              ((.spec.overrides.components // [] | map(select(.name != "cluster-backup"))) + [{name: "cluster-backup", enabled: false}])}}}')
          act "$(cl "$c"): disable cluster-backup again (the build enabled it)" \
            oc --context "$c" patch multiclusterhubs.operator.open-cluster-management.io "${mch#* }" -n "${mch% *}" --type merge -p "$x"
          ns_gone "$c" "$NS"
        fi
        x=$(sub_of "$c" advanced-cluster-management)
        n=$(sub_get "$c" "$x" "{.metadata.annotations.$A_APPROVAL}")
        if [ -n "$n" ]; then
          act "$(cl "$c"): set the ACM subscription's approval back to $n" oc --context "$c" patch "$SUB" "${x#* }" -n "${x% *}" --type merge \
            -p "{\"metadata\":{\"annotations\":{\"$A_APPROVAL\":null}},\"spec\":{\"installPlanApproval\":\"$n\"}}"
        fi
        ;;
      remove)
        say "$(cl "$c"): remove ACM"
        if [ "$FULL" = 1 ]; then
          for x in discoveryconfigs.discovery.open-cluster-management.io agentserviceconfigs.agent-install.openshift.io \
            multiclusterobservabilities.observability.open-cluster-management.io; do
            if some "$c" "$x" -A; then
              act "$(cl "$c"): delete every ${x%%.*} (the ACM docs remove them before the MultiClusterHub)" \
                oc --context "$c" delete "$x" --all --all-namespaces --ignore-not-found --wait=false
            fi
          done
        fi
        mch=$(mch_of "$c")
        if [ -n "$mch" ]; then
          act "$(cl "$c"): delete multiclusterhub/${mch#* } in ${mch% *}" oc --context "$c" delete multiclusterhubs.operator.open-cluster-management.io \
            "${mch#* }" -n "${mch% *}" --ignore-not-found --wait=false
        fi
        ;;
    esac
  done
  for c in "${HUBS[@]}"; do
    if [ "${ACM_PLAN[$c]}" != remove ]; then continue; fi
    say "$(cl "$c"): after the MultiClusterHub$(if [ "$DRY" = 1 ]; then echo ", whatever of this it leaves behind"; fi)"
    help_at docs/build.md#a-multiclusterhub-that-does-not-go
    if [ "$DRY" = 0 ] && ! try_until 1800 "$(cl "$c")'s MultiClusterHub to finish uninstalling" not some "$c" multiclusterhubs.operator.open-cluster-management.io -A; then
      oc --context "$c" get multiclusterhubs.operator.open-cluster-management.io -A -o json |
        jq -r '.items[].status | "phase \(.phase // "?")", (.conditions[]? | "\(.type) \(.status): \(.message // "")")' | show
      red "$(cl "$c"): the MultiClusterHub is still there after 30 min"
      die "$(cl "$c")'s MultiClusterHub does not finish uninstalling: its status is above"
    fi
    remove_operator "$c" advanced-cluster-management
    for x in $(oc --context "$c" get multiclusterengines.multicluster.openshift.io -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true); do
      act "$(cl "$c"): delete multiclusterengine/$x (left by the MultiClusterHub)" \
        oc --context "$c" delete multiclusterengines.multicluster.openshift.io "$x" --ignore-not-found --wait=false
      gone "$c" 1200 "multiclusterengine $x" multiclusterengines.multicluster.openshift.io "$x"
    done
    remove_operator "$c" multicluster-engine
    act "$(cl "$c"): delete what ACM's cleanup script lists (API services, cluster image sets, cluster roles, CRDs, webhooks)" cleanup_script "$c"
    for n in "$NS" open-cluster-management-global-set open-cluster-management-hub hive local-cluster "$MANAGED" \
      "${OP_NS[$c/mce]:-multicluster-engine}" "${OP_NS[$c/acm]:-open-cluster-management}"; do
      ns_gone "$c" "$n"
    done
    # the agent left on the hub is its own (local-cluster), which the uninstall can leave behind, unless another hub manages it
    if some "$c" klusterlets.operator.open-cluster-management.io klusterlet && ! self_agent "$c"; then
      note "$(cl "$c") still runs a klusterlet for the hub at $(klusterlet_hub "$c"): that hub manages $(cl "$c"), so its agent stays"
    else
      remove_own_agent "$c"
    fi
  done
  for c in "${CLUSTERS[@]}"; do
    if [ "${ORPHAN[$c]:-0}" = 1 ]; then
      say "$(cl "$c"): the ACM agent an earlier uninstall left"
      remove_own_agent "$c"
    fi
  done
}

cmd_gitops() {
  local c s
  stage "OpenShift GitOps" "Where OpenShift GitOps goes, it goes the documented way: its Argo CD instance first, while the operator can still clean up after it, then the operator, then the openshift-gitops namespace. The Argo CD CRDs stay; they are harmless, and the next install adopts them."
  for c in "${CLUSTERS[@]}"; do
    case ${GITOPS_PLAN[$c]} in
      none) continue ;;
      keep) say "$(cl "$c"): OpenShift GitOps stays"; continue ;;
    esac
    say "$(cl "$c"): remove OpenShift GitOps"
    if some "$c" gitopsservices.pipelines.openshift.io cluster -n "$GNS"; then
      act "$(cl "$c"): delete gitopsservice/cluster (the operator then deletes its Argo CD instance)" \
        oc --context "$c" delete gitopsservices.pipelines.openshift.io cluster -n "$GNS" --ignore-not-found --wait=false
    fi
    if some "$c" argocds.argoproj.io -n "$GNS"; then
      act "$(cl "$c"): delete the Argo CD instances in $GNS" oc --context "$c" delete argocds.argoproj.io --all -n "$GNS" --ignore-not-found --wait=false
    fi
    gone "$c" 600 "the Argo CD instance" argocds.argoproj.io -n "$GNS"
    s=$(sub_of "$c" openshift-gitops-operator)
    remove_operator "$c" openshift-gitops-operator
    if [ "$DRY" = 0 ] && some "$c" argocds.argoproj.io -n "$GNS"; then
      # the operator can re-create its default instance before it stops; with the operator gone, delete it again
      oc --context "$c" delete argocds.argoproj.io --all -n "$GNS" --ignore-not-found --wait=false 2>&1 | to_log
    fi
    ns_gone "$c" "$GNS"
    if [ -n "$s" ] && [ "${s% *}" != openshift-operators ]; then ns_gone "$c" "${s% *}"; fi
  done
}

dr_reset() {   # dr_reset <worktree> <hub>: dr/<hub> lists only the role the build starts it in, and no activation one-shot
  local f=$1/dr/$2/kustomization.yaml v
  v=$(want_role "$2")
  awk -v r="  - ../roles/$v" '/^resources:/ {print; print r; skip = 1; next} skip && /^  - / {next} {skip = 0; print}' "$f" >"$f.new" &&
    mv "$f.new" "$f" &&
    git -C "$1" rm -q --ignore-unmatch "dr/$2/restore-activate-*.yaml" &&
    [ "$(sed -n 's/^  - //p' "$f" | paste -sd' ' -)" = "../roles/$v" ]
}
push_reset() {   # push_reset <hub...>: one commit on top of origin/$BRANCH, made in a scratch worktree, so your checkout stays as it is
  local w c rc=0
  w=$(mktemp -d)
  git worktree add -q --detach "$w" "origin/$BRANCH" || { rmdir "$w"; return 1; }
  for c in "$@"; do dr_reset "$w" "$c" || rc=1; done
  if [ "$rc" = 0 ]; then
    git -C "$w" add -A dr/ &&
      git -C "$w" commit -q -m "dr/: $ACTIVE active, $PASSIVE passive, as the next build starts them (hack/teardown.sh)" &&
      git -C "$w" push -q origin "HEAD:refs/heads/$BRANCH" || rc=$?
  fi
  git worktree remove --force "$w" 2>/dev/null || rm -rf "$w"
  return "$rc"
}

cmd_git() {
  local c what=""
  stage "Git" "Now that no dr-role application reads it, resets dr/ on $BRANCH to the roles the build starts from: $(cl "$ACTIVE") active, $(cl "$PASSIVE") passive, and no activation one-shot left by a git-driven failover. Then deletes the branches hack/dr.sh pushed for its pull requests, once $BRANCH has merged them."
  if [ "$GIT_OK" = 0 ]; then note "could not fetch $BRANCH from origin: git stays as it is"; return 0; fi
  help_at dr/README.md
  for c in $GIT_RESET; do what+="${what:+, }dr/$c to $(want_role "$c")"; done
  if [ -n "$GIT_RESET" ]; then
    # shellcheck disable=SC2086 # one hub per word
    act "$BRANCH: reset $what, and push it" push_reset $GIT_RESET
    c=$(git branch --show-current)
    if [ "$DRY" = 1 ]; then :
    elif [ "$c" != "$BRANCH" ]; then note "your checkout is on ${c:-a detached HEAD}: git pull $BRANCH when you switch back to it"
    elif [ -n "$(git status --porcelain --untracked-files=no)" ]; then note "your checkout of $BRANCH has changes, so it stays behind origin: git pull before the next build"
    else act "git: update your checkout of $BRANCH" git merge -q --ff-only "origin/$BRANCH"; fi
  fi
  if [ -n "$RUN_BRANCHES" ]; then
    # shellcheck disable=SC2086 # one branch per word
    act "git: delete the merged hack/dr.sh branches on origin" git push -q origin --delete $RUN_BRANCHES
    show <<<"$(fmt -w 72 <<<"$RUN_BRANCHES")"
  fi
  if [ -n "$LOCAL_BRANCHES" ]; then
    # shellcheck disable=SC2086 # one branch per word
    act "git: delete the merged hack/dr.sh branches in your checkout" git branch -q -D $LOCAL_BRANCHES
  fi
  if [ -z "$GIT_RESET" ] && [ -z "$RUN_BRANCHES" ] && [ -z "$LOCAL_BRANCHES" ]; then
    ok "dr/ on $BRANCH already gives $(cl "$ACTIVE") the active role and $(cl "$PASSIVE") the passive one"
  fi
}

summary() {
  local c
  stage "Summary" "What is left of the exercise on each cluster."
  steps_end
  for c in "${CLUSTERS[@]}"; do
    printf '%s\t%s\t%s\t%s\n' "$(cl "$c")" \
      "$(if [ -n "$(sub_of "$c" advanced-cluster-management)" ]; then echo installed; else echo -; fi)" \
      "$(if [ -n "$(sub_of "$c" openshift-gitops-operator)" ]; then echo installed; else echo -; fi)" \
      "$(if some "$c" klusterlets.operator.open-cluster-management.io klusterlet; then echo yes; else echo -; fi)"
  done | { printf 'Cluster\tACM\tOpenShift GitOps\tACM agent\n'; cat; } | table
  if [ "$GIT_OK" = 1 ]; then note "dr/ on $BRANCH: $(cl "$ACTIVE") $(git_role "$ACTIVE"), $(cl "$PASSIVE") $(git_role "$PASSIVE")"; fi
  if [ "$RESET" = 1 ]; then note "ACM, OpenShift GitOps, the backup storage and $(cl "$MANAGED")'s import stay (--reset): hack/build.sh reuses them"; fi
  note "the S3 bucket still holds the old backups; the next build's first backup is newer, so restores use that"
  note "CRDs the operators installed stay (ACM's, Velero's, Argo CD's): harmless, and a new install adopts them"
  box rounded 10 "Teardown done in $(dur $((SECONDS - T0)))" "Next: hack/build.sh builds the exercise again (docs/build.md)." \
    "Log: $LOGFILE"
}

usage() { sed -n '2,/^set -euo/{/^set -euo/d;s/^# \{0,1\}//;p}' "$SELF"; }
menu() {   # no options on a terminal: what --reset and --full remove, then pick one; the default mode is a command (usage)
  local choice items
  intro "Tear down the ACM hub DR exercise" \
    "--reset removes the exercise: the DR roles and the demo apps, and dr/ in git goes back to the roles the build starts from. ACM, OpenShift GitOps, the backup storage and the workload cluster's import stay, so the next build takes minutes." \
    "" \
    "--full removes all of that, plus the backup storage, ACM and OpenShift GitOps whoever installed them, and the workload cluster's import." \
    "" \
    "Other workloads and the S3 bucket stay either way."
  items=("Check (Reset)" "Check (Teardown)" "Teardown (Reset)" "Teardown (Full)" Quit)
  echo
  if [ "$UI" = gum ]; then
    choice=$(gum choose --header "What would you like to do?" "${items[@]}" </dev/tty 2>/dev/tty) || choice=Quit
  else
    PS3="What would you like to do? "
    select choice in "${items[@]}"; do if [ -n "$choice" ]; then break; fi; done </dev/tty
  fi
  case $choice in
    "Check (Reset)") menu_run --dry-run --reset ;;
    "Check (Teardown)") menu_run --dry-run --full ;;
    "Teardown (Reset)") menu_run --reset ;;
    "Teardown (Full)") menu_run --full ;;
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
  if [ -n "$POLL_PID" ]; then kill "$POLL_PID" 2>/dev/null || true; fi
  spin_stop
  pin_off
  if [ "$rc" = 0 ] || [ "$DIED" = 1 ]; then return 0; fi
  if [ "$rc" = 130 ]; then
    box thick 9 "STOP" "interrupted: run it again to carry on; every stage skips what is already gone" ${LOGFILE:+"" "Log: $LOGFILE"}
  else
    box thick 9 "STOP" "hack/teardown.sh stopped on a failed command ${ERR_AT:-} (exit $rc). Its output, if any, is above." ${LOGFILE:+"" "Log: $LOGFILE"}
  fi
}

start_screen
if [ "$ARGC" = 0 ]; then
  if [ -t 0 ] && [ -t 1 ]; then menu; else usage; exit 2; fi
fi
if [ "$FULL" = 1 ] && [ "$RESET" = 1 ]; then echo "--reset keeps what --full removes: pick one" >&2; exit 2; fi
if [ "$RESET" = 1 ]; then STAGES=(Pre-flight "DR roles" "Demo apps" Git Summary); fi
for c in "${CLUSTERS[@]}"; do
  grep -qx -- "$c" <<<"$(oc config get-contexts -o name)" || { echo "no kubeconfig context named '$c' (KUBECONFIG=${KUBECONFIG:-default})" >&2; exit 2; }
done
mkdir -p "$HOME/acm-dr/logs"
LOGFILE=$HOME/acm-dr/logs/teardown$(if [ "$DRY" = 1 ]; then echo -dryrun; fi)-$(date -u +%Y%m%dT%H%M%SZ).log
# shellcheck disable=SC2094 # both append
exec 3>>"$LOGFILE" 2> >(tee -a "$LOGFILE" >&2)
logln "#### $(now) hack/teardown.sh$(mode_flag)$(if [ "$DRY" = 1 ]; then echo " --dry-run"; fi)"
trap on_exit EXIT
trap 'exit 130' INT TERM
set -E
trap 'on_err "$BASH_COMMAND"' ERR
T0=$SECONDS
STEPS_TITLE="Teardown$(mode_flag)$(if [ "$DRY" = 1 ]; then echo " dry run"; fi) · $(cl "$ACTIVE"), $(cl "$PASSIVE"), $(cl "$MANAGED")"
steps_pin   # the stages stay at the top, and the output stays in the window under them

if [ "$DRY" = 1 ]; then
  box rounded 13 "Dry run$(if [ -n "$(mode_flag)" ]; then echo " with$(mode_flag)"; fi): nothing changes" \
    "Lines marked 'would' are what a real run does, read from the clusters as they are now. A real run checks again at each step, so what an earlier step removes is not removed twice."
fi
if ! preflight; then DIED=1; exit 1; fi
if [ "$DRY" = 0 ]; then
  confirm "Remove what the table marks remove, detach, turn off or reset, on $(cl "$ACTIVE"), $(cl "$PASSIVE"), $(cl "$MANAGED") and in git?"
fi
cmd_roles
cmd_demo
if [ "$RESET" = 0 ]; then
  cmd_detach
  cmd_storage
  cmd_acm
  cmd_gitops
fi
cmd_git
if [ "$DRY" = 1 ]; then
  stage "Summary" "Nothing changed: this was a dry run. The log has every 'would' line: ${LOGFILE/#$HOME/\~}"
  steps_end
  next="hack/teardown.sh$(mode_flag)"
  if [ "${DR_MENU:-0}" = 1 ]; then next="Teardown ($(if [ "$FULL" = 1 ]; then echo Full; else echo Reset; fi)) in the menu"; fi
  verdict ok "DRY RUN: nothing changed. To do what the 'would' lines name: $next"
else
  summary
fi
