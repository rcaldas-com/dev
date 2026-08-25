#!/bin/bash
# Garante os pre-requisitos de HOST pra role "home" (LAN/WAN) numa interface.
# Idempotente -- roda quantas vezes quiser, so aplica o que falta.
#
# Historico de duas rodadas de correcao real (credito: revisao cruzada
# com o chat do Monitor, que testou tudo em netns descartavel antes de
# confiarmos):
#
#   1a rodada -- incidente real: `systemctl reload nftables` reprocessa
#   /etc/nftables.conf inteiro, que comeca com `flush ruleset` -- isso
#   apagou as tabelas do Docker (gerenciadas por fora, via iptables-nft),
#   derrubando publicacao de porta de todos os containers do host. E um
#   plano cogitado de colocar forward numa tabela separada com policy
#   drop teria quebrado de qualquer jeito: duas base chains no mesmo
#   hook, um drop em qualquer uma e terminal -- uma chain accept separada
#   nao resgata o que a outra derrubou (testado e provado em netns).
#
#   Correcao 1: as regras da role vivem em chains PROPRIAS (nao-base),
#   referenciadas por "jump" a partir de UMA linha estavel dentro de
#   chain input/chain forward -- inserida uma unica vez.
#
#   2a rodada -- gap descoberto: aplicar via `nft add rule` direto (sem
#   persistir num arquivo que o boot releia do MESMO jeito) deixa a regra
#   so em memoria. Simulado reboot em netns: a chain volta vazia e o DHCP
#   morre nos primeiros 60s+boot ate o agente reconciliar -- ruim
#   exatamente quando os clientes tambem estao subindo e entram em
#   backoff.
#
#   Correcao 2: cada dropin agora e um artefato UNICO que serve os dois
#   caminhos -- contem `flush chain ... ; add rule ...` (comandos
#   completos, com tabela/chain explicitos), entao e valido tanto como
#   `nft -f` direto (update a quente) quanto incluido no boot via
#   `include "/etc/nftables.d/home-*.conf"` no FIM do arquivo principal
#   (depois do bloco que declara as chains -- nft aborta com "did you
#   mean chain X?" se o include vier antes). O glob e "home-*", nao "*",
#   pra nao colidir com monitor-ports.conf (formato diferente: statements
#   soltos pensados pra viver DENTRO de uma chain, nao comandos completos).
#
# O que resolve:
#   1. Interface marcada unmanaged no NetworkManager (por MAC) -- senao
#      qualquer replug zera o IP que a gente configurou.
#   2. DHCP/DNS aceito so na interface LAN (chain propria home_lan_input).
#   3. Redirecionamento transparente de porta 53 pro dnsmasq local --
#      nao importa o resolver que o cliente configurou.
#   4. (Se WAN for passada) forward LAN->WAN + NAT (chain propria
#      home_lan_forward + tabela de NAT dedicada, hook postrouting nao
#      tem policy concorrente entao e seguro).
#
# Uso: sudo ./provision-router-role.sh <interface-lan> [interface-wan]
set -euo pipefail

IFACE="${1:?uso: sudo ./provision-router-role.sh <interface-lan> [interface-wan]}"
WAN_IFACE="${2:-}"

NFT_MAIN="/etc/nftables.conf"
NFT_DROPIN_DIR="/etc/nftables.d"
NFT_DHCP_DNS_DROPIN="$NFT_DROPIN_DIR/home-lan-input.conf"
NFT_FORWARD_DROPIN="$NFT_DROPIN_DIR/home-lan-forward.conf"
NFT_NAT_DROPIN="$NFT_DROPIN_DIR/home-nat.conf"
NM_DROPIN_DIR="/etc/NetworkManager/conf.d"

if [[ "$EUID" -ne 0 ]]; then
  echo "Precisa rodar como root (sudo)." >&2
  exit 1
fi

if ! ip link show "$IFACE" >/dev/null 2>&1; then
  echo "Interface $IFACE nao encontrada." >&2
  ip -br link >&2
  exit 1
fi

MAC=$(ip link show "$IFACE" | awk '/link\/ether/ {print $2}')
echo "Interface LAN: $IFACE (MAC $MAC)${WAN_IFACE:+, WAN: $WAN_IFACE}"

# --- 1. NetworkManager: nunca deixa a LAN sob gestao dele ---
if command -v nmcli >/dev/null 2>&1; then
  mkdir -p "$NM_DROPIN_DIR"
  NM_FILE="$NM_DROPIN_DIR/home-role-$IFACE.conf"
  if [[ ! -f "$NM_FILE" ]] || ! grep -q "$MAC" "$NM_FILE" 2>/dev/null; then
    cat > "$NM_FILE" <<EOF
