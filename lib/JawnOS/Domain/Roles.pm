package subs;

# Roles: the named permission sets a resident can hold. A role is a list of
# permission keys from Domain/Access.pm, so the roles table never invents a
# surface: a key that the route map does not know is dropped on the way in.
#
# The presets follow the master plan's departments. They are offered until the
# house saves a list, and an assignment made before that save still resolves
# because a preset's uuid is its own key (sales, reception, ...). Loaded on
# demand by Domain/Loader.pm.
use strict;
use warnings;

use Mojo::JSON qw(decode_json encode_json);

our @ROLE_PRESET = (
	{
		uuid => 'sales', name => 'Sales Associate', department => 'Sales', builtin => 1,
		permissions => [qw(store market inventory warehouse pay accounting)],
	},
	{
		uuid => 'reception', name => 'Receptionist', department => 'Customer Service', builtin => 1,
		permissions => [qw(reception phone mail chat records people)],
	},
	{
		uuid => 'web', name => 'Web Editor', department => 'Web Presence', builtin => 1,
		permissions => [qw(web library media)],
	},
	{
		uuid => 'bookkeeper', name => 'Bookkeeper', department => 'Accounting', builtin => 1,
		permissions => [qw(accounting budget records crypto pay mail)],
	},
	{
		uuid => 'hr', name => 'Human Resources', department => 'Staff/HR', builtin => 1,
		permissions => [qw(people box_office records mail)],
	},
	{
		uuid => 'manager', name => 'Store Manager', department => 'Operations', builtin => 1,
		# everything a resident may reach; the citizen-only desks (configure,
		# security, power, packages, network writes, the code desk) are absent on
		# purpose, because a role can never raise a tier.
		permissions => [qw(store market inventory warehouse pay people box_office
			accounting budget records crypto mail chat phone reception web library
			help device studio media games weather travel notes clock)],
	},
);

sub role_slug {
	my ($text) = @_;
	my $slug = lc($text // '');
	$slug =~ s/[^a-z0-9]+/_/g;
	$slug =~ s/^_+|_+$//g;
	return substr($slug, 0, 100);
}

# A role entry as the table and the UI both read it. Permissions are filtered to
# the route map's keys, deduplicated and kept in the route map's order; an
# unknown key is dropped rather than stored as a grant nobody can enforce.
sub role_normalize {
	my ($entry) = @_;
	return undef unless ref $entry eq 'HASH';
	my $name = $entry->{'name'} // '';
	$name =~ s/^\s+|\s+$//g;
	return undef unless length $name;
	my $uuid = $entry->{'uuid'} // '';
	$uuid =~ s/^\s+|\s+$//g;
	$uuid = &role_slug($uuid) unless length $uuid;
	$uuid = &role_slug($name) unless length $uuid;
	return undef unless length $uuid;
	my $permissions = $entry->{'permissions'} // $entry->{'keys'} // [];
	unless (ref $permissions eq 'ARRAY') {
		my $decoded = eval { return decode_json($permissions) };
		$permissions = ref $decoded eq 'ARRAY' ? $decoded : [ split /\s*,\s*/, $permissions ];
	}
	my %seen;
	my @keys = grep { defined $_ && length $_ && !$seen{$_}++ && &access_permission_known($_) && $_ ne 'core' } @{$permissions};
	my $department = $entry->{'department'} // '';
	$department =~ s/^\s+|\s+$//g;
	return {
		uuid => $uuid,
		name => $name,
		department => $department,
		permissions => \@keys,
		builtin => ($entry->{'builtin'} ? 1 : 0),
	};
}

sub role_presets {
	return [ map { &role_normalize($_) } @ROLE_PRESET ];
}

# The house's roles. An empty table means the house has not edited the list, so
# the presets are offered; the first save writes them down.
sub role_catalog {
	my $rows = eval { &db_select('roles', undef, {})->hashes } || [];
	my @out;
	foreach my $row ( @{$rows} ) {
		my $role = &role_normalize($row) or next;
		push @out, $role;
	}
	return \@out if scalar @out;
	return &role_presets();
}

sub role_find {
	my ($catalog, $uuid) = @_;
	return undef unless defined $uuid && length $uuid;
	foreach my $role ( @{$catalog || []} ) {
		return $role if $role->{'uuid'} eq $uuid;
	}
	return undef;
}

# Write the list the editor sent. Rows are upserted, never deleted here: a
# removal is its own call so an interrupted save cannot drop a role a person
# still holds.
sub role_catalog_save {
	my ($list) = @_;
	$list = eval { return decode_json($list) } if defined $list && !ref $list;
	$list = [] unless ref $list eq 'ARRAY';
	my @out;
	foreach my $entry ( @{$list} ) {
		my $role = &role_normalize($entry) or next;
		my $row = {
			uuid => $role->{'uuid'},
			name => $role->{'name'},
			department => $role->{'department'},
			permissions => encode_json($role->{'permissions'}),
			builtin => $role->{'builtin'},
		};
		my $known = eval { &db_query('select 1 from roles where uuid = ? limit 1', $role->{'uuid'})->hashes->[0] };
		if ($known) {
			$row->{'server_time'} = &rightNow();
			&db_update('roles', $row, { uuid => $role->{'uuid'} });
		}
		else {
			$row->{'server_time'} = &rightNow();
			&db_insert('roles', $row);
		}
		push @out, $role;
	}
	return \@out;
}

sub role_catalog_delete {
	my ($uuid) = @_;
	return 0 unless defined $uuid && length $uuid;
	&db_delete('roles', { uuid => $uuid });
	return 1;
}

# The role keys a person holds, read from the people row. A deleted role is
# kept on the person but grants nothing, because expansion only reads the role
# catalog.
sub person_role_keys {
	my ($person_uuid) = @_;
	return [] unless defined $person_uuid && length $person_uuid;
	my $row = eval { &db_select('people', ['roles'], { uuid => $person_uuid })->hash } || {};
	my $raw = $row->{'roles'} // '';
	return [] unless defined $raw && length $raw;
	my $decoded = eval { return decode_json($raw) };
	return [] unless ref $decoded eq 'ARRAY';
	return [ grep { defined $_ && !ref $_ && length $_ } @{$decoded} ];
}

sub person_roles_write {
	my ($person_uuid, $keys, $catalog) = @_;
	return [] unless defined $person_uuid && length $person_uuid;
	$catalog ||= &role_catalog();
	my %known = map { $_->{'uuid'} => 1 } @{$catalog};
	my @keep;
	my %seen;
	foreach my $key ( @{$keys || []} ) {
		next unless defined $key && !ref $key && length $key;
		next unless $known{$key} && !$seen{$key}++;
		push @keep, $key;
	}
	&db_update('people', { roles => encode_json(\@keep) }, { uuid => $person_uuid });
	return \@keep;
}

# The union of the permissions a set of roles grants. This is what a scope
# check asks; core is never granted by a role.
sub role_permissions_keyed {
	my ($catalog, $keys) = @_;
	my %want = map { $_ => 1 } @{$keys || []};
	my %out;
	foreach my $role ( @{$catalog || []} ) {
		next unless $want{ $role->{'uuid'} };
		$out{$_} = 1 for @{ $role->{'permissions'} || [] };
	}
	return [ sort keys %out ];
}

sub role_permission_allowed {
	my ($catalog, $keys, $permission) = @_;
	return 0 unless defined $permission && length $permission;
	return scalar( grep { $_ eq $permission } @{ &role_permissions_keyed($catalog, $keys) } ) ? 1 : 0;
}

1;
