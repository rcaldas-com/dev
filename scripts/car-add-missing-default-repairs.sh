#!/bin/bash

# Script para adicionar manutenções padrão faltantes em veículos usando Docker
# Uso: ./add-missing-default-repairs.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "🔧 Adicionar Manutenções Padrão Faltantes (Docker)"
echo "=================================================="
echo ""

# Verificar se Docker está disponível
if ! command -v docker &> /dev/null; then
    echo "❌ Docker não encontrado. Instale o Docker para continuar."
    exit 1
fi

# Verificar se docker-compose está disponível (ou docker compose)
if command -v docker-compose &> /dev/null; then
    DC_CMD="docker-compose"
elif docker compose version &> /dev/null 2>&1; then
    DC_CMD="docker compose"
else
    echo "❌ Docker Compose não encontrado. Instale o Docker Compose para continuar."
    exit 1
fi

# Verificar se estamos no diretório correto (deve ter docker-compose.yml)
COMPOSE_FILE="$PROJECT_DIR/docker-compose.yml"
if [ ! -f "$COMPOSE_FILE" ]; then
    echo "❌ Arquivo docker-compose.yml não encontrado em: $COMPOSE_FILE"
    echo "   Execute este script a partir do diretório scripts/"
    exit 1
fi

# Verificar se o arquivo .env existe
ENV_FILE="$PROJECT_DIR/.env"
if [ ! -f "$ENV_FILE" ]; then
    echo "❌ Arquivo .env não encontrado em: $ENV_FILE"
    exit 1
fi

echo "📁 Diretório do projeto: $PROJECT_DIR"
echo "🐳 Usando Docker Compose: $DC_CMD"
echo ""

# Obter a network do docker-compose
NETWORK_NAME=$(cd "$PROJECT_DIR" && $DC_CMD ps --format json | head -1 | jq -r '.Networks' | cut -d',' -f1)
if [ -z "$NETWORK_NAME" ]; then
    NETWORK_NAME="car-dev_default"
    echo "⚠️  Usando network padrão: $NETWORK_NAME"
else
    echo "🌐 Usando network: $NETWORK_NAME"
fi

echo ""
echo "⚠️  ATENÇÃO:"
echo "   Este script irá adicionar manutenções padrão faltantes em TODOS os veículos."
echo "   As manutenções já existentes NÃO serão alteradas."
echo ""

read -p "🤔 Deseja continuar? (y/N): " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "❌ Operação cancelada pelo usuário"
    exit 0
fi

echo ""
echo "🚀 Iniciando processamento via Docker..."
echo ""

# Executar container temporário Node.js
echo "🐳 Criando container temporário Node.js..."
cd "$PROJECT_DIR"
docker run --rm -it \
  --network="$NETWORK_NAME" \
  --env-file="$ENV_FILE" \
  -v "$SCRIPT_DIR:/scripts" \
  -w /scripts \
  node:20-alpine \
  sh -c "npm install mongodb && node add-missing-default-repairs.js"

echo ""
echo "✅ Script concluído!"
