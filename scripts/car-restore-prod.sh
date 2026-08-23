#!/bin/bash

# Script para restore completo do banco e S3 de produção
# Uso: ./scripts/restore-prod.sh config-file.env

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${GREEN}[$(date +'%H:%M:%S')] $1${NC}"; }
warn() { echo -e "${YELLOW}[$(date +'%H:%M:%S')] $1${NC}"; }
error() { echo -e "${RED}[$(date +'%H:%M:%S')] $1${NC}"; }
info() { echo -e "${BLUE}[$(date +'%H:%M:%S')] $1${NC}"; }

if [ -z "$1" ]; then
    error "Uso: $0 config-file.env"
    error "O arquivo deve conter: MONGO_URI, S3_HOST, S3_KEY, S3_SECRET"
    exit 1
fi

CONFIG_FILE="$1"
if [ ! -f "$CONFIG_FILE" ]; then
    error "Arquivo de configuração não encontrado: $CONFIG_FILE"
    exit 1
fi

BACKUP_DIR="backup-$(date +%Y%m%d-%H%M%S)"

# Função para ler variável do arquivo de configuração
get_config_var() {
    grep "^$1=" "$CONFIG_FILE" 2>/dev/null | cut -d'=' -f2- | tr -d '"'
}

# Função para ler variável do .env local
get_env_var() {
    grep "^$1=" .env 2>/dev/null | cut -d'=' -f2- | tr -d '"'
}

# Função para extrair credenciais do MongoDB URI
extract_mongo_creds() {
    local uri="$1"
    # Extrair usuário e senha do formato mongodb://user:pass@host:port/db
    echo "$uri" | sed -n 's|mongodb://\([^:]*\):\([^@]*\)@.*|\1 \2|p'
}

# Função para extrair nome do banco de dados da URI
extract_db_name() {
    local uri="$1"
    # Extrair nome do banco após a última / e antes de ?
    echo "$uri" | sed -n 's|.*\/\([^?]*\).*|\1|p'
}

# Carregar configurações de produção
log "📋 Carregando configurações..."
PROD_MONGO_URI=$(get_config_var "MONGO_URI")
PROD_S3_HOST=$(get_config_var "S3_HOST")
PROD_S3_KEY=$(get_config_var "S3_KEY")
PROD_S3_SECRET=$(get_config_var "S3_SECRET")

if [ -z "$PROD_MONGO_URI" ] || [ -z "$PROD_S3_HOST" ] || [ -z "$PROD_S3_KEY" ] || [ -z "$PROD_S3_SECRET" ]; then
    error "Arquivo de configuração incompleto. Necessário: MONGO_URI, S3_HOST, S3_KEY, S3_SECRET"
    exit 1
fi

# Obter configurações locais do arquivo .env
LOCAL_MONGO_URI=$(get_env_var "MONGO_URI")
LOCAL_S3_HOST=$(get_env_var "S3_HOST")
LOCAL_S3_KEY=$(get_env_var "S3_KEY")
LOCAL_S3_SECRET=$(get_env_var "S3_SECRET")

if [ -z "$LOCAL_MONGO_URI" ] || [ -z "$LOCAL_S3_HOST" ] || [ -z "$LOCAL_S3_KEY" ] || [ -z "$LOCAL_S3_SECRET" ]; then
    error "Configurações locais incompletas no arquivo .env"
    exit 1
fi

# Converter para usar hostname docker (mongo em vez de localhost)
LOCAL_URI=$(echo "$LOCAL_MONGO_URI" | sed 's/localhost/mongo/g')

# Para S3, garantir que esteja usando o nome do serviço Docker
LOCAL_S3_DOCKER_HOST=$(echo "$LOCAL_S3_HOST" | sed 's/localhost/minio/g')

# Extrair credenciais para comandos mongosh
MONGO_CREDS=($(extract_mongo_creds "$LOCAL_URI"))
MONGO_USER="${MONGO_CREDS[0]}"
MONGO_PASS="${MONGO_CREDS[1]}"

# Extrair nome do banco de dados
DB_NAME=$(extract_db_name "$LOCAL_URI")

