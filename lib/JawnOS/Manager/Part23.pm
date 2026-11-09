package Manager;

# Manager helpers, part 23 of 37. Moved out of Manager.pl so a
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

sub card_of_the_day() {
	my $card;
	my $cards = &subs::cards_list('day');
	splice @{$cards}, 40;
	my $last_card = $cards->[0];
	$card = $last_card->{'title'};
	my @time = localtime($last_card->{'timestamp'} / 1000);
	my @now = localtime(&subs::rightNow() / 1000);

	if ($time[3] != $now[3]) {
		my $new_card = &random_card_picker();
		$new_card =~ s/.png$//gi;
		my $car = { title => $new_card, timestamp => &subs::rightNow() };
		$card = $car->{'title'};
		unshift @{$cards}, $car;
		&subs::cards_list_write('day', $cards);
	}

	return $card . '.png';
}

sub card_of_the_week() {
	my $card;
	my $cards = &subs::cards_list('week');
	splice @{$cards}, 40;
	my $last_card = $cards->[0] || {};
	$card = $last_card->{'title'};
	# the week a moment is in, named by the Sunday it opens on, so the card turns
	# over with the week the rest of the house counts - father_time's weeks start
	# on Sunday. This used to divide yday by seven, which drifts across the year
	# and here happened to turn the card on a Monday.
	my $week_opens = sub {
		my $ms = shift || 0;
		my @t = localtime($ms / 1000);
		my $sunday = timegm(0, 0, 0, $t[3], $t[4], $t[5]) - $t[6] * 86400;
		my @d = gmtime($sunday);
		return sprintf('%04d-%02d-%02d', $d[5] + 1900, $d[4] + 1, $d[3]);
	};
	if ($week_opens->($last_card->{'timestamp'}) ne $week_opens->(&subs::rightNow())) {
		my $new_card = &random_card_picker();
		$new_card =~ s/.png$//gi;
		my $car = { title => $new_card, timestamp => &subs::rightNow() };
		$card = $car->{'title'};
		unshift @{$cards}, $car;
		&subs::cards_list_write('week', $cards);
	}
	return $card . '.png';
}

sub card_of_the_month() {
	my $card;
	my $cards = &subs::cards_list('month');
	splice @{$cards}, 40;
	my $last_card = $cards->[0];
	$card = $last_card->{'title'};
	my @time = localtime($last_card->{'timestamp'} / 1000);
	my @now = localtime(&subs::rightNow() / 1000);
	if ($time[4] != $now[4]) {
		my $new_card = &random_card_picker();
		$new_card =~ s/.png$//gi;
		my $car = { title => $new_card, timestamp => &subs::rightNow() };
		$card = $car->{'title'};
		unshift @{$cards}, $car;
		&subs::cards_list_write('month', $cards);
	}
	return $card . '.png';
}

sub card_of_the_year() {
	my $card;
	my $cards = &subs::cards_list('year');
	splice @{$cards}, 40;
	my $last_card = $cards->[0];
	$card = $last_card->{'title'};
	my @time = localtime($last_card->{'timestamp'} / 1000);
	my @now = localtime(&subs::rightNow() / 1000);
	if ($time[5] != $now[5]) {
		my $new_card = &random_card_picker();
		$new_card =~ s/.png$//gi;
		my $car = { title => $new_card, timestamp => &subs::rightNow() };
		$card = $car->{'title'};
		unshift @{$cards}, $car;
		&subs::cards_list_write('year', $cards);
	}
	return $card . '.png';
}

sub relational_social_sing {
	my ($entry) = @_;
	return '' unless ref $entry eq 'HASH';
	my %social = map { $_->{'sing'} => 1 } values %{$gb::social_constructs};
	return $entry->{'pos'} if ($entry->{'pos'} || '') ne '' && $social{ $entry->{'pos'} };
	return $entry->{'mab'} if ($entry->{'mab'} || '') ne '' && $social{ $entry->{'mab'} };
	return '';
}

sub relational_colours {
	my $rows = eval { &subs::db_query("select app, value from settings where setting='colour' and value<>''")->hashes } || [];
	my %colours;
	foreach my $row ( @{$rows} ) {
		my $app = $row->{'app'} || '';
		next unless length $app;
		$colours{$app} ||= $row->{'value'};
	}
	return \%colours;
}