[keyfile]
unmanaged-devices=mac:$MAC
EOF
    systemctl reload NetworkManager 2>/dev/null || systemctl restart NetworkManager
    echo "  [ok] NetworkManager: $IFACE marcada unmanaged ($NM_FILE)"
  else
    echo "  [ok] NetworkManager: ja estava marcada unmanaged"
  fi
else
  echo "  [--] NetworkManager nao presente, pulando"
fi

# --- 2. nftables: garante a ESTRUTURA (chains proprias, vazias, + jump +
#         include no fim do arquivo), sem tocar em policy de chain de base ---
mkdir -p "$NFT_DROPIN_DIR"

if [[ ! -f "$NFT_MAIN" ]]; then
  echo "  [AVISO] $NFT_MAIN nao existe -- criando do zero."
  echo "  [AVISO] Isso vai exigir um flush ruleset (nada a perder ainda,"
  echo "  [AVISO] mas se o Docker ja estiver rodando neste host, reinicie-o"
  echo "  [AVISO] logo em seguida: systemctl restart docker"
  cat > "$NFT_MAIN" <<'EOF'
#!/usr/sbin/nft -f
flush ruleset

table inet filter {
	chain input {
		type filter hook input priority filter; policy drop;

		iifname "lo" accept
		ct state established,related accept
		ct state invalid drop

		# ICMP/ICMPv6 essenciais (RFC 4890) -- sem isso o NDP quebra e o
		# IPv6 fica morto.
		icmp type { destination-unreachable, time-exceeded, parameter-problem, echo-request, echo-reply } accept
		icmpv6 type {
			destination-unreachable, packet-too-big,
			time-exceeded, parameter-problem,
			echo-request, echo-reply,
			nd-router-solicit, nd-router-advert,
			nd-neighbor-solicit, nd-neighbor-advert
		} accept

		jump home_lan_input
	}
	chain forward {
		type filter hook forward priority filter; policy accept;
		jump home_lan_forward
	}
	chain output {
		type filter hook output priority filter; policy accept;
	}
	chain home_lan_input { }
	chain home_lan_forward { }
}

# Cada dropin e um artefato completo (flush chain + add rule / table
# inteira) -- por isso o include vem DEPOIS das chains acima existirem,
# nunca antes (nft aborta se a chain alvo ainda nao existe).
include "/etc/nftables.d/home-*.conf"
EOF
  : > "$NFT_DHCP_DNS_DROPIN"
  : > "$NFT_FORWARD_DROPIN"
  : > "$NFT_NAT_DROPIN"
  nft -c -f "$NFT_MAIN"
  nft -f "$NFT_MAIN"
  BOOTSTRAPPED=1
else
  BOOTSTRAPPED=0
fi

# A partir daqui o arquivo TEM a estrutura (ou acabou de ganhar, acima).
# Toda mudanca de agora em diante e incremental na chain propria -- nunca
# mais flush ruleset neste script.

live_chain_exists() { nft list chain inet filter "$1" >/dev/null 2>&1; }
live_has_jump() { nft list chain inet filter "$1" 2>/dev/null | grep -qF "jump $2"; }

if [[ "$BOOTSTRAPPED" -eq 0 ]]; then
  # Garante ao vivo (sem tocar no arquivo/reload) que as chains proprias e
  # os jumps existem -- host ja provisionado antes, arquivo mais antigo
  # que essa versao do script.
  live_chain_exists home_lan_input || nft add chain inet filter home_lan_input
  live_chain_exists home_lan_forward || nft add chain inet filter home_lan_forward
  live_has_jump input home_lan_input || nft insert rule inet filter input jump home_lan_input
  live_has_jump forward home_lan_forward || nft insert rule inet filter forward jump home_lan_forward

  # E garante que o ARQUIVO reflete o mesmo (so importa no proximo boot,
  # nao dispara reload nenhum agora). nftables mescla blocos repetidos da
  # mesma table/chain (testado com -c antes de confiar nisso) -- so
  # anexa um bloco novo no fim do arquivo, nunca edita o existente, nunca
  # conta chave. A chain input real tem um bloco icmpv6 multi-linha --
  # qualquer heuristica baseada em "primeira linha com }" cairia nele.
  if ! grep -qF 'jump home_lan_input' "$NFT_MAIN"; then
    cp "$NFT_MAIN" "$NFT_MAIN.bak"
    cat >> "$NFT_MAIN" <<'EOF'

