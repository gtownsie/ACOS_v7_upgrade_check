#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# AXAPI V7 Upgrade Check - Shell Equivalent
# Converted from Postman folder: V7-Upgrade Check
#
# Required environment variables:
#   HOST        e.g. 10.0.0.1
#   PORT        e.g. :443   or empty string
#   USERNAME
#   PASSWORD
#
# Optional:
INSECURE=true   # use curl -k for self-signed certs
# ============================================================================

HOST="${HOST:-}"
USERNAME="${USERNAME:-}"
PASSWORD="${PASSWORD:-}"

usage() {
  cat <<EOF
Usage: $0 -host <host> -username <username> -password <password>

Options:
  -host      Hostname or IP address of the device
  -username  Username for authentication
  -password  Password for authentication

You may also provide HOST, USERNAME, and PASSWORD as environment variables.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -host|--host)
      if [[ $# -lt 2 || "$2" == -* ]]; then
        echo "Missing value for $1" >&2
        usage
        exit 1
      fi
      HOST="$2"
      shift 2
      ;;
    -username|--username)
      if [[ $# -lt 2 || "$2" == -* ]]; then
        echo "Missing value for $1" >&2
        usage
        exit 1
      fi
      USERNAME="$2"
      shift 2
      ;;
    -password|--password)
      if [[ $# -lt 2 || "$2" == -* ]]; then
        echo "Missing value for $1" >&2
        usage
        exit 1
      fi
      PASSWORD="$2"
      shift 2
      ;;
    -h|-help|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

: "${HOST:?HOST is required}"
: "${USERNAME:?USERNAME is required}"
: "${PASSWORD:?PASSWORD is required}"

PORT="${PORT:-}"
INSECURE="${INSECURE:-true}"

BASE_URL="https://${HOST}${PORT}/axapi/v3"

if [[ "${INSECURE}" == "true" ]]; then
  CURL_TLS=(-k)
else
  CURL_TLS=()
fi

PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0

CPU_CONTROL=0
CPU_DATA=0
CPU_COUNT=0
DEVICE_HOSTNAME=""
DEVICE_SERIAL=""
FAIL_MESSAGES=()

pass() {
  echo "[PASS] $*"
  PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
  echo "[FAIL] $*" >&2
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAIL_MESSAGES+=("$*")
}

warn() {
  echo "[WARN] $*"
  WARN_COUNT=$((WARN_COUNT + 1))
}

info() {
  echo "[INFO] $*"
}

require_jq() {
  if ! command -v jq >/dev/null 2>&1; then
    echo "jq is required but not installed." >&2
    exit 1
  fi
}

request_json() {
  local method="$1"
  local endpoint="$2"
  local content_type="$3"
  local body="${4:-}"
  local auth_header="${5:-}"

  local args=("${CURL_TLS[@]}" -sS -X "$method" "${BASE_URL}${endpoint}" -H "Content-Type: ${content_type}")
  if [[ -n "${auth_header}" ]]; then
    args+=(-H "Authorization: ${auth_header}")
  fi
  if [[ -n "${body}" ]]; then
    args+=(--data "$body")
  fi

  curl "${args[@]}"
}

request_text() {
  local method="$1"
  local endpoint="$2"
  local content_type="$3"
  local body="${4:-}"
  local auth_header="${5:-}"

  local args=("${CURL_TLS[@]}" -sS -X "$method" "${BASE_URL}${endpoint}" -H "Content-Type: ${content_type}")
  if [[ -n "${auth_header}" ]]; then
    args+=(-H "Authorization: ${auth_header}")
  fi
  if [[ -n "${body}" ]]; then
    args+=(--data "$body")
  fi

  curl "${args[@]}"
}

validate_json() {
  local payload="$1"
  echo "$payload" | jq . >/dev/null 2>&1
}

print_section() {
  echo
  echo "================================================================"
  echo "$1"
  echo "================================================================"
}

require_jq

print_section "1) Authorize - RUN ME FIRST!"

AUTH_PAYLOAD=$(jq -n \
  --arg username "$USERNAME" \
  --arg password "$PASSWORD" \
  '{credentials: {username: $username, password: $password}}')

AUTH_RESPONSE=$(request_json "POST" "/auth" "application/json" "$AUTH_PAYLOAD")

if ! validate_json "$AUTH_RESPONSE"; then
  echo "$AUTH_RESPONSE"
  fail "Authorization response is not valid JSON"
  exit 1
fi

SIGNATURE=$(echo "$AUTH_RESPONSE" | jq -r '.authresponse.signature // empty')

if [[ -z "$SIGNATURE" ]]; then
  echo "$AUTH_RESPONSE"
  fail "Could not extract authresponse.signature from authorization response"
  exit 1
fi

AUTHKEY="A10 ${SIGNATURE}"
pass "Authorization token acquired"

print_section "2) Get version info"

VERSION_RESPONSE=$(request_json "GET" "/version/oper" "application/json" "" "$AUTHKEY")

if validate_json "$VERSION_RESPONSE"; then
  CPU_COUNT=$(echo "$VERSION_RESPONSE" | jq -r '."ctrl-cpu".oper["number-of-cpu"] // 0' 2>/dev/null || echo 0)
  DEVICE_HOSTNAME=$(echo "$VERSION_RESPONSE" | jq -r 'try(.version.oper.hostname // .version.oper["hostname"] // .hostname // empty) catch empty' 2>/dev/null || true)
  DEVICE_SERIAL=$(echo "$VERSION_RESPONSE" | jq -r 'try(.version.oper["serial-number"] // .["serial-number"] // empty) catch empty' 2>/dev/null || true)
  DETECTED_HARDWARE=$(echo "$VERSION_RESPONSE" | jq -r 'try(.version.oper["hw-platform"] // .version.oper.hw_platform // .["hw-platform"] // .hw_platform // empty) catch empty' 2>/dev/null || true)
  DETECTED_VERSION_RAW=$(echo "$VERSION_RESPONSE" | jq -r 'try(.version.oper["sw-version"] // empty) catch empty' 2>/dev/null || true)

  DETECTED_VERSION=$(echo "${DETECTED_VERSION_RAW}" | cut -d',' -f1 | tr -d '[:space:]')
  info "Version info retrieved ${DETECTED_VERSION_RAW} -> ${DETECTED_VERSION}"
  info "Hardware info retrieved ${DETECTED_HARDWARE}"
  info "Derived cpu_count from response: ${CPU_COUNT}"
  info "Hostname: ${DEVICE_HOSTNAME}"
  info "Serial Number: ${DEVICE_SERIAL}"

  if [[ -n "${DETECTED_HARDWARE}" ]] && [[ "${DETECTED_HARDWARE}" == *"vThunder"* ]]; then
    info "Detected hardware is vThunder; skipping 4th-generation platform validation."
  elif [[ -n "${DETECTED_HARDWARE}" ]] && [[ "${DETECTED_HARDWARE}" =~ ^[A-Za-z]+[0-9]{4}[A-Za-z]?$ ]]; then
    HARDWARE_GEN="${DETECTED_HARDWARE:$((${#DETECTED_HARDWARE}-3)):1}"
    info "Detected hardware generation ${HARDWARE_GEN} for platform ${DETECTED_HARDWARE}"
    if [[ "${HARDWARE_GEN}" == "4" ]]; then
      fail "Detected 4th generation hardware (${DETECTED_HARDWARE}); the last supported version is 6.0.7."
    fi
  fi

  if [[ -n "${DETECTED_VERSION}" && "${DETECTED_VERSION}" != "6.0.7" ]]; then
    fail "Detected software version ${DETECTED_VERSION}; expected 6.0.7, please upgrade to 6.0.7 before proceeding with this upgrade."
  fi
  pass "Version info request completed"
else
  echo "$VERSION_RESPONSE"
  fail "Version info response is not valid JSON"
fi

print_section "3) Get Control CPU count"

CTRL_CPU_RESPONSE=$(request_json "GET" "/system-cpu/ctrl-cpu/oper" "application/json" "" "$AUTHKEY")

if validate_json "$CTRL_CPU_RESPONSE"; then
  CPU_CONTROL=$(echo "$CTRL_CPU_RESPONSE" | jq -r '.["ctrl-cpu"].oper["number-of-cpu"] // 0')
  info "Control CPU count: ${CPU_CONTROL}"
  pass "Control CPU count retrieved"
else
  echo "$CTRL_CPU_RESPONSE"
  fail "Control CPU response is not valid JSON"
fi

print_section "4) Get Data CPU count"

DATA_CPU_RESPONSE=$(request_json "GET" "/system-cpu/data-cpu/oper" "application/json" "" "$AUTHKEY")

if validate_json "$DATA_CPU_RESPONSE"; then
  CPU_DATA=$(echo "$DATA_CPU_RESPONSE" | jq -r '."data-cpu".oper["number-of-cpu"] // 0')
  info "Data CPU count: ${CPU_DATA}"

  if [[ "${CPU_CONTROL}" =~ ^[0-9]+$ ]] && [[ "${CPU_DATA}" =~ ^[0-9]+$ ]]; then
    CPU_TOTAL=0
    CPU_TOTAL=$((CPU_TOTAL + CPU_CONTROL))
    CPU_TOTAL=$((CPU_TOTAL + CPU_DATA))

    if (( CPU_TOTAL >= 8 )); then
      pass "CPU total is ${CPU_TOTAL} (control + data), meeting the threshold"
    else
      fail "CPU total is ${CPU_TOTAL} (control + data), below the required threshold of 8"
    fi
  else
    fail "Invalid CPU counts returned (cpu_control=${CPU_CONTROL}, cpu_data=${CPU_DATA})"
  fi
else
  echo "$DATA_CPU_RESPONSE"
  fail "Data CPU response is not valid JSON"
fi

print_section "5) Current boot image"

BOOTIMAGE_RESPONSE=$(request_json "GET" "/bootimage/oper" "application/json" "" "$AUTHKEY")

if validate_json "$BOOTIMAGE_RESPONSE"; then
  info "Current boot image response:"
  echo "$BOOTIMAGE_RESPONSE" | jq .
  pass "Boot image information retrieved"
else
  echo "$BOOTIMAGE_RESPONSE"
  fail "Boot image response is not valid JSON"
fi

print_section "6) License Info"

LICENSE_RESPONSE=$(request_json "GET" "/scm/licenseinfo/oper" "application/json" "" "$AUTHKEY")

if validate_json "$LICENSE_RESPONSE"; then
  BILLING_SERIAL=$(echo "$LICENSE_RESPONSE" | jq -r '.licenseinfo.oper["billing-serial"] // empty')

  if [[ -z "$BILLING_SERIAL" ]]; then
    fail "billing-serial is missing"
  else
    IFS=',' read -r -a SERIAL_PARTS <<< "$BILLING_SERIAL"

    CLEAN_COUNT=0
    for part in "${SERIAL_PARTS[@]}"; do
      trimmed="$(echo "$part" | xargs)"
      if [[ -n "$trimmed" ]]; then
        CLEAN_COUNT=$((CLEAN_COUNT + 1))
      fi
    done

    if (( CLEAN_COUNT == 2 )); then
      pass "billing-serial contains two comma-delimited values"
    elif (( CLEAN_COUNT == 1 )); then
      fail "This device may not be licensed for v7. Please validate the license and apply the RHEL license"
    else
      fail "Expected 2 billing-serial values, but received ${CLEAN_COUNT}: ${BILLING_SERIAL}"
    fi
  fi
else
  echo "$LICENSE_RESPONSE"
  fail "License Info response is not valid JSON"
fi

print_section "7) DiskInfo"

DISK_RESPONSE=$(request_json "GET" "/rrd/disk/oper" "application/json" "" "$AUTHKEY")

if validate_json "$DISK_RESPONSE"; then
  TOTAL_DISK=$(echo "$DISK_RESPONSE" | jq -r '.disk.oper["total-disk"] // empty')

  if [[ -z "$TOTAL_DISK" ]]; then
    fail "Missing disk.oper['total-disk']; expected a string like '30G'"
  elif [[ ! "$TOTAL_DISK" =~ ^[0-9]+([.][0-9]+)?[Gg]$ ]]; then
    fail "disk.oper['total-disk'] has invalid format: ${TOTAL_DISK}"
  else
    DISK_NUM=$(echo "$TOTAL_DISK" | sed -E 's/[Gg]$//')
    DISK_INT=${DISK_NUM%.*}

    if (( DISK_INT >= 128 )); then
      pass "disk.oper['total-disk'] is at least 128G (${TOTAL_DISK})"
    else
      fail "disk.oper['total-disk'] numeric value is below 128G (${TOTAL_DISK})"
    fi
  fi
else
  echo "$DISK_RESPONSE"
  fail "DiskInfo response is not valid JSON"
fi

print_section "8) Memory"

MEMORY_RESPONSE=$(request_json "GET" "/system/memory/oper" "application/json" "" "$AUTHKEY")

if validate_json "$MEMORY_RESPONSE"; then
  MEMORY_VALUE=$(echo "$MEMORY_RESPONSE" | jq -r '.memory.oper.Total // .memory.oper["Total"] // empty')

  if [[ -z "$MEMORY_VALUE" ]]; then
    fail "Memory value is missing"
  elif [[ ! "$MEMORY_VALUE" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    fail "Memory value should be numeric, got: ${MEMORY_VALUE}"
  else
    MEMORY_INT=${MEMORY_VALUE%.*}
    info "Memory reported: ${MEMORY_VALUE}"

    if (( MEMORY_INT > 16000000 )); then
      pass "Memory validation passed: must be greater than 16G of RAM"
    else
      fail "Memory validation failed: expected > 16000000, got ${MEMORY_VALUE}"
    fi
  fi
else
  echo "$MEMORY_RESPONSE"
  fail "Memory response is not valid JSON"
fi

print_section "9) Shared Poll Mode"

SHARED_POLL_RESPONSE=$(request_text "POST" "/clideploy" "text/plain" "sh system shared-poll-mode" "$AUTHKEY")

echo "$SHARED_POLL_RESPONSE"

SECOND_LINE=$(echo "$SHARED_POLL_RESPONSE" | awk 'NF{count++; if (count == 2) print;}' || true)
NONEMPTY_LINES=$(echo "$SHARED_POLL_RESPONSE" | awk 'NF{count++} END{print count+0}')

echo "end of shared poll mode response.  next logging"
if (( NONEMPTY_LINES < 2 )); then
  fail "Shared Poll Mode response must contain at least 2 non-empty lines"
else
  if [[ "$SECOND_LINE" == *"Shared poll mode is enabled"* ]]; then
    fail "Shared Poll mode is not supported in v7, run the command \"system shared-poll-mode disable\" before installing v7."
  else
    pass "Shared Poll Mode validation passed"
  fi
fi

print_section "Summary"

if [[ -z "${DEVICE_HOSTNAME:-}" ]]; then
  DEVICE_HOSTNAME=$(echo "$VERSION_RESPONSE" | jq -r 'try(.version.oper.hostname // .version.oper["hostname"] // .hostname // empty) catch empty' 2>/dev/null || true)
fi
if [[ -z "${DEVICE_SERIAL:-}" ]]; then
  DEVICE_SERIAL=$(echo "$VERSION_RESPONSE" | jq -r 'try(.version.oper["serial-number"] // .["serial-number"] // empty) catch empty' 2>/dev/null || true)
fi

echo "Hostname : ${DEVICE_HOSTNAME:-}"
echo "Serial   : ${DEVICE_SERIAL:-}"
echo " "
echo "Passed : ${PASS_COUNT}"
echo "Failed : ${FAIL_COUNT}"
echo "Warnings: ${WARN_COUNT}"

if (( ${#FAIL_MESSAGES[@]} > 0 )); then
  echo
  echo "Fail checks:"
  for msg in "${FAIL_MESSAGES[@]}"; do
    echo "- $msg"
  done
fi

if (( FAIL_COUNT > 0 )); then
  exit 1
fi

exit 0
