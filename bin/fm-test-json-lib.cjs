// fm-test-json-lib.cjs - the one owner of the JSON artifact layout that
// bin/fm-test-run.sh (--json, --aggregate-json) and
// bin/fm-test-isolation-proof.sh (--json) write. The layout is the one that
// Python's json.dump(indent=2, sort_keys=True, ensure_ascii=True) wrote before
// these writers moved to node, so the artifact bytes stay the same.
'use strict';

function dumpJson(value) {
  const sortKeys = (key, v) => {
    if (v !== null && typeof v === 'object' && !Array.isArray(v)) {
      const sorted = {};
      for (const k of Object.keys(v).sort()) sorted[k] = v[k];
      return sorted;
    }
    return v;
  };
  return JSON.stringify(value, sortKeys, 2).replace(/[^\x20-\x7e\n]/g, (c) =>
    String.fromCharCode(92) + 'u' + c.charCodeAt(0).toString(16).padStart(4, '0'));
}

// Python's int() of a record field: an optionally signed decimal integer with
// surrounding white space, and an error for any other text.
function toInt(text) {
  if (!/^\s*[-+]?[0-9]+\s*$/.test(text)) throw new Error(`invalid literal for int(): '${text}'`);
  return parseInt(text, 10);
}

module.exports = { dumpJson, toInt };
