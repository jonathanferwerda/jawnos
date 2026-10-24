# tls.pl - DNS credentials and the DNS-01 records a certificate needs.
#
# Loaded by Manager.pl (after subroutines.pl) for the Configure -> Plat -> DNS
# panel, and by scripts/tls_issue.pl for a renewal. The credentials live in the
# `dns` settings app, sealed with the house key like an OAuth client secret, so
# they ride the mesh as ciphertext and never sit in the tree.
#
# Only DNS-01 can validate a wildcard, and it needs no inbound connection, which
# is exactly what a house behind NAT can do. Each provider here writes one TXT
# record at _acme-challenge.<domain> and removes it again.

package tls;

use strict;
use warnings;
no warnings 'uninitialized';

use Mojo::JSON qw(decode_json encode_json);
use Mojo::UserAgent;

# The providers with a real implementation below. `manual` writes nothing: the
# issuer prints the record for a person to add, which is the honest fallback for
# a provider we have not taught yet.
sub dns_providers {
	return [
		{ id => 'cloudflare',   label => 'Cloudflare',   fields => [ [ 'token', 'API token' ] ] },
		{ id => 'godaddy',      label => 'GoDaddy',      fields => [ [ 'key', 'API key' ], [ 'secret', 'API secret' ] ] },
		{ id => 'digitalocean', label => 'DigitalOcean', fields => [ [ 'token', 'API token' ] ] },
		{ id => 'hetzner',      label => 'Hetzner',      fields => [ [ 'token', 'API token' ] ] },
		{ id => 'manual',       label => 'Manual (add the record yourself)', fields => [] },
	];
}

sub dns_provider {
	my ($id) = @_;
	return undef unless defined $id && length $id;
	my ($p) = grep { $_->{'id'} eq $id } @{ &dns_providers() };
	return $p;
}

# The clients the house can issue through: { uuid, name, provider, zone, plus
# the provider's own secret fields }. One entry per zone is the normal case.
sub dns_clients {
	my $raw = &subs::setting_grabber({ app => 'dns', setting => 'clients' });
	my $list = eval { decode_json($raw) } || [];
	return [ grep { ref $_ eq 'HASH' } @{$list} ];
}

sub dns_clients_store {
	my ($list) = @_;
	&subs::setting_setter({ app => 'dns', setting => 'clients', value => encode_json($list) });
}

sub dns_client {
	my ($uuid) = @_;
	return undef unless defined $uuid && length $uuid;
	my ($c) = grep { ($_->{'uuid'} || '') eq $uuid } @{ &dns_clients() };
	return $c;
}

# The client that owns a domain: the longest configured zone that is the domain
# itself or a suffix of it, so dev.example.com is issued through example.com
# and a more specific zone wins when both are configured.
sub dns_client_for {
	my ($domain, $uuid) = @_;
	my $clients = &dns_clients();
	if (defined $uuid && length $uuid) {
		my ($c) = grep { ($_->{'uuid'} || '') eq $uuid } @{$clients};
		return $c;
	}
	my ($best, $best_len);
	foreach my $c ( @{$clients} ) {
		my $zone = $c->{'zone'} || '';
		next unless length $zone;
		next unless $domain eq $zone || $domain =~ /\.\Q$zone\E$/i;
		if (!defined $best_len || length($zone) > $best_len) {
			$best = $c;
			$best_len = length $zone;
		}
	}
	return $best;
}

# A secret is stored sealed; a hand-written plain value still reads, so an older
# row (or a test fixture) is not stranded.
sub dns_plain {
	my ($value) = @_;
	return '' unless defined $value && length $value;
	my $suds = eval { &subs::suds_grabber() };
	return $value unless $suds;
	my $d = eval { &subs::note_decrypter($suds, $value) };
	return (defined $d && length $d) ? $d : $value;
}

sub dns_seal {
	my ($value, $suds) = @_;
	return '' unless defined $value;
	$suds ||= eval { &subs::suds_grabber() };
	return $value unless $suds;
	return &subs::note_encrypter($suds, $value);
}

sub dns_ua {
	my $ua = Mojo::UserAgent->new;
	$ua->connect_timeout(10);
	$ua->request_timeout(30);
	return $ua;
}

# A transaction that failed to connect has no response at all, so every check
# goes through here rather than calling is_success on a possibly-empty res.
sub tx_ok {
	my ($tx) = @_;
	return 0 unless $tx;
	return 0 if $tx->error;
	my $res = $tx->res;
	return 0 unless $res;
	return $res->is_success ? 1 : 0;
}

