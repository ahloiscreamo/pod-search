#!/bin/bash
# Configuration
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/pod-search"
CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/pod-search/config"
CACHE_TTL=86400        # 24h - genre chart data doesn't need to be re-fetched constantly
CATEGORIES_TTL=2592000 # 30d - category list almost never changes
mkdir -p "$CACHE_DIR"

copy_to_clipboard() {
    if [[ "$XDG_SESSION_TYPE" == "wayland" ]]; then
        wl-copy
    else
        xclip -selection clipboard
    fi
}

# Plain (non-fzf) confirmation screen so the "Copied:" line actually stays
# visible - fzf takes over the whole screen on its next call and would
# otherwise wipe it out before it's readable.
show_copied_and_wait() {
    local url="$1"
    echo
    echo "Copied: $url"
    read -p "[Enter] Menu   [q] Quit: " next
    [[ "$next" == "q" || "$next" == "Q" ]] && exit 0
}

# Pad/truncate a raw tab-separated "name\tartist\tkey" stream into a
# display-friendly "paddedname  paddedartist\tkey" stream for fzf.
format_for_fzf() {
    awk -F'\t' -v nw=42 -v aw=28 -v gap=4 '
    {
        name = $1; artist = $2; key = $3
        if (length(name) > nw)   name = substr(name, 1, nw - 1) "…"
        else                     name = sprintf("%-*s", nw, name)
        if (length(artist) > aw) artist = substr(artist, 1, aw - 1) "…"
        else                     artist = sprintf("%-*s", aw, artist)
        printf "%s%*s%s\t%s\n", name, gap, "", artist, key
    }'
}

# Pad/truncate a raw tab-separated "name\tkey" stream (2 fields only - for
# pickers like the genre list that don't have a separate artist column).
format_single_for_fzf() {
    awk -F'\t' -v nw=50 '
    {
        name = $1; key = $2
        if (length(name) > nw) name = substr(name, 1, nw - 1) "…"
        else                   name = sprintf("%-*s", nw, name)
        printf "%s\t%s\n", name, key
    }'
}

# For the genre-browse podcast list: name-only display (author is already visible
# in the preview pane, so no need to compete for width with a truncated author column).
# Input: "name\tauthor\tkey\tpreview" (author field is ignored here).
format_name_preview_for_fzf() {
    awk -F'\t' -v nw=48 '
    {
        name = $1; key = $3; preview = $4
        if (length(name) > nw) name = substr(name, 1, nw - 1) "…"
        else                   name = sprintf("%-*s", nw, name)
        printf "%s\t%s\t%s\n", name, key, preview
    }'
}

search_and_select() {
    read -p "Enter podcast name: " search_term
    [ -z "$search_term" ] && return 1

    encoded_term=$(jq -srR '@uri' <<< "$search_term")

    raw=$(curl -s "https://itunes.apple.com/search?term=${encoded_term}&media=podcast&entity=podcast&limit=25" | \
        jq -r '.results[] | select(.feedUrl != null) | "\(.collectionName)\t\(.artistName)\t\(.feedUrl)"')

    if [ -z "$raw" ]; then
        echo "No results found."
        return 1
    fi

    results=$(echo "$raw" | format_for_fzf)
    selected=$(echo "$results" | fzf --delimiter=$'\t' --with-nth=1 --prompt="Select Podcast: " --bind 'esc:abort')
    url=$(echo "$selected" | awk -F'\t' '{print $2}')

    [ -z "$url" ] && { echo "No selection made."; return 1; }

    printf '%s' "$url" | copy_to_clipboard
    show_copied_and_wait "$url"
    return 0
}

# --- Podcast Index auth ---
# authHeader = sha1(apiKey + apiSecret + unixTime), per official API spec
pi_request() {
    local endpoint="$1"
    local ts hash
    ts=$(date +%s)
    hash=$(printf '%s' "${PODCASTINDEX_API_KEY}${PODCASTINDEX_API_SECRET}${ts}" | sha1sum | cut -d' ' -f1)
    curl -s \
        -H "User-Agent: ${PODCASTINDEX_USER_AGENT:-podcast-search-cli/1.0}" \
        -H "X-Auth-Key: ${PODCASTINDEX_API_KEY}" \
        -H "X-Auth-Date: ${ts}" \
        -H "Authorization: ${hash}" \
        "$endpoint"
}

pi_configured() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "No config found at $CONFIG_FILE"
        echo "Create it with PODCASTINDEX_API_KEY, PODCASTINDEX_API_SECRET, PODCASTINDEX_USER_AGENT."
        return 1
    fi
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
    if [ -z "$PODCASTINDEX_API_KEY" ] || [ -z "$PODCASTINDEX_API_SECRET" ]; then
        echo "Config found but PODCASTINDEX_API_KEY/SECRET are empty. Check $CONFIG_FILE"
        return 1
    fi
    return 0
}

