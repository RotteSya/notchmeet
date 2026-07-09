#!/usr/bin/env bash
# Mint a NotchMeet setup code that carries a Deepgram + LLM key in a single paste.
#
#   scripts/mint-code.sh <DEEPGRAM_KEY> <LLM_KEY> [gemini|claude|deepseek|qwen]
#
# Pass `-` as DEEPGRAM_KEY to omit it — 国内试用者走 Apple 端侧 STT，不需要 Deepgram，
# 只发一个域内 LLM key（deepseek/qwen）即可。
#
# Output is one line: nmk1.<base64url(JSON)>. DM that line to a trial user; they paste it into the
# onboarding key field and the app fills both keys for them (see Sources/NotchMeet/Core/SetupCode.swift).
#
# The code IS the keys — there is no server. Hand out only SCOPED, TIME-LIMITED, SPEND-CAPPED keys,
# one per recipient: a Deepgram key with a TTL, and an LLM key in a project/workspace with a hard cap.
set -euo pipefail

if [ "$#" -lt 2 ]; then
  echo "usage: $0 <DEEPGRAM_KEY|-> <LLM_KEY> [gemini|claude|deepseek|qwen]" >&2
  exit 1
fi

dg="$1"
llm="$2"
provider="${3:-gemini}"
case "$provider" in
  gemini) llm_name="GEMINI_API_KEY" ;;
  claude) llm_name="ANTHROPIC_API_KEY" ;;
  deepseek) llm_name="DEEPSEEK_API_KEY" ;;
  qwen) llm_name="DASHSCOPE_API_KEY" ;;
  *) echo "provider must be gemini|claude|deepseek|qwen (got: $provider)" >&2; exit 1 ;;
esac

if [ "$dg" = "-" ]; then
  json=$(printf '{"%s":"%s"}' "$llm_name" "$llm")
else
  json=$(printf '{"DEEPGRAM_API_KEY":"%s","%s":"%s"}' "$dg" "$llm_name" "$llm")
fi
printf 'nmk1.%s\n' "$(printf '%s' "$json" | base64 | tr '+/' '-_' | tr -d '=\n')"
