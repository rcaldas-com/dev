#!/bin/bash
# Acompanha o arquivo de leases e mostra quem pegou IP.
set -euo pipefail

LEASES="$(dirname "$0")/leases/dnsmasq.leases"

echo "Esperando dispositivos em $LEASES ..."
echo "(Ctrl+C pra sair. Formato: expira mac ip hostname client-id)"
echo

touch "$LEASES"
tail -n +1 -F "$LEASES" | while read -r _expiry mac ip hostname _clientid; do
  echo "=== novo lease ==="
  echo "MAC:      $mac"
  echo "IP:       $ip"
  echo "Hostname: ${hostname:-<nenhum>}"
  echo "Próximo passo: ssh root@$ip   (Armbian default, vai pedir troca de senha)"
  echo "Se não responder: avahi-browse -art   |   nmap -sV $ip"
  echo
done
