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

stop_active_factorio() {
    if [ -z "${ACTIVE_FACTORIO_PID:-}" ]; then return; fi
    kill -TERM "$ACTIVE_FACTORIO_PID" 2>/dev/null || true
    wait "$ACTIVE_FACTORIO_PID" 2>/dev/null || true
    ACTIVE_FACTORIO_PID=""
}

safe_cleanup() {
    status=$?
    stop_active_factorio
    if [ "${KEEP_TEST_DATA:-0}" = "1" ]; then
        echo "headless-test: isolated data preserved at $TEST_ROOT" >&2
        return
    fi

    if [ "$status" -ne 0 ]; then
        echo "headless-test: failed; rerun with KEEP_TEST_DATA=1 to preserve isolated test data" >&2
    fi

    case "$TEST_ROOT" in
        "$TEST_ROOT_PREFIX"??????)
            rm -rf -- "$TEST_ROOT" || \
                echo "headless-test: could not clean isolated root: $TEST_ROOT" >&2
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
            --exclude 'dist/' \
            --exclude 'mcp/dist/' \
            --exclude 'mcp/node_modules/' \
            --exclude '.pytest_cache/' \
            --exclude '__pycache__/' \
            --exclude '*.pyc' \
            "$REPO_ROOT/" "$mod_target/"
    else
        cp -R "$REPO_ROOT/." "$mod_target/"
        rm -rf -- \
            "$mod_target/.git" \
            "$mod_target/dist" \
            "$mod_target/mcp/dist" \
            "$mod_target/mcp/node_modules" \
            "$mod_target/.pytest_cache" \
            "$mod_target/scripts/__pycache__" \
            "$mod_target/tests/headless/__pycache__" \
            "$mod_target/tests/unit/__pycache__"
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

# Backgrounding a shell function makes $! identify a wrapper subshell on some
# shells. Replace that subshell with Factorio so TERM/wait always target the
# process that owns the test sockets.
run_factorio_background() {
    exec "$FACTORIO_BIN_PATH" \
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

    run_factorio_background \
        --start-server "$SAVE_FILE" \
        --bind 127.0.0.1 \
        --port "${FACTORIO_TEST_PORT:-34199}" \
        --server-settings "$server_settings" \
        --server-id "$WRITE_DATA/server-id.json" \
        > "$server_log" 2>&1 &
    ACTIVE_FACTORIO_PID=$!
    server_pid=$ACTIVE_FACTORIO_PID

    attempts=0
    while [ "$attempts" -lt 80 ]; do
        if grep -Eq 'Hosting game|changing state from\(CreatingGame\) to\(InGame\)' "$server_log"; then
            stop_active_factorio
            echo "headless-test: isolated server reached hosting state"
            return
        fi
        if ! kill -0 "$server_pid" 2>/dev/null; then
            wait "$server_pid" || true
            ACTIVE_FACTORIO_PID=""
            sed -n '1,240p' "$server_log" >&2
            fail "server exited before reaching hosting state"
        fi
        attempts=$((attempts + 1))
        sleep 0.25
    done

    stop_active_factorio
    sed -n '1,240p' "$server_log" >&2
    fail "server did not reach hosting state within 20 seconds"
}

