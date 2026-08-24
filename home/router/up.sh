#!/bin/bash
# Sobe a interface de teste com IP estático e liga o container router.
# Rodar DEPOIS de plugar o adaptador USB (enxd03745ea2d6b).
set -euo pipefail

IFACE="enxd03745ea2d6b"
CIDR="10.84.0.1/24"

if ! ip link show "$IFACE" >/dev/null 2>&1; then
  echo "Interface $IFACE não encontrada." >&2
  echo "Plugue o adaptador USB (o rock64 na outra ponta) e rode de novo." >&2
  echo "Interfaces atuais:" >&2
  ip -br link >&2
  exit 1
fi

echo "Interface $IFACE encontrada. Configurando $CIDR..."
sudo ip addr flush dev "$IFACE"
sudo ip addr add "$CIDR" dev "$IFACE"
sudo ip link set "$IFACE" up

echo "Subindo container do dnsmasq (só nesta interface, só DHCP)..."
cd "$(dirname "$0")"
docker compose up -d

echo
echo "Pronto. Acompanhe com: ./watch.sh"
