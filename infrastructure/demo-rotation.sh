#!/bin/bash

# demo-rotation.sh - Demonstrates key rotation using Vault Transit Secret Engine
# Proves that rotation works for both Symmetric (AES) and Asymmetric (RSA) keys.

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

run_demo_for_key() {
  local KEY_NAME=$1
  local KEY_TYPE=$2

  echo ""
  echo -e "${CYAN}>>> Testing Key: $KEY_NAME ($KEY_TYPE)${NC}"

  # 1. Get initial version
  KEY_INFO=$(kubectl exec -n vault vault-0 -- vault read -format=json transit/keys/$KEY_NAME)
  CURRENT_VERSION=$(echo "$KEY_INFO" | jq -r '.data.latest_version')
  echo -e "Initial version: ${GREEN}$CURRENT_VERSION${NC}"

  # 2. Encrypt with Node.js
  echo "Encrypting with Node.js..."
  ENCRYPT_RESPONSE=$(kube_curl -s -X POST "$NODE_SERVICE/encrypt" -H "Content-Type: application/json" -d "{\"plaintext\": \"Hello $KEY_TYPE\", \"key\": \"$KEY_NAME\"}")
  CIPHERTEXT=$(echo "$ENCRYPT_RESPONSE" | jq -r '.ciphertext')
  echo -e "Ciphertext: ${CYAN}${CIPHERTEXT:0:50}...${NC}"

  # 3. Rotate
  echo "Rotating key in Vault..."
  kubectl exec -n vault vault-0 -- vault write -f transit/keys/$KEY_NAME/rotate

  # 4. Decrypt with Java
  echo "Decrypting with Java..."
  DECRYPT_RESPONSE=$(kube_curl -s -X POST "$JAVA_SERVICE/decrypt" -H "Content-Type: application/json" -d "{\"ciphertext\": \"$CIPHERTEXT\", \"key\": \"$KEY_NAME\"}")
  PLAINTEXT=$(echo "$DECRYPT_RESPONSE" | jq -r '.plaintext')

  if [ "$PLAINTEXT" == "Hello $KEY_TYPE" ]; then
    echo -e "${GREEN}✅ SUCCESS: Decrypted '$PLAINTEXT' after rotation.${NC}"
  else
    echo -e "${RED}❌ FAILURE: Decryption failed for $KEY_NAME${NC}"
    exit 1
  fi
}

echo -e "${CYAN}=====================================================${NC}"
echo -e "${CYAN}  Dual-Key Rotation Demo (Symmetric & Asymmetric)${NC}"
echo -e "${CYAN}=====================================================${NC}"

run_demo_for_key "demo-key-symmetric" "AES-256"
run_demo_for_key "demo-key-asymmetric" "RSA-2048"

echo ""
echo -e "${GREEN}All tests passed! Both Symmetric and Asymmetric rotation verified.${NC}"
echo -e "${CYAN}=====================================================${NC}"
