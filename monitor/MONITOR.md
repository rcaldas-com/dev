# Monitor — logs de serviço (estado em 23/08/2026)

> Documento de partida. Serve pra abrir um chat dedicado a continuar o
> Monitor por-serviço sem precisar redescobrir o que já foi feito aqui.
> Mesmo espírito do `home/HOME.md`.

## Contexto — o que já existia antes desta sessão

O Monitor (implementado em `web/`, ver `web/CLAUDE.md`) até aqui era só
**por host**: heartbeat a cada 60s (`/heartbeat`, `lib/monitor.ts`) reporta
CPU/disco/memória/túnel de cada host da frota, abre/fecha incidentes em
`monitor_incidents` e alerta por email na transição. Dashboard em
`web/app/monitor`. **Nenhum log de aplicação de nenhum serviço chegava
nesse sistema** — nem do próprio `web`.

`web/CLAUDE.md` já tinha a seção "Próximo módulo: monitoramento/backup
por serviço" com o inventário de onde cada serviço roda — essa tabela foi
o ponto de partida do que segue.

O coletor central de log de **host** já existia em produção: rsyslog em
`us`, `/etc/rsyslog.d/10-collector.conf`, escuta `imtcp` em
`127.0.0.1:514` (hosts remotos chegam pelo túnel reverso que o agente já
mantém), separa por `%HOSTNAME%` da mensagem syslog em
`/var/log/remote/<host>/syslog.log`. Retenção: `/etc/logrotate.d/rcaldas-remote`,
7 dias, `maxsize 200M`, glob `/var/log/remote/*/*.log`.

## O que foi feito nesta sessão

**Gatilho real**: uma wallet BTC externa (chave pública, somente leitura)
ficou dias com a cotação falhando (`blockstream.info` instável, sem
fallback) e ninguém percebeu — o único registro era um `console.error` no
stdout do container, sem rotação, e provavelmente já perdido (o wallet já
tinha sido redeployado desde então; container recriado = log novo).

Duas coisas resolvidas:

### 1. Fallback de fonte BTC (`wallet/app/lib/bitcoin.ts`)

`mempool.space` como fallback de `blockstream.info` — mesma API Esplora,
mesmo parsing. Já commitado/deployado, não é mais um problema em aberto.

### 2. Log de aplicação de cada serviço no coletor central (o que interessa aqui)

**Desenho**: como os serviços rodam no próprio `us` (não em hosts
remotos), não precisam do túnel — o driver `syslog` do Docker aponta
direto pro rsyslog local (`127.0.0.1:514`). Nova regra,
`/etc/rsyslog.d/05-docker-services.conf` (**carrega antes** de
`10-collector.conf` — 05 < 10 na ordem alfabética, e aquele arquivo tem
um `stop` incondicional pra todo `imtcp` que engoliria essas mensagens se
carregasse depois):

```
template(name="LocalServiceFile" type="string"
         string="/var/log/remote/us/%programname%.log")

if $inputname == "imtcp" and $hostname == "localhost" then {
    action(type="omfile" dynaFile="LocalServiceFile"
           createDirs="on" dirCreateMode="0750" fileCreateMode="0640")
    stop
}
```

**Gotcha que definiu o desenho**: o driver `syslog` do Docker manda
`HOSTNAME` **sempre** `"localhost"` no campo syslog — testado, `--hostname`
do container não muda isso. Por isso a separação é por `%programname%`
(o `tag` do log-opt), não por host — mesmo padrão que `49-haproxy.conf`
já usa (`:programname, startswith, "haproxy"`).

**Resultado**: cai em `/var/log/remote/us/<serviço>.log`, dentro do MESMO
glob que o logrotate da frota já cobre — retenção de 7 dias automática,
zero mudança na rotação.

**Aplicado em** (`docker-compose.prod.yml`, raiz deste repo — o deploy
real em produção fica em `/var/rcaldas/rcaldas`, **não** `/var/rc-web`
como uma nota antiga em `web/CLAUDE.md` ainda diz):

```yaml
logging:
  driver: syslog
  options:
    syslog-address: "tcp://127.0.0.1:514"
    tag: "<nome-do-serviço>"
```

