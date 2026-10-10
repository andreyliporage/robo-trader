# AGENTS.md — Robô "Canal de Abertura" (MQL5)

Este arquivo orienta qualquer agente de IA ou desenvolvedor que for ler, alterar ou estender os Expert Advisors deste repositório. Leia tudo antes de mudar o código: várias decisões aqui existem para proteger dinheiro real.

O repositório tem **dois robôs independentes** (arquivos únicos, sem código compartilhado):

| Arquivo | Robô | Seções |
|---|---|---|
| `CanalAbertura.mq5` | Canal de Abertura (canal 1 → canal 2 → canal 3) | 1 a 12 |
| `SetupCarCas.mq5` | Setup CAR/CAS/C1/TAKE1 automatizado | 13 |

As seções 8 (convenções), 9 (compilar e testar) e 12 (regras para agentes) valem para **os dois**. Não altere um robô ao trabalhar no outro.

---

## 1. Visão geral

| Item | Valor |
|---|---|
| Arquivo principal | `CanalAbertura.mq5` (arquivo único, sem includes próprios) |
| Linguagem / plataforma | MQL5 / MetaTrader 5 |
| Tipo | Expert Advisor (EA) |
| Versão | 2.10 (MVP) |
| Dependência | `#include <Trade/Trade.mqh>` (classe padrão `CTrade`) |
| Idioma | Código em inglês (nomes de variáveis/funções), comentários, mensagens e parâmetros em **português** |
| Codificação | **UTF-8 com BOM** (`EF BB BF`) — necessário para o MetaEditor exibir acentos corretamente |

### Estratégia em uma frase
A partir de um horário fixo (horário da plataforma), o robô marca a máxima e a mínima das **N primeiras velas** (canal 1); o primeiro rompimento do canal 1 **arma** um **canal 2 do mesmo tamanho**, projetado a partir do lado rompido, e esse lado fica **fixo para o resto do dia**; só o **fechamento de uma vela** rompendo o **canal 2** (sempre por fechamento, mesmo no modo toque) confirma a **entrada** na direção rompida; o alvo é o fim de um **canal 3**, cujo tamanho é a **soma do canal 1 + canal 2** (x multiplicador), projetado a partir do canal 2. **Uma única operação por dia.**

### Exemplo numérico
- 4 velas de M15 a partir de 01:00 → máxima 110, mínima 100 → canal 1 = 10 pontos.
- Preço rompe 110 → **arma o canal 2** (110 a 120, 10 pontos, mesmo tamanho do canal 1). Ainda não entra. O lado "cima" fica fixo para o resto do dia.
- Uma vela **fecha** rompendo 120 → **compra** (entrada). Canal 3 = soma do canal 1 (10) + canal 2 (10) = 20 pontos a partir de 120 → **alvo em 140**.
- Stop (padrão) no lado oposto do canal 1 → **100**.
- Se, antes do fechamento rompendo 120, o preço cair e voltar a cruzar 100 ou 110, isso **não muda nada**: o robô continua esperando o fechamento de vela rompendo 120 (ou o horário limite, o que vier primeiro).

---

## 2. Contexto do usuário (requisitos originais)

- O pregão que o usuário opera abre às **19h de Brasília**, que corresponde a **01:00 no horário da plataforma/servidor**. Todo horário no código é **horário do servidor** (`TimeCurrent()`), nunca horário local.
- Contar as **4 primeiras velas** da abertura e criar um canal com o tamanho delas (canal 1).
- O **primeiro** rompimento do canal 1 **arma** um **canal 2 do mesmo tamanho**, projetado a partir do lado rompido — isso **não** é a entrada, é só a confirmação de que o canal 2 existe. Esse lado fica **fixo para o resto do dia** (sem troca de lado).
- A **entrada** só acontece quando uma vela **fecha** rompendo o **canal 2**, na mesma direção (confirmado pelo usuário em 2026-09-29, corrigindo a interpretação anterior de que o canal 2 era o alvo; a exigência de fechamento de vela na entrada foi adicionada em 2026-10-05).
- O alvo passa a ser o fim de um **canal 3**, cujo tamanho é a **soma do canal 1 + canal 2** (x multiplicador) — revisado em 2026-10-05, antes era só o tamanho do canal 1 — projetado a partir do canal 2. O stop continua baseado no canal 1 (confirmado pelo usuário).
- **Apenas uma operação por dia.**
- Tudo que o usuário ainda não definiu virou **parâmetro ajustável** (tempo gráfico, tipo de entrada, stop, lote, horários).

### Pontos já confirmados pelo usuário (2026-09-29, revisado em 2026-10-05)
- O canal 2 é um **gatilho de confirmação de entrada**, não o alvo — o alvo é o canal 3.
- **Sem troca de lado:** o primeiro rompimento do canal 1 define o lado do dia de forma definitiva — se o preço depois cruzar para o lado oposto do canal 1, isso é ignorado (removido em 2026-10-05; antes disso o robô trocava de lado).
- **Entrada sempre por fechamento de vela:** o rompimento do canal 1 (arma o canal 2) pode ser detectado no toque ou no fechamento, conforme `InpEntryMode`; mas o rompimento do canal 2 (abre a operação) **sempre** exige o fechamento da vela, mesmo com `InpEntryMode` em modo toque (adicionado em 2026-10-05).
- **Canal 3 = soma do canal 1 + canal 2:** o tamanho do canal 3 (alvo) não é mais só o tamanho do canal 1 — é a soma dos tamanhos do canal 1 e do canal 2 (que são sempre iguais), multiplicada por `InpTargetMult` (revisado em 2026-10-05).
- O stop continua calculado em cima do **canal 1**, não do canal 2.

