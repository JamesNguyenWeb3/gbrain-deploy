#!/usr/bin/env bash
# ==============================================================================
# Configure GBrain for 100% OpenRouter + System One / Jev
#
# Idempotent setup script that wires:
#   1. File-plane embedding & chat models (`openrouter:...`)
#   2. DB-plane model tiers (utility, reasoning, deep, subagent, dream, facts)
#   3. Cross-encoder reranker via OpenRouter (`openrouter:cohere/rerank-v3.5`)
#      or TypeSafe Jev (`typesafe:jev-1.13.0`)
#   4. Operator price overrides (`gbrain pricing set`) for OpenRouter models so
#      explicit cost caps (`--max-usd`, spend budgets) never fail with `no_pricing`
#   5. System One / Jev decision layer (`decide.*`) via TypeSafe API key or
#      OpenRouter LLM fallback
# ==============================================================================
set -euo pipefail

GBRAIN="/usr/local/bin/gbrain-run"

echo "[openrouter-config] Applying OpenRouter model, reranker, pricing, and System One configuration..."

# 1. Model selections (override via env vars if desired)
EMB_MODEL="${GBRAIN_EMBEDDING_MODEL:-openrouter:openai/text-embedding-3-small}"
EMB_DIMS="${GBRAIN_EMBEDDING_DIMENSIONS:-1536}"
UTILITY_MODEL="${GBRAIN_TIER_UTILITY_MODEL:-openrouter:anthropic/claude-haiku-4.5}"
REASONING_MODEL="${GBRAIN_TIER_REASONING_MODEL:-openrouter:anthropic/claude-sonnet-4.6}"
DEEP_MODEL="${GBRAIN_TIER_DEEP_MODEL:-openrouter:anthropic/claude-opus-4.7}"
# Note: OpenRouter subagent loop requires anthropic/* or deepseek/* family
# (see src/core/ai/openrouter-families.ts)
SUBAGENT_MODEL="${GBRAIN_TIER_SUBAGENT_MODEL:-openrouter:anthropic/claude-sonnet-4.6}"
EXPANSION_MODEL="${GBRAIN_EXPANSION_MODEL:-openrouter:google/gemini-3-flash-preview}"
RERANK_MODEL="${GBRAIN_RERANKER_MODEL:-openrouter:cohere/rerank-v3.5}"
SEARCH_MODE="${GBRAIN_SEARCH_MODE:-balanced}"

# 2. Core file/DB model settings
# Note: `embedding_model` and `embedding_dimensions` are file-plane schema-sizing
# fields written to config.json at `gbrain init` time (and refused by `config set`).
CONFIG_JSON="${GBRAIN_HOME:-/srv/gbrain}/.gbrain/config.json"
if [[ -f "${CONFIG_JSON}" ]] && command -v jq >/dev/null 2>&1; then
  CURRENT_EMB="$(jq -r '.embedding_model // empty' "${CONFIG_JSON}")"
  if [[ -n "${CURRENT_EMB}" && "${CURRENT_EMB}" != "${EMB_MODEL}" ]]; then
    echo "[openrouter-config] NOTE: config.json uses embedding_model=${CURRENT_EMB} (env requests ${EMB_MODEL})."
    echo "[openrouter-config] To switch embedding models safely, run: gbrain-run migrate embeddings --to ${EMB_MODEL} --dim ${EMB_DIMS} --dry-run"
  fi
  # Set query instruction prefix in config.json if using Qwen3 embeddings
  if [[ "${EMB_MODEL}" == *"qwen3-embedding"* ]]; then
    TMP_CFG="$(mktemp)"
    jq '.embedding_query_prefix = "Instruct: Given a web search query, retrieve relevant passages that answer the query\nQuery:"' "${CONFIG_JSON}" > "${TMP_CFG}" && mv "${TMP_CFG}" "${CONFIG_JSON}"
    chmod 600 "${CONFIG_JSON}" || true
  fi
fi

"${GBRAIN}" config set expansion_model "${EXPANSION_MODEL}"
"${GBRAIN}" config set chat_model "${REASONING_MODEL}"

# 3. Model tiers & task-specific pins
"${GBRAIN}" config set models.default "${REASONING_MODEL}"
"${GBRAIN}" config set models.tier.utility "${UTILITY_MODEL}"
"${GBRAIN}" config set models.tier.reasoning "${REASONING_MODEL}"
"${GBRAIN}" config set models.tier.deep "${DEEP_MODEL}"
"${GBRAIN}" config set models.tier.subagent "${SUBAGENT_MODEL}"
"${GBRAIN}" config set models.subagent "${SUBAGENT_MODEL}"
"${GBRAIN}" config set models.chat "${REASONING_MODEL}"
"${GBRAIN}" config set models.think "${REASONING_MODEL}"
"${GBRAIN}" config set models.expansion "${EXPANSION_MODEL}"
"${GBRAIN}" config set models.dream.triage "${UTILITY_MODEL}"
"${GBRAIN}" config set models.dream.synthesize "${REASONING_MODEL}"
"${GBRAIN}" config set models.dream.extract_atoms "${UTILITY_MODEL}"
"${GBRAIN}" config set models.dream.patterns "${REASONING_MODEL}"
"${GBRAIN}" config set models.fence_repair "${DEEP_MODEL}"
"${GBRAIN}" config set facts.extraction_model "${UTILITY_MODEL}"
"${GBRAIN}" config set agent.use_gateway_loop true

