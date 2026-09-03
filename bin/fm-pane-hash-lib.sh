# shellcheck shell=bash
# Shared derivation of a pane capture's .hash-<key> marker.
# Usage: . bin/fm-pane-hash-lib.sh; pane_hash_content "<tail40>" | hash_pane
#
# ONE OWNER for that marker's value. bin/fm-watch.sh writes it on the stale
# path and reads it back on the turn-end churn path, and a second derivation
# on either side silently breaks the comparison: a raw read against a
# normalized write can never report an unchanged pane, so the opt-in churn
# absorb (config/turnend-churn-absorb) degrades into an unconditional defer.
# Every producer and consumer of the marker, tests included, composes it from
# the two functions here.

hash_pane() {
  if command -v md5 >/dev/null 2>&1; then md5 -q; else md5sum | cut -d' ' -f1; fi
}

# Volatile-footer normalization for staleness hashing. Harness TUIs redraw a
# footer with ticking elapsed-time/token counters and rotating spinner glyphs
# even while the agent sits idle, so hashing the raw capture makes every poll
# look like fresh activity followed by fresh staleness and the same parked pane
# re-fires stale wakes minutes apart. Collapse every digit run to a single 0
# and drop the known spinner glyph rotations (claude's pulse set, the braille
# spinner set, kimi's moon phases) before hashing, so a counter tick or spinner
# turn is not activity.
# A glyph this filter misses only restores the churny per-tick hash for that
# harness - it can never mask a real content change - so the list stays small
# and additive. LC_ALL=C keeps sed byte-oriented: the multibyte glyphs match as
# literal byte sequences and raw captures with non-UTF-8 bytes cannot error.
# The second, third and fourth expressions fold counter FORMAT transitions that
# digit collapsing alone leaves behind: an elapsed or countdown counter grows and
# sheds units ("59s" -> "1m 3s" -> "1h 2m 3s", "3h23m" -> "59m") and a token
# counter gains a decimal k suffix ("847" -> "3.4k"), each of which would
# otherwise change the hash once per rollover. The duration expression folds a
# whole run of zeroed unit tokens, with or without separating spaces, to one
# token, so no unit count survives the fold.
# The fifth expression folds a bracketed FILL BAR - the usage/progress meter
# claude renders beside its reset countdown ("[##--------]") and the same shape
# any TUI draws for a quota or download bar. It advances on its own schedule
# while the agent sits idle, and no digit or glyph rule reaches it because the
# bar carries its value in the ratio of its fill characters, not in a number.
# It is matched by SHAPE - a bracketed run of fill characters - not by any
# vendor's bar string, so a harness that draws the same meter with different
# glyphs folds too.
normalize_pane_volatiles() {
  LC_ALL=C sed -E \
    -e 's/[0-9]+/0/g' \
    -e 's/0(\.0)+/0/g' \
    -e 's/(0[hmsd][[:space:]]*)+/0s/g' \
    -e 's/0k/0/g' \
    -e 's/\[[#=+*.:_ -]{2,}\]/[]/g' \
    -e 's/✢|✳|✶|✻|✽|·//g' \
    -e 's/⠁|⠂|⠄|⡀|⢀|⠠|⠐|⠈|⠋|⠙|⠹|⠸|⠼|⠴|⠦|⠧|⠇|⠏//g' \
    -e 's/🌑|🌒|🌓|🌔|🌕|🌖|🌗|🌘//g'
}

# Lines of the captured tail treated as the harness footer. Every verified
# harness renders its counters and spinner there, and window_is_busy already
# reads the same bottom slice for its own indicator.
PANE_FOOTER_LINES=${FM_PANE_FOOTER_LINES:-6}

# Emit the hashing form of a captured tail: the footer normalized, everything
# above it byte-exact. The capture is passed through byte-for-byte otherwise,
# including a missing final newline, so the hash of an unchanged pane is the
# same value it was before this split existed.
# The split is the whole point. Digit collapsing over the WHOLE capture would
# fold real progress output too - "Ran 12 tests, 0 failed" and "Ran 15 tests,
# 3 failed" both become "Ran 0 tests, 0 failed", and a crew whose only visible
# progress is a counter would read as idle and be surfaced as stale while it
# worked. Confining the fold to the footer keeps the counter tick out of the
# hash without buying it at the cost of blinding the watcher to real output.
pane_hash_content() {  # <tail40>
  local body=$1 total head_n
  total=$(printf '%s' "$body" | grep -c '') || total=0
  head_n=$((total - PANE_FOOTER_LINES))
  if [ "$head_n" -le 0 ]; then
    printf '%s' "$body" | normalize_pane_volatiles
    return 0
  fi
  printf '%s' "$body" | head -n "$head_n"
  printf '%s' "$body" | tail -n "+$((head_n + 1))" | normalize_pane_volatiles
}
