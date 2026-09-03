#!/usr/bin/env bash
# tests/fm-test-base-path-guard.test.sh - the suite must not assume an FHS layout.
#
# Two distinct ways a fixture can hardcode where a tool lives, both of which
# broke real suites on this NixOS host, where /bin holds only sh and /usr/bin
# holds only env:
#
#   1. A restricted PATH built from a bare FHS tail, e.g.
#        BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
#      Nothing on that PATH resolves, so any subshell or `bash -c` built from
#      it dies with "command not found" before the assertions run.
#      tests/lib.sh's fm_test_core_path exists to be prepended here.
#   2. An absolute path to a tool that simply is not there, e.g. /bin/echo as a
#      registered argv, /bin/bash as a symlink target or shebang, /bin/cat in a
#      fake that must reach the real one. PATH cannot help: these bypass it.
#      tests/lib.sh's fm_test_tool resolves such a path instead.
#
# Both checks are structural sweeps over every suite rather than a snapshot of
# today's offenders, so a newly introduced instance fails here regardless of
# which file introduces it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SELF=fm-test-base-path-guard.test.sh

# restricted_path_hazards <file>: one line per restricted-PATH fallback that
# names an FHS system directory without prepending fm_test_core_path.
restricted_path_hazards() {
  perl -ne '
    next if /^\s*#/;
    next unless /(BASE_PATH|RUN_PATH|FM_TEST_BASE_PATH)/;
    next unless m{(/usr/bin|/usr/sbin|(?<![\w/])/bin(?![\w])|(?<![\w/])/sbin(?![\w]))};
    next if /fm_test_core_path/;
    print "$.: $_";
  ' "$1"
}

