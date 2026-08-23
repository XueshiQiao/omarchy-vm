#!/bin/bash
# Builds omarchy-vm and signs it with the virtualization entitlement.
# Without that entitlement the process dies the moment it touches VZVirtualMachine.
set -euo pipefail
cd "$(dirname "$0")"

swiftc -O src/main.swift -o omarchy-vm
codesign --force --sign - --entitlements omarchy-vm.entitlements omarchy-vm

echo "built ./omarchy-vm"
codesign -d --entitlements - omarchy-vm 2>&1 | grep -A1 virtualization || true
