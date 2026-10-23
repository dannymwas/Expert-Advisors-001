//+------------------------------------------------------------------+
//| XAUUSD_RangeMSS_EA.mq5                                           |
//| XAUUSD M15 range breakout + M3 market-structure shift (v1.0)     |
//| Implements the written specification exactly; no extra filters.  |
//|                                                                  |
//| INDEXING CONVENTION (anti look-ahead):                           |
//|  Every CopyRates() array is chronological (index 0 = oldest,     |
//|  last index = newest, possibly the still-forming bar).           |
//|  A bar k is "closed" only if  a[k].time + PeriodSeconds <= now.  |
//|  A swing centred on bar c with strength S needs bars c-S..c+S    |
//|  all closed; it is usable by candle k only if c+S <= k-1.        |
//+------------------------------------------------------------------+
#property copyright "Spec v1.0 implementation"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

#define OBJP "XRM_"
#define M3SEC 180
#define M15SEC 900
#define EAT_UTC_OFFSET_SEC 10800

enum ENUM_SERVER_TZ_MODE
  {
   TZ_FIXED_OFFSET     = 0,  // Server offset is constant (Std offset input)
   TZ_US_DST_SCHEDULE  = 1   // Server follows US DST (e.g. GMT+2 winter / GMT+3 summer)
  };

enum ENUM_STATE
  {
   ST_WAITING_FOR_RANGE = 0,
   ST_RANGE_READY,
   ST_WAITING_FOR_M15_BREAKOUT,
   ST_WAITING_FOR_M3_STRUCTURE_SHIFT,
   ST_WAITING_FOR_RETEST,
   ST_WAITING_FOR_CONFIRMATION,
   ST_TRADE_ACTIVE,
   ST_SETUP_EXPIRED,
   ST_DAY_COMPLETE
  };

enum ENUM_ENTRY_RESULT { ENTRY_FILLED = 0, ENTRY_REJECTED = 1, ENTRY_RETRY = 2 };

//--- inputs
input string  InpSymbol                = "";         // Trading symbol (empty = chart symbol, e.g. XAUUSD / GOLD)
input string  InpRangeStartEAT         = "13:00";    // Range start (EAT)
input string  InpRangeEndEAT           = "14:30";    // Range end (EAT)
input string  InpTradingStartEAT       = "14:30";    // Earliest trading time (EAT)
input string  InpLastEntryEAT          = "17:00";    // Last permitted new entry (EAT)
input int     InpSwingStrength         = 2;          // Swing strength (candles each side)
input int     InpSwingLookbackBars     = 300;        // Max M3 bars scanned back for a swing
input double  InpRetestTolerancePoints = 20;         // Retest tolerance (points)
input double  InpStopBufferPoints      = 20;         // Stop buffer (points)
input double  InpRewardRiskRatio       = 2.0;        // Reward:Risk (2.0 or 3.0 only)
input double  InpRiskPercent           = 0.5;        // Risk per trade (% of equity)
input double  InpMaxSpreadPoints       = 50;         // Max spread (points)
input int     InpMaxDeviationPoints    = 30;         // Max deviation (points)
input int     InpSetupExpiryMinutes    = 30;         // Setup expiry after M15 breakout close
input ulong   InpMagicNumber           = 20261022;   // Magic number
input ENUM_SERVER_TZ_MODE InpServerTZMode = TZ_US_DST_SCHEDULE; // Server time model
input int     InpServerStdOffsetHours  = 2;          // Server UTC offset (winter / fixed)
input int     InpServerDstOffsetHours  = 3;          // Server UTC offset while US DST active
input bool    InpVerifyServerOffsetLive= true;       // Live: verify offset vs TimeGMT()
input int     InpMaxEntryDelaySeconds  = 60;         // Max delay between confirmation close and entry
input int     InpMaxOrderRetries       = 2;          // Retries on requote/price change/timeout
input bool    InpUsePersistence        = true;       // Persist end-of-day state (live only)
input bool    InpShowChart             = true;       // Draw objects / status panel
input bool    InpVerboseLog            = false;      // Log swing confirmations etc.

//--- forward declarations
datetime ServerToEAT(datetime srv);
bool     SetState(ENUM_STATE ns, const string note);
void     Refresh();
void     PrintCounters();

//--- globals: symbol
string   g_sym;
double   g_point, g_tick;
int      g_digits;
CTrade   g_trade;

//--- globals: schedule (minutes after 00:00 EAT)
int      g_startMin, g_endMin, g_tradeStartMin, g_lastEntryMin;

//--- globals: day state
ENUM_STATE g_state = ST_WAITING_FOR_RANGE;
datetime g_dayEAT = 0;
datetime g_rangeStartSrv, g_rangeEndSrv, g_tradeStartSrv, g_lastEntrySrv;
bool     g_rangeFinal = false;
double   g_rangeHigh = 0, g_rangeLow = 0;
int      g_dir = 0;
datetime g_boTime = 0, g_boClose = 0;
double   g_boPrice = 0;
datetime g_expiry = 0, g_deadline = 0;
datetime g_lastM15Proc = 0, g_lastM3Proc = 0, g_lastM3Bar0 = 0;
double   g_brokenLevel = 0;
datetime g_brokenSwingTime = 0, g_mssTime = 0;
double   g_retHigh = 0, g_retLow = 0;
datetime g_retTime = 0;
bool     g_confirmed = false;
datetime g_confTime = 0;
double   g_confHigh = 0, g_confLow = 0;
double   g_entryPrice = 0, g_sl = 0, g_tp = 0;
bool     g_tradeTakenToday = false;
bool     g_tzOK = true;
ulong    g_trackPosId = 0;
string   g_dayNote = "";
double   g_lastSpread = 0;
bool     g_initOK = false;
datetime g_lastWarn = 0;

//--- counters / records
int g_cntDays = 0, g_cntNoRange = 0, g_cntNoBreakout = 0, g_cntBreakouts = 0;
int g_cntExpired = 0, g_cntRejected = 0, g_cntTrades = 0;
ulong  g_recPos[];
double g_recRisk[];
int    g_recDir[];

//+------------------------------------------------------------------+
//| Logging helpers                                                  |
//+------------------------------------------------------------------+
void Log(const string msg)
  {
   datetime now = TimeCurrent();
   Print("[RangeMSS] ", TimeToString(ServerToEAT(now), TIME_DATE | TIME_SECONDS), " EAT | srv ",
         TimeToString(now, TIME_DATE | TIME_SECONDS), " | ", msg);
  }

void Warn(const string msg)   // throttled to once per 5 minutes
  {
   datetime now = TimeCurrent();
   if(now - g_lastWarn < 300) return;
   g_lastWarn = now;
   Log("WARN: " + msg);
  }

string StateName(ENUM_STATE s)
  {
   switch(s)
     {
      case ST_WAITING_FOR_RANGE:            return "WAITING_FOR_RANGE";
      case ST_RANGE_READY:                  return "RANGE_READY";
      case ST_WAITING_FOR_M15_BREAKOUT:     return "WAITING_FOR_M15_BREAKOUT";
      case ST_WAITING_FOR_M3_STRUCTURE_SHIFT: return "WAITING_FOR_M3_STRUCTURE_SHIFT";
      case ST_WAITING_FOR_RETEST:           return "WAITING_FOR_RETEST";
      case ST_WAITING_FOR_CONFIRMATION:     return "WAITING_FOR_CONFIRMATION";
      case ST_TRADE_ACTIVE:                 return "TRADE_ACTIVE";
      case ST_SETUP_EXPIRED:                return "SETUP_EXPIRED";
      case ST_DAY_COMPLETE:                 return "DAY_COMPLETE";
     }
   return "UNKNOWN";
  }

