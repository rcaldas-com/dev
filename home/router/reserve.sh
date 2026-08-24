#!/bin/bash
# Reserva IP fixo por MAC. Uso:
#   ./reserve.sh <mac> <ip> [nome]
#   ./reserve.sh --remove <mac>
set -euo pipefail

HOSTS_FILE="$(dirname "$0")/hosts/hosts.conf"

reload() {
  # dnsmasq recarrega dhcp-hostsfile com SIGHUP, sem precisar recriar o
  # container nem soltar os leases já concedidos.
  docker kill --signal=SIGHUP home-router-test >/dev/null 2>&1 \
    && echo "dnsmasq recarregado" \
    || echo "aviso: container home-router-test não está rodando (config será aplicada quando subir)"
}

if [[ "${1:-}" == "--remove" ]]; then
  mac="${2:?uso: ./reserve.sh --remove <mac>}"
  sed -i "/^$mac,/Id" "$HOSTS_FILE"
  echo "removido: $mac"
  reload
  exit 0
fi

mac="${1:?uso: ./reserve.sh <mac> <ip> [nome]}"
ip="${2:?uso: ./reserve.sh <mac> <ip> [nome]}"
nome="${3:-}"

sed -i "/^$mac,/Id" "$HOSTS_FILE"
if [[ -n "$nome" ]]; then
  echo "$mac,$ip,$nome" >> "$HOSTS_FILE"
else
  echo "$mac,$ip" >> "$HOSTS_FILE"
fi
echo "reservado: $mac -> $ip ${nome:+($nome)}"
reload
