#!/usr/bin/env bash
# Mint a notchmeet setup code that carries a Deepgram + LLM key in a single paste.
#
#   scripts/mint-code.sh <DEEPGRAM_KEY> <LLM_KEY> [gemini|claude]
#
# Output is one line: nmk1.<base64url(JSON)>. DM that line to a trial user; they paste it into the
# onboarding key field and the app fills both keys for them (see Sources/notchmeet/Core/SetupCode.swift).
#
# The code IS the keys — there is no server. Hand out only SCOPED, TIME-LIMITED, SPEND-CAPPED keys,
# one per recipient: a Deepgram key with a TTL, and an LLM key in a project/workspace with a hard cap.
set -euo pipefail

if [ "$#" -lt 2 ]; then
  echo "usage: $0 <DEEPGRAM_KEY> <LLM_KEY> [gemini|claude]" >&2
  exit 1
fi

dg="$1"
llm="$2"
provider="${3:-gemini}"
case "$provider" in
  gemini) llm_name="GEMINI_API_KEY" ;;
  claude) llm_name="ANTHROPIC_API_KEY" ;;
  *) echo "provider must be 'gemini' or 'claude' (got: $provider)" >&2; exit 1 ;;
esac

json=$(printf '{"DEEPGRAM_API_KEY":"%s","%s":"%s"}' "$dg" "$llm_name" "$llm")
printf 'nmk1.%s\n' "$(printf '%s' "$json" | base64 | tr '+/' '-_' | tr -d '=\n')"
