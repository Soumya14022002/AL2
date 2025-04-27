#!/bin/bash

# === File paths ===
jsonFile="automated.json"
remediationFile="remediations.txt"
csvFile="compliance_results.csv"
logFile="compliance_log.txt"

: > "$logFile"
echo "ID,Description,Post Fix Compliance" > "$csvFile"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$logFile"
}

[[ ! -f "$jsonFile" ]] && echo "Missing $jsonFile" && exit 1
[[ ! -f "$remediationFile" ]] && echo "Missing $remediationFile" && exit 1

mapfile -t remediationIDs < "$remediationFile"
ids_json=$(printf '%s\n' "${remediationIDs[@]}" | jq -R . | jq -s .)
controls=$(jq --argjson ids "$ids_json" '[.[] | select(.id as $id | $ids | index($id))]' "$jsonFile")

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

    if [[ -n "$file" ]]; then
        for m in "${missing[@]}"; do
            if ! grep -qF -- "$m" "$file" 2>/dev/null; then
                echo "$m" | sudo tee -a "$file" > /dev/null
                log "Appended missing item to $file: $m"
            fi
        done
    fi

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

# === Main Processing Loop ===

jq -c '.[]' <<< "$controls" | while read -r control; do
    id=$(jq -r '.id' <<< "$control")
    desc=$(jq -r '.description' <<< "$control")
    cmd=$(jq -r '.command' <<< "$control")
    expected=$(jq -r '.expected_output' <<< "$control")
    fix=$(jq -r '.fix' <<< "$control")
    type=$(jq -r '.type' <<< "$control")

    # Suppress command output on screen
    echo "$id - Remediating..."

    pre_out=$(bash -c "$cmd" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr -s ' ')
    log "BEFORE FIX: $id - $desc"
    log "Expected: $expected"
    log "Found: $pre_out"

    result="FAIL"
    check_status=1

    case "$type" in
        "Generic") handle_generic && result="PASS" ;;
        "List") handle_list; check_status=$?; [[ "$check_status" == 0 ]] && result="PASS" ;;
        "Either | OR") handle_either_or && result="PASS" ;;
        "FileCheck") handle_filecheck && result="PASS" ;;
        *) log "Unknown type '$type' for $id" ;;
    esac

    if [[ "$result" == "FAIL" && "$check_status" -ne 2 ]]; then
        log "Applying fix for $id"
        eval "$fix" 2>/dev/null
        log "Fix applied"

        sleep 2
        pre_out=$(eval "$cmd" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr -s ' ')
        case "$type" in
            "Generic") handle_generic && result="PASS" ;;
            "List") handle_list; [[ $? == 0 ]] && result="PASS" ;;
            "Either | OR") handle_either_or && result="PASS" ;;
            "FileCheck") handle_filecheck && result="PASS" ;;
        esac
        log "AFTER FIX: $id - Compliance: $result"
    elif [[ -z "$pre_out" ]]; then
        log "FILE MISSING: $id - Command output is empty"
    else
        log "ALREADY COMPLIANT: $id - No action needed"
    fi

    echo "$id,\"$desc\",$result" >> "$csvFile"
done

echo "✅ Remediation complete. Output:"
echo " - CSV: $csvFile"
echo " - Log: $logFile"
