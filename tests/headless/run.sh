#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd)
MATRIX="$SCRIPT_DIR/matrix.json"
MATRIX_HELPER="$SCRIPT_DIR/matrix.py"

fail() {
    echo "headless-test: $*" >&2
    exit 1
}

find_factorio() {
    if [ -n "${FACTORIO_BIN:-}" ]; then
        [ -x "$FACTORIO_BIN" ] || fail "FACTORIO_BIN is not executable: $FACTORIO_BIN"
        printf '%s\n' "$FACTORIO_BIN"
        return
    fi

    if command -v factorio >/dev/null 2>&1; then
        command -v factorio
        return
    fi

    for candidate in \
        "/Applications/factorio.app/Contents/MacOS/factorio" \
        "/Applications/Factorio.app/Contents/MacOS/factorio" \
        "${HOME:-}/Applications/factorio.app/Contents/MacOS/factorio" \
        "${HOME:-}/Applications/Factorio.app/Contents/MacOS/factorio" \
        "${HOME:-}/Library/Application Support/Steam/steamapps/common/Factorio/factorio.app/Contents/MacOS/factorio" \
        "${HOME:-}/.steam/steam/steamapps/common/Factorio/bin/x64/factorio"
    do
        if [ -x "$candidate" ]; then
            printf '%s\n' "$candidate"
            return
        fi
    done

    fail "Factorio was not found; set FACTORIO_BIN to a 2.1.12 executable"
}

find_read_data() {
    binary_dir=$(dirname -- "$FACTORIO_BIN_PATH")
    for candidate in \
        "$binary_dir/../data" \
        "$binary_dir/../../data"
    do
        if [ -f "$candidate/core/info.json" ]; then
            (CDPATH='' cd -- "$candidate" && pwd)
            return
        fi
    done
    fail "could not locate Factorio's data directory beside $FACTORIO_BIN_PATH"
}

json_field() {
    python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))[sys.argv[2]])' "$1" "$2"
}

safe_cleanup() {
    status=$?
    if [ "${KEEP_TEST_DATA:-0}" = "1" ] || [ "$status" -ne 0 ]; then
        echo "headless-test: isolated data preserved at $TEST_ROOT" >&2
        return
    fi

    case "$TEST_ROOT" in
        "${TMPDIR:-/tmp}"/sceatorio-factorio.*)
            rm -rf -- "$TEST_ROOT"
            ;;
        *)
            echo "headless-test: refusing to clean unexpected path: $TEST_ROOT" >&2
            ;;
    esac
}

prepare_mod() {
    mod_target="$MODS_DIR/${MOD_NAME}_${MOD_VERSION}"
    mkdir -p "$mod_target"
    if command -v rsync >/dev/null 2>&1; then
        rsync -a --delete \
            --exclude '.git/' \
            --exclude '.DS_Store' \
            "$REPO_ROOT/" "$mod_target/"
    else
        cp -R "$REPO_ROOT/." "$mod_target/"
        rm -rf -- "$mod_target/.git"
    fi
}

write_config() {
    mkdir -p "$WRITE_DATA/config" "$MODS_DIR" "$WRITE_DATA/saves"
    {
        printf '%s\n' '[path]'
        printf 'read-data=%s\n' "$READ_DATA"
        printf 'write-data=%s\n' "$WRITE_DATA"
        printf '%s\n' '[other]'
        printf '%s\n' 'check-updates=false'
    } > "$CONFIG_FILE"
}

write_mod_list() {
    profile=$1
    if [ -n "$EXTERNAL_MOD_SET" ]; then
        python3 "$MATRIX_HELPER" "$MATRIX" mod-list \
            "$profile" "$MOD_NAME" "$EXTERNAL_MOD_SET" > "$MODS_DIR/mod-list.json"
    else
        python3 "$MATRIX_HELPER" "$MATRIX" mod-list \
            "$profile" "$MOD_NAME" > "$MODS_DIR/mod-list.json"
    fi
}

sha1_file() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 1 "$1" | awk '{print $1}'
        return
    fi
    if command -v sha1sum >/dev/null 2>&1; then
        sha1sum "$1" | awk '{print $1}'
        return
    fi
    fail "neither shasum nor sha1sum is available for archive verification"
}

prepare_external_mods() {
    [ -n "$EXTERNAL_MOD_SET" ] || return 0
    [ -n "${FACTORIO_EXTERNAL_MOD_DIR:-}" ] || \
        fail "set FACTORIO_EXTERNAL_MOD_DIR to a staging directory containing the pinned archives"
    [ -d "$FACTORIO_EXTERNAL_MOD_DIR" ] || \
        fail "external mod staging directory does not exist: $FACTORIO_EXTERNAL_MOD_DIR"

    external_manifest="$TEST_ROOT/external-mods.tsv"
    python3 "$MATRIX_HELPER" "$MATRIX" external-mods \
        "$EXTERNAL_MOD_SET" > "$external_manifest"

    tab=$(printf '\t')
    while IFS="$tab" read -r external_name external_version expected_sha1; do
        source_archive="$FACTORIO_EXTERNAL_MOD_DIR/${external_name}_${external_version}.zip"
        [ -f "$source_archive" ] || fail "missing pinned archive: $source_archive"
        actual_sha1=$(sha1_file "$source_archive")
        [ "$actual_sha1" = "$expected_sha1" ] || \
            fail "SHA-1 mismatch for $source_archive: expected $expected_sha1, found $actual_sha1"
        cp "$source_archive" "$MODS_DIR/"
    done < "$external_manifest"
}

