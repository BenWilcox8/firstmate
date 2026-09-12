# Firstmate portable test shards

`bin/fm-test-run.sh` owns portable lane composition and execution.
`bin/fm-test-isolation-proof.sh` owns the proven-isolated candidate set.

## Verification inputs

The current candidate timings came from the 2026-08-20 concurrent proof recorded in [fm-test-isolation-proof.md](fm-test-isolation-proof.md).
The proof ran 24 candidates with four workers and no failures.

| duration_ms | script |
|---:|---|
| 45356 | `tests/fm-backend-herdr.test.sh` |
| 35415 | `tests/fm-x-mode.test.sh` |
| 35095 | `tests/fm-captain-hold-lifecycle.test.sh` |
| 27529 | `tests/fm-arm-pretool-check.test.sh` |
| 20922 | `tests/fm-test-run.test.sh` |
| 17558 | `tests/fm-crew-state.test.sh` |
| 16582 | `tests/fm-cd-pretool-check.test.sh` |
| 9766 | `tests/fm-lint.test.sh` |
| 9562 | `tests/fm-herdr-lab.test.sh` |
| 6768 | `tests/fm-grok-harness.test.sh` |
| 6290 | `tests/fm-pr-merge.test.sh` |
| 5569 | `tests/fm-composer-ghost.test.sh` |
| 4563 | `tests/fm-send-popup-settle.test.sh` |
| 4021 | `tests/fm-tmux-submit-busy.test.sh` |
| 3544 | `tests/fm-composer-lib.test.sh` |
| 3025 | `tests/fm-send-strict.test.sh` |
| 2753 | `tests/fm-send-settle.test.sh` |
| 2166 | `tests/fm-review-diff.test.sh` |
| 1315 | `tests/fm-brief.test.sh` |
| 975 | `tests/fm-spawn-batch.test.sh` |
| 598 | `tests/fm-pi-primary-types.test.sh` |
| 513 | `tests/fm-ensure-agents-md.test.sh` |
| 331 | `tests/fm-supervision-instructions.test.sh` |
| 99 | `tests/fm-transition-lib.test.sh` |

## Parallel lanes

The two parallel lanes use longest-processing-time assignment from those measured durations.

| Lane | Script count | Estimated duration |
|---|---:|---:|
| `portable-parallel-1` | 11 | 134295 ms (~134.3 s) |
| `portable-parallel-2` | 13 | 126020 ms (~126.0 s) |
| imbalance | | 8275 ms |

`bin/fm-test-run.sh` contains the exact ordered memberships in `list_portable_parallel_1` and `list_portable_parallel_2`.

## Portable serial remainder

`portable-serial` includes every `tests/*.test.sh` that is neither proven-isolated nor `real-herdr-gated`.
It keeps watcher, lock, AFK, real tmux, daemon, secondmate lifecycle, bootstrap, the `live-harness-optin` family, GUI-backend, and other unproven work serial.
Membership is derived rather than enumerated, so a newly added test lands here by default.

## Portable serial CI shards

