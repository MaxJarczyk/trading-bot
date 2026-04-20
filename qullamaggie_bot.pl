#!/usr/bin/perl
# =============================================================================
#  Qullamaggie Full Market Scanner — Flags & Episodic Pivots
#  Scans all active NYSE + NASDAQ + AMEX stocks daily
#  Account : Alpaca Paper Account 3
#  Schedule: 09:35 ET weekdays
#
#  Pipeline:
#    1. Load/cache full US stock universe (~3-4k symbols)
#    2. Batch-snapshot pre-screen (price $5-$500, vol > 300k)
#    3. Fetch SPY bars for RS + market health check
#    4. Batch-fetch 260-day bars for all candidates
#    5. Detect EP + Flag signals — ALL 10 filters applied per stock:
#         Trend  : EMA 20, SMA 50, SMA 150, Stage 2 (SMA150 rising)
#         Quality: RS vs SPY uptrend, ADR ≥ 3%, within 30% of 52w high
#         Setup  : Gap %, Volume ×avg, Pole %, Flag depth, Vol dry-up
#    6. Rank: EP first (catalyst), then FLAG by score
#    7. Execute top signals up to MAX_CONCURRENT position slots
#    8. Bracket orders handle stop-loss + take-profit automatically
# =============================================================================
use strict;
use warnings;
use JSON::PP;
use POSIX       qw(strftime floor);
use List::Util  qw(sum min max);

# ─── Paths ────────────────────────────────────────────────────────────────────
# BASE_DIR: local machine default; Railway sets TRADING_BASE_DIR or falls back to /tmp
my $BASE_DIR   = $ENV{TRADING_BASE_DIR} || "/Users/maximilianjarczyk/Documents/Trading";
my $LOG_FILE   = $ENV{LOG_FILE}  || "$BASE_DIR/qullamaggie_bot.log";
my $ENV_FILE   = "$BASE_DIR/.env";
my $CACHE_DIR  = "$BASE_DIR/.cache";
my $TRADE_URL  = "https://paper-api.alpaca.markets/v2";
my $DATA_URL   = "https://data.alpaca.markets/v2";
# curl: prefer system PATH on Railway (Docker), fall back to macOS absolute path
my $CURL       = -x "/usr/bin/curl" ? "/usr/bin/curl" : "curl";

# Cache dir: fall back to /tmp if base dir isn't writable (Railway ephemeral FS)
unless (-d $CACHE_DIR || mkdir $CACHE_DIR) {
    $CACHE_DIR = "/tmp/.qull_cache";
    mkdir $CACHE_DIR unless -d $CACHE_DIR;
}
my $UNIV_FILE = "$CACHE_DIR/qull_universe.json";

