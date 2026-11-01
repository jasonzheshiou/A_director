#!/usr/bin/env bash
# ===========================================================================
# host-reset.sh - the .59-side primitive: hand the GPU over from whatever holds
# it, PROVE the memory came back, then start one named host.
# Kept in the video_generation repo (bin/host-reset.sh), installed at ~/host-reset.sh.
#
#   host-reset.sh status          containers, units, servers, memory   (no change)
#   host-reset.sh stop            release everything, verify, start nothing
#   host-reset.sh abl | stock     release everything, start that Flash-Next
#   host-reset.sh video           release everything, start the MiniMax H3 node
#   host-reset.sh ... --dry-run   print every action, change nothing
#   host-reset.sh ... --force     also TERM/KILL host servers no container owns
#
# Three rules, all learned the hard way on this box:
#
#  1. Stop each container through whatever owns it. A systemd user unit is
#     stopped with systemctl - its ExecStop knows the right grace and the right
#     container. halogen/halogen-abl belong to their launchers instead, so they
#     are stopped AND removed after their log is saved: a launcher refuses to run
#     over a dead container of its own name, so "stopped" is not "released".
#     video-comfy / story-comfy / story-tts are only ever stopped: their units
#     start them with `podman start`, so removing one breaks the unit.
#  2. Nothing new starts until the GPU and RAM are measurably free. gtt_used and
#     MemAvailable are polled, not assumed - a container podman has forgotten can
#     still leave the AMD driver holding device memory, and that is how a box
#     ends up refusing a model it clearly has room for.
#  3. Cache reclaim needs root, and this account has no passwordless sudo. The
#     kernel is asked to drop caches only when `sudo -n` works; otherwise the
#     shortfall is reported rather than hidden.
# ===========================================================================
set -uo pipefail

PORT="${MODEL_PORT:-8080}"
SANDBOX="${VIDEO_SANDBOX:-$HOME/Video_Sandbox}"
SWAP="${SWAPPER:-$HOME/model-swap}"
TOGGLE="${TOGGLE:-$HOME/model-toggle}"

# containers owned by a launcher: stop + remove (a stale one blocks the launcher)
LAUNCHER_OWNED=(halogen halogen-abl)
# containers owned by a podman systemd unit: stop only (rm would break the unit)
UNIT_OWNED=(video-comfy story-comfy story-tts)
# every unit name that may be keeping one of those alive
UNITS=(video-comfy.service story-comfy.service story-tts.service)

GTT_MAX_GIB="${GTT_MAX_GIB:-2}"          # device memory tolerated when "released"
MEM_FLOOR_GIB="${MEM_FLOOR_GIB:-110}"    # RAM required before a 57 GiB model starts
RELEASE_TIMEOUT="${RELEASE_TIMEOUT:-120}"
START_TIMEOUT="${START_TIMEOUT:-300}"

DRY=0 FORCE=0 VERB=status
for a in "$@"; do
  case "$a" in
    status|stop|video|abl|abliterated|stock|halogen|flash) VERB="$a" ;;
    --dry-run|-n) DRY=1 ;;
    --force|-f)   FORCE=1 ;;
    --help|-h)    awk '/^# ={5,}/{f=!f;next} f{sub(/^# ?/,"");print}'; exit 0 ;;
    *) printf 'unknown argument: %s\n' "$a" >&2; exit 2 ;;
  esac
done
[[ $VERB == abliterated ]] && VERB=abl
[[ $VERB == halogen ]]     && VERB=stock

act() { if (( DRY )); then printf '  [dry-run] %s\n' "$*"; else eval "$@"; fi; }
die() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# ---- the measurements ------------------------------------------------------
gtt_gib()  { awk '{printf "%.1f", $1/1073741824}' /sys/class/drm/card0/device/mem_info_gtt_used 2>/dev/null || echo unknown; }
mem_gib()  { awk -v k="$1" '$1==k":"{printf "%.1f", $2/1048576}' /proc/meminfo 2>/dev/null || echo unknown; }
model_id() { curl -s -m 5 "http://127.0.0.1:$PORT/v1/models" 2>/dev/null \
             | tr -d '\n' | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4; }
