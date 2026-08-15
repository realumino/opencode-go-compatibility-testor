#!/usr/bin/env bash
#
# check_endpoints.sh — verify endpoint compatibility of every model in model_endpoint_info.csv
#
# Every model is tested against all three OpenAI/Anthropic-style endpoints:
#   /chat/completions   OpenAI Chat Completions   (@ai-sdk/openai-compatible)
#   /responses          OpenAI Responses API      (@ai-sdk/openai)
#   /messages           Anthropic Messages API    (@ai-sdk/anthropic)
#
# The endpoint listed in the CSV for a model is its "primary" endpoint; the
# other two are the compatibility checks. E.g. deepseek-v4-pro is served via
# /chat/completions, so the script also tries /responses and /messages on it.
#
# No Python, no SDKs — just bash + curl (responses parsed with grep/tr/cut).
#
# API key resolution (first match wins):
#   1. -k/--key <key>
#   2. $OPENCODE_API_KEY
#   3. $API_KEY
#   4. the key stored in ~/.local/share/opencode/auth.json (opencode's config)
#
# Usage:
#   ./check_endpoints.sh
#   ./check_endpoints.sh -k sk-...                    # explicit key
#   ./check_endpoints.sh -m deepseek-v4-pro           # single model only
#   ./check_endpoints.sh --dry-run                    # print plan, no HTTP
#   ./check_endpoints.sh --csv results.csv            # also write results CSV
#
# Expects a simple unquoted CSV (no commas inside fields). Requires: bash, curl.

set -uo pipefail

CSV_FILE="model_endpoint_info.csv"
KEY=""
MODEL_FILTER=""
DRY_RUN=0
CSV_OUT=""

usage() {
    cat <<'EOF'
check_endpoints.sh — verify endpoint compatibility of models in model_endpoint_info.csv

Every model is tested against all three endpoints:
  /chat/completions   OpenAI Chat Completions   (@ai-sdk/openai-compatible)
  /responses          OpenAI Responses API      (@ai-sdk/openai)
  /messages           Anthropic Messages API    (@ai-sdk/anthropic)
The endpoint listed in the CSV is the "primary" one; the other two are the
compatibility checks (e.g. can deepseek-v4-pro also be reached via /responses?).

API key resolution (first match wins):
  1. -k/--key <key>
  2. $OPENCODE_API_KEY
  3. $API_KEY
  4. the key stored in ~/.local/share/opencode/auth.json (opencode's config)

Usage:
  ./check_endpoints.sh
  ./check_endpoints.sh -k sk-...          # explicit key
  ./check_endpoints.sh -m deepseek-v4-pro # single model only
  ./check_endpoints.sh --dry-run          # print plan, no HTTP requests
  ./check_endpoints.sh --csv out.csv      # also write machine-readable results

Expects a simple unquoted CSV (no commas inside fields). Requires: bash, curl.
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -k|--key)   KEY="${2:?missing argument for $1}"; shift 2 ;;
        -m|--model) MODEL_FILTER="${2:?missing argument for $1}"; shift 2 ;;
        -f|--file)  CSV_FILE="${2:?missing argument for $1}"; shift 2 ;;
        --csv)      CSV_OUT="${2:?missing argument for $1}"; shift 2 ;;
        --dry-run)  DRY_RUN=1; shift ;;
        -h|--help)  usage ;;
        *) echo "unknown option: $1" >&2; usage ;;
    esac
done

resolve_key() {
    [[ -n "$KEY" ]] && return
    [[ -n "${OPENCODE_API_KEY:-}" ]] && { KEY="$OPENCODE_API_KEY"; return; }
    [[ -n "${API_KEY:-}" ]] && { KEY="$API_KEY"; return; }
    local auth="$HOME/.local/share/opencode/auth.json"
    if [[ -f "$auth" ]]; then
        KEY="$(sed -n 's/.*"key"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$auth" | head -1)"
        [[ -n "$KEY" ]] && { echo "note: using API key from $auth (opencode config)" >&2; return; }
    fi
    echo "error: no API key found. Set OPENCODE_API_KEY or API_KEY, pass -k, or run 'opencode auth login'." >&2
    exit 1
}

# request <model_id> <url> <kind> <body_file> -> prints HTTP status (000 on failure)
request() {
    local model="$1" url="$2" kind="$3" body="$4"
    local args=(--silent --show-error --max-time 90 --connect-timeout 10
                -o "$body" -w '%{http_code}')
    case "$kind" in
        chat)
            curl "${args[@]}" \
                -H 'Content-Type: application/json' \
                -H "Authorization: Bearer $KEY" \
                --data "{\"model\":\"$model\",\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}],\"max_tokens\":1024}" \
                "$url" 2>/dev/null
            ;;
        responses)
            # array-form input: the proxy's translators reject the bare-string form
            curl "${args[@]}" \
                -H 'Content-Type: application/json' \
                -H "Authorization: Bearer $KEY" \
                --data "{\"model\":\"$model\",\"input\":[{\"role\":\"user\",\"content\":\"ping\"}],\"max_output_tokens\":1024}" \
                "$url" 2>/dev/null
            ;;
        messages)
            # array-form content blocks: what @ai-sdk/anthropic actually sends
            curl "${args[@]}" \
                -H 'Content-Type: application/json' \
                -H "x-api-key: $KEY" \
                -H 'anthropic-version: 2023-06-01' \
                --data "{\"model\":\"$model\",\"max_tokens\":8,\"messages\":[{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"ping\"}]}]}" \
                "$url" 2>/dev/null
            ;;
    esac
}

