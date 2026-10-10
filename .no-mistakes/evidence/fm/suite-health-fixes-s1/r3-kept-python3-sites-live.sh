#!/usr/bin/env bash
# Live drive: production entry points that keep python3 (scope decision A),
# run in a throwaway HOME/FM_HOME on this host with no python3. Each must stop
# with a message that names python3, and must not write the config it guards.
set -u
ROOT=$1
H=$(mktemp -d /tmp/fm-kept-py.XXXXXX)
mkdir -p "$H/.kimi-code" "$H/state" "$H/data"
printf '[general]\nname = "x"\n' > "$H/.kimi-code/config.toml"; cp "$H/.kimi-code/config.toml" "$H/before.toml"
echo "python3 on PATH: $(command -v python3 || echo none)"
run() { printf '\n$ %s\n' "$*" | sed "s|$H|<home>|g"; "$@" 2>&1 | sed "s|$H|<home>|g"; printf '[exit %s]\n' "${PIPESTATUS[0]}"; }
run env HOME="$H" "$ROOT/bin/fm-kimi-turnend-hook.sh" install
echo "config.toml unchanged after the refused install: $(cmp -s "$H/before.toml" "$H/.kimi-code/config.toml" && echo yes || echo NO)"
printf "FM_MAIL_USER=placeholder@example.invalid\nFM_MAIL_PASS=placeholder\nFM_IMAP_HOST=imap.example.invalid\nFM_SMTP_HOST=smtp.example.invalid\n" > "$H/.env"
echo; echo "(placeholder FM_MAIL_* values in the throwaway <home>/.env; .invalid hosts, never contacted)"
run env HOME="$H" FM_HOME="$H" "$ROOT/bin/fm-mail.sh" status
run "$ROOT/bin/fm-herdr-lab.sh" viewer start fm-lab-never-provisioned
rm -rf "$H"
