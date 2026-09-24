#!/usr/bin/env bash
# Real idle Codex composer frames through the shared composer classifier.
# Codex 0.155.1 on Herdr 0.8.2, captured 2026-09-24 with the Herdr adapter's own
# ANSI read (pane read --source recent --format ansi, last rows).
# The animation can leave the prompt row without any braille cell while the
# rows around it still carry bright cells; the doorbell must still ring there.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-composer-lib.sh"

ESC=$(printf '\033')
CAPS_TMUX=$'styled=1\ncursor=1\nidentity=1\nrows=0'
CAPS_STYLED=$'styled=1\ncursor=0\nidentity=1\nrows=20'      # herdr
CAPS_STYLED_NOID=$'styled=1\ncursor=0\nidentity=0\nrows=20' # zellij
CAPS_PLAIN=$'styled=0\ncursor=0\nidentity=0\nrows=20'       # cmux, orca

# assert_screen <label> <want> <caps> <screen> [cursor] [identity]: one
# verdict, asserted under the ambient locale AND LC_ALL=C.
assert_screen() {
  local label=$1 want=$2 out
  shift 2
  out=$(fm_composer_classify_screen "$@")
  [ "$out" = "$want" ] || fail "$label: expected $want, got '$out'"
  out=$(LC_ALL=C fm_composer_classify_screen "$@")
  [ "$out" = "$want" ] || fail "$label under LC_ALL=C: expected $want, got '$out'"
}

# Live frames: no animation cell on the prompt row, bright cells below it.
FRAME_NO_CELL_BELOW=$'\033[0m\033[48;2;61;59;78m                             \033[0m\r\n\033[0m\033[1m\033[48;2;61;59;78m›\033[0m\033[48;2;61;59;78m \033[0m\033[2m\033[48;2;61;59;78mAsk Codex to do anything\033[0m\033[48;2;61;59;78m   \033[0m\r\n\033[0m\033[48;2;61;59;78m        \033[0m\033[38;2;137;135;156m\033[48;2;61;59;78m⠐\033[0m\033[48;2;61;59;78m        \033[0m\033[38;2;149;147;168m\033[48;2;61;59;78m⠄\033[0m\033[48;2;61;59;78m           \033[0m\r\n  \033[0m\033[2mgpt-6-astra xhigh · 1.63M …\033[0m'
FRAME_NO_CELL_AROUND=$'\033[0m\033[48;2;61;59;78m    \033[0m\033[38;2;101;99;119m\033[48;2;61;59;78m⠈\033[0m\033[48;2;61;59;78m                        \033[0m\r\n\033[0m\033[1m\033[48;2;61;59;78m›\033[0m\033[48;2;61;59;78m \033[0m\033[2m\033[48;2;61;59;78mAsk Codex to do anything\033[0m\033[48;2;61;59;78m   \033[0m\r\n\033[0m\033[48;2;61;59;78m                    \033[0m\033[38;2;143;141;162m\033[48;2;61;59;78m⠠\033[0m\033[48;2;61;59;78m        \033[0m\r\n  \033[0m\033[2mgpt-6-astra xhigh · 1.63M …\033[0m'
# Frames saved after the skipped doorbells of 2026-09-24 (prompt-row cells present).
FRAME_SAVED_CONTEXT=$'\033[0m\033[48;2;61;59;78m    \033[0m\033[38;2;107;105;125m\033[48;2;61;59;78m⠈\033[0m\033[48;2;61;59;78m                    \033[0m\033[38;2;68;66;86m\033[48;2;61;59;78m⢀\033[0m\033[48;2;61;59;78m  \033[0m\033[38;2;83;81;101m\033[48;2;61;59;78m⠈\033[0m\033[48;2;61;59;78m               \033[0m\r\n\033[0m\033[1m\033[48;2;61;59;78m›\033[0m\033[48;2;61;59;78m \033[0m\033[2m\033[48;2;61;59;78mAsk Codex to do anything\033[0m\033[38;2;150;148;168m\033[48;2;61;59;78m⡀\033[0m\033[48;2;61;59;78m        \033[0m\033[38;2;72;70;89m\033[48;2;61;59;78m⠈\033[0m\033[48;2;61;59;78m \033[0m\033[38;2;137;135;156m\033[48;2;61;59;78m⠂\033[0m\033[48;2;61;59;78m  \033[0m\033[38;2;119;117;137m\033[48;2;61;59;78m⠁\033[0m\033[48;2;61;59;78m   \033[0m\r\n\033[0m\033[48;2;61;59;78m      \033[0m\033[38;2;132;130;150m\033[48;2;61;59;78m⠠\033[0m\033[48;2;61;59;78m \033[0m\033[38;2;150;148;169m\033[48;2;61;59;78m⠐\033[0m\033[48;2;61;59;78m        \033[0m\033[38;2;86;84;104m\033[48;2;61;59;78m⠄\033[0m\033[48;2;61;59;78m        \033[0m\033[38;2;150;148;169m\033[48;2;61;59;78m⠄\033[0m\033[48;2;61;59;78m         \033[0m\033[38;2;99;97;117m\033[48;2;61;59;78m⠠\033[0m\033[48;2;61;59;78m       \033[0m\r\n  \033[0m\033[2mgpt-6-astra xhigh · 295K used · Context 1…\033[0m'
FRAME_SAVED_USAGE=$'\033[0m\033[48;2;61;59;78m                             \033[0m\r\n\033[0m\033[1m\033[48;2;61;59;78m›\033[0m\033[48;2;61;59;78m \033[0m\033[2m\033[48;2;61;59;78mAsk Codex to do anything\033[0m\033[38;2;96;94;113m\033[48;2;61;59;78m⡀\033[0m\033[48;2;61;59;78m  \033[0m\r\n\033[0m\033[48;2;61;59;78m                          \033[0m\033[38;2;128;126;147m\033[48;2;61;59;78m⠄\033[0m\033[48;2;61;59;78m  \033[0m\r\n  \033[0m\033[2mgpt-6-astra xhigh · 1.36M …\033[0m'

