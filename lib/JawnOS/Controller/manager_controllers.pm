package Manager;

# manager_controllers: the house's controller roster and the two halves of the
# join (ask from the device, approve at the desk). Pairing rides the existing
# device_requests/paired_devices machinery; no new table is added.
use strict;
use warnings;
use utf8;

no warnings 'uninitialized';

our $log;

# GET /manager/controllers
sub action_54001 {
	my $c = shift;
	my $timestamp = $c->param('timestamp') || &subs::rightNow();
	my $content = $c->render_to_string(
		template => 'controllers/controllers',
		timestamp => $timestamp,
		config => &subs::config_reader(),
	);
	my $contents = &window_maker({ user_agent => $c->param('user_agent'), app => 'controller', title => &subs::ui('Controller'), contents => $content }, $timestamp);
	$c->render(text => $contents);
}

# GET /manager/controllers/list
sub action_54002 {
	my $c = shift;
	&app_schema_ensure();
	my $rows = &subs::db_select('paired_devices', undef, { kind => 'controller', status => 'active' })->hashes;
	my $controllers = [];
	foreach my $device ( @{$rows || []} ) {
		# A paired key and a roster row name the same machine two ways: the
		# device may have been introduced by its signatorial, or by the uuid
		# the house minted. Try the one it carries, then either half.
		my $key = $device->{'signatorial'} || $device->{'uuid'};
		my $machine = ($key && &subs::db_select('remote_machines', undef, { uuid => $key })->hash)
			|| ($key && &subs::db_select('remote_machines', undef, { signatorial => $key })->hash)
			|| {};
		my $pending = &subs::db_select('device_requests', undef, { device_uuid => $device->{'uuid'}, kind => 'controller', status => 'pending' })->hash;
		push @{$controllers}, {
			uuid => $device->{'uuid'},
			name => $device->{'name'} || '',
			kind => $device->{'kind'} || 'controller',
			hostname => $machine->{'hostname'} || '',
			ip => $machine->{'ip'} || '',
			last_seen => $device->{'last_seen'} || $machine->{'server_time'} || '',
			pending => ($pending ? 1 : 0),
		};
	}
	$c->render(json => { ok => 1, controllers => $controllers });
}

# POST /manager/controllers/request
sub action_54003 {
	my $c = shift;
	&app_schema_ensure();
	my $now = &subs::rightNow();
	my $uuid = &subs::random_string_creator(25);
	my $code = &subs::device_request_code();
	my $name = substr($c->param('name') || 'Controller', 0, 60);
	my $agent = substr($c->req->headers->user_agent // '', 0, 400);
	&subs::db_insert('device_requests', {
		uuid => $uuid,
		kind => 'controller',
		name => $name,
		code => $code,
		status => 'pending',
		agent => $agent,
		remote_address => $c->tx->remote_address,
		timestamp => $now,
		server_time => $now,
	});
	$log->info('controller request: ' . $name . ' code ' . $code);
	$c->render(json => { ok => 1, uuid => $uuid, code => $code });
}

# POST /manager/controllers/approve
sub action_54004 {
	my $c = shift;
	&app_schema_ensure();
	my $uuid = $c->param('uuid') || '';
	my $code = $c->param('code') || '';
	my $request = ($uuid && &subs::db_select('device_requests', undef, { uuid => $uuid, kind => 'controller', status => 'pending' })->hash)
		|| ($code && &subs::db_select('device_requests', undef, { code => $code, kind => 'controller', status => 'pending' })->hash)
		|| undef;
	return $c->render(json => { ok => 0, error => 'no request' }) unless $request;
	unless (($c->session('authentication') || '') eq 'approved' && &subs::privilege_is_house($c->session('privilege'))) {
		return $c->render(json => { ok => 0, error => 'not allowed' });
	}
	my $now = &subs::rightNow();
	my $name = $request->{'name'} || 'Controller';
	my $device_uuid = $request->{'device_uuid'} || &subs::random_string_creator(25);
	my $existing = &subs::db_select('paired_devices', undef, { uuid => $device_uuid })->hash;
	my $data = {
		name => $name,
		kind => 'controller',
		status => 'active',
		pubkey => $request->{'pubkey'} || '',
		privilege => $request->{'privilege'} || 'resident',
		person_uuid => $c->session('person_uuid'),
		agent => $request->{'agent'} || '',
		server_time => $now,
	};
	if ($existing) {
		&subs::db_update('paired_devices', $data, { uuid => $device_uuid });
	}
	else {
		$data->{'uuid'} = $device_uuid;
		$data->{'timestamp'} = $now;
		&subs::db_insert('paired_devices', $data);
	}
	&subs::db_update('device_requests', { status => 'approved', device_uuid => $device_uuid, server_time => $now }, { uuid => $request->{'uuid'} });
	$log->info('controller approved: ' . $name . ' uuid ' . $device_uuid);
	$c->render(json => { ok => 1, uuid => $device_uuid, name => $name });
}

1;