### Pontos ainda não confirmados pelo usuário
Não "resolva" esses pontos no código por conta própria; mantenha-os parametrizáveis e pergunte ao usuário:
1. Tempo gráfico real das velas (padrão provisório: M15).
2. Se o rompimento do canal 1 (que arma o canal 2) é no toque ou no fechamento de vela (a entrada no canal 2 já é sempre por fechamento).
3. Ativo e tamanho de lote.
4. Horário limite de entrada e horário de zeragem.

---

## 3. Fluxo de execução

Tudo acontece em `OnTick()`, que roda a cada tick nesta ordem:

```
OnTick
 ├─ Novo dia do servidor?  → ResetDay(hoje)
 ├─ ManagePosition(now)    → zeragem por horário + breakeven (sempre roda, mesmo após a operação do dia)
 ├─ se !g_tradeDone && !g_dayDone:
 │    ├─ se !g_rangeReady → BuildRange(now)     (monta o canal 1 quando as N velas fecham)
 │    └─ se g_rangeReady && !g_dayDone → CheckBreakout(now)
 │           ├─ primeiro rompimento do canal 1 (toque ou fechamento, via InpEntryMode) → ArmChannel2(dir)  (lado fixo no dia; ainda não entra)
 │           └─ se canal 2 armado e uma vela FECHA rompendo-o → OpenTrade(dir)
 └─ UpdateComment()        → painel de texto no gráfico
```

### Máquina de estados diária

```
[Aguardando canal 1] --N velas fechadas--> [Canal 1 formado] --primeiro rompimento do canal 1--> [Canal 2 armado]
        |                                       |    |                                                 |
        |                                       |    +--filtro de tamanho falhou--> [Fim]               +--vela fecha rompendo o canal 2--> [Operação feita]
        |                                       |    +--lado desativado--> [Dia encerrado]              +--horário limite / alvo já ultrapassado / stop inválido / 3 falhas--> [Dia encerrado]
        |                                       +--horário limite--> [Dia encerrado]
        +--(virada do dia do servidor)--> ResetDay reinicia tudo
```

Flags que representam esses estados:

| Variável | Significado |
|---|---|
| `g_rangeReady` | Canal 1 já foi calculado para o dia |
| `g_c1BreakDir` | Lado armado do canal 1 (`0` = nenhum rompimento ainda, `+1`/`-1` = canal 2 armado nesse lado). Uma vez definido, fica **fixo pelo resto do dia** |
| `g_tradeDone` | O robô já **entrou** hoje (não entra de novo) |
| `g_dayDone` | O dia foi encerrado sem operar (ou por falha); não procura mais entradas |

---

## 4. Referência das funções

| Função | Responsabilidade |
|---|---|
| `DayStart(t)` | Retorna 00:00 do dia de `t` (horário do servidor). |
| `AtTime(day, h, m)` | Retorna `day + h:m`. |
| `IsTestDay()` | `true` se o modo teste (`InpStartNow`) está ligado **e** o dia atual é o dia em que o robô foi ligado. |
| `NormalizePrice(p)` | Arredonda o preço ao **tick size** do ativo (essencial na B3: WIN anda de 5 em 5, WDO de 0,5 em 0,5). Nunca envie preço sem passar por aqui. |
| `NormalizeLots(l)` | Ajusta o lote ao passo/mínimo/máximo do ativo. |
| `CurrentPrice()` | Preço usado para detectar o rompimento do canal 1 no modo toque: `last` (B3) ou `bid` (forex, onde `last` = 0). Não é usado na etapa 2 (canal 2), que é sempre por fechamento de vela. |
| `GetPositionTicket()` | Ticket da posição do robô, filtrando por **ativo + número mágico**. Retorna 0 se não houver. |
| `TradedSince(from, to)` | Procura no histórico um negócio de **entrada** (`DEAL_ENTRY_IN`) deste robô no intervalo. É o que garante 1 operação por dia mesmo se o robô/MT5 reiniciar. |
| `DrawRect(...)` / `DrawChannels()` | Desenha o canal 1 (azul, preenchido). Antes do canal 2 armar: as duas projeções possíveis do canal 2 (verde acima, vermelho abaixo, pontilhados). Depois de armar: o canal 2 armado preenchido no lado correspondente e o canal 3 (alvo) pontilhado além dele. Objetos com prefixo `CA_` + data. |
| `ResetDay(day)` | Zera o estado do dia (inclusive `g_c1BreakDir`/`g_c2High`/`g_c2Low`); define `g_rangeStart`; consulta o histórico para `g_tradeDone`. |
| `BuildRange(now)` | Copia as velas a partir de `g_rangeStart`, espera a N-ésima vela **fechar**, calcula máx/mín, aplica filtros de tamanho e desenha. |
| `ArmChannel2(dir)` | Define o lado armado (`g_c1BreakDir`), fixo pelo resto do dia, e calcula os limites do canal 2 (`g_c2High`/`g_c2Low`) a partir do canal 1 e do lado rompido. Não abre operação. |
| `CheckBreakout(now)` | Verifica horário limite e posição aberta. Etapa 1 (só se `g_c1BreakDir == 0`): primeiro rompimento do canal 1 (via `InpEntryMode`: toque ou fechamento) arma o canal 2 via `ArmChannel2`. Etapa 2: se o canal 2 já está armado, verifica se uma vela nova de `InpRangeTF` **fechou** rompendo o canal 2 (sempre por fechamento, ignora `InpEntryMode`) e, se sim, chama `OpenTrade`. |
| `OpenTrade(dir)` | Calcula alvo (fim do canal 3 = soma do canal 1 + canal 2, x `InpTargetMult`, projetado do canal 2) e stop (baseado no canal 1), valida, envia ordem a mercado. `dir = +1` compra, `-1` venda. |
| `ManagePosition(now)` | Zera a posição no horário configurado e aplica breakeven. |
| `UpdateComment()` | Painel de status no canto do gráfico. |
| `OnInit / OnDeinit / OnTick` | Eventos padrão do MQL5. |

