#!/usr/bin/env bash
# Public scaffold and promotion regressions for the merged worker contract.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-brief-merge-contract)
home="$TMP_ROOT/home"
mkdir -p "$home/data" "$home/state"

for kind in ship scout; do
  if [ "$kind" = scout ]; then
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$kind" sample --scout >/dev/null || fail 'scout scaffold failed'
  else
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$kind" sample --mode no-mistakes >/dev/null || fail 'ship scaffold failed'
  fi
  brief="$home/data/$kind/brief.md"
  assert_grep 'echo "{state} [at=<epoch>]: {one short line}"' "$brief" 'worker status lost its timestamp'
  assert_grep 'date +%s' "$brief" 'worker cannot obtain the timestamp'
  assert_grep 'until <YYYY-MM-DDTHH:MMZ>' "$brief" 'worker lost its timed wait instructions'
  assert_grep 'your own validation round' "$brief" 'validation waits lost the pause contract'
  assert_grep 'must pass an explicit model' "$brief" 'worker lost the local model contract'
done
pass 'ship and scout scaffolds combine timestamped waits with the local model contract'

mkdir -p "$home/data/promoted" "$home/bin"
cat > "$home/data/promoted/brief.md" <<'EOF'
# Task
## Captain's intent
Preserve the original request.

## Firstmate spec
Retain the accepted constraint.

# Setup
This investigation procedure is obsolete after promotion.
EOF
printf 'window=fm-promoted\nkind=scout\nworktree=/tmp/unused\n' > "$home/state/promoted.meta"
printf '#!/usr/bin/env bash\nexit 0\n' > "$home/bin/fm-send.sh"
chmod +x "$home/bin/fm-send.sh"
FM_SPAWN_NO_GUARD=1 FM_HOME="$home" "$ROOT/bin/fm-promote.sh" promoted --mode no-mistakes --yolo off >/dev/null || fail 'promotion failed'
brief="$home/data/promoted/ship-instructions.md"
[ "$(grep -cx '## Firstmate spec' "$brief")" = 1 ] || fail 'promotion generated duplicate current spec headings'
assert_grep 'Retain the accepted constraint.' "$brief" 'promotion dropped the accepted constraint'
assert_no_grep 'as investigation context, not captain intent' "$brief" 'promotion demoted accepted requirements'
assert_no_grep 'This investigation procedure is obsolete' "$brief" 'promotion copied obsolete setup'
assert_grep 'preserve the existing' "$brief" 'promotion lost safe relaunch instructions'
pass 'promotion preserves accepted requirements under one current spec heading'
