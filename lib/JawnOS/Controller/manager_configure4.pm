package Manager;

# manager_configure4: route actions moved out of Manager.pl, one sub per route so a
# route can be read and changed without opening the whole file. The package
# is still Manager, so unqualified calls to its helpers and its package
# state work exactly as they did in the single file.
use strict;
use warnings;
use utf8;
use feature 'signatures';
no warnings 'experimental::signatures';
no warnings 'uninitialized';
no warnings 'once';

use strict;
use warnings ;#'uninitialized';
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
use Mojo::IOLoop::ReadWriteFork;
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
use IO::Socket::UNIX;
use IPC::Open2 qw(open2);

our ($APP, $ws_live_window, $encoder, $decoder, $tuuid, $thread_uuid, $universal_splitter, $database, $sql, $remote_input_clipboard, $config_file, $config, $logfile, $log, $environment, $random_caching_string, $duty_file, $main_process, $device, $user_agent, %time_machine_guide_cache, @media_unlock_apps, %help_search_tables, %media_type_for_ext, %file_relay_down, @appointments, @results, %market_payment_family, @manager_bundle_files, $manager_bundle_cache, $js_minifier, %app_release_sha, %folders_desk_not_app, $jg_body, $remote_input_geometry_at, $remote_input_geometry_cache, %remote_input_ua, %remote_input_ws, %remote_input_rm, %remote_input_ws_failed, $public_ip_memo, $coding_protocols, $coding_protocols_mtime, $app_schema_done, $fingerprint_checked_at, $fingerprint_ok, %padlock_time_memo, %credential_browser_app, %app_gate_shadow_seen, $ws_server, %mailws_untrusted_rate);

# POST /manager/configure/packaging/save
sub action_17823 {
	my $c = shift;
	my $timestamp = $c->param('timestamp');
	my $app = $c->param('app');
	my $name = $c->param('name');
	my $value = $c->param('value');
	my $uuid = $c->param('uuid');
	my $packaging = eval { return decode_json &subs::setting_grabber({ app => $app, setting => 'packaging' }) } || {};
	$packaging->{$uuid}->{$name} = $value;
	my $jpack = encode_json $packaging;
	&subs::setting_setter({ app => $app, value => $jpack, setting => 'packaging' });

	my $html = $c->render_to_string(
		template => 'configure/packaging',
		settings => { app_packaging => $packaging }
	);
	$c->render(json => { packaging => $packaging, html => $html });

}

# The Guide fills the packaging in: given an item it names how the thing is sold
# (a six-pack, a case of 24), so nobody types every pack by hand. The set packs
# are merged, not replaced, so anything already entered stays.
# POST /manager/configure/packaging/suggest
sub action_17845 {
	my $c = shift;
	my $app = $c->param('app');
	my $packaging = eval { return decode_json &subs::setting_grabber({ app => $app, setting => 'packaging' }) } || {};
	my $settings = &subs::settings_grabber({ app => $app });
	my $unit = $settings->{'unit'} || '';
	my $ask = [
		{ role => 'system', content => 'You know how shop goods are packaged in Canada. Answer with strict JSON only.' },
		{ role => 'user', content => 'The item is "' . &subs::format_name($app) . '"' . ($unit ? ' sold in ' . $unit : '') . '.'
			. ' List the ways it is normally bought as packages, most common first, up to 3.'
			. ' Return ONLY JSON: {"packages":[{"name":"6-pack","quantity":6},{"name":"case of 24","quantity":24}]}.'
			. ' quantity is how many of the item one package holds; if it is sold only singly, return {"name":"single","quantity":1}.' },
	];
	&subs::render_in_subprocess($c, sub {
		my ($text) = &subs::ai_chat_role('chatbot_model', $ask);
		return { text => $text };
	}, sub {
		my ($c, $r) = @_;
		my ($json) = ((($r && $r->{'text'}) || '') =~ /(\{.*\})/s);
		my $out = eval { return decode_json $json } || {};
		my $added = 0;
		foreach my $p ( @{ $out->{'packages'} || [] } ) {
			next unless ref $p eq 'HASH' && ($p->{'name'} || '') ne '';
			my $uuid = &subs::random_string_creator(20);
			$packaging->{$uuid} = { uuid => $uuid, name => $p->{'name'}, quantity => ($p->{'quantity'} || 1) };
			$added++;
		}
		&subs::setting_setter({ app => $app, setting => 'packaging', value => encode_json($packaging) }) if $added;
		my $html = $c->render_to_string(
			template => 'configure/packaging',
			settings => { app_packaging => $packaging }
		);
		$c->render(json => { html => $html, added => $added });
	});
}

