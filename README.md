# Canal de Abertura — Robô para MetaTrader 5

Robô (Expert Advisor) em MQL5 que opera o **rompimento confirmado do canal de abertura**: o rompimento do canal 1 arma um segundo canal do mesmo tamanho, e só o rompimento desse **canal 2** dispara a entrada, com alvo em um **canal 3**. Faz **uma única operação por dia**.

> ⚠️ **Aviso:** este é um MVP (primeira versão). Teste bastante no Strategy Tester e em conta demo antes de usar em conta real. Resultados passados não garantem resultados futuros, e nenhum robô elimina o risco de perda.

---

## Como funciona

1. No horário de abertura (padrão **01:00 da plataforma**, que corresponde a 19h em Brasília), o robô conta as **4 primeiras velas**.
2. Ele marca a **máxima** e a **mínima** dessas velas. Esse é o **canal 1**.
3. Quando o preço **rompe o canal 1** (para cima ou para baixo), o robô **arma o canal 2**: um canal do mesmo tamanho do canal 1, projetado a partir do lado rompido. Isso ainda **não é uma entrada**.
4. A **entrada** só acontece quando o preço **rompe o canal 2**, na mesma direção:
   - **Rompeu o canal 2 para cima → COMPRA**
   - **Rompeu o canal 2 para baixo → VENDA**
5. Se, antes do canal 2 romper, o preço voltar e romper o canal 1 pelo **lado oposto**, o robô **troca de lado**: descarta o canal 2 antigo e arma um novo canal 2 no novo lado.
6. O **alvo** fica no fim do **canal 3**, que tem o mesmo tamanho do canal 1 (x multiplicador configurável) e é projetado a partir do canal 2 confirmado.
7. O **stop** fica, por padrão, no lado oposto do canal 1.
8. Depois de entrar, o robô não opera mais naquele dia.

### Exemplo

```
  130 ┄┄┄┄┄┄┄┄┄┄┄┄┄  ← ALVO (fim do canal 3)
      ┆  canal 3  ┆
  120 ━━━━━━━━━━━━━  ← rompeu aqui → COMPRA (entrada)
      ┃  canal 2  ┃     (armado ao romper o canal 1)
  110 ━━━━━━━━━━━━━  ← canal 1 rompeu aqui → arma o canal 2 (ainda não entra)
      ┃  canal 1  ┃     (4 primeiras velas)
  100 ━━━━━━━━━━━━━  ← STOP
```

Canal 1 de 10 pontos (100 a 110). Rompeu 110 → arma o canal 2 (110 a 120). Rompeu 120 → o robô compra, com alvo em 130 (fim do canal 3) e stop em 100 (lado oposto do canal 1).

---

## Instalação

1. No MetaTrader 5: **Arquivo → Abrir pasta de dados**.
2. Entre em `MQL5` → `Experts` e copie o arquivo `CanalAbertura.mq5` para lá.
3. Abra o arquivo no **MetaEditor** e aperte **F7** para compilar.
4. No MT5, atualize a janela **Navegador**. O robô vai aparecer em *Expert Advisors*.
5. Arraste o robô para o gráfico do ativo, ajuste os parâmetros e deixe o botão **Algo Trading** ligado.

---

## Parâmetros

Todos os horários são no **horário da plataforma** (servidor da corretora), e não no horário de Brasília.

### Horários
| Parâmetro | Padrão | O que faz |
|---|---|---|
| MODO TESTE: começar o canal agora | false | Começa o canal na hora em que você liga o robô (veja abaixo) |
| Hora / Minuto de início do canal | 01:00 | Quando começam as velas do canal |
| Tempo gráfico das velas do canal | M15 | Tamanho de cada vela do canal (independe do gráfico aberto) |
| Quantidade de velas do canal | 4 | Quantas velas formam o canal 1 |
| Hora / Minuto limite para entrar | 23:00 | Se não houver rompimento até esse horário, o robô não opera no dia |
| Zerar posição em horário definido | true | Fecha a posição no horário abaixo |
| Hora / Minuto para zerar | 23:50 | Horário de fechamento forçado |

### Entrada
| Parâmetro | Padrão | O que faz |
|---|---|---|
| Tipo de rompimento | Preço rompe | Vale para o rompimento do canal 1 (arma o canal 2) e do canal 2 (entra). **Preço rompe:** confirma assim que o preço passa do canal. **Vela fecha fora:** espera uma vela fechar fora do canal |
| Folga além do canal | 0 | Pontos a mais além do canal para confirmar o rompimento |
| Permitir compras / vendas | true / true | Desliga um dos lados. Se o canal 1 romper para o lado desligado, o robô não arma o canal 2 desse lado (mas continua aguardando o outro lado) |
| Tamanho mínimo / máximo do canal | 0 / 0 | Ignora o dia se o canal for pequeno ou grande demais (0 = sem filtro) |

