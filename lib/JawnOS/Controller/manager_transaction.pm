package Manager;

# manager_transaction: route actions moved out of Manager.pl, one sub per route so a
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

# GET /manager/transaction/autocomplete
sub action_16801 {
	my $c = shift;
	my $attribute = $c->param('attribute');
	my $value = $c->param('value');
	my $app = $c->param('app');
	my $list;
	if ($attribute) {
		my $query = 'select distinct(app),' . $attribute . ' from appointments where app=? and (type=? or type=?) and ' . $attribute . ' like ? and ' . $attribute . ' != \'\' order by server_time desc limit 5';
		$list = &subs::db_query($query, $app, 'purchase','transaction', '%' . $value . '%')->hashes;
	}
	else {
		my $query = 'select distinct(app) from appointments where app like ? order by server_time desc limit 5';
		$list = &subs::db_query($query, '%' . $value . '%')->hashes;
	}
	foreach my $l ( @{$list} ) {
		$l->{'formatted'} = &subs::format_name($l->{$attribute});
		$l->{'unformatted'} = &subs::unformat_name($l->{$attribute});
	}


	$c->render('json' => $list);

}

# GET /manager/transaction/autofill
sub action_16824 {
	my $c = shift;
	my $name = &subs::unformat_name($c->param('name'));
	my $app = &subs::unformat_name($c->param('app'));
	my $movement = $c->param('movement');
	my $raw_value = $c->param('value');
	my $value = &subs::unformat_name($c->param('value'));


	my $query = 'select ' . $name . ' from appointments where ' . $name . '=? and app=? and type=? and movement = ? order by timestamp DESC LIMIT 40';
	my $probs = &subs::db_query($query,$value, $app,'transaction',$movement)->hashes;



	my $returner = {};
	foreach my $prob ( @{$probs} ) {
		my $occurrences = 1;
		if ($returner->{$prob->{$name}}) {
			$occurrences = $returner->{$prob->{$name}}->{'occurrences'} + 1;
		}
		$returner->{$prob->{$name}} = {
			unformatted => $prob->{$name},
			formatted => &subs::format_name($prob->{$name}),
			occurrences => $occurrences
		};
	}
	my $probable = {};
	if ($name eq 'quantity') {
		if ($raw_value =~ /[a-zA-Z]/) {
			my $gunit = $raw_value;
			$gunit =~ s/[^a-zA-Z]//gi;
			$probable->{'unit'} = $gunit if grep { $_ eq $gunit } keys %{$gb::measures};

		}
	}

	foreach my $ret ( keys %{$returner} ) {
		if ( $returner->{$ret}->{'occurrences'} > $probable->{'occurrences'} ) {
			$probable = $returner->{$ret};
		}
	}

	if (!$probable->{'unformatted'}) {
		$probable->{'unformatted'} = &subs::unformat_name($raw_value);
	}

	if ($name eq 'item' || $name eq 'vendor' || $name eq 'manufacturer') {
		my $a = $probable->{'unformatted'};
		$a = $app unless $raw_value =~ /[a-zA-Z.,]/gi;
		my $appts = &log_reader({ app => $a, view => 'centre_view' });
		if ($appts->{$a}) {
			foreach my $convert ( qw/app_measures packaging/ ) {
				if (eval { $appts->{$a}->{'setting'}->{$convert} }) {
					$appts->{$a}->{'setting'}->{$convert} = eval { return decode_json $appts->{$a}->{'setting'}->{$convert} } || [];
				}
			}
			$appts->{$a}->{'setting'}->{'source_app'} = $app;
			$probable->{'settings'} = $appts->{$a}->{'setting'};

			foreach my $mo ( @{$appts->{$a}->{'model'}}, @{$appts->{$a}->{'option'}} ) {
				$mo->{'characteristics'} = eval { return decode_json $mo->{'characteristics'} } || [];
				if (my @oc = grep { $_->{'name'} eq 'option_category' } @{$mo->{'characteristics'}}) {
					$mo->{'option_category'} = $oc[0]->{'value'};
				}
				else {
					$mo->{'option_category'} = 'uncategorized';
				}
			}
			if (scalar @{$appts->{$a}->{'model'}} > 0) {
				$probable->{'models'} = $c->render_to_string(
					template => 'apps/transaction/models',
					settings => $appts->{$a}->{'setting'},
					models => $appts->{$a}->{'model'},
					l => $appts->{$a}->{'list'}->[0],
					source => 'transaction',
				);
			}
			if (scalar @{$appts->{$a}->{'option'}} > 0) {
				$probable->{'options'} = $c->render_to_string(
					template => 'apps/transaction/options',
					settings => $appts->{$a}->{'setting'},
					options => $appts->{$a}->{'option'},
					option_categories => $appts->{$a}->{'option_category'},
					l => $appts->{$a}->{'list'}->[0],
					source => 'transaction',
				);
			}
		}
		else {
			$probable = {};
		}
	}
	if ($probable->{'unformatted'}) {
		$probable->{'informations'} = [];
		if ($movement eq 'income') {
			my $invoices = &subs::db_query('select * from appointments where type=? and app = ? order by timestamp', 'invoice', $probable->{'unformatted'})->hashes;
			@{$invoices} = grep { $_->{'status'} ne 'completed' } @{$invoices};
			$probable->{'informations'} = $invoices;
		}
		elsif ($movement eq 'expense') {
			my $purchases = &subs::db_query('select * from appointments where type=? and app = ? order by timestamp', 'purchase', $probable->{'unformatted'})->hashes;
			@{$purchases} = grep { $_->{'status'} eq 'delivered' } @{$purchases};
			$probable->{'informations'} = $purchases;
		}
		if (grep { $name eq $_ } qw/amount tax aux total/ ) {
			if (&subs::price_formatter($value) ne &subs::price_formatter($probable->{'unformatted'})) {
				$probable = {};
			}
		}
	}



	$c->render(json => $probable);
}

