//+------------------------------------------------------------------+
//|                                              CanalAbertura.mq5   |
//|  MVP - Canal de abertura com confirmação em dois estágios        |
//|                                                                  |
//|  Lógica:                                                         |
//|   1. A partir do horário de início (horário da plataforma),      |
//|      pega as N primeiras velas do tempo gráfico escolhido.       |
//|   2. Máxima e mínima dessas velas = CANAL 1.                     |
//|   3. Rompeu o CANAL 1 (cima ou baixo) -> arma o CANAL 2, do      |
//|      mesmo tamanho do canal 1, projetado a partir do lado        |
//|      rompido (não entra ainda).                                  |
//|   4. Rompeu o CANAL 2 na mesma direção -> ENTRA na operação      |
//|      (compra se foi para cima, vende se foi para baixo). O lado  |
//|      definido pelo primeiro rompimento do canal 1 é fixo no dia. |
//|   5. Alvo = fim do CANAL 3 (mesmo tamanho do canal 1, x          |
//|      multiplicador, projetado a partir do canal 2).              |
//|   6. Apenas 1 operação por dia.                                  |
//+------------------------------------------------------------------+
#property copyright "MVP Canal de Abertura"
#property version   "2.00"
#property description "Canal de abertura: rompimento do canal 1 (lado fixo no dia) arma o canal 2; rompimento do canal 2 confirma a entrada; alvo no canal 3. 1 operação por dia."

#include <Trade/Trade.mqh>

//--- Opções de entrada
enum ENUM_ENTRY_MODE
  {
   ENTRADA_TOQUE      = 0, // Preço rompe o canal (entra na hora)
   ENTRADA_FECHAMENTO = 1  // Vela fecha fora do canal
  };

//--- Opções de stop
enum ENUM_STOP_MODE
  {
   STOP_LADO_OPOSTO   = 0, // Lado oposto do canal 1
   STOP_MEIO_CANAL    = 1, // Meio do canal 1
   STOP_PONTOS_FIXOS  = 2, // Pontos fixos a partir da entrada
   STOP_TAMANHO_CANAL = 3  // Tamanho do canal (x multiplicador) a partir da entrada
  };

//+------------------------------------------------------------------+
//| Parâmetros                                                       |
//+------------------------------------------------------------------+
input group "=== Horários (horário da PLATAFORMA) ==="
input bool            InpStartNow        = false;      // MODO TESTE: começar o canal agora (ao ligar o robô)
input int             InpStartHour       = 1;          // Hora de início do canal
input int             InpStartMinute     = 0;          // Minuto de início do canal
input ENUM_TIMEFRAMES InpRangeTF         = PERIOD_M15; // Tempo gráfico das velas do canal
input int             InpRangeBars       = 4;          // Quantidade de velas do canal
input int             InpLastEntryHour   = 23;         // Hora limite para entrar
input int             InpLastEntryMinute = 0;          // Minuto limite para entrar
input bool            InpUseCloseTime    = true;       // Zerar posição em horário definido?
input int             InpCloseHour       = 23;         // Hora para zerar
input int             InpCloseMinute     = 50;         // Minuto para zerar

input group "=== Entrada ==="
input ENUM_ENTRY_MODE InpEntryMode       = ENTRADA_TOQUE; // Tipo de rompimento (vale para o canal 1 e o canal 2)
input int             InpBreakoutBuffer  = 0;          // Folga além do canal para confirmar (pontos)
input bool            InpAllowBuy        = true;       // Permitir compras
input bool            InpAllowSell       = true;       // Permitir vendas
input int             InpMinRangePoints  = 0;          // Tamanho mínimo do canal (pontos, 0 = sem filtro)
input int             InpMaxRangePoints  = 0;          // Tamanho máximo do canal (pontos, 0 = sem filtro)

input group "=== Alvo (canal 3) ==="
input bool            InpUseTarget       = true;       // Usar alvo no fim do canal 3
input double          InpTargetMult      = 1.0;        // Tamanho do canal 3 (x tamanho do canal 1)

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
input ulong           InpMagic           = 20260928;   // Número mágico (identificador do robô)
input int             InpDeviation       = 10;         // Desvio máximo de preço (pontos)
input bool            InpDrawChannels    = true;       // Desenhar canais no gráfico

//+------------------------------------------------------------------+
//| Variáveis globais                                                |
//+------------------------------------------------------------------+
#define PREFIX "CA_"

CTrade   trade;

