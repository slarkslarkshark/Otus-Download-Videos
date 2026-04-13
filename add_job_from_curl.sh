#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  ./add_job_from_curl.sh [--from-list FILE] [--config-file config.yaml] [--replace] [--print-only]

Description:
  Imports many videos only from file blocks in curl-list format.

Input block format (recommended):
  final_name_1.mp4
  curl 'https://.../media-2.ts' \
    -H 'referer: https://otus.ru/learning/...' \
    -H 'origin: https://otus.ru' \
    -H 'cookie: ...'

  final_name_2.mp4
  curl 'https://.../media-8.ts' \
    -H 'referer: https://otus.ru/learning/...' \
    -H 'origin: https://otus.ru'

Notes:
  - Blocks are usually separated by an empty line.

Options:
  --from-list FILE  Source file with name+curl blocks (overrides config key CURL_LIST_FILE)
  --config-file FILE YAML config file (default: ./config.yaml)
  --replace         Truncate target file before writing new jobs
  --print-only      Print parsed lines without writing to videos.list
  -h, --help        Show help
USAGE
}

CONFIG_FILE="config.yaml"
SOURCE_LIST_FILE=""
LIST_FILE="videos.list"
REPLACE=false
PRINT_ONLY=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --from-list)
      SOURCE_LIST_FILE="${2:-}"
      shift 2
      ;;
    --config-file)
      CONFIG_FILE="${2:-}"
      shift 2
      ;;
    --replace)
      REPLACE=true
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

