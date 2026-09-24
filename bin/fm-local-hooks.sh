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
    *) echo "error: unknown local hook: $1" >&2; return 1 ;;
  esac
}