sub relational_workspace {
	my ($focus) = @_;
	my $index = &people_index();
	my %apps = %{ $index->{'apps'} || {} };
	$focus = '' unless defined $focus && length $focus && $apps{$focus}
		&& !(($apps{$focus}->{'house_uuid'} || '') ne '');
	my $colours = &relational_colours();
	my %social_by_sing = map { $_->{'sing'} => $_ } values %{$gb::social_constructs};
	my $type_label = sub {
		my ($scons) = @_;
		my $key = 'construct.' . $scons->{'name'};
		my $label = &subs::lang($key);
		return $label if defined $label && length $label && $label ne $key;
		return &subs::format_name($scons->{'name'});
	};
	my @types;
	foreach my $scons ( sort { $a->{'order'} <=> $b->{'order'} } values %{$gb::social_constructs} ) {
		my @rows;
		foreach my $app ( sort keys %apps ) {
			my $entry = $apps{$app};
			# another house's construct is read-only here; the Relational board
			# shows only what this house may change
			next if ($entry->{'house_uuid'} || '') ne '';
			next unless (($entry->{'pos'} || '') eq $scons->{'sing'} || ($entry->{'mab'} || '') eq $scons->{'sing'});
			push @rows, {
				app => $app,
				name => &subs::format_name($app),
				type => $scons->{'name'},
				sing => $scons->{'sing'},
				colour => $colours->{$app} || '',
				uuid => $entry->{'preferred_uuid'} || '',
				focus => ($app eq $focus ? 1 : 0),
			};
		}
		@rows = sort { lc($a->{'name'}) cmp lc($b->{'name'}) } @rows;
		push @types, {
			name => $scons->{'name'},
			sing => $scons->{'sing'},
			label => $type_label->($scons),
			count => scalar @rows,
			rows => \@rows,
		};
	}
	my %memberships;
	my $focus_data;
	if ($focus) {
		my $entry = $apps{$focus};
		my $focus_sing = &relational_social_sing($entry);
		my %focus_uuids = map { $_ => 1 } keys %{ $entry->{'uuids'} || {} };
		my %candidate;
		foreach my $sing ( keys %{ $entry->{'sc'} || {} } ) {
			foreach my $uuid ( keys %{ $entry->{'sc'}->{$sing} } ) {
				my $app = $index->{'uuid_app'}->{$uuid};
				next unless defined $app && $app ne $focus;
				$candidate{$app} = 1;
			}
		}
		if ($focus_sing) {
			foreach my $app ( keys %apps ) {
				next if $app eq $focus;
				foreach my $uuid ( keys %{ $apps{$app}->{'sc'}->{$focus_sing} || {} } ) {
					if ($focus_uuids{$uuid}) { $candidate{$app} = 1; last; }
				}
			}
		}
		foreach my $app ( keys %candidate ) {
			my $member = $apps{$app};
			my $sing = &relational_social_sing($member);
			next unless $sing;
			my $scons = $social_by_sing{$sing};
			next unless $scons;
			push @{ $memberships{ $scons->{'name'} } }, {
				app => $app,
				name => &subs::format_name($app),
				type => $scons->{'name'},
				sing => $sing,
				colour => $colours->{$app} || '',
			};
		}
		foreach my $name ( keys %memberships ) {
			@{ $memberships{$name} } = sort { lc($a->{'name'}) cmp lc($b->{'name'}) } @{ $memberships{$name} };
		}
		my $scons = $social_by_sing{$focus_sing};
		my $people_row = eval { &subs::db_select('people', undef, { app => $focus, status => 'active' })->hashes->[0] };
		$focus_data = {
			app => $focus,
			name => &subs::format_name($focus),
			type => $scons ? $scons->{'name'} : '',
			type_label => $scons ? $type_label->($scons) : '',
			sing => $focus_sing,
			pos => $entry->{'pos'} || '',
			mab => $entry->{'mab'} || '',
			colour => $colours->{$focus} || '',
			uuid => $entry->{'preferred_uuid'} || '',
			image => &people_main_image($focus),
			people_uuid => $people_row ? ($people_row->{'uuid'} || '') : '',
		};
	}
	my @pos_options = map { { value => $_, label => &subs::format_name($_) } } sort keys %{$gb::relationals};
	return {
		ok => 1,
		focus => $focus_data,
		memberships => \%memberships,
		types => \@types,
		pos_options => \@pos_options,
		labels => {
			library => &subs::ui('Constructs'),
			search => &subs::ui('Search'),
			add => &subs::ui('Add'),
			add_placeholder => &subs::ui('New name'),
			details => &subs::ui('Details'),
			open_people => &subs::ui('Open People'),
			drop_to_remove => &subs::ui('Drop here to remove'),
			empty_members => &subs::ui('Nothing here yet'),
			overview => &subs::ui('Choose a construct to work on'),
			focus_hint => &subs::ui('Drag a construct from the left into one of these groups, or press + on a card.'),
			all_constructs => &subs::ui('All constructs'),
		},
	};
}