# 4. Search mode & Reranker
# OpenRouter natively proxies Cohere & NVIDIA rerankers at /api/v1/rerank:
#   - openrouter:cohere/rerank-v3.5
#   - openrouter:cohere/rerank-4-fast
#   - openrouter:cohere/rerank-4-pro
#   - openrouter:nvidia/llama-nemotron-rerank-vl-1b-v2:free
"${GBRAIN}" config set search.mode "${SEARCH_MODE}"
"${GBRAIN}" config set search.reranker.model "${RERANK_MODEL}"
"${GBRAIN}" config set search.reranker.enabled true

# 5. Register OpenRouter model prices (`pricing.overrides`)
# OpenRouter models are declared in `unpriced_models` in src/core/ai/recipes/openrouter.ts.
# Registering their per-1M-token rates allows explicit USD budget gates to meter accurately.
"${GBRAIN}" pricing set openrouter:anthropic/claude-haiku-4.5 --input 1.00 --output 5.00 --source https://openrouter.ai/models >/dev/null
"${GBRAIN}" pricing set openrouter:anthropic/claude-sonnet-4.6 --input 3.00 --output 15.00 --source https://openrouter.ai/models >/dev/null
"${GBRAIN}" pricing set openrouter:anthropic/claude-opus-4.7 --input 5.00 --output 25.00 --source https://openrouter.ai/models >/dev/null
"${GBRAIN}" pricing set openrouter:google/gemini-3-flash-preview --input 0.15 --output 0.60 --source https://openrouter.ai/models >/dev/null
"${GBRAIN}" pricing set openrouter:deepseek/deepseek-chat --input 0.27 --output 1.10 --source https://openrouter.ai/models >/dev/null
"${GBRAIN}" pricing set openrouter:openai/gpt-5.2 --input 2.50 --output 10.00 --source https://openrouter.ai/models >/dev/null
"${GBRAIN}" pricing set openrouter:openai/text-embedding-3-small --rate 0.02 --source https://openrouter.ai/models >/dev/null
"${GBRAIN}" pricing set openrouter:openai/text-embedding-3-large --rate 0.13 --source https://openrouter.ai/models >/dev/null
"${GBRAIN}" pricing set openrouter:cohere/rerank-v3.5 --rate 0.001 --source https://openrouter.ai/models >/dev/null
"${GBRAIN}" pricing set openrouter:cohere/rerank-4-fast --rate 0.001 --source https://openrouter.ai/models >/dev/null
"${GBRAIN}" pricing set openrouter:cohere/rerank-4-pro --rate 0.002 --source https://openrouter.ai/models >/dev/null

# 6. System One / Jev (`decide.*`) Configuration
DECIDE_FALLBACK="llm:${UTILITY_MODEL}"
"${GBRAIN}" config set decide.egress_fallback "${DECIDE_FALLBACK}"
"${GBRAIN}" config set decide.budget.daily_usd "${GBRAIN_DECIDE_DAILY_USD:-1.00}"

if [[ -n "${TYPESAFE_API_KEY:-${JEV_TYPESAFE_API_KEY:-}}" ]]; then
  echo "[openrouter-config] TYPESAFE_API_KEY detected — enabling System One (typesafe:jev-1.13.0)..."
  if [[ -n "${GBRAIN_TYPESAFE_BASE_URL:-}" ]]; then
    "${GBRAIN}" config set provider_base_urls.typesafe "${GBRAIN_TYPESAFE_BASE_URL}"
  fi
  if [[ "${GBRAIN_DECIDE_EGRESS_PRIVATE:-allow}" == "allow" ]]; then
    "${GBRAIN}" config set decide.egress.private allow
  fi
  "${GBRAIN}" decide enable --recommended --yes || true
  if [[ "${GBRAIN_DECIDE_ENABLE_RERANK:-0}" == "1" ]]; then
    "${GBRAIN}" decide enable rerank --yes || true
  fi
else
  echo "[openrouter-config] No TYPESAFE_API_KEY set — System One keeps OpenRouter egress_fallback (${DECIDE_FALLBACK})."
fi

# 7. Publish skills to MCP clients and set timezone if provided
"${GBRAIN}" config set mcp.publish_skills true
if [[ -n "${TZ:-}" ]]; then
  "${GBRAIN}" config set cycle.timezone "${TZ}" || true
fi

echo "[openrouter-config] Configuration complete."