On green CI run [30725985757](https://github.com/kunchenguid/firstmate/actions/runs/30725985757), that remainder accumulated 19m04s of script time against a 20-minute job timeout.
On [PR 1495](https://github.com/kunchenguid/firstmate/pull/1495), its main step ran about 19m51s before the job was cancelled at that boundary.
`portable-serial-<k>of<n>` splits it across `n` separate CI runners.
Each shard is still strictly serial in itself, and separate runners mean no two of these stateful scripts ever share a machine, so the split needs no concurrency isolation proof.

`bin/fm-test-run.sh` owns `n` and refuses any lane whose `of<n>` disagrees with it.
`.github/workflows/ci.yml` derives the same `n` from `strategy.job-total` rather than a literal, so changing the shard count in either file without the other fails the lane loudly instead of leaving part of the required suite unrun.

Assignment uses longest-processing-time bin packing over per-script duration hints in `bin/fm-test-run.sh`.
The 174 current hints retain the larger existing hint or successful exit-0 observation from the 2026-09-12 integration runs.
The inputs include the complete green run [34689466430](https://github.com/BenWilcox8/firstmate/actions/runs/34689466430).
They also include successful script records from these workflows:

- [34687245844](https://github.com/BenWilcox8/firstmate/actions/runs/34687245844) and [34688385628](https://github.com/BenWilcox8/firstmate/actions/runs/34688385628).
- [34693005421](https://github.com/BenWilcox8/firstmate/actions/runs/34693005421) and [34695201096](https://github.com/BenWilcox8/firstmate/actions/runs/34695201096).
- [34697219751](https://github.com/BenWilcox8/firstmate/actions/runs/34697219751) and [34699090764](https://github.com/BenWilcox8/firstmate/actions/runs/34699090764).
- [34700273710](https://github.com/BenWilcox8/firstmate/actions/runs/34700273710), the measurement cutoff for this partition.

Cancelled workflows are not green verdicts, and only their completed exit-0 records supply duration measurements.
Interrupted shards leave unfinished scripts unobserved; those scripts retain their prior successful timings.
The shipped hints total 6053782 ms, and all 174 current serial scripts have a duration hint.
Each shard remains serial, and six separate runners preserve the unchanged 20-minute job bound.

An exit-0 capability skip measures only that skip path, not the skipped live behavior.
Keep larger platform-specific measurements when portable CI skips a test.
In particular, retain the 5121 ms native-Windows measurement for `tests/fm-pi-windows-shell-invocation.test.sh`.
Existing isolated measurements for endpoint retirement and Herdr layout remain valid lower bounds.

The runner's executable LPT selection produces this six-way partition.
The retained-max sums are estimates for scheduling, not measured passes for this partition.
The observed maximum CI setup/finalization overhead was 20888 ms.
The capacity check adds a 39112 ms contingency, for a 60000 ms allowance per job.
The maximum retained sum plus that allowance is 1068996 ms, leaving 131004 ms below the unchanged 1200000 ms job bound.

| Lane | Script count | Retained-max hint | Hint plus setup allowance |
|---|---:|---:|---:|
| `portable-serial-1of6` | 26 | 1008946 ms | 1068946 ms |
| `portable-serial-2of6` | 30 | 1008996 ms | 1068996 ms |
| `portable-serial-3of6` | 29 | 1008948 ms | 1068948 ms |
| `portable-serial-4of6` | 30 | 1008968 ms | 1068968 ms |
| `portable-serial-5of6` | 30 | 1008979 ms | 1068979 ms |
| `portable-serial-6of6` | 29 | 1008945 ms | 1068945 ms |

The observed overhead is a scheduling input, not a future-runtime guarantee.
The current partition uses the fixed measurement cutoff above; later passing-run variation alone does not require another update.
Refresh the hints when a script change or a repeated capacity failure requires a new measurement set.

Hints affect balance only.
The coverage guard keeps the partition complete and disjoint for every valid hint table.
An unmeasured script receives `PORTABLE_SERIAL_DEFAULT_WEIGHT_MS`, and the guard refuses an unmeasured share above `PORTABLE_SERIAL_MAX_UNHINTED_PERCENT`.
Do not weaken that limit to hide missing measurements.

Refresh the hints from downloaded timing artifacts:

```sh
gh-axi run download <run-id> --repo <owner/repo> --name fm-test-timing-aggregate --dir /tmp/fm-serial/<run-id>
jq -r '.scripts[] | select(.exit == 0) | [.path, .duration_ms] | @tsv' /tmp/fm-serial/*/*.json \
  | awk -F'\t' '$2 > m[$1] { m[$1] = $2 } END { for (p in m) print p, m[p] }' \
  | LC_ALL=C sort
bin/fm-test-run.sh --check-coverage
```

Merge those successful observations with the existing hints by retaining the larger duration for each current serial path.
Update the table above from the resulting scheduled partition.
Prefer complete green workflows; an interrupted shard can leave an incomplete or absent artifact.
When using an interrupted workflow, account for every missing script and never count failed or cancelled commands as passing measurements.
Retain native-only measurements separately when portable CI cannot run their behavior.

## Coverage guard

`bin/fm-test-run.sh --check-coverage` verifies that both parallel lanes partition the proven-isolated set.
It also verifies that the parallel lanes, portable serial lane, and real-Herdr family are disjoint and cover every `tests/*.test.sh` script.
It separately verifies that the portable serial CI shards are non-empty, disjoint, and together equal the portable serial lane.
It reports the unmeasured serial share as `serial_unhinted=` and refuses when that share exceeds `PORTABLE_SERIAL_MAX_UNHINTED_PERCENT`, so the shards stay balanced on evidence rather than on the default weight.

## Timing artifacts

Portable shards, each portable serial shard, and the Herdr lane upload runner-generated timing JSON.
`bin/fm-test-run.sh --aggregate-json` creates the combined summary artifact.
`.github/workflows/ci.yml` owns the exact artifact names and aggregation wiring.

## Local entry points

[CONTRIBUTING.md](../CONTRIBUTING.md) owns the local test policy and common entry points.
`bin/fm-test-run.sh --help` owns exact lane names, selection flags, and bounded `--jobs` mechanics.

## Timeouts

| Lane | Bound | Rationale |
|---|---|---|
| portable parallel 1/2 | job `timeout-minutes: 10` | The measured shard sums are about three minutes and the timeout is a hang tripwire. |
| portable serial 1-6 | job `timeout-minutes: 20` | The largest retained-max sum is 1008996 ms. The 60000 ms setup allowance gives 1068996 ms, leaving 131004 ms before the bound. |
| Herdr | family-run step `timeout-minutes: 20`; job `timeout-minutes: 75` backstop | Healthy runs finished around 7 minutes before this lane gained `fm-backend-herdr-focus-flash-e2e`, which measures about 2 minutes against a real lab locally, so the step bound is still the hang tripwire (cleanup and timing artifacts still upload) while the job cap stays a last-resort backstop. Refresh this figure from the lane's uploaded timing artifact. |

Timeouts are hang tripwires rather than expected healthy durations.
`.github/workflows/ci.yml` owns the exact numbers.
