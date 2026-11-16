package subs;

# Relay: the applications that arrived through thejunderground. The switch
# stores them where an applicant with no house identity can reach the house; the
# Box Office pulls them over the signed rail and lands each as an ordinary
# request ticket, so the existing approve/decline flow keeps working.
#
# A relayed application is never trusted for privilege: it always arrives as a
# guest request, and the switch never sees the person or the roles the house
# grants. The relay id is kept in the ticket's information so a second pull does
# not import it twice.
#
# Loaded on demand by lib/JawnOS/Domain/Loader.pm.
use strict;
use warnings;

use Mojo::JSON qw(decode_json encode_json);

# The information blob a request row carries for a relayed application. Undef
# when the switch's row is not shaped like an application at all.
sub relay_application_info {
	my ($app, $handle) = @_;
	return undef unless ref $app eq 'HASH';
	my $id = $app->{'id'} // '';
	return undef unless $id =~ /^[A-Za-z0-9_-]{8,64}$/;
	my $name = $app->{'name'} // '';
	$name =~ s/^\s+|\s+$//g;
	return undef unless length $name;
	my $info = {
		name => substr($name, 0, 200),
		source => 'relay',
		relay_id => $id,
		relay_handle => (defined $handle ? "$handle" : ''),
		consent => 'on',
	};
	foreach my $key ( qw(email phone description interview trial) ) {
		my $value = $app->{$key};
		next unless defined $value && !ref $value && length $value;
		$value =~ s/^\s+|\s+$//g;
		$info->{$key} = substr($value, 0, ($key eq 'description' ? 2000 : $key eq 'trial' ? 1000 : 300))
			if length $value;
	}
	$info->{'roles'} = [ grep { defined $_ && !ref $_ && length $_ } @{ $app->{'roles'} } ]
		if ref $app->{'roles'} eq 'ARRAY';
	$info->{'crest'} = $app->{'crest'} if ref $app->{'crest'} eq 'HASH';
	return $info;
}

sub relay_application_row {
	my ($app, $handle) = @_;
	my $info = &relay_application_info($app, $handle);
	return undef unless $info;
	my $now = &rightNow();
	my $created = $app->{'created'};
	my $timestamp = (defined $created && $created =~ /^\d{9,}$/) ? $created * 1000 : $now;
	my $crest_uuid = (ref $app->{'crest'} eq 'HASH' && ($app->{'crest'}->{'uuid'} // '') =~ /^[A-Za-z0-9_-]{4,64}$/)
		? $app->{'crest'}->{'uuid'} : '';
	return {
		uuid => &random_string_creator(35),
		name => $info->{'name'},
		timestamp => $timestamp,
		server_time => $now,
		status => 'request',
		privilege => 'guest',
		information => encode_json($info),
		crest_uuid => $crest_uuid,
		ip => '',
	};
}

# Has this relay id already landed as a ticket? A relayed application that was
# approved keeps its id in the minted ticket's information too, so the whole
# table is scanned rather than only the waiting requests.
sub relay_application_seen {
	my ($relay_id) = @_;
	return 0 unless defined $relay_id && length $relay_id;
	my $rows = eval { &db_select('tickets', ['information'], {})->hashes } || [];
	foreach my $row ( @{$rows} ) {
		next unless ref $row eq 'HASH';
		my $info = eval { decode_json($row->{'information'} // '') };
		next unless ref $info eq 'HASH';
		return 1 if ($info->{'relay_id'} // '') eq $relay_id;
	}
	return 0;
}

# Land one application as a request ticket. A duplicate is skipped, never
# rewritten: the house's own desk may already have acted on it.
sub relay_application_import {
	my ($app, $handle) = @_;
	my $info = &relay_application_info($app, $handle);
	return { error => 'not an application' } unless $info;
	return { skipped => 1 } if &relay_application_seen($info->{'relay_id'});
	my $row = &relay_application_row($app, $handle);
	return { error => 'not an application' } unless $row;
	my $written = eval { &db_insert('tickets', { %{$row} }) };
	return { error => 'the application could not be stored' } unless $written;
	return { imported => $row, info => $info };
}

# The relay id a ticket's information carries, for the approve/decline paths.
sub relay_application_ticket {
	my ($ticket) = @_;
	return '' unless ref $ticket eq 'HASH';
	my $info = eval { decode_json($ticket->{'information'} // '') } || {};
	return ref $info eq 'HASH' ? ($info->{'relay_id'} // '') : '';
}

1;