# --- Mode 2: browse by genre via Podcast Index ---
browse_by_genre() {
    pi_configured || return 1

    cat_cache="$CACHE_DIR/categories.json"
    use_cat_cache=false
    if [ -f "$cat_cache" ]; then
        age=$(( $(date +%s) - $(stat -c %Y "$cat_cache") ))
        [ "$age" -lt "$CATEGORIES_TTL" ] && use_cat_cache=true
    fi

    if [ "$use_cat_cache" = true ]; then
        categories_json=$(cat "$cat_cache")
    else
        categories_json=$(pi_request "https://api.podcastindex.org/api/1.0/categories/list")
        status=$(echo "$categories_json" | jq -r '.status // empty' 2>/dev/null)
        if [ -z "$categories_json" ] || [ "$status" != "true" ]; then
            echo "Failed to fetch category list. Raw response below:"
            echo "$categories_json"
            return 1
        fi
        echo "$categories_json" > "$cat_cache"
    fi

    # Response shape isn't 100% pinned down in advance - try both plausible keys.
    genre_raw=$(echo "$categories_json" | jq -r '
        (.feeds // .categories // []) | .[] | "\(.name)\t\(.id)"
    ')

    if [ -z "$genre_raw" ]; then
        echo "Could not parse categories from the API response."
        echo "Raw response saved for inspection: $CACHE_DIR/categories.json"
        return 1
    fi

    genre_display=$(echo "$genre_raw" | format_single_for_fzf)
    selected_genre=$(echo "$genre_display" | fzf --delimiter=$'\t' --with-nth=1 --prompt="Select Genre: " --bind 'esc:abort')
    [ -z "$selected_genre" ] && return 1

    genre_id=$(echo "$selected_genre" | awk -F'\t' '{print $2}')
    genre_name=$(echo "$genre_raw" | awk -F'\t' -v id="$genre_id" '$2 == id { print $1 }')
    chart_cache="$CACHE_DIR/genre_${genre_id}.json"

    use_chart_cache=false
    if [ -f "$chart_cache" ]; then
        age=$(( $(date +%s) - $(stat -c %Y "$chart_cache") ))
        if [ "$age" -lt "$CACHE_TTL" ]; then
            age_h=$(( age / 3600 ))
            cache_choice=$(printf 'Use cached\nRefresh' | \
                fzf --prompt="${genre_name} (~${age_h}h old) > " --bind 'esc:abort')
            [ "$cache_choice" != "Refresh" ] && use_chart_cache=true
        fi
    fi

    if [ "$use_chart_cache" = true ]; then
        chart_json=$(cat "$chart_cache")
    else
        chart_json=$(pi_request "https://api.podcastindex.org/api/1.0/podcasts/trending?cat=${genre_id}&max=200")
        if [ -z "$chart_json" ] || ! echo "$chart_json" | jq -e '.feeds' >/dev/null 2>&1; then
            echo "Failed to fetch trending list for '${genre_name}' (and no valid cache available)."
            return 1
        fi
        echo "$chart_json" > "$chart_cache"
    fi

    # Podcast Index feed objects include the actual feed url directly - no second lookup needed.
    # Also build a compact preview blob per item (literal \n as a section separator, since the
    # whole thing has to stay on one line for the tab-delimited list to parse correctly).
    raw=$(echo "$chart_json" | jq -r '
        .feeds[] | select(.url != null) |
        ((.categories // {}) | [.[]] | join(", ")) as $catstr |
        ((.description // "No description available.")
            | gsub("\r"; " ") | gsub("\n"; " ") | gsub("\t"; " ")) as $desc |
        "\(.title)\t\(.author)\t\(.url)\t" +
        "\(.title)\\n\(.author)\\n\\n" +
        "Episodes: \(.episodeCount // 0)\\n" +
        "Language: \(.language // "unknown")\\n" +
        "Categories: \($catstr)\\n\\n" +
        "\($desc)"
    ')
    [ -z "$raw" ] && { echo "No results in this genre."; return 1; }

    results=$(echo "$raw" | format_name_preview_for_fzf)
    selected=$(echo "$results" | fzf --delimiter=$'\t' --with-nth=1 \
        --preview 'printf "%b\n" {3} | fold -s -w "${FZF_PREVIEW_COLUMNS:-60}"' \
        --preview-window=right:55%:wrap \
        --prompt="Select Podcast ($genre_name): " --bind 'esc:abort')
    url=$(echo "$selected" | awk -F'\t' '{print $2}')

    [ -z "$url" ] && { echo "No selection made."; return 1; }

    printf '%s' "$url" | copy_to_clipboard
    show_copied_and_wait "$url"
    return 0
}

# --- Main menu loop ---
while true; do
    mode=$(printf 'Search by name\nBrowse by genre\nQuit' | \
        fzf --prompt="Podcast Search > " --bind 'esc:abort')
    case "$mode" in
        "Search by name") search_and_select ;;
        "Browse by genre") browse_by_genre ;;
        *) exit 0 ;;
    esac
done