# assert_idle_frame <label> <screen>: an idle frame reads empty on every styled
# backend and keeps every refusal around it.
assert_idle_frame() {
  local label=$1 screen=$2 plain changed
  assert_screen "$label on Herdr" empty "$CAPS_STYLED" "$screen"
  assert_screen "$label on Zellij" empty "$CAPS_STYLED_NOID" "$screen"
  assert_screen "$label on tmux" empty "$CAPS_TMUX" "$screen" 1
  plain=$(printf '%s\n' "$screen" | fm_composer_strip_ansi)
  assert_screen "$label without styling" unknown "$CAPS_PLAIN" "$plain"
  changed=${screen/'Ask Codex to do anything'/"${ESC}[22mtyped draft"}
  assert_screen "$label with a typed draft" pending "$CAPS_STYLED" "$changed"
  changed=${screen/"${ESC}[2m${ESC}[48;2;61;59;78mAsk"/"${ESC}[22m${ESC}[48;2;61;59;78mfix Ask"}
  assert_screen "$label with typed text before the placeholder" pending "$CAPS_STYLED" "$changed"
  changed=${screen/"${ESC}[2mgpt-"/"${ESC}[0mgpt-"}
  assert_screen "$label with a bright footer-like row" pending "$CAPS_STYLED" "$changed"
  changed=${screen/›/❯}
  assert_screen "$label under a Claude glyph" pending "$CAPS_STYLED" "$changed"
}

test_codex_idle_frames_ring_the_doorbell() {
  assert_idle_frame "prompt row without animation cells" "$FRAME_NO_CELL_BELOW"
  assert_idle_frame "prompt row without cells between animated rows" "$FRAME_NO_CELL_AROUND"
  assert_idle_frame "saved frame with a context footer" "$FRAME_SAVED_CONTEXT"
  assert_idle_frame "saved frame with a usage footer" "$FRAME_SAVED_USAGE"
  pass "real idle Codex frames read empty, with or without prompt-row animation"
}

test_typed_text_on_an_animation_row_still_blocks() {
  local changed
  changed=${FRAME_NO_CELL_BELOW/⠐/x}
  assert_screen "bright text on the row below an idle prompt" pending "$CAPS_STYLED" "$changed"
  changed=${FRAME_NO_CELL_AROUND/⠠/⠠ more}
  assert_screen "wrapped text beside an animation cell" pending "$CAPS_STYLED" "$changed"
  pass "typed text below an idle Codex prompt still blocks the doorbell"
}

test_other_harness_typed_drafts_still_block() {
  assert_screen "Claude typed draft" pending "$CAPS_STYLED" $'❯ a real typed draft\n'
  assert_screen "Codex typed draft" pending "$CAPS_STYLED" $'› a real typed draft\n'
  assert_screen "Pi typed draft" pending "$CAPS_STYLED" \
    $'────────────────────\na real typed draft\n────────────────────' '' $'pi\tidle'
  pass "typed drafts in other harness composers still block the doorbell"
}

test_codex_idle_frames_ring_the_doorbell
test_typed_text_on_an_animation_row_still_blocks
test_other_harness_typed_drafts_still_block
