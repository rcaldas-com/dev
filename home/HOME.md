# Home — Monitor de uma Rede Local

> Documento de partida. Serve pra abrir um chat dedicado ao Home sem
> precisar redescobrir o que já existe do lado do `web`/Monitor. O que
> está em "Contrato de integração" é fato verificado em produção; o resto
> é proposta, e está marcado como tal.

## O que é

O Monitor de hoje cuida de **hosts espalhados pela internet** — cada um
com seu IP público, alcançado por túnel SSH reverso quando está atrás de
NAT. O Home é o mesmo sistema virado pra dentro: **um host que é a
infraestrutura de uma LAN inteira** — DHCP, DNS, proxy, firewall, router,
VLAN, web e samba — e que, sendo um host com agente como qualquer outro,
continua visível e configurável pelo mesmo Monitor.

A diferença de fundo: no Monitor atual o host é o objeto. No Home o
objeto é a **rede** — e os dispositivos dentro dela podem não ter agente,
não ter shell, não ter tela e às vezes nem sistema operacional de verdade
(um esp32). O Home é quem os enxerga, nomeia, endereça e recupera.

## Por que não é só "instalar dnsmasq"

Três coisas que o rascunho pede e que nenhum roteador de prateleira faz:

1. **Balanceamento fino entre links, monitorável de verdade.** Não é
   failover binário. É saber a latência, perda e jitter de cada link em
   tempo real e mover *classes de tráfego* entre eles — e ver isso no
   Monitor, com histórico e incidente quando degrada. O balanceamento
   existe no Linux há décadas; o que não existe é a visibilidade.

2. **Intranet que não depende de DNS.** DNS na LAN é o ponto único de
   falha mais comum: caiu o resolver, "a internet caiu". A ideia é usar
   nftables pra fazer o mapeamento serviço→destino no caminho do pacote:
   um endereço estável (IP:porta, ou uma faixa reservada) que o nftables
   redireciona pro serviço onde quer que ele esteja rodando. DNS vira
   conveniência, não dependência.

3. **Mesh off-grid heterogênea.** esp32, raspberry, arduino, rock64 e x86
   na mesma malha, com papéis diferentes conforme o que cada um aguenta.
   Um esp32 não roda protocolo de roteamento de mesh; ele fala com um nó
   que roda.

---

## Contrato de integração — o que JÁ existe e deve ser reaproveitado

Tudo abaixo está em produção e testado. O Home deve **estender**, não
reimplementar.

### Agente e heartbeat

`app/install/route.ts` instala um agente bash (hoje `VERSION="2.2.0"`) que
roda por systemd timer a cada 60s e faz POST em `/heartbeat` com estado do
host. O servidor responde com o estado desejado. É um loop de
**reconciliação**, não de comandos: o agente compara o que existe com o
que deveria existir e corrige. Se o túnel cai, o próximo ciclo reabre
sozinho — sem ninguém mandar nada.

Esse é o modelo mental certo pro Home também. "O Monitor manda um comando
pro router" é frágil; "o router lê a config desejada e converge" se
recupera sozinho de reboot, de falha de rede e de erro de aplicação.

### Jobs (`hasJobs`)

Pra quando reconciliação contínua não cabe (coisa cara, pontual, que não
faz sentido checar todo minuto):

1. O heartbeat responde `"hasJobs":true` — um booleano, custo zero quando
   não há nada.
2. O agente faz POST em `/agent-jobs` com seu token e recebe a lista.
3. Executa e devolve o resultado pela mesma fila dos `results`.

Tipos são **whitelist** (`AgentJob['type']` em `lib/monitor.ts:122`, hoje
`'backup-config' | 'update-agent'`) — nunca comando arbitrário vindo do
servidor. O Home vai querer acrescentar tipos aqui (`apply-network-config`,
`renew-dhcp`, `flush-dns`, `rotate-ca`), e a regra se mantém: cada tipo é
uma ação conhecida do agente.

⚠️ **Problema de bootstrap já pago uma vez:** um agente antigo não tem o
código que processa jobs, então não consegue processar o job que o
atualizaria. Ao adicionar um tipo novo, os hosts precisam estar na versão
que o entende **antes** de você depender dele. Verifique a `version` no
Monitor antes de enfileirar em massa.

