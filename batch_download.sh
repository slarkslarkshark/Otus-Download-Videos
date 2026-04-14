#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  ./batch_download.sh [options]

Batch download and assemble multiple HLS videos.

Input format (pipe-separated file):
  output_name.mp4|https://.../media-2.ts|referer(required)|origin(optional)|cookie(optional)|ua=...(optional)

Options:
  --output-dir DIR       Final MP4 directory (default: downloads)
  --work-dir DIR         Logs/temp directory (default: logs)
  --skip-existing yes|no Skip jobs with existing output (default: yes)
  --reuse-segments yes|no Reuse already downloaded segment files (default: yes)
  --assemble-only yes|no  Skip network and run only ffmpeg on existing local files (default: no)
  --config-file FILE     YAML config file to load (default: ./config.yaml)
  --dry-run              Validate and print jobs without network/download
  -h, --help             Show help

YAML config keys (optional):
  BATCH_OUTPUT_DIR: downloads
  BATCH_LOGS_DIR: logs
  BATCH_RETRIES: 2
  SKIP_EXISTING: yes
  REUSE_SEGMENTS: yes
  ASSEMBLE_ONLY: no
USAGE
}

CONFIG_FILE="config.yaml"
CLI_OUTPUT_DIR=""
CLI_LOGS_DIR=""
CLI_SKIP_EXISTING=""
CLI_REUSE_SEGMENTS=""
CLI_ASSEMBLE_ONLY=""
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir)
      CLI_OUTPUT_DIR="$2"
      shift 2
      ;;
    --work-dir)
      CLI_LOGS_DIR="$2"
      shift 2
      ;;
    --skip-existing)
      CLI_SKIP_EXISTING="$2"
      shift 2
      ;;
    --reuse-segments)
      CLI_REUSE_SEGMENTS="$2"
      shift 2
      ;;
    --assemble-only)
      CLI_ASSEMBLE_ONLY="$2"
      shift 2
      ;;
    --config-file)
      CONFIG_FILE="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
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

LIST_FILE="videos.list"
OUTPUT_DIR="${CLI_OUTPUT_DIR:-$(yaml_get "BATCH_OUTPUT_DIR" "downloads")}"
LOGS_DIR="${CLI_LOGS_DIR:-$(yaml_get "BATCH_LOGS_DIR" "logs")}"
RETRIES="$(yaml_get "BATCH_RETRIES" "2")"
SKIP_EXISTING="${CLI_SKIP_EXISTING:-$(yaml_get "SKIP_EXISTING" "yes")}"
REUSE_SEGMENTS="${CLI_REUSE_SEGMENTS:-$(yaml_get "REUSE_SEGMENTS" "yes")}"
ASSEMBLE_ONLY="${CLI_ASSEMBLE_ONLY:-$(yaml_get "ASSEMBLE_ONLY" "no")}"
FALLBACK_USER_AGENT="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36"

is_yes() {
  case "${1,,}" in
    1|y|yes|true) return 0 ;;
    *) return 1 ;;
  esac
}

trim() {
  local v="$1"
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  printf '%s' "$v"
}

sanitize_name() {
  printf '%s' "$1" | sed -E 's#[^A-Za-z0-9._-]+#_#g'
}

job_id() {
  local output_name="$1"
  local ts_url="$2"
  # Stable id across runs, independent of line order in videos.list.
  printf '%s|%s' "$output_name" "$ts_url" | cksum | awk '{print $1}'
}

require_bin() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "ERROR: required command not found: $1"
    exit 1
  fi
}

add_unique() {
  local candidate="$1"
  local -n arr_ref="$2"
  local item
  for item in "${arr_ref[@]:-}"; do
    [[ "$item" == "$candidate" ]] && return 0
  done
  arr_ref+=("$candidate")
}

derive_base_candidates() {
  local ts_url="$1"
  local -n out_ref="$2"
  out_ref=()

  local normalized
  local parent

  normalized="$(printf '%s' "$ts_url" | sed -E 's#https://cdnv-([^/]+)/vod/size%3A[^/]+/duration%3A[^/]+/fragment%3A[^/]+/#https://\1/vod/#; s#/media-[0-9]+\.ts$##')"
  if [[ "$normalized" == "$ts_url" ]]; then
    parent="${ts_url%/media-*}"
  else
    parent="$normalized"
  fi

  add_unique "$parent" out_ref
  add_unique "$(printf '%s' "$parent" | sed -E 's#https://[^/]+#https://m1.boomstream.com#')" out_ref
  add_unique "$(printf '%s' "$parent" | sed -E 's#https://[^/]+#https://m2.boomstream.com#')" out_ref
  add_unique "$(printf '%s' "$parent" | sed -E 's#https://[^/]+#https://m3.boomstream.com#')" out_ref
  add_unique "${parent%/*}" out_ref
}

