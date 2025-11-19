#!/usr/bin/env bash
set -euo pipefail

AUTHOR="Mateusz Meteo"
VERSION="1.0.0"
USER_AGENT="mymeteo-bash/${VERSION} (kontakt@example.com)"
NOMINATIM_URL="https://nominatim.openstreetmap.org/search"
IMGW_URL="https://danepubliczne.imgw.pl/api/data/synop"
DEFAULT_CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/mymeteo"
DEFAULT_RC_FILE="$HOME/.mymeteorc"
MIN_NOMINATIM_DELAY=2
COLOR=1
DEBUG=0
CITY=""
CACHE_DIR="$DEFAULT_CACHE_DIR"
RC_FILE="$DEFAULT_RC_FILE"

declare -A RC_VALUES

usage() {
    cat <<USAGE
mymeteo ${VERSION}
Autor: ${AUTHOR}

Użycie: $0 --city "Nazwa" [opcje]

Opcje:
  -c, --city NAZWA       Miejscowość, dla której ma zostać wyświetlona prognoza.
      --cache-dir ŚCIEŻKA    Własny katalog pamięci podręcznej.
      --config ŚCIEŻKA       Plik konfiguracji (~/.mymeteorc domyślnie).
      --debug                Włącza szczegółowe logi działania.
      --no-color             Wyłącza kolorowanie wyników (dla bajeru ;)).
  -h, --help                Wyświetla tę pomoc.

Plik rc (~/.mymeteorc) obsługuje wpisy w postaci klucz=wartość, np.:
  city=Poznań
  cache_dir=~/.cache/mymeteo
  color=no
USAGE
}

log_info() { printf '[INFO] %s\n' "$*" >&2; }
log_debug() { [[ $DEBUG -eq 1 ]] && printf '[DEBUG] %s\n' "$*" >&2; }
log_error() { printf '[ERROR] %s\n' "$*" >&2; }

die() { log_error "$1"; exit 1; }

ensure_command() {
    command -v "$1" >/dev/null || die "Polecenie '$1' jest wymagane, zainstaluj je proszę."
}

sanitize_key() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c '[:alnum:]' '-'
}

expand_path() {
    local path="$1"
    case "$path" in
        ~*) echo "${path/#\~/$HOME}" ;;
        *) echo "$path" ;;
    esac
}

urlencode() {
    jq -rn --arg v "$1" '$v|@uri'
}

ensure_rate_limit() {
    local rate_file="$CACHE_DIR/.nominatim_last_call"
    local now ts wait
    now=$(date +%s)
    if [[ -f "$rate_file" ]]; then
        ts=$(<"$rate_file")
        if [[ -n "$ts" ]]; then
            local diff=$(( now - ts ))
            if (( diff < MIN_NOMINATIM_DELAY )); then
                wait=$(( MIN_NOMINATIM_DELAY - diff ))
                log_debug "Wstrzymuję zapytanie do Nominatim na ${wait}s"
                sleep "$wait"
            fi
        fi
    fi
    printf '%s' "$now" >"$rate_file"
}

get_cached_place() {
    local key="$1"
    local file="$CACHE_DIR/places/${key}.json"
    [[ -f "$file" ]] || return 1
    jq -er '{lat:.lat,lon:.lon}' "$file" >/dev/null || return 1
    jq -r '"\(.lat)\t\(.lon)"' "$file"
}

store_place_cache() {
    local key="$1" lat="$2" lon="$3" raw_file="$4"
    local file="$CACHE_DIR/places/${key}.json"
    printf '{"lat":%s,"lon":%s,"raw":%s}\n' "$lat" "$lon" "$(cat "$raw_file")" >"$file"
}

fetch_place() {
    local query="$1" key
    key=$(sanitize_key "$query")
    if coords=$(get_cached_place "$key" 2>/dev/null); then
        log_debug "Korzystam z pamięci podręcznej dla '${query}'"
        printf '%s\n' "$coords"
        return 0
    fi
    ensure_rate_limit
    local encoded
    encoded=$(urlencode "$query, Polska")
    log_debug "Zapytanie do Nominatim o '${query}'"
    local response tmp
    tmp=$(mktemp)
    if ! curl -sS -A "$USER_AGENT" -H 'Accept-Language: pl' "$NOMINATIM_URL?q=$encoded&format=json&limit=1" -o "$tmp"; then
        rm -f "$tmp"
        die "Nie udało się pobrać danych lokalizacji z Nominatim."
    fi
    local lat lon
    lat=$(jq -r '.[0].lat // empty' "$tmp")
    lon=$(jq -r '.[0].lon // empty' "$tmp")
    [[ -n "$lat" && -n "$lon" ]] || die "Brak wyników dla lokalizacji '${query}'."
    store_place_cache "$key" "$lat" "$lon" "$tmp"
    rm -f "$tmp"
    printf '%s\t%s\n' "$lat" "$lon"
}

