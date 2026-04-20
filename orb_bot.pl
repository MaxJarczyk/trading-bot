#!/usr/bin/perl
use strict;
use warnings;
use POSIX qw(floor);
use JSON::PP;

# ─── LOAD .ENV ────────────────────────────────────────────────────────────────
my %ENV_VARS;
my $env_file = '/Users/maximilianjarczyk/Documents/Trading/.env';
if (-f $env_file) {
    # Local: load from file
    open my $ef, '<', $env_file or die "Cannot read .env: $!";
    while (<$ef>) {
        chomp; next if /^\s*#/ or /^\s*$/;
        my ($k, $v) = split /=/, $_, 2;
        $ENV_VARS{$k} = $v if defined $k && defined $v;
    }
    close $ef;
} else {
    # Cloud (Railway): use process environment variables directly
    %ENV_VARS = %ENV;
}

# ─── CONFIG ───────────────────────────────────────────────────────────────────
# Default watchlist — 100 liquid large-cap names across tech/finance/energy/
# materials/consumer/health. Override via ORB_WATCHLIST env var.
my $DEFAULT_WATCHLIST = join(',',
    # Tech / megacap growth (30)
    qw(AAPL MSFT GOOGL META AMZN NVDA TSLA AVGO ORCL AMD
       CRM ADBE QCOM TXN INTC MU AMAT KLAC LRCX MRVL
       NFLX TMUS UBER SHOP PYPL PLTR SNOW CRWD PANW NOW),
    # Financials (15)
    qw(JPM BAC WFC GS MS C BLK AXP V MA SCHW COF USB MET PNC),
    # Energy (10)
    qw(XOM CVX COP OXY SLB HAL EOG MPC PSX VLO),
    # Materials / Industrials (15)
    qw(FCX NEM GOLD X CLF NUE ALB CAT DE BA GE HON LMT RTX UPS),
    # Consumer (15)
    qw(WMT COST TGT HD LOW NKE SBUX MCD CMG DIS DAL UAL AAL LUV CCL),
    # Healthcare (10)
    qw(UNH PFE MRK LLY ABBV BMY JNJ CVS TMO ISRG),
    # Momentum misc (5)
    qw(COIN HOOD RBLX SMCI ANET),
);
my @WATCHLIST      = split /,/, ($ENV_VARS{ORB_WATCHLIST}     || $DEFAULT_WATCHLIST);
my $MAX_TRADE_USD  = $ENV_VARS{ORB_MAX_TRADE_USD}  || 1000;
my $BUDGET_USD     = $ENV_VARS{ORB_BUDGET_USD}     || 50000;
my $MAX_POSITIONS  = $ENV_VARS{ORB_MAX_POSITIONS}  || 10;

# ORB params
my $ORB_MINUTES    = $ENV_VARS{ORB_MINUTES}        || 30;
my $ORB_VOL_MULT   = $ENV_VARS{ORB_VOL_MULT}       || 1.1;
my $ORB_RR         = $ENV_VARS{ORB_RR_RATIO}       || 1.5;
my $ORB_CUT        = $ENV_VARS{ORB_CUTOFF_HOUR}    || 14;
my $ORB_GAP_THRESH = $ENV_VARS{ORB_GAP_THRESH}     || 0.75;  # min gap % to enable ORB

# VWAP MR params
my $MR_EXT         = $ENV_VARS{MR_EXT_PCT}         || 1.5;   # % extension from VWAP
my $MR_DRY         = $ENV_VARS{MR_VOL_DRY}         || 0.70;  # vol must drop to X× MA
my $MR_CUT         = $ENV_VARS{MR_CUTOFF_HOUR}     || 14;    # no MR entries after this hour ET

my $VOL_MA_LEN     = 20;
my $EOD_HOUR       = 15;
my $EOD_MIN        = 55;

my $ALPACA_KEY     = $ENV_VARS{ALPACA_API_KEY_2}    or die "Missing ALPACA_API_KEY_2";
my $ALPACA_SECRET  = $ENV_VARS{ALPACA_SECRET_KEY_2} or die "Missing ALPACA_SECRET_KEY_2";
my $TRADE_URL      = 'https://paper-api.alpaca.markets/v2';
my $DATA_URL       = 'https://data.alpaca.markets/v2';
my $LOG            = $ENV{RAILWAY_ENVIRONMENT} ? undef
                   : '/Users/maximilianjarczyk/Documents/Trading/orb_bot.log';