Ligado em `wallet`, `web`, `car`, `ccxt`, `emailer`. **Não** ligado em
`site` (nginx estático — logs de acesso/erro do nginx, não avaliado se
vale a pena) nem `redis` (infra, não serviço de aplicação).

**Validado em produção**: os 5 containers foram recriados/reiniciados,
confirmei saída real de cada um chegando no arquivo certo
(`/var/log/remote/us/{wallet,web,car,ccxt,emailer}.log`), e que a coleta
de host da frota (`tp`, `bag`, `lev`) continuou normal depois de dois
restarts do rsyslog (o serviço não tem `ExecReload` — restart é a única
opção, e é seguro: os forwarders TCP da frota reconectam sozinhos).

**Erro cometido no processo** (documentado pra não repetir): apaguei um
arquivo de log de teste (`rm`) enquanto o rsyslog ainda tinha ele aberto
(cache de `dynaFile` do `omfile`) — as escritas seguintes foram pro inode
órfão, invisíveis, até um segundo restart do rsyslog. Lição: nunca `rm`
um arquivo em `/var/log/remote/` com o rsyslog rodando; se precisar
limpar, `> arquivo` (truncar) ou reiniciar o rsyslog depois.

## Sessão 2 — visualizador de log centralizado (Grafana + Loki + Alloy)

Resolve o item 1 da lista de "em aberto" que estava aqui embaixo: os logs
agora são pesquisáveis numa UI, com gráfico e retenção de 90 dias, em vez
de só existirem como arquivo alcançável por `ssh us` + sudo.

**Stack**: `grafana/loki:3.7.6` + `grafana/alloy:v1.18.1` +
`grafana/grafana:13.2.0`, três serviços novos no `docker-compose.prod.yml`.
Imagens públicas — não passam pelo `registry.rcaldas.com` e não dependem de
build/push, ao contrário do resto da stack.

**É Alloy, não Promtail**: o Promtail chegou ao fim de vida em 02/03/2026.
Mesmo papel, mesma arquitetura, só o binário e a sintaxe da config mudam.

**Por que essa stack e não ELK/Graylog**: o `us` tem ~1,7Gi de RAM livre e
**zero swap** — um OpenSearch sozinho quer 1-2GB de heap. Medido em teste
local com os logs reais, o conjunto todo fica em ~380MB (loki 106, grafana
222, alloy 50).

**Desenho**: o Alloy lê os arquivos que o rsyslog **já** escreve
(`/var/log/remote/*/*.log`). Nada do que a sessão 1 montou mudou — rsyslog,
`05-docker-services.conf` e o logrotate de 7 dias continuam iguais. O Loki é
**aditivo**: os arquivos seguem sendo a fonte bruta de 7 dias, o Loki é o
índice pesquisável e o histórico de 90 dias. De quebra passou a cobrir o
syslog de host da frota (`bag`/`lev`/`tp`), que já chegava no mesmo
diretório e é a maior parte do volume (80 dos 81MB).

**Rótulos**: só `host` e `service`, derivados do **caminho**, não do
conteúdo — o driver syslog do Docker fixa `HOSTNAME=localhost` pra todo
container, então a linha não sabe de quem é, mas o caminho sabe.
`programname` e `pid` vão como *structured metadata*, nunca como label:
`pid` muda a cada restart e viraria explosão de cardinalidade.

**Exposto** em `logs.rcaldas.com` (Cloudflare proxied) → HAProxy →
`127.0.0.1:8616`, login do próprio Grafana, signup desligado, senha em
`GF_SECURITY_ADMIN_PASSWORD` no `.env`. O compose **falha na subida** se ela
estiver vazia, de propósito: Grafana sem senha cai no `admin/admin` padrão,
e isso ficaria na internet.

### Gotchas — todos verificados em teste local antes do deploy

1. **Permissão.** `/var/log/remote/` é `0750 root:root` e os arquivos
   `0640 root:root`. A imagem do Alloy roda como não-root por padrão →
   precisa de `user: root` no compose, senão o tail falha **em silêncio** e
   o Loki fica vazio sem erro óbvio.
