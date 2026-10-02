#!/usr/bin/env bash
# ==============================================================================
# EZP2023+ / IMSProg Universal Build, Test & Release Automation Script
#
# Automates compilation of the native C CLI, the IMSProg Qt6 GUI suite,
# comprehensive testing (including 64KB page alignment & headless execution),
# container/RPM packaging, and GitHub synchronization.
# ==============================================================================

set -euo pipefail

# Script directory and repository root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${SCRIPT_DIR}"
BUILD_DIR="${ROOT_DIR}/build"
LINUX_DIR="${ROOT_DIR}/linux"
IMSPROG_DIR="${ROOT_DIR}/IMSProg"
PACKAGES_DIR="${ROOT_DIR}/packages"

# Colors for terminal output
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    COLOR_RESET=$'\033[0m'
    COLOR_BOLD=$'\033[1m'
    COLOR_GREEN=$'\033[32m'
    COLOR_RED=$'\033[31m'
    COLOR_YELLOW=$'\033[33m'
    COLOR_BLUE=$'\033[34m'
    COLOR_CYAN=$'\033[36m'
else
    COLOR_RESET=""
    COLOR_BOLD=""
    COLOR_GREEN=""
    COLOR_RED=""
    COLOR_YELLOW=""
    COLOR_BLUE=""
    COLOR_CYAN=""
fi

log_info() {
    echo -e "${COLOR_BLUE}[INFO]${COLOR_RESET} $*"
}

log_success() {
    echo -e "${COLOR_GREEN}[SUCCESS]${COLOR_RESET} $*"
}

log_warn() {
    echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET} $*"
}

log_error() {
    echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} $*" >&2
}

log_step() {
    echo -e "\n${COLOR_CYAN}${COLOR_BOLD}=== $* ===${COLOR_RESET}"
}

# ------------------------------------------------------------------------------
# Environment Setup: Ensure local library and pkg-config search paths
# ------------------------------------------------------------------------------
setup_environment() {
    local LOCAL_PKG_PATHS=(
        "$HOME/.local/lib64/pkgconfig"
        "$HOME/.local/lib/pkgconfig"
        "/usr/local/lib64/pkgconfig"
        "/usr/local/lib/pkgconfig"
    )

    for p in "${LOCAL_PKG_PATHS[@]}"; do
        if [ -d "$p" ]; then
            export PKG_CONFIG_PATH="${p}:${PKG_CONFIG_PATH:-}"
        fi
    done

    local LOCAL_PREFIX_PATHS=(
        "$HOME/.local"
        "/usr/local"
    )

    for p in "${LOCAL_PREFIX_PATHS[@]}"; do
        if [ -d "$p" ]; then
            export CMAKE_PREFIX_PATH="${p}:${CMAKE_PREFIX_PATH:-}"
        fi
    done

    local LOCAL_LD_PATHS=(
        "$HOME/.local/lib64"
        "$HOME/.local/lib"
        "/usr/local/lib64"
        "/usr/local/lib"
    )

    for p in "${LOCAL_LD_PATHS[@]}"; do
        if [ -d "$p" ]; then
            export LD_LIBRARY_PATH="${p}:${LD_LIBRARY_PATH:-}"
        fi
    done
}

# ------------------------------------------------------------------------------
# Submodule Verification
# ------------------------------------------------------------------------------
check_submodules() {
    if [ ! -f "${IMSPROG_DIR}/CMakeLists.txt" ]; then
        log_info "Initializing git submodule: IMSProg..."
        git -C "${ROOT_DIR}" submodule update --init --recursive
    fi
}

# ------------------------------------------------------------------------------
# Dependency Checking
# ------------------------------------------------------------------------------
check_prerequisites() {
    local missing=0
    for cmd in cmake make gcc g++ pkg-config python3; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            log_error "Missing required build tool: $cmd"
            missing=1
        fi
    done

    if ! pkg-config --exists libusb-1.0; then
        log_error "libusb-1.0 development package is required but not found via pkg-config."
        missing=1
    fi

    if [ "$missing" -ne 0 ]; then
        log_error "Please install prerequisites before proceeding."
        log_error "Debian/Ubuntu: sudo apt install -y build-essential cmake pkg-config qt6-base-dev qt6-tools-dev libusb-1.0-0-dev libftdi1-dev"
        log_error "Fedora/RHEL:   sudo dnf install -y gcc-c++ cmake pkgconf-pkg-config qt6-qtbase-devel qt6-qttools-devel libusb1-devel libftdi-devel"
        exit 1
    fi
}