parse_rc() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    while IFS='=' read -r key value; do
        [[ -z "$key" ]] && continue
        [[ "$key" =~ ^# ]] && continue
        key=$(echo "$key" | tr '[:upper:]' '[:lower:]' | xargs)
        value=$(echo "$value" | sed 's/^\s*//;s/\s*$//')
        RC_VALUES["$key"]="$value"
    done < <(grep -Ev '^\s*(#|$)' "$file")
}

apply_rc() {
    [[ -n "${RC_VALUES[cache_dir]:-}" ]] && CACHE_DIR=$(expand_path "${RC_VALUES[cache_dir]}")
    if [[ -n "${RC_VALUES[color]:-}" ]]; then
        case "${RC_VALUES[color],,}" in
            no|false|0) COLOR=0 ;;
            *) COLOR=1 ;;
        esac
    fi
    [[ -z "$CITY" && -n "${RC_VALUES[city]:-}" ]] && CITY="${RC_VALUES[city]}"
}

ensure_cache_layout() {
    mkdir -p "$CACHE_DIR" "$CACHE_DIR/places" "$CACHE_DIR/stations" "$CACHE_DIR/weather"
}

geocode_station() {
    local station="$1"
    local cache_file="$CACHE_DIR/stations/$(sanitize_key "$station").json"
    if [[ -f "$cache_file" ]]; then
        jq -er '.lat, .lon' "$cache_file" >/dev/null 2>&1 && jq -r '"\(.lat)\t\(.lon)"' "$cache_file" && return
    fi
    read -r lat lon < <(fetch_place "$station")
    printf '{"lat":%s,"lon":%s,"name":%s}\n' "$lat" "$lon" "$(jq -Rn --arg v "$station" '$v')" >"$cache_file"
    printf '%s\t%s\n' "$lat" "$lon"
}

ensure_station_metadata() {
    local stations_file="$CACHE_DIR/stations.json"
    if [[ -f "$stations_file" ]]; then
        jq -er '.stations' "$stations_file" >/dev/null 2>&1 && echo "$stations_file" && return
    fi
    log_info "Generuję bazę współrzędnych stacji IMGW (pierwsze uruchomienie może chwilę potrwać)..."
    local tmp_data tmp_rows
    tmp_data=$(mktemp)
    tmp_rows=$(mktemp)
    if ! curl -sS -A "$USER_AGENT" "$IMGW_URL" -o "$tmp_data"; then
        rm -f "$tmp_data" "$tmp_rows"
        die "Nie udało się pobrać listy stacji IMGW."
    fi
    jq -r '.[] | [.id_stacji, .stacja] | @tsv' "$tmp_data" | sort -u > "$tmp_rows"
    local rows_file
    rows_file=$(mktemp)
    while IFS=$'\t' read -r station_id station_name; do
        [[ -z "$station_id" ]] && continue
        read -r lat lon < <(geocode_station "$station_name")
        printf '%s\t%s\t%s\t%s\n' "$station_id" "$station_name" "$lat" "$lon" >> "$rows_file"
    done < "$tmp_rows"
    jq -Rn --arg gen "$(date --iso-8601=seconds)" '(
        [inputs | split("\t") | select(length==4) | {
            id: .[0],
            name: .[1],
            lat: (.[2]|tonumber),
            lon: (.[3]|tonumber)
        }]
    ) as $stations | {generated_at:$gen, stations:$stations}' "$rows_file" > "$stations_file"
    rm -f "$tmp_data" "$tmp_rows" "$rows_file"
    echo "$stations_file"
}

calculate_distance() {
    local lat1="$1" lon1="$2" lat2="$3" lon2="$4"
    awk -v lat1="$lat1" -v lon1="$lon1" -v lat2="$lat2" -v lon2="$lon2" 'BEGIN {
        pi = atan2(0, -1)
        dlat = (lat2-lat1)*pi/180
        dlon = (lon2-lon1)*pi/180
        a = (sin(dlat/2))^2 + cos(lat1*pi/180) * cos(lat2*pi/180) * (sin(dlon/2))^2
        c = 2 * atan2(sqrt(a), sqrt(1-a))
        printf "%.3f\n", 6371 * c
    }'
}

find_nearest_station() {
    local lat="$1" lon="$2" stations_file="$3"
    local nearest_id="" nearest_name="" nearest_lat="" nearest_lon="" nearest_dist=""
    while IFS=$'\t' read -r sid sname slat slon; do
        local dist
        dist=$(calculate_distance "$lat" "$lon" "$slat" "$slon")
        if [[ -z "$nearest_dist" ]] || awk -v a="$dist" -v b="$nearest_dist" 'BEGIN {exit !(a < b)}'; then
            nearest_dist="$dist"
            nearest_id="$sid"
            nearest_name="$sname"
            nearest_lat="$slat"
            nearest_lon="$slon"
        fi
    done < <(jq -r '.stations[] | [.id,.name,.lat,.lon] | @tsv' "$stations_file")
    printf '%s\t%s\t%s\t%s\t%s\n' "$nearest_id" "$nearest_name" "$nearest_lat" "$nearest_lon" "$nearest_dist"
}

