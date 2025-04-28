#!/bin/bash

# === File paths ===
jsonFile="automated.json"
csvFile="compliance_results.csv"
logFile="compliance_log.txt"

# === Pre-requisite Check and Install jq if missing ===
if ! command -v jq &> /dev/null; then
    echo "jq not found. Installing jq..."
    sudo yum install -y jq || { echo "Failed to install jq. Exiting."; exit 1; }
fi

# === Prepare output files ===
: > "$logFile"
echo "ID,Description,Post Check Compliance" > "$csvFile"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$logFile"
}

# === Sanity Check ===
[[ ! -f "$jsonFile" ]] && echo "Missing $jsonFile" && exit 1

# === Compliance Check Functions ===

normalize_line() {
    local line="$1"
    echo "$line" | tr -s ' ' | sed -E 's/auid!=unset/auid!=-1/g'
}

handle_generic() {
    if [[ "$expected" == regex:* ]]; then
        local regex="${expected#regex:}"
        [[ "$pre_out" =~ $regex ]] && return 0 || return 1
    else
        [[ "$pre_out" == "$expected" ]] && return 0 || return 1
    fi
}

handle_either_or() {
    IFS='||' read -ra options <<< "$(jq -r '.' <<< "$expected")"
    for val in "${options[@]}"; do
        [[ "$pre_out" == "$(echo "$val" | tr -s ' ')" ]] && return 0
    done
    return 1
}

handle_list() {
    mapfile -t expected_arr < <(jq -r '.[]' <<< "$expected")
    pre_lines=()
    while IFS= read -r line; do pre_lines+=("$(normalize_line "$line")"); done <<< "$pre_out"

    missing=()
    for item in "${expected_arr[@]}"; do
        norm_item=$(normalize_line "$item")
        found=false
        for line in "${pre_lines[@]}"; do [[ "$line" == "$norm_item" ]] && found=true && break; done
        $found || missing+=("$item")
    done

    if [ "${#missing[@]}" -eq 0 ]; then return 0; fi
    return 1
}

handle_filecheck() {
    mapfile -t expected_arr < <(jq -r '.[]' <<< "$expected")
    current_out=()
    while IFS= read -r line; do current_out+=("$(echo "$line" | tr -s ' ')"); done <<< "$pre_out"

    for expected_line in "${expected_arr[@]}"; do
        matched=false
        for line in "${current_out[@]}"; do
            [[ "$line" == "$expected_line" ]] && matched=true && break
        done
        if ! $matched; then return 1; fi
    done
    return 0
}

# === Main Checking Loop ===

jq -c '.[]' "$jsonFile" | while read -r control; do
    id=$(jq -r '.id' <<< "$control")
    desc=$(jq -r '.description' <<< "$control")
    cmd=$(jq -r '.command' <<< "$control")
    expected=$(jq -r '.expected_output' <<< "$control")
    type=$(jq -r '.type' <<< "$control")

    echo "$id - Checking..."

    pre_out=$(bash -c "$cmd" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr -s ' ')

    log "CHECKING: $id - $desc"
    log "Expected: $expected"
    log "Found: $pre_out"

    result="FAIL"
    case "$type" in
        "Generic") handle_generic && result="PASS" ;;
        "List") handle_list && result="PASS" ;;
        "Either | OR") handle_either_or && result="PASS" ;;
        "FileCheck") handle_filecheck && result="PASS" ;;
        *) log "Unknown type '$type' for $id" ;;
    esac

    if [[ -z "$pre_out" ]]; then
        log "COMMAND OUTPUT EMPTY: $id - Cannot determine compliance"
    fi

    echo "$id,\"$desc\",$result" >> "$csvFile"
    log "FINAL RESULT: $id - Compliance: $result"

done

echo "✅ Compliance Checking Complete."
echo " - CSV Report: $csvFile"
echo " - Log File: $logFile"
