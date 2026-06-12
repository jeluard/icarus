#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: bash scripts/setup-gh-apple-secrets.sh [--repo owner/name] [--certificate-path path]

Discovers local Apple signing information when available, prompts for missing values,
and updates the GitHub Actions secrets used by the macOS release workflow.

Environment overrides:
  APPLE_SIGNING_IDENTITY
  APPLE_CERTIFICATE
  APPLE_CERTIFICATE_PASSWORD
  APPLE_ID
  APPLE_PASSWORD
  APPLE_TEAM_ID
EOF
}

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

extract_team_id_from_identity() {
  printf '%s\n' "$1" | sed -n 's/.*(\([A-Z0-9][A-Z0-9]*\)).*/\1/p'
}

extract_team_id_from_subject() {
  printf '%s\n' "$1" | sed -n \
    -e 's/^subject=.*OU=\([^,]*\).*/\1/p' \
    -e 's/^subject=.*OU = \([^,/]*\).*/\1/p' \
    -e 's/^subject=.*\/OU=\([^/]*\).*/\1/p' \
    -e 's/^subject=.*\/OU = \([^/]*\).*/\1/p' | head -n 1
}

resolve_repo_from_git() {
  local remote_url

  command -v git >/dev/null 2>&1 || return 0
  remote_url="$(git config --get remote.origin.url 2>/dev/null || true)"

  case "$remote_url" in
    https://github.com/*)
      remote_url="${remote_url#https://github.com/}"
      remote_url="${remote_url%.git}"
      printf '%s\n' "$remote_url"
      ;;
    git@github.com:*)
      remote_url="${remote_url#git@github.com:}"
      remote_url="${remote_url%.git}"
      printf '%s\n' "$remote_url"
      ;;
  esac
}

prompt_value() {
  local var_name="$1"
  local prompt_text="$2"
  local is_secret="${3:-0}"

  if [ -n "${!var_name:-}" ]; then
    return 0
  fi

  while :; do
    if [ "$is_secret" = "1" ]; then
      printf '%s: ' "$prompt_text" >&2
      IFS= read -r -s "$var_name"
      printf '\n' >&2
    else
      printf '%s: ' "$prompt_text" >&2
      IFS= read -r "$var_name"
    fi

    if [ -n "${!var_name:-}" ]; then
      return 0
    fi

    printf '%s\n' 'Value is required.' >&2
  done
}

AVAILABLE_CODESIGN_IDENTITY=""
CERTIFICATE_PATH=""
CERTIFICATE_SIGNING_IDENTITY=""
CERTIFICATE_TEAM_ID=""

select_signing_identity() {
  local identities=()
  local available_identities=()
  local line
  local choice
  local index=1

  while IFS= read -r line; do
    if [ -n "$line" ]; then
      identities+=("$line")
    fi
  done < <(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Developer ID Application: .* ([A-Z0-9][A-Z0-9]*)\)".*/\1/p')

  while IFS= read -r line; do
    if [ -n "$line" ]; then
      available_identities+=("$line")
    fi
  done < <(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(.*\)".*/\1/p')

  if [ "${#identities[@]}" -eq 0 ]; then
    printf '%s\n' 'No local Developer ID Application identity was found.' >&2
    if [ "${#available_identities[@]}" -gt 0 ]; then
      printf '%s\n' 'Available code-signing identities on this Mac:' >&2
      for line in "${available_identities[@]}"; do
        printf '  - %s\n' "$line" >&2
      done
      if [ "${#available_identities[@]}" -eq 1 ]; then
        AVAILABLE_CODESIGN_IDENTITY="${available_identities[0]}"
      fi
    else
      printf '%s\n' 'No local code-signing identities were found.' >&2
    fi
    printf '%s\n' 'The script will try to read the Developer ID Application identity from your .p12 certificate instead.' >&2
    return 0
  fi

  if [ "${#identities[@]}" -eq 1 ]; then
    APPLE_SIGNING_IDENTITY="${identities[0]}"
    AVAILABLE_CODESIGN_IDENTITY="${identities[0]}"
    return 0
  fi

  printf '%s\n' 'Multiple Developer ID Application identities found:' >&2
  for line in "${identities[@]}"; do
    printf '  %s) %s\n' "$index" "$line" >&2
    index=$((index + 1))
  done

  while :; do
    printf 'Choose signing identity [1-%s]: ' "${#identities[@]}" >&2
    IFS= read -r choice
    case "$choice" in
      ''|*[!0-9]*) ;;
      *)
        if [ "$choice" -ge 1 ] && [ "$choice" -le "${#identities[@]}" ]; then
          APPLE_SIGNING_IDENTITY="${identities[$((choice - 1))]}"
          AVAILABLE_CODESIGN_IDENTITY="$APPLE_SIGNING_IDENTITY"
          return 0
        fi
        ;;
    esac
    printf '%s\n' 'Invalid choice.' >&2
  done
}

