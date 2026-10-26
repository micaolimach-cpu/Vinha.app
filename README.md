# Vinha — gestão de visitas

Versão para GitHub Pages + Supabase. As telas estão em `docs/`; o servidor Python original continua como referência, mas não é usado nesta implantação.

## Publicação

1. Habilitar GitHub Pages: branch `main`, pasta `/docs`. No GitHub Free, o repositório precisa ser público.
2. No Supabase Auth, definir Site URL e Redirect URL como `https://micaolimach-cpu.github.io/Vinha.app/`.
3. Configurar SMTP próprio no Supabase antes de liberar os links de acesso para a equipe. O SMTP padrão não atende vendedores externos à organização do Supabase.
4. Entrar com o e-mail do gestor, importar o XLSX e vincular cada e-mail à carteira correta em Equipe.

A interface contém somente a chave **publicável** do Supabase. Dados de clientes, e-mails dos vendedores e credenciais não devem ser adicionados ao repositório. O cadastro dos vendedores fica exclusivamente no banco.

## Arquitetura e permissões

- `docs/`: aplicativo estático com caminhos relativos compatíveis com Pages.
- `web/src/backend.js`: autenticação Supabase e conexão com a API. O SDK é fixado no `package-lock.json`.
- `docs/import-worker.js`: leitura do Excel em worker, com limite de arquivo, expansão ZIP, linhas e tempo.
- `supabase/functions/vinha-api/index.ts`: valida o token com Supabase Auth antes de chamar o banco. `verify_jwt=false` permite o endpoint público de configuração; todos os endpoints de dados exigem validação explícita do usuário.
- `db/schema.sql`: definição consolidada do banco. As tabelas estão em schema privado com RLS e sem concessão de acesso a `anon`/`authenticated`. A função transacional é SECURITY INVOKER e executável apenas pelo servidor. O servidor verifica a sessão, e-mail confirmado, cadastro ativo e carteira em toda operação.
- Escritas serializadas por lock transacional preservam os limites de 20 ON ou 10 OFF, inclusive em dias mistos. Check-in/out usa horário do banco. A revogação bloqueia o acesso imediatamente e sessões antigas não voltam a valer quando o cadastro é reativado. Sessões do app têm limite de oito horas.

## Desenvolvimento e testes

```sh
npm ci --prefix web
web/node_modules/.bin/esbuild web/src/backend.js --bundle --minify --format=iife --outfile=docs/backend.js
node --test tests/import-parser.test.cjs
```

`db/test.sql` verifica as regras contra PostgreSQL em uma transação com rollback, usando apenas dados fictícios. Nenhum token de login é emitido. O schema já aplicado é controlado pelo histórico de migrations no Supabase; `db/schema.sql` é referência consolidada e não deve ser reaplicado sobre um banco existente.

## Limites e validação pendente

- Envio real de e-mail e acesso final no endereço Pages devem ser testados depois da configuração SMTP e de redirects.
- O roteiro é ordenado por município/bairro; o Maps calcula o trajeto ao destino. Não há otimização viária de múltiplas paradas.
- Feriados nacionais fixos e fins de semana são considerados; feriados móveis/locais precisam de revisão.
- E-mails sem vínculo não veem carteiras. Não inferimos os responsáveis a partir do nome do e-mail.
- O plano Free do Supabase tem cotas e pode pausar por inatividade. Não houve contratação de plano pago.