# ------------------------------------------------------------------------------
# Compilation
# ------------------------------------------------------------------------------
compile_linux_cli() {
    log_step "Compiling Native C Standalone CLI (linux/ezp2023)"
    make -C "${LINUX_DIR}"
    log_success "Native C CLI built: ${LINUX_DIR}/ezp2023"
}

compile_imsprog() {
    log_step "Compiling IMSProg Suite (CMake Release)"
    mkdir -p "${BUILD_DIR}"
    
    local NPROC
    NPROC=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)

    cmake -S "${IMSPROG_DIR}" -B "${BUILD_DIR}" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr

    cmake --build "${BUILD_DIR}" -j"${NPROC}"
    log_success "IMSProg suite built successfully in ${BUILD_DIR}"
}

compile_all() {
    setup_environment
    check_submodules
    check_prerequisites
    compile_linux_cli
    compile_imsprog
}

# ------------------------------------------------------------------------------
# Testing Framework
# ------------------------------------------------------------------------------
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

run_test() {
    local test_name="$1"
    shift
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    echo -n "  Testing: ${test_name} ... "
    
    set +e
    local output
    output=$("$@" 2>&1)
    local status=$?
    set -e

    if [ "$status" -eq 0 ]; then
        echo -e "${COLOR_GREEN}[PASS]${COLOR_RESET}"
        PASSED_TESTS=$((PASSED_TESTS + 1))
    else
        echo -e "${COLOR_RED}[FAIL]${COLOR_RESET}"
        echo -e "    ${COLOR_YELLOW}Command:${COLOR_RESET} $*"
        if [ -n "${output}" ]; then
            echo -e "    ${COLOR_YELLOW}Output:${COLOR_RESET}\n${output}"
        fi
        FAILED_TESTS=$((FAILED_TESTS + 1))
    fi
}

