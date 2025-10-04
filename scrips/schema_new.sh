#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# JSON Schema compile benchmark & analysis harness
# - Input:  (1) schema path or URL   (2) output directory
# - Output: bundled/variant files + timings.csv + report.txt
# - Tools:  jsonschema (sourcemeta), jq, curl, /usr/bin/time
# ============================================================

require() { command -v "$1" >/dev/null 2>&1 || { echo "error: '$1' not found in PATH" >&2; exit 127; }; }

usage() {
  cat <<'USAGE'
Usage:
  schema_bench.sh <schema.json|.yaml|URL> <output_dir>

Examples:
  schema_bench.sh https://schemas.sourcemeta.com/openapi/v3.2/schema/2025-09-17.json ~/bench/openapi
  schema_bench.sh ./geojson.schema.json ./out-geojson
USAGE
  exit 2
}

[[ $# -eq 2 ]] || usage

INPUT="$1"
OUTDIR="$(realpath -m "$2")"
mkdir -p "$OUTDIR"

# --- deps ---
require jq
require jsonschema
require curl
[[ -x /usr/bin/time ]] || { echo "error: /usr/bin/time not found"; exit 127; }
if ! command -v column >/dev/null 2>&1; then
  echo "warn: 'column' not found; report will show raw CSV table"
  COLUMN_MISSING=1
else
  COLUMN_MISSING=0
fi

timestamp() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

# Base name
if [[ "$INPUT" =~ ^https?:// ]]; then
  BASENAME="$(basename "${INPUT%%\?*}")"
else
  BASENAME="$(basename "$INPUT")"
fi
BASEROOT="${BASENAME%.*}"
SRC="$OUTDIR/${BASEROOT}.schema.json"
BUNDLE="$OUTDIR/${BASEROOT}.bundle.json"
REPORT="$OUTDIR/report.txt"
CSV="$OUTDIR/timings.csv"
LOG="$OUTDIR/run.log"
JQF="$OUTDIR/filters.jq"

exec > >(tee -a "$LOG") 2>&1

echo "== schema_bench.sh started: $(timestamp) =="
echo "Input : $INPUT"
echo "Outdir: $OUTDIR"

# ------------------------------------------------------------------
# jq helper library (portable):
# - walk/1
# - cond_empty: keep if/then/else keys but empty bodies
# - strip_refs_inside_conditionals
# - del_conditional_keys
# ------------------------------------------------------------------
cat > "$JQF" <<'JQ'
# portable walk/1 for jq < 1.6
def walk(f):
  def w:
    . as $in
    | if type == "object" then
        reduce keys[] as $k (.; .[$k] = (.[$k] | w))
      elif type == "array" then
        map( w )
      else .
      end;
  (w | f);

def cond_empty:
  walk(
    if type=="object" then
      (if has("if")   then .if   = {} else . end)
    | (if has("then") then .then = {} else . end)
    | (if has("else") then .else = {} else . end)
    else . end
  );

def strip_refs_inside_conditionals:
  walk(
    if type=="object" and (has("if") or has("then") or has("else")) then
      (if has("if")   then .if   |= walk(if type=="object" and has("$ref") then del(."$ref") else . end) else . end)
    | (if has("then") then .then |= walk(if type=="object" and has("$ref") then del(."$ref") else . end) else . end)
    | (if has("else") then .else |= walk(if type=="object" and has("$ref") then del(."$ref") else . end) else . end)
    else . end
  );

def del_conditional_keys:
  walk(if type=="object" then del(.if, .then, .else) else . end);
JQ

# --- normalize input to JSON file SRC ---
if [[ "$INPUT" =~ ^https?:// ]]; then
  echo "[fetch] downloading -> $SRC"
  curl -fsSL "$INPUT" -o "$SRC"
else
  echo "[copy] $INPUT -> $SRC"
  cp -f "$INPUT" "$SRC"
fi

# --- helpers (robust presence-based counters) ---
count_objects()       { jq '[..|objects]|length' "$1"; }
count_refs_total()    { jq --arg k '$ref' '[..|objects|select(has($k))]|length' "$1"; }
count_refs_unique()   { jq -r '..|objects|.["$ref"]? | select(.)' "$1" | sort -u | wc -l; }
count_key()           { jq --arg k "$2" '[..|objects|select(has($k))]|length' "$1"; }
count_patterns()      { jq -r '..|objects|.pattern? // empty' "$1" | wc -l; }
max_pattern_len()     { 
  local result
  result=$(jq -r '..|objects|.pattern? // empty' "$1" | awk '{print length}' | sort -nr | head -1)
  echo "${result:-0}"
}
pretty()              { jq -S . "$1" >"$2"; }

TIMEFMT="real %E  user %U  sys %S  maxrss %M KB"
compile_time() {
  local file="$1" label="$2" mode="$3"   # mode: normal|fast
  local cmd=( jsonschema compile "$file" )
  [[ "$mode" == "fast" ]] && cmd=( jsonschema compile --fast "$file" )

  # Capture ONLY /usr/bin/time's stderr; discard the compiler's stdout
  local metrics
  metrics=$({ /usr/bin/time -f "$TIMEFMT" "${cmd[@]}" >/dev/null; } 2>&1 | tr '\n' ' ')

  # Parse robustly (fill N/A if missing)
  local real="N/A" user="N/A" sys="N/A" maxrss="N/A"
  [[ -n "$metrics" ]] && real=$(sed -n 's/.*real \([^ ]*\).*/\1/p' <<<"$metrics" | head -n1 || true)
  [[ -n "$metrics" ]] && user=$(sed -n 's/.*user \([^ ]*\).*/\1/p' <<<"$metrics" | head -n1 || true)
  [[ -n "$metrics" ]] && sys=$(sed -n  's/.*sys \([^ ]*\).*/\1/p'  <<<"$metrics" | head -n1 || true)
  [[ -n "$metrics" ]] && maxrss=$(sed -n 's/.*maxrss \([^ ]*\) KB.*/\1/p' <<<"$metrics" | head -n1 || true)

  echo "$label,$mode,$real,$user,$sys,$maxrss" >> "$CSV"
}

# A small sanity block into run.log
sanity_counts() {
  local f="$1"
  echo "[sanity] $f : " \
    "objects=$(jq '[..|objects]|length' "$f")," \
    "\$ref=$(jq --arg k '$ref' '[..|objects|select(has($k))]|length' "$f")," \
    "if=$(jq --arg k if '[..|objects|select(has($k))]|length' "$f")," \
    "then=$(jq --arg k then '[..|objects|select(has($k))]|length' "$f")," \
    "else=$(jq --arg k else '[..|objects|select(has($k))]|length' "$f")," \
    "allOf=$(jq --arg k allOf '[..|objects|select(has($k))]|length' "$f")," \
    "anyOf=$(jq --arg k anyOf '[..|objects|select(has($k))]|length' "$f")," \
    "oneOf=$(jq --arg k oneOf '[..|objects|select(has($k))]|length' "$f")"
}

# --- 0) metaschema (non-fatal) ---
echo "[metaschema] checking…"
META_OK="ok"
if ! jsonschema metaschema "$SRC" >/dev/null 2>&1; then
  META_OK="fail"
  echo "warn: metaschema validation FAILED (continuing)"
fi

# --- 1) bundle ---
echo "[bundle] -> $BUNDLE"
jsonschema bundle "$SRC" > "$BUNDLE"

# --- sanity to log
sanity_counts "$BUNDLE"

# --- 2) base stats for SRC & BUNDLE (using mapfile so we don't lose values) ---
SRC_LINES=$(wc -l < "$SRC");   SRC_BYTES=$(stat -c%s "$SRC")
BUN_LINES=$(wc -l < "$BUNDLE");BUN_BYTES=$(stat -c%s "$BUNDLE")

base_stats() {
  local f="$1"
  count_objects "$f"
  count_refs_total "$f"
  count_refs_unique "$f"
  count_key "$f" allOf
  count_key "$f" anyOf
  count_key "$f" oneOf
  count_key "$f" not
  count_key "$f" if
  count_key "$f" then
  count_key "$f" else
  count_key "$f" dependentSchemas
  count_key "$f" unevaluatedProperties
  count_patterns "$f"
  max_pattern_len "$f"
}

echo "[stats] collecting…"
mapfile -t SRC_ARR < <(base_stats "$SRC")
mapfile -t BUN_ARR < <(base_stats "$BUNDLE")

SRC_OBJ=${SRC_ARR[0]}
SRC_REFS_T=${SRC_ARR[1]}
SRC_REFS_U=${SRC_ARR[2]}
SRC_allOf=${SRC_ARR[3]}
SRC_anyOf=${SRC_ARR[4]}
SRC_oneOf=${SRC_ARR[5]}
SRC_not=${SRC_ARR[6]}
SRC_if=${SRC_ARR[7]}
SRC_then=${SRC_ARR[8]}
SRC_else=${SRC_ARR[9]}
SRC_depSchemas=${SRC_ARR[10]}
SRC_uneval=${SRC_ARR[11]}
SRC_pat=${SRC_ARR[12]}
SRC_patmax=${SRC_ARR[13]}

BUN_OBJ=${BUN_ARR[0]}
BUN_REFS_T=${BUN_ARR[1]}
BUN_REFS_U=${BUN_ARR[2]}
BUN_allOf=${BUN_ARR[3]}
BUN_anyOf=${BUN_ARR[4]}
BUN_oneOf=${BUN_ARR[5]}
BUN_not=${BUN_ARR[6]}
BUN_if=${BUN_ARR[7]}
BUN_then=${BUN_ARR[8]}
BUN_else=${BUN_ARR[9]}
BUN_depSchemas=${BUN_ARR[10]}
BUN_uneval=${BUN_ARR[11]}
BUN_pat=${BUN_ARR[12]}
BUN_patmax=${BUN_ARR[13]}

# --- 3) variants (ablations) ---
mk() { jq "$2" "$BUNDLE" > "$1"; }

V_NO_COND="$OUTDIR/${BASEROOT}.no-conditionals.json"
V_NO_DEPS="$OUTDIR/${BASEROOT}.no-depschemas.json"
V_NO_UNEV="$OUTDIR/${BASEROOT}.no-uneval.json"
V_REFS_ONLY="$OUTDIR/${BASEROOT}.refs-only.json"
V_ONLY_ALLOF="$OUTDIR/${BASEROOT}.only-allof.json"
V_NO_ANYOF="$OUTDIR/${BASEROOT}.no-anyof.json"
V_NO_ONEOF="$OUTDIR/${BASEROOT}.no-oneof.json"
V_NO_ALLOF="$OUTDIR/${BASEROOT}.no-allof.json"
V_COND_EMPTY="$OUTDIR/${BASEROOT}.conditionals-empty.json"
V_NO_REFS_IN_COND="$OUTDIR/${BASEROOT}.no-refs-inside-conditionals.json"
V_NO_COND_KEYS="$OUTDIR/${BASEROOT}.no-conditional-keys.json"

echo "[variants] building ablations…"

# Simple deletions (no walk required)
mk "$V_NO_COND" 'del(..|objects|.if?, .then?, .else?)'
mk "$V_NO_DEPS" 'del(..|objects|."dependentSchemas"?)'
mk "$V_NO_UNEV" 'del(..|objects|."unevaluatedProperties"?)'
mk "$V_REFS_ONLY" 'del(..|objects|.allOf?, .anyOf?, .oneOf?, .not?, .if?, .then?, .else?, ."dependentSchemas"?, ."unevaluatedProperties"?)'
mk "$V_ONLY_ALLOF" 'del(..|objects|.if?, .then?, .else?, ."dependentSchemas"?, ."unevaluatedProperties"?)'
mk "$V_NO_ANYOF" 'del(..|objects|.anyOf?)'
mk "$V_NO_ONEOF" 'del(..|objects|.oneOf?)'
mk "$V_NO_ALLOF" 'del(..|objects|.allOf?)'

# Functions from filters.jq - create temporary filter files
TMP1="$OUTDIR/.tmp_cond_empty.jq"
TMP2="$OUTDIR/.tmp_strip_refs.jq"
TMP3="$OUTDIR/.tmp_del_cond.jq"

cat "$JQF" > "$TMP1"
echo "cond_empty" >> "$TMP1"
jq -f "$TMP1" "$BUNDLE" > "$V_COND_EMPTY"

cat "$JQF" > "$TMP2"
echo "strip_refs_inside_conditionals" >> "$TMP2"
jq -f "$TMP2" "$BUNDLE" > "$V_NO_REFS_IN_COND"

cat "$JQF" > "$TMP3"
echo "del_conditional_keys" >> "$TMP3"
jq -f "$TMP3" "$BUNDLE" > "$V_NO_COND_KEYS"

# Clean up temp files
rm -f "$TMP1" "$TMP2" "$TMP3"

VARIANTS=(
  "$BUNDLE:baseline"
  "$V_NO_COND:no-conditionals"
  "$V_NO_DEPS:no-depschemas"
  "$V_NO_UNEV:no-uneval"
  "$V_REFS_ONLY:refs-only"
  "$V_ONLY_ALLOF:only-allof"
  "$V_NO_ANYOF:no-anyof"
  "$V_NO_ONEOF:no-oneof"
  "$V_NO_ALLOF:no-allof"
  "$V_COND_EMPTY:conditionals-empty"
  "$V_NO_REFS_IN_COND:no-refs-inside-conditionals"
  "$V_NO_COND_KEYS:no-conditional-keys"
)

# --- 4) timings + per-variant stats ---
echo "variant,mode,real,user,sys,maxrss_kb" > "$CSV"
for pair in "${VARIANTS[@]}"; do
  FILE="${pair%%:*}"; LABEL="${pair##*:}"
  echo "[compile] $LABEL (normal/fast)…"
  compile_time "$FILE" "$LABEL" "normal"
  compile_time "$FILE" "$LABEL" "fast"
done

# Per-file block printer (like your OMC notes)
dump_block() {
  local f="$1" title="$2"
  local objs refs allOf anyOf oneOf not ifk thenk elsek deps uneval
  objs=$(count_objects "$f")
  refs=$(count_refs_total "$f")
  allOf=$(count_key "$f" allOf)
  anyOf=$(count_key "$f" anyOf)
  oneOf=$(count_key "$f" oneOf)
  not=$(count_key "$f" not)
  ifk=$(count_key "$f" if)
  thenk=$(count_key "$f" then)
  elsek=$(count_key "$f" else)
  deps=$(count_key "$f" dependentSchemas)
  uneval=$(count_key "$f" unevaluatedProperties)

  echo "=== $title ==="
  echo "objects: $objs"
  echo
  echo '$ref:    '"$refs"
  printf "%-20s %s\n" "allOf:" "$allOf"
  printf "%-20s %s\n" "oneOf:" "$oneOf"
  printf "%-20s %s\n" "anyOf:" "$anyOf"
  printf "%-20s %s\n" "not:" "$not"
  printf "%-20s %s\n" "if:" "$ifk"
  printf "%-20s %s\n" "then:" "$thenk"
  printf "%-20s %s\n" "else:" "$elsek"
  printf "%-20s %s\n" "dependentSchemas:" "$deps"
  printf "%-20s %s\n" "unevaluatedProperties:" "$uneval"
  echo
}

# --- 5) generate report.txt ---
{
  echo "JSON Schema Compile Report"
  echo "Generated: $(timestamp)"
  echo
  echo "Input: $INPUT"
  echo "Outdir: $OUTDIR"
  echo "Metaschema: $META_OK"
  echo
  printf "Source:  %7d lines, %8d bytes, objects=%d, \$ref=%d (%d unique)\n" "$SRC_LINES" "$SRC_BYTES" "$SRC_OBJ" "$SRC_REFS_T" "$SRC_REFS_U"
  printf "Bundle:  %7d lines, %8d bytes, objects=%d, \$ref=%d (%d unique)\n" "$BUN_LINES" "$BUN_BYTES" "$BUN_OBJ" "$BUN_REFS_T" "$BUN_REFS_U"
  echo
  echo "Keyword counts (bundle):"
  printf "  allOf=%-6d anyOf=%-6d oneOf=%-6d not=%-6d if=%-6d then=%-6d else=%-6d depSchemas=%-6d unevaluatedProperties=%-6d\n" \
    "$BUN_allOf" "$BUN_anyOf" "$BUN_oneOf" "$BUN_not" "$BUN_if" "$BUN_then" "$BUN_else" "$BUN_depSchemas" "$BUN_uneval"
  printf "  patterns=%-6d max_pattern_len=%s\n" "$BUN_pat" "${BUN_patmax:-0}"
  echo
  echo "Timings (see timings.csv for full):"
  if [[ "$COLUMN_MISSING" -eq 0 ]]; then
    column -s, -t "$CSV"
  else
    cat "$CSV"
  fi
  echo
  echo "Per-variant structural counts"
  echo
  dump_block "$BUNDLE"                    "${BASEROOT}.bundle.json"
  dump_block "$V_NO_COND"                 "${BASEROOT}.no-conditionals.json"
  dump_block "$V_NO_DEPS"                 "${BASEROOT}.no-depschemas.json"
  dump_block "$V_NO_UNEV"                 "${BASEROOT}.no-uneval.json"
  dump_block "$V_REFS_ONLY"               "${BASEROOT}.refs-only.json"
  dump_block "$V_ONLY_ALLOF"              "${BASEROOT}.only-allof.json"
  dump_block "$V_NO_ANYOF"                "${BASEROOT}.no-anyof.json"
  dump_block "$V_NO_ONEOF"                "${BASEROOT}.no-oneof.json"
  dump_block "$V_NO_ALLOF"                "${BASEROOT}.no-allof.json"
  dump_block "$V_COND_EMPTY"              "${BASEROOT}.conditionals-empty.json"
  dump_block "$V_NO_REFS_IN_COND"         "${BASEROOT}.no-refs-inside-conditionals.json"
  dump_block "$V_NO_COND_KEYS"            "${BASEROOT}.no-conditional-keys.json"
} > "$REPORT"

echo "== done: $(timestamp) =="
echo "Artifacts:"
ls -lh "$OUTDIR" | sed 's/^/  /'