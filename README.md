# Folha da Casa

Calculadora de folha de pagamento para funcionárias domésticas (empregada, babá, cuidadora etc.), registradas no eSocial ou sem registro.

Você cadastra as regras uma vez e o app calcula tudo sozinho a cada mês.

## O que o app calcula

- **Dias de trabalho do mês**, a partir da escala semanal de cada funcionária, descontando os feriados.
- **Vale-transporte** (Lei 7.418/85, Decreto 10.854/2021 e LC 150/2015, art. 19): devido só nos dias de deslocamento efetivo. No modo adiantado (padrão), cada folha entrega o VT do mês seguinte (a folha de outubro paga novembro) e faz o **acerto do mês atual**: dias usados − dias já adiantados. Faltas, férias e dias após o desligamento viram desconto; dias extras viram complemento. No mês do desligamento não há adiantamento e o VT não usado é devolvido. A funcionária paga no máximo 6% do salário básico do mês, limitado ao VT que usou no mês; o resto é custo do empregador.
- **INSS** pela tabela progressiva (só para registradas).
- **Faltas**, marcadas direto no calendário do mês: falta sem justificativa desconta o dia (1/30 do salário) e o **DSR** da semana; falta justificada (atestado) não desconta salário, só o vale-transporte do dia.
- **DSR (descanso semanal remunerado)**: cada semana de segunda a domingo com falta sem justificativa perde o domingo e os feriados de folga daquela semana. Pode ser desligado em **Regras gerais**.
- **Admissão e desligamento**: no mês de entrada e no de saída o salário é proporcional aos dias de vínculo (1/30 por dia), e a escala, o vale-transporte e o 13º respeitam essas datas. No mês do desligamento entram também o 13º proporcional e as férias proporcionais com 1/3. Aviso prévio e multa do FGTS não são calculados.
- **Dias extras trabalhados** (fora da escala, como um sábado): cada dia é pago a 1/30 do salário mais o adicional informado (padrão 50%), entra na base do INSS e soma a passagem do dia no vale-transporte.
- **Horas extras** com adicional configurável (padrão 50%).
- **Guia DAE do eSocial**: INSS da empregada, INSS patronal 8%, GILRAT 0,8%, FGTS 8% e indenização compensatória 3,2% (só para registradas).
- **13º salário** proporcional aos meses trabalhados: 1ª parcela em novembro (até 30/11) e 2ª em dezembro (até 20/12).
- **Férias** com 1/3, data de vencimento do período e quanto guardar por mês para 13º e férias.
- **Recibo em PDF** no formato de holerite, em duas vias (empregador e funcionária), com proventos e descontos, valor por extenso e linhas de assinatura. Também dá para copiar o recibo em texto.

## Acesso da funcionária e assinatura (ZapSign)

- Em **Cadastros**, cada funcionária com CPF ganha o bloco **Acesso da funcionária ao app**: o empregador cria a senha (o app sugere uma) e passa para ela. Também dá para trocar a senha ou bloquear o acesso.
- A funcionária abre o app, escolhe **Sou funcionária** e entra com CPF e senha. Ela vê **todos os recibos que ainda não assinou** e, depois de assinar, cada recibo continua disponível por **15 dias**. Ela não vê mais nada.
- Ao **Salvar folha**, uma janela avisa que o recibo ficará disponível para ela. O recibo (com os recibos de adiantamento do mês) vai para assinatura na ZapSign, com **selfie**.
- O empregador também assina, de forma simplificada (**visto**: assinatura na tela, sem selfie). O visto não muda o prazo de disponibilidade para a funcionária. O PDF final da ZapSign fica pronto depois das duas assinaturas.
- O status aparece na folha: a assinatura dela (aguardando, assinado ou recusado), o seu visto (com o botão **Dar visto**) e o PDF assinado. **Editar folha** cancela as assinaturas pendentes daquele mês.
- O app não cria nem altera webhooks na ZapSign: ele consulta o status pela API. Os documentos ficam na pasta `/Folha da Casa/` e têm `external_id` começando com `folhadacasa:`.

