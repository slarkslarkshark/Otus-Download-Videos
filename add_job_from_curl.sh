#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  1) Single cURL from file:
     ./add_job_from_curl.sh --input copied_curl.txt [--name output.mp4] [--list videos.list] [--print-only]

  2) Paste many cURLs from terminal (Ctrl+D to finish):
     ./add_job_from_curl.sh --paste [--list videos.list] [--start N] [--print-only]

Options:
  --input FILE      File containing raw "Copy as cURL (bash)"
  --name NAME       Output filename for single mode (optional; auto-number if omitted)
  --paste           Read many cURL blocks from stdin and append all
  --list FILE       Target jobs file (default: videos.list)
  --start N         Start number for auto-naming in paste mode
  --print-only      Print parsed line(s) without writing
  -h, --help        Show help

Output line format:
  output.mp4|ts_url|referer|origin|cookie|ua=...
USAGE
}

INPUT_FILE=""
NAME=""
LIST_FILE="videos.list"
PRINT_ONLY=false
PASTE_MODE=false
START_NUM=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --input)
      INPUT_FILE="$2"
      shift 2
      ;;
    --name)
      NAME="$2"
      shift 2
      ;;
    --list)
      LIST_FILE="$2"
      shift 2
      ;;
    --start)
      START_NUM="$2"
      shift 2
      ;;
    --paste)
      PASTE_MODE=true
      shift
      ;;
    --print-only)
      PRINT_ONLY=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      usage
      exit 1
      ;;
  esac
done

trim() {
  local v="$1"
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  printf '%s' "$v"
}

next_numeric_name() {
  local list_file="$1"
  local start_override="$2"
  local maxn=0

  if [[ -n "$start_override" ]]; then
    if ! [[ "$start_override" =~ ^[0-9]+$ ]]; then
      echo "ERROR: --start must be an integer"
      exit 1
    fi
    printf '%s.mp4' "$start_override"
    return 0
  fi

  if [[ -f "$list_file" ]]; then
    maxn="$(awk -F'|' '
      {
        name=$1
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)
        if (name == "" || name ~ /^#/) next
        if (name ~ /^[0-9]+\.mp4$/) {
          sub(/\.mp4$/, "", name)
          n=name+0
          if (n>m) m=n
        } else if (name ~ /^[0-9]+$/) {
          n=name+0
          if (n>m) m=n
        }
      }
      END { print m+0 }
    ' "$list_file")"
  fi

  printf '%s.mp4' "$((maxn + 1))"
}

increment_numeric_name() {
  local name="$1"
  local n
  n="${name%.mp4}"
  if ! [[ "$n" =~ ^[0-9]+$ ]]; then
    echo "ERROR: internal auto-name is not numeric: $name"
    exit 1
  fi
  printf '%s.mp4' "$((n + 1))"
}

parse_curl_block_to_line() {
  local block_text="$1"
  local out_name="$2"

  if [[ "$out_name" != *.mp4 ]]; then
    out_name="${out_name}.mp4"
  fi

  local flat
  flat="$(printf '%s' "$block_text" | tr '\n' ' ' | sed -E 's/\\[[:space:]]*/ /g; s/[[:space:]]+/ /g')"

  # URL after curl '...'
  local ts_url
  ts_url="$(printf '%s' "$flat" | perl -ne 'if (/curl\s+(?:--[^\s]+\s+)*["\x27]([^"\x27]+)["\x27]/i) { print $1; exit 0 }')"
  if [[ -z "$ts_url" ]]; then
    return 1
  fi

  local headers
  headers="$(printf '%s' "$flat" | perl -ne 'while (/-H\s+["\x27]([^"\x27]+)["\x27]/g) { print "$1\n" }')"

  find_header_value() {
    local key="$1"
    printf '%s\n' "$headers" | awk -v k="$key" '
      BEGIN { IGNORECASE=1 }
      $0 ~ "^" k ":" {
        sub("^[^:]*:[[:space:]]*", "", $0)
        print
        exit
      }'
  }

  local referer origin cookie ua
  referer="$(trim "$(find_header_value "referer")")"
  origin="$(trim "$(find_header_value "origin")")"
  cookie="$(trim "$(find_header_value "cookie")")"
  ua="$(trim "$(find_header_value "user-agent")")"

  local line
  line="$out_name|$ts_url|$referer|$origin|$cookie"
  if [[ -n "$ua" ]]; then
    line="$line|ua=$ua"
  fi

  printf '%s\n' "$line"
  return 0
}

append_or_print_line() {
  local line="$1"
  if [[ "$PRINT_ONLY" == true ]]; then
    printf '%s\n' "$line"
  else
    touch "$LIST_FILE"
    printf '%s\n' "$line" >> "$LIST_FILE"
  fi
}

if [[ "$PASTE_MODE" == true ]]; then
  if [[ -n "$INPUT_FILE" || -n "$NAME" ]]; then
    echo "ERROR: --paste cannot be combined with --input/--name"
    exit 1
  fi

  local_raw="$(cat)"
  if [[ -z "$(trim "$local_raw")" ]]; then
    echo "ERROR: no input received on stdin"
    exit 1
  fi

  current_name="$(next_numeric_name "$LIST_FILE" "$START_NUM")"

  current_block=""
  added=0
  failed=0

  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^[[:space:]]*curl[[:space:]] ]]; then
      if [[ -n "$(trim "$current_block")" ]]; then
        if parsed_line="$(parse_curl_block_to_line "$current_block" "$current_name")"; then
          append_or_print_line "$parsed_line"
          echo "Added: $current_name"
          added=$((added + 1))
          current_name="$(increment_numeric_name "$current_name")"
        else
          echo "WARN: skipped block (cannot parse cURL URL)"
          failed=$((failed + 1))
        fi
      fi
      current_block="$line"
    else
      if [[ -n "$current_block" ]]; then
        current_block+=$'\n'
        current_block+="$line"
      fi
    fi
  done <<< "$local_raw"

  if [[ -n "$(trim "$current_block")" ]]; then
    if parsed_line="$(parse_curl_block_to_line "$current_block" "$current_name")"; then
      append_or_print_line "$parsed_line"
      echo "Added: $current_name"
      added=$((added + 1))
    else
      echo "WARN: skipped block (cannot parse cURL URL)"
      failed=$((failed + 1))
    fi
  fi

  echo "Done. Added: $added, Skipped: $failed"
  exit 0
fi

# Single-file mode
if [[ -z "$INPUT_FILE" ]]; then
  echo "ERROR: --input is required in single mode"
  usage
  exit 1
fi
if [[ ! -f "$INPUT_FILE" ]]; then
  echo "ERROR: file not found: $INPUT_FILE"
  exit 1
fi

if [[ -z "$NAME" ]]; then
  NAME="$(next_numeric_name "$LIST_FILE" "")"
fi

block_text="$(cat "$INPUT_FILE")"
if ! line="$(parse_curl_block_to_line "$block_text" "$NAME")"; then
  echo "ERROR: cannot parse curl URL from $INPUT_FILE"
  exit 1
fi
append_or_print_line "$line"

echo "Added job: ${NAME%.mp4}.mp4"
