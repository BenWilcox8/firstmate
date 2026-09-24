#!/usr/bin/env bash
# Manual E2E: drive bin/fm-send.sh at a registered Codex worker over a stand-in tmux,
# then show the typed pane bytes and the persisted provenance JSONL (public record contract).
set -u
unset NO_MISTAKES_GATE; export FM_GATE_REFUSE_BYPASS=1  # isolated temp FM_HOME and stand-in tmux; tests/lib.sh does the same
ROOT=${1:?repo root}
PROV_T=$(mktemp -d); mkdir -p "$PROV_T/bin" "$PROV_T/home/state"
export PROV_T
cat > "$PROV_T/bin/tmux" <<'SH'
#!/usr/bin/env bash
case "$1" in
  send-keys) if [ "${4:-}" = -l ]; then printf '%s' "$5" > "$PROV_T/typed"; fi ;;
  display-message) case "$*" in *cursor_y*) printf '1\n' ;; *) printf '%%7\n' ;; esac ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n' ;;
  list-windows) printf 'win\n' ;;
esac
SH
printf '#!/usr/bin/env bash\nexit 0\n' > "$PROV_T/bin/sleep"; chmod +x "$PROV_T/bin/"*
export PATH="$PROV_T/bin:$PATH" FM_HOME="$PROV_T/home" FM_ROOT_OVERRIDE="$PROV_T/home" FM_SEND_SETTLE=0
printf 'window=sess:win\nkind=ship\nharness=codex\n' > "$FM_HOME/state/worker.meta"
for msg in '$no-mistakes' 'please continue'; do
  echo "\$ fm-send.sh worker '$msg'"
  "$ROOT/bin/fm-send.sh" worker "$msg"; echo "rc=$?"
  echo "typed into pane: $(cat "$PROV_T/typed")"
done
echo; echo "== inbox =="; ls "$FM_HOME/state" | grep -i inbox || true
echo; echo "== state/local-send-provenance/*.jsonl =="
for f in "$FM_HOME"/state/local-send-provenance/*.jsonl; do echo "# ${f#$FM_HOME/}"; cat "$f"; done
rm -rf "$PROV_T"