run_fixture() {
    profile=$1
    fixture_manifest="$TEST_ROOT/fixtures.tsv"
    python3 "$MATRIX_HELPER" "$MATRIX" fixtures \
        "$profile" "$FIXTURE_FILTER" > "$fixture_manifest"
    [ -s "$fixture_manifest" ] || fail "no implemented fixture for profile=$profile filter=$FIXTURE_FILTER"

    tab=$(printf '\t')
    while IFS="$tab" read -r case_id fixture_name pass_marker; do
        fixture_source="$REPO_ROOT/tests/fixtures/$fixture_name"
        [ -f "$fixture_source/control.lua" ] || fail "missing fixture control.lua: $fixture_source"
        mkdir -p "$WRITE_DATA/scenarios"
        cp -R "$fixture_source" "$WRITE_DATA/scenarios/$fixture_name"
        write_mod_list "$profile"

        fixture_log="$WRITE_DATA/$fixture_name.log"
        fixture_settings="$WRITE_DATA/$fixture_name-server-settings.json"
        cat > "$fixture_settings" <<'EOF'
{
  "name": "Sceatorio isolated fixture",
  "description": "Disposable local integration test",
  "visibility": {"public": false, "lan": false},
  "require_user_verification": false,
  "auto_pause": false
}
EOF
        echo "headless-test: running $case_id"
        run_factorio_background \
            --start-server-load-scenario "$fixture_name" \
            --bind 127.0.0.1 \
            --port "${FACTORIO_TEST_PORT:-34199}" \
            --server-settings "$fixture_settings" \
            --server-id "$WRITE_DATA/$fixture_name-server-id.json" \
            > "$fixture_log" 2>&1 &
        ACTIVE_FACTORIO_PID=$!
        fixture_pid=$ACTIVE_FACTORIO_PID

        attempts=0
        while [ "$attempts" -lt 80 ]; do
            if grep -Fq "$pass_marker" "$fixture_log"; then
                stop_active_factorio
                echo "headless-test: $case_id emitted $pass_marker"
                break
            fi
            if grep -Eq 'SCEATORIO_[A-Z_]+_FAIL' "$fixture_log"; then
                stop_active_factorio
                sed -n '1,260p' "$fixture_log" >&2
                fail "$case_id emitted a failure marker"
            fi
            if ! kill -0 "$fixture_pid" 2>/dev/null; then
                wait "$fixture_pid" || true
                ACTIVE_FACTORIO_PID=""
                sed -n '1,260p' "$fixture_log" >&2
                fail "$case_id exited before $pass_marker"
            fi
            attempts=$((attempts + 1))
            sleep 0.25
        done
        if [ "$attempts" -ge 80 ]; then
            stop_active_factorio
            sed -n '1,260p' "$fixture_log" >&2
            fail "$case_id did not emit $pass_marker within 20 seconds"
        fi
    done < "$fixture_manifest"
}

