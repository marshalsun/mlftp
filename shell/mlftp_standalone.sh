#!/bin/bash
#=============================================================
# mlftp_standalone.sh - Interactive lftp client (pure bash)
# Design by Marshall Suen
#-------------------------------------------------------------
# Supported systems and lftp packages:
#
#   OS          | package name
#   ------------|-------------------------------
#   RHEL 5      | lftp-3.7.11-8.el5
#   RHEL 7      | lftp-4.4.8-12.el7_8.1
#   CentOS 7    | lftp-4.4.8-12.el7_8.1
#   Rocky 8     | lftp-4.8.4-7.el8_10
#   Fedora 44   | lftp (latest from repo)
#
#   64-bit both supported.
#=============================================================

#=============================================================
# 1. CONFIG AREA
#=============================================================
CONF_DIR="$HOME/.mlftp"
CONF_FILE="$CONF_DIR/sites.conf"
TMP_DIR="$CONF_DIR/tmp"

PROTO=""
HOST=""
PORT=""
USER=""
PASS=""
CONNECTED=0

LOCAL_DIR="$PWD"
REMOTE_DIR="/"

LOCAL_FILES=()
REMOTE_FILES=()

LOCAL_PAGE=1
REMOTE_PAGE=1
PAGE_SIZE=10

WIDTH=80
HEIGHT=24
HALF=40
LAST_W=0
LAST_H=0

MSG=""
MSG_COLOR=""

LFTP_VER=""
LFTP_MAJOR=0
LFTP_OLD=0

OS_SHORT=""
UTF8_LOCALE=""

# === 日志功能区（配置） ===
LOG_FILE=""
LOG_COUNT=0
HAS_FAILURE=0
# ==========================

#=============================================================
# 2. UTILITY FUNCTIONS
#=============================================================
err()  { MSG="ERROR: $*"; MSG_COLOR="31"; }
info() { MSG="$*";       MSG_COLOR="32"; }

has_cmd() { command -v "$1" >/dev/null 2>&1; }

get_size() {
    local size
    size=$(stty size 2>/dev/null)
    if [ -n "$size" ]; then
        HEIGHT=${size% *}
        WIDTH=${size#* }
    else
        WIDTH=$(tput cols 2>/dev/null || echo 80)
        HEIGHT=$(tput lines 2>/dev/null || echo 24)
    fi
    HALF=$((WIDTH / 2))
    [ "$HALF" -lt 20 ] && HALF=20
    PAGE_SIZE=$((HEIGHT - 11))
    [ "$PAGE_SIZE" -lt 3 ] && PAGE_SIZE=3
}

hr() {
    local ch="${1:--}"
    local n="${2:-$WIDTH}"
    local i
    for ((i=0; i<n; i++)); do printf "%s" "$ch"; done
    printf "\n"
}

two_col() {
    printf "%-${HALF}s| %s\n" "$1" "$2"
}

lower() { echo "$1" | tr 'A-Z' 'a-z'; }

norm_path() {
    echo "$1" | sed 's|//*|/|g'
}

total_pages() {
    local count="$1"
    local p=$(( (count + PAGE_SIZE - 1) / PAGE_SIZE ))
    [ "$p" -lt 1 ] && p=1
    echo "$p"
}

clean_lftp_line() {
    local f="$1"
    [ -z "$f" ] && return 1
    case "$f" in
        "cd ok"*|"open "*|"Connected"*|"set "*) return 1 ;;
    esac
    if echo "$f" | grep -qiE "(no such|not found|permission denied|access denied|fatal|connection refused|^ls: |^cd: |^get: |^put: |^mv: |^rm: |^mkdir: )"; then
        return 1
    fi
    return 0
}

detect_os_short() {
    local rel
    if [ -f /etc/redhat-release ]; then
        rel=$(cat /etc/redhat-release)
        case "$rel" in
            *"release 5"*)
                if echo "$rel" | grep -qi centos; then echo "CentOS5"; else echo "RHEL5"; fi
                ;;
            *"release 6"*)
                if echo "$rel" | grep -qi centos; then echo "CentOS6"; else echo "RHEL6"; fi
                ;;
            *"release 7"*)
                if echo "$rel" | grep -qi centos; then echo "CentOS7"; else echo "RHEL7"; fi
                ;;
            *"release 8"*)
                if echo "$rel" | grep -qi rocky; then echo "Rocky8"
                elif echo "$rel" | grep -qi centos; then echo "CentOS8"
                else echo "RHEL8"; fi
                ;;
            *Fedora*)
                local n
                n=$(echo "$rel" | grep -oE 'release [0-9]+' | grep -oE '[0-9]+' | head -1)
                [ -z "$n" ] && n="?"
                echo "Fedora$n"
                ;;
            *) echo "Unknown" ;;
        esac
    else
        echo "Unknown"
    fi
}

