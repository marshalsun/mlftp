#!/bin/bash
#=============================================================
# install.sh - Install mlftp (64-bit only)
# Design by Marshall Suen
#-------------------------------------------------------------
# Usage:
#   ./install.sh              install mlftp + lftp
#   ./install.sh uninstall    remove mlftp
#
# lftp install rules:
#   - already installed      : show version, skip
#   - RHEL 5 / RHEL 7        : install from packages/ (x86_64)
#   - other systems          : try dnf / yum online install
#   - if all fail            : prompt user to install manually
#=============================================================

SRC_DIR=$(cd "$(dirname "$0")" && pwd)
SRC_MAIN="$SRC_DIR/shell/mlftp_install.sh"
PKG_DIR="$SRC_DIR/packages"

BIN_PATH="/usr/local/bin/mlftp"

err() { echo "ERROR: $*" >&2; }
msg() { echo "$*"; }

#-------------------------------------------------------------
# Must run as root
#-------------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
    err "Please run as root (use sudo)."
    exit 1
fi

#-------------------------------------------------------------
# Uninstall
#-------------------------------------------------------------
if [ "$1" = "uninstall" ]; then
    if [ -f "$BIN_PATH" ]; then
        rm -f "$BIN_PATH"
        msg "Removed: $BIN_PATH"
    else
        msg "Not installed: $BIN_PATH"
    fi
    exit 0
fi

#-------------------------------------------------------------
# 1. Check / install lftp
#-------------------------------------------------------------
msg "Checking lftp..."

if command -v lftp >/dev/null 2>&1; then
    ver=$(lftp --version 2>/dev/null | head -1)
    msg "lftp already installed: $ver"
else
    msg "lftp not found."

    os_family=""
    if [ -f /etc/redhat-release ]; then
        rel=$(cat /etc/redhat-release)
        case "$rel" in
            *"release 5"*) os_family="el5" ;;
            *"release 7"*) os_family="el7" ;;
        esac
    fi

    if [ "$os_family" = "el5" ] || [ "$os_family" = "el7" ]; then
        # ---- RHEL5 / RHEL7 : local rpm ----
        msg "System is $os_family, installing from local packages..."
        if [ ! -d "$PKG_DIR" ]; then
            err "Packages directory not found: $PKG_DIR"
            err "Please install lftp manually, or provide the rpm package."
            exit 1
        fi
        pkg=$(ls "$PKG_DIR"/lftp-*${os_family}*.x86_64.rpm 2>/dev/null | head -1)
        if [ -z "$pkg" ]; then
            err "No matching lftp package found for $os_family in $PKG_DIR"
            err "Please install lftp manually, or provide the rpm package."
            exit 1
        fi
        msg "Installing: $(basename "$pkg")"
        rpm -ivh "$pkg" || { err "rpm install failed"; exit 1; }
    else
        # ---- other systems : try network ----
        msg "System is not RHEL5 / RHEL7, trying online install..."

        if command -v dnf >/dev/null 2>&1; then
            msg "Using: dnf install -y lftp"
            dnf install -y lftp
        elif command -v yum >/dev/null 2>&1; then
            msg "Using: yum install -y lftp"
            yum install -y lftp
        else
            err "Neither dnf nor yum found."
            err "Please install lftp manually, or make sure network is available and re-run."
            exit 1
        fi
    fi

    # verify
    if command -v lftp >/dev/null 2>&1; then
        ver=$(lftp --version 2>/dev/null | head -1)
        msg "lftp installed: $ver"
    else
        err "lftp still not found after install."
        err "Please install lftp manually, or make sure network is available and re-run."
        exit 1
    fi
fi

#-------------------------------------------------------------
# 2. Install mlftp
#-------------------------------------------------------------
msg ""
msg "Installing mlftp..."

if [ ! -f "$SRC_MAIN" ]; then
    err "Source script not found: $SRC_MAIN"
    exit 1
fi

cp -f "$SRC_MAIN" "$BIN_PATH" || { err "Copy failed"; exit 1; }
chmod 755 "$BIN_PATH"
msg "Installed: $BIN_PATH"

#-------------------------------------------------------------
# 3. Done
#-------------------------------------------------------------
# refresh shell command hash (in case mlftp was cached before)
hash -r 2>/dev/null

msg ""
msg "mlftp installed successfully."
msg "  Run 'mlftp'                        to start"
msg "  Run 'mlftp --help'                 to see help"
msg "  Run 'sudo ./install.sh uninstall'  to uninstall"
msg ""
msg "If 'mlftp' not found, open a new terminal or run: hash -r"