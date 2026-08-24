#!/bin/bash
# Reconstroi a tabela nftables de mapeamento de intranet a partir do
# intranet-map.conf e aplica atomicamente (valida com -c antes de trocar).
set -euo pipefail

IFACE="enxd03745ea2d6b"
DIR="$(cd "$(dirname "$0")" && pwd)"
MAP_FILE="$DIR/intranet-map.conf"
RULESET=$(mktemp)

{
  echo "table ip home_intranet {"
  echo "  chain prerouting {"
  echo "    type nat hook prerouting priority dstnat; policy accept;"
  while read -r stable real _rest; do
    [[ -z "$stable" || "$stable" == \#* ]] && continue
    echo "    iifname \"$IFACE\" ip daddr $stable dnat to $real"
  done < "$MAP_FILE"
  echo "  }"
  echo "  chain output {"
  echo "    type nat hook output priority -100; policy accept;"
  while read -r stable real _rest; do
    [[ -z "$stable" || "$stable" == \#* ]] && continue
    echo "    ip daddr $stable dnat to $real"
  done < "$MAP_FILE"
  echo "  }"
  echo "}"
} > "$RULESET"

sudo nft -c -f "$RULESET"
sudo nft delete table ip home_intranet 2>/dev/null || true
sudo nft -f "$RULESET"
rm -f "$RULESET"

count=$(grep -vc '^#\|^$' "$MAP_FILE" 2>/dev/null) || count=0
echo "mapeamento de intranet aplicado ($count entrada(s))"