### Papéis de host

`backupRunner` (`lib/monitor.ts`) é o precedente: uma flag no host que diz
"este aqui executa os backups da frota". O que faz funcionar bem:

- Só um ativo por vez — marcar um desmarca o anterior.
- A troca é **autoconfigurável**: o servidor distribui a chave pública do
  runner pelo heartbeat e cada host a autoriza sozinho. Trocar de runner
  não exige reprovisionar host nenhum.
- Config sensível (senha do restic) fica **só no runner**, nunca no Mongo.

**Proposta:** generalizar pra `roles`, mantendo `backupRunner` funcionando
durante a migração:

```ts
roles?: {
  backup?:   { enabled: boolean; snapshotRoot?: string };
  router?:   { enabled: boolean; wan: string[]; lan: string[] };
  dhcpDns?:  { enabled: boolean; scopes: DhcpScope[] };
  storage?:  { enabled: boolean; shares: SambaShare[] };
  ca?:       { enabled: boolean };
}
```

E um instalador `/router` no padrão `curl … | bash` que já existe pra
`/init`, `/install`, `/init-auto`, `/setup-backup-runner`, `/remove-zxnet`.

### Túnel

O agente mantém um `ssh -fNR` persistente pro `us` que carrega **duas
direções no mesmo processo**: `-R` dá acesso ao host, `-L` leva o syslog
dele pro coletor central. Chaves aprovadas com `restrict,port-forwarding`
— servem pra túnel, nunca pra shell.

Pro Home isso resolve um problema chato de graça: **a LAN de casa fica
alcançável pelo `us` sem abrir porta nenhuma no roteador da operadora**, e
funciona atrás de CGNAT.

### Incidentes

`upsertIncident` deduplica por `key` com `$inc: count`, e o email sai na
**transição** (abriu/resolveu), nunca por heartbeat. Qualquer `result` com
`type: "alarm"` vira incidente sem mudar código no servidor — então um
alarme de link degradado gerado pelo router entra direto.

Chaves sugeridas pro Home: `link:<host>:<iface>`, `dhcp-pool:<scope>`,
`lease-conflict:<mac>`, `mesh-partition:<segmento>`, `newdev:<mac>`.

### Logs

Coletor no `us` (`/etc/rsyslog.d/10-collector.conf`), `imtcp` **só em
127.0.0.1**, alcançado pelo `-L` do túnel. O cliente encaminha com fila em
disco com teto de 200MB: coletor fora do ar enfileira, volta e drena, e se
estourar o teto descarta o antigo em vez de encher o disco do host.

Retenção curta de propósito (7 dias, `maxsize 200M`) porque `/var` do `us`
é apertado. Histórico longo vem pelo backup.

### Backup

`/backup-config` gera config de rsnapshot por host, resolvendo o acesso
sozinho: host com túnel ganha `ssh_args -p <tunnelPort>`, host direto ganha
`-p 8422`. O Home entra nisso como qualquer outro host — a config do
router (leases, zonas, regras de firewall, CA) é justamente o que dói
perder.

---

## Auto-recuperação

Ideia recuperada do `uptest.sh` (script antigo de cron num raspberry, já
apagado do `live/bin`). O que ele fazia de certo, e que nada no sistema
atual faz: **antes de declarar que caiu, tentar consertar.**

O agente hoje é honesto mas passivo — reporta o que vê e para por aí. Num
host de infraestrutura isso é pouco: se o Home perde o link, quem receberia
o alerta está do outro lado do link.

Proposta de escada de recuperação, em ordem de agressividade, com
**backoff e teto** (isso é essencial — recuperação em loop é pior que a
falha original):

| Nível | Gatilho | Ação | Teto |
|---|---|---|---|
| 0 | heartbeat falhou 1× | nada, registra | — |
| 1 | 3 falhas seguidas | `dhclient -r && dhclient` na WAN | 1× a cada 10min |
| 2 | 5 falhas | derruba e sobe a interface | 1× a cada 30min |
| 3 | 8 falhas | reinicia os serviços de rede | 1× por hora |
| 4 | 15 falhas + uptime > 1h | reboot | 1× a cada 6h |