datetime g_day         = 0;     // dia atual (00:00 do servidor)
datetime g_rangeStart  = 0;     // início do canal 1
datetime g_rangeEnd    = 0;     // fim do canal 1 (fechamento da última vela)
bool     g_rangeReady  = false; // canal 1 formado
bool     g_tradeDone   = false; // já operou hoje
bool     g_dayDone     = false; // dia encerrado (sem mais entradas)
double   g_high        = 0.0;   // máxima do canal 1
double   g_low         = 0.0;   // mínima do canal 1
int      g_c1BreakDir  = 0;     // lado armado do canal 1 (0 = nenhum, +1 = cima, -1 = baixo); fixo no dia
double   g_c2High      = 0.0;   // topo do canal 2 armado
double   g_c2Low       = 0.0;   // fundo do canal 2 armado
datetime g_lastBarTime = 0;     // controle de nova vela (modo fechamento)
int      g_failCount   = 0;     // tentativas de envio de ordem que falharam
string   g_status      = "";
datetime g_testDay     = 0;     // modo teste: dia em que o robô foi ligado
datetime g_testStart   = 0;     // modo teste: início do canal (vela atual ao ligar)

bool IsTestDay()
  {
   return (InpStartNow && g_day == g_testDay);
  }

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

double CurrentPrice()
  {
   MqlTick t;
   if(!SymbolInfoTick(_Symbol, t))
      return 0.0;
   // Na B3 usa o último negócio; no forex (sem "last") usa o bid
   return (t.last > 0.0 ? t.last : t.bid);
  }

//+------------------------------------------------------------------+
//| Posição do robô (filtrada por ativo + número mágico)             |
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

//+------------------------------------------------------------------+
//| Verifica no histórico se o robô já entrou hoje                   |
//| (garante 1 operação por dia mesmo se o robô for reiniciado)      |
//+------------------------------------------------------------------+
bool TradedSince(datetime from, datetime to)
  {
   if(!HistorySelect(from, to))
      return false;
   for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
     {
      ulong deal = HistoryDealGetTicket(i);
      if(deal == 0)
         continue;
      if(HistoryDealGetString(deal, DEAL_SYMBOL) == _Symbol &&
         HistoryDealGetInteger(deal, DEAL_MAGIC) == (long)InpMagic &&
         HistoryDealGetInteger(deal, DEAL_ENTRY) == DEAL_ENTRY_IN)
         return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Desenho dos canais                                               |
//+------------------------------------------------------------------+
void DrawRect(string name, datetime t1, double p1, datetime t2, double p2,
              color clr, bool fill, ENUM_LINE_STYLE style)
  {
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_RECTANGLE, 0, t1, p1, t2, p2);
   else
     {
      ObjectMove(0, name, 0, t1, p1);
      ObjectMove(0, name, 1, t2, p2);
     }
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_FILL, fill);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
   ObjectSetInteger(0, name, OBJPROP_STYLE, style);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
  }

void DrawChannels()
  {
   if(!InpDrawChannels)
      return;
   string   d      = TimeToString(g_day, TIME_DATE);
   datetime tEnd   = AtTime(g_day, 23, 59);
   double   range  = g_high - g_low;
   double   c3Size = range * InpTargetMult;

   // Canal 1 (velas de abertura)
   DrawRect(PREFIX + d + "_C1", g_rangeStart, g_high, tEnd, g_low,
            clrSteelBlue, true, STYLE_SOLID);

   if(g_c1BreakDir == 0)
     {
      // Ainda não rompeu: mostra as duas projeções possíveis do canal 2
      DrawRect(PREFIX + d + "_C2_UP", g_rangeEnd, g_high, tEnd, g_high + range,
               clrLimeGreen, false, STYLE_DOT);
      DrawRect(PREFIX + d + "_C2_DN", g_rangeEnd, g_low, tEnd, g_low - range,
               clrTomato, false, STYLE_DOT);
      ObjectDelete(0, PREFIX + d + "_C3");
     }
   else
     {
      // Canal 2 armado (lado definido): apaga a projeção do lado que não armou
      color clr = (g_c1BreakDir > 0 ? clrLimeGreen : clrTomato);
      if(g_c1BreakDir > 0)
        {
         ObjectDelete(0, PREFIX + d + "_C2_DN");
         DrawRect(PREFIX + d + "_C2_UP", g_rangeEnd, g_c2Low, tEnd, g_c2High, clr, true, STYLE_SOLID);
        }
      else
        {
         ObjectDelete(0, PREFIX + d + "_C2_UP");
         DrawRect(PREFIX + d + "_C2_DN", g_rangeEnd, g_c2Low, tEnd, g_c2High, clr, true, STYLE_SOLID);
        }

      // Canal 3 (alvo), projetado a partir do canal 2 armado
      if(InpUseTarget)
        {
         if(g_c1BreakDir > 0)
            DrawRect(PREFIX + d + "_C3", g_rangeEnd, g_c2High, tEnd, g_c2High + c3Size,
                     clrLimeGreen, false, STYLE_DOT);
         else
            DrawRect(PREFIX + d + "_C3", g_rangeEnd, g_c2Low, tEnd, g_c2Low - c3Size,
                     clrTomato, false, STYLE_DOT);
        }
     }
   ChartRedraw();
  }

