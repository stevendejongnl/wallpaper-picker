#!/bin/bash
#
# Wallpaper changer.
#   (no args)         fetch a new wallpaper from Wallhaven (random category
#                     from categories.conf), fall back to a random local one
#                     on any failure (offline, API down, empty result, etc.)
#   --gui             fetch candidates and show a GTK picker to choose/blacklist
#   --candidates N    fetch N candidates (skipping blacklisted ids), print one
#                     absolute path per line. They are not kept: --set moves the
#                     chosen one into ~/Pictures/wallpapers/online, the rest is deleted
#   --set FILE        apply FILE as the wallpaper (feh + notify + record it)
#   --blacklist FILE  blacklist FILE (by Wallhaven id, or by path if local)
#                     and delete it
#   --remove FILE     delete FILE without blacklisting it (may be fetched again)
#   --list            print every downloaded/local wallpaper, one path per line
#   --current         print the currently applied wallpaper's path
#   --gallery         show a GTK gallery of all wallpapers: set, remove, blacklist
#   --reapply         re-apply the last-set wallpaper, no fetch, no GUI
#   -s / --select     pick from your local wallpapers directory interactively
#   -l / --local      force a random local wallpaper, skip the online fetch
#
#   --interval VALUE  set the timer's auto-run interval (systemd time span,
#                     e.g. "1h", "90m", "6h") via a drop-in override; does
#                     not touch the tracked wallpaper.timer file
#   --mode periodic [VALUE]
#                     run the timer every VALUE (default: the 3h from
#                     wallpaper.timer when VALUE is omitted)
#   --mode events     run once after boot and after each display profile
#                     change, no repeat; needs --display-changed called from
#                     the profile switcher
#   --display-changed open the picker if the mode is "events", else do nothing
#   --timer-enable    turn automatic (timer-driven) runs on
#   --timer-disable   turn automatic runs off; manual invocation (this
#                     script, the alias, the .desktop launchers) still works
#   --timer-status    show whether the timer is enabled and its interval

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"

WALLPAPERS_DIR="$HOME/Pictures/wallpapers"
ONLINE_DIR="$WALLPAPERS_DIR/online"      # wallpapers you selected, kept for good
# Candidates are downloaded here and are not kept: only the one you select is moved
# into ONLINE_DIR. The folder is emptied on every new fetch and when the picker closes.
CANDIDATES_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/wallpaper/candidates"
LOG_FILE="$WALLPAPERS_DIR/log.txt"
CATEGORIES_FILE="$HOME/.config/wallpaper/categories.conf"
BLACKLIST_FILE="$HOME/.config/wallpaper/blacklist.txt"
CURRENT_FILE="$HOME/.config/wallpaper/current"
LOCK_FILE="$WALLPAPERS_DIR/.wallpaper.lock"
# Optional Immich source. A shell file with IMMICH_API_KEY (required) and optionally
# IMMICH_ALBUM_IDS (space separated), IMMICH_INTERNAL_URL, IMMICH_EXTERNAL_URL. Keep it chmod 600.
IMMICH_CONF="$HOME/.config/wallpaper/immich.conf"
TIMER_OVERRIDE_DIR="$HOME/.config/systemd/user/wallpaper.timer.d"
TIMER_OVERRIDE_FILE="$TIMER_OVERRIDE_DIR/override.conf"
LOG_KEEP_LINES=2000

mkdir -p "$WALLPAPERS_DIR" "$ONLINE_DIR" "$CANDIDATES_DIR" "$(dirname "$BLACKLIST_FILE")"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG_FILE"; }

trim_log() {
    [[ -f "$LOG_FILE" ]] || return 0
    local lines
    lines=$(wc -l < "$LOG_FILE")
    if (( lines > LOG_KEEP_LINES )); then
        tail -n "$LOG_KEEP_LINES" "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
    fi
}
trap trim_log EXIT

