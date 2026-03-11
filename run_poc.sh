#!/bin/bash

# Jito Restaking Vault — Reward Front-Running Exploit PoC Runner
# This script copies the test file and runs the REAL PoC

set -e

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║  Jito Restaking Vault — Reward Front-Running Exploit PoC      ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

# Check if we're in the right directory
if [ ! -f "tests/reward_frontrun_exploit.rs" ]; then
    echo "❌ Error: tests/reward_frontrun_exploit.rs not found"
    echo "Please run this script from the poc-reward-frontrun directory"
    exit 1
fi

# Check if restaking directory exists
if [ ! -d "./restaking" ]; then
    echo "❌ Error: Cannot find ./restaking directory"
    echo "Please run this script from the jito root directory (next to restaking)"
    exit 1
fi

echo "📦 Copying exploit test to restaking repository..."
cp tests/reward_frontrun_exploit.rs ./restaking/integration_tests/tests/vault/
echo "mod reward_frontrun_exploit;" >> ./restaking/integration_tests/tests/vault/mod.rs
echo "✅ Test file copied and module added"

echo ""
echo "🚀 Running REAL PoC with jito_vault_program code..."
echo ""

cd ./restaking/integration_tests

# Run the exploit test
cargo test test_reward_frontrun_exploit_real -- --nocapture

echo ""
echo "✅ PoC execution complete"
echo ""
echo "If the test passed, the vulnerability is confirmed!"
echo ""
echo "For more details, see:"
echo "  - README.md"
echo "  - IMMUNEFI.md"
echo "  - ATTACK_FLOW.md"
