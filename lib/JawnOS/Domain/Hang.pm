package subs;

# Hang: extracted from subroutines.pl (package subs). Loaded on
# demand by lib/JawnOS/Domain/Loader.pm.
use strict;
use warnings;
use utf8;
use feature 'signatures';
no warnings 'experimental::signatures';
no warnings 'experimental::args_array_with_signatures';

use Clone qw(clone);
use Data::Dumper;
use Date::Parse;
use Digest::SHA qw(sha256_hex);
use Encode qw(encode_utf8);
use Fcntl qw(:flock);
use File::Copy;
use File::Find;
use File::Path;
use File::Slurp;
use IPC::Open2;
use JSON::PP ();
use List::Util qw(shuffle);
use MIME::Base64;
use Math::Trig qw(cartesian_to_spherical spherical_to_cartesian great_circle_distance rad2deg deg2rad great_circle_bearing great_circle_direction great_circle_destination);
use Mojo::IOLoop;
use Mojo::JSON qw(decode_json encode_json);
use Mojo::Util qw/md5_sum xml_escape html_unescape term_escape quote unquote secure_compare url_escape url_unescape network_contains punycode_decode punycode_encode b64_decode b64_encode/;
use POSIX ();   # mktime: a local-time epoch that still predates 1970
use Text::Unidecode;
use Time::Duration;
use Time::HiRes qw(gettimeofday time);
use Time::Local;
use Time::Piece;
use Unicode::Normalize qw(NFC);

our $device;
our $gb;
our %m;