detect_utf8_locale() {
    UTF8_LOCALE=""
    local cur="${LC_ALL:-${LC_CTYPE:-${LANG:-}}}"
    case "$cur" in
        *UTF-8*|*utf8*|*UTF8*|*utf-8*|*Utf-8*) return 0 ;;
    esac

    local loc
    loc=$(locale -a 2>/dev/null | grep -i 'utf' | grep -v '@' | head -1)
    if [ -z "$loc" ]; then
        loc=$(locale -a 2>/dev/null | grep -i 'utf' | head -1)
    fi
    if [ -n "$loc" ]; then
        UTF8_LOCALE="$loc"
        return 0
    fi
    return 1
}

# === 日志功能区（函数） ===
init_log() {
    local date_str=$(date '+%Y%m%d')
    LOG_COUNT=1
    while [ -f "$HOME/mlftp_failed_${date_str}_${LOG_COUNT}.log" ]; do
        LOG_COUNT=$((LOG_COUNT + 1))
    done
    LOG_FILE="$HOME/mlftp_failed_${date_str}_${LOG_COUNT}.log"
}

log_failure() {
    local action="$1"
    local source="$2"
    local reason="$3"
    local category="$4"

    HAS_FAILURE=1
    if [ -z "$LOG_FILE" ]; then
        init_log
    fi
    local now=$(date '+%Y-%m-%d %H:%M:%S')

    {
        echo "[$now] ${action} failed (${category})"
        echo "Source: $source"
        echo "Reason: $reason"
        echo "----------------------------------------"
    } >> "$LOG_FILE"

    printf "\033[31m"
    printf "FAILED: %s\n" "$source"
    printf "  Reason: %s\n" "$reason"
    printf "  Category: %s\n" "$category"
    printf "\033[0m"
}

show_log_hint() {
    if [ "$HAS_FAILURE" -eq 1 ] && [ -n "$LOG_FILE" ]; then
        printf "\n\033[33mLog saved to: %s\033[0m\n" "$LOG_FILE"
        sleep 3
    fi
}

analyze_lftp_error() {
    local out="$1"
    local src="$2"
    
    if echo "$src" | LC_ALL=C grep -q '[^ -~]'; then
        if echo "$out" | grep -qiE "(no such|not found|access failed|invalid)"; then
            echo "Encoding"
            return
        fi
    fi
    
    if echo "$out" | grep -qiE "(permission denied|access failed|no such directory)"; then
        echo "Permission/Path"
        return
    fi

    echo "Unknown"
}
# ==========================

#=============================================================
# 3. UI AREA
#=============================================================
draw_header() {
    hr "="
    local rdir="$REMOTE_DIR"
    [ "$CONNECTED" -ne 1 ] && rdir="(not connected)"
    two_col "Local: $LOCAL_DIR" "Remote: $rdir"
    hr "="
}

