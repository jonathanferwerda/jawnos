package subs;

# Web: extracted from subroutines.pl (package subs). Loaded on
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
use Socket ();  # resolve a URL host before the house fetches it
use Text::Unidecode;
use Time::Duration;
use Time::HiRes qw(gettimeofday time);
use Time::Local;
use Time::Piece;
use Unicode::Normalize qw(NFC);

our $device;
our $gb;
our $log;
our %m;

# Build the specs a person can choose after clicking a value in the web view:
# a JSON path, a table row, a label/value pair, or - last - the old CSS
# selector + count. Every candidate is run through the extractor, so the list
# only contains shapes that really read this page.
sub web_measure_candidates {
	my ($dom, $json, $selector, $index) = @_;
	return [] unless $dom;
	$index = 0 unless defined $index && $index =~ /^\d+$/;
	my $ctx = { dom => $dom, json => $json, format => (ref $json ? 'json' : 'html') };
	my @out;
	my %seen;
	my $add = sub {
		my ($kind, $spec) = @_;
		return unless ref $spec eq 'HASH';
		my $r = &web_measure_extract($spec, $ctx);
		return unless $r->{'ok'} && defined $r->{'value'} && length $r->{'value'};
		my $key = encode_json($spec);
		return if $seen{$key}++;
		push @out, { kind => $kind, spec => $spec, value => &web_measure_clean_text($r->{'value'}) };
	};

	my @found;
	if (defined $selector && length $selector) {
		my $nodes = eval { $dom->find($selector) };
		@found = $nodes ? $nodes->each : ();
	}
	my $el = $found[$index] || $found[0];

	# 1. the JSON prettyfier puts the concatenated keys in the value span's id
	if (ref $json && $el) {
		my $id = $el->attr('id');
		unless (defined $id && length $id) {
			my $span = $el->ancestors('span[id]')->[0];
			$id = $span->attr('id') if $span;
		}
		if (defined $id && length $id) {
			my $path = &web_measure_json_id_path($json, $id);
			$add->('JSON path', { path => $path }) if defined $path && length $path;
		}
	}

	# 2. the table row and the cell inside it
	my $row = $el ? ($el->tag eq 'tr' ? $el : $el->ancestors('tr')->[0]) : undef;
	my $cell = $el;
	while ($cell && ($cell->tag || '') !~ /^(?:td|th)$/i) { $cell = $cell->parent; }
	if ($row && $cell) {
		my @cells = $row->find('td, th')->each;
		my $cell_index = 0;
		my $s = $cell->previous;
		while ($s) {
			$cell_index++ if $s->type eq 'tag' && ($s->tag || '') =~ /^(?:td|th)$/i;
			$s = $s->previous;
		}
		my $label = @cells ? &web_measure_clean_text($cells[0]->all_text) : '';
		$label = substr($label, 0, 80);
		if (length $label && $label !~ /^[\d.,+\-%\s]+$/) {
			my $row_count = 0;
			foreach my $r ( $dom->find($row->tag)->each ) {
				last if $r->to_string eq $row->to_string;
				$row_count++ if index(lc(&web_measure_clean_text($r->all_text)), lc($label)) >= 0;
			}
			my $tag = $cell->tag;
			my $within = $tag;
			my $count = 0;
			if (my $testid = $cell->attr('data-testid-cell')) {
				$within = $tag . '[data-testid-cell="' . $testid . '"]';
			}
			elsif (my $cid = $cell->attr('id')) {
				$within = $tag . '[id="' . $cid . '"]';
			}
			else {
				$within = 'td, th';
				$count = $cell_index;
			}
			my $spec = { row => $row->tag, match => $label, within => $within, count => $count };
			$spec->{'row_count'} = $row_count if $row_count;
			$add->('table row', $spec);
			$add->('table row', { row => $row->tag, match => $label, within => 'td, th', count => $cell_index }) if $within ne 'td, th';
		}
	}

	# 3. a definition list: <dt>Label:</dt><dd>value</dd>
	if ($el) {
		my $dd = $el;
		while ($dd && ($dd->tag || '') ne 'dd') { $dd = $dd->parent; }
		if ($dd) {
			my $dt = $dd->previous;
			if ($dt && ($dt->tag || '') eq 'dt') {
				my $label = &web_measure_clean_text($dt->all_text);
				$add->('label', { label => $label, value => 'next' }) if length $label;
			}
		}
	}

	# 4. a label written as bare text in a container that has an id
	if ($el && $el->parent) {
		my $parent = $el->parent;
		my $cid = $parent->attr('id');
		if (defined $cid && length $cid) {
			my $html = $parent->to_string;
			my $markup = $el->to_string;
			my $at = index($html, $markup);
			if ($at > 0) {
				my $before = substr($html, 0, $at);
				my ($tail) = $before =~ /([^<>]*)$/;
				$tail = &web_measure_clean_text($tail);
				if ($tail =~ /([A-Za-z][A-Za-z0-9 .\/#%()+_-]{0,40}:?)\s*$/) {
					my $label = $1;
					$add->('label', { container => '#' . $cid, label => $label });
				}
			}
		}
	}

	# 5. the old selector + count, always available as a fallback
	if (defined $selector && length $selector) {
		$add->('selector', { selector => $selector, count => $index });
	}

	return \@out;
}

# app/setting rows, with the local device preferred but a row stored on another
# device still visible. A web measure is an app fact, not a device fact: the
# phone can be the headless browser and still use the selectors configured on
# the computer. Dedupe by $by when a setting has one row per subsetting.
sub setting_rows_for {
	my ($app, $setting, $by) = @_;
	my $dev = &device_setter();
	my $sig = &signatorial_designer();
	my $rows = &db_query(q{
		select * from settings
		where app = ? and setting = ?
		order by case when device = ? or device = ? or device = 'all' or device is null then 0 else 1 end,
		         cast(server_time as integer) desc
	}, $app, $setting, $dev, $sig)->hashes || [];
	if ($by) {
		my %seen;
		@{$rows} = grep { !$seen{ defined $_->{$by} ? $_->{$by} : '' }++ } @{$rows};
	}
	return $rows;
}

sub setting_value_for {
	my ($app, $setting) = @_;
	my $rows = &setting_rows_for($app, $setting);
	return $rows->[0] ? $rows->[0]->{'value'} : undef;
}

# A URL the house may fetch on a resident's behalf: http or https, no userinfo,
# and a host that is neither a private literal nor a name that resolves to one.
# The web app fetches whatever URL it is set to, so without this a resident
# could point it at loopback, the LAN or a cloud metadata endpoint and have the
# answer stored and synced. A literal is judged directly; a name is resolved and
# every answer checked, so evil.example pointing at 127.0.0.1 is refused too. A
# resolver that fails is refused, not guessed at.
sub url_public_http_ok {
	my ($url) = @_;
	return 0 unless defined $url && length $url;
	return 0 unless $url =~ m{\Ahttps?://([^/?#]+)}i;
	my $authority = $1;
	# userinfo (user:pass@host) hides the real host from a casual reader.
	return 0 if $authority =~ /\@/;
	my $host;
	if ($authority =~ /\A\[([^\]]+)\]/) { $host = $1 }   # bracketed IPv6
	else { ($host) = $authority =~ /\A([^:]+)/ }
	return 0 unless defined $host && length $host;
	$host = lc $host;
	return 0 if $host eq 'localhost' || $host =~ /\.localhost\z/;
	# A literal, not the name an address could hide behind. IPv4 and IPv6
	# loopback, RFC1918/ULA, link-local, CGNAT and reserved ranges are refused.
	my $private = sub {
		my ($ip) = @_;
		return 0 unless defined $ip && length $ip;
		$ip = lc $ip;
		if ($ip =~ /:/) {
			return 1 if $ip eq '::' || $ip eq '::1';
			return 1 if $ip =~ /\A::/;                        # unspecified, mapped, compatible
			return 1 if $ip =~ /\Afe[89ab](?::|\z)/;          # fe80::/10 link-local
			return 1 if $ip =~ /\Af[cd][0-9a-f]{0,2}(?::|\z)/; # fc00::/7 unique local
			return 0;
		}
		my @o = split /\./, $ip, 4;
		# Not a dotted quad: a host name, which the resolver below judges.
		return 0 unless @o == 4 && !grep { !/\A\d{1,3}\z/ || $_ > 255 } @o;
		return 1 if $o[0] == 0 || $o[0] == 10 || $o[0] == 127;
		return 1 if $o[0] == 169 && $o[1] == 254;
		return 1 if $o[0] == 172 && $o[1] >= 16 && $o[1] <= 31;
		return 1 if $o[0] == 192 && $o[1] == 168;
		return 1 if $o[0] == 100 && $o[1] >= 64 && $o[1] <= 127;   # CGNAT 100.64/10
		return 1 if $o[0] >= 224;                                  # multicast and reserved
		return 0;
	};
	return 0 if $private->($host);
	my @ip;
	my @res = eval { Socket::getaddrinfo($host, undef, { socktype => Socket::SOCK_STREAM() }) };
	if (@res) {
		my ($err, @addrs) = @res;
		for my $addr (@addrs) {
			my (undef, $num) = eval { Socket::getnameinfo($addr->{'addr'}, Socket::NI_NUMERICHOST()) };
			push @ip, $num if defined $num && length $num;
		}
	}
	return 0 unless @ip;
	for my $ip (@ip) { return 0 if $private->($ip); }
	return 1;
}

sub headless_browser {
	my $changes = 0;
	my $signatorial = &subs::signatorial_designer();
	# A web measure is an app fact, not a device fact. Read the recurrence and
	# URL regardless of the device that configured them; the local row wins when
	# there is more than one. This is what lets the phone be the headless browser
	# while the selectors remain on the computer.
	my $apps = &subs::db_query(q{select distinct app from settings where setting = ? and app is not null and value is not null and value != ?}, 'web_recurring', '')->hashes || [];
	foreach my $a ( @{$apps} ) {
		my $app = $a->{'app'};
		next unless defined $app && length $app;
		my $rw = &subs::setting_rows_for($app, 'web_recurring')->[0] or next;
		# The newest choice wins. A machine keeps its own row and may also see a
		# peer's, so an old row saying "mobile" would keep a phone fetching after
		# the app was moved to the server. Read the newest row, not any row.
		my ($wd) = sort { ($b->{'server_time'} || 0) <=> ($a->{'server_time'} || 0) }
			grep { defined $_->{'value'} && length $_->{'value'} }
			@{ &subs::setting_rows_for($app, 'web_headless_device') };
		next unless $wd;
		my $headless_for = $wd->{'value'};
		next unless $headless_for eq $device || $headless_for eq $signatorial || $headless_for eq 'all';
		# One URL per app, and the newest configuration wins. These rows are per
		# device, so an older machine can still carry a URL the app has moved on
		# from; fetching every row pulled two feeds (a JSON API and its retired
		# HTML page) at once. The history a fetch leaves behind is keyed by URL,
		# so a second URL also kept resetting the first one's last_run.
		my ($w) = sort { ($b->{'server_time'} || 0) <=> ($a->{'server_time'} || 0) }
			grep { defined $_->{'value'} && length $_->{'value'} }
			@{ &subs::setting_rows_for($app, 'web') };
		next unless $w;
		my $url = $w->{'value'};
		my $history = &subs::db_query('select * from websites where app=? and url=? order by timestamp desc', $app, $url)->hashes;
		my $last_run = $history->[0] ? $history->[0]->{'timestamp'} : 0;
		my $recurrence = &time_abbrev_translator($rw->{'value'}) || '1M';
		next unless &subs::rightNow() - $last_run > $recurrence;
		my ($window,$internal_url,$uuid,$timestamp) = &Manager::website_grabber({
			app => $app,
			website => $url,
			timestamp => &subs::rightNow(),
			user_agent => $gb::user_agent,
		});
		$changes = 1;
	}
	if ($changes == 1) {
		my $c = &subs::controller_builder();
		my $update = $c->render_to_string(
			template => 'web',
			app => ''
		);
		&Websocket::send('tab', { type => 'replaceWith', selector => '#web', content => $update });


	}
}

sub telephone_contacts_check {

	return 0 unless $device eq 'mobile';

	my $n = 0;
	my $bridge_contacts = &subs::device_call('contact.list');
	my $contacts = ($bridge_contacts && ref $bridge_contacts->{'contacts'} eq 'ARRAY')
		? $bridge_contacts->{'contacts'}
		: [];
	foreach my $contact ( @{$contacts} ) {
		my $name = &subs::unformat_name($contact->{'name'});
		my $number = $contact->{'number'};
		$number =~ s/\D+//gi;

		next unless $number;

		my $phones = &subs::settings_grabber({ app => $name, settings => ['phone', 'phones', 'uuid' ] });

		# only a person the house already knows: a contact never mints an app
		next unless $phones->{'uuid'};
		next if &subs::contact_matches('phone', $phones->{'phone'}, $number);

		# another number for somebody whose line is already set is another line on
		# them, not a replacement: the phone row keeps what call and text route on,
		# and the typed list holds the rest (mobile, home, work, a custom label).
		if (!$phones->{'phone'}) {
			&subs::setting_setter({ app => $name, setting => 'phone', value => $number });
			$n++;
			next;
		}
		my $list = eval { return decode_json $phones->{'phones'} } || [];
		$list = [ $list ] if ref $list eq 'HASH';
		$list = [] unless ref $list eq 'ARRAY';
		next if grep { ref $_ eq 'HASH' && &subs::contact_matches('phone', $_->{'value'}, $number) } @{$list};
		push @{$list}, {
			uuid => &subs::random_string_creator(20),
			type => 'mobile',
			label => '',
			value => $number
		};
		&subs::setting_setter({ app => $name, setting => 'phones', value => encode_json $list });
		$n++;
	}
	return $n;
}

# The contacts of one kind a person keeps: the plain setting (phone/email) and
# the typed list beside it (phones/emails, rows of {type,label,value}). Comparison
# tidies the way the rest of the code does - a phone to its digits (a leading 1
# dropped) so a country code or spacing never hides a match, an email lowered.
sub contact_normalizer {
	my ($kind, $value) = @_;
	return '' unless defined $value && length $value;
	if ($kind eq 'phone') {
		my $n = $value;
		$n =~ s/\D+//g;
		$n =~ s/^1//;
		return $n;
	}
	my $e = lc $value;
	$e =~ s/^\s+//;
	$e =~ s/\s+$//;
	return $e;
}

sub contact_matches {
	my ($kind, $a, $b) = @_;
	my $x = &subs::contact_normalizer($kind, $a);
	my $y = &subs::contact_normalizer($kind, $b);
	return 0 unless length $x && length $y;
	if ($kind eq 'phone') {
		$x = substr $x, -10 if length $x >= 10;
		$y = substr $y, -10 if length $y >= 10;
	}
	return $x eq $y ? 1 : 0;
}

# Every app whose records hold this phone or email: the plain setting first
# (phone/email), then the typed list (phones/emails). A match is the address, so
# the two are scanned the same way - a number kept as somebody's work line names
# them as surely as the one on the app.
sub contact_apps {
	my ($kind, $value) = @_;
	return () unless defined $value && length $value;
	my (%seen, @apps);
	my $plain = &subs::db_query('select app, value from settings where setting=? and value != ?', $kind, '')->hashes;
	foreach my $r ( @{$plain} ) {
		next unless &subs::contact_matches($kind, $r->{'value'}, $value);
		push @apps, $r->{'app'} unless $seen{ $r->{'app'} }++;
	}
	my $rows = &subs::db_query('select app, value from settings where setting=? and value != ?', $kind . 's', '')->hashes;
	foreach my $r ( @{$rows} ) {
		my $list = eval { return decode_json $r->{'value'} } || [];
		$list = [ $list ] if ref $list eq 'HASH';
		next unless ref $list eq 'ARRAY';
		foreach my $c ( @{$list} ) {
			next unless ref $c eq 'HASH';
			next unless &subs::contact_matches($kind, $c->{'value'}, $value);
			push @apps, $r->{'app'} unless $seen{ $r->{'app'} }++;
		}
	}
	return @apps;
}

# Every line the house holds of one kind, one app's under it: the plain setting
# (phone/email) first and marked primary, then the typed list (phones/emails) with
# its type and label. A person with a home and a work line is one entry with all
# of them, not one per number - which is what the Phone app's directory and
# Chat's friends both want. Pass $only_app to read just one person's lines.
sub contact_lines {
	my ($kind, $only_app) = @_;
	my $mine = (defined $only_app && length $only_app) ? $only_app : undef;
	my %lines;
	my $plain = &subs::db_query('select app, value, server_time from settings where setting=? and value != ? order by server_time desc', $kind, '')->hashes;
	foreach my $r ( @{$plain} ) {
		my $app = $r->{'app'};
		next if $mine && $app ne $mine;
		next if exists $lines{$app};
		my $v = $r->{'value'};
		next unless defined $v && length $v;
		$lines{$app} = [ { value => $v, type => '', label => '', primary => 1 } ];
	}
	my $lists = &subs::db_query('select app, value from settings where setting=? and value != ?', $kind . 's', '')->hashes;
	foreach my $r ( @{$lists} ) {
		my $app = $r->{'app'};
		next if $mine && $app ne $mine;
		my $list = eval { return decode_json $r->{'value'} } || [];
		$list = [ $list ] if ref $list eq 'HASH';
		next unless ref $list eq 'ARRAY';
		$lines{$app} ||= [];
		my %seen = map { &subs::contact_normalizer($kind, $_->{'value'}) => 1 } @{ $lines{$app} };
		foreach my $c ( @{$list} ) {
			next unless ref $c eq 'HASH';
			my $v = $c->{'value'};
			next unless defined $v && length $v;
			my $key = &subs::contact_normalizer($kind, $v);
			next if $key && $seen{$key}++;
			push @{ $lines{$app} }, { value => $v, type => ($c->{'type'} || ''), label => ($c->{'label'} || ''), primary => 0 };
		}
	}
	return \%lines;
}

# How one line reads in a list: the number or address, and - for a line beyond
# the first - its type in front of it (a custom entry wears its own label). A
# blocked line says so.
sub contact_line_label {
	my $l = shift;
	my $text = $l->{'value'};
	my $type = $l->{'type'} || '';
	my $label = $l->{'label'} || '';
	my $name = ($type eq 'custom' && length $label) ? $label : $type;
	$text = $name . ' ' . $text if length $name && !$l->{'primary'};
	$text .= ' (blocked)' if $l->{'blocked'};
	return $text;
}

# The app a number belongs to: the person who saved it, or - when the house
# does not know the number - the number itself, filed as an app of its own so
# a stranger's calls and texts still land somewhere, and naming that app later
# turns the stranger into a person. The phone row is made at the same time, so
# the next call or text from the same number resolves the same way. Matching is
# on the last ten digits of both sides, the way the call-log check learned to,
# and covers the typed list as well as the plain phone row.
sub phone_number_app {
	my $number = shift;
	$number =~ s/\D+//g;
	$number =~ s/^1//;
	return '' unless $number;
	my @known = &subs::contact_apps('phone', $number);
	return $known[0] if scalar @known;
	# unknown: the number becomes the app, and the row makes it known
	&subs::setting_setter({ app => $number, setting => 'phone', value => $number });
	return $number;
}

sub telephone_call_log_check {

	return 0 unless $device eq 'mobile';

	my $n = 0;
	my $bridge_calls = &subs::device_call('telephony.call_log', { limit => 30 });
	my $calls = ($bridge_calls && ref $bridge_calls->{'calls'} eq 'ARRAY')
		? $bridge_calls->{'calls'}
		: [];

	foreach my $call ( grep { $_->{'phone_number'} =~ /\d/ } @{$calls} ) {
		my $name = &subs::unformat_name($call->{'name'});
		my $number = $call->{'phone_number'};
		$number =~ s/\D+//gi;
		my $timestamp = &subs::epoch_or_span($call->{'date'},&subs::rightNow());

		my @duration = split /:/, $call->{'duration'};


		my $duration = '';
		if (scalar @duration == 3) {
			$duration .= $duration[0] . 'h ';
			$duration .= $duration[1] . 'm ';
			$duration .= $duration[2] . 's';
		}
		else {
			$duration .= $duration[0] . 'm ';
			$duration .= $duration[1] . 's';
		}
		$duration = &subs::time_abbrev_translator($duration);


		# the log carries the number in whatever shape the carrier sent it (+1…,
		# bare digits, sometimes with the country code) while the house keeps its
		# contacts as they were typed (519-849-5604, 2263493283, the odd +1…).
		# Match on the last ten digits of both: a raw substring test meant a
		# contact stored without the country code (or with dashes) never met its
		# own call - which is why a working termux-call-log still filed nothing.
		# (the matching itself lives in phone_number_app)
		# an unknown caller is still a call: file it on the number's own app
		# (the number becomes the app), rather than dropping it on the floor
		my $app = &subs::phone_number_app($number) || 'phone';

		# the live phone app may already have written this call as it happened
		# (window.JawnPhoneEvent): skip it so a live call and its call-log trail
		# are one appointment, not two
		my $live = &subs::db_query('select uuid from appointments where subtype=? and timestamp between ? and ? limit 1', 'phone', $timestamp - 180000, $timestamp + 180000)->hashes;
		next if scalar @{$live} > 0;

		my $appts = &subs::db_query('select * from appointments where app=? and timestamp = ?', $app, $timestamp)->hashes;
		unless (scalar @{$appts} > 0) {
			my $data = {
				app => $app,
				type => 'start',
				duration => '-' . $duration,
				timestamp => $timestamp,
				stop_timestamp => ($timestamp + $duration),
				seen => 'yes',
				subtype => 'phone'
			};

			my $c = &subs::controller_builder();
			&Manager::appointment_writer($c,$data);
			$n++;
		}
	}
	return $n;
}

sub appt_toggle_checker {
	my $app = shift;
	return unless $app;
	my $server_time = &subs::rightNow();
	my $toggle = 'off';
	# An open row is a running session, however long it has run. The configured
	# duration is only a guess - a real session can be much longer - so elapsed
	# time must never turn an appointment off by itself. Doing that made a place
	# whose session outlived its estimate look stopped: navigation then started a
	# fresh session on every tick while the old one was still open.
	my $open = &subs::db_query('select timestamp from appointments where app=? and (type=? or type=?) and stop_seen is null and timestamp <= ? order by timestamp desc limit 1', $app, 'start', 'record', $server_time)->hashes->[0];
	$toggle = 'on' if $open;
	# rewriting an unchanged toggle cost two writes and a websocket message on
	# every header render
	my $current = &subs::setting_grabber({ app => $app, setting => 'toggle' });
	if (!(defined $current && $current eq $toggle)) {
		my %tog_write = (app => $app, setting => 'toggle', value => $toggle);
		# the open session names the moment this derived state belongs to, so a
		# late check cannot repaint a toggle a newer switch event already set
		$tog_write{'timestamp'} = $open->{'timestamp'} if $open;
		&subs::setting_setter(\%tog_write);
	}
	return $toggle;
}

# ---- warehouse / inventory helpers -----------------------------------------

# Where are we right now? navigation_automation starts a place when GPS says we
# are in it, which shows up as its 'toggle' being on. A device without GPS
# (laptop/desktop) can't do that, so we fall back to whichever running place is
# flagged with inventory ability.
sub current_place {
	my $q = &db_query('select app from settings where setting=? and value=?', 'toggle', 'on');
	my $toggled = $q ? $q->hashes : [];
	my ($inventory, $fallback);
	foreach my $t ( @{$toggled} ) {
		my $app = $t->{'app'};
		my $pin = &db_query('select app from settings where app=? and (setting=? or setting=?) and value=? limit 1', $app, 'pos', 'mab', 'place');
		next unless ($pin && $pin->hashes->[0]);
		$fallback = $app unless $fallback;
		my $inv = &setting_grabber({ app => $app, setting => 'inventory_ability' });
		$inventory = $app if $inv && $inv eq 'on';
	}
	return $inventory || $fallback || '';
}

# Split a typed quantity from its unit: "355mL" -> (355, mL), "12" ->
# (12, default). A known measure is returned in its canonical spelling (mL, not
# ml); with keep_unknown an unrecognised letter unit is returned as written so a
# caller can refuse it rather than silently count it as a bare number.
sub quantity_unit_split {
	my ($raw, $default_unit, $keep_unknown) = @_;
	$raw = '' unless defined $raw;
	my $unit = '';
	my $letters = $raw;
	$letters =~ s/[^a-zA-Z]//g;
	if (length $letters) {
		my ($match) = grep { lc($_) eq lc($letters) } keys %{$gb::measures};
		$unit = $match || ($keep_unknown ? $letters : '');
		$raw =~ s/[a-zA-Z]//g;
	}
	my $quantity = &numeric_formatter($raw) + 0;
	$unit = $default_unit unless length $unit;
	return ($quantity, $unit);
}

# What an item has on hand at one place and unit: the same signed stock rows the
# Levels view sums, but scoped so a consumption can take only what is on that
# shelf. Usage rows are history, not stock, and are left out.
sub warehouse_on_hand_at {
	my ($item, $unit, $place) = @_;
	return 0 unless defined $item && length $item;
	$unit = 'each' unless defined $unit && length $unit;
	my $q = &db_query("select coalesce(sum(cast(quantity as real)),0) as q from warehouse where item=? and unit=? and place=? and coalesce(nullif(kind,''),'stock')='stock'", $item, $unit, $place);
	# hashes drains the result set, so read it once: asking twice made the second
	# read empty and every consumption look like it had no stock to take
	my $rows = $q ? $q->hashes : undef;
	return ($rows && $rows->[0]) ? $rows->[0]->{'q'} + 0 : 0;
}

# What an item has on hand right now: its signed stock rows summed per unit, the
# same figure the warehouse Levels view shows. A money row (it names an account)
# and a balance anchor (kind inventory) are not stock and are left out, the way
# warehouse_grabber reads them.
sub warehouse_stock_for {
	my ($item) = @_;
	return {} unless $item && $item ne '';
	my $rows = &db_query('select quantity, unit, kind, type, account from warehouse where item = ?', $item);
	my %stock;
	foreach my $r ( @{ $rows ? $rows->hashes : [] } ) {
		my $kind = $r->{'kind'};
		$kind = ($r->{'type'} eq 'inventory' ? 'inventory' : (($r->{'account'} && $r->{'account'} ne '') ? 'money' : 'stock')) if !defined $kind || $kind eq '';
		next unless $kind eq 'stock';
		my $unit = $r->{'unit'} || 'each';
		$stock{$unit} += &numeric_formatter($r->{'quantity'}) + 0;
	}
	return \%stock;
}

# What an item has on hand, in the unit its own app names (its `unit` setting),
# else its sole unit - what a fixed-level quantity budget reads. Zero when nothing
# of it is stocked.
sub warehouse_on_hand {
	my ($item, $settings) = @_;
	my $stock = &warehouse_stock_for($item);
	my $unit = $settings && $settings->{'unit'};
	return $stock->{$unit} + 0 if $unit && defined $stock->{$unit};
	my @units = grep { defined $stock->{$_} } keys %{$stock};
	return 0 unless scalar @units == 1;
	return $stock->{$units[0]} + 0;
}

# How to reach a stock target from what is on hand now, in whole packages where
# the item names them: a shortfall of four covered by a six-pack reads "buy one
# six-pack". The smallest pack that covers the shortfall is bought once; when no
# pack covers it the biggest is repeated; with no packaging at all the bare
# shortfall is the answer.
sub warehouse_restock_for {
	my ($item, $target) = @_;
	my $settings = &settings_grabber({ app => $item });
	my $on_hand = &warehouse_on_hand($item, $settings);
	my $short = ($target || 0) - $on_hand;
	my $plan = { item => $item, on_hand => $on_hand, target => ($target || 0), short => ($short > 0 ? $short : 0), buy => undef };
	return $plan unless $short > 0;
	my $packaging = eval { return decode_json &setting_grabber({ app => $item, setting => 'app_packaging' }) }
		|| eval { return decode_json &setting_grabber({ app => $item, setting => 'packaging' }) }
		|| {};
	my @packs = sort { $a->{'quantity'} <=> $b->{'quantity'} }
		map { { name => $packaging->{$_}->{'name'}, quantity => ($packaging->{$_}->{'quantity'} + 0) } }
		grep { ref $packaging->{$_} eq 'HASH' && ($packaging->{$_}->{'quantity'} || '') =~ /[0-9]/ }
		keys %{$packaging};
	my ($covers) = grep { $_->{'quantity'} >= $short } @packs;
	if ($covers) {
		$plan->{'buy'} = { %{$covers}, count => 1, units => $covers->{'quantity'} };
	}
	elsif (scalar @packs) {
		my $pack = $packs[-1];
		my $count = int(( $short + $pack->{'quantity'} - 1 ) / $pack->{'quantity'});
		$plan->{'buy'} = { %{$pack}, count => $count, units => $count * $pack->{'quantity'} };
	}
	else {
		$plan->{'buy'} = { name => 'each', quantity => 1, count => $short, units => $short };
	}
	return $plan;
}

# The shelf life (e.g. '3w') declared on an item's packaging, if any.
sub warehouse_item_expires {
	my $item = shift;
	my $packaging = eval { return decode_json &setting_grabber({ app => $item, setting => 'packaging' }) } || {};
	foreach my $p ( values %{$packaging} ) {
		next unless ref $p eq 'HASH';
		my $exp = $p->{'expires'};
		return $exp if $exp && $exp ne '';
	}
	return '';
}

# Where does an item live? Most specific first: a 'stock_place' setting on the
# item (or its app), then the older 'place' setting on either, a 'default_place'
# on the item's packaging, the app itself when it is a place (pos=place), and
# finally wherever we currently are. Returns '' when nothing resolves, and
# callers treat that as "do not touch stock".
sub warehouse_place_for {
	my ($app,$item) = @_;
	foreach my $subject ( $item, $app ) {
		next unless $subject;
		foreach my $key ( qw/stock_place place/ ) {
			my $q = &db_query('select value from settings where app=? and setting=? limit 1', $subject, $key);
			my $s = $q ? $q->hashes->[0] : undef;
			return $s->{'value'} if $s->{'value'} && $s->{'value'} ne '';
		}
	}
	if ($item) {
		my $packaging = eval { return decode_json &setting_grabber({ app => $item, setting => 'packaging' }) } || {};
		foreach my $p ( values %{$packaging} ) {
			next unless ref $p eq 'HASH';
			return $p->{'default_place'} if $p->{'default_place'} && $p->{'default_place'} ne '';
		}
	}
	if ($app) {
		my $q = &db_query('select value from settings where app=? and setting=? and value=? limit 1', $app, 'pos', 'place');
		return $app if ($q && $q->hashes->[0]);
	}
	return &current_place();
}

# The journal metadata stored in a warehouse row's data column: why the stock
# moved, what app it came from, and the uuid of the document that caused it.
sub warehouse_journal_entry {
	my $d = shift;
	return encode_json {
		reason => $d->{'reason'},
		source => $d->{'source'},
		source_uuid => $d->{'source_uuid'}
	};
}

# Record a stock movement. Positive quantity puts stock in, negative takes it
# out. Only called once a place is known, so stock never lands unplaced.
sub warehouse_movement {
	my $d = shift;
	my $item = $d->{'item'};
	my $quantity = &numeric_formatter($d->{'quantity'}) + 0;
	return unless $item && $quantity != 0;
	my $wdata = {
		timestamp => $d->{'timestamp'} || &rightNow(),
		server_time => &rightNow(),
		item => $item,
		model => $d->{'model'},
		options => $d->{'options'},
		uuid => &random_string_creator(40),
		quantity => $quantity,
		unit => $d->{'unit'} || 'each',
		place => $d->{'place'},
		# the warehouse has three faces now; this writer only ever moves stock
		kind => $d->{'kind'} || 'stock',
		type => $d->{'type'} || 'stock',
		account => $d->{'account'},
		project => $d->{'project'},
		warranty => $d->{'warranty'},
		app_uuid => $d->{'app_uuid'},
		data => &warehouse_journal_entry($d)
	};
	&db_insert('warehouse', $wdata);
	return $wdata;
}

# Record consumption that had no stock to take from. It is a history row, not a
# stock row: the Levels view and every balance ignore it, while the moves view
# and the item's journal still show that the amount was used. This is the drink
# that came from outside the warehouse - counted, but not owed to it.
sub warehouse_usage {
	my $d = shift;
	my $item = $d->{'item'};
	my $quantity = &numeric_formatter($d->{'quantity'}) + 0;
	return unless $item && $quantity;
	my $wdata = {
		timestamp => $d->{'timestamp'} || &rightNow(),
		server_time => &rightNow(),
		item => $item,
		model => $d->{'model'},
		options => $d->{'options'},
		uuid => &random_string_creator(40),
		quantity => $quantity,
		unit => $d->{'unit'} || 'each',
		place => $d->{'place'},
		kind => 'usage',
		type => 'usage',
		project => $d->{'project'},
		app_uuid => $d->{'app_uuid'},
		data => &warehouse_journal_entry($d)
	};
	&db_insert('warehouse', $wdata);
	return $wdata;
}

1;