build_curl_headers() {
  local referer="$1"
  local origin="$2"
  local cookie="$3"
  local ua="$4"
  local -n headers_ref="$5"

  headers_ref=(-H "User-Agent: $ua")
  [[ -n "$referer" ]] && headers_ref+=(-H "Referer: $referer")
  [[ -n "$origin" ]] && headers_ref+=(-H "Origin: $origin")
  [[ -n "$cookie" ]] && headers_ref+=(-H "Cookie: $cookie")
  return 0
}

fetch_to_file() {
  local url="$1"
  local out_file="$2"
  local retries="$3"
  local -n hdrs_ref="$4"
  curl -fL -s --retry "$retries" "${hdrs_ref[@]}" "$url" -o "$out_file"
}

absolutize_url() {
  local base="$1"
  local rel="$2"
  if [[ "$rel" =~ ^https?:// ]]; then
    printf '%s' "$rel"
    return 0
  fi
  if [[ "$rel" == /* ]]; then
    local root
    root="$(printf '%s' "$base" | sed -E 's#(https?://[^/]+).*#\1#')"
    printf '%s%s' "$root" "$rel"
    return 0
  fi
  printf '%s/%s' "$base" "$rel"
}

resolve_media_playlist_if_master() {
  local playlist_file="$1"
  local playlist_base="$2"
  local retries="$3"
  local job_dir="$4"
  local -n headers_ref="$5"
  local -n out_playlist_file_ref="$6"
  local -n out_playlist_base_ref="$7"
  local child_rel
  local child_url
  local child_file
  local child_base

  out_playlist_file_ref="$playlist_file"
  out_playlist_base_ref="$playlist_base"

  if ! grep -q '^#EXT-X-STREAM-INF' "$playlist_file"; then
    return 0
  fi

  child_rel="$(awk '
    /^#EXT-X-STREAM-INF/ { f=1; next }
    f && $0 !~ /^#/ && $0 !~ /^[[:space:]]*$/ { print; exit }
  ' "$playlist_file")"

  if [[ -z "$child_rel" ]]; then
    return 0
  fi

  child_url="$(absolutize_url "$playlist_base" "$child_rel")"
  child_file="$job_dir/playlist_media.m3u8"
  if ! fetch_to_file "$child_url" "$child_file" "$retries" headers_ref; then
    return 1
  fi
  if ! grep -qE '^#EXTM3U' "$child_file"; then
    return 1
  fi

  child_base="${child_url%/*}"
  out_playlist_file_ref="$child_file"
  out_playlist_base_ref="$child_base"
  return 0
}

discover_playlist() {
  local ts_url="$1"
  local retries="$2"
  local job_dir="$3"
  local -n headers_ref="$4"
  local -n out_playlist_url_ref="$5"
  local -n out_base_ref="$6"
  local -n out_playlist_file_ref="$7"

  local -a bases
  local -a playlist_names=(chunklist.m3u8 playlist.m3u8 manifest.m3u8 index.m3u8)
  local base
  local pl
  local try_i=0
  local url
  local tmp

  derive_base_candidates "$ts_url" bases

  for base in "${bases[@]}"; do
    for pl in "${playlist_names[@]}"; do
      try_i=$((try_i + 1))
      url="$base/$pl"
      tmp="$job_dir/playlist_try_${try_i}.m3u8"
      if fetch_to_file "$url" "$tmp" "$retries" headers_ref; then
        if grep -qE '^#EXTM3U' "$tmp"; then
          out_playlist_url_ref="$url"
          out_base_ref="$base"
          out_playlist_file_ref="$tmp"
          return 0
        fi
      fi
      rm -f "$tmp"
    done
  done

  return 1
}

extract_key_uri() {
  local playlist_file="$1"
  local key_uri
  key_uri="$(grep -m1 '#EXT-X-KEY' "$playlist_file" 2>/dev/null | sed -n 's/.*URI="\([^"]*\)".*/\1/p' || true)"
  if [[ -z "$key_uri" ]]; then
    key_uri="$(grep -m1 '#EXT-X-KEY' "$playlist_file" 2>/dev/null | sed -n "s/.*URI='\\([^']*\\)'.*/\\1/p" || true)"
  fi
  printf '%s' "$key_uri"
}

download_key_file() {
  local key_uri="$1"
  local base="$2"
  local out_key_file="$3"
  local retries="$4"
  local -n headers_ref="$5"
  local -n key_source_ref="$6"
  local -a candidates=()
  local key_url

  key_source_ref=""

  if [[ -z "$key_uri" ]]; then
    return 1
  fi

  if [[ "$key_uri" == "[KEY]" ]]; then
    candidates+=("$base/key.bin" "$base/key.key" "$base/encryption.key")
  elif [[ "$key_uri" =~ ^https?:// ]]; then
    candidates+=("$key_uri")
  else
    candidates+=("$base/$key_uri")
  fi

  for key_url in "${candidates[@]}"; do
    if fetch_to_file "$key_url" "$out_key_file" "$retries" headers_ref; then
      if [[ -s "$out_key_file" ]]; then
        key_source_ref="$key_url"
        return 0
      fi
    fi
  done

  rm -f "$out_key_file"
  return 1
}

build_local_playlist() {
  local src_playlist="$1"
  local dest_playlist="$2"
  local playlist_base="$3"
  local key_replacement="$4"

  sed -E "s/URI='([^']*)'/URI=\"\\1\"/g" "$src_playlist" | \
    awk -v base="$playlist_base" -v key_uri="$key_replacement" '
      /^#EXT-X-KEY/ {
        gsub(/,IV=\[IV\]/, "")
        if (key_uri != "") {
          gsub(/URI="[^"]*"/, "URI=\"" key_uri "\"")
        }
        print
        next
      }
      /^#/ { print; next }
      /^[[:space:]]*$/ { next }
      {
        if ($0 ~ /^https?:\/\//) {
          print
          next
        }
        gsub(/^[.]\//, "", $0)
        print base "/" $0
      }' > "$dest_playlist"
}

materialize_playlist_local() {
  local src_playlist="$1"
  local dst_playlist="$2"
  local seg_dir="$3"
  local retries="$4"
  local -n headers_ref="$5"
  local status_prefix="$6"
  local reuse_segments="$7"
  local total_segments
  local idx=0
  local line
  local out_seg
  local abs_seg
  local reused_count=0

  mkdir -p "$seg_dir"
  : > "$dst_playlist"
  total_segments="$(awk 'BEGIN{c=0} !/^#/ && $0 !~ /^[[:space:]]*$/ {c++} END{print c}' "$src_playlist")"
  echo "${status_prefix} SEGMENTS: 0/${total_segments}"

  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == \#* ]] || [[ -z "$line" ]]; then
      printf '%s\n' "$line" >> "$dst_playlist"
      continue
    fi

    idx=$((idx + 1))
    out_seg="$seg_dir/seg_$(printf '%06d' "$idx").ts"
    if is_yes "$reuse_segments" && [[ -s "$out_seg" ]]; then
      reused_count=$((reused_count + 1))
    else
      if ! fetch_to_file "$line" "$out_seg" "$retries" headers_ref; then
        echo "Failed to download segment: $line"
        return 1
      fi
    fi
    abs_seg="$(readlink -f "$out_seg")"
    printf '%s\n' "$abs_seg" >> "$dst_playlist"

    if [[ "$idx" -eq 1 || "$idx" -eq "$total_segments" || $((idx % 50)) -eq 0 ]]; then
      echo "${status_prefix} SEGMENTS: ${idx}/${total_segments}"
    fi
  done < "$src_playlist"

  if [[ "$reused_count" -gt 0 ]]; then
    echo "${status_prefix} SEGMENTS: reused ${reused_count}/${total_segments}"
  fi
  return 0
}

if [[ ! -f "$LIST_FILE" ]]; then
  echo "ERROR: jobs file not found: $LIST_FILE"
  exit 1
fi

require_bin curl
require_bin ffmpeg
require_bin awk
require_bin sed
require_bin grep

mkdir -p "$OUTPUT_DIR" "$LOGS_DIR"

umask 077

total=0
success=0
failed=0
skipped=0
job_index=0
TOTAL_JOBS="$(awk -F'|' '
  {
    l=$1
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", l)
    if (l == "" || l ~ /^#/) next
    c++
  }
  END { print c+0 }
' "$LIST_FILE")"

echo "Using list: $LIST_FILE"
echo "Output dir: $OUTPUT_DIR"
echo "Logs dir: $LOGS_DIR"
echo "Jobs total: $TOTAL_JOBS"
echo ""

line_no=0
while IFS='|' read -r raw_output raw_ts raw_referer raw_origin raw_cookie raw_extra <&3 || [[ -n "${raw_output:-}${raw_ts:-}${raw_referer:-}${raw_origin:-}${raw_cookie:-}${raw_extra:-}" ]]; do
  line_no=$((line_no + 1))

  output_name="$(trim "${raw_output:-}")"
  ts_url="$(trim "${raw_ts:-}")"

  if [[ -z "$output_name" && -z "$ts_url" ]]; then
    continue
  fi
  if [[ "${output_name:0:1}" == "#" ]]; then
    continue
  fi

  total=$((total + 1))
  job_index=$((job_index + 1))

  if [[ -z "$output_name" ]]; then
    echo "[line $line_no][job $job_index/$TOTAL_JOBS] FAIL: output name is empty"
    failed=$((failed + 1))
    continue
  fi

  if [[ -z "$ts_url" ]]; then
    echo "[line $line_no][job $job_index/$TOTAL_JOBS] FAIL: ts_url is empty"
    failed=$((failed + 1))
    continue
  fi

  if [[ "$output_name" != *.mp4 ]]; then
    output_name="${output_name}.mp4"
  fi

  referer="$(trim "${raw_referer:-}")"
  origin="$(trim "${raw_origin:-}")"
  cookie="$(trim "${raw_cookie:-}")"
  extra="$(trim "${raw_extra:-}")"
  user_agent="$FALLBACK_USER_AGENT"
  if [[ -n "$extra" ]]; then
    if [[ "$extra" == ua=* ]]; then
      user_agent="${extra#ua=}"
    else
      user_agent="$extra"
    fi
  fi

  if [[ -z "$referer" ]]; then
    echo "[line $line_no][job $job_index/$TOTAL_JOBS] FAIL: referer is required (must come from curl block)"
    failed=$((failed + 1))
    continue
  fi

  output_path="$OUTPUT_DIR/$output_name"
  safe_job_name="$(sanitize_name "$output_name")"
  stable_id="$(job_id "$output_name" "$ts_url")"
  job_dir="$LOGS_DIR/${safe_job_name}__${stable_id}"
  job_log="$job_dir/job.log"

  # One-time migration from old line-based folders to stable folder naming.
  if [[ ! -d "$job_dir" ]]; then
    legacy_job_dir="$(find "$LOGS_DIR" -maxdepth 1 -type d -name "*_${safe_job_name}" | head -n 1 || true)"
    if [[ -n "${legacy_job_dir:-}" && -d "$legacy_job_dir" ]]; then
      mv "$legacy_job_dir" "$job_dir" 2>/dev/null || true
    fi
  fi

  if is_yes "$SKIP_EXISTING" && [[ -s "$output_path" ]]; then
    echo "[line $line_no][job $job_index/$TOTAL_JOBS] SKIP: exists -> $output_path"
    skipped=$((skipped + 1))
    continue
  fi

  status_prefix="[line $line_no][job $job_index/$TOTAL_JOBS]"
  echo "$status_prefix START: $output_name"

  if [[ "$DRY_RUN" == true ]]; then
    echo "$status_prefix DRY-RUN: validated"
    success=$((success + 1))
    continue
  fi

  mkdir -p "$job_dir"
  : > "$job_log"

  {
    echo "Line: $line_no"
    echo "Output: $output_name"
    echo "TS URL: $ts_url"
    echo "Referer: $referer"
    if [[ -n "$origin" ]]; then
      echo "Origin: $origin"
    fi
    if [[ -n "$cookie" ]]; then
      echo "Cookie: [set]"
    fi
    if [[ -n "${raw_extra:-}" ]]; then
      echo "Extra columns: ignored"
    fi
  } >> "$job_log"

  curl_headers=()
  build_curl_headers "$referer" "$origin" "$cookie" "$user_agent" curl_headers

  playlist_url=""
  playlist_base=""
  playlist_file=""
  local_playlist="$job_dir/playlist_local.m3u8"
  if is_yes "$ASSEMBLE_ONLY"; then
    if [[ ! -f "$local_playlist" ]]; then
      echo "$status_prefix FAIL: assemble-only requested but missing $local_playlist"
      echo "FAIL: assemble-only missing local playlist" >> "$job_log"
      failed=$((failed + 1))
      continue
    fi
    echo "$status_prefix STEP 1/1: assembling from existing local files..."
  else
    echo "$status_prefix STEP 1/4: discovering playlist..."
    if ! discover_playlist "$ts_url" "$RETRIES" "$job_dir" curl_headers playlist_url playlist_base playlist_file; then
      echo "$status_prefix FAIL: playlist not found"
      echo "FAIL: playlist not found" >> "$job_log"
      failed=$((failed + 1))
      continue
    fi

    echo "$status_prefix STEP 1/4: playlist found"
    if ! resolve_media_playlist_if_master "$playlist_file" "$playlist_base" "$RETRIES" "$job_dir" curl_headers playlist_file playlist_base; then
      echo "$status_prefix FAIL: cannot resolve media playlist from master"
      echo "FAIL: cannot resolve media playlist from master" >> "$job_log"
      failed=$((failed + 1))
      continue
    fi

    echo "Playlist URL: $playlist_url" >> "$job_log"

    key_uri="$(extract_key_uri "$playlist_file")"
    key_file="$job_dir/key.bin"
    key_source=""
    key_replace=""

    if [[ -n "$key_uri" ]]; then
      echo "$status_prefix STEP 2/4: resolving key..."
      if download_key_file "$key_uri" "$playlist_base" "$key_file" "$RETRIES" curl_headers key_source; then
        key_replace="file://$(readlink -f "$key_file")"
        echo "Key source: $key_source" >> "$job_log"
        echo "$status_prefix STEP 2/4: key ready"
      else
        if [[ "$key_uri" =~ ^https?:// ]]; then
          key_replace="$key_uri"
        elif [[ "$key_uri" == "[KEY]" ]]; then
          key_replace=""
          if [[ -s "$key_file" ]]; then
            key_replace="file://$(readlink -f "$key_file")"
          fi
        else
          key_replace="$playlist_base/$key_uri"
        fi
        echo "Key source: not downloaded, fallback=$key_replace" >> "$job_log"
        echo "$status_prefix STEP 2/4: key fallback mode"
      fi
    else
      echo "Key source: no #EXT-X-KEY in playlist" >> "$job_log"
      echo "$status_prefix STEP 2/4: key not present in media playlist"
    fi

    if [[ -n "${key_uri:-}" && -z "${key_replace:-}" ]]; then
      echo "$status_prefix FAIL: encryption key unresolved (likely missing/expired cookie)"
      echo "FAIL: encryption key unresolved (check cookie from Copy as cURL)" >> "$job_log"
      failed=$((failed + 1))
      continue
    fi

    final_playlist="$job_dir/playlist_final.m3u8"
    build_local_playlist "$playlist_file" "$final_playlist" "$playlist_base" "$key_replace"

    echo "$status_prefix STEP 3/4: downloading segments..."
    segments_dir="$job_dir/segments"
    if ! materialize_playlist_local "$final_playlist" "$local_playlist" "$segments_dir" "$RETRIES" curl_headers "$status_prefix" "$REUSE_SEGMENTS" >> "$job_log" 2>&1; then
      echo "$status_prefix FAIL: segment download failed (see $job_log)"
      echo "FAIL: segment download failed" >> "$job_log"
      failed=$((failed + 1))
      continue
    fi
  fi

  if is_yes "$ASSEMBLE_ONLY"; then
    echo "$status_prefix STEP 1/1: assembling MP4..."
  else
    echo "$status_prefix STEP 4/4: assembling MP4..."
  fi
  tmp_out="$job_dir/output.part.mp4"

  if ffmpeg -nostdin -hide_banner -loglevel warning \
      -allowed_extensions ALL \
      -protocol_whitelist file,crypto,data \
      -i "$local_playlist" \
      -map_metadata -1 \
      -metadata encoder= \
      -c copy \
      -bsf:a aac_adtstoasc \
      -movflags +faststart \
      -y "$tmp_out" >> "$job_log" 2>&1; then
    mv -f "$tmp_out" "$output_path"
    echo "$status_prefix DONE: $output_path"
    echo ""
    success=$((success + 1))
    rm -rf "$job_dir"
  else
    echo "$status_prefix FAIL: ffmpeg assembly failed (see $job_log)"
    echo "FAIL: ffmpeg assembly failed" >> "$job_log"
    failed=$((failed + 1))
  fi
done 3< "$LIST_FILE"

echo ""
echo "Summary:"
echo "  total:   $total"
echo "  success: $success"
echo "  failed:  $failed"
echo "  skipped: $skipped"

if [[ "$failed" -gt 0 ]]; then
  exit 3
fi