# The TXT name a domain's validation goes at. CERTBOT_DOMAIN is the base name
# even for a wildcard, so this is the same record for apex and *.
sub dns_record_name {
	my ($domain) = @_;
	return '_acme-challenge.' . $domain;
}

# The part of the record name below the zone. DigitalOcean and Hetzner take the
# relative label; Cloudflare takes the full name.
sub dns_relative_name {
	my ($domain, $zone) = @_;
	my $name = &dns_record_name($domain);
	return $name unless length $zone;
	$name =~ s/\.\Q$zone\E$//i;
	return $name;
}

sub dns_error {
	my ($tx) = @_;
	return 'no response' unless $tx;
	my $res = $tx->res;
	my $body = eval { $res->body } || '';
	my $json = eval { decode_json($body) } || {};
	my $msg = '';
	if (ref $json eq 'HASH') {
		$msg = $json->{'message'} || $json->{'error'} || '';
		if (!$msg && ref $json->{'errors'} eq 'ARRAY') {
			$msg = join('; ', map { ref $_ eq 'HASH' ? ($_->{'message'} || '') : $_ } @{ $json->{'errors'} });
		}
	}
	my $err = eval { $tx->error } || {};
	$msg = $err->{'message'} if !length $msg && ref $err eq 'HASH';
	$msg = substr($body, 0, 200) unless length $msg;
	return ($res ? $res->code . ' ' : '') . $msg;
}

# ---- Cloudflare -------------------------------------------------------------
sub _cf_zone_id {
	my ($ua, $token, $zone) = @_;
	my $tx = $ua->get('https://api.cloudflare.com/client/v4/zones?name=' . $zone => {
		'Authorization' => 'Bearer ' . $token,
		'Content-Type'  => 'application/json',
	});
	return (undef, &dns_error($tx)) unless &tx_ok($tx);
	my $d = eval { $tx->res->json } || {};
	my ($z) = grep { ($_->{'name'} || '') eq $zone } @{ $d->{'result'} || [] };
	return (undef, 'zone not found in this account') unless $z;
	return ($z->{'id'}, '');
}

sub _cf_write {
	my ($client, $domain, $value, $remove) = @_;
	my $ua = &dns_ua();
	my $token = &dns_plain($client->{'token'});
	return (0, 'no API token') unless length $token;
	my $zone = $client->{'zone'} || $domain;
	my ($zid, $err) = &_cf_zone_id($ua, $token, $zone);
	return (0, $err) unless $zid;
	my $name = &dns_record_name($domain);
	my $base = "https://api.cloudflare.com/client/v4/zones/$zid/dns_records";
	my %h = ( 'Authorization' => 'Bearer ' . $token, 'Content-Type' => 'application/json' );
	my $list = $ua->get($base . '?type=TXT&name=' . $name => \%h);
	return (0, &dns_error($list)) unless &tx_ok($list);
	my $ld = eval { $list->res->json } || {};
	my @ids = map { $_->{'id'} } grep { ($_->{'content'} || '') eq $value } @{ $ld->{'result'} || [] };
	if ($remove) {
		my $ok = 1;
		foreach my $id ( @ids ) {
			next unless defined $id && length $id;
			my $del = $ua->delete($base . '/' . $id => \%h);
			$ok = 0 unless &tx_ok($del);
		}
		return ($ok, $ok ? '' : 'could not remove the record');
	}
	return (1, '') if @ids;
	my $tx = $ua->post($base => \%h => json => {
		type    => 'TXT',
		name    => $name,
		content => $value,
		ttl     => 120,
	});
	my $ok = &tx_ok($tx);
	return ($ok ? 1 : 0, $ok ? '' : &dns_error($tx));
}

# ---- GoDaddy ----------------------------------------------------------------
# GoDaddy has no append: a PUT replaces every TXT at that name. Read the list,
# add or drop our value, and write the whole set back, so the apex and wildcard
# validations can coexist.
sub _gd_request {
	my ($method, $url, $key, $secret, $body) = @_;
	my $ua = &dns_ua();
	my %h = (
		'Authorization' => 'sso-key ' . $key . ':' . $secret,
		'Content-Type'  => 'application/json',
	);
	my $tx = $method eq 'PUT'
		? $ua->put($url => \%h => json => $body)
		: $method eq 'DELETE'
			? $ua->delete($url => \%h)
			: $ua->get($url => \%h);
	return $tx;
}

