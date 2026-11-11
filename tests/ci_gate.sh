#!/usr/bin/env bash
# Pull request gate: checks that need neither a model nor a GPU backend.
# Usage: tests/ci_gate.sh [build|test|jpeg]. With no argument it runs build
# and test; jpeg needs uv and compares the JPEG decoder with libjpeg.
set -euo pipefail

cd "$(dirname "$0")/.."

UNIT_TESTS="tests/test_q4k_dot tests/test_mxfp4_dot tests/test_engram
    tests/test_session_state tests/test_tp_commands tests/test_tp_rdma
    tests/test_tp_tcp tests/test_layer_pack tests/test_prompt_prefix
    tests/test_gpu_args tests/test_image_decode tests/test_engine_mgpu_placement
    tests/test_deepseek4_vision_image tests/test_sampling"

# Only the build differs: CI hosts have Metal on macOS but no nvcc on Linux,
# where the runners link the CPU backend. Both run the same tests.
if [ "$(uname -s)" = Darwin ]; then
    BINARIES="ds4 ds4-server ds4-bench ds4-agent ds4-eval ds4_test ds4_agent_test"
    SERVER_TEST=./ds4_test
    AGENT_TEST=./ds4_agent_test
else
    # Compile check only: the CPU backend is reference code.
    BINARIES="cpu ds4_test_cpu ds4_agent_test_cpu"
    SERVER_TEST=./ds4_test_cpu
    AGENT_TEST=./ds4_agent_test_cpu
fi

# CI_SANITIZE=1 builds with ASan and UBSan instead of the release flags:
# -O1 keeps reports readable, and -ffast-math is left out because UBSan
# checks float conversions it would make undefined. The sanitizers go in CC
# so that rules with hand-written flags are instrumented too, and make
# expands $(NATIVE_CPU_FLAG) from the Makefile.
SANITIZE=
if [ "${CI_SANITIZE:-}" = 1 ]; then
    SANITIZE=1
    CC_BASE=${CC:-cc}
    export CC="$CC_BASE -fsanitize=address,undefined -fno-sanitize-recover=undefined"
    export CFLAGS='-O1 -g -fno-omit-frame-pointer $(NATIVE_CPU_FLAG) -Wall -Wextra -std=c99'
fi

build_all() {
    # Objects that are already built emit no warnings and would pass unchecked.
    if compgen -G '*.o' >/dev/null || compgen -G 'tests/*.o' >/dev/null; then
        echo "ci_gate: run make clean first" >&2
        exit 2
    fi

    local log jobs ignore='^$'
    log=$(mktemp)
    jobs=$(getconf _NPROCESSORS_ONLN)
    make -j"$jobs" $BINARIES 2>&1 | tee -a "$log"
    make -j"$jobs" tests/test_web_recovery $UNIT_TESTS 2>&1 | tee -a "$log"

    # Only build output counts: some tests print runtime warnings on purpose.
    # At -O1 gcc reports snprintf truncation the release builds do not see.
    [ -n "$SANITIZE" ] && ignore='-Wformat-truncation'
    if grep -E 'warning( #[0-9]+)?:' "$log" | grep -vE -- "$ignore"; then
        echo "ci_gate: compiler warnings are build failures" >&2
        exit 1
    fi
}

# Sanitizer reports go to files: tests that expect a failing exit status
# or check only the output would otherwise hide them.
SAN_LOGS=
sanitize_runtime() {
    [ -n "$SANITIZE" ] || return 0
    SAN_LOGS=$(mktemp -d)
    export ASAN_OPTIONS="log_path=$SAN_LOGS/report:detect_stack_use_after_return=1:check_initialization_order=1${1:-}"
    export UBSAN_OPTIONS="log_path=$SAN_LOGS/report:print_stacktrace=1"
    trap check_reports EXIT
}

check_reports() {
    local status=$?
    if compgen -G "$SAN_LOGS/report*" >/dev/null; then
        cat "$SAN_LOGS"/report* >&2
        echo "ci_gate: sanitizer reports above" >&2
        exit 1
    fi
    exit "$status"
}

run() {
    echo "--- $*"
    "$@"
}

# Tests run one at a time, so timing-sensitive ones do not compete for CPU.
run_tests() {
    sanitize_runtime
    run ./ds4-eval --validate-cases
    run ./ds4-eval --self-test-extractors
    run "$SERVER_TEST" --server
    run "$AGENT_TEST"

    for bin in $UNIT_TESTS; do
        run "./$bin"
    done

    run python3 tests/test_web_recovery.py ./tests/test_web_recovery
    run ./tests/test_gpu_args_cli.sh

    for bin in ds4 ds4-server ds4-agent; do
        echo "--- ./$bin --help"
        "./$bin" --help >/dev/null
    done
}

# The test builds ds4_image.c into a library that Python loads. Under
# sanitizers the ASan runtime must be loaded first, and Python's own leaks
# at exit are not ours.
run_jpeg() {
    local preload=()
    if [ -n "$SANITIZE" ]; then
        sanitize_runtime :detect_leaks=0
        if [ "$(uname -s)" = Darwin ]; then
            preload=(env DYLD_INSERT_LIBRARIES="$($CC_BASE -print-file-name=libclang_rt.asan_osx_dynamic.dylib)")
        else
            preload=(env LD_PRELOAD="$($CC_BASE -print-file-name=libasan.so)")
        fi
    fi
    run uv run --no-project --python 3.13 --with numpy==2.5.4 --with pillow==13.0.0 \
        ${preload[@]+"${preload[@]}"} python -m unittest discover -s tests -p test_jpeg_decode.py
}

case "${1:-all}" in
    build) build_all ;;
    test) run_tests ;;
    jpeg) run_jpeg ;;
    all) build_all; run_tests ;;
    *) echo "usage: tests/ci_gate.sh [build|test|jpeg]" >&2; exit 2 ;;
esac
