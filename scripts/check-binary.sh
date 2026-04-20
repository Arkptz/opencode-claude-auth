#!/usr/bin/env bash
# check-binary.sh — Compare opencode-claude-auth values against the installed Claude Code binary.
# Run after every Claude Code update to see what changed and what needs syncing.
#
# Usage:
#   ./scripts/check-binary.sh                  # auto-detect binary
#   ./scripts/check-binary.sh /path/to/binary  # explicit binary path
#
set -euo pipefail

# ─── Locate binary ───────────────────────────────────────────────────
if [[ -n "${1:-}" ]]; then
  BIN="$1"
else
  CLAUDE_PATH="$(which claude 2>/dev/null || true)"
  if [[ -z "$CLAUDE_PATH" ]]; then
    echo "ERROR: 'claude' not found in PATH. Provide binary path as argument." >&2
    exit 1
  fi
  # Resolve nix symlinks: claude → .claude-wrapped (the actual ELF)
  CLAUDE_DIR="$(dirname "$(readlink -f "$CLAUDE_PATH")")"
  if [[ -f "$CLAUDE_DIR/.claude-wrapped" ]]; then
    BIN="$CLAUDE_DIR/.claude-wrapped"
  else
    BIN="$(readlink -f "$CLAUDE_PATH")"
  fi
fi

if [[ ! -f "$BIN" ]]; then
  echo "ERROR: Binary not found: $BIN" >&2
  exit 1
fi

echo "═══════════════════════════════════════════════════════"
echo "  Claude Code Binary Audit"
echo "  Binary: $BIN"
echo "  Date:   $(date -Iseconds)"
echo "═══════════════════════════════════════════════════════"
echo

# ─── Helpers ─────────────────────────────────────────────────────────
GREEN='\033[32m'
RED='\033[31m'
YELLOW='\033[33m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

ok()   { echo -e "  ${GREEN}✓${RESET} $1"; }
warn() { echo -e "  ${YELLOW}⚠${RESET} $1"; }
fail() { echo -e "  ${RED}✗${RESET} $1"; }
dim()  { echo -e "  ${DIM}$1${RESET}"; }
hdr()  { echo -e "\n${BOLD}── $1 ──${RESET}"; }

# ─── 1. CLI version ─────────────────────────────────────────────────
hdr "CLI Version"
BIN_VERSION=$(claude --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "unknown")
PLUGIN_VERSION=$(grep -oP 'ccVersion:\s*"([^"]+)"' src/model-config.ts | grep -oP '"[^"]+"' | tr -d '"')
echo "  Binary:  $BIN_VERSION"
echo "  Plugin:  $PLUGIN_VERSION (ccVersion in model-config.ts)"
if [[ "$BIN_VERSION" == "$PLUGIN_VERSION" ]]; then
  ok "Versions match"
else
  fail "VERSION MISMATCH — update ccVersion in src/model-config.ts to \"$BIN_VERSION\""
fi

# ─── 2. Beta flags ──────────────────────────────────────────────────
hdr "Beta Flags (date-suffixed)"
echo "  Binary contains:"
BIN_BETAS=$(strings -n 15 "$BIN" | grep -E '^[a-z][-a-z]+-20[0-9]{2}-[0-9]{2}-[0-9]{2}$' | sort -u)
echo "$BIN_BETAS" | while read -r b; do dim "  $b"; done

echo
echo "  Plugin baseBetas (model-config.ts):"
PLUGIN_BETAS=$(grep -A 20 'baseBetas:' src/model-config.ts | grep -oP '"([^"]+)"' | tr -d '"')
echo "$PLUGIN_BETAS" | while read -r b; do dim "  $b"; done

echo
echo "  Comparison:"
for beta in $PLUGIN_BETAS; do
  if echo "$BIN_BETAS" | grep -qF "$beta"; then
    ok "$beta — present in binary"
  else
    fail "$beta — NOT FOUND in binary (may have been removed)"
  fi
