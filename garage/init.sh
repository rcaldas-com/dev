#!/bin/sh
# Bootstrap do Garage de dev. Roda no servico garage-init a cada
# `docker compose up` e e' idempotente: so' faz o que falta.
#
# O MinIO subia pronto com usuario/senha de ambiente; o Garage precisa de tres
# passos, feitos aqui pela API de admin (a imagem dele nao tem shell, entao
# nao da' pra rodar o CLI dentro dela):
#   1. layout: dizer ao no' que ele guarda dados (so' na primeira vez);
#   2. importar a chave S3_KEY/S3_SECRET do .env -- chave FIXA, pra o .env de
#      dev funcionar igual em qualquer maquina, como root/password no MinIO;
#   3. permitir que essa chave crie bucket: car e wallet criam o deles
#      sozinhos quando nao existe (HeadBucket -> CreateBucket).
set -eu

API="http://garage:3903"
AUTH="Authorization: Bearer $GARAGE_ADMIN_TOKEN"

: "${S3_KEY:?S3_KEY ausente no .env}"
: "${S3_SECRET:?S3_SECRET ausente no .env}"
case "$S3_KEY" in
  GK????????????????????????) ;;
  *) echo "garage-init: S3_KEY tem que ser GK + 24 hex (formato do Garage), veio '$S3_KEY'" >&2; exit 1 ;;
esac

i=0
until status=$(curl -sf -H "$AUTH" "$API/v2/GetClusterStatus"); do
  i=$((i + 1)); [ "$i" -ge 30 ] && { echo "garage-init: admin API nao respondeu" >&2; exit 1; }
  sleep 1
done

# O JSON vem formatado ("layoutVersion": 0, com espaco): o grep aceita os
# dois jeitos. Sem jq de proposito -- a imagem do curl nao tem.
if printf '%s' "$status" | grep -qE '"layoutVersion": *0[,}[:space:]]'; then
  node=$(printf '%s' "$status" | grep -oE '"id": *"[0-9a-f]+"' | head -1 | grep -oE '[0-9a-f]{16,}')
  [ -n "$node" ] || { echo "garage-init: nao achei o id do no' no GetClusterStatus" >&2; exit 1; }
  curl -sf -H "$AUTH" -X POST "$API/v2/UpdateClusterLayout" \
    -d "{\"roles\":[{\"id\":\"$node\",\"zone\":\"dev\",\"capacity\":20000000000,\"tags\":[\"dev\"]}]}" >/dev/null
  curl -sf -H "$AUTH" -X POST "$API/v2/ApplyClusterLayout" -d '{"version":1}' >/dev/null
  echo "garage-init: layout aplicado no no' ${node%"${node#????????????}"}..."
fi

# Layout aplicado nao e' layout pronto: ate o /health dar 200, as chamadas de
# chave respondem 500 "Layout not ready".
i=0
until curl -sf -o /dev/null "$API/health"; do
  i=$((i + 1)); [ "$i" -ge 30 ] && { echo "garage-init: layout nao ficou pronto (/health)" >&2; exit 1; }
  sleep 1
done

code=$(curl -s -o /dev/null -w '%{http_code}' -H "$AUTH" "$API/v2/GetKeyInfo?id=$S3_KEY")
case "$code" in
  200|404) ;;
  *) echo "garage-init: GetKeyInfo respondeu $code" >&2; exit 1 ;;
esac
if [ "$code" = 404 ]; then
  curl -sf -H "$AUTH" -X POST "$API/v2/ImportKey" \
    -d "{\"accessKeyId\":\"$S3_KEY\",\"secretAccessKey\":\"$S3_SECRET\",\"name\":\"dev\"}" >/dev/null
  echo "garage-init: chave $S3_KEY importada"
fi
curl -sf -H "$AUTH" -X POST "$API/v2/UpdateKey?id=$S3_KEY" -d '{"allow":{"createBucket":true}}' >/dev/null

echo "garage-init: pronto (S3 em http://garage:3900, chave $S3_KEY)"
