#!/bin/bash

# Script para inicializar categorias padrão de manutenção
# 
# Detecta automaticamente se deve usar:
# - Docker Compose (para URLs locais como mongodb://db:27017)
# - Docker standalone (para URLs públicas/remotas)
# 
# Uso:
#   ./scripts/init-categories.sh [arquivo-env]
#   ./scripts/init-categories.sh .env.production
#   ./scripts/init-categories.sh web/.env.local

set -e

# Cores
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

ENV_FILE="${1:-web/.env.local}"

echo -e "${BLUE}🚀 Inicializando categorias de manutenção...${NC}\n"

if [ ! -f "$ENV_FILE" ]; then
    echo -e "${RED}❌ Arquivo $ENV_FILE não encontrado!${NC}"
    exit 1
fi

echo -e "${GREEN}✅ Arquivo $ENV_FILE encontrado${NC}"

MONGO_URI=$(grep "^MONGO_URI=" "$ENV_FILE" | cut -d '=' -f2- | tr -d '"' | tr -d "'")

if [ -z "$MONGO_URI" ]; then
    echo -e "${RED}❌ MONGO_URI não encontrado no arquivo $ENV_FILE${NC}"
    exit 1
fi

# Detectar se é URL local (usa nomes de serviços do compose como 'mongo')
# Exemplos: mongodb://mongo:27017, mongodb://user:pass@mongo/db, mongodb://mongo/db
if [[ "$MONGO_URI" =~ mongodb://.*@mongo[/:] ]] || [[ "$MONGO_URI" =~ mongodb://mongo[/:] ]]; then
    USE_COMPOSE=true
    echo -e "${YELLOW}🔍 Detectado MongoDB local (compose network)${NC}"
else
    USE_COMPOSE=false
    echo -e "${BLUE}🌐 Detectado MongoDB remoto${NC}"
fi

# Script JavaScript inline
cat > /tmp/init-categories-$$.js << 'EOFJS'
const { MongoClient } = require('mongodb');

const defaultCategories = [
  { id: 'motor', name: 'Motor', description: 'Motor, combustível, arrefecimento, escapamento, fixação do motor', icon: 'engine', order: 1 },
  { id: 'iluminacao', name: 'Iluminação', description: 'Faróis, lanternas, lâmpadas e sistema elétrico de iluminação', icon: 'lightbulb', order: 2 },
  { id: 'transmissao', name: 'Transmissão', description: 'Câmbio, cardã, diferencial e componentes de transmissão', icon: 'cog', order: 3 },
  { id: 'suspensao', name: 'Suspensão', description: 'Amortecedores, molas, bandejas, bieletas, direção e alinhamento', icon: 'arrows-alt-v', order: 4 },
  { id: 'pneus_rodas_freios', name: 'Pneus, Rodas e Freios', description: 'Pneus, rodas, freios, pastilhas, discos e sistema de frenagem', icon: 'circle', order: 5 },
  { id: 'manutencao_geral', name: 'Manutenção Geral', description: 'Limpezas, lubrificações e manutenções periódicas gerais', icon: 'tools', order: 6 },
  { id: 'estetica_carroceria', name: 'Estética e Carroceria', description: 'Pintura, vidros, acessórios estéticos e reparos de carroceria', icon: 'paint-brush', order: 7 },
  { id: 'administrativo', name: 'Administrativo', description: 'Compra, documentos, impostos e despesas administrativas', icon: 'file-text', order: 8 },
  { id: 'outros', name: 'Outros', description: 'Itens que não se encaixam nas categorias acima', icon: 'ellipsis-h', order: 9 }
];

async function init() {
  const uri = process.env.MONGO_URI;
  if (!uri) { console.error('❌ MONGO_URI não encontrado'); process.exit(1); }
  
  console.log('🔌 Conectando ao MongoDB...');
  const client = new MongoClient(uri, {
    serverSelectionTimeoutMS: 10000,
    connectTimeoutMS: 10000
  });
  try {
    await client.connect();
    console.log('✅ Conectado ao MongoDB');
    
    const collection = client.db().collection('repair_categories');
    const count = await collection.countDocuments();
    
    if (count > 0) {
      console.log(`⚠️  Já existem ${count} categorias. Abortando.`);
      process.exit(0);
    }
    
    console.log(`📝 Inserindo ${defaultCategories.length} categorias...`);
    const cats = defaultCategories.map(c => ({...c, createdAt: new Date(), updatedAt: new Date()}));
    const result = await collection.insertMany(cats);
    
    console.log(`✅ ${result.insertedCount} categorias criadas!`);
    defaultCategories.forEach((c, i) => console.log(`  ${i + 1}. ${c.name} (${c.id})`));
  } catch (error) {
    console.error('❌ Erro:', error.message);
    process.exit(1);
  } finally {
    await client.close();
    console.log('\n🔌 Conexão fechada');
  }
}

init();
EOFJS

# Executar conforme o tipo de conexão
if [ "$USE_COMPOSE" = true ]; then
    echo -e "${BLUE}🐳 Usando Docker Compose (rede compartilhada)...${NC}"
    
    # Serviço 'car', não 'web': depois que o car veio do stack próprio pra
    # dentro do dev, 'web' passou a ser o app rcaldas. Rodar isto no 'web'
    # apontaria o script pro container errado — que sobe, tem rede e não
    # reclama, então o erro só apareceria no resultado.
    if ! docker compose ps | grep -q "car"; then
        echo -e "${RED}❌ Container 'car' não está rodando!${NC}"
        echo -e "   Execute: docker compose up -d"
        rm -f /tmp/init-categories-$$.js
        exit 1
    fi

    # Executar no container car, que tem acesso à rede do compose
    docker compose exec -T car sh -c "
        npm install --silent mongodb 2>/dev/null
        node - <<'NODESCRIPT'
$(cat /tmp/init-categories-$$.js)
NODESCRIPT
    " <<< "MONGO_URI=$MONGO_URI"
    
    EXIT_CODE=$?
else
    echo -e "${BLUE}🐳 Usando Docker standalone...${NC}"
    
    # Rodar em container Docker independente para URLs públicas
    echo "📦 Instalando driver MongoDB..."
    docker run --rm \
      -e MONGO_URI="$MONGO_URI" \
      -v /tmp/init-categories-$$.js:/app/script.js:ro \
      -w /app \
      node:18-alpine \
      sh -c "echo '{\"type\":\"commonjs\"}' > package.json && npm install --silent mongodb && node script.js"
    
    EXIT_CODE=$?
fi

rm -f /tmp/init-categories-$$.js

if [ $EXIT_CODE -eq 0 ]; then
  echo -e "\n${GREEN}✨ Concluído!${NC}"
else
  echo -e "\n${RED}❌ Falhou com código $EXIT_CODE${NC}"
  exit $EXIT_CODE
fi
