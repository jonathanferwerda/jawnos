package Manager;

# Manager helpers, part 18 of 37. Moved out of Manager.pl so a
# helper can be read and changed without opening 24k lines. The package is
# still Manager, and lib/JawnOS/Manager/Index.pm maps every sub name here to
# this file; Manager.pm loads it on the first call.
use strict;
use warnings;
use utf8;
use feature 'signatures';
no warnings 'experimental::signatures';
no warnings 'uninitialized';
no warnings 'once';

use Mojo::Promise;
use Mojo::UserAgent;
use Time::Local;
use Time::Piece;
use Time::Duration;
use Date::Parse;
use Clone qw(clone);
use Mojolicious::Static;
use Mojo::Log;
use Mojo::Transaction::WebSocket;
use Mojo::Parameters;
use Mojo::DOM;
use Mojo::URL;
use Mojo::JSON qw(decode_json encode_json);
use URI::Encode qw(uri_encode uri_decode);
use List::Util qw(shuffle);
use Data::Dumper;
use Mojo::Util qw/md5_sum html_unescape xml_escape term_escape quote unquote secure_compare url_escape url_unescape network_contains punycode_decode punycode_encode b64_decode b64_encode/;
use File::Find;
use File::Slurp;
use File::Type;
use File::Copy;
use POSIX ();
use Fcntl qw(:flock O_CREAT O_EXCL O_WRONLY);
use Number::Format qw/:subs/;
use SQL::Abstract;
use Mojo::SQLite;
use Mojo::IOLoop;

use Mojolicious::Sessions;
use Mojo::Server::Daemon;
use Mojolicious::Renderer;
use Crypt::Simple;
use CryptX;
use HTML::Strip;
use HTML::Parser;
use Data::UUID;
use Storable;
use Math::Trig qw(cartesian_to_spherical spherical_to_cartesian great_circle_distance rad2deg deg2rad great_circle_bearing great_circle_direction great_circle_destination);
use MIME::Base64;
use Sereal::Encoder qw(encode_sereal SRL_SNAPPY SRL_ZSTD);
use Sereal::Decoder qw(decode_sereal);
use Minion;
use IPC::Open2 qw(open2);

our ($APP, $ws_live_window, $encoder, $decoder, $tuuid, $thread_uuid, $universal_splitter, $database, $sql, $remote_input_clipboard, $config_file, $config, $logfile, $log, $environment, $random_caching_string, $duty_file, $main_process, $device, $user_agent, %time_machine_guide_cache, @media_unlock_apps, %help_search_tables, %media_type_for_ext, %file_relay_down, @appointments, @results, %market_payment_family, @manager_bundle_files, $manager_bundle_cache, $js_minifier, %app_release_sha, %folders_desk_not_app, $jg_body, $remote_input_geometry_at, $remote_input_geometry_cache, %remote_input_ua, %remote_input_ws, %remote_input_rm, %remote_input_ws_failed, $public_ip_memo, $coding_protocols, $coding_protocols_mtime, $app_schema_done, $fingerprint_checked_at, $fingerprint_ok, %padlock_time_memo, %credential_browser_app, %app_gate_shadow_seen, $ws_server, %mailws_untrusted_rate);