- Em **Cadastros**, cada funcionária com acesso tem **Documentos para assinatura**: escolha o tipo (termo de rescisão, aviso prévio, pedido de demissão, recibo de férias, contrato ou outro), confira o título e anexe o PDF (até 3 MB). Ele vai para a ZapSign com as mesmas regras do recibo (selfie dela e visto do empregador) e fica disponível para ela até assinar e por mais 15 dias.
- **Documentos de rescisão** (termo de rescisão, aviso prévio e pedido de demissão) só podem ser assinados depois que todos os recibos dela estiverem assinados. A regra é aplicada no servidor: o link de assinatura só é liberado quando não há recibo pendente.
- Um documento ainda não assinado pode ter o envio cancelado. **Editar folha** nunca cancela documentos, só os recibos do mês.

- A aba **Assinaturas** (só com a nuvem ligada) reúne todos os recibos e documentos enviados, de todas as funcionárias e meses. Mostra quantos aguardam o seu visto, quantos aguardam a funcionária, os concluídos e os recusados; filtra por funcionária e tipo; e em cada item tem **Dar visto**, **Ver PDF** (original ou assinado), os valores do recibo e o cancelamento de documentos pendentes. Os itens assinados ficam guardados aqui mesmo depois que somem da área da funcionária. A aba mostra um contador de vistos pendentes, e a lista se atualiza ao voltar da ZapSign.

### Configuração

1. No Supabase, rode `supabase/funcionarias.sql` no SQL Editor (depois do `schema.sql`).
2. Na Vercel, em **Settings → Environment Variables**, cadastre:
   - `ZAPSIGN_TOKEN`: token de API da ZapSign.
   - `SUPABASE_SECRET_KEY`: chave secreta (service_role) do Supabase.
   - Opcional: `ZAPSIGN_SANDBOX=1` para testar no ambiente de testes da ZapSign (com token de sandbox).
3. Faça um novo deploy para as variáveis valerem.

## Rotina: tarefas, ponto e recados

Requer o script `supabase/rotina.sql` (rode no SQL Editor depois do `funcionarias.sql`).

- **Tarefas**: na aba **Rotina → Tarefas**, o empregador cria tarefas para um dia específico, para todos os dias de trabalho da funcionária ou para dias da semana escolhidos. Ela vê as tarefas de hoje na aba **Tarefas** da área dela e marca as concluídas; o empregador vê o que foi feito e a que horas.
- **Conclusão com hora e foto** (requer `supabase/tarefas_fotos.sql`): para concluir, ela informa a hora em que terminou e tira uma foto (reduzida no celular antes do envio). A foto vai para uma pasta privada do Supabase Storage pelo servidor do app (`api/rotina.js`), que confere a sessão; sem foto não é possível concluir. Ela pode desfazer no mesmo dia o que ainda não foi aprovado.
- **Atrasos**: tarefa que não foi feita num dia em que ela trabalhou (tem ponto) fica atrasada, em vermelho, por até 7 dias. Tarefa repetida não duplica: aparece uma vez, marcada como atrasada desde o primeiro dia sem fazer; concluí-la resolve o atraso.
- **Painel** (Rotina → Painel): percentual de tarefas concluídas no período, progresso de hoje por funcionária, gráfico por dia, fotos para **Aprovar** ou **Pedir para refazer** (com comentário, a tarefa volta para ela), tarefas atrasadas (desde quando e quantos dias), pendentes de hoje e as tarefas que mais ficam sem fazer.
- **Ponto**: na área dela, a aba **Ponto** mostra um relógio e o botão do próximo registro (entrada, saída para o almoço, volta do almoço, saída). O horário é o do servidor; o IP e, se o celular permitir, o local também são gravados. Ela não altera nem apaga registros. Em **Rotina → Ponto**, o empregador vê os registros do mês, as horas de cada dia e o total, pode incluir ajustes (com motivo) e desconsiderar registros (com motivo, sem apagar). Atende ao registro de horário exigido pela LC 150/2015, art. 12.
- **Recados**: ela envia recados (recado, atraso ou falta, falta algo em casa, outro) e vê as respostas. Em **Rotina → Recados**, o empregador lê e responde; a aba mostra quantos recados novos chegaram.