---

## 5. Regras de negócio em detalhe

### 5.1 Formação do canal 1 (`BuildRange`)
- Usa `CopyRates(_Symbol, InpRangeTF, g_rangeStart, now, rates)` com `ArraySetAsSeries(false)` → índice 0 = vela mais antiga.
- As "N primeiras velas" são as **N primeiras velas existentes a partir de `g_rangeStart`**. Se a vela das 01:00 não existir (gap), o canal começa na próxima vela disponível.
- O canal só é considerado pronto quando `rates[N-1].time + PeriodSeconds(TF) <= now` (última vela **fechada**).
- `g_rangeEnd` = fechamento da última vela do canal.
- O tempo gráfico das velas do canal é `InpRangeTF`, **independente do gráfico** em que o robô está.
- Filtros: canal com tamanho zero, menor que `InpMinRangePoints` ou maior que `InpMaxRangePoints` (quando > 0) → dia encerrado.

### 5.2 Rompimento em dois estágios (`CheckBreakout` + `ArmChannel2`)
- `InpBreakoutBuffer` é a folga em **pontos** (`_Point`), aplicada tanto no rompimento do canal 1 quanto no do canal 2.
- **Etapa 1 — canal 1 arma o canal 2 (só a primeira vez)**: enquanto `g_c1BreakDir == 0`, usa o preço conforme `InpEntryMode`:
  - **Modo toque (`ENTRADA_TOQUE`)**: a cada tick, `CurrentPrice() > g_high + folga` → rompeu para cima; `< g_low − folga` → rompeu para baixo.
  - **Modo fechamento (`ENTRADA_FECHAMENTO`)**: só avalia quando abre uma vela nova de `InpRangeTF`; olha o fechamento da vela anterior (índice 1), ignorando velas que ainda fazem parte do canal 1 (`closedTime < g_rangeEnd`).
  - Se rompeu, chama `ArmChannel2(dir)`, que fixa `g_c1BreakDir` e calcula `g_c2High`/`g_c2Low` a partir desse lado. **Não há troca de lado**: uma vez armado, essa etapa não roda mais no dia, mesmo que o preço depois cruze para o lado oposto do canal 1.
- Se o lado do primeiro rompimento estiver desativado (`InpAllowBuy`/`InpAllowSell` = false), **o dia é encerrado** — não espera o outro lado romper (mesma regra do MVP original: "o primeiro rompimento define o lado").
- **Etapa 2 — canal 2 confirma a entrada (sempre por fechamento de vela)**: só roda se `g_c1BreakDir != 0`. Independente de `InpEntryMode`, só avalia quando abre uma vela nova de `InpRangeTF` (controlado por `g_c2LastBarTime`, separado do `g_lastBarTime` da etapa 1); se o fechamento da vela anterior (índice 1) rompe o limite do canal 2 armado (`g_c2High` para cima, `g_c2Low` para baixo) na direção de `g_c1BreakDir`, chama `OpenTrade(g_c1BreakDir)`. Isso evita abrir a operação só por um toque intrabar que reverte antes do fechamento (adicionado em 2026-10-05).
- Não entra se já existir posição do robô (ex.: posição do dia anterior ainda aberta).
- Se o horário limite de entrada for atingido antes do canal 2 romper, **o dia é encerrado** (mesmo que o canal 2 já esteja armado).

### 5.3 Alvo (canal 3 = soma do canal 1 + canal 2)
- Compra: `TP = topo_do_canal_2 + (tamanho_canal_1 + tamanho_canal_2) × InpTargetMult`.
- Venda: `TP = fundo_do_canal_2 − (tamanho_canal_1 + tamanho_canal_2) × InpTargetMult`.
- O alvo é **ancorado no canal 2 armado**, não no preço de entrada. O canal 2 em si é sempre do **mesmo tamanho** do canal 1 (sem multiplicador); como os dois tamanhos são iguais, o canal 3 default (`InpTargetMult = 1.0`) equivale a **2x o tamanho do canal 1** (revisado em 2026-10-05; antes o canal 3 era só 1x o canal 1).
- Se, no momento da entrada, o preço já passou do alvo (gap, robô ligado atrasado, entrada por fechamento longe do canal), **a entrada é cancelada** e o dia encerrado.
- `InpUseTarget = false` → sem TP (saída só por stop, breakeven não funciona, ou zeragem por horário).