done
# Check for betas in binary that we don't have
for beta in $BIN_BETAS; do
  if ! echo "$PLUGIN_BETAS" | grep -qF "$beta"; then
    # Only flag the ones that look relevant to Claude Code API
    case "$beta" in
      claude-code-*|oauth-*|interleaved-thinking-*|prompt-caching-*|context-*|effort-*)
        warn "$beta — in binary but NOT in plugin baseBetas"
        ;;
    esac
  fi
done

# ─── 3. Billing salt ────────────────────────────────────────────────
hdr "Billing Salt"
PLUGIN_SALT=$(grep -oP 'BILLING_SALT\s*=\s*"([^"]+)"' src/signing.ts | grep -oP '"[^"]+"' | tr -d '"')
SALT_COUNT=$(strings -n 8 "$BIN" | grep -c "$PLUGIN_SALT" || true)
echo "  Plugin salt: $PLUGIN_SALT"
echo "  Occurrences in binary: $SALT_COUNT"
if [[ "$SALT_COUNT" -gt 0 ]]; then
  ok "Billing salt is still valid"
else
  fail "Billing salt NOT FOUND — needs updating!"
fi

# ─── 4. Version suffix sampling indices ─────────────────────────────
hdr "Version Suffix Sampling Indices [4,7,20]"
INDICES_COUNT=$(python3 -c "
with open('$BIN', 'rb') as f:
    data = f.read()
print(data.count(b'[4,7,20]'))
" 2>/dev/null || echo "0")
echo "  Occurrences of [4,7,20] in binary: $INDICES_COUNT"
if [[ "$INDICES_COUNT" -gt 0 ]]; then
  ok "Sampling indices unchanged"
else
  fail "Sampling indices NOT FOUND — algorithm may have changed!"
fi

# ─── 5. CCH / xxHash64 seed ─────────────────────────────────────────
hdr "CCH Hash (xxHash64)"
PLUGIN_SEED=$(grep -oP 'CCH_SEED\s*=\s*(0x[0-9a-fA-F]+)' src/xxhash64.ts | grep -oP '0x[0-9a-fA-F]+')
echo "  Plugin CCH_SEED: $PLUGIN_SEED"
echo "  cch=00000 placeholder in binary: $(strings -n 8 "$BIN" | grep -c 'cch=00000' || true) occurrences"
echo "  Bun.hash references: $(python3 -c "
with open('$BIN', 'rb') as f:
    print(f.read().count(b'Bun.hash('))
" 2>/dev/null || echo "?")"
echo "  xxhash references: $(python3 -c "
with open('$BIN', 'rb') as f:
    data = f.read()
    print(f'xxhash={data.count(b\"xxhash\")} xxHash64={data.count(b\"xxHash64\")} wyhash={data.count(b\"wyhash\")}')
" 2>/dev/null || echo "?")"
dim "Note: Seed is embedded as Bun native — not directly extractable as string."
dim "Use 'pnpm run extract:cch' to verify against live CLI if needed."

# ─── 6. OAuth client ID ─────────────────────────────────────────────
hdr "OAuth Client ID"
PLUGIN_CLIENT_ID=$(grep -oP 'OAUTH_CLIENT_ID\s*=\s*"([^"]+)"' src/credentials.ts | grep -oP '"[^"]+"' | tr -d '"')
CLIENT_ID_COUNT=$(strings -n 20 "$BIN" | grep -c "$PLUGIN_CLIENT_ID" || true)
echo "  Plugin: $PLUGIN_CLIENT_ID"
echo "  In binary: $CLIENT_ID_COUNT occurrences"
if [[ "$CLIENT_ID_COUNT" -gt 0 ]]; then
  ok "OAuth client ID matches"
else
  fail "OAuth client ID NOT FOUND — may have changed!"
fi

# ─── 7. OAuth token endpoint ────────────────────────────────────────
hdr "OAuth Token Endpoint"
PLUGIN_ENDPOINT=$(grep -oP 'OAUTH_TOKEN_URL\s*=\s*"([^"]+)"' src/credentials.ts | grep -oP '"[^"]+"' | tr -d '"')
ENDPOINT_COUNT=$(strings -n 10 "$BIN" | grep -cF "$(echo "$PLUGIN_ENDPOINT" | sed 's|https://||')" || true)
echo "  Plugin: $PLUGIN_ENDPOINT"
echo "  Fragments in binary: $ENDPOINT_COUNT"
if [[ "$ENDPOINT_COUNT" -gt 0 ]]; then
  ok "OAuth endpoint still valid"
else
  warn "OAuth endpoint not confirmed in binary strings (may be obfuscated)"
fi

# ─── 8. System identity prompt ──────────────────────────────────────
hdr "System Identity Prompt"
IDENTITY="You are Claude Code, Anthropic's official CLI for Claude."
IDENTITY_COUNT=$(strings -n 30 "$BIN" | grep -cF "$IDENTITY" || true)
echo "  Identity string: \"$IDENTITY\""
echo "  In binary: $IDENTITY_COUNT occurrences"
if [[ "$IDENTITY_COUNT" -gt 0 ]]; then
  ok "System identity string unchanged"
else
  fail "System identity string NOT FOUND — may have changed!"
fi

# ─── 9. API version ─────────────────────────────────────────────────
hdr "API Version"
API_VER="2023-06-01"
API_VER_COUNT=$(strings -n 8 "$BIN" | grep -c "^${API_VER}$" || true)
echo "  Plugin: $API_VER"
echo "  In binary: $API_VER_COUNT occurrences"
if [[ "$API_VER_COUNT" -gt 0 ]]; then
  ok "anthropic-version header unchanged"
else
  fail "anthropic-version NOT FOUND — check if it changed!"
fi

# ─── 10. Billing header format ──────────────────────────────────────
hdr "Billing Header Format"
echo "  Format markers in binary:"
for marker in "x-anthropic-billing-header" "cc_version=" "cc_entrypoint=" "cch=00000" "cc_workload="; do
  COUNT=$(strings -n 8 "$BIN" | grep -cF "$marker" || true)
  if [[ "$COUNT" -gt 0 ]]; then
    ok "$marker — $COUNT occurrences"
  else
    if [[ "$marker" == "cc_workload=" ]]; then
      dim "$marker — $COUNT (optional, only in new versions)"
    else
      fail "$marker — NOT FOUND"
    fi
  fi
done

# ─── 11. New betas not in plugin ────────────────────────────────────
hdr "Potentially Relevant New Betas (in binary, not in plugin)"
ALL_PLUGIN_BETAS=$(grep -oP '"[a-z][-a-z]+-20[0-9]{2}-[0-9]{2}-[0-9]{2}"' src/model-config.ts src/betas.ts 2>/dev/null | grep -oP '"[^"]+"' | tr -d '"' | sort -u)
NEW_BETAS=()
for beta in $BIN_BETAS; do
  if ! echo "$ALL_PLUGIN_BETAS" | grep -qF "$beta"; then
    case "$beta" in
      claude-code-*|oauth-*|interleaved-thinking-*|prompt-caching-*|context-*|effort-*)
        NEW_BETAS+=("$beta")
        ;;
    esac
  fi
done
if [[ ${#NEW_BETAS[@]} -eq 0 ]]; then
  ok "No new relevant betas found"
else
  for b in "${NEW_BETAS[@]}"; do
    warn "NEW: $b"
  done
fi

# ─── 12. Model alias map ────────────────────────────────────────────
hdr "Default Model Aliases (from binary)"
echo "  Nw6 map in binary (last known):"
for alias_search in 'opus.*claude-opus' 'sonnet.*claude-sonnet' 'haiku.*claude-haiku'; do
  ALIAS=$(strings -n 10 "$BIN" | grep -oP "${alias_search}[\"'\w.-]*" | head -1 || true)
  if [[ -n "$ALIAS" ]]; then
    dim "$ALIAS"
  fi
done
echo "  Direct search:"
strings -n 10 "$BIN" | grep -E '"(opus|sonnet|haiku)":"claude-' | head -5 | while read -r line; do dim "$line"; done

# ─── Summary ─────────────────────────────────────────────────────────
echo
echo "═══════════════════════════════════════════════════════"
echo "  Audit complete. Review ⚠ and ✗ items above."
echo "═══════════════════════════════════════════════════════"
