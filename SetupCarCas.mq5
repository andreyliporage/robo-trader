//+------------------------------------------------------------------+
//|                                                SetupCarCas.mq5   |
//|  Setup CAR / CAS / C1 / TAKE1 - versão totalmente automatizada   |
//|                                                                  |
//|  Lógica (sempre no FECHAMENTO da vela, shift 1):                 |
//|   1. CAR (resistência) e CAS (suporte) = máxima e mínima das N   |
//|      primeiras velas a partir do horário de início.              |
//|      Canal de abertura = entre CAS e CAR. dist = CAR - CAS.      |
//|   2. C1 (fixo depois de criado, 1 vez por dia):                  |
//|      fechou acima do CAR  -> C1 = CAR + dist                     |
//|      fechou abaixo do CAS -> C1 = CAS - dist                     |
//|   3. TAKE1 (alvo), a cada fechamento depois do C1:               |
//|      C1 abaixo: fechou abaixo do C1 -> TAKE1 = C1 - |CAR - C1|   |
//|                 fechou acima do CAR -> TAKE1 = CAR + |CAR - C1|  |
//|      C1 acima:  fechou acima do C1  -> TAKE1 = C1 + |C1 - CAS|   |
//|                 fechou abaixo do CAS -> TAKE1 = CAS - |C1 - CAS| |
//|   4. Sinal:                                                      |
//|      BUY na CAR  se TAKE1 > CAR e TAKE1 > C1                     |
//|      SELL na CAS se TAKE1 < CAS e TAKE1 < C1                     |
//|      senão BUY/SELL na C1                                        |
//|   5. Entrada a mercado ou ordem limitada na linha do sinal;      |
//|      alvo = TAKE1; stop configurável (padrão: lado oposto do     |
//|      canal). 1 operação por dia, ou 2 com a virada ligada.       |
//+------------------------------------------------------------------+
#property copyright "Setup CAR/CAS automatizado"
#property version   "1.00"
#property description "Setup CAR/CAS/C1/TAKE1 automatizado: canal de abertura pelas N primeiras velas, C1 fixo no primeiro fechamento fora do canal, TAKE1 como alvo, entrada a mercado ou limitada. 1 operação por dia (2 com virada)."

#include <Trade/Trade.mqh>

//--- Tipo de entrada
enum ENUM_ENTRY_TYPE
  {
   ENTRADA_MERCADO = 0, // A mercado no fechamento da vela do sinal
   ENTRADA_LIMITE  = 1  // Ordem limitada na linha do sinal (CAR / CAS / C1)
  };

//--- Opções de stop
enum ENUM_STOP_MODE
  {
   STOP_LADO_OPOSTO   = 0, // Lado oposto do canal (BUY: CAS / SELL: CAR)
   STOP_MEIO_CANAL    = 1, // Meio do canal de abertura
   STOP_PONTOS_FIXOS  = 2, // Pontos fixos a partir da entrada
   STOP_TAMANHO_CANAL = 3  // Tamanho do canal (x multiplicador) a partir da entrada
  };

//--- Resultado de uma tentativa de entrada
#define ENTRY_OK   0
#define ENTRY_SKIP 1
#define ENTRY_FAIL 2

//+------------------------------------------------------------------+
//| Parâmetros                                                       |
//+------------------------------------------------------------------+
input group "=== Horários (horário da PLATAFORMA) ==="
input bool            InpStartNow        = false;      // MODO TESTE: começar o canal agora (ao ligar o robô)
input int             InpStartHour       = 1;          // Hora de início do canal (CAR/CAS)
input int             InpStartMinute     = 0;          // Minuto de início do canal
input ENUM_TIMEFRAMES InpRangeTF         = PERIOD_M15; // Tempo gráfico das velas (canal e sinais)
input int             InpRangeBars       = 4;          // Quantidade de velas do canal
input int             InpLastEntryHour   = 23;         // Hora limite para entrar
input int             InpLastEntryMinute = 0;          // Minuto limite para entrar
input bool            InpUseCloseTime    = true;       // Zerar posição em horário definido?
input int             InpCloseHour       = 23;         // Hora para zerar
input int             InpCloseMinute     = 50;         // Minuto para zerar

input group "=== Sinais ==="
input int             InpBreakoutBuffer  = 0;          // Folga para considerar fechamento fora da linha (pontos)
input bool            InpAllowBuy        = true;       // Permitir compras
input bool            InpAllowSell       = true;       // Permitir vendas
input int             InpMinRangePoints  = 0;          // Tamanho mínimo do canal (pontos, 0 = sem filtro)
input int             InpMaxRangePoints  = 0;          // Tamanho máximo do canal (pontos, 0 = sem filtro)