sub relational_sc_update_all {
	my ($app, $sing, $add_uuid, $remove_uuids) = @_;
	return 0 unless defined $app && length $app && defined $sing && length $sing;
	my $setting = 'sc_' . $sing;
	my $rows = eval { &subs::db_query('select uuid, value from settings where app=? and setting=?', $app, $setting)->hashes } || [];
	my $found = 0;
	foreach my $row ( @{$rows} ) {
		my $list = eval { decode_json($row->{'value'} || '') } || [];
		$list = [] unless ref $list eq 'ARRAY';
		my %set;
		foreach my $uuid ( @{$list} ) {
			next unless defined $uuid && length $uuid && $uuid ne 'all';
			$set{$uuid} = 1;
		}
		$set{$add_uuid} = 1 if defined $add_uuid && length $add_uuid;
		delete $set{$_} for (ref $remove_uuids eq 'HASH' ? keys %{$remove_uuids} : ());
		&subs::db_update('settings', {
			value => encode_json([ sort keys %set ]),
			server_time => &subs::rightNow(),
		}, { uuid => $row->{'uuid'} });
		$found++;
	}
	unless ($found) {
		my %set;
		$set{$add_uuid} = 1 if defined $add_uuid && length $add_uuid;
		delete $set{$_} for (ref $remove_uuids eq 'HASH' ? keys %{$remove_uuids} : ());
		if (scalar keys %set) {
			&subs::setting_setter({ app => $app, setting => $setting, value => encode_json([ sort keys %set ]) });
		}
	}
	return 1;
}

sub relational_link {
	my ($focus, $member, $type, $movement) = @_;
	return 0 unless defined $focus && length $focus && defined $member && length $member && defined $type && length $type;
	return 0 if $focus eq $member;
	my $index = &people_index();
	my $f = $index->{'apps'}->{$focus};
	my $m = $index->{'apps'}->{$member};
	return 0 unless $f && $m;
	# an imported construct belongs to another house: its links are theirs
	return 0 if ($f->{'house_uuid'} || '') ne '' || ($m->{'house_uuid'} || '') ne '';
	my $scons = $gb::social_constructs->{$type};
	unless ($scons) {
		($scons) = grep { $_->{'sing'} eq $type } values %{$gb::social_constructs};
	}
	return 0 unless $scons;
	my $sing = $scons->{'sing'};
	my $focus_sing = &relational_social_sing($f);
	return 0 unless $focus_sing;
	my $f_uuid = $f->{'preferred_uuid'} || '';
	my $m_uuid = $m->{'preferred_uuid'} || '';
	return 0 unless $f_uuid && $m_uuid;
	if ($movement eq 'delete') {
		my %focus_uuids = map { $_ => 1 } keys %{ $f->{'uuids'} || {} };
		my %member_uuids = map { $_ => 1 } keys %{ $m->{'uuids'} || {} };
		&relational_sc_update_all($focus, $sing, undef, \%member_uuids);
		&relational_sc_update_all($member, $focus_sing, undef, \%focus_uuids);
	}
	else {
		&relational_sc_update_all($focus, $sing, $m_uuid, undef);
		&relational_sc_update_all($member, $focus_sing, $f_uuid, undef);
	}
	return 1;
}

sub relationalizer($data) {
	my $timestamp = $data->{'timestamp'};
	my $c = $data->{'c'};
	my $focus = defined $data->{'focus'} ? $data->{'focus'} : ($c ? ($c->param('focus') || '') : '');
	my $settings = &subs::settings_grabber({ app => 'relational' });
	my $dims = eval { decode_json($settings->{'dimensions'} || '') } || {};
	$dims = {} unless ref $dims eq 'HASH';
	# the two-pane matcher was happy at 500px; the board is not, and a window
	# parked past the right edge of a 1280px screen looks broken. Grow it once,
	# then leave whatever size the person chooses alone.
	$dims->{'width'} = 980 if !($dims->{'width'} || 0) || $dims->{'width'} < 720;
	$dims->{'height'} = 720 if !($dims->{'height'} || 0) || $dims->{'height'} < 560;
	$dims->{'left'} = 80 if !defined $dims->{'left'} || $dims->{'left'} > 900;
	$dims->{'top'} = 60 if !defined $dims->{'top'} || $dims->{'top'} > 200;
	$settings->{'dimensions'} = encode_json($dims);
	my $returner = {};
	$returner->{'contents'} = $c->render_to_string(
		template => 'relational/workspace',
		focus => $focus,
	);
	$returner->{'window'} = &Manager::window_maker({ user_agent => $c->param('user_agent'), app => 'relational', settings => $settings, contents => $returner->{'contents'} }, $timestamp);
	return $returner;
}

