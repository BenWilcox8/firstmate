# shellcheck shell=bash
# Shared claude-swap (cswap) access for firstmate.
# Usage: . bin/fm-cswap-lib.sh
#
# cswap (https://github.com/realiti4/claude-swap) is the Claude multi-account
# switcher of the captain. It owns which Claude accounts exist, which one the
# default login is, the usage of each account, and the per-terminal path that
# runs one agent as one exact account. Firstmate uses that tool and keeps no
# account registry of its own.
#
# This file owns how firstmate CALLS cswap: where the executable is, how each
# call is time-bounded, and how an account pin resolves to one exact account
# before a spawn creates anything. The header of bin/fm-spawn.sh owns the
# --account flag. The header of bin/fm-cswap-rotate.sh owns the rotation check.
# docs/configuration.md "Claude accounts (cswap)" owns the operator story.
#
# Every helper here is read-only against cswap. Firstmate does not switch the
# live login of the captain, and it does not add, remove, or edit an account.
# The live store belongs to the captain. A firstmate spawn either uses that
# store as it is, or it runs beside it through `cswap run`, which is
# per-terminal and does not change the default login.
#
# Environment:
#   FM_CSWAP_TIMEOUT   hard bound in whole seconds for one cswap call
#                      (default 20). cswap reads usage over the network, so an
#                      unbounded call can wedge a spawn.
#   FM_CSWAP_BIN       absolute path to the cswap executable, for tests and for
#                      a home whose cswap is not on the spawn PATH.

FM_CSWAP_DEFAULT_TIMEOUT=20

# Print the cswap executable to use, or return 1 when none is available.
fm_cswap_bin() {
  if [ -n "${FM_CSWAP_BIN:-}" ]; then
    [ -x "$FM_CSWAP_BIN" ] || return 1
    printf '%s\n' "$FM_CSWAP_BIN"
    return 0
  fi
  command -v cswap 2>/dev/null || return 1
}

fm_cswap_timeout_seconds() {
  local value=${FM_CSWAP_TIMEOUT:-$FM_CSWAP_DEFAULT_TIMEOUT}
  case "$value" in
    ''|*[!0-9]*|0) return 1 ;;
  esac
  printf '%s\n' "$value"
}

# Run one cswap command under a hard time bound. The stdout of the command is
# the stdout here, and its exit status is the status here. The one exception is
# 127, which means that no cswap executable exists. The perl fallback is the
# same pattern as fm-quota-axi-lib.sh, so that a host without timeout or
# gtimeout still gets a bound instead of an unbounded network call.
fm_cswap_run() {
  local bin seconds
  bin=$(fm_cswap_bin) || return 127
  seconds=$(fm_cswap_timeout_seconds) || return 1
  if command -v timeout >/dev/null 2>&1; then
    timeout "$seconds" "$bin" "$@" </dev/null
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$seconds" "$bin" "$@" </dev/null
  elif command -v perl >/dev/null 2>&1; then
    perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' \
      "$seconds" "$bin" "$@" </dev/null
  else
    echo "error: cswap calls cannot be time-bounded without timeout, gtimeout, or perl on PATH" >&2
    return 1
  fi
}

# Resolve an account pin to one exact account and print "<number> <label>",
# separated by one space. The label is the cswap alias of the account, or its
# slot number when the account has no alias. A pin can be a slot number, an
# alias, or an email. The match order is the order of cswap itself: number,
# then alias, then email. Every failure is loud and non-zero, because a spawn
# that cannot prove which subscription it bills must not start.
fm_cswap_resolve_account() {
  local pin=$1 json rc resolved kind rest
  [ -n "$pin" ] || { echo "error: no Claude account pin was given" >&2; return 1; }
  if ! command -v jq >/dev/null 2>&1; then
    echo "error: jq is required to resolve a Claude account through cswap" >&2
    return 1
  fi
  json=$(fm_cswap_run list --json 2>/dev/null)
  rc=$?
  if [ "$rc" -eq 127 ]; then
    echo "error: cswap is not installed or not on PATH; install claude-swap or drop the account pin" >&2
    return 1
  fi
  if [ "$rc" -ne 0 ] || [ -z "$json" ]; then
    echo "error: cswap could not list its Claude accounts (exit $rc)" >&2
    return 1
  fi
  # One jq pass prints "<kind> <detail>": ok with the resolved identity, or a
  # named failure with the material the error message needs.
  resolved=$(printf '%s' "$json" | jq -r --arg pin "$pin" '
    def acct_label: if ((.alias // "") | length) > 0 then .alias else (.number | tostring) end;
    def norm: ascii_downcase;
    (.accounts // []) as $all
    | if ($all | length) == 0 then "none -"
      else
        (if ($pin | test("^[0-9]+$"))
           then [$all[] | select((.number | tostring) == $pin)]
           else [] end) as $by_number
        | (if ($by_number | length) > 0 then $by_number
           else [$all[] | select(((.alias // "") | norm) == ($pin | norm))] end) as $by_alias
        | (if ($by_alias | length) > 0 then $by_alias
           else [$all[] | select(((.email // "") | norm) == ($pin | norm))] end) as $matched
        | if ($matched | length) == 1
            then "ok \($matched[0].number) \($matched[0] | acct_label)"
          elif ($matched | length) > 1
            then "ambiguous " + ([$matched[] | .number | tostring] | join(", "))
          else "unknown " + ([$all[] | acct_label] | join(", "))
          end
      end
  ' 2>/dev/null)
  if [ -z "$resolved" ]; then
    echo "error: cswap account listing could not be parsed" >&2
    return 1
  fi
  kind=${resolved%% *}
  rest=${resolved#* }
  case "$kind" in
    ok) printf '%s\n' "$rest"; return 0 ;;
    none)
      echo "error: cswap manages no Claude accounts yet; register one with 'cswap add'" >&2
      return 1
      ;;
    ambiguous)
      echo "error: Claude account '$pin' is ambiguous; it matches slots $rest - pin the slot number instead" >&2
      return 1
      ;;
    unknown)
      echo "error: unknown Claude account '$pin'; cswap knows: $rest" >&2
      return 1
      ;;
    *)
      echo "error: cswap account listing could not be parsed" >&2
      return 1
      ;;
  esac
}
