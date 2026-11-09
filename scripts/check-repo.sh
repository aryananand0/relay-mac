#!/bin/zsh
# Fast repository checks, shared by the pre-commit hook and CI:
#   - no secrets (private keys, common API-token formats)
#   - no personal machine paths (/Users/<name>/…) or real pairing links (#k=<code>)
#   - no files that must never be committed (.env, keys, certificates, logs, pairing codes)
#   - the phone page's scripts parse
# Usage: scripts/check-repo.sh            all tracked files
#        scripts/check-repo.sh --staged   only what's staged for the next commit
set -uo pipefail
cd "${0:A:h}/.."

if [[ "${1:-}" == "--staged" ]]; then
  files=("${(@f)$(git diff --cached --name-only --diff-filter=ACMR)}")
  read_file() { git show ":$1" 2>/dev/null; }
else
  files=("${(@f)$(git ls-files)}")
  read_file() { cat -- "$1" 2>/dev/null; }
fi

patterns=(
  'BEGIN [A-Z ]*PRIVATE KEY'           # private keys
  'AKIA[0-9A-Z]{16}'                   # AWS access keys
  'gh[pousr]_[A-Za-z0-9]{30,}'         # GitHub tokens
  'sk-[A-Za-z0-9_-]{20,}'              # OpenAI / Anthropic-style keys
  'xox[abpr]-[A-Za-z0-9-]{10,}'        # Slack tokens
  'AIza[0-9A-Za-z_-]{35}'              # Google API keys
  '/Users/[A-Za-z0-9._-]+/'            # personal home-folder paths
  '#k=[A-HJ-NP-Z2-9]{8,}'              # a real pairing link
)

fail=0
for f in $files; do
  [[ -n "$f" ]] || continue
  case "$f" in
    .env.example) ;;
    .env|.env.*|*.pem|*.p12|*.p8|*.key|*.cer|*.mobileprovision|*.provisionprofile|*.log|*pairing-code*)
      print -u2 "check-repo: $f must not be committed"; fail=1; continue ;;
  esac
  [[ "$f" == scripts/check-repo.sh ]] && continue   # the patterns themselves live here
  content="$(read_file "$f")" || continue
  [[ "$content" == *$'\0'* ]] && continue           # skip binary files
  for p in $patterns; do
    if print -r -- "$content" | grep -qE -- "$p"; then
      print -u2 "check-repo: $f matches a secret/personal-data pattern ($p)"; fail=1
    fi
  done
done

if command -v node >/dev/null; then
  for js in web/relay.js web/crypto.js; do node --check "$js" || fail=1; done
fi

(( fail )) && { print -u2 "check-repo: failed (see AGENTS.md)"; exit 1; }
echo "check-repo: OK"