### Alvo
| Parâmetro | Padrão | O que faz |
|---|---|---|
| Usar alvo no fim do canal 3 | true | Liga ou desliga o take profit |
| Tamanho do canal 3 | 1.0 | Múltiplo do canal 1 (1.5 = alvo 50% mais longe). O canal 2 é sempre do mesmo tamanho do canal 1 |

### Stop
| Parâmetro | Padrão | O que faz |
|---|---|---|
| Tipo de stop | Lado oposto | **Lado oposto do canal**, **meio do canal**, **pontos fixos** ou **tamanho do canal** a partir da entrada |
| Stop em pontos | 200 | Usado no modo de pontos fixos |
| Multiplicador | 1.0 | Usado no modo de tamanho do canal |

### Breakeven
| Parâmetro | Padrão | O que faz |
|---|---|---|
| Usar breakeven | false | Move o stop para o preço de entrada |
| Aciona ao percorrer X% | 50 | Percentual do caminho até o alvo |
| Stop vai para entrada + X pontos | 0 | Garante alguns pontos de lucro |

### Gestão
| Parâmetro | Padrão | O que faz |
|---|---|---|
| Lote / contratos | 1.0 | Quantidade operada |
| Número mágico | 20260928 | Identifica as ordens do robô. Use números diferentes se rodar em mais de um gráfico |
| Desvio máximo de preço | 10 | Deslizamento aceito na execução (pontos) |
| Desenhar canais no gráfico | true | Mostra os canais: azul = canal 1; verde/vermelho pontilhado = projeções possíveis do canal 2 (antes de armar); verde/vermelho preenchido = canal 2 armado; verde/vermelho pontilhado além dele = canal 3 (alvo) |

---

## Como testar

### No Strategy Tester (backtest)
1. Aperte **Ctrl+R** no MT5.
2. Escolha **CanalAbertura**, o ativo e o período.
3. Em modelagem, use **"Cada tick baseado em ticks reais"**.
4. Ligue o **modo visual** para ver os canais e as entradas acontecendo.

### Em conta demo, sem esperar a abertura (modo teste)
1. Coloque **MODO TESTE: começar o canal agora = true**.
2. Coloque **Tempo gráfico das velas do canal = M1**. Assim o canal fica pronto em 4 minutos.
3. Ligue o robô no gráfico e acompanhe o painel no canto superior esquerdo.

No modo teste, o horário limite de entrada é ignorado e você pode remover e religar o robô para testar de novo no mesmo dia. A partir do dia seguinte, ele volta ao horário normal. **Lembre de voltar para `false` depois dos testes.**

---

## Painel no gráfico

O canto superior esquerdo mostra:
- O dia e o horário de início do canal
- A máxima, a mínima e o tamanho do canal 1
- O canal 2, quando já estiver armado (e de que lado)
- O status: aguardando canal 1, aguardando rompimento do canal 1, aguardando rompimento do canal 2, compra ou venda executada, dia encerrado e o motivo

Os detalhes de cada ação ficam na aba **Experts** (caixa de ferramentas do MT5).

---

## Cuidados importantes

- **Uma operação por dia de verdade:** o robô confere o histórico, então mesmo que você reinicie o robô ou o MT5, ele não entra duas vezes no mesmo dia.
- **Conta netting (padrão da B3):** não opere manualmente o mesmo ativo com o robô ligado, porque as posições se misturam.
- **Ligar o robô com o dia em andamento:** se o preço já estiver além do canal 2 (não só do canal 1), ele entra imediatamente, a não ser que o preço já tenha passado do alvo (canal 3).
- **Horário do servidor:** se a corretora mudar o fuso do servidor (horário de verão em outros países), ajuste o horário de início para continuar batendo com 19h de Brasília.
- **Lote fixo:** ainda não há cálculo de lote por % do capital nem limite de perda diária em dinheiro.

---

## Arquivos

| Arquivo | Descrição |
|---|---|
| `CanalAbertura.mq5` | Código-fonte do robô |
| `README.md` | Este guia de uso |
| `AGENTS.md` | Documentação técnica detalhada para quem for alterar o código |