input group "=== Entrada ==="
input ENUM_ENTRY_TYPE InpEntryType       = ENTRADA_MERCADO; // Tipo de entrada
input bool            InpAllowReversal   = false;      // Permitir 1 virada no dia (sinal contrário fecha e inverte)

input group "=== Alvo (TAKE1) ==="
input bool            InpUseTarget       = true;       // Usar TAKE1 como alvo
input double          InpTargetMult      = 1.0;        // Multiplicador da distância de projeção do TAKE1

input group "=== Stop ==="
input ENUM_STOP_MODE  InpStopMode        = STOP_LADO_OPOSTO; // Tipo de stop
input int             InpStopPoints      = 200;        // Stop em pontos (modo pontos fixos, 0 = sem stop)
input double          InpStopMult        = 1.0;        // Multiplicador (modo tamanho do canal)

input group "=== Breakeven ==="
input bool            InpUseBreakeven    = false;      // Usar breakeven
input double          InpBETriggerPct    = 50.0;       // Aciona ao percorrer X% do caminho até o alvo
input int             InpBEOffsetPoints  = 0;          // Stop vai para entrada + X pontos

input group "=== Gestão ==="
input double          InpLots            = 1.0;        // Lote / contratos
input ulong           InpMagic           = 20261010;   // Número mágico (diferente do Canal de Abertura)
input int             InpDeviation       = 10;         // Desvio máximo de preço (pontos)

input group "=== Visual e som ==="
input bool            InpDrawObjects     = true;       // Desenhar linhas e canal no gráfico
input color           InpColorCAR        = clrDodgerBlue;  // Cor da CAR
input color           InpColorCAS        = clrOrangeRed;   // Cor da CAS
input color           InpColorC1         = clrGold;        // Cor da C1
input color           InpColorTake1      = clrMagenta;     // Cor do TAKE1
input color           InpColorChannel    = C'25,45,70';    // Cor do preenchimento do canal
input int             InpLineWidth       = 2;          // Espessura das linhas
input color           InpColorBuy        = clrLime;    // Cor do texto BUY
input color           InpColorSell       = clrRed;     // Cor do texto SELL
input bool            InpUseSound        = true;       // Tocar som em sinal novo
input string          InpSoundFile       = "alert.wav"; // Arquivo de som (pasta Sounds do MT5)

//+------------------------------------------------------------------+
//| Variáveis globais                                                |
//+------------------------------------------------------------------+
#define PREFIX "CC_"

CTrade   trade;

datetime g_day          = 0;     // dia atual (00:00 do servidor)
datetime g_rangeStart   = 0;     // início do canal
datetime g_rangeEnd     = 0;     // fechamento da última vela do canal
bool     g_rangeReady   = false; // CAR/CAS definidos
bool     g_dayDone      = false; // dia encerrado (filtro de canal)
double   g_car          = 0.0;   // resistência (máxima do canal)
double   g_cas          = 0.0;   // suporte (mínima do canal)
int      g_c1Dir        = 0;     // 0 = sem C1, +1 = C1 acima do CAR, -1 = C1 abaixo do CAS
double   g_c1           = 0.0;   // preço da C1 (fixo no dia)
int      g_sigDir       = 0;     // sinal ativo: 0 = nenhum, +1 = BUY, -1 = SELL
double   g_take1        = 0.0;   // TAKE1 do sinal ativo
double   g_sigLevel     = 0.0;   // linha do sinal (CAR / CAS / C1)
string   g_sigName      = "";    // nome da linha do sinal
datetime g_sigTime      = 0;     // vela que gerou o sinal
datetime g_lastBarTime  = 0;     // controle de vela nova
int      g_entries      = 0;     // entradas feitas hoje (posições + ordens limitadas)
bool     g_entryPending = false; // há um sinal aguardando execução
int      g_failCount    = 0;     // falhas de envio para o sinal atual
string   g_status       = "";
datetime g_testDay      = 0;     // modo teste: dia em que o robô foi ligado
datetime g_testStart    = 0;     // modo teste: início do canal

bool IsTestDay()
  {
   return (InpStartNow && g_day == g_testDay);
  }

int MaxEntries()
  {
   return (InpAllowReversal ? 2 : 1);
  }

//--- Declaração antecipada (definida mais abaixo)
void EvaluateClose(double close1, datetime t1, datetime now, bool live);

//+------------------------------------------------------------------+
//| Utilidades de tempo                                              |
//+------------------------------------------------------------------+
datetime DayStart(datetime t)
  {
   MqlDateTime s;
   TimeToStruct(t, s);
   s.hour = 0;
   s.min  = 0;
   s.sec  = 0;
   return StructToTime(s);
  }

