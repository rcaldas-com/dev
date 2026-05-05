#!/bin/bash

# Restore a partir de backup local já existente: MongoDB (todos os bancos) + S3 (se configurado)
# Uso: ./scripts/restore-local.sh backup-20250901-162914

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${GREEN}[$(date +'%H:%M:%S')] $1${NC}"; }
warn() { echo -e "${YELLOW}[$(date +'%H:%M:%S')] $1${NC}"; }
error(){ echo -e "${RED}[$(date +'%H:%M:%S')] $1${NC}"; }
info() { echo -e "${BLUE}[$(date +'%H:%M:%S')] $1${NC}"; }

if [ -z "$1" ]; then
    error "Uso: $0 <diretório-backup>"
    error "Exemplo: $0 backup-20250901-162914"
    info "📁 Backups disponíveis:"
    ls -1d backup-* 2>/dev/null | head -10 || echo "   Nenhum backup encontrado"
    exit 1
fi

BACKUP_DIR="$1"

if [ ! -d "$BACKUP_DIR" ]; then
    error "Diretório de backup não encontrado: $BACKUP_DIR"
    info "📁 Backups disponíveis:"
    ls -1d backup-* 2>/dev/null | head -10 || echo "   Nenhum backup encontrado"
    exit 1
fi

get_env_var() { grep "^$1=" .env 2>/dev/null | cut -d'=' -f2- | tr -d '"'; }

# Remove o caminho do banco do URI para conectar ao servidor inteiro
server_uri() {
    echo "$1" | sed -E 's|(mongodb://[^/]+)/[^?]*(\?.*)?|\1/\2|'
}

extract_mongo_creds() {
    echo "$1" | sed -n 's|mongodb://\([^:]*\):\([^@]*\)@.*|\1 \2|p'
}

# === CARREGAR CONFIGURAÇÕES ===
log "📋 Carregando configurações do .env local..."

LOCAL_MONGO_URI=$(get_env_var "MONGO_URI")
[ -z "$LOCAL_MONGO_URI" ] && { error "MONGO_URI ausente no .env local"; exit 1; }

LOCAL_S3_HOST=$(get_env_var "S3_HOST")
LOCAL_S3_KEY=$(get_env_var "S3_KEY")
LOCAL_S3_SECRET=$(get_env_var "S3_SECRET")

HAS_LOCAL_S3=false
[ -n "$LOCAL_S3_HOST" ] && [ -n "$LOCAL_S3_KEY" ] && [ -n "$LOCAL_S3_SECRET" ] && HAS_LOCAL_S3=true

HAS_BACKUP_S3=false
[ -d "$BACKUP_DIR/s3" ] && [ "$(ls -A "$BACKUP_DIR/s3" 2>/dev/null)" ] && HAS_BACKUP_S3=true

# Detectar se o MongoDB local é externo (projeto car na porta do host)
IS_EXTERNAL_MONGO=false
if echo "$LOCAL_MONGO_URI" | grep -qE 'localhost|host\.docker\.internal|[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+'; then
    IS_EXTERNAL_MONGO=true
fi

if $IS_EXTERNAL_MONGO; then
    RESTORE_URI=$(echo "$LOCAL_MONGO_URI" | sed 's/host\.docker\.internal/127.0.0.1/g; s/localhost/127.0.0.1/g')
    LOCAL_SERVER_URI=$(server_uri "$RESTORE_URI")
    MONGO_NET_ARGS="--network=host"
else
    COMPOSE_NET="$(basename "$(pwd)")_default"
    RESTORE_URI="$LOCAL_MONGO_URI"
    LOCAL_SERVER_URI=$(server_uri "$RESTORE_URI")
    MONGO_NET_ARGS="--network=$COMPOSE_NET"
fi

MONGO_CREDS=($(extract_mongo_creds "$RESTORE_URI"))
MONGO_USER="${MONGO_CREDS[0]}"
MONGO_PASS="${MONGO_CREDS[1]}"

log "🚀 Iniciando restore do backup local..."
info "   Backup:      $BACKUP_DIR"
$IS_EXTERNAL_MONGO \
    && info "   Mongo local: $LOCAL_SERVER_URI (porta do projeto car — certifique-se de que o car está rodando)" \
    || info "   Mongo local: via rede $COMPOSE_NET"
$HAS_BACKUP_S3 && $HAS_LOCAL_S3 \
    && info "   S3:          $LOCAL_S3_HOST (restore incluído)" \
    || { $HAS_BACKUP_S3 \
        && warn "   S3:          backup tem arquivos mas S3_HOST/S3_KEY/S3_SECRET ausentes no .env — será ignorado" \
        || info "   S3:          sem arquivos no backup"; }

# === FASE 1: PREPARAR SERVIÇOS LOCAIS ===
if $IS_EXTERNAL_MONGO; then
    warn "⏭️  MongoDB em $LOCAL_SERVER_URI (porta do projeto car no host)"
    info "   Para garantir conectividade: cd ~/car && docker compose up -d mongo"
else
    log "🔄 Reiniciando serviços locais..."
    docker compose down >/dev/null 2>&1 || true
    SERVICES_TO_START="mongo redis"
    $HAS_LOCAL_S3 && SERVICES_TO_START="$SERVICES_TO_START minio"
    docker compose up -d $SERVICES_TO_START >/dev/null 2>&1
fi

# === FASE 2: AGUARDAR MONGODB LOCAL ===
log "⏳ Aguardando MongoDB local..."
for i in {1..30}; do
    if docker run --rm $MONGO_NET_ARGS mongo:7 \
        mongosh "$LOCAL_SERVER_URI" --eval "db.runCommand('ping')" --quiet >/dev/null 2>&1; then
        break
    fi
    if [ "$i" -eq 30 ]; then
        error "❌ MongoDB local não respondeu após 60s"
        $IS_EXTERNAL_MONGO && error "   Execute antes: cd ~/car && docker compose up -d mongo"
        exit 1
    fi
    sleep 2