sub folders_desk_folder {
	my $set = &subs::setting_grabber({ app => 'folders', setting => 'desktop_folder' });
	if (defined $set && length $set) {
		my $chosen = &subs::home($set);
		$chosen =~ s{/+$}{} unless $chosen eq '/';
		return $chosen if -d $chosen;
	}
	my $desktop = &subs::home('~/Desktop');
	$desktop =~ s{/+$}{} unless $desktop eq '/';
	if (-d $desktop) {
		my @names = &folders_entry_names($desktop);
		return $desktop if scalar @names;
	}
	my $home = &subs::home('~/');
	$home =~ s{/+$}{};
	$home = '/' unless length $home;
	return $home;
}

sub folders_desk_pinned {
	my $raw = eval { decode_json &subs::setting_grabber({ app => 'folders', setting => 'desktop_apps' }) };
	my @list = ref $raw eq 'ARRAY' ? @{$raw} : ();
	my %seen;
	return grep {
		defined $_ && length $_ && !$seen{$_}++
			&& $gb::known_appts->{$_} && !$folders_desk_not_app{$_}
	} @list;
}

sub folders_pinable_apps {
	return [ map {
		{
			app => $_,
			name => &subs::format_name($_),
			icon => &subs::icon_for($gb::known_appts->{$_}->{'icon'})
		}
	} grep { !$folders_desk_not_app{$_} } sort { lc($a) cmp lc($b) } keys %{$gb::known_appts} ];
}

sub folders_owning_app($path) {
	return undef unless defined $path && length $path;
	my $misc = &misc_setting_list();
	my $device = &subs::device_setter();
	foreach my $k ( keys %{ $misc->{$device} || {} } ) {
		next unless $k =~ /_location$/;
		my $root = $misc->{$device}->{$k};
		next unless defined $root && length $root;
		$root = &subs::home($root);
		$root =~ s{/+$}{};
		next unless length $root;
		next unless index($path, $root . '/') == 0;
		my $rest = substr($path, length($root) + 1);
		my ($seg) = split '/', $rest;
		return $seg if defined $seg && length $seg;
	}
	return undef;
}

sub folders_app_names {
	my %apps = map { $_ => 1 } keys %{ $gb::known_appts || {} };
	my $names = &subs::appointment_names() || {};
	$apps{$_} = 1 for keys %{$names};
	return \%apps;
}

sub folders_display_segment($seg) {
	$seg = '' unless defined $seg;
	if ($seg =~ /%[0-9A-Fa-f]{2}/) {
		my $decoded = eval { &url_unescape($seg) };
		$seg = $decoded if defined $decoded && length $decoded;
	}
	return &subs::format_name($seg);
}

sub folders_display_path($path) {
	return '' unless defined $path && length $path;
	my $lead = (substr($path, 0, 1) eq '/') ? '/' : '';
	my @parts = grep { length } split '/', $path;
	return '/' unless scalar @parts;
	return $lead . join('/', map { &folders_display_segment($_) } @parts);
}

sub folders_display_name($path) {
	return '' unless defined $path && length $path;
	return '/' if $path eq '/';
	my $display = &folders_display_path($path);
	$display =~ s{.*/}{};
	return length $display ? $display : '/';
}

sub folders_app_folder_display($path, $apps) {
	return undef unless defined $path && length $path && $apps;
	my $base = $path;
	$base =~ s{.*/}{};
	my $seg = &folders_owning_app($path);
	return undef unless defined $seg && length $seg && $seg eq $base;
	my $app = &url_unescape($seg);
	utf8::decode($app) if !utf8::is_utf8($app);
	return undef unless $apps->{$app};
	my $display = &subs::format_name($app);
	return ($display eq $base) ? undef : $display;
}

