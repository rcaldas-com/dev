#!/bin/bash
# Estado de disco -> journal -> coletor central -> Loki.
#
# POR QUE ISTO EXISTE
# -------------------
# O log da' EVENTO, nunca ESTADO. O zed do ZFS grita quando um erro JA
# aconteceu; um pool que esta degradando devagar nao gera linha nenhuma.
# Foi assim que o disco sdb do bag ficou 3 dias com erro de I/O sem
# ninguem saber -- e o que finalmente contou a historia nao foi o log, foi
# rodar `smartctl` na mao.
#
# Isto fecha essa metade: coleta o ESTADO periodicamente e joga no
# journal, que ja vai pro Loki. Zero plumbing novo -- sem MTA, sem
# endpoint, sem credencial, sem porta.
#
# Prioridade separa o que interessa: estado saudavel vai como `info`,
# problema vai como `err`. Assim uma regra de alerta filtra por nivel em
# vez de tentar adivinhar por texto.
#
# Instalacao (ver o timer no fim deste arquivo):
#   sudo install -m 755 disk-health.sh /usr/local/sbin/rcaldas-disk-health
#
# Depois procure no Grafana por: {service="disk-health"}

# Sem `-e`: isto e' COLETA, nao acao. Um smartctl que falha num disco nao
# pode impedir a checagem dos outros nem derrubar o timer.
set -uo pipefail

TAG="disk-health"
ok()      { logger -t "$TAG" -p daemon.info "$*"; }
problema(){ logger -t "$TAG" -p daemon.err  "$*"; }

# ---------------------------------------------------------------- ZFS ---
if command -v zpool >/dev/null 2>&1; then
  # `-x` e' o resumo: imprime "all pools are healthy" ou SO' os pools com
  # problema. Muito melhor que parsear o status completo.
  saida=$(zpool status -x 2>/dev/null)
  if [ -n "$saida" ]; then
    if [ "$saida" = "all pools are healthy" ]; then
      ok "zfs: todos os pools saudaveis"
    else
      # Uma linha de log por linha de saida, de proposito: o Loki indexa
      # por linha, e um bloco de 20 linhas numa entrada so' fica ilegivel
      # na busca e impossivel de filtrar.
      printf '%s\n' "$saida" | while IFS= read -r linha; do
        [ -n "$linha" ] && problema "zfs: $linha"
      done
    fi
  fi

  # Contadores de erro por dispositivo. O `-x` acima pode dizer que esta
  # tudo bem enquanto um disco acumula CKSUM -- o ZFS corrige e segue.
  zpool list -H -o name 2>/dev/null | while IFS= read -r pool; do
    zpool status -p "$pool" 2>/dev/null | awk -v p="$pool" '
      # pula cabecalho ate a tabela de dispositivos
      /^\tNAME/ { emtabela=1; next }
      /^$/      { emtabela=0 }
      emtabela && NF>=5 {
        dev=$1; r=$3; w=$4; c=$5
        if (r ~ /^[0-9]+$/ && (r+0 || w+0 || c+0))
          printf "%s %s READ=%s WRITE=%s CKSUM=%s\n", p, dev, r, w, c
      }' | while IFS= read -r l; do
        [ -n "$l" ] && problema "zfs erros: $l"
      done
  done
fi

# -------------------------------------------------------------- SMART ---
if command -v smartctl >/dev/null 2>&1; then
  # Só discos de verdade: fora loop, zram, dm.
  lsblk -dno NAME,TYPE 2>/dev/null | awk '$2=="disk"{print $1}' | while IFS= read -r d; do
    [ -z "$d" ] && continue
    saude=$(smartctl -H "/dev/$d" 2>/dev/null | awk -F': *' '/overall-health/{print $2}')
    [ -z "$saude" ] && continue

    # PASSED e' o indicador MENOS informativo do SMART: ele so' reprova
    # quando um atributo cruza o limiar, e um disco pode ter centenas de
    # setores realocados muito antes disso. O sdb do bag passa no teste
    # longo com 734 realocados e Reported_Uncorrect a UM ponto do limite.
    # Por isso os contadores vao junto -- eles e' que contam a historia.
    attrs=$(smartctl -A "/dev/$d" 2>/dev/null | awk '
      /Reallocated_Sector_Ct/ {r=$10}
      /Current_Pending_Sector/ {p=$10}
      /Offline_Uncorrectable/  {o=$10}
      /Reported_Uncorrect/     {u=$10}
      END { printf "realoc=%s pendentes=%s incorrigiveis=%s reportados=%s", r+0, p+0, o+0, u+0 }')

    if [ "$saude" = "PASSED" ] && [ -z "${attrs##*realoc=0 pendentes=0 incorrigiveis=0*}" ]; then
      ok "smart /dev/$d: $saude ($attrs)"
    else
      problema "smart /dev/$d: $saude ($attrs)"
    fi
  done
fi

# ------------------------------------------------------------- systemd ---
# Timer sugerido (nao instalado por este script):
#
#   /etc/systemd/system/rcaldas-disk-health.service
#     [Unit]
#     Description=Coleta estado de disco (ZFS/SMART) para o journal
#     [Service]
#     Type=oneshot
#     ExecStart=/usr/local/sbin/rcaldas-disk-health
#
#   /etc/systemd/system/rcaldas-disk-health.timer
#     [Unit]
#     Description=Estado de disco de hora em hora
#     [Timer]
#     OnBootSec=5min
#     OnUnitActiveSec=1h
#     [Install]
#     WantedBy=timers.target
#
# De hora em hora, e nao a cada minuto: e' ESTADO, muda devagar, e
# smartctl acorda disco que estiver em standby.