ensure_weather_cache() {
    local weather_file="$CACHE_DIR/weather/latest.json"
    local now=$(date +%s)
    if [[ -f "$weather_file" ]]; then
        local fetched=$(jq -r '.fetched_at // 0' "$weather_file")
        if [[ "$fetched" =~ ^[0-9]+$ ]] && (( now - fetched < 1800 )); then
            echo "$weather_file"
            return
        fi
    fi
    log_info "Pobieram świeże dane synoptyczne IMGW..."
    local tmp=$(mktemp)
    if ! curl -sS -A "$USER_AGENT" "$IMGW_URL" -o "$tmp"; then
        rm -f "$tmp"
        die "Nie udało się pobrać danych IMGW."
    fi
    printf '{"fetched_at":%s,"data":%s}\n' "$now" "$(cat "$tmp")" > "$weather_file"
    rm -f "$tmp"
    echo "$weather_file"
}

fetch_station_measurements() {
    local station_id="$1" weather_file="$2"
    jq -r --arg sid "$station_id" '.data[] | select(.id_stacji==$sid)' "$weather_file"
}

format_value() {
    local label="$1" value="$2" unit="$3"
    local color_code reset="\033[0m"
    if [[ $COLOR -eq 0 ]]; then
        printf '%-18s %10s %s\n' "$label:" "$value" "$unit"
        return
    fi
    case "$label" in
        Temperatura) color_code="\033[38;5;208m" ;;
        "Prędkość wiatru") color_code="\033[36m" ;;
        "Wilgotność wzgl.") color_code="\033[35m" ;;
        "Ciśnienie") color_code="\033[32m" ;;
        *) color_code="\033[37m" ;;
    esac
    printf '%s%-18s%s %10s %s\n' "$color_code" "$label:" "$reset" "$value" "$unit"
}

print_report() {
    local station_json="$1" station_name="$2" station_id="$3" city_name="$4" distance="$5"
    local measurement_time
    measurement_time=$(echo "$station_json" | jq -r '.data_pomiaru + " " + .godzina_pomiaru')
    printf '\n%s [%s] — %s (%.1f km)\n' "$station_name" "$station_id" "$measurement_time" "$distance"
    format_value "Temperatura" "$(echo "$station_json" | jq -r '.temperatura // "brak"')" "°C"
    format_value "Prędkość wiatru" "$(echo "$station_json" | jq -r '.predkosc_wiatru // "brak"')" "m/s"
    format_value "Kierunek wiatru" "$(echo "$station_json" | jq -r '.kierunek_wiatru // "brak"')" "°"
    format_value "Wilgotność wzgl." "$(echo "$station_json" | jq -r '.wilgotnosc_wzgledna // "brak"')" "%"
    format_value "Suma opadu" "$(echo "$station_json" | jq -r '.suma_opadu // "brak"')" "mm"
    format_value "Ciśnienie" "$(echo "$station_json" | jq -r '.cisnienie // "brak"')" "hPa"
    printf '\nDane: IMGW-PIB (https://danepubliczne.imgw.pl/)\n'
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -c|--city)
                CITY="$2"; shift 2 ;;
            --cache-dir)
                CACHE_DIR=$(expand_path "$2"); shift 2 ;;
            --config)
                RC_FILE=$(expand_path "$2"); shift 2 ;;
            --debug|--verbose)
                DEBUG=1; shift ;;
            --no-color)
                COLOR=0; shift ;;
            -h|--help)
                usage; exit 0 ;;
            *)
                die "Nieznany parametr: $1" ;;
        esac
    done
}

main() {
    ensure_command curl
    ensure_command jq
    ensure_command awk

    parse_args "$@"
    RC_FILE=$(expand_path "$RC_FILE")
    parse_rc "$RC_FILE"
    apply_rc

    [[ -n "$CITY" ]] || die "Musisz podać nazwę miasta (--city)."
    ensure_cache_layout

    log_debug "Katalog cache: $CACHE_DIR"
    log_debug "Miasto: $CITY"

    read -r city_lat city_lon < <(fetch_place "$CITY")
    log_debug "Współrzędne miasta: $city_lat,$city_lon"

    local stations_file
    stations_file=$(ensure_station_metadata)
    log_debug "Używam pliku stacji: $stations_file"

    local station_data
    station_data=$(find_nearest_station "$city_lat" "$city_lon" "$stations_file")
    IFS=$'\t' read -r station_id station_name station_lat station_lon distance <<< "$station_data"
    log_info "Najbliższa stacja: $station_name ($distance km)"

    local weather_file
    weather_file=$(ensure_weather_cache)

    local measurement
    measurement=$(fetch_station_measurements "$station_id" "$weather_file")
    [[ -n "$measurement" ]] || die "Brak danych dla stacji $station_name ($station_id)."

    print_report "$measurement" "$station_name" "$station_id" "$CITY" "$distance"
}

main "$@"
