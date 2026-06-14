#!/bin/bash

# demo-rotation-v1-v3.sh - Encrypt at v1 and v3, rotate once more, decrypt both
#
# Scenario:
#   1. Reset key → v1, encrypt message A at v1
#   2. Rotate twice → v3, encrypt message B at v3
#   3. Rotate once more → v4
#   4. Decrypt both messages — proves Vault keeps all key versions alive
#
# Usage:
#   ./infrastructure/demo-rotation-v1-v3.sh

set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

NODE_SERVICE="http://encryption-service.default.svc.cluster.local:3000"
JAVA_SERVICE="http://encryption-service-java.default.svc.cluster.local:8080"

kube_curl() {
  kubectl run curl-test --image=curlimages/curl --rm -i --restart=Never --quiet -- "$@" 2>/dev/null
}

get_latest_version() {
  kubectl exec -n vault vault-0 -- vault read -format=json "transit/keys/$1" \
    | jq -r '.data.latest_version'
}

reset_key() {
  local KEY_NAME=$1
  local KEY_VAULT_TYPE=$2

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

rotate_once() {
  local KEY_NAME=$1
  kubectl exec -n vault vault-0 -- vault write -f "transit/keys/$KEY_NAME/rotate" >/dev/null
  echo -e "    latest version: ${GREEN}v$(get_latest_version "$KEY_NAME")${NC}"
}

encrypt_via_node() {
  local KEY_NAME=$1
  local PLAINTEXT=$2
  local EXPECTED_VERSION=$3

  local RESPONSE
  RESPONSE=$(kube_curl -s -X POST "$NODE_SERVICE/encrypt" \
    -H "Content-Type: application/json" \
    -d "{\"plaintext\": \"$PLAINTEXT\", \"key\": \"$KEY_NAME\"}")

  local CIPHERTEXT VERSION
  CIPHERTEXT=$(echo "$RESPONSE" | jq -r '.ciphertext')
  VERSION=$(echo "$RESPONSE" | jq -r '.key_version')

  if [ "$VERSION" != "$EXPECTED_VERSION" ]; then
    echo -e "${RED}❌ FAILURE: Expected encryption at v$EXPECTED_VERSION, got v$VERSION${NC}"
    exit 1
  fi

  echo "$CIPHERTEXT"
}

decrypt_via_java() {
  local KEY_NAME=$1
  local CIPHERTEXT=$2

  kube_curl -s -X POST "$JAVA_SERVICE/decrypt" \
    -H "Content-Type: application/json" \
    -d "{\"ciphertext\": \"$CIPHERTEXT\", \"key\": \"$KEY_NAME\"}" \
    | jq -r '.plaintext'
}

decrypt_via_node() {
  local KEY_NAME=$1
  local CIPHERTEXT=$2

  kube_curl -s -X POST "$NODE_SERVICE/decrypt" \
    -H "Content-Type: application/json" \
    -d "{\"ciphertext\": \"$CIPHERTEXT\", \"key\": \"$KEY_NAME\"}" \
    | jq -r '.plaintext'
}

run_demo_for_key() {
  local KEY_NAME=$1
  local KEY_TYPE=$2
  local KEY_VAULT_TYPE=$3
  local MSG_V1="Message encrypted at v1 ($KEY_TYPE)"
  local MSG_V3="Message encrypted at v3 ($KEY_TYPE)"

  echo ""
  echo -e "${CYAN}>>> Key: $KEY_NAME ($KEY_TYPE)${NC}"

  reset_key "$KEY_NAME" "$KEY_VAULT_TYPE"
  echo -e "  Key reset to: ${GREEN}v$(get_latest_version "$KEY_NAME")${NC}"

  echo -e "${YELLOW}Step 1:${NC} Encrypt message A with Node.js at v1..."
  CIPHER_V1=$(encrypt_via_node "$KEY_NAME" "$MSG_V1" "1")
  echo -e "  A (v1): ${CYAN}${CIPHER_V1:0:55}...${NC}"

  echo -e "${YELLOW}Step 2:${NC} Rotate twice (v1 → v2 → v3)..."
  rotate_once "$KEY_NAME"
  rotate_once "$KEY_NAME"

  echo -e "${YELLOW}Step 3:${NC} Encrypt message B with Node.js at v3..."
  CIPHER_V3=$(encrypt_via_node "$KEY_NAME" "$MSG_V3" "3")
  echo -e "  B (v3): ${CYAN}${CIPHER_V3:0:55}...${NC}"

  echo -e "${YELLOW}Step 4:${NC} Rotate once more (v3 → v4)..."
  rotate_once "$KEY_NAME"

  local FINAL_VERSION
  FINAL_VERSION=$(get_latest_version "$KEY_NAME")
  if [ "$FINAL_VERSION" != "4" ]; then
    echo -e "${RED}❌ FAILURE: Expected key at v4, got v$FINAL_VERSION${NC}"
    exit 1
  fi

  echo -e "${YELLOW}Step 5:${NC} Decrypt both messages (key now at v$FINAL_VERSION)..."
  DECRYPTED_V1=$(decrypt_via_java "$KEY_NAME" "$CIPHER_V1")
  DECRYPTED_V3=$(decrypt_via_node "$KEY_NAME" "$CIPHER_V3")

  if [ "$DECRYPTED_V1" != "$MSG_V1" ]; then
    echo -e "${RED}❌ FAILURE: v1 message — expected '$MSG_V1', got '$DECRYPTED_V1'${NC}"
    exit 1
  fi
  if [ "$DECRYPTED_V3" != "$MSG_V3" ]; then
    echo -e "${RED}❌ FAILURE: v3 message — expected '$MSG_V3', got '$DECRYPTED_V3'${NC}"
    exit 1
  fi

  echo -e "${GREEN}✅ SUCCESS: Both messages decrypt after rotation to v$FINAL_VERSION${NC}"
  echo -e "    A (v1 → Java):  '$DECRYPTED_V1'"
  echo -e "    B (v3 → Node):  '$DECRYPTED_V3'"
}

echo -e "${CYAN}=====================================================${NC}"
echo -e "${CYAN}  Dual-Version Demo — Encrypt v1 & v3, Rotate → v4${NC}"
echo -e "${CYAN}=====================================================${NC}"
echo ""
echo "Encrypt two messages at different key versions, rotate once more,"
echo "then prove both ciphertexts still decrypt from v4."

run_demo_for_key "demo-key-symmetric" "AES-256" "aes256-gcm96"
run_demo_for_key "demo-key-asymmetric" "RSA-2048" "rsa-2048"

echo ""
echo -e "${GREEN}All tests passed! v1 and v3 ciphertext both decrypt after rotation to v4.${NC}"
echo -e "${CYAN}=====================================================${NC}"