# POST /manager/configure/packaging/delete
sub action_17880 {
	my $c = shift;
	my $app = $c->param('app');
	my $uuid = $c->param('uuid');
	my $packaging = eval { return decode_json &subs::setting_grabber({ app => $app, setting => 'packaging' }) } || {};
	delete $packaging->{$uuid};
	my $jpack = encode_json $packaging;
	&subs::setting_setter({ app => $app, value => $jpack, setting => 'packaging' });
	my $html = $c->render_to_string(
		template => 'configure/packaging',
		settings => { app_packaging => $packaging }
	);
	$c->render(json => { packaging => $packaging, html => $html });
}

# POST /manager/configure/colour_update
sub action_18883 {
	my $c = shift;
	# The theme stopped repainting appointments on its own, so this is the
	# deliberate version of it, per device: colours that are no longer part of the
	# theme get a stable theme colour for that app, the rest are left alone.
	my $device = $c->param('device') || &subs::device_setter();
	my $rows = &subs::db_query('select distinct app, value from settings where setting = ? and device = ?', 'colour', $device)->hashes;
	my $updated = 0;
	foreach my $row ( @{$rows} ) {
		my $app = $row->{'app'};
		next unless $app;
		next if grep { lc($_) eq lc($app) } @gb::protected;
		my $colour = &subs::theme_colour_grabber({ app => $app, existing => $row->{'value'}, device => $device });
		$updated++ if defined $colour && lc($colour) ne lc($row->{'value'} || '');
	}
	# the desk top and the stored clothesline both paint from caches, so rebuild them
	# the same way a single colour change does before telling the browsers to redraw
	&subs::hang_to_dry() if $updated;
	&Websocket::send('server', { console => &Websocket::console_command('calculator')}) if $updated;
	$c->render(json => { updated => $updated, device => $device });
}

# GET /manager/configure/appointment_list
sub action_18904 {
	my $c = shift;
	my ($db,$database,$sql) = &subs::database_grabber();
	# Every app that has a visibility or kind row, not only the visible ones: an
	# app turned off must still be listed so the dropdown can turn it back on.
	my $results = &subs::db_query("select distinct app from settings where setting in ('visible','pos','mab') and app is not null and app != '' and substr(app,1,2) <> '__' order by app")->hashes;
	my $appointments = $results;
	foreach my $a (@{$appointments}) {
		$a->{'app'} = &subs::unformat_name($a->{'app'});
		$a->{'formatted_name'} = &subs::format_name($a->{'app'});
	}
	$c->render(
		template => 'configure/appointment_lister',
		appts => $appointments,
		timestamp => &subs::rightNow()
	);
}

