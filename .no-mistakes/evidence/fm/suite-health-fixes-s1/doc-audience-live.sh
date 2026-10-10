#!/usr/bin/env bash
# Live drive of bin/fm-doc-audience-check.sh (node port) on a host with no
# python3: the real repo, then copies of it with one defect each.
set -u
ROOT=$1
echo "python3 on PATH: $(command -v python3 || echo none)"
run() { printf '\n$ %s\n' "$*"; "$@"; printf '[exit %s]\n' "$?"; }
run "$ROOT/bin/fm-doc-audience-check.sh"
fresh() {
  F=$(mktemp -d /tmp/fm-doc-aud.XXXXXX)
  git -C "$ROOT" archive HEAD | tar -x -C "$F"
  git -C "$F" init -q && git -C "$F" add -A >/dev/null
}
echo; echo "== clean copy"
fresh; run "$ROOT/bin/fm-doc-audience-check.sh" --root "$F"; rm -rf "$F"
echo; echo "== broken local link added to docs/configuration.md"
fresh; printf '\nSee [gone](missing-page.md).\n' >> "$F/docs/configuration.md"
run "$ROOT/bin/fm-doc-audience-check.sh" --root "$F"; rm -rf "$F"
echo; echo "== broken anchor"
fresh; printf '\nSee [nowhere](scripts.md#no-such-heading-here).\n' >> "$F/docs/configuration.md"
run "$ROOT/bin/fm-doc-audience-check.sh" --root "$F"; rm -rf "$F"
echo; echo "== a new tracked Markdown file with no classification"
fresh; printf '# New\n' > "$F/docs/unclassified-new.md"; git -C "$F" add docs/unclassified-new.md
run "$ROOT/bin/fm-doc-audience-check.sh" --root "$F"; rm -rf "$F"
echo; echo "== a surface with an unsupported audience"
fresh; node -e 'const f=process.argv[1];const j=JSON.parse(require("fs").readFileSync(f));j.surfaces[0].audience="pirates";require("fs").writeFileSync(f,JSON.stringify(j,null,2))' "$F/docs/documentation-audiences.json"
run "$ROOT/bin/fm-doc-audience-check.sh" --root "$F"; rm -rf "$F"
echo; echo "== inventory missing"
fresh; rm "$F/docs/documentation-audiences.json"
run "$ROOT/bin/fm-doc-audience-check.sh" --root "$F"; rm -rf "$F"
echo; echo "== inventory is not JSON"
fresh; printf '{not json' > "$F/docs/documentation-audiences.json"
run "$ROOT/bin/fm-doc-audience-check.sh" --root "$F"; rm -rf "$F"