run_mod_fixture() {
    profile=$1
    fixture_manifest="$TEST_ROOT/mod-fixtures.tsv"
    python3 "$MATRIX_HELPER" "$MATRIX" fixtures \
        "$profile" "$FIXTURE_FILTER" mod-fixture > "$fixture_manifest"
    [ -s "$fixture_manifest" ] || \
        fail "no implemented mod fixture for profile=$profile filter=$FIXTURE_FILTER"

    tab=$(printf '\t')
    while IFS="$tab" read -r case_id fixture_name pass_marker; do
        fixture_source="$REPO_ROOT/tests/fixtures/$fixture_name"
        fixture_info="$fixture_source/info.json"
        [ -f "$fixture_info" ] || fail "missing fixture info.json: $fixture_source"
        fixture_mod_name=$(json_field "$fixture_info" name)
        fixture_mod_version=$(json_field "$fixture_info" version)
        fixture_target="$MODS_DIR/${fixture_mod_name}_${fixture_mod_version}"
        mkdir -p "$fixture_target"
        cp -R "$fixture_source/." "$fixture_target/"
        python3 "$MATRIX_HELPER" "$MATRIX" mod-list \
            "$profile" "$MOD_NAME" "" "$fixture_mod_name" > "$MODS_DIR/mod-list.json"

        fixture_log="$WRITE_DATA/$fixture_name.log"
        fixture_reload_log="$WRITE_DATA/$fixture_name-reload.log"
        fixture_save="$WRITE_DATA/saves/$fixture_name.zip"
        echo "headless-test: running $case_id"
        if ! run_factorio --create "$fixture_save" --map-gen-seed 424242 \
            > "$fixture_log" 2>&1; then
            sed -n '1,300p' "$fixture_log" >&2
            fail "$case_id exited unsuccessfully"
        fi
        fixture_checkpoint="$WRITE_DATA/saves/$fixture_name-checkpoint.zip"
        fixture_server_log="$WRITE_DATA/$fixture_name-server.log"
        fixture_settings="$WRITE_DATA/$fixture_name-server-settings.json"
        cat > "$fixture_settings" <<'EOF'
{
  "name": "Sceatorio state-roundtrip fixture",
  "description": "Disposable local integration test",
  "visibility": {"public": false, "lan": false},
  "require_user_verification": false,
  "auto_pause": false
}
EOF
        run_factorio_background \
            --start-server "$fixture_save" \
            --bind 127.0.0.1 \
            --port "${FACTORIO_TEST_PORT:-34209}" \
            --server-settings "$fixture_settings" \
            --server-id "$WRITE_DATA/$fixture_name-server-id.json" \
            < /dev/null > "$fixture_server_log" 2>&1 &
        ACTIVE_FACTORIO_PID=$!
        fixture_pid=$ACTIVE_FACTORIO_PID

        attempts=0
        checkpoint_ready=0
        while [ "$attempts" -lt 240 ]; do
            if grep -Eq 'SCEATORIO_[A-Z_]+_FAIL' "$fixture_server_log"; then
                stop_active_factorio
                sed -n '1,300p' "$fixture_server_log" >&2
                fail "$case_id emitted a failure marker before checkpoint"
            fi
            # game.server_save is asynchronous. Killing as soon as the archive
            # appears can race ParallelScenarioSaver and crash Factorio 2.1.12
            # during shutdown; wait for the engine's completion marker.
            if grep -Eq 'SCEATORIO_[A-Z_]+_CHECKPOINT' "$fixture_server_log" \
                && [ -s "$fixture_checkpoint" ] \
                && grep -Fq 'Saving finished' "$fixture_server_log"; then
                checkpoint_ready=1
                stop_active_factorio
                break
            fi
            if ! kill -0 "$fixture_pid" 2>/dev/null; then
                wait "$fixture_pid" || true
                ACTIVE_FACTORIO_PID=""
                sed -n '1,300p' "$fixture_server_log" >&2
                fail "$case_id server exited before checkpoint"
            fi
            attempts=$((attempts + 1))
            sleep 0.25
        done
        if [ "$checkpoint_ready" -ne 1 ]; then
            stop_active_factorio
            sed -n '1,300p' "$fixture_server_log" >&2
            fail "$case_id did not finish a checkpoint within 60 seconds"
        fi

        if ! run_factorio \
            --benchmark "$fixture_checkpoint" \
            --benchmark-ticks "${FACTORIO_FIXTURE_BENCHMARK_TICKS:-900}" \
            --benchmark-runs "${FACTORIO_FIXTURE_BENCHMARK_RUNS:-1}" \
            --benchmark-sanitize > "$fixture_reload_log" 2>&1; then
            sed -n '1,300p' "$fixture_reload_log" >&2
            fail "$case_id checkpoint reload exited unsuccessfully"
        fi
        fixture_engine_log="$WRITE_DATA/factorio-current.log"
        if grep -Eq 'SCEATORIO_[A-Z_]+_FAIL' \
            "$fixture_log" "$fixture_server_log" "$fixture_reload_log" \
            "$fixture_engine_log"; then
            sed -n '1,300p' "$fixture_log" >&2
            sed -n '1,300p' "$fixture_server_log" >&2
            sed -n '1,300p' "$fixture_reload_log" >&2
            sed -n '1,300p' "$fixture_engine_log" >&2
            fail "$case_id emitted a failure marker"
        fi
        if ! grep -Fq "$pass_marker" "$fixture_reload_log" \
            && ! grep -Fq "$pass_marker" "$fixture_engine_log"; then
            sed -n '1,300p' "$fixture_log" >&2
            sed -n '1,300p' "$fixture_server_log" >&2
            sed -n '1,300p' "$fixture_reload_log" >&2
            sed -n '1,300p' "$fixture_engine_log" >&2
            fail "$case_id exited before $pass_marker"
        fi
        echo "headless-test: $case_id emitted $pass_marker"
        fixture_retired="$TEST_ROOT/completed-mod-fixtures/$case_id"
        mkdir -p "$TEST_ROOT/completed-mod-fixtures"
        mv "$fixture_target" "$fixture_retired"
        if [ -f "$MODS_DIR/mod-settings.dat" ]; then
            mv "$MODS_DIR/mod-settings.dat" "$fixture_retired/mod-settings.dat"
        fi
    done < "$fixture_manifest"
}