//+------------------------------------------------------------------+
//| Time zone conversion (server <-> UTC <-> EAT)                    |
//+------------------------------------------------------------------+
datetime NthSunday(int year, int mon, int n)
  {
   MqlDateTime s;
   ZeroMemory(s);
   s.year = year; s.mon = mon; s.day = 1;
   datetime first = StructToTime(s);
   MqlDateTime f;
   TimeToStruct(first, f);
   int firstSun = 1 + ((7 - f.day_of_week) % 7);
   s.day = firstSun + 7 * (n - 1);
   return StructToTime(s);
  }

bool DSTActiveUTC(datetime utc)
  {
   MqlDateTime t;
   TimeToStruct(utc, t);
   datetime st = NthSunday(t.year, 3, 2);   // 2nd Sunday of March
   datetime en = NthSunday(t.year, 11, 1);  // 1st Sunday of November
   return (utc >= st && utc < en);
  }

datetime ServerToUTC(datetime srv)
  {
   if(InpServerTZMode == TZ_FIXED_OFFSET)
      return srv - InpServerStdOffsetHours * 3600;
   datetime cand = srv - InpServerDstOffsetHours * 3600;
   if(DSTActiveUTC(cand)) return cand;
   return srv - InpServerStdOffsetHours * 3600;
  }

datetime UTCToServer(datetime utc)
  {
   if(InpServerTZMode == TZ_FIXED_OFFSET)
      return utc + InpServerStdOffsetHours * 3600;
   int off = DSTActiveUTC(utc) ? InpServerDstOffsetHours : InpServerStdOffsetHours;
   return utc + off * 3600;
  }

datetime ServerToEAT(datetime srv) { return ServerToUTC(srv) + EAT_UTC_OFFSET_SEC; }
datetime EATToServer(datetime eat) { return UTCToServer(eat - EAT_UTC_OFFSET_SEC); }

// Live only: compare modelled UTC with the terminal's TimeGMT().
bool VerifyServerOffset()
  {
   if(!InpVerifyServerOffsetLive || MQLInfoInteger(MQL_TESTER)) return true;
   datetime srv = TimeTradeServer();
   datetime gmt = TimeGMT();
   datetime model = ServerToUTC(srv);
   long diff = (long)model - (long)gmt;
   if(MathAbs(diff) > 300)
     {
      Log(StringFormat("ERROR: server-time model disagrees with TimeGMT() by %d s. "
                       "Fix InpServerTZMode / offset inputs. New entries disabled.", (int)diff));
      return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
//| Input parsing / validation                                       |
//+------------------------------------------------------------------+
bool ParseHHMM(const string s, int &minutes)
  {
   string p[];
   if(StringSplit(s, ':', p) != 2) return false;
   int h = (int)StringToInteger(p[0]);
   int m = (int)StringToInteger(p[1]);
   if(h < 0 || h > 23 || m < 0 || m > 59) return false;
   minutes = h * 60 + m;
   return true;
  }

bool ValidateInputs()
  {
   if(!ParseHHMM(InpRangeStartEAT, g_startMin) || !ParseHHMM(InpRangeEndEAT, g_endMin) ||
      !ParseHHMM(InpTradingStartEAT, g_tradeStartMin) || !ParseHHMM(InpLastEntryEAT, g_lastEntryMin))
     { Print("[RangeMSS] INIT ERROR: time inputs must be HH:MM"); return false; }
   if(g_endMin - g_startMin != 90 || (g_startMin % 15) != 0)
     { Print("[RangeMSS] INIT ERROR: range must be exactly six M15 candles (end-start = 90 min, start on a 15-min boundary)"); return false; }
   if(g_tradeStartMin < g_endMin)
     { Print("[RangeMSS] INIT ERROR: trading start must be >= range end"); return false; }
   if(g_lastEntryMin <= g_tradeStartMin)
     { Print("[RangeMSS] INIT ERROR: last entry must be after trading start"); return false; }
   if(InpSwingStrength < 1 || InpSwingStrength > 10)
     { Print("[RangeMSS] INIT ERROR: SwingStrength must be 1..10"); return false; }
   if(InpSwingLookbackBars < 10 || InpSwingLookbackBars > 2000)
     { Print("[RangeMSS] INIT ERROR: SwingLookbackBars must be 10..2000"); return false; }
   if(MathAbs(InpRewardRiskRatio - 2.0) > 1e-9 && MathAbs(InpRewardRiskRatio - 3.0) > 1e-9)
     { Print("[RangeMSS] INIT ERROR: RewardRiskRatio must be 2.0 or 3.0"); return false; }
   if(InpRiskPercent <= 0 || InpRiskPercent > 10)
     { Print("[RangeMSS] INIT ERROR: RiskPercent must be in (0,10]"); return false; }
   if(InpRetestTolerancePoints < 0 || InpStopBufferPoints < 0)
     { Print("[RangeMSS] INIT ERROR: tolerance/buffer must be >= 0"); return false; }
   if(InpMaxSpreadPoints <= 0 || InpMaxDeviationPoints < 0)
     { Print("[RangeMSS] INIT ERROR: invalid spread/deviation"); return false; }
   if(InpSetupExpiryMinutes < 3 || InpSetupExpiryMinutes > 120)
     { Print("[RangeMSS] INIT ERROR: SetupExpiryMinutes must be 3..120"); return false; }
   if(InpMaxOrderRetries < 0 || InpMaxOrderRetries > 5 || InpMaxEntryDelaySeconds < 0)
     { Print("[RangeMSS] INIT ERROR: invalid retry/delay inputs"); return false; }
   if(InpServerStdOffsetHours < -12 || InpServerStdOffsetHours > 14 ||
      InpServerDstOffsetHours < -12 || InpServerDstOffsetHours > 14)
     { Print("[RangeMSS] INIT ERROR: server offset out of range"); return false; }
   return true;
  }

//+------------------------------------------------------------------+
//| Price / volume helpers                                           |
//+------------------------------------------------------------------+
double TickSz() { return (g_tick > 0 ? g_tick : g_point); }
double RoundTick(double p) { return NormalizeDouble(MathRound(p / TickSz()) * TickSz(), g_digits); }
double FloorTick(double p) { return NormalizeDouble(MathFloor(p / TickSz() + 1e-9) * TickSz(), g_digits); }
double CeilTick(double p)  { return NormalizeDouble(MathCeil(p / TickSz() - 1e-9) * TickSz(), g_digits); }

int VolumeDigits(double step)
  {
   int d = 0;
   while(d < 8 && MathAbs(step * MathPow(10, d) - MathRound(step * MathPow(10, d))) > 1e-9) d++;
   return d;
  }

bool IsHedging()
  {
   return ((ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE) == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING);
  }

//+------------------------------------------------------------------+
//| History availability                                             |
//+------------------------------------------------------------------+
bool HistoryReady()
  {
   if(!(bool)SeriesInfoInteger(g_sym, PERIOD_M15, SERIES_SYNCHRONIZED)) return false;
   if(!(bool)SeriesInfoInteger(g_sym, PERIOD_M3, SERIES_SYNCHRONIZED)) return false;
   long b15 = SeriesInfoInteger(g_sym, PERIOD_M15, SERIES_BARS_COUNT);
   long b3  = SeriesInfoInteger(g_sym, PERIOD_M3, SERIES_BARS_COUNT);
   return (b15 >= 20 && b3 >= 50);
  }

//+------------------------------------------------------------------+
//| Positions / history                                              |
//+------------------------------------------------------------------+
bool FindOurPosition(ulong &ident, double &vol, double &price, long &type)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != g_sym) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      ident = (ulong)PositionGetInteger(POSITION_IDENTIFIER);
      vol   = PositionGetDouble(POSITION_VOLUME);
      price = PositionGetDouble(POSITION_PRICE_OPEN);
      type  = PositionGetInteger(POSITION_TYPE);
      return true;
     }
   return false;
  }