### 5.4 Stop (`InpStopMode`)
Continua ancorado no **canal 1** (não no canal 2), mesmo com a entrada acontecendo mais longe do preço original — decisão confirmada pelo usuário em 2026-09-29.

| Modo | Compra | Venda |
|---|---|---|
| `STOP_LADO_OPOSTO` | mínima do canal 1 | máxima do canal 1 |
| `STOP_MEIO_CANAL` | (máx + mín) / 2 | (máx + mín) / 2 |
| `STOP_PONTOS_FIXOS` | entrada − `InpStopPoints` | entrada + `InpStopPoints` (0 = sem stop) |
| `STOP_TAMANHO_CANAL` | entrada − canal × `InpStopMult` | entrada + canal × `InpStopMult` |

Validações antes de enviar a ordem:
- Stop do lado errado da entrada → cancela o dia.
- Stop ou alvo mais perto que `SYMBOL_TRADE_STOPS_LEVEL` → cancela o dia.

### 5.5 Envio da ordem (`OpenTrade`)
- Ordem **a mercado** via `CTrade.Buy/Sell` com preço 0 (usa ask/bid atual), SL e TP já anexados.
- Comentário da ordem: `"Canal Abertura"`.
- Sucesso = retcode `DONE`, `PLACED` ou `DONE_PARTIAL` → `g_tradeDone = true`.
- Falha → tenta de novo nos próximos ticks; após **3 falhas**, encerra o dia.
- Configuração do `CTrade` em `OnInit`: número mágico, desvio (`InpDeviation`) e tipo de preenchimento automático pelo ativo (`SetTypeFillingBySymbol`).

### 5.6 Gestão da posição (`ManagePosition`)
- **Zeragem por horário** (`InpUseCloseTime`): o horário é calculado a partir do **dia de abertura da posição**. Se esse horário for anterior ou igual à abertura, passa para o dia seguinte (suporta zeragem depois da meia-noite).
- **Breakeven** (`InpUseBreakeven`): quando o lucro atinge `InpBETriggerPct`% da distância entrada→alvo, move o stop para `entrada ± InpBEOffsetPoints`. Só move se melhorar o stop atual e respeitar a distância mínima. Exige TP definido.

### 5.7 Uma operação por dia
Garantida por duas camadas:
1. Flag `g_tradeDone` em memória.
2. `TradedSince()` no histórico de negócios a cada novo dia/reinício → sobrevive a reinício do robô, troca de parâmetros ou queda do MT5.

"Dia" = dia do **servidor** (00:00 a 23:59 do horário da plataforma).

### 5.8 Modo teste (`InpStartNow`)
Criado a pedido do usuário para testar em conta demo sem esperar o horário de abertura.
- Ao ligar o robô, o canal 1 começa na **vela atual** de `InpRangeTF` (`iTime(..., 0)`).
- No dia do teste: o **horário limite de entrada é ignorado** e só contam operações feitas **depois** que o robô foi ligado (permite repetir o teste no mesmo dia removendo e recolocando o robô).
- A zeragem por horário **continua valendo**.
- A partir do dia seguinte, volta ao horário normal (`InpStartHour:InpStartMinute`).
- O painel mostra `*** MODO TESTE ***`.
- Dica ao usuário: usar `InpRangeTF = M1` para o canal ficar pronto em poucos minutos.

---

## 6. Parâmetros (inputs)

Os comentários `//` ao lado de cada `input` são o **texto exibido ao usuário** na janela do MT5 — mantenha-os em português e claros.

### Horários (horário da PLATAFORMA)
| Input | Tipo | Padrão | Descrição |
|---|---|---|---|
| `InpStartNow` | bool | false | Modo teste: começar o canal ao ligar o robô |
| `InpStartHour` | int | 1 | Hora de início do canal |
| `InpStartMinute` | int | 0 | Minuto de início do canal |
| `InpRangeTF` | ENUM_TIMEFRAMES | M15 | Tempo gráfico das velas do canal |
| `InpRangeBars` | int | 4 | Quantidade de velas do canal |
| `InpLastEntryHour` | int | 23 | Hora limite para entrar |
| `InpLastEntryMinute` | int | 0 | Minuto limite para entrar |
| `InpUseCloseTime` | bool | true | Zerar posição em horário definido |
| `InpCloseHour` | int | 23 | Hora para zerar |
| `InpCloseMinute` | int | 50 | Minuto para zerar |

### Entrada
| Input | Tipo | Padrão | Descrição |
|---|---|---|---|
| `InpEntryMode` | ENUM_ENTRY_MODE | ENTRADA_TOQUE | Toque no rompimento ou fechamento de vela fora do canal — vale só para o rompimento do canal 1 (arma o canal 2). O rompimento do canal 2 (entrada) é sempre por fechamento de vela |
| `InpBreakoutBuffer` | int | 0 | Folga além do canal (pontos) |
| `InpAllowBuy` | bool | true | Permitir compras |
| `InpAllowSell` | bool | true | Permitir vendas |
| `InpMinRangePoints` | int | 0 | Tamanho mínimo do canal (0 = sem filtro) |
| `InpMaxRangePoints` | int | 0 | Tamanho máximo do canal (0 = sem filtro) |

