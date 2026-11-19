package subs;

# Access: the route -> permission map. The privilege ladder itself lives in
# perl/subroutines.pl (%privilege_rank); this module answers which permission
# key a /manager path belongs to, so a resident's roles can be checked against
# the surface they are trying to reach. Loaded on demand by Domain/Loader.pm.
#
# The first segment after /manager/ names the surface for almost every route.
# A handful of surfaces share a segment with a full app (appointment records
# under records, the reception SCO routes), so the grouping is explicit rather
# than derived. A route that matches nothing is undef, never core: the audit
# test must be told about every new surface instead of inheriting the door.
use strict;
use warnings;

our %ACCESS_APP = (
	store        => [qw(store)],
	market       => [qw(market)],
	inventory    => [qw(inventory)],
	warehouse    => [qw(warehouse)],
	pay          => [qw(pay)],
	people       => [qw(people crest relational)],
	box_office   => [qw(box_office)],
	accounting   => [qw(transaction)],
	budget       => [qw(budget)],
	records      => [qw(records appointment appointment_details appointment_measures appointment_viewer centre_view unclaimed delete_duty)],
	crypto       => [qw(crypto)],
	mail         => [qw(mail mailbox email sms)],
	chat         => [qw(chat pen)],
	phone        => [qw(phone telephony)],
	reception    => [qw(sco)],
	web          => [qw(web internet browser magazine editor website_get)],
	library      => [qw(folders handbook)],
	help         => [qw(help)],
	configure    => [qw(configure configuration measures)],
	security     => [qw(security webauthn credentials key_push operator_door leave legacy_keys legacy_reseal ticket_privilege delete_ticket renew_ticket reinstate_ticket suspend_ticket vault_share)],
	network      => [qw(network tls tailnet tunnel public_ip neighbour_status address_directory address_lookup address_report available health health_report)],
	device       => [qw(device crew shell remote_auth_test remote_command remote_input remote_manager remote_refresh sound watch navigation process_monitor volume)],
	power        => [qw(power power_status)],
	packages     => [qw(packages)],
	controllers  => [qw(controllers controller)],
	embedded     => [qw(embedded lorawan ble nfc teletype)],
	ide          => [qw(ide terminal text_editor code_bundle)],
	coding       => [qw(coding agents app_draft work_claim work_claims)],
	junderground => [qw(junderground new_room room_namer)],
	studio       => [qw(studio synth)],
	media        => [qw(gallery camera scan scan_document marker thumbs media_window take_picture)],
	games        => [qw(games cards twirl pipedream minesweeper card_picker game_play)],
	weather      => [qw(weather)],
	travel       => [qw(travel continent)],
	notes        => [qw(notes note_delete note_header note_retriever note_save note_to_appt notes_categories tasks)],
	clock        => [qw(clock time_jump time_preview)],
);

# Shared rails and the desktop shell: reachable by any resident who passes the
# tier gate. Kept explicit so an unclassified route fails the audit test rather
# than silently becoming core.
our %ACCESS_CORE = map { $_ => 1 } qw(
	ago ai_chat app_download app_measure_delete app_measures app_release
	app_release_sync app_section apps assistant backup backup_serve
	cache_delete cache_get cache_set calculate clipboard_getter clipboard_setter
	clone_app clothesline clothesline_rail debrief debrief_grabber delete_app
	delete_file delete_whole_app device_ws dictate download_file edit_app file
	fuck_you home home_plates home_status icons js_error keyboard keyup_search
	lock_session notifications ollama_chat ollama_models palette past_life_recall
	president qrcode_generator random_word register_grabber reset resolve
	rsync_pack rsync_unpack say_it search search_engine_grabber search_index
	self_deploy setting_deleter setting_grabber setting_setter settings_grabber
	share silence snapshot_save sound_status start_menu sync_buckets
	sync_history sync_rows sync_tombstones torch translate update_database
	upload_file usage version voice_download voice_release volume_control
	window_closer window_maker window_retriever windows_update ws ws_close
);

# The keys a role may name. core is not a grant: it is what every resident
# already reaches, so a role never has to list it.
sub access_permission_keys {
	return [ sort keys %ACCESS_APP ];
}

sub access_core_prefixes {
	return [ sort keys %ACCESS_CORE ];
}

# Which permission a path belongs to. Returns the key, 'core' for a shared rail
# or the bare desk, and undef when the path is not under /manager or nobody has
# classified it. Query strings and trailing slashes are ignored.
sub access_app_for_path {
	my ($path) = @_;
	return undef unless defined $path && length $path;
	$path = "$path";
	$path =~ s/[?#].*$//;
	$path =~ s#/+$##;
	return undef unless $path =~ m{^/manager(?:/|$)};
	my $rest = $path;
	$rest =~ s{^/manager/?}{};
	return 'core' unless length $rest;
	my ($first) = split m{/}, $rest;
	return 'core' if $ACCESS_CORE{$first};
	foreach my $key ( sort keys %ACCESS_APP ) {
		return $key if grep { $_ eq $first } @{ $ACCESS_APP{$key} };
	}
	return undef;
}

# The roles a resident's session holds. They are read from the person row on
# each request, never from the cookie: a role changed or revoked in People takes
# effect on the next page, not when the pass expires.
sub session_role_keys {
	my ($c) = @_;
	return [] unless $c;
	my $uuid = eval { $c->session('person_uuid') } || '';
	return [] unless defined $uuid && length $uuid;
	return &person_role_keys($uuid);
}

sub session_role_names {
	my ($c) = @_;
	my $keys = ($c && $c->stash('session_roles')) || &session_role_keys($c);
	my %want = map { $_ => 1 } @{$keys};
	my $catalog = &role_catalog();
	return [ map { $_->{'name'} } grep { $want{ $_->{'uuid'} } } @{$catalog} ];
}

# What a resident is missing to reach a path. A citizen or a guest returns
# undef: the tier gate owns those rungs, not a role. 'core' is open to every
# resident. An unclassified path is refused by name, because the route audit
# should have caught it first.
sub access_scope_missing {
	my ($path, $privilege, $role_keys, $catalog) = @_;
	return undef unless (($privilege // '') eq 'resident');
	return undef unless defined $path && $path =~ m{^/manager(?:/|$)};
	my $need = &access_app_for_path($path);
	return 'unclassified' unless defined $need;
	return undef if $need eq 'core' || $need eq '';
	$catalog ||= &role_catalog();
	return undef if &role_permission_allowed($catalog, $role_keys, $need);
	return $need;
}

# Does this route exist in the map at all? A role editor uses this to refuse a
# key it does not recognise; the audit test uses the same answer for routes.
sub access_permission_known {
	my ($key) = @_;
	return 0 unless defined $key && length $key;
	return 1 if $key eq 'core';
	return 1 if exists $ACCESS_APP{$key};
	return 0;
}

1;