# --- Bank statement import and reconciliation ------------------------------
# A statement is read into dated, signed lines, matched against the money the
# ledger already holds for one account, and shown as a screen where a person
# settles the rest. Reconciling writes the statement's ending balance as an
# inventory anchor, which is the number the Budget balance is measured from.
sub bank_date_ms {
	my ($d,$order) = @_;
	return undef unless defined $d && length $d;
	$d =~ s/^\s+|\s+$//g;
	$d =~ s/[\x{2018}\x{2019}']/\//g;   # a QIF year separator (10/14'26)
	$d =~ s/[T ].*$//;                   # drop a time part
	$d =~ s/\..*$//;
	my ($y,$m,$day);
	if ($d =~ /^(\d{4})[-\/.](\d{1,2})[-\/.](\d{1,2})/) { ($y,$m,$day) = ($1,$2,$3); }
	elsif ($d =~ /^(\d{4})(\d{2})(\d{2})/) { ($y,$m,$day) = ($1,$2,$3); }
	elsif ($d =~ /^(\d{1,2})[\-\/., ]*([A-Za-z]{3,})[\-\/., ]*(\d{2,4})/) {
		# a bank that spells the month out (Libro writes 19Oct2026)
		my %month = ( jan=>1, feb=>2, mar=>3, apr=>4, may=>5, jun=>6, jul=>7, aug=>8, sep=>9, oct=>10, nov=>11, dec=>12 );
		my $mm = $month{ lc substr($2,0,3) };
		return undef unless $mm;
		($day,$m) = ($1,$mm);
		my $yy = $3;
		$y = $yy < 100 ? ($yy < 70 ? 2000 + $yy : 1900 + $yy) : $yy;
	}
	elsif ($d =~ /^([A-Za-z]{3,})[\-\/., ]*(\d{1,2})[\-\/., ]*(\d{2,4})/) {
		my %month = ( jan=>1, feb=>2, mar=>3, apr=>4, may=>5, jun=>6, jul=>7, aug=>8, sep=>9, oct=>10, nov=>11, dec=>12 );
		my $mm = $month{ lc substr($1,0,3) };
		return undef unless $mm;
		($m,$day) = ($mm,$2);
		my $yy = $3;
		$y = $yy < 100 ? ($yy < 70 ? 2000 + $yy : 1900 + $yy) : $yy;
	}
	elsif ($d =~ /^(\d{1,2})[-\/.](\d{1,2})[-\/.](\d{2,4})/) {
		my ($a,$b,$yy) = ($1,$2,$3);
		if (($order || 'mdy') eq 'dmy') { ($day,$m) = ($a,$b); } else { ($m,$day) = ($a,$b); }
		$y = $yy < 100 ? ($yy < 70 ? 2000 + $yy : 1900 + $yy) : $yy;
	}
	else { return undef; }
	return undef unless $m >= 1 && $m <= 12 && $day >= 1 && $day <= 31 && $y >= 1900 && $y <= 2200;
	my $ms = eval { timelocal(0,0,12,$day,$m-1,$y) };
	return undef unless defined $ms;
	return $ms * 1000;
}

