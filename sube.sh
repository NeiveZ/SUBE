#!/usr/bin/env bash
# SUBE - Subdomain Enumerator
# Author: NeiveZ | github.com/NeiveZ/SUBE


set -euo pipefail

# ── Colors ────────────────────────────────────────────────────────
R="\e[0m"; BOLD="\e[1m"
RD="\e[91m"; GR="\e[92m"; YL="\e[93m"; CY="\e[96m"; DG="\e[90m"; WH="\e[97m"

# ── Defaults ──────────────────────────────────────────────────────
DOMAIN=""
OUTPUT_DIR=""
WORDLIST=""
THREADS=40
MIN_PASSIVE=5
CURL_TIMEOUT=15
HOST_TIMEOUT=3
PASSIVE_ONLY=false
NO_AXFR=false
SILENT=false
TMPDIR_RUN=""
FINAL_OUTPUT=""

# ================================================================
#  HELP
# ================================================================

usage() {
cat << HELP
${BOLD}Usage:${R}
  $0 -d <domain> [options]

${BOLD}Options:${R}
  -d, --domain          Target domain (required)
  -o, --output          Output directory (default: <domain>.out)
  -w, --wordlist        Local wordlist for brute force (default: download SecLists)
  -t, --threads         Brute force parallel threads (default: 40)
  -m, --min-passive     Min passive results to skip brute force (default: 5)
  -T, --timeout         curl timeout in seconds (default: 15)
  --passive-only        Run AXFR + crt.sh only, skip brute force
  --no-axfr             Skip zone transfer attempt
  --silent              Results only — no progress output
  -h, --help            Show this help

${BOLD}Examples:${R}
  $0 -d example.com
  $0 -d example.com --passive-only -o /tmp/results
  $0 -d example.com -w /usr/share/seclists/Discovery/DNS/common.txt -t 80
  $0 -d example.com --no-axfr --silent | tee subdomains.txt
  $0 -d example.com -m 20
HELP
exit 0
}

# ================================================================
#  LOGGING
# ================================================================

log()  { $SILENT || printf "${CY}[*]${R} %s\n" "$*"; }
ok()   { $SILENT || printf "${BOLD}${GR}[+]${R} %s\n" "$*"; }
warn() { $SILENT || printf "${YL}[!]${R} %s\n" "$*"; }
err()  { printf "${RD}[-]${R} %s\n" "$*"; }

# ================================================================
#  CLEANUP
# ================================================================

cleanup() {
    [[ -n "$TMPDIR_RUN" && -d "$TMPDIR_RUN" ]] && rm -rf "$TMPDIR_RUN"
}
trap cleanup EXIT INT TERM

# ================================================================
#  STEP 1 — AXFR
# ================================================================