draw_lists() {
    local start_l=$(( (LOCAL_PAGE - 1) * PAGE_SIZE ))
    local start_r=$(( (REMOTE_PAGE - 1) * PAGE_SIZE ))
    local i

    for ((i=0; i<PAGE_SIZE; i++)); do
        local li=$((start_l + i))
        local ri=$((start_r + i))
        local ln=""
        local rn=""

        if [ -n "${LOCAL_FILES[$li]}" ]; then
            ln="L$((li+1)): ${LOCAL_FILES[$li]}"
        fi
        if [ "$CONNECTED" -eq 1 ] && [ -n "${REMOTE_FILES[$ri]}" ]; then
            rn="R$((ri+1)): ${REMOTE_FILES[$ri]}"
        fi
        two_col "$ln" "$rn"
    done

    hr "-"
    local lp
    local rp
    lp=$(total_pages "${#LOCAL_FILES[@]}")
    rp=$(total_pages "${#REMOTE_FILES[@]}")

    local ltotal=$(( ${#LOCAL_FILES[@]} - 1 ))
    local rtotal=$(( ${#REMOTE_FILES[@]} - 1 ))
    [ "$ltotal" -lt 0 ] && ltotal=0
    [ "$rtotal" -lt 0 ] && rtotal=0

    local lpage="Page $LOCAL_PAGE/$lp  total $ltotal  ln=next lp=prev"
    local rpage=""
    if [ "$CONNECTED" -eq 1 ]; then
        rpage="Page $REMOTE_PAGE/$rp  total $rtotal  rn=next rp=prev"
    fi
    two_col "$lpage" "$rpage"
}

draw_status() {
    local status="Not connected"
    [ "$CONNECTED" -eq 1 ] && status="Connected: $PROTO://$USER@$HOST:$PORT"
    printf "Status: %s %s  %s\n" "$status" "$OS_SHORT" "$LFTP_VER"
}

draw_msg() {
    if [ -n "$MSG" ]; then
        printf "\033[${MSG_COLOR}m%s\033[0m\n" "$MSG"
        MSG=""
    fi
}

refresh_screen() {
    get_size
    LAST_W=$WIDTH
    LAST_H=$HEIGHT
    clear
    draw_header
    draw_lists
    draw_status
    draw_msg
    printf "Choice or input (CMD: help lcd cd ls lls exit Enter): "
}

show_help() {
    clear
    cat <<'EOF'
================ mlftp help ================

NAVIGATION
  lcd DIR          - change LOCAL directory to DIR
  lcd ..           - go to parent LOCAL directory
  lcd              - prompt for local directory
  cd DIR           - change REMOTE directory to DIR
  cd ..            - go to parent REMOTE directory
  cd               - prompt for remote directory

  Note: cd = remote, lcd = local.

LISTING
  ls               - refresh remote file list
  lls              - refresh local file list
  (blank Enter)    - refresh both

PAGING
  ln               - local next page
  lp               - local previous page
  rn               - remote next page
  rp               - remote previous page

MARKING (for upload/download/rename/erase)
  L1               - mark local item #1
  L1,L2,L3         - mark local items #1,#2,#3
  R1               - mark remote item #1
  R1,R2            - mark remote items #1,#2
  Note: cannot mark both sides at once.
        Marking one side clears the other.

  After marking, an action menu appears:
    Local marked:  [U]pload  [R]ename  [E]rase (delete items)  [C]ancel
    Remote marked: [D]ownload [R]ename [E]rase (delete items)  [C]ancel

  Upload / Download will abort if any target name already
  exists on the other side (name conflict).

UPLOAD / DOWNLOAD
  - Works for both files and directories.
  - For files: uses put / get
  - For directories: uses mirror
  - You don't need to choose; script decides.

EXIT
  exit             - quit mlftp
  quit             - same as exit

-------------------------------------------------------------
        mlftp
   Design by Marshall Suen
-------------------------------------------------------------
Press Enter to return.
EOF
    read -r
}

#=============================================================
# 4. LOCAL OPERATIONS
#=============================================================
load_local() {
    LOCAL_FILES=()
    LOCAL_FILES+=("..")
    local f base
    local saved_nullglob
    saved_nullglob=$(shopt -p nullglob 2>/dev/null)
    shopt -s nullglob 2>/dev/null
    for f in "$LOCAL_DIR"/*; do
        [ -e "$f" ] || [ -L "$f" ] || continue
        base=$(basename "$f")
        [ -n "$base" ] && LOCAL_FILES+=("$base")
    done
    eval "$saved_nullglob" 2>/dev/null
    LOCAL_PAGE=1
}

local_cd() {
    local target="$1"
    if [ -z "$target" ]; then
        read -r -p "lcd to where? " target
        [ -z "$target" ] && return
    fi

    local newdir
    if [ "$target" = ".." ]; then
        newdir=$(dirname "$LOCAL_DIR")
    elif [ "${target:0:1}" = "/" ]; then
        newdir="$target"
    else
        newdir="$LOCAL_DIR/$target"
    fi
    newdir=$(norm_path "$newdir")

    if [ -d "$newdir" ]; then
        LOCAL_DIR="$newdir"
        load_local
        info "Local: $LOCAL_DIR"
        return
    fi

    if [ "$target" != ".." ] && [ "${target:0:1}" != "/" ]; then
        local entry base lname
        lname=$(echo "$target" | tr 'A-Z' 'a-z')
        for entry in "$LOCAL_DIR"/*; do
            [ -d "$entry" ] || continue
            base=$(basename "$entry")
            if [ "$(echo "$base" | tr 'A-Z' 'a-z')" = "$lname" ]; then
                LOCAL_DIR="$entry"
                load_local
                info "Local: $LOCAL_DIR"
                return
            fi
        done
    fi

    err "Not a directory: $target"
}

#=============================================================
# 5. REMOTE OPERATIONS
#=============================================================

#-------------------------------------------------------------
# 5a. LFTP basic wrappers
#-------------------------------------------------------------
build_lftp_script() {
    local cmdfile="$1"
    shift
    {
        echo "set net:timeout 10;"
        echo "set net:max-retries 2;"
        if [ "$PROTO" = "sftp" ]; then
            if [ "$OS_SHORT" = "Fedora44" ]; then
                echo "set sftp:connect-program \"ssh -a -x -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o GSSAPIAuthentication=no -o PreferredAuthentications=password,keyboard-interactive -o ConnectTimeout=10\";"
            else
                echo "set sftp:connect-program \"ssh -a -x -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null\";"
            fi
            echo "open sftp://$USER:$PASS@$HOST:$PORT;"
        else
            echo "open ftp://$USER:$PASS@$HOST:$PORT;"
        fi
        printf "%s\n" "$@"
        echo "bye"
    } > "$cmdfile"
    chmod 600 "$cmdfile"
}

lftp_run() {
    local tmpf="$TMP_DIR/lftp.cmd"
    mkdir -p "$TMP_DIR"; chmod 700 "$TMP_DIR"
    build_lftp_script "$tmpf" "$@"
    local out
    if [ -n "$UTF8_LOCALE" ]; then
        out=$(LANG="$UTF8_LOCALE" LC_ALL="$UTF8_LOCALE" lftp -f "$tmpf" 2>&1)
    else
        out=$(lftp -f "$tmpf" 2>&1)
    fi
    local rc=$?
    rm -f "$tmpf"
    echo "$out"
    return $rc
}

lftp_transfer() {
    local label="$1"; shift
    local tmpf="$TMP_DIR/lftp.cmd"
    mkdir -p "$TMP_DIR"; chmod 700 "$TMP_DIR"
    build_lftp_script "$tmpf" "$@"

    echo "=== $label ==="
    if [ -n "$UTF8_LOCALE" ]; then
        LANG="$UTF8_LOCALE" LC_ALL="$UTF8_LOCALE" lftp -f "$tmpf"
    else
        lftp -f "$tmpf"
    fi
    local rc=$?
    rm -f "$tmpf"
    echo "=== done ==="
    return $rc
}

#-------------------------------------------------------------
# 5b. LFTP version detection
#-------------------------------------------------------------
detect_lftp_version() {
    LFTP_VER=$(lftp --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    [ -z "$LFTP_VER" ] && LFTP_VER="0.0.0"
    LFTP_MAJOR=${LFTP_VER%%.*}
    if [ "$LFTP_MAJOR" -lt 4 ]; then
        LFTP_OLD=1
    else
        LFTP_OLD=0
    fi
}

#-------------------------------------------------------------
# 5c. Remote path resolution
#-------------------------------------------------------------
resolve_remote_entry() {
    local dir="$1"
    local parent name
    parent=$(dirname "$dir")
    name=$(basename "$dir")
    [ -z "$parent" ] && parent="/"

    local out line
    out=$(lftp_run "cd \"$parent\"; cls -1;")
    while IFS= read -r line; do
        clean_lftp_line "$line" || continue
        line="${line#/}"

        local isdir=0
        case "$line" in
            */) isdir=1; line="${line%/}" ;;
        esac

        [ -z "$line" ] && continue

        if [ "$(echo "$line" | tr 'A-Z' 'a-z')" = "$(echo "$name" | tr 'A-Z' 'a-z')" ]; then
            local full
            if [ "$parent" = "/" ]; then
                full="/$line"
            else
                full="$parent/$line"
            fi
            if [ "$isdir" -eq 1 ]; then
                echo "$full|d"
            else
                echo "$full|f"
            fi
            return 0
        fi
    done <<< "$out"
    return 1
}

#-------------------------------------------------------------
# 5c-fedora. Fedora44 remote listing
#-------------------------------------------------------------
load_remote_fedora() {
    REMOTE_FILES=()
    [ "$CONNECTED" -ne 1 ] && return
    REMOTE_FILES+=("..")
    local out line
    out=$(lftp_run "cd \"$REMOTE_DIR\"; ls;")
    while IFS= read -r line; do
        clean_lftp_line "$line" || continue
        case "$line" in
            "total "*) continue ;;
        esac
        case "${line:0:1}" in
            d)
                line=$(echo "$line" | awk '{print $NF}')/
                ;;
            -|l)
                line=$(echo "$line" | awk '{print $NF}')
                ;;
            *)
                continue
                ;;
        esac
        line="${line#/}"
        line="${line%/}"
        clean_lftp_line "$line" || continue
        REMOTE_FILES+=("$line")
    done <<< "$out"
    REMOTE_PAGE=1
}

#-------------------------------------------------------------
# 5d. High-level remote operations
#-------------------------------------------------------------
load_remote() {
    if [ "$OS_SHORT" = "Fedora44" ]; then
        load_remote_fedora
        return
    fi

    REMOTE_FILES=()
    [ "$CONNECTED" -ne 1 ] && return
    REMOTE_FILES+=("..")
    local out
    out=$(lftp_run "cd \"$REMOTE_DIR\"; cls -1;")
    local f
    while IFS= read -r f; do
        clean_lftp_line "$f" || continue
        f="${f#/}"
        f="${f%/}"
        clean_lftp_line "$f" || continue
        REMOTE_FILES+=("$f")
    done <<< "$out"
    REMOTE_PAGE=1
}

remote_cd() {
    [ "$CONNECTED" -ne 1 ] && { err "Not connected"; return; }
    local target="$1"
    if [ -z "$target" ]; then
        read -r -p "cd to where? " target
        [ -z "$target" ] && return
    fi

    local newdir
    if [ "$target" = ".." ]; then
        [ "$REMOTE_DIR" = "/" ] && { info "Already at root"; return; }
        newdir=$(dirname "$REMOTE_DIR")
        [ -z "$newdir" ] && newdir="/"
    elif [ "${target:0:1}" = "/" ]; then
        newdir="$target"
    else
        newdir="$REMOTE_DIR/$target"
    fi
    newdir=$(norm_path "$newdir")

    if [ "$newdir" = "/" ]; then
        REMOTE_DIR="/"
        load_remote
        info "Remote: /"
        return
    fi

    if [ "$OS_SHORT" = "Fedora44" ]; then
        REMOTE_DIR="$newdir"
        load_remote
        info "Remote: $REMOTE_DIR"
        return
    fi

    local result
    result=$(resolve_remote_entry "$newdir")
    if [ -z "$result" ]; then
        err "Remote dir not found: $newdir"
        return
    fi
    local realpath="${result%|*}"
    local realtype="${result#*|}"
    if [ "$realtype" != "d" ]; then
        err "Not a directory: $newdir"
        return
    fi

    REMOTE_DIR="$realpath"
    load_remote
    info "Remote: $REMOTE_DIR"
}

#=============================================================
# 6. ACTION / TRANSFER AREA
#=============================================================
parse_sel_list() {
    echo "$1" | tr ',' ' ' | tr -d 'lLrR'
}

upload_one() {
    local f="$1"
    local full_local="$LOCAL_DIR/$f"
    local out
    if [ -d "$full_local" ]; then
        out=$(lftp_transfer "Upload $f" "mirror -R --verbose \"$full_local\" \"$REMOTE_DIR/$f\";")
    else
        out=$(lftp_transfer "Upload $f" "put \"$full_local\" -o \"$REMOTE_DIR/$f\" --continue;")
    fi
    
    if echo "$out" | grep -qiE "(no such|not found|permission denied|access denied|fatal|access failed)"; then
        local reason=$(echo "$out" | grep -iE "(no such|not found|permission denied|access denied|fatal|access failed)" | head -1)
        local cat=$(analyze_lftp_error "$out" "$f")
        log_failure "Upload" "$full_local" "$reason" "$cat"
    fi
}

download_one() {
    local f="$1"
    local full="$REMOTE_DIR/$f"
    local result
    result=$(resolve_remote_entry "$full")
    local out
    if [ -n "$result" ]; then
        local realtype="${result#*|}"
        if [ "$realtype" = "d" ]; then
            out=$(lftp_transfer "Download $f" "mirror --verbose \"$full\" \"$LOCAL_DIR/$f\";")
        else
            out=$(lftp_transfer "Download $f" "get \"$full\" -o \"$LOCAL_DIR/$f\" --continue;")
        fi
    else
        out=$(lftp_transfer "Download $f" "get \"$full\" -o \"$LOCAL_DIR/$f\" --continue;")
    fi
    
    if echo "$out" | grep -qiE "(no such|not found|permission denied|access denied|fatal|access failed)"; then
        local reason=$(echo "$out" | grep -iE "(no such|not found|permission denied|access denied|fatal|access failed)" | head -1)
        local cat=$(analyze_lftp_error "$out" "$f")
        log_failure "Download" "$full" "$reason" "$cat"
    fi
}

check_upload_conflicts() {
    local list="$1"
    local conflicts=""
    local idx f
    for idx in $list; do
        case "$idx" in ''|*[!0-9]*) continue ;; esac
        f="${LOCAL_FILES[$((idx-1))]}"
        [ -z "$f" ] && continue
        [ "$f" = ".." ] && continue
        local res
        res=$(resolve_remote_entry "$REMOTE_DIR/$f")
        if [ -n "$res" ]; then
            conflicts="${conflicts}  L${idx}: ${f}"$'\n'
        fi
    done
    if [ -n "$conflicts" ]; then
        MSG="ERROR: name conflict, nothing transferred."$'\n'"${conflicts%$'\n'}"
        MSG_COLOR="31"
        return 1
    fi
    return 0
}

