#!/usr/bin/env perl
package Manager;
use strict;
use warnings ;#'uninitialized';

use Mojo::Base 'Mojolicious::Controller';
use utf8;
use feature 'signatures';
use JawnOS::Platform::Paths ();

# The old `app` was Mojolicious::Lite's accessor for the one application object.
# Manager.pm is now loaded by JawnOS::startup, which publishes the app here
# before the require, so every `app->...` below still means the same thing.
our $APP;
sub app { return $APP }
# The helpers live in lib/JawnOS/Manager/Part*.pm, one require on first call. Every
# name is forward-declared (Manager/Declarations.pm), so this file and the
# controllers compile normally and a call resolves here instead of dying. This is
# registered before the init code below runs, because that code calls helpers.
require 'JawnOS/Manager/Declarations.pm';
require JawnOS::Manager::Index;
our $AUTOLOAD;
our %IN_AUTOLOAD;
sub AUTOLOAD {
	return if $AUTOLOAD eq 'Manager::DESTROY';
	my $name = $AUTOLOAD;
	my ($short) = $name =~ /([^:]+)$/;
	my $part = $JawnOS::Manager::Index::SUB{$short}
		or die "Undefined subroutine &$name called\n";
	# A part that loads without defining the sub leaves the forward-declared
	# stub in place; calling it re-enters here, and that second entry is the
	# one that reports it. (A coderef comparison cannot tell: the glob's CV
	# slot is reused, so \&name is the same ref before and after the load.)
	die "Undefined subroutine &$name called ($part does not define it)\n"
		if $IN_AUTOLOAD{$short};
	unless ($JawnOS::Manager::Index::LOADED{$part}) {
		$JawnOS::Manager::Index::LOADED{$part} = 1;
		require $part;
	}
	local $IN_AUTOLOAD{$short} = 1;
	no strict 'refs';
	goto &{$name};
}

use Mojo::Promise;
use Mojo::UserAgent;
use Time::Local;
use Time::Piece;
use Time::Duration;
use Date::Parse;
use Clone qw(clone);
use feature 'signatures';

use Mojolicious::Static;
use Mojo::Log;
use Mojo::Transaction::WebSocket;
use Mojo::Parameters;
use Mojo::DOM;
use Mojo::URL;

use Mojo::JSON qw(decode_json encode_json);
use URI::Encode qw(uri_encode uri_decode);
use List::Util qw(shuffle);
app->plugin('RenderFile');

# A websocket beat refreshes its row's liveness column on a slow cadence (the
# row itself is written only when something changed), so "still here" is judged
# over a window wide enough to cover a missed refresh rather than the old
# every-two-seconds beat. Rows are still deleted the moment a socket closes.
our $ws_live_window = 60000;

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

# A prefork worker is forked after this file is loaded, and the manager that
# forked it never ticks the IOLoop (Prefork polls its heartbeat pipe instead),
# so this next_tick runs in the worker only. It installs the parent-death guard
# before the worker's first request: a SIGKILLed manager takes its workers with
# it at once, not after the five-second heartbeat. See perl/parent_guard.pl.
our $worker_manager_pid = $$;
Mojo::IOLoop->next_tick(sub {
	return if $$ == $worker_manager_pid;
	require './perl/parent_guard.pl';
	parent_guard::worker($worker_manager_pid);
});
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
# The mail stack is loaded on demand (see subroutines.pl): heavy, and used by two
# routines only, so a worker that never handles mail should not pay for it.
use Sereal::Encoder qw(encode_sereal SRL_SNAPPY SRL_ZSTD);
use Sereal::Decoder qw(decode_sereal);
our $encoder = Sereal::Encoder->new({ compress => SRL_ZSTD, compress_level => 3 });
our $decoder = Sereal::Decoder->new();
use Minion;
use IPC::Open2 qw(open2);
no warnings 'uninitialized';
no warnings 'once';
require "./perl/Websocket.pl";
require "./perl/subroutines.pl";
require "./perl/junderground.pl";
require "./perl/AddressDirectory.pl";
require "./perl/remote_input.pl";
require "./perl/tls.pl";
require "./perl/webauthn.pl";
require "./perl/Music.pl";
require "./perl/hooks.pl";
require "./perl/tunnel.pl";
require "./perl/help.pl";
require "./perl/crew.pl";
require "./perl/printers.pl";

# The domain layer owns these now (domain.pl, package subs). The forward
# declarations are for the parser (and for any call spelled without parens);
# the glob aliases keep this file, the templates and the Music/Alarm callers
# working through the old Manager:: name, while subroutines.pl calls the
# subs:: name directly and no longer needs this file for them.
sub ocr_reader;
sub misc_setting_list;
sub remote_useragent_maker;
sub deletion_registration;
sub notification_sender;
sub embedded_toggle;
sub migration_already_applied;
sub guide_resolve_when;

*Manager::ocr_reader = sub { &subs::ocr_reader(@_) };
*Manager::misc_setting_list = sub { &subs::misc_setting_list(@_) };
*Manager::remote_useragent_maker = sub { &subs::remote_useragent_maker(@_) };
*Manager::deletion_registration = sub { &subs::deletion_registration(@_) };
*Manager::notification_sender = sub { &subs::notification_sender(@_) };
*Manager::embedded_toggle = sub { &subs::embedded_toggle(@_) };
*Manager::migration_already_applied = sub { &subs::migration_already_applied(@_) };
*Manager::guide_resolve_when = sub { &subs::guide_resolve_when(@_) };