### Alvo (canal 3)
| Input | Tipo | Padrão | Descrição |
|---|---|---|---|
| `InpUseTarget` | bool | true | Usar alvo no fim do canal 3 |
| `InpTargetMult` | double | 1.0 | Tamanho do canal 3 em múltiplos da soma do canal 1 + canal 2 (o canal 2 em si é sempre 1x o canal 1, sem multiplicador) |

### Stop
| Input | Tipo | Padrão | Descrição |
|---|---|---|---|
| `InpStopMode` | ENUM_STOP_MODE | STOP_LADO_OPOSTO | Tipo de stop (ver 5.4) |
| `InpStopPoints` | int | 200 | Pontos do stop fixo (0 = sem stop) |
| `InpStopMult` | double | 1.0 | Multiplicador do modo tamanho do canal |

### Breakeven
| Input | Tipo | Padrão | Descrição |
|---|---|---|---|
| `InpUseBreakeven` | bool | false | Liga o breakeven |
| `InpBETriggerPct` | double | 50.0 | % do caminho até o alvo para acionar |
| `InpBEOffsetPoints` | int | 0 | Stop vai para entrada ± X pontos |

### Gestão
| Input | Tipo | Padrão | Descrição |
|---|---|---|---|
| `InpLots` | double | 1.0 | Lote / contratos |
| `InpMagic` | ulong | 20260928 | Número mágico (identifica as ordens do robô) |
| `InpDeviation` | int | 10 | Desvio máximo de preço (pontos) |
| `InpDrawChannels` | bool | true | Desenhar canais no gráfico |

### Validações em `OnInit` (retornam `INIT_PARAMETERS_INCORRECT`)
- `InpRangeBars < 1`.
- Horas fora de 0–23 ou minutos fora de 0–59.
- Horário limite de entrada ≤ horário de início do canal.
- `InpLots`, `InpTargetMult` ou `InpStopMult` ≤ 0.

---

## 7. Variáveis globais

| Variável | Uso |
|---|---|
| `trade` | Instância de `CTrade` |
| `g_day` | 00:00 do dia atual do servidor |
| `g_rangeStart` / `g_rangeEnd` | Início do canal / fechamento da última vela do canal |
| `g_high` / `g_low` | Máxima / mínima do canal 1 |
| `g_c1BreakDir` | Lado armado do canal 1 (0 = nenhum, +1 = cima, -1 = baixo) |
| `g_c2High` / `g_c2Low` | Topo / fundo do canal 2 armado |
| `g_rangeReady`, `g_tradeDone`, `g_dayDone` | Estados do dia (seção 3) |
| `g_lastBarTime` | Controle de vela nova para o rompimento do canal 1 (modo fechamento) |
| `g_c2LastBarTime` | Controle de vela nova para a confirmação do canal 2 (sempre por fechamento, independente de `InpEntryMode`) |
| `g_failCount` | Falhas de envio de ordem no dia |
| `g_status` | Texto de status mostrado no painel |
| `g_testDay` / `g_testStart` | Dia e início do canal no modo teste |

---

## 8. Convenções de código

- Prefixos: `Inp` para inputs, `g_` para globais, `PREFIX` (`"CA_"`) para objetos gráficos.
- Estilo de chaves e indentação do MetaEditor (3 espaços, chaves na linha de baixo).
- Mensagens ao usuário (`Print`, `g_status`, comentários de input e de enum) em **português**.
- Todo preço enviado à corretora passa por `NormalizePrice`; todo lote por `NormalizeLots`.
- Posições do robô são sempre identificadas por **ativo + número mágico** — nunca opere/feche posições sem esse filtro.
- Ao editar, preserve o **BOM UTF-8** no início do arquivo.
- Não use `Sleep()` nem laços de espera em `OnTick`.

---

## 9. Como compilar e testar

Não existe compilador MQL5 fora do MetaTrader (no Linux, só via Wine). **Um agente sem MetaEditor não consegue compilar** — diga isso explicitamente ao usuário e peça as mensagens de erro do MetaEditor.