# GET /manager/configure/appointment_display
sub action_18921 {
	my $c = shift;
	my $app = &subs::unformat_name($c->param('app'));
	my $appts = &log_reader({ app => $app, view => 'appointment_display' });
	my $abilities = $gb::abilities;
	my $setting = eval { return decode_json $c->param('setting') } || [];
	if (scalar @{$setting} > 0) {
		$abilities = {};
		foreach my $s ( @{$setting} ) {
			$abilities->{$s} = $gb::abilities->{$s} if $gb::abilities->{$s};
		}
	}
	my $config_window = $c->param('config');
	my $preferred_appts = {};

	my $measures = eval { return decode_json $appts->{$app}->{'setting'}->{'app_measures'} } || {};
	foreach my $m ( keys %{$measures} ) {

	}
	$appts->{$app}->{'setting'}->{'measures'} = join ',', keys %{$measures};
	$appts->{$app}->{'setting'}->{'app_measures'} = $measures;

	my $packaging = eval { return decode_json $appts->{$app}->{'setting'}->{'packaging'} } || {};
	$appts->{$app}->{'setting'}->{'app_packaging'} = $packaging;
	$appts->{$app}->{'setting'}->{'packaging'} = join ',', map { $_ = $packaging->{$_}->{'name'} } keys %{$packaging};

	my $home_plate = eval { return decode_json $appts->{$app}->{'setting'}->{'home_plate'} } || {};
	$appts->{$app}->{'setting'}->{'app_home_plate'} = $home_plate;
	$appts->{$app}->{'setting'}->{'home_plate'} = $home_plate->{'latitude'} . ' ' . $home_plate->{'longitude'};


	foreach my $k (keys %{$appts}) {
		if ($k =~ /^__/) {
			next;
		}
		else {
			$preferred_appts->{$k} = $appts->{$k}
		}
	}
	$c->render(
		template => 'configure/appointment_list',
		appts => $preferred_appts,
		'pos' => $gb::pos,
		'abilities' => $abilities,
		config_window => $config_window,
		app_themes => &subs::app_theme_map(),
		timestamp => &subs::rightNow()
	);
}

# POST /manager/configure/permissions
sub action_18970 {
	my $c = shift;
	my $timestamp = $c->param('timestamp');
	my ($av_data);
	if ($c->param('avData')) {
		$av_data = decode_json($c->param('avData'));
	}
	my $constraints = $c->param('constraints');
	foreach my $av (@{$av_data}) {
		if ($av->{'kind'} eq 'audioinput') {
			$av->{'icon'} = 'microphone';
		}
		elsif ($av->{'kind'} eq 'videoinput') {
			$av->{'icon'} = 'monitor';
		}
		elsif ($av->{'kind'} eq 'audiooutput') {
			$av->{'icon'} = 'speaker';
		}
	}
	# On the phone the browser prompts are not the whole story: the device
	# utilities need Android runtime permissions too, so also open the app's own
	# grant-all screen, which requests them in the app's own name (M2: it used to
	# live in the API app). The screen is not exported; the app's wake receiver
	# opens it.
	if (&subs::device_setter() eq 'mobile') {
		# A broadcast, not `am start`: Android refuses an activity start from the
		# tree's own shell child (the tool reports the shell's package, not ours),
		# while the app's exported wake receiver opens the screen in-process. M4.
		my $component = &subs::app_component('JawnWakeReceiver');
		my $action = &subs::app_action('JAWN_PERMISSIONS');
		system('/system/bin/am', 'broadcast', '-a', $action, '-n', $component);
	}
	$c->render(json => { av_data => $av_data, constraints => $constraints });
}

# GET /manager/configure
sub action_19004 {
	my $c = shift;
	# Citizen-only. The hook already refuses a lower tier; this is the second
	# lock so a future change to the hook cannot reopen the settings desk.
	unless (($c->session('privilege') || '') eq 'citizen') {
		return $c->render(template => 'guest_layouts/denial', layout => undef,
			message => '... access denied.', status => 403);
	}
	my $timestamp = $c->param('timestamp');
	my ($db,$database,$sql) = &subs::database_grabber();

	my $browser_tab = $c->param('browser_tab');
	my $browser_tab_id = $c->param('browser_tab_id');

	my $web_query = &subs::db_query('select * from websockets where browser_tab_id = ?',$browser_tab_id);
	my $websockets = $web_query->hashes;
	my $pseudonyms = &pseudonym_maker('config','');

	my $content = $c->render_to_string(
		template => 'configure/configure',
		config => &subs::config_reader(),
		device => $device,
		websockets => $websockets,
		pseudonyms => $pseudonyms,
	);
	my $contents = &window_maker({ user_agent => $c->param('user_agent'), app => 'configure', title => 'Configure', contents => $content },$timestamp);
	$c->render(text => $contents);
}

