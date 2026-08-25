#!/bin/bash
# Garante os pre-requisitos de HOST pra role "home" (LAN/WAN) numa interface.
# Idempotente -- roda quantas vezes quiser, so aplica o que falta.
#
# Reescrito depois de um incidente real: a versao anterior usava
# `systemctl reload nftables`, que reprocessa /etc/nftables.conf inteiro
# -- e esse arquivo comeca com `flush ruleset`, que apaga TUDO, inclusive
# as tabelas que o Docker gerencia via iptables-nft. Isso derrubou a
# publicacao de porta de todos os containers do host (nao so os nossos).
#
# Correcao (credito: revisao cruzada com o chat do Monitor, que testou em
# netns descartavel e provou o problema):
#   - NUNCA cria uma tabela/chain de base separada competindo no mesmo
#     hook (input/forward) com policy propria -- testado que uma policy
#     drop em qualquer chain do mesmo hook e terminal, e uma chain accept
#     separada NAO resgata o que a outra derrubou.
#   - As regras da role vivem em chains PROPRIAS (nao-base), referenciadas
#     por "jump" a partir de UMA linha estavel dentro de chain input/
#     chain forward -- inserida uma unica vez.
#   - Atualizar as regras da role depois disso e SEMPRE incremental (nft
#     flush chain / nft add rule numa chain especifica), nunca um reload
#     do arquivo inteiro. flush ruleset so acontece se o arquivo base
#     tiver que ser criado do zero (host nunca provisionado) -- nesse
#     caso, o script avisa antes de aplicar.
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

# --- 2. nftables: garante a ESTRUTURA (chains proprias + jump), sem tocar
#         em policy nenhuma de chain de base ---
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
	chain home_lan_input {
		include "/etc/nftables.d/home-lan-input.conf"
	}
	chain home_lan_forward {
		include "/etc/nftables.d/home-lan-forward.conf"
	}
}

include "/etc/nftables.d/home-nat.conf"
EOF
  touch "$NFT_DHCP_DNS_DROPIN" "$NFT_FORWARD_DROPIN" "$NFT_NAT_DROPIN"
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

# Os dropins de chain (home-lan-input.conf/home-lan-forward.conf) usam
# statements soltos (iifname ... accept), formato certo pra dentro de um
# 'include' num bloco chain {}. Fora desse contexto (nft -f direto) nao e
# valido standalone -- por isso aplica sempre atraves de um wrapper
# efemero que reabre a chain via table merge, nunca via arquivo persistido.
apply_chain_dropin() {
  local chain="$1" dropin="$2" wrapper
  wrapper=$(mktemp)
  cat > "$wrapper" <<EOF
table inet filter {
	chain $chain {
		include "$dropin"
	}
}
EOF
  nft flush chain inet filter "$chain"
  nft -f "$wrapper"
  rm -f "$wrapper"
}

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
  # Os arquivos de include precisam existir ANTES de validar o bloco que
  # os referencia -- nft -c falha com "File not found" senao.
  touch "$NFT_DHCP_DNS_DROPIN" "$NFT_FORWARD_DROPIN"
  [[ -f "$NFT_NAT_DROPIN" ]] || echo "" > "$NFT_NAT_DROPIN"

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
	chain home_lan_input {
		include "/etc/nftables.d/home-lan-input.conf"
	}
	chain home_lan_forward {
		include "/etc/nftables.d/home-lan-forward.conf"
	}
}
EOF
    if ! nft -c -f "$NFT_MAIN"; then
      echo "  [ERRO] arquivo ficou invalido apos o append -- revertendo" >&2
      mv "$NFT_MAIN.bak" "$NFT_MAIN"
      exit 1
    fi
    rm -f "$NFT_MAIN.bak"
  fi
  if ! grep -qF 'include "/etc/nftables.d/home-nat.conf"' "$NFT_MAIN"; then
    printf '\ninclude "/etc/nftables.d/home-nat.conf"\n' >> "$NFT_MAIN"
  fi
  echo "  [ok] estrutura da role garantida ao vivo, sem flush ruleset"
fi

# --- 3. Conteudo das regras: sempre incremental (flush so da NOSSA chain) ---
cat > "$NFT_DHCP_DNS_DROPIN" <<EOF
# Gerado por provision-router-role.sh -- reescrito a cada execucao.
# So aplicado ao vivo via 'nft flush chain' + 'nft -f', nunca via reload
# do arquivo inteiro.
iifname "$IFACE" udp dport { 67, 53 } accept
iifname "$IFACE" tcp dport 53 accept
EOF
apply_chain_dropin home_lan_input "$NFT_DHCP_DNS_DROPIN"
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
ct state established,related accept
iifname "$IFACE" oifname "$WAN_IFACE" accept
EOF
  apply_chain_dropin home_lan_forward "$NFT_FORWARD_DROPIN"

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
ct state established,related accept
EOF
  apply_chain_dropin home_lan_forward "$NFT_FORWARD_DROPIN"
fi

echo
echo "Pronto. Role home garantida pra $IFACE${WAN_IFACE:+ (WAN: $WAN_IFACE)}, sem flush ruleset."
