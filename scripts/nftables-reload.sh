#!/bin/bash
# Recarrega o /etc/nftables.conf com seguranca.
#
# POR QUE ISTO EXISTE
# -------------------
# /etc/nftables.conf comeca com `flush ruleset`, e o `iptables` desta
# maquina e' nf_tables -- ou seja, as regras do Docker e do fail2ban vivem
# no MESMO ruleset e sao apagadas junto. Depois de um reload puro:
#
#   - o Docker perde as chains DOCKER/DOCKER-USER e o NAT das portas
#     publicadas (containers ficam inalcancaveis de fora);
#   - o fail2ban perde a regra que faz o ipset de banidos valer alguma
#     coisa (os IPs continuam "banidos" na lista e ninguem bloqueia).
#
# O segundo e' pior porque e' SILENCIOSO: nada quebra visivelmente, a
# protecao so' para de existir. Foi assim que a jail bad-auth-bots ficou
# com 24.563 falhas contra 8 bans.
#
# A ORDEM IMPORTA: o Docker precisa vir antes, porque e' ele quem recria a
# chain DOCKER-USER; o fail2ban insere DENTRO dela.
#
# Uso:
#   sudo scripts/nftables-reload.sh          # confere, aplica e restaura
#   sudo scripts/nftables-reload.sh --check  # so' valida a sintaxe
set -euo pipefail

CONF="/etc/nftables.conf"

[[ $EUID -eq 0 ]] || { echo "precisa de root"; exit 1; }

echo "==> validando $CONF"
nft -c -f "$CONF"

if [[ "${1:-}" == "--check" ]]; then
  echo "    sintaxe ok (nada aplicado)"
  exit 0
fi

echo "==> guardando o ruleset atual"
BKP="/root/nftables-ruleset-$(date +%Y%m%d-%H%M%S).bak"
nft list ruleset > "$BKP"
echo "    $BKP"

echo "==> aplicando"
nft -f "$CONF"

echo "==> recriando as regras do Docker (ele e' quem cria a DOCKER-USER)"
systemctl restart docker
# Sem esta espera o fail2ban abaixo pode inserir na chain antes de ela
# existir, falhar em silencio, e a gente sai daqui achando que restaurou.
for i in $(seq 1 30); do
  iptables -S DOCKER-USER >/dev/null 2>&1 && break
  sleep 1
done
iptables -S DOCKER-USER >/dev/null 2>&1 \
  || { echo "    ERRO: DOCKER-USER nao apareceu -- nao vou reiniciar o fail2ban por cima"; exit 1; }

echo "==> recriando as regras do fail2ban (actionstart de cada jail)"
systemctl restart fail2ban

echo "==> conferindo o que ficou de pe"
for s in nftables docker fail2ban; do
  printf '    %-10s %s\n' "$s" "$(systemctl is-active $s)"
done

echo "    regras em DOCKER-USER:"
iptables -S DOCKER-USER | sed 's/^/      /'

echo "    ipsets do fail2ban e quem os referencia:"
for s in $(ipset list -n 2>/dev/null | grep '^f2b-' || true); do
  ref=$(ipset list "$s" 2>/dev/null | awk '/^References:/{print $2}')
  n=$(ipset list "$s" 2>/dev/null | awk '/^Number of entries:/{print $4}')
  printf '      %-28s entradas=%-5s referencias=%s\n' "$s" "$n" "$ref"
  # referencias=0 significa que o conjunto existe mas nenhuma regra o
  # consulta: e' exatamente o estado em que o ban nao bane.
  [[ "$ref" == "0" ]] && echo "        AVISO: ninguem consulta este conjunto -- o ban nao esta valendo"
done