unit_of()  { local u; for u in "${UNITS[@]}"; do [[ "${u%.service}" == "$1" ]] && { printf '%s' "$u"; return 0; }; done; return 1; }

# ---- status ----------------------------------------------------------------
show_status() {
  printf 'host      %s   :%s answers: %s\n' "$(hostname)" "$PORT" "${1:-$(model_id)}"
  printf 'gpu gtt   %s GiB used        ram free %s GiB      swap free %s GiB\n' \
    "$(gtt_gib)" "$(mem_gib MemAvailable)" "$(mem_gib SwapFree)"
  echo  "containers"
  podman ps -a --format '{{.Names}}\t{{.Status}}' 2>/dev/null | sed 's/^/  /'
  echo  "units"
  for u in "${UNITS[@]}"; do
    local st; st="$(systemctl --user is-active "$u" 2>/dev/null)"; [[ -z $st ]] && st=unknown
    printf '  %-22s %s\n' "$u" "$st"
  done
  echo  "host servers not inside a container"
  local found=0 pid cg
  for pid in $(pgrep -f 'llama-server|serve_api\.py' 2>/dev/null); do
    cg="$(awk -F: '$1=="0"{print $3}' "/proc/$pid/cgroup" 2>/dev/null)"
    [[ $cg == *podman* || $cg == *libpod* ]] && continue
    printf '  %s\n' "$(ps -o pid=,etimes=,rss=,cmd= -p "$pid" 2>/dev/null | awk '{printf "pid=%s age=%ss rss=%.1fGiB %s", $1,$2,$3/1048576,$4}')"; found=1
  done
  (( found )) || echo "  (none)"
}

# ---- releasing -------------------------------------------------------------
# Stop one container the way its owner expects, and only call it released once
# the process is gone. Returns non-zero if podman had to escalate to SIGKILL.
release_container() {
  local c="$1" unit rc=0
  podman ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$c" || { echo "  $c: absent"; return 0; }
  if [[ " ${LAUNCHER_OWNED[*]} " == *" $c "* ]]; then
    act "mkdir -p ~/.local/state/vgen && podman logs $c > ~/.local/state/vgen/$c.\$(date +%s).log 2>&1"
    act "podman stop -t 60 $c"                        # the launcher refuses to reuse it
    act "podman rm -f $c >/dev/null 2>&1"
  elif unit="$(unit_of "$c")"; then
    act "systemctl --user stop $unit"                 # ExecStop owns the grace period
  else
    act "podman stop -t 60 $c"
  fi
  if (( ! DRY )); then
    podman ps --format '{{.Names}}' 2>/dev/null | grep -qx "$c" && { echo "  $c: STILL RUNNING"; rc=1; } \
      || echo "  $c: stopped"
  fi
  return $rc
}

stop_everything() {
  local n=0
  for u in "${UNITS[@]}"; do
    [[ "$(systemctl --user is-active "$u" 2>/dev/null)" == active ]] && { act "systemctl --user stop $u"; n=1; }
  done
  local c
  for c in $(podman ps --format '{{.Names}}' 2>/dev/null); do
    release_container "$c" || true
  done
  # anything the container set did not cover (a bare llama-server, say)
  local pid cg found=0
  for pid in $(pgrep -f 'llama-server|serve_api\.py' 2>/dev/null); do
    cg="$(awk -F: '$1=="0"{print $3}' "/proc/$pid/cgroup" 2>/dev/null)"
    [[ $cg == *podman* || $cg == *libpod* ]] && continue
    found=1
    if (( FORCE )); then
      act "kill $pid; sleep 2; kill -0 $pid 2>/dev/null && kill -9 $pid; true"
      echo "  pid $pid terminated"
    else
      echo "  pid $pid ($(ps -o cmd= -p "$pid" 2>/dev/null | cut -c1-60)) is a host process, not a container"
      echo "        not killed without --force: stopping someone else's server is not this script's call"
    fi
  done
  (( found && ! FORCE && ! DRY )) && echo "        (use --force to include it in the release)"
  return 0
}