Regras que fazem isso ser seguro:

- **Contador persistente em disco**, zerado por heartbeat com sucesso.
  Contador em memória não sobrevive ao reboot que ele mesmo causou.
- **Nunca escalar sem confirmar em duas fontes.** "Não alcanço o servidor"
  pode ser o servidor. Checar gateway + DNS + um IP externo fixo antes.
- **Tudo que a recuperação fizer entra na fila de `results`** e vira
  incidente quando voltar. Recuperação silenciosa esconde a causa raiz —
  o link pode estar caindo 20× por dia e ninguém saber.
- **`uptime` mínimo antes de reboot**, senão um problema permanente vira
  ciclo de boot infinito.

Vale pro Home e pra frota inteira. Sugestão: implementar no agente comum,
com os níveis ligáveis por host no Monitor (default: só nível 0 e 1).

---

## Primeiro teste concreto: achar e acessar o rock64

O objetivo declarado é modesto e por isso é bom teste: **um rock64 sendo
configurado do zero, sem display, precisa ser identificado e acessado com
o menor esforço possível. Do DHCP até o HTTP.**

A interface LAN do teste é a `enxd03745ea2d6b` no `tp` — **um adaptador USB
que só é conectado na hora de desenvolver**, então ela não aparece no
`ip -br link` fora do teste (as fixas são `enp0s31f6` e `wlp9s0`). Como o
nome vem do MAC, é estável: plugou, é essa. Nada a investigar aqui — só
confirmar que subiu antes de configurar qualquer coisa em cima dela.

⚠️ **Risco alto e real:** subir DHCP na interface errada envenena a rede de
casa inteira, competindo com o roteador da operadora. O servidor DHCP tem
que ser amarrado **explicitamente** à interface do teste
(`interface=<lan>` + `bind-interfaces` no dnsmasq, nunca `bind-dynamic`), e
o teste deve começar com a interface LAN fisicamente separada.

### Caminho

1. **Endereçar a interface LAN** com uma faixa que não colida com a de
   casa (ex.: `10.84.0.1/24` — evite `192.168.0/1.0`).

2. **dnsmasq só nessa interface**, faixa curta, lease curto pro teste:

   ```
   interface=<lan>
   bind-interfaces
   dhcp-range=10.84.0.50,10.84.0.99,1h
   log-dhcp
   ```

3. **Ver o dispositivo aparecer** — é aqui que o Home ganha o teste:
   `/var/lib/misc/dnsmasq.leases` traz MAC, IP e hostname. O OUI do MAC
   identifica o fabricante (Pine64 = rock64), e o hostname que o cliente
   manda no DHCP costuma entregar a distro. Isso, mostrado no Monitor como
   "dispositivo novo na LAN", já resolve o problema declarado — **descobrir
   sem tela.**

4. **Chegar nele.** Em ordem de probabilidade:
   - **SSH** — Armbian sobe com SSH ligado por padrão (`root` com senha
     inicial que ele obriga a trocar no primeiro login).
   - **mDNS** — Armbian anuncia; `avahi-browse -art` acha sem saber o IP.
   - **nmap -sV** na faixa, pra ver o que responde.
   - **Serial UART** — o plano B que sempre funciona em placa sem tela.
     O rock64 tem UART nos pinos 6/8/10 do header; adaptador USB-TTL 3.3V,
     `screen /dev/ttyUSB0 1500000`. **1500000 baud**, não 115200 — os SoC
     Rockchip usam essa taxa e é a causa número um de "só sai lixo na
     tela". Vale ter o adaptador em mãos antes de começar.

5. **Até o HTTP** — com IP conhecido, o proxy do Home publica o
   dispositivo num nome interno, e é aqui que entra a intranet sem DNS:
   nftables mapeando um endereço estável pro IP que o DHCP deu, de forma
   que trocar o lease não quebre o acesso.

6. **Fechar o ciclo** — rodar `/init-auto` no rock64 (já pronto, ver
   abaixo): hostname do sistema, instala só o suficiente pro túnel, e a
   placa aparece no Monitor sozinha. Aí ela é um host normal e o resto se
   faz remoto.

