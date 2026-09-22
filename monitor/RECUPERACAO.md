# Recuperação de desastre — procedimento genérico

> Este documento é intencionalmente vago sobre onde as coisas ficam
> (hosts, buckets, portas, IPs). Isso é proposital: é um documento
> público (git), e detalhe de infraestrutura real só ajuda quem não
> deveria ter acesso. O procedimento completo e específico vive fora do
> git, num pacote local cifrado (ver "Onde está o resto" no fim).

## Ideia geral

Existe um backup diário, feito com `restic`, que cobre:

- arquivos de configuração dos hosts da frota (não dados de aplicação);
- dump lógico do banco de documentos (Mongo);
- dump lógico do banco relacional (MySQL/MariaDB);
- cópia dos arquivos de cada bucket de armazenamento de objetos (S3) em
  uso.

O repositório restic fica num provedor de armazenamento de objetos
diferente do usado em produção — nunca o mesmo bucket que guarda o dado
sendo copiado, pra um incidente num provedor não levar os dois.

A chave que decifra esse repositório **não está em lugar nenhum online**.
Existe uma cópia local, cifrada com senha simétrica (`gpg -c`), mantida
fora da rede de produção. Sem essa cópia, o backup existe mas é
irrecuperável — é o modelo de ameaça aceito de propósito: quem comprometer
só a infraestrutura online não ganha acesso ao backup.

## Como a recuperação funciona, em alto nível

1. Decifrar o pacote local (`gpg -d` com a senha memorizada), obtendo um
   diretório pronto pra rodar em container — não depende de nenhum host
   específico estar de pé, só de `docker` instalado em qualquer máquina.
2. Listar os snapshots disponíveis e conferir qual tem os dados íntegros
   (o mais recente, normalmente — mas sempre inspecionar antes de confiar,
   um snapshot pode ter uma fonte vazia por falha silenciosa upstream).
3. Restaurar, de forma seletiva, só o que for necessário, pra um destino
   novo e descartável — nunca por cima de produção diretamente.
4. Para os bancos: subir um container novo, vazio, com credenciais novas,
   e importar o dump restaurado — não se restaura a instância inteira do
   banco, só os dados.
5. Para os arquivos de objeto: sincronizar de volta pro bucket de destino
   com uma ferramenta de sync (tipo `aws s3 sync` ou `rclone`), depois de
   conferir a contagem/tamanho batendo com o esperado.

## Cuidados que já morderam esta operação e vale repetir

- **Timestamps do restic saem em UTC**, não no fuso local. Já causou
  confusão sobre "qual foi o backup de ontem à noite" mais de uma vez.
- Depois de qualquer restore, a posse dos arquivos restaurados costuma
  ficar de um usuário diferente do seu (o processo de restore roda como
  root dentro do container) — é preciso devolver a posse antes de mexer
  nos arquivos como usuário normal.
- Nunca usar rastreamento de shell (`bash -x`/`set -x`) em nada que
  manipule as credenciais desse processo — isso ecoa segredos em texto
  puro pra qualquer log ou terminal compartilhado. Aconteceu nesta
  operação, mais de uma vez, e forçou rotação de credenciais depois.
- Um snapshot pode existir e "passar" no backup sem conter dado real
  (uma falha de permissão silenciosa numa das fontes já produziu um dump
  vazio que só foi percebido meses depois, numa inspeção manual). Sempre
  inspecionar o conteúdo antes de considerar um snapshot confiável pra
  uma recuperação real.
- Testar a recuperação de tempos em tempos, não só quando o desastre já
  aconteceu. Um backup nunca restaurado é uma hipótese, não uma garantia.

## Onde está o resto

O procedimento completo — comandos exatos, nomes de provedor, credenciais
de acesso ao repositório restic, exemplos já testados com números reais —
fica só no pacote local cifrado descrito acima, mantido fora deste
repositório e fora de qualquer host da frota. Quem tem acesso a essa
senha sabe onde encontrar o pacote.