step_axfr() {
    $NO_AXFR && return

    log "Step 1/3 — Zone transfer attempt (AXFR)"

    local ns_file="${TMPDIR_RUN}/nameservers.txt"
    local axfr_raw="${TMPDIR_RUN}/axfr.raw"
    local success=false

    host -t NS "$DOMAIN" 2>/dev/null \
        | grep "name server" \
        | awk '{print $NF}' \
        | sed 's/\.$//' \
        > "$ns_file" || true

    local ns_count
    ns_count=$(wc -l < "$ns_file")

    if [[ "$ns_count" -eq 0 ]]; then
        warn "No nameservers found for ${DOMAIN}"
        return
    fi

    log "Found ${ns_count} nameserver(s). Testing AXFR..."

    while IFS= read -r ns; do
        [[ -z "$ns" || "$ns" == \#* ]] && continue

        timeout "$HOST_TIMEOUT" host -t axfr "$DOMAIN" "$ns" > "$axfr_raw" 2>/dev/null || true

        if [[ -s "$axfr_raw" ]] && grep -q "has address\|IN[[:space:]]" "$axfr_raw"; then
            ok "Zone transfer successful on ${ns}"
            success=true

            local record_types=("A" "AAAA" "CNAME" "MX" "NS" "TXT" "SOA")
            for rtype in "${record_types[@]}"; do
                local count
                count=$(grep -cE "IN[[:space:]]+${rtype}[[:space:]]+" "$axfr_raw" 2>/dev/null || echo 0)
                if [[ "$count" -gt 0 ]]; then
                    $SILENT || printf "  ${DG}%-6s${R} ${WH}%s${R} records\n" "$rtype" "$count"
                fi
            done

            grep -E "IN[[:space:]]+(A|CNAME|MX|NS)" "$axfr_raw" \
                | awk '{print $1}' \
                | sed 's/\.$//' \
                | grep -E "(^|\.)${DOMAIN}$" \
                | sort -u \
                >> "${TMPDIR_RUN}/axfr.results" 2>/dev/null || true

            break
        fi
    done < "$ns_file"

    $success || warn "Zone transfer failed or not permitted"
}

# ================================================================
#  STEP 2 — crt.sh
# ================================================================

step_crtsh() {
    log "Step 2/3 — Passive enumeration via crt.sh"

    local crt_raw="${TMPDIR_RUN}/crtsh.json"
    local crt_results="${TMPDIR_RUN}/crtsh.results"

    curl -s --max-time "$CURL_TIMEOUT" \
        "https://crt.sh/?q=${DOMAIN}&output=json" \
        -o "$crt_raw" 2>/dev/null || true

    if [[ ! -s "$crt_raw" ]] || [[ "$(wc -c < "$crt_raw")" -lt 10 ]]; then
        warn "crt.sh unreachable or returned no data"
        return 1
    fi

    {
        grep -o '"common_name":"[^"]*' "$crt_raw" | cut -d'"' -f4
        grep -o '"name_value":"[^"]*'  "$crt_raw" | cut -d'"' -f4
    } \
        | sed 's/^\*\.//' \
        | grep -E "(^|\.)${DOMAIN}$" \
        | grep -v "^${DOMAIN}$" \
        | sort -u \
        > "$crt_results" 2>/dev/null || true

    local count
    count=$(wc -l < "$crt_results")
    ok "crt.sh returned ${count} unique subdomain(s)"
    return 0
}

# ================================================================
#  STEP 3 — BRUTE FORCE
# ================================================================

step_bruteforce() {
    $PASSIVE_ONLY && { log "Skipping brute force (--passive-only)"; return; }

    log "Step 3/3 — Active brute force"

    local wl="${TMPDIR_RUN}/wordlist.txt"

    if [[ -n "$WORDLIST" && -f "$WORDLIST" ]]; then
        cp "$WORDLIST" "$wl"
        log "Using local wordlist: ${WORDLIST} ($(wc -l < "$wl") words)"
    else
        log "Downloading SecLists Top 100K..."
        curl -s --max-time 30 \
            "https://raw.githubusercontent.com/danielmiessler/SecLists/master/Discovery/DNS/bitquark-subdomains-top100000.txt" \
            -o "$wl" 2>/dev/null || true

        local wl_count
        wl_count=$(wc -l < "$wl" 2>/dev/null || echo 0)

        if [[ "$wl_count" -lt 1000 ]]; then
            warn "Failed to download wordlist. Skipping brute force."
            return
        fi
        log "Wordlist: ${wl_count} words | threads: ${THREADS}"
    fi

    local bf_results="${TMPDIR_RUN}/bruteforce.results"
    : > "$bf_results"

    export _SUBE_DOMAIN="$DOMAIN"
    export _SUBE_OUTFILE="$bf_results"
    export _SUBE_TIMEOUT="$HOST_TIMEOUT"
    export _SUBE_SILENT="$SILENT"

    grep -v '^ *#\|^$' "$wl" | xargs -P "$THREADS" -I{} bash -c '
        sub="${1}.${_SUBE_DOMAIN}"
        if timeout "${_SUBE_TIMEOUT}" host "$sub" 2>/dev/null | grep -q "has address\|has IPv6"; then
            echo "$sub" >> "${_SUBE_OUTFILE}"
            [ "${_SUBE_SILENT}" = "false" ] && printf "\033[92m[>]\033[0m \033[1m%s\033[0m\n" "$sub"
        fi
    ' _ {}

    unset _SUBE_DOMAIN _SUBE_OUTFILE _SUBE_TIMEOUT _SUBE_SILENT

    local bf_count
    bf_count=$(wc -l < "$bf_results" 2>/dev/null || echo 0)
    ok "Brute force found ${bf_count} subdomain(s)"
}

# ================================================================
#  MERGE & RESULTS
# ================================================================

merge_results() {
    : > "$FINAL_OUTPUT"

    for f in "${TMPDIR_RUN}/axfr.results" \
              "${TMPDIR_RUN}/crtsh.results" \
              "${TMPDIR_RUN}/bruteforce.results"; do
        [[ -s "$f" ]] && cat "$f" >> "$FINAL_OUTPUT"
    done

    sort -u "$FINAL_OUTPUT" \
        | sed '/^$/d; s/\.$//' \
        | grep -E "(^|\.)${DOMAIN}$" \
        > "${TMPDIR_RUN}/merged.tmp" 2>/dev/null || true

    mv "${TMPDIR_RUN}/merged.tmp" "$FINAL_OUTPUT"
}

print_results() {
    local total
    total=$(wc -l < "$FINAL_OUTPUT" 2>/dev/null || echo 0)

    if [[ "$total" -eq 0 ]]; then
        err "No subdomains found for ${DOMAIN}"
        return
    fi

    if ! $SILENT; then
        echo
        ok "Total unique subdomains: ${BOLD}${WH}${total}${R}"
        log "Saved to: ${WH}${FINAL_OUTPUT}${R}"
        echo
        log "Sample results:"
        head -n 10 "$FINAL_OUTPUT" | while IFS= read -r line; do
            printf "  ${WH}%s${R}\n" "$line"
        done
        if [[ "$total" -gt 10 ]]; then
            printf "  ${DG}... and %d more — see %s${R}\n" "$(( total - 10 ))" "$FINAL_OUTPUT"
        fi
    else
        cat "$FINAL_OUTPUT"
    fi
}

# ================================================================
#  ARGUMENT PARSING
# ================================================================

[[ $# -eq 0 ]] && usage

while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--domain)      DOMAIN="$2";       shift 2 ;;
        -o|--output)      OUTPUT_DIR="$2";   shift 2 ;;
        -w|--wordlist)    WORDLIST="$2";     shift 2 ;;
        -t|--threads)     THREADS="$2";      shift 2 ;;
        -m|--min-passive) MIN_PASSIVE="$2";  shift 2 ;;
        -T|--timeout)     CURL_TIMEOUT="$2"; shift 2 ;;
        --passive-only)   PASSIVE_ONLY=true; shift ;;
        --no-axfr)        NO_AXFR=true;      shift ;;
        --silent)         SILENT=true;       shift ;;
        -h|--help)        usage ;;
        *) err "Unknown option: $1"; usage ;;
    esac