# POST /manager/configure
sub action_19033 {
	my $c = shift;
	# This writes any setting, so it carries its own citizen check: the route
	# must not depend on the hook alone.
	unless (($c->session('privilege') || '') eq 'citizen') {
		return $c->render(status => 403, json => { ok => 0, error => 'citizen only' });
	}
	my $app = $c->param('app');
#	&subs::cache_delete({ app => $app });
	my $setting = $c->param('setting');
	my $value = $c->param('value');
	my $timestamp = $c->param('timestamp');
	my $source = $c->param('source');
	# a destructive rename plans its history drops before the rows are relabelled,
	# then tombstones them under the unified name once the rename has run
	my $history_plan;
	my $renamed_to;
	if ($setting eq 'measures') {
		$setting = 'app_measures';
		my $measures = eval { decode_json &subs::setting_grabber({ app => $app, setting => 'app_measures' }) } || {};
		my @potentials = split ',', $value;

		foreach my $p ( @potentials ) {
			unless ($measures->{$p}) {
				$measures->{$p} = 0;
			}
		}
		foreach my $m ( keys %{$measures} ) {
			unless ( grep { $_ eq $m } @potentials ) {
				delete $measures->{$m};
			}
		}

		$value = encode_json $measures;
	}
	if (grep { $setting eq $_ } qw/ollama_key cloudflare_token openai_key anthropic_key xai_key google_key mistral_key cohere_key groq_key openrouter_key deepseek_key/ ) {
		# Never log the key: these two lines used to write the plaintext and then
		# its ciphertext into ~/manager.log on every save.
		$value = &subs::note_encrypter(&subs::suds_grabber(), $value);
	}
	# a rename into a name the house already knows is a merge: the two apps'
	# settings meet on one row each, so the panel picks which value wins per
	# setting (and which merge naturally) before the rename runs. A conflict is
	# only something to choose, though: two apps that share no setting simply join,
	# and reporting a conflict over an empty list left the panel's own button
	# re-asking forever - a rename that visibly did nothing at all.
	if ($setting eq 'name_change') {
		my $new_app = &subs::unformat_name($value);
		$renamed_to = $new_app;
		my $choices = eval { return decode_json $c->param('choices') } || {};
		my $appt_policy = $c->param('appt_policy') || '';
		my $target = &subs::db_query('select 1 from settings where app = ? limit 1', $new_app)->hashes->[0];
		my $target_appts = &subs::db_query('select 1 from appointments where app = ? limit 1', $new_app)->hashes->[0];
		my $pairs = &subs::name_change_pairs($app, $new_app);
		# the panel is also worth showing when only the history overlaps: it is
		# where the per-side summary and the history policy live
		if (($target || $target_appts) && !scalar keys %{$choices} && !$appt_policy && (scalar @{$pairs} || $target_appts)) {
			my $history = &subs::name_change_history($app, $new_app);
			$c->render(json => { conflict => 1, app => $app, new => $new_app, pairs => $pairs, appointments => $history });
			return;
		}
		if ($appt_policy && $appt_policy ne 'keep_all' && $appt_policy ne 'flag') {
			$history_plan = &subs::name_change_history_plan($app, $new_app, $appt_policy);
			if ($history_plan && $history_plan->{'count'}) {
				# a destructive history policy is the one write worth a fresh snapshot
				my $fresh = eval { &subs::records_backup_ensure_fresh(600000) };
				&subs::log_writer('name merge backup ' . (($fresh && $fresh->{'fresh'}) ? ($fresh->{'path'} || 'fresh') : 'FAILED')
					. ' before ' . $app . ' -> ' . $new_app . ' policy=' . $appt_policy);
			}
		}
		&subs::name_change_apply($app, $new_app, $choices) if scalar keys %{$choices};
	}
	my $setting_data = { app => $app, setting => $setting, value => $value, timestamp => $timestamp, source => 'panel' };
	# an appointment type's theme and its warranty are properties of the type, not
	# of the machine that happened to set them: keep both on the house-wide row
	$setting_data->{'device'} = 'all' if $setting eq 'theme' || $setting eq 'warranty' || $setting eq 'relationship';
	$setting_data->{'value'} = &subs::relationship_normalize($setting_data->{'value'}) if $setting eq 'relationship';
	&subs::setting_setter($setting_data);
	if (($source || '') eq 'people') {
		$c->render(json => { ok => 1, app => $app, setting => $setting, value => $setting_data->{'value'} });
		return;
	}
	# the rename has relabelled the surviving rows, so a planned drop can now be
	# tombstoned under the name every peer will be using
	&subs::name_change_history_apply_plan($renamed_to, $history_plan) if $history_plan && $renamed_to;
	# The rename has moved every row to the new name. Re-rendering the old one
	# here would make setting_initializer re-create it with default settings - a
	# phantom app, which then made renaming back fail as "exists".
	$c->param('app' => $renamed_to) if $renamed_to && $renamed_to ne $c->param('app');
	# changing the theme of an app that is running re-paints the desktop now
	&subs::appointment_theme_push() if $setting eq 'theme';
	undef @appointments;
	my $appts = &log_reader({ app => $c->param('app'), view => 'appointment_display' });
	my $measures = eval { decode_json $appts->{$app}->{'setting'}->{'app_measures'} } || {};
	$appts->{$app}->{'setting'}->{'measures'} = join ',', keys %{$measures};
	$appts->{$app}->{'setting'}->{'app_measures'} = $measures;

	my $packaging = eval { decode_json $appts->{$app}->{'setting'}->{'packaging'} } || {};
	$appts->{$app}->{'setting'}->{'app_packaging'} = $packaging;
	$appts->{$app}->{'setting'}->{'packaging'} = join ',', map { $_ = $packaging->{$_}->{'name'} } keys %{$packaging};

	my $home_plate = eval { return decode_json $appts->{$app}->{'setting'}->{'home_plate'} } || {};
	$appts->{$app}->{'setting'}->{'app_home_plate'} = $home_plate;
	$appts->{$app}->{'setting'}->{'home_plate'} = $home_plate->{'latitude'} . ' ' . $home_plate->{'longitude'};

	if ($setting eq 'enc' && $value eq 'on') {
		&subs::file_encrypter({ app => $app });
	}
	elsif ($setting eq 'enc' && $value eq 'off') {
		&subs::file_decrypter({ app => $app });
	}



	my $preferred_appts = {};
	foreach my $k (keys %{$appts}) {
		if ($k =~ /^__/) {
			next;
		}
		else {
			$preferred_appts->{$k} = $appts->{$k}
		}
	}
	if ($setting eq 'navigation') {
		$value = &subs::time_abbrev_translator($value, $timestamp);
	}

	&Websocket::send($app, { console => &Websocket::console_command('setAppointmentAttr', $app, $setting, $value)});
	if ($source eq 'panel') {

		my $window = &centre_view_grabber({ c => $c, app => $c->param('app'), timestamp => $timestamp, cached => 'no' });
		$c->render(text => $window);

	}
	else {
		$c->render(
			template => 'configure/appointment_list',
			appts => $preferred_appts,
			abilities => $gb::abilities,
			app_themes => &subs::app_theme_map(),
			timestamp => &subs::rightNow()
		);
	}
}