2. **Arquivo de posições em volume nomeado.** Sem isso todo restart
   reingere tudo e duplica linha. Testado: 4024 entradas antes e depois de
   um `restart` do alloy, marcador único aparecendo 1×.
3. **Timestamp.** O formato BSD do rsyslog não tem ano nem timezone, e o
   `us` roda em `-03`. O `location = "America/Sao_Paulo"` no
   `stage.timestamp` é obrigatório — sem ele tudo fica 3h deslocado, em
   silêncio. O **ano** o Alloy infere sozinho (testado: linha crua
   `Aug 23 05:48:39` virou `2026-08-23 05:48:39`); não precisa de template.
4. **Log com mais de 3h só aparece depois do flush do ingester.** Custou
   uma depuração: na primeira subida as linhas antigas chegam no Loki
   (`loki_distributor_lines_received_total` bate exato, zero descarte) mas
   somem das consultas, porque o querier só pergunta ao ingester dentro de
   `query_ingesters_within` (3h) e o chunk ainda não foi pro store. Não é
   bug — espera o flush (até ~30min) antes de concluir que quebrou.
5. **`GF_SERVER_ROOT_URL`** é obrigatório: atrás de TLS terminado no
   HAProxy, sem ele o Grafana monta redirect e URL de asset em `http://`.
   Daí também o `X-Forwarded-Proto https` no backend.
6. **Rotacionados fora do glob.** `*.log` não casa `syslog.log.1` nem
   `.gz` — que é o certo: já foram lidos enquanto eram o arquivo corrente.
   Incluí-los reingeriria tudo duplicado a cada rotação. Testado com um
   rename simulando o logrotate: a linha do arquivo novo chegou, o `.1` não
   virou target.
7. **Sem swap.** Os limites de memória no compose não são decorativos, e os
   números do teste local ficaram curtos na máquina real: o Grafana foi pra
   512M (fica em ~310MB de ocioso no `us`, contra 222MB local) e o Alloy pra
   192M (bateu 117MB no backfill inicial, 91% de um teto de 128M).
8. **`GOMEMLIMIT` no Alloy.** O GC do Go **não enxerga o limite do cgroup**:
   o Alloy assentou em 165MB de um teto de 192M (86%) e não descia — ele
   cresce o heap até o container morrer. Com `GOMEMLIMIT=150MiB` o GC aperta
   ao se aproximar em vez de estourar, e ele caiu pra ~53MB em regime. Sem
   swap no host, isso protege a caixa inteira, não só o container.
9. **Hostname novo exige certificado.** Só criar o registro na Cloudflare e o
   backend no HAProxy dá **526** (a Cloudflare não valida o cert da origem).
   Emitir com
   `certbot certonly --standalone --preferred-challenges http --http-01-address 45.56.114.108 --http-01-port 8889 -d <host>`
   e depois rodar `/var/rcaldas/live/haproxy/renew_certbot.sh`, que concatena
   `privkey+fullchain` de cada dir de `/etc/letsencrypt/live/` em
   `live/haproxy/certs/<host>.pem` e recarrega o HAProxy.

### Números reais em produção (23/08/2026, logo após subir)

| | valor |
|---|---|
| linhas indexadas (backfill de 7 dias) | 282.208 |
| disco do Loki pra esses 7 dias | **3,0MB** (contra 81MB de log cru) |
| projeção pros 90 dias de retenção | ~40MB |
| memória em regime | alloy 53MB, loki 81MB, grafana 212MB (~347MB) |
| cobertura | hosts `us`/`bag`/`lev`/`tp`; serviços `web`/`car`/`wallet`/`ccxt`/`emailer` + `syslog` |

A compressão do Loki é o número que surpreende: 81MB de log cru viram 3MB
indexados. O medo inicial de disco (`/var` apertado) não se aplica — dava
pra guardar bem mais que 90 dias se quisesse.

### `monitor-worker` removido

Apagado em commit próprio. Não abre buraco: o comentário de
`sweepOfflineHosts` (`web/lib/monitor.ts`) já documentava que ele nunca foi
pra produção e reimplementava pior o `upsertIncident`/`resolveIncident`.
Host-down é detectado por uma varredura que pega carona no heartbeat de
qualquer host, com trava no Redis (`monitor:offline-sweep`), abrindo
incidente após 5 min sem heartbeat.

