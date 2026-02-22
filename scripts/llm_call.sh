#!/usr/bin/env bash
set -euo pipefail

command -v jq >/dev/null || { echo "Error: jq required" >&2; exit 1; }

# ── Defaults ──────────────────────────────────────────────────────────────────
LLM_PROVIDER="${LLM_PROVIDER:-anthropic}"
LLM_MODEL="${LLM_MODEL:-claude-3-5-haiku-20241022}"
LLM_MAX_TOKENS="${LLM_MAX_TOKENS:-4096}"
LLM_TIMEOUT="${LLM_TIMEOUT:-30}"
MAX_PROMPT_CHARS=150000

case "$LLM_PROVIDER" in
  anthropic|openai)
    if [[ -z "${LLM_API_KEY:-}" ]]; then
      echo "Error: LLM_API_KEY not set" >&2
      exit 1
    fi
    ;;
  gcp)
    _GCLOUD=$(command -v gcloud 2>/dev/null \
      || ls "$HOME/google-cloud-sdk/bin/gcloud" 2>/dev/null \
      || ls /usr/lib/google-cloud-sdk/bin/gcloud 2>/dev/null \
      || ls /opt/google-cloud-sdk/bin/gcloud 2>/dev/null)
    if [[ -z "$_GCLOUD" ]]; then
      echo "Error: gcloud CLI not found. Install Google Cloud SDK or add it to PATH." >&2
      exit 1
    fi
    ;;
  *)
    echo "Error: Unknown provider '$LLM_PROVIDER'. Use 'anthropic', 'openai', or 'gcp'" >&2
    exit 1
    ;;
esac

# ── Read and truncate prompt from stdin ───────────────────────────────────────
prompt=$(cat)
if (( ${#prompt} > MAX_PROMPT_CHARS )); then
  echo "Warning: prompt truncated from ${#prompt} to $MAX_PROMPT_CHARS chars" >&2
  prompt="${prompt:0:$MAX_PROMPT_CHARS}"
fi

_build_body() {
  printf '%s' "$prompt" | python3 -c "
import sys, json
provider = sys.argv[1]
model = sys.argv[2]
max_tokens = int(sys.argv[3])
prompt = sys.stdin.read()
if provider == 'gcp':
    body = {
        'anthropic_version': 'vertex-2023-10-16',
        'max_tokens': max_tokens,
        'stream': False,
        'messages': [{'role': 'user', 'content': prompt}]
    }
else:
    body = {
        'model': model,
        'max_tokens': max_tokens,
        'messages': [{'role': 'user', 'content': prompt}]
    }
print(json.dumps(body))
" "$LLM_PROVIDER" "$LLM_MODEL" "$LLM_MAX_TOKENS"
}

BODY_FILE=$(mktemp /tmp/llm_body.XXXXXX)
RESP_FILE=$(mktemp /tmp/llm_resp.XXXXXX)
trap 'rm -f "$BODY_FILE" "$RESP_FILE"' EXIT

_build_body > "$BODY_FILE"

# ── curl wrapper: returns http_code, writes body to RESP_FILE ─────────────────
_curl_llm() {
  local url="$1"; shift
  curl -s --max-time "$LLM_TIMEOUT" \
    -o "$RESP_FILE" -w "%{http_code}" \
    -X POST "$url" \
    "$@" \
    -d @"$BODY_FILE"
}

# ── Provider-specific call ────────────────────────────────────────────────────
_call_api() {
  case "$LLM_PROVIDER" in
    anthropic)
      _curl_llm "https://api.anthropic.com/v1/messages" \
        -H "x-api-key: $LLM_API_KEY" \
        -H "anthropic-version: 2023-06-01" \
        -H "content-type: application/json"
      ;;
    openai)
      _curl_llm "https://api.openai.com/v1/chat/completions" \
        -H "Authorization: Bearer $LLM_API_KEY" \
        -H "content-type: application/json"
      ;;
    gcp)
      local gcp_project="${CFG_GCP_PROJECT:-}"
      local gcp_region="${CFG_GCP_REGION:-global}"
      local gcp_model="${LLM_MODEL:-claude-sonnet-4-6}"

      if [[ -z "$gcp_project" ]]; then
        gcp_project=$(gcloud config get-value project 2>/dev/null)
        if [[ -z "$gcp_project" ]]; then
          echo "Error: GCP project not set. Configure gcp.project_id in local.toml or run: gcloud config set project PROJECT_ID" >&2
          return 1
        fi
      fi

      local token_cmd="$_GCLOUD auth print-access-token"
      [[ "${CFG_GCP_USE_ADC:-false}" == "true" ]] && token_cmd="$_GCLOUD auth application-default print-access-token"
      local gcp_token
      gcp_token=$($token_cmd 2>/dev/null)
      if [[ -z "$gcp_token" ]]; then
        echo "Error: Could not get gcloud access token. Run: gcloud auth login" >&2
        return 1
      fi

      local endpoint
      if [[ "$gcp_region" == "global" ]]; then
        endpoint="https://global-aiplatform.googleapis.com/v1/projects/${gcp_project}/locations/global/publishers/anthropic/models/${gcp_model}:streamRawPredict"
      else
        endpoint="https://${gcp_region}-aiplatform.googleapis.com/v1/projects/${gcp_project}/locations/${gcp_region}/publishers/anthropic/models/${gcp_model}:streamRawPredict"
      fi

      _curl_llm "$endpoint" \
        -H "Authorization: Bearer $gcp_token" \
        -H "content-type: application/json"
      ;;
  esac
}

