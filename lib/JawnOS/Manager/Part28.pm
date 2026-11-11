package Manager;

# Manager helpers, part 28 of 37. Moved out of Manager.pl so a
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

# the nearest thing we have measured, for naming a fix
sub help_nearest_place($lat, $lon, $within_km = 0.15) {
	my $rows = &subs::db_query("select app, value from settings where setting = 'home_plate' and value like '%latitude%' limit 400")->hashes;
	my ($best, $best_km);
	foreach my $r ( @{$rows} ) {
		my $hp = eval { decode_json $r->{'value'} } || {};
		next unless $hp->{'latitude'} && $hp->{'longitude'};
		my $d = help_distance_km($lat, $lon, $hp->{'latitude'}, $hp->{'longitude'});
		($best, $best_km) = ($r->{'app'}, $d) if !defined $best_km || $d < $best_km;
	}
	return undef unless defined $best_km && $best_km <= $within_km;
	return { app => $best, km => $best_km };
}

# the distance walked between two moments, read from the walk app's own fixes.
# A step is only counted between fixes close in time and at a walking pace, so
# the quiet hours between two walks do not read as one long stride.
sub help_walk_distance_km($start, $end) {
	my $rows = &subs::db_query("select latitude, longitude, timestamp from continent where app = 'walk' and cast(timestamp as integer) >= ? and cast(timestamp as integer) <= ? and latitude is not null and latitude != '' order by cast(timestamp as integer) asc", $start, $end)->hashes;
	my ($total, $prev) = (0, undef);
	foreach my $r ( @{$rows} ) {
		next unless $r->{'latitude'} =~ /^-?[0-9.]+$/ && $r->{'longitude'} =~ /^-?[0-9.]+$/;
		my ($lat, $lon) = ($r->{'latitude'} + 0, $r->{'longitude'} + 0);
		if ($prev) {
			my $dt = ($r->{'timestamp'} - $prev->{'timestamp'}) / 1000;
			my $km = help_distance_km($prev->{'lat'}, $prev->{'lon'}, $lat, $lon);
			$total += $km if $dt > 0 && $dt <= 1200 && (($km / $dt) * 3600) <= 15;
		}
		$prev = { lat => $lat, lon => $lon, timestamp => $r->{'timestamp'} };
	}
	return ($total, scalar @{$rows});
}

# the person's weight trend, read from their logged measurements, projected to a
# target: a line through the recent readings, taken to where it meets the budget
sub help_weight_projection($app, $target) {
	my $rows = &subs::db_query('select timestamp, measures from appointments where app = ? and measures like ? order by cast(timestamp as integer) asc', $app, '%"weight"%')->hashes;
	my @pts;
	foreach my $r ( @{$rows} ) {
		next unless ($r->{'measures'} || '') =~ /"weight":"?([0-9.]+)"?/;
		push @pts, [ $r->{'timestamp'} + 0, $1 + 0 ];
	}
	return { readings => 0 } unless @pts;
	# the pace is the recent weeks, not all time: a turn only shows there
	my $cutoff = $pts[-1][0] - (90 * 86400 * 1000);
	my @recent = grep { $_->[0] >= $cutoff } @pts;
	@recent = @pts if scalar @recent < 3;
	my ($n, $sx, $sy, $sxx, $sxy) = (0, 0, 0, 0, 0);
	my $t0 = $recent[0][0];
	foreach my $p ( @recent ) {
		my $x = ($p->[0] - $t0) / 86400000;  # days
		my $y = $p->[1];
		$n++; $sx += $x; $sy += $y; $sxx += $x * $x; $sxy += $x * $y;
	}
	my $latest = $pts[-1][1];
	my $den = $n * $sxx - $sx * $sx;
	return { readings => scalar @pts, latest => $latest } unless $den;
	my $slope = ($n * $sxy - $sx * $sy) / $den;  # per day
	my ($days, $when);
	if (defined $target && $target ne '' && abs($slope) > 0.00001) {
		my $d = ($target - $latest) / $slope;
		if ($d > 0) {
			$days = int($d + 0.5);
			$when = localtime(($pts[-1][0] + $d * 86400000) / 1000)->strftime('%B %d, %Y');
		}
	}
	return { readings => scalar @pts, latest => $latest, target => $target,
		slope_per_week => sprintf('%.3f', $slope * 7), days => $days, when => $when };
}

