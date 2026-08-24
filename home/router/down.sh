#!/bin/bash
# Derruba o container router e limpa o IP da interface de teste.
set -euo pipefail

IFACE="enxd03745ea2d6b"

cd "$(dirname "$0")"
docker compose down

sudo nft delete table ip home_intranet 2>/dev/null || true

if ip link show "$IFACE" >/dev/null 2>&1; then
  sudo ip addr flush dev "$IFACE"
  echo "IP removido de $IFACE."
fi