log "🚀 Iniciando sincronização completa com produção..."
log "📍 URI local: $LOCAL_URI"
log "🗄️  Banco de dados: $DB_NAME"
log "☁️  S3 produção: $PROD_S3_HOST"
log "💾 S3 local: $LOCAL_S3_DOCKER_HOST"

# Criar diretório de backup
mkdir -p "$BACKUP_DIR"

# === FASE 1: BACKUP DO MONGODB ===
log "📥 Baixando dados de produção (MongoDB)..."
if docker run --rm --user $(id -u):$(id -g) -v "$(pwd)/$BACKUP_DIR:/backup" mongo:7 \
   mongodump --uri="$PROD_MONGO_URI" --out="/backup" --gzip --quiet; then
    log "✅ Backup MongoDB de produção concluído"
else 
    error "❌ Falha no backup MongoDB de produção"
    exit 1
fi

# === FASE 2: BACKUP DO S3 ===
log "📥 Baixando arquivos de produção (S3)..."
mkdir -p "$BACKUP_DIR/s3"

# Usar container temporário com minio client para backup S3
log "🔧 Configurando cliente S3 para backup..."
docker run --rm -v "$(pwd)/$BACKUP_DIR/s3:/data" \
    --entrypoint /bin/sh minio/mc:latest -c "
        mc alias set prod '$PROD_S3_HOST' '$PROD_S3_KEY' '$PROD_S3_SECRET'
        if mc ls prod/ >/dev/null 2>&1; then
            echo 'Conectado ao S3 de produção'
            mc mirror prod/ /data/ --quiet || echo 'Falha no backup S3'
        else
            echo 'Falha na conexão com S3 de produção'
            exit 1
        fi
    " 2>/dev/null && log "✅ Backup S3 de produção concluído" || warn "⚠️  Falha no backup S3 (continuando sem arquivos)"

# === FASE 3: REINICIAR AMBIENTE ===
log "🔄 Reiniciando ambiente..."
docker compose down > /dev/null 2>&1 || true
docker compose up -d mongo redis minio > /dev/null 2>&1

# Aguardar serviços
log "⏳ Aguardando serviços..."
for i in {1..30}; do
    if docker exec $(docker compose ps -q mongo) mongosh --eval "db.runCommand('ping')" >/dev/null 2>&1; then
        break
    fi
    sleep 2
done

# Aguardar MinIO
for i in {1..20}; do
    if curl -s "$LOCAL_S3_HOST/minio/health/live" >/dev/null 2>&1; then
        break
    fi
    sleep 2
done

# === FASE 4: LIMPAR DADOS LOCAIS ===
log "🧹 Limpando dados locais (MongoDB + S3)..."

# Limpar MongoDB
docker exec $(docker compose ps -q mongo) mongosh "$DB_NAME" --authenticationDatabase admin -u "$MONGO_USER" -p "$MONGO_PASS" --quiet --eval "
    db.getCollectionNames().forEach(collection => db[collection].drop());
" >/dev/null 2>&1

# Limpar MinIO completamente usando container na rede do compose
info "🗑️  Limpando MinIO local..."
NETWORK_NAME="$(basename $(pwd))_default"