datetime AtTime(datetime day, int hour, int minute)
  {
   return day + hour * 3600 + minute * 60;
  }

datetime EntryDeadline()
  {
   return AtTime(g_day, InpLastEntryHour, InpLastEntryMinute);
  }

bool EntryWindowClosed(datetime now)
  {
   return (!IsTestDay() && now >= EntryDeadline());
  }

//+------------------------------------------------------------------+
//| Utilidades de preço e lote                                       |
//+------------------------------------------------------------------+
double NormalizePrice(double price)
  {
   double tick = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tick <= 0.0)
      tick = _Point;
   return NormalizeDouble(MathRound(price / tick) * tick, _Digits);
  }

double NormalizeLots(double lots)
  {
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double vmax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(step <= 0.0)
      step = 1.0;
   lots = MathFloor(lots / step + 1e-9) * step;
   if(lots < vmin)
      lots = vmin;
   if(lots > vmax)
      lots = vmax;
   int digits = (int)MathMax(0, MathCeil(-MathLog10(step) - 1e-9));
   return NormalizeDouble(lots, digits);
  }

string Px(double price)
  {
   return DoubleToString(price, _Digits);
  }

//+------------------------------------------------------------------+
//| Posições e ordens do robô (filtradas por ativo + número mágico)  |
//+------------------------------------------------------------------+
ulong GetPositionTicket()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         PositionGetInteger(POSITION_MAGIC) == (long)InpMagic)
         return ticket;
     }
   return 0;
  }

ulong GetPendingTicket()
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0)
         continue;
      if(OrderGetString(ORDER_SYMBOL) == _Symbol &&
         OrderGetInteger(ORDER_MAGIC) == (long)InpMagic)
         return ticket;
     }
   return 0;
  }

//--- Apaga ordens pendentes do robô; se olderThan > 0, só as criadas antes dessa data
void DeletePendingOrders(datetime olderThan)
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0)
         continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol ||
         OrderGetInteger(ORDER_MAGIC) != (long)InpMagic)
         continue;
      if(olderThan > 0 && (datetime)OrderGetInteger(ORDER_TIME_SETUP) >= olderThan)
         continue;
      if(trade.OrderDelete(ticket))
         PrintFormat("Ordem pendente %I64u cancelada", ticket);
     }
  }

//+------------------------------------------------------------------+
//| Conta as entradas do robô no intervalo (negócios de entrada +    |
//| ordens limitadas ainda pendentes). Garante o limite diário       |
//| mesmo se o robô ou o MT5 forem reiniciados.                      |
//+------------------------------------------------------------------+
int CountEntriesSince(datetime from, datetime to)
  {
   int count = 0;
   if(HistorySelect(from, to))
     {
      for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
        {
         ulong deal = HistoryDealGetTicket(i);
         if(deal == 0)
            continue;
         if(HistoryDealGetString(deal, DEAL_SYMBOL) == _Symbol &&
            HistoryDealGetInteger(deal, DEAL_MAGIC) == (long)InpMagic &&
            HistoryDealGetInteger(deal, DEAL_ENTRY) == DEAL_ENTRY_IN)
            count++;
        }
     }
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0)
         continue;
      if(OrderGetString(ORDER_SYMBOL) == _Symbol &&
         OrderGetInteger(ORDER_MAGIC) == (long)InpMagic &&
         (datetime)OrderGetInteger(ORDER_TIME_SETUP) >= from)
         count++;
     }
   return count;
  }

//+------------------------------------------------------------------+
//| Objetos gráficos (criados 1 vez, depois só atualizados)          |
//+------------------------------------------------------------------+
void SetCommonProps(string name)
  {
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTED, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
  }

void DrawText(string name, datetime t, double price, string text, color clr, ENUM_ANCHOR_POINT anchor)
  {
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_TEXT, 0, t, price);
   else
      ObjectMove(0, name, 0, t, price);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 9);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR, anchor);
   SetCommonProps(name);
  }

void DrawLine(string name, datetime t1, datetime t2, double price, color clr, string label)
  {
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_TREND, 0, t1, price, t2, price);
   else
     {
      ObjectMove(0, name, 0, t1, price);
      ObjectMove(0, name, 1, t2, price);
     }
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, InpLineWidth);
   ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_SOLID);
   ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
   ObjectSetInteger(0, name, OBJPROP_RAY_LEFT, false);
   SetCommonProps(name);
   DrawText(name + "_TXT", t1, price, label + " " + Px(price), clr, ANCHOR_LEFT_LOWER);
  }

