#!/bin/bash
#
# Usage:
#   ./render_tiles.sh [--bbox xmin,ymin,xmax,ymax] [--project path] [--out dir]
#                     [--zmin N] [--zmax N] [--metatile N] [--gutter N]
#                     [--dpi N] [--background #rrggbb] [--format png|jpg]
#                     [--advanced-effects] [--preflight] [--tree-mode full|off|only]
#                     [--only-metatile z:x:y] [--worker-metatiles N] [--max-rss-mb N]
#
#   --bbox         Optional WGS84 extent (xmin,ymin,xmax,ymax). Without it, combined
#                  project layer extent is used.
#   --project      QGIS project (.qgz/.qgs). Default: <repo>/style/strassenraumkarte.qgz
#   --out          Output generation directory. Default: <repo>/render/tiles-validated
#   --zmin         Minimum zoom (default: 15)
#   --zmax         Maximum zoom (default: 20)
#   --metatile     Metatile size (default: 8)
#   --gutter       Extra tiles around each metatile for labels/symbols (default: 1);
#                  rendered then discarded (not written)
#   --dpi          Render DPI (default: 96)
#   --background   Tile background colour as #rrggbb (default: #ededed)
#   --format       png or jpg (default: jpg)
#   --resume       Resume matching committed and decodable metatiles only
#   --advanced-effects  Enable QGIS effects for reference-image rendering
#
# Rendering uses a custom PyQGIS metatile loop (render/xyz_tiles.py) with
# per-metatile progress. Tiles are rendered directly in EPSG:3857; ground-metre
# symbol sizes use @mercator_scale (1/cos φ).
#

set -euo pipefail

export QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-offscreen}"

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
# shellcheck source=../data/db_config.sh
source "$REPO_ROOT/data/db_config.sh"