# passes <http_status> <body_file> <kind> -> 0 if the response looks like a real model reply
# "Real reply" means the model actually produced output: 2xx, no "error" field, and at
# least one non-empty content/text/reasoning string. 2xx stubs with empty output —
# "content":[], "choices":[], "content":"", or a bare {"id":...} — fail this check.
# (The original check only required the marker key to be present, so e.g. an empty
# anthropic-shaped 200 with "content":[] was reported OK even though the model never
# answered.)
passes() {
    local status="$1" body="$2" kind="$3"
    [[ "$status" =~ ^2[0-9][0-9]$ ]] || return 1
    # a real error has "error": {...} or "error": "..." — "error":null is normal
    grep -qE '"error"[[:space:]]*:[[:space:]]*[^n]' "$body" 2>/dev/null && return 1
    # One non-empty string for a content-ish key, in whatever shape the translator
    # returns: "content":"ping" (chat string form), "text":"ping" (anthropic /
    # responses block form), "content":[{"type":"text","text":"ping"}]. Reasoning
    # models (glm, deepseek, ...) spend their budget on reasoning first, so also
    # accept non-empty reasoning fields: "reasoning_content":"..." (chat),
    # "thinking":"..." (anthropic thinking blocks), "reasoning":"...". Fails on
    # "" / null / [] / no content-ish key at all. The kind arg is unused by the
    # check itself — the shape-agnostic pattern covers all three endpoints.
    grep -qE '"(content|text|thinking|reasoning_content|reasoning)"[[:space:]]*:[[:space:]]*"[^"]' "$body" 2>/dev/null
}

# snippet <body_file> -> one-line, truncated body, for failure detail
snippet() {
    tr '\n' ' ' < "$1" 2>/dev/null | sed 's/  */ /g' | cut -c1-220
}

main() {
    resolve_key
    [[ -f "$CSV_FILE" ]] || { echo "error: $CSV_FILE not found" >&2; exit 1; }

    [[ "$DRY_RUN" == 1 ]] && echo "DRY RUN — no HTTP requests will be made"
    [[ -n "$MODEL_FILTER" ]] && echo "filtered to model: $MODEL_FILTER"
    echo

    tmpdir="$(mktemp -d)"   # global (not local): the EXIT trap runs after main returns
    trap 'rm -rf "$tmpdir"' EXIT

    if [[ -n "$CSV_OUT" ]]; then
        : > "$CSV_OUT"
        echo "model_id,model_name,endpoint,primary,http_status,result" > "$CSV_OUT"
    fi

    printf '%-20s %-17s %-8s %-5s %s\n' 'Model' 'Endpoint' 'Primary' 'HTTP' 'Result'
    printf '%-20s %-17s %-8s %-5s %s\n' '--------------------' '-----------------' '-------' '-----' '------'

    local total=0 passed=0 model_all_ok=0 model_count=0
    local failures=()

    while IFS=, read -r name model_id url sdk; do
        [[ -z "$name" || "$name" == "Model" ]] && continue   # skip header + blanks
        [[ -n "$MODEL_FILTER" && "$model_id" != "$MODEL_FILTER" ]] && continue

        # All CSV endpoints live under a shared /v1/ prefix; cut there so
        # /chat/completions, /responses and /messages all reduce to the same base.
        # (dirname doesn't work: it strips only the last component, so
        # .../v1/chat/completions would lose just "completions".)
        local base="${url%/v1/*}/v1"
        local primary_path="${url#"$base"}"                  # e.g. /chat/completions
        local row_results=() model_pass=1

        for ep in chat/completions responses messages; do
            case "$ep" in
                chat/completions) kind=chat ;;
                responses) kind=responses ;;
                messages) kind=messages ;;
            esac
            local ep_url="$base/$ep"
            local is_primary=no; [[ "/$ep" == "$primary_path" ]] && is_primary=yes

            if [[ "$DRY_RUN" == 1 ]]; then
                printf '%-20s %-17s %-8s %-5s %s\n' "$name" "$ep" "$is_primary" '-' 'would test'
                continue
            fi

            local body="$tmpdir/body.$$.$model_id.$kind"   # kind has no '/', unlike $ep
            local status="$(request "$model_id" "$ep_url" "$kind" "$body")"

            if passes "$status" "$body" "$kind"; then
                local result=OK; passed=$((passed+1))
            else
                local result=FAIL; model_pass=0
                failures+=("$model_id /$ep -> HTTP $status")
            fi
            total=$((total+1))
            printf '%-20s %-17s %-8s %-5s %s\n' "$name" "$ep" "$is_primary" "$status" "$result"
            [[ "$result" == FAIL ]] && printf '    %s\n' "$(snippet "$body")"
            row_results+=("$result")

            if [[ -n "$CSV_OUT" ]]; then
                echo "$model_id,$name,$ep,$is_primary,$status,$result" >> "$CSV_OUT"
            fi
            sleep 0.2
        done

        model_count=$((model_count+1))
        if [[ "$DRY_RUN" != 1 ]]; then
            [[ "$model_pass" == 1 ]] && model_all_ok=$((model_all_ok+1))
            printf '  → %s: chat=%s responses=%s messages=%s\n' \
                "$model_id" "${row_results[0]}" "${row_results[1]}" "${row_results[2]}"
        fi
    done < <(tr -d '\r' < "$CSV_FILE")

    if [[ "$DRY_RUN" != 1 ]]; then
        echo
        echo "Summary: $passed/$total checks passed"
        echo "Models with all 3 endpoints working: $model_all_ok/$model_count"
        if [[ ${#failures[@]} -gt 0 ]]; then
            echo
            echo "Failures:"
            printf '  - %s\n' "${failures[@]}"
        fi
        [[ -n "$CSV_OUT" ]] && echo "Results written to $CSV_OUT"
    fi
    return 0
}

main "$@"
