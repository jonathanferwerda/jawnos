package Manager;

# manager_relational: route actions moved out of Manager.pl, one sub per route so a
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

use IPC::Open2 qw(open2);

our ($APP, $ws_live_window, $encoder, $decoder, $tuuid, $thread_uuid, $universal_splitter, $database, $sql, $remote_input_clipboard, $config_file, $config, $logfile, $log, $environment, $random_caching_string, $duty_file, $main_process, $device, $user_agent, %time_machine_guide_cache, @media_unlock_apps, %help_search_tables, %media_type_for_ext, %file_relay_down, @appointments, @results, %market_payment_family, @manager_bundle_files, $manager_bundle_cache, $js_minifier, %app_release_sha, %folders_desk_not_app, $jg_body, $remote_input_geometry_at, $remote_input_geometry_cache, %remote_input_ua, %remote_input_ws, %remote_input_rm, %remote_input_ws_failed, $public_ip_memo, $coding_protocols, $coding_protocols_mtime, $app_schema_done, $fingerprint_checked_at, $fingerprint_ok, %padlock_time_memo, %credential_browser_app, %app_gate_shadow_seen, $ws_server, %mailws_untrusted_rate);

# GET /manager/relational
sub action_28581 {
	my $c = shift;
	my $timestamp = $c->param('timestamp');
	my $cache = $c->param('cache');
	my $website = &relationalizer({
		timestamp => $timestamp,
		c => $c,
		focus => $c->param('focus'),
		cache => $cache
	});
	$c->render(text => $website->{'window'});
}

# GET /manager/relational/workspace
sub action_28834 {
	my $c = shift;
	my $focus = $c->param('focus') || '';
	$c->render(json => &relational_workspace($focus));
}

# POST /manager/relational/link
sub action_28839 {
	my $c = shift;
	my $focus = $c->param('focus') || '';
	my $member = $c->param('member') || '';
	my $type = $c->param('type') || '';
	my $movement = ($c->param('movement') || 'add') eq 'delete' ? 'delete' : 'add';
	my $ok = &relational_link($focus, $member, $type, $movement);
	my $workspace = &relational_workspace($focus);
	$workspace->{'ok'} = $ok ? 1 : 0;
	$workspace->{'error'} = $ok ? undef : 'could not link';
	$c->render(json => $workspace);
}

# GET /manager/relational/select
sub action_28851 {
	my $c = shift;
	my $construct = $c->param('construct');
	my $setting = $c->param('setting');
	&subs::setting_setter({ 'app' => 'relational', setting => $setting, value => $construct });
	my $server_time = &subs::rightNow();
	my $settings = &subs::settings_grabber({ app => 'relational' });
	my $relationals;
	%{$relationals} = %{$gb::relationals};
	foreach my $sc ( keys %{$gb::relationals} ) {
		$relationals->{$sc}->{'list'} =	&subs::db_query('select * from settings where (setting = ? or setting = ?) and value = ?', 'pos', 'mab', $gb::relationals->{$sc}->{'sing'})->hashes;
	}
	my $returner = { settings => $settings, relationalizer => &relationalizer({ settings => $settings, timestamp => $server_time, c => $c }) };

	$c->render(json => $returner);
}

# POST /manager/relational/adder
sub action_28867 {
	my $c = shift;
	my $construct = $c->param('construct');
	my $server_time = &subs::rightNow();
	my $addition = &subs::unformat_name($c->param('addition'));
	my $settings = &subs::settings_grabber({ app => $addition });
	if (!$settings->{'pos'}) {
		$settings = &subs::setting_initializer($addition . '_' . $construct,$server_time);
	}
	elsif (!$settings->{'mab'} && $settings->{'pos'} ne $construct) {
		&subs::setting_setter({ app => $addition, setting => 'mab', value => $construct });
		$settings->{'mab'} = $construct;
	}


	my @constructs = grep { $_->{'sing'} eq $construct } values %{$gb::relationals};

	my $returner = { ok => 1, app => $addition, settings => $settings, sc => $constructs[0] };

	# a new person construct is a person the moment it is made
	&people_link_sync() if ($construct eq 'person');

	$c->render(json => $returner);
}

