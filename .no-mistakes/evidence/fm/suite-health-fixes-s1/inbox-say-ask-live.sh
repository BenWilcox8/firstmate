#!/usr/bin/env bash
# Live drive of fm-inbox.sh say/ask (node ports) and the ~/.local/bin node lookup.
# Only the network edge is replaced: a fake `aws` records the request body file
# and returns a canned transcript. Everything else is the real script.
set -u
ROOT=$1
NODE=$(command -v node)
H=$(mktemp -d /tmp/fm-inbox-say.XXXXXX)
NB=$(mktemp -d /tmp/fm-inbox-say-bin.XXXXXX)
for d in /run/current-system/sw/bin /etc/profiles/per-user/$USER/bin; do
  for t in "$d"/*; do
    b=$(basename "$t"); [ "$b" = node ] && continue; [ -e "$NB/$b" ] || ln -s "$t" "$NB/$b"
  done
done
mkdir -p "$H/.local/bin" "$H/state" "$H/data" "$H/cap"
ln -s "$(command -v node)" "$H/.local/bin/node"
cat > "$NB/aws" <<'AWS'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in file://*) cp "${a#file://}" "$CAP/request.json" ;; esac; done
printf '%s\n' "$*" > "$CAP/argv"
printf 'hello from the fake model\n'
AWS
chmod +x "$NB/aws"
export FM_HOME=$H HOME=$H PATH=$NB CAP=$H/cap FM_INBOX_REGION=us-test-1 FM_INBOX_STT_MODEL=stt-model FM_INBOX_ASK_MODEL=ask-model FM_INBOX_PROFILE=
run() { printf '\n$ %s\n' "$*"; "$@"; printf '[exit %s]\n' "$?"; }
echo "node on caller PATH: $(command -v node || echo none); HOME/.local/bin/node -> $(readlink "$H/.local/bin/node")"
echo "== note --json finds node through ~/.local/bin"
run "$ROOT/bin/fm-inbox.sh" note --json -- "via local bin"
echo "== say with 1 s of raw 16 kHz s16le PCM (32000 bytes + 1 odd byte)"
head -c 32001 /dev/zero > "$H/raw.pcm"
"$ROOT/bin/fm-inbox.sh" say < "$H/raw.pcm"; echo "[exit $?]"
echo "request body (audio bytes elided):"
"$NODE" -e 'const r=JSON.parse(require("fs").readFileSync(process.argv[1]));const b=Buffer.from(r[0].content[0].audio.source.bytes,"base64");console.log("wav bytes:",b.length,"riff:",b.toString("latin1",0,4),"datalen:",b.readUInt32LE(40),"rate:",b.readUInt32LE(24));r[0].content[0].audio.source.bytes="<"+b.length+" bytes>";console.log(JSON.stringify(r))' "$H/cap/request.json"
echo "raw separators in request file: $(head -c 60 "$H/cap/request.json")"
echo "saved voice note:"; cat "$(ls -t "$H"/state/inbox/*.note | head -1)"
echo "== say with a real WAV of 2.5 s at 8 kHz"
"$NODE" -e 'const n=20000;const h=Buffer.alloc(44);h.write("RIFF",0);h.writeUInt32LE(36+n*2,4);h.write("WAVEfmt ",8);h.writeUInt32LE(16,16);h.writeUInt16LE(1,20);h.writeUInt16LE(1,22);h.writeUInt32LE(8000,24);h.writeUInt32LE(16000,28);h.writeUInt16LE(2,32);h.writeUInt16LE(16,34);h.write("data",36);h.writeUInt32LE(n*2,40);require("fs").writeFileSync(process.argv[1],Buffer.concat([h,Buffer.alloc(n*2)]))' "$H/a.wav"
run "$ROOT/bin/fm-inbox.sh" say "$H/a.wav"
echo "== say refuses Ogg"
printf 'OggS\0\0\0\0' > "$H/x.ogg"
run "$ROOT/bin/fm-inbox.sh" say "$H/x.ogg"
echo "== ask with a non-ASCII question"
run "$ROOT/bin/fm-inbox.sh" ask "what does ünïcode → do?"
echo "ask request body: $(cat "$H/cap/request.json")"
rm -rf "$H" "$NB"