void DrawRect(string name, datetime t1, double p1, datetime t2, double p2, color clr)
  {
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_RECTANGLE, 0, t1, p1, t2, p2);
   else
     {
      ObjectMove(0, name, 0, t1, p1);
      ObjectMove(0, name, 1, t2, p2);
     }
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_FILL, true);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
   SetCommonProps(name);
  }

void DrawAll()
  {
   if(!InpDrawObjects || !g_rangeReady)
      return;
   string   d    = PREFIX + TimeToString(g_day, TIME_DATE);
   datetime tEnd = AtTime(g_day, 23, 59);

   DrawRect(d + "_CANAL", g_rangeStart, g_car, tEnd, g_cas, InpColorChannel);
   DrawLine(d + "_CAR", g_rangeStart, tEnd, g_car, InpColorCAR, "CAR");
   DrawLine(d + "_CAS", g_rangeStart, tEnd, g_cas, InpColorCAS, "CAS");

   if(g_c1Dir != 0)
      DrawLine(d + "_C1", g_rangeEnd, tEnd, g_c1, InpColorC1, "C1");

   if(g_sigDir != 0)
     {
      DrawLine(d + "_TAKE1", g_rangeEnd, tEnd, g_take1, InpColorTake1, "TAKE1");
      // Um único texto de sinal por dia, acima da linha do TAKE1 (atualizado a cada sinal novo)
      double offset = (g_car - g_cas) * 0.15;
      string txt    = StringFormat("%s na %s (%s)", g_sigDir > 0 ? "BUY" : "SELL", g_sigName, Px(g_sigLevel));
      DrawText(d + "_SINAL", g_sigTime, g_take1 + offset, txt,
               g_sigDir > 0 ? InpColorBuy : InpColorSell, ANCHOR_LEFT_LOWER);
     }
   ChartRedraw();
  }

//+------------------------------------------------------------------+
//| Início de um novo dia: zera o estado                             |
//+------------------------------------------------------------------+
void ResetDay(datetime day)
  {
   g_day          = day;
   g_rangeStart   = AtTime(day, InpStartHour, InpStartMinute);
   g_rangeEnd     = 0;
   g_rangeReady   = false;
   g_dayDone      = false;
   g_car          = 0.0;
   g_cas          = 0.0;
   g_c1Dir        = 0;
   g_c1           = 0.0;
   g_sigDir       = 0;
   g_take1        = 0.0;
   g_sigLevel     = 0.0;
   g_sigName      = "";
   g_sigTime      = 0;
   g_lastBarTime  = 0;
   g_entryPending = false;
   g_failCount    = 0;

   // Ordens limitadas de dias anteriores não valem mais
   DeletePendingOrders(day);

   if(IsTestDay())
     {
      g_rangeStart = g_testStart;
      g_entries    = CountEntriesSince(g_testStart, day + 86400);
     }
   else
      g_entries = CountEntriesSince(day, day + 86400);

   g_status = (g_entries >= MaxEntries()) ? "Limite de operações do dia já atingido"
                                          : "Aguardando formação do canal (CAR/CAS)";
  }

//+------------------------------------------------------------------+
//| Define CAR e CAS quando as N velas fecham                        |
//+------------------------------------------------------------------+
void BuildRange(datetime now)
  {
   if(now < g_rangeStart)
      return;

   MqlRates rates[];
   ArraySetAsSeries(rates, false); // índice 0 = vela mais antiga
   int copied = CopyRates(_Symbol, InpRangeTF, g_rangeStart, now, rates);
   if(copied < InpRangeBars)
      return;

   int period = PeriodSeconds(InpRangeTF);
   if(rates[InpRangeBars - 1].time + period > now)
      return; // última vela do canal ainda aberta

   double hi = rates[0].high;
   double lo = rates[0].low;
   for(int i = 1; i < InpRangeBars; i++)
     {
      if(rates[i].high > hi)
         hi = rates[i].high;
      if(rates[i].low < lo)
         lo = rates[i].low;
     }

   g_car         = hi;
   g_cas         = lo;
   g_rangeEnd    = rates[InpRangeBars - 1].time + period;
   g_rangeReady  = true;
   g_lastBarTime = iTime(_Symbol, InpRangeTF, 0);

   double rangePts = (hi - lo) / _Point;
   PrintFormat("Canal de abertura: CAR %s | CAS %s | tamanho %.0f pontos", Px(hi), Px(lo), rangePts);
   DrawAll();

   if(hi <= lo)
     {
      g_dayDone = true;
      g_status  = "Canal com tamanho zero - sem operação hoje";
      return;
     }
   if(InpMinRangePoints > 0 && rangePts < InpMinRangePoints)
     {
      g_dayDone = true;
      g_status  = StringFormat("Canal menor que o mínimo (%.0f < %d pts) - sem operação hoje", rangePts, InpMinRangePoints);
      Print(g_status);
      return;
     }
   if(InpMaxRangePoints > 0 && rangePts > InpMaxRangePoints)
     {
      g_dayDone = true;
      g_status  = StringFormat("Canal maior que o máximo (%.0f > %d pts) - sem operação hoje", rangePts, InpMaxRangePoints);
      Print(g_status);
      return;
     }
   g_status = "Canal formado - aguardando fechamento fora do canal (C1)";

   // Robô ligado com o dia em andamento: reconstrói C1 / TAKE1 / sinal
   // a partir das velas que já fecharam depois do canal (sem operar).
   // A última posição de rates[] é a vela em formação, por isso fica de fora.
   for(int i = InpRangeBars; i < copied - 1; i++)
      EvaluateClose(rates[i].close, rates[i].time, now, false);
   if(g_sigDir != 0)
      g_status = StringFormat("Estado reconstruído: último sinal %s na %s (já passou, sem entrada)",
                              g_sigDir > 0 ? "BUY" : "SELL", g_sigName);
  }