sub hang_to_dry {
	my $server_time = &rightNow();
	my $returner = [];

	my $time_plinkos = clone $gb::time_plinkos;
	my $cls = &db_query('select * from settings where setting = ? and device = ? and app!= ? and value is not null', 'clothesline', $device,'__president')->hashes;

	foreach my $clr ( @{$cls} ) {

		my $cl = eval { return decode_json $clr->{'value'} } || {};
		my $time = localtime($server_time / 1000);
		my $app = &unformat_name($clr->{'app'});
		my $settings = &settings_grabber({ app => $app });
		my $app_data = { name => $app, app => $app, formatted_name => &format_name($app), colour => $settings->{'colour'}, dark_colour => $settings->{'dark_colour'} };
		my $time_plinko = $cl->{'time_plinko'} || {};
		my @schedule = split ',', ($cl->{'schedule'} // '');
		foreach my $schedule ( @schedule ) {

		}
		my $count = scalar keys %{$cl->{'time_plinko'}};
		my $cl_count = 0;

		for (my $n = 0; $n <= 8; $n++) {
			my $ft = $time->[$n];
			if ($n == 2) {
				if ($ft == 0) {
					$ft = '12am';
				}
				elsif ($ft >= 12) {
					if ($ft == 12) { $ft = 24; }
					$ft = ($ft - 12) . 'pm';
				}
				elsif ($time->[$n] > 0 && $time->[$n] < 13) {
					$ft .= 'am';
				}
			}
			if ($n == 4) { $ft = $time->monname; }
			if ($n == 5) { $ft += 1900; }
			if ($n == 6) { $ft = $time->wdayname; }

			if ($time_plinko->{$time_plinkos->[$n]->{'name'}}) {

				if (grep { $_ eq $ft || $_ eq 'all' } @{$time_plinko->{$time_plinkos->[$n]->{'name'}}}) {
					$cl_count++;
					if ($cl_count == $count) {
						if (!&app_hidden_now($app)) {
							push @{$returner}, $app_data;
						}

					}
				}
			}
		}
		unless (grep { $_->{'app'} eq $app } @{$returner}) {
			my $running_appts = &db_query('select * from appointments where app = ? and (type = ? or type = ?)',$app, 'start','record')->hashes;
			if (scalar @{$running_appts} > 0) {
				push @{$returner}, $app_data;
			}
			foreach my $circumstance( keys %{$gb::budget_modes} ) {
				if ($cl->{$circumstance . '_budget'}) {
					my $budget = &subs::cache_get({ app => $app, context => 'budget', subcontext => $circumstance });
					if (grep { $budget->{'status'} eq $_ } @{$cl->{$circumstance . '_budget'}}) {
						push @{$returner}, $app_data unless grep { $_->{'app'} eq $app } @{$returner};
					}
				}
			}
		}



	}
	# The day's order, and the apps regular enough to hang themselves. An app the
	# user has never given a clothesline setting is offered at the hour its own
	# history keeps it, when that hour holds on most of the last fortnight and the
	# app is in its visible state. A setting of `off` in `clothesline_daily_auto`
	# turns the automatic hanging off; it is on when unset.
	my $daily = &clothesline_daily_hours();
	my $cur_time = localtime($server_time / 1000);
	my $cur_hour = $cur_time->[2];
	my %configured = map { &unformat_name($_->{'app'}) => 1 } @{$cls};
	# an app another app adds on its own - a default option, or a default model -
	# is not a thing the user clicks, so it never hangs itself (the coffee behind
	# the cream, the lunch behind its eggs). Their parent carries the routine.
	my $autos = &db_query(q{select distinct name from option where name is not null and name != app and lower(coalesce(def,'')) not in ('','off','false','0')
		union
		select distinct name from model where name is not null and name != app and lower(coalesce(def,'')) not in ('','off','false','0')})->hashes;
	my %auto_hung = map { $_->{'name'} => 1 } @{$autos};
	# the tasks an app carries: starting it records them as well, so they are not
	# clicks of the user's either (the flush and wash hands behind a pee or dump)
	my $task_rows = &db_query('select value from settings where setting = ? and value is not null', 'tasks')->hashes;
	foreach my $tr ( @{$task_rows} ) {
		my $list = eval { return decode_json $tr->{'value'} } || [];
		foreach my $t ( @{$list} ) {
			next unless $t->{'task'};
			$auto_hung{&unformat_name($t->{'task'})} = 1;
		}
	}
	# ...but a task or default the user also runs on their own is still theirs to
	# hang: a meaningful share of an app's own appointments carry no source (they
	# were not spawned by a parent). wash_hands is run by hand about half the time
	# and must stay; a flush that mostly follows a pee does not.
	my $auto_since = $server_time - (14 * 86400 * 1000);
	my $run_rows = &db_query(q{select app, count(*) total, sum(case when source_uuid is null or source_uuid = '' then 1 else 0 end) direct from appointments where type in ('usual','stop') and timestamp >= ? group by app}, $auto_since)->hashes;
	my %user_run;
	foreach my $r ( @{$run_rows} ) {
		next unless $r->{'total'};
		$user_run{$r->{'app'}} = 1 if ($r->{'direct'} / $r->{'total'}) >= 0.25;
	}
	my $auto = &setting_grabber({ app => '__president', setting => 'clothesline_daily_auto' });
	unless (defined $auto && lc($auto) eq 'off') {
		foreach my $app ( sort keys %{$daily} ) {
			next if $configured{$app};
			next if $auto_hung{$app} && !$user_run{$app};
			my $routine = $daily->{$app};
			next unless $routine->{'hour_days'} >= 7;
			next unless $routine->{'hour'} == $cur_hour;
			my $aset = &settings_grabber({ app => $app });
			next if &app_hidden_now($app);
			push @{$returner}, { name => $app, app => $app, formatted_name => &format_name($app), colour => $aset->{'colour'}, dark_colour => $aset->{'dark_colour'} };
		}
	}
	# left to right, the order the day happens in; apps with no time of their own
	# (no history yet) fall to the end rather than shuffling those that have one
	@{$returner} = sort {
		my $ha = (defined $daily->{$a->{'app'}} && defined $daily->{$a->{'app'}}->{'hour'}) ? $daily->{$a->{'app'}}->{'hour'} : 24;
		my $hb = (defined $daily->{$b->{'app'}} && defined $daily->{$b->{'app'}}->{'hour'}) ? $daily->{$b->{'app'}}->{'hour'} : 24;
		$ha <=> $hb || $a->{'app'} cmp $b->{'app'};
	} @{$returner};
	&subs::subprocessor(sub {
		foreach my $clothes ( @{$returner} ) {
			&Manager::centre_view_grabber({ app => &subs::unformat_name($clothes->{'app'}), timestamp => &subs::rightNow() });
		}
	}, { name => 'clothesline centreview cacher' });
	my $jreturner = encode_json $returner;
	&setting_setter({ app => '__president', setting => 'clothesline', value => $jreturner });
	return 0;

}

# ---- web measures ----------------------------------------------------------
# A web measure used to be a CSS selector plus a count, applied to whatever the
# last fetch stored. That works until a page reorders, and it cannot say where
# a JSON value lives. One spec now covers both worlds:
#
#   JSON:  { "path": "properties.currentConditions.temperature.value.en" }
#   HTML:  { "selector": "#price", "count": 0, "attribute": "text" }
#          { "row": "tr", "match": "Gold", "within": "td" }
#
# with optional regex, fallback, number/unit/scale and the old prev/next
# context. The old selector/count specs keep working unchanged; a JSON id from
# the prettyfier is mapped back to its path, so weather's old selectors start
# reading the decoded JSON instead of the rendered DOM.
sub web_measure_clean_text {
	my ($s) = @_;
	return '' unless defined $s;
	$s =~ s/\x{00A0}/ /g;
	$s =~ s/\s+/ /g;
	$s =~ s/^\s+|\s+$//g;
	return $s;
}

sub web_measure_json_path {
	my ($json, $path) = @_;
	return undef unless defined $path && length $path;
	my $p = $path;
	$p =~ s/^\$//;
	$p =~ s/\[(\d+)\]/.$1/g;
	my @t = grep { length } split /\./, $p;
	my $node = $json;
	for my $t (@t) {
		if (ref $node eq 'HASH') {
			return undef unless exists $node->{$t};
			$node = $node->{$t};
		}
		elsif (ref $node eq 'ARRAY') {
			return undef unless $t =~ /^\d+$/ && $t < scalar @{$node};
			$node = $node->[$t];
		}
		else {
			return undef;
		}
	}
	return $node;
}

# The JSON prettyfier writes <span id="propertiescurrentConditions..."> by
# concatenating the keys (arrays become 1arr, 2arr...). Recover the real path
# from that id, so an old JSON selector keeps working and can be read as a
# path instead of through the rendered page.
sub web_measure_json_id_path {
	my ($json, $id) = @_;
	return undef unless defined $id && length $id;
	my $flat = sub { my $s = shift; $s =~ s/[^A-Za-z0-9]//g; return $s; };
	my $want = $flat->($id);
	my $walk;
	$walk = sub {
		my ($node, $parts, $idparts) = @_;
		if (ref $node eq 'HASH') {
			foreach my $k ( sort keys %{$node} ) {
				my $r = $walk->($node->{$k}, [@{$parts}, $k], [@{$idparts}, $k]);
				return $r if defined $r;
			}
		}
		elsif (ref $node eq 'ARRAY') {
			for my $i ( 0 .. $#{$node} ) {
				my $r = $walk->($node->[$i], [@{$parts}, $i], [@{$idparts}, ($i + 1) . 'arr']);
				return $r if defined $r;
			}
		}
		else {
			return join('.', @{$parts}) if $flat->(join '', @{$idparts}) eq $want;
		}
		return undef;
	};
	return $walk->($json, [], []);
}

# Every scalar path a JSON response offers, for the picker and the audit tool.
sub web_measure_json_paths {
	my ($json, $prefix, $out, $limit) = @_;
	$prefix = '' unless defined $prefix;
	$out = [] unless ref $out eq 'ARRAY';
	$limit ||= 4000;
	return $out if scalar @{$out} >= $limit;
	if (ref $json eq 'HASH') {
		foreach my $k ( sort keys %{$json} ) {
			my $p = length $prefix ? $prefix . '.' . $k : $k;
			&web_measure_json_paths($json->{$k}, $p, $out, $limit);
		}
	}
	elsif (ref $json eq 'ARRAY') {
		for my $i ( 0 .. $#{$json} ) {
			my $p = (length $prefix ? $prefix : '') . '[' . $i . ']';
			&web_measure_json_paths($json->[$i], $p, $out, $limit);
		}
	}
	else {
		push @{$out}, { path => $prefix, value => $json };
	}
	return $out;
}

# One number parser for every source. Currency, percent, a degree sign and a
# unit suffix are stripped; a comma decimal and a thousands separator are read
# by position; a leading minus (or parentheses) is kept. appt_measure_writer
# used to strip everything but digits and dots, which quietly turned -0.5 into
# 0.5.
sub web_measure_number {
	my ($raw, $spec) = @_;
	$spec ||= {};
	return undef unless defined $raw;
	my $s = &web_measure_clean_text($raw);
	return undef unless length $s;
	my $neg = 0;
	if ($s =~ /^\((.*)\)\s*$/) { $neg = 1; $s = $1; }
	my ($token) = $s =~ /([+\-]?(?:\d[\d.,']*|\.\d+)(?:[eE][+\-]?\d+)?)/;
	return undef unless defined $token;
	$token =~ s/['\s]//g;
	my $sign = 1;
	if ($token =~ s/^-//) { $sign = -1; }
	$token =~ s/^\+//;
	my $dec = $spec->{'decimal'};
	my $thou = $spec->{'thousands'};
	if (!defined $dec || !length $dec) {
		my $last_comma = rindex($token, ',');
		my $last_dot = rindex($token, '.');
		if ($last_comma >= 0 && $last_dot >= 0) {
			if ($last_comma > $last_dot) { $dec = ','; $thou = '.'; }
			else { $dec = '.'; $thou = ','; }
		}
		elsif ($last_comma >= 0) {
			my @c = split /,/, $token;
			if (scalar @c == 2 && length($c[1]) && length($c[1]) <= 2) { $dec = ','; $thou = ''; }
			else { $dec = '.'; $thou = ','; }
		}
		else { $dec = '.'; $thou = ''; }
	}
	if ($thou) { $token =~ s/\Q$thou\E//g; }
	if ($dec ne '.') { $token =~ s/\Q$dec\E/./g; }
	return undef unless $token =~ /^\d*(?:\.\d*)?$/ && $token =~ /\d/;
	my $n = $token + 0;
	$n = -$n if $neg || $sign < 0;
	my $scale = $spec->{'scale'};
	$n *= $scale if defined $scale && $scale =~ /^-?\d+(?:\.\d+)?$/;
	if (defined $spec->{'decimals'} && $spec->{'decimals'} =~ /^\d+$/) {
		return sprintf('%.' . $spec->{'decimals'} . 'f', $n);
	}
	# Keep the precision the page wrote. A fixed %.10f rounds 149,095,031.14
	# through a float and prints 149095031.1399999857.
	my $dp = ($token =~ /\.(\d+)$/) ? length($1) : 0;
	$dp = 10 if $dp > 10;
	my $out = sprintf('%.' . $dp . 'f', $n);
	$out =~ s/0+$// if $out =~ /\./;
	$out =~ s/\.$//;
	return $out;
}

# Some pages write a label as bare text, with the value in the next element:
#   Phase: <span>Waxing Crescent</span><br>
# Mojo::DOM drops text nodes from children(), so match the label in the
# container's own markup and return the first element that follows it.
sub web_measure_after_text_label {
	my ($dom, $container, $label, $skip) = @_;
	return undef unless $dom && defined $container && length $container && defined $label && length $label;
	my $box = $dom->at($container) or return undef;
	my $html = $box->to_string;
	my $needle = lc $label;
	my $pos = -1;
	for (my $i = 0; $i <= ($skip || 0); $i++) {
		$pos = index(lc($html), $needle, $pos + 1);
		return undef if $pos < 0;
	}
	my $cursor = 0;
	foreach my $child ( @{$box->children} ) {
		next unless $child->type eq 'tag';
		my $markup = $child->to_string;
		my $at = index($html, $markup, $cursor);
		next unless $at >= 0;
		$cursor = $at + length $markup;
		next unless $at > $pos;
		my $tag = lc($child->tag || '');
		next if $tag eq 'br' || $tag eq 'hr' || $tag eq 'wbr';
		return $child;
	}
	return undef;
}

# Extract one value from a fetched page. $ctx is { format, json, dom, raw }.
sub web_measure_extract {
	my ($spec, $ctx) = @_;
	$spec ||= {};
	$ctx ||= {};
	require Mojo::DOM;
	require Mojo::Collection;
	my $result = { ok => 0, value => undef, raw => undef, used => '', error => '' };
	my $json = $ctx->{'json'};
	my $dom = $ctx->{'dom'};
	my $raw_value;
	my $used = '';
	my $attr = $spec->{'attribute'} || 'text';

	# 1. an explicit JSON path
	if (ref $json && defined $spec->{'path'} && length $spec->{'path'}) {
		my $v = &web_measure_json_path($json, $spec->{'path'});
		if (defined $v && !ref $v) { $raw_value = $v; $used = 'path'; }
		else { $result->{'error'} = 'JSON path not found'; }
	}

	# 2. an old JSON id selector, mapped back to a path
	if (!defined $raw_value && ref $json && defined $spec->{'selector'} && $spec->{'selector'} =~ /^\s*\[id\s*=\s*["']?([^"'\]]+)["']?\]\s*$/i) {
		my $id = $1;
		my $path = &web_measure_json_id_path($json, $id);
		if (defined $path) {
			my $v = &web_measure_json_path($json, $path);
			if (defined $v && !ref $v) {
				$raw_value = $v;
				$used = 'path (from id)';
				$result->{'path'} = $path;
			}
		}
	}

	# 3. label then value: the label's own next cell/sibling, or a selector
	# inside the label's row. This survives a reordered page where a global
	# count does not.
	if (!defined $raw_value && $dom && defined $spec->{'label'} && length $spec->{'label'}) {
		my $want = $spec->{'label'};
		my $match_label = sub {
			my $t = &web_measure_clean_text(shift);
			return 0 unless length $t && length $t <= 200;
			if ($want =~ m{^/(.*)/([i]?)$}) { return $t =~ /$1/i ? 1 : 0; }
			return index(lc($t), lc($want)) >= 0 ? 1 : 0;
		};
		my $scope = $dom;
		if (defined $spec->{'container'} && length $spec->{'container'}) {
			my $box = $dom->at($spec->{'container'});
			$scope = $box if $box;
		}
		# all_text, not text: text only returns an element's own text, so a
		# <td><a>Silver</a></td> or <dd><span>2.4</span></dd> would look empty.
		my @labels = $scope->find('td, th, dt, dd, b, strong, span, div, label, h1, h2, h3, h4, h5, h6, p')->each;
		my @picked = grep { $match_label->($_->all_text) } @labels;
		# the tightest match wins: a <dt>Condition:</dt> is the label, not the
		# <dl> that contains it and its value
		@picked = sort { length($a->all_text) <=> length($b->all_text) } @picked;
		my $label_node = $picked[ $spec->{'label_count'} || 0 ];
		my $node;
		if ($label_node) {
			my $value = $spec->{'value'};
			if (defined $value && $value eq 'parent_next') {
				my $p = $label_node->parent;
				$node = $p ? $p->next : undef;
			}
			elsif (defined $value && $value eq 'next') {
				$node = $label_node->next;
			}
			elsif (defined $spec->{'value_selector'} && length $spec->{'value_selector'}) {
				my $scope = $label_node->parent;
				if (defined $spec->{'row'} && length $spec->{'row'}) {
					my $r = $label_node->ancestors($spec->{'row'})->[0];
					$scope = $r if $r;
				}
				my $nodes = $scope ? $scope->find($spec->{'value_selector'}) : Mojo::Collection->new;
				$node = $nodes->[ $spec->{'count'} || 0 ];
			}
			else {
				# a bare label means "the cell or sibling beside it"
				$node = $label_node->next;
			}
		}
		elsif (defined $spec->{'container'} && length $spec->{'container'}) {
			# a label written as bare text (moongiant: "Moon Angle: <span>0.49</span>")
			# has no element to match; walk the container's children instead.
			$node = &web_measure_after_text_label($dom, $spec->{'container'}, $want, $spec->{'label_count'} || 0);
		}
		if ($node) {
			$raw_value = ($attr ne 'text') ? $node->attr($attr) : $node->all_text;
			$used = 'label';
		}
	}

	# 4. HTML row + label + cell (the stable way to read a table)
	if (!defined $raw_value && $dom && defined $spec->{'row'} && length $spec->{'row'}) {
		my @rows = $dom->find($spec->{'row'})->each;
		my @cand;
		my $match = $spec->{'match'};
		foreach my $row (@rows) {
			my $t = &web_measure_clean_text($row->all_text);
			if (defined $match && length $match) {
				if ($match =~ m{^/(.*)/([i]?)$}) { next unless $t =~ /$1/i; }
				else { next unless index(lc($t), lc($match)) >= 0; }
			}
			if (defined $spec->{'contains'} && length $spec->{'contains'}) {
				next unless index(lc($t), lc($spec->{'contains'})) >= 0;
			}
			push @cand, $row;
		}
		my $row = $cand[ $spec->{'row_count'} || 0 ];
		if ($row) {
			my $nodes = (defined $spec->{'within'} && length $spec->{'within'})
				? $row->find($spec->{'within'})
				: Mojo::Collection->new($row);
			my $node = $nodes->[ $spec->{'count'} || 0 ];
			if ($node) {
				$raw_value = ($attr ne 'text') ? $node->attr($attr) : $node->all_text;
				$used = 'row';
			}
		}
	}

	# 5. the classic CSS selector + count. An [id="…"] selector is a JSON id
	# only when there is JSON to read; on an HTML page it is a real selector
	# (tradingeconomics puts prices in <td id="p">).
	if (!defined $raw_value && $dom && defined $spec->{'selector'} && length $spec->{'selector'} && ($spec->{'selector'} !~ /^\s*\[id\s*=/i || !ref $json)) {
		my @nodes = $dom->find($spec->{'selector'})->each;
		if (defined $spec->{'contains'} && length $spec->{'contains'}) {
			@nodes = grep { index(lc(&web_measure_clean_text($_->all_text)), lc($spec->{'contains'})) >= 0 } @nodes;
		}
		my $node;
		if ((defined $spec->{'prev'} && length $spec->{'prev'}) || (defined $spec->{'next'} && length $spec->{'next'})) {
			foreach my $n ( @nodes ) {
				my $p = $n->previous;
				my $q = $n->next;
				my $okp = !defined $spec->{'prev'} || !length $spec->{'prev'} || ($p && index(lc(&web_measure_clean_text($p->all_text)), lc($spec->{'prev'})) >= 0);
				my $okq = !defined $spec->{'next'} || !length $spec->{'next'} || ($q && index(lc(&web_measure_clean_text($q->all_text)), lc($spec->{'next'})) >= 0);
				if ($okp && $okq) { $node = $n; last; }
			}
		}
		$node ||= $nodes[ $spec->{'count'} || 0 ];
		if ($node) {
			$raw_value = ($attr ne 'text') ? $node->attr($attr) : $node->all_text;
			$used = 'selector';
		}
	}

	# 6. named fallbacks
	if (!defined $raw_value && ref $spec->{'fallback'} eq 'ARRAY') {
		foreach my $f ( @{$spec->{'fallback'}} ) {
			next unless ref $f eq 'HASH';
			my $r = &web_measure_extract($f, $ctx);
			return $r if $r->{'ok'};
		}
	}

	unless (defined $raw_value) {
		$result->{'error'} ||= 'no element matched';
		return $result;
	}

	if (defined $spec->{'regex'} && length $spec->{'regex'}) {
		my $re = $spec->{'regex'};
		if ($re =~ m{^/(.*)/([i]?)$}) { $re = $1; }
		if ($raw_value =~ /$re/) { $raw_value = defined $1 ? $1 : $&; }
		else { $result->{'error'} = 'regex did not match'; return $result; }
	}

	$raw_value = &web_measure_clean_text($raw_value);
	if ($spec->{'number'}) {
		my $n = &web_measure_number($raw_value, $spec);
		return { %{$result}, error => 'not a number' } unless defined $n;
		$raw_value = $n;
	}
	return { ok => 1, value => $raw_value, raw => $raw_value, used => $used, error => '', path => $result->{'path'} };
}

# Suggest working specs for a label on this page. The useful shape for a table
# is "the row that contains Gold, cell N", where N is the first cell *after*
# the label. Every candidate is tested against the page before it is offered,
# so a suggestion is a value the extractor will really read.
sub web_measure_suggest {
	my ($ctx, $label) = @_;
	my $dom = $ctx->{'dom'};
	return [] unless $dom && defined $label && length $label;
	my @out;
	my $seen;
	my $add = sub {
		my ($spec, $value) = @_;
		my $key = join '|', map { $_ . '=' . (defined $spec->{$_} ? $spec->{$_} : '') } sort keys %{$spec};
		return if $seen->{$key}++;
		push @out, { spec => $spec, value => $value };
	};
	my $test = sub {
		my ($spec) = @_;
		my $r = &web_measure_extract($spec, $ctx);
		return undef unless $r->{'ok'} && defined $r->{'value'} && length $r->{'value'};
		return &web_measure_clean_text($r->{'value'});
	};

	# the row that holds the label, then the cells after the label's own cell
	my @rows = grep {
		index(lc(&web_measure_clean_text($_->all_text)), lc($label)) >= 0
	} $dom->find('tr')->each;
	foreach my $row ( @rows ) {
		my @cells = $row->find('td, th')->each;
		my $label_idx = -1;
		for my $i ( 0 .. $#cells ) {
			if (index(lc(&web_measure_clean_text($cells[$i]->all_text)), lc($label)) >= 0) { $label_idx = $i; last; }
		}
		next if $label_idx < 0;
		for my $j ( $label_idx + 1 .. $#cells ) {
			my $txt = &web_measure_clean_text($cells[$j]->all_text);
			next unless length $txt;
			my $spec = { row => 'tr', match => $label, within => 'td, th', count => $j };
			my $v = $test->($spec);
			$add->($spec, $v) if defined $v;
		}
		foreach my $sel ( '[data-testid="change"]', '.price', '.value', 'span', 'b', 'strong' ) {
			my $spec = { row => 'tr', match => $label, within => $sel, count => 0 };
			my $v = $test->($spec);
			$add->($spec, $v) if defined $v;
		}
		last if scalar @out >= 4;
	}

	# definition-list / label-and-next shapes
	foreach my $spec ( { label => $label, value => 'next' }, { label => $label, value => 'parent_next' } ) {
		my $v = $test->($spec);
		$add->($spec, $v) if defined $v;
	}

	# a label written as bare text inside a container that has an id
	# (moongiant: "Moon Angle: <span>0.49</span>")
	my $scanned = 0;
	foreach my $box ( $dom->find('[id]')->each ) {
		last if scalar @out >= 4 || $scanned++ >= 200;
		my $kids = $box->children;
		next if scalar @{$kids} > 100;
		my $html = $box->to_string;
		foreach my $child ( @{$kids} ) {
			next unless $child->type eq 'tag';
			next if ($child->tag || '') =~ /^(?:br|hr|wbr)$/i;
			my $markup = $child->to_string;
			my $at = index($html, $markup);
			next if $at <= 0;
			my ($tail) = substr($html, 0, $at) =~ /([^<>]*)$/;
			$tail = &web_measure_clean_text($tail);
			next unless $tail =~ /([A-Za-z][A-Za-z0-9 .\/#%()+_-]{0,40}:)\s*$/;
			my $near = $1;
			next unless index(lc($near), lc($label)) >= 0;
			my $spec = { container => '#' . $box->attr('id'), label => $near };
			my $v = $test->($spec);
			$add->($spec, $v) if defined $v;
			last if scalar @out >= 4;
		}
	}
	return \@out;
}

1;
