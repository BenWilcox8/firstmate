#!/usr/bin/env bash
# fm-lint.sh - the single owner of firstmate's lint definition.
#
# Runs its file set with ShellCheck's default severity, extended analysis,
# ambient configuration disabled, and one exact ShellCheck version. CI and
# no-mistakes both invoke this script with no arguments, so the rule set,
# version, bounded execution, and diagnostics ordering cannot drift.
# The explicit --fast mode is local-only and disables ShellCheck's extended
# dataflow analysis while preserving ordinary shell lint checks. CI and
# no-mistakes keep the full-analysis no-argument default.
# Tests stop source analysis at imported production modules because every
# production shell is already a canonical, source-aware root of this same run.
# The default (no explicit-path) path also runs bin/fm-lint-workflows.sh so a
# malformed GitHub workflow, including a self-broken ci.yml, fails locally
# before merge instead of only failing to run as CI.
#
# Every lint target named *.test.sh, in the canonical set or given
# explicitly, is also scanned for two hazardous test-suite shapes: a
# restricted-PATH fallback that names an FHS directory without the portable
# tool-resolution helper, and a single-quoted `bash -c '...'` body that reads
# an outer-scope shell variable never exported or passed through that
# invocation's own prefix. Both break silently rather than failing loudly, so
# ShellCheck alone cannot catch them; this is the single lint entry point
# either way. The scan skips a fixture literal that never executes.
#
# With no explicit paths, the file set depends on context:
#   - In CI (GITHUB_ACTIONS=true or CI=true), on the main branch, or when no
#     merge-base against origin/main (or local main) can be found, it lints
#     the full canonical set: bin/*.sh bin/backends/*.sh tests/*.sh. This is
#     what CI always runs, so CI coverage never depends on a local diff.
#   - Otherwise (an ordinary local branch with a real merge-base) it lints
#     only the canonical-set files changed since that merge-base, including
#     uncommitted local edits, via plain local `git diff` (no network, no
#     `gh`). A branch with zero matching changed files skips ShellCheck and
#     prints a "no changed lint targets" note, then still validates workflows.
# Explicit paths always bypass this file-set selection and lint exactly the
# given paths, matching the same config, without the workflow YAML check.
#
# Canonical lint defaults to two bounded workers over two stable logical shards.
# Each shard writes separate diagnostics, and the parent replays those outputs in
# deterministic shard and root order after every worker finishes. FM_LINT_JOBS=1
# runs the same shards serially with byte-identical diagnostics and exit selection.
#
# Optional quiet telemetry writes one bounded TSV snapshot of content and source
# graph identity, wall/CPU/RSS, shard load, and competing ShellCheck processes.
#
# Usage:
#   fm-lint.sh                         lint the context-selected file set (see above)
#   fm-lint.sh --fast [path]...       local lint with extended analysis disabled
#   fm-lint.sh <path>...               lint explicit roots with the same config
#   fm-lint.sh --jobs <1|2> [path]...  override bounded worker count
#   fm-lint.sh --telemetry <path> ...  write a quiet metrics snapshot
#   fm-lint.sh --required-version      print the ShellCheck pin
#   fm-lint.sh --list-files            print the file set that would be linted
#   fm-lint.sh --help                  print this usage
set -u

REQUIRED_SHELLCHECK=0.11.0
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SELF_DIR/fm-lint.sh"
ROOT="$(cd "$SELF_DIR/.." && pwd)"
cd "$ROOT" || exit 1

FM_LINT_WORKER_SHELLCHECK_PID=
# shellcheck disable=SC2329 # Registered by the private worker's signal traps.
fm_lint_worker_stop() {
  [ -n "$FM_LINT_WORKER_SHELLCHECK_PID" ] || return 0
  kill "$FM_LINT_WORKER_SHELLCHECK_PID" 2>/dev/null || true
  wait "$FM_LINT_WORKER_SHELLCHECK_PID" 2>/dev/null || true
  FM_LINT_WORKER_SHELLCHECK_PID=
}

fm_lint_worker() {  # <manifest> <output-dir> <shard-index>
  local manifest=$1 output_dir=$2 shard_index=$3 tab index path output rc=0
  local -a roots shellcheck_args
  roots=()
  tab=$(printf '\t')
  while IFS="$tab" read -r index path || [ -n "${index:-}${path:-}" ]; do
    [ -n "${index:-}" ] || continue
    roots+=("$path")
  done < "$manifest"
  output="$output_dir/shard.$shard_index"
  if [ "${#roots[@]}" -gt 0 ]; then
    trap 'fm_lint_worker_stop; exit 129' HUP
    trap 'fm_lint_worker_stop; exit 130' INT
    trap 'fm_lint_worker_stop; exit 143' TERM
    shellcheck_args=(--norc --external-sources)
    if [ "${FM_LINT_INTERNAL_FAST:-0}" -eq 1 ]; then
      shellcheck_args+=(--extended-analysis=false)
    fi
    "$FM_LINT_SHELLCHECK" "${shellcheck_args[@]}" -- "${roots[@]}" > "$output.out" 2>&1 &
    FM_LINT_WORKER_SHELLCHECK_PID=$!
    wait "$FM_LINT_WORKER_SHELLCHECK_PID" || rc=$?
    FM_LINT_WORKER_SHELLCHECK_PID=
    trap - HUP INT TERM
  else
    : > "$output.out"
  fi
  printf '%s\n' "$rc" > "$output.rc"
  return "$rc"
}