//+------------------------------------------------------------------+
//| Envia a ordem de entrada do sinal ativo                          |
//+------------------------------------------------------------------+
int PlaceEntry(int dir)
  {
   MqlTick t;
   if(!SymbolInfoTick(_Symbol, t))
      return ENTRY_FAIL;

   double minDist  = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   double market   = (dir > 0 ? t.ask : t.bid);
   double entry    = market;
   bool   useLimit = (InpEntryType == ENTRADA_LIMITE);

   if(useLimit)
     {
      double lvl = NormalizePrice(g_sigLevel);
      // Limitada só faz sentido com a linha "atrás" do preço (compra abaixo, venda acima)
      bool valid = (dir > 0 ? lvl < t.ask : lvl > t.bid) && MathAbs(market - lvl) >= minDist;
      if(valid)
         entry = lvl;
      else
        {
         useLimit = false; // preço já está na linha: entra a mercado
         Print("Preço já está na linha do sinal - entrada a mercado");
        }
     }

   // --- Alvo = TAKE1
   double tp = (InpUseTarget ? NormalizePrice(g_take1) : 0.0);
   if(tp != 0.0 && ((dir > 0 && entry >= tp) || (dir < 0 && entry <= tp)))
     {
      g_status = "Preço já passou do TAKE1 - sinal ignorado";
      Print(g_status);
      return ENTRY_SKIP;
     }

   // --- Stop
   double range = g_car - g_cas;
   double sl    = 0.0;
   switch(InpStopMode)
     {
      case STOP_LADO_OPOSTO:
         sl = (dir > 0 ? g_cas : g_car);
         break;
      case STOP_MEIO_CANAL:
         sl = (g_car + g_cas) / 2.0;
         break;
      case STOP_PONTOS_FIXOS:
         sl = (InpStopPoints > 0 ? entry - dir * InpStopPoints * _Point : 0.0);
         break;
      case STOP_TAMANHO_CANAL:
         sl = entry - dir * range * InpStopMult;
         break;
     }
   if(sl != 0.0)
      sl = NormalizePrice(sl);

   if(sl != 0.0 && ((dir > 0 && sl >= entry) || (dir < 0 && sl <= entry)))
     {
      g_status = "Stop ficaria do lado errado da entrada - sinal ignorado";
      Print(g_status);
      return ENTRY_SKIP;
     }
   if(minDist > 0.0 &&
      ((sl != 0.0 && MathAbs(entry - sl) < minDist) || (tp != 0.0 && MathAbs(tp - entry) < minDist)))
     {
      g_status = "Stop ou alvo abaixo da distância mínima da corretora - sinal ignorado";
      Print(g_status);
      return ENTRY_SKIP;
     }

   double lots    = NormalizeLots(InpLots);
   string comment = StringFormat("CAR/CAS %s na %s", dir > 0 ? "BUY" : "SELL", g_sigName);
   bool   ok;

   if(useLimit)
     {
      long expModes = SymbolInfoInteger(_Symbol, SYMBOL_EXPIRATION_MODE);
      ENUM_ORDER_TYPE_TIME tt = ((expModes & SYMBOL_EXPIRATION_DAY) != 0 ? ORDER_TIME_DAY : ORDER_TIME_GTC);
      ok = (dir > 0 ? trade.BuyLimit(lots, entry, _Symbol, sl, tp, tt, 0, comment)
                    : trade.SellLimit(lots, entry, _Symbol, sl, tp, tt, 0, comment));
     }
   else
      ok = (dir > 0 ? trade.Buy(lots, _Symbol, 0.0, sl, tp, comment)
                    : trade.Sell(lots, _Symbol, 0.0, sl, tp, comment));

   uint rc = trade.ResultRetcode();
   if(ok && (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_PLACED || rc == TRADE_RETCODE_DONE_PARTIAL))
     {
      g_status = StringFormat("%s %s | entrada %s | SL %s | TP %s",
                              dir > 0 ? "COMPRA" : "VENDA",
                              useLimit ? "limitada enviada" : "executada",
                              useLimit ? Px(entry) : "mercado",
                              sl != 0.0 ? Px(sl) : "-",
                              tp != 0.0 ? Px(tp) : "-");
      Print(g_status);
      return ENTRY_OK;
     }

   PrintFormat("Falha ao enviar ordem: %u - %s", rc, trade.ResultRetcodeDescription());
   return ENTRY_FAIL;
  }