# The Sys panel is loaded with the whole browser localStorage in the request. As a
# GET that rode the query string, which the manager caps at MOJO_MAX_LINE_SIZE
# (64k) - once localStorage grew past it the request was answered by the Gate page
# and injected into the panel, so Sys "would not load". Accept POST too so the
# panel can send that payload in the body.
# ANY /manager/configure/system_list
sub action_19179 {
	my $c = shift;
	my $local_storage = eval { return decode_json $c->param('local_storage') } || {};
	my $settings = { };
	my ($db,$database,$sql) = &subs::database_grabber();
	foreach my $dt ( @gb::device_types ) {
		$settings->{$dt} = &subs::settings_grabber({ app => '__president', device => $dt });
	}
	my $stats = [];
	# list the tables from the metadata table instead of shelling out to the
	# sqlite3 binary on every load of the system settings page
	my $table_names = &subs::db_query("select name from sqlite_master where type = 'table' order by name")->hashes;
	foreach my $row ( @{$table_names} ) {
		my $d = $row->{'name'};
		my $results = &subs::db_query('select count(*) from ' . $d);
		push @{$stats}, { formatted_table => &subs::format_name($d), table => $d, count => $results->hash->{'count(*)'} };
	}
	push @{$stats}, { formatted_table => 'Downloads', table => 'download', count => &subs::setting_grabber({ app => '__president', setting => 'download_count' }) || 0 };

	my $evaluation = &subs::cache_get({ app => '__president', context => 'evaluation' }) || {};

	my $last_restart = -e $duty_file ? read_file($duty_file) : &subs::rightNow();
	$last_restart =~ s/\s+$// if defined $last_restart;

	$settings->{$device}->{'stats'} = $stats;
	$c->render(
		template => '/configure/system_setting_list',
		stats => $stats,
		local_storage => $local_storage,
		evaluation => $evaluation,
		ai_house => &subs::ai_house_report(),
		ai_balance => &subs::ai_balance_report(),
		where_stats => &subs::where_lookup_stats(substr(&subs::ai_spend_minute_key(), 0, 10)),
		where_audit => &subs::where_audit_report(),
		where_audit_enabled => &subs::where_audit_enabled(),
		where_audit_cadence => &subs::where_audit_cadence(),
		where_audit_next => &subs::where_audit_next(),
		settings => $settings,
		last_restart => $last_restart,
		device => $device
	);
}