table inet filter {
	chain input {
		jump home_lan_input
	}
	chain forward {
		jump home_lan_forward
	}
	chain home_lan_input { }
	chain home_lan_forward { }
}
EOF
    if ! nft -c -f "$NFT_MAIN"; then
      echo "  [ERRO] arquivo ficou invalido apos o append -- revertendo" >&2
      mv "$NFT_MAIN.bak" "$NFT_MAIN"
      exit 1
    fi
    rm -f "$NFT_MAIN.bak"
  fi
  if ! grep -qF 'include "/etc/nftables.d/home-*.conf"' "$NFT_MAIN"; then
    printf '\n# Dropins da role home -- cada um e um artefato nft -f completo\n# (flush chain + add rule, ou table inteira), valido standalone. So\n# funciona aqui porque as chains acima ja existem neste ponto do arquivo.\ninclude "/etc/nftables.d/home-*.conf"\n' >> "$NFT_MAIN"
  fi
  echo "  [ok] estrutura da role garantida ao vivo, sem flush ruleset"
fi

# --- 3. Conteudo das regras: cada dropin e um artefato nft -f completo e
#         standalone -- o MESMO arquivo serve o update a quente (nft -f
#         direto) e o boot (include "home-*.conf" no fim do arquivo). Sem
#         wrapper, sem duplicar formato. ---
cat > "$NFT_DHCP_DNS_DROPIN" <<EOF
# Gerado por provision-router-role.sh -- reescrito a cada execucao.
# Idempotente: flush chain + add rule, sem flush ruleset. Valido como
# nft -f direto (update a quente) e via include no boot.
flush chain inet filter home_lan_input
add rule inet filter home_lan_input iifname "$IFACE" udp dport { 67, 53 } accept
add rule inet filter home_lan_input iifname "$IFACE" tcp dport 53 accept
EOF
nft -f "$NFT_DHCP_DNS_DROPIN"
echo "  [ok] DHCP/DNS liberado pra $IFACE (chain home_lan_input, sem reload)"

cat > "$NFT_NAT_DROPIN" <<EOF
# Gerado por provision-router-role.sh -- reescrito a cada execucao.
# Intercepta qualquer pacote porta 53 saindo da LAN e redireciona pro
# dnsmasq local -- nao importa o que o cliente tenha configurado, o
# router decide. Hook nat postrouting nao tem policy concorrente, entao
# uma tabela propria aqui e segura (diferente de input/forward).
table ip dns_redirect_$IFACE {
	chain prerouting {
		type nat hook prerouting priority dstnat; policy accept;
		iifname "$IFACE" udp dport 53 redirect to :53
		iifname "$IFACE" tcp dport 53 redirect to :53
	}
}
EOF
nft delete table ip "dns_redirect_$IFACE" 2>/dev/null || true
nft -f "$NFT_NAT_DROPIN"
echo "  [ok] redirecionamento de DNS aplicado (tabela propria, sem reload)"

if [[ -n "$WAN_IFACE" ]]; then
  if ! ip link show "$WAN_IFACE" >/dev/null 2>&1; then
    echo "Interface WAN $WAN_IFACE nao encontrada." >&2
    exit 1
  fi
  if [[ "$(cat /proc/sys/net/ipv4/ip_forward)" != "1" ]]; then
    echo 1 > /proc/sys/net/ipv4/ip_forward
  fi
  cat > "$NFT_FORWARD_DROPIN" <<EOF
# Gerado por provision-router-role.sh -- reescrito a cada execucao.
flush chain inet filter home_lan_forward
add rule inet filter home_lan_forward ct state established,related accept
add rule inet filter home_lan_forward iifname "$IFACE" oifname "$WAN_IFACE" accept
EOF
  nft -f "$NFT_FORWARD_DROPIN"

  NAT_MASQ="$NFT_DROPIN_DIR/home-nat-masquerade-$IFACE.conf"
  cat > "$NAT_MASQ" <<EOF
table ip home_nat_$IFACE {
	chain postrouting {
		type nat hook postrouting priority srcnat; policy accept;
		ip saddr $(ip -o -f inet addr show "$IFACE" | awk '{print $4}') oifname "$WAN_IFACE" masquerade
	}
}
EOF
  nft delete table ip "home_nat_$IFACE" 2>/dev/null || true
  nft -f "$NAT_MASQ"
  echo "  [ok] forward + NAT $IFACE -> $WAN_IFACE aplicado (sem reload)"
else
  # Sem WAN: garante que a chain de forward fica vazia (so o
  # established/related, sem abrir nada) -- idempotente se rodar de novo
  # sem WAN depois de ter passado WAN antes.
  cat > "$NFT_FORWARD_DROPIN" <<'EOF'
flush chain inet filter home_lan_forward
add rule inet filter home_lan_forward ct state established,related accept
EOF
  nft -f "$NFT_FORWARD_DROPIN"
fi

echo
echo "Pronto. Role home garantida pra $IFACE${WAN_IFACE:+ (WAN: $WAN_IFACE)}, sem flush ruleset."