check_download_conflicts() {
    local list="$1"
    local conflicts=""
    local idx f
    for idx in $list; do
        case "$idx" in ''|*[!0-9]*) continue ;; esac
        f="${REMOTE_FILES[$((idx-1))]}"
        [ -z "$f" ] && continue
        [ "$f" = ".." ] && continue
        if [ -e "$LOCAL_DIR/$f" ]; then
            conflicts="${conflicts}  R${idx}: ${f}"$'\n'
        fi
    done
    if [ -n "$conflicts" ]; then
        MSG="ERROR: name conflict, nothing transferred."$'\n'"${conflicts%$'\n'}"
        MSG_COLOR="31"
        return 1
    fi
    return 0
}

do_upload_list() {
    local list="$1"
    [ "$CONNECTED" -ne 1 ] && { err "Not connected"; return; }
    if ! check_upload_conflicts "$list"; then
        return
    fi
    local idx f ok=0
    for idx in $list; do
        case "$idx" in ''|*[!0-9]*) continue ;; esac
        f="${LOCAL_FILES[$((idx-1))]}"
        [ -z "$f" ] && continue
        [ "$f" = ".." ] && continue
        info "Uploading $f ..."; refresh_screen
        upload_one "$f"
        ok=$((ok+1))
    done
    info "Uploaded $ok item(s)"
}

