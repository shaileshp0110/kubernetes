#!/bin/bash

# demo-rotation-n.sh - Encrypt at key v1, rotate N times, verify ciphertext still decrypts
#
# Usage:
#   ./infrastructure/demo-rotation-n.sh <rotations>
#
# Example:
#   ./infrastructure/demo-rotation-n.sh 2   # encrypt v1, rotate twice → key at v3, decrypt v1 ciphertext
#   ./infrastructure/demo-rotation-n.sh 5   # encrypt v1, rotate five times → key at v6, decrypt v1 ciphertext

set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

NODE_SERVICE="http://encryption-service.default.svc.cluster.local:3000"
JAVA_SERVICE="http://encryption-service-java.default.svc.cluster.local:8080"

usage() {
  echo "Usage: $0 <number-of-rotations>"
  echo ""
  echo "  Encrypts at key version 1, rotates the key N times, then decrypts"
  echo "  the original v1 ciphertext to prove Vault retains old key material."
  echo ""
  echo "Examples:"
  echo "  $0 2    # rotate twice  (key ends at v3)"
  echo "  $0 5    # rotate 5 times (key ends at v6)"
  exit 1
}

if [ $# -ne 1 ] || ! [[ "$1" =~ ^[0-9]+$ ]] || [ "$1" -lt 1 ]; then
  usage
fi

ROTATIONS=$1
EXPECTED_FINAL_VERSION=$((ROTATIONS + 1))

kube_curl() {
  # sidecar.istio.io/inject=false keeps this throwaway pod out of the mesh so it
  # exits cleanly with --rm -i (a sidecar would block pod termination).
  kubectl run curl-test --image=curlimages/curl --rm -i --restart=Never --quiet \
    --overrides='{"metadata":{"annotations":{"sidecar.istio.io/inject":"false"}}}' \
    -- "$@" 2>/dev/null
}

get_latest_version() {
  kubectl exec -n vault vault-0 -- vault read -format=json "transit/keys/$1" \
    | jq -r '.data.latest_version'
}

reset_key() {
  local KEY_NAME=$1
  local KEY_VAULT_TYPE=$2

  # Vault blocks key deletion unless deletion_allowed=true on the key config
  if kubectl exec -n vault vault-0 -- vault read "transit/keys/$KEY_NAME" >/dev/null 2>&1; then
    kubectl exec -n vault vault-0 -- vault write "transit/keys/$KEY_NAME/config" deletion_allowed=true >/dev/null
    kubectl exec -n vault vault-0 -- vault delete "transit/keys/$KEY_NAME" >/dev/null
  fi
  kubectl exec -n vault vault-0 -- vault write -f "transit/keys/$KEY_NAME" "type=$KEY_VAULT_TYPE" >/dev/null

  local VERSION
  VERSION=$(get_latest_version "$KEY_NAME")
  if [ "$VERSION" != "1" ]; then
    echo -e "${RED}❌ FAILURE: Key reset failed — latest version is v$VERSION, expected v1${NC}"
    exit 1
  fi
}

rotate_key_n_times() {
  local KEY_NAME=$1
  local COUNT=$2

  for ((i = 1; i <= COUNT; i++)); do
    kubectl exec -n vault vault-0 -- vault write -f "transit/keys/$KEY_NAME/rotate" >/dev/null
    echo -e "    rotation $i/$COUNT → latest version: ${GREEN}v$(get_latest_version "$KEY_NAME")${NC}"
  done
}

run_demo_for_key() {
  local KEY_NAME=$1
  local KEY_TYPE=$2
  local KEY_VAULT_TYPE=$3
  local PLAINTEXT="Hello $KEY_TYPE (encrypted at v1)"

  echo ""
  echo -e "${CYAN}>>> Key: $KEY_NAME ($KEY_TYPE) — $ROTATIONS rotation(s)${NC}"

  reset_key "$KEY_NAME" "$KEY_VAULT_TYPE"
  echo -e "  Key reset to version: ${GREEN}v$(get_latest_version "$KEY_NAME")${NC}"

  echo -e "${YELLOW}Encrypt${NC} with Node.js at v1..."
  ENCRYPT_RESPONSE=$(kube_curl -s -X POST "$NODE_SERVICE/encrypt" \
    -H "Content-Type: application/json" \
    -d "{\"plaintext\": \"$PLAINTEXT\", \"key\": \"$KEY_NAME\"}")

  CIPHERTEXT=$(echo "$ENCRYPT_RESPONSE" | jq -r '.ciphertext')
  ENCRYPT_VERSION=$(echo "$ENCRYPT_RESPONSE" | jq -r '.key_version')

  if [ "$ENCRYPT_VERSION" != "1" ]; then
    echo -e "${RED}❌ FAILURE: Expected encryption at v1, got v$ENCRYPT_VERSION${NC}"
    exit 1
  fi

  echo -e "  Ciphertext (v$ENCRYPT_VERSION): ${CYAN}${CIPHERTEXT:0:60}...${NC}"

  echo -e "${YELLOW}Rotate${NC} $ROTATIONS time(s)..."
  rotate_key_n_times "$KEY_NAME" "$ROTATIONS"

  FINAL_VERSION=$(get_latest_version "$KEY_NAME")
  if [ "$FINAL_VERSION" != "$EXPECTED_FINAL_VERSION" ]; then
    echo -e "${RED}❌ FAILURE: Expected v$EXPECTED_FINAL_VERSION after $ROTATIONS rotations, got v$FINAL_VERSION${NC}"
    exit 1
  fi

  echo -e "${YELLOW}Decrypt${NC} v1 ciphertext with Java (key now at v$FINAL_VERSION)..."
  DECRYPT_RESPONSE=$(kube_curl -s -X POST "$JAVA_SERVICE/decrypt" \
    -H "Content-Type: application/json" \
    -d "{\"ciphertext\": \"$CIPHERTEXT\", \"key\": \"$KEY_NAME\"}")
  DECRYPTED=$(echo "$DECRYPT_RESPONSE" | jq -r '.plaintext')

  if [ "$DECRYPTED" == "$PLAINTEXT" ]; then
    echo -e "${GREEN}✅ SUCCESS: v1 ciphertext decrypts after $ROTATIONS rotation(s) (key at v$FINAL_VERSION).${NC}"
  else
    echo -e "${RED}❌ FAILURE: Expected '$PLAINTEXT', got '$DECRYPTED'${NC}"
    exit 1
  fi
}

echo -e "${CYAN}=====================================================${NC}"
echo -e "${CYAN}  Multi-Rotation Demo — Encrypt v1, Rotate ×$ROTATIONS, Decrypt${NC}"
echo -e "${CYAN}=====================================================${NC}"
echo ""
echo "Vault Transit keeps all prior key versions. Ciphertext encrypted"
echo "at v1 should decrypt even after the key has been rotated to v$EXPECTED_FINAL_VERSION."

run_demo_for_key "demo-key-symmetric" "AES-256" "aes256-gcm96"
run_demo_for_key "demo-key-asymmetric" "RSA-2048" "rsa-2048"

echo ""
echo -e "${GREEN}All tests passed! v1 ciphertext decrypts after $ROTATIONS rotation(s).${NC}"
echo -e "${CYAN}=====================================================${NC}"
