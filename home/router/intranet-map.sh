#!/bin/bash
# Mapeia um IP estavel pro destino real de um servico, sem depender de DNS
# (nftables DNAT no caminho do pacote -- HOME.md, "intranet que nao
# depende de DNS"). Trocar onde o servico roda so muda uma linha aqui,
# nunca exige atualizar DNS nem reconfigurar cliente.
#
# Uso:
#   ./intranet-map.sh <ip-estavel> <ip-real> [comentario]
#   ./intranet-map.sh --remove <ip-estavel>
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
MAP_FILE="$DIR/intranet-map.conf"

if [[ "${1:-}" == "--remove" ]]; then
  stable="${2:?uso: ./intranet-map.sh --remove <ip-estavel>}"
  sed -i "/^$stable /d" "$MAP_FILE"
  echo "removido: $stable"
  "$DIR/intranet-apply.sh"
  exit 0
fi

stable="${1:?uso: ./intranet-map.sh <ip-estavel> <ip-real> [comentario]}"
real="${2:?uso: ./intranet-map.sh <ip-estavel> <ip-real> [comentario]}"
comentario="${3:-}"

sed -i "/^$stable /d" "$MAP_FILE"
if [[ -n "$comentario" ]]; then
  echo "$stable $real # $comentario" >> "$MAP_FILE"
else
  echo "$stable $real" >> "$MAP_FILE"
fi
echo "mapeado: $stable -> $real ${comentario:+($comentario)}"
"$DIR/intranet-apply.sh"