//+------------------------------------------------------------------+
//| Início de um novo dia: zera o estado                             |
//+------------------------------------------------------------------+
void ResetDay(datetime day)
  {
   g_day         = day;
   g_rangeStart  = AtTime(day, InpStartHour, InpStartMinute);
   g_rangeEnd    = 0;
   g_rangeReady  = false;
   g_dayDone     = false;
   g_high        = 0.0;
   g_low         = 0.0;
   g_c1BreakDir  = 0;
   g_c2High      = 0.0;
   g_c2Low       = 0.0;
   g_lastBarTime = 0;
   g_failCount   = 0;

   if(IsTestDay())
     {
      // Modo teste: canal começa na vela em que o robô foi ligado
      // e só contam as operações feitas depois disso
      g_rangeStart = g_testStart;
      g_tradeDone  = TradedSince(g_testStart, day + 86400);
     }
   else
      g_tradeDone = TradedSince(day, day + 86400);

   g_status = g_tradeDone ? "Operação do dia já realizada"
                          : "Aguardando formação do canal 1";
  }

//+------------------------------------------------------------------+
//| Monta o canal 1 quando as N velas fecham                         |
//+------------------------------------------------------------------+
void BuildRange(datetime now)
  {
   if(now < g_rangeStart)
      return;

   MqlRates rates[];
   ArraySetAsSeries(rates, false); // índice 0 = vela mais antiga
   int copied = CopyRates(_Symbol, InpRangeTF, g_rangeStart, now, rates);
   if(copied < InpRangeBars)
      return; // canal ainda em formação (ou dados carregando)

   int period = PeriodSeconds(InpRangeTF);
   // a última vela do canal precisa estar fechada
   if(rates[InpRangeBars - 1].time + period > now)
      return;

   double hi = rates[0].high;
   double lo = rates[0].low;
   for(int i = 1; i < InpRangeBars; i++)
     {
      if(rates[i].high > hi)
         hi = rates[i].high;
      if(rates[i].low < lo)
         lo = rates[i].low;
     }

   g_high        = hi;
   g_low         = lo;
   g_rangeEnd    = rates[InpRangeBars - 1].time + period;
   g_rangeReady  = true;
   g_lastBarTime = iTime(_Symbol, InpRangeTF, 0);

   double rangePts = (hi - lo) / _Point;
   PrintFormat("Canal 1 formado: máxima %s | mínima %s | tamanho %.0f pontos",
               DoubleToString(hi, _Digits), DoubleToString(lo, _Digits), rangePts);

   DrawChannels();

   if(hi <= lo)
     {
      g_dayDone = true;
      g_status  = "Canal com tamanho zero - sem operação hoje";
      return;
     }
   if(InpMinRangePoints > 0 && rangePts < InpMinRangePoints)
     {
      g_dayDone = true;
      g_status  = StringFormat("Canal menor que o mínimo (%.0f < %d pts) - sem operação hoje",
                               rangePts, InpMinRangePoints);
      Print(g_status);
      return;
     }
   if(InpMaxRangePoints > 0 && rangePts > InpMaxRangePoints)
     {
      g_dayDone = true;
      g_status  = StringFormat("Canal maior que o máximo (%.0f > %d pts) - sem operação hoje",
                               rangePts, InpMaxRangePoints);
      Print(g_status);
      return;
     }
   g_status = "Canal 1 formado - aguardando rompimento do canal 1";
  }