# GET /manager/relational/search
sub action_28891 {
	my $c = shift;
	my $server_time = &subs::rightNow();
	if ($c->param('search_tool') eq 'categories') {
		&subs::setting_setter({ app => 'relational', 'setting' => 'category_search', 'value' => &subs::unformat_name($c->param('search')) });
	}
	else {
		&subs::setting_setter({ app => 'relational', 'setting' => 'contents_search', 'value' => &subs::unformat_name($c->param('search')) });
	}
	my $settings = &subs::settings_grabber({ app => 'relational' });
	my $returner = { settings => $settings, relationalizer => &relationalizer({ timestamp => $server_time, c => $c }) };
	$c->render(json => $returner);

}

# POST /manager/relational/sorter
sub action_28905 {
	my $c = shift;
	my $timestamp = $c->param('timestamp');
	my $uuid = $c->param('uuid');
	my $construct = $c->param('construct');
	my $b_uuid = $c->param('b_uuid');
	my $b_construct = $c->param('b_construct');
	my $movement = $c->param('movement');


	my $bubble = &subs::settings_grabber({ uuid => $uuid });
	my $bucket = &subs::settings_grabber({ uuid => $b_uuid });
	$b_construct = $bucket->{'pos'};
	$construct = $bubble->{'pos'};
	my $sc = eval { return decode_json $bucket->{'sc_' . $construct} } || [];

	push @{$sc}, $bubble->{'uuid'} unless grep { $_ eq $bubble->{'uuid'} } @{$sc};

	if ($movement eq 'delete') {
		@{$sc} = grep { $_ ne $bubble->{'uuid'} } @{$sc};
	}
	@{$sc} = grep { $_ ne 'all' } @{$sc};



	my $bc = eval { return decode_json $bubble->{'sc_' . $b_construct} } || [];
	push @{$bc}, $bucket->{'uuid'} unless grep { $_ eq $bucket->{'uuid'} } @{$bc};

	if ($movement eq 'delete') {
		@{$bc} = grep { $_ ne $bucket->{'uuid'} } @{$bc};
	}
	@{$bc} = grep { $_ ne 'all' } @{$bc};


	my $jsc = encode_json $sc;
	&subs::setting_setter({ app => $bucket->{'app'}, setting => 'sc_' . $construct, value => $jsc });
	my $jbc = encode_json $bc;
	&subs::setting_setter({ app => $bubble->{'app'}, setting => 'sc_' . $b_construct, value => $jbc });
	$bucket->{'sc_' . $construct} = $jsc;
	$bubble->{'sc_' . $b_construct} = $jbc;
	$gb::relational_construct->{$construct}->{'list'} = [];
	$gb::relational_construct->{$b_construct}->{'list'} = [];

	my $settings = &subs::settings_grabber({ app => 'relational' });
	my $returner = { movement => $movement, bucket_uuid => $bucket->{'uuid'}, bubble => $bubble, bucket => $bucket, sc => $sc, bc => $bc };
	$returner->{'bucket'} = $c->render_to_string(
		template => 'relational/bucket',
		all_settings => {},
		settings => $settings,
		const => $bucket,
		contents_search => $settings->{'contents_search'}
	);

	$returner->{'bubble'} = $c->render_to_string(
		template => 'relational/bucket',
		all_settings => {},
		settings => $settings,
		const => $bubble,
		contents_search => $settings->{'contents_search'}
	);

	$c->render(json => $returner);
}

