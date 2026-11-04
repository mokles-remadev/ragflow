#!/usr/bin/env bash
# Bulk-load specification PDFs (scanned or digital) into a RAGFlow dataset,
# parse them with DeepDoc (layout analysis + OCR), and wait until they are indexed.
#
# Usage:
#   export RAGFLOW_API_KEY=ragflow-xxxxxxxx     # avatar → API in the RAGFlow UI
#   example/specs-db/ingest.sh /path/to/spec/pdfs
#
# Re-running is safe: files already present in the dataset (same name) are skipped.
#
# Environment:
#   RAGFLOW_API_KEY   required
#   RAGFLOW_URL       default http://localhost:9380
#   DATASET_NAME      default "specifications"
#   PARSER_ID         default "manual" (section-aware; good for numbered specs).
#                     Use "general" for loosely structured docs, "laws" for clause-style text.
#   LANGUAGE          default "English"
#   FILE_GLOB         default "*.pdf" (case-insensitive)
#   WAIT              default 1; set 0 to return right after parsing is queued
set -euo pipefail

src_dir="${1:?usage: ingest.sh <directory-with-pdfs>}"
: "${RAGFLOW_API_KEY:?set RAGFLOW_API_KEY (create one in the RAGFlow UI: avatar → API)}"
base="${RAGFLOW_URL:-http://localhost:9380}"
dataset_name="${DATASET_NAME:-specifications}"
parser_id="${PARSER_ID:-manual}"
language="${LANGUAGE:-English}"
file_glob="${FILE_GLOB:-*.pdf}"

for bin in curl jq; do command -v "$bin" >/dev/null || { echo "$bin is required" >&2; exit 1; }; done
[[ -d "$src_dir" ]] || { echo "not a directory: $src_dir" >&2; exit 1; }

auth=(-H "Authorization: Bearer ${RAGFLOW_API_KEY}")

# api METHOD PATH [curl args…] → prints .data, fails on non-zero .code
api() {
  local method="$1" path="$2"; shift 2
  local body
  body="$(curl -sS -X "$method" "${auth[@]}" "$@" "${base}/api/v1${path}")"
  if [[ "$(jq -r '.code // 1' <<<"$body" 2>/dev/null)" != "0" ]]; then
    echo "API ${method} ${path} failed: ${body}" >&2
    return 1
  fi
  jq -c '.data' <<<"$body"
}

urlenc() { jq -rn --arg v "$1" '$v|@uri'; }

# 1. Find or create the dataset.
dataset_id="$(api GET "/datasets?name=$(urlenc "$dataset_name")&page_size=100" \
  | jq -r --arg n "$dataset_name" '[.[]? | select(.name == $n)][0].id // empty')"
if [[ -z "$dataset_id" ]]; then
  echo "Creating dataset '${dataset_name}' (parser: ${parser_id})"
  dataset_id="$(api POST /datasets -H 'Content-Type: application/json' \
    --data "$(jq -n --arg name "$dataset_name" --arg lang "$language" --arg p "$parser_id" \
      '{name:$name, language:$lang, parse_type:1, parser_id:$p}')" | jq -r '.id')"
fi
echo "Dataset: ${dataset_name} (${dataset_id})"

# list_docs [extra query] → one JSON doc per line, across all pages (server caps page_size at 100).
list_docs() {
  local extra="${1:-}" page=1 batch count
  while :; do
    batch="$(api GET "/datasets/${dataset_id}/documents?page=${page}&page_size=100${extra}")"
    jq -c '.docs[]' <<<"$batch"
    count="$(jq '.docs | length' <<<"$batch")"
    (( count < 100 )) && break
    page=$((page + 1))
  done
}

# 2. Collect names already in the dataset so re-runs only add new files.
declare -A existing=()
while IFS= read -r n; do [[ -n "$n" ]] && existing["$n"]=1; done < <(list_docs | jq -r '.name')

# 3. Upload new files one at a time (keeps request size bounded for large scans).
uploaded=0 skipped=0
while IFS= read -r -d '' f; do
  name="$(basename "$f")"
  if [[ -n "${existing[$name]:-}" ]]; then skipped=$((skipped + 1)); continue; fi
  echo "Uploading ${name}"
  api POST "/datasets/${dataset_id}/documents" -F "file=@${f}" >/dev/null
  existing["$name"]=1; uploaded=$((uploaded + 1))
done < <(find "$src_dir" -type f -iname "$file_glob" -print0 | sort -z)
echo "Uploaded ${uploaded}, skipped ${skipped} already present."

# 4. Queue parsing for everything not yet parsed (new uploads plus earlier failures/unstarted).
# Go status names: UNSTART (never parsed), FAILED, STOPPED (cancelled).
pending="$(list_docs '&run=UNSTART&run=FAILED&run=STOPPED' | jq -sc '[.[].id]')"
if [[ "$(jq length <<<"$pending")" -gt 0 ]]; then
  echo "Queueing $(jq length <<<"$pending") document(s) for DeepDoc parsing + OCR"
  api POST "/datasets/${dataset_id}/chunks" -H 'Content-Type: application/json' \
    --data "$(jq -n --argjson ids "$pending" '{document_ids:$ids}')" >/dev/null
else
  echo "Nothing to parse."
fi

[[ "${WAIT:-1}" == "1" ]] || exit 0

# 5. Wait for parsing. Scanned PDFs on CPU can take a minute or more per page batch.
# Counts come from the ingestion summary; a missing field is an error, never "done".
echo "Waiting for parsing (Ctrl-C is safe; parsing continues server-side)…"
while :; do
  summary="$(api GET "/datasets/${dataset_id}/ingestions/summary")"
  if ! counts="$(jq -er '[.doc_num, .status.unstart_count, .status.running_count,
                         .status.done_count, .status.fail_count, .status.cancel_count,
                         (.chunk_num // 0)]
                        | if all(type == "number") then map(tostring) | join(" ") else false end' <<<"$summary")"; then
    echo "Unexpected ingestion summary from the server: ${summary}" >&2
    exit 1
  fi
  read -r total unstart running done_ fail cancel chunks <<<"$counts"
  printf '\r  done=%s/%s running=%s queued=%s failed=%s stopped=%s chunks=%s   ' \
    "$done_" "$total" "$running" "$unstart" "$fail" "$cancel" "$chunks"
  (( running == 0 && unstart == 0 && done_ + fail + cancel >= total )) && break
  sleep 10
done
echo
if (( fail > 0 )); then
  echo "Failed documents:"
  list_docs '&run=FAILED' | jq -r '"  \(.name): \((.progress_msg // "") | split("\n") | map(select(length > 0)) | last // "")"'
  exit 2
fi
if (( cancel > 0 )); then
  echo "${cancel} document(s) were stopped; re-run this script to queue them again." >&2
  exit 2
fi
echo "All ${total} specs indexed (${chunks} chunks). Dataset id: ${dataset_id}"
