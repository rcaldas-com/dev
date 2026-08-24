#!/bin/bash
# Shim de sendmail: em vez de ENTREGAR mail local, joga no journal.
#
# Por que existe
# -------------
# Um monte de coisa do sistema so' avisa por mail local pro root e nunca
# passa pelo syslog: saida de cron que falhou, apt/unattended-upgrades,
# mdadm, smartd, zed. Sem MTA isso e' descartado em silencio.
#
# O caso real que motivou: o `zed` do `bag` estava configurado com
# ZED_EMAIL_ADDR e detectou o disco sdb com erro em 20/08/2026 -- mas o host
# nao tinha MTA, o aviso nunca saiu, e o problema so' apareceu 3 dias depois
# quando alguem foi olhar na mao.
#
# Por que nao um MTA de verdade
# -----------------------------
# Porque email e' fire-and-forget: sem estado, sem dedupe, sem "esta ruim
# AGORA?". E um email as 4h que ninguem le e' igual a nenhum email -- foi
# exatamente assim que o zed falhou, mesmo configurado. O journal ja vai pro
# Loki (retencao de 90 dias, pesquisavel, com grafico), que e' onde a gente
# de fato olha. Zero entrega pra configurar, zero coisa nova pra falhar.
#
# Instalacao (por host):
#   sudo cp mail-to-journal.sh /usr/local/sbin/mail-to-journal
#   sudo chmod 755 /usr/local/sbin/mail-to-journal
#   sudo ln -sf /usr/local/sbin/mail-to-journal /usr/sbin/sendmail
#   sudo ln -sf /usr/local/sbin/mail-to-journal /usr/lib/sendmail
#
# Depois disso, procure no Grafana por {service="local-mail"}.
#
# Cuidado: se um dia o host precisar mandar email DE VERDADE, isto esta no
# caminho. Remova os symlinks antes de instalar um MTA real.

set -euo pipefail

TAG="local-mail"

# O sendmail recebe o destinatario em argv e a mensagem inteira (cabecalho +
# corpo) em stdin. Nao interpretamos argv de proposito: o que importa e' o
# conteudo, e qualquer coisa que chegue aqui merece ser registrada.
destinatarios="$*"

# Prioridade err: e' aviso de coisa que deu errado, nao informativo. Isso faz
# a linha aparecer com nivel adequado no journal e no Grafana.
{
  echo "--- inicio de mail local (para: ${destinatarios:-root}) ---"
  # `cat` sem timeout: o sendmail sempre recebe stdin fechado pelo chamador.
  cat
  echo "--- fim de mail local ---"
} | /usr/bin/logger -t "$TAG" -p mail.err

exit 0