run_tests() {
    log_step "Running Automated Test Suite"
    setup_environment

    TOTAL_TESTS=0
    PASSED_TESTS=0
    FAILED_TESTS=0

    # 1. Binary existence checks
    run_test "linux/ezp2023 executable exists" test -x "${LINUX_DIR}/ezp2023"
    run_test "build/IMSProg_programmer/IMSProg executable exists" test -x "${BUILD_DIR}/IMSProg_programmer/IMSProg"
    run_test "build/IMSProg_editor/IMSProg_editor executable exists" test -x "${BUILD_DIR}/IMSProg_editor/IMSProg_editor"
    run_test "build/IMSProg_database_update/IMSProg_database_update executable exists" test -x "${BUILD_DIR}/IMSProg_database_update/IMSProg_database_update"

    # 2. Standalone CLI tests
    run_test "linux/ezp2023 usage output on no arguments" bash -c "${LINUX_DIR}/ezp2023 2>&1 | grep -q 'Usage:'"
    run_test "linux/ezp2023 detect handles missing hardware cleanly" bash -c "${LINUX_DIR}/ezp2023 detect 2>&1 | grep -qE 'EZP programmer not found|Connected to EZP programmer'"

    # 3. Python CLI & database tests
    run_test "python3 ezp2023.py syntax compile" python3 -m py_compile "${LINUX_DIR}/ezp2023.py"
    run_test "python3 ezp_db.py syntax compile" python3 -m py_compile "${LINUX_DIR}/ezp_db.py"
    run_test "python3 ezp2023.py --help" python3 "${LINUX_DIR}/ezp2023.py" --help
    run_test "python3 ezp_db.py loads 878 chips from database" bash -c "python3 '${LINUX_DIR}/ezp_db.py' | grep -q 'Loaded 878 chips'"

    # 4. ARM64 64KB page alignment verification
    local ARCH
    ARCH=$(uname -m)
    if [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then
        run_test "ARM64 64KB (0x10000) page alignment: IMSProg" bash -c "readelf -l '${BUILD_DIR}/IMSProg_programmer/IMSProg' | grep LOAD -A 1 | grep -q '0x10000'"
        run_test "ARM64 64KB (0x10000) page alignment: IMSProg_editor" bash -c "readelf -l '${BUILD_DIR}/IMSProg_editor/IMSProg_editor' | grep LOAD -A 1 | grep -q '0x10000'"
        run_test "ARM64 64KB (0x10000) page alignment: IMSProg_database_update" bash -c "readelf -l '${BUILD_DIR}/IMSProg_database_update/IMSProg_database_update' | grep LOAD -A 1 | grep -q '0x10000'"
    fi

    # 5. Headless GUI load test (verifies dynamic linking & Qt plugins without X11/Wayland crash)
    if command -v timeout >/dev/null 2>&1; then
        run_test "IMSProg GUI headless initialization" bash -c "timeout 2s env QT_QPA_PLATFORM=offscreen '${BUILD_DIR}/IMSProg_programmer/IMSProg' >/dev/null 2>&1; ret=\$?; [ \$ret -eq 124 ] || [ \$ret -eq 0 ]"
        run_test "IMSProg_editor GUI headless initialization" bash -c "timeout 2s env QT_QPA_PLATFORM=offscreen '${BUILD_DIR}/IMSProg_editor/IMSProg_editor' >/dev/null 2>&1; ret=\$?; [ \$ret -eq 124 ] || [ \$ret -eq 0 ]"
        run_test "IMSProg_database_update GUI headless initialization" bash -c "timeout 2s env QT_QPA_PLATFORM=offscreen '${BUILD_DIR}/IMSProg_database_update/IMSProg_database_update' >/dev/null 2>&1; ret=\$?; [ \$ret -eq 124 ] || [ \$ret -eq 0 ]"
    fi

    # Summary
    echo ""
    echo -e "${COLOR_BOLD}Test Summary:${COLOR_RESET} ${PASSED_TESTS}/${TOTAL_TESTS} tests passed."
    if [ "${FAILED_TESTS}" -gt 0 ]; then
        log_error "${FAILED_TESTS} test(s) failed!"
        return 1
    else
        log_success "All automated tests passed successfully!"
        return 0
    fi
}

# ------------------------------------------------------------------------------
# Packaging
# ------------------------------------------------------------------------------
package_debian() {
    log_step "Building Debian Package via Podman/Docker"
    if [ -x "${ROOT_DIR}/build_debian_package.sh" ]; then
        "${ROOT_DIR}/build_debian_package.sh"
    else
        log_error "build_debian_package.sh not found or not executable."
        return 1
    fi
}

package_rpm() {
    log_step "Building Fedora RPM Package"
    if ! command -v rpmbuild >/dev/null 2>&1; then
        log_error "rpmbuild is not installed. Run: sudo dnf install -y rpm-build"
        return 1
    fi

    local RPM_SOURCES="$HOME/rpmbuild/SOURCES"
    mkdir -p "${RPM_SOURCES}"
    log_info "Preparing source tarball in ${RPM_SOURCES}/v1.9.1.tar.gz..."
    tar --transform 's|^|IMSProg-1.9.1/|' --exclude='.git' --exclude='build*' \
        -czf "${RPM_SOURCES}/v1.9.1.tar.gz" -C "${IMSPROG_DIR}" .

    log_info "Running rpmbuild..."
    rpmbuild -ba "${IMSPROG_DIR}/rpm/imsprog.spec"
    log_success "RPM build complete. Check ~/rpmbuild/RPMS/"
}

# ------------------------------------------------------------------------------
# Installation
# ------------------------------------------------------------------------------
install_system() {
    log_step "Installing IMSProg & Udev Rules"
    if [ ! -d "${BUILD_DIR}" ]; then
        log_error "Build directory not found. Please compile first."
        exit 1
    fi
    sudo cmake --install "${BUILD_DIR}"
    sudo cp "${LINUX_DIR}/99-ezp2023.rules" /etc/udev/rules.d/
    sudo udevadm control --reload-rules && sudo udevadm trigger
    log_success "Installation complete!"
}

# ------------------------------------------------------------------------------
# Cleanup
# ------------------------------------------------------------------------------
clean_all() {
    log_step "Cleaning Build Artifacts"
    rm -rf "${BUILD_DIR}"
    make -C "${LINUX_DIR}" clean 2>/dev/null || true
    find "${LINUX_DIR}" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
    find "${LINUX_DIR}" -type f -name "*.pyc" -delete 2>/dev/null || true
    log_success "Clean completed."
}

# ------------------------------------------------------------------------------
# Git Push Automation
# ------------------------------------------------------------------------------
push_to_github() {
    local commit_msg="${1:-"ci: Update build automation script and documentation"}"
    log_step "Pushing Changes to GitHub"

    cd "${ROOT_DIR}"
    
    local branch
    branch=$(git rev-parse --abbrev-ref HEAD)
    log_info "Current git branch: ${branch}"

    git status -s

    git add -A
    
    if git diff-index --quiet HEAD --; then
        log_info "No uncommitted changes in working tree."
    else
        log_info "Committing changes with message: '${commit_msg}'"
        git commit -m "${commit_msg}"
    fi

    log_info "Pushing to origin/${branch}..."
    git push origin "${branch}"
    log_success "Successfully pushed to GitHub repository!"
}

# ------------------------------------------------------------------------------
# Help / Usage
# ------------------------------------------------------------------------------
show_help() {
    cat <<EOF
${COLOR_BOLD}EZP2023+ Build & Test Automation Script${COLOR_RESET}

Usage:
  ./build.sh [COMMAND] [OPTIONS]

Commands:
  all               Compile all targets and run tests (default)
  compile | build   Compile linux/ezp2023 native CLI and IMSProg Qt6 suite
  test              Run automated verification & page alignment test suite
  clean             Remove build directory and temporary artifacts
  install           Install compiled binaries and udev rules to /usr
  package-deb | deb Build Debian arm64 .deb package via container
  package-rpm | rpm Build Fedora RPM package via rpmbuild
  push [MESSAGE]    Commit all changes and push to GitHub (origin/<current_branch>)
  help | -h         Display this help message

Options:
  --push            Run build, test, and automatically push to GitHub if tests pass
  --no-test         Skip running test suite during 'all'
  --clean           Clean build artifacts before compiling
  -m, --message     Commit message when used with push or --push

Examples:
  ./build.sh                     # Build everything and run test suite
  ./build.sh compile             # Compile native tools and GUI
  ./build.sh test                # Run test suite only
  ./build.sh all --push          # Build, test, and push to GitHub on success
  ./build.sh push "Update guide" # Commit and push changes directly
EOF
}

# ------------------------------------------------------------------------------
# Main Entry Point
# ------------------------------------------------------------------------------
main() {
    local cmd="all"
    local do_push=0
    local skip_test=0
    local do_clean_first=0
    local commit_message=""

    while [ $# -gt 0 ]; do
        case "$1" in
            all|compile|build|test|clean|install|package-deb|deb|package-rpm|rpm|push|help|-h|--help)
                cmd="$1"
                shift
                if [ "$cmd" = "push" ] && [ $# -gt 0 ] && [[ "$1" != -* ]]; then
                    commit_message="$1"
                    shift
                fi
                ;;
            --push)
                do_push=1
                shift
                ;;
            --no-test)
                skip_test=1
                shift
                ;;
            --clean)
                do_clean_first=1
                shift
                ;;
            -m|--message)
                shift
                if [ $# -gt 0 ]; then
                    commit_message="$1"
                    shift
                fi
                ;;
            *)
                log_error "Unknown option or command: $1"
                show_help
                exit 1
                ;;
        esac
    done

    case "$cmd" in
        help|-h|--help)
            show_help
            exit 0
            ;;
        clean)
            clean_all
            exit 0
            ;;
        compile|build)
            if [ "$do_clean_first" -eq 1 ]; then clean_all; fi
            compile_all
            ;;
        test)
            run_tests
            ;;
        install)
            install_system
            ;;
        package-deb|deb)
            package_debian
            ;;
        package-rpm|rpm)
            package_rpm
            ;;
        push)
            push_to_github "${commit_message:-"build: Automate build and test pipeline"}"
            exit 0
            ;;
        all)
            if [ "$do_clean_first" -eq 1 ]; then clean_all; fi
            compile_all
            if [ "$skip_test" -eq 0 ]; then
                run_tests
            fi
            if [ "$do_push" -eq 1 ]; then
                push_to_github "${commit_message:-"feat: Add automated build.sh script, tests, and documentation update"}"
            fi
            ;;
    esac
}

main "$@"