//+------------------------------------------------------------------+
//| Abre a operação na direção do rompimento                         |
//| dir = +1 compra | -1 venda                                       |
//+------------------------------------------------------------------+
void OpenTrade(int dir)
  {
   MqlTick t;
   if(!SymbolInfoTick(_Symbol, t))
      return;

   double range = g_high - g_low;
   double entry = (dir > 0 ? t.ask : t.bid);
   double tp    = 0.0;
   double sl    = 0.0;

   // --- Alvo: fim do canal 3 (projetado a partir do canal 2 armado)
   if(InpUseTarget)
     {
      double c2Bound = (dir > 0 ? g_c2High : g_c2Low);
      tp = NormalizePrice(dir > 0 ? c2Bound + range * InpTargetMult
                                  : c2Bound - range * InpTargetMult);
      if((dir > 0 && entry >= tp) || (dir < 0 && entry <= tp))
        {
         g_dayDone = true;
         g_status  = "Preço já passou do alvo do canal 3 - entrada cancelada";
         Print(g_status);
         return;
        }
     }

   // --- Stop
   switch(InpStopMode)
     {
      case STOP_LADO_OPOSTO:
         sl = (dir > 0 ? g_low : g_high);
         break;
      case STOP_MEIO_CANAL:
         sl = (g_high + g_low) / 2.0;
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
      g_dayDone = true;
      g_status  = "Stop ficaria do lado errado da entrada - entrada cancelada";
      Print(g_status);
      return;
     }

   // --- Distância mínima exigida pela corretora
   double minDist = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   if(minDist > 0.0)
     {
      if((sl != 0.0 && MathAbs(entry - sl) < minDist) ||
         (tp != 0.0 && MathAbs(tp - entry) < minDist))
        {
         g_dayDone = true;
         g_status  = "Stop ou alvo abaixo da distância mínima da corretora - entrada cancelada";
         Print(g_status);
         return;
        }
     }

   double lots = NormalizeLots(InpLots);
   bool   ok   = (dir > 0 ? trade.Buy(lots, _Symbol, 0.0, sl, tp, "Canal Abertura")
                          : trade.Sell(lots, _Symbol, 0.0, sl, tp, "Canal Abertura"));

   uint rc = trade.ResultRetcode();
   if(ok && (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_PLACED || rc == TRADE_RETCODE_DONE_PARTIAL))
     {
      g_tradeDone = true;
      g_status    = StringFormat("%s executada | SL %s | TP %s",
                                 dir > 0 ? "COMPRA" : "VENDA",
                                 sl != 0.0 ? DoubleToString(sl, _Digits) : "-",
                                 tp != 0.0 ? DoubleToString(tp, _Digits) : "-");
      Print(g_status);
      return;
     }

   g_failCount++;
   PrintFormat("Falha ao enviar ordem (tentativa %d): %u - %s",
               g_failCount, rc, trade.ResultRetcodeDescription());
   if(g_failCount >= 3)
     {
      g_dayDone = true;
      g_status  = "Ordem falhou 3 vezes - sem operação hoje (veja a aba Experts)";
     }
  }

//+------------------------------------------------------------------+
//| Arma o canal 2 a partir do primeiro rompimento do canal 1.       |
//| dir = +1 rompeu para cima | -1 rompeu para baixo                 |
//+------------------------------------------------------------------+
void ArmChannel2(int dir)
  {
   double range = g_high - g_low;
   g_c1BreakDir = dir;
   if(dir > 0)
     {
      g_c2Low  = g_high;
      g_c2High = g_high + range;
     }
   else
     {
      g_c2High = g_low;
      g_c2Low  = g_low - range;
     }
   g_status = StringFormat("Canal 1 rompeu para %s - canal 2 armado (%s - %s), aguardando rompimento do canal 2",
                           dir > 0 ? "cima" : "baixo",
                           DoubleToString(g_c2Low, _Digits), DoubleToString(g_c2High, _Digits));
   Print(g_status);
   DrawChannels();
  }