do_download_list() {
    local list="$1"
    [ "$CONNECTED" -ne 1 ] && { err "Not connected"; return; }
    if ! check_download_conflicts "$list"; then
        return
    fi
    local idx f ok=0
    for idx in $list; do
        case "$idx" in ''|*[!0-9]*) continue ;; esac
        f="${REMOTE_FILES[$((idx-1))]}"
        [ -z "$f" ] && continue
        [ "$f" = ".." ] && continue
        info "Downloading $f ..."; refresh_screen
        download_one "$f"
        ok=$((ok+1))
    done
    info "Downloaded $ok item(s)"
}

do_rename_list() {
    local side="$1"
    local list="$2"
    local newname
    read -r -p "New name: " newname
    [ -z "$newname" ] && { err "Empty name"; return; }
    local idx f
    if [ "$side" = "l" ]; then
        for idx in $list; do
            case "$idx" in ''|*[!0-9]*) continue ;; esac
            f="${LOCAL_FILES[$((idx-1))]}"
            [ -z "$f" ] && continue
            [ "$f" = ".." ] && continue
            mv "$LOCAL_DIR/$f" "$LOCAL_DIR/$newname"
            info "Renamed local: $f -> $newname"
        done
        load_local
    else
        for idx in $list; do
            case "$idx" in ''|*[!0-9]*) continue ;; esac
            f="${REMOTE_FILES[$((idx-1))]}"
            [ -z "$f" ] && continue
            [ "$f" = ".." ] && continue
            lftp_run "mv \"$REMOTE_DIR/$f\" \"$REMOTE_DIR/$newname\";"
            info "Renamed remote: $f -> $newname"
        done
        load_remote
    fi
}