sub bank_amount_value {
	my $v = shift;
	return undef unless defined $v;
	$v =~ s/[^\d.,()\-+]//g;
	return undef unless $v =~ /\d/;
	my $neg = ($v =~ /^\s*\(/ || $v =~ /-\s*$/ || $v =~ /^-/) ? 1 : 0;
	$v =~ s/[()+\s]//g;
	$v =~ s/-//g;
	# a decimal comma (1.234,56 or 12,34) versus a thousands comma
	if ($v =~ /,(\d{1,2})$/) { $v =~ s/\.//g; $v =~ s/,/./; }
	else { $v =~ s/,//g; }
	return undef unless $v =~ /^\d+(?:\.\d+)?$/;
	$v = $neg ? -$v : $v;
	return $v + 0;
}

sub bank_csv_rows {
	my $text = shift;
	$text =~ s/\r\n/\n/g;
	$text =~ s/\r/\n/g;
	my @rows;
	foreach my $line ( split /\n/, $text ) {
		next unless length $line;
		my $commas = () = $line =~ /,/g;
		my $semis = () = $line =~ /;/g;
		my $tabs = () = $line =~ /\t/g;
		my $d = ',';
		$d = ';' if $semis > $commas && $semis >= $tabs;
		$d = "\t" if $tabs > $commas && $tabs > $semis;
		my @fields;
		my $field = '';
		my $quoted = 0;
		my @ch = split //, $line;
		for (my $i = 0; $i <= $#ch; $i++) {
			my $ch = $ch[$i];
			if ($quoted) {
				if ($ch eq '"') {
					if ($i < $#ch && $ch[$i+1] eq '"') { $field .= '"'; $i++; }
					else { $quoted = 0; }
				}
				else { $field .= $ch; }
			}
			elsif ($ch eq '"') { $quoted = 1; }
			elsif ($ch eq $d) { push @fields, $field; $field = ''; }
			else { $field .= $ch; }
		}
		push @fields, $field;
		push @rows, \@fields;
	}
	return \@rows;
}

sub bank_csv_column_map {
	my $header = shift;
	my %map;
	for (my $i = 0; $i < scalar @{$header}; $i++) {
		my $h = lc($header->[$i] // '');
		$h =~ s/^\s+|\s+$//g;
		$map{'date'} = $i if !defined $map{'date'} && $h =~ /date/;
		$map{'description'} = $i if !defined $map{'description'} && $h =~ /desc|payee|memo|detail|narrative|name/;
		$map{'debit'} = $i if !defined $map{'debit'} && $h =~ /debit|withdraw|money out|paid out/;
		$map{'credit'} = $i if !defined $map{'credit'} && $h =~ /credit|deposit|money in|paid in/;
		$map{'amount'} = $i if !defined $map{'amount'} && $h =~ /amount|value/;
		$map{'balance'} = $i if !defined $map{'balance'} && $h =~ /balance/;
	}
	return \%map;
}

sub bank_statement_parse_csv {
	my ($text,$date_order) = @_;
	my $rows = &bank_csv_rows($text);
	my $lines = [];
	my $file_balance;
	my @balances;
	my $start = 0;
	my $map;
	# a bank export often opens with a name or an account number before the
	# column headings, so look a few rows in for a heading this can read
	for (my $r = 0; $r < scalar @{$rows} && $r < 10; $r++) {
		my $candidate = &bank_csv_column_map($rows->[$r]);
		if (defined $candidate->{'date'} && (defined $candidate->{'amount'} || defined $candidate->{'debit'} || defined $candidate->{'credit'})) {
			$map = $candidate;
			$start = $r + 1;
			last;
		}
	}
	unless ($map) {
		my $width = 0;
		for (my $r = 0; $r < scalar @{$rows} && $r < 10; $r++) {
			$width = scalar @{$rows->[$r]} if scalar @{$rows->[$r]} > $width;
		}
		$map = $width >= 4 ? { date => 0, description => 1, debit => 2, credit => 3 } : { date => 0, description => 1, amount => 2 };
	}
	for (my $r = $start; $r < scalar @{$rows}; $r++) {
		my $row = $rows->[$r];
		my $ts = &bank_date_ms($row->[$map->{'date'}], $date_order);
		next unless defined $ts;
		my $amount;
		if (defined $map->{'amount'} && defined $row->[$map->{'amount'}]) {
			$amount = &bank_amount_value($row->[$map->{'amount'}]);
		}
		else {
			my $debit = defined $map->{'debit'} ? &bank_amount_value($row->[$map->{'debit'}]) : undef;
			my $credit = defined $map->{'credit'} ? &bank_amount_value($row->[$map->{'credit'}]) : undef;
			$amount = defined $debit ? -abs($debit) : (defined $credit ? abs($credit) : undef);
		}
		next unless defined $amount;
		next if $amount == 0;
		my $description = defined $map->{'description'} ? ($row->[$map->{'description'}] // '') : '';
		$description =~ s/^\s+|\s+$//g;
		unless (length $description) {
			$description = join ' ', grep { defined && length && $_ !~ /^[\s\d.,$()\-+]+$/ } @{$row};
		}
		if (defined $map->{'balance'}) {
			my $b = &bank_amount_value($row->[$map->{'balance'}]);
			push @balances, [ $ts, $b, $amount ] if defined $b;
		}
		push @{$lines}, { timestamp => $ts, amount => $amount, description => $description };
	}
	# The balance column runs after each row's transaction, so the closing
	# balance is the one at the newest end of a file we do not know the
	# direction of. The running balance itself says which end that is: on a
	# newest-first file row i's balance equals the next row's plus row i's
	# amount, and the other way round on an oldest-first file.
	if (scalar @balances == 1) {
		$file_balance = $balances[0]->[1];
	}
	elsif (scalar @balances > 1) {
		my ($down,$up) = (0,0);
		for (my $i = 0; $i < $#balances; $i++) {
			my ($b0,$b1) = ($balances[$i]->[1], $balances[$i+1]->[1]);
			my ($a0,$a1) = ($balances[$i]->[2], $balances[$i+1]->[2]);
			$down++ if abs($b0 - ($b1 + $a0)) < 0.005;
			$up++ if abs($b1 - ($b0 + $a1)) < 0.005;
		}
		$file_balance = ($up > $down) ? $balances[-1]->[1] : $balances[0]->[1];
	}
	@{$lines} = sort { $a->{'timestamp'} <=> $b->{'timestamp'} } @{$lines};
	return ($lines, $file_balance, undef, undef);
}

sub bank_statement_parse_qif {
	my ($text,$date_order) = @_;
	my $lines = [];
	my %cur;
	foreach my $l ( split /\n/, $text ) {
		$l =~ s/\r$//;
		if ($l =~ /^\^/) {
			my $ts = &bank_date_ms($cur{'date'}, $date_order);
			my $amount = &bank_amount_value($cur{'amount'});
			if (defined $ts && defined $amount && $amount != 0) {
				my $description = join ' ', grep { defined && length } ($cur{'payee'}, $cur{'memo'});
				push @{$lines}, { timestamp => $ts, amount => $amount, description => $description };
			}
			%cur = ();
			next;
		}
		my ($k,$v) = ($l =~ /^(.)(.*)$/s);
		next unless $k;
		if ($k eq 'D') { $cur{'date'} = $v; }
		elsif ($k eq 'T' || $k eq 'U') { $cur{'amount'} = $v if !defined $cur{'amount'} || $k eq 'T'; }
		elsif ($k eq 'P') { $cur{'payee'} = $v; }
		elsif ($k eq 'M') { $cur{'memo'} = $v; }
	}
	@{$lines} = sort { $a->{'timestamp'} <=> $b->{'timestamp'} } @{$lines};
	my $error = scalar @{$lines} ? undef : 'No QIF transactions were found.';
	return ($lines, undef, $error, undef);
}

sub bank_statement_parse_ofx {
	my ($text,$date_order) = @_;
	my $lines = [];
	while ($text =~ m{<STMTTRN>(.*?)(?:</STMTTRN>|(?=<STMTTRN>)|$)}gis) {
		my $body = $1;
		my ($d) = $body =~ m{<DTPOSTED>\s*([0-9]+)}i;
		my ($a) = $body =~ m{<TRNAMT>\s*([-0-9.,]+)}i;
		my ($n) = $body =~ m{<NAME>\s*([^<\r\n]*)}i;
		my ($m) = $body =~ m{<MEMO>\s*([^<\r\n]*)}i;
		my $ts = &bank_date_ms($d, $date_order);
		my $amount = &bank_amount_value($a);
		next unless defined $ts && defined $amount && $amount != 0;
		my $description = join ' ', grep { defined && length } ($n, $m);
		push @{$lines}, { timestamp => $ts, amount => $amount, description => $description };
	}
	my ($file_balance);
	if ($text =~ m{<LEDGERBAL>(.*?)(?:</LEDGERBAL>|$)}is) {
		my $block = $1;
		my ($bal) = $block =~ m{<BALAMT>\s*([-0-9.,]+)}i;
		$file_balance = &bank_amount_value($bal);
	}
	# the closing balance is as of the statement's end, which the bank states
	# itself; the last transaction often sits a day or two earlier
	my $statement_end;
	if ($text =~ m{<LEDGERBAL>.*?<DTASOF>\s*([0-9]{8,14})}is) {
		$statement_end = &bank_date_ms($1, $date_order);
	}
	if (!defined $statement_end && $text =~ m{<DTEND>\s*([0-9]{8,14})}i) {
		$statement_end = &bank_date_ms($1, $date_order);
	}
	@{$lines} = sort { $a->{'timestamp'} <=> $b->{'timestamp'} } @{$lines};
	my $error = scalar @{$lines} ? undef : 'No OFX transactions were found.';
	return ($lines, $file_balance, $error, $statement_end);
}

sub bank_statement_parse {
	my ($filename,$text,$date_order) = @_;
	my $ext = lc($filename // '');
	$ext =~ s/.*\.//;
	return &bank_statement_parse_qif($text,$date_order) if $ext eq 'qif' || $text =~ /^!Type:/im;
	return &bank_statement_parse_ofx($text,$date_order) if $ext eq 'ofx' || $ext eq 'qfx' || $ext eq 'qbo' || $text =~ /<OFX>/i;
	return &bank_statement_parse_csv($text,$date_order);
}

# The money the ledger already holds for the account at the statement's end:
# its last inventory anchor plus every transaction after it. Purchase rows are
# breakdowns, not moves, so only type='transaction' is read.
sub bank_ledger_balance {
	my ($account,$end) = @_;
	my $anchor = &subs::db_query("select amount, timestamp from appointments where account=? and movement='inventory' and type='transaction' and cast(timestamp as integer) <= cast(? as integer) order by cast(timestamp as integer) desc limit 1", $account, $end)->hashes->[0];
	my $balance = $anchor ? ($anchor->{'amount'} || 0) + 0 : 0;
	my $since = $anchor ? ($anchor->{'timestamp'} || 0) + 0 : 0;
	my $sum = &subs::db_query("select coalesce(sum(cast(total as real)),0) as s from warehouse where kind='money' and type='transaction' and movement != 'inventory' and account=? and cast(timestamp as integer) >= cast(? as integer) and cast(timestamp as integer) <= cast(? as integer)", $account, $since, $end)->hashes->[0];
	$balance += ($sum->{'s'} || 0) + 0;
	return $balance;
}

# Pair each bank line with at most one ledger row of the same amount within three
# days; the closest date wins. A line the ledger only partly holds - an e-transfer
# whose service charge was recorded on its own, as Libro writes it - is then
# settled from the few rows that make it up, and the screen records only the
# remainder. Rows left over are the money in Budget that the statement does not
# show.
sub bank_reconcile_match {
	my ($lines,$candidates) = @_;
	my $used = {};
	my $near = sub {
		my $line = shift;
		return grep {
			!$used->{$_->{'uuid'}}
			&& abs((($_->{'timestamp'} || 0) + 0) - $line->{'timestamp'}) <= 3 * 86400000
		} @{$candidates};
	};
	foreach my $line ( sort { $a->{'timestamp'} <=> $b->{'timestamp'} } @{$lines} ) {
		my @near = grep { abs((($_->{'total'} || 0) + 0) - $line->{'amount'}) < 0.005 } &{$near}($line);
		next unless scalar @near;
		@near = sort { abs((($a->{'timestamp'} || 0) + 0) - $line->{'timestamp'}) <=> abs((($b->{'timestamp'} || 0) + 0) - $line->{'timestamp'}) } @near;
		my $match = $near[0];
		$used->{$match->{'uuid'}} = 1;
		$line->{'match'} = $match;
	}
	# a line made of more than one recorded move: take same-signed rows nearest
	# the line until it is covered; anything still short is what Record writes
	foreach my $line ( grep { !$_->{'match'} } sort { $a->{'timestamp'} <=> $b->{'timestamp'} } @{$lines} ) {
		my $sign = $line->{'amount'} < 0 ? -1 : 1;
		my $remaining = $line->{'amount'} + 0;
		my @parts;
		my @near = sort { abs((($a->{'timestamp'} || 0) + 0) - $line->{'timestamp'}) <=> abs((($b->{'timestamp'} || 0) + 0) - $line->{'timestamp'}) }
			grep {
				my $a = (($_->{'total'} || 0) + 0);
				$a != 0 && (($a < 0 ? -1 : 1) == $sign) && abs($a) <= abs($remaining) + 0.005
			} &{$near}($line);
		foreach my $candidate ( @near ) {
			my $a = (($candidate->{'total'} || 0) + 0);
			next if abs($a) > abs($remaining) + 0.005;
			push @parts, $candidate;
			$used->{$candidate->{'uuid'}} = 1;
			$remaining -= $a;
			last if abs($remaining) < 0.005;
		}
		next unless scalar @parts;
		$line->{'parts'} = \@parts;
		# a cent or two of rounding (Libro's $4.00 fee against a $3.99 row) is the
		# same move, not a remainder worth writing
		$line->{'settled'} = 1 if abs($remaining) <= 0.05;
		$line->{'record_amount'} = $line->{'settled'} ? 0 : $remaining;
	}
	my @outstanding = grep { !$used->{$_->{'uuid'}} } @{$candidates};
	return \@outstanding;
}

# The merchant memory: the app a description has consistently been filed under.
# It reads the old transactions' vendor (Libro writes 77 Vape Wyoming as
# 77_vape), then their item, then their app, and matches those words against a
# statement line. A suggestion is only a default - the line still waits to be
# confirmed.
sub bank_merchant_tokens {
	my $s = shift || '';
	$s = lc $s;
	$s =~ s/[^a-z0-9]+/ /g;
	return grep { length } split ' ', $s;
}

sub bank_merchant_memory {
	my $rows = &subs::db_query("select app, vendor, item, movement, count(*) as n from warehouse where kind='money' and type='transaction' and movement in ('income','expense') group by app, vendor, item, movement")->hashes || [];
	my @memory;
	my %stop = map { $_ => 1 } qw(cash account payment purchase transfer deposit withdrawal online pos card debit credit the and inc ltd of for at);
	foreach my $r ( @{$rows} ) {
		my $text = ($r->{'vendor'} && length $r->{'vendor'}) ? $r->{'vendor'}
			: (($r->{'item'} && length $r->{'item'}) ? $r->{'item'} : ($r->{'app'} || ''));
		my @tokens = grep { !$stop{$_} } &bank_merchant_tokens($text);
		next unless scalar @tokens;
		push @memory, {
			tokens => \@tokens, app => ($r->{'app'} || ''), vendor => ($r->{'vendor'} || ''),
			item => ($r->{'item'} || ''), movement => ($r->{'movement'} || ''), n => (($r->{'n'} || 0) + 0)
		};
	}
	return \@memory;
}

sub bank_merchant_lookup {
	my ($memory,$description,$movement) = @_;
	my %bank = map { $_ => 1 } &bank_merchant_tokens($description);
	return undef unless scalar keys %bank;
	my $best;
	foreach my $c ( @{$memory} ) {
		next unless (($c->{'movement'} || '') eq ($movement || ''));
		my $overlap = grep { $bank{$_} } @{$c->{'tokens'}};
		# a multi-word merchant needs more than one shared word: 'Service Fee'
		# must not become the passport office just because both say service
		my $need = scalar @{$c->{'tokens'}} >= 2 ? 2 : 1;
		next if $overlap < $need;
		my $score = $overlap / scalar @{$c->{'tokens'}};
		next if $score < 0.5;
		if (!$best || $score > $best->{'score'} + 0.0001 || (abs($score - $best->{'score'}) < 0.0001 && $c->{'n'} > $best->{'n'})) {
			$best = { %{$c}, score => $score };
		}
	}
	return $best;
}

# The pair of two legs of one transfer is the other side of the same move, so a
# missing leg is recorded as that transfer rather than as a new expense.
sub bank_reconcile_result {
	my ($account,$lines,$filename,$file_balance,$parse_error,$statement_end) = @_;
	my ($min,$max);
	foreach my $l ( @{$lines} ) {
		$min = $l->{'timestamp'} if !defined $min || $l->{'timestamp'} < $min;
		$max = $l->{'timestamp'} if !defined $max || $l->{'timestamp'} > $max;
	}
	my $start = defined $min ? $min : &subs::rightNow();
	my $end = defined $max ? $max : &subs::rightNow();
	# the statement's last day is the window's end, so a line stamped noon does
	# not push the end into the next morning and an anchor is written for the day
	# the closing balance belongs to
	if (defined $min) {
		my @s = localtime($min / 1000);
		my $midnight = eval { timelocal(0,0,0,$s[3],$s[4],$s[5]) };
		$start = $midnight * 1000 if defined $midnight;
	}
	if (defined $max) {
		my @e = localtime($max / 1000);
		my $night = eval { timelocal(59,59,23,$e[3],$e[4],$e[5]) };
		$end = $night * 1000 if defined $night;
	}
	# an OFX statement states the moment its closing balance belongs to; prefer
	# that over the last transaction's day (Libro closes two days after the last
	# transaction on the file)
	if (defined $statement_end) {
		my @e = localtime($statement_end / 1000);
		my $night = eval { timelocal(59,59,23,$e[3],$e[4],$e[5]) };
		$end = $night * 1000 if defined $night;
	}
	my $candidates = &subs::db_query("select * from warehouse where kind='money' and type='transaction' and account=? and movement != 'inventory' and cast(timestamp as integer) >= cast(? as integer) and cast(timestamp as integer) <= cast(? as integer) order by timestamp", $account, $start - 5 * 86400000, $end + 86400000)->hashes;
	my $outstanding = &bank_reconcile_match($lines, $candidates);
	my @inside = grep { (($_->{'timestamp'} || 0) + 0) >= $start && (($_->{'timestamp'} || 0) + 0) <= $end } @{$outstanding};
	my $anchor = &subs::db_query("select amount, timestamp from appointments where account=? and movement='inventory' and type='transaction' and cast(timestamp as integer) <= cast(? as integer) order by cast(timestamp as integer) desc limit 1", $account, $end)->hashes->[0];
	# money before the last inventory anchor is already in that one figure, not
	# itemised, so a statement line from that stretch cannot match and must not
	# be offered as something to record (that would write it twice)
	if ($anchor) {
		my $anchor_ts = ($anchor->{'timestamp'} || 0) + 0;
		foreach my $l ( @{$lines} ) {
			next if $l->{'match'} || $l->{'settled'};
			if (($l->{'timestamp'} + 0) <= $anchor_ts) {
				$l->{'covered'} = 1;
				$l->{'record_amount'} = 0;
			}
		}
	}
	# A transfer recorded on the other account alone (one leg of the pair was
	# lost) is the counterpart of this line: recording the line as a transfer
	# supplies the missing leg and leaves the other account's balance alone.
	my $counterparts = &subs::db_query("select * from warehouse where kind='money' and type='transaction' and movement='transfer' and account != ? and cast(timestamp as integer) >= cast(? as integer) and cast(timestamp as integer) <= cast(? as integer) order by timestamp", $account, $start - 3 * 86400000, $end + 3 * 86400000)->hashes;
	my %app_seen;
	my @app_choices;
	foreach my $l ( @{$lines} ) {
		next if $l->{'match'} || $l->{'settled'} || $l->{'covered'};
		my $amount = defined $l->{'record_amount'} ? $l->{'record_amount'} + 0 : $l->{'amount'} + 0;
		next if abs($amount) < 0.005;
		my @near = grep {
			abs((($_->{'total'} || 0) + 0) + $amount) < 0.005
			&& abs((($_->{'timestamp'} || 0) + 0) - $l->{'timestamp'}) <= 3 * 86400000
		} @{$counterparts};
		$l->{'counterpart'} = $near[0] if scalar @near;
		$l->{'movement'} = $l->{'counterpart'} ? 'transfer' : ($amount < 0 ? 'expense' : 'income');
		$l->{'app_default'} = $l->{'counterpart'} ? $l->{'counterpart'}->{'account'} : $account;
	}
	# a merchant the house has paid before supplies a default app; the line is
	# still shown with Record/Ignore so the person confirms it
	my $memory = &bank_merchant_memory();
	foreach my $l ( @{$lines} ) {
		next if $l->{'match'} || $l->{'settled'} || $l->{'covered'} || $l->{'counterpart'};
		my $suggestion = &bank_merchant_lookup($memory, $l->{'description'}, $l->{'movement'});
		next unless $suggestion;
		$l->{'suggested_app'} = $suggestion->{'app'};
		$l->{'suggested_vendor'} = $suggestion->{'vendor'};
		$l->{'suggested_item'} = $suggestion->{'item'};
		$l->{'suggested_count'} = $suggestion->{'n'};
		$l->{'app_default'} = $suggestion->{'app'} if $suggestion->{'app'} && length $suggestion->{'app'};
	}
	foreach my $choice ( $account, map { $_->{'account'} } @{$counterparts} ) {
		next unless defined $choice && length $choice && !$app_seen{$choice}++;
		push @app_choices, $choice;
	}
	foreach my $row ( @{ &subs::db_query("select app, count(*) as c from appointments where type in ('transaction','purchase') and app is not null and app != '' group by app order by c desc limit 150")->hashes || [] } ) {
		next if !defined $row->{'app'} || !length $row->{'app'} || $app_seen{$row->{'app'}}++;
		push @app_choices, $row->{'app'};
	}
	my ($matched_count,$unmatched_count,$covered_count,$matched_total,$unmatched_total,$covered_total) = (0,0,0,0,0,0);
	foreach my $l ( @{$lines} ) {
		if ($l->{'covered'}) { $covered_count++; $covered_total += $l->{'amount'}; }
		elsif ($l->{'match'} || $l->{'settled'}) { $matched_count++; $matched_total += $l->{'amount'}; }
		else { $unmatched_count++; $unmatched_total += $l->{'amount'}; }
	}
	my $outstanding_total = 0;
	$outstanding_total += (($_->{'total'} || 0) + 0) for @inside;
	my $ledger_balance = &bank_ledger_balance($account, $end);
	my $statement_balance = defined $file_balance ? $file_balance : '';
	my $delta;
	my $delta_defined = 0;
	if (defined $file_balance) { $delta = $file_balance - $ledger_balance; $delta_defined = 1; }
	my $settings = &subs::settings_grabber({ app => $account, benign => 1 });
	return {
		account => $account,
		filename => $filename,
		parse_error => $parse_error,
		lines => $lines,
		outstanding => \@inside,
		app_choices => \@app_choices,
		statement_end => $end,
		statement_start => $start,
		ledger_balance => $ledger_balance,
		statement_balance => $statement_balance,
		delta => $delta,
		delta_defined => $delta_defined,
		matched_count => $matched_count,
		unmatched_count => $unmatched_count,
		covered_count => $covered_count,
		matched_total => $matched_total,
		unmatched_total => $unmatched_total,
		covered_total => $covered_total,
		outstanding_total => $outstanding_total,
		last_inventory_amount => $anchor ? ($anchor->{'amount'} || 0) + 0 : undef,
		last_inventory_time => $anchor ? ($anchor->{'timestamp'} || 0) + 0 : undef,
		currency => $settings->{'currency'} || &subs::setting_grabber({ app => 'misc', setting => 'currency', benign => 1 }) || '[]'
	};
}

# Write the decisions of a reconciliation: each line left on Record becomes a
# transaction, then the statement's closing balance becomes the account's newest
# inventory anchor. Nothing is read back from the browser to decide this, so the
# same routine can run on a copy of the database in a test.
sub budget_reconcile_apply {
	my ($account,$statement_end,$ending,$lines) = @_;
	$lines = [] unless ref $lines eq 'ARRAY';
	my $currency = &subs::setting_grabber({ app => $account, setting => 'currency', benign => 1 });
	$currency = &subs::setting_grabber({ app => 'misc', setting => 'currency', benign => 1 }) unless defined $currency && length $currency;
	my $server_time = &subs::rightNow();
	my $recorded = 0;
	foreach my $line ( @{$lines} ) {
		next unless (($line->{'action'} || '') eq 'record');
		my $amount = (defined $line->{'record_amount'} && $line->{'record_amount'} ne '') ? &bank_amount_value($line->{'record_amount'}) : &bank_amount_value($line->{'amount'});
		next unless defined $amount && $amount != 0;
		my $movement = $line->{'movement'} || ($amount < 0 ? 'expense' : 'income');
		$movement = ($amount < 0 ? 'expense' : 'income') unless $movement eq 'expense' || $movement eq 'income' || $movement eq 'transfer';
		my $app = &subs::unformat_name($line->{'app'} || $account);
		$app = $account unless length $app;
		my $item = (defined $line->{'item'} && length $line->{'item'}) ? $line->{'item'} : ($line->{'description'} || 'imported');
		my $vendor = $line->{'vendor'} || '';
		my $uuid = &subs::random_string_creator(40);
		my $row = {
			app => $app,
			timestamp => $line->{'timestamp'},
			type => 'transaction',
			movement => $movement,
			account => $account,
			amount => $amount,
			total => $amount,
			item => &subs::unformat_name($item),
			vendor => &subs::unformat_name($vendor),
			uuid => $uuid,
			server_time => $server_time,
			currency => $currency
		};
		&subs::db_insert('appointments', $row);
		&subs::warehouse_money_mirror($row);
		$recorded++;
	}
	my $anchored = 0;
	my $balance = &bank_amount_value($ending);
	if (defined $balance && defined $statement_end && $statement_end =~ /[0-9]/) {
		# a statement that closes today ends at midnight tonight; the anchor is
		# written no later than now so it is the balance the panel reads at once
		my $anchor_time = $statement_end + 0;
		$anchor_time = $server_time if $anchor_time > $server_time;
		my $uuid = &subs::random_string_creator(40);
		my $row = {
			app => $account,
			timestamp => $anchor_time,
			type => 'transaction',
			movement => 'inventory',
			account => $account,
			amount => $balance,
			total => $balance,
			uuid => $uuid,
			server_time => $server_time,
			currency => $currency
		};
		&subs::db_insert('appointments', $row);
		# the warehouse keeps the anchor beside it, as the transaction form does
		&subs::db_insert('warehouse', {
			kind => 'inventory',
			type => 'transaction',
			movement => 'inventory',
			app => $account,
			account => $account,
			item => $account,
			quantity => $balance,
			amount => $balance,
			total => $balance,
			uuid => &subs::random_string_creator(40),
			app_uuid => $uuid,
			timestamp => $anchor_time,
			server_time => $server_time
		});
		$anchored = 1;
	}
	foreach my $circumstance ( keys %{$gb::budget_modes} ) {
		&subs::cache_delete({ app => $account, context => 'budget', subcontext => $circumstance });
	}
	&subs::cache_delete({ app => $account, context => 'template' });
	return { recorded => $recorded, anchored => $anchored, balance => &bank_ledger_balance($account, &subs::rightNow()) };
}

# --- Financial statements --------------------------------------------------
# The cash-basis statements read the same ledger the Budget view does: each
# account's money moves (type='transaction'), grouped by the app that carries
# the category. Nothing here writes.
sub accounting_moves {
	my ($accounts,$from,$to) = @_;
	my @rows;
	foreach my $a ( @{$accounts} ) {
		next unless defined $a && length $a;
		push @rows, @{ &subs::db_query("select * from warehouse where kind='money' and type='transaction' and movement != 'inventory' and account=? and cast(timestamp as integer) >= cast(? as integer) and cast(timestamp as integer) <= cast(? as integer) order by timestamp", $a, $from, $to)->hashes || [] };
	}
	return \@rows;
}

# Open invoices (not quotes) at a moment, with the balance and the age of each.
# There is no due date on an invoice, so the age is counted from the day it was
# written; the screen says so.
sub accounting_receivables {
	my $to = shift;
	my $returner = { rows => [], total => 0, count => 0, buckets => { current => 0, '31_60' => 0, '61_90' => 0, 'over_90' => 0 } };
	my $rows = &subs::db_query("select * from appointments where type='invoice' and cast(timestamp as integer) <= cast(? as integer) order by timestamp", $to)->hashes || [];
	foreach my $doc ( @{$rows} ) {
		my $data = eval { decode_json $doc->{'data'} } || {};
		my $numbers = $data->{'numbers'} || {};
		my $paid = 0;
		foreach my $p ( @{$data->{'payments'} || []} ) {
			$paid += (($p->{'amount'} || 0) + 0);
		}
		my $balance = defined $numbers->{'balance'} ? ($numbers->{'balance'} + 0) : (($numbers->{'total'} || 0) + 0) - $paid;
		next if $balance <= 0.005;
		my $issued = ($doc->{'timestamp'} || 0) + 0;
		my $age = int(($to - $issued) / 86400000);
		$age = 0 if $age < 0;
		my $bucket = $age <= 30 ? 'current' : $age <= 60 ? '31_60' : $age <= 90 ? '61_90' : 'over_90';
		$returner->{'total'} += $balance;
		$returner->{'buckets'}->{$bucket} += $balance;
		$returner->{'count'}++;
		push @{$returner->{'rows'}}, {
			app => $doc->{'app'},
			uuid => $doc->{'uuid'},
			id => $data->{'id'},
			timestamp => $issued,
			age => $age,
			bucket => $bucket,
			total => ($numbers->{'total'} || 0) + 0,
			paid => $paid,
			balance => $balance
		};
	}
	@{$returner->{'rows'}} = sort { $b->{'age'} <=> $a->{'age'} } @{$returner->{'rows'}};
	return $returner;
}

1;