yaml_get() {
  local key="$1"
  local default="$2"
  local val=""
  if [[ -f "$CONFIG_FILE" ]]; then
    val="$(awk -v k="$key" '
      /^[[:space:]]*#/ { next }
      {
        line=$0
        sub(/[[:space:]]+#.*$/, "", line)
        if (line ~ /^[[:space:]]*$/) next
        if (line ~ "^[[:space:]]*" k "[[:space:]]*:") {
          sub("^[[:space:]]*" k "[[:space:]]*:[[:space:]]*", "", line)
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
          if (line ~ /^".*"$/) {
            line=substr(line, 2, length(line)-2)
          }
          print line
          exit
        }
      }
    ' "$CONFIG_FILE")"
  fi
  if [[ -n "$val" ]]; then
    printf '%s' "$val"
  else
    printf '%s' "$default"
  fi
}

if [[ -z "$SOURCE_LIST_FILE" ]]; then
  SOURCE_LIST_FILE="$(yaml_get "CURL_LIST_FILE" "curl-list.txt")"
fi

trim() {
  local v="$1"
  v="${v%$'\r'}"
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  printf '%s' "$v"
}

ensure_mp4_name() {
  local name="$1"
  name="$(trim "$name")"
  if [[ -z "$name" ]]; then
    printf '\n'
    return 0
  fi
  if [[ "$name" != *.mp4 ]]; then
    name="${name}.mp4"
  fi
  printf '%s\n' "$name"
}

parse_curl_block_to_line() {
  local block_text="$1"
  local out_name="$2"

  out_name="$(ensure_mp4_name "$out_name")"

  local flat
  flat="$(printf '%s' "$block_text" | tr '\n' ' ' | sed -E 's/\\[[:space:]]*/ /g; s/[[:space:]]+/ /g')"

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
}

append_or_print_line() {
  local line="$1"
  if [[ "$PRINT_ONLY" == true ]]; then
    printf '%s\n' "$line"
  else
    printf '%s\n' "$line" >> "$LIST_FILE"
  fi
}

ADDED=0
FAILED=0

process_one() {
  local name="$1"
  local curl_block="$2"
  local parsed_line=""

  name="$(ensure_mp4_name "$name")"
  if [[ -z "$name" ]]; then
    echo "WARN: skipped block (empty output filename)"
    FAILED=$((FAILED + 1))
    return 0
  fi

  if parsed_line="$(parse_curl_block_to_line "$curl_block" "$name")"; then
    append_or_print_line "$parsed_line"
    if [[ "$PRINT_ONLY" == true ]]; then
      echo "Parsed: $name"
    else
      echo "Added: $name"
    fi
    ADDED=$((ADDED + 1))
  else
    echo "WARN: skipped '$name' (cannot parse cURL URL)"
    FAILED=$((FAILED + 1))
  fi
}

process_block_from_list() {
  local block_text="$1"
  local -a raw_lines=()
  local -a rows=()
  local first_raw first_trim
  local name=""
  local curl_block=""
  local i

  mapfile -t raw_lines <<< "$block_text"

  for i in "${!raw_lines[@]}"; do
    raw_lines[$i]="${raw_lines[$i]%$'\r'}"
    local t
    t="$(trim "${raw_lines[$i]}")"
    [[ -z "$t" ]] && continue
    [[ "$t" == \#* ]] && continue
    rows+=("${raw_lines[$i]}")
  done

  if [[ ${#rows[@]} -eq 0 ]]; then
    return 0
  fi

  first_raw="${rows[0]}"
  first_trim="$(trim "$first_raw")"

  if [[ "$first_trim" =~ ^curl[[:space:]] ]]; then
    echo "WARN: skipped block (first line must be output filename, got curl)"
    FAILED=$((FAILED + 1))
    return 0
  fi

  name="$first_trim"
  if [[ ${#rows[@]} -lt 2 ]]; then
    echo "WARN: skipped '$name' (curl block not found)"
    FAILED=$((FAILED + 1))
    return 0
  fi

  curl_block="${rows[1]}"
  for ((i=2; i<${#rows[@]}; i++)); do
    curl_block+=$'\n'
    curl_block+="${rows[$i]}"
  done

  process_one "$name" "$curl_block"
}

is_name_only_line() {
  local raw="$1"
  local t
  t="$(trim "$raw")"
  [[ -z "$t" ]] && return 1
  [[ "$t" == \#* ]] && return 1
  [[ "$t" =~ ^curl[[:space:]] ]] && return 1
  [[ "$t" =~ [[:space:]]curl[[:space:]] ]] && return 1
  [[ "$t" =~ ^- ]] && return 1
  return 0
}

process_batch_file() {
  local src_file="$1"
  local line
  local block=""
  local block_has_curl=false

  if [[ ! -f "$src_file" ]]; then
    echo "ERROR: file not found: $src_file"
    exit 1
  fi

  if [[ "$PRINT_ONLY" == false ]]; then
    touch "$LIST_FILE"
    if [[ "$REPLACE" == true ]]; then
      : > "$LIST_FILE"
    fi
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    if [[ -z "$(trim "$line")" ]]; then
      if [[ -n "$(trim "$block")" ]]; then
        process_block_from_list "$block"
        block=""
        block_has_curl=false
      fi
      continue
    fi

    if [[ -n "$(trim "$block")" && "$block_has_curl" == true ]] && is_name_only_line "$line"; then
      process_block_from_list "$block"
      block="$line"
      block_has_curl=false
      continue
    fi

    if [[ -z "$block" ]]; then
      block="$line"
    else
      block+=$'\n'
      block+="$line"
    fi

    if [[ "$(trim "$line")" =~ ^curl[[:space:]] || "$(trim "$line")" =~ [[:space:]]curl[[:space:]] ]]; then
      block_has_curl=true
    fi
  done < "$src_file"

  if [[ -n "$(trim "$block")" ]]; then
    process_block_from_list "$block"
  fi

  if [[ "$PRINT_ONLY" == true ]]; then
    echo "Done. Parsed: $ADDED, Skipped: $FAILED"
  else
    echo "Done. Added: $ADDED, Skipped: $FAILED"
  fi
}

process_batch_file "$SOURCE_LIST_FILE"
