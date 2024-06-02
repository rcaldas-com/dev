# RCaldas Dev
Ambiente de Desenvolvimento Local dos serviços RCaldas em Docker

Faça clone do repositório com o seguinte comando para baixar os submódulos:

`git clone --recurse-submodules git@github.com:rcaldas-com/rcaldas-dev.git`

Entre no novo diretório e faça checkout nos submódulos:

`cd rcaldas-dev`

`git submodule foreach -q --recursive 'git checkout main || git checkout master'`

Crie o arquivo `.env` a partir do ememplo:

`cp env-example .env`

Inicie os serviços em segundo plano:

`docker compose up -d`

Siga os logs do serviço "web":

`docker compose logs -f web`

Acesso o app pelo link http://localhost:8001
