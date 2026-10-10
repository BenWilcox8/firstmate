#!/usr/bin/env bash
# Round-2 batch 2: run after the watch-triage batch, one heavy run at a time.
# Uses the repo's own runner; the real-Herdr family is not selected.
set -u
ROOT=$1 EV=$2
cd "$ROOT"
bin/fm-test-run.sh --jobs 1 --per-script-timeout-secs 1200 --json "$EV/r2-missing-tool-skips.json" \
  tests/fm-ci-workflow.test.sh tests/fm-nm-test-contract.test.sh tests/fm-no-mistakes-required.test.sh \
  tests/fm-turnend-foreign-owner-arm-fix.test.sh tests/fm-voice-relay.test.sh tests/fm-mail.test.sh \
  tests/fm-kimi-harness.test.sh > "$EV/r2-missing-tool-skips.log" 2>&1
echo "missing-tool-skips runner exit $?" >> "$EV/r2-missing-tool-skips.log"
bin/fm-test-run.sh --jobs 1 --per-script-timeout-secs 1200 --json "$EV/r2-ported-suites.json" \
  tests/fm-test-fixture-cleanup.test.sh tests/fm-ensure-agents-md.test.sh \
  tests/fm-inbox.test.sh tests/fm-documentation-audiences.test.sh tests/fm-test-isolation-proof.test.sh \
  tests/fm-crew-state.test.sh tests/fm-bootstrap-network-parallel.test.sh tests/fm-extension-binding.test.sh \
  tests/fm-local-send-provenance.test.sh tests/fm-herdr-lab.test.sh tests/fm-backend-herdr.test.sh \
  tests/fm-home-summary-refresh.test.sh tests/fm-on.test.sh tests/fm-quota-array-dispatch-live-e2e.test.sh \
  tests/fm-cmux-claude-composer-live-e2e.test.sh tests/fm-branch-supervision.test.sh \
  tests/fm-test-run.test.sh tests/fm-public-followup.test.sh tests/fm-procevent.test.sh \
  > "$EV/r2-ported-suites.log" 2>&1
echo "ported-suites runner exit $?" >> "$EV/r2-ported-suites.log"
