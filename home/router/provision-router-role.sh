#!/bin/bash
# Garante os pre-requisitos de HOST pra role router numa interface LAN.
# Idempotente -- roda quantas vezes quiser, so aplica o que falta.
#
# O que resolve (tudo descoberto na pratica, nao no papel):
#   1. Interface marcada unmanaged no NetworkManager (por MAC) -- senao
#      qualquer replug zera o IP que a gente configurou.
#   2. Regra de firewall liberando DHCP/DNS so nessa interface -- sem
#      isso a policy padrao 'drop' do host derruba o DHCP silenciosamente,
#      sem erro em lugar nenhum.
#   3. O include dessa regra no /etc/nftables.conf, criando o arquivo base
#      se ainda nao existir.
#
# Uso: sudo ./provision-router-role.sh <interface-lan>
set -euo pipefail

IFACE="${1:?uso: sudo ./provision-router-role.sh <interface-lan>}"
NFT_MAIN="/etc/nftables.conf"
NFT_DROPIN_DIR="/etc/nftables.d"
NFT_DROPIN="$NFT_DROPIN_DIR/router-role.conf"
NFT_NAT_DROPIN="$NFT_DROPIN_DIR/router-role-nat.conf"
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
echo "Interface: $IFACE (MAC $MAC)"

# --- 1. NetworkManager: nunca deixa essa interface sob gestao dele ---
if command -v nmcli >/dev/null 2>&1; then
  mkdir -p "$NM_DROPIN_DIR"
  NM_FILE="$NM_DROPIN_DIR/router-role-$IFACE.conf"
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

# --- 2/3. nftables: garante arquivo base + include + regra da role ---
mkdir -p "$NFT_DROPIN_DIR"

if [[ ! -f "$NFT_MAIN" ]]; then
  echo "  [criando] $NFT_MAIN nao existia, criando esqueleto base"
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

		include "/etc/nftables.d/router-role.conf"
	}
	chain forward {
		type filter hook forward priority filter; policy accept;
	}
	chain output {
		type filter hook output priority filter; policy accept;
	}
}

include "/etc/nftables.d/router-role-nat.conf"
EOF
elif ! grep -qF 'include "/etc/nftables.d/router-role.conf"' "$NFT_MAIN"; then
  echo "  [ajustando] adicionando include do router-role.conf em $NFT_MAIN"
  # Insere o include logo antes do fechamento da chain input (a primeira
  # linha "}" depois da abertura "chain input {").
  awk '
    /chain input \{/ { print; in_input=1; next }
    in_input && /^[[:space:]]*\}/ { print "\t\tinclude \"/etc/nftables.d/router-role.conf\";"; print; in_input=0; next }
    { print }
  ' "$NFT_MAIN" > "$NFT_MAIN.new"
  nft -c -f "$NFT_MAIN.new" || { echo "  [ERRO] arquivo gerado invalido, abortando sem tocar no original" >&2; rm -f "$NFT_MAIN.new"; exit 1; }
  mv "$NFT_MAIN.new" "$NFT_MAIN"
else
  echo "  [ok] include do router-role.conf ja presente em $NFT_MAIN"
fi

if ! grep -qF 'include "/etc/nftables.d/router-role-nat.conf"' "$NFT_MAIN"; then
  echo "  [ajustando] adicionando include do router-role-nat.conf (nivel raiz) em $NFT_MAIN"
  printf '\ninclude "/etc/nftables.d/router-role-nat.conf"\n' >> "$NFT_MAIN"
else
  echo "  [ok] include do router-role-nat.conf ja presente em $NFT_MAIN"
fi

cat > "$NFT_DROPIN" <<EOF
# Gerado por provision-router-role.sh -- reescrito a cada execucao.
# Libera DHCP/DNS so na interface LAN da role router, nunca em geral.
iifname "$IFACE" udp dport { 67, 53 } accept
iifname "$IFACE" tcp dport 53 accept
EOF

cat > "$NFT_NAT_DROPIN" <<EOF
# Gerado por provision-router-role.sh -- reescrito a cada execucao.
# Intercepta qualquer pacote porta 53 saindo da LAN e redireciona pro
# dnsmasq local -- nao importa o que o cliente tenha configurado como DNS,
# o router decide. Principio "intranet que nao depende de DNS" do HOME.md,
# aplicado como politica: o resolver do cliente nunca manda.
table ip dns_redirect_$IFACE {
	chain prerouting {
		type nat hook prerouting priority dstnat; policy accept;
		iifname "$IFACE" udp dport 53 redirect to :53
		iifname "$IFACE" tcp dport 53 redirect to :53
	}
}
EOF

echo "  [validando] nft -c -f $NFT_MAIN"
nft -c -f "$NFT_MAIN"
echo "  [aplicando] systemctl reload nftables"
systemctl reload nftables 2>/dev/null || nft -f "$NFT_MAIN"
echo "  [ok] regra de DHCP/DNS liberada em $NFT_DROPIN"

echo
echo "Pronto. Pre-requisitos de host garantidos pra $IFACE."