bool PositionBlocksEntry()
  {
   bool hedge = IsHedging();
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != g_sym) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) == InpMagicNumber) return true;
      if(!hedge) return true;   // netting: any position on the symbol would be modified
     }
   return false;
  }

bool TradeTakenToday()
  {
   datetime from = EATToServer(g_dayEAT);
   if(!HistorySelect(from, TimeCurrent() + 60)) return false;
   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
     {
      ulong tk = HistoryDealGetTicket(i);
      if(tk == 0) continue;
      if((ulong)HistoryDealGetInteger(tk, DEAL_MAGIC) != InpMagicNumber) continue;
      if(HistoryDealGetString(tk, DEAL_SYMBOL) != g_sym) continue;
      if(HistoryDealGetInteger(tk, DEAL_ENTRY) == DEAL_ENTRY_IN) return true;
     }
   return false;
  }

string ReasonStr(long r)
  {
   if(r == DEAL_REASON_SL) return "STOP-LOSS";
   if(r == DEAL_REASON_TP) return "TAKE-PROFIT";
   if(r == DEAL_REASON_SO) return "STOP-OUT";
   return "OTHER(" + IntegerToString((int)r) + ")";
  }

void CheckTrackedPosition()
  {
   if(g_trackPosId == 0) return;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if((ulong)PositionGetInteger(POSITION_IDENTIFIER) == g_trackPosId) return; // still open
     }
   ulong pid = g_trackPosId;
   g_trackPosId = 0;
   if(HistorySelectByPosition(pid))
     {
      int total = HistoryDealsTotal();
      for(int i = 0; i < total; i++)
        {
         ulong tk = HistoryDealGetTicket(i);
         if(tk == 0) continue;
         long en = HistoryDealGetInteger(tk, DEAL_ENTRY);
         if(en == DEAL_ENTRY_OUT || en == DEAL_ENTRY_OUT_BY || en == DEAL_ENTRY_INOUT)
            Log(StringFormat("Position %I64u closed by %s at %s, profit %.2f swap %.2f commission %.2f",
                             pid, ReasonStr(HistoryDealGetInteger(tk, DEAL_REASON)),
                             DoubleToString(HistoryDealGetDouble(tk, DEAL_PRICE), g_digits),
                             HistoryDealGetDouble(tk, DEAL_PROFIT), HistoryDealGetDouble(tk, DEAL_SWAP),
                             HistoryDealGetDouble(tk, DEAL_COMMISSION)));
        }
     }
   if(g_state == ST_TRADE_ACTIVE) SetState(ST_DAY_COMPLETE, "trade closed");
  }

//+------------------------------------------------------------------+
//| Persistence (live/demo only; tester global vars are not durable) |
//+------------------------------------------------------------------+
string GVKey(const string suffix) { return StringFormat("XRM_%I64u_%s_%s", InpMagicNumber, g_sym, suffix); }

void PersistDone()
  {
   if(!InpUsePersistence || MQLInfoInteger(MQL_TESTER)) return;
   GlobalVariableSet(GVKey("day"), (double)g_dayEAT);
   GlobalVariableSet(GVKey("done"), 1.0);
  }

bool PersistedDone()
  {
   if(!InpUsePersistence || MQLInfoInteger(MQL_TESTER)) return false;
   if(!GlobalVariableCheck(GVKey("day")) || !GlobalVariableCheck(GVKey("done"))) return false;
   return ((datetime)GlobalVariableGet(GVKey("day")) == g_dayEAT && GlobalVariableGet(GVKey("done")) > 0.5);
  }

//+------------------------------------------------------------------+
//| State machine                                                    |
//+------------------------------------------------------------------+
bool TransitionAllowed(ENUM_STATE f, ENUM_STATE t)
  {
   switch(f)
     {
      case ST_WAITING_FOR_RANGE:              return (t == ST_RANGE_READY || t == ST_DAY_COMPLETE);
      case ST_RANGE_READY:                    return (t == ST_WAITING_FOR_M15_BREAKOUT || t == ST_DAY_COMPLETE);
      case ST_WAITING_FOR_M15_BREAKOUT:       return (t == ST_WAITING_FOR_M3_STRUCTURE_SHIFT || t == ST_DAY_COMPLETE);
      case ST_WAITING_FOR_M3_STRUCTURE_SHIFT: return (t == ST_WAITING_FOR_RETEST || t == ST_SETUP_EXPIRED || t == ST_DAY_COMPLETE);
      case ST_WAITING_FOR_RETEST:             return (t == ST_WAITING_FOR_CONFIRMATION || t == ST_SETUP_EXPIRED || t == ST_DAY_COMPLETE);
      case ST_WAITING_FOR_CONFIRMATION:       return (t == ST_TRADE_ACTIVE || t == ST_SETUP_EXPIRED || t == ST_DAY_COMPLETE);
      case ST_TRADE_ACTIVE:                   return (t == ST_DAY_COMPLETE);
      case ST_SETUP_EXPIRED:                  return (t == ST_DAY_COMPLETE);
      case ST_DAY_COMPLETE:                   return false;
     }
   return false;
  }

bool SetState(ENUM_STATE ns, const string note)
  {
   if(ns == g_state) return true;
   if(!TransitionAllowed(g_state, ns))
     {
      Log("ERROR: illegal state transition " + StateName(g_state) + " -> " + StateName(ns));
      return false;
     }
   Log("STATE " + StateName(g_state) + " -> " + StateName(ns) + (note != "" ? " (" + note + ")" : ""));
   g_state = ns;
   if(note != "") g_dayNote = note;
   if(ns == ST_DAY_COMPLETE) PersistDone();
   Refresh();
   return true;
  }

void FinishDay(const string reason)
  {
   Log("Day complete: " + reason);
   SetState(ST_DAY_COMPLETE, reason);
  }

void ExpireSetup(const string reason)
  {
   g_cntExpired++;
   Log("SETUP EXPIRED: " + reason);
   SetState(ST_SETUP_EXPIRED, reason);
   SetState(ST_DAY_COMPLETE, reason);
  }

bool InM3Stage()
  {
   return (g_state == ST_WAITING_FOR_M3_STRUCTURE_SHIFT || g_state == ST_WAITING_FOR_RETEST ||
           g_state == ST_WAITING_FOR_CONFIRMATION);
  }