# Poll until the machine provably has room, then say so in the log.
verify_released() {
  local want="${1:-$MEM_FLOOR_GIB}" t0 g a
  (( DRY )) && { printf '  [dry-run] wait for gtt<=%sGiB and MemAvailable>=%sGiB\n' "$GTT_MAX_GIB" "$want"; return 0; }
  t0="$(date +%s)"
  while :; do
    g="$(gtt_gib)"; a="$(mem_gib MemAvailable)"
    [[ $g == unknown || $a == unknown ]] && { echo "  cannot read gtt/MemAvailable on this host"; return 1; }
    if awk -v g="$g" -v gm="$GTT_MAX_GIB" -v a="$a" -v am="$want" 'BEGIN{exit !(g+0<=gm+0 && a+0>=am+0)}'; then
      echo "  released: gtt ${g} GiB (limit ${GTT_MAX_GIB}), MemAvailable ${a} GiB (floor ${want}) in $(( $(date +%s) - t0 ))s"
      return 0
    fi
    if (( $(date +%s) - t0 > RELEASE_TIMEOUT )); then
      echo "  NOT released after ${RELEASE_TIMEOUT}s: gtt ${g} GiB, MemAvailable ${a} GiB (floor ${want})"
      if sudo -n true 2>/dev/null; then
        echo "  attempting cache reclaim (sudo -n available)"; sudo -n sync && echo 3 | sudo -n tee /proc/sys/vm/drop_caches >/dev/null 2>&1
        g="$(gtt_gib)"; a="$(mem_gib MemAvailable)"; echo "  after drop_caches: gtt ${g} GiB, MemAvailable ${a} GiB"
        awk -v g="$g" -v gm="$GTT_MAX_GIB" -v a="$a" -v am="$want" 'BEGIN{exit !(g+0<=gm+0 && a+0>=am+0)}' && return 0
      else
        echo "  no passwordless sudo: cannot drop caches from here. Run in a terminal:"
        echo "    sudo sync && sudo sysctl -w vm.drop_caches=3"
      fi
      return 1
    fi
    sleep 3
  done
}

# ---- starting --------------------------------------------------------------
expect_id() { case "$1" in abl) printf 'Abliterated' ;; stock) printf 'Flash-Next' ;; esac; }

start_host() {   # abl | stock -> launcher via model-toggle, then confirm the id
  local v="$1" cmd t0 got want
  if [[ -x "$TOGGLE" ]]; then cmd="$TOGGLE $v --force"
  elif [[ -x "$SWAP" ]]; then cmd="$SWAP to-$v"
  else die "neither $TOGGLE nor $SWAP is executable - cannot start $v"; fi
  act "$cmd"
  (( DRY )) && return 0
  t0="$(date +%s)"; want="$(expect_id "$v")"
  while :; do
    got="$(model_id)"
    [[ -n "$got" && "$got" == *"$want"* ]] && { echo "  answering on :$PORT as $got ($(( $(date +%s) - t0 ))s)"; return 0; }
    [[ -n "$got" ]] && die "started but answers as '$got', expected a model containing '$want'"
    (( $(date +%s) - t0 > START_TIMEOUT )) && die "no model id published on :$PORT within ${START_TIMEOUT}s"
    sleep 3
  done
}

start_video() {
  [[ -d "$SANDBOX" ]] || die "$SANDBOX not present - nothing to start"
  act "cd $SANDBOX && ./bin/video start"
}

# ---- main ------------------------------------------------------------------
[[ $VERB == status ]] && { show_status; exit 0; }

# Every mutating path releases first. That is the point of the script: an LLM
# cannot be started beside another LLM, and H3 cannot start beside either.
[[ -f /sys/class/drm/card0/device/mem_info_gtt_used ]] || die "no AMD GPU here - is this 192.0.2.59?"

case "$VERB" in
  stop)
    stop_everything
    verify_released || die "refusing to report success: memory was not fully released"
    ;;
  abl|stock)
    stop_everything
    verify_released || die "refusing to start an LLM while the previous one still holds memory"
    start_host "$VERB"
    ;;
  video)
    stop_everything
    # H3 needs ~57.5 GiB resident: the floor is checked before ComfyUI is started,
    # not after, so a stranded allocation cannot be mistaken for a slow render.
    verify_released || die "refusing to start the video node: the LLM's memory was not released"
    start_video
    ;;
esac