# ─── LOGGING ──────────────────────────────────────────────────────────────────
sub log_msg {
    my ($msg) = @_;
    my $ts = scalar localtime;
    if ($LOG) {
        open my $fh, '>>', $LOG or die $!;
        print $fh "[$ts] $msg\n";
        close $fh;
    }
    print "[$ts] $msg\n";   # always log to STDOUT (captured by Railway)
}

# ─── ALPACA HELPERS ───────────────────────────────────────────────────────────
sub alpaca_get {
    my ($url) = @_;
    my $out = `/usr/bin/curl -s "$url" -H "APCA-API-KEY-ID: $ALPACA_KEY" -H "APCA-API-SECRET-KEY: $ALPACA_SECRET"`;
    return eval { decode_json($out) } // {};
}

sub alpaca_post {
    my ($path, $body) = @_;
    my $json = encode_json($body);
    my $tmp  = "/tmp/orb_body_$$.json";
    open my $fh, '>', $tmp or die "Cannot write $tmp: $!";
    print $fh $json; close $fh;
    my $cmd = qq(/usr/bin/curl -s -X POST "$TRADE_URL$path" )
            . qq(-H "APCA-API-KEY-ID: $ALPACA_KEY" )
            . qq(-H "APCA-API-SECRET-KEY: $ALPACA_SECRET" )
            . qq(-H "Content-Type: application/json" )
            . qq(--data-binary \@$tmp --max-time 30);
    my $out = `$cmd`;
    unlink $tmp;
    return eval { decode_json($out) } // {};
}

# ─── CURRENT ET TIME ──────────────────────────────────────────────────────────
# US DST: 2nd Sunday of March at 02:00 → 1st Sunday of November at 02:00.
# During DST: ET = UTC-4 (EDT). Otherwise: ET = UTC-5 (EST).
sub _us_dst_in_effect {
    my ($y, $m, $d, $h) = @_;   # 4-digit year, 1-12 month, 1-31 day, 0-23 UTC hour
    return 0 if $m < 3 || $m > 11;
    return 1 if $m > 3 && $m < 11;
    # Find 2nd Sunday of March and 1st Sunday of November
    # Zeller-like: day-of-week for Y-M-1
    require POSIX;
    my @t_mar = (0,0,12, 1, 2, $y - 1900);   # Mar 1 noon UTC
    my $wday_mar = (POSIX::strftime("%w", @t_mar));
    my $mar_2nd_sun = 1 + (7 - $wday_mar) % 7 + 7;     # 2nd Sunday
    my @t_nov = (0,0,12, 1, 10, $y - 1900);  # Nov 1 noon UTC
    my $wday_nov = (POSIX::strftime("%w", @t_nov));
    my $nov_1st_sun = 1 + (7 - $wday_nov) % 7;
    if ($m == 3) {
        return 0 if $d <  $mar_2nd_sun;
        return 1 if $d >  $mar_2nd_sun;
        return $h >= 7 ? 1 : 0;   # 07:00 UTC = 02:00 EST → DST starts
    }
    if ($m == 11) {
        return 1 if $d <  $nov_1st_sun;
        return 0 if $d >  $nov_1st_sun;
        return $h >= 6 ? 0 : 1;   # 06:00 UTC = 02:00 EDT → DST ends
    }
    return 0;
}

sub et_time {
    my @utc = gmtime(time);
    my ($sec, $min, $hr, $mday, $mon, $year) = @utc;
    my $dst    = _us_dst_in_effect($year + 1900, $mon + 1, $mday, $hr);
    my $offset = $dst ? 4 : 5;
    my $et_hour = ($hr - $offset + 24) % 24;
    return ($et_hour, $min);
}

# ─── POSITION HELPERS ─────────────────────────────────────────────────────────
sub get_all_positions {
    my $res = alpaca_get("$TRADE_URL/positions");
    return ref $res eq 'ARRAY' ? @$res : ();
}

sub get_position_for {
    my ($symbol) = @_;
    my $res = alpaca_get("$TRADE_URL/positions/$symbol");
    return undef if ref $res eq 'HASH' && ($res->{code} || $res->{message});
    return $res;
}

# ─── GET TODAY'S 5-MIN BARS ───────────────────────────────────────────────────
sub get_bars {
    my ($symbol) = @_;
    my @t    = gmtime(time);
    my $date = sprintf("%04d-%02d-%02d", $t[5]+1900, $t[4]+1, $t[3]);
    my $url  = "$DATA_URL/stocks/$symbol/bars?timeframe=5Min"
             . "&start=${date}T13:30:00Z&feed=iex&limit=100";
    my $res  = alpaca_get($url);
    return () unless ref $res eq 'HASH' && $res->{bars};
    return @{$res->{bars}};
}