discover_team_id() {
  if [ -n "${APPLE_TEAM_ID:-}" ]; then
    return 0
  fi

  if [ -n "$CERTIFICATE_TEAM_ID" ]; then
    APPLE_TEAM_ID="$CERTIFICATE_TEAM_ID"
    return 0
  fi

  if [ -n "${APPLE_SIGNING_IDENTITY:-}" ]; then
    APPLE_TEAM_ID="$(extract_team_id_from_identity "$APPLE_SIGNING_IDENTITY")"
    return 0
  fi

  if [ -n "$AVAILABLE_CODESIGN_IDENTITY" ]; then
    APPLE_TEAM_ID="$(extract_team_id_from_identity "$AVAILABLE_CODESIGN_IDENTITY")"
  fi
}

locate_certificate_path() {
  local matches=()

  if [ -n "${APPLE_CERTIFICATE:-}" ] || [ -n "$CERTIFICATE_PATH" ]; then
    return 0
  fi

  if [ -f "./certificate.p12" ]; then
    CERTIFICATE_PATH="./certificate.p12"
    return 0
  fi

  shopt -s nullglob
  matches=(./*.p12)
  shopt -u nullglob

  if [ "${#matches[@]}" -eq 1 ]; then
    CERTIFICATE_PATH="${matches[0]}"
  fi
}

ensure_certificate_path() {
  if [ -n "${APPLE_CERTIFICATE:-}" ]; then
    return 0
  fi

  locate_certificate_path
  prompt_value CERTIFICATE_PATH 'Path to the Developer ID Application .p12 file'
  CERTIFICATE_PATH="${CERTIFICATE_PATH/#\~/$HOME}"
  [ -f "$CERTIFICATE_PATH" ] || fail "Certificate file not found: $CERTIFICATE_PATH"
}

read_pkcs12_certificate() {
  if openssl pkcs12 "$@" 2>/dev/null; then
    return 0
  fi

  if openssl pkcs12 -help 2>&1 | grep -q -- '-legacy'; then
    openssl pkcs12 -legacy "$@" 2>/dev/null
    return $?
  fi

  return 1
}

read_certificate_identity() {
  local subject
  local identity

  if [ -z "$CERTIFICATE_PATH" ] || [ -z "${APPLE_CERTIFICATE_PASSWORD:-}" ]; then
    return 0
  fi

  if ! command -v openssl >/dev/null 2>&1; then
    return 0
  fi

  subject="$(read_pkcs12_certificate -in "$CERTIFICATE_PATH" -clcerts -nokeys -passin "pass:$APPLE_CERTIFICATE_PASSWORD" | openssl x509 -noout -subject -nameopt RFC2253 2>/dev/null || true)"

  if [ -z "$subject" ]; then
    subject="$(read_pkcs12_certificate -in "$CERTIFICATE_PATH" -clcerts -nokeys -passin "pass:$APPLE_CERTIFICATE_PASSWORD" | openssl x509 -noout -subject 2>/dev/null || true)"
  fi

  identity="$(printf '%s\n' "$subject" | sed -n \
    -e 's/^subject=.*CN=\([^,]*\).*/\1/p' \
    -e 's/^subject=.*CN = \([^,/]*\).*/\1/p' \
    -e 's/^subject=.*\/CN=\([^/]*\).*/\1/p' \
    -e 's/^subject=.*\/CN = \([^/]*\).*/\1/p' | head -n 1)"

  printf '%s\n' "$identity"
}

read_certificate_team_id() {
  local subject
  local team_id

  if [ -z "$CERTIFICATE_PATH" ] || [ -z "${APPLE_CERTIFICATE_PASSWORD:-}" ]; then
    return 0
  fi

  if ! command -v openssl >/dev/null 2>&1; then
    return 0
  fi

  subject="$(read_pkcs12_certificate -in "$CERTIFICATE_PATH" -clcerts -nokeys -passin "pass:$APPLE_CERTIFICATE_PASSWORD" | openssl x509 -noout -subject -nameopt RFC2253 2>/dev/null || true)"

  if [ -z "$subject" ]; then
    subject="$(read_pkcs12_certificate -in "$CERTIFICATE_PATH" -clcerts -nokeys -passin "pass:$APPLE_CERTIFICATE_PASSWORD" | openssl x509 -noout -subject 2>/dev/null || true)"
  fi

  team_id="$(extract_team_id_from_subject "$subject")"

  printf '%s\n' "$team_id"
}

discover_signing_identity_from_certificate() {
  local identity
  local team_id

  if [ -z "$CERTIFICATE_PATH" ] || [ -z "${APPLE_CERTIFICATE_PASSWORD:-}" ]; then
    return 0
  fi

  identity="$(read_certificate_identity)"

  if [ -z "$identity" ]; then
    fail "Could not read the signing identity from $CERTIFICATE_PATH. Check that the .p12 path and password are correct."
  fi

  CERTIFICATE_SIGNING_IDENTITY="$identity"
  team_id="$(read_certificate_team_id)"

  if [ -n "$team_id" ]; then
    CERTIFICATE_TEAM_ID="$team_id"
  fi

  case "$CERTIFICATE_SIGNING_IDENTITY" in
    Developer\ ID\ Application:*)
      ;;
    *)
      fail "Certificate at $CERTIFICATE_PATH is \"$CERTIFICATE_SIGNING_IDENTITY\". This release flow requires a Developer ID Application certificate."
      ;;
  esac

  if [ -n "${APPLE_SIGNING_IDENTITY:-}" ] && [ "$APPLE_SIGNING_IDENTITY" != "$CERTIFICATE_SIGNING_IDENTITY" ]; then
    fail "APPLE_SIGNING_IDENTITY \"$APPLE_SIGNING_IDENTITY\" does not match the certificate identity \"$CERTIFICATE_SIGNING_IDENTITY\" from $CERTIFICATE_PATH."
  fi

  if [ -n "$CERTIFICATE_TEAM_ID" ] && [ -n "${APPLE_TEAM_ID:-}" ] && [ "$APPLE_TEAM_ID" != "$CERTIFICATE_TEAM_ID" ]; then
    fail "APPLE_TEAM_ID \"$APPLE_TEAM_ID\" does not match the certificate team ID \"$CERTIFICATE_TEAM_ID\" from $CERTIFICATE_PATH."
  fi

  APPLE_SIGNING_IDENTITY="$CERTIFICATE_SIGNING_IDENTITY"
}