sub _gd_write {
	my ($client, $domain, $value, $remove) = @_;
	my $key = &dns_plain($client->{'key'});
	my $secret = &dns_plain($client->{'secret'});
	return (0, 'no API key/secret') unless length $key && length $secret;
	my $zone = $client->{'zone'} || $domain;
	my $rel = &dns_relative_name($domain, $zone);
	my $url = "https://api.godaddy.com/v1/domains/$zone/records/TXT/$rel";
	my $get = &_gd_request('GET', $url, $key, $secret);
	my @rows;
	if (&tx_ok($get)) {
		my $d = eval { $get->res->json } || [];
		@rows = map { { data => ($_->{'data'} || ''), ttl => ($_->{'ttl'} || 600) } } grep { ref $_ eq 'HASH' } @{$d};
	}
	my @keep = grep { ($_->{'data'} || '') ne $value } @rows;
	if ($remove) {
		return (1, '') if @keep == @rows;    # nothing of ours there
		if (!@keep) {
			my $del = &_gd_request('DELETE', $url, $key, $secret);
			return (1, '') if &tx_ok($del) || ($del->res && $del->res->code == 404);
			return (0, &dns_error($del));
		}
		my $put = &_gd_request('PUT', $url, $key, $secret, \@keep);
		my $ok = &tx_ok($put);
		return ($ok ? 1 : 0, $ok ? '' : &dns_error($put));
	}
	push @keep, { data => $value, ttl => 600 };
	my $put = &_gd_request('PUT', $url, $key, $secret, \@keep);
	my $ok = &tx_ok($put);
	return ($ok ? 1 : 0, $ok ? '' : &dns_error($put));
}

# ---- DigitalOcean -----------------------------------------------------------
sub _do_write {
	my ($client, $domain, $value, $remove) = @_;
	my $token = &dns_plain($client->{'token'});
	return (0, 'no API token') unless length $token;
	my $zone = $client->{'zone'} || $domain;
	my $rel = &dns_relative_name($domain, $zone);
	my $fqdn = &dns_record_name($domain);
	my $ua = &dns_ua();
	my %h = ( 'Authorization' => 'Bearer ' . $token, 'Content-Type' => 'application/json' );
	my $base = "https://api.digitalocean.com/v2/domains/$zone/records";
	my $list = $ua->get($base . '?type=TXT&name=' . $fqdn => \%h);
	return (0, &dns_error($list)) unless &tx_ok($list);
	my $ld = eval { $list->res->json } || {};
	my @ids = map { $_->{'id'} } grep { ($_->{'data'} || '') eq $value } @{ $ld->{'domain_records'} || [] };
	if ($remove) {
		my $ok = 1;
		foreach my $id ( @ids ) {
			next unless defined $id;
			my $del = $ua->delete($base . '/' . $id => \%h);
			$ok = 0 unless &tx_ok($del);
		}
		return ($ok, $ok ? '' : 'could not remove the record');
	}
	return (1, '') if @ids;
	my $tx = $ua->post($base => \%h => json => {
		type => 'TXT',
		name => $rel,
		data => $value,
		ttl  => 30,
	});
	my $ok = &tx_ok($tx);
	return ($ok ? 1 : 0, $ok ? '' : &dns_error($tx));
}

# ---- Hetzner ----------------------------------------------------------------
sub _hz_zone_id {
	my ($ua, $token, $zone) = @_;
	my $tx = $ua->get('https://dns.hetzner.com/api/v1/zones?name=' . $zone => {
		'Auth-API-Token' => $token,
	});
	return (undef, &dns_error($tx)) unless &tx_ok($tx);
	my $d = eval { $tx->res->json } || {};
	my ($z) = grep { ($_->{'name'} || '') eq $zone } @{ $d->{'zones'} || [] };
	return (undef, 'zone not found in this account') unless $z;
	return ($z->{'id'}, '');
}

sub _hz_write {
	my ($client, $domain, $value, $remove) = @_;
	my $token = &dns_plain($client->{'token'});
	return (0, 'no API token') unless length $token;
	my $zone = $client->{'zone'} || $domain;
	my $rel = &dns_relative_name($domain, $zone);
	my $ua = &dns_ua();
	my %h = ( 'Auth-API-Token' => $token, 'Content-Type' => 'application/json' );
	my ($zid, $err) = &_hz_zone_id($ua, $token, $zone);
	return (0, $err) unless $zid;
	my $list = $ua->get('https://dns.hetzner.com/api/v1/records?zone_id=' . $zid => \%h);
	return (0, &dns_error($list)) unless &tx_ok($list);
	my $ld = eval { $list->res->json } || {};
	my @ids = map { $_->{'id'} } grep { ($_->{'type'} || '') eq 'TXT' && ($_->{'name'} || '') eq $rel && ($_->{'value'} || '') eq $value } @{ $ld->{'records'} || [] };
	if ($remove) {
		my $ok = 1;
		foreach my $id ( @ids ) {
			next unless defined $id && length $id;
			my $del = $ua->delete('https://dns.hetzner.com/api/v1/records/' . $id => \%h);
			$ok = 0 unless &tx_ok($del);
		}
		return ($ok, $ok ? '' : 'could not remove the record');
	}
	return (1, '') if @ids;
	my $tx = $ua->post('https://dns.hetzner.com/api/v1/records' => \%h => json => {
		zone_id => $zid,
		type    => 'TXT',
		name    => $rel,
		value   => $value,
		ttl     => 60,
	});
	my $ok = &tx_ok($tx);
	return ($ok ? 1 : 0, $ok ? '' : &dns_error($tx));
}