//+------------------------------------------------------------------+
//| Day reset                                                        |
//+------------------------------------------------------------------+
void ResetDay(datetime dayEAT)
  {
   g_dayEAT = dayEAT;
   g_rangeStartSrv = EATToServer(dayEAT + g_startMin * 60);
   g_rangeEndSrv   = EATToServer(dayEAT + g_endMin * 60);
   g_tradeStartSrv = EATToServer(dayEAT + g_tradeStartMin * 60);
   g_lastEntrySrv  = EATToServer(dayEAT + g_lastEntryMin * 60);

   g_rangeFinal = false; g_rangeHigh = 0; g_rangeLow = 0;
   g_dir = 0; g_boTime = 0; g_boClose = 0; g_boPrice = 0;
   g_expiry = 0; g_deadline = 0;
   g_lastM15Proc = 0; g_lastM3Proc = 0; g_lastM3Bar0 = 0;
   g_brokenLevel = 0; g_brokenSwingTime = 0; g_mssTime = 0;
   g_retHigh = 0; g_retLow = 0; g_retTime = 0;
   g_confirmed = false; g_confTime = 0; g_confHigh = 0; g_confLow = 0;
   g_entryPrice = 0; g_sl = 0; g_tp = 0;
   g_dayNote = "";
   g_state = ST_WAITING_FOR_RANGE;
   g_cntDays++;

   if(InpShowChart && !MQLInfoInteger(MQL_OPTIMIZATION)) ObjectsDeleteAll(0, OBJP);

   g_tzOK = VerifyServerOffset();
   g_tradeTakenToday = TradeTakenToday();
   Log("New trading day (EAT) " + TimeToString(dayEAT, TIME_DATE) + " | range " +
       TimeToString(g_rangeStartSrv, TIME_DATE | TIME_MINUTES) + " - " +
       TimeToString(g_rangeEndSrv, TIME_DATE | TIME_MINUTES) + " srv time");

   if(g_tradeTakenToday)
     {
      ulong id; double v, p; long ty;
      if(FindOurPosition(id, v, p, ty))
        {
         g_trackPosId = id;
         g_state = ST_TRADE_ACTIVE;
         g_dayNote = "recovered open position after restart";
         Log("Recovered open position " + IntegerToString((long)id) + "; state TRADE_ACTIVE");
        }
      else
        {
         g_state = ST_DAY_COMPLETE;
         g_dayNote = "trade already taken today";
         Log("Trade already taken today; state DAY_COMPLETE");
        }
     }
   else if(PersistedDone())
     {
      g_state = ST_DAY_COMPLETE;
      g_dayNote = "restored DAY_COMPLETE from persistence";
      Log("Restored DAY_COMPLETE from persisted state");
     }
   Refresh();
  }

//+------------------------------------------------------------------+
//| Stage 1: range construction                                      |
//+------------------------------------------------------------------+
void TryBuildRange()
  {
   datetime now = TimeCurrent();
   if(now < g_rangeEndSrv) return;
   if(!HistoryReady()) { Warn("M3/M15 history not ready"); return; }
   if(!g_tzOK)
     {
      FinishDay("server-time offset not verified; trading disabled for the day");
      return;
     }

   MqlRates r[];
   ArraySetAsSeries(r, false);
   int n = CopyRates(g_sym, PERIOD_M15, g_rangeStartSrv, g_rangeEndSrv - 1, r);
   bool ok = (n == 6);
   if(ok)
      for(int i = 0; i < 6; i++)
         if(r[i].time != g_rangeStartSrv + i * M15SEC) ok = false;

   if(!ok)
     {
      if(now > g_rangeEndSrv + M15SEC)
        {
         g_cntNoRange++;
         Log(StringFormat("ERROR: range incomplete (%d of 6 expected M15 candles found).", n));
         FinishDay("range candles missing");
        }
      return;
     }

   g_rangeHigh = r[0].high;
   g_rangeLow  = r[0].low;
   for(int i = 1; i < 6; i++)
     {
      if(r[i].high > g_rangeHigh) g_rangeHigh = r[i].high;
      if(r[i].low  < g_rangeLow)  g_rangeLow  = r[i].low;
     }
   g_rangeFinal = true;
   Log(StringFormat("RANGE FINAL: High %s Low %s Width %s",
                    DoubleToString(g_rangeHigh, g_digits), DoubleToString(g_rangeLow, g_digits),
                    DoubleToString(g_rangeHigh - g_rangeLow, g_digits)));
   SetState(ST_RANGE_READY, "range finalized");
   SetState(ST_WAITING_FOR_M15_BREAKOUT, "monitoring M15 closes");
  }

//+------------------------------------------------------------------+
//| Stage 2: M15 breakout                                            |
//+------------------------------------------------------------------+
void ProcessM15()
  {
   datetime now = TimeCurrent();
   if(!HistoryReady()) { Warn("M3/M15 history not ready"); return; }

   MqlRates r[];
   ArraySetAsSeries(r, false);
   datetime from = (g_lastM15Proc > 0 ? g_lastM15Proc + M15SEC : g_rangeEndSrv);
   if(from <= now)
     {
      int n = CopyRates(g_sym, PERIOD_M15, from, now, r);
      if(n > 0)
        {
         for(int i = 0; i < n; i++)
           {
            if(r[i].time + M15SEC > now) break;      // still forming
            g_lastM15Proc = r[i].time;
            if(r[i].time < g_rangeEndSrv) continue;
            datetime cclose = r[i].time + M15SEC;
            if(cclose < g_tradeStartSrv) continue;
            if(cclose > g_lastEntrySrv)
              {
               g_cntNoBreakout++;
               FinishDay("no M15 breakout before last permitted entry time");
               return;
              }
            int dir = 0;
            if(r[i].close > g_rangeHigh) dir = 1;
            else if(r[i].close < g_rangeLow) dir = -1;
            if(dir != 0)
              {
               g_dir = dir;
               g_boTime = r[i].time;
               g_boClose = cclose;
               g_boPrice = r[i].close;
               g_expiry = g_boClose + InpSetupExpiryMinutes * 60;
               g_deadline = (g_expiry < g_lastEntrySrv ? g_expiry : g_lastEntrySrv);
               g_lastM3Proc = 0;
               g_lastM3Bar0 = 0;
               g_cntBreakouts++;
               Log(StringFormat("M15 BREAKOUT %s: candle %s close %s (range %s / %s). Expiry %s srv",
                                (dir > 0 ? "BULLISH" : "BEARISH"),
                                TimeToString(g_boTime, TIME_DATE | TIME_MINUTES),
                                DoubleToString(g_boPrice, g_digits),
                                DoubleToString(g_rangeLow, g_digits), DoubleToString(g_rangeHigh, g_digits),
                                TimeToString(g_deadline, TIME_DATE | TIME_MINUTES | TIME_SECONDS)));
               SetState(ST_WAITING_FOR_M3_STRUCTURE_SHIFT, "M15 breakout confirmed");
               return;
              }
           }
        }
     }
   // No qualifying breakout yet. Close the day if the entry window has passed.
   if(now > g_lastEntrySrv + M15SEC && g_state == ST_WAITING_FOR_M15_BREAKOUT)
     {
      g_cntNoBreakout++;
      FinishDay("no M15 breakout before last permitted entry time");
     }
  }

//+------------------------------------------------------------------+
//| Swing detection on a chronological array                         |
//+------------------------------------------------------------------+
bool IsSwingAt(const MqlRates &a[], int c, bool isHigh)
  {
   int S = InpSwingStrength;
   if(c - S < 0 || c + S >= ArraySize(a)) return false;
   for(int d = 1; d <= S; d++)
     {
      if(isHigh)
        { if(!(a[c].high > a[c - d].high && a[c].high > a[c + d].high)) return false; }
      else
        { if(!(a[c].low < a[c - d].low && a[c].low < a[c + d].low)) return false; }
     }
   return true;
  }

