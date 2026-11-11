#!/usr/bin/env bash
# Creates or updates the Azure AI Search objects (data source, index, skillset, indexer, knowledge source,
# knowledge base) from templates/*.json, in name order. Safe to re-run: each object is PUT.
#
#   ./provision.sh             create or update
#   ./provision.sh --fresh     delete the objects first (needed when an index field or the vector size changes)
#   ./provision.sh --dry-run   print the filled JSON instead of calling Azure
#
# Settings come from the environment, or from a .env file next to this script (see .env.example).
set -euo pipefail
shopt -u patsub_replacement 2>/dev/null || true # Bash 5.2+: keep "&" literal in replacements

cd "$(dirname "$0")"
if [[ -f .env ]]; then set -a; source .env; set +a; fi

FRESH=false
DRY_RUN=false
for arg in "$@"; do
    case "$arg" in
        --fresh) FRESH=true ;;
        --dry-run) DRY_RUN=true ;;
        *) echo "Unknown option: $arg" >&2; exit 2 ;;
    esac
done

API_VERSION="${AZURE_SEARCH_API_VERSION:-2025-11-01-preview}"
AZURE_AI_SERVICES_KEY="${AZURE_AI_SERVICES_KEY:-${AZURE_OPENAI_KEY:-}}"
RETRIEVAL_INSTRUCTIONS="${RETRIEVAL_INSTRUCTIONS:-Describe your documents here: their types, languages, and how questions are asked.}"
# The indexer reads Blob from inside Azure: with the Search managed identity when the resource ID is set, else with the account key
if [[ -n "${AZURE_STORAGE_RESOURCE_ID:-}" ]]; then
    DATASOURCE_CONNECTION_STRING="ResourceId=${AZURE_STORAGE_RESOURCE_ID};"
else
    DATASOURCE_CONNECTION_STRING="${AZURE_STORAGE_CONNECTION_STRING:-}"
fi

placeholders=(APP AZURE_STORAGE_CONTAINER AZURE_OPENAI_RESOURCE_URL AZURE_OPENAI_KEY AZURE_OPENAI_CHAT_DEPLOYMENT
    AZURE_OPENAI_EMBEDDING_DEPLOYMENT AZURE_AI_SERVICES_URL AZURE_AI_SERVICES_KEY RETRIEVAL_INSTRUCTIONS)
required=("${placeholders[@]}" DATASOURCE_CONNECTION_STRING)
$DRY_RUN || required+=(AZURE_SEARCH_ENDPOINT AZURE_SEARCH_KEY)
missing=()
for name in "${required[@]}"; do [[ -n "${!name:-}" ]] || missing+=("$name"); done
if ((${#missing[@]})); then
    echo "Missing settings: ${missing[*]} (DATASOURCE_CONNECTION_STRING comes from AZURE_STORAGE_RESOURCE_ID or AZURE_STORAGE_CONNECTION_STRING)" >&2
    exit 1
fi

# Values go inside JSON strings: escape backslashes, quotes and control characters
json_escape() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//$'\n'/\\n}"
    value="${value//$'\r'/\\r}"
    value="${value//$'\t'/\\t}"
    printf '%s' "$value"
}

fill() {
    local content name
    content="$(cat "$1")"
    for name in "${placeholders[@]}"; do
        content="${content//"{{$name}}"/$(json_escape "${!name}")}"
    done
    content="${content//"{{AZURE_STORAGE_CONNECTION_STRING}}"/$(json_escape "$DATASOURCE_CONNECTION_STRING")}"
    printf '%s\n' "$content"
}

collection_of() {
    case "$(basename "$1" .json | sed -E 's/^[0-9]+-//')" in
        datasource) echo datasources ;;
        index) echo indexes ;;
        skillset) echo skillsets ;;
        indexer) echo indexers ;;
        knowledge-source) echo knowledgesources ;;
        knowledge-base) echo knowledgebases ;;
        *) echo "Unknown template: $1" >&2; exit 1 ;;
    esac
}

name_of() { # The object's name: the first "name" in the filled JSON
    sed -nE 's/^ *"name": *"([^"]+)".*/\1/p' <<<"$1" | head -1
}

search() { # method, path [, body]: prints the HTTP status, keeps the response body in $response_file
    curl -sS -o "$response_file" -w '%{http_code}' -X "$1" "${AZURE_SEARCH_ENDPOINT%/}/$2?api-version=${API_VERSION}" \
        -H "api-key: ${AZURE_SEARCH_KEY}" -H "Content-Type: application/json" -H "Prefer: return=representation" \
        ${3:+--data-binary "$3"}
}

response_file="$(mktemp)"
trap 'rm -f "$response_file"' EXIT
templates=(templates/*.json)

if $DRY_RUN; then
    for template in "${templates[@]}"; do
        echo "### $(collection_of "$template") ($template)"
        fill "$template"
    done
    exit 0
fi

if $FRESH; then
    for ((i = ${#templates[@]} - 1; i >= 0; i--)); do
        body="$(fill "${templates[i]}")"
        target="$(collection_of "${templates[i]}")('$(name_of "$body")')"
        status="$(search DELETE "$target")"
        echo "$target: $([[ $status == 404 ]] && echo 'not there' || echo "deleted ($status)")"
    done
fi

for template in "${templates[@]}"; do
    body="$(fill "$template")"
    target="$(collection_of "$template")('$(name_of "$body")')"
    status="$(search PUT "$target" "$body")"
    if [[ $status != 2* ]]; then
        echo "$target: failed ($status)" >&2
        cat "$response_file" >&2; echo >&2
        exit 1
    fi
    echo "$target: $([[ $status == 201 ]] && echo created || echo updated)"
done