done

# ── Validations ───────────────────────────────────────────────────

[[ -z "$DOMAIN" ]] && { err "-d is required"; exit 1; }

echo "$DOMAIN" | grep -qE '^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z]{2,})+$' || {
    err "Invalid domain: ${DOMAIN}"
    exit 1
}

for dep in curl host awk sort; do
    command -v "$dep" &>/dev/null || {
        err "Missing dependency: ${dep} — apt install dnsutils curl"
        exit 1
    }
done

# ── Setup ─────────────────────────────────────────────────────────

OUTPUT_DIR="${OUTPUT_DIR:-${DOMAIN}.out}"
mkdir -p "$OUTPUT_DIR"
TMPDIR_RUN=$(mktemp -d /tmp/sube_XXXXXX)
FINAL_OUTPUT="${OUTPUT_DIR}/${DOMAIN}-subdomains.txt"
: > "$FINAL_OUTPUT"
touch "${TMPDIR_RUN}/axfr.results" \
      "${TMPDIR_RUN}/crtsh.results" \
      "${TMPDIR_RUN}/bruteforce.results"

# ================================================================
#  RUN
# ================================================================

START_TIME=$(date +%s)

if ! $SILENT; then
    echo -e "\n${BOLD}${DOMAIN}${R}  ${DG}chain:${R} AXFR → crt.sh → Brute Force"
    echo -e "${DG}min-passive:${R} ${MIN_PASSIVE}  ${DG}threads:${R} ${THREADS}  ${DG}passive-only:${R} ${PASSIVE_ONLY}\n"
fi

step_axfr
step_crtsh

# Decide whether brute force is needed
axfr_count=$(wc -l < "${TMPDIR_RUN}/axfr.results"  2>/dev/null || echo 0)
crtsh_count=$(wc -l < "${TMPDIR_RUN}/crtsh.results" 2>/dev/null || echo 0)
total_passive=$(( axfr_count + crtsh_count ))

if [[ "$total_passive" -ge "$MIN_PASSIVE" ]]; then
    log "Passive results (${total_passive}) meet threshold (${MIN_PASSIVE}). Skipping brute force."
    PASSIVE_ONLY=true
else
    warn "Passive results (${total_passive}) below threshold (${MIN_PASSIVE}). Starting brute force..."
fi

step_bruteforce
merge_results
print_results

END_TIME=$(date +%s)
ELAPSED=$(( END_TIME - START_TIME ))
$SILENT || echo -e "\n${DG}time:${R} ${ELAPSED}s"