# GET /manager/configure/balance_period
# One period of the Balance drop chart, drawn when its arrows step away from
# now. A past period comes from the stored samples; a future one is projected
# from the same history's burn rate, so it is a runway rather than a reading.
# The plot HTML is rendered from the same partial the panel includes, so the
# arrows change the period without duplicating the chart's markup.
sub action_19411 {
	my $c = shift;
	my $provider = $c->param('provider') // '';
	my $window = $c->param('window') // '1d';
	my $offset = $c->param('offset');
	$offset = 0 unless defined $offset && $offset =~ /^-?\d+$/;
	$offset = -400 if $offset < -400;
	$offset = 400 if $offset > 400;
	$offset += 0;
	my $chart = &subs::ai_balance_chart(&subs::ai_balance_report(), undef, $offset);
	my ($series) = grep { ($_->{'provider'} || '') eq $provider } @{ $chart->{'series'} || [] };
	return $c->render(json => { ok => 0, error => 'provider not charted' }) unless $series;
	my $wd = $series->{'windows'}->{$window};
	return $c->render(json => { ok => 0, error => 'window not charted' }) unless $wd;
	my $html = $c->render_to_string(
		template => 'configure/balance_plot',
		series => $series,
		window => $window,
		wd => $wd,
		series_currency => ($series->{'currency'} || $chart->{'base'} || ''),
		window_label => { '1h' => 'configure.last_hour', '1d' => 'configure.last_day', '1w' => 'configure.last_week', '1m' => 'configure.last_month' },
		hidden => 0,
	);
	$c->render(json => {
		ok => 1,
		provider => $provider,
		window => $window,
		offset => $offset,
		label => ($wd->{'period_label'} || ''),
		projected => ($wd->{'projected'} ? 1 : 0),
		can_prev => ($wd->{'can_prev'} ? 1 : 0),
		can_next => ($wd->{'can_next'} ? 1 : 0),
		html => $html,
	});
}

# POST /manager/configure/sys_setting
sub action_19216 {
	my $c = shift;
	my $timestamp = $c->param('timestamp');
	my $setting = &subs::unformat_name($c->param('setting'));
	my $value = $c->param('value');
	my $device = &subs::unformat_name($c->param('device'));
	my $set = &subs::setting_setter({ app => '__president', setting => $setting, value => $value, device => $device });
	$c->render(json => $set);
}

# POST /manager/configure/system_monitor
sub action_19225 {
	my $c = shift;
	my $all_params = $c->req->query_params;
	my $data;
	for (my $n = 0; $n < scalar @{$all_params->{'pairs'}} - 1; $n++) {

		$data->{$all_params->{'pairs'}->[$n]} = $all_params->{'pairs'}->[$n + 1];
		$n++;
	}
	$c->render(json => {});
}

# GET /manager/configure/utility_controller
sub action_19236 {
	my $c = shift;
	my $html = $c->render_to_string(
		template => 'configure/utility_controller',
	);

	$c->render(json => { html => $html });

}