# absent_tool_hazards <file>: one line per hardcoded absolute path to a tool
# that does not exist outside an FHS layout, in a position where the path is
# actually used as an executable. /bin/sh and /usr/bin/env are the two
# spellings a non-FHS host still provides, so they are never flagged.
#
# Only execution positions count, because the same text as DATA is legitimate:
# a fixture that prints "/bin/bash" as fake `ps` output is asserting on a
# string, not running anything. A block that proves the path exists first
# (`[ -x /bin/bash ] || { pass ...; return; }`) is portable by construction, so
# a guard within the preceding two lines suppresses the finding.
absent_tool_hazards() {
  perl -ne '
    BEGIN { @recent = ("", "") }
    my $line = $_;
    my $guarded = ($recent[0] =~ m{-x\s+/bin/} || $recent[1] =~ m{-x\s+/bin/}
                   || $line =~ m{-x\s+/bin/} || $line =~ m{command -v\s+/bin/});
    push @recent, $line; shift @recent;
    next if $line =~ /^\s*#/ && $line !~ /^#!/;
    next if $guarded;
    my $tool = qr{/bin/(?:bash|echo|true|false|cat|sleep|cp|mv|rm|ls|sed|grep)(?![\w.-])};
    print "$.: $line" if
         $line =~ /^#!$tool/                 # shebang
      || $line =~ /\bexec\s+$tool/           # exec replacement
      || $line =~ /\bln\s+-s\s+$tool/        # symlink target
      || $line =~ /(?:^|\s)--\s+$tool/       # recorded argv after --
      || $line =~ /\bexec(?:l|v|vp|lp)?\s*\(\s*"$tool"/  # C exec family
      # Command position: start of line, or after a separator or block keyword
      # (`; do /bin/sleep 0.01; done` is as much a command as a bare line).
      || $line =~ /(?:^|;|\||&|\(|\}|\bdo\b|\bthen\b|\belse\b|\bin\b)\s*$tool/
      || $line =~ /\$\(\s*$tool/             # command substitution
      # VAR=/bin/tool anywhere on the line, not just the first assignment:
      # `FM_HOME="$st" FM_AFK_LAUNCH_ENTRY=/bin/true \` puts it second.
      || $line =~ /(?:^|\s)\w+=$tool/
      # A quoted path as an element of a language-level argv list, e.g.
      # Popen(["/bin/sleep", "300"]). Anchored to the opening bracket or paren
      # so that the same text merely being printed as data is not flagged.
      || $line =~ /[\[\(]\s*[\x27"]$tool[\x27"]/
      ;
  ' "$1"
}

test_detector_tells_hazard_from_portable() {
  local unsafe safe
  unsafe="$TMP_ROOT/unsafe.sh"
  safe="$TMP_ROOT/safe.sh"
  # shellcheck disable=SC2016 # Literal shell fixtures must remain unexpanded.
  printf '%s\n' \
    'BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}' \
    'BASE_PATH=${FM_TEST_BASE_PATH:-/bin:/sbin}' \
    'ln -s /bin/bash "$dir/claude"' \
    'register lavish src -- /bin/echo payload' \
    'exec /bin/cat "$@"' \
    'FM_HOME="$st" FM_AFK_LAUNCH_ENTRY=/bin/true' \
    'while [ ! -e "$release" ]; do /bin/sleep 0.01; done' \
    'child = subprocess.Popen(["/bin/sleep", "300"], cwd="/")' > "$unsafe"
  # shellcheck disable=SC2016 # Literal shell fixtures must remain unexpanded.
  printf '%s\n' \
    'BASE_PATH=${FM_TEST_BASE_PATH:-"$(fm_test_core_path):/usr/bin:/bin:/usr/sbin:/sbin"}' \
    'ln -s "$(fm_test_tool bash)" "$dir/claude"' \
    'register lavish src -- "$(fm_test_tool echo)" payload' \
    '[ -x /bin/bash ] || { pass "skipped"; return; }' \
    'printf "#!/usr/bin/env bash\n" > "$dir/fake"' \
    'exec /bin/sh -c "true"' > "$safe"

  [ "$(restricted_path_hazards "$unsafe" | wc -l)" -eq 2 ] \
    || fail "restricted-PATH check missed a bare FHS fallback: $(restricted_path_hazards "$unsafe")"
  # Every non-BASE_PATH line in the unsafe fixture must be caught: the symlink
  # target, the argv after --, the exec, the second assignment on its line, the
  # command after `do`, and the path inside a language-level argv list. The
  # last three are shapes an earlier version of this detector missed.
  [ "$(absent_tool_hazards "$unsafe" | wc -l)" -eq 6 ] \
    || fail "absent-tool check missed a hardcoded absent binary: $(absent_tool_hazards "$unsafe")"
  [ -z "$(restricted_path_hazards "$safe")" ] \
    || fail "restricted-PATH check flagged a portable fallback: $(restricted_path_hazards "$safe")"
  [ -z "$(absent_tool_hazards "$safe")" ] \
    || fail "absent-tool check flagged a portable line: $(absent_tool_hazards "$safe")"
  pass "fm-test-base-path-guard: both checks separate a hazardous line from a portable one"
}

sweep() {  # <label> <detector>
  local label=$1 detector=$2 file hazards all=""
  for file in "$ROOT"/tests/*.test.sh "$ROOT"/tests/lib.sh; do
    [ "$(basename "$file")" != "$SELF" ] || continue
    hazards=$("$detector" "$file")
    [ -z "$hazards" ] || all="$all
$file:
$hazards"
  done
  [ -z "$all" ] || fail "$label:$all"
}

test_no_restricted_path_hazards() {
  sweep "restricted PATH fallback(s) without fm_test_core_path" restricted_path_hazards
  pass "fm-test-base-path-guard: every restricted-PATH fallback prepends fm_test_core_path"
}

test_no_absent_tool_hazards() {
  sweep "hardcoded absolute path(s) to a tool absent outside an FHS layout" absent_tool_hazards
  pass "fm-test-base-path-guard: no suite hardcodes an absolute path to an FHS-only tool"
}

TMP_ROOT=$(fm_test_tmproot fm-test-base-path-guard)

test_detector_tells_hazard_from_portable
test_no_restricted_path_hazards
test_no_absent_tool_hazards

echo "ALL TESTS PASSED"
