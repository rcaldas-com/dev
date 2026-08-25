#!/bin/bash
# Compartilha a internet deste notebook (saindo por <wan-iface>) com a rede
# de teste isolada (entrando por <lan-iface>, ex: 10.84.0.0/24).
#
# Uso temporário -- é o notebook fazendo de WAN pro rock64 testar /init
# e afins antes de virar router de verdade. Nada disso é permanente por
# padrão; use down.sh (--remove) pra desfazer.
#
#   sudo ./share-internet.sh <wan-iface> <lan-cidr>
#   sudo ./share-internet.sh --remove
set -euo pipefail

NFT_TABLE="ip router_wan_share"

if [[ "$EUID" -ne 0 ]]; then
  echo "Precisa rodar como root (sudo)." >&2
  exit 1
fi

if [[ "${1:-}" == "--remove" ]]; then
  nft delete table $NFT_TABLE 2>/dev/null || true
  echo "Compartilhamento removido."
  exit 0
fi

WAN_IFACE="${1:?uso: sudo ./share-internet.sh <wan-iface> <lan-cidr>}"
LAN_CIDR="${2:?uso: sudo ./share-internet.sh <wan-iface> <lan-cidr>}"

if ! ip link show "$WAN_IFACE" >/dev/null 2>&1; then
  echo "Interface WAN $WAN_IFACE não encontrada." >&2
  exit 1
fi

if [[ "$(cat /proc/sys/net/ipv4/ip_forward)" != "1" ]]; then
  echo "1" > /proc/sys/net/ipv4/ip_forward
  echo "ip_forward habilitado (era 0)"
else
  echo "ip_forward já habilitado"
fi

RULESET=$(mktemp)
cat > "$RULESET" <<EOF
table $NFT_TABLE {
	chain postrouting {
		type nat hook postrouting priority srcnat; policy accept;
		ip saddr $LAN_CIDR oifname "$WAN_IFACE" masquerade
	}
}
EOF

nft -c -f "$RULESET"
nft delete table $NFT_TABLE 2>/dev/null || true
nft -f "$RULESET"
rm -f "$RULESET"

echo "Compartilhando internet: $LAN_CIDR -> $WAN_IFACE"
nft list table $NFT_TABLE