sub folders_sealed_display($path, $apps, $references) {
	return undef unless defined $path && length $path;
	my $blob;
	my $row_app = '';
	foreach my $spot ( @{ ($references && $references->{'paths'}->{$path}) || [] } ) {
		next unless ($spot->{'kind'} || '') eq 'f';
		$blob = $spot->{'blob'};
		$row_app = $spot->{'info'}->{'app'} || '';
		last;
	}
	my $named = $blob ? ($blob->{'name'} || '') : '';
	if ($named =~ /\S/) {
		my $display = &subs::format_name($named);
		return $display if length $display;
	}
	my $app = '';
	my $seg = &folders_owning_app($path);
	if (defined $seg && length $seg) {
		my $candidate = &url_unescape($seg);
		utf8::decode($candidate) if !utf8::is_utf8($candidate);
		$app = $candidate if $apps && $apps->{$candidate};
	}
	$app = $row_app unless length $app;
	my $stamp = 0;
	my $base = $path;
	$base =~ s{.*/}{};
	if ($base =~ /_(\d{12,14})\.[^.]+\.enc$/i) { $stamp = $1 + 0; }
	elsif ($blob && ($blob->{'server_time'} || '') =~ /^(\d{10,14})$/) { $stamp = $1 + 0; }
	else { my @st = stat($path); $stamp = ($st[9] || 0) * 1000; }
	my $when = &folders_stamp_words($stamp);
	if (length $app) {
		my $app_name = &subs::format_name($app);
		return $app_name . (length $when ? ' ' . $when : '');
	}
	# nothing ties it to an app: the name it went in under is still better than
	# the random one the seal carries
	if ($blob && ($blob->{'of'} || '') =~ /\S/) {
		my $of = $blob->{'of'};
		$of =~ s{.*/}{};
		return $of if length $of;
	}
	return undef;
}

sub folders_stamp_words($ms) {
	return '' unless $ms && $ms > 0;
	my @t = localtime(int($ms / 1000));
	my $hour = $t[2] % 12;
	$hour = 12 unless $hour;
	return sprintf('%02d%02d%04d %d:%02d%s', $t[4] + 1, $t[3], $t[5] + 1900, $hour, $t[1], ($t[2] < 12 ? 'am' : 'pm'));
}

sub folders_opener($data) {
	my $folder = $data->{'folder'};
	my $command = $data->{'command'};
	my $c = $data->{'c'};
	my $unlocked = $data->{'unlocked'} ? 1 : 0;
	if (defined $command && $command eq 'up') {
		my @folders = split '/', $folder;
		pop @folders if scalar @folders;
		$folder = join '/', @folders;
	}
	elsif (defined $command && $command eq 'home') {
		$folder = &subs::home('~/');
	}
	# a trailing slash makes every path below it look like a double slash
	$folder =~ s{/+$}{} if (defined $folder && $folder ne '/');
	my $formatted_folder = &subs::terminal_name($folder);
	my $listing = &folders_listing($folder, $unlocked, $c, $data->{'show_hidden'});
	return { %{$listing},
		formatted_folder => $formatted_folder,
		folder => $folder,
		display_folder => &folders_display_path($folder),
		display_name => &folders_display_name($folder) };
}

sub folders_entry_names {
	my ($folder, $show_hidden) = @_;
	unless (defined $folder && length $folder && -d $folder) { return (); }
	opendir(my $dh, $folder) or return ();
	# dotfiles stay out of the listing unless the window has been told to show
	# hidden files from its background menu
	my @names = grep { $_ ne '.' && $_ ne '..' && ($show_hidden || substr($_, 0, 1) ne '.') } readdir $dh;
	closedir $dh;
	return sort { lc($a) cmp lc($b) || $a cmp $b } @names;
}

sub folders_archive_index($folder) {
	my $misc = &misc_setting_list();
	my $device = &subs::device_setter();
	my $settings = $misc->{$device} || {};
	my $machines = &subs::archive_machines();
	my ($match, $base) = &subs::archive_location_for($folder, $settings);
	return {} unless $match;
	my $rm = &subs::archive_machine_for($match, $settings, $machines);
	return {} unless ($rm && ($rm->{'self'} || (($rm->{'connection'} || '') eq 'active')));
	my $manifest = &subs::archive_manifest_for({ rm => $rm, location => $match, timeout => 5 });
	return {} if $manifest->{'error'};
	my %rows = map { $_->{'relative'} => 1 }
		grep { defined $_->{'relative'} && length $_->{'relative'} } @{$manifest->{'rows'} || []};
	# a folder is archived when any file under it is
	my %dirs;
	foreach my $rel ( keys %rows ) {
		my @parts = split m{/}, $rel;
		pop @parts;
		my $prefix = '';
		foreach my $p ( @parts ) {
			$prefix = length $prefix ? $prefix . '/' . $p : $p;
			$dirs{$prefix} = 1;
		}
	}
	return { location => $match, base => $base, rows => \%rows, dirs => \%dirs };
}

1;
