#!/bin/bash
# Valida os scripts bash que o app SERVE (/init, /install, ...).
#
# O QUE MUDOU
# -----------
# Ate 12/09/2026 esses scripts moravam dentro de template literal de JS, e
# este checker existia pra pegar os acidentes que isso causava: crase em
# comentario encerrando o literal, `${VAR}` do bash lido como interpolacao,
# `\n` virando quebra de linha de verdade. Sete quebras de build pelo mesmo
# motivo.
#
# Agora o bash mora em web/served-scripts/*.sh -- arquivo de verdade, sem
# camada de escape. Aquela classe inteira de erro deixou de existir, e o
# que sobra pra verificar e' outra coisa:
#
#   1. o .sh e' bash valido
#   2. todo marcador @@NOME@@ do .sh tem valor no route que o serve
#      (senao o servedScript lanca -- melhor descobrir aqui que em runtime)
#   3. nenhum .sh ficou orfao, sem route que o sirva
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIR="$REPO/web/served-scripts"
APP="$REPO/web/app"
FALHAS=0

[[ -d "$DIR" ]] || { echo "diretorio nao existe: $DIR"; exit 1; }

# partials/ sao fragmentos usados por outras rotas (script de dump,
# preexec) -- nao tem route proprio, entao so' a validacao de sintaxe vale.
for sh in "$DIR"/*.sh "$DIR"/partials/*.sh; do
  [[ -e "$sh" ]] || continue
  nome=$(basename "$sh")
  rota="${nome%.sh}"
  parcial=no; [[ "$sh" == */partials/* ]] && parcial=sim
  echo "== ${parcial:+}$([[ $parcial == sim ]] && echo 'partials/')$nome =="

  if bash -n "$sh" 2>/tmp/err_ck; then
    echo "   bash -n: ok ($(wc -l < "$sh") linhas)"
  else
    echo "   BASH INVALIDO:"; sed 's/^/     /' /tmp/err_ck
    FALHAS=$((FALHAS+1)); continue
  fi

  if command -v shellcheck >/dev/null 2>&1; then
    # Marcador @@X@@ nao e' sintaxe de shell; o -e SC1009/SC1073 evita
    # ruido onde ele aparece no lugar de um valor.
    if shellcheck -S error -e SC1009,SC1073,SC1072,SC2154 "$sh" >/tmp/err_sc 2>&1; then
      echo "   shellcheck: ok"
    else
      echo "   shellcheck apontou:"; head -12 /tmp/err_sc | sed 's/^/     /'
      FALHAS=$((FALHAS+1))
    fi
  fi

  # Marcador que aparece 2+ vezes NAO e' erro por si so' (RET_DIA, APP_URL
  # etc sao seguros -- valor de uma linha so'), mas e' o padrao exato que
  # quebrou limpa-orfaos.sh: um marcador dentro de um COMENTARIO, com
  # valor de VARIAS linhas, faz as linhas seguintes "vazarem" do comentario
  # e virarem bash de verdade. servedScript() faz substituicao de texto
  # literal -- nao sabe o que e' comentario nem quantas linhas o valor tem.
  # So' aviso (nao falha o build): cabe a quem edita julgar se o valor
  # daquele marcador pode ter mais de uma linha.
  repetidos=""
  for m in $(grep -oE '@@[A-Za-z_][A-Za-z0-9_]*@@' "$sh" | sort -u); do
    n=$(grep -oF "$m" "$sh" | wc -l)
    [[ "$n" -gt 1 ]] && repetidos="$repetidos $m(${n}x)"
  done
  [[ -n "$repetidos" ]] && echo "   AVISO -- marcador repetido, confira se o valor e' sempre 1 linha:$repetidos"

  if [[ "$parcial" == sim ]]; then
    echo "   parcial: sem route proprio (usado por outra rota)"
    continue
  fi

  route="$APP/$rota/route.ts"
  if [[ ! -f "$route" ]]; then
    echo "   ORFAO: nenhum route em app/$rota/route.ts serve este arquivo"
    FALHAS=$((FALHAS+1)); continue
  fi

  # Marcador usado no .sh que o route nao fornece = erro em runtime.
  faltando=""
  for m in $(grep -oE '@@[A-Za-z_][A-Za-z0-9_]*@@' "$sh" | tr -d '@' | sort -u); do
    grep -q "\b$m\b" "$route" || faltando="$faltando $m"
  done
  if [[ -n "$faltando" ]]; then
    echo "   MARCADOR SEM VALOR no route:$faltando"
    FALHAS=$((FALHAS+1))
  else
    echo "   marcadores: todos supridos por app/$rota/route.ts"
  fi
done

rm -f /tmp/err_ck /tmp/err_sc
echo
if [[ $FALHAS -eq 0 ]]; then echo "tudo ok"; else echo "$FALHAS verificacao(oes) falhou(ram)"; fi
exit $FALHAS
