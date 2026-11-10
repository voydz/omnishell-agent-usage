#!/bin/bash
# Installs the pinned CodexBar CLI, a LaunchAgent that runs `codexbar serve`
# on loopback, and the agent-usage OmniShell widget.
set -euo pipefail

LABEL="io.github.voydz.omnishell-agent-usage"
DEFAULT_PORT=18487
RELEASES="https://github.com/steipete/CodexBar/releases/download"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
LOCK_FILE="$REPO_DIR/codexbar.lock"
WIDGET_SRC="$REPO_DIR/widget/agent-usage"

DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/omnishell-agent-usage"
CLI_ROOT="$DATA_DIR/codexbar"
LOG_DIR="$HOME/Library/Logs/omnishell-agent-usage"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
SHELL_DIR="${OMNIWM_SHELL_DIR:-$HOME/.config/omniwm/shell}"
WIDGET_DST="$SHELL_DIR/widgets/agent-usage"
MARKER=".omnishell-agent-usage"
DOMAIN="gui/$(id -u)"

TMP_DIR=""
trap '[ -z "$TMP_DIR" ] || rm -rf "$TMP_DIR"' EXIT

usage() {
    cat <<EOF
Usage: ./install.sh [install] [--link] [--port <port>]
       ./install.sh status
       ./install.sh uninstall

  install     Download the CodexBar CLI pinned in codexbar.lock, start the
              LaunchAgent and install the widget. Run again to update.
  --link      Symlink the widget to this checkout instead of copying it.
  --port      Loopback port for the CodexBar server (default $DEFAULT_PORT).
  status      Show the installed version and whether the server answers.
  uninstall   Remove the LaunchAgent, the CLI, the logs and the widget.
EOF
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

info() {
    printf '%s\n' "$*"
}

lock_value() {
    sed -n "s/^$1=//p" "$LOCK_FILE" | head -n 1
}

xml_escape() {
    printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

install_cli() {
    local version arch expected dest tmp url actual dir name
    version="$(lock_value version)"
    arch="$(uname -m)"
    case "$arch" in
        arm64 | x86_64) ;;
        *) die "unsupported architecture: $arch" ;;
    esac
    expected="$(lock_value "sha256_macos_$arch")"
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "codexbar.lock has no valid version"
    [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || die "codexbar.lock has no checksum for macos-$arch"

    dest="$CLI_ROOT/$version"
    if [ -x "$dest/CodexBarCLI" ] && [ "$(cat "$dest/.sha256" 2>/dev/null)" = "$expected" ]; then
        info "CodexBar CLI $version is already installed."
    else
        tmp="$(mktemp -d)"
        TMP_DIR="$tmp"
        url="$RELEASES/v$version/CodexBarCLI-v$version-macos-$arch.tar.gz"
        info "Downloading CodexBar CLI $version (macos-$arch)…"
        curl -fsSL --proto '=https' --tlsv1.2 --retry 3 -o "$tmp/cli.tar.gz" "$url" \
            || die "download failed: $url"
        actual="$(shasum -a 256 "$tmp/cli.tar.gz" | awk '{print $1}')"
        [ "$actual" = "$expected" ] \
            || die "checksum mismatch for $url (expected $expected, got $actual)"
        mkdir "$tmp/unpacked"
        tar -xzf "$tmp/cli.tar.gz" -C "$tmp/unpacked"
        [ -x "$tmp/unpacked/CodexBarCLI" ] || die "release archive has no CodexBarCLI executable"
        mkdir -p "$CLI_ROOT"
        rm -rf "$dest"
        mv "$tmp/unpacked" "$dest"
        printf '%s\n' "$expected" > "$dest/.sha256"
        info "Installed CodexBar CLI $version."
    fi

    ln -sfn "$version" "$CLI_ROOT/current"
    for dir in "$CLI_ROOT"/*; do
        name="$(basename "$dir")"
        if [ "$name" != "$version" ] && [ "$name" != "current" ]; then
            rm -rf "$dir"
        fi
    done
}

# The server shells out to provider CLIs such as `codex`, which usually live
# on the interactive shell's PATH rather than launchd's.
login_path() {
    local shell output found
    shell="${SHELL:-/bin/zsh}"
    output="$("$shell" -lic 'command env' 2>/dev/null </dev/null || true)"
    found="$(printf '%s\n' "$output" | sed -n 's/^PATH=//p' | tail -n 1)"
    [ -n "$found" ] || found="$PATH"
    printf '%s:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin' "$found"
}

write_plist() {
    local port="$1" cli log path
    cli="$(xml_escape "$CLI_ROOT/current/CodexBarCLI")"
    log="$(xml_escape "$LOG_DIR/serve.log")"
    path="$(xml_escape "$(login_path)")"
    mkdir -p "$LOG_DIR" "$(dirname "$PLIST")"
    cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$cli</string>
        <string>serve</string>
        <string>--host</string>
        <string>127.0.0.1</string>
        <string>--port</string>
        <string>$port</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>$path</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>ThrottleInterval</key>
    <integer>30</integer>
    <key>ProcessType</key>
    <string>Background</string>
    <key>StandardOutPath</key>
    <string>$log</string>
    <key>StandardErrorPath</key>
    <string>$log</string>
</dict>
</plist>
EOF
    plutil -lint "$PLIST" >/dev/null || die "generated an invalid LaunchAgent plist: $PLIST"
}

stop_agent() {
    local attempt=0
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    while [ "$attempt" -lt 20 ]; do
        launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 || return 0
        sleep 0.25
        attempt=$((attempt + 1))
    done
    die "the LaunchAgent $LABEL did not stop"
}

server_healthy() {
    curl -fsS -m 2 "http://127.0.0.1:$1/health" >/dev/null 2>&1
}

start_agent() {
    local port="$1" attempt=0
    stop_agent
    launchctl bootstrap "$DOMAIN" "$PLIST" || die "could not load the LaunchAgent: $PLIST"
    while [ "$attempt" -lt 20 ]; do
        if server_healthy "$port"; then
            info "CodexBar server is running on http://127.0.0.1:$port."
            return 0
        fi
        sleep 0.5
        attempt=$((attempt + 1))
    done
    die "the server did not answer on port $port; see $LOG_DIR/serve.log"
}

remove_widget() {
    if [ -L "$WIDGET_DST" ]; then
        rm "$WIDGET_DST"
    elif [ -e "$WIDGET_DST" ]; then
        [ -f "$WIDGET_DST/$MARKER" ] \
            || die "$WIDGET_DST exists and was not installed by this script; move it away first"
        rm -rf "$WIDGET_DST"
    fi
}

install_widget() {
    local link="$1"
    [ -d "$SHELL_DIR" ] || die "OmniShell folder not found at $SHELL_DIR (needs OmniWM 0.8 or later)"
    mkdir -p "$SHELL_DIR/widgets"
    remove_widget
    if [ "$link" = 1 ]; then
        ln -s "$WIDGET_SRC" "$WIDGET_DST"
        info "Linked the widget to $WIDGET_SRC."
    else
        mkdir "$WIDGET_DST"
        cp "$WIDGET_SRC"/*.luau "$WIDGET_SRC"/*.toml "$WIDGET_DST"/
        : > "$WIDGET_DST/$MARKER"
        info "Installed the widget to $WIDGET_DST."
    fi
}

cmd_install() {
    local link="$1" port="$2"
    [ -f "$LOCK_FILE" ] || die "missing $LOCK_FILE; run this script from a checkout of the repo"
    [ -d "$WIDGET_SRC" ] || die "missing $WIDGET_SRC; run this script from a checkout of the repo"
    install_cli
    write_plist "$port"
    start_agent "$port"
    install_widget "$link"
    cat <<EOF

Next steps:
  1. Add "agent-usage" to a bar lane: Settings > Styles & Widgets > Bar > Add Widget.
  2. Allow the widget to reach 127.0.0.1 when OmniWM asks.
  3. Sign in to the providers you want with the CodexBar CLI (see README.md):
       $CLI_ROOT/current/codexbar config providers
EOF
    if [ "$port" != "$DEFAULT_PORT" ]; then
        info "  4. Set the widget's \"CodexBar server port\" option to $port."
    fi
}

cmd_status() {
    local port="$1" current
    info "Pinned CodexBar CLI:    $(lock_value version)"
    if current="$(readlink "$CLI_ROOT/current" 2>/dev/null)"; then
        info "Installed CodexBar CLI: $current"
    else
        info "Installed CodexBar CLI: none"
    fi
    if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
        info "LaunchAgent:            loaded"
    else
        info "LaunchAgent:            not loaded"
    fi
    if server_healthy "$port"; then
        info "Server on port $port:   answering"
    else
        info "Server on port $port:   not answering"
    fi
    if [ -e "$WIDGET_DST" ]; then
        info "Widget:                 $WIDGET_DST"
    else
        info "Widget:                 not installed"
    fi
}

cmd_uninstall() {
    stop_agent
    rm -f "$PLIST"
    rm -rf "$DATA_DIR" "$LOG_DIR"
    remove_widget
    info "Removed the LaunchAgent, the CodexBar CLI, the logs and the widget."
    info "Still yours to remove: \"agent-usage\" in your bar lanes, the widget's entry under"
    info "Settings > Network & Permissions, and the CodexBar config in ~/.config/codexbar."
}

main() {
    local command="install" link=0 port="$DEFAULT_PORT"
    while [ $# -gt 0 ]; do
        case "$1" in
            install | uninstall | status) command="$1" ;;
            --link) link=1 ;;
            --port)
                [ $# -ge 2 ] || die "--port needs a value"
                port="$2"
                shift
                ;;
            --port=*) port="${1#--port=}" ;;
            -h | --help)
                usage
                exit 0
                ;;
            *)
                usage >&2
                die "unknown argument: $1"
                ;;
        esac
        shift
    done

    [ "$(uname -s)" = "Darwin" ] || die "this installer only supports macOS"
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1024 ] && [ "$port" -le 65535 ] \
        || die "--port must be a number between 1024 and 65535"

    case "$command" in
        install) cmd_install "$link" "$port" ;;
        status) cmd_status "$port" ;;
        uninstall) cmd_uninstall ;;
    esac
}

main "$@"
