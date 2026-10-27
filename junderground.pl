#!/usr/bin/perl
# The JawnOS side of the junderground client.
#
# The browser never holds the house key: every request to a junderground is
# signed here, with the crest key the house already keeps for its crest, over
# the junderground request message:
#
#   METHOD \n PATH?QUERY \n sha256hex(body) \n timestamp \n nonce
#
# The client only needs the switch URL and the house handle; everything else -
# registration, dialling, tokens, presence, grading - is derived from the crest
# and the house's own people/blacklist settings.
use strict;
use warnings;
use JSON::PP;
use MIME::Base64;
use Digest::SHA qw(sha256_hex);
use Crypt::PK::Ed25519;
use Mojo::UserAgent;
use URI::Escape qw(uri_escape);

our $jg_json = JSON::PP->new->canonical(1);

sub jg_setting {
	my ($key, $value) = @_;
	my $device = &subs::device_setter();
	if (defined $value) {
		&subs::setting_setter({ app => 'junderground', setting => $key, device => $device, value => $value });
	}
	return &subs::setting_grabber({ app => 'junderground', setting => $key, device => $device }) || '';
}

sub jg_url {
	my $u = &jg_setting('url');
	$u =~ s{/+$}{};
	return $u;
}

sub jg_slug {
	my ($v) = @_;
	$v = lc($v // '');
	$v =~ s/[^a-z0-9._-]+/_/g;
	$v =~ s/^_+|_+$//g;
	return substr($v, 0, 63);
}

sub jg_handle {
	my ($crest) = @_;
	my $h = &jg_slug(&jg_setting('handle'));
	return $h if length $h;
	$crest ||= &subs::crest_record_read();
	$h = &jg_slug($crest->{'name'} || '');
	return $h if length $h;
	return 'house_' . substr(sha256_hex($crest->{'pubkey'} || 'x'), 0, 8);
}

sub jg_b64url {
	my ($bytes) = @_;
	my $b = encode_base64($bytes // '', '');
	$b =~ tr{+/}{-_};
	$b =~ s/=+$//;
	return $b;
}

sub jg_nonce {
	my $raw = '';
	if (open my $fh, '<', '/dev/urandom') {
		binmode $fh;
		read($fh, $raw, 12);
		close $fh;
	}
	$raw = pack('N3', time, $$, int(rand(1_000_000))) unless length $raw;
	return &jg_b64url($raw);
}

sub jg_ua {
	my $ua = Mojo::UserAgent->new(timeout => 10, max_redirects => 0);
	$ua->insecure(1) if (&jg_setting('insecure') || '') eq 'yes';
	return $ua;
}

sub jg_key {
	my ($c) = @_;
	my $key = &subs::crest_key_read($c->session('suds'));
	return (defined $key && length $key == 32) ? $key : undef;
}

sub jg_call {
	my ($c, $method, $path, $body, $auth) = @_;
	my $base = &jg_url();
	return { error => 'no junderground url' } unless length $base;

	my %headers = ('content-type' => 'application/json');
	if ($auth) {
		my $priv = &jg_key($c);
		return { error => 'house key locked' } unless $priv;
		my $crest = &subs::crest_record_read();
		my $handle = &jg_handle($crest);
		return { error => 'no house handle' } unless length $handle;

		my $ts = time;
		my $nonce = &jg_nonce();
		my $msg = join("\n", $method, $path, sha256_hex($body // ''), $ts, $nonce);
		my $key = Crypt::PK::Ed25519->new;
		$key->import_key_raw($priv, 'private');
		$headers{'x-jg-handle'} = $handle;
		$headers{'x-jg-timestamp'} = $ts;
		$headers{'x-jg-nonce'} = $nonce;
		$headers{'x-jg-signature'} = encode_base64($key->sign_message($msg), '');
	}

	my $ua = &jg_ua();
	my $tx = ($method eq 'GET')
		? $ua->get($base . $path => \%headers)
		: $ua->request($method => $base . $path => \%headers => ($body // ''));

	my $res = $tx->res;
	my $decoded = eval { decode_json($res->body) } || {};
	$decoded->{'http'} = $res->code;
	if ($res->code >= 400 && !$decoded->{'error'}) {
		$decoded->{'error'} = 'http ' . $res->code;
	}
	return $decoded;
}

sub jg_register {
	my ($c) = @_;
	my $priv = &jg_key($c) or return { error => 'house key locked' };
	my $crest = &subs::crest_record_read();
	my $pub = $crest->{'pubkey'} || '';
	return { error => 'this house has no crest yet' } unless length $pub;
	my $handle = &jg_handle($crest);

	# Continue the chain when the switch already has this house's head.
	my $head = &jg_call($c, 'GET', '/v1/houses/' . $handle, '', 0);
	my ($seq, $prev) = (1, undef);
	if (ref $head->{'record'} eq 'HASH' && ($head->{'record'}{'pubkey'} || '') eq $pub) {
		$seq = ($head->{'record'}{'seq'} || 0) + 1;
		$prev = $head->{'record'}{'sig'};
	}

	my $record = {
		format => 'junderground-house',
		version => 1,
		kind => 'register',
		handle => $handle,
		name => $crest->{'name'} || $handle,
		pubkey => $pub,
		seq => $seq,
		issued => time,
		routes => {},
		crest => {
			uuid => $crest->{'uuid'} || '',
			name => $crest->{'name'} || $handle,
			pubkey => $pub,
		},
	};
	$record->{'prev'} = $prev if defined $prev && length $prev;

	my $signed = &subs::crest_sign_record($record, $priv) or return { error => 'could not sign the house record' };
	return &jg_call($c, 'POST', '/v1/houses', $jg_json->encode($signed), 0);
}

sub jg_dial_query {
	my ($c, $picks) = @_;
	my @qs;
	foreach my $kind (sort keys %{$picks || {}}) {
		my $value = $picks->{$kind};
		next unless defined $value && length $value;
		utf8::encode($value) if utf8::is_utf8($value);
		push @qs, uri_escape($kind) . '=' . uri_escape($value);
	}
	my $path = '/v1/dial' . (@qs ? '?' . join('&', @qs) : '');
	return &jg_call($c, 'GET', $path, '', 0);
}

# The switch's identity for a room is a slug, and its *name* is in the
# administrator's language. A value the switch does not know comes back in
# `unknown`, so it is translated here (through the Guide's engine, cached) and
# the dial is repeated once: two houses dialling Munich in two languages then
# arrive at the same room. With no model configured the first answer stands.
sub jg_dial {
	my ($c, $picks) = @_;
	my $first = &jg_dial_query($c, $picks);
	return $first if $first->{'error'};
	return $first unless ref $first->{'unknown'} eq 'HASH' && %{ $first->{'unknown'} };

	my $target = $first->{'language'} || '';
	my $house = &subs::language();
	return $first unless length $target && $target ne $house;

	my @values = grep { defined $_ && length $_ } values %{ $first->{'unknown'} };
	return $first unless @values;

	my $engine = &subs::translate_engine({ to => $target, strings => \@values });
	return $first unless $engine->{'ok'} && ref $engine->{'translations'} eq 'HASH';

	my %next = %{ $picks || {} };
	my $changed = 0;
	foreach my $kind (keys %{ $first->{'unknown'} }) {
		my $value = $first->{'unknown'}{$kind};
		next unless defined $value && length $value;
		my $translated = $engine->{'translations'}{$value};
		next unless defined $translated && length $translated && $translated ne $value;
		$next{$kind} = $translated;
		$changed = 1;
	}
	return $first unless $changed;

	my $second = &jg_dial_query($c, \%next);
	return $second->{'error'} ? $first : $second;
}

sub jg_room {
	my ($c, $handle, $room) = @_;
	my $h = &jg_slug($handle);
	my $r = &jg_slug($room);
	return { error => 'no room' } unless length $h && length $r;

	my %out;
	$out{'room'} = &jg_call($c, 'GET', "/v1/rooms/$h/$r", '', 0);
	$out{'rentals'} = &jg_call($c, 'GET', "/v1/rooms/$h/$r/rentals", '', 0);
	$out{'door'} = &jg_call($c, 'GET', "/v1/rooms/$h/$r/door", '', 0);
	$out{'presence'} = &jg_call($c, 'GET', "/v1/rooms/$h/$r/presence", '', 0);
	$out{'grade'} = &jg_grade($out{'presence'}{'roster'} || []);
	return \%out;
}

sub jg_join {
	my ($c, $handle, $room, $ticket) = @_;
	my $h = &jg_slug($handle);
	my $r = &jg_slug($room);
	return { error => 'no room' } unless length $h && length $r;

	my $body = { caps => ['join', 'publish_audio', 'subscribe'] };
	$body->{'ticket'} = $ticket if defined $ticket && length $ticket;
	my $token = &jg_call($c, 'POST', "/v1/rooms/$h/$r/token", $jg_json->encode($body), 1);
	return $token if $token->{'error'} || !$token->{'grant'};

	my $presence = &jg_call($c, 'POST', "/v1/rooms/$h/$r/presence",
		$jg_json->encode({ grant => $token->{'grant'} }), 1);
	$presence->{'grant'} = $token->{'grant'};
	$presence->{'role'} = $token->{'role'};
	$presence->{'ticketed'} = $token->{'ticketed'};
	$presence->{'grade'} = &jg_grade($presence->{'roster'} || []);
	return $presence;
}

sub jg_leave {
	my ($c, $handle, $room, $presence_id) = @_;
	my $h = &jg_slug($handle);
	my $r = &jg_slug($room);
	return { error => 'no room' } unless length $h && length $r;
	return &jg_call($c, 'POST', "/v1/rooms/$h/$r/presence/leave",
		$jg_json->encode({ presence_id => $presence_id // '' }), 1);
}

sub jg_people_key {
	my ($value) = @_;
	$value = lc($value // '');
	$value =~ s/^\s+|\s+$//g;
	return $value;
}

# The house grades the roster; the switch never sees the relationship map.
sub jg_grade {
	my ($roster) = @_;
	my %rel;
	foreach my $key (qw/blacklist hostile known/) {
		my $relation = $key eq 'blacklist' ? 'blacklist' : $key;
		foreach my $value (split /,/, &jg_setting($key)) {
			my $k = &jg_people_key($value);
			$rel{$k} = $relation if length $k;
		}
	}

	my @subjects = grep { defined $_ && length $_ } map { $_->{'subject'} } @{$roster || []};
	my %count = (known => 0, blacklisted => 0, hostile => 0, unknown => 0);
	foreach my $subject (@subjects) {
		my $relation = $rel{&jg_people_key($subject)} || '';
		if ($relation eq 'blacklist') { $count{'blacklisted'}++ }
		elsif ($relation eq 'hostile') { $count{'hostile'}++ }
		elsif ($relation eq 'known') { $count{'known'}++ }
		else { $count{'unknown'}++ }
	}

	my @flags;
	push @flags, 'blacklisted' if $count{'blacklisted'};
	push @flags, 'hostile' if $count{'hostile'};
	push @flags, 'stranger' if $count{'unknown'};

	my $grade = 'empty';
	if (!@subjects) { $grade = 'empty' }
	elsif ($count{'blacklisted'} || $count{'hostile'}) { $grade = 'hostile' }
	elsif ($count{'unknown'} == scalar @subjects) { $grade = 'strangers' }
	elsif ($count{'unknown'}) { $grade = 'mixed' }
	elsif ($count{'known'} == scalar @subjects) { $grade = 'known' }
	else { $grade = 'trusted' }

	return {
		grade => $grade,
		flags => \@flags,
		block => ($count{'blacklisted'} ? 1 : 0),
		counts => \%count,
		subjects => \@subjects,
	};
}

1;