## Sessão 3 — log do `us`, firewall, dashboards e mail no journal

### Log do próprio `us` no Loki — via **journal**, não rsyslog

Cobertura foi de 6 para **38 serviços**. A escolha da fonte tem motivo
medido, e corrige uma afirmação errada que ficou registrada antes ("o rate
limit resolveu o flood pra zero"):

O rsyslog **perdeu o kernel pro journald**. As mensagens do nftables
(`LIMBO`) existiam só no ring buffer e no journal: `grep LIMBO` dava **zero**
em `/var/log/kern.log`, `/var/log/syslog` e `/var/log/messages`, e o
`kern.log` parou de ser escrito às 14:23. No journal eram **14.401 linhas em
24h** — exatamente o teto de `10/minute`. A regra nunca parou de logar; o log
é que não ia pro disco onde se procurou.

O journal é superconjunto dos arquivos no resto: `sshd` 963 linhas contra 0
(auth é excluída do syslog por padrão no Debian), `CRON` 4.896 contra 1.143,
`mailu-front` 16.300 contra 11.373.

`max_age = "24h"` porque o journal está em 988MB, no próprio
`SystemMaxUse=1G` — sem teto, o primeiro start ingeriria tudo e estouraria a
memória. `service` vem do `SYSLOG_IDENTIFIER` (31 distintos, contados antes
de virar label). `fail2ban` entra por arquivo: é o único fora do journal.

### nftables: 10 → 100/minute, e a porta 21114 liberada

Trocado com `nft replace rule`, **não** recarregando `/etc/nftables.conf`. O
arquivo começa com `flush ruleset` e um reload apagaria as regras que o
**fail2ban** instalou (`table ip filter`/`ip6 filter`) sem ele saber — bans
parariam de valer em silêncio.

Resultado: **~43/min sem saturar o teto**. A 10/min estava saturado, ou seja,
amostra truncada.

⚠️ **O log é amostra; o contador é censo.** Se o tráfego passar de 100/min o
log trunca de novo. Pra contagem exata use o `counter ... "total unfiltered
input packets"` da própria regra.

**Análise de 7 dias (105.151 linhas dropadas):**

| porta | linhas | leitura |
|---|---|---|
| TCP 21114 | **53.603** (51%) | cliente RustDesk legítimo — 52.753 de um IP só |
| TCP 22 | 12.365 | força bruta distribuída (bloco `91.92.42.x`) |
| TCP 8080/3389/8443/445 | ~1.000 | scan genérico |
| GRE (proto 47) | 194 | espalhado por IPs distintos = scan, não túnel |

**A 21114 era o único tráfego legítimo sendo dropado** — liberada
(`tcp dport 21114-21119`). Nada escuta nela (é o console do RustDesk
**Pro**; rodamos a OSS `hbbs 1.1.14`), mas isso já melhora: com `drop` o
cliente retransmite pra sempre, com `accept` recebe RST e desiste. Volume
total caiu de ~43 para ~25 drops/min.

### Dashboards provisionados

Dois, versionados em `monitor/grafana/dashboards/`, recarregados a cada 30s
sem restart. Editar pela UI **não** persiste (`allowUiUpdates: false`) — o
que vale é o arquivo.

- **Frota — volume de log**: linhas/min por host e por serviço, tabela de
  volume, e um painel de "linhas com cara de erro" com as três exclusões de
  ruído conhecidas já embutidas.
- **Segurança**: drops/min (com limiar visual em 95, onde o log satura),
  top portas e IPs, bans por jail, e auth SSH falha × bans sobrepostos.

Ficam em `/etc/grafana/dashboards` e não dentro de `/var/lib/grafana`, que é
volume nomeado — montar bind dentro de volume é aninhamento frágil à toa.

#### Três armadilhas que só apareceram ao validar os painéis

1. **`max_query_series` (500) estourava os painéis de firewall.** Cada porta
   e cada IP distinto vira **uma série** na hora da consulta; em poucas horas
   de scan passa de 500 e a consulta morre com
   `maximum number of series reached` — painel vazio, sem erro visível na
   tela. O `topk` **não** salva: o Loki monta todas as séries antes de
   recortar. Subido pra 5000 em `monitor/loki.yaml`.
   Não confundir com cardinalidade de *label* (essa continua baixa: `host` +
   `service`): são séries efêmeras extraídas por `| regexp` do texto, que só
   existem durante a consulta.
2. **Trocar o `uid` de um datasource já provisionado derruba o Grafana.** Ele
   procura o uid novo, não acha, falha o módulo de provisionamento inteiro e
   entra em **loop de restart** — a UI não sobe. Resolvido com
   `deleteDatasources` no mesmo arquivo, que apaga pelo nome antes de
   recriar.
3. **Bind mount de config não reinicia sozinho.** `docker compose up -d loki`
   não recria o container quando só o arquivo montado mudou (a spec é a
   mesma), e o Loki lê a config só no start. Precisa de `restart` explícito.
   Vale pro Loki e pro Alloy.

#### O que os painéis mostraram de imediato

- **`fail2ban`: 2.610 linhas "already banned" e ZERO bans novos em 24h — de
  apenas 4 IPs distintos.** Um ban efetivo deveria fazer o IP parar de gerar
  linha; 4 endereços reincidindo milhares de vezes sugere que a **ação de ban
  pode não estar bloqueando de fato**. Vale investigar (jail
  `bad-auth-bots`). Ficou registrado nos painéis como duas séries separadas
  em vez de um "bans" que mostraria zero e pareceria saúde.
- **O painel de SSH fica em zero no `us`, e está certo.** A chain não tem
  `tcp dport 22 accept` — o acesso real é pela 8422. As 12.365 tentativas na
  porta 22 morrem no firewall e nunca chegam no `sshd`; elas aparecem no
  painel de firewall, não no de SSH.
- **A 21114 parou de ser dropada às 20:02:11**, no minuto da mudança, e
  seguiu em zero. Confirmado com a regra viva e 2h de silêncio.

### Mail local → journal (a decisão "B")

`scripts/mail-to-journal.sh`, instalado como `sendmail` em `bag`. Testado
ponta a ponta: `mail -s ... root` → journal (`programname=local-mail`) →
túnel → Loki.

**A descoberta que justificou a escolha:** os hosts *têm* MTA (postfix
3.10.13) — a checagem anterior que dizia "sem MTA" estava errada, foi PATH
de shell não-interativo, o mesmo erro que fez o `smartctl` parecer ausente.
O problema real é pior: no `us` há **17 mensagens presas na fila desde
21/08** (42 KB), todas do `MAILER-DAEMON` pro Gmail, falhando com
`local data error while talking to us.rcaldas.com`. O canal de email está
quebrado há dias, em silêncio — exatamente o modo de falha que deixou o
alerta do `zed` sem sair.

⚠️ Não instalei o shim no `us`: lá o postfix do host convive com o Mailu, e
desviar o `sendmail` merece olhar antes. **A fila presa continua presa.**

### RustDesk movido para `/var/rcaldas/rustdesk`

Estava em `/var/rustdesk`. `down` → `mv` → `up`, com `logging: syslog`
adicionado (tags `hbbs`/`hbbr`) pra cair no coletor como os outros serviços.

Chave do servidor preservada e conferida por hash antes e depois
(`id_ed25519` = `77f52aa1…`, pub `PJzb9BstlwNeGtTOyVCl9AW3vz9pYMxVkKAhxyDinys=`).
Se um dia mover de novo: **`data/` tem que ir junto** — perder essa chave
obriga re-adicionar o servidor em cada cliente.

## Pendências levantadas na Sessão 2

### P0 — `bag`: disco `sdb` falhando no pool `tank`

**Atualização da Sessão 3 — SMART instalado e o diagnóstico fechado.** Não é
a energia instável; é o disco.

| atributo | sdb | sda | sdc |
|---|---|---|---|
| Reallocated_Sector_Ct | **734** | 0 | 0 |
| Reported_Uncorrect | **9.891** (value=001, thr=000) | — | — |
| ATA Error Count | **8.409** | 1 | 50 |
| Power_On_Hours | 7.107 | 17.549 | 19.668 |
| Power_Cycle_Count | 5.011 | 4.470 | 3.368 |

Os três discos viveram as **mesmas quedas de energia** (4-5 mil ciclos cada).
`sda` e `sdc` têm **2,5× mais horas ligados e zero setores realocados**. Se
a tomada fosse a causa, os três estariam machucados — só o `sdb` está, e ele
é o mais novo. É unidade ruim.

⚠️ **O teste longo passou** ("Completed without error") — e isso é a
armadilha: o SMART lê o mapeamento *atual*, e os 734 setores ruins já foram
remapeados pra reserva. Só reprova quando a reserva acabar. `Reported_Uncorrect`
está em `value=001` contra `threshold=000`: **um ponto** de reprovar.

Recomendação: **substituir, não reinserir**. E não precisa tirar do pool pra
testar (o self-test roda no próprio disco). Tirar é a parte perigosa —
`raidz1` com 3 discos tolera 1 falha, e com o `sdb` offline ficam **zero**
redundância. Quando o disco novo chegar, use
`zpool replace tank sdb <novo>` **com o sdb ainda plugado**: assim o ZFS
pode ler dele durante o resilver se outro tropeçar.

### P0-original — como foi descoberto

Descoberto ao responder "tem mensagem de ZFS nos logs?". **Não é hipótese**:

```
pool: tank / raidz1-0 (sdc, sda, sdb) -- ONLINE mas:
  sdb   ONLINE   READ 6   CKSUM 2
status: One or more devices has experienced an unrecoverable error.
action: Determine if the device needs to be replaced
scan: resilvered 260M in 00:00:30 on Thu Aug 20 12:07:00 2026
```

Não é histórico: o Loki tem **7 eventos de `class=io ... err=5`** (erro de
I/O de verdade, não só checksum) em `sdb1` em **23/08 às 04:00**, hoje. O
disco está errando agora.

Agravantes:
- **`raidz1` = paridade simples.** Um disco já errando; se ele sair e outro
  tiver setor latente durante o rebuild, perde dado.
- Os três são **HDD de notebook 5400rpm de consumo** (`TOSHIBA MQ01ABD050`,
  `ST9500325AS`, `HGST HTS545050A7E680`), todos 465,8G.
- **`smartmontools` não está instalado** — zero visibilidade de SMART.
- O `zed` está ativo e **avisaria** (`ZED_EMAIL_ADDR=rclgsm@gmail.com`), mas
  o `bag` **não tem MTA** (`sendmail` e `postfix` ausentes; só `mail`/`mailx`
  sem transporte). O aviso nunca saiu da máquina — por isso passou batido
  desde 20/08.

### P1 — o syslog do próprio `us` não está no Loki

Os hosts da frota (`bag`/`lev`/`tp`) mandam o syslog deles pelo túnel, mas o
`us` é o coletor e **nunca manda pra si mesmo**. Resultado: `/var/log/syslog`
do `us` (3,2MB, ~20k linhas) está fora do viewer — justo o host que motivou
o projeto.

O que fica invisível: `mailu-front` (**10.712 linhas**, o maior falador de
longe), `sshd`, `fail2ban` (9 jails ativas), `kernel`, `dockerd`, `CRON`.

Conserto provável: uma regra de `omfile`/`omfwd` local no rsyslog do `us`
escrevendo em `/var/log/remote/us/syslog.log` — cai no glob que o Alloy já
lê, sem tocar em nada mais. **Cuidado**: o `10-collector.conf` tem um `stop`
incondicional, e o `05-docker-services.conf` filtra por
`$inputname == "imtcp"`; a regra nova precisa não colidir com nenhum dos
dois nem criar laço de realimentação.

### P2 — visibilidade de atacante: ainda não existe

Resposta honesta pra "já dá pra ver padrões e portas usadas pelos
atacantes?": **ainda não**, por dois motivos independentes.

1. O syslog do `us` está fora do Loki (P1). Sem isso, nem `sshd` nem
   `fail2ban` nem `mailu-front` são pesquisáveis.
2. **A regra de log do nftables não produz nada hoje.** Ela existe
   (`limit rate 10/minute burst 5 packets log prefix "LIMBO: "`), mas o
   `grep LIMBO` dá **0** em `syslog`, `syslog.1`, `messages` e `messages.1`.
   O rate limit resolveu o flood que motivou tudo — só que resolveu pra
   zero. As "50 linhas de firewall" que aparecem num grep ingênuo são
   `systemd` falando de `nftables.service`, não pacote dropado.

Ou seja: pra ter dado de scan/porta é preciso **decidir voltar a logar** e
calibrar o limite (o motivo original de desligar foi encher o disco), ou
tirar o sinal de outra fonte. A fonte mais rica que **já existe** é o
`fail2ban.log` (IP, jail, ban/unban) — é o "quem está atacando" pronto,
sem custo de disco novo.

### P3 — ZFS: o que o log dá e o que não dá

Medido, não suposto. Em 24h no `bag` o filtro `/zfs|zed|scrub/i` traz 153
linhas, e **todas são ruído**: `zfs-auto-snap` (81) e `CRON` (66) de
snapshot, mais 3 `systemd` e 3 `sshd` (esses últimos casaram por causa de um
usuário chamado `zedooo` numa tentativa de invasão — falso positivo puro).

- **Evento**: sim, chega naturalmente. O `zed` escreve
  `class=checksum`/`class=io` no syslog e isso **já flui pro coletor** —
  provado, está no Loki.
- **Estado**: não, nunca. Saúde do pool, resultado/agenda de scrub, SMART e
  capacidade **não passam pelo syslog**. Um pool degradando em silêncio não
  gera linha nenhuma — que é exatamente o caso do `sdb` entre 20/08 e hoje.

Conclusão: log resolve metade. A outra metade quer uma coleta de **estado**,
periódica.

## Em aberto — próximos passos possíveis

1. ~~**Ler esses logs em algum lugar útil.**~~ **Feito** — ver a seção
   "Sessão 2" acima.
2. **Instrumentação → incidente.** A ideia original era os apps
   escreverem direto em `monitor_incidents` (mesmo Mongo compartilhado
   entre `web` e `wallet`) quando uma leitura falha repetidamente — o
   `/monitor` já é source-agnostic (`getMonitorOverview` lê
   `monitor_incidents` sem filtrar por host), então apareceria sem
   nenhuma mudança no `web`. **Adiado de propósito** — decisão explícita
   de revisar o desenho antes (threshold de quantas falhas seguidas abre
   incidente, severidade, etc.) antes de mexer numa collection de
   produção que já dispara email de alerta.
   - Alternativa, agora bem mais curta com a Sessão 2 no ar: regra no
     **ruler do Loki** → contact point webhook → endpoint novo no `web`
     que chama o `upsertIncident` **que já existe**
     (`web/lib/monitor.ts`). Reaproveita dedupe, email só na transição,
     teto de 10 emails/host/hora e `emailSubject` estável — e o incidente
     aparece no `/monitor` sem tocar no dashboard, porque
     `getMonitorOverview` já é agnóstico de origem. Não exige mudar código
     de app nenhum.
   - **A lista de exclusão é pré-requisito, não refinamento.** Medido no
     log real: no `web.log`, **8 de 22 linhas** casam com `error|warn` — e
     as 8 são ruído de boot do pdfjs, incluindo uma que contém
     literalmente `Error: Cannot find module '@napi-rs/canvas'`. No
     `emailer.log`, a linha **saudável** `❌ Erros: 0` também casa. Uma
     regra ingênua mandaria email a cada deploy. Com o Grafana no ar dá
     pra escrever a query contra o log real e ver quantas vezes ela teria
     disparado nos últimos dias **antes** de ligar qualquer email.
   - Quando for: histerese espelhando o `CONSECUTIVE_BREACHES_REQUIRED = 3`
     que já existe, e no `summary` a última linha **redigida** (sem o
     prefixo syslog, truncada em ~200 chars, blobs tipo credencial
     `[A-Za-z0-9_-]{24,}` trocados por `***`) — o summary vira corpo de
     email.
3. **Estender pra `site`** (e decidir se `redis` faz sentido).
4. **CI/CD** (`site/SITE.md`) é um projeto separado, não relacionado a
   este — só compartilha o mesmo servidor `us`.