# POST /manager/configure/utility_controller/save
sub action_19245 {
	my $c = shift;
	&subs::subprocessor(sub {
    Mojo::IOLoop->reset;
#		&remote_relay_request($c, { dissemination => 'yes' });
	}, { name => 'utility remote relay' });
	my $device = $c->param('device');
	my $control = $c->param('control');
	my $setting = $c->param('setting');
	my $value = $c->param('value');
	my $timestamp = $c->param('timestamp') || &subs::rightNow();
	my $real_device = &subs::device_setter();
	my $signatorial = &subs::signatorial_designer();
	my $controls = eval { return decode_json &subs::setting_grabber({ app => '__president', setting => 'utility_controller' }) } || {};
	if (scalar keys %{$controls} == 0) {
		foreach my $dt ( (&subs::signatorial_designer(), @gb::device_types ) ) {
			$controls->{$dt} = clone $gb::timeouts;
		}
	}
	if ($setting eq 'interval') {
		# the field shows a duration such as "2m"; a bare number is seconds, so
		# typing 120 cannot silently become 120 minutes
		$value = ($value =~ /^\s*-?\d+(\.\d+)?\s*$/)
			? ($value + 0)
			: &subs::time_abbrev_translator($value,$timestamp) / 1000;
	}

	# Write the row that was edited and stamp its own last_change. The runtime
	# reads only the signatorial key, so a device-type post (a stale page, or the
	# old device tab) must not create or change a device row: fold it onto our
	# signatorial when it is this machine's own device type, and ignore it
	# otherwise. This is what stopped a device-type row from reading a job off
	# while the signatorial row - the one that runs - stayed untouched.
	my $now = &subs::rightNow();
	if (grep { $_ eq $device } @gb::device_types) {
		if ($device eq $real_device) {
			$controls->{$signatorial}->{$control}->{$setting} = $value;
			$controls->{$signatorial}->{'__settings'}->{'last_change'} = $now;
			$controls->{$signatorial}->{'__settings'}->{$setting}->{'last_change'} = $now;
		}
	}
	else {
		$controls->{$device}->{$control}->{$setting} = $value;
		$controls->{$device}->{'__settings'}->{'last_change'} = $now;
		$controls->{$device}->{'__settings'}->{$setting}->{'last_change'} = $now;
	}
	my $jcontrols = encode_json $controls;
	# Name every utility save in the log, with the row key it came from - a job
	# being read off with nobody touching it has to be traceable to the page (or
	# machine) that posted the value.
	&subs::log_writer('utility save: sig=' . substr($signatorial, 0, 8) . ' device=' . $device . ' real=' . $real_device . ' ' . $control . '.' . $setting . '=' . (defined $value ? $value : 'undef'));

	&subs::setting_setter({ app => '__president', setting => 'utility_controller', value => $jcontrols });
	my $html = $c->render_to_string(
		template => 'configure/utility_controller',
	);

	$c->render(json => { html => $html, controls => $controls });

}