run_factorio() {
    "$FACTORIO_BIN_PATH" \
        --config "$CONFIG_FILE" \
        --mod-directory "$MODS_DIR" \
        --disable-audio \
        "$@"
}

create_save() {
    profile=$1
    SAVE_FILE="$WRITE_DATA/saves/sceatorio-$profile.zip"
    write_mod_list "$profile"
    run_factorio --create "$SAVE_FILE" --map-gen-seed 424242
}

run_smoke() {
    profile=$1
    case_ids=$(python3 "$MATRIX_HELPER" "$MATRIX" cases smoke "$profile")
    [ -n "$case_ids" ] || fail "no implemented smoke case for profile: $profile"
    echo "headless-test: running $case_ids"
    create_save "$profile"
    run_factorio \
        --benchmark "$SAVE_FILE" \
        --benchmark-ticks "${FACTORIO_SMOKE_TICKS:-120}" \
        --benchmark-runs 1 \
        --benchmark-sanitize
}

run_benchmark() {
    profile=$1
    create_save "$profile"
    run_factorio \
        --benchmark "$SAVE_FILE" \
        --benchmark-ticks "${FACTORIO_BENCHMARK_TICKS:-3600}" \
        --benchmark-runs "${FACTORIO_BENCHMARK_RUNS:-3}" \
        --benchmark-sanitize
}

run_server() {
    profile=$1
    case_ids=$(python3 "$MATRIX_HELPER" "$MATRIX" cases server "$profile")
    [ -n "$case_ids" ] || fail "no implemented server case for profile: $profile"
    echo "headless-test: running $case_ids"
    create_save "$profile"
    server_settings="$WRITE_DATA/server-settings.json"
    server_log="$WRITE_DATA/server.log"
    cat > "$server_settings" <<'EOF'
{
  "name": "Sceatorio isolated headless smoke",
  "description": "Disposable local integration test",
  "visibility": {"public": false, "lan": false},
  "require_user_verification": false,
  "auto_pause": false
}
EOF

    run_factorio \
        --start-server "$SAVE_FILE" \
        --bind 127.0.0.1 \
        --port "${FACTORIO_TEST_PORT:-34199}" \
        --server-settings "$server_settings" \
        --server-id "$WRITE_DATA/server-id.json" \
        > "$server_log" 2>&1 &
    server_pid=$!

    attempts=0
    while [ "$attempts" -lt 80 ]; do
        if grep -Eq 'Hosting game|changing state from\(CreatingGame\) to\(InGame\)' "$server_log"; then
            kill -TERM "$server_pid" 2>/dev/null || true
            wait "$server_pid" 2>/dev/null || true
            echo "headless-test: isolated server reached hosting state"
            return
        fi
        if ! kill -0 "$server_pid" 2>/dev/null; then
            wait "$server_pid" || true
            sed -n '1,240p' "$server_log" >&2
            fail "server exited before reaching hosting state"
        fi
        attempts=$((attempts + 1))
        sleep 0.25
    done

    kill -TERM "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
    sed -n '1,240p' "$server_log" >&2
    fail "server did not reach hosting state within 20 seconds"
}

run_profiles() {
    command_name=$1
    selected_profile=$2
    if [ "$selected_profile" = "all" ]; then
        profiles=$(python3 "$MATRIX_HELPER" "$MATRIX" profiles "$command_name")
    else
        profiles=$selected_profile
    fi

    for profile in $profiles; do
        case "$command_name" in
            smoke) run_smoke "$profile" ;;
            server) run_server "$profile" ;;
            benchmark) run_benchmark "$profile" ;;
            *) fail "unsupported command: $command_name" ;;
        esac
    done
}

command_name=${1:-smoke}
profile=${2:-all}
EXTERNAL_MOD_SET=${3:-}

case "$command_name" in
    smoke|server|benchmark) ;;
    *) fail "usage: tests/headless/run.sh (smoke|server|benchmark) [base|space-age|all] [external-mod-set]" ;;
esac

command -v python3 >/dev/null 2>&1 || fail "python3 is required to read matrix.json"

FACTORIO_BIN_PATH=$(find_factorio)
EXPECTED_VERSION=$(python3 "$MATRIX_HELPER" "$MATRIX" version)
ACTUAL_VERSION=$("$FACTORIO_BIN_PATH" --version | sed -n 's/^Version: \([^ ]*\).*/\1/p' | head -n 1)
[ "$ACTUAL_VERSION" = "$EXPECTED_VERSION" ] || \
    fail "expected Factorio $EXPECTED_VERSION, found ${ACTUAL_VERSION:-unknown} at $FACTORIO_BIN_PATH"

READ_DATA=$(find_read_data)
MOD_NAME=$(json_field "$REPO_ROOT/info.json" name)
MOD_VERSION=$(json_field "$REPO_ROOT/info.json" version)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/sceatorio-factorio.XXXXXX")
WRITE_DATA="$TEST_ROOT/write-data"
MODS_DIR="$TEST_ROOT/mods"
CONFIG_FILE="$WRITE_DATA/config/config.ini"
trap safe_cleanup EXIT
trap 'exit 130' HUP INT TERM

write_config
prepare_mod
prepare_external_mods

echo "headless-test: Factorio $ACTUAL_VERSION"
echo "headless-test: profile $profile; isolated root $TEST_ROOT"
run_profiles "$command_name" "$profile"
