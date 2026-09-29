#!/usr/bin/env bash
#
# Install shared Linux tools and initialize isolated uv/Quarto projects.
# Run --help for desktop, remote, and project-only usage.
# Python packages (including Ruff, ty, and marimo) belong to each project.
#
# Supported package-manager families:
#   - Debian/Ubuntu
#   - Fedora/RHEL (RHEL, Rocky, and Alma also get EPEL and CodeReady Builder)
#   - Arch Linux (Visual Studio Code comes from the AUR, so yay is required)
#
# NVIDIA drivers are intentionally not installed or changed. Install a
# driver appropriate for the machine first; --cuda opts into the toolkit.

set -Eeuo pipefail

readonly UV_BIN_DIR="${UV_BIN_DIR:-$HOME/.local/bin}"
export PATH="$UV_BIN_DIR:$PATH"

readonly CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}"
readonly VSCODE_SETTINGS_FILE="$CONFIG_DIR/Code/User/settings.json"
readonly QUARTO_MARIMO_RELEASE="v0.5.0"
readonly MIN_QUARTO_VERSION="1.9.20"
readonly VSCODE_EXTENSIONS=(
    ms-python.python ms-python.vscode-pylance ms-python.debugpy
    ms-python.vscode-python-envs charliermarsh.ruff astral-sh.ty
    marimo-team.vscode-marimo llvm-vs-code-extensions.vscode-clangd
    ms-vscode.cmake-tools quarto.quarto myriad-dreamin.tinymist
    vadimcn.vscode-lldb timonwong.shellcheck tamasfe.even-better-toml
    redhat.vscode-yaml EditorConfig.EditorConfig
)

PROJECT_DIR=""
PROJECT_ONLY=false
EXTENSIONS_ONLY=false
REMOTE=false
INSTALL_CUDA=false
PROJECT_PYTHON=""

case "$(basename "${SHELL:-bash}")" in
zsh)
    readonly SHELL_RC="$HOME/.zshrc"
    ;;
*)
    readonly SHELL_RC="$HOME/.bashrc"
    ;;
esac

# Set by add_cuda_to_path when nvcc lives outside the default PATH.
CUDA_BIN_DIR=""

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

info() {
    printf '\n==> %s\n' "$*"
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

usage() {
    cat <<'EOF'
Usage: bash setup.sh [OPTIONS]

  --project DIR       Install shared tools, then initialize/sync this project
  --project-only DIR  Initialize/sync a project using existing uv and Quarto;
                      no sudo, global Python tools, or user config changes
  --remote            Skip the desktop app and user settings/shell changes
                      (also detected in SSH and VS Code remote sessions)
  --extensions-only   Install editor extensions through the current code CLI
  --cuda              Also install CUDA (driver separate), or add Nsight when
                      combined with --extensions-only
  --python VERSION    Python for a new project (default: 3.12)
  -h, --help          Show this help

Examples:
  bash setup.sh --project ~/work/my-project  # normal setup on your own computer
  code ~/work/my-project
  bash setup.sh --project-only ~/work/report
  bash setup.sh --project-only ~/work/another-report --python 3.12
  bash setup.sh --remote --project ~/work/report  # optional SSH/headless host
  bash setup.sh --extensions-only    # inside a VS Code remote terminal

Reruns sync existing uv.lock files without upgrading project dependencies.
Shared uv and Quarto may update during machine setup. CUDA is optional.
EOF
}

parse_arguments() {
    while (($#)); do
        case "$1" in
        --project | --project-only)
            [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || die "$1 requires a directory"
            [[ -z "$PROJECT_DIR" ]] || die "specify only one project directory"
            PROJECT_DIR="$2"
            [[ "$1" != --project-only ]] || PROJECT_ONLY=true
            shift 2
            ;;
        --python)
            [[ $# -ge 2 && "$2" =~ ^3\.[0-9]+(\.[0-9]+)?$ ]] || die "--python requires a version such as 3.12"
            PROJECT_PYTHON="$2"
            local minor="${PROJECT_PYTHON#3.}"
            [[ "${minor%%.*}" -ge 10 ]] || die "marimo requires Python 3.10 or newer"
            shift 2
            ;;
        --remote)
            REMOTE=true
            shift
            ;;
        --cuda)
            INSTALL_CUDA=true
            shift
            ;;
        --extensions-only)
            EXTENSIONS_ONLY=true
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *) die "unknown argument: $1 (see --help)" ;;
        esac
    done
    [[ -z "$PROJECT_PYTHON" || -n "$PROJECT_DIR" ]] || die "--python requires a project directory"
    if $EXTENSIONS_ONLY && [[ -n "$PROJECT_DIR" ]]; then
        die "--extensions-only cannot be combined with a project directory"
    fi
    if $PROJECT_ONLY && $INSTALL_CUDA; then
        die "--cuda installs system packages; use --project DIR instead of --project-only"
    fi
    if [[ -n "${SSH_CONNECTION:-}${SSH_TTY:-}" ]] || vscode_is_remote; then
        REMOTE=true
    fi
}

detect_host() {
    [[ "$(id -u)" -ne 0 ]] || die "run machine setup as a normal user; it uses sudo for system packages"
    command_exists sudo || die "sudo is required"
    command_exists curl || die "curl is required to bootstrap this setup"

    [[ -r /etc/os-release ]] || die "/etc/os-release is required"
    # shellcheck disable=SC1091
    source /etc/os-release

    readonly DISTRO_ID="${ID:-}"
    ARCH="$(uname -m)"
    readonly ARCH

    case "$DISTRO_ID" in
    ubuntu | debian | linuxmint | pop)
        readonly FAMILY="debian"
        ;;
    fedora)
        readonly FAMILY="fedora"
        ;;
    rhel | rocky | almalinux)
        readonly FAMILY="rhel"
        ;;
    arch | manjaro | endeavouros)
        readonly FAMILY="arch"
        ;;
    *)
        die "unsupported Linux distribution: ${PRETTY_NAME:-$DISTRO_ID}; supported families are Debian/Ubuntu, Fedora/RHEL, and Arch"
        ;;
    esac

    case "$ARCH" in
    x86_64 | amd64)
        readonly QUARTO_ARCH="amd64"
        ;;
    aarch64 | arm64)
        readonly QUARTO_ARCH="arm64"
        ;;
    *)
        die "unsupported CPU architecture: $ARCH"
        ;;
    esac

}

# CUDA from NVIDIA's repositories puts nvcc in /usr/local/cuda/bin and Arch's
# package puts it in /opt/cuda/bin; neither is on PATH by default.
add_cuda_to_path() {
    local dir
    for dir in /usr/local/cuda/bin /opt/cuda/bin; do
        if [[ ! -x "$dir/nvcc" ]]; then
            continue
        fi
        if [[ "$(command -v nvcc || true)" == "$dir/nvcc" ]]; then
            # Already on PATH, possibly from an earlier run's shell block.
            CUDA_BIN_DIR="$dir"
        elif ! command_exists nvcc; then
            export PATH="$dir:$PATH"
            CUDA_BIN_DIR="$dir"
        fi
        return
    done
}