run_ai_e2e() {
    profile=$1
    [ "$profile" = "base" ] || fail "the AI gateway E2E currently uses the base profile"
    fixture_source="$REPO_ROOT/tests/fixtures/ai-gateway"
    fixture_info="$fixture_source/info.json"
    fixture_mod_name=$(json_field "$fixture_info" name)
    fixture_mod_version=$(json_field "$fixture_info" version)
    fixture_target="$MODS_DIR/${fixture_mod_name}_${fixture_mod_version}"
    mkdir -p "$fixture_target"
    cp -R "$fixture_source/." "$fixture_target/"
    python3 "$MATRIX_HELPER" "$MATRIX" mod-list \
        "$profile" "$MOD_NAME" "" "$fixture_mod_name" > "$MODS_DIR/mod-list.json"

    SAVE_FILE="$WRITE_DATA/saves/sceatorio-ai-gateway.zip"
    run_factorio --create "$SAVE_FILE" --map-gen-seed 424242
    server_settings="$fixture_source/server-settings.json"
    server_log="$WRITE_DATA/ai-gateway-server.log"
    lua_udp_port=${FACTORIO_LUA_UDP_PORT:-34320}
    rcon_port=${FACTORIO_RCON_PORT:-34321}
    game_port=${FACTORIO_TEST_PORT:-34322}
    rcon_password="sceatorio-isolated-e2e"

    npm --prefix "$REPO_ROOT/mcp" run build --silent
    run_factorio_background \
        --start-server "$SAVE_FILE" \
        --bind 127.0.0.1 \
        --port "$game_port" \
        --server-settings "$server_settings" \
        --server-id "$WRITE_DATA/ai-gateway-server-id.json" \
        --rcon-bind "127.0.0.1:$rcon_port" \
        --rcon-password "$rcon_password" \
        --enable-lua-udp "$lua_udp_port" \
        > "$server_log" 2>&1 &
    ACTIVE_FACTORIO_PID=$!
    ai_server_pid=$ACTIVE_FACTORIO_PID

    attempts=0
    while [ "$attempts" -lt 80 ]; do
        if grep -Eq 'Hosting game|changing state from\(CreatingGame\) to\(InGame\)' "$server_log"; then
            break
        fi
        if ! kill -0 "$ai_server_pid" 2>/dev/null; then
            wait "$ai_server_pid" || true
            ACTIVE_FACTORIO_PID=""
            sed -n '1,320p' "$server_log" >&2
            fail "AI gateway server exited before reaching hosting state"
        fi
        attempts=$((attempts + 1))
        sleep 0.25
    done
    if [ "$attempts" -ge 80 ]; then
        sed -n '1,320p' "$server_log" >&2
        fail "AI gateway server did not reach hosting state"
    fi

    if ! SCEATORIO_E2E_RCON_PORT="$rcon_port" \
        SCEATORIO_E2E_RCON_PASSWORD="$rcon_password" \
        SCEATORIO_E2E_LUA_UDP_PORT="$lua_udp_port" \
        node "$REPO_ROOT/tests/e2e/ai-gateway.mjs"; then
        sed -n '1,420p' "$server_log" >&2
        fail "AI gateway E2E failed"
    fi

    stop_active_factorio
    echo "headless-test: AI gateway E2E passed"
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
            fixture) run_fixture "$profile" ;;
            mod-fixture) run_mod_fixture "$profile" ;;
            ai-e2e) run_ai_e2e "$profile" ;;
            *) fail "unsupported command: $command_name" ;;
        esac
    done
}

command_name=${1:-smoke}
profile=${2:-all}
if [ "$command_name" = "fixture" ] || [ "$command_name" = "mod-fixture" ]; then
    FIXTURE_FILTER=${3:-all}
    EXTERNAL_MOD_SET=""
else
    FIXTURE_FILTER="all"
    EXTERNAL_MOD_SET=${3:-}
fi

case "$command_name" in
    smoke|server|benchmark|fixture|mod-fixture|ai-e2e) ;;
    *) fail "usage: tests/headless/run.sh (smoke|server|benchmark|fixture|mod-fixture|ai-e2e) [base|space-age|all] [external-mod-set|fixture]" ;;
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
TEST_ROOT_PREFIX="${TMPDIR:-/tmp}/sceatorio-factorio."
TEST_ROOT=$(mktemp -d "${TEST_ROOT_PREFIX}XXXXXX")
WRITE_DATA="$TEST_ROOT/write-data"
MODS_DIR="$TEST_ROOT/mods"
CONFIG_FILE="$WRITE_DATA/config/config.ini"
trap safe_cleanup EXIT
trap 'exit 130' HUP INT TERM
ACTIVE_FACTORIO_PID=""

write_config
prepare_mod
prepare_external_mods

echo "headless-test: Factorio $ACTUAL_VERSION"
echo "headless-test: profile $profile; isolated root $TEST_ROOT"
run_profiles "$command_name" "$profile"