# Prefer the caller's PyQGIS-capable interpreter. A normal Homebrew/system
# Python cannot import QGIS. The macOS fallback bootstraps the app bundle's
# embedded Python so a terminal invocation behaves like QGIS itself.
QGIS_PYTHON_BIN="${QGIS_PYTHON:-python3}"
if ! "$QGIS_PYTHON_BIN" -c 'import qgis' >/dev/null 2>&1 && [[ "$(uname)" == "Darwin" ]]; then
  # QGIS_APP pins one app bundle (e.g. QGIS_APP=/Applications/QGIS-final-4_2_1.app).
  # Otherwise every /Applications/QGIS*.app is tried in turn and the first one
  # whose embedded Python can actually import PyQGIS wins; a bundle whose
  # Python cannot (e.g. a QGIS 3 LTR next to QGIS 4) is skipped.
  if [[ -n "${QGIS_APP:-}" ]]; then
    QGIS_APP_BUNDLES=("$QGIS_APP")
  else
    QGIS_APP_BUNDLES=(/Applications/QGIS*.app)
  fi
  for app_bundle in "${QGIS_APP_BUNDLES[@]}"; do
    for candidate in "$app_bundle"/Contents/MacOS/python3*; do
      [[ -x "$candidate" ]] || continue
      BUNDLE_CONTENTS=${candidate%/MacOS/python3*}
      PYTHON_VERSION=${candidate##*/python}
      PYTHON_ROOT="$BUNDLE_CONTENTS/Resources/python$PYTHON_VERSION"
      # Do not set PYTHONHOME: the bundle's executable has a build-time prefix,
      # while its standard library and extension modules live under Resources.
      bundle_pythonpath="$PYTHON_ROOT/site-packages:$PYTHON_ROOT:$PYTHON_ROOT/lib-dynload${PYTHONPATH:+:$PYTHONPATH}"
      if PYTHONPATH="$bundle_pythonpath" QGIS_PREFIX_PATH="$BUNDLE_CONTENTS/MacOS" \
         QT_PLUGIN_PATH="$BUNDLE_CONTENTS/PlugIns" PROJ_LIB="$BUNDLE_CONTENTS/Resources/qgis/proj" \
         "$candidate" -c 'import qgis' >/dev/null 2>&1; then
        QGIS_PYTHON_BIN="$candidate"
        export PYTHONPATH="$bundle_pythonpath"
        export QGIS_PREFIX_PATH="$BUNDLE_CONTENTS/MacOS"
        export QT_PLUGIN_PATH="$BUNDLE_CONTENTS/PlugIns"
        export PROJ_LIB="$BUNDLE_CONTENTS/Resources/qgis/proj"
        echo "$(date +'%Y-%m-%d %H:%M:%S')  [INFO] PyQGIS runtime: ${BUNDLE_CONTENTS%/Contents} (pin with QGIS_APP=...)" >&2
        break 2
      fi
    done
  done
fi
if ! "$QGIS_PYTHON_BIN" -c 'import qgis' >/dev/null 2>&1; then
  echo "$(date +'%Y-%m-%d %H:%M:%S')  [ERROR] No PyQGIS-capable Python. Set QGIS_PYTHON to a QGIS Python interpreter." >&2
  exit 1
fi

BBOX=""
PROJECT="$REPO_ROOT/style/strassenraumkarte.qgz"
OUT="$REPO_ROOT/render/tiles-validated"
ZMIN=15
ZMAX=20
METATILE=8
GUTTER=1
DPI=96
BACKGROUND="#ededed"
FORMAT="jpg"
RESUME=0
ADVANCED_EFFECTS=0
PREFLIGHT=0
TREE_MODE="full"
ONLY_METATILE=""
WORKER_METATILES=20
MAX_RSS_MB=0

log() {
  echo "$(date +'%Y-%m-%d %H:%M:%S')  [$1] $2"
}

usage() {
  echo "Usage: $0 [--bbox xmin,ymin,xmax,ymax] [--project path] [--out dir] [--zmin N] [--zmax N] [--metatile N] [--gutter N] [--dpi N] [--background #rrggbb] [--format png|jpg] [--resume] [--advanced-effects] [--preflight] [--tree-mode full|off|only] [--only-metatile z:x:y] [--worker-metatiles N] [--max-rss-mb N]"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bbox)
      [[ -z "${2:-}" || "$2" == --* ]] && { log ERROR "--bbox requires xmin,ymin,xmax,ymax"; usage; exit 1; }
      BBOX="$2"
      shift 2
      ;;
    --project)
      [[ -z "${2:-}" || "$2" == --* ]] && { log ERROR "--project requires a path"; usage; exit 1; }
      PROJECT="$2"
      shift 2
      ;;
    --out)
      [[ -z "${2:-}" || "$2" == --* ]] && { log ERROR "--out requires a directory"; usage; exit 1; }
      OUT="$2"
      shift 2
      ;;
    --zmin)
      [[ -z "${2:-}" || "$2" == --* ]] && { log ERROR "--zmin requires a number"; usage; exit 1; }
      ZMIN="$2"
      shift 2
      ;;
    --zmax)
      [[ -z "${2:-}" || "$2" == --* ]] && { log ERROR "--zmax requires a number"; usage; exit 1; }
      ZMAX="$2"
      shift 2
      ;;
    --metatile)
      [[ -z "${2:-}" || "$2" == --* ]] && { log ERROR "--metatile requires a number"; usage; exit 1; }
      METATILE="$2"
      shift 2
      ;;
    --gutter)
      [[ -z "${2:-}" || "$2" == --* ]] && { log ERROR "--gutter requires a number"; usage; exit 1; }
      GUTTER="$2"
      shift 2
      ;;
    --dpi)
      [[ -z "${2:-}" || "$2" == --* ]] && { log ERROR "--dpi requires a number"; usage; exit 1; }
      DPI="$2"
      shift 2
      ;;
    --background)
      [[ -z "${2:-}" || "$2" == --* ]] && { log ERROR "--background requires #rrggbb"; usage; exit 1; }
      BACKGROUND="$2"
      shift 2
      ;;
    --format)
      [[ -z "${2:-}" || "$2" == --* ]] && { log ERROR "--format requires png or jpg"; usage; exit 1; }
      FORMAT="$2"
      shift 2
      ;;
    --resume)
      RESUME=1
      shift
      ;;
    --advanced-effects)
      ADVANCED_EFFECTS=1
      shift
      ;;
    --preflight)
      PREFLIGHT=1
      shift
      ;;
    --tree-mode)
      TREE_MODE="${2:-}"
      shift 2
      ;;
    --only-metatile)
      ONLY_METATILE="${2:-}"
      shift 2
      ;;
    --worker-metatiles)
      WORKER_METATILES="${2:-}"
      shift 2
      ;;
    --max-rss-mb)
      MAX_RSS_MB="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      log ERROR "Unknown parameter: $1"
      usage
      exit 1
      ;;
  esac
done