1. MT5 → Arquivo → Abrir pasta de dados → `MQL5/Experts` → copiar `CanalAbertura.mq5`.
2. Abrir no MetaEditor e compilar (**F7**). Deve compilar com 0 erros e 0 avisos.
3. **Strategy Tester** (Ctrl+R):
   - Modelagem: "Cada tick baseado em ticks reais" (mais fiel para rompimentos).
   - Modo visual ligado para conferir os desenhos dos canais e as entradas.
   - Conferir na aba *Diário*/*Experts* as mensagens `Canal 1 formado`, `canal 2 armado`, `COMPRA/VENDA executada`, etc.
4. **Conta demo**: usar `InpStartNow = true` + `InpRangeTF = M1` para ver o ciclo completo em minutos.

### Checklist de verificação após qualquer alteração
- [ ] Compila sem erros/avisos.
- [ ] No máximo 1 entrada por dia no backtest (conferir no relatório).
- [ ] Canal 1 desenhado bate com máx/mín das N velas a partir do horário configurado.
- [ ] Canal 2 só arma **depois** do rompimento do canal 1, e a entrada só acontece no rompimento do canal 2 (nunca no rompimento do canal 1 sozinho).
- [ ] Rompimento do canal 1 pelo lado oposto ao armado **não** troca o canal 2 de lado (o lado do dia fica fixo no primeiro rompimento).
- [ ] Entrada no canal 2 só acontece no **fechamento** de uma vela rompendo-o, mesmo com `InpEntryMode` em modo toque (um toque que reverte antes do fechamento não deve abrir operação).
- [ ] TP no fim do canal 3 (soma do canal 1 + canal 2, x `InpTargetMult`); SL conforme o modo escolhido (ancorado no canal 1).
- [ ] Posição zerada no horário configurado.
- [ ] Reiniciar o robô no meio do dia não gera segunda entrada.

---

## 10. Limitações conhecidas (MVP)

- **Robô ligado com o dia em andamento (modo toque):** se o preço já estiver além do canal 2, entra imediatamente (só cancela se o alvo já tiver sido ultrapassado). Não verifica se os rompimentos aconteceram antes.
- **Conta netting (padrão B3):** operações manuais no mesmo ativo se misturam com a posição do robô.
- **Horários fixos do servidor:** mudanças de horário de verão no servidor da corretora deslocam o horário equivalente em Brasília; ajustar `InpStartHour` manualmente se necessário.
- **Sem controle de risco financeiro** (lote por % do capital, perda máxima diária em R$): lote é fixo.
- **Sem trailing stop.**
- **Sem filtro de dias** (feriados, dias da semana, notícias).
- **Deadline e zeragem** são do mesmo dia do servidor do início do canal (deadline não atravessa meia-noite).
- Canais desenhados vão até 23:59 do dia, não até o horário de zeragem.

## 11. Ideias de evolução (só implementar com pedido do usuário)
- Lote por % de risco do capital baseado na distância do stop.
- Trailing stop.
- Limite de perda/ganho diário em dinheiro.
- Filtro por dia da semana / datas.
- Checagem de rompimentos prévios ao ligar o robô no meio do dia.
- Limite de tempo entre o rompimento do canal 1 e o do canal 2 (hoje só há o horário limite geral de entrada).

---

## 12. Regras para agentes

1. **Não altere a lógica de negócio** (seção 5) sem confirmação do usuário — especialmente "1 operação por dia", "rompimento do canal 1 arma o canal 2 / rompimento do canal 2 confirma a entrada", "lado do canal 1 é fixo no dia (sem troca de lado, removida em 2026-10-05)", "entrada no canal 2 sempre por fechamento de vela, mesmo no modo toque (2026-10-05)", "canal 3 = soma do canal 1 + canal 2, x multiplicador (2026-10-05)" e "stop ancorado no canal 1, alvo ancorado no canal 2 (canal 3)".
2. Novas regras entram como **inputs com padrão que preserva o comportamento atual**.
3. Nunca remova o filtro por número mágico nem as validações de stop/alvo.
4. Atualize este `AGENTS.md` (tabelas de inputs e funções) sempre que mudar o código, e incremente `#property version`.
5. Lembre o usuário de testar em Strategy Tester e conta demo antes de conta real; resultados passados não garantem resultados futuros.
---

## 13. Robô 2 — `SetupCarCas.mq5` (Setup CAR/CAS automatizado)

### 13.1 Visão geral

| Item | Valor |
|---|---|
| Arquivo | `SetupCarCas.mq5` (arquivo único, UTF-8 com BOM) |
| Versão | 1.00 |
| Número mágico padrão | `20261010` (diferente do Canal de Abertura, para rodarem juntos) |
| Prefixo dos objetos | `CC_` + data |
| Origem | Setup de um trader (prints de prompts + vídeo do YouTube enviados pelo usuário em 2026-10-10). No original, CAR e CAS são **digitados à mão** e o EA só mostra sinais (texto + som). Este robô **automatiza tudo**: calcula CAR/CAS, gera os sinais e opera, **sem interação do usuário com o gráfico** (pedido explícito do usuário). |

### 13.2 Regras do setup (todas no fechamento da vela, shift 1, avaliadas na virada de vela de `InpRangeTF`)

Notação: `dist = CAR − CAS` (o canal), `close1` = fechamento da vela que acabou de fechar, `buf = InpBreakoutBuffer × _Point`.

1. **CAR / CAS** = máxima / mínima das `InpRangeBars` primeiras velas de `InpRangeTF` a partir de `InpStartHour:InpStartMinute` (mesma lógica do `BuildRange` do Canal de Abertura). Como vêm de máx/mín, sempre `CAR ≥ CAS`, então `top = CAR` e `bot = CAS` (o original precisava de `top = max(CAR,CAS)` / `bot = min(...)` porque os valores eram digitados).
2. **C1** — criado **uma única vez por dia**, no primeiro fechamento fora do canal, e **nunca mais recalculado**:
   - `close1 > CAR + buf` → `C1 = CAR + dist` (`g_c1Dir = +1`)
   - `close1 < CAS − buf` → `C1 = CAS − dist` (`g_c1Dir = −1`)
3. **TAKE1** — avaliado em todo fechamento depois que o C1 existe (inclusive na mesma vela que criou o C1):
   - C1 abaixo: `close1 < C1 − buf` → `TAKE1 = C1 − |CAR − C1|·mult` (SELL); `close1 > CAR + buf` → `TAKE1 = CAR + |CAR − C1|·mult` (BUY). A segunda regra também cobre o "bugfix" do original (`C1 < CAR e close1 > CAR`).
   - C1 acima: `close1 > C1 + buf` → `TAKE1 = C1 + |C1 − CAS|·mult` (BUY); `close1 < CAS − buf` → `TAKE1 = CAS − |C1 − CAS|·mult` (SELL).
   - `mult = InpTargetMult` (1.0 = regra original). Com `mult = 1`, a distância de projeção é sempre `2 × dist`.
4. **Classificação do sinal** (regras com AND do original):
   - BUY: `TAKE1 > CAR && TAKE1 > C1` → **BUY na CAR**; senão **BUY na C1**.
   - SELL: `TAKE1 < CAS && TAKE1 < C1` → **SELL na CAS**; senão **SELL na C1**.
   - Pela matemática do passo 3, com `mult ≥ 0` os casos "na C1" praticamente não ocorrem; foram mantidos por fidelidade ao setup.
5. **Anti-repetição**: um sinal só é **novo** quando o lado muda (`dir != g_sigDir`). Fechamentos seguintes no mesmo lado não geram sinal, som nem entrada.

Exemplo (CAS 100, CAR 110): fechou 112 → C1 = 120; fechou 121 → TAKE1 140, **BUY na CAR**; depois fechou 99 → TAKE1 80, **SELL na CAS**. Com C1 abaixo (fechou 98 → C1 = 90): fechou 89 → TAKE1 70, SELL na CAS; fechou 111 → TAKE1 130, BUY na CAR.

### 13.3 Decisões de automação (confirmadas pelo usuário em 2026-10-10)

- **CAR/CAS automáticos** = máx/mín das N primeiras velas (não há input de preço manual).
- **Tipo de entrada é parâmetro** (`InpEntryType`):
  - `ENTRADA_MERCADO` (padrão): ordem a mercado no fechamento da vela do sinal.
  - `ENTRADA_LIMITE`: ordem limitada na linha do sinal (`g_sigLevel` = CAR, CAS ou C1). Se a linha não estiver "atrás" do preço (compra precisa de linha abaixo do ask, venda acima do bid) ou estiver mais perto que `SYMBOL_TRADE_STOPS_LEVEL`, entra **a mercado**. Validade: `ORDER_TIME_DAY` se o ativo aceitar, senão `ORDER_TIME_GTC`; o robô também cancela no horário limite de entrada, no horário de zeragem e na virada do dia.
- **Alvo = TAKE1** (`InpUseTarget`). Se o preço de entrada já passou do TAKE1, o sinal é ignorado.
- **Stop** (o setup original não define): padrão **lado oposto do canal** (BUY → CAS, SELL → CAR). Outros modos iguais ao Canal de Abertura (meio do canal, pontos fixos, tamanho do canal × mult). Stop do lado errado ou abaixo da distância mínima → sinal ignorado.
- **Virada é parâmetro** (`InpAllowReversal`, padrão `false`):
  - `false`: **1 operação por dia**; o primeiro sinal executado define o dia.
  - `true`: no máximo **2 entradas por dia**. Sinal contrário fecha a posição aberta (ou cancela a limitada pendente) e entra do outro lado.

### 13.4 Fluxo (`OnTick`)

```
OnTick
 ├─ novo dia → ResetDay (zera estado, cancela limitadas de dias anteriores, conta entradas do dia no histórico)
 ├─ ManagePosition  → zeragem por horário + breakeven (igual ao Canal de Abertura)
 ├─ ManagePending   → cancela limitada no horário limite / zeragem
 ├─ g_entryPending  → TryEntry (re-tenta envio; até 3 falhas)
 └─ se !g_dayDone:
      ├─ !g_rangeReady → BuildRange (CAR/CAS + reconstrução das velas já fechadas, sem operar)
      └─ vela nova de InpRangeTF → OnNewBar → EvaluateClose(close1, live=true)
                                       ├─ cria C1 (1x)
                                       ├─ calcula TAKE1 / classifica sinal
                                       └─ sinal novo → desenha, som, TryEntry
```

### 13.5 Funções específicas

| Função | Responsabilidade |
|---|---|
| `MaxEntries()` | 1 sem virada, 2 com virada. |
| `EntryWindowClosed(now)` | Horário limite de entrada atingido (ignorado no dia do modo teste). |
| `GetPendingTicket()` / `DeletePendingOrders(olderThan)` | Ordens pendentes do robô (ativo + mágico). `olderThan > 0` apaga só as criadas antes dessa data. |
| `CountEntriesSince(from, to)` | Negócios de entrada + ordens pendentes do robô no intervalo. Base do limite diário, sobrevive a reinício. |
| `BuildRange(now)` | Define CAR/CAS, aplica filtros de tamanho e **reconstrói** C1/TAKE1/sinal com as velas que já fecharam (`EvaluateClose(..., live=false)`), para o robô ligado no meio do dia não ficar com estado vazio. Sinais reconstruídos **não** geram entrada nem som. |
| `OnNewBar(now)` | Chama `EvaluateClose` para a vela shift 1, se ela for posterior ao canal. |
| `EvaluateClose(close1, t1, now, live)` | Regras 13.2 (C1, TAKE1, classificação, anti-repetição). Com `live = true`, toca som e chama `TryEntry`. Tem declaração antecipada no topo do arquivo. |
| `TryEntry(now)` | Checa horário e limite diário; trata posição aberta (mesmo lado → nada; outro lado → fecha para virada; de dia anterior → ignora); cancela limitada antiga; chama `PlaceEntry`. |
| `PlaceEntry(dir)` | Calcula entrada (mercado ou limitada), TP = TAKE1, SL conforme `InpStopMode`, valida e envia. Retorna `ENTRY_OK`, `ENTRY_SKIP` (sinal descartado) ou `ENTRY_FAIL` (re-tenta). |
| `ManagePending(now)` | Cancela limitada no horário limite de entrada ou no horário de zeragem. |
| `DrawAll()` / `DrawLine` / `DrawText` / `DrawRect` | Canal (retângulo preenchido), linhas CAR/CAS/C1/TAKE1 (`OBJ_TREND` do início do canal até 23:59, com nome e preço) e **um único** texto de sinal por dia acima do TAKE1. Objetos criados 1 vez e depois só atualizados; `SELECTABLE = false`, `SELECTED = false`, `HIDDEN = true`. |

### 13.6 Variáveis globais específicas

| Variável | Uso |
|---|---|
| `g_car` / `g_cas` | Resistência / suporte (máx / mín do canal) |
| `g_c1Dir` / `g_c1` | Lado e preço da C1 (0 = ainda não criada); fixos no dia |
| `g_sigDir` / `g_take1` / `g_sigLevel` / `g_sigName` / `g_sigTime` | Sinal ativo: lado, alvo, linha de entrada, nome da linha, vela do sinal |
| `g_entries` | Entradas do dia (para `MaxEntries()`) |
| `g_entryPending` / `g_failCount` | Sinal aguardando envio / falhas de envio desse sinal |

### 13.7 Inputs específicos (os demais são iguais aos do Canal de Abertura, seção 6)

| Input | Tipo | Padrão | Descrição |
|---|---|---|---|
| `InpEntryType` | ENUM_ENTRY_TYPE | ENTRADA_MERCADO | Mercado ou limitada na linha do sinal |
| `InpAllowReversal` | bool | false | Permitir 1 virada no dia (máx. 2 entradas) |
| `InpUseTarget` | bool | true | TAKE1 como take profit |
| `InpTargetMult` | double | 1.0 | Multiplicador da distância de projeção do TAKE1 |
| `InpBreakoutBuffer` | int | 0 | Folga (pontos) para valer fechamento fora de qualquer linha (CAR, CAS, C1) |
| `InpMagic` | ulong | 20261010 | Número mágico |
| `InpDrawObjects` | bool | true | Desenhar objetos |
| `InpColorCAR` / `InpColorCAS` / `InpColorC1` / `InpColorTake1` | color | azul / laranja / dourado / magenta | Cores das linhas |
| `InpColorChannel` | color | `C'25,45,70'` | Preenchimento do canal |
| `InpLineWidth` | int | 2 | Espessura das linhas |
| `InpColorBuy` / `InpColorSell` | color | verde / vermelho | Cor do texto do sinal |
| `InpUseSound` / `InpSoundFile` | bool / string | true / `alert.wav` | Som em sinal novo (ignorado no Strategy Tester) |

Não existe `InpEntryMode` (toque) neste robô: tudo é por fechamento de vela, como no setup original.

### 13.8 Checklist específico

- [ ] CAR/CAS batem com máx/mín das N velas; canal e linhas desenhados sem duplicar objetos.
- [ ] C1 criado no primeiro fechamento fora do canal e **nunca** muda no dia.
- [ ] TAKE1 e rótulo do sinal batem com a tabela do exemplo 13.2.
- [ ] Sem virada: no máximo 1 entrada por dia. Com virada: no máximo 2, e a virada fecha a posição anterior antes de entrar.
- [ ] Limitada: ordem na linha certa (CAR para BUY, CAS para SELL); cancelada no horário limite, na zeragem e no dia seguinte.
- [ ] Ligar o robô no meio do dia reconstrói o estado e **não** entra em sinal antigo.

### 13.9 Pontos ainda não confirmados pelo usuário

1. Tempo gráfico real das velas (padrão provisório M15) e se o canal do setup também usa 4 velas a partir das 01:00.
2. Qual tipo de entrada funciona melhor (mercado × limitada) e se a virada fica ligada — decidir com backtest.
3. Stop definitivo (o setup original não define).
4. Ativo, lote, horário limite de entrada e horário de zeragem.

### 13.10 Limitações conhecidas

- **Conta netting:** operações manuais ou de outro robô no mesmo ativo se misturam com a posição (o Canal de Abertura e este robô **não devem operar o mesmo ativo na mesma conta netting**).
- Sem trailing stop, sem lote por % de risco, sem limite financeiro diário.
- O texto do sinal mostra só o último sinal do dia (um único objeto, como pedido no setup).
- Reinício com virada ligada: o lado do último sinal é reconstruído pelas velas; se a posição do primeiro sinal já tiver sido encerrada, um sinal contrário novo ainda pode gerar a 2ª entrada (comportamento esperado).
