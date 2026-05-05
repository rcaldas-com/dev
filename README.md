# RCaldas Dev
Ambiente de Desenvolvimento Local dos serviços RCaldas em Docker

Faça clone do repositório com o seguinte comando para baixar os submódulos:

`git clone --recurse-submodules git@github.com:rcaldas-com/dev.git rcaldas`

Entre no novo diretório e faça checkout nos submódulos:

`cd rcaldas`

`git submodule foreach -q --recursive 'git checkout main || git checkout master'`

Crie o arquivo `.env` a partir do ememplo:

`cp env-example .env`

Inicie os serviços em segundo plano:

`docker compose up -d`

Siga os logs do serviço "web":

`docker compose logs -f web`

Acesso o app pelo link http://localhost:8001


### Banco de Dados

O dump do banco de dados por ser colocado no diretório `bkp/`

O restore do backup pode ser feito com o comando:

`docker compose exec -it mongo sh -c 'mongorestore --objcheck --drop --uri="$MONGODB_URI"'`


### Build do Web App Next.js para Produção

Abra um shell interativo no container web
`docker compose exec -it web bash`


### Teste manual do emailer em produção

Para validar se o worker de email está consumindo a fila e enviando pelo SMTP, publique uma mensagem diretamente no Redis:

```bash
docker compose exec redis redis-cli LPUSH email:send '{
	"to":"seu-email@dominio.com",
	"subject":"Teste RCaldas Emailer",
	"template":"reset-password",
	"variables":{
		"name":"Teste",
		"resetUrl":"https://web.rcaldas.com/reset-password?token=teste",
		"app":"RCaldas"
	}
}'
```

Depois acompanhe os logs:

```bash
docker compose logs emailer --tail=80
```

Se aparecer `[DRY-RUN EMAIL]`, o container não está com SMTP configurado. Se aparecer `SMTP aceitou email`, o servidor SMTP recebeu a mensagem e qualquer falha posterior tende a ser fila/spam/política do provedor.


### Seed do módulo Finance

Popula o banco com dados de perfil, cartões, despesas e parcelas:

```bash
cd ~/car && docker compose exec -T mongo mongosh --quiet -u user -p password --authenticationDatabase admin rcaldas < /home/robca/rcaldas/scripts/seed-finance.js
```

O script limpa os dados existentes antes de inserir. Os dados de referência estão em `scripts/seed-finance.js` (dump de 2026-04-07).