# fm_lint_hazard_targets prints, one per line, the members of ROOTS named
# *.test.sh: the only files the hazard scan below ever reads. Restricting to
# that suffix keeps helper libraries like tests/lib.sh out of scope and lets
# a fixture fed by an explicit path (the lint self-test) opt in by name.
fm_lint_hazard_targets() {
  local path
  for path in "$@"; do
    case "$path" in
      *.test.sh) [ -f "$path" ] && printf '%s\n' "$path" ;;
    esac
  done
}

# fm_lint_write_hazard_scanner writes the embedded hazard-scan Perl script to
# the given path. Kept as one small file rather than a second bin/ entry
# point: bin/fm-lint.sh remains the only thing CI and no-mistakes invoke.
fm_lint_write_hazard_scanner() {
  cat > "$1" <<'FM_LINT_HAZARD_SCAN_PL'
#!/usr/bin/env perl
# fm-lint.sh's embedded hazard scan - see that script's header for the
# contract. Scans *.test.sh files for two shapes that broke real suites:
#   1. a restricted-PATH fallback naming an FHS directory (nothing on it
#      resolves on a host, like NixOS, whose /bin and /usr/bin hold only a
#      handful of tools) without the portable tool-resolution helper.
#   2. a single-quoted `bash -c '...'` body reading, by name, a shell
#      variable the outer test scope assigned but never exported or passed
#      through that invocation's own env-var prefix - invisible to the
#      child, so it aborts under `set -u` or is masked by a `:-default`
#      while the case still reports ok.
# Prints one "<file>:<line>: <message>" finding per line and exits nonzero
# if any file had one.
use strict;
use warnings;

my $findings = 0;

# A heredoc body is data one part of the script writes to a file or pipe,
# never code this script itself executes, so text inside one (a fixture
# embedding an example of either hazard, quoted or not) is never a hazard
# here. Blank those lines out before either scan runs, keeping every other
# line's number unchanged.
sub strip_heredocs {
  my ($lines) = @_;
  my @out = @$lines;
  my $i = 0;
  while ($i <= $#out) {
    if ($out[$i] =~ /<<-?\s*(['"]?)([A-Za-z_][A-Za-z0-9_]*)\1/) {
      my $delim = $2;
      $i++;
      while ($i <= $#out) {
        my $body_line = $out[$i];
        my $trimmed = $body_line;
        $trimmed =~ s/^\s+|\s+$//g;
        $out[$i] = "\n";
        last if $trimmed eq $delim;
        $i++;
      }
    }
    $i++;
  }
  return \@out;
}

sub scan_restricted_path {
  my ($file, $lines) = @_;
  my $n = 0;
  for my $i (0 .. $#$lines) {
    my $line = $lines->[$i];
    next if $line =~ /^\s*#/;
    next unless $line =~ /\b(?:BASE_PATH|RUN_PATH|FM_TEST_BASE_PATH)\b/;
    next unless $line =~ m{(?:/usr/bin|/usr/sbin|(?<![\w/])/bin(?![\w])|(?<![\w/])/sbin(?![\w]))};
    next if $line =~ /fm_test_core_path/;
    printf "%s:%d: restricted-PATH fallback names an FHS directory without fm_test_core_path: %s\n",
      $file, $i + 1, $line =~ s/^\s+|\s+$//gr;
    $n++;
  }
  return $n;
}

my %safe = map { $_ => 1 } qw(
  PATH HOME USER SHELL PWD OLDPWD LANG LC_ALL LC_CTYPE TERM TZ TMPDIR
  LOGNAME EDITOR VISUAL DISPLAY SSH_AUTH_SOCK SSH_TTY XDG_RUNTIME_DIR
  RANDOM SECONDS LINENO BASHPID PPID UID EUID HOSTNAME HOSTTYPE OSTYPE
  MACHTYPE BASH BASH_VERSION FUNCNAME PIPESTATUS OPTARG OPTIND REPLY
  IFS GITHUB_ACTIONS CI
);

sub find_bash_c_bodies {
  my ($lines) = @_;
  my $n = scalar @$lines;
  my @out;
  my $i = 0;
  while ($i < $n) {
    my $line = $lines->[$i];
    if ($line =~ /^(.*?)\bbash\s+-c\s+'(.*)$/s) {
      my ($prefix, $rest) = ($1, $2);
      my $start_lineno = $i + 1;
      my @prefix_lines = ($prefix);
      my $j = $i - 1;
      while ($j >= 0 && $lines->[$j] =~ /\\\s*$/) {
        unshift @prefix_lines, $lines->[$j];
        $j--;
      }
      my $prefix_text = join(' ', @prefix_lines);
      my $body = '';
      my $cur = $rest;
      my $end_lineno = $start_lineno;
      while (1) {
        if ($cur =~ /^([^']*)'(.*)$/s) {
          $body .= "$1\n";
          last;
        } else {
          $body .= "$cur\n";
          $i++;
          last if $i >= $n;
          $cur = $lines->[$i];
          $end_lineno = $i + 1;
        }
      }
      push @out, { start => $start_lineno, end => $end_lineno,
                   prefix => $prefix_text, body => $body };
      $i++;
      next;
    }
    $i++;
  }
  return @out;
}

sub scan_unexported_body_vars {
  my ($file, $lines) = @_;
  my $n = 0;
  my @bodies = find_bash_c_bodies($lines);
  return 0 unless @bodies;

  my %exported;
  for my $l (@$lines) {
    if ($l =~ /^\s*export\s+([A-Za-z_][A-Za-z0-9_]*)\b/) {
      $exported{$1} = 1;
    }
    if ($l =~ /^\s*export\s+(?:[A-Za-z_][A-Za-z0-9_]*\s+)*([A-Za-z_][A-Za-z0-9_]*)=/) {
      $exported{$1} = 1;
    }
  }

  # A name plainly assigned somewhere OUTSIDE any bash -c body is the outer
  # test scope's own local variable. A body reading that exact name, without
  # it being exported or carried by this invocation's own prefix, is the
  # hazard: the value exists in scope and the author forgot the inner shell
  # cannot see it. A name never assigned outside a body instead belongs to
  # whatever production script the body sources, which this check does not
  # and should not try to model.
  my %in_body_line;
  for my $b (@bodies) {
    $in_body_line{$_} = 1 for $b->{start} .. $b->{end};
  }
  my %outer_assigned;
  for my $idx (0 .. $#$lines) {
    next if $in_body_line{$idx + 1};
    my $l = $lines->[$idx];
    while ($l =~ /(?:^|[\s(;])([A-Za-z_][A-Za-z0-9_]*)=/g) {
      $outer_assigned{$1} = 1;
    }
    if ($l =~ /^\s*local\s+(?:-\w+\s+)?(.+)$/) {
      for my $tok (split /\s+/, $1) {
        $tok =~ s/=.*$//;
        $outer_assigned{$tok} = 1;
      }
    }
  }

  for my $b (@bodies) {
    my %localvars;
    while ($b->{prefix} =~ /(?:^|[\s(])([A-Za-z_][A-Za-z0-9_]*)=/g) {
      $localvars{$1} = 1;
    }
    my $body = $b->{body};
    my %bodylocal;
    while ($body =~ /(?:^|[\s(;])([A-Za-z_][A-Za-z0-9_]*)=/gm) {
      $bodylocal{$1} = 1;
    }
    while ($body =~ /^\s*local\s+(?:-\w+\s+)?(.+)$/gm) {
      $bodylocal{$_} = 1 for map { (my $x = $_) =~ s/=.*$//; $x } split /\s+/, $1;
    }
    while ($body =~ /\bfor\s+([A-Za-z_][A-Za-z0-9_]*)\s+in\b/g) {
      $bodylocal{$1} = 1;
    }
    while ($body =~ /\bread\s+(?:-\w+\s+)*(.+)$/gm) {
      $bodylocal{$_} = 1 for split /\s+/, $1;
    }

    my @bodylines = split /\n/, $body, -1;
    my $bl = $b->{start};
    for my $bline (@bodylines) {
      while ($bline =~ /\$(\{)?([A-Za-z_][A-Za-z0-9_]*)/g) {
        my ($braced, $var) = ($1, $2);
        if ($braced) {
          my $tail = substr($bline, pos($bline));
          next if $tail =~ /^:?[-=+?]/;
        }
        next if $var =~ /^[0-9]+$/;
        next if $safe{$var};
        next if $localvars{$var};
        next if $exported{$var};
        next if $bodylocal{$var};
        next unless $outer_assigned{$var};
        printf "%s:%d: unexported \$%s read inside a single-quoted bash -c body (opens line %d)\n",
          $file, $bl, $var, $b->{start};
        $n++;
      }
      $bl++;
    }
  }
  return $n;
}

die "usage: fm-lint-hazard-scan.pl <file>...\n" unless @ARGV;
for my $file (@ARGV) {
  open my $fh, '<', $file or die "fm-lint-hazard-scan.pl: cannot open $file: $!\n";
  my @raw_lines = <$fh>;
  close $fh;
  my $lines = strip_heredocs(\@raw_lines);
  $findings += scan_restricted_path($file, $lines);
  $findings += scan_unexported_body_vars($file, $lines);
}
exit($findings > 0 ? 1 : 0);
FM_LINT_HAZARD_SCAN_PL
}

# Private subprocess mode used only by the bounded parent above.
if [ "${1:-}" = "--internal-worker" ]; then
  [ "${FM_LINT_INTERNAL:-}" = 1 ] || {
    printf 'fm-lint.sh: --internal-worker is private to the lint owner.\n' >&2
    exit 2
  }
  [ "$#" -eq 4 ] && [ -n "${FM_LINT_SHELLCHECK:-}" ] || exit 2
  fm_lint_worker "$2" "$3" "$4"
  exit $?
fi

if [ "${1:-}" = "--required-version" ]; then
  printf '%s\n' "$REQUIRED_SHELLCHECK"
  exit 0
fi

fm_lint_usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$SELF"
}

# Default no-args lint also validates GitHub workflows. Explicit paths stay a
# ShellCheck-only override so callers can target one shell root.
fm_lint_run_workflows() {
  [ "$EXPLICIT_PATHS" -eq 0 ] || return 0
  "$SELF_DIR/fm-lint-workflows.sh"
}

JOBS=${FM_LINT_JOBS:-2}
TELEMETRY=${FM_LINT_TELEMETRY:-}
FAST=0
ANALYSIS_MODE=full
LIST_FILES=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --jobs)
      [ "$#" -ge 2 ] || { printf 'fm-lint.sh: --jobs requires 1 or 2.\n' >&2; exit 2; }
      JOBS=$2
      shift 2
      ;;
    --jobs=*)
      JOBS=${1#*=}
      shift
      ;;
    --telemetry)
      [ "$#" -ge 2 ] || { printf 'fm-lint.sh: --telemetry requires a path.\n' >&2; exit 2; }
      TELEMETRY=$2
      shift 2
      ;;
    --telemetry=*)
      TELEMETRY=${1#*=}
      shift
      ;;
    --fast)
      FAST=1
      ANALYSIS_MODE=fast
      shift
      ;;
    --list-files)
      LIST_FILES=1
      shift
      ;;
    --help|-h)
      fm_lint_usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    *) break ;;
  esac
done

case "$JOBS" in
  1|2) ;;
  *) printf 'fm-lint.sh: jobs must be 1 or 2, got %s.\n' "$JOBS" >&2; exit 2 ;;
