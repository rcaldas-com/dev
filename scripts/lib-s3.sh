# shellcheck shell=bash
# Funcoes S3 compartilhadas por restore-prod.sh e restore-local.sh.
# Uso: source "$(dirname "$0")/lib-s3.sh", com o cwd na raiz do repo (onde
# esta o docker-compose.yml de dev).
#
# Qualquer S3, dos DOIS lados: o Garage do compose de dev, um provedor publico
# (Storj, Wasabi, Filebase...) ou algo exposto no host (localhost:porta). O
# restore-prod tambem serve pra trocar de provedor: o .env local aponta pro
# provedor NOVO e o config de producao pro atual. Por isso nada aqui conhece
# nome de servico -- o que decide rede e endereco e' o hostname do endpoint.

# Hostname de uma URL (sem esquema, porta ou caminho).
s3_hostname() { printf '%s' "$1" | sed -E 's#^[a-zA-Z]+://##; s#[:/].*$##'; }

# Nome do servico do compose de dev que atende o endpoint ("garage"), ou vazio.
# Servico = hostname sem ponto que existe como servico no docker-compose.yml.
s3_compose_service() {
  local h; h=$(s3_hostname "$1")
  [[ -n "$h" && "$h" != *.* && "$h" != localhost ]] || return 0
  if docker compose config --services 2>/dev/null | grep -qx "$h"; then printf '%s' "$h"; fi
}

# Rede pro container do rclone alcancar o endpoint. Provedor publico: nenhuma
# (rede padrao, com internet).
s3_net_args() {
  case "$(s3_hostname "$1")" in
    localhost|127.0.0.1|host.docker.internal) printf '%s' "--network=host" ;;
    *) [[ -n "$(s3_compose_service "$1")" ]] && printf '%s' "--network=$(basename "$(pwd)")_default" ;;
  esac
  return 0
}

# Se o endpoint e' um servico do compose, sobe e espera ficar pronto. Com um
# "<servico>-init" (o Garage tem), pronto = o init terminou com sucesso: antes
# disso o S3 responde mas recusa a chave do .env.
s3_ensure_service() {
  local svc; svc=$(s3_compose_service "$1")
  [[ -z "$svc" ]] && return 0
  if docker compose config --services 2>/dev/null | grep -qx "${svc}-init"; then
    docker compose up -d "$svc" "${svc}-init" >/dev/null 2>&1
    local _
    for _ in $(seq 1 30); do
      [[ "$(docker compose ps -a --format '{{.State}} {{.ExitCode}}' "${svc}-init" 2>/dev/null)" == "exited 0" ]] && return 0
      sleep 2
    done
    return 1
  fi
  docker compose up -d "$svc" >/dev/null 2>&1
  sleep 3
}

# rclone com UM remote S3 definido so' por variavel de ambiente.
#   s3_rclone NOME ENDPOINT KEY SECRET REGIAO [-v origem:destino ...] -- args do rclone
# Credencial vai por `-e VAR` (so' o nome) com o valor exportado num subshell:
# `-e VAR=valor` deixaria o segredo na linha de comando do docker, visivel no
# ps de qualquer usuario do host.
s3_rclone() {
  local nome="$1" ep="$2" key="$3" sec="$4" reg="${5:-us-east-1}"
  shift 5
  local vols=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do vols+=("$1"); shift; done
  [[ "${1:-}" == "--" ]] && shift
  local N; N=$(printf '%s' "$nome" | tr '[:lower:]' '[:upper:]')
  local net; net=$(s3_net_args "$ep")
  (
    export "RCLONE_CONFIG_${N}_TYPE=s3" "RCLONE_CONFIG_${N}_PROVIDER=Other"
    # host.docker.internal nao existe dentro do container na rede do host.
    export "RCLONE_CONFIG_${N}_ENDPOINT=$(printf '%s' "$ep" | sed 's/host\.docker\.internal/127.0.0.1/')"
    # Regiao entra na assinatura: o Garage exige a dele (us-east-1 no dev);
    # Storj/Wasabi aceitam qualquer uma. Path-style igual aos apps com S3_HOST.
    export "RCLONE_CONFIG_${N}_REGION=$reg" "RCLONE_CONFIG_${N}_FORCE_PATH_STYLE=true"
    export "RCLONE_CONFIG_${N}_ACCESS_KEY_ID=$key" "RCLONE_CONFIG_${N}_SECRET_ACCESS_KEY=$sec"
    # shellcheck disable=SC2086 # $net vazio ou um unico argumento
    docker run --rm $net "${vols[@]}" \
      -e "RCLONE_CONFIG_${N}_TYPE" -e "RCLONE_CONFIG_${N}_PROVIDER" -e "RCLONE_CONFIG_${N}_ENDPOINT" \
      -e "RCLONE_CONFIG_${N}_REGION" -e "RCLONE_CONFIG_${N}_FORCE_PATH_STYLE" \
      -e "RCLONE_CONFIG_${N}_ACCESS_KEY_ID" -e "RCLONE_CONFIG_${N}_SECRET_ACCESS_KEY" \
      rclone/rclone:latest "$@"
  )
}