collect_notarization_values() {
  prompt_value APPLE_ID 'Apple ID email used for notarization'
  prompt_value APPLE_PASSWORD 'Apple app-specific password for notarization' 1
  discover_team_id
  prompt_value APPLE_TEAM_ID 'Apple Developer Team ID'
}

encode_certificate() {
  if [ -n "${APPLE_CERTIFICATE:-}" ]; then
    return 0
  fi

  ensure_certificate_path

  APPLE_CERTIFICATE="$(base64 < "$CERTIFICATE_PATH" | tr -d '\n')"
}

set_secret() {
  local secret_name="$1"
  local secret_value="$2"

  printf 'Setting %s\n' "$secret_name" >&2
  if ! printf '%s' "$secret_value" | gh secret set "$secret_name" --repo "$REPO" >/dev/null; then
    fail "Failed to set $secret_name for $REPO. Check that the repository exists and that gh is authenticated with access to it. For private repositories, refresh auth with: gh auth refresh -h github.com -s repo"
  fi
}

set_secret_if_present() {
  local secret_name="$1"
  local secret_value="${!secret_name:-}"

  if [ -z "$secret_value" ]; then
    return 0
  fi

  set_secret "$secret_name" "$secret_value"
}

REPO=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo)
      [ "$#" -ge 2 ] || fail 'Missing value for --repo'
      REPO="$2"
      shift 2
      ;;
    --certificate-path)
      [ "$#" -ge 2 ] || fail 'Missing value for --certificate-path'
      CERTIFICATE_PATH="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown argument: $1"
      ;;
  esac
done

require_command gh
require_command base64

if [ -z "$REPO" ]; then
  REPO="$(resolve_repo_from_git)"
fi

if [ -z "$REPO" ]; then
  REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
fi

prompt_value REPO 'GitHub repository (owner/name)'

gh auth status >/dev/null 2>&1 || fail 'gh is not authenticated. Run: gh auth login'

if command -v security >/dev/null 2>&1 && [ -z "${APPLE_SIGNING_IDENTITY:-}" ] && [ -z "$CERTIFICATE_PATH" ] && [ -z "${APPLE_CERTIFICATE:-}" ]; then
  select_signing_identity
fi

ensure_certificate_path
prompt_value APPLE_CERTIFICATE_PASSWORD 'Password used when exporting the .p12 file' 1
discover_signing_identity_from_certificate
if command -v security >/dev/null 2>&1 && [ -z "${APPLE_SIGNING_IDENTITY:-}" ]; then
  select_signing_identity
fi
prompt_value APPLE_SIGNING_IDENTITY 'Developer ID Application signing identity'
discover_team_id
encode_certificate
collect_notarization_values

printf '\nTarget repository: %s\n' "$REPO" >&2
if [ -n "${APPLE_TEAM_ID:-}" ]; then
  printf 'Resolved Apple team ID: %s\n' "$APPLE_TEAM_ID" >&2
fi
printf '%s\n' 'Secrets to update:' >&2
printf '%s\n' '  APPLE_SIGNING_IDENTITY' >&2
printf '%s\n' '  APPLE_CERTIFICATE' >&2
printf '%s\n' '  APPLE_CERTIFICATE_PASSWORD' >&2
if [ -n "${APPLE_TEAM_ID:-}" ]; then
  printf '%s\n' '  APPLE_TEAM_ID' >&2
fi
if [ -n "${APPLE_ID:-}" ]; then
  printf '%s\n' '  APPLE_ID' >&2
  printf '%s\n' '  APPLE_PASSWORD' >&2
fi

set_secret_if_present APPLE_SIGNING_IDENTITY
set_secret_if_present APPLE_CERTIFICATE
set_secret_if_present APPLE_CERTIFICATE_PASSWORD
set_secret_if_present APPLE_TEAM_ID
set_secret_if_present APPLE_ID
set_secret_if_present APPLE_PASSWORD

printf '\n%s\n' 'GitHub Actions secrets updated.' >&2