// Latest swing usable by candle k: centre c <= k-1-S so that every right-side
// candle (c+S <= k-1) had fully closed BEFORE candle k closed.
bool FindLatestSwing(const MqlRates &a[], int k, bool isHigh, double &price, datetime &t)
  {
   int S = InpSwingStrength;
   int cMax = k - 1 - S;
   int cMin = MathMax(S, cMax - InpSwingLookbackBars);
   for(int c = cMax; c >= cMin; c--)
     {
      if(IsSwingAt(a, c, isHigh))
        {
         price = (isHigh ? a[c].high : a[c].low);
         t = a[c].time;
         return true;
        }
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Stage 3: M3 structure shift / retest / confirmation              |
//+------------------------------------------------------------------+
void EvaluateM3Bar(const MqlRates &a[], int k)
  {
   datetime cclose = a[k].time + M3SEC;
   if(cclose > g_deadline)
     {
      string why = (g_deadline == g_lastEntrySrv && g_lastEntrySrv <= g_expiry) ?
                   "permitted entry window ended before sequence completed" :
                   "30-minute setup expiry reached before sequence completed";
      ExpireSetup(why + " (stage " + StateName(g_state) + ")");
      return;
     }

   if(InpVerboseLog)
     {
      int c = k - InpSwingStrength;
      if(IsSwingAt(a, c, true))
         Log("Swing HIGH confirmed: " + DoubleToString(a[c].high, g_digits) + " @ " + TimeToString(a[c].time, TIME_DATE | TIME_MINUTES));
      if(IsSwingAt(a, c, false))
         Log("Swing LOW confirmed: " + DoubleToString(a[c].low, g_digits) + " @ " + TimeToString(a[c].time, TIME_DATE | TIME_MINUTES));
     }

   double tol = InpRetestTolerancePoints * g_point;

   if(g_state == ST_WAITING_FOR_M3_STRUCTURE_SHIFT)
     {
      double lvl; datetime lt;
      bool found = FindLatestSwing(a, k, (g_dir > 0), lvl, lt);
      if(found && ((g_dir > 0 && a[k].close > lvl) || (g_dir < 0 && a[k].close < lvl)))
        {
         g_brokenLevel = lvl;
         g_brokenSwingTime = lt;
         g_mssTime = a[k].time;
         Log(StringFormat("M3 MSS/CHoCH %s: candle %s closed %s through swing %s (swing time %s)",
                          (g_dir > 0 ? "BULLISH" : "BEARISH"),
                          TimeToString(a[k].time, TIME_DATE | TIME_MINUTES),
                          DoubleToString(a[k].close, g_digits), DoubleToString(lvl, g_digits),
                          TimeToString(lt, TIME_DATE | TIME_MINUTES)));
         SetState(ST_WAITING_FOR_RETEST, "structure broken");
        }
      return;
     }

   if(g_state == ST_WAITING_FOR_RETEST)
     {
      double zl = g_brokenLevel - tol, zh = g_brokenLevel + tol;
      if(a[k].low <= zh && a[k].high >= zl)
        {
         g_retHigh = a[k].high;
         g_retLow = a[k].low;
         g_retTime = a[k].time;
         Log(StringFormat("RETEST detected: candle %s range %s-%s intersects zone %s-%s",
                          TimeToString(a[k].time, TIME_DATE | TIME_MINUTES),
                          DoubleToString(a[k].low, g_digits), DoubleToString(a[k].high, g_digits),
                          DoubleToString(zl, g_digits), DoubleToString(zh, g_digits)));
         SetState(ST_WAITING_FOR_CONFIRMATION, "retest detected");
        }
      return;
     }

   if(g_state == ST_WAITING_FOR_CONFIRMATION)
     {
      bool ok;
      if(g_dir > 0) ok = (a[k].close > a[k].open && a[k].close > g_brokenLevel);
      else          ok = (a[k].close < a[k].open && a[k].close < g_brokenLevel);
      if(ok)
        {
         g_confirmed = true;
         g_confTime = a[k].time;
         g_confHigh = a[k].high;
         g_confLow = a[k].low;
         Log(StringFormat("CONFIRMATION candle %s O %s H %s L %s C %s",
                          TimeToString(a[k].time, TIME_DATE | TIME_MINUTES),
                          DoubleToString(a[k].open, g_digits), DoubleToString(a[k].high, g_digits),
                          DoubleToString(a[k].low, g_digits), DoubleToString(a[k].close, g_digits)));
        }
     }
  }

// returns true when the closed-bar scan completed (so the new-bar marker may advance)
bool ProcessNewM3Bars()
  {
   datetime now = TimeCurrent();
   int S = InpSwingStrength;
   MqlRates a[];
   ArraySetAsSeries(a, false);
   datetime from = g_boClose - (datetime)((InpSwingLookbackBars + 2 * S + 5) * M3SEC);
   int n = CopyRates(g_sym, PERIOD_M3, from, now, a);
   if(n < 2 * S + 3) { Warn("insufficient M3 bars copied (" + IntegerToString(n) + ")"); return false; }

   int last = n - 1;
   while(last >= 0 && a[last].time + M3SEC > now) last--;

   for(int k = 0; k <= last; k++)
     {
      if(a[k].time < g_boClose) continue;      // only candles AFTER the M15 breakout close
      if(a[k].time <= g_lastM3Proc) continue;  // each candle evaluated once
      g_lastM3Proc = a[k].time;
      EvaluateM3Bar(a, k);
      if(!InM3Stage()) return true;
      if(g_confirmed) return true;
     }
   return true;
  }

//+------------------------------------------------------------------+
//| Order execution                                                  |
//+------------------------------------------------------------------+
ENUM_ENTRY_RESULT Rej(const string why)
  {
   g_cntRejected++;
   Log(StringFormat("TRADE REJECTED: %s | spread %.1f pts", why, g_lastSpread));
   return ENTRY_REJECTED;
  }

void RecordTrade(ulong pid, double risk, int dir)
  {
   int n = ArraySize(g_recPos);
   ArrayResize(g_recPos, n + 1);
   ArrayResize(g_recRisk, n + 1);
   ArrayResize(g_recDir, n + 1);
   g_recPos[n] = pid; g_recRisk[n] = risk; g_recDir[n] = dir;
  }

ENUM_ENTRY_RESULT TryEnter(int attempt)
  {
   MqlTick tk;
   if(!SymbolInfoTick(g_sym, tk) || tk.bid <= 0 || tk.ask <= 0 || tk.ask < tk.bid)
      return Rej("no valid tick/quote");
   double bid = tk.bid, ask = tk.ask;
   g_lastSpread = (ask - bid) / g_point;
   Log(StringFormat("Entry attempt %d: bid %s ask %s spread %.1f pts", attempt + 1,
                    DoubleToString(bid, g_digits), DoubleToString(ask, g_digits), g_lastSpread));

   if(g_lastSpread > InpMaxSpreadPoints)
      return Rej(StringFormat("spread %.1f exceeds max %.1f", g_lastSpread, InpMaxSpreadPoints));

   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED) ||
      !AccountInfoInteger(ACCOUNT_TRADE_ALLOWED) || !AccountInfoInteger(ACCOUNT_TRADE_EXPERT))
      return Rej("trading not allowed (terminal/EA/account)");
   if(SymbolInfoInteger(g_sym, SYMBOL_TRADE_MODE) != SYMBOL_TRADE_MODE_FULL)
      return Rej("symbol trade mode is not FULL");

   if(PositionBlocksEntry()) return Rej("an open position already blocks a new entry");
   if(TradeTakenToday())     return Rej("duplicate protection: trade already taken today");

   bool buy = (g_dir > 0);
   double entry = (buy ? ask : bid);
   double buf = InpStopBufferPoints * g_point;
   double sl = buy ? (MathMin(g_retLow, g_confLow) - buf) : (MathMax(g_retHigh, g_confHigh) + buf);
   sl = buy ? FloorTick(sl) : CeilTick(sl);
   double risk = buy ? (entry - sl) : (sl - entry);
   if(risk <= 0) return Rej("executable price is already beyond the stop-loss level");
   double tp = RoundTick(buy ? entry + InpRewardRiskRatio * risk : entry - InpRewardRiskRatio * risk);

   double stopsLvl = (double)SymbolInfoInteger(g_sym, SYMBOL_TRADE_STOPS_LEVEL);
   double frzLvl   = (double)SymbolInfoInteger(g_sym, SYMBOL_TRADE_FREEZE_LEVEL);
   double minDist  = MathMax(stopsLvl, frzLvl) * g_point;
   if(buy)
     {
      if(bid - sl < minDist) return Rej("stop-loss closer than broker min stop/freeze distance");
      if(tp - bid < minDist) return Rej("take-profit closer than broker min stop/freeze distance");
     }
   else
     {
      if(sl - ask < minDist) return Rej("stop-loss closer than broker min stop/freeze distance");
      if(ask - tp < minDist) return Rej("take-profit closer than broker min stop/freeze distance");
     }
   if(tp <= 0 || sl <= 0) return Rej("invalid stop/target price");

   // --- position sizing from tick value / tick size
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney = equity * InpRiskPercent / 100.0;
   double tickVal = SymbolInfoDouble(g_sym, SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tickVal <= 0) tickVal = SymbolInfoDouble(g_sym, SYMBOL_TRADE_TICK_VALUE);
   if(TickSz() <= 0 || tickVal <= 0) return Rej("invalid tick size/value");
   double lossPerLot = risk / TickSz() * tickVal;
   double p = 0;
   if(OrderCalcProfit(buy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, g_sym, 1.0, entry, sl, p) && p < 0)
      lossPerLot = MathMax(lossPerLot, -p);   // conservative of the two estimates
   if(lossPerLot <= 0) return Rej("could not compute loss per lot");

   double step = SymbolInfoDouble(g_sym, SYMBOL_VOLUME_STEP);
   double vmin = SymbolInfoDouble(g_sym, SYMBOL_VOLUME_MIN);
   double vmax = SymbolInfoDouble(g_sym, SYMBOL_VOLUME_MAX);
   if(step <= 0) return Rej("invalid volume step");
   double vol = riskMoney / lossPerLot;
   vol = MathFloor(vol / step + 1e-9) * step;
   if(vol < vmin - 1e-12)
      return Rej(StringFormat("minimum volume %.2f would exceed risk limit (risk money %.2f, loss/lot %.2f)",
                              vmin, riskMoney, lossPerLot));
   if(vol > vmax) vol = vmax;
   vol = NormalizeDouble(vol, VolumeDigits(step));
   double actualRisk = vol * lossPerLot;

   double margin = 0;
   if(!OrderCalcMargin(buy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, g_sym, vol, entry, margin))
      return Rej("OrderCalcMargin failed, error " + IntegerToString(GetLastError()));
   if(margin > AccountInfoDouble(ACCOUNT_MARGIN_FREE))
      return Rej(StringFormat("insufficient free margin (need %.2f, free %.2f)", margin, AccountInfoDouble(ACCOUNT_MARGIN_FREE)));

   Log(StringFormat("Sending %s %.2f lots | entry~%s SL %s TP %s | risk %.2f (%.2f%%) | R:R %.1f",
                    (buy ? "BUY" : "SELL"), vol, DoubleToString(entry, g_digits),
                    DoubleToString(sl, g_digits), DoubleToString(tp, g_digits),
                    actualRisk, InpRiskPercent, InpRewardRiskRatio));

   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetDeviationInPoints(InpMaxDeviationPoints);
   g_trade.SetTypeFillingBySymbol(g_sym);
   ResetLastError();
   bool sent = buy ? g_trade.Buy(vol, g_sym, 0.0, sl, tp, "RangeMSS") : g_trade.Sell(vol, g_sym, 0.0, sl, tp, "RangeMSS");
   uint rc = g_trade.ResultRetcode();
   Log(StringFormat("Order result: sent=%s retcode=%u (%s) deal=%I64u order=%I64u vol=%.2f price=%s",
                    (sent ? "true" : "false"), rc, g_trade.ResultRetcodeDescription(),
                    g_trade.ResultDeal(), g_trade.ResultOrder(), g_trade.ResultVolume(),
                    DoubleToString(g_trade.ResultPrice(), g_digits)));

   // verify real position state regardless of the return code (guards against timeouts)
   ulong id; double pv, pp; long pt;
   bool havePos = FindOurPosition(id, pv, pp, pt);
   bool doneCode = (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_DONE_PARTIAL);

   if(havePos)
     {
      if(rc == TRADE_RETCODE_DONE_PARTIAL || (pv + 1e-9 < vol))
         Log(StringFormat("WARNING: partial fill %.2f of %.2f lots", pv, vol));
      g_trackPosId = id;
      g_tradeTakenToday = true;
      g_cntTrades++;
      g_entryPrice = pp; g_sl = sl; g_tp = tp;
      RecordTrade(id, (pv > 0 ? pv : vol) * lossPerLot, g_dir);
      Log(StringFormat("TRADE FILLED: position %I64u %s %.2f @ %s (expected %s, slippage %.1f pts) SL %s TP %s",
                       id, (buy ? "BUY" : "SELL"), pv, DoubleToString(pp, g_digits),
                       DoubleToString(entry, g_digits), MathAbs(pp - entry) / g_point,
                       DoubleToString(sl, g_digits), DoubleToString(tp, g_digits)));
      SetState(ST_TRADE_ACTIVE, "order filled");
      return ENTRY_FILLED;
     }
   if(doneCode && TradeTakenToday())
     {
      // filled and already closed (e.g. instant SL/TP) - never re-enter
      g_tradeTakenToday = true;
      g_cntTrades++;
      Log("Order executed and position already closed; marking day complete");
      SetState(ST_TRADE_ACTIVE, "filled and closed");
      SetState(ST_DAY_COMPLETE, "filled and closed");
      return ENTRY_FILLED;
     }
   if(rc == TRADE_RETCODE_REQUOTE || rc == TRADE_RETCODE_PRICE_CHANGED ||
      rc == TRADE_RETCODE_PRICE_OFF || rc == TRADE_RETCODE_TIMEOUT)
     {
      if(attempt < InpMaxOrderRetries)
        {
         Log("Retryable result; re-validating with fresh prices");
         return ENTRY_RETRY;
        }
     }
   return Rej(StringFormat("order failed: retcode %u (%s)", rc, g_trade.ResultRetcodeDescription()));
  }