# Prevent overlapping top-level runs (e.g. OnFailure retry racing the
# original run). GUI callbacks (--set / --blacklist / --candidates invoked
# by wallpaper-gui.py while the parent --gui run is still alive) set
# WALLPAPER_SH_NOLOCK=1 so they don't deadlock against the lock their own
# parent process is holding.
#
# --display-changed only starts wallpaper.service, which then takes the lock
# itself, so it must not hold the lock while that service starts.
if [[ -z "${WALLPAPER_SH_NOLOCK:-}" && "${1:-}" != "--display-changed" ]]; then
    exec 9>"$LOCK_FILE"
    flock -n 9 || { log "already running, skip"; exit 0; }
fi

# --- blacklist helpers ------------------------------------------------------

# Key for a wallpaper file: the Wallhaven id for online downloads, kept or still a
# candidate (filename pattern "<query>-<id>.jpg"), otherwise the absolute path.
key_for_file() {
    local file="$1" base
    if [[ "$file" == "$ONLINE_DIR"/* || "$file" == "$CANDIDATES_DIR"/* ]]; then
        base=$(basename "$file")
        if [[ "$base" =~ -([A-Za-z0-9]+)\.jpg$ ]]; then
            echo "${BASH_REMATCH[1]}"
            return
        fi
    fi
    echo "$file"
}

is_blacklisted() {
    local key="$1" k
    [[ -f "$BLACKLIST_FILE" ]] || return 1
    while IFS= read -r k; do
        [[ "$k" == "$key" ]] && return 0
    done < <(grep -vE '^\s*(#|$)' "$BLACKLIST_FILE" | awk '{print $1}')
    return 1
}

blacklist_add() {
    local key="$1" label="${2:-}"
    is_blacklisted "$key" && return 0
    printf '%s    # %s %s\n' "$key" "$label" "$(date '+%Y-%m-%d')" >> "$BLACKLIST_FILE"
}

# Commit + push BLACKLIST_FILE's dotfiles repo so it doesn't stay dirty.
# Best-effort: offline or diverged repo should not break the wallpaper flow.
sync_blacklist() {
    command -v archsync >/dev/null || return 0
    archsync sync "wallpaper: blacklist update $(date '+%Y-%m-%d %H:%M')" >>"$LOG_FILE" 2>&1 || \
        log "archsync sync failed, blacklist left uncommitted"
}

# --- core actions ------------------------------------------------------------

clear_candidates() {
    find "$CANDIDATES_DIR" -maxdepth 1 -type f -delete 2>/dev/null
}

set_wallpaper() {
    local file="$1"
    # A selected candidate is the only download that is kept: move it into the library
    if [[ "$file" == "$CANDIDATES_DIR"/* ]]; then
        mv -f "$file" "$ONLINE_DIR/" && file="$ONLINE_DIR/$(basename "$file")"
    fi
    feh --bg-fill "$file"
    touch "$file"
    echo "$file" > "$CURRENT_FILE"
    timeout 3 notify-send -i monitor 'Wallpaper' "changed to $(basename "$file")" || log "notify-send timed out/failed, skipping"
    log "set: $file"
}

find_local_wallpapers() {
    local dir="$1" file
    shopt -s nullglob
    for file in "$dir"/*; do
        if [[ -d "$file" ]]; then
            find_local_wallpapers "$file"
        elif [[ -f "$file" && $file =~ \.(jpg|jpeg|png|gif)$ ]]; then
            wallpapers_list+=("$file")
        fi
    done
}

# Populates wallpapers_list with all local wallpapers that are not blacklisted.
find_local_wallpapers_filtered() {
    wallpapers_list=()
    find_local_wallpapers "$WALLPAPERS_DIR"
    local filtered=() f
    for f in "${wallpapers_list[@]}"; do
        is_blacklisted "$(key_for_file "$f")" || filtered+=("$f")
    done
    wallpapers_list=("${filtered[@]}")
}

pick_random_local() {
    find_local_wallpapers_filtered
    if [[ ${#wallpapers_list[@]} -eq 0 ]]; then
        log "no local wallpapers found in $WALLPAPERS_DIR"
        return 1
    fi
    echo "${wallpapers_list[$((RANDOM % ${#wallpapers_list[@]}))]}"
}

# Fetch one wallpaper for a given query, skipping any result whose Wallhaven
# id is blacklisted. Prints the absolute path on success.
fetch_online_for_query() {
    local query="$1"
    command -v curl >/dev/null 2>&1 || { log "curl not found, skipping online fetch"; return 1; }
    command -v jq   >/dev/null 2>&1 || { log "jq not found, skipping online fetch"; return 1; }

    log "fetching from Wallhaven, category: $query"
    local resp
    resp=$(curl -s --max-time 15 -G "https://wallhaven.cc/api/v1/search" \
        --data-urlencode "q=$query" \
        --data-urlencode "categories=111" \
        --data-urlencode "purity=100" \
        --data-urlencode "sorting=random")

    if [[ -z "$resp" ]]; then
        log "wallhaven: empty response"
        return 1
    fi

    local count
    count=$(echo "$resp" | jq '.data | length' 2>/dev/null)
    if [[ -z "$count" || "$count" -eq 0 ]]; then
        log "wallhaven: no results for '$query'"
        return 1
    fi

    local -a tried=()
    local attempts=0 max_attempts=$(( count < 10 ? count : 10 ))
    while (( attempts < max_attempts )); do
        local idx=$((RANDOM % count))
        if [[ " ${tried[*]:-} " == *" $idx "* ]]; then
            continue
        fi
        tried+=("$idx")
        ((attempts++))

        local url id
        url=$(echo "$resp" | jq -r ".data[$idx].path")
        id=$(echo "$resp" | jq -r ".data[$idx].id")
        [[ -z "$url" || "$url" == "null" ]] && continue

        if is_blacklisted "$id"; then
            log "wallhaven: skipping blacklisted id $id"
            continue
        fi

        # already selected before: reuse the kept file
        local kept="$ONLINE_DIR/${query}-${id}.jpg"
        if [[ -f "$kept" ]]; then
            echo "$kept"
            return 0
        fi
        local dest="$CANDIDATES_DIR/${query}-${id}.jpg"
        if [[ -f "$dest" ]]; then
            echo "$dest"
            return 0
        fi

        if ! curl -s --max-time 30 -o "$dest" "$url"; then
            log "wallhaven: download failed for $url"
            rm -f "$dest"
            continue
        fi
        if [[ ! -s "$dest" ]]; then
            log "wallhaven: downloaded file is empty"
            rm -f "$dest"
            continue
        fi

        echo "$dest"
        return 0
    done

    log "wallhaven: no non-blacklisted results for '$query'"
    return 1
}

# --- Immich source ------------------------------------------------------------

# Prints the Immich base URL: the internal one when it answers (at home, or on the
# home VPN), otherwise the external one. Probing needs no SSID or network state.
immich_base_url() {
    if curl -fs --max-time 2 -o /dev/null "$IMMICH_INTERNAL_URL/api/server/ping"; then
        echo "$IMMICH_INTERNAL_URL"
    else
        echo "$IMMICH_EXTERNAL_URL"
    fi
}

# Fetch one random landscape JPEG from Immich into CANDIDATES_DIR, skipping blacklisted
# ids. Prints the absolute path on success. Fails quietly when Immich is not configured.
fetch_immich() {
    [[ -f "$IMMICH_CONF" ]] || return 1
    local IMMICH_API_KEY="" IMMICH_ALBUM_IDS=""
    local IMMICH_INTERNAL_URL="http://192.168.1.69:2283"
    local IMMICH_EXTERNAL_URL="https://immich.madebysteven.nl"
    # shellcheck disable=SC1090
    source "$IMMICH_CONF"
    [[ -n "$IMMICH_API_KEY" ]] || { log "immich: no IMMICH_API_KEY in $IMMICH_CONF"; return 1; }
    command -v curl >/dev/null 2>&1 || return 1
    command -v jq   >/dev/null 2>&1 || return 1

    # One random album per request, so several albums act as one combined pool
    local -a albums=($IMMICH_ALBUM_IDS)
    local album=""
    (( ${#albums[@]} )) && album="${albums[$((RANDOM % ${#albums[@]}))]}"

    local base body resp
    base=$(immich_base_url)
    body=$(jq -n --arg album "$album" \
        '{size: 20, type: "IMAGE", withExif: true} + (if $album != "" then {albumIds: [$album]} else {} end)')
    log "fetching from Immich ($base)"
    resp=$(curl -fs --max-time 15 -X POST "$base/api/search/random" \
        -H "x-api-key: $IMMICH_API_KEY" -H "Content-Type: application/json" -d "$body") || {
        log "immich: search failed"
        return 1
    }

    local id key dest
    while IFS= read -r id; do
        key="${id//-/}"
        is_blacklisted "$key" && continue
        local kept="$ONLINE_DIR/immich-${key}.jpg"
        if [[ -f "$kept" ]]; then echo "$kept"; return 0; fi
        dest="$CANDIDATES_DIR/immich-${key}.jpg"
        # already a candidate in this batch: take another photo
        [[ -f "$dest" ]] && continue
        if curl -fs --max-time 60 -o "$dest" -H "x-api-key: $IMMICH_API_KEY" \
                "$base/api/assets/$id/original" && [[ -s "$dest" ]]; then
            echo "$dest"
            return 0
        fi
        rm -f "$dest"
    done < <(echo "$resp" | jq -r '
        .[]?
        | select(.originalMimeType == "image/jpeg")
        | select((.exifInfo.exifImageWidth // 0) > (.exifInfo.exifImageHeight // 0))
        | .id')

    log "immich: no usable landscape JPEG in the result"
    return 1
}

# One online wallpaper. WALLPAPER_SOURCE picks the source: "wallhaven" (default),
# "immich" (only Immich, needs immich.conf) or "mixed" (a random one of both).
fetch_one_online() {
    local source="${WALLPAPER_SOURCE:-wallhaven}" path
    if [[ "$source" == immich ]] || { [[ "$source" == mixed ]] && (( RANDOM % 2 == 0 )); }; then
        path=$(fetch_immich) && [[ -n "$path" ]] && { echo "$path"; return 0; }
        [[ "$source" == immich ]] && return 1
    fi
    local -a categories
    mapfile -t categories < <(grep -vE '^\s*(#|$)' "$CATEGORIES_FILE" 2>/dev/null)
    [[ ${#categories[@]} -gt 0 ]] || return 1
    fetch_online_for_query "${categories[$((RANDOM % ${#categories[@]}))]}"
}

fetch_online_wallpaper() {
    fetch_one_online
}

# Fetch N distinct candidate wallpapers, print one absolute path per line.
fetch_candidates() {
    local n="$1"
    command -v curl >/dev/null 2>&1 || { log "curl not found, skipping candidates fetch"; return 1; }
    command -v jq   >/dev/null 2>&1 || { log "jq not found, skipping candidates fetch"; return 1; }
    if [[ ! -f "$CATEGORIES_FILE" ]]; then
        log "no categories file at $CATEGORIES_FILE, skipping candidates fetch"
        return 1
    fi

    local categories
    mapfile -t categories < <(grep -vE '^\s*(#|$)' "$CATEGORIES_FILE")
    if [[ ${#categories[@]} -eq 0 ]]; then
        log "categories file is empty, skipping candidates fetch"
        return 1
    fi

    clear_candidates
    local -a results=()
    local tries=0 max_tries=$(( n * 4 > 12 ? n * 4 : 12 ))
    while (( ${#results[@]} < n && tries < max_tries )); do
        ((tries++))
        local path
        path=$(fetch_one_online) || continue
        [[ -n "$path" && " ${results[*]} " != *" $path "* ]] && results+=("$path")
    done

    if [[ ${#results[@]} -eq 0 ]]; then
        log "candidates: no results after $tries attempt(s)"
        return 1
    fi

    printf '%s\n' "${results[@]}"
}

select_local() {
    find_local_wallpapers_filtered
    if [[ ${#wallpapers_list[@]} -eq 0 ]]; then
        log "no local wallpapers found"
        exit 1
    fi
    echo "Select a wallpaper:"
    local i
    for (( i=0; i<${#wallpapers_list[@]}; i++ )); do
        echo "$((i+1)). ${wallpapers_list[i]}"
    done
    read -r -p "Enter the number of the wallpaper: " choice
    if [[ $choice -ge 1 && $choice -le ${#wallpapers_list[@]} ]]; then
        set_wallpaper "${wallpapers_list[choice-1]}"
    else
        log "invalid selection: $choice"
        exit 1
    fi
}

# --- new subcommands ---------------------------------------------------------

cmd_set() {
    local file="$1"
    if [[ -z "$file" || ! -f "$file" ]]; then
        log "--set: file not found: $file"
        exit 1
    fi
    set_wallpaper "$file"
}

cmd_blacklist() {
    local file="$1"
    if [[ -z "$file" ]]; then
        log "--blacklist: no file given"
        exit 1
    fi
    local key
    key=$(key_for_file "$file")
    blacklist_add "$key" "$(basename "$file")"
    rm -f "$file"
    log "blacklisted: $file (key=$key)"
    sync_blacklist
}

cmd_remove() {
    local file="$1"
    if [[ -z "$file" || ! -f "$file" ]]; then
        log "--remove: file not found: $file"
        exit 1
    fi
    rm -f "$file"
    log "removed: $file"
}

cmd_list() {
    wallpapers_list=()
    find_local_wallpapers "$WALLPAPERS_DIR"
    printf '%s\n' "${wallpapers_list[@]}"
}

cmd_current() {
    [[ -f "$CURRENT_FILE" ]] && cat "$CURRENT_FILE"
}

cmd_gallery() {
    if ! command -v python3 >/dev/null 2>&1; then
        log "python3 not found, cannot show gallery"
        exit 1
    fi
    WALLPAPER_SH_NOLOCK=1 python3 "$SCRIPT_DIR/wallpaper-gallery.py" "$SCRIPT_PATH"
}

cmd_reapply() {
    if [[ ! -f "$CURRENT_FILE" ]]; then
        log "--reapply: no current wallpaper recorded"
        exit 1
    fi
    local file
    file=$(<"$CURRENT_FILE")
    if [[ ! -f "$file" ]]; then
        log "--reapply: recorded wallpaper missing: $file"
        exit 1
    fi
    feh --bg-fill "$file"
    log "reapplied: $file"
}

# Fallback path shared by cmd_gui and the default no-args case.
fallback_fetch_or_local() {
    local chosen
    chosen=$(fetch_online_wallpaper)
    if [[ -n "$chosen" ]]; then
        set_wallpaper "$chosen"
    else
        log "online fetch failed, falling back to local"
        chosen=$(pick_random_local) && set_wallpaper "$chosen"
    fi
}

cmd_gui() {
    if ! command -v python3 >/dev/null 2>&1; then
        log "python3 not found, falling back to non-interactive pick"
        fallback_fetch_or_local
        return
    fi

    local rc
    WALLPAPER_SH_NOLOCK=1 python3 "$SCRIPT_DIR/wallpaper-gui.py" "$SCRIPT_PATH"
    rc=$?
    clear_candidates
    if [[ $rc -ne 0 ]]; then
        log "gui exited non-zero ($rc), falling back to non-interactive pick"
        fallback_fetch_or_local
    fi
}

# --- timer control -------------------------------------------------------------
# These manage wallpaper.timer only. wallpaper.service (and therefore --gui,
# manual runs, the alias, and the .desktop launchers) is untouched either way
# -- disabling the timer only stops the automatic every-N-hours run.

# Write the drop-in override. An empty interval leaves the timer without a
# repeat, so it fires once after boot only (events mode).
write_timer_override() {
    local interval="$1"
    mkdir -p "$TIMER_OVERRIDE_DIR"
    # Blank OnUnitActiveSec first: systemd drop-ins accumulate values for
    # list-type directives rather than replacing them. An empty assignment
    # also clears OnBootSec, and a timer left with no trigger is refused
    # ("Timer unit lacks value setting"), so the boot run is set again.
    printf '[Timer]\nOnUnitActiveSec=\nOnBootSec=30s\n' > "$TIMER_OVERRIDE_FILE"
    if [[ -n "$interval" ]]; then
        printf 'OnUnitActiveSec=%s\n' "$interval" >> "$TIMER_OVERRIDE_FILE"
    fi
    systemctl --user daemon-reload
}

# True when the override removes the repeat: runs happen after boot and after
# a display change only.
timer_runs_on_events() {
    [[ -f "$TIMER_OVERRIDE_FILE" ]] && ! grep -qP '^OnUnitActiveSec=.+' "$TIMER_OVERRIDE_FILE"
}

cmd_set_interval() {
    local value="$1"
    if [[ -z "$value" ]]; then
        echo "usage: wallpaper.sh --interval <systemd time span, e.g. 1h, 90m, 6h>" >&2
        exit 1
    fi
    write_timer_override "$value"
    log "timer interval set to $value"
    echo "interval set to $value"
}

cmd_set_periodic() {
    local value="$1"
    if [[ -n "$value" ]]; then
        cmd_set_interval "$value"
        return
    fi
    rm -f "$TIMER_OVERRIDE_FILE"
    systemctl --user daemon-reload
    log "timer mode set to periodic (default interval)"
    echo "mode: periodic, default interval from wallpaper.timer"
}

cmd_set_events() {
    write_timer_override ""
    log "timer mode set to events"
    echo "mode: events (once after boot, then after each display profile change)"
}

cmd_set_mode() {
    case "${1:-}" in
        periodic)
            cmd_set_periodic "${2:-}"
            ;;
        events)
            cmd_set_events
            ;;
        *)
            echo "usage: wallpaper.sh --mode periodic [span] | events" >&2
            exit 1
            ;;
    esac
}

# Called by the display profile switcher (e.g. autorandr) once the profile is
# chosen. Opens the picker in events mode, does nothing in periodic mode.
cmd_display_changed() {
    if ! timer_runs_on_events; then
        log "display changed: periodic mode, nothing to do"
        return
    fi
    # The switcher may run as a system service without a user session bus
    # address, so point systemctl at the user manager.
    export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
    systemctl --user start --no-block wallpaper.service
    log "display changed: picker started"
}

cmd_timer_enable() {
    systemctl --user enable --now wallpaper.timer
    log "timer enabled"
    echo "timer enabled: wallpaper runs automatically again"
}

cmd_timer_disable() {
    systemctl --user disable --now wallpaper.timer
    log "timer disabled"
    echo "timer disabled: wallpaper only changes when you run it manually"
}

cmd_timer_status() {
    local enabled interval mode
    enabled=$(systemctl --user is-enabled wallpaper.timer 2>/dev/null)
    [[ -z "$enabled" ]] && enabled="unknown"
    mode="periodic"
    interval="3h (default, from wallpaper.timer)"
    if timer_runs_on_events; then
        mode="events"
        interval="none (after boot and display changes only)"
    elif [[ -f "$TIMER_OVERRIDE_FILE" ]]; then
        interval="$(grep -oP '(?<=OnUnitActiveSec=).+' "$TIMER_OVERRIDE_FILE" | tail -1) (override)"
    fi
    echo "timer: $enabled"
    echo "mode: $mode"
    echo "interval: $interval"
    systemctl --user list-timers wallpaper.timer --no-pager 2>/dev/null
}

# --- dispatch -----------------------------------------------------------------

log "===== run ($*) ====="

case "${1:-}" in
    -s|--select)
        select_local
        ;;
    -l|--local)
        chosen=$(pick_random_local) && set_wallpaper "$chosen"
        ;;
    --candidates)
        fetch_candidates "${2:-3}"
        ;;
    --set)
        cmd_set "$2"
        ;;
    --blacklist)
        cmd_blacklist "$2"
        ;;
    --remove)
        cmd_remove "$2"
        ;;
    --list)
        cmd_list
        ;;
    --current)
        cmd_current
        ;;
    --gallery)
        cmd_gallery
        ;;
    --reapply)
        cmd_reapply
        ;;
    --gui)
        cmd_gui
        ;;
    --interval)
        cmd_set_interval "$2"
        ;;
    --mode)
        cmd_set_mode "${2:-}" "${3:-}"
        ;;
    --display-changed)
        cmd_display_changed
        ;;
    --timer-enable)
        cmd_timer_enable
        ;;
    --timer-disable)
        cmd_timer_disable
        ;;
    --timer-status)
        cmd_timer_status
        ;;
    *)
        fallback_fetch_or_local
        ;;
esac