---

## Recomendações técnicas

Opinião, não decisão tomada — mas com o porquê, pra poder ser contestada.

**DHCP + DNS: dnsmasq.** Kea + Unbound é mais "correto" e escala melhor,
mas dnsmasq faz DHCP, DNS, TFTP e PXE em um processo e um arquivo de
config. Numa LAN doméstica, a integração DHCP↔DNS (o host ganha nome
automaticamente ao pegar lease) vale mais do que qualquer coisa que o Kea
oferece. PXE no mesmo binário também importa: é o caminho pra provisionar
placa nova sem cartão.

**Roteamento e balanceamento: nftables + `ip rule`/`ip route` com
`nexthop`.** Balanceamento por *fluxo* (não por pacote — por pacote quebra
TCP). Marcar classes de tráfego com `meta mark` no nftables e mandar cada
marca pra uma tabela de rota diferente. A qualidade de cada link se mede
com pings periódicos e entra no heartbeat como métrica — é o que torna o
balanceamento observável, que é o ponto do rascunho.

**Fila: CAKE.** Uma linha (`tc qdisc add dev <wan> root cake bandwidth
<X>`) e o bufferbloat acaba. É a melhoria mais perceptível por linha de
config que existe em rede doméstica.

**CA intermediário: step-ca.** Faz ACME, então os hosts renovam certificado
sozinhos com o mesmo client que já usariam pro Let's Encrypt. A raiz entra
no trust store pelo `/init`, que já distribui arquivo do `live`. Chave da
raiz **offline**, só a intermediária no ar — se o Home for comprometido, a
raiz não vai junto.

**Mesh:** `batman-adv` (camada 2, a malha parece um switch — muito mais
simples pro resto do sistema) ou `babel` (camada 3, lida melhor com links
ruins e mistura wifi com ethernet). Pra off-grid de verdade, `babel`.
**esp32 não roda nenhum dos dois** — ele fala ESP-NOW ou ESP-MESH com um nó
raspberry/rock64 que faz a ponte. Arduino, menos ainda: ele é sensor na
ponta, não nó de rede. Isso já define os papéis do rascunho: x86/rock64 são
**roteadores e validadores**, raspberry são **propagadores e pontes**, e
esp32/arduino são **folhas**.

**Samba:** só SMB3, `server signing = mandatory`, sem SMB1 nem convidado.

**VLAN:** exige switch gerenciável. Sem ele, VLAN em roteador de uma perna
só (`router on a stick`) funciona mas todo o tráfego entre VLANs passa pela
mesma placa — aceitável em casa, mas é bom saber antes de contar com
isolamento.

---

## Armadilhas já pagas neste sistema

Erros que custaram tempo real neste trabalho e que vão reaparecer no Home
porque o padrão é o mesmo:

- **Template literal do JS.** Os scripts bash servidos por rota vivem dentro
  de template literal sem tag. Todo `\` e todo `${` passa por uma rodada de
  escape do JS antes de chegar no host. `\\` vira `\`, e `${...}` é
  interpolado. O `$` literal se escreve `${'$'}`. Isso já quebrou todos os
  heartbeats da frota uma vez. **Não confie no olho — gere o script e rode.**
- **Dois escopos no mesmo arquivo.** O instalador e o agente que ele escreve
  via heredoc entre aspas são scripts separados. Variável de um não existe
  no outro, e com `set -u` isso é fatal — e como `cat > arquivo <<EOF`
  trunca antes de expandir, o resultado é config vazia e instalação
  abortada no meio, com o agente ficando silenciosamente na versão antiga.
- **`KillMode=process` no systemd.** Sem isso, um serviço `Type=oneshot`
  mata o cgroup inteiro ao terminar — incluindo o `ssh -fNR` que já fez fork.
  O túnel abria e morria segundos depois, sem erro nenhum em log nenhum.
- **`stick-table type ip` no HAProxy é só IPv4.** Cliente IPv6 passava por
  cima de todo rate limit sem aparecer em lugar nenhum. Use `type ipv6`.
- **Ordem de regra no nftables.** ICMPv6 tem que ser aceito **antes** de
  `ct state invalid drop`, senão IPv6 quebra de um jeito difícil de
  diagnosticar (NDP é ICMPv6). Ver RFC 4890 pros tipos obrigatórios.
- **`sed` largo demais em `authorized_keys`.** Uma regex frouxa apagou 11
  chaves legítimas de uma vez. Faça backup, conte as linhas que a regex
  casa (`grep -c`) e confirme o número **antes** de executar.
- **Cuidado ao matar túnel pelo qual você está passando.** Aconteceu duas
  vezes. No Home o equivalente é aplicar regra de firewall que corta a
  própria sessão — sempre com rollback agendado (`sleep 60 && nft -f
  backup.conf` em background antes de aplicar) até confirmar que sobreviveu.

---

## Segurança

- **Papel não dá acesso, só configura.** O runner de backup entra nos hosts
  com chave restrita a `rrsync -ro`. O Home vai precisar do mesmo cuidado:
  o que gerencia rede não precisa de shell em ninguém.
- **Dispositivo novo na LAN entra em quarentena, não em confiança.** MAC
  desconhecido cai numa VLAN/faixa isolada com saída limitada, aparece no
  Monitor, e só sai dali por ação explícita. É o mesmo princípio do
  `ddnsEnabled`/`tunnelEnabled`: **nada se autoriza sozinho.**
- **Segredo de papel fica no host do papel.** Senha do restic mora só no
  runner; chave da CA mora só na CA. Nunca no Mongo, nunca no Monitor. Se o
  Monitor for comprometido, o que ele guarda é configuração, não chave.
- **`/router` distribui chaves e confiança** — mesmo nível do `/init`.
  Precisa do mesmo `PROVISION_TOKEN` e do mesmo cuidado.
- **`/init-auto` e `/router` são não-interativos por definição.** Isso os
  torna alvo atraente: o fluxo de aprovação por email (a chave do host novo
  espera aprovação humana) é o que impede que rodar o script já dê acesso.
  **Não remova esse passo em nome da automação.**

---

## Estado atual

**Pronto:**
- `/init-auto` (`app/init-auto/route.ts`) — provisionamento mínimo e sem
  perguntas: hostname do próprio sistema, SSH na 8422 com o `Match` de
  forwarding, chave do root, agente, e para por aí. Existe exatamente pro
  caso do rock64: placa sem tela, ninguém pra responder prompt. Pré-grava o
  `config.env` pro `/install` não depender de resposta nenhuma (sem tty ele
  cai nos defaults, e os defaults saem daí). A aprovação da chave por email
  continua valendo.

**Anotado, não feito:**
- **Criador de links curtos, com suporte a domínios adicionais.** Nasceu de
  um limite concreto: um `/init` totalmente parametrizado por query string
  fica grande demais pra digitar num terminal de placa sem tela. Um
  encurtador próprio resolve isso e serve pro resto do sistema. Ter domínio
  adicional importa porque o link curto vai ser digitado à mão — quanto mais
  curto o domínio, melhor.
- Generalizar `backupRunner` → `roles`.
- Rota `/router`.
- Escada de auto-recuperação no agente comum.
- Tipos de job novos pro Home (`apply-network-config`, `renew-dhcp`, …).

---

## Ordem sugerida

1. **Achar o rock64.** dnsmasq amarrado na interface certa, ler o lease,
   chegar via SSH ou serial. Sem código novo — valida o caminho e já entrega
   o que foi pedido.
2. **`/init-auto` no rock64.** Fecha o ciclo: a placa vira host normal no
   Monitor e o resto se faz remoto.
3. **Descoberta de dispositivo no Monitor.** Leases + OUI + `newdev:<mac>`
   como incidente. É o menor pedaço do Home que já tem valor sozinho.
4. **`roles` e `/router`.** Só depois que houver o que gerenciar.
5. **Balanceamento e métrica de link.** O pilar mais alto do rascunho, e o
   que mais depende de ter a base observável primeiro.

A ordem é essa de propósito: cada passo entrega algo usável sozinho, e
nenhum depende de um pedaço grande do seguinte estar pronto.
