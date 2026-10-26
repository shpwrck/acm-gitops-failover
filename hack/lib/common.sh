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
C_B="" C_DIM="" C_OFF="" C_OK="" C_BAD="" C_WARN="" C_ACC="" C_CL=""
if [ "$UI" = gum ]; then
  C_B=$'\e[1m' C_DIM=$'\e[2m' C_OFF=$'\e[0m' C_OK=$'\e[92m' C_BAD=$'\e[91m' C_WARN=$'\e[33m' C_ACC=$'\e[95m' C_CL=$'\e[1;96m'
fi
exec 3>/dev/null

# Cluster names: a message marks each one with cl, and paint shows it bold
# and in its own color. The log and plain output get the bare name.
CL_ON=$'\x1e' CL_OFF=$'\x1f'
cl() { printf '%s%s%s' "$CL_ON" "$1" "$CL_OFF"; }   # cl <context>: a cluster name in a message
bare() { printf '%s' "${1//[$CL_ON$CL_OFF]/}"; }   # bare <text>: the text without the marks
paint() {   # paint <text> [style]: the marked names in C_CL, each followed by <style>, the text's own
  local s=$1
  if [ "$UI" != gum ]; then bare "$s"; return 0; fi
  s=${s//$CL_ON/$C_CL}
  printf '%s' "${s//$CL_OFF/$C_OFF${2:-}}"
}

now() { date -u +%FT%TZ; }
# Spacing: a blank line wherever description text meets live output (checks, waits, tables), in
# either direction, and never two in a row. LAST is what the screen's last line is: blank, top (of
# an empty window), heading (a heading or a box), text (description) or live (output)
LAST=top
blank() { if [ "$LAST" != blank ]; then echo; LAST=blank; fi; }
kind() {   # kind text|live: a line of that kind comes next; after one of the other kind, a blank line first
  if { [ "$LAST" = text ] && [ "$1" = live ]; } || { [ "$LAST" = live ] && [ "$1" = text ]; }; then echo; fi
  LAST=$1
}
logln() { local l; for l in "$@"; do printf '%s\n' "${l//[$CL_ON$CL_OFF]/}"; done >&3; }
line() { kind live; printf '%s\n' "$(paint "$*")"; logln "$*"; }
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
  local border=$1 color=$2 title=$3 l w lines=()
  shift 3
  logln "" "== $title"
  for l in "$@"; do logln "   $l"; done
  if [ "$UI" = gum ]; then
    w=$(cols)
    w=$((w > 80 ? 76 : w - 4))
    for l in "$@"; do lines+=("$(paint "$l")"); done
    blank
    printf '%s\n' "$(gumc style --border "$border" --border-foreground "$color" --padding '0 2' --margin '0 1' --width "$w" -- \
      "$(gumc style --bold --foreground "$color" -- "$(paint "$title" $'\e[1;38;5;'"$color"m)")" ${lines[@]+"${lines[@]}"})"
  else
    blank
    printf '== %s\n' "$(bare "$title")"
    for l in "$@"; do bare "$l" | fold -s -w 76 | sed 's/ *$//; s/^/   /'; echo; done
  fi
  LAST=heading
}
intro() {   # intro <title> [line...]: what the script does, above its menu; all three scripts open this way
  box rounded 13 "$@"
}
your_turn() {   # your_turn <what> [line...]: something only you can do; the bell calls you back
  box double 3 "YOUR TURN: $1" "${@:2}"
  if [ "$UI" = gum ]; then printf '\a'; fi
}
say() {
  HELP_SHOWN=""
  logln "" "== $*"
  pin_draw
  blank
  if [ "$UI" = gum ]; then printf ' %s▍%s%s%s\n' "$C_ACC" "$C_B" "$(paint "$*" "$C_ACC$C_B")" "$C_OFF"; else printf '== %s\n' "$(bare "$*")"; fi
  LAST=heading
}
mark() {   # mark <plain tag> <gum mark> <text>
  logln "   $1 $3"
  kind live
  if [ "$UI" = gum ]; then printf '   %s %s\n' "$2" "$(paint "$3")"; else printf '   %s %s\n' "$1" "$(bare "$3")"; fi
}
BAD=0 RED_LIST=()
ok() { SEC_OK=$((SEC_OK + 1)); mark "ok   " "${C_OK}✓${C_OFF}" "$*"; }
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
  BAD=1 RED_LIST+=("$*") SEC_RED=$((SEC_RED + 1))
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
note() { SEC_NOTE=$((SEC_NOTE + 1)); mark "note " "${C_WARN}•${C_OFF}" "$*"; }
label() { logln "   $*"; kind live; printf '   %s%s%s\n' "$C_B" "$(paint "$*" "$C_B")" "$C_OFF"; }
explain() {   # explain <text>: what a step does and why, wrapped under its heading
  local w
  w=$(cols)
  w=$((w > 84 ? 76 : w - 8))
  logln "$(bare "$*" | fold -s -w 76 | sed 's/ *$//; s/^/   /')"
  kind text
  paint "$(printf '%s\n' "$*" | fold -s -w "$w" | sed 's/ *$//; s/^/   /')"
  echo
}
finished() {   # finished <text>: a step that went through
  logln "   $*"
  kind live
  if [ "$UI" = gum ]; then printf '   %s✓%s %s%s%s\n' "$C_OK" "$C_OFF" "$C_DIM" "$(paint "$*" "$C_DIM")" "$C_OFF"; else echo "   $(bare "$*")"; fi
}
verdict() {   # verdict ok|bad <text>
  local color=9
  if [ "$1" = ok ]; then color=10; fi
  logln "" "$2"
  blank
  if [ "$UI" = gum ]; then
    printf '%s\n' "$(gumc style --border rounded --border-foreground "$color" --foreground "$color" --bold --padding '0 1' --margin '0 1' -- \
      "$(paint "$2" $'\e[1;38;5;'"$color"m)")"
  else
    printf '%s\n' "$(bare "$2")"
  fi
  LAST=heading
}
show() {   # show [command...]: its output (or stdin), indented and dim, on the screen and in the log
  local out rc=0 l
  if [ $# -gt 0 ]; then out=$("$@" 2>&1) || rc=$?; else out=$(cat); fi
  if [ -n "$out" ]; then
    kind live
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
  bare "$rows" | align >&3
  kind live
  if [ "$UI" = gum ]; then
    rows=$(paint "$rows")
    # gum 0.17's --print leaves the header plain (and bolds the first row), so the header is colored here
    rows=$(awk -F'\t' -v OFS='\t' -v a="$C_B$C_ACC" -v z="$C_OFF" 'NR == 1 { for (i = 1; i <= NF; i++) $i = a $i z } 1' <<<"$rows")
    printf '%s\n' "$(gumc table --print --separator $'\t' --border rounded --border.foreground 8 --selected.foreground '' \
      --lazy-quotes <<<"$rows" | sed 's/^/  /')"
  else
    bare "$rows" | align
  fi
}

# Sections of checks: with gum, a section whose checks are all green
# collapses to its heading, a ✓ and what it found; one with a RED line or
# a note shows in full. The log gets every line either way.
SEC=0 SEC_H="" SEC_FILE="" SEC_OK=0 SEC_RED=0 SEC_NOTE=0 SEC_LAST="" SEC_KIND=""
sec_begin() {   # sec_begin <heading>: a section of checks, held back until sec_end
  if [ "$UI" != gum ]; then say "$1"; return 0; fi
  SEC=1 SEC_H=$1 SEC_OK=0 SEC_RED=0 SEC_NOTE=0
  SEC_FILE=$(mktemp) SEC_KIND=$LAST   # the screen's last line, for when the section shrinks to one
  exec 5>&1 1>"$SEC_FILE"
  say "$1"
}
sec_end() {   # sec_end <what was found>: the section in full, or one line when it is all green
  local h w
  if [ "$SEC" != 1 ]; then return 0; fi
  exec 1>&5 5>&-
  SEC=0
  if [ $((SEC_RED + SEC_NOTE)) -gt 0 ] || [ "$SEC_OK" = 0 ]; then
    cat "$SEC_FILE"
    SEC_LAST=full
  else
    LAST=$SEC_KIND
    if [ "$SEC_LAST" != line ]; then blank; fi   # a run of one-line sections starts after a blank line
    SEC_LAST=line
    h=$(bare "$SEC_H")
    w=$(($(cols) - ${#h} - 8))
    printf ' %s▍%s%s%s %s✓%s' "$C_ACC" "$C_B" "$(paint "$SEC_H" "$C_ACC$C_B")" "$C_OFF" "$C_OK" "$C_OFF"
    if [ -n "${1:-}" ] && [ "$w" -ge 12 ]; then printf ' %s%s%s' "$C_DIM" "$(fit "$w" "$1" "$C_DIM")" "$C_OFF"; fi
    echo
    LAST=live
  fi
  rm -f "$SEC_FILE"
}
sec_flush() { if [ "$SEC" = 1 ]; then SEC_RED=1; sec_end; fi; }   # a stop inside a section shows all of it

DIED=0
die() {
  spin_stop
  sec_flush
  pin_off
  DIED=1
  box thick 9 "STOP" "$*" ${LOGFILE:+"" "Log: $LOGFILE"}
  exit 1
}
gum_stop() {   # gum_stop <gum's exit status> [when]: Ctrl-C at a question interrupts the script; Esc or No stops it at your request
  case $1 in
    0) ;;
    130) exit 130 ;;
    *) die "stopped at your request${2:+, $2}" ;;
  esac
}
confirm() {
  [ "$YES" = 1 ] && return 0
  local answer="" rc=0
  if [ "$UI" = gum ]; then
    blank
    gum confirm --default=false "$(paint "$1")" </dev/tty >/dev/tty 2>/dev/tty || rc=$?
    if [ "$rc" = 0 ]; then
      finished "$1 yes"
      return 0
    fi
    logln "$1 no"
    gum_stop "$rc"
  fi
  read -r -p "$(bare "$1") [y/N] " answer </dev/tty || true
  logln "$1 [y/N] $answer"
  [ "$answer" = y ] || [ "$answer" = Y ] || die "stopped at your request"
}
PAUSED=0   # seconds spent at go_on's prompt
go_on() {   # go_on <next stage>: wait for Continue before the next stage clears the window (not with --yes, or without a terminal)
  local t0=$SECONDS answer=""
  if [ "${YES:-0}" = 1 ] || ! { : </dev/tty; } 2>/dev/null; then return 0; fi
  logln "" "-- next: $1"
  if [ "$UI" = gum ]; then
    blank
    gum choose --header "Next: $(paint "$1")" Continue </dev/tty >/dev/null 2>/dev/tty || gum_stop "$?" "before $1"
  else
    read -r -p "Next: $(bare "$1"). Press Enter to continue " answer </dev/tty || true
  fi
  PAUSED=$((PAUSED + SECONDS - t0))
  logln "   continued after $(dur $((SECONDS - t0)))"
}

# The menu: with no options on a terminal, each script opens on its menu. A pick
# runs as a new process of the script (DR_MENU=1), with its own settings, log
# and screen. When it ends, done or stopped, "Back to the menu" starts the
# script afresh, so the settings are read again. Only Quit leaves, or Ctrl-C.
menu_run() {   # menu_run [option...]: the script with those options, then the menu again
  local rc=0 int=0
  trap 'int=1' INT   # Ctrl-C reaches both; however the pick ends, it leaves the menu too
  DR_MENU=1 bash "$SELF" "$@" || rc=$?
  trap - INT
  if [ "$rc" = 130 ] || [ "$int" = 1 ]; then DIED=1; exit 130; fi
  echo
  rc=0
  if [ "$UI" = gum ]; then
    gum choose --header "" "Back to the menu" </dev/tty >/dev/null 2>/dev/tty || rc=$?
  else
    read -r -p "Press Enter for the menu " </dev/tty || rc=130
  fi
  if [ "$rc" = 130 ]; then DIED=1; exit 130; fi
  menu_again
}
menu_again() { exec env -u DR_MENU bash "$SELF"; }   # the menu from the start: a clear screen, the settings read again

# The spinner: one status line, redrawn ten times a second while the script
# waits. Checks run in the background so it keeps turning.
SPIN="" SPIN_SHOW="" SPIN_T0=0 SPIN_N=0 SPIN_W=60 POLL_PID=""
FRAMES=(⣾ ⣽ ⣻ ⢿ ⡿ ⣟ ⣯ ⣷)
spin_begin() {   # spin_begin <title>
  spin_stop
  logln "   $1"
  kind live
  if [ "$UI" = gum ]; then
    SPIN=$1 SPIN_T0=$SECONDS SPIN_W=$(($(cols) - 14))
    if [ "$SPIN_W" -lt 20 ]; then SPIN_W=20; fi
    SPIN_SHOW=$(fit "$SPIN_W" "$1" "" cut)
    printf '\e[?25l'
    spin_draw
  else
    echo "   $(bare "$1")"
  fi
}
spin_draw() {
  local e=$((SECONDS - SPIN_T0))
  SPIN_N=$(((SPIN_N + 1) % ${#FRAMES[@]}))
  printf '\r\e[K   %s%s%s %s %s%d:%02d%s' "$C_ACC" "${FRAMES[SPIN_N]}" "$C_OFF" "$SPIN_SHOW" "$C_DIM" $((e / 60)) $((e % 60)) "$C_OFF"
  if [ "$PIN" = 1 ] && [ "$SECONDS" != "$PIN_AT" ]; then pin_draw; fi   # the header's clock and counters, once a second
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

start_screen() {   # with gum, a script starts on a clear screen (DR_CLEAR=0: not when another script runs it)
  if [ "$UI" = gum ] && [ "${DR_CLEAR:-1}" != 0 ]; then fresh_screen; fi
}
fresh_screen() {   # scroll what the screen shows into the scrollback, then write from the top
  local rows
  rows=$(stty size 2>/dev/null </dev/tty) || rows=""
  rows=${rows%% *}
  if ! [[ $rows =~ ^[0-9]+$ ]] || [ "$rows" -lt 1 ]; then rows=50; fi
  printf '%*s' "$rows" '' | tr ' ' '\n'
  printf '\e[H'
  LAST=top
}

# The pinned header: with gum, on a terminal of at least 72 columns and
# <rows> + 16 lines, the top <rows> lines stay put and show what <draw>
# prints, and the output scrolls under them. What scrolls off the top of
# that part is gone from the screen (the log keeps it). DR_PIN=0 turns it off.
PIN=0 PIN_H=0 PIN_DRAW="" PIN_AT=-1 PIN_ROWS=0 PIN_COLS=80
term_rows() {   # the terminal's height; 0 when it does not say
  local s
  s=$(stty size 2>/dev/null </dev/tty) || s=""
  s=${s%% *}
  if [[ $s =~ ^[0-9]+$ ]]; then echo "$s"; else echo 0; fi
}
pin_fits() { PIN_ROWS=$(term_rows) PIN_COLS=$(cols); [ "$PIN_ROWS" -ge $((PIN_H + 16)) ] && [ "$PIN_COLS" -ge 72 ]; }
pin_on() {   # pin_on <rows> <draw function>: pin the header, and start the output under it on an empty screen
  if [ "$UI" != gum ] || [ "${DR_PIN:-1}" = 0 ] || [ "$PIN" = 1 ]; then return 0; fi
  PIN_H=$1 PIN_DRAW=$2
  if ! pin_fits; then
    note "the terminal is ${PIN_COLS}x$PIN_ROWS; the progress header needs 72x$((PIN_H + 16)) or more, so the output scrolls instead"
    return 0
  fi
  PIN=1
  fresh_screen
  printf '\e[%d;%dr' $((PIN_H + 1)) "$PIN_ROWS"   # the scrolling region: everything under the header
  pin_clear
  trap pin_resize WINCH
}
pin_clear() {   # empty the part under the header, and write from its top
  if [ "$PIN" = 1 ]; then printf '\e[%d;1H\e[J' $((PIN_H + 1)); LAST=top; pin_draw; fi
}
pin_draw() {   # redraw the header; the cursor stays where the output is
  local out l i=0 s=$'\e7'
  if [ "$PIN" != 1 ]; then return 0; fi
  PIN_AT=$SECONDS
  out=$("$PIN_DRAW" "$((PIN_COLS - 1))" 2>/dev/null) || true
  while IFS= read -r l && [ "$i" -lt "$PIN_H" ]; do
    i=$((i + 1))
    s+=$'\e['"$i"$';1H\e[2K'"$l"
  done <<<"$out"
  while [ "$i" -lt "$PIN_H" ]; do i=$((i + 1)); s+=$'\e['"$i"$';1H\e[2K'; done
  if [ "$SEC" = 1 ]; then printf '%s\e8' "$s" >&5; else printf '%s\e8' "$s"; fi   # past a held-back section, to the screen
}
pin_resize() {   # a new terminal size: a new scrolling region, or no header if it no longer fits
  if [ "$PIN" != 1 ]; then return 0; fi
  if ! pin_fits; then pin_off; return 0; fi
  printf '\e[%d;%dr\e[%d;1H' $((PIN_H + 1)) "$PIN_ROWS" "$PIN_ROWS"
  pin_draw
}
pin_off() {   # the whole screen scrolls again; the header stays on it as last drawn
  if [ "$PIN" != 1 ]; then return 0; fi
  PIN=0
  trap - WINCH
  printf '\e7\e[r\e8'   # resetting the region homes the cursor, so it is saved around that
}
crumbs() {   # crumbs <n> [width]: the stages in STAGES, done, current and to come; wrapped at <width>
  local i t len=0 s=""
  # shellcheck disable=SC2153 # each script sets STAGES
  for i in "${!STAGES[@]}"; do
    t=${STAGES[i]}
    if [ "$i" -gt 0 ]; then
      if [ $((len + 5 + ${#t})) -gt "${2:-999}" ]; then s+=$'\n' len=0; else s+="${C_DIM} › ${C_OFF}" len=$((len + 3)); fi
    fi
    if [ "$i" -lt $(($1 - 1)) ]; then
      s+="${C_OK}✓ $t${C_OFF}"
    elif [ "$i" = $(($1 - 1)) ]; then
      s+="${C_B}${C_ACC}● $t${C_OFF}"
    else
      s+="${C_DIM}○ $t${C_OFF}"
    fi
    len=$((len + 2 + ${#t}))
  done
  printf '%s' "$s"
}
STEPS_TITLE=""
steps_header() {   # steps_header <width>: build.sh's and teardown.sh's pinned lines: what runs and for how long, and the stages
  local w=$(($1 > 80 ? 78 : $1)) rule fill l n=0
  rule="── $STEPS_TITLE · $(dur $((SECONDS - T0))) "
  l=$(bare "$rule")
  printf -v fill '%*s' $((w - ${#l} > 0 ? w - ${#l} : 0)) ''
  printf ' %s%s%s\n' "$C_DIM" "$(paint "$rule${fill// /─}" "$C_DIM")" "$C_OFF"
  while IFS= read -r l; do printf ' %s\n' "$l"; n=$((n + 1)); done <<<"$(crumbs "$STAGE" $((w - 1)))"
  while [ "$n" -lt $((PIN_H - 2)) ]; do echo; n=$((n + 1)); done
  printf -v fill '%*s' "$w" ''
  printf ' %s%s%s\n' "$C_DIM" "${fill// /─}" "$C_OFF"
}
steps_pin() {   # pin steps_header, as tall as the stages need at this width
  local w=$(($(cols) - 1))
  w=$((w > 80 ? 78 : w))
  pin_on $(($(crumbs 1 $((w - 1)) | grep -c '') + 2)) steps_header
}
stage_name() {   # stage_name <n> <title>: the title; "Stage <n>/<all>: <title>" when no header shows where the stage stands
  if [ "$PIN" = 1 ] || [ "${#STAGES[@]}" -le 1 ]; then printf '%s' "$2"; else printf 'Stage %d/%d: %s' "$1" "${#STAGES[@]}" "$2"; fi
}
steps_end() {   # every stage ticked in the header
  STAGE=$((${#STAGES[@]} + 1))
  pin_draw
}
fit() {   # fit <width> <text> [style] [cut]: the text, its names painted (then <style>); if longer, cut bare, with an ellipsis unless [cut]
  local b
  b=$(bare "$2")
  if [ "${#b}" -le "$1" ]; then paint "$2" "${3:-}"
  elif [ $# -ge 4 ]; then printf '%s' "${b:0:$1}"
  else printf '%s…' "${b:0:$(($1 - 1))}"; fi
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

# The ACM agent (klusterlet) on a cluster: another hub's, or the cluster's own as a hub (local-cluster)
klusterlet_hub() {   # klusterlet_hub <context>: the API of the hub its klusterlet reports to, or nothing
  local s
  for s in hub-kubeconfig-secret bootstrap-hub-kubeconfig; do
    oc --context "$1" get secret "$s" -n open-cluster-management-agent -o jsonpath='{.data.kubeconfig}' 2>/dev/null |
      base64 -d 2>/dev/null | awk '/server:/ {print $2; exit}' | grep . && return 0
  done
  return 0
}
self_agent() {   # self_agent <context>: its klusterlet reports to the cluster itself: a hub's own agent for local-cluster
  local h
  if [ "$(oc --context "$1" get klusterlets.operator.open-cluster-management.io klusterlet -o jsonpath='{.spec.clusterName}' 2>/dev/null)" = local-cluster ]; then
    return 0
  fi
  h=$(klusterlet_hub "$1")
  case $h in https://kubernetes.default.svc*) return 0 ;; esac
  [ -n "$h" ] && [ "${h%/}" = "$(server "$1")" ]
}
orphan_agent() {   # orphan_agent <context>: the cluster's own agent with no hub left on it, as an ACM uninstall can leave it
  { some "$1" klusterlets.operator.open-cluster-management.io klusterlet || some "$1" ns open-cluster-management-agent; } &&
    self_agent "$1" && ! some "$1" multiclusterhubs.operator.open-cluster-management.io -A &&
    ! some "$1" multiclusterengines.multicluster.openshift.io
}

repo_url() { git remote get-url origin | sed -e 's#^git@github.com:#https://github.com/#' -e 's#^ssh://git@github.com/#https://github.com/#' -e 's#\.git$##'; }
git_role() {   # git_role <hub>: active, passive or something else, as dr/<hub> lists it on origin/$BRANCH
  local k
  k=$(git show "origin/$BRANCH:dr/$1/kustomization.yaml" 2>/dev/null | sed -n 's/^  - //p' | paste -sd' ' -)
  case $k in
    ../roles/active) echo active ;;
    ../roles/passive) echo passive ;;
    "../roles/active restore-activate-"*) echo "active with ${k#../roles/active }" ;;   # promoted by a git-driven failover
    "") echo missing ;;
    *) echo "'$k'" ;;
  esac
}