void DoEntryFlow()
  {
   datetime now = TimeCurrent();
   datetime confClose = g_confTime + M3SEC;
   if(now - confClose > InpMaxEntryDelaySeconds)
     {
      Rej(StringFormat("confirmation is stale (%d s old)", (int)(now - confClose)));
      FinishDay("stale confirmation; setup cancelled");
      return;
     }
   if(!VerifyServerOffset())
     {
      g_tzOK = false;
      Rej("server-time offset could not be verified");
      FinishDay("time-zone verification failed");
      return;
     }
   ENUM_ENTRY_RESULT r = ENTRY_RETRY;
   for(int a = 0; a <= InpMaxOrderRetries && r == ENTRY_RETRY; a++)
      r = TryEnter(a);
   if(r == ENTRY_RETRY) r = Rej("retries exhausted");
   if(r == ENTRY_REJECTED) FinishDay("entry rejected; setup cancelled");
  }

void ProcessM3AndEntry()
  {
   datetime now = TimeCurrent();
   if(!HistoryReady()) { Warn("M3/M15 history not ready"); return; }
   datetime cur0 = iTime(g_sym, PERIOD_M3, 0);
   if(cur0 == 0) { Warn("M3 series unavailable"); return; }

   if(cur0 != g_lastM3Bar0)
     {
      if(ProcessNewM3Bars()) g_lastM3Bar0 = cur0;
      if(!InM3Stage()) return;
     }
   if(g_confirmed && g_state == ST_WAITING_FOR_CONFIRMATION)
     {
      DoEntryFlow();
      return;
     }
   if(InM3Stage() && now > g_deadline)
      ExpireSetup(StringFormat("deadline %s passed before sequence completed (stage %s)",
                               TimeToString(g_deadline, TIME_DATE | TIME_MINUTES | TIME_SECONDS), StateName(g_state)));
  }