# GET /manager/transaction/information
sub action_16939 {
	my $c = shift;
	my $app = $c->param('app');
	my $timestamp = $c->param('timestamp');
	my $uuid = $c->param('uuid');
	my $returner = { autofillers => ['vendor','item', 'manufacturer'] };
	my $transaction = &subs::db_query('select * from appointments where uuid=?', $uuid)->hashes->[0];
	if ($transaction) {
		$transaction->{'data'} = eval { return decode_json $transaction->{'data'} };
		$transaction->{'data'}->{'vendor'} = $transaction->{'app'} || &subs::setting_grabber({ app => 'me', setting => 'store_name' }) unless $transaction->{'data'}->{'vendor'};

		foreach my $af ( @{$returner->{'autofillers'}} ) {
			$transaction->{'data'}->{'formatted_' . $af } = &subs::format_name($transaction->{'data'}->{$af});
		}
	}
	$returner->{'html'} = $c->render_to_string(
		template => 'apps/information',
		app => $transaction
	);
	$returner->{'transaction'} = $transaction;
	$c->render(json => $returner);
}

# GET /manager/transaction/history_retriever
sub action_16961 {
	my $c = shift;
	my $app = $c->param('app');
	my $timestamp = $c->param('timestamp');

	my $query = 'select * from appointments where data is not null and type=? and app=? and timestamp < ? order by timestamp desc limit 1';
	my $transactions = &subs::db_query($query, 'transaction', $app, $timestamp)->hashes->[0];
	unless ($transactions->{'app'}) {
		my $query = 'select * from appointments where data is not null and type=? and app=? and timestamp < ? order by timestamp desc limit 1';
		$transactions = &subs::db_query($query, 'transaction', $app, &subs::rightNow())->hashes->[0];
	}
	$c->render(json => $transactions);
}

# POST /manager/transaction/status
sub action_16974 {
	my $c = shift;
	my $timestamp = $c->param('timestamp');
	my $appt_uuid = $c->param('appt_uuid');
	my $status = $c->param('status');
	my $app = $c->param('app');
	&subs::db_update('appointments', { status => $status }, { app => $app, uuid => $appt_uuid });

	$c->render('text' => 'ok');


}

1;
