#!/usr/bin/env bash
# publish-check.sh - refuse to publish anything private. Run before every push.
#
#   tools/publish-check.sh          check the tree
#   tools/publish-check.sh --fix    check, then show what would need changing
#
# This exists because the private working tree this folder is distilled from contains
# real LAN addresses, a personal ssh alias, a home path and an email address. A
# published repository cannot rely on memory to keep them out; it relies on this gate.
set -uo pipefail
cd "$(dirname "$(realpath "$0")")/.."

# pattern                 why it is forbidden
declare -a PATTERNS=(
  '192\.168\.[0-9]+\.[0-9]+'      # LAN addressing of the real hosts
  '100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]+\.[0-9]+'  # CGNAT / tailnet address
  '10\.[0-9]+\.[0-9]+\.[0-9]+'    # private-range addressing
  # the last two are written as char classes so they do not match their own source line
  'nucbox[-]ops'                  # personal ssh alias
  '/home/[a-z]'                   # a home path naming a real user
  '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'  # an email address
  'jasonzheshiou@g[m]ail'         # the account behind the git identity
)

fail=0
for p in "${PATTERNS[@]}"; do
  # -I skips binaries (the sample clip), -l lists files only
  hits="$(grep -rlIE "$p" --exclude-dir=.git . 2>/dev/null)"
  [[ -z $hits ]] && { printf '  ok    %s\n' "$p"; continue; }
  fail=1
  printf '  HIT   %s\n' "$p"
  printf '        %s\n' $hits
  grep -rnIE "$p" --exclude-dir=.git . 2>/dev/null | head -5 | sed 's/^/        /'
done

# Media policy: exactly one delivered clip; images only in assets/ (the inline README
# preview); no audio at all, because a stray .wav here could be the voice reference.
clips=$(find . -path ./.git -prune -o -type f \( -name '*.mp4' -o -name '*.mov' -o -name '*.mkv' \) -print)
audio=$(find . -path ./.git -prune -o -type f \( -name '*.wav' -o -name '*.mp3' -o -name '*.m4a' -o -name '*.flac' -o -name '*.ogg' \) -print)
loose=$(find . -path ./.git -prune -o -path ./assets -prune -o -type f \( -name '*.png' -o -name '*.jpg' -o -name '*.jpeg' -o -name '*.gif' -o -name '*.webp' \) -print)
n=$(printf '%s\n' "$clips" | grep -c .)
if (( n != 1 )); then
  fail=1; echo "  HIT   expected exactly one sample clip, found $n"; printf '%s\n' "$clips" | sed 's/^/        /'
else
  echo "  ok    exactly one sample clip"
fi
[[ -n $audio ]] && { fail=1; echo "  HIT   no audio may be published (voice-clone rights)"; printf '%s\n' "$audio" | sed 's/^/        /'; } || echo "  ok    no audio files"
[[ -n $loose ]] && { fail=1; echo "  HIT   image outside assets/"; printf '%s\n' "$loose" | sed 's/^/        /'; } || echo "  ok    images only in assets/"

# Anything over GitHub's hard 100 MB block?
big=$(find . -path ./.git -prune -o -type f -size +95M -print)
[[ -n $big ]] && { fail=1; echo "  HIT   file over GitHub's limit:"; echo "$big" | sed 's/^/        /'; } || echo "  ok    no file over 95 MB"

if (( fail )); then
  echo
  echo "publish-check: REFUSED - fix the hits above before pushing."
  exit 1
fi
echo
echo "publish-check: clean."