do_delete_list() {
    local side="$1"
    local list="$2"
    local idx f ans
    if [ "$side" = "l" ]; then
        for idx in $list; do
            case "$idx" in ''|*[!0-9]*) continue ;; esac
            f="${LOCAL_FILES[$((idx-1))]}"
            [ -z "$f" ] && continue
            [ "$f" = ".." ] && continue
            read -r -p "Erase local '$f'? (y/n): " ans
            ans=$(lower "$ans")
            [ "$ans" != "y" ] && continue
            rm -rf "$LOCAL_DIR/$f"
            info "Erased local: $f"
        done
        load_local
    else
        for idx in $list; do
            case "$idx" in ''|*[!0-9]*) continue ;; esac
            f="${REMOTE_FILES[$((idx-1))]}"
            [ -z "$f" ] && continue
            [ "$f" = ".." ] && continue
            read -r -p "Erase remote '$f'? (y/n): " ans
            ans=$(lower "$ans")
            [ "$ans" != "y" ] && continue
            lftp_run "rm -rf \"$REMOTE_DIR/$f\";"
            info "Erased remote: $f"
        done
        load_remote
    fi
}

action_menu_local() {
    local display=""
    local x
    for x in "${LOCAL_SEL[@]}"; do display="${display}L${x},"; done
    display="${display%,}"
    local list="${LOCAL_SEL[*]}"
    echo "Marked local: $display"
    echo "  [U] upload"
    echo "  [R] rename"
    echo "  [E] erase (delete items)"
    echo "  [C] cancel"
    local op
    read -r -p "Choice: " op
    op=$(lower "$op")
    case "$op" in
        u) do_upload_list "$list" ;;
        r) do_rename_list "l" "$list" ;;
        e) do_delete_list "l" "$list" ;;
        c) info "Cancelled" ;;
        *) err "Invalid" ;;
    esac
    LOCAL_SEL=()
}

action_menu_remote() {
    local display=""
    local x
    for x in "${REMOTE_SEL[@]}"; do display="${display}R${x},"; done
    display="${display%,}"
    local list="${REMOTE_SEL[*]}"
    echo "Marked remote: $display"
    echo "  [D] download"
    echo "  [R] rename"
    echo "  [E] erase (delete items)"
    echo "  [C] cancel"
    local op
    read -r -p "Choice: " op
    op=$(lower "$op")
    case "$op" in
        d) do_download_list "$list" ;;
        r) do_rename_list "r" "$list" ;;
        e) do_delete_list "r" "$list" ;;
        c) info "Cancelled" ;;
        *) err "Invalid" ;;
    esac
    REMOTE_SEL=()
}

#=============================================================
# 7. SITE MANAGEMENT
#=============================================================
ensure_conf() {
    mkdir -p "$CONF_DIR"; chmod 700 "$CONF_DIR"
    [ -f "$CONF_FILE" ] || : > "$CONF_FILE"
    chmod 600 "$CONF_FILE"
}