//+------------------------------------------------------------------+
//| Executa o sinal ativo (com virada, se permitida)                 |
//+------------------------------------------------------------------+
void TryEntry(datetime now)
  {
   int dir = g_sigDir;

   if(EntryWindowClosed(now))
     {
      g_entryPending = false;
      g_status       = "Sinal depois do horário limite - ignorado";
      return;
     }
   if(g_entries >= MaxEntries())
     {
      g_entryPending = false;
      g_status       = "Limite de operações do dia atingido - sinal ignorado";
      return;
     }

   // --- Posição aberta?
   ulong pos = GetPositionTicket();
   if(pos != 0 && PositionSelectByTicket(pos))
     {
      int posDir = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? 1 : -1);
      if(posDir == dir)
        {
         g_entryPending = false; // já está posicionado no lado do sinal
         return;
        }
      if((datetime)PositionGetInteger(POSITION_TIME) < g_day)
        {
         g_entryPending = false;
         g_status       = "Posição de dia anterior ainda aberta - sinal ignorado";
         return;
        }
      // Sinal contrário com posição aberta = virada (só chega aqui se InpAllowReversal,
      // porque sem virada o limite de 1 entrada já barrou acima)
      if(!trade.PositionClose(pos))
        {
         g_failCount++;
         PrintFormat("Falha ao fechar posição para virada: %u - %s",
                     trade.ResultRetcode(), trade.ResultRetcodeDescription());
         if(g_failCount >= 3)
            g_entryPending = false;
         return;
        }
      Print("Virada: posição anterior fechada");
     }

   // Ordem limitada antiga (do sinal anterior) não vale mais
   DeletePendingOrders(0);

   int r = PlaceEntry(dir);
   if(r == ENTRY_OK)
     {
      g_entries++;
      g_entryPending = false;
     }
   else if(r == ENTRY_SKIP)
      g_entryPending = false;
   else
     {
      g_failCount++;
      if(g_failCount >= 3)
        {
         g_entryPending = false;
         g_status       = "Ordem falhou 3 vezes - sinal descartado (veja a aba Experts)";
        }
     }
  }

//+------------------------------------------------------------------+
//| Avalia a vela que acabou de fechar (shift 1): C1, TAKE1 e sinal  |
//+------------------------------------------------------------------+
void OnNewBar(datetime now)
  {
   datetime t1 = iTime(_Symbol, InpRangeTF, 1);
   if(t1 < g_rangeEnd)
      return; // vela ainda faz parte do canal
   EvaluateClose(iClose(_Symbol, InpRangeTF, 1), t1, now, true);
  }

