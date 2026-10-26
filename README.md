# Vinha — Gestão de visitas

Primeira versão de um aplicativo web para importar carteiras em XLSX, manter a agenda compartilhada e acompanhar visitas em campo. Interface em português, com área do gestor e área do vendedor adaptadas ao celular.

## O que já está implementado

- Importação XLSX em duas etapas: prévia e confirmação. Lê a planilha de clientes ou as abas dos roteiros. Reimportações preservam as edições do gestor e evitam duplicar clientes e visitas.
- Cadastro de clientes, endereço, frequência e preferência de atendimento.
- Agenda por data, com filtro de vendedor para o gestor.
- Check-in e check-out com horário do servidor. Localização opcional, somente quando o vendedor escolhe compartilhá-la. Não há rastreamento contínuo.
- Destaque do próximo cliente depois do check-out e botão de trajeto no Google Maps.
- Solicitações de nova data, frequência e dias/horários de atendimento. O gestor aprova, ajusta ou recusa; o vendedor não altera a agenda oficial diretamente.
- Acesso individual por link de e-mail, válido por 15 minutos e de uso único. Sessão de 8 horas. Revogação encerra as sessões do vendedor.
- Permissões no servidor: cada vendedor vê somente sua própria carteira.
- Limite diário de 20 ON, 10 OFF ou carga proporcional em dias mistos. A geração de novas visitas e a aprovação de pedidos respeitam a capacidade.
- Histórico técnico de alterações no banco de dados.

## Estado de entrega

O código e o banco de dados foram testados localmente. Os testes de autorização, capacidade, reimportação, check-in/check-out e aprovação passaram. A leitura do arquivo fornecido de aproximadamente 39 MB identificou 1.751 linhas, sendo 1.721 registros de pessoas jurídicas e 30 de pessoas físicas fora do escopo da agenda.

Não há uma publicação online confirmada nem serviço de e-mail configurado. O envio real de e-mails e a interface no navegador ainda precisam de validação no ambiente publicado. A prévia disponível nesta sessão não possuía a dependência de leitura de XLSX e não foi usada como prova de funcionamento visual.

Não há dados reais de clientes, banco de produção, senhas ou chaves neste pacote. A demonstração usa dados fictícios.

## Experimentar no computador

Requisitos: Python 3.12, acesso para instalar os pacotes de `requirements.txt`.

```bash
python -m venv .venv
```

Ative o ambiente virtual de acordo com seu sistema e execute:

```bash
python -m pip install -r requirements.txt
```

No Linux/macOS:

```bash
APP_ENV=demo DATA_DIR=./data-demo python app.py --port 3000
```

No PowerShell:

```powershell
$env:APP_ENV="demo"
$env:DATA_DIR="./data-demo"
python app.py --port 3000
```

Abra `http://localhost:3000`. Os botões **Ver como gestor** e **Ver como vendedor** existem somente no modo de demonstração. Não use `APP_ENV=demo` em produção.

## Colocar em produção

Administrador definido: **micael.oliveira@portoaporto.com.br**. O Blueprint já configura esse endereço em `ADMIN_EMAIL`. Isso define a conta inicial na implantação; não envia um e-mail nem ativa uma hospedagem por si só.

O arquivo `render.yaml` descreve uma implantação no Render, com servidor Python e disco persistente para o SQLite. A conexão com o serviço, a escolha do plano e a configuração de e-mail ainda devem ser feitas. Confira a oferta e os custos no provedor antes de criar recursos.

1. Publique este diretório em um repositório Git privado e conecte-o ao serviço de hospedagem. O arquivo `render.yaml` deve estar na raiz do repositório.
2. Crie a aplicação a partir do Blueprint e mantenha o disco persistente montado em `/var/data`. Não use armazenamento efêmero para os registros da equipe.
3. No painel de variáveis, configure `APP_ENV=production`, `DATA_DIR=/var/data`, `ADMIN_EMAIL` com o e-mail do gestor e `BASE_URL` com o endereço HTTPS final, sem barra no fim.
4. Configure `SMTP_HOST`, `SMTP_PORT` (587 com STARTTLS ou 465 com TLS), `SMTP_USER`, `SMTP_PASSWORD` e `MAIL_FROM`. Use o remetente autorizado no seu serviço de e-mail. Credenciais ficam no painel, nunca no código ou no navegador.
5. Abra o app, solicite o link para `ADMIN_EMAIL` e confirme o acesso recebido. Em seguida, importe a planilha.
6. Em **Equipe**, autorize o e-mail de cada vendedor. Compartilhe o endereço do app para que cada um solicite seu próprio link. O cadastro de um e-mail não envia convites automaticamente.
7. Valide em celulares reais: acesso por e-mail, permissão de localização, link para o Maps e check-in/check-out. Confirme também a entrega do e-mail antes de distribuir o app à equipe.