save_site_named() {
    local name="$1"
    {
        echo "[$name]"
        echo "protocol=$PROTO"
        echo "host=$HOST"
        echo "port=$PORT"
        echo "user=$USER"
        echo "password=$PASS"
        echo ""
    } >> "$CONF_FILE"
}

save_site() {
    local name
    read -r -p "Site name to save: " name
    [ -z "$name" ] && return
    delete_site_by_name "$name" quiet
    save_site_named "$name"
    info "Saved site: $name"
}

list_site_names() {
    grep '^\[' "$CONF_FILE" 2>/dev/null | tr -d '[]'
}

delete_site_by_name() {
    local target="$1"
    local quiet="$2"
    local tmpf="$TMP_DIR/sites.tmp"
    mkdir -p "$TMP_DIR"
    local in_site=0 line
    : > "$tmpf"
    while IFS= read -r line; do
        case "$line" in
            "[$target]") in_site=1; continue ;;
            \[*\]) [ "$in_site" -eq 1 ] && in_site=0 ;;
        esac
        [ "$in_site" -eq 1 ] && continue
        echo "$line" >> "$tmpf"
    done < "$CONF_FILE"
    mv "$tmpf" "$CONF_FILE"
    chmod 600 "$CONF_FILE"
    [ "$quiet" = "quiet" ] || info "Deleted site: $target"
}

load_site_by_name() {
    local target="$1"
    local in_site=0 line
    PROTO=""; HOST=""; PORT=""; USER=""; PASS=""
    while IFS= read -r line; do
        case "$line" in
            "[$target]") in_site=1; continue ;;
            \[*\]) [ "$in_site" -eq 1 ] && break ;;
        esac
        [ "$in_site" -eq 1 ] || continue
        case "$line" in
            protocol=*) PROTO="${line#protocol=}" ;;
            host=*)     HOST="${line#host=}" ;;
            port=*)     PORT="${line#port=}" ;;
            user=*)     USER="${line#user=}" ;;
            password=*) PASS="${line#password=}" ;;
        esac
    done < "$CONF_FILE"

    if [ -n "$HOST" ] && [ -n "$USER" ]; then
        CONNECTED=1
        load_remote
        info "Connected to $HOST"
    else
        err "Failed to load site: $target"
    fi
}

choose_saved_site() {
    ensure_conf
    local names
    names=$(list_site_names)
    if [ -z "$names" ]; then
        echo "No saved sites."
        sleep 1
        return 1
    fi
    echo "Saved sites:"
    local i=1 name
    while IFS= read -r name; do
        echo "  $i) $name"; i=$((i+1))
    done <<< "$names"
    echo "  0) back"
    local n
    read -r -p "Choose: " n
    [ "$n" = "0" ] && return 1
    local chosen
    chosen=$(echo "$names" | sed -n "${n}p")
    [ -z "$chosen" ] && { echo "Invalid"; sleep 1; return 1; }
    load_site_by_name "$chosen"
    return 0
}

delete_saved_site() {
    ensure_conf
    local names
    names=$(list_site_names)
    if [ -z "$names" ]; then
        echo "No saved sites."
        sleep 1
        return
    fi
    echo "Saved sites:"
    local i=1 name
    while IFS= read -r name; do
        echo "  $i) $name"; i=$((i+1))
    done <<< "$names"
    echo "  0) back"
    local n
    read -r -p "Delete which number (0=back): " n
    [ "$n" = "0" ] && return
    local chosen
    chosen=$(echo "$names" | sed -n "${n}p")
    [ -z "$chosen" ] && { echo "Invalid"; sleep 1; return; }
    read -r -p "Delete site '$chosen'? (y/n): " ans
    ans=$(lower "$ans")
    if [ "$ans" = "y" ]; then
        delete_site_by_name "$chosen"
        sleep 1
    else
        echo "Cancelled."
        sleep 1
    fi
}

connect_new() {
    read -r -p "Protocol (ftp/sftp) [ftp]: " PROTO
    PROTO=$(lower "$PROTO")
    [ -z "$PROTO" ] && PROTO="ftp"
    read -r -p "Host: " HOST
    [ -z "$HOST" ] && { err "Host required"; return 1; }
    local defport=21
    [ "$PROTO" = "sftp" ] && defport=22
    read -r -p "Port [$defport]: " PORT
    [ -z "$PORT" ] && PORT="$defport"
    read -r -p "User: " USER
    [ -z "$USER" ] && { err "User required"; return 1; }
    read -r -s -p "Password: " PASS; echo

    CONNECTED=1
    load_remote
    if [ "$CONNECTED" -eq 1 ]; then
        local ans
        read -r -p "Save this site? (y/n): " ans
        ans=$(lower "$ans")
        [ "$ans" = "y" ] && save_site
    fi
    return 0
}