# ─── GET PREVIOUS DAY'S CLOSE (for gap calculation) ───────────────────────────
sub get_prev_close {
    my ($symbol) = @_;
    my @t    = gmtime(time);
    my $date = sprintf("%04d-%02d-%02d", $t[5]+1900, $t[4]+1, $t[3]);
    # Fetch last 3 daily bars to safely get yesterday's close
    my $url  = "$DATA_URL/stocks/$symbol/bars?timeframe=1Day"
             . "&end=${date}T13:00:00Z&feed=iex&limit=3";
    my $res  = alpaca_get($url);
    return undef unless ref $res eq 'HASH' && $res->{bars} && @{$res->{bars}};
    my @daily = @{$res->{bars}};
    # Return the close of the most recent completed day
    return $daily[-1]{c};
}

# ─── VWAP ─────────────────────────────────────────────────────────────────────
sub calc_vwap {
    my @bars = @_;
    my ($cum_pv, $cum_vol) = (0, 0);
    for my $b (@bars) {
        my $tp = ($b->{h} + $b->{l} + $b->{c}) / 3;
        $cum_pv  += $tp * $b->{v};
        $cum_vol += $b->{v};
    }
    return $cum_vol > 0 ? $cum_pv / $cum_vol : 0;
}

# ─── EVALUATE SIGNAL FOR ONE SYMBOL ──────────────────────────────────────────
sub check_symbol {
    my ($symbol) = @_;

    my @bars = get_bars($symbol);
    my $n    = scalar @bars;
    my $orb_count = $ORB_MINUTES / 5;

    if ($n < $orb_count + 1) {
        log_msg("[$symbol] Only $n bars — skipping");
        return;
    }

    # ── ORB levels ─────────────────────────────────────────────────────────────
    my @orb_bars = @bars[0..$orb_count-1];
    my $orb_high = (sort { $b->{h} <=> $a->{h} } @orb_bars)[0]->{h};
    my $orb_low  = (sort { $a->{l} <=> $b->{l} } @orb_bars)[0]->{l};

    # ── Running VWAP (all bars so far) ────────────────────────────────────────
    my $vwap = calc_vwap(@bars);

    # ── Current price & previous bar ──────────────────────────────────────────
    my $price = $bars[-1]->{c};
    my $prev  = $n >= 2 ? $bars[-2]->{c} : $price;
    my $bar   = $bars[-1];

    # ── Volume MA (last VOL_MA_LEN bars, excluding current) ───────────────────
    my @vol_slice = map { $_->{v} } @bars;
    my $ma_start  = $n >= $VOL_MA_LEN ? $n - $VOL_MA_LEN : 0;
    my @ma_bars   = @vol_slice[$ma_start .. $n-2];   # exclude current bar
    my $vol_ma    = @ma_bars ? do { my $s=0; $s+=$_ for @ma_bars; $s/@ma_bars } : $bar->{v};

    # ── Gap calculation ────────────────────────────────────────────────────────
    my $prev_close = get_prev_close($symbol);
    my $day_open   = $bars[0]->{o};
    my $gap_pct    = ($prev_close && $prev_close>0)
                   ? ($day_open - $prev_close) / $prev_close * 100
                   : 0;
    my $gap_abs    = abs($gap_pct);
    my $gap_dir    = $gap_pct >= 0 ? 'up' : 'down';
    my $orb_armed  = $gap_abs >= $ORB_GAP_THRESH;

    log_msg(sprintf("[$symbol] price=%.2f ORB=%.2f/%.2f VWAP=%.2f gap=%+.2f%% orb=%s",
        $price, $orb_high, $orb_low, $vwap, $gap_pct, $orb_armed?'ARMED':'off'));

    my ($et_hour, $et_min) = et_time();

    # ═════════════════════════════════════════════════════════════════════════
    # STRATEGY 1 — ORB BREAKOUT (only on qualifying gap days)
    # ═════════════════════════════════════════════════════════════════════════
    if ($orb_armed && $et_hour < $ORB_CUT) {
        my $vol_ok     = $bar->{v} > $vol_ma * $ORB_VOL_MULT;
        my $crossed_up = $prev <= $orb_high && $price > $orb_high;
        my $crossed_dn = $prev >= $orb_low  && $price < $orb_low;

        # Long only on gap-up days; short only on gap-down days
        my $long_sig  = $crossed_up && $price > $vwap && $vol_ok && $gap_dir eq 'up';
        my $short_sig = $crossed_dn && $price < $vwap && $vol_ok && $gap_dir eq 'down';

        if ($long_sig || $short_sig) {
            my $qty = floor($MAX_TRADE_USD / $price);
            if ($qty < 1) {
                log_msg("[$symbol][ORB] Price \$$price > max trade size — skipping");
            } else {
                if ($long_sig) {
                    my $risk   = $price - $orb_low;
                    my $target = $price + $risk * $ORB_RR;
                    log_msg(sprintf("[$symbol][ORB] LONG — qty:%d entry:%.2f stop:%.2f target:%.2f gap:+%.2f%%",
                        $qty, $price, $orb_low, $target, $gap_pct));
                    my $order = alpaca_post('/orders', {
                        symbol        => $symbol,
                        qty           => "$qty",
                        side          => 'buy',
                        type          => 'market',
                        time_in_force => 'day',
                        order_class   => 'bracket',
                        stop_loss     => { stop_price  => sprintf("%.2f", $orb_low)  },
                        take_profit   => { limit_price => sprintf("%.2f", $target)   },
                    });
                    log_msg("[$symbol][ORB] Order: " . ($order->{id} || encode_json($order)));
                    return;   # one trade per symbol per run
                }
                if ($short_sig) {
                    my $risk   = $orb_high - $price;
                    my $target = $price - $risk * $ORB_RR;
                    log_msg(sprintf("[$symbol][ORB] SHORT — qty:%d entry:%.2f stop:%.2f target:%.2f gap:%.2f%%",
                        $qty, $price, $orb_high, $target, $gap_pct));
                    my $order = alpaca_post('/orders', {
                        symbol        => $symbol,
                        qty           => "$qty",
                        side          => 'sell',
                        type          => 'market',
                        time_in_force => 'day',
                        order_class   => 'bracket',
                        stop_loss     => { stop_price  => sprintf("%.2f", $orb_high) },
                        take_profit   => { limit_price => sprintf("%.2f", $target)   },
                    });
                    log_msg("[$symbol][ORB] Order: " . ($order->{id} || encode_json($order)));
                    return;
                }
            }
        }
    }

    # ═════════════════════════════════════════════════════════════════════════
    # STRATEGY 2 — VWAP MEAN-REVERSION (every day, all market conditions)
    # ═════════════════════════════════════════════════════════════════════════
    if ($et_hour < $MR_CUT && $n >= 2) {
        my $ext_frac   = $MR_EXT / 100;
        my $vol_exhaust = $bar->{v} < $vol_ma * $MR_DRY;

        # Previous bar's VWAP (we need it to confirm "was already extended")
        my $prev_vwap  = calc_vwap(@bars[0..$n-2]);

        my $above_ext  = $vwap > 0 && $price > $vwap * (1 + $ext_frac);
        my $was_above  = $prev_vwap > 0 && $prev  > $prev_vwap * (1 + $ext_frac * 0.5);
        my $bear_bar   = $bar->{c} < $bar->{o};

        my $below_ext  = $vwap > 0 && $price < $vwap * (1 - $ext_frac);
        my $was_below  = $prev_vwap > 0 && $prev  < $prev_vwap * (1 - $ext_frac * 0.5);
        my $bull_bar   = $bar->{c} > $bar->{o};

        my $mr_long  = $below_ext && $was_below && $vol_exhaust && $bull_bar;
        my $mr_short = $above_ext && $was_above && $vol_exhaust && $bear_bar;

        log_msg(sprintf("[$symbol][MR] ext=%.2f%% exhaust=%s bull=%s bear=%s → long=%s short=%s",
            ($price - $vwap) / ($vwap||1) * 100,
            $vol_exhaust?'Y':'N', $bull_bar?'Y':'N', $bear_bar?'Y':'N',
            $mr_long?'YES':'no', $mr_short?'YES':'no'));

        if ($mr_long || $mr_short) {
            my $qty = floor($MAX_TRADE_USD / $price);
            if ($qty < 1) {
                log_msg("[$symbol][MR] Price \$$price > max trade size — skipping");
                return;
            }

            if ($mr_long) {
                my $dist   = $vwap - $price;          # distance to VWAP (= target)
                my $stop   = $price - $dist * 0.5;    # 50% further below
                my $target = $vwap;                    # full mean-reversion
                log_msg(sprintf("[$symbol][MR] LONG — qty:%d entry:%.2f stop:%.2f target:%.2f (VWAP)",
                    $qty, $price, $stop, $target));
                my $order = alpaca_post('/orders', {
                    symbol        => $symbol,
                    qty           => "$qty",
                    side          => 'buy',
                    type          => 'market',
                    time_in_force => 'day',
                    order_class   => 'bracket',
                    stop_loss     => { stop_price  => sprintf("%.2f", $stop)   },
                    take_profit   => { limit_price => sprintf("%.2f", $target) },
                });
                log_msg("[$symbol][MR] Order: " . ($order->{id} || encode_json($order)));

            } elsif ($mr_short) {
                my $dist   = $price - $vwap;
                my $stop   = $price + $dist * 0.5;
                my $target = $vwap;
                log_msg(sprintf("[$symbol][MR] SHORT — qty:%d entry:%.2f stop:%.2f target:%.2f (VWAP)",
                    $qty, $price, $stop, $target));
                my $order = alpaca_post('/orders', {
                    symbol        => $symbol,
                    qty           => "$qty",
                    side          => 'sell',
                    type          => 'market',
                    time_in_force => 'day',
                    order_class   => 'bracket',
                    stop_loss     => { stop_price  => sprintf("%.2f", $stop)   },
                    take_profit   => { limit_price => sprintf("%.2f", $target) },
                });
                log_msg("[$symbol][MR] Order: " . ($order->{id} || encode_json($order)));
            }
        }
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════════
log_msg("=== ORB+MR Bot — watchlist: " . join(', ', @WATCHLIST) . " ===");
log_msg(sprintf("Params: ORB %dmin/%.2fx/RR%.1f/cut%d/gap≥%.2f%%  MR ext%.1f%%/dry%.2fx/cut%d",
    $ORB_MINUTES,$ORB_VOL_MULT,$ORB_RR,$ORB_CUT,$ORB_GAP_THRESH,
    $MR_EXT,$MR_DRY,$MR_CUT));

my ($et_hour, $et_min) = et_time();
log_msg("ET time: ${et_hour}:${et_min}");

# ── EOD: close all positions ───────────────────────────────────────────────────
if ($et_hour == $EOD_HOUR && $et_min >= $EOD_MIN) {
    log_msg("EOD — closing all positions");
    my @positions = get_all_positions();
    if (@positions) {
        for my $pos (@positions) {
            my $sym = $pos->{symbol};
            my $pnl = $pos->{unrealized_pl} // 'n/a';
            `/usr/bin/curl -s -X DELETE "$TRADE_URL/positions/$sym" -H "APCA-API-KEY-ID: $ALPACA_KEY" -H "APCA-API-SECRET-KEY: $ALPACA_SECRET" --max-time 30`;
            log_msg("Closed $sym — unrealized P&L: \$$pnl");
        }
    } else {
        log_msg("No open positions at EOD");
    }
    exit 0;
}

# ── Before 10:00 AM (ORB still forming for 30-min window) ─────────────────────
if ($et_hour < 9 || ($et_hour == 9 && $et_min < 55)) {
    log_msg("Before 9:55 ET — ORB window still forming, no entries yet");
    exit 0;
}

# ── Past all entry cutoffs ─────────────────────────────────────────────────────
my $latest_cut = ($ORB_CUT > $MR_CUT) ? $ORB_CUT : $MR_CUT;
if ($et_hour >= $latest_cut) {
    log_msg("Past $latest_cut:00 ET — no new entries");
    exit 0;
}

# ── Budget check ──────────────────────────────────────────────────────────────
my $account = alpaca_get("$TRADE_URL/account");
my $equity  = $account->{equity} || 0;
log_msg("Equity: \$$equity  Floor: \$" . ($BUDGET_USD * 0.90));
if ($equity < $BUDGET_USD * 0.90) {
    log_msg("HALT — equity below 90% of budget. Stopping.");
    exit 1;
}

# ── Count open positions ───────────────────────────────────────────────────────
my @open_positions = get_all_positions();
my $open_count     = scalar @open_positions;
my %has_position   = map { $_->{symbol} => 1 } @open_positions;

log_msg("Open positions: $open_count / $MAX_POSITIONS");

if ($open_count >= $MAX_POSITIONS) {
    log_msg("At max positions ($MAX_POSITIONS) — skipping all entries");
    exit 0;
}

# ── Scan watchlist ─────────────────────────────────────────────────────────────
my $slots = $MAX_POSITIONS - $open_count;
log_msg("Available slots: $slots");

for my $symbol (@WATCHLIST) {
    last if $slots <= 0;

    if ($has_position{$symbol}) {
        log_msg("[$symbol] Already in position — skipping");
        next;
    }

    check_symbol($symbol);

    # Recount after each potential entry
    @open_positions = get_all_positions();
    $open_count     = scalar @open_positions;
    %has_position   = map { $_->{symbol} => 1 } @open_positions;
    $slots          = $MAX_POSITIONS - $open_count;
}

log_msg("=== Done — open positions: $open_count ===");