# ─── Load config — .env file (local) merged with process env (Railway) ────────
# Process environment (Railway-injected secrets) takes precedence over .env file.
my %CFG = %ENV;   # start with system env — includes Railway-injected vars
if (-f $ENV_FILE) {
    open my $ef, '<', $ENV_FILE or warn "Cannot open $ENV_FILE: $!";
    while ($ef && ($_ = <$ef>)) {
        chomp; next if /^\s*[#\s]/ or !/=/;
        /^([^=]+)=(.*)$/ and $CFG{$1} //= $2;  # file value only if not already set
    }
    close $ef if $ef;
}

my $API_KEY    = $CFG{ALPACA_API_KEY_3}    or die "Missing ALPACA_API_KEY_3 (set in .env or Railway env vars)";
my $API_SECRET = $CFG{ALPACA_SECRET_KEY_3} or die "Missing ALPACA_SECRET_KEY_3 (set in .env or Railway env vars)";
my $BUDGET     = $CFG{QULL_BUDGET_USD}    || 100_000;
my $MAX_POS    = $CFG{QULL_MAX_POS_USD}   || 10_000;
my $RISK_F     = $CFG{QULL_RISK_PCT}      || 0.02;

# ─── Explicit watchlist (100 momentum names) — when set, skips full-universe fetch
my $DEFAULT_QULL_WATCHLIST = join(',',
    qw(NVDA AMD AVGO MRVL MU AMAT LRCX KLAC ASML TSM ARM SMCI DELL ANET CRDO CRCL ALMU AAOI FN LITE),
    qw(META AAPL MSFT GOOGL AMZN NFLX ORCL CRM ADBE NOW),
    qw(PLTR SNOW DDOG NET CRWD ZS PANW FTNT OKTA MDB HUBS MNDY WDAY INTU VEEV),
    qw(SHOP SQ PYPL COIN HOOD SOFI AFRM NU SPGI MSCI),
    qw(UBER DASH ABNB BKNG EXPE RBLX DUOL APP TTD RDDT),
    qw(IONQ RGTI QBTS BBAI SOUN AI IREN MARA RIOT TMDX),
    qw(DXCM ISRG EXAS NTRA REGN VRTX BIIB MRNA AXSM CELH),
    qw(TSLA RIVN LCID CVNA GLXY),
    qw(BIRD HIMS NBIS AXTI ASTS RKLB HROW HPS FORM LWLG),
);
my @QULL_WATCHLIST = split /,/, ($CFG{QULL_WATCHLIST} || $DEFAULT_QULL_WATCHLIST);

# ─── Strategy parameters ──────────────────────────────────────────────────────
# Universe
my @EXCHANGES      = ('NYSE', 'NASDAQ', 'AMEX');
my $UNIVERSE_TTL   = 7 * 24 * 3600;   # refresh universe weekly

# Pre-screen
my $MIN_PRICE      = 5.0;
my $MAX_PRICE      = 500.0;
my $MIN_PREV_VOL   = 300_000;

# Episodic Pivot
my $EP_MIN_GAP     = 5.0;    # min gap-up %
my $EP_VOL_MULT    = 2.5;    # volume vs 20d avg

# Flag Breakout
my $POLE_MIN_PCT   = 15.0;   # min pole move %
my $POLE_BARS      = 25;     # bars to detect pole
my $FLAG_BARS      = 15;     # consolidation window
my $FLAG_MAX_DEPTH = 12.0;   # max flag depth %
my $FLAG_VOL_DRY   = 0.80;   # vol dry-up threshold
my $FLAG_BO_MULT   = 1.5;    # breakout volume multiplier

# Shared
my $VOL_MA_LEN     = 20;     # volume moving average period
my $ATR_PERIOD     = 14;     # ATR period
my $ATR_SL_BUF     = 0.5;    # extra ATR below low for stop

# Qullamaggie quality filters (mirrors Pine Script)
my $MIN_ADR_PCT    = 3.0;    # min average daily range % (low-vol stocks excluded)
my $MAX_FROM_52HI  = 30.0;   # max % below 52-week high
my $RS_PERIOD      = 20;     # bars for RS vs SPY trending check
my $SMA150_TREND   = 10;     # SMA150 must be above its value N bars ago (Stage 2)

# Portfolio
my $RR_RATIO       = 3.0;    # risk : reward target
my $MAX_CONCURRENT = 5;      # max simultaneous positions
my $BARS_NEEDED    = 260;    # daily bars per symbol (covers SMA150 + 52w high + RS)
my $BATCH_SIZE     = 50;     # symbols per API call (smaller batches for larger payload)

# SPY close prices by date — populated at runtime by load_spy_data(), used in detect_signals()
my %SPY_CLOSES;

# ─── Logging ──────────────────────────────────────────────────────────────────
sub log_msg {
    my ($lvl, $msg) = @_;
    my $ts   = strftime("%Y-%m-%d %H:%M:%S", localtime);
    my $line = "[$ts][$lvl] $msg\n";
    print $line;   # stdout always works (Railway captures this as logs)
    if (open my $fh, '>>', $LOG_FILE) { print $fh $line; close $fh; }
}
sub log_info  { log_msg("INFO ", $_[0]) }
sub log_warn  { log_msg("WARN ", $_[0]) }
sub log_error { log_msg("ERROR", $_[0]) }
sub log_trade { log_msg("TRADE", $_[0]) }
sub log_scan  { log_msg("SCAN ", $_[0]) }

# ─── Alpaca REST ──────────────────────────────────────────────────────────────
sub _curl_get {
    my ($url) = @_;
    my $out = `/usr/bin/curl -s -X GET -H "APCA-API-KEY-ID: $API_KEY" -H "APCA-API-SECRET-KEY: $API_SECRET" --max-time 30 "$url" 2>&1`;
    return eval { decode_json($out) };
}

sub _curl_post {
    my ($url, $body) = @_;
    my $json = encode_json($body);
    # Write body to temp file to avoid shell quoting issues
    my $tmp = "/tmp/qull_order_$$.json";
    open my $fh, '>', $tmp or die "Cannot write tmp: $!";
    print $fh $json; close $fh;
    my $out = `/usr/bin/curl -s -X POST -H "APCA-API-KEY-ID: $API_KEY" -H "APCA-API-SECRET-KEY: $API_SECRET" -H "Content-Type: application/json" --data-binary \@$tmp --max-time 30 "$url" 2>&1`;
    unlink $tmp;
    return eval { decode_json($out) };
}

sub _curl_patch {
    my ($url, $body) = @_;
    my $json = encode_json($body);
    my $tmp = "/tmp/qull_patch_$$.json";
    open my $fh, '>', $tmp or die "Cannot write tmp: $!";
    print $fh $json; close $fh;
    my $out = `/usr/bin/curl -s -X PATCH -H "APCA-API-KEY-ID: $API_KEY" -H "APCA-API-SECRET-KEY: $API_SECRET" -H "Content-Type: application/json" --data-binary \@$tmp --max-time 30 "$url" 2>&1`;
    unlink $tmp;
    return eval { decode_json($out) };
}

sub trade_get   { _curl_get("$TRADE_URL$_[0]") }
sub trade_post  { _curl_post("$TRADE_URL$_[0]", $_[1]) }
sub trade_patch { _curl_patch("$TRADE_URL$_[0]", $_[1]) }
sub data_get    { _curl_get("$DATA_URL$_[0]") }

# ─── Universe ─────────────────────────────────────────────────────────────────
sub fetch_universe {
    log_info("Fetching fresh universe from Alpaca assets API...");
    my %ex_ok = map { $_ => 1 } @EXCHANGES;
    my @symbols;

    my $assets = trade_get("/assets?status=active&asset_class=us_equity");
    unless (ref $assets eq 'ARRAY') {
        log_error("Failed to fetch assets");
        return [];
    }

    for my $a (@$assets) {
        next unless ($a->{tradable}  // 0);
        next unless ($a->{status}   // '') eq 'active';
        next unless  $ex_ok{$a->{exchange} // ''};
        my $sym = $a->{symbol} // '';
        next if $sym =~ /[.\-\/]/ or length($sym) > 5 or length($sym) < 1;
        push @symbols, $sym;
    }

    log_info("Universe fetched: " . scalar(@symbols) . " symbols");
    return \@symbols;
}

sub load_universe {
    if (-f $UNIV_FILE && (time() - (stat($UNIV_FILE))[9]) < $UNIVERSE_TTL) {
        open my $fh, '<', $UNIV_FILE or die;
        my $data = decode_json(do { local $/; <$fh> });
        close $fh;
        my $n = scalar @{$data->{symbols}};
        log_info("Universe loaded from cache: $n symbols (age " .
                 int((time() - $data->{ts}) / 3600) . "h)");
        return $data->{symbols};
    }
    my $syms = fetch_universe();
    open my $fh, '>', $UNIV_FILE or die "Cannot write $UNIV_FILE: $!";
    print $fh encode_json({ symbols => $syms, ts => time() });
    close $fh;
    return $syms;
}

# ─── Batch snapshots ──────────────────────────────────────────────────────────
sub batch_snapshots {
    my (@syms) = @_;
    my %snaps;
    my @batches;
    while (@syms) { push @batches, [splice(@syms, 0, $BATCH_SIZE)] }

    log_info("Fetching snapshots: " . scalar(@batches) . " batches of $BATCH_SIZE...");
    my $done = 0;
    for my $b (@batches) {
        my $list = join(',', @$b);
        my $r = data_get("/stocks/snapshots?symbols=$list&feed=iex");
        if (ref $r eq 'HASH') {
            $snaps{$_} = $r->{$_} for keys %$r;
        }
        $done++;
        log_info("  Snapshots: $done/" . scalar(@batches) . " batches done") if $done % 10 == 0;
    }
    log_info("Snapshots received: " . scalar(keys %snaps) . " symbols");
    return %snaps;
}

# ─── Pre-screen ───────────────────────────────────────────────────────────────
sub pre_screen {
    my (%snaps) = @_;
    my @out;
    for my $sym (keys %snaps) {
        my $s   = $snaps{$sym} // {};
        my $db  = $s->{dailyBar}     // {};
        my $pdb = $s->{prevDailyBar} // {};

        my $price    = $db->{c}  // 0;
        my $prev_vol = $pdb->{v} // 0;

        next if $price    < $MIN_PRICE or $price > $MAX_PRICE;
        next if $prev_vol < $MIN_PREV_VOL;

        push @out, {
            symbol     => $sym,
            price      => $price,
            open       => $db->{o}  // $price,
            high       => $db->{h}  // $price,
            low        => $db->{l}  // $price,
            today_vol  => $db->{v}  // 0,
            prev_close => $pdb->{c} // $price,
            prev_vol   => $prev_vol,
        };
    }
    return @out;
}

# ─── Batch bars ───────────────────────────────────────────────────────────────
sub fetch_bars_batch {
    my ($syms_ref) = @_;
    my @syms = @$syms_ref;
    my %bars;
    my @batches;
    while (@syms) { push @batches, [splice(@syms, 0, $BATCH_SIZE)] }

    log_info("Fetching bars: " . scalar(@batches) . " batches for " .
             scalar(@$syms_ref) . " symbols...");

    my $done = 0;
    for my $b (@batches) {
        my $list = join(',', @$b);
        my $r = data_get("/stocks/bars?symbols=$list&timeframe=1Day" .
                         "&limit=$BARS_NEEDED&adjustment=raw&feed=iex");
        if (ref $r eq 'HASH' && ref $r->{bars} eq 'HASH') {
            $bars{$_} = $r->{bars}{$_} for keys %{$r->{bars}};
        }
        $done++;
        log_info("  Bars: $done/" . scalar(@batches) . " batches done") if $done % 5 == 0;
    }
    log_info("Bars received: " . scalar(keys %bars) . " symbols");
    return %bars;
}

# ─── Math helpers ─────────────────────────────────────────────────────────────
sub avg { @_ ? sum(@_) / scalar(@_) : 0 }

sub atr {
    my ($bars_ref, $n) = @_;
    my @b = @$bars_ref;
    my @tr;
    for my $i (1 .. $#b) {
        push @tr, max($b[$i]{h} - $b[$i]{l},
                      abs($b[$i]{h} - $b[$i-1]{c}),
                      abs($b[$i]{l} - $b[$i-1]{c}));
    }
    return 0 unless @tr >= $n;
    return avg(@tr[-$n .. -1]);
}

# ─── Signal detection — all 10 Qullamaggie filters ──────────────────────────
sub detect_signals {
    my ($sym, $bars_ref) = @_;
    my @b  = @$bars_ref;
    my $nb = scalar @b;
    return () if $nb < $POLE_BARS + $FLAG_BARS + 10;
    return () if $nb < $VOL_MA_LEN + 2;

    my $today = $b[-1];
    my $prev  = $b[-2];
    my $close = $today->{c};

    # ── Volume average (20d excl today) ──────────────────────────────────────
    my @vol20   = map { $b[$_]{v} } ($nb - $VOL_MA_LEN - 1) .. ($nb - 2);
    my $vol_avg = avg(@vol20);
    return () unless $vol_avg > 0;

    my $atr_val = atr(\@b, $ATR_PERIOD);
    return () unless $atr_val > 0;

    # ── Filter 1 & 2: EMA 20 + SMA 50 ───────────────────────────────────────
    my @c20  = map { $b[$_]{c} } ($nb - 21) .. ($nb - 2);
    my @c50  = map { $b[$_]{c} } ($nb - 51) .. ($nb - 2);
    my $ema20 = @c20 >= 20 ? avg(@c20) : 0;
    my $sma50 = @c50 >= 50 ? avg(@c50) : 0;
    return () if $ema20 > 0 && $close < $ema20;
    return () if $sma50 > 0 && $close < $sma50;

    # ── Filter 3 & 4: SMA 150 + Stage 2 (SMA150 rising) ─────────────────────
    my $sma150 = 0;
    my $sma150_old = 0;
    if ($nb >= 152) {
        my @c150 = map { $b[$_]{c} } ($nb - 151) .. ($nb - 2);
        $sma150  = avg(@c150);
        my @c150_old = map { $b[$_]{c} } ($nb - 151 - $SMA150_TREND) .. ($nb - 2 - $SMA150_TREND);
        $sma150_old  = @c150_old >= 150 ? avg(@c150_old) : 0;
    }
    return () if $sma150 > 0 && $close < $sma150;           # below SMA150
    return () if $sma150 > 0 && $sma150_old > 0
              && $sma150 < $sma150_old;                      # Stage 2: SMA150 not rising

    # ── Filter 5: Relative Strength vs SPY uptrend ───────────────────────────
    if (%SPY_CLOSES) {
        my @rs_vals;
        for my $bar (@b[($nb - $RS_PERIOD - 1) .. ($nb - 1)]) {
            my $date  = substr($bar->{t}, 0, 10);
            my $spy_c = $SPY_CLOSES{$date} // 0;
            push @rs_vals, ($bar->{c} / $spy_c) if $spy_c > 0;
        }
        if (@rs_vals >= $RS_PERIOD) {
            my $rs_now  = $rs_vals[-1];
            my $rs_then = $rs_vals[0];
            return () if $rs_now <= $rs_then;   # RS line falling vs SPY
        }
    }

    # ── Filter 6: ADR% ≥ 3% ─────────────────────────────────────────────────
    my @adr_bars = @b[($nb - 21) .. ($nb - 2)];
    my $adr_pct  = avg(map { $_->{c} > 0 ? ($_->{h} - $_->{l}) / $_->{c} * 100 : 0 } @adr_bars);
    return () if $adr_pct < $MIN_ADR_PCT;

    # ── Filter 7: Within 30% of 52-week high ─────────────────────────────────
    my $start_52 = $nb >= 253 ? $nb - 253 : 0;
    my $wk52_hi  = max(map { $_->{h} } @b[$start_52 .. ($nb - 1)]);
    my $dist_hi  = $wk52_hi > 0 ? ($wk52_hi - $close) / $wk52_hi * 100 : 100;
    return () if $dist_hi > $MAX_FROM_52HI;

    # ── All 7 quality filters passed — now check setups ──────────────────────
    my @signals;

    # ── Filter 8-9: Episodic Pivot (gap + volume) ─────────────────────────────
    if ($prev->{c} > 0) {
        my $gap_pct  = ($today->{o} - $prev->{c}) / $prev->{c} * 100.0;
        my $vol_mult = $today->{v} / $vol_avg;
        my $rng      = $today->{h} - $today->{l};
        my $str_cls  = $rng > 0 ? ($today->{c} - $today->{l}) / $rng : 0;

        if ($gap_pct >= $EP_MIN_GAP && $vol_mult >= $EP_VOL_MULT && $str_cls >= 0.50) {
            my $sl   = min($today->{l}, $today->{o}) - $atr_val * $ATR_SL_BUF;
            my $risk = $close - $sl;
            if ($risk > 0) {
                push @signals, {
                    symbol   => $sym,
                    type     => 'EP',
                    score    => $gap_pct * $vol_mult,
                    entry    => $close,
                    stop     => $sl,
                    target   => $close + $risk * $RR_RATIO,
                    gap_pct  => $gap_pct,
                    vol_mult => $vol_mult,
                    adr_pct  => $adr_pct,
                    dist_hi  => $dist_hi,
                };
            }
        }
    }

    # ── Filters 10-12: Flag Breakout (pole + depth + vol dry-up) ─────────────
    my $total_lb  = $POLE_BARS + $FLAG_BARS;
    if ($nb >= $total_lb + 5) {
        my @pole_zone = @b[($nb - $total_lb - 1) .. ($nb - $FLAG_BARS - 2)];
        if (@pole_zone >= 5) {
            my $pole_lo  = min(map { $_->{l} } @pole_zone);
            my $pole_hi  = max(map { $_->{h} } @pole_zone);
            my $pole_pct = $pole_lo > 0 ? ($pole_hi - $pole_lo) / $pole_lo * 100.0 : 0;

            my @flag_zone = @b[($nb - $FLAG_BARS - 1) .. ($nb - 2)];
            if (@flag_zone >= 3) {
                my $flag_hi  = max(map { $_->{h} } @flag_zone);
                my $flag_lo  = min(map { $_->{l} } @flag_zone);
                my $flag_dep = $flag_hi > 0 ? ($flag_hi - $flag_lo) / $flag_hi * 100.0 : 999;
                my $fvol_avg = avg(map { $_->{v} } @flag_zone);
                my $vol_dry  = $fvol_avg <= $vol_avg * $FLAG_VOL_DRY;
                my $bo_vol   = $today->{v} / $vol_avg;

                if ($pole_pct >= $POLE_MIN_PCT && $flag_dep <= $FLAG_MAX_DEPTH &&
                    $vol_dry  && $close > $flag_hi && $bo_vol >= $FLAG_BO_MULT) {
                    my $sl   = $flag_lo - $atr_val * $ATR_SL_BUF;
                    my $risk = $close - $sl;
                    if ($risk > 0) {
                        push @signals, {
                            symbol   => $sym,
                            type     => 'FLAG',
                            score    => $pole_pct / $flag_dep * $bo_vol,
                            entry    => $close,
                            stop     => $sl,
                            target   => $close + $risk * $RR_RATIO,
                            pole_pct => $pole_pct,
                            flag_dep => $flag_dep,
                            vol_mult => $bo_vol,
                            adr_pct  => $adr_pct,
                            dist_hi  => $dist_hi,
                        };
                    }
                }
            }
        }
    }

    return @signals;
}

# ─── SPY: market health + RS benchmark ───────────────────────────────────────
sub load_spy_data {
    log_info("Fetching SPY bars for market health + RS benchmark...");
    my $r;
    for my $feed (qw(iex sip)) {
        $r = data_get("/stocks/SPY/bars?timeframe=1Day&limit=270&feed=$feed");
        if (ref $r eq 'HASH' && ref $r->{bars} eq 'ARRAY' && @{$r->{bars}} >= 50) {
            log_info("SPY bars fetched via feed=$feed (" . scalar(@{$r->{bars}}) . " bars)");
            last;
        }
        log_warn("SPY feed=$feed returned insufficient data; trying next feed");
        $r = undef;
    }
    unless ($r) {
        log_warn("Could not fetch SPY bars from any feed — skipping RS and market filter");
        return 1;   # default healthy
    }

    my @bars = @{$r->{bars}};

    # Build date-keyed close hash for RS calculation in detect_signals
    for my $b (@bars) {
        my $date = substr($b->{t}, 0, 10);
        $SPY_CLOSES{$date} = $b->{c};
    }

    # Market health: SPY above 50 SMA
    my @closes = map { $_->{c} } @bars;
    my $sma50  = avg(@closes[-50 .. -1]);
    my $price  = $closes[-1];

    if ($price < $sma50) {
        log_warn(sprintf("SPY %.2f < SMA50 %.2f — bear market: FLAG scan disabled", $price, $sma50));
        return 0;
    }
    log_info(sprintf("SPY healthy: %.2f > SMA50 %.2f | RS benchmark loaded (%d dates)",
                     $price, $sma50, scalar keys %SPY_CLOSES));
    return 1;
}

# ─── Portfolio helpers ────────────────────────────────────────────────────────
sub get_account {
    trade_get('/account');
}

sub get_positions {
    my $p = trade_get('/positions');
    return ref $p eq 'ARRAY' ? { map { $_->{symbol} => $_ } @$p } : {};
}

sub is_market_open {
    my $c = trade_get('/clock');
    return ($c && $c->{is_open}) ? 1 : 0;
}

# ─── Trailing stop management ────────────────────────────────────────────────
sub manage_trailing_stops {
    my (%held) = @_;
    return unless %held;

    my $TRAIL_MULT = 2.0;   # ATR multiplier
    my $BE_TRIGGER = 1.0;   # move to breakeven when gain >= 1R

    log_info("Managing trailing stops for " . scalar(keys %held) . " position(s)...");

    # Find open stop-sell orders (legs of bracket orders)
    my $orders = trade_get('/orders?status=open&limit=500');
    unless (ref $orders eq 'ARRAY') {
        log_warn("Could not fetch open orders — skipping trailing stop update");
        return;
    }

    my %stop_orders;
    for my $o (@$orders) {
        next unless ($o->{type} // '') eq 'stop';
        next unless ($o->{side} // '') eq 'sell';
        my $sym = $o->{symbol} // '';
        next unless $sym && exists $held{$sym};
        $stop_orders{$sym} = { id => $o->{id}, stop_price => $o->{stop_price} + 0 };
    }

    # Fetch recent bars for ATR + peak close
    my $list = join(',', keys %held);
    my $r = data_get("/stocks/bars?symbols=$list&timeframe=1Day&limit=60&adjustment=raw&feed=iex");
    my %recent_bars;
    if (ref $r eq 'HASH' && ref $r->{bars} eq 'HASH') {
        %recent_bars = %{$r->{bars}};
    }

    for my $sym (sort keys %held) {
        my $pos = $held{$sym};
        my $so  = $stop_orders{$sym};

        unless ($so) {
            log_warn("$sym: no open stop order found — bracket may have already triggered");
            next;
        }

        my $entry     = $pos->{avg_entry_price} + 0;
        my $cur_stop  = $so->{stop_price};
        my $init_risk = $entry - $cur_stop;

        if ($init_risk <= 0) {
            log_warn("$sym: stop \$$cur_stop >= entry \$$entry — skipping");
            next;
        }

        my $bars_ref = $recent_bars{$sym} // [];
        unless (@$bars_ref >= $ATR_PERIOD + 1) {
            log_warn("$sym: not enough bars for ATR — skipping trailing stop");
            next;
        }

        my $atr_val   = atr($bars_ref, $ATR_PERIOD);
        my $cur_close = $bars_ref->[-1]{c};
        my $peak_cl   = max(map { $_->{c} } @$bars_ref);

        # Breakeven floor activates when gain >= 1R
        my $be_floor  = ($cur_close - $entry >= $init_risk * $BE_TRIGGER)
                        ? $entry : $cur_stop;

        my $atr_trail = $peak_cl - $atr_val * $TRAIL_MULT;
        my $new_stop  = max($be_floor, $atr_trail, $cur_stop);
        $new_stop     = $cur_close * 0.999 if $new_stop >= $cur_close;  # must stay below price
        $new_stop     = sprintf("%.2f", $new_stop) + 0;

        if ($new_stop > $cur_stop + 0.005) {
            my $resp = trade_patch("/orders/$so->{id}", { stop_price => $new_stop });
            if ($resp && $resp->{id}) {
                log_trade(sprintf("TRAIL UPDATED %s: SL \$%.2f → \$%.2f  ATR=%.2f peak=%.2f",
                                  $sym, $cur_stop, $new_stop, $atr_val, $peak_cl));
            } else {
                my $err = $resp ? ($resp->{message} // encode_json($resp)) : "no response";
                log_warn("TRAIL PATCH failed $sym: $err");
            }
        } else {
            log_info(sprintf("TRAIL %s: SL \$%.2f unchanged (candidate=\$%.2f)",
                             $sym, $cur_stop, $new_stop));
        }
    }
}

# ─── Order ────────────────────────────────────────────────────────────────────
sub calc_qty {
    my ($equity, $entry, $stop) = @_;
    my $dist = $entry - $stop;
    return 0 unless $dist > 0;
    my $by_risk = floor($equity * $RISK_F / $dist);
    my $by_cap  = floor($MAX_POS / $entry);
    my $qty     = min($by_risk, $by_cap);
    return $qty > 0 ? $qty : 0;
}

sub place_bracket {
    my (%sig) = @_;
    my $sl   = sprintf("%.2f", $sig{stop});
    # Wide TP (5× risk) — trailing stop is primary exit, this is a safety ceiling
    my $risk = $sig{entry} - $sig{stop};
    my $tp   = sprintf("%.2f", $sig{entry} + $risk * 5.0);

    my $resp = trade_post('/orders', {
        symbol        => $sig{symbol},
        qty           => "$sig{qty}",
        side          => 'buy',
        type          => 'market',
        time_in_force => 'day',
        order_class   => 'bracket',
        stop_loss     => { stop_price  => $sl + 0 },
        take_profit   => { limit_price => $tp + 0 },
    });

    if ($resp && $resp->{id}) {
        log_trade(sprintf("PLACED [%s] %s x%d | ~\$%.2f SL=\$%s TP=\$%s | score=%.2f",
                          $sig{type}, $sig{symbol}, $sig{qty},
                          $sig{entry}, $sl, $tp, $sig{score}));
        return 1;
    }
    my $err = $resp ? ($resp->{message} // encode_json($resp)) : "no response";
    log_error("Order FAILED $sig{symbol}: $err");
    return 0;
}

# ═══════════════════════════════════════════════════════════════════════════════
#  MAIN
# ═══════════════════════════════════════════════════════════════════════════════
log_info("=" x 72);
log_info("Qullamaggie Full Market Scanner — " . strftime("%Y-%m-%d %H:%M", localtime));

# 1. Market open?
unless (is_market_open()) {
    log_warn("Market closed — exiting");
    exit 0;
}

# 2. Account check
my $acct = get_account();
unless ($acct && ($acct->{status} // '') eq 'ACTIVE') {
    log_error("Account not active: " . encode_json($acct // {}));
    exit 1;
}
my $equity  = $acct->{equity}        + 0;
my $bp      = $acct->{buying_power}  + 0;
log_info(sprintf("Account: equity=\$%.2f  buying_power=\$%.2f", $equity, $bp));

# 3. Position slots
my %held     = %{ get_positions() };
my $pos_cnt  = scalar keys %held;
my $slots    = $MAX_CONCURRENT - $pos_cnt;
log_info("Positions: $pos_cnt open / $MAX_CONCURRENT max — $slots slot(s) available");

if ($pos_cnt > 0) {
    for my $sym (sort keys %held) {
        my $p = $held{$sym};
        log_info(sprintf("  HELD %s x%s @ \$%s | uPnL \$%.2f",
                         $sym, $p->{qty}, $p->{avg_entry_price},
                         $p->{unrealized_pl} + 0));
    }
    manage_trailing_stops(%held);
}

if ($slots <= 0) {
    log_info("All position slots full — no new entries today");
    exit 0;
}

if ($bp < $MAX_POS) {
    log_warn(sprintf("Buying power \$%.2f < MAX_POS \$%.2f — skipping", $bp, $MAX_POS));
    exit 0;
}

# 4. SPY data: market health + RS benchmark
my $bull_market = load_spy_data();

# 5. Universe — prefer explicit watchlist (QULL_WATCHLIST env), fall back to
#    full assets API when the variable is literally set to "ALL".
my $universe;
if (uc($CFG{QULL_WATCHLIST} // '') eq 'ALL') {
    $universe = load_universe();
    log_info("Universe mode: FULL (" . scalar(@$universe) . " symbols)");
} else {
    $universe = \@QULL_WATCHLIST;
    log_info("Universe mode: WATCHLIST (" . scalar(@$universe) . " symbols)");
}
my @scan_syms = grep { !exists $held{$_} } @$universe;
log_info("Scanning " . scalar(@scan_syms) . " symbols (universe minus held positions)");

# 6. Batch snapshots + pre-screen
my %snaps = batch_snapshots(@scan_syms);
my @candidates = pre_screen(%snaps);
log_info("Pre-screen passed: " . scalar(@candidates) . " candidates (price + volume)");

# In bear market, only scan obvious EP gaps (faster + more selective)
if (!$bull_market) {
    @candidates = grep {
        my $gap = $_->{prev_close} > 0
            ? ($_->{open} - $_->{prev_close}) / $_->{prev_close} * 100.0
            : 0;
        $gap >= ($EP_MIN_GAP - 1.0);
    } @candidates;
    log_info("Bear-market mode: narrowed to " . scalar(@candidates) . " EP-gap candidates");
}

unless (@candidates) {
    log_info("No candidates after pre-screen — done");
    exit 0;
}

# 7. Fetch bars for all candidates
my @cand_syms = map { $_->{symbol} } @candidates;
my %bars = fetch_bars_batch(\@cand_syms);

# 8. Detect signals
log_info("Running signal detection...");
my (@ep_sigs, @flag_sigs);

for my $sym (keys %bars) {
    my @sigs = detect_signals($sym, $bars{$sym});
    for my $sig (@sigs) {
        if    ($sig->{type} eq 'EP')   { push @ep_sigs,   $sig }
        elsif ($sig->{type} eq 'FLAG') { push @flag_sigs, $sig }
    }
}

# Sort each group by score descending
@ep_sigs   = sort { $b->{score} <=> $a->{score} } @ep_sigs;
@flag_sigs = $bull_market
    ? sort { $b->{score} <=> $a->{score} } @flag_sigs
    : ();  # suppress flags in bear market

my @ranked = (@ep_sigs, @flag_sigs);

log_scan(sprintf("Signals: %d EP + %d FLAG = %d total",
                 scalar @ep_sigs, scalar @flag_sigs, scalar @ranked));

# 9. Report top signals
if (@ranked) {
    log_scan("─── TOP SIGNALS ───────────────────────────────────────────────");
    my $shown = 0;
    for my $sig (@ranked) {
        last if $shown >= 15;
        if ($sig->{type} eq 'EP') {
            log_scan(sprintf("  [EP  ] %-6s score=%6.1f gap=%+.1f%% vol=%.1fx ADR=%.1f%% hi=%.1f%%  \$%.2f SL=\$%.2f TP=\$%.2f",
                             $sig->{symbol}, $sig->{score},
                             $sig->{gap_pct}, $sig->{vol_mult},
                             $sig->{adr_pct} // 0, $sig->{dist_hi} // 0,
                             $sig->{entry}, $sig->{stop}, $sig->{target}));
        } else {
            log_scan(sprintf("  [FLAG] %-6s score=%6.1f pole=%.1f%% depth=%.1f%% vol=%.1fx ADR=%.1f%% hi=%.1f%%  \$%.2f SL=\$%.2f TP=\$%.2f",
                             $sig->{symbol}, $sig->{score},
                             $sig->{pole_pct}, $sig->{flag_dep}, $sig->{vol_mult},
                             $sig->{adr_pct} // 0, $sig->{dist_hi} // 0,
                             $sig->{entry}, $sig->{stop}, $sig->{target}));
        }
        $shown++;
    }
    log_scan("───────────────────────────────────────────────────────────────");
} else {
    log_info("No signals today — market is being watched");
    exit 0;
}

# 10. Execute top signals up to available slots
my $executed = 0;
for my $sig (@ranked) {
    last if $executed >= $slots;
    next if exists $held{$sig->{symbol}};  # safety: don't double-enter

    my $qty = calc_qty($equity, $sig->{entry}, $sig->{stop});
    unless ($qty > 0) {
        log_warn("$sig->{symbol}: qty=0, skipping");
        next;
    }

    my $ok = place_bracket(%$sig, qty => $qty);
    $executed++ if $ok;
}

log_info(sprintf("Done: %d order(s) placed | %d total positions",
                 $executed, $pos_cnt + $executed));
log_info("=" x 72);