# POST /manager/configure/utility_pools/save
sub action_19305 {
	my $c = shift;
	# The pool editor sends its whole state: the pools in the person's order and
	# the pool each job sits in (an empty id means the regular list). Saving the
	# whole thing keeps drag-and-drop, add, remove and rename to one route.
	my $pools = eval { decode_json($c->param('pools') // '[]') };
	$pools = [] unless ref $pools eq 'ARRAY';
	my $members = eval { decode_json($c->param('members') // '{}') };
	$members = {} unless ref $members eq 'HASH';

	my (@clean, %seen);
	foreach my $pool ( @{$pools} ) {
		next unless ref $pool eq 'HASH';
		my $id = $pool->{'id'} // '';
		$id =~ s/[^a-z0-9_]//g;
		$id = substr($id, 0, 40);
		next if $id eq '' || $seen{$id}++;
		my $raw = $pool->{'seconds'};
		my $seconds = (defined $raw && $raw =~ /^\s*-?\d+(\.\d+)?\s*$/)
			? int($raw)
			: int(&subs::time_abbrev_translator($raw, &subs::rightNow()) / 1000);
		$seconds = $gb::batch_groups->{$id}->{'seconds'} || 900 unless $seconds > 0;
		my $label = $pool->{'label'} // '';
		$label =~ s/^\s+|\s+$//g;
		$label = substr($label, 0, 40);
		$label = $id if $label eq '';
		push @clean, { id => $id, label => $label, seconds => $seconds };
	}

	my $signatorial = &subs::signatorial_designer();
	my $controls = eval { decode_json &subs::setting_grabber({ app => '__president', setting => 'utility_controller' }) } || {};
	$controls->{$signatorial} = clone $gb::timeouts unless $controls->{$signatorial};
	$controls->{$signatorial}->{'__batch_groups'} = \@clean;
	my $now = &subs::rightNow();
	$controls->{$signatorial}->{'__settings'}->{'last_change'} = $now;
	my $moved = 0;
	foreach my $t ( keys %{$gb::timeouts} ) {
		next if $t =~ /^__/;
		next unless ref $gb::timeouts->{$t} eq 'HASH';
		$controls->{$signatorial}->{$t} = clone $gb::timeouts->{$t} unless $controls->{$signatorial}->{$t};
		my $group = $members->{$t};
		$group = '' unless defined $group && $seen{$group};
		$controls->{$signatorial}->{$t}->{'group'} = $group;
		$moved++;
	}
	&subs::log_writer('utility pools: ' . scalar(@clean) . ' pool(s), ' . $moved . ' job(s) placed');
	&subs::setting_setter({ app => '__president', setting => 'utility_controller', value => encode_json($controls) });
	my $html = $c->render_to_string(template => 'configure/utility_controller');
	$c->render(json => { html => $html, pools => \@clean });
}

# POST /manager/configure/utility_batch_group/save
sub action_19355 {
	my $c = shift;
	# The old pace box: kept for a page that still carries one, and it now writes
	# the pool's pace rather than copying the interval onto every member.
	my $group = $c->param('group') || '';
	my $value = $c->param('interval');
	return $c->render(json => { error => 'unknown group' }) unless $gb::batch_groups->{$group};
	my $seconds = ($value =~ /^\s*-?\d+(\.\d+)?\s*$/)
		? ($value + 0)
		: &subs::time_abbrev_translator($value, &subs::rightNow()) / 1000;
	$seconds = int($seconds);
	return $c->render(json => { error => 'interval required' }) unless $seconds > 0;

	my $signatorial = &subs::signatorial_designer();
	my $controls = eval { decode_json &subs::setting_grabber({ app => '__president', setting => 'utility_controller' }) } || {};
	$controls->{$signatorial} = clone $gb::timeouts unless $controls->{$signatorial};
	my $pools = &subs::batch_pools($controls->{$signatorial});
	foreach my $pool ( @{$pools} ) {
		$pool->{'seconds'} = $seconds if $pool->{'id'} eq $group;
	}
	$controls->{$signatorial}->{'__batch_groups'} = $pools;
	$controls->{$signatorial}->{'__settings'}->{'last_change'} = &subs::rightNow();
	&subs::log_writer('utility batch: ' . $group . '=' . $seconds . 's');
	&subs::setting_setter({ app => '__president', setting => 'utility_controller', value => encode_json($controls) });
	my $html = $c->render_to_string(template => 'configure/utility_controller');
	$c->render(json => { html => $html, group => $group, interval => $seconds });
}

# GET /manager/configure/restore_list
sub action_19387 {
	my $c = shift;
	my @database = split '/', $c->session('database');
	pop @database;
	my $dir = join '/', @database;

	$dir = $dir . '/';
	$dir = &subs::home($c->param('president')) if $c->param('president');
	my $returner = &subs::restore_list($dir);
	@{$returner} = grep { $_->{'filename'} =~ /enc$/gi } @{$returner};
	my @tables = qw/appointments settings notifications websites continent backups/;

	$c->render(
		template => 'configure/restore_list',
		backups => $returner,
		tables => \@tables
	);
}

# POST /manager/configure/where_audit/run
sub action_19400 {
	my $c = shift;
	my $ok = &subs::where_audit_run({ reason => 'button' });
	my $report = &subs::where_audit_report();
	return $c->render(json => {
		ok       => $ok ? 1 : 0,
		at       => $report->{'at'} || 0,
		since    => $report->{'since'} || '',
		summary  => $report->{'summary'} || {},
		findings => $report->{'findings'} || 0,
		error    => $report->{'error'} || '',
	});
}

1;
