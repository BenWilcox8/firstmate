#!/usr/bin/env bash
# Opt-in guard for the disabled Rovo integration.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fm_live_gate opt-in FM_ROVO_SIGNALS_LIVE

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-rovo-disabled.XXXXXX") || fail "could not create Rovo test lab"
trap 'rm -rf -- "$LAB"' EXIT
mkdir -p "$LAB/bin"
cat > "$LAB/bin/rovo" <<'SH'
#!/usr/bin/env bash
printf 'unexpected Rovo launch\n' >> "$FM_ROVO_TRIPWIRE"
exit 99
SH
chmod +x "$LAB/bin/rovo"
: > "$LAB/tripwire"
FM_ROVO_TRIPWIRE="$LAB/tripwire" PATH="$LAB/bin:$PATH" \
  bash "$ROOT/tests/fm-rovo-harness.test.sh" || fail "disabled Rovo dispatch check failed"
[ ! -s "$LAB/tripwire" ] || fail "disabled Rovo check launched its provider tripwire"
pass "Rovo live integration is disabled before provider launch"