//+------------------------------------------------------------------+
//| Chart display                                                    |
//+------------------------------------------------------------------+
void Seg(const string name, datetime t1, datetime t2, double price, color clr, ENUM_LINE_STYLE st, const string txt)
  {
   string n = OBJP + name;
   if(ObjectFind(0, n) < 0) ObjectCreate(0, n, OBJ_TREND, 0, t1, price, t2, price);
   else { ObjectMove(0, n, 0, t1, price); ObjectMove(0, n, 1, t2, price); }
   ObjectSetInteger(0, n, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, n, OBJPROP_STYLE, st);
   ObjectSetInteger(0, n, OBJPROP_RAY_RIGHT, false);
   ObjectSetInteger(0, n, OBJPROP_WIDTH, 1);
   string tn = n + "_t";
   if(ObjectFind(0, tn) < 0) ObjectCreate(0, tn, OBJ_TEXT, 0, t2, price);
   else ObjectMove(0, tn, 0, t2, price);
   ObjectSetString(0, tn, OBJPROP_TEXT, txt + " " + DoubleToString(price, g_digits));
   ObjectSetInteger(0, tn, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, tn, OBJPROP_FONTSIZE, 8);
   ObjectSetInteger(0, tn, OBJPROP_ANCHOR, ANCHOR_LEFT_LOWER);
  }

void Box(const string name, datetime t1, double p1, datetime t2, double p2, color clr)
  {
   string n = OBJP + name;
   if(ObjectFind(0, n) < 0) ObjectCreate(0, n, OBJ_RECTANGLE, 0, t1, p1, t2, p2);
   else { ObjectMove(0, n, 0, t1, p1); ObjectMove(0, n, 1, t2, p2); }
   ObjectSetInteger(0, n, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, n, OBJPROP_FILL, false);
  }

void Refresh()
  {
   if(!InpShowChart || MQLInfoInteger(MQL_OPTIMIZATION)) return;
   if(g_rangeFinal)
     {
      Box("RangeBox", g_rangeStartSrv, g_rangeHigh, g_rangeEndSrv, g_rangeLow, clrDodgerBlue);
      Seg("RangeHigh", g_rangeStartSrv, g_lastEntrySrv, g_rangeHigh, clrDodgerBlue, STYLE_SOLID, "Range High");
      Seg("RangeLow",  g_rangeStartSrv, g_lastEntrySrv, g_rangeLow,  clrDodgerBlue, STYLE_SOLID, "Range Low");
     }
   if(g_dir != 0 && g_boTime > 0)
     {
      string n = OBJP + "Breakout";
      if(ObjectFind(0, n) < 0) ObjectCreate(0, n, OBJ_TEXT, 0, g_boTime, g_boPrice);
      ObjectSetString(0, n, OBJPROP_TEXT, (g_dir > 0 ? "M15 BULL BREAKOUT" : "M15 BEAR BREAKOUT"));
      ObjectSetInteger(0, n, OBJPROP_COLOR, (g_dir > 0 ? clrLime : clrRed));
      ObjectSetInteger(0, n, OBJPROP_FONTSIZE, 8);
     }
   if(g_brokenLevel > 0)
     {
      Seg("Broken", g_mssTime, g_deadline, g_brokenLevel, clrOrange, STYLE_DASH, "Broken M3 level");
      double tol = InpRetestTolerancePoints * g_point;
      if(g_retTime > 0)
         Box("RetestZone", g_retTime, g_brokenLevel + tol, g_deadline, g_brokenLevel - tol, clrGold);
     }
   if(g_entryPrice > 0)
     {
      datetime t2 = g_deadline + 3600;
      Seg("Entry", g_confTime, t2, g_entryPrice, clrWhite, STYLE_SOLID, "Entry");
      Seg("SL", g_confTime, t2, g_sl, clrRed, STYLE_SOLID, "SL");
      Seg("TP", g_confTime, t2, g_tp, clrLime, STYLE_SOLID, "TP");
     }
   string s = "XAUUSD Range + M3 MSS EA v1.00\n";
   s += "EAT day: " + TimeToString(g_dayEAT, TIME_DATE) + "\n";
   s += "State: " + StateName(g_state) + (g_dayNote != "" ? " (" + g_dayNote + ")" : "") + "\n";
   if(g_rangeFinal)
      s += "Range: " + DoubleToString(g_rangeLow, g_digits) + " - " + DoubleToString(g_rangeHigh, g_digits) + "\n";
   s += "Breakout: " + (g_dir > 0 ? "BULLISH " : (g_dir < 0 ? "BEARISH " : "none")) +
        (g_boTime > 0 ? TimeToString(g_boTime, TIME_MINUTES) + " srv" : "") + "\n";
   if(g_brokenLevel > 0) s += "Broken level: " + DoubleToString(g_brokenLevel, g_digits) + "\n";
   if(g_entryPrice > 0)
      s += "Entry " + DoubleToString(g_entryPrice, g_digits) + " SL " + DoubleToString(g_sl, g_digits) +
           " TP " + DoubleToString(g_tp, g_digits) + "\n";
   s += "Daily trade: " + (g_tradeTakenToday ? "TAKEN" : "none") + " | TZ ok: " + (g_tzOK ? "yes" : "NO") + "\n";
   Comment(s);
  }

