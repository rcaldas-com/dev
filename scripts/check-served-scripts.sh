#!/bin/bash
# Valida os scripts bash que /init e /install SERVEM, sem subir o Next.
#
# POR QUE EXISTE
# -------------
# Aquele bash mora dentro de um template literal de JS, entao passa por um
# escape antes de chegar no host. Tres classes de erro ja quebraram
# producao a partir dai, e nenhuma aparece lendo o codigo:
#
# 1. BACKTICK em comentario. Encerra o template no meio e quebra o
#    `next build` inteiro. Aconteceu QUATRO vezes -- sempre no mesmo tipo
#    de comentario explicativo, do tipo "o `set -e` mata o script".
# 2. `\n` que vira NEWLINE de verdade. Um printf de awk com o formato
#    quebrado no meio da string vira erro de sintaxe do awk, em runtime,
#    num host remoto.
# 3. `${VAR}` do bash lido como interpolacao de JS -- ou some, ou quebra o
#    build.
#
# O que este script faz e' o que o CLAUDE.md manda: renderizar a saida e
# conferir, em vez de olhar o fonte.
#
# Uso:
#   scripts/check-served-scripts.sh          # roda os dois
#   scripts/check-served-scripts.sh install  # so' um
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WEB="$REPO/web"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FALHAS=0

cat > "$TMP/render.js" <<'JSEOF'
const fs = require('fs');
const src = fs.readFileSync(process.argv[2], 'utf8');
const ini = src.indexOf('return `#!/usr/bin/env bash');
const fim = src.lastIndexOf('`;');
if (ini < 0 || fim < 0) { console.error('template nao encontrado'); process.exit(1); }
const corpo = src.slice(ini + 'return `'.length, fim);
// Descobre sozinho o que o template interpola, pra nao quebrar quando
// alguem adiciona uma variavel nova.
const nomes = [...new Set([...corpo.matchAll(/\$\{([A-Za-z_][A-Za-z0-9_]*)\}/g)].map(m => m[1]))];
try {
  const out = new Function(...nomes, 'return `' + corpo + '`;')(...nomes.map(n => 'X_' + n));
  fs.writeFileSync(process.argv[3], out);
  console.log(out.split('\n').length + ' linhas');
} catch (e) { console.error('ERRO: ' + e.message); process.exit(1); }
JSEOF

verifica() {
  local nome="$1" arquivo="$WEB/app/$1/route.ts" saida="$TMP/$1.sh"
  echo "== $nome =="
  [[ -f "$arquivo" ]] || { echo "   arquivo nao existe: $arquivo"; FALHAS=$((FALHAS+1)); return; }

  # 1) backtick solto no template -- pega antes de o build reclamar, e com
  #    mensagem que diz ONDE.
  local achados
  achados=$(python3 - "$arquivo" <<'PYEOF'
import sys
src = open(sys.argv[1]).read()
try:
    i = src.index('return `#!/usr/bin/env bash'); j = src.rindex('`;')
except ValueError:
    raise SystemExit
corpo = src[i + len('return `'):j]
for n, linha in enumerate(corpo.split('\n'), 1):
    if '`' in linha:
        print(f"   linha {n}: {linha.strip()[:76]}")
PYEOF
)
  if [[ -n "$achados" ]]; then
    echo "   BACKTICK dentro do template (encerra o literal e quebra o build):"
    echo "$achados"
    FALHAS=$((FALHAS+1))
  fi

  # 2) renderiza como o JS renderiza
  local n
  if ! n=$(docker run --rm -v "$WEB:/w:ro" -v "$TMP:/o" node:22-alpine \
             node /o/render.js "/w/app/$nome/route.ts" "/o/$nome.sh" 2>&1); then
    echo "   NAO RENDERIZA: $n"
    FALHAS=$((FALHAS+1)); return
  fi
  echo "   renderiza: $n"

  # 3) o bash resultante e' valido?
  if ! bash -n "$saida" 2>"$TMP/err"; then
    echo "   BASH INVALIDO:"; sed 's/^/     /' "$TMP/err"
    FALHAS=$((FALHAS+1)); return
  fi
  echo "   bash -n: ok"

  # 4) sobrou marca de escape mal resolvido? `${'$'}` que nao virou ${
  if grep -n "\${'\\\$'}" "$saida" >/dev/null 2>&1; then
    echo "   ESCAPE NAO RESOLVIDO: sobrou \${'\$'} literal na saida"
    FALHAS=$((FALHAS+1))
  fi
}

if [[ $# -gt 0 ]]; then verifica "$1"; else verifica init; verifica install; fi

echo
if [[ $FALHAS -eq 0 ]]; then echo "tudo ok"; else echo "$FALHAS verificacao(oes) falhou(ram)"; fi
exit $FALHAS