# Second slice of the same move (guide aliases, budget, log reader, leave,
# database migrations, relay and coding path). Same contract as above.
sub leave;
sub original_timestamp;
sub appts_marker_builder;
sub log_reader;
sub remote_relay_request;
sub appointment_overlap;
sub father_time;
sub measure_calc_for;
sub budget_calculator;
sub budget_status_maker;
sub people_index;
sub people_chips;
sub help_app_hidden;
sub guide_name_normalize;
sub guide_name_distance;
sub guide_target_label;
sub guide_aliases_read;
sub guide_aliases_write;
sub guide_aka_read;
sub guide_alias_add;
sub guide_alias_remove;
sub guide_resolve_target;
sub guide_resolve_action;
sub guide_ask_candidates;
sub coding_repo;
sub coding_path;
sub update_database;

*Manager::leave = sub { &subs::leave(@_) };
*Manager::original_timestamp = sub { &subs::original_timestamp(@_) };
*Manager::appts_marker_builder = sub { &subs::appts_marker_builder(@_) };
*Manager::log_reader = sub { &subs::log_reader(@_) };
*Manager::remote_relay_request = sub { &subs::remote_relay_request(@_) };
*Manager::appointment_overlap = sub { &subs::appointment_overlap(@_) };
*Manager::father_time = sub { &subs::father_time(@_) };
*Manager::measure_calc_for = sub { &subs::measure_calc_for(@_) };
*Manager::budget_calculator = sub { &subs::budget_calculator(@_) };
*Manager::budget_status_maker = sub { &subs::budget_status_maker(@_) };
*Manager::people_index = sub { &subs::people_index(@_) };
*Manager::people_chips = sub { &subs::people_chips(@_) };
*Manager::help_app_hidden = sub { &subs::help_app_hidden(@_) };
*Manager::guide_name_normalize = sub { &subs::guide_name_normalize(@_) };
*Manager::guide_name_distance = sub { &subs::guide_name_distance(@_) };
*Manager::guide_target_label = sub { &subs::guide_target_label(@_) };
*Manager::guide_aliases_read = sub { &subs::guide_aliases_read(@_) };
*Manager::guide_aliases_write = sub { &subs::guide_aliases_write(@_) };
*Manager::guide_aka_read = sub { &subs::guide_aka_read(@_) };
*Manager::guide_alias_add = sub { &subs::guide_alias_add(@_) };
*Manager::guide_alias_remove = sub { &subs::guide_alias_remove(@_) };
*Manager::guide_resolve_target = sub { &subs::guide_resolve_target(@_) };
*Manager::guide_resolve_action = sub { &subs::guide_resolve_action(@_) };
*Manager::guide_ask_candidates = sub { &subs::guide_ask_candidates(@_) };
*Manager::coding_repo = sub { &subs::coding_repo(@_) };
*Manager::coding_path = sub { &subs::coding_path(@_) };
*Manager::update_database = sub { &subs::update_database(@_) };
{ package gb; }

# Run the schema migrations once per worker when the app comes up: a git pull
# (which the watcher follows with a restart) then lands its new schema on boot
# instead of waiting for a login. update_database is idempotent
# (migration_already_applied), so a restart with no schema change is cheap.
app->hook(before_dispatch => sub {
	unless ($Manager::schema_checked) {
		$Manager::schema_checked = 1;
		# one machine, one database: leftovers from older databases (server.enc,
		# laptop_*.enc, a stray .db) are discarded here, once per worker at boot
		eval { &subs::database_tidy(); };
		eval { &update_database({}); };
	}
});

our $tuuid    = Data::UUID->new;
our $thread_uuid = $tuuid->create_str();
our $universal_splitter = $gb::universal_splitter;
our $database;
our $sql;
our $remote_input_clipboard;
our $config_file = read_file(JawnOS::Platform::Paths::config_path());
our $config = decode_json $config_file;
our $logfile = &subs::home($config->{'logfile'});
write_file($logfile, '') if not -e $logfile;
our $log = Mojo::Log->new(path => $logfile);
&remote_input::set_log($log);
our $environment = $config->{'environment'};
our $random_caching_string = &subs::jawn_version();
our $duty_file = &subs::home('~/.president/on_duty');
write_file($duty_file, &subs::rightNow());
$gb::database_holder->{'last_restart'} = &subs::rightNow();

our $main_process = $$;
our $device = &subs::device_setter();
our $user_agent = $gb::user_agent;

# sshd is NOT started here. This file is Manager.pl's body: the master loads it
# into every worker of every server, so a start here ran once per worker and
# was skipped entirely by a replacement worker that found the daemon already up
# - the daemon then belonged to whichever worker started it and died with that
# process' group. President starts it once per tree instead ('sshd watcher' in
# perl/President.pl) with the prefix's keys and an absolute AuthorizedKeysFile.

# A pull interrupted by an app update or a tree restart leaves the
# `remote_upgrade` marker behind; peers then hear "merging" and skip this
# machine's newer rows until the age bound expires (the phone hid six rows this
# way, 2026-10-31). Drop a marker no live process owns as the tree comes up.
if ($device eq 'mobile') {
	my $up = &subs::remote_upgrade_lock_state();
	&subs::setting_setter({ app => '__president', setting => 'remote_upgrade', value => '' })
		if &subs::remote_upgrade_marker_reapable($up);
}

# What the guide made of a phrase the time machine could not read; cached per
# phrase so a typed word the poll re-sends every cycle costs one model call, not
# one per poll. A phrase mapped to undef is one the guide could not read either.
our %time_machine_guide_cache;

# The boot body is split into two parts, both required unconditionally and in
# the order the code used to run: nothing here is lazy, so the hooks and the
# $ENV{PURPOSE} worker blocks still run when this file loads.
require 'JawnOS/Manager/Core1_tables_hooks.pm';
require 'JawnOS/Manager/Core2_worker_boot.pm';