# ── Extract text from response JSON ──────────────────────────────────────────
_extract_content() {
  case "$LLM_PROVIDER" in
    anthropic|gcp) jq -r '.content[0].text' < "$RESP_FILE" ;;
    openai)        jq -r '.choices[0].message.content' < "$RESP_FILE" ;;
  esac
}

# ── Main request loop with retry logic ────────────────────────────────────────
rate_limit_attempts=0
server_retried=false
network_retried=false

while true; do
  http_code=0
  curl_exit=0
  http_code=$(_call_api) || curl_exit=$?

  # Network/timeout error (curl non-zero exit)
  if (( curl_exit != 0 )); then
    if [[ "$network_retried" == false ]]; then
      network_retried=true
      echo "Network error, retrying..." >&2
      sleep 1
      continue
    fi
    echo "Network error: curl failed" >&2
    exit 1
  fi

  # HTTP 429 — rate limit: retry 3x with exponential backoff
  if [[ "$http_code" == "429" ]]; then
    rate_limit_attempts=$((rate_limit_attempts + 1))
    if (( rate_limit_attempts > 3 )); then
      echo "Rate limit hit, giving up" >&2
      exit 1
    fi
    local_sleep=$((1 << (rate_limit_attempts - 1)))
    echo "Rate limited (429), retry $rate_limit_attempts/3 in ${local_sleep}s..." >&2
    sleep "$local_sleep"
    continue
  fi

  # HTTP 401/403 — auth error
  if [[ "$http_code" == "401" || "$http_code" == "403" ]]; then
    echo "Invalid API key (HTTP $http_code)" >&2
    exit 1
  fi

  # HTTP 5xx — server error: retry once after 2s
  if [[ "$http_code" =~ ^5[0-9][0-9]$ ]]; then
    if [[ "$server_retried" == false ]]; then
      server_retried=true
      echo "Server error ($http_code), retrying in 2s..." >&2
      sleep 2
      continue
    fi
    echo "LLM service unavailable (HTTP $http_code)" >&2
    exit 1
  fi

  # Success path (2xx)
  break
done

# ── Extract and validate response content ────────────────────────────────────
content=$(_extract_content 2>/dev/null) || content=""

if [[ -z "$content" || "$content" == "null" ]]; then
  echo "--- Raw LLM response ---" >&2
  cat "$RESP_FILE" >&2
  echo "" >&2
  echo "LLM returned empty response" >&2
  exit 1
fi

printf '%s\n' "$content"