# POST /manager/relational/autocalc
sub action_28968 {
	my $c = shift;
	my $uuid = $c->param('uuid');
	my $construct = $c->param('construct');
	my $returner = {
		tasks => [],
		model => [],
		option => [],
		optioncategory => [],
		subcategory => [],
		transactions => [],
		locations => []
	};
	my $rel = &subs::db_query('select * from settings where setting=? and value=?', 'uuid', $uuid)->hashes->[0];
	my $settings = &subs::settings_grabber({ app => $rel->{'app'} });
	foreach my $a ( qw/model option option_category subcategory/ ) {
		my $as = &subs::db_query('select * from ' . $a . ' where app=? or name=?',$rel->{'app'},$rel->{'app'})->hashes;
		foreach my $at ( @{$as} ) {
			my $name = $at->{'app'} eq $rel->{'app'} ? $at->{'name'} : $at->{'app'};
			my $set = &subs::settings_grabber({ app => $name });
			push @{$returner->{$a}}, { uuid => $set->{'uuid'}, app => $set->{'app'}, settings => $set };
		}
	}
	my $tasks = &subs::task_grabber($rel->{'app'});

	foreach my $t ( grep { $_->{'task'} } @{$tasks->{'tasks'}}) {
		my $set = &subs::settings_grabber({ app => $t->{'task'} });
		push @{$returner->{'tasks'}}, { uuid => $set->{'uuid'}, app => $set->{'app'}, settings => $set };
	}

	my $appts = &subs::db_query('select * from appointments where app=? and type=? and data is not null', $rel->{'app'}, 'transaction')->hashes;
	foreach my $appt ( @{$appts} ) {
		my $data = eval { return decode_json $appt->{'data'} } || {};
		foreach my $dk ( keys %{$data} ) {
			foreach my $d ( keys %{$data->{$dk}} ) {
				foreach my $i ( qw/item vendor manufacturer/ ) {
					if ($data->{$dk}->{$d}->{$i}) {
						my $tapp = &subs::unformat_name($data->{$dk}->{$d}->{$i});
						unless ( grep { $_->{'app'} eq $tapp } @{$returner->{'transactions'}}) {
							my $set = &subs::settings_grabber({ app => $tapp });
							push @{$returner->{'transactions'}}, { uuid => $set->{'uuid'}, app => $set->{'app'}, settings => $set };
						}
					}
				}
			}
		}
	}
	if ($settings->{'home_plate'}) {
		my $hp = eval { return decode_json $settings->{'home_plate'} };
		my $mult = .00001;
		my $continent = &subs::db_query('select distinct(app) from continent where latitude >= ? and latitude <= ? and longitude >= ? and longitude <= ?',
			($hp->{'latitude'} - $mult), ($hp->{'latitude'} + $mult), ($hp->{'longitude'} + $mult), ($hp->{'longitude'} - $mult))->hashes;
		foreach my $con ( @{$continent} ) {
			my $set = &subs::settings_grabber({ app => $con->{'app'} });
			push @{$returner->{'locations'}}, { uuid => $set->{'uuid'}, app => $set->{'app'}, settings => $set };
		}
	}

	# What the house has noticed running beside this app, so a relationship it
	# found can be filed by hand: the apps whose occurrences the evaluation's
	# event scan puts around this one more than chance would, each shown with the
	# lift and ticked to relate right here.
	my @noticed;
	my %noticed_seen = ( $rel->{'app'} => 1 );
	foreach my $entry ( @{ &subs::evaluation_context_scan($rel->{'app'}, &subs::rightNow() - 60 * 86400000, 30 * 60000, 6) } ) {
		next if $noticed_seen{ $entry->{'app'} }++;
		my $set = &subs::settings_grabber({ app => $entry->{'app'} });
		next unless $set->{'uuid'};
		push @noticed, { uuid => $set->{'uuid'}, app => $set->{'app'}, settings => $set, lift => $entry->{'lift'}, hits => $entry->{'hits'} };
	}
	$returner->{'noticed'} = \@noticed;

	$returner->{'html'} = $c->render_to_string(
		template => 'relational/autocalc',
		returner => $returner,
		uuid => $uuid,
		construct => $construct
	);



	$c->render(json => $returner);
}

# GET /manager/relational/tree
sub action_29051 {
	my $c = shift;
	my $uuid = $c->param('uuid');

	my $rel = &subs::db_select('settings', undef, { setting => 'uuid', value => $uuid })->hashes->[0];
	my $settings = &subs::settings_grabber({ app => $rel->{'app'} });
	$settings->{'formatted_name'} = &subs::format_name($settings->{'app'});
	my $relationships = {};
	foreach my $s ( grep { $_ =~ /^sc_/gi } keys %{$settings} ) {
		my $sc = $s;
		$sc =~ s/^sc_//gi;
		$settings->{$s} = eval { return decode_json $settings->{$s} } || [];
		foreach my $scs ( @{$settings->{$s}} ) {
			my $rel_settings = &subs::db_query('select * from settings where setting=? and value=?', 'uuid', $scs)->hashes->[0];
			$rel_settings->{'formatted_name'} = &subs::format_name($rel_settings->{'app'});
			push @{$relationships->{$sc}}, $rel_settings;
		}
	}

	my $returner = { rel => $rel, settings => $settings, relationships => $relationships };

	$returner->{'html'} = $c->render_to_string(
		template => 'relational/tree',
		rel => $rel,
		settings => $settings,
		relationships => $relationships
	);

	$c->render(json => $returner);
}

1;