esac

if [ "$FAST" -eq 1 ] && { [ "${GITHUB_ACTIONS:-}" = true ] || [ "${CI:-}" = true ]; }; then
  printf 'fm-lint.sh: --fast is local-only; CI uses full ShellCheck analysis.\n' >&2
  exit 2
fi

# fm_lint_changed_base_ref prints the ref to diff the working branch against:
# the local origin/main tracking ref when present, else local main. Returns
# nonzero when neither is resolvable, which the caller treats as "no
# merge-base found" and falls back to a full lint.
fm_lint_changed_base_ref() {
  if git rev-parse --verify -q origin/main >/dev/null 2>&1; then
    printf 'origin/main\n'
    return 0
  fi
  if git rev-parse --verify -q main >/dev/null 2>&1; then
    printf 'main\n'
    return 0
  fi
  return 1
}

# fm_lint_is_canonical_root tests membership in the canonical set (a direct
# *.sh child of bin/, bin/backends/, or tests/) without the shell case
# statement's non-pathname wildcard matching a path separator by accident.
fm_lint_is_canonical_root() {
  local path=$1 dir base
  case "$path" in
    */*) dir=${path%/*}; base=${path##*/} ;;
    *) dir=; base=$path ;;
  esac
  case "$base" in
    *.sh) : ;;
    *) return 1 ;;
  esac
  case "$dir" in
    bin|bin/backends|tests) return 0 ;;
    *) return 1 ;;
  esac
}

