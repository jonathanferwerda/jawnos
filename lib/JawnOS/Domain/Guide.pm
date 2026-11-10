package subs;

# Guide half of the domain layer: functions subroutines.pl calls that used
# to live in Manager.pl. Same package (subs) so every call site and the
# Manager:: aliases keep working; the Loader in lib/JawnOS/Domain/Loader.pm
# requires this file on the first call that needs it.
use strict;
use warnings;
use utf8;
use feature 'signatures';
no warnings 'experimental::signatures';

use Date::Parse qw(str2time);
use Mojo::JSON qw(decode_json encode_json);

# File-scope state owned by subroutines.pl, in this same package.
our $config;
our $device;
our $log;
our $logfile;

# Resolve a spoken or typed name. opts: kind => app|person|construct|machine|house.
sub guide_resolve_target {
	my ($text, %opts) = @_;
	$text = '' unless defined $text;
	# A qualifier narrows the kind before matching: app:music, person:john,
	# club:garden (a construct singular), machine:table, house:maple.
	my $want = $opts{'kind'} || '';
	my $filter_sing = '';
	if ($text =~ /^\s*([A-Za-z_]+)\s*:\s*(.+)$/s) {
		my $prefix = lc $1;
		my $rest = $2;
		my %kinds = (app => 'app', person => 'person', construct => 'construct', machine => 'machine', house => 'house');
		if ($kinds{$prefix}) {
			$want = $kinds{$prefix};
			$text = $rest;
		}
		else {
			foreach my $sc ( values %{$gb::social_constructs} ) {
				next unless lc($sc->{'sing'}) eq $prefix || lc($sc->{'name'}) eq $prefix;
				$want = 'construct';
				$filter_sing = $sc->{'sing'};
				$text = $rest;
				last;
			}
		}
	}
	# A house narrows the name to that house's constructs: maple/john. It is the
	# spoken form of a qualifier, so it is read before the name is normalized.
	my $house_filter = '';
	if ($text =~ m{^\s*([^/]+?)\s*/\s*(.+)$}s) {
		$house_filter = &guide_name_normalize($1);
		$text = $2;
	}
	# A short id pins the exact thing: john#7f3a.
	my $id_prefix = '';
	if ($text =~ s/#([A-Za-z0-9]{3,})\s*$//) { $id_prefix = $1; }
	my $query = &guide_name_normalize($text);
	return { ok => 0, reason => 'nothing named', candidates => [] } unless length $query;
	my $alias_map = &guide_aliases_read();
	my %alias_for_app;
	# aka rows live on the target app; the aliases map covers machines and houses
	# (and anything taught before this rule).
	my $aka_map = &guide_aka_read();
	foreach my $app ( keys %{$aka_map} ) {
		$alias_for_app{$app} = [ @{ $aka_map->{$app} || [] } ];
	}
	my %alias_for_key;
	foreach my $key ( keys %{$alias_map} ) {
		my $entry = $alias_map->{$key};
		next unless ref $entry eq 'HASH';
		my $kind = $entry->{'kind'} || '';
		if (($kind eq 'machine' || $kind eq 'house') && length($entry->{'uuid'} || '')) {
			push @{ $alias_for_key{ $kind . "\x1f" . $entry->{'uuid'} } }, $key;
		}
		elsif (length($entry->{'app'} || '')) {
			push @{ $alias_for_app{ $entry->{'app'} } }, $key;
		}
	}
	my $score_aliases = sub {
		my ($aliases) = @_;
		my ($score, $how) = (0, '');
		foreach my $raw ( @{$aliases} ) {
			next unless defined $raw && length $raw;
			my $alias = &guide_name_normalize($raw);
			next unless length $alias;
			return (100, 'exact') if $alias eq $query;
			if (index($alias, $query) == 0) {
				($score, $how) = (70, 'prefix') if $score < 70;
			}
			elsif (length($alias) >= 3 && length($query) >= 4 && index($query, $alias) == 0) {
				($score, $how) = (65, 'prefix') if $score < 65;
			}
			elsif (length($query) >= 4 && index($alias, $query) >= 0) {
				($score, $how) = (45, 'part') if $score < 45;
			}
			elsif (length($query) >= 4 && abs(length($alias) - length($query)) <= 2) {
				my $d = &guide_name_distance($alias, $query);
				if ($d <= 1) { ($score, $how) = (30, 'near') if $score < 30; }
				elsif ($d <= 2) { ($score, $how) = (20, 'near') if $score < 20; }
			}
		}
		return ($score, $how);
	};
	my $accept = sub {
		my ($kind, $construct) = @_;
		return 0 if length $filter_sing && $construct ne $filter_sing;
		return 1 unless length $want;
		return 1 if $want eq $kind;
		return 1 if $want eq 'app' && ($kind eq 'app' || $kind eq 'person');
		return 1 if $want eq 'construct' && ($construct || '') ne '';
		return 0;
	};
	my $index = &people_index();
	my %kind_of;
	my %display_name;
	my %house_of;
	my %house_name_of;
	foreach my $construct ( @{ $index->{'constructs'} || [] } ) {
		foreach my $row ( @{ $construct->{'rows'} || [] } ) {
			next unless defined $row->{'app'};
			$kind_of{ $row->{'app'} } = $construct->{'sing'};
			$display_name{ $row->{'app'} } = $row->{'name'} if $row->{'foreign'} && ($row->{'name'} || '') ne '';
			if (($row->{'house_uuid'} || '') ne '') {
				$house_of{ $row->{'app'} } = $row->{'house_uuid'};
				$house_name_of{ $row->{'app'} } = $row->{'house_name'} || '';
			}
		}
	}
	# this house is the provenance of its own constructs
	my $own_crest = &subs::crest_record_read();
	my $own_house_uuid = $own_crest->{'uuid'} || '';
	my $own_house_name = $own_crest->{'name'} || &subs::crest_house_name_read();
	my %person;
	my $people_rows = eval { &subs::db_select('people', undef, { status => 'active' })->hashes } || [];
	foreach my $p ( @{$people_rows} ) {
		$person{ $p->{'app'} } = $p if defined $p->{'app'} && length $p->{'app'};
	}
	my %used;
	my $used_rows = eval { &subs::db_query('select app, max(server_time) as used from appointments group by app')->hashes } || [];
	foreach my $row ( @{$used_rows} ) {
		$used{ $row->{'app'} } = $row->{'used'} if defined $row->{'app'};
	}
	my %apps;
	$apps{$_} = 1 for keys %{$gb::known_appts};
	my $construct_rows = eval { &subs::db_query("select distinct app from settings where setting in ('pos','mab')")->hashes } || [];
	$apps{ $_->{'app'} } = 1 for @{$construct_rows};
	my $appt_rows = eval { &subs::db_query('select distinct app from appointments')->hashes } || [];
	$apps{ $_->{'app'} } = 1 for @{$appt_rows};
	$apps{$_} = 1 for keys %person;
	my @candidates;
	foreach my $app ( keys %apps ) {
		next unless defined $app && length $app;
		my $is_person = $person{$app} ? 1 : 0;
		my $kind = $is_person ? 'person' : 'app';
		my $construct = $kind_of{$app} || '';
		next unless $accept->($kind, $construct);
		my @aliases = ($app, &subs::format_name($app));
		push @aliases, $display_name{$app} if ($display_name{$app} || '') ne '';
		push @aliases, @{ $alias_for_app{$app} || [] };
		push @aliases, $person{$app}->{'name'} if $is_person;
		my ($score, $how) = $score_aliases->(\@aliases);
		next unless $score;
		my $uuid = $is_person ? ($person{$app}->{'uuid'} || '') : '';
		$uuid = &subs::construct_uuid($app) unless length $uuid;
		my @memberships;
		if ($is_person) {
			foreach my $chip ( @{ &people_chips($index, $app) || [] } ) {
				push @memberships, $chip->{'label'} . ': ' . $chip->{'name'};
				last if scalar @memberships >= 3;
			}
		}
		push @candidates, {
			kind => $kind,
			app => $app,
			name => $display_name{$app} || ($is_person ? ($person{$app}->{'name'} || &subs::format_name($app)) : &subs::format_name($app)),
			uuid => $uuid,
			construct => $construct,
			foreign => (($house_of{$app} || '') ne '' ? 1 : 0),
			house_uuid => $house_of{$app} || $own_house_uuid,
			house_name => $house_name_of{$app} || $own_house_name,
			memberships => \@memberships,
			score => $score,
			how => $how,
			used => $used{$app} || 0,
		};
	}
	if (!$want || $want eq 'machine') {
		my $machine_rows = eval { &subs::db_select('remote_machines')->hashes } || [];
		foreach my $rm ( @{$machine_rows} ) {
			next unless $rm->{'signatorial'};
			my @aliases = grep { defined && length } ($rm->{'hostname'}, $rm->{'fqdn'}, $rm->{'ip'});
			push @aliases, @{ $alias_for_key{ 'machine' . "\x1f" . ($rm->{'uuid'} || '') } || [] };
			my @short = map { my $x = $_; $x =~ s/\..*$//; $x } grep { defined && length } ($rm->{'fqdn'});
			my ($score, $how) = $score_aliases->([ @aliases, @short ]);
			next unless $score;
			push @candidates, {
				kind => 'machine',
				app => $rm->{'hostname'} || $rm->{'fqdn'} || '',
				name => $rm->{'hostname'} || $rm->{'fqdn'} || $rm->{'ip'} || '',
				uuid => $rm->{'uuid'} || '',
				construct => '',
				memberships => [],
				score => $score,
				how => $how,
				used => $rm->{'server_time'} || 0,
			};
		}
	}
	if (!$want || $want eq 'house') {
		my $own = &subs::crest_record_read();
		if ($own->{'uuid'}) {
			my @aliases = ($own->{'name'}, &subs::crest_house_name_read());
			push @aliases, @{ $alias_for_key{ 'house' . "\x1f" . ($own->{'uuid'} || '') } || [] };
			my ($score, $how) = $score_aliases->(\@aliases);
			if ($score) {
				push @candidates, {
					kind => 'house', app => $own->{'name'} || '', name => $own->{'name'} || &subs::crest_house_name_read(),
					uuid => $own->{'uuid'}, construct => '', memberships => [], score => $score, how => $how, used => 0,
				};
			}
		}
		foreach my $entry ( @{ &subs::crest_peer_list_read() || [] } ) {
			next unless ref $entry eq 'HASH' && ref $entry->{'crest'} eq 'HASH';
			my $crest = $entry->{'crest'};
			next unless ($crest->{'uuid'} || '') ne '';
			my ($score, $how) = $score_aliases->([ $crest->{'name'}, @{ $alias_for_key{ 'house' . "\x1f" . ($crest->{'uuid'} || '') } || [] } ]);
			next unless $score;
			push @candidates, {
				kind => 'house', app => $crest->{'name'} || '', name => $crest->{'name'} || '',
				uuid => $crest->{'uuid'}, construct => '', memberships => [], score => $score, how => $how, used => 0,
			};
		}
	}
	@candidates = grep {
		my $hn = &guide_name_normalize($_->{'house_name'} || '');
		my $hu = lc($_->{'house_uuid'} || '');
		(length $hn && $hn eq $house_filter)
			|| (length $hu && index($hu, lc $house_filter) == 0)
	} @candidates if length $house_filter;
	@candidates = grep { index(lc($_->{'uuid'} || ''), lc($id_prefix)) == 0 } @candidates if length $id_prefix;
	@candidates = sort {
		$b->{'score'} <=> $a->{'score'}
			|| ($b->{'used'} || 0) <=> ($a->{'used'} || 0)
			|| lc($a->{'name'} || '') cmp lc($b->{'name'} || '')
	} @candidates;
	return { ok => 0, reason => 'none', candidates => [] } unless @candidates;
	splice @candidates, 12 if scalar @candidates > 12;
	my @top = grep { $_->{'score'} == $candidates[0]->{'score'} } @candidates;
	# An exact tie is ambiguous even at 100. A single prefix (70) is clear; a
	# fuzzy guess never acts on its own.
	if ($candidates[0]->{'score'} >= 60 && scalar @top == 1) {
		return { ok => 1, target => $candidates[0], candidates => \@candidates };
	}
	return { ok => 0, reason => 'ambiguous', candidates => \@candidates };
}

# The social people are settings rows (`pos` or `mab` = person), not the
# `people` table's device accounts. One read builds the whole picture: every
# app's effective construct, the settings uuid each device copy carries, and
# the membership arrays (`sc_<singular>`) those rows already keep. The
# Relational cache is deliberately not reused here: it caches rendered
# buckets, and this index is one small query over rows the window needs fresh.
sub people_index {
	my $rows = eval {
		&subs::db_query("select app, device, setting, value, server_time from settings where setting in ('pos','mab','uuid','house_uuid','house_name','house_pubkey','peer_name','peer_construct','peer_profile','web','crest_uuid') or substr(setting,1,3) = 'sc_'")->hashes;
	} || [];
	my $current = &subs::device_setter();
	my %apps;
	my %uuid_app;
	my %effective;
	foreach my $row ( @{$rows} ) {
		my $app = $row->{'app'} // '';
		next unless length $app;
		my $setting = $row->{'setting'} // '';
		$apps{$app} ||= { app => $app, uuids => {}, sc => {}, pos => '', mab => '', house_uuid => '', house_name => '', peer_name => '', web => '', crest_uuid => '' };
		if ($setting eq 'uuid') {
			my $uuid = $row->{'value'} // '';
			next unless length $uuid;
			$apps{$app}->{'uuids'}->{$uuid} = 1;
			$apps{$app}->{'uuid_rows'}->{$uuid} = {
				device => $row->{'device'} // '',
				server_time => $row->{'server_time'} // '',
			};
			$uuid_app{$uuid} = $app;
		}
		elsif ($setting eq 'pos' || $setting eq 'mab') {
			# a device keeps its own copy of a construct; the newest row on a
			# device is that device's answer, and the current device answers
			# for the whole app when it has one
			my $device = $row->{'device'} // '';
			my $stamp = $row->{'server_time'} // '';
			my $slot = $effective{$app}->{$setting}->{$device};
			unless ($slot && $slot->{'server_time'} gt $stamp) {
				$effective{$app}->{$setting}->{$device} = { value => $row->{'value'} // '', server_time => $stamp };
			}
		}
		elsif ($setting eq 'house_uuid' || $setting eq 'house_name' || $setting eq 'peer_name' || $setting eq 'web' || $setting eq 'crest_uuid') {
			# provenance of an imported construct; a local construct has none
			$apps{$app}->{$setting} = $row->{'value'} // '';
		}
		elsif ($setting =~ /^sc_(.+)$/) {
			my $sing = $1;
			my $list = eval { decode_json($row->{'value'} // '') } || [];
			next unless ref $list eq 'ARRAY';
			foreach my $uuid ( @{$list} ) {
				next unless defined $uuid && length $uuid;
				$apps{$app}->{'sc'}->{$sing}->{$uuid} = 1;
			}
		}
	}
	foreach my $app ( keys %apps ) {
		foreach my $setting ( qw/pos mab/ ) {
			my $devices = $effective{$app}->{$setting} || {};
			my $pick = $devices->{$current};
			unless ($pick) {
				foreach my $device ( keys %{$devices} ) {
					my $candidate = $devices->{$device};
					$pick = $candidate if !$pick || $candidate->{'server_time'} gt $pick->{'server_time'};
				}
			}
			$apps{$app}->{$setting} = $pick ? $pick->{'value'} : '';
		}
		# the row this machine writes to: its own device's copy when there is
		# one, otherwise the newest copy another machine made
		my $preferred = '';
		my $newest = '';
		my $newest_stamp = '';
		foreach my $uuid ( keys %{ $apps{$app}->{'uuid_rows'} || {} } ) {
			my $entry = $apps{$app}->{'uuid_rows'}->{$uuid};
			if (($entry->{'device'} || '') eq $current) { $preferred = $uuid; last; }
			if (!$newest || ($entry->{'server_time'} || '') gt $newest_stamp) {
				$newest = $uuid;
				$newest_stamp = $entry->{'server_time'} || '';
			}
		}
		$apps{$app}->{'preferred_uuid'} = $preferred || $newest || '';
	}
	# a membership array names the uuid of the construct's settings row, so
	# the reverse map is what turns "these uuids" into "these construct apps"
	my %member;
	foreach my $app ( keys %apps ) {
		my $sc = $apps{$app}->{'sc'} || {};
		foreach my $sing ( keys %{$sc} ) {
			foreach my $uuid ( keys %{$sc->{$sing}} ) {
				my $construct_app = $uuid_app{$uuid};
				next unless defined $construct_app;
				$member{$sing}->{$construct_app}->{$app} = 1;
			}
		}
	}
	my @person_apps = sort grep {
		my $entry = $apps{$_};
		(($entry->{'pos'} || '') eq 'person' || ($entry->{'mab'} || '') eq 'person') ? 1 : 0;
	} keys %apps;
	my @constructs;
	foreach my $scons ( sort { $a->{'order'} <=> $b->{'order'} } values %{$gb::social_constructs} ) {
		next if $scons->{'name'} eq 'people';
		my $sing = $scons->{'sing'};
		my @rows;
		foreach my $app ( keys %apps ) {
			my $entry = $apps{$app};
			next unless (($entry->{'pos'} || '') eq $sing || ($entry->{'mab'} || '') eq $sing);
			my @members;
			foreach my $member_app ( keys %{ $member{$sing}->{$app} || {} } ) {
				push @members, { app => $member_app, name => &subs::format_name($member_app) };
			}
			@members = sort { lc($a->{'name'}) cmp lc($b->{'name'}) } @members;
			push @rows, {
				app => $app,
				name => $entry->{'peer_name'} || &subs::format_name($app),
				foreign => ($entry->{'house_uuid'} || '') ne '' ? 1 : 0,
				house_uuid => $entry->{'house_uuid'} || '',
				house_name => $entry->{'house_name'} || '',
				web => $entry->{'web'} || '',
				crest_uuid => $entry->{'crest_uuid'} || '',
				member_count => scalar @members,
				members => \@members,
			};
		}
		@rows = sort { lc($a->{'name'}) cmp lc($b->{'name'}) } @rows;
		push @constructs, { name => $scons->{'name'}, sing => $sing, rows => \@rows };
	}
	return {
		apps => \%apps,
		uuid_app => \%uuid_app,
		member => \%member,
		person_apps => \@person_apps,
		constructs => \@constructs,
	};
}

sub guide_alias_add {
	my ($alias, $target, $app_key) = @_;
	my $key = &guide_name_normalize($alias);
	return { ok => 0, text => 'That alias is too short.' } unless length $key && length($key) >= 2;
	my $t;
	if (defined $app_key && length $app_key) {
		# the People window names a construct by its key, so nothing is resolved: a
		# name that is ambiguous today cannot make the alias land on the wrong one
		$app_key = &subs::unformat_name($app_key);
		my $index = &people_index();
		my $entry = $index->{'apps'}->{$app_key};
		return { ok => 0, text => 'No such construct.' } unless $entry;
		return { ok => 0, text => 'Another house keeps that construct; its names are theirs.' }
			if ($entry->{'house_uuid'} || '') ne '';
		$t = {
			kind => ($entry->{'pos'} || $entry->{'mab'} || 'app'),
			app => $app_key,
			uuid => &subs::construct_uuid($app_key),
			name => &subs::format_name($app_key),
		};
	}
	else {
		my $r = &guide_resolve_target($target, kind => '');
		unless ($r->{'ok'}) {
			return { ok => 0, text => &guide_ask_candidates($target, $r->{'candidates'} || [])->{'text'} };
		}
		$t = $r->{'target'};
	}
	my $app = $t->{'app'} || '';
	# A word another thing already answers to exactly is not an alias, it is a
	# collision: exact wins over everything, so teaching it would silently take
	# the word away. A prefix or fuzzy near-miss is not a collision - an alias is
	# an exact answer, and the person is deliberately choosing it over the guess.
	my $clash = &guide_resolve_target($alias, kind => '');
	my @clash;
	if ($clash->{'ok'} && ($clash->{'target'}->{'score'} || 0) >= 100) {
		@clash = ($clash->{'target'}) if ($clash->{'target'}->{'app'} || '') ne $app;
	}
	elsif (($clash->{'reason'} || '') eq 'ambiguous') {
		@clash = grep { ($_->{'score'} || 0) >= 100 && ($_->{'app'} || '') ne $app } @{ $clash->{'candidates'} || [] };
	}
	if (@clash) {
		my @labels = map { &guide_target_label($_) } @clash;
		@labels = @labels[0 .. 3] if scalar @labels > 4;
		return { ok => 0, text => '"' . $alias . '" already means ' . join('; ', @labels) . '.' };
	}
	if (length $app && ($t->{'kind'} || '') ne 'machine' && ($t->{'kind'} || '') ne 'house') {
		# An app or person: the aka row lives on the target itself, where the
		# existing aka convention and setting_initializer already look for it.
		my $aka = &guide_aka_read();
		my @tokens = @{ $aka->{$app} || [] };
		push @tokens, $alias unless grep { &guide_name_normalize($_) eq $key } @tokens;
		# one row per app, not one per device: old copies would otherwise keep
		# winning a removal from another machine
		&subs::db_query('delete from settings where app=? and setting=?', $app, 'aka');
		&subs::setting_setter({ app => $app, setting => 'aka', device => 'all', value => join(',', @tokens) });
		# do not leave a second copy in the map
		my $map = &guide_aliases_read();
		if (exists $map->{$key}) { delete $map->{$key}; &guide_aliases_write($map); }
	}
	else {
		my $map = &guide_aliases_read();
		$map->{$key} = {
			kind => $t->{'kind'} || 'app',
			app => $app,
			uuid => $t->{'uuid'} || '',
			name => $t->{'name'} || $app,
			construct => $t->{'construct'} || '',
			at => &subs::rightNow(),
		};
		&guide_aliases_write($map);
	}
	return { ok => 1, text => 'Remembered "' . $alias . '" for ' . ($t->{'name'} || $app) . '.', target => $t };
}

# The construct chips a person wears: each membership array names a construct
# app's settings uuid, and the index's reverse map names the app itself.
sub people_chips {
	my ($index, $app) = @_;
	my $entry = $index->{'apps'}->{$app} || {};
	my $sc = $entry->{'sc'} || {};
	my @chips;
	foreach my $scons ( sort { $a->{'order'} <=> $b->{'order'} } values %{$gb::social_constructs} ) {
		my $sing = $scons->{'sing'};
		next unless $sc->{$sing};
		my %seen;
		my @names;
		foreach my $uuid ( keys %{ $sc->{$sing} } ) {
			my $construct_app = $index->{'uuid_app'}->{$uuid} || '';
			next unless length $construct_app;
			next if $seen{$construct_app}++;
			push @names, { app => $construct_app, name => &subs::format_name($construct_app) };
		}
		foreach my $name ( sort { lc($a->{'name'}) cmp lc($b->{'name'}) } @names ) {
			push @chips, {
				construct => $scons->{'name'},
				sing => $sing,
				label => &subs::lang('construct.' . $scons->{'name'}),
				app => $name->{'app'},
				name => $name->{'name'},
			};
		}
	}
	return \@chips;
}

# Resolve the app a Guide action names before it runs. A clear answer is written
# back as the canonical key; a tie becomes an "ask" action, so the model does not
# get to pick one John Smith for the person.
sub guide_resolve_action {
	my ($action) = @_;
	return $action unless ref $action eq 'HASH';
	my $a = $action->{'action'} || '';
	my %needs = map { $_ => 1 } qw/open_app update stop delete/;
	my $text = $action->{'app'} || '';
	return $action unless length $text;
	return $action unless $needs{$a} || $a eq 'create' || $a eq 'generate';
	my $r = &guide_resolve_target($text, kind => 'app');
	if ($r->{'ok'}) {
		$action->{'app'} = $r->{'target'}->{'app'};
		$action->{'app_uuid'} = $r->{'target'}->{'uuid'} if length($r->{'target'}->{'uuid'} || '');
		$action->{'app_label'} = &guide_target_label($r->{'target'});
		return $action;
	}
	if ($a eq 'create' || $a eq 'generate') {
		# create may legitimately name a new app; an ambiguous existing name is
		# still a question, and generate's app is optional.
		my $cands = $r->{'candidates'} || [];
		if ($r->{'reason'} eq 'ambiguous' && @{$cands}) {
			return &guide_ask_candidates($text, $cands);
		}
		delete $action->{'app'} if $a eq 'generate';
		return $action;
	}
	# Opening an app we have never seen is allowed to fall through: the client
	# simply does nothing, and an app may exist that the index does not list yet.
	return $action if $a eq 'open_app' && $r->{'reason'} eq 'none';
	return &guide_ask_candidates($text, $r->{'candidates'} || []);
}

sub guide_alias_remove {
	my ($alias, $app_key) = @_;
	my $key = &guide_name_normalize($alias);
	return { ok => 0, text => 'No alias named.' } unless length $key;
	my $found = 0;
	# the People window removes a chip from one construct's row: only that row is
	# touched, so the same word on another construct survives
	my $only = (defined $app_key && length $app_key) ? &subs::unformat_name($app_key) : '';
	my $aka = &guide_aka_read();
	foreach my $app ( keys %{$aka} ) {
		next if length $only && $app ne $only;
		my @tokens = @{ $aka->{$app} || [] };
		my @keep = grep { &guide_name_normalize($_) ne $key } @tokens;
		next if scalar @keep == scalar @tokens;
		$found = 1;
		&subs::db_query('delete from settings where app=? and setting=?', $app, 'aka');
		&subs::setting_setter({ app => $app, setting => 'aka', device => 'all', value => join(',', @keep) }) if @keep;
	}
	my $map = &guide_aliases_read();
	if (exists $map->{$key} && (!length $only || ($map->{$key}->{'app'} || '') eq $only)) {
		delete $map->{$key};
		&guide_aliases_write($map);
		$found = 1;
	}
	return { ok => 0, text => 'I did not know "' . $alias . '".' } unless $found;
	return { ok => 1, text => 'Forgot "' . $alias . '".' };
}

sub guide_name_distance {
	my ($a, $b) = @_;
	return 0 if $a eq $b;
	return length($a) if !length($b);
	return length($b) if !length($a);
	my @prev = (0 .. length($b));
	for my $i ( 1 .. length($a) ) {
		my @cur = ($i);
		my $ca = substr($a, $i - 1, 1);
		for my $j ( 1 .. length($b) ) {
			my $cost = $ca eq substr($b, $j - 1, 1) ? 0 : 1;
			my $v = $prev[$j] + 1;
			$v = $cur[$j - 1] + 1 if $cur[$j - 1] + 1 < $v;
			$v = $prev[$j - 1] + $cost if $prev[$j - 1] + $cost < $v;
			push @cur, $v;
		}
		@prev = @cur;
	}
	return $prev[-1];
}

sub guide_target_label {
	my ($cand) = @_;
	return '' unless ref $cand eq 'HASH';
	my $name = $cand->{'name'} || $cand->{'app'} || '';
	my $kind = $cand->{'kind'} || 'app';
	my $label = $kind eq 'app' ? 'app' : $kind;
	$label = $cand->{'construct'} if ($kind ne 'person' && ($cand->{'construct'} || '') ne '');
	# an imported construct says whose it is, so two Gardens in different houses
	# are told apart in the question rather than by an opaque local key
	$label .= ' from ' . $cand->{'house_name'} if $cand->{'foreign'} && ($cand->{'house_name'} || '') ne '';
	if ($cand->{'memberships'} && @{ $cand->{'memberships'} }) {
		return $name . ' (' . $label . ': ' . join(', ', @{ $cand->{'memberships'} }) . ')';
	}
	return $name . ' (' . $label . ')';
}

# The long-standing aka convention: a settings row on the app itself, with a
# comma-separated list of other words for it ("21" for policy 21, "zzz" for
# sleep). It predates the Guide and is already used by setting_initializer, so
# the resolver reads it too; a taught alias for an app is written here.
sub guide_aka_read {
	my $rows = eval { &subs::db_query("select app, value from settings where setting='aka'")->hashes } || [];
	my %map;
	foreach my $row ( @{$rows} ) {
		my $app = $row->{'app'} || '';
		next unless length $app;
		foreach my $token ( split /,/, ($row->{'value'} || '') ) {
			$token =~ s/^\s+|\s+$//g;
			next unless length $token;
			push @{ $map{$app} }, $token;
		}
	}
	return \%map;
}

sub guide_ask_candidates {
	my ($text, $candidates) = @_;
	my @all = @{ $candidates || [] };
	my $top = @all ? $all[0]->{'score'} : 0;
	# Only the real contenders: an exact tie, or the same prefix tier. A fuzzy
	# "misc" beside "music" is not something to ask the person about.
	my @labels = map { &guide_target_label($_) } grep { $_->{'score'} >= $top - 10 } @all;
	@labels = @labels[0 .. 3] if scalar @labels > 4;
	return { action => 'ask', text => 'Which one did you mean: ' . join('; ', @labels) . '?' } if @labels;
	return { action => 'ask', text => 'I do not know "' . $text . '" yet.' };
}

sub guide_name_normalize {
	my ($text) = @_;
	my $s = lc(defined $text ? $text : '');
	$s =~ s/[^\p{L}\p{N}]+/ /g;
	$s =~ s/^\s+|\s+$//g;
	$s =~ s/^(?:the|my|a|an)\s+//;
	$s =~ s/\s+//g;
	return $s;
}

sub guide_aliases_write {
	my ($map) = @_;
	return 0 unless ref $map eq 'HASH';
	&subs::setting_setter({ app => '__president', setting => 'aliases', device => 'all', value => encode_json($map) });
	return 1;
}

# ---- names and identity -----------------------------------------------------
# A name is not an identity. "music" can mean the Music app or a club called
# Music, and two people can both be called John Smith. Resolution returns a
# ranked set of candidates and only acts when one is clearly ahead; anything
# else is handed back as a question, never guessed.
# A person's own words for a thing: "zzz" for sleep, "js" for John Smith.
# One synced map of normalized word -> target, so every machine understands the
# same aliases. The target is stored by identity (kind + uuid + app) as well as
# by name, so a rename does not break the alias.
sub guide_aliases_read {
	my $raw = eval { &subs::setting_grabber({ app => '__president', setting => 'aliases', device => 'all' }) } || '';
	my $map = eval { decode_json($raw) } || {};
	return ref $map eq 'HASH' ? $map : {};
}

sub guide_resolve_when($when) {
	my $now = &subs::rightNow();
	return $now unless defined $when && length $when;
	return $when + 0 if $when =~ /^\d{10,}$/;
	my $s = lc $when;
	$s =~ s/^\s+|\s+$//g;
	# the browser's helpResolveWhen takes "in 3 hours"; a spoken reminder uses
	# the same shape, and str2time would not read it
	if ($s =~ /^in\s+(\d+)\s*(minute|min|hour|hr|day|week)s?$/) {
		my ($n, $u) = ($1, $2);
		my $mult = ($u =~ /^min/) ? 60000 : ($u =~ /^h/) ? 3600000 : ($u =~ /^d/) ? 86400000 : 604800000;
		return $now + $n * $mult;
	}
	return $now if $s eq 'now';
	my $t = eval { str2time($when) };
	return $t ? $t * 1000 : $now;
}

1;