# ccache comes from EPEL and ninja-build from CodeReady Builder, both of which
# RHEL, Rocky, and Alma leave disabled.
enable_rhel_extra_repositories() {
    [[ -n "${VERSION_ID:-}" ]] || die "VERSION_ID is missing from /etc/os-release"
    local major="${VERSION_ID%%.*}"

    info "Enabling the EPEL and CodeReady Builder repositories"
    if [[ "$DISTRO_ID" == "rhel" ]]; then
        sudo subscription-manager repos --enable "codeready-builder-for-rhel-${major}-${ARCH}-rpms"
        sudo dnf install -y "https://dl.fedoraproject.org/pub/epel/epel-release-latest-${major}.noarch.rpm"
    else
        # Rocky and Alma call CodeReady Builder "crb", or "powertools" on version 8.
        local builder_repo="crb"
        if [[ "$major" == "8" ]]; then
            builder_repo="powertools"
        fi
        sudo dnf install -y dnf-plugins-core
        sudo dnf config-manager --set-enabled "$builder_repo"
        sudo dnf install -y epel-release
    fi
}

install_system_packages() {
    # A CUDA toolkit from NVIDIA's repositories may already be installed but off PATH.
    add_cuda_to_path

    case "$FAMILY" in
    debian)
        info "Installing Debian-family packages"
        sudo apt-get update
        sudo apt-get install -y \
            ca-certificates \
            clang \
            clangd \
            clang-format \
            clang-tidy \
            ccache \
            cmake \
            curl \
            g++ \
            gdb \
            git \
            jq \
            lldb \
            make \
            ninja-build \
            pkg-config \
            python3 \
            python3-dev \
            python3-venv \
            ripgrep \
            rsync \
            shellcheck \
            shfmt \
            openssh-client \
            unzip \
            zip \
            xz-utils \
            gnupg

        if $INSTALL_CUDA && ! command_exists nvcc; then
            info "Installing CUDA toolkit from the configured Debian repositories"
            sudo apt-get install -y nvidia-cuda-toolkit || die \
                "CUDA toolkit was not available; configure NVIDIA's CUDA repository for this distro and rerun"
        fi
        ;;
    fedora | rhel)
        if [[ "$FAMILY" == "rhel" ]]; then
            enable_rhel_extra_repositories
        fi

        info "Installing Fedora/RHEL-family packages"
        sudo dnf install -y \
            ca-certificates \
            clang \
            clang-tools-extra \
            ccache \
            cmake \
            curl \
            gcc-c++ \
            gdb \
            git \
            jq \
            lldb \
            make \
            ninja-build \
            pkgconf-pkg-config \
            python3 \
            python3-devel \
            ripgrep \
            rsync \
            ShellCheck \
            shfmt \
            openssh-clients \
            unzip \
            zip \
            xz \
            gnupg2

        if $INSTALL_CUDA && ! command_exists nvcc; then
            info "Installing CUDA toolkit from the configured RPM repositories"
            sudo dnf install -y cuda-toolkit || die \
                "CUDA toolkit was not available; configure NVIDIA's CUDA repository for this distro and rerun"
        fi
        ;;
    arch)
        info "Installing Arch-family packages (this also upgrades the whole system, as Arch requires)"
        sudo pacman -Syu --needed --noconfirm \
            base-devel \
            ca-certificates \
            clang \
            ccache \
            cmake \
            curl \
            gcc \
            gdb \
            git \
            jq \
            lldb \
            ninja \
            pkgconf \
            python \
            ripgrep \
            rsync \
            shellcheck \
            shfmt \
            openssh \
            unzip \
            zip \
            xz

        if $INSTALL_CUDA && ! command_exists nvcc; then
            info "Installing CUDA toolkit"
            sudo pacman -S --needed --noconfirm cuda || die \
                "CUDA toolkit could not be installed from the configured Arch repositories"
        fi
        ;;
    esac

    add_cuda_to_path
}

