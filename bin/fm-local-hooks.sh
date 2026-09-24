#!/usr/bin/env bash
# Fork hooks. Each case has one owner and leaves unrelated backends unchanged.
fm_local_hook() {
  case "$1" in
    provenance-*)
      # shellcheck source=bin/fm-local-send-provenance.sh
      . "$FM_BACKEND_LIB_DIR/fm-local-send-provenance.sh"
      case "$1" in
        provenance-init) fm_local_provenance_init "${@:2}" ;;
        provenance-typed) fm_local_provenance_typed "${@:2}" ;;
        provenance-launch) fm_local_provenance_launch "${@:2}" ;;
        provenance-remote-sent) fm_local_provenance_remote_sent ;;
        provenance-prune) fm_local_provenance_prune "${@:2}" ;;
        *) echo "error: unknown local hook: $1" >&2; return 1 ;;
      esac
      ;;
    # Restart recovery (bin/fm-local-restart-recovery.sh owns both contracts).
    restart-record)
      FM_HOME="$FM_HOME" "$FM_BACKEND_LIB_DIR/fm-local-restart-recovery.sh" record
      ;;
    secondmate-liveness-skip)
      FM_HOME="$FM_HOME" "$FM_BACKEND_LIB_DIR/fm-local-restart-recovery.sh" liveness-skip "${@:2}"
      ;;
    # The startup liveness sweep relaunches second mates one at a time, to
    # keep the load on the machine low after a restart.
    secondmate-liveness-serial) return 0 ;;
    *) echo "error: unknown local hook: $1" >&2; return 1 ;;
  esac
}