CALLER_PWD=$(pwd)
resolve_path() {
  local path="$1"
  if [[ "$path" = /* ]]; then
    echo "$path"
  elif [[ -e "$CALLER_PWD/$path" ]]; then
    echo "$CALLER_PWD/$path"
  else
    echo "$REPO_ROOT/$path"
  fi
}

PROJECT=$(resolve_path "$PROJECT")
OUT=$(resolve_path "$OUT")

if [[ ! -f "$PROJECT" ]]; then
  log ERROR "QGIS project not found: $PROJECT"
  exit 1
fi

if ! [[ "$ZMIN" =~ ^[0-9]+$ && "$ZMAX" =~ ^[0-9]+$ && "$ZMIN" -le "$ZMAX" ]]; then
  log ERROR "Invalid zoom range: zmin=$ZMIN zmax=$ZMAX"
  exit 1
fi

if ! [[ "$METATILE" =~ ^[0-9]+$ && "$METATILE" -ge 1 ]]; then
  log ERROR "Invalid --metatile: $METATILE"
  exit 1
fi

if ! [[ "$GUTTER" =~ ^[0-9]+$ ]]; then
  log ERROR "Invalid --gutter: $GUTTER"
  exit 1
fi

if ! [[ "$WORKER_METATILES" =~ ^[0-9]+$ && "$MAX_RSS_MB" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  log ERROR "Invalid worker or RSS limit"
  exit 1
fi

case "$TREE_MODE" in full|off|only) ;; *) log ERROR "Invalid --tree-mode: $TREE_MODE"; exit 1;; esac

# --only-metatile targets one metatile inside a generation that (almost
# always) already exists; requiring --resume as well, on top of it, made the
# single-metatile re-render workflow the flag exists for fail by default with
# "already exists; use --resume".
if [[ -n "$ONLY_METATILE" ]]; then
  RESUME=1
fi

bg_hex="${BACKGROUND#\#}"
if ! [[ "$bg_hex" =~ ^[0-9A-Fa-f]{6}$ ]]; then
  log ERROR "Invalid --background (expected #rrggbb): $BACKGROUND"
  exit 1
fi
# ${var,,} (bash 4+ lowercase expansion) isn't available on macOS's default
# /bin/bash (3.2, GPLv3-avoidance) — tr works on any bash version.
BACKGROUND="#$(printf '%s' "$bg_hex" | tr '[:upper:]' '[:lower:]')"

case "$FORMAT" in
  png|PNG|jpg|jpeg|JPG|JPEG) ;;
  *)
    log ERROR "Invalid --format: $FORMAT (use png or jpg)"
    exit 1
    ;;
esac

if [[ -n "$BBOX" ]]; then
  if ! [[ "$BBOX" =~ ^-?[0-9]+(\.[0-9]+)?,-?[0-9]+(\.[0-9]+)?,-?[0-9]+(\.[0-9]+)?,-?[0-9]+(\.[0-9]+)?$ ]]; then
    log ERROR "Invalid --bbox (expected xmin,ymin,xmax,ymax): $BBOX"
    exit 1
  fi
  IFS=',' read -r XMIN YMIN XMAX YMAX <<< "$BBOX"
  EXTENT="${XMIN},${XMAX},${YMIN},${YMAX} [EPSG:4326]"
  log INFO "Using bbox extent: $EXTENT"
else
  log INFO "No --bbox given; computing combined project layer extent..."
  EXTENT=$("$QGIS_PYTHON_BIN" "$SCRIPT_DIR/project_extent.py" "$PROJECT") || {
    log ERROR "Failed to determine project extent."
    exit 1
  }
  log INFO "Using project extent: $EXTENT"
fi

mkdir -p "$OUT"

# Keep parking publication out of a render: the QGIS project reads the
# file-backed parking layer while tiles are being produced.
PARKING_LOCK="$REPO_ROOT/data/parking/.render.lock"
if [[ -e "$PARKING_LOCK" ]]; then
  lock_pid=$(cat "$PARKING_LOCK" 2>/dev/null || true)
  if [[ "$lock_pid" =~ ^[0-9]+$ ]] && kill -0 "$lock_pid" 2>/dev/null; then
    log ERROR "Parking data is already being rendered; refusing a concurrent run."
    exit 1
  fi
  rm -f "$PARKING_LOCK"
fi
printf '%s\n' "$$" > "$PARKING_LOCK"
trap 'rm -f "$PARKING_LOCK"' EXIT INT TERM

log INFO "Starting PyQGIS metatile renderer..."
log INFO "  project=$PROJECT"
log INFO "  out=$OUT"
log INFO "  zoom=${ZMIN}-${ZMAX} metatile=$METATILE gutter=$GUTTER dpi=$DPI format=$FORMAT bg=$BACKGROUND"

# Exit status 75 is a deliberate post-metatile recycle. It bounds retained QGIS
# memory while retaining a manifest-backed resume point.
while true; do
  CMD=("$QGIS_PYTHON_BIN" "$SCRIPT_DIR/xyz_tiles.py"
    --project "$PROJECT" --extent "$EXTENT" --out "$OUT"
    --zmin "$ZMIN" --zmax "$ZMAX" --metatile "$METATILE" --gutter "$GUTTER"
    --dpi "$DPI" --background "$BACKGROUND" --format "$FORMAT"
    --tree-mode "$TREE_MODE" --max-metatiles-per-worker "$WORKER_METATILES" --max-rss-mb "$MAX_RSS_MB")
  if [[ "$ADVANCED_EFFECTS" -eq 1 ]]; then CMD+=(--advanced-effects); fi
  if [[ "$RESUME" -eq 1 ]]; then CMD+=(--resume); fi
  if [[ "$PREFLIGHT" -eq 1 ]]; then CMD+=(--preflight); fi
  if [[ -n "$ONLY_METATILE" ]]; then CMD+=(--only-metatile "$ONLY_METATILE"); fi
  set +e
  "${CMD[@]}"
  STATUS=$?
  set -e
  if [[ "$STATUS" -ne 75 ]]; then
    exit "$STATUS"
  fi
  if [[ "$PREFLIGHT" -eq 1 || -n "$ONLY_METATILE" ]]; then
    log ERROR "A single-run mode requested worker recycling unexpectedly."
    exit 1
  fi
  log INFO "Restarting clean QGIS worker from committed render state..."
  RESUME=1
done