# Inside a VS Code remote session (SSH, WSL, containers), `code` is a helper
# that installs extensions on this host rather than the desktop app.
vscode_is_remote() {
    [[ "$(command -v code || true)" == */remote-cli/* ]]
}

install_vscode() {
    if $REMOTE; then
        info "Remote setup: skipping the VS Code desktop app"
        return
    fi

    if command_exists code; then
        info "Visual Studio Code is already installed"
        return
    fi

    case "$FAMILY" in
    debian)
        info "Installing Microsoft Visual Studio Code"
        local keyring="/usr/share/keyrings/microsoft-archive-keyring.gpg"
        curl -fsSL https://packages.microsoft.com/keys/microsoft.asc |
            gpg --dearmor |
            sudo tee "$keyring" >/dev/null
        printf '%s\n' \
            "Types: deb" \
            "URIs: https://packages.microsoft.com/repos/code" \
            "Suites: stable" \
            "Components: main" \
            "Architectures: amd64 arm64" \
            "Signed-By: $keyring" |
            sudo tee /etc/apt/sources.list.d/vscode.sources >/dev/null
        sudo apt-get update
        sudo apt-get install -y code
        ;;
    fedora | rhel)
        info "Installing Microsoft Visual Studio Code"
        sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc
        sudo tee /etc/yum.repos.d/vscode.repo >/dev/null <<'EOF'
[code]
name=Visual Studio Code
baseurl=https://packages.microsoft.com/yumrepos/vscode
enabled=1
autorefresh=1
type=rpm-md
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc
EOF
        sudo dnf install -y code
        ;;
    arch)
        if command_exists yay; then
            info "Installing Microsoft Visual Studio Code from the AUR"
            yay -S --needed --noconfirm visual-studio-code-bin
        else
            die "on Arch, install visual-studio-code-bin with an AUR helper, then rerun"
        fi
        ;;
    esac
}

# quarto.org redirects its "latest" downloads to a versioned GitHub release URL.
latest_quarto_version() {
    local url
    url="$(curl -fsSI -o /dev/null -w '%{redirect_url}' "https://quarto.org/download/latest/quarto-linux-${QUARTO_ARCH}.tar.gz")"
    [[ "$url" =~ /download/v([0-9.]+)/ ]] && printf '%s\n' "${BASH_REMATCH[1]}"
}

install_quarto() (
    local latest
    latest="$(latest_quarto_version)" || latest=""

    if command_exists quarto; then
        local current
        current="$(quarto --version)"
        if [[ -z "$latest" ]]; then
            info "Could not check the latest Quarto release; keeping $current"
            return
        fi
        if [[ "$(printf '%s\n' "$current" "$latest" | sort -V | tail -n 1)" == "$current" ]]; then
            info "Quarto $current is up to date"
            return
        fi
        info "Updating Quarto $current to $latest"
    else
        info "Installing Quarto"
    fi

    local package_url="https://quarto.org/download/latest/quarto-linux-${QUARTO_ARCH}"
    local temporary_dir
    temporary_dir="$(mktemp -d)"
    trap 'rm -rf -- "$temporary_dir"' EXIT

    case "$FAMILY" in
    debian)
        curl -fL "${package_url}.deb" -o "$temporary_dir/quarto.deb"
        # apt reads local packages as its unprivileged _apt user.
        chmod 755 "$temporary_dir"
        sudo apt-get install -y "$temporary_dir/quarto.deb"
        ;;
    fedora | rhel | arch)
        # Quarto's .rpm is unsigned and the AUR's quarto-cli builds from
        # source, so use the official tarball.
        curl -fL "${package_url}.tar.gz" -o "$temporary_dir/quarto.tar.gz"
        sudo rm -rf /opt/quarto
        sudo mkdir -p /opt/quarto
        sudo tar -xzf "$temporary_dir/quarto.tar.gz" -C /opt/quarto --strip-components=1
        sudo ln -sf /opt/quarto/bin/quarto /usr/local/bin/quarto
        ;;
    esac

    rm -rf "$temporary_dir"
    trap - EXIT
)

install_uv() {
    mkdir -p "$UV_BIN_DIR"
    if command_exists uv; then
        info "Updating uv"
        # Only uv from the standalone installer can update itself.
        uv self update || printf 'warning: uv could not update itself; update it the way it was installed\n' >&2
    else
        info "Installing uv"
        curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR="$UV_BIN_DIR" UV_NO_MODIFY_PATH=1 sh
    fi

    command_exists uv || die "uv was not found at $UV_BIN_DIR/uv after installation"

}

install_vscode_extensions() {
    if $REMOTE && ! vscode_is_remote; then
        if $EXTENSIONS_ONLY; then
            die "open a VS Code Remote SSH terminal so code points to the remote extension host"
        fi
        info "Open this host with VS Code Remote SSH, then run: bash setup.sh --extensions-only"
        return
    fi
    if ! command_exists code; then
        die "the code CLI is unavailable; run --extensions-only inside a VS Code terminal"
    fi

    info "Installing Visual Studio Code extensions"
    # The Python extension would fetch Pylance, the debugger, and Python
    # Environments (which runs uv) on first launch; list them so they are here
    # now. The ty extension switches Pylance's language server off by itself.
    local extensions=("${VSCODE_EXTENSIONS[@]}")
    if ! $REMOTE; then
        extensions+=(ms-vscode-remote.remote-ssh)
    fi
    if $INSTALL_CUDA; then
        extensions+=(NVIDIA.nsight-vscode-edition)
    fi

    local extension
    for extension in "${extensions[@]}"; do
        code --install-extension "$extension"
    done
}

configure_vscode_settings() {
    local settings_file="${1:-$VSCODE_SETTINGS_FILE}"
    local scope="${2:-user}"
    local python_bin="${3:-python3}"
    info "Configuring Visual Studio Code settings in $settings_file"
    # Preserve preferences; explicit project tool paths are reset to .venv.
    "$python_bin" - "$settings_file" "$scope" <<'EOF'
import json
import re
import shutil
import sys
import time
from pathlib import Path

SETTINGS = {
    # No welcome page, walkthroughs, tips, extension recommendations, surveys,
    # or release notes after updates.
    "workbench.startupEditor": "none",
    "workbench.welcomePage.walkthroughs.openOnInstall": False,
    "workbench.tips.enabled": False,
    "extensions.ignoreRecommendations": True,
    "telemetry.feedback.enabled": False,
    "update.showReleaseNotes": False,
    # No prompts to open a Git repository found in a parent folder, create a
    # Python environment, or configure tests, and no warning for folders
    # without a top-level CMakeLists.txt.
    "git.openRepositoryInParentFolders": "never",
    "python.createEnvironment.trigger": "off",
    "python.testing.promptToConfigure": False,
    "cmake.ignoreCMakeListsMissing": True,
    "yaml.extension.recommendations": False,
}

if sys.argv[2] == "project":
    SETTINGS.update(
        {
            # uv creates environments and installs packages, and Ruff formats and
            # sorts imports on save.
            "python-envs.alwaysUseUv": True,
            "python.defaultInterpreterPath": "${workspaceFolder}/.venv/bin/python",
            "python.testing.pytestEnabled": True,
            "python.testing.unittestEnabled": False,
            "python.testing.pytestArgs": ["--ignore=_extensions", "--ignore=build"],
            "python.testing.cwd": "${workspaceFolder}",
            "git.detectWorktrees": True,
            "marimo.sandbox": False,
            "ruff.path": ["${workspaceFolder}/.venv/bin/ruff"],
            "ty.path": ["${workspaceFolder}/.venv/bin/ty"],
            "[python]": {
                "editor.defaultFormatter": "charliermarsh.ruff",
                "editor.formatOnSave": True,
                "editor.codeActionsOnSave": {"source.organizeImports.ruff": "explicit"},
            },
            # CMake builds use Ninja and ccache and write compile_commands.json for
            # clangd. As environment variables, unlike -D flags, these don't make
            # CMake warn in projects without C or CUDA.
            "cmake.configureEnvironment": {
                "CMAKE_GENERATOR": "Ninja",
                "CMAKE_EXPORT_COMPILE_COMMANDS": "ON",
                "CMAKE_C_COMPILER_LAUNCHER": "ccache",
                "CMAKE_CXX_COMPILER_LAUNCHER": "ccache",
                "CMAKE_CUDA_COMPILER_LAUNCHER": "ccache",
            },
            "cmake.debugConfig": {"type": "lldb"},
            "cmake.buildBeforeRun": True,
            "[c]": {
                "editor.defaultFormatter": "llvm-vs-code-extensions.vscode-clangd",
                "editor.formatOnSave": True,
            },
            "[cpp]": {
                "editor.defaultFormatter": "llvm-vs-code-extensions.vscode-clangd",
                "editor.formatOnSave": True,
            },
        }
    )

# A JSON string, matched first so the patterns below never edit inside one.
STRING = r'("(?:\\.|[^"\\])*")'


def keep_strings(match):
    return match.group(1) or ""


def parse_jsonc(text):
    """Parse settings.json, which may contain comments and trailing commas."""
    text = re.sub(STRING + r"|//[^\n]*|/\*.*?\*/", keep_strings, text, flags=re.S)
    text = re.sub(STRING + r"|,(?=\s*[}\]])", keep_strings, text)
    return json.loads(text) if text.strip() else {}


def add_missing(current, wanted, prefix=""):
    """Add the keys from wanted that current lacks.

    Returns the names added and the names already set to something else.
    """
    added, different = [], []
    for key, value in wanted.items():
        name = prefix + key
        if key not in current:
            current[key] = value
            added.append(name)
        elif isinstance(current[key], dict) and isinstance(value, dict):
            nested_added, nested_different = add_missing(
                current[key], value, f"{name} > "
            )
            added += nested_added
            different += nested_different
        elif current[key] != value:
            different.append(name)
    return added, different


path = Path(sys.argv[1])
original = path.read_text(encoding="utf-8") if path.exists() else ""
try:
    current = parse_jsonc(original)
except ValueError:
    current = None
if not isinstance(current, dict):
    print(f"warning: could not parse {path}; left it unchanged", file=sys.stderr)
    sys.exit(1 if sys.argv[2] == "project" else 0)

# An existing unittest project keeps its chosen runner.
if sys.argv[2] == "project" and current.get("python.testing.unittestEnabled"):
    SETTINGS["python.testing.pytestEnabled"] = False

added, different = add_missing(current, SETTINGS)
# Explicit project tool paths must win over old paths to another machine/env.
if sys.argv[2] == "project":
    for key in (
        "python.defaultInterpreterPath",
        "ruff.path",
        "ty.path",
        "marimo.sandbox",
    ):
        if current.get(key) != SETTINGS[key]:
            current[key] = SETTINGS[key]
            added.append(key + " (updated to this project's .venv)")
            if key in different:
                different.remove(key)
if different:
    print("Kept your own values for:")
    for name in different:
        print(f"  {name}")
if not added:
    print("No settings to add")
    sys.exit()

if original.strip():
    backup = path.with_name(f"{path.name}.bak-{time.strftime('%Y%m%d-%H%M%S')}")
    shutil.copy2(path, backup)
    print(f"Saved the previous settings to {backup}")
    try:
        json.loads(original)
    except ValueError:
        print("Comments in the previous file are kept only in that backup")
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(
    json.dumps(current, indent=4, ensure_ascii=False) + "\n", encoding="utf-8"
)
print("Added:")
for name in added:
    print(f"  {name}")
EOF
}

# CMake records nvcc's command line for .cu files, and clangd, which reads
# CUDA with clang, rejects the nvcc-only flags. Keep this config in the project.
configure_clangd() {
    if [[ -e .clangd ]]; then
        info "Keeping the project's existing .clangd"
        return
    fi

    info "Writing project .clangd for the dev CMake preset and CUDA"
    if [[ "${1:-false}" == true ]]; then
        cat >.clangd <<'EOF'
# Generated by setup.sh; customize and commit this file.
CompileFlags:
  CompilationDatabase: build/dev
---
EOF
    fi
    cat >>.clangd <<'EOF'
If:
  PathMatch: .*\.(cu|cuh)$
# Drop nvcc-only flags that clang rejects in CUDA compile commands.
CompileFlags:
  Remove:
    - -forward-unknown-to-host-compiler
    - --generate-code*
    - -gencode*
    - -arch*
    - --expt-*
    - --extended-lambda
    - -rdc*
    - --relocatable-device-code*
    - -Xcompiler*
    - -Xptxas*
    - --ptxas-options*
    - --use_fast_math
    - -lineinfo
    - --diag-suppress*
    - -ccbin*
    - --options-file
EOF
}

# Shared executable paths only. Build defaults are in each project's presets.
configure_shell() {
    local start="# >>> install.sh >>>"
    local end="# <<< install.sh <<<"
    local block=(
        "$start"
        "# Written by setup.sh; rerunning it replaces this block."
    )
    local dir
    for dir in "$UV_BIN_DIR" ${CUDA_BIN_DIR:+"$CUDA_BIN_DIR"}; do
        local quoted_dir
        printf -v quoted_dir '%q' "$dir"
        block+=("case \":\$PATH:\" in *\":\"$quoted_dir\":\"*) ;; *) export PATH=$quoted_dir:\"\$PATH\" ;; esac")
    done
    block+=("$end")

    info "Adding shared tool PATH entries to $SHELL_RC"
    touch "$SHELL_RC"
    cp -p "$SHELL_RC" "$SHELL_RC.bak-$(date +%Y%m%d-%H%M%S)"
    local kept
    kept="$(awk -v start="$start" -v end="$end" '$0 == start { skip = 1 } !skip { print } $0 == end { skip = 0 }' "$SHELL_RC")"
    {
        if [[ -n "$kept" ]]; then
            printf '%s\n\n' "$kept"
        fi
        printf '%s\n' "${block[@]}"
    } >"$SHELL_RC"
}

verify_installation() {
    info "Verifying installed tools"
    local required_commands=(uv quarto clang clangd clang-format clang-tidy cmake ninja ccache rg jq shellcheck shfmt)
    if ! $REMOTE; then required_commands+=(code); fi
    if $INSTALL_CUDA; then required_commands+=(nvcc); fi
    local command_name
    for command_name in "${required_commands[@]}"; do
        command_exists "$command_name" || die "required command is missing: $command_name"
    done

    printf '\nVersions:\n'
    if command_exists code; then code --version | sed -n '1p'; fi
    uv --version
    quarto --version
    quarto typst --version
    clang --version | sed -n '1p'
    clangd --version | sed -n '1p'
    cmake --version | sed -n '1p'
    ninja --version
    ccache --version | sed -n '1p'
    if command_exists nvcc; then nvcc --version | tail -n 1; fi

    if $INSTALL_CUDA && command_exists nvidia-smi; then
        printf '\nNVIDIA driver:\n'
        nvidia-smi --query-gpu=name,driver_version --format=csv,noheader
    elif $INSTALL_CUDA; then
        printf '\nwarning: nvidia-smi is not available; install and verify the NVIDIA driver separately\n' >&2
    fi

}

require_project_tools() {
    command_exists uv || die "project setup requires uv; run machine setup first"
    command_exists quarto || die "project setup requires Quarto; run machine setup first"
    local version
    version="$(quarto --version)"
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "cannot verify Quarto version: $version"
    [[ "$(printf '%s\n' "$MIN_QUARTO_VERSION" "$version" | sort -V | tail -n 1)" == "$version" ]] ||
        die "quarto-marimo $QUARTO_MARIMO_RELEASE needs Quarto >= $MIN_QUARTO_VERSION; found $version. Update Quarto, then rerun."
    quarto typst --version
}

# Templates are only created when absent; user changes survive subsequent runs.
write_project_file() {
    if [[ -e "$1" ]]; then
        cat >/dev/null
    else
        cat >"$1"
    fi
}

setup_project() (
    require_project_tools
    mkdir -p -- "$PROJECT_DIR"
    cd -- "$PROJECT_DIR"
    # An activated environment or a host-wide uv override must not redirect installs.
    unset VIRTUAL_ENV CONDA_PREFIX PYTHONPATH PYTHONHOME UV_PYTHON UV_PROJECT UV_WORKING_DIRECTORY UV_ACTIVE
    export UV_PROJECT_ENVIRONMENT="$PWD/.venv"

    info "Setting up project Python dependencies in $PWD/.venv"
    # A stdlib-only bootstrap interpreter supplies tomllib even on old host Python.
    # Application packages are installed only into the project's .venv.
    uv run --no-project --python 3.12 python - "$PROJECT_PYTHON" "${VSCODE_EXTENSIONS[@]}" <<'PY'
import json
import re
import shutil
import subprocess
import sys
import time
import tomllib
from pathlib import Path

root = Path.cwd()
requested_python = sys.argv[1]
extensions = sys.argv[2:]


def run(*args):
    subprocess.run(args, check=True)


def read_toml(path):
    return tomllib.loads(path.read_text(encoding="utf-8"))


def create(path, text):
    if not path.exists():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")


# Do not let uv edit a parent workspace or install into a linked external venv.
if (root / ".venv").is_symlink():
    sys.exit("error: .venv is a symlink; use a project-owned environment")
for parent in root.parents:
    candidate = parent / "pyproject.toml"
    if candidate.exists() and "workspace" in read_toml(candidate).get("tool", {}).get(
        "uv", {}
    ):
        sys.exit(
            f"error: choose a standalone project outside the uv workspace at {parent}"
        )
for filename, marker in (
    ("dev.sh", "# Generated by setup.sh"),
    ("_quarto-marimo.yml", "# Generated by setup.sh"),
    ("_extensions/project-marimo/engine.js", "// Generated by setup.sh"),
    ("_extensions/project-marimo/_extension.yml", "# Generated by setup.sh"),
):
    path = root / filename
    if path.exists() and marker not in path.read_text(encoding="utf-8"):
        sys.exit(
            f"error: {filename} already exists and is not a setup.sh template; left it unchanged"
        )

pyproject = root / "pyproject.toml"
new_project = not pyproject.exists()
pin = root / ".python-version"
if requested_python and pin.exists() and pin.read_text().strip() != requested_python:
    sys.exit(
        "error: --python conflicts with the existing .python-version; change the project pin explicitly"
    )
if new_project:
    name = re.sub(r"[^a-z0-9-]+", "-", root.name.lower()).strip("-") or "analysis"
    run(
        "uv",
        "init",
        "--bare",
        "--no-workspace",
        "--vcs",
        "none",
        "--name",
        name,
        "--python",
        requested_python or "3.12",
    )
    create(pin, (requested_python or "3.12") + "\n")
elif requested_python:
    create(pin, requested_python + "\n")

data = read_toml(pyproject)
if "project" not in data or "workspace" in data.get("tool", {}).get("uv", {}):
    sys.exit("error: project setup requires a standalone [project] in pyproject.toml")
if data.get("tool", {}).get("uv", {}).get("managed") is False:
    sys.exit("error: this project disables uv environment management")


def names(requirements):
    found = set()
    for requirement in requirements:
        if isinstance(requirement, str):
            match = re.match(r"[A-Za-z0-9][A-Za-z0-9._-]*", requirement)
            if match:
                found.add(re.sub(r"[-_.]+", "-", match.group()).lower())
    return found


# Check an existing lock before making intentional additions. Never silently
# refresh a stale lock or upgrade requirements that are already present.
if (root / "uv.lock").exists():
    run("uv", "sync", "--locked")
if "marimo" not in names(data["project"].get("dependencies", [])):
    run("uv", "add", "marimo>=0.23.16")
development = names(data.get("dependency-groups", {}).get("dev", []))
missing = [name for name in ("ruff", "ty", "pytest") if name not in development]
if missing:
    run("uv", "add", "--dev", *missing)
# Project files stop editor tools from inheriting unrelated parent settings.
data = read_toml(pyproject)
if "ruff" not in data.get("tool", {}) and not any(
    (root / name).exists() for name in ("ruff.toml", ".ruff.toml")
):
    with pyproject.open("a", encoding="utf-8") as stream:
        stream.write('\n[tool.ruff]\nextend-exclude = ["_extensions", "build"]\n')
if "ty" not in data.get("tool", {}) and not (root / "ty.toml").exists():
    with pyproject.open("a", encoding="utf-8") as stream:
        stream.write('\n[tool.ty.src]\nexclude = ["_extensions", "build"]\n')
if (root / "uv.lock").exists():
    run("uv", "sync", "--locked", "--group", "dev")
else:
    run("uv", "sync", "--group", "dev")

version = subprocess.check_output(
    [
        str(root / ".venv/bin/python"),
        "-c",
        "import platform; print(platform.python_version())",
    ],
    text=True,
).strip()
create(pin, version + "\n")
run(
    str(root / ".venv/bin/python"),
    "-c",
    "from importlib.metadata import version; "
    "v = version('marimo'); "
    "assert tuple(map(int, v.split('.')[:3])) >= (0,23,16), "
    "'quarto-marimo needs marimo >= 0.23.16; update this project explicitly'",
)

# Keep existing Quarto configuration. A profile adds the integration when
# dev.sh renders an existing project, without rewriting its YAML/comments.
if not (root / "_quarto.yml").exists() and not (root / "_quarto.yaml").exists():
    create(
        root / "_quarto.yml",
        """# Generated by setup.sh; customize and commit.
project:
  type: default
  output-dir: _output
engine: project-marimo
external-env: true
execute:
  error: false
format:
  html: default
  typst: default
""",
    )
create(
    root / "_quarto-marimo.yml",
    """# Generated by setup.sh; used by dev.sh render/preview.
engine: project-marimo
external-env: true
execute:
  error: false
""",
)

string = r'("(?:\\.|[^"\\])*")'


def jsonc(path):
    if not path.exists():
        return {}
    text = path.read_text(encoding="utf-8")
    text = re.sub(
        string + r"|//[^\n]*|/\*.*?\*/", lambda m: m.group(1) or "", text, flags=re.S
    )
    text = re.sub(string + r"|,(?=\s*[}\]])", lambda m: m.group(1) or "", text)
    value = json.loads(text) if text.strip() else {}
    if not isinstance(value, dict):
        raise ValueError(f"{path} must contain an object")
    return value


def merge_entries(path, key, values, identity):
    current = jsonc(path)
    entries = current.setdefault(key, [])
    if not isinstance(entries, list):
        raise ValueError(f"{path}: {key} must be an array")
    known = {identity(entry) for entry in entries}
    additions = [value for value in values if identity(value) not in known]
    if not additions:
        return
    entries.extend(additions)
    if path.exists():
        shutil.copy2(
            path, path.with_name(path.name + ".bak-" + time.strftime("%Y%m%d-%H%M%S"))
        )
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(current, indent=4) + "\n", encoding="utf-8")


merge_entries(
    root / ".vscode/extensions.json",
    "recommendations",
    extensions,
    lambda item: item.lower(),
)
tasks = [
    {
        "label": label,
        "type": "process",
        "command": "bash",
        "args": ["${workspaceFolder}/dev.sh", command],
        "options": {"cwd": "${workspaceFolder}"},
        "problemMatcher": [],
    }
    for label, command in (
        ("Project: render", "render"),
        ("Project: preview", "preview"),
        ("Project: check Python", "check"),
        ("Project: test Python", "test"),
        ("Project: sync", "sync"),
    )
]
tasks.append(
    {
        "label": "Project: run Python file",
        "type": "process",
        "command": "bash",
        "args": ["${workspaceFolder}/dev.sh", "run", "python", "${file}"],
        "options": {"cwd": "${workspaceFolder}"},
        "problemMatcher": [],
    }
)
create(root / ".vscode/tasks.json", '{"version": "2.0.0", "tasks": []}\n')
merge_entries(
    root / ".vscode/tasks.json", "tasks", tasks, lambda item: item.get("label")
)

python_debug = {
    "type": "debugpy",
    "request": "launch",
    "python": "${workspaceFolder}/.venv/bin/python",
    "cwd": "${workspaceFolder}",
    "console": "integratedTerminal",
    "justMyCode": True,
    "preLaunchTask": "Project: sync",
    "env": {
        "VIRTUAL_ENV": "${workspaceFolder}/.venv",
        "UV_PROJECT_ENVIRONMENT": "${workspaceFolder}/.venv",
        "PYTHONPATH": "",
        "PYTHONHOME": "",
    },
}
configurations = [
    {**python_debug, "name": "Python: current file", "program": "${file}"},
    {
        **python_debug,
        "name": "Python: tests in Testing panel",
        "purpose": ["debug-test"],
    },
    {
        **python_debug,
        "name": "marimo: current notebook (interactive)",
        "program": "${file}",
        "justMyCode": False,
        "env": {**python_debug["env"], "MARIMO_SCRIPT_EDIT": "1"},
    },
    {
        "name": "C++: CMake target",
        "type": "lldb",
        "request": "launch",
        # CMake Tools configures/builds the selected executable when resolving
        # this command, according to its cmake.buildBeforeRun setting.
        "program": "${command:cmake.launchTargetPath}",
        "cwd": "${workspaceFolder}",
        "args": [],
    },
]
create(root / ".vscode/launch.json", '{"version": "0.2.0", "configurations": []}\n')
merge_entries(
    root / ".vscode/launch.json",
    "configurations",
    configurations,
    lambda item: item.get("name"),
)

# Small runnable examples for new projects; never inject example tests into an
# existing project's test suite or create tests for a pre-existing user file.
if new_project and not any(
    (root / name).exists() for name in ("debug_example.py", "test_debug_example.py")
):
    create(
        root / "debug_example.py",
        '''"""Open this file in VS Code to practice stepping through Python."""


def sum_squares(numbers: list[int]) -> int:
    total = 0
    for number in numbers:
        squared = number * number  # Put a breakpoint here (F9).
        total += squared
    return total


if __name__ == "__main__":
    values = [2, 3, 4]
    result = sum_squares(values)
    print(f"Sum of squares: {result}")
''',
    )
    create(
        root / "test_debug_example.py",
        '''"""Run or debug these checks from VS Code's Testing panel."""

from debug_example import sum_squares


def test_sum_squares():
    assert sum_squares([2, 3, 4]) == 29


def test_empty_input():
    assert sum_squares([]) == 0


def test_negative_input():
    assert sum_squares([-2, 3]) == 13
''',
    )

ignore = root / ".gitignore"
original = ignore.read_text(encoding="utf-8") if ignore.exists() else ""
patterns = [
    ".venv/",
    ".quarto/",
    "_output/",
    "build/",
    "__pycache__/",
    ".pytest_cache/",
    ".ruff_cache/",
    "*.bak-*",
    ".env",
]
missing_patterns = [
    pattern for pattern in patterns if pattern not in original.splitlines()
]
if missing_patterns:
    with ignore.open("a", encoding="utf-8") as stream:
        if original and not original.endswith("\n"):
            stream.write("\n")
        stream.write(
            "\n# Local environments and generated files\n"
            + "\n".join(missing_patterns)
            + "\n"
        )
PY

    local extension_manifest=""
    local candidate
    for candidate in _extensions/marimo-team/marimo/_extension.yml _extensions/marimo/_extension.yml; do
        if [[ -f "$candidate" ]]; then
            extension_manifest="$candidate"
            break
        fi
    done
    if [[ -z "$extension_manifest" ]]; then
        info "Adding project extension quarto-marimo $QUARTO_MARIMO_RELEASE"
        quarto add "marimo-team/quarto-marimo@$QUARTO_MARIMO_RELEASE" --no-prompt
    else
        info "Keeping the project's existing quarto-marimo extension"
        .venv/bin/python - "$extension_manifest" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
match = re.search(r'^version:\s*["\x27]?(\d+)\.(\d+)\.(\d+)', path.read_text(), re.M)
if (
    not match
    or tuple(map(int, match.groups())) < (0, 5, 0)
    or not (path.parent / "marimo-engine.js").exists()
):
    sys.exit(
        "error: existing quarto-marimo is incompatible/incomplete; update the project's extension to >= 0.5.0 explicitly"
    )
PY
    fi

    # Upstream v0.5 reads external-env from document front matter, ignoring
    # project/profile defaults. A local adapter enforces .venv for every file
    # without modifying either the user's documents or the vendored extension.
    .venv/bin/python - <<'PY'
import json
import os
from pathlib import Path

root = Path.cwd()
upstream = next(
    (
        path
        for path in (
            root / "_extensions/marimo-team/marimo/marimo-engine.js",
            root / "_extensions/marimo/marimo-engine.js",
        )
        if path.exists()
    ),
    None,
)
if upstream is None:
    raise SystemExit("error: quarto-marimo installation did not provide its engine")
directory = root / "_extensions/project-marimo"
directory.mkdir(parents=True, exist_ok=True)
manifest = directory / "_extension.yml"
adapter = directory / "engine.js"
if not manifest.exists():
    manifest.write_text(
        """# Generated by setup.sh
title: Project marimo environment
version: 1.0.0
quarto-required: ">=1.9.20"
contributes:
  engines:
    - path: engine.js
""",
        encoding="utf-8",
    )
if not adapter.exists():
    import_path = json.dumps(os.path.relpath(upstream, directory))
    adapter.write_text(
        "// Generated by setup.sh: always execute in the project's .venv.\n"
        + "import upstream from "
        + import_path
        + ";\n"
        + """
const name = "project-marimo";
export default {
    ...upstream,
    name,
    defaultYaml: () => ["format: html", `engine: ${name}`],
    launch(context) {
        const worker = upstream.launch(context);
        return {
            ...worker,
            name,
            async execute(options) {
                const python = decodeURIComponent(new URL("../../.venv/bin/python", import.meta.url).pathname);
                const result = await new Deno.Command(python, {
                    args: ["-c", 'from importlib.metadata import version; print(version("marimo"))'],
                    stdout: "piped",
                    stderr: "piped",
                }).output();
                if (!result.success) throw new Error("Run ./dev.sh sync to restore the project's Python environment");
                Deno.env.set("QUARTO_PYTHON", python);
                Deno.env.set("QUARTO_MARIMO_VERSION", new TextDecoder().decode(result.stdout).trim());
                const target = {...options.target, metadata: {...options.target.metadata, "external-env": true}};
                return {...await worker.execute({...options, target}), engine: name};
            },
        };
    },
};
""",
        encoding="utf-8",
    )
PY

    write_project_file dev.sh <<'EOF'
#!/usr/bin/env bash
# Generated by setup.sh; project commands always use this project's .venv.
set -Eeuo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
unset VIRTUAL_ENV CONDA_PREFIX PYTHONPATH PYTHONHOME UV_PYTHON UV_PROJECT UV_WORKING_DIRECTORY UV_ACTIVE
export UV_PROJECT_ENVIRONMENT="$PWD/.venv"
command="${1:-help}"
if (( $# )); then shift; fi
if [[ "$command" == help || "$command" == --help || "$command" == -h ]]; then
    cat <<'HELP'
Usage: ./dev.sh COMMAND [ARGUMENTS]
  sync                Restore .venv from uv.lock, without upgrading
  render [ARGS]       Render Quarto documents with project marimo (HTML/Typst)
  preview [ARGS]      Open a document preview (no browser in SSH sessions)
  notebook [FILE]     Edit a marimo notebook using project packages
  check [PATHS]       Ruff lint and ty type checks
  test [ARGS]         Run pytest
  run COMMAND [...]   Run any command in the locked project environment
  doctor              Report Python, marimo, Ruff, ty, Quarto, and Typst versions
Add project packages with uv add PACKAGE; commit pyproject.toml and uv.lock.
HELP
    exit 0
fi
case "$command" in
    sync|render|preview|notebook|check|test|run|doctor) ;;
    *) printf 'error: unknown project command: %s\n' "$command" >&2; exit 1 ;;
esac
if [[ -L .venv ]]; then
    printf 'error: .venv must belong to this project, not be a symlink\n' >&2
    exit 1
fi
uv sync --locked --group dev
if [[ "$command" == sync ]]; then exit 0; fi
export PATH="$PWD/.venv/bin:$PATH"
if ! command -v nvcc >/dev/null 2>&1; then
    for cuda_bin in /usr/local/cuda/bin /opt/cuda/bin; do
        if [[ -x "$cuda_bin/nvcc" ]]; then
            export PATH="$cuda_bin:$PATH"
            break
        fi
    done
fi
export QUARTO_PYTHON="$PWD/.venv/bin/python"
export QUARTO_MARIMO_VERSION
QUARTO_MARIMO_VERSION="$(python -c 'from importlib.metadata import version; print(version("marimo"))')"
headless=false
if [[ -n "${SSH_CONNECTION:-}${SSH_TTY:-}" || "$(command -v code || true)" == */remote-cli/* ]]; then
    headless=true
fi
case "$command" in
    render|preview)
        version="$(quarto --version)"
        if [[ "$(printf '%s\n' 1.9.20 "$version" | sort -V | tail -n 1)" != "$version" ]]; then
            printf 'error: quarto-marimo requires Quarto >= 1.9.20 (found %s)\n' "$version" >&2
            exit 1
        fi
        if [[ "$command" == preview ]]; then
            browser_args=()
            if $headless; then browser_args+=(--no-browser); fi
            exec quarto preview --profile marimo --metadata engine:project-marimo "${browser_args[@]}" "$@"
        fi
        exec quarto render --profile marimo --metadata engine:project-marimo "$@"
        ;;
    notebook)
        browser_args=()
        if $headless; then browser_args+=(--headless); fi
        exec marimo edit "${browser_args[@]}" "$@"
        ;;
    check) ruff check --extend-exclude _extensions "${@:-.}"; exec ty check --exclude _extensions "$@" ;;
    test) exec pytest --ignore=_extensions "$@" ;;
    run)
        if (( $# == 0 )); then printf 'error: run requires a command\n' >&2; exit 1; fi
        exec "$@"
        ;;
    doctor)
        python --version
        marimo --version
        ruff --version
        ty --version
        quarto --version
        quarto typst --version
        ;;
esac
EOF
    chmod +x dev.sh

    write_project_file .marimo.toml <<'EOF'
# Keep notebook preferences and package management inside the project.
[package_management]
manager = "uv"
EOF
    write_project_file .editorconfig <<'EOF'
root = true

[*]
charset = utf-8
end_of_line = lf
insert_final_newline = true
indent_style = space
indent_size = 4

[*.{yml,yaml,json,toml}]
indent_size = 2

[Makefile]
indent_style = tab
EOF
    write_project_file .clang-format <<'EOF'
BasedOnStyle: LLVM
IndentWidth: 4
EOF
    local new_cmake_presets=false
    if [[ ! -e CMakePresets.json ]]; then new_cmake_presets=true; fi
    write_project_file CMakePresets.json <<'EOF'
{
    "version": 2,
    "cmakeMinimumRequired": {"major": 3, "minor": 20, "patch": 0},
    "configurePresets": [{
        "name": "dev",
        "generator": "Ninja",
        "binaryDir": "${sourceDir}/build/dev",
        "cacheVariables": {
            "CMAKE_BUILD_TYPE": "Debug",
            "CMAKE_EXPORT_COMPILE_COMMANDS": true,
            "CMAKE_C_COMPILER_LAUNCHER": "ccache",
            "CMAKE_CXX_COMPILER_LAUNCHER": "ccache",
            "CMAKE_CUDA_COMPILER_LAUNCHER": "ccache"
        }
    }],
    "buildPresets": [{"name": "dev", "configurePreset": "dev"}],
    "testPresets": [{"name": "dev", "configurePreset": "dev"}]
}
EOF
    write_project_file example.qmd <<'EOF'
---
title: Project check
---

This result is computed using this project's Python environment.

```{python .marimo}
#| error: false
import marimo as mo

result = 6 * 7
mo.md(f"Project Python says **{result}**.")
```
EOF
    write_project_file PROJECT-SETUP.md <<'EOF'
# Working on this project in VS Code

Open this whole folder in VS Code: `code .` (or File > Open Folder).
Python packages and tools live in this folder's `.venv`. On a new computer or
in a new worktree, first run `./dev.sh sync` in VS Code's terminal.

## Try the debugger

New projects include `debug_example.py` and three small tests. Existing projects
can use their own Python scripts with the same debug configuration.

1. Open `debug_example.py`. Click to the left of the line number on
   `squared = number * number` (or press F9 on that line). The red dot is a
   **breakpoint**: execution will pause before running that line.
2. Open Run and Debug in the sidebar (Ctrl+Shift+D), choose **Python: current
   file**, and press F5. This restores the locked project environment first.
3. While paused, hover over `number` or look in **Variables** to see its value.
   Press **F10** to run one line; watch `squared` and `total` change.
4. **F11** steps inside a function call; **Shift+F11** finishes that function.
   **F5** continues to the next breakpoint; **Shift+F5** stops debugging.

The Debug Console can evaluate expressions while paused, and Watch keeps chosen
expressions visible. The highlighted line is the next line to execute. To run
without pausing, use Run > Run Without Debugging (Ctrl+F5).

For tests, open the **Testing** sidebar (the flask icon), then use the play or
debug button next to a test. New projects use pytest automatically. The example
tests should all pass; delete the two example files when you no longer need them.
Use Terminal > Run Task for **Project: check Python**, **Project: test Python**,
or **Project: run Python file**. Ruff formats Python when you save.

If VS Code remembers an interpreter from before this setup, run **Python: Select
Interpreter** from Ctrl+Shift+P and choose this folder's `.venv/bin/python`.
F5 configurations already point explicitly at it. Tips, surveys, release notes,
and routine setup prompts are suppressed; errors and debugging views still work.

## Notebooks, documents, and C++

`./dev.sh notebook notebook.py` opens the marimo editor in your browser.
For interactive notebook debugging, open a saved marimo `.py` file and select
**marimo: current notebook (interactive)** in Run and Debug. Set a breakpoint,
press F5, and run the cell in the notebook editor. Save the notebook before
debugging; while stopped at a breakpoint, resume from VS Code to unblock it.
For a notebook's script execution, use **Python: current file** instead.

Run `./dev.sh render example.qmd --to typst` for a PDF, or use `--to html`.
**Project: preview** in Terminal > Run Task (or `./dev.sh preview`) opens a browser
preview. A `.qmd` document is rendered with Quarto; the Python F5 configuration
expects a `.py` file. Put reusable calculations in Python files when you want to
debug them separately from the document.

For a C++ project with a `CMakeLists.txt`, choose **CMake: Select Configure Preset**
from Ctrl+Shift+P and select `dev` (or your existing Debug preset). Run **CMake:
Configure**, then select **C++: CMake target** in Run and Debug and press F5.
Choose your executable if prompted. CMake Tools builds it before debugging by
default; use a Debug build to inspect local variables reliably. The same
breakpoint and step controls apply. CUDA device debugging uses optional Nsight.

## Git checkpoints and optional worktrees

Git records checkpoints called commits. For a new project, open **Source Control**
(Ctrl+Shift+G), choose **Initialize Repository**, review/stage the files, write a
message, and commit. Git may first ask you to configure your author name/email.
Commits stay on your computer until you choose to push them elsewhere.

A branch lets you develop an idea separately. Use **Git: Create Branch** when
you want one. A worktree is a second folder with a different branch checked out;
it is useful when you want two versions open at once. In Source Control's
Repositories view, use **... > Worktrees > Create Worktree**, then open that folder
in a new window and run `./dev.sh sync`. Commit the setup files before creating
the worktree so it receives them. Each worktree gets its own `.venv` and `build/`;
never copy or link another worktree's `.venv`. You can start with ordinary commits
and learn branches/worktrees when you need them.

## Dependencies and reproducibility

Shared prerequisites: uv, Quarto >= 1.9.20 (includes Typst), and your C++/CUDA
toolchain if used. VS Code extensions are installed per user; project settings,
debug configurations, and Python packages are kept here.

On another machine, clone this directory and run `./dev.sh sync`.
This restores the committed `uv.lock`, including development dependencies.
uv may download the Python version requested by `.python-version`.
Do not copy `.venv` between machines. New projects start with Python 3.12.

The `marimo` Quarto profile selects the project Python environment for builds.
Its small `project-marimo` engine adapter is kept in `_extensions/` alongside
upstream quarto-marimo. This handles an upstream v0.5 limitation: external-env
in project YAML alone is ignored. The adapter enforces .venv for every document.
The wrapper also sets QUARTO_PYTHON and matches the HTML marimo runtime version
to the installed Python package. Use the Project tasks in VS Code for the same
environment selection. The standalone Quarto preview button may use different
environment settings; use these tasks for reliable project isolation.

Add packages with `uv add PACKAGE`; add development tools with `uv add --dev TOOL`.
Use `./dev.sh check`, `./dev.sh test`, and `./dev.sh doctor` as needed.
Upgrade deliberately with `uv lock --upgrade`, then `./dev.sh sync` and test.
For CMake projects, use `cmake --preset dev` and `cmake --build --preset dev`.
Adapt the presets and `.clangd` if your existing project uses another build folder.

Commit `.python-version`, `.marimo.toml`, `pyproject.toml`, `uv.lock`, `_extensions/`, the Quarto
YAML files, `dev.sh`, and the editor/build configuration. Keep `.venv`, generated
output, secrets, and local caches out of Git. Each newly initialized project
gets quarto-marimo v0.5.0; reruns keep its existing extension. Update it deliberately.

Interactive HTML runs Python in the browser, separately from the build's .venv.
Declare browser-compatible dependencies using quarto-marimo's `pyproject`
document metadata; a local uv.lock does not automatically lock browser packages.
CUDA/native libraries are not generally available in that browser environment.
PDFs contain static output from the project's Python environment.

For consistent typography, commit any extra fonts with the project and configure
Typst font paths; host fonts and host tool versions can otherwise differ.

The initializer preserves existing documents, Quarto YAML, presets, and custom
clangd settings. It adds missing VS Code settings with a backup and sets Python,
Ruff, and ty paths to .venv. It refuses to adopt a uv workspace or a conflicting
dev.sh/_quarto-marimo.yml; initialize a separate directory in those cases.
On a headless SSH host, open the folder with VS Code Remote SSH and run
`bash /path/to/setup.sh --extensions-only` inside its terminal to install extensions.
Preview/notebook commands automatically skip opening a browser in SSH/VS Code
remote sessions; forward the displayed port to your computer. Locally, pass
`--no-browser` to preview or `--headless` to notebook if you want the same behavior.

References:
- https://code.visualstudio.com/docs/python/debugging
- https://code.visualstudio.com/docs/python/testing
- https://code.visualstudio.com/docs/sourcecontrol/branches-worktrees
- https://docs.marimo.io/guides/debugging/
- https://github.com/marimo-team/quarto-marimo
- https://quarto.org/docs/extensions/managing.html
- https://docs.astral.sh/uv/guides/projects/
EOF

    configure_clangd "$new_cmake_presets"
    configure_vscode_settings "$PWD/.vscode/settings.json" project "$PWD/.venv/bin/python"
    # Load extension assets now so _extensions can be committed in full.
    quarto inspect . --profile marimo >/dev/null
    ./dev.sh doctor
    info "Project ready: $PWD"
    printf 'Open in VS Code: code %q\n' "$PWD"
    printf '%s\n' "See PROJECT-SETUP.md for breakpoints, tests, notebooks, and Git." \
        "Run ./dev.sh render example.qmd --to typst to check PDF output."
)

main() {
    parse_arguments "$@"
    if $EXTENSIONS_ONLY; then
        install_vscode_extensions
        return
    fi
    if ! $PROJECT_ONLY; then
        detect_host
        install_system_packages
        install_vscode
        install_quarto
        install_uv
        if ! $REMOTE; then
            configure_vscode_settings
            configure_shell
        fi
        install_vscode_extensions
        verify_installation
    fi
    if [[ -n "$PROJECT_DIR" ]]; then
        setup_project
    else
        info "Shared tools ready. Initialize a project with: bash setup.sh --project-only /path/to/project"
    fi
}

main "$@"