//+------------------------------------------------------------------+
//| Verifica o rompimento do canal 1 (arma o canal 2, lado fixo no   |
//| dia) e o rompimento do canal 2 (confirma a entrada)              |
//+------------------------------------------------------------------+
void CheckBreakout(datetime now)
  {
   datetime deadline = AtTime(g_day, InpLastEntryHour, InpLastEntryMinute);
   if(!IsTestDay() && now >= deadline) // no modo teste o limite de entrada é ignorado
     {
      g_dayDone = true;
      g_status  = (g_c1BreakDir == 0)
                  ? "Horário limite de entrada atingido sem rompimento do canal 1"
                  : "Horário limite de entrada atingido sem rompimento do canal 2";
      Print(g_status);
      return;
     }
   if(GetPositionTicket() != 0)
      return; // ainda existe posição aberta (ex.: do dia anterior)

   double buffer = InpBreakoutBuffer * _Point;
   double price  = 0.0;

   if(InpEntryMode == ENTRADA_TOQUE)
     {
      price = CurrentPrice();
      if(price <= 0.0)
         return;
     }
   else // ENTRADA_FECHAMENTO
     {
      datetime barTime = iTime(_Symbol, InpRangeTF, 0);
      if(barTime == g_lastBarTime)
         return; // só verifica quando abre uma vela nova
      g_lastBarTime = barTime;

      datetime closedTime = iTime(_Symbol, InpRangeTF, 1);
      if(closedTime < g_rangeEnd)
         return; // a vela fechada ainda faz parte do canal

      price = iClose(_Symbol, InpRangeTF, 1);
     }

   // --- Etapa 1: primeiro rompimento do canal 1 arma o canal 2 (lado fixo no dia)
   if(g_c1BreakDir == 0)
     {
      int rawDir1 = 0;
      if(price > g_high + buffer)
         rawDir1 = 1;
      else if(price < g_low - buffer)
         rawDir1 = -1;

      if(rawDir1 == 0)
         return;

      // O primeiro rompimento define o lado do dia
      if((rawDir1 > 0 && !InpAllowBuy) || (rawDir1 < 0 && !InpAllowSell))
        {
         g_dayDone = true;
         g_status  = StringFormat("Rompimento do canal 1 para %s, mas esse lado está desativado - sem operação hoje",
                                  rawDir1 > 0 ? "cima" : "baixo");
         Print(g_status);
         return;
        }

      ArmChannel2(rawDir1);
     }

   // --- Etapa 2: rompimento do canal 2 (confirma a entrada)
   bool broke2 = (g_c1BreakDir > 0 ? price > g_c2High + buffer
                                   : price < g_c2Low  - buffer);
   if(!broke2)
      return;

   OpenTrade(g_c1BreakDir);
  }

//+------------------------------------------------------------------+
//| Gestão da posição: zerar por horário e breakeven                 |
//+------------------------------------------------------------------+
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
         closeTime += 86400; // horário de zerar é no dia seguinte
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
      return; // breakeven é medido em relação ao alvo

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
            Print("Breakeven acionado (compra): stop em ", DoubleToString(beLevel, _Digits));
        }
     }
   else if(type == POSITION_TYPE_SELL)
     {
      double ask     = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double beLevel = NormalizePrice(open - InpBEOffsetPoints * _Point);
      if(open - ask >= trigger && (sl == 0.0 || sl > beLevel) && beLevel - ask > minDist)
        {
         if(trade.PositionModify(ticket, beLevel, tp))
            Print("Breakeven acionado (venda): stop em ", DoubleToString(beLevel, _Digits));
        }
     }
  }

//+------------------------------------------------------------------+
//| Painel de informações no gráfico                                 |
//+------------------------------------------------------------------+
void UpdateComment()
  {
   string s = "Canal de Abertura - MVP\n";
   if(IsTestDay())
      s += "*** MODO TESTE: canal iniciado ao ligar o robô ***\n";
   s += "Dia: " + TimeToString(g_day, TIME_DATE) + "\n";
   s += "Início do canal: " + TimeToString(g_rangeStart, TIME_MINUTES) +
        " | " + IntegerToString(InpRangeBars) + " velas de " +
        StringSubstr(EnumToString(InpRangeTF), 7) + "\n";
   if(g_rangeReady)
      s += StringFormat("Canal 1: %s - %s (%.0f pts)\n",
                        DoubleToString(g_low, _Digits),
                        DoubleToString(g_high, _Digits),
                        (g_high - g_low) / _Point);
   if(g_c1BreakDir != 0)
      s += StringFormat("Canal 2 (%s): %s - %s\n",
                        g_c1BreakDir > 0 ? "cima" : "baixo",
                        DoubleToString(g_c2Low, _Digits),
                        DoubleToString(g_c2High, _Digits));
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
      g_testStart  = iTime(_Symbol, InpRangeTF, 0); // vela atual
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

   if(!g_tradeDone && !g_dayDone)
     {
      if(!g_rangeReady)
         BuildRange(now);
      if(g_rangeReady && !g_dayDone)
         CheckBreakout(now);
     }

   UpdateComment();
  }
//+------------------------------------------------------------------+