//+------------------------------------------------------------------+
//| Regras do setup para um fechamento de vela.                      |
//| live = false: só reconstrói o estado (C1, TAKE1, sinal) das      |
//| velas que já fecharam antes de o robô ser ligado, sem operar.    |
//+------------------------------------------------------------------+
void EvaluateClose(double close1, datetime t1, datetime now, bool live)
  {
   double buf    = InpBreakoutBuffer * _Point;
   double dist   = g_car - g_cas; // dist = |CAR - CAS|

   // --- C1: criado uma única vez, no primeiro fechamento fora do canal; depois fica fixo
   if(g_c1Dir == 0)
     {
      if(close1 > g_car + buf)
        {
         g_c1Dir = 1;
         g_c1    = NormalizePrice(g_car + dist);
        }
      else if(close1 < g_cas - buf)
        {
         g_c1Dir = -1;
         g_c1    = NormalizePrice(g_cas - dist);
        }
      if(g_c1Dir == 0)
         return;
      g_status = StringFormat("C1 criado %s do canal em %s - aguardando TAKE1",
                              g_c1Dir > 0 ? "acima" : "abaixo", Px(g_c1));
      Print(g_status);
      DrawAll();
      // segue: a mesma vela pode já formar o TAKE1
     }

   // --- TAKE1
   int    dir  = 0;
   double take = 0.0;
   if(g_c1Dir < 0) // C1 abaixo do CAS
     {
      double d = MathAbs(g_car - g_c1) * InpTargetMult;
      if(close1 < g_c1 - buf)
        {
         dir  = -1;
         take = g_c1 - d;
        }
      else if(close1 > g_car + buf)
        {
         dir  = 1;
         take = g_car + d;
        }
     }
   else // C1 acima do CAR
     {
      double d = MathAbs(g_c1 - g_cas) * InpTargetMult;
      if(close1 > g_c1 + buf)
        {
         dir  = 1;
         take = g_c1 + d;
        }
      else if(close1 < g_cas - buf)
        {
         dir  = -1;
         take = g_cas - d;
        }
     }
   if(dir == 0)
      return;
   take = NormalizePrice(take);

   // --- Classificação do sinal (regras do setup, com AND)
   double level = 0.0;
   string name  = "";
   if(dir > 0)
     {
      if(take > g_car && take > g_c1)
        { level = g_car; name = "CAR"; }
      else
        { level = g_c1;  name = "C1"; }
     }
   else
     {
      if(take < g_cas && take < g_c1)
        { level = g_cas; name = "CAS"; }
      else
        { level = g_c1;  name = "C1"; }
     }

   // --- Anti-repetição: só é sinal novo se mudou o lado
   if(dir == g_sigDir)
      return;

   g_sigDir   = dir;
   g_take1    = take;
   g_sigLevel = level;
   g_sigName  = name;
   g_sigTime  = t1;
   g_status   = StringFormat("Sinal %s na %s (%s) | TAKE1 %s",
                             dir > 0 ? "BUY" : "SELL", name, Px(level), Px(take));
   Print(g_status);
   DrawAll();
   if(!live)
      return; // reconstrução: o sinal já passou, não opera nem toca som

   if(InpUseSound)
      PlaySound(InpSoundFile);

   if((dir > 0 && !InpAllowBuy) || (dir < 0 && !InpAllowSell))
     {
      g_status = StringFormat("Sinal %s ignorado (lado desativado)", dir > 0 ? "BUY" : "SELL");
      Print(g_status);
      return;
     }

   g_entryPending = true;
   g_failCount    = 0;
   TryEntry(now);
  }

//+------------------------------------------------------------------+
//| Gestão: ordens pendentes, zeragem por horário e breakeven        |
//+------------------------------------------------------------------+
void ManagePending(datetime now)
  {
   if(GetPendingTicket() == 0)
      return;
   bool expire = EntryWindowClosed(now);
   if(InpUseCloseTime)
     {
      datetime ct = AtTime(g_day, InpCloseHour, InpCloseMinute);
      if(ct <= g_rangeStart)
         ct += 86400;
      if(now >= ct)
         expire = true;
     }
   if(expire)
     {
      DeletePendingOrders(0);
      g_status = "Ordem limitada cancelada por horário";
     }
  }

void ManagePosition(datetime now)
  {
   ulong ticket = GetPositionTicket();
   if(ticket == 0 || !PositionSelectByTicket(ticket))
      return;

   // --- Zerar por horário
   if(InpUseCloseTime)
     {
      datetime openTime  = (datetime)PositionGetInteger(POSITION_TIME);
      datetime closeTime = AtTime(DayStart(openTime), InpCloseHour, InpCloseMinute);
      if(closeTime <= openTime)
         closeTime += 86400;
      if(now >= closeTime)
        {
         if(trade.PositionClose(ticket))
           {
            g_status = "Posição zerada por horário";
            Print(g_status);
           }
         return;
        }
     }

   // --- Breakeven
   if(!InpUseBreakeven)
      return;

   double open = PositionGetDouble(POSITION_PRICE_OPEN);
   double sl   = PositionGetDouble(POSITION_SL);
   double tp   = PositionGetDouble(POSITION_TP);
   if(tp == 0.0)
      return;

   long   type    = PositionGetInteger(POSITION_TYPE);
   double trigger = MathAbs(tp - open) * InpBETriggerPct / 100.0;
   double minDist = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;

   if(type == POSITION_TYPE_BUY)
     {
      double bid     = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double beLevel = NormalizePrice(open + InpBEOffsetPoints * _Point);
      if(bid - open >= trigger && (sl == 0.0 || sl < beLevel) && bid - beLevel > minDist)
        {
         if(trade.PositionModify(ticket, beLevel, tp))
            Print("Breakeven acionado (compra): stop em ", Px(beLevel));
        }
     }
   else if(type == POSITION_TYPE_SELL)
     {
      double ask     = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double beLevel = NormalizePrice(open - InpBEOffsetPoints * _Point);
      if(open - ask >= trigger && (sl == 0.0 || sl > beLevel) && beLevel - ask > minDist)
        {
         if(trade.PositionModify(ticket, beLevel, tp))
            Print("Breakeven acionado (venda): stop em ", Px(beLevel));
        }
     }
  }