# "where was I at a moment" - the newest fix at or before it, named if we can
sub help_where($when) {
	my $target;
	if (defined $when && $when =~ /^\d{10,}$/) { $target = $when + 0; }
	else { my $t = eval { str2time($when // '') }; $target = $t ? $t * 1000 : undef; }
	return { error => "I could not read the time '" . ($when // '') . "'." } unless $target;
	my $now = &subs::rightNow();
	$target = $now if $target > $now;
	my $row = &subs::db_query('select latitude, longitude, timestamp from continent where cast(timestamp as integer) <= ? and cast(timestamp as integer) <= ? and latitude is not null and latitude != ? order by cast(timestamp as integer) desc limit 1', $target, $now, '')->hash;
	return { when => $target, found => 0 } unless $row && $row->{'latitude'};
	my $at = localtime($row->{'timestamp'} / 1000)->strftime('%A, %B %d %Y at %I:%M%P');
	my $near = help_nearest_place($row->{'latitude'}, $row->{'longitude'});
	return {
		found => 1, latitude => $row->{'latitude'}, longitude => $row->{'longitude'},
		timestamp => $row->{'timestamp'}, at => $at,
		place => ($near ? &subs::format_name($near->{'app'}) : undef),
		place_km => ($near ? sprintf('%.3f', $near->{'km'}) : undef)
	};
}

# "how far did I walk" and "when will I be <target>" - read from the fixes and
# the logged measurements, answered in the guide's own voice
sub help_measure($measure, $period, $target) {
	$measure = lc($measure // '');
	$period = lc($period // 'month');
	my $now = &subs::rightNow();
	if ($measure =~ /walk|distance|km|steps?|far/) {
		my $unit = ($period =~ /^(day|week|month|year)$/) ? $period : 'month';
		my ($start) = &subs::period_bounds($unit, $now);
		my ($km, $fixes) = help_walk_distance_km($start, $now);
		my $label = { day => 'today', week => 'this week', month => 'this month', year => 'this year' }->{$unit};
		my $text = sprintf('You have walked about %.1f km %s', $km, $label) . ($fixes ? ' (from ' . $fixes . ' place fixes).' : '.');
		return { measure => 'walk', period => $unit, km => sprintf('%.2f', $km), fixes => $fixes, text => $text };
	}
	if ($measure =~ /weight|pounds?|lbs?|kilos?|kg|mass/) {
		my $person = &subs::unformat_name(&subs::setting_grabber({ app => 'me', setting => 'my_name' }) || '');
		return { error => 'I do not know whose weight to read.' } unless $person;
		my $settings = &subs::settings_grabber({ app => $person });
		my $unit = 'lb';
		my $units = &subs::db_select('settings', ['value'], { app => $person, setting => 'unit' })->hashes;
		foreach my $u ( @{$units} ) {
			my $v = $u->{'value'};
			if ($v && $gb::measures->{$v} && grep { $_ eq 'weight' || $_ eq 'mass' } @{ $gb::measures->{$v}->{'types'} || [] }) { $unit = $v; last; }
		}
		if (!$target) {
			my $budgets = &subs::db_select('settings', ['value'], { app => $person, setting => 'budget' })->hashes;
			foreach my $b ( @{$budgets} ) {
				if (($b->{'value'} || '') =~ /([0-9.]+)\s*weight/i) { $target = $1; last; }
			}
		}
		my $proj = help_weight_projection($person, $target);
		my $text;
		if (!$proj->{'readings'}) { $text = 'I have no weight readings logged yet.'; }
		else {
			my $latest = $proj->{'latest'};
			my $rate = abs($proj->{'slope_per_week'} + 0);
			my $dir = $proj->{'slope_per_week'} >= 0 ? 'gaining' : 'losing';
			if (defined $target && $target ne '' && $proj->{'days'}) {
				$text = sprintf("You are at %.1f %s and %s about %.1f %s a week. At that pace you would reach %s %s around %s (about %d days).", $latest, $unit, $dir, $rate, $unit, $target, $unit, $proj->{'when'}, $proj->{'days'});
			}
			elsif (defined $target && $target ne '') {
				$text = sprintf("You are at %.1f %s. The trend has been flat or moving away from %s %s recently, so I cannot say when you would reach it.", $latest, $unit, $target, $unit);
			}
			else {
				$text = sprintf("You are at %.1f %s, %s about %.1f %s a week.", $latest, $unit, $dir, $rate, $unit);
			}
		}
		return { measure => 'weight', unit => $unit, target => $target, %{$proj}, text => $text };
	}
	return { error => 'I can only measure walking distance and weight so far.' };
}

# "play <x>" - run the music app's own folder walk (Music::music_search) over
# every known location, then keep the files that contain all the words asked for,
# best match first (a "Ben Folds Five" album folder and a "Mess" track are the
# same request). Hands back the one file to play. Shared by the guide's route and
# the remote command channel.
sub help_music_file($c, $q, $shuffle) {
	$q = '' unless defined $q;
	$q =~ s/^\s+//; $q =~ s/\s+$//;
	return { q => $q, found => 0 } unless length $q;
	$shuffle = $shuffle ? 1 : 0;
	my $settings = &subs::settings_grabber({ app => 'music' });
	# The guide searches the whole library, not the music window's browsing pick:
	# music_search reads a selected artist or album as *the folder set to walk*,
	# so with one artist lit the guide answered "found nothing" while the file
	# sat in the library ("Ben Folds Five Army" against a lit ac/dc). The
	# person's own words are the scope here.
	$settings->{'artist'} = [];
	$settings->{'album'} = [];
	my $misc = &misc_setting_list();
	my $device = &subs::device_setter();
	my @every = sort grep { /_location$/ } keys %{ $misc->{$device} || {} };
	my $port = $c->req->url->base->port;
	my $res = &music_search({ settings => $settings, c => $c, now_playing => {}, port => $port, misc_settings => $misc, return_files => 1, folders => \@every, permissive => (&help_media_revealed(&media_unlock_device($c)) ? 1 : 0) });
	my @files = @{ $res->{'files'} || [] };
	my @words = grep { length } split /\s+/, lc $q;
	my @hits;
	foreach my $f ( @files ) {
		my $lf = lc $f;
		my $ok = 1;
		my $last = -1;
		foreach my $w ( @words ) {
			my $at = index($lf, $w);
			if ($at < 0) { $ok = 0; last; }
			$last = $at if $at > $last;
		}
		next unless $ok;
		push @hits, { file => $f, last => $last };
	}
	return { q => $q, found => 0 } unless @hits;
	# the words landing earliest in the path is the tighter match (the album folder
	# holds the artist, the track name holds the song); a shorter path breaks a tie
	my @ranked = sort { $a->{'last'} <=> $b->{'last'} || length($a->{'file'}) <=> length($b->{'file'}) } @hits;
	my $file = $ranked[0]->{'file'};
	my $title = $file;
	$title =~ s{.*/}{};
	$title =~ s/\.[a-z0-9]+$//i;
	# Every match rides along, so "watch friends" plays the whole show rather
	# than one episode. The player splices its queue to the max_files setting, so
	# only what it will actually play is handed over; a requested shuffle happens
	# here, and same_order keeps the player from re-sorting it away.
	my @all = map { $_->{'file'} } @ranked;
	my $max = &subs::setting_grabber({ app => 'misc', setting => 'max_files' }) || 30;
	@all = @all[0 .. $max - 1] if scalar @all > $max;
	my $same_order = 0;
	if ($shuffle && scalar @all > 1) {
		@all = shuffle(@all);
		$same_order = 1;
	}
	return { q => $q, found => scalar @hits, file => $file, title => $title, files => \@all, same_order => $same_order };
}

# A name a write route was handed by our own client or by the model. An id wins
# over a name, so a rename is not an identity change; a name that now means more
# than one thing asks instead of acting on the wrong one. An exact app key the
# client sent is trusted even when the name is ambiguous, because a key is not a
# guess. A name nothing matches is handed back unchanged: stage may be naming an
# app that does not exist yet.
# exact => 1 is for a create: there a partial name is a new thing being named,
# not a shorthand for an old one, so only the key itself (or an id) is accepted.
sub guide_request_app {
	my ($app, $app_uuid, $opts) = @_;
	$opts = {} unless ref $opts eq 'HASH';
	$app = '' unless defined $app;
	$app_uuid = '' unless defined $app_uuid;
	my $key = &subs::unformat_name($app);
	if (length $app_uuid) {
		my $row = eval { &subs::db_query("select app from settings where setting = 'construct_uuid' and value = ? limit 1", $app_uuid)->hash };
		return { ok => 1, app => $row->{'app'}, uuid => $app_uuid } if $row && length($row->{'app'} || '');
	}
	my $r = &guide_resolve_target($app, kind => 'app');
	if ($r->{'ok'}) {
		my $score = $r->{'target'}->{'score'} || 0;
		return { ok => 1, app => $r->{'target'}->{'app'}, uuid => $r->{'target'}->{'uuid'} || '' }
			if !$opts->{'exact'} || $score >= 100;
	}
	my $cands = $r->{'candidates'} || [];
	my $top = @{$cands} ? ($cands->[0]->{'score'} || 0) : 0;
	if (length $key) {
		my @exact = grep { ($_->{'app'} || '') eq $key && ($_->{'score'} || 0) >= 60 } @{$cands};
		return { ok => 1, app => $key, uuid => $exact[0]->{'uuid'} || '' } if scalar @exact == 1;
	}
	# an exact tie is a question in both modes; a fuzzy or prefix tie is only a
	# question when the route meant an existing construct
	if (($r->{'reason'} || '') eq 'ambiguous' && (!$opts->{'exact'} || $top >= 100)) {
		return { ok => 0, ask => &guide_ask_candidates($app, $cands)->{'text'} };
	}
	return { ok => 1, app => $key, uuid => '' };
}

sub remote_command_run($c, $data) {
	my $text = $data->{'text'} // '';
	my $verb = $data->{'verb'} // '';
	my $args = $data->{'args'};
	$args = eval { decode_json $args } if !ref $args && defined $args && length $args;
	$args = {} unless ref $args eq 'HASH';
	my $action;
	if ($verb) {
		my $live = &help::live_verb_names();
		# qa_install is a machine action, not a Guide verb: the Configure panel
		# sends it over this same signed rail to prepare the target's QA
		# environment. qa_retime and qa_run_now are the same kind of action -
		# they write a timer drop-in and start a unit on the machine the house
		# chose. release_probe and release_now are the same kind of action too:
		# a machine with no promotion service asks its peers which one has it,
		# then hands that machine the release. None is offered to the model.
		return { ok => 0, error => 'unknown verb: ' . $verb }
			unless $live->{$verb}
				|| $verb eq 'qa_install'
				|| $verb eq 'qa_retime'
				|| $verb eq 'qa_run_now'
				|| $verb eq 'release_probe'
				|| $verb eq 'release_now';
		$action = { action => $verb, %{$args} };
	}
	elsif (length $text) {
		# the peer's own guide reads it, so the command stays on that machine
		my $model = $data->{'model'} || &subs::setting_grabber({ app => 'mail', setting => 'help_assistant' });
		return { ok => 0, error => 'no agent on this machine to read that' } unless $model;
		# Only the verbs this executor actually runs are offered, so the peer's guide
		# cannot pick an action whose effect has nowhere to go.
		my %remote_verbs = map { $_ => 1 } qw/open_app play_music measure where_when say ask done/;
		my $system = &help::actions_prompt(\%remote_verbs) . "\n\nRight now it is " . localtime(&subs::rightNow() / 1000)->strftime('%A, %B %d %Y, %I:%M%P') . ".\n";
		my ($out) = &subs::evaluation_model_call_role('help_assistant', $system, 'USER: ' . $text . "\n\nReply with the single JSON action.", &subs::ai_role_thinking_effective('help_assistant'));
		$action = $out ? &subs::json_from_model($out) : undef;
		return { ok => 0, error => 'the guide returned nothing readable' } unless $action && $action->{'action'};
	}
	else {
		return { ok => 0, error => 'send text, or a verb' };
	}
	my $obs = remote_command_execute($c, $action);
	return { ok => 1, action => $action, observation => $obs };
}

# Run one action here. Client effects go to our own tabs over the websocket;
# anything that is only words is answered directly.
sub remote_command_execute($c, $action) {
	$action = &guide_resolve_action($action) if ref $action eq 'HASH';
	return $action->{'text'} if ref $action eq 'HASH' && ($action->{'action'} || '') eq 'ask';
	my $a = $action->{'action'};
	# The release promotion is its own machine action: a peer asks whether this
	# machine holds the service, and then hands it the release. It is never a
	# Guide verb and it is not tied to the nightly switch.
	if ($a eq 'release_probe') {
		return &subs::release_service_check();
	}
	if ($a eq 'release_now') {
		return &subs::release_now_local({ dry_run => ($action->{'dry_run'} ? 1 : 0) });
	}
	# Off is a house decision the far end honours too: no timer edit and no
	# systemctl start may happen while the nightly system is turned off.
	if (($a eq 'qa_install' || $a eq 'qa_retime' || $a eq 'qa_run_now')
		&& &subs::qa_nightly_is_off(&subs::qa_nightly_device())) {
		return { ok => 0, error => 'the nightly system is off; choose a machine to turn it on' };
	}
	# Preparing the QA environment is local work the Configure panel asked for
	# over the peer rail; it never goes near the Guide's action table. A phone
	# or tablet refuses it even if someone sends the verb by hand.
	if ($a eq 'qa_install') {
		return { ok => 0, error => 'not an eligible device (computer or server only)' }
			unless &subs::qa_device_kind_eligible(&subs::device_setter());
		return &subs::qa_install_local({ dry_run => ($action->{'dry_run'} ? 1 : 0) });
	}
	# The nightly's schedule and its Run now are the same class of action: a
	# timer drop-in and a `systemctl start`, both on the one machine the house
	# chose. A phone refuses them, and so does any machine the setting does not
	# name - the panel's own guard already said no, but the far end must too.
	if ($a eq 'qa_retime' || $a eq 'qa_run_now') {
		return { ok => 0, error => 'not an eligible device (computer or server only)' }
			unless &subs::qa_device_kind_eligible(&subs::device_setter());
		my $chosen = &subs::qa_nightly_device();
		my $mine = &subs::signatorial_designer();
		return { ok => 0, error => 'this machine is not the chosen nightly device' }
			if length $chosen && (!$mine || $chosen ne $mine);
		if ($a eq 'qa_retime') {
			return &subs::qa_retime_local({
				times => (ref $action->{'times'} eq 'HASH' ? $action->{'times'} : {}),
				dry_run => ($action->{'dry_run'} ? 1 : 0),
			});
		}
		return &subs::qa_run_now_local($action->{'run'} // '', { dry_run => ($action->{'dry_run'} ? 1 : 0) });
	}
	# a runtime (learned) verb runs through the same primitive executor
	return guide_verb_execute($c, $action) if grep { $_->{'name'} eq ($a // '') } @{ &help::learned_verbs() };
	if ($a eq 'open_app' && $action->{'app'}) {
		my $js = &Websocket::console_command('appWindowOpener', $action->{'app'});
		&Websocket::send('server', { console => $js });
		return 'opened the ' . $action->{'app'} . ' window';
	}
	if ($a eq 'play_music' && $action->{'query'}) {
		my $r = help_music_file($c, $action->{'query'}, $action->{'shuffle'});
		return 'found nothing to play for "' . $action->{'query'} . '"' unless $r->{'found'};
		my $list = ($r->{'files'} && scalar @{$r->{'files'}}) ? $r->{'files'} : [ $r->{'file'} ];
		my $js = &Websocket::console_command('musicToggle', $list, ($r->{'same_order'} ? 1 : 0));
		&Websocket::send('server', { console => $js });
		return scalar(@{$list}) > 1 ? ('now playing ' . scalar(@{$list}) . ' matches') : ('now playing ' . $r->{'title'});
	}
	if ($a eq 'measure') {
		my $r = help_measure($action->{'measure'}, $action->{'period'}, $action->{'target'});
		return $r->{'text'} || $r->{'error'} || 'I measured nothing.';
	}
	if ($a eq 'where_when') {
		my $r = help_where($action->{'when'});
		return $r->{'error'} if $r->{'error'};
		return 'I have no place fix for ' . ($action->{'when'} // 'then') . '.' unless $r->{'found'};
		return 'The nearest fix before then was at ' . $r->{'at'} . ($r->{'place'} ? (', by ' . $r->{'place'}) : '') . '.';
	}
	return $action->{'text'} || ('did ' . ($a // 'nothing'));
}

# The local half: this machine sends a command to a peer.
sub remote_command_send($data) {
	my $uuid = $data->{'uuid'};
	my $rm = &subs::remote_machine_lister({ uuid => $uuid, limit => 1 });
	return { ok => 0, error => 'no such machine' } unless $rm && $rm->{'uuid'};
	$rm = &remote_useragent_maker({ signatorial => $rm->{'signatorial'}, rm => $rm });
	return { ok => 0, error => 'that machine is not reachable' } unless $rm->{'ua'};
	my $url = $rm->{'manager'} . '/manager/remote_command';
	my $ua = $rm->{'ua'};
	$ua->inactivity_timeout(defined $data->{'inactivity_timeout'} ? $data->{'inactivity_timeout'} : 30);
	$ua->request_timeout($data->{'request_timeout'})
		if defined $data->{'request_timeout'} && $data->{'request_timeout'} =~ /^\d+$/;
	my $res = eval {
		$ua->post($url => form => {
			signatorial => &subs::signatorial_designer(),
			text => $data->{'text'} || '',
			verb => $data->{'verb'} || '',
			args => (ref $data->{'args'} ? encode_json($data->{'args'}) : ($data->{'args'} || '')),
			target => $data->{'target'} || ''
		})->result;
	};
	return { ok => 0, error => 'no reply from ' . ($rm->{'hostname'} || $rm->{'fqdn'} || $uuid) } unless $res && $res->is_success;
	my $parsed = eval { decode_json $res->body };
	# a login gate coming back means the peer no longer trusts our session
	return { ok => 0, error => ($rm->{'hostname'} || $rm->{'fqdn'} || $uuid) . ' did not accept the sign-in (a fresh ticket there would renew it)' } unless $parsed && ref $parsed eq 'HASH';
	return $parsed;
}

# Remote keyboard and mouse, the peer half: a linked machine that this house
# already trusts sends one batch of pointer/key events and they are injected
# here. It is the same path the T-Deck's teletype uses, shared through
# remote_input.pl, so an X11 or Wayland backend installed for one serves both.
#
# The batch is small and arrives in order from the sending manager; moves are
# absolute fractions of this screen, so a lost or reordered batch cannot leave
# the pointer drifting.
sub remote_input_geometry {
	if (time - $remote_input_geometry_at > 10 || !$remote_input_geometry_cache) {
		$remote_input_geometry_cache = &remote_input::screen_geometry();
		$remote_input_geometry_at = time;
	}
	return $remote_input_geometry_cache;
}

# Adjacent moves and typed characters are one action each: a fast typist must
# not become a process per character, and a dragged pointer only needs its last
# position. Runs on both sides so a batch that crossed a handshake is still one
# string.
sub remote_input_coalesce($events) {
	my @out;
	foreach my $e ( @{$events} ) {
		next unless ref $e eq 'HASH';
		my $last = @out ? $out[-1] : undef;
		if (($e->{'t'} || '') eq 'move' && $last && ($last->{'t'} || '') eq 'move') {
			$out[-1] = $e;
		}
		elsif (($e->{'t'} || '') eq 'type' && $last && ($last->{'t'} || '') eq 'type') {
			$last->{'s'} = substr((($last->{'s'} // '') . ($e->{'s'} // '')), -2000);
		}
		else {
			push @out, $e;
		}
	}
	return \@out;
}

sub remote_input_apply($events) {
	$events = &remote_input_coalesce($events);
	$remote_input_clipboard = undef;
	my $geometry = &remote_input_geometry();
	my $applied = 0;
	foreach my $e ( @{$events} ) {
		next unless ref $e eq 'HASH';
		my $t = $e->{'t'} || '';
		if ($t eq 'move') {
			next unless $geometry && $geometry->[0] && $geometry->[1];
			my ($w, $h) = @{$geometry};
			my $x = int(($e->{'x'} // 0) * $w);
			my $y = int(($e->{'y'} // 0) * $h);
			$x = 0 if $x < 0;
			$y = 0 if $y < 0;
			$x = $w - 1 if $x >= $w;
			$y = $h - 1 if $y >= $h;
			$applied++ if &remote_input::inject('move', $x, $y, $w, $h);
		}
		elsif ($t eq 'move_rel') {
			my ($dx, $dy) = (int($e->{'dx'} // 0), int($e->{'dy'} // 0));
			next unless $dx || $dy;
			$applied++ if &remote_input::inject('move_rel', $dx, $dy);
		}
		elsif ($t eq 'button') {
			my $button = lc($e->{'b'} // 'left');
			$button = 'left' unless $button =~ /^(?:left|middle|right)$/;
			$applied++ if &remote_input::inject($e->{'d'} ? 'mousedown' : 'mouseup', $button);
		}
		elsif ($t eq 'wheel') {
			my ($dy, $dx) = (int($e->{'dy'} // 0), int($e->{'dx'} // 0));
			next unless $dy || $dx;
			$applied++ if &remote_input::inject('wheel', $dy, $dx);
		}
		elsif ($t eq 'key') {
			# A key spec is a name, never a sentence: it is written to dotool's
			# stdin, where a newline would queue a second action.
			my $spec = $e->{'k'} // '';
			next unless $spec =~ /^[A-Za-z0-9_+]{1,40}$/;
			$applied++ if &remote_input::inject('key', $spec);
		}
		elsif ($t eq 'type') {
			my $text = $e->{'s'} // '';
			next unless length $text;
			# xdotool and dotool read bytes; a character string would warn and
			# could lose an accent.
			utf8::encode($text) if utf8::is_utf8($text);
			$applied++ if &remote_input::inject('type', substr($text, 0, 4096));
		}
		elsif ($t eq 'release') {
			$applied++ if &remote_input::inject('release');
		}
		elsif ($t eq 'clipboard_get') {
			$remote_input_clipboard = &remote_input::clipboard_read();
			$applied++;
		}
		elsif ($t eq 'clipboard_set' || $t eq 'paste') {
			my $text = $e->{'s'} // '';
			next unless length $text;
			$applied++ if $t eq 'paste'
				? &remote_input::clipboard_paste($text)
				: &remote_input::clipboard_write($text);
		}
	}
	return $applied;
}

# A peer that answered the handshake with a page or a refusal is not asked again
# for a minute: the signed HTTP route still carries input, and an old peer must
# not pay a dial on every batch.
sub remote_input_socket_cooling($key) {
	my $until = $remote_input_ws_failed{$key} || 0;
	return $until > time ? 1 : 0;
}

# The roster row is read on every batch otherwise (a SQLite query per 6 ms of
# typing). Ten seconds is long enough to save the work and short enough to
# follow a tunnel that moved.
sub remote_input_machine($uuid) {
	return undef unless $uuid;
	my $hit = $remote_input_rm{$uuid};
	return $hit->{'rm'} if $hit && time - $hit->{'at'} < 10;
	my $rm = &subs::remote_machine_lister({ uuid => $uuid, limit => 1 });
	$remote_input_rm{$uuid} = { rm => $rm, at => time } if $rm;
	return $rm;
}

sub remote_input_batch($events) {
	$events = eval { decode_json $events } unless ref $events eq 'ARRAY';
	$events = [] unless ref $events eq 'ARRAY';
	$#$events = 119 if @{$events} > 120;
	return $events;
}

# Mojo builds a text frame from a character string and would encode a byte
# string again, so an accented letter typed on one side would arrive mangled.
# Decode exactly once, as websocket_sender does.
sub remote_input_frame($object) {
	my $wire = encode_json($object);
	utf8::decode($wire) if defined $wire && length $wire && !utf8::is_utf8($wire);
	return $wire;
}

# The signed HTTP relay, used when a control socket cannot be opened. Every call
# signs and verifies with openssl, which is exactly why the socket exists.
sub remote_input_http($rm, $events) {
	my $cache_key = ($rm->{'uuid'} || '') . '|' . ($rm->{'manager'} || '');
	my $ua = $remote_input_ua{$cache_key};
	unless ($ua) {
		my $peer = &remote_useragent_maker({ signatorial => $rm->{'signatorial'}, rm => $rm });
		$ua = $peer->{'ua'};
	}
	return { ok => 0, error => 'that machine is not reachable' } unless $ua;
	$remote_input_ua{$cache_key} = $ua;
	$ua->inactivity_timeout(8);
	my $res = eval {
		$ua->post($rm->{'manager'} . '/manager/remote_input' => form => {
			signatorial => &subs::signatorial_designer(),
			events => $events,
		})->result;
	};
	unless ($res && $res->is_success) {
		my $status = $res ? $res->code : '';
		return { ok => 0, error => 'no reply from ' . ($rm->{'hostname'} || $rm->{'fqdn'} || $rm->{'uuid'} || '') . ($status ? " ($status)" : '') };
	}
	my $parsed = eval { decode_json $res->body };
	return $parsed if ref $parsed eq 'HASH';
	return { ok => 0, error => 'that machine did not understand the input' };
}

# One open control socket per peer. Signing the handshake is the expensive part
# (openssl on each end), so it is paid once and the frames after it are cheap.
# Nothing is sent on the socket until the peer's `hello` arrives: until then the
# signed HTTP route carries the input, so an old peer (or a handshake the gate
# refused after the upgrade) costs latency but never control.
sub remote_input_socket_for($rm, $browser_tab_id, $events) {
	my $key = ($rm->{'uuid'} || $rm->{'signatorial'} || '') . '|' . ($rm->{'manager'} || '');
	return 0 if &remote_input_socket_cooling($key);
	my $entry = $remote_input_ws{$key};
	if ($entry) {
		$entry->{'browser_tab_id'} = $browser_tab_id if $browser_tab_id;
		if ($entry->{'ready'} && $entry->{'socket'}) {
			$entry->{'socket'}->send(&remote_input_frame({ events => &remote_input_batch($events) }));
			return 1;
		}
		# still dialling: this batch goes through HTTP rather than waiting
		return 0;
	}
	my $manager = $rm->{'manager'} || '';
	return 0 unless $manager;
	my $url = $manager;
	$url =~ s{^https://}{wss://}i;
	$url =~ s{^http://}{ws://}i;
	$url =~ s{/manager/?$}{}i;
	$url .= '/manager/remote_input/ws?signatorial=' . uri_encode(&subs::signatorial_designer());
	my $ua = Mojo::UserAgent->new;
	$ua->insecure(1);
	# The auth gate needs the stored peer session, not only the signature: a
	# signed handshake passes the app gate, but a session-less one still gets the
	# Gate page. Carry the same cookie jar remote_command uses.
	my $peer = eval { &remote_useragent_maker({ signatorial => $rm->{'signatorial'}, rm => $rm }) };
	if ($peer && $peer->{'ua'} && $peer->{'ua'}->cookie_jar) {
		$ua->cookie_jar($peer->{'ua'}->cookie_jar);
	}
	$ua->connect_timeout(4);
	$ua->inactivity_timeout(20);
	$ua->on(start => sub { my ($ua, $tx) = @_; &subs::peer_sign_request($tx->req); });
	$entry = {
		ua => $ua,
		uuid => $rm->{'uuid'} || '',
		browser_tab_id => $browser_tab_id || '',
	};
	$remote_input_ws{$key} = $entry;
	$ua->websocket($url => sub {
		my ($ua, $tx) = @_;
		my $socket = ($tx && $tx->is_websocket) ? $tx->res->websocket : undef;
		unless ($socket) {
			delete $remote_input_ws{$key};
			$remote_input_ws_failed{$key} = time + 60;
			$log->info('remote input socket declined for ' . ($entry->{'uuid'} || '?') . ' code=' . ($tx && $tx->res->code ? $tx->res->code : 'none'));
			return;
		}
		$entry->{'socket'} = $socket;
		$entry->{'tx'} = $tx;
		$ua->inactivity_timeout(0);
		my $hello = 0;
		my $timer = Mojo::IOLoop->timer(2 => sub {
			return if $hello;
			my $sock = delete $entry->{'socket'};
			eval { $sock->finish } if $sock;
			delete $remote_input_ws{$key};
			$remote_input_ws_failed{$key} = time + 60;
			$log->info('remote input socket silent for ' . ($entry->{'uuid'} || '?'));
		});
		$socket->on(message => sub($socket, $msg) {
			my $m = eval { decode_json $msg } || {};
			my $kind = $m->{'t'} || '';
			if ($kind eq 'hello') {
				$hello = 1;
				Mojo::IOLoop->remove($timer) if $timer;
				$entry->{'ready'} = 1;
				delete $remote_input_ws_failed{$key};
				$log->info('remote input socket ready for ' . ($entry->{'uuid'} || '?'));
				my $dest = $entry->{'browser_tab_id'} || '';
				if ($dest) {
					&Websocket::send('server', {
						type => 'remote_input_result',
						destination => $dest,
						ok => 1,
						backend => $m->{'backend'},
						screen => $m->{'screen'},
						remote_uuid => $entry->{'uuid'},
						socket => 1,
					});
				}
			}
			elsif ($kind eq 'clipboard') {
				my $dest = $entry->{'browser_tab_id'} || '';
				return unless $dest;
				&Websocket::send('server', {
					type => 'remote_input_result',
					destination => $dest,
					ok => 1,
					clipboard => $m->{'text'},
					remote_uuid => $entry->{'uuid'},
				});
			}
		});
		$socket->on(finish => sub {
			Mojo::IOLoop->remove($timer) if $timer && !$hello;
			delete $remote_input_ws{$key};
			$remote_input_ws_failed{$key} = time + 60 unless $hello;
		});
	});
	return 0;
}

sub remote_input_send($data) {
	my $uuid = $data->{'uuid'};
	my $rm = &remote_input_machine($uuid);
	return { ok => 0, error => 'no such machine' } unless $rm && $rm->{'uuid'} && $rm->{'manager'};
	my $events = $data->{'events'};
	$events = encode_json($events) if ref $events eq 'ARRAY';
	$events = '[]' unless defined $events && length $events;
	if (&remote_input_socket_for($rm, $data->{'browser_tab_id'}, $events)) {
		return { ok => 1, queued => 1, socket => 1 };
	}
	my $result = &remote_input_http($rm, $events);
	$result->{'socket'} = 0 if ref $result eq 'HASH';
	return $result;
}

# ---- the Guide's write path: stage, then promote or drop ------------------
# The Guide never writes an appointment straight in. It stages a proposal, the
# person sees it, and only a promote turns it into a real appointment.
# The Guide's write path as named subs, so the routes and the voice brain share
# one implementation: a proposal staged by a spoken "remind me to ..." lands in
# the same staged_appointments row a typed one would.
sub guide_stage_appointment($c, $params) {
	my $uuid = &subs::random_string_creator(40);
	my $now = &subs::rightNow();
	my $app = &subs::unformat_name($params->{'app'} || '');
	my $type = $params->{'type'} || 'usual';
	my $timestamp = &guide_when_ms($params->{'timestamp'});
	my $title = $params->{'title'} || '';
	my $notes = $params->{'notes'} || '';
	my $data = $params->{'data'} || '';
	# resolved to the tree's own sign now (a start accrues negative), so the staged
	# row shows the length the person will get
	my $duration = &guide_duration_ms($params->{'duration'}, $type);
	&subs::db_insert('staged_appointments', {
		uuid => $uuid, staged_time => $now, source => ($params->{'source'} || 'guide'),
		app => $app, type => $type, timestamp => $timestamp, title => $title,
		notes => $notes, data => $data, duration => (defined $duration ? $duration : ''),
		device => ($params->{'device'} || &subs::device_setter()), status => 'pending'
	});
	return { staged => $uuid, app => $app, type => $type, timestamp => $timestamp, title => $title, duration => $duration };
}

sub guide_promote_staged($c, $uuid) {
	my $row = &subs::db_select('staged_appointments', undef, { uuid => $uuid })->hash;
	return { error => 'no such staged appointment' } unless $row;
	# a staged change edits an appointment that already exists, a staged delete
	# removes one, a staged create makes a new one - the row's kind tells them apart
	return guide_promote_delete($c, $row) if (($row->{'kind'} || '') eq 'delete');
	return guide_promote_update($c, $row) if (($row->{'kind'} || '') eq 'update');
	my $real_uuid = &subs::random_string_creator(40);
	my $notes = $row->{'title'} ? ($row->{'title'} . ($row->{'notes'} ? (" \x{2014} " . $row->{'notes'}) : '')) : $row->{'notes'};
	# Write through appointment_writer, not straight to the table. A bare insert
	# left the app's model/options empty, and the details view then met a string
	# where it wanted a hash; the writer works those out, fires the header, alarms
	# and budget, and stamps the row. source 'guide' marks it as the Guide's own,
	# so its auto-made appointments can be told apart from the person's.
	my $appt = {
		uuid => $real_uuid,
		app => $row->{'app'},
		type => ($row->{'type'} || 'usual'),
		timestamp => $row->{'timestamp'},
		server_time => &subs::rightNow(),
		notes => $notes,
		source => 'guide',
		device => $row->{'device'} || &subs::device_setter(),
	};
	# only hand data on when it is real JSON; an empty string is not
	$appt->{'data'} = $row->{'data'} if defined $row->{'data'} && $row->{'data'} =~ /^\s*[\[\{]/;
	# the length the person gave rides through as the negative accrual the tree stores
	$appt->{'duration'} = $row->{'duration'} if defined $row->{'duration'} && $row->{'duration'} =~ /^-?[0-9]+$/ && $row->{'duration'} != 0;
	&Manager::appointment_writer($c, $appt);
	&subs::db_update('staged_appointments', { status => 'promoted' }, { uuid => $uuid });
	return { promoted => $uuid, uuid => $real_uuid, app => $row->{'app'} };
}

1;
