// fm-test-json-lib.cjs - the one owner of the JSON artifact layout that
// bin/fm-test-run.sh (--json, --aggregate-json) and
// bin/fm-test-isolation-proof.sh (--json) write, and of the record files they
// read. The layout is the one that Python's
// json.dump(indent=2, sort_keys=True, ensure_ascii=True) wrote before these
// writers moved to node, so the artifact bytes stay the same.
'use strict';

const fs = require('fs');

// Python str order: by code point, where JS sort compares UTF-16 code units.
function byCodePoint(a, b) {
  const x = Array.from(a, (c) => c.codePointAt(0));
  const y = Array.from(b, (c) => c.codePointAt(0));
  for (let i = 0; i < x.length && i < y.length; i++) {
    if (x[i] !== y[i]) return x[i] - y[i];
  }
  return x.length - y.length;
}

// Built by hand, because a JS object always lists integer-like keys first.
function dumpJson(value) {
  const leaf = (v) => JSON.stringify(v).replace(/[^\x20-\x7e]/g, (c) =>
    String.fromCharCode(92) + 'u' + c.charCodeAt(0).toString(16).padStart(4, '0'));
  const encode = (v, indent) => {
    if (v === null || typeof v !== 'object') return leaf(v);
    const inner = indent + '  ';
    const items = Array.isArray(v)
      ? v.map((x) => inner + encode(x, inner))
      : Object.keys(v).sort(byCodePoint).map((k) => inner + leaf(k) + ': ' + encode(v[k], inner));
    const [open, close] = Array.isArray(v) ? ['[', ']'] : ['{', '}'];
    if (items.length === 0) return open + close;
    return open + '\n' + items.join(',\n') + '\n' + indent + close;
  };
  return encode(value, '');
}

// Python's int() of a record field: an optionally signed decimal integer with
// surrounding white space, and an error for any other text.
function toInt(text) {
  if (!/^\s*[-+]?[0-9]+(?:_[0-9]+)*\s*$/.test(text)) throw new Error(`invalid literal for int(): '${text}'`);
  return parseInt(text.replace(/_/g, ''), 10);
}

// Python's open(file, encoding="utf-8").read(): bytes that are not UTF-8 are an
// error, and a leading byte order mark stays in the text.
function readUtf8(file) {
  return new TextDecoder('utf-8', { fatal: true, ignoreBOM: true }).decode(fs.readFileSync(file));
}

// The tab-separated records of <file>, one per non-empty line. As in Python
// text mode, "\r\n", "\r", and "\n" each end a line.
function rows(file, width) {
  const result = [];
  for (const line of readUtf8(file).split(/\r\n|\r|\n/)) {
    if (!line) continue;
    const cols = line.split('\t');
    if (cols.length !== width) throw new Error(`malformed record in ${file}: expected ${width} fields, got ${cols.length}`);
    result.push(cols);
  }
  return result;
}

module.exports = { byCodePoint, dumpJson, readUtf8, rows, toInt };