# Write or remove the validation record. Returns (ok, message).
sub dns_write {
	my ($client, $domain, $value, $remove) = @_;
	return (0, 'no client') unless ref $client eq 'HASH';
	my $p = $client->{'provider'} || '';
	if ($p eq 'cloudflare')   { return &_cf_write($client, $domain, $value, $remove); }
	if ($p eq 'godaddy')      { return &_gd_write($client, $domain, $value, $remove); }
	if ($p eq 'digitalocean') { return &_do_write($client, $domain, $value, $remove); }
	if ($p eq 'hetzner')      { return &_hz_write($client, $domain, $value, $remove); }
	if ($p eq 'manual') {
		return ($remove ? 1 : 0, $remove ? '' : 'manual provider: add TXT ' . &dns_record_name($domain) . ' = ' . $value);
	}
	return (0, 'unknown provider "' . $p . '"');
}

# Does the credential work, and does the zone exist in that account?
sub dns_check {
	my ($client) = @_;
	return (0, 'no client') unless ref $client eq 'HASH';
	my $p = $client->{'provider'} || '';
	my $zone = $client->{'zone'} || '';
	return (0, 'a zone is needed (example.com)') unless length $zone;
	my $ua = &dns_ua();
	if ($p eq 'cloudflare') {
		my $token = &dns_plain($client->{'token'});
		return (0, 'no API token') unless length $token;
		my ($zid, $err) = &_cf_zone_id($ua, $token, $zone);
		return ($zid ? 1 : 0, $zid ? 'zone ' . $zone . ' is reachable' : $err);
	}
	if ($p eq 'godaddy') {
		my $key = &dns_plain($client->{'key'});
		my $secret = &dns_plain($client->{'secret'});
		return (0, 'no API key/secret') unless length $key && length $secret;
		my $tx = &_gd_request('GET', "https://api.godaddy.com/v1/domains/$zone", $key, $secret);
		my $ok = &tx_ok($tx);
		return ($ok ? 1 : 0, $ok ? 'domain ' . $zone . ' is reachable' : &dns_error($tx));
	}
	if ($p eq 'digitalocean') {
		my $token = &dns_plain($client->{'token'});
		return (0, 'no API token') unless length $token;
		my $tx = $ua->get("https://api.digitalocean.com/v2/domains/$zone" => {
			'Authorization' => 'Bearer ' . $token,
		});
		my $ok = &tx_ok($tx);
		return ($ok ? 1 : 0, $ok ? 'domain ' . $zone . ' is reachable' : &dns_error($tx));
	}
	if ($p eq 'hetzner') {
		my $token = &dns_plain($client->{'token'});
		return (0, 'no API token') unless length $token;
		my ($zid, $err) = &_hz_zone_id($ua, $token, $zone);
		return ($zid ? 1 : 0, $zid ? 'zone ' . $zone . ' is reachable' : $err);
	}
	if ($p eq 'manual') { return (1, 'manual mode: the issuer will print the record'); }
	return (0, 'unknown provider');
}

# ---- run status, read by the panel -----------------------------------------
sub tls_status_path {
	return ($ENV{'HOME'} || '.') . '/.president/tls_status.json';
}

sub tls_status_write {
	my ($data) = @_;
	my $path = &tls_status_path;
	my $dir = $path;
	$dir =~ s{/[^/]+$}{};
	mkdir $dir unless -d $dir;
	return 0 unless open my $fh, '>', $path;
	print $fh encode_json($data);
	close $fh;
	chmod 0600, $path;
	return 1;
}

sub tls_status_read {
	my $path = &tls_status_path;
	return {} unless -e $path;
	open my $fh, '<', $path or return {};
	local $/;
	my $raw = <$fh>;
	close $fh;
	return eval { decode_json($raw) } || {};
}

1;