#=============================================================
# MAIN
#=============================================================
startup_menu() {
    local mode_str
    if [ "$LFTP_OLD" -eq 1 ]; then
        mode_str="old mode"
    else
        mode_str="new mode"
    fi
    clear
    while true; do
        echo "===================================="
        echo "              mlftp"
        echo "   $OS_SHORT | $LFTP_VER ($mode_str)"
        echo "===================================="
        echo "  1) connect new"
        echo "  2) choose saved site"
        echo "  3) delete saved site"
        echo "  4) quit"
        read -r -p "Choice: " c
        case "$c" in
            1) connect_new && return 0 ;;
            2) choose_saved_site && return 0 ;;
            3) delete_saved_site ;;
            4) echo "Bye."; exit 0 ;;
            *) echo "Invalid"; clear ;;
        esac
    done
}

main() {
    ensure_conf
    mkdir -p "$TMP_DIR"; chmod 700 "$TMP_DIR"

    if ! has_cmd lftp; then
        echo "ERROR: lftp not found. Please install lftp first."; exit 1
    fi

    detect_lftp_version
    OS_SHORT=$(detect_os_short)
    detect_utf8_locale

    if [ -f /etc/redhat-release ]; then
        rel=$(cat /etc/redhat-release)
        case "$rel" in
            *"release 5"*|*"release 7"*|*"release 8"*|*Fedora*) ;;
            *) echo "Warning: $rel may not be fully supported." ; sleep 1 ;;
        esac
    fi

    LOCAL_DIR=$(norm_path "$LOCAL_DIR")

    load_local
    startup_menu
    refresh_screen
    trap 'refresh_screen' SIGWINCH

    while true; do
        get_size
        if [ "$WIDTH" != "$LAST_W" ] || [ "$HEIGHT" != "$LAST_H" ]; then
            refresh_screen
        fi

        read -r input
        local linput
        linput=$(lower "$input")

        if [ -z "$linput" ]; then
            load_local
            [ "$CONNECTED" -eq 1 ] && load_remote
            refresh_screen
            continue
        fi

        if [[ "$linput" =~ ^l[0-9] ]]; then
            LOCAL_SEL=()
            REMOTE_SEL=()
            local x
            for x in $(parse_sel_list "$linput"); do
                case "$x" in ''|*[!0-9]*) continue ;; esac
                [ -n "${LOCAL_FILES[$((x-1))]}" ] && LOCAL_SEL+=("$x")
            done
            if [ "${#LOCAL_SEL[@]}" -eq 0 ]; then
                err "No valid local marks"; refresh_screen; continue
            fi
            action_menu_local
            refresh_screen
            continue
        fi

        if [[ "$linput" =~ ^r[0-9] ]]; then
            LOCAL_SEL=()
            REMOTE_SEL=()
            local x
            for x in $(parse_sel_list "$linput"); do
                case "$x" in ''|*[!0-9]*) continue ;; esac
                [ -n "${REMOTE_FILES[$((x-1))]}" ] && REMOTE_SEL+=("$x")
            done
            if [ "${#REMOTE_SEL[@]}" -eq 0 ]; then
                err "No valid remote marks"; refresh_screen; continue
            fi
            action_menu_remote
            refresh_screen
            continue
        fi

        case "$linput" in
            ls)
                [ "$CONNECTED" -eq 1 ] && load_remote
                refresh_screen ;;
            lls)
                load_local
                refresh_screen ;;
            ln)
                local tp
                tp=$(total_pages "${#LOCAL_FILES[@]}")
                [ "$LOCAL_PAGE" -lt "$tp" ] && LOCAL_PAGE=$((LOCAL_PAGE+1))
                refresh_screen ;;
            lp)
                [ "$LOCAL_PAGE" -gt 1 ] && LOCAL_PAGE=$((LOCAL_PAGE-1))
                refresh_screen ;;
            rn)
                local tp
                tp=$(total_pages "${#REMOTE_FILES[@]}")
                [ "$REMOTE_PAGE" -lt "$tp" ] && REMOTE_PAGE=$((REMOTE_PAGE+1))
                refresh_screen ;;
            rp)
                [ "$REMOTE_PAGE" -gt 1 ] && REMOTE_PAGE=$((REMOTE_PAGE-1))
                refresh_screen ;;
            cd)
                remote_cd ""
                refresh_screen ;;
            cd\ *)
                remote_cd "${input:3}"
                refresh_screen ;;
            lcd)
                local_cd ""
                refresh_screen ;;
            lcd\ *)
                local_cd "${input:4}"
                refresh_screen ;;
            help)
                show_help
                refresh_screen ;;
            exit|quit)
                show_log_hint
                echo "Bye."
                exit 0 ;;
            *)
                err "Unknown: $input"
                refresh_screen ;;
        esac
    done
}

main "$@"