# Usar container temporário do minio client na rede do compose
docker run --rm --network="$NETWORK_NAME" \
    --entrypoint /bin/sh minio/mc:latest -c "
        mc alias set local '$LOCAL_S3_DOCKER_HOST' '$LOCAL_S3_KEY' '$LOCAL_S3_SECRET'
        if mc ls local/ >/dev/null 2>&1; then
            echo 'Conectado ao MinIO local'
            echo 'Executando limpeza completa...'
            
            # Método 1: Remover buckets conhecidos da aplicação
            for bucket in repair car user file default wishlist; do
                if mc ls local/\$bucket/ >/dev/null 2>&1; then
                    echo \"Limpando bucket: \$bucket\"
                    mc rm --recursive --force local/\$bucket/ 2>/dev/null || true
                    mc rb local/\$bucket/ 2>/dev/null || true
                else
                    echo \"Bucket \$bucket não existe\"
                fi
            done
            
            # Verificar se ainda há buckets
            remaining=\$(mc ls local 2>/dev/null | wc -l)
            if [ \"\$remaining\" -eq 0 ]; then
                echo 'MinIO local completamente limpo'
            else
                echo \"Atenção: \$remaining bucket(s) ainda restam\"
                # Tentar remover buckets restantes
                mc ls local 2>/dev/null | while IFS= read -r line; do
                    bucket=\$(echo \"\$line\" | rev | cut -d' ' -f1 | rev | sed 's|/$||')
                    if [ ! -z \"\$bucket\" ]; then
                        echo \"Removendo bucket restante: \$bucket\"
                        mc rm --recursive --force local/\$bucket/ 2>/dev/null || true
                        mc rb local/\$bucket/ 2>/dev/null || true
                    fi
                done
            fi
        else
            echo 'Falha na conexão com MinIO local'
        fi
    " 2>&1 && log "✅ MinIO local limpo" || warn "⚠️  Falha na limpeza do MinIO (continuando)"

# === FASE 5: RESTAURAR MONGODB ===
log "📤 Restaurando dados MongoDB..."
if docker run --rm --network="$(basename $(pwd))_default" -v "$(pwd)/$BACKUP_DIR:/backup" mongo:7 \
   mongorestore --uri="$LOCAL_URI" --gzip --drop "/backup/$DB_NAME" --quiet; then
    log "✅ Restore MongoDB concluído"
else
    error "❌ Falha no restore MongoDB"
    exit 1
fi

# === FASE 6: RESTAURAR S3 ===
log "📤 Restaurando arquivos S3..."
if [ -d "$BACKUP_DIR/s3" ] && [ "$(ls -A $BACKUP_DIR/s3)" ]; then
    # Usar container temporário do minio client na rede do compose para restore
    docker run --rm --network="$NETWORK_NAME" -v "$(pwd)/$BACKUP_DIR/s3:/data" \
        --entrypoint /bin/sh minio/mc:latest -c "
            mc alias set local '$LOCAL_S3_DOCKER_HOST' '$LOCAL_S3_KEY' '$LOCAL_S3_SECRET'
            if mc ls local/ >/dev/null 2>&1; then
                echo 'Conectado ao MinIO local para restore'
                mc mirror /data/ local/ --quiet && echo 'Restore S3 concluído' || echo 'Falha no restore S3'
            else
                echo 'Falha na conexão com MinIO local'
                exit 1
            fi
        " >/dev/null 2>&1 && log "✅ Restore S3 concluído" || warn "⚠️  Falha no restore S3 (dados MongoDB restaurados com sucesso)"
else
    warn "⚠️  Nenhum arquivo S3 para restaurar"
fi

# === FASE 7: INICIAR APLICAÇÃO ===
log "🚀 Iniciando aplicação completa..."
docker compose up -d > /dev/null 2>&1

# === FASE 8: VERIFICAÇÕES FINAIS ===
log "📊 Verificando dados importados..."
sleep 3

# Verificar MongoDB
info "📊 Dados MongoDB:"
docker exec $(docker compose ps -q mongo) mongosh "$DB_NAME" --authenticationDatabase admin -u "$MONGO_USER" -p "$MONGO_PASS" --quiet --eval "
    print('=== DADOS IMPORTADOS (MongoDB) ===');
    const collections = ['car', 'repair', 'user', 'wishlist', 'file'];
    collections.forEach(name => {
        try {
            const count = db[name].countDocuments();
            print(\`\${name}: \${count} documentos\`);
        } catch(e) {
            print(\`\${name}: coleção não encontrada\`);
        }
    });
"

# Verificar S3/MinIO
info "📊 Dados S3:"
docker run --rm --network="$NETWORK_NAME" \
    --entrypoint /bin/sh minio/mc:latest -c "
        mc alias set local '$LOCAL_S3_DOCKER_HOST' '$LOCAL_S3_KEY' '$LOCAL_S3_SECRET'
        if mc ls local/ >/dev/null 2>&1; then
            echo '=== DADOS IMPORTADOS (S3) ==='
            mc du local/ 2>/dev/null | tail -1 || echo 'Nenhum arquivo encontrado no S3'
        else
            echo 'S3: Falha na conexão para verificação'
        fi
    " 2>/dev/null

log "🎉 Sincronização completa concluída!"
log "💾 Backup salvo em: $BACKUP_DIR"
info "� Para usar este backup novamente, execute:"
info "   ./scripts/restore-prod.sh $CONFIG_FILE"