done
log "✅ MongoDB local pronto"

if $HAS_LOCAL_S3; then
    log "⏳ Aguardando MinIO local..."
    for i in {1..20}; do
        curl -sf "$LOCAL_S3_HOST/minio/health/live" >/dev/null 2>&1 && break
        sleep 2
    done
fi

# === FASE 3: RESTAURAR MONGODB ===
log "📤 Restaurando MongoDB (todos os bancos do backup)..."

# Listar bancos no backup (excluindo diretório s3)
BACKUP_DBS=$(find "$BACKUP_DIR" -maxdepth 1 -mindepth 1 -type d ! -name s3 -exec basename {} \; | tr '\n' ' ')
info "   Bancos encontrados no backup: $BACKUP_DBS"

if docker run --rm $MONGO_NET_ARGS \
    -v "$(pwd)/$BACKUP_DIR:/backup" mongo:7 \
    mongorestore --uri="$LOCAL_SERVER_URI" --gzip --drop \
        --nsExclude="admin.*" --nsExclude="local.*" --nsExclude="config.*" \
        "/backup" --quiet; then
    log "✅ Restore MongoDB concluído"
else
    error "❌ Falha no restore MongoDB"
    exit 1
fi

# === FASE 4: RESTAURAR S3 (SE BACKUP TEM S3 E .env TEM CONFIGURAÇÃO) ===
if $HAS_BACKUP_S3 && $HAS_LOCAL_S3; then
    log "📤 Restaurando S3..."
    LOCAL_S3_DOCKER=$(echo "$LOCAL_S3_HOST" | sed 's/localhost/minio/g; s/127.0.0.1/minio/g; s/host.docker.internal/minio/g')
    S3_NETWORK="$(basename "$(pwd)")_default"
    docker run --rm --network="$S3_NETWORK" \
        -v "$(pwd)/$BACKUP_DIR/s3:/data" \
        --entrypoint /bin/sh minio/mc:latest -c "
            mc alias set local '$LOCAL_S3_DOCKER' '$LOCAL_S3_KEY' '$LOCAL_S3_SECRET'
            if mc ls local/ >/dev/null 2>&1; then
                echo 'Limpando S3 local...'
                mc ls local 2>/dev/null | awk '{print \$NF}' | sed 's|/\$||' | while read bucket; do
                    [ -n \"\$bucket\" ] && mc rm --recursive --force local/\$bucket/ 2>/dev/null || true
                    [ -n \"\$bucket\" ] && mc rb local/\$bucket/ 2>/dev/null || true
                done
                mc mirror /data/ local/ --quiet && echo 'Restore S3 concluído' || { echo 'Falha no restore S3'; exit 1; }
            else
                echo 'Falha na conexão com S3 local'
                exit 1
            fi
        " >/dev/null 2>&1 \
        && log "✅ Restore S3 concluído" \
        || warn "⚠️  Falha no restore S3 (dados MongoDB restaurados com sucesso)"
elif $HAS_BACKUP_S3 && ! $HAS_LOCAL_S3; then
    warn "⚠️  Backup tem arquivos S3 mas S3_HOST/S3_KEY/S3_SECRET ausentes no .env — S3 ignorado"
fi

# === FASE 5: INICIAR APLICAÇÃO COMPLETA ===
if ! $IS_EXTERNAL_MONGO; then
    log "🚀 Iniciando aplicação completa..."
    docker compose up -d >/dev/null 2>&1
fi

# === FASE 6: VERIFICAÇÃO FINAL ===
log "📊 Verificando dados restaurados..."
sleep 3

info "📊 MongoDB — todos os bancos restaurados:"
docker run --rm $MONGO_NET_ARGS mongo:7 \
    mongosh "$LOCAL_SERVER_URI" --quiet --eval "
    const dbs = db.getMongo().getDB('admin')
        .adminCommand({ listDatabases: 1 }).databases
        .filter(d => !['admin','local','config'].includes(d.name));
    if (dbs.length === 0) { print('  (nenhum banco encontrado)'); quit(); }
    dbs.forEach(d => {
        const database = db.getMongo().getDB(d.name);
        const collections = database.getCollectionNames();
        print('');
        print('=== ' + d.name + ' ===');
        if (collections.length === 0) { print('  (sem coleções)'); return; }
        collections.forEach(c => {
            try {
                const count = database[c].countDocuments();
                print('  ' + c + ': ' + count + ' documentos');
            } catch(e) { print('  ' + c + ': (erro ao contar)'); }
        });
    });
" 2>/dev/null || warn "⚠️  Verificação MongoDB falhou"

if $HAS_BACKUP_S3 && $HAS_LOCAL_S3; then
    info ""
    info "📊 S3 local:"
    LOCAL_S3_DOCKER=$(echo "$LOCAL_S3_HOST" | sed 's/localhost/minio/g; s/127.0.0.1/minio/g; s/host.docker.internal/minio/g')
    docker run --rm --network="$(basename "$(pwd)")_default" \
        --entrypoint /bin/sh minio/mc:latest -c "
            mc alias set local '$LOCAL_S3_DOCKER' '$LOCAL_S3_KEY' '$LOCAL_S3_SECRET' >/dev/null 2>&1
            mc du local/ 2>/dev/null | tail -1 || echo '  (nenhum arquivo)'
        " 2>/dev/null || true
fi

log ""
log "🎉 Restore concluído!"
log "💾 Backup usado: $BACKUP_DIR"
info "ℹ️  Para restaurar novamente: ./scripts/restore-local.sh $BACKUP_DIR"