## Recibos de vários meses

Na aba **Recibos**, escolha o período (de/até, até 36 meses) e as funcionárias. A prévia mostra cada mês com o total recebido e se a folha está salva. **Gerar PDF** cria um único arquivo com uma página de resumo (opcional), os recibos de cada mês em uma ou duas vias e os recibos de adiantamento (opcional). Meses com a folha salva usam os valores congelados; os demais usam os cadastros e regras atuais.

## Salvar a folha

Depois de conferir o mês, clique em **Salvar folha**. Os valores ficam congelados (mesmo que você mude salário ou regras depois) e os campos do mês ficam travados. Para mexer, clique em **Editar folha**: a folha volta a usar os cadastros e regras atuais.

## Lançamentos avulsos

Cada funcionária tem uma lista livre de proventos e descontos do mês (gratificação, adiantamento, empréstimo etc.). A descrição digitada sai no recibo. Proventos entram na base do INSS; descontos saem do líquido.

## Adiantamentos

Em cada funcionária, **+ Adiantamento** registra um valor pago antes do fechamento (data, valor e observação). Cada adiantamento gera um **recibo próprio em PDF**, em duas vias na mesma folha A4 (que também sai junto, nas páginas finais, quando você baixa os recibos da folha), e é abatido automaticamente do salário líquido na folha do mês. Adiantamentos não alteram a base do INSS.

## Funcionárias sem registro

Para quem não é registrada, o app não calcula INSS, FGTS nem guia DAE. Salário, vale-transporte, 13º e férias com 1/3 são calculados normalmente.

## Feriados

Todos os feriados nacionais entram automaticamente, inclusive os móveis (calculados a partir da Páscoa). O estado padrão é o Distrito Federal, e dá para trocar para qualquer um dos 27 estados, com os feriados da capital. Carnaval e Corpus Christi vêm ligados; Quarta-feira de Cinzas e as vésperas de Natal e Ano-Novo podem ser ligadas em **Regras gerais**.

## Cadastros

Na aba **Cadastros** ficam o nome e o CPF do empregador e os dados de cada funcionária, incluindo CPF, que preenchem o recibo. O CPF é formatado e conferido automaticamente.

## Onde os dados ficam

Com a nuvem configurada, cada pessoa entra com e-mail e senha e os dados ficam no Supabase, sincronizados em tempo real entre computador e celular. Cada casa pode ter várias pessoas com acesso (aba **Cadastros → Conta e acesso**).

Sem a nuvem configurada (`config.js` em branco), o app guarda os dados no navegador. Ao entrar na nuvem pela primeira vez, ele oferece enviar esses dados.

**Exportar backup** e **Importar backup** (em **Regras gerais**) continuam disponíveis para guardar uma cópia em arquivo.

### Configurar a nuvem (Supabase)

1. Crie um projeto gratuito em [supabase.com](https://supabase.com).
2. Em **SQL Editor → New query**, cole o conteúdo de `supabase/schema.sql` e clique em **Run**.
3. Em **Authentication → URL Configuration**, coloque o endereço do app em **Site URL**.
4. Em **Project Settings → API**, copie a **Project URL** e a chave **anon public** para o arquivo `config.js`.

A chave *anon* é pública por natureza; quem protege os dados são as regras do banco (Row Level Security), que só deixam cada pessoa ver as casas às quais tem acesso.

## Como rodar

É uma página estática, sem build: abra `index.html` no navegador ou publique a pasta em qualquer hospedagem estática (Vercel, GitHub Pages, Netlify).

## Aviso

Os valores padrão são os de 2026 (salário mínimo de R$ 1.621 e tabela do INSS). Atualize em **Regras gerais** quando sair a tabela do ano seguinte. O app é uma calculadora de apoio e não substitui o eSocial.