O `.env.example` é uma referência das variáveis; o programa não o carrega automaticamente. O servidor de desenvolvimento não substitui o Gunicorn em produção. O comando de produção está no Blueprint.

Referências de implantação e navegação:

- https://render.com/docs/blueprint-spec
- https://render.com/docs/disks
- https://developers.google.com/maps/documentation/urls/get-started

## Importação e rotina do gestor

1. Em **Importar**, escolha o XLSX. O nome de uma aba é opcional. Sem nome, o app prioriza abas com datas de roteiro; se não existirem, usa a base de clientes identificada.
2. Confira a prévia e confirme. As colunas de CNPJ, nome e vendedor são lidas pelos nomes usados nas planilhas deste projeto. Quando a aba é de um roteiro individual, o nome da aba identifica o vendedor.
3. Sem coluna de data, o arquivo cadastra os clientes, sem inventar uma agenda. Abra **Clientes → Agendar** para definir início, frequência e fim do período.
4. Visitas em feriados nacionais fixos, fins de semana, dias com excesso de capacidade, filiais e clientes inativos não são criadas automaticamente. O resultado lista os avisos. Feriados municipais, feriados móveis e horários comerciais precisam de revisão do gestor.
5. Clientes com código de estabelecimento diferente de `0001` são inicialmente tratados como filiais. O gestor pode marcar uma unidade como central/recebedora de visitas quando houver uma exceção confirmada.
6. O app não presume que um CNPJ sem situação cadastral no XLSX foi verificado na Receita. Importe situação cadastral quando disponível e revise o campo Ativo.
7. Frequência padrão: semanal para ON, mensal para OFF. Quando a planilha informa semanal/quinzenal/mensal, essa classificação é mantida. A coluna REFF não é usada como média mensal presumida.

Editar a frequência do cadastro não reescreve todas as visitas existentes. **Editar visita** muda a ocorrência selecionada e a frequência do cadastro. **Gerar próximas visitas** cria novas ocorrências no período escolhido, sem duplicar as que já existem. Datas não úteis e datas acima da capacidade são listadas para ajuste e não são movidas silenciosamente.

Na importação, dados já cadastrados ficam preservados. Para corrigir um cadastro existente, use **Editar**. O e-mail de vendedor é vinculado a uma carteira; os apoios devem ter carteira e agenda formalmente definidas, sem contas fictícias ou nomes “a designar” como se fossem executores reais.

## Fluxo do vendedor

1. Abrir **Meu dia** e conferir o próximo cliente.
2. Tocar **Trajeto no Maps** para abrir o endereço como destino. O Maps pode usar a localização atual ou pedir a origem.
3. Ao chegar, tocar **Check-in**. Opcionalmente compartilhar a localização daquele registro.
4. Ao terminar, tocar **Check-out**. O próximo cliente é destacado.
5. Se o cliente não puder atender, tocar **Não pode atender/Solicitar mudança**, informar a data, a frequência e os dias/horários. A visita só muda após aprovação do gestor.

O app usa a sequência por município, bairro e cliente. Não afirma calcular a menor distância ou o melhor próximo estabelecimento. O Google Maps calcula o trajeto para o destino escolhido; não foi integrada uma API de otimização de toda a rota. Endereços incompletos podem ser ambíguos e devem ser conferidos antes de navegar.

## Dados, manutenção e testes

O banco é `DATA_DIR/vinha.sqlite3`, com SQLite WAL. Faça cópias de segurança consistentes com a API de backup do SQLite. Não copie apenas o arquivo principal enquanto houver operações em andamento. O script `backup.py` fornece esse procedimento.

```bash
python -m unittest discover -s tests -v
node --check static/app.js
```

Os testes usam um banco temporário e não enviam e-mails. Os links SMTP e o navegador devem ser testados em homologação antes da distribuição.

Esta versão não contém notificações por WhatsApp, acompanhamento de localização em segundo plano, otimização viária de múltiplas paradas nem envio de pedidos de mudança por e-mail: os pedidos ficam no painel compartilhado e atualizam automaticamente quando aberto. As alterações de canal/vendedor ainda devem ser tratadas com uma carteira revisada, evitando transferir visitas e exceder capacidade silenciosamente.
