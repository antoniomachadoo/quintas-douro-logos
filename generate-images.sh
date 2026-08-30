#!/usr/bin/env bash

set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_IMAGE="$SCRIPT_DIR/input/base.png"
LOGO_DIR="$SCRIPT_DIR/logos"
OUTPUT_DIR="$SCRIPT_DIR/output"
LOG_DIR="${TMPDIR:-/tmp}/quintas-douro-logos"
BATCH_SIZE=10
BATCH_DELAY=60

usage() {
  echo "Usage: $0 [slug ...]" >&2
  echo "With no slugs, generates an image for every PNG in logos/." >&2
}

if ! command -v codex >/dev/null 2>&1; then
  echo "Error: codex CLI is not installed or not on PATH." >&2
  exit 1
fi

if [[ ! -f "$BASE_IMAGE" ]]; then
  echo "Error: base image not found: $BASE_IMAGE" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR" "$LOG_DIR"

logos=()
if (( $# > 0 )); then
  for slug in "$@"; do
    slug="${slug%.png}"
    logo="$LOGO_DIR/$slug.png"
    if [[ ! -f "$logo" ]]; then
      echo "Error: logo not found: $logo" >&2
      usage
      exit 1
    fi
    logos+=("$logo")
  done
else
  for logo in "$LOGO_DIR"/*.png; do
    logos+=("$logo")
  done
fi

pending=()
for logo in "${logos[@]}"; do
  filename="$(basename "$logo")"
  slug="${filename%.png}"
  if [[ -s "$OUTPUT_DIR/$slug.png" ]]; then
    echo "[skip] $slug (output already exists)"
  else
    pending+=("$logo")
  fi
done
logos=("${pending[@]}")

run_one() {
  local logo="$1"
  local filename slug output log prompt

  filename="$(basename "$logo")"
  slug="${filename%.png}"
  output="$OUTPUT_DIR/$slug.png"
  log="$LOG_DIR/$slug.log"

  prompt="$(cat <<EOF
Use the imagegen skill and the built-in image generation tool to perform this image edit.

Image 1 is the edit target: a square Douro vineyard product photograph.
Image 2 is the replacement logo reference.

Replace every visible Quinta dos Murças logo and brand name in Image 1 with the complete logo from Image 2. Apply it consistently to both the transparent ice bucket and the black bottle sleeve. Keep the replacement logo recognizable and faithful to Image 2; adjust only its size, perspective, curvature, and light/dark treatment as needed to look naturally printed on each surface.

Change nothing else. Preserve the composition of the original photograph, bottles, glass, ice, food, vineyard, building, lighting, colors, depth of field, and square dimensions. Do not add text, labels, objects, or watermarks beyond what is already part of the replacement logo.

Generate exactly one final PNG. Then copy or move the generated image to this exact workspace path: output/$slug.png
Do not merely describe the edit. Verify that output/$slug.png exists before finishing.
EOF
)"

  echo "[start] $slug"
  if codex exec \
      --ephemeral \
      --sandbox workspace-write \
      --cd "$SCRIPT_DIR" \
      --image "$BASE_IMAGE" \
      --image "$logo" \
      -- "$prompt" >"$log" 2>&1; then
    if [[ -s "$output" ]]; then
      echo "[done]  $slug -> output/$slug.png"
      return 0
    fi
    echo "[fail]  $slug (Codex finished without creating output; log: $log)" >&2
  else
    echo "[fail]  $slug (log: $log)" >&2
  fi

  return 1
}

total=${#logos[@]}
failed=0

for ((start = 0; start < total; start += BATCH_SIZE)); do
  end=$((start + BATCH_SIZE))
  if (( end > total )); then
    end=$total
  fi

  echo "Batch $((start / BATCH_SIZE + 1)): items $((start + 1))-$end of $total"
  pids=()

  for ((i = start; i < end; i++)); do
    run_one "${logos[$i]}" &
    pids+=("$!")
  done

  for pid in "${pids[@]}"; do
    if ! wait "$pid"; then
      failed=1
    fi
  done

  if (( end < total )); then
    echo "Waiting ${BATCH_DELAY}s before the next batch..."
    sleep "$BATCH_DELAY"
  fi
done

exit "$failed"