//+------------------------------------------------------------------+
//| Painel de informações no gráfico                                 |
//+------------------------------------------------------------------+
void UpdateComment()
  {
   string s = "Setup CAR/CAS - automatizado\n";
   if(IsTestDay())
      s += "*** MODO TESTE: canal iniciado ao ligar o robô ***\n";
   s += "Dia: " + TimeToString(g_day, TIME_DATE) + " | início " + TimeToString(g_rangeStart, TIME_MINUTES) +
        " | " + IntegerToString(InpRangeBars) + " velas de " + StringSubstr(EnumToString(InpRangeTF), 7) + "\n";
   if(g_rangeReady)
      s += StringFormat("CAR: %s | CAS: %s (%.0f pts)\n", Px(g_car), Px(g_cas), (g_car - g_cas) / _Point);
   if(g_c1Dir != 0)
      s += StringFormat("C1: %s (%s)\n", Px(g_c1), g_c1Dir > 0 ? "acima" : "abaixo");
   if(g_sigDir != 0)
      s += StringFormat("Sinal: %s na %s | TAKE1: %s\n", g_sigDir > 0 ? "BUY" : "SELL", g_sigName, Px(g_take1));
   s += StringFormat("Operações hoje: %d de %d\n", g_entries, MaxEntries());
   s += "Status: " + g_status;
   Comment(s);
  }

//+------------------------------------------------------------------+
//| Eventos                                                          |
//+------------------------------------------------------------------+
int OnInit()
  {
   if(InpRangeBars < 1)
     {
      Print("Quantidade de velas do canal deve ser >= 1");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpStartHour < 0 || InpStartHour > 23 || InpStartMinute < 0 || InpStartMinute > 59 ||
      InpLastEntryHour < 0 || InpLastEntryHour > 23 || InpLastEntryMinute < 0 || InpLastEntryMinute > 59 ||
      InpCloseHour < 0 || InpCloseHour > 23 || InpCloseMinute < 0 || InpCloseMinute > 59)
     {
      Print("Horários inválidos (hora 0-23, minuto 0-59)");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpLastEntryHour * 60 + InpLastEntryMinute <= InpStartHour * 60 + InpStartMinute)
     {
      Print("O horário limite de entrada precisa ser depois do início do canal");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpLots <= 0.0 || InpTargetMult <= 0.0 || InpStopMult <= 0.0)
     {
      Print("Lote e multiplicadores precisam ser maiores que zero");
      return INIT_PARAMETERS_INCORRECT;
     }

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpDeviation);
   trade.SetTypeFillingBySymbol(_Symbol);

   if(InpStartNow)
     {
      datetime now = TimeCurrent();
      g_testStart  = iTime(_Symbol, InpRangeTF, 0);
      if(g_testStart <= 0)
        {
         int per     = PeriodSeconds(InpRangeTF);
         g_testStart = (datetime)((long)now / per * per);
        }
      g_testDay = DayStart(now);
      PrintFormat("MODO TESTE: canal começa em %s (%d velas de %s)",
                  TimeToString(g_testStart, TIME_DATE | TIME_MINUTES), InpRangeBars,
                  StringSubstr(EnumToString(InpRangeTF), 7));
     }

   ResetDay(DayStart(TimeCurrent()));
   UpdateComment();
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   Comment("");
   if(reason == REASON_REMOVE)
      ObjectsDeleteAll(0, PREFIX);
  }

void OnTick()
  {
   datetime now   = TimeCurrent();
   datetime today = DayStart(now);
   if(today != g_day)
      ResetDay(today);

   ManagePosition(now);
   ManagePending(now);

   if(g_entryPending)
      TryEntry(now);

   if(!g_dayDone)
     {
      if(!g_rangeReady)
         BuildRange(now);
      if(g_rangeReady && !g_dayDone)
        {
         datetime barTime = iTime(_Symbol, InpRangeTF, 0);
         if(barTime != g_lastBarTime)
           {
            g_lastBarTime = barTime;
            OnNewBar(now);
           }
        }
     }

   UpdateComment();
  }
//+------------------------------------------------------------------+
