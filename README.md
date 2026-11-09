# Folha da Casa

Calculadora de folha de pagamento para funcionárias domésticas (empregada, babá, cuidadora etc.), registradas no eSocial ou sem registro.

Você cadastra as regras uma vez e o app calcula tudo sozinho a cada mês.

## O que o app calcula

- **Dias de trabalho do mês**, a partir da escala semanal de cada funcionária, descontando os feriados.
- **Vale-transporte**: dias × viagens por dia × tarifa. Desconto de até 6% do salário; o resto é pago pelo empregador. Por padrão o VT é pago adiantado, com os dias do mês seguinte.
- **INSS** pela tabela progressiva (só para registradas).
- **Faltas**, marcadas direto no calendário do mês: falta sem justificativa desconta o dia (1/30 do salário) e o **DSR** da semana; falta justificada (atestado) não desconta salário, só o vale-transporte do dia.
- **DSR (descanso semanal remunerado)**: cada semana de segunda a domingo com falta sem justificativa perde o domingo e os feriados de folga daquela semana. Pode ser desligado em **Regras gerais**.
- **Admissão e desligamento**: no mês de entrada e no de saída o salário é proporcional aos dias de vínculo (1/30 por dia), e a escala, o vale-transporte e o 13º respeitam essas datas. No mês do desligamento entram também o 13º proporcional e as férias proporcionais com 1/3. Aviso prévio e multa do FGTS não são calculados.
- **Horas extras** com adicional configurável (padrão 50%).
- **Guia DAE do eSocial**: INSS da empregada, INSS patronal 8%, GILRAT 0,8%, FGTS 8% e indenização compensatória 3,2% (só para registradas).
- **13º salário** proporcional aos meses trabalhados: 1ª parcela em novembro (até 30/11) e 2ª em dezembro (até 20/12).
- **Férias** com 1/3, data de vencimento do período e quanto guardar por mês para 13º e férias.
- **Recibo** de pagamento pronto para copiar.

## Funcionárias sem registro

Para quem não é registrada, o app não calcula INSS, FGTS nem guia DAE. Salário, vale-transporte, 13º e férias com 1/3 são calculados normalmente.

## Feriados

Todos os feriados nacionais entram automaticamente, inclusive os móveis (calculados a partir da Páscoa). O estado padrão é o Distrito Federal, e dá para trocar para qualquer um dos 27 estados, com os feriados da capital. Carnaval e Corpus Christi vêm ligados; Quarta-feira de Cinzas e as vésperas de Natal e Ano-Novo podem ser ligadas em **Regras gerais**.

## Onde os dados ficam

Fora do Claude, os dados ficam salvos no navegador (localStorage). Use **Regras gerais → Exportar backup** para guardar uma cópia e **Importar backup** para levar para outro aparelho.

## Como rodar

É uma página estática, sem build: abra `index.html` no navegador ou publique a pasta em qualquer hospedagem estática (Vercel, GitHub Pages, Netlify).

## Aviso

Os valores padrão são os de 2026 (salário mínimo de R$ 1.621 e tabela do INSS). Atualize em **Regras gerais** quando sair a tabela do ano seguinte. O app é uma calculadora de apoio e não substitui o eSocial.