//+------------------------------------------------------------------+
//| Init / deinit / tick                                             |
//+------------------------------------------------------------------+
int OnInit()
  {
   g_initOK = false;
   if(!ValidateInputs()) return INIT_PARAMETERS_INCORRECT;

   g_sym = (StringLen(InpSymbol) > 0 ? InpSymbol : _Symbol);
   if(MQLInfoInteger(MQL_TESTER) && g_sym != _Symbol)
     {
      Print("[RangeMSS] Tester symbol is ", _Symbol, "; InpSymbol '", g_sym, "' ignored in the tester.");
      g_sym = _Symbol;
     }
   if(!SymbolSelect(g_sym, true))
     { Print("[RangeMSS] INIT ERROR: symbol not found: ", g_sym); return INIT_FAILED; }
   if(g_sym != _Symbol)
      Print("[RangeMSS] WARNING: chart symbol (", _Symbol, ") differs from trading symbol (", g_sym, ")");

   g_point  = SymbolInfoDouble(g_sym, SYMBOL_POINT);
   g_tick   = SymbolInfoDouble(g_sym, SYMBOL_TRADE_TICK_SIZE);
   g_digits = (int)SymbolInfoInteger(g_sym, SYMBOL_DIGITS);
   if(g_point <= 0) { Print("[RangeMSS] INIT ERROR: invalid point size"); return INIT_FAILED; }

   PrintFormat("[RangeMSS] Symbol %s digits %d point %s tick size %s | retest tol %.0f pts = %s price | stop buffer %.0f pts = %s price",
               g_sym, g_digits, DoubleToString(g_point, g_digits + 2), DoubleToString(g_tick, g_digits + 2),
               InpRetestTolerancePoints, DoubleToString(InpRetestTolerancePoints * g_point, g_digits),
               InpStopBufferPoints, DoubleToString(InpStopBufferPoints * g_point, g_digits));
   PrintFormat("[RangeMSS] Account mode: %s | server tz model: %s (std %+d h, dst %+d h)",
               (IsHedging() ? "HEDGING" : "NETTING/EXCHANGE"),
               (InpServerTZMode == TZ_FIXED_OFFSET ? "FIXED" : "US-DST"),
               InpServerStdOffsetHours, InpServerDstOffsetHours);

   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetDeviationInPoints(InpMaxDeviationPoints);
   g_trade.SetTypeFillingBySymbol(g_sym);

   g_dayEAT = 0;
   g_state = ST_WAITING_FOR_RANGE;
   g_initOK = true;
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   if(!MQLInfoInteger(MQL_TESTER)) PrintCounters();
   if(InpShowChart && !MQLInfoInteger(MQL_OPTIMIZATION))
     {
      ObjectsDeleteAll(0, OBJP);
      Comment("");
     }
  }

void PrintCounters()
  {
   PrintFormat("[RangeMSS] SUMMARY days=%d noRange=%d noBreakout=%d breakouts=%d expired=%d rejected=%d trades=%d",
               g_cntDays, g_cntNoRange, g_cntNoBreakout, g_cntBreakouts, g_cntExpired, g_cntRejected, g_cntTrades);
  }

void OnTick()
  {
   if(!g_initOK) return;
   datetime now = TimeCurrent();
   datetime eatNow = ServerToEAT(now);
   datetime day = eatNow - (datetime)((long)eatNow % 86400);
   if(day != g_dayEAT) ResetDay(day);

   CheckTrackedPosition();

   switch(g_state)
     {
      case ST_WAITING_FOR_RANGE:          TryBuildRange(); break;
      case ST_WAITING_FOR_M15_BREAKOUT:   ProcessM15();    break;
      case ST_WAITING_FOR_M3_STRUCTURE_SHIFT:
      case ST_WAITING_FOR_RETEST:
      case ST_WAITING_FOR_CONFIRMATION:   ProcessM3AndEntry(); break;
      default: break;
     }
  }

//+------------------------------------------------------------------+
//| Strategy Tester report: R-multiples, long/short, by year         |
//+------------------------------------------------------------------+
double OnTester()
  {
   PrintCounters();
   if(!HistorySelect(0, TimeCurrent() + 60)) return 0.0;
   ulong  pos[]; double net[]; datetime ct[]; bool closed[];
   int cnt = 0;
   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
     {
      ulong tk = HistoryDealGetTicket(i);
      if(tk == 0) continue;
      if((ulong)HistoryDealGetInteger(tk, DEAL_MAGIC) != InpMagicNumber) continue;
      long en = HistoryDealGetInteger(tk, DEAL_ENTRY);
      if(en != DEAL_ENTRY_IN && en != DEAL_ENTRY_OUT && en != DEAL_ENTRY_OUT_BY && en != DEAL_ENTRY_INOUT) continue;
      ulong pid = (ulong)HistoryDealGetInteger(tk, DEAL_POSITION_ID);
      int idx = -1;
      for(int j = 0; j < cnt; j++) if(pos[j] == pid) { idx = j; break; }
      if(idx < 0)
        {
         idx = cnt++;
         ArrayResize(pos, cnt); ArrayResize(net, cnt); ArrayResize(ct, cnt); ArrayResize(closed, cnt);
         pos[idx] = pid; net[idx] = 0; ct[idx] = 0; closed[idx] = false;
        }
      net[idx] += HistoryDealGetDouble(tk, DEAL_PROFIT) + HistoryDealGetDouble(tk, DEAL_SWAP) +
                  HistoryDealGetDouble(tk, DEAL_COMMISSION) + HistoryDealGetDouble(tk, DEAL_FEE);
      if(en != DEAL_ENTRY_IN) { closed[idx] = true; ct[idx] = (datetime)HistoryDealGetInteger(tk, DEAL_TIME); }
     }

   int trades = 0, wins = 0, nl = 0, ns = 0;
   double gp = 0, gl = 0, sumR = 0, netAll = 0, netL = 0, netS = 0;
   int years[]; double yNet[]; int yN = 0;
   for(int j = 0; j < cnt; j++)
     {
      if(!closed[j]) continue;
      double risk = 0; int dir = 0;
      for(int r = 0; r < ArraySize(g_recPos); r++)
         if(g_recPos[r] == pos[j]) { risk = g_recRisk[r]; dir = g_recDir[r]; break; }
      trades++;
      netAll += net[j];
      if(net[j] > 0) { wins++; gp += net[j]; } else gl += -net[j];
      if(risk > 0) sumR += net[j] / risk;
      if(dir > 0) { nl++; netL += net[j]; } else if(dir < 0) { ns++; netS += net[j]; }
      MqlDateTime d; TimeToStruct(ct[j], d);
      int yi = -1;
      for(int y = 0; y < yN; y++) if(years[y] == d.year) { yi = y; break; }
      if(yi < 0) { yi = yN++; ArrayResize(years, yN); ArrayResize(yNet, yN); years[yi] = d.year; yNet[yi] = 0; }
      yNet[yi] += net[j];
     }
   double pf = (gl > 0 ? gp / gl : (gp > 0 ? 999.0 : 0.0));
   double expR = (trades > 0 ? sumR / trades : 0.0);
   PrintFormat("[RangeMSS] TESTER REPORT: trades=%d winRate=%.1f%% net(after costs)=%.2f PF=%.2f expectancy=%.3fR",
               trades, (trades > 0 ? 100.0 * wins / trades : 0.0), netAll, pf, expR);
   PrintFormat("[RangeMSS] TESTER REPORT: avgWin=%.2f avgLoss=%.2f | long n=%d net=%.2f | short n=%d net=%.2f",
               (wins > 0 ? gp / wins : 0.0), (trades - wins > 0 ? gl / (trades - wins) : 0.0), nl, netL, ns, netS);
   for(int y = 0; y < yN; y++)
      PrintFormat("[RangeMSS] TESTER REPORT: year %d net=%.2f", years[y], yNet[y]);
   Print("[RangeMSS] Max equity drawdown: see the Strategy Tester report (equity DD).");
   return expR;
  }
//+------------------------------------------------------------------+
