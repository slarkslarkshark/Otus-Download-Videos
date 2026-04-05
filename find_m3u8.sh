#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage:
  ./find_m3u8.sh --ts-url URL --referer URL [options]

Required:
  --ts-url URL       Full media-*.ts URL copied from browser
  --referer URL      Referer header (e.g. https://otus.ru/learning/358135/)

Optional:
  --ua STRING        User-Agent header
  --origin URL       Origin header
  --outdir DIR       Output directory (default: discover_out)
  -h, --help         Show help

Outputs:
  <outdir>/find_m3u8.log
  <outdir>/found_urls.txt
  <outdir>/key_results.txt
  <outdir>/chunklist_*.m3u8
USAGE
}

TS_URL=""
REFERER=""
UA="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36"
ORIGIN=""
OUTDIR="discover_out"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ts-url)
      TS_URL="$2"
      shift 2
      ;;
    --referer)
      REFERER="$2"
      shift 2
      ;;
    --ua)
      UA="$2"
      shift 2
      ;;
    --origin)
      ORIGIN="$2"
      shift 2
      ;;
    --outdir)
      OUTDIR="$2"
      shift 2
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

if [[ -z "$TS_URL" || -z "$REFERER" ]]; then
  echo "ERROR: --ts-url and --referer are required"
  usage
  exit 1
fi

mkdir -p "$OUTDIR"
LOG_FILE="$OUTDIR/find_m3u8.log"
FOUND_FILE="$OUTDIR/found_urls.txt"
KEY_FILE="$OUTDIR/key_results.txt"

: > "$LOG_FILE"
: > "$FOUND_FILE"
: > "$KEY_FILE"

log() {
  printf '%s\n' "$*" | tee -a "$LOG_FILE"
}

build_headers() {
  local arr=( -H "Referer: $REFERER" -H "User-Agent: $UA" )
  if [[ -n "$ORIGIN" ]]; then
    arr+=( -H "Origin: $ORIGIN" )
  fi
  printf '%s\n' "${arr[@]}"
}

mapfile -t CURL_HEADERS < <(build_headers)

log "Input TS URL: $TS_URL"
log "Referer: $REFERER"
log "Output dir: $OUTDIR"

# Convert cdnv-*.boomstream.com URL to base candidates.
base_from_ts="$(printf '%s' "$TS_URL" | sed -E 's#https://cdnv-([^/]+)/vod/size%3A[^/]+/duration%3A[^/]+/fragment%3A[^/]+/#https://\1/vod/#; s#/media-[0-9]+\.ts$##')"

if [[ "$base_from_ts" == "$TS_URL" ]]; then
  log "WARNING: Could not normalize TS URL with expected pattern."
  log "Will also try parent path fallback."
  parent_base="${TS_URL%/media-*}"
else
  parent_base="$base_from_ts"
fi

cand1="$parent_base"
cand2="$(printf '%s' "$parent_base" | sed -E 's#https://[^/]+#https://m1.boomstream.com#')"
cand3="$(printf '%s' "$parent_base" | sed -E 's#https://[^/]+#https://m3.boomstream.com#')"
cand4="$(printf '%s' "$parent_base" | sed -E 's#https://[^/]+#https://m2.boomstream.com#')"

# Unique candidates in stable order.
declare -a BASES=()
add_base() {
  local b="$1"
  for x in "${BASES[@]:-}"; do
    [[ "$x" == "$b" ]] && return 0
  done
  BASES+=("$b")
}

add_base "$cand1"
add_base "$cand2"
add_base "$cand3"
add_base "$cand4"

# Also try one level up (sometimes manifest is there).
for b in "${BASES[@]}"; do
  add_base "${b%/*}"
done

PLAYLIST_NAMES=( chunklist.m3u8 playlist.m3u8 manifest.m3u8 index.m3u8 )

found_count=0
idx=0
for base in "${BASES[@]}"; do
  for pl in "${PLAYLIST_NAMES[@]}"; do
    url="$base/$pl"
    idx=$((idx + 1))
    out="$OUTDIR/chunklist_${idx}.m3u8"
    log "TRY: $url"

    if curl -fL -s "${CURL_HEADERS[@]}" "$url" -o "$out"; then
      if grep -qE '^#EXTM3U' "$out"; then
        found_count=$((found_count + 1))
        echo "$url" >> "$FOUND_FILE"
        log "FOUND: $url"

        key_uri="$(grep -m1 '#EXT-X-KEY' "$out" | sed -n 's/.*URI="\([^"]*\)".*/\1/p')"
        if [[ -n "$key_uri" ]]; then
          if [[ "$key_uri" == "[KEY]" ]]; then
            for k in key.bin key.key encryption.key; do
              key_try="$base/$k"
              if curl -fL -s "${CURL_HEADERS[@]}" "$key_try" -o "$OUTDIR/key_${idx}.bin"; then
                if [[ -s "$OUTDIR/key_${idx}.bin" ]]; then
                  echo "OK $key_try" >> "$KEY_FILE"
                  log "KEY OK: $key_try"
                  break
                fi
              fi
            done
          elif [[ "$key_uri" =~ ^https?:// ]]; then
            if curl -fL -s "${CURL_HEADERS[@]}" "$key_uri" -o "$OUTDIR/key_${idx}.bin"; then
              if [[ -s "$OUTDIR/key_${idx}.bin" ]]; then
                echo "OK $key_uri" >> "$KEY_FILE"
                log "KEY OK: $key_uri"
              else
                echo "FAIL $key_uri" >> "$KEY_FILE"
                log "KEY FAIL(empty): $key_uri"
              fi
            else
              echo "FAIL $key_uri" >> "$KEY_FILE"
              log "KEY FAIL: $key_uri"
            fi
          else
            key_try="$base/$key_uri"
            if curl -fL -s "${CURL_HEADERS[@]}" "$key_try" -o "$OUTDIR/key_${idx}.bin"; then
              if [[ -s "$OUTDIR/key_${idx}.bin" ]]; then
                echo "OK $key_try" >> "$KEY_FILE"
                log "KEY OK: $key_try"
              else
                echo "FAIL $key_try" >> "$KEY_FILE"
                log "KEY FAIL(empty): $key_try"
              fi
            else
              echo "FAIL $key_try" >> "$KEY_FILE"
              log "KEY FAIL: $key_try"
            fi
          fi
        else
          log "No #EXT-X-KEY in playlist: $url"
        fi
      else
        rm -f "$out"
        log "Not an m3u8 signature: $url"
      fi
    else
      log "MISS: $url"
      rm -f "$out"
    fi
  done
done

log ""
log "Done. Found playlists: $found_count"
log "Found list: $FOUND_FILE"
log "Key checks: $KEY_FILE"
log "Full log: $LOG_FILE"

if [[ "$found_count" -eq 0 ]]; then
  exit 2
fi