CHANGED_MODE=0
EXPLICIT_PATHS=0
if [ "$#" -gt 0 ]; then
  EXPLICIT_PATHS=1
  ROOTS=("$@")
else
  full_lint=1
  if [ "${GITHUB_ACTIONS:-}" != true ] && [ "${CI:-}" != true ] \
    && command -v git >/dev/null 2>&1 \
    && git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    && [ "$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" != main ]; then
    base_ref=$(fm_lint_changed_base_ref) || base_ref=
    merge_base=
    [ -z "$base_ref" ] || merge_base=$(git merge-base "$base_ref" HEAD 2>/dev/null) || merge_base=
    [ -z "$merge_base" ] || full_lint=0
  fi

  if [ "$full_lint" -eq 1 ]; then
    ROOTS=(bin/*.sh bin/backends/*.sh tests/*.sh)
  else
    CHANGED_MODE=1
    ROOTS=()
    while IFS= read -r -d '' changed_path; do
      fm_lint_is_canonical_root "$changed_path" || continue
      [ -f "$changed_path" ] || continue
      ROOTS+=("$changed_path")
    done < <(git diff --name-only --diff-filter=ACMR -z "$merge_base" -- 2>/dev/null | LC_ALL=C sort -z)
  fi
fi
ROOT_COUNT=${#ROOTS[@]}

if [ "$LIST_FILES" -eq 1 ]; then
  [ "$#" -eq 0 ] || {
    printf 'fm-lint.sh: --list-files does not accept explicit paths.\n' >&2
    exit 2
  }
  [ "$ROOT_COUNT" -eq 0 ] || printf '%s\n' "${ROOTS[@]}"
  exit 0
fi

if ! command -v shellcheck >/dev/null 2>&1; then
  printf 'fm-lint.sh: ShellCheck not found; install ShellCheck %s with bin/fm-install-shellcheck.sh <destination-directory> and put that directory on PATH.\n' \
    "$REQUIRED_SHELLCHECK" >&2
  exit 1
fi
unset SHELLCHECK_OPTS
SHELLCHECK_BIN=$(command -v shellcheck)
if ! PERL_BIN=$(command -v perl); then
  printf 'fm-lint.sh: perl is required for bounded worker cleanup.\n' >&2
  exit 127
fi
resolved=$("$SHELLCHECK_BIN" --version | awk '/^version:/ {print $2; exit}')
printf 'fm-lint.sh: ShellCheck %s (pinned %s)\n' "$resolved" "$REQUIRED_SHELLCHECK" >&2
if [ "$resolved" != "$REQUIRED_SHELLCHECK" ]; then
  printf 'fm-lint.sh: ShellCheck %s required for CI parity, found %s. Install %s with bin/fm-install-shellcheck.sh <destination-directory>.\n' \
    "$REQUIRED_SHELLCHECK" "$resolved" "$REQUIRED_SHELLCHECK" >&2
  exit 1
fi
if [ "$FAST" -eq 1 ]; then
  printf 'fm-lint.sh: fast local mode; ShellCheck extended analysis disabled\n' >&2
else
  printf 'fm-lint.sh: full ShellCheck extended analysis enabled\n' >&2
fi

if [ "$CHANGED_MODE" -eq 1 ] && [ "$ROOT_COUNT" -eq 0 ]; then
  printf 'fm-lint.sh: no changed lint targets\n'
  overall_rc=0
  fm_lint_run_workflows || overall_rc=$?
  exit "$overall_rc"
fi

if [ -n "$TELEMETRY" ]; then
  telemetry_parent=$(dirname "$TELEMETRY")
  [ -d "$telemetry_parent" ] || {
    printf 'fm-lint.sh: telemetry directory does not exist: %s\n' "$telemetry_parent" >&2
    exit 2
  }
fi

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-lint.XXXXXX") || exit 1
ACTIVE_PIDS=()
# shellcheck disable=SC2329 # Registered by the EXIT and signal traps below.
fm_lint_cleanup() {
  local pid
  for pid in "${ACTIVE_PIDS[@]:-}"; do
    [ -n "$pid" ] || continue
    kill -TERM -- "-$pid" 2>/dev/null || true
    kill -TERM "$pid" 2>/dev/null || true
  done
  for pid in "${ACTIVE_PIDS[@]:-}"; do
    [ -n "$pid" ] || continue
    kill -KILL -- "-$pid" 2>/dev/null || true
    kill -KILL "$pid" 2>/dev/null || true
  done
  for pid in "${ACTIVE_PIDS[@]:-}"; do
    [ -n "$pid" ] && wait "$pid" 2>/dev/null || true
  done
  rm -rf "$TMP_ROOT"
}
trap fm_lint_cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

TAB=$(printf '\t')
WEIGHTS="$TMP_ROOT/weights"
OUTPUT_DIR="$TMP_ROOT/output"
mkdir -p "$OUTPUT_DIR"
SHARD_COUNT=2
worker=0
while [ "$worker" -lt "$SHARD_COUNT" ]; do
  : > "$TMP_ROOT/manifest.$worker"
  worker=$((worker + 1))
done

index=1
: > "$WEIGHTS"
for path in "${ROOTS[@]}"; do
  case "$path" in
    *"$TAB"*|*$'\n'*)
      printf 'fm-lint.sh: paths containing tabs or newlines are not supported: %s\n' "$path" >&2
      exit 2
      ;;
  esac
  if [ -f "$path" ]; then
    weight=$(wc -c < "$path" 2>/dev/null | tr -d '[:space:]')
  else
    weight=1
  fi
  case "$weight" in ''|*[!0-9]*) weight=1 ;; esac
  printf '%s\t%s\t%s\n' "$weight" "$index" "$path" >> "$WEIGHTS"
  index=$((index + 1))
done

# Largest-first deterministic greedy assignment keeps the two bounded workers
# balanced without affecting replay order. Direct bytes are a stable portable
# proxy after the expensive dynamic adapter source fan-out is cut.
WORKER_LOADS=(0 0)
LC_ALL=C sort -t "$TAB" -k1,1nr -k2,2n "$WEIGHTS" > "$WEIGHTS.sorted"
while IFS="$TAB" read -r weight index path; do
  worker=0
  if [ "${WORKER_LOADS[1]}" -lt "${WORKER_LOADS[0]}" ]; then
    worker=1
  fi
  printf '%s\t%s\n' "$index" "$path" >> "$TMP_ROOT/manifest.$worker"
  WORKER_LOADS[worker]=$((WORKER_LOADS[worker] + weight))
done < "$WEIGHTS.sorted"
worker=0
while [ "$worker" -lt "$SHARD_COUNT" ]; do
  LC_ALL=C sort -t "$TAB" -k1,1n "$TMP_ROOT/manifest.$worker" > "$TMP_ROOT/manifest.$worker.sorted"
  mv "$TMP_ROOT/manifest.$worker.sorted" "$TMP_ROOT/manifest.$worker"
  worker=$((worker + 1))
done

fm_lint_shellcheck_count() {
  if command -v pgrep >/dev/null 2>&1; then
    pgrep -x shellcheck 2>/dev/null | wc -l | tr -d '[:space:]'
  else
    printf 'unavailable'
  fi
}

fm_lint_load_average() {
  if [ -r /proc/loadavg ]; then
    awk '{print $1 "/" $2 "/" $3}' /proc/loadavg
  elif command -v sysctl >/dev/null 2>&1; then
    sysctl -n vm.loadavg 2>/dev/null | awk '{gsub(/[{}]/, ""); print $1 "/" $2 "/" $3}' || printf 'unavailable'
  else
    printf 'unavailable'
  fi
}

fm_lint_aggregate_cpu() {
  ps -A -o %cpu= 2>/dev/null | awk '{sum += $1} END {printf "%.2f", sum + 0}'
}

TELEMETRY_START_EPOCH=0
TELEMETRY_SHELLCHECK_START=unavailable
TELEMETRY_LOAD_START=unavailable
TELEMETRY_CPU_START=unavailable
if [ -n "$TELEMETRY" ]; then
  TELEMETRY_START_EPOCH=$(date +%s)
  TELEMETRY_SHELLCHECK_START=$(fm_lint_shellcheck_count)
  TELEMETRY_LOAD_START=$(fm_lint_load_average)
  TELEMETRY_CPU_START=$(fm_lint_aggregate_cpu)
fi

fm_lint_run_worker() {  # <worker-index>
  local worker_index=$1 manifest timing
  manifest="$TMP_ROOT/manifest.$worker_index"
  timing="$TMP_ROOT/timing.$worker_index"
  if [ -n "$TELEMETRY" ] && [ -x /usr/bin/time ]; then
    if [ "$(uname)" = Darwin ]; then
      exec "$PERL_BIN" -e 'setpgrp(0, 0) or die "setpgrp: $!"; exec @ARGV or die "exec: $!"' \
        /usr/bin/time -lp -o "$timing" \
        env FM_LINT_INTERNAL=1 FM_LINT_INTERNAL_FAST="$FAST" FM_LINT_SHELLCHECK="$SHELLCHECK_BIN" \
        "${BASH:-bash}" "$SELF" --internal-worker "$manifest" "$OUTPUT_DIR" "$worker_index"
    else
      exec "$PERL_BIN" -e 'setpgrp(0, 0) or die "setpgrp: $!"; exec @ARGV or die "exec: $!"' \
        /usr/bin/time -f 'wall_seconds=%e\nuser_seconds=%U\nsystem_seconds=%S\nmax_rss_kib=%M' -o "$timing" \
        env FM_LINT_INTERNAL=1 FM_LINT_INTERNAL_FAST="$FAST" FM_LINT_SHELLCHECK="$SHELLCHECK_BIN" \
        "${BASH:-bash}" "$SELF" --internal-worker "$manifest" "$OUTPUT_DIR" "$worker_index"
    fi
  else
    [ -z "$TELEMETRY" ] || printf 'timing_unavailable=1\n' > "$timing"
    exec "$PERL_BIN" -e 'setpgrp(0, 0) or die "setpgrp: $!"; exec @ARGV or die "exec: $!"' \
      env FM_LINT_INTERNAL=1 FM_LINT_INTERNAL_FAST="$FAST" FM_LINT_SHELLCHECK="$SHELLCHECK_BIN" \
      "${BASH:-bash}" "$SELF" --internal-worker "$manifest" "$OUTPUT_DIR" "$worker_index"
  fi
}

fm_lint_start_worker() {
  fm_lint_run_worker "$1" &
  ACTIVE_PIDS+=("$!")
}

fm_lint_wait_workers() {
  local pid
  while [ "${#ACTIVE_PIDS[@]}" -gt 0 ]; do
    pid=${ACTIVE_PIDS[0]}
    wait "$pid" 2>/dev/null || true
    ACTIVE_PIDS=("${ACTIVE_PIDS[@]:1}")
  done
}

if [ "$JOBS" -eq 1 ]; then
  worker=0
  while [ "$worker" -lt "$SHARD_COUNT" ]; do
    fm_lint_start_worker "$worker"
    fm_lint_wait_workers
    worker=$((worker + 1))
  done
else
  worker=0
  while [ "$worker" -lt "$SHARD_COUNT" ]; do
    fm_lint_start_worker "$worker"
    worker=$((worker + 1))
  done
  fm_lint_wait_workers
fi

# Replay both stable shards in deterministic order and select the first nonzero
# shard status. ShellCheck processes every root in a shard after earlier findings.
overall_rc=0
worker=0
while [ "$worker" -lt "$SHARD_COUNT" ]; do
  output="$OUTPUT_DIR/shard.$worker"
  [ ! -f "$output.out" ] || cat "$output.out"
  if [ -f "$output.rc" ]; then
    rc=$(cat "$output.rc" 2>/dev/null || printf '2')
    case "$rc" in ''|*[!0-9]*) rc=2 ;; esac
  else
    printf 'fm-lint.sh: worker produced no result for shard %s.\n' "$worker" >&2
    rc=2
  fi
  if [ "$overall_rc" -eq 0 ] && [ "$rc" -ne 0 ]; then
    overall_rc=$rc
  fi
  worker=$((worker + 1))
done

mapfile -t HAZARD_TARGETS < <(fm_lint_hazard_targets "${ROOTS[@]}")
if [ "${#HAZARD_TARGETS[@]}" -gt 0 ]; then
  HAZARD_SCANNER="$TMP_ROOT/fm-lint-hazard-scan.pl"
  fm_lint_write_hazard_scanner "$HAZARD_SCANNER"
  if ! "$PERL_BIN" "$HAZARD_SCANNER" "${HAZARD_TARGETS[@]}"; then
    [ "$overall_rc" -ne 0 ] || overall_rc=1
  fi
fi

if [ -n "$TELEMETRY" ]; then
  TELEMETRY_END_EPOCH=$(date +%s)
  TELEMETRY_SHELLCHECK_END=$(fm_lint_shellcheck_count)
  TELEMETRY_LOAD_END=$(fm_lint_load_average)
  TELEMETRY_CPU_END=$(fm_lint_aggregate_cpu)

  direct_lines=$(awk 'END {print NR + 0}' "${ROOTS[@]}" 2>/dev/null || printf 'unavailable')
  direct_bytes=0
  : > "$TMP_ROOT/content-cksums"
  : > "$TMP_ROOT/source-targets"
  source_directives=0
  source_boundaries=0
  for path in "${ROOTS[@]}"; do
    if [ -f "$path" ]; then
      bytes=$(wc -c < "$path" 2>/dev/null | tr -d '[:space:]')
      case "$bytes" in ''|*[!0-9]*) bytes=0 ;; esac
      direct_bytes=$((direct_bytes + bytes))
      cksum "$path" >> "$TMP_ROOT/content-cksums" 2>/dev/null || true
      awk '
        /^[[:space:]]*# shellcheck source=/ {
          target=$0
          sub(/^[[:space:]]*# shellcheck source=/, "", target)
          sub(/[[:space:]].*$/, "", target)
          print target
        }
      ' "$path" >> "$TMP_ROOT/source-targets"
    fi
  done
  source_directives=$(wc -l < "$TMP_ROOT/source-targets" | tr -d '[:space:]')
  source_boundaries=$(grep -c '^/dev/null$' "$TMP_ROOT/source-targets" 2>/dev/null || true)
  case "$source_boundaries" in ''|*[!0-9]*) source_boundaries=0 ;; esac
  source_followed=$((source_directives - source_boundaries))
  source_targets=$(LC_ALL=C sort -u "$TMP_ROOT/source-targets" | wc -l | tr -d '[:space:]')
  content_cksum=$(cksum "$TMP_ROOT/content-cksums" | awk '{print $1 "-" $2}')
  git_head=$(git rev-parse HEAD 2>/dev/null || printf 'unavailable')

  if [ -x /usr/bin/time ]; then
    if [ "$(uname)" = Darwin ]; then
      timing_summary=$(awk '
        /^real / {wall += $2; if ($2 > max_wall) max_wall=$2}
        /^user / {user += $2}
        /^sys / {sys_cpu += $2}
        /maximum resident set size/ {
          rss=$1 / 1024
          rss_sum += rss
          if (rss > max_rss) max_rss=rss
        }
        END {printf "%.2f %.2f %.2f %.0f %.0f %.2f", user, sys_cpu, wall, max_rss, rss_sum, max_wall}
      ' "$TMP_ROOT"/timing.*)
    else
      timing_summary=$(awk -F= '
        $1 == "wall_seconds" {wall += $2; if ($2 > max_wall) max_wall=$2}
        $1 == "user_seconds" {user += $2}
        $1 == "system_seconds" {sys_cpu += $2}
        $1 == "max_rss_kib" {rss_sum += $2; if ($2 > max_rss) max_rss=$2}
        END {printf "%.2f %.2f %.2f %.0f %.0f %.2f", user, sys_cpu, wall, max_rss, rss_sum, max_wall}
      ' "$TMP_ROOT"/timing.*)
    fi
    read -r timing_user timing_system timing_worker_wall max_worker_rss worker_rss_sum max_worker_wall <<EOF
$timing_summary
EOF
  else
    timing_user=unavailable
    timing_system=unavailable
    timing_worker_wall=unavailable
    max_worker_rss=unavailable
    worker_rss_sum=unavailable
    max_worker_wall=unavailable
  fi

  telemetry_tmp="$TMP_ROOT/telemetry.tsv"
  {
    printf 'format\tfm-lint-telemetry-v1\n'
    printf 'git_head\t%s\n' "$git_head"
    printf 'content_cksum\t%s\n' "$content_cksum"
    printf 'shellcheck_version\t%s\n' "$resolved"
    printf 'analysis_mode\t%s\n' "$ANALYSIS_MODE"
    printf 'jobs\t%s\n' "$JOBS"
    printf 'root_count\t%s\n' "$ROOT_COUNT"
    printf 'direct_lines\t%s\n' "$direct_lines"
    printf 'direct_bytes\t%s\n' "$direct_bytes"
    printf 'source_directives\t%s\n' "$source_directives"
    printf 'source_boundary_directives\t%s\n' "$source_boundaries"
    printf 'source_followed_directives\t%s\n' "$source_followed"
    printf 'source_target_count\t%s\n' "$source_targets"
    printf 'shard_1_weight_bytes\t%s\n' "${WORKER_LOADS[0]}"
    printf 'shard_2_weight_bytes\t%s\n' "${WORKER_LOADS[1]:-0}"
    printf 'wall_seconds\t%s\n' "$((TELEMETRY_END_EPOCH - TELEMETRY_START_EPOCH))"
    printf 'worker_wall_sum_seconds\t%s\n' "$timing_worker_wall"
    printf 'max_worker_wall_seconds\t%s\n' "$max_worker_wall"
    printf 'user_seconds\t%s\n' "$timing_user"
    printf 'system_seconds\t%s\n' "$timing_system"
    printf 'max_worker_rss_kib\t%s\n' "$max_worker_rss"
    printf 'worker_rss_sum_kib\t%s\n' "$worker_rss_sum"
    printf 'shellcheck_processes_start\t%s\n' "$TELEMETRY_SHELLCHECK_START"
    printf 'shellcheck_processes_end\t%s\n' "$TELEMETRY_SHELLCHECK_END"
    printf 'load_average_start\t%s\n' "$TELEMETRY_LOAD_START"
    printf 'load_average_end\t%s\n' "$TELEMETRY_LOAD_END"
    printf 'aggregate_cpu_percent_start\t%s\n' "$TELEMETRY_CPU_START"
    printf 'aggregate_cpu_percent_end\t%s\n' "$TELEMETRY_CPU_END"
    printf 'result_exit\t%s\n' "$overall_rc"
  } > "$telemetry_tmp"
  if ! mv -f "$telemetry_tmp" "$TELEMETRY"; then
    printf 'fm-lint.sh: could not write telemetry to %s.\n' "$TELEMETRY" >&2
    [ "$overall_rc" -ne 0 ] || overall_rc=2
  fi
fi

if [ "$overall_rc" -eq 0 ]; then
  fm_lint_run_workflows || overall_rc=$?
else
  fm_lint_run_workflows || true
fi

exit "$overall_rc"
