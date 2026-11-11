package Manager;

# Manager boot, part 2 of 2. The eager segment of the old Manager.pm: the folder
# and mailbox state, the junderground client, remote-input geometry, the padlock
# and credential caches, the websocket server and the three $ENV{PURPOSE} worker
# blocks. Manager.pm requires this last, at the exact point the code used to
# sit, so every block here still runs eagerly when the app loads.
use strict;
use warnings;
use utf8;
use feature 'signatures';
# File-scoped pragmas do not cross a require: repeat the ones the original
# file had in force at this point, so diagnostics are unchanged.
no warnings 'uninitialized';
no warnings 'once';
BEGIN {
	require File::Basename;
	require Cwd;
	my $dir = Cwd::abs_path(File::Basename::dirname(__FILE__));
	unshift @INC, "$dir/../.." if $dir && -d "$dir/../..";
}
use JawnOS::Transport ();
# Globals declared by the index (Manager.pm) and read below.
use vars qw($config $decoder $log);

# ---- junderground client ---------------------------------------------------
# The Chat Rooms section talks to these; every call is signed on this side with
# the house crest key, so the browser never sees it.
our $jg_body = sub ($c) {
	my $raw = $c->param('incoming_data') || '{}';
	return eval { decode_json($raw) } || {};
};

# The screen does not usually change between batches, and asking xprop for it
# on every pointer move would add a process to each one. A ten-second memory
# keeps a monitor that is plugged in from being missed for long.
our $remote_input_geometry_at = 0;
our $remote_input_geometry_cache;

our %remote_input_ua;
our %remote_input_ws;
our %remote_input_rm;
our %remote_input_ws_failed;

# The remote_control panel's Me view names this machine's public address, which is
# the quickest proof that the VPN is really carrying the traffic: with an exit
# node in force the echo service sees that machine, and without one it sees the
# ISP. The answer is kept for 30 seconds; `refresh` skips it so toggling the VPN
# repaints at once instead of showing the previous route's address. The lookup is
# asynchronous, so a slow or unreachable echo service cannot stall the manager.
our $public_ip_memo;

# The Coding agent's protocols: the baked, tracked copy first (so every machine
# carries them, even though AGENTS.md itself is gitignored), else a local AGENTS.md
# if there is one. Cached by mtime so a run does not re-read it every turn.
our $coding_protocols;
our $coding_protocols_mtime;

our $app_schema_done;

# The server machine's own fingerprint reader, if it has an enrolled finger.
# Checked at most once a minute: fprintd-list talks to D-Bus.
our ($fingerprint_checked_at, $fingerprint_ok);

# The lock timers are milliseconds, not secrets: a plain number is readable by
# every worker, and an older sealed value still decrypts. A sealed value is
# opened once per worker rather than on every request: the answer is a pure
# function of (key, ciphertext), so the memo is exact - a rotation or a re-seal
# changes the key id or the ciphertext and misses. It is capped because a lock
# stamp is rewritten whenever the timer moves.
our %padlock_time_memo;

# ---- the keyboard's vault ---------------------------------------------------
# A saved login or field is one row: the non-secret metadata used to offer it
# (app, origin, kind, label, hints) and a note_encrypter() payload holding the
# values. The payload is sealed with the house key, so it rides the ordinary
# sync rail - and a remote backup - without the secrets being readable there.
#
# Scope is the security rule: a row with an `origin` belongs to that site and is
# only offered for that site; a row without one belongs to that app package. A
# browser package may not save a password without a site, because the keyboard
# cannot see the address bar and a package-wide Chrome password would be offered
# on every site (the Autofill service is what reads the web domain).

our %credential_browser_app = map { $_ => 1 } qw(
	com.android.chrome com.brave.browser com.microsoft.emmx org.mozilla.firefox
	com.sec.android.app.sbrowser com.opera.browser com.opera.mini.native
	com.duckduckgo.mobile.android com.vivaldi.browser com.ecosia.android
);

# The app gate in shadow mode writes what it would refuse. A browser with no app
# key sends every request through here, so a repeating poll wrote the same line
# on every tick (tens of thousands of lines in the log). Name each
# (method, path, caller) once a minute instead: a route that would be refused is
# still recorded, without the repeated write becoming a per-request cost.
our %app_gate_shadow_seen;

our $ws_server;

if ($ENV{PURPOSE} && ($ENV{PURPOSE} eq 'alarm' || ($ENV{PORT_ENV} eq 'development' && $ENV{PURPOSE} eq 'main'))) {
	#require './perl/Alarm.pl';
	#&Alarm::alarm_clock();;
}

if ($ENV{PURPOSE} && ($ENV{PURPOSE} eq 'websocket' || ($ENV{PORT_ENV} eq 'development' && $ENV{PURPOSE} eq 'main'))) {
	# Sessions are ptys owned by this worker: a restarted worker has none, so
	# the list a person sees must not promise shells that no longer exist.
	$gb::terminal_sessions = {};
	&subs::cache_set({ app => 'terminal', context => 'sessions', warranty => '-1d' }, {});

	my %buffers;

	# These sockets are how a manager worker hands a live push to the websocket
	# worker that holds the page's socket. The websocket worker must bind them
	# *itself*, after the fork: bound earlier (in the process that loads this
	# file), the pre-fork server's start registers the listeners as MOJO_REUSE
	# descriptors and the forked worker then "reuses" a file descriptor while
	# no path exists on disk. Every push then looked delivered to the caller
	# while the page never saw it - the phone's silent MMS failure. Bound here,
	# on the worker's first tick, the path is real; and a worker that is
	# recycled leaves a stale path behind, so any path that stops answering is
	# bound again. (See ws_server_socket: it also clears this path from
	# MOJO_REUSE, which is what made the reuse win over a real bind.)
	my $ws_binder_pid = $$;
	my $ws_bind_all = sub {
		my ($check) = @_;
		# On TCP one port carries every app (the payload names its app), so there
		# is nothing per-app to probe or rebind.
		if (JawnOS::Transport::tcp()) {
			my $server = $ws_server->{'__tcp'};
			return if $server && defined Mojo::IOLoop->acceptor($server);
			$ws_server->{'__tcp'} = &ws_server_socket({ app => 'ws' });
			return;
		}
		foreach my $ws ( @{$gb::ws_apps} ) {
			my $file = &subs::ws_dir() . '/' . &subs::path_name($ws);
			if ($check && -e $file) {
				my $probe = JawnOS::Transport::client_unix_socket($file);
				if ($probe) { close $probe; next; }
			}
			$ws_server->{$ws} = &ws_server_socket({ app => $ws });
		}
	};
	# only a forked worker binds: the loader's own loop never accepts, so a
	# listener it held would swallow a push with no page socket to deliver to
	Mojo::IOLoop->next_tick(sub { $ws_bind_all->(0) if $$ != $ws_binder_pid });
	Mojo::IOLoop->recurring(5 => sub { $ws_bind_all->(1) if $$ != $ws_binder_pid });
	sub ws_server_socket($data) {
		my $app = $data->{'app'} || 'general';
		my $file;
		my $args;
		if (JawnOS::Transport::tcp()) {
			my $existing = $ws_server->{'__tcp'};
			return $existing if $existing && defined Mojo::IOLoop->acceptor($existing);
			$args = JawnOS::Transport::server_args('ws') or return undef;
		}
		else {
			my $folder = &subs::ws_dir();
			`mkdir -p $folder` unless -e $folder;
			$file = $folder . '/' . &subs::path_name($app);
			# a reused descriptor wins over a real bind in Mojo's listen(), and the
			# pre-fork server put this path in MOJO_REUSE from the loader's own
			# listeners; drop it so the bind really creates the path
			if ($ENV{'MOJO_REUSE'}) {
				$ENV{'MOJO_REUSE'} = join ',', grep { !/^unix:\Q$file\E:/ } split /,/, $ENV{'MOJO_REUSE'};
			}
			unlink $file if -e $file;
			$args = JawnOS::Transport::server_args('ws', path => $file) or return undef;
		}
		my $server = eval {
			Mojo::IOLoop->server($args => sub ($loop,$stream,$id) {
				$stream->handle->autoflush(1);
				$stream->high_water_mark(8 * 1024 * 1024);
				$buffers{$id} = '';
				$stream->on(read => sub ($stream, $bytes) {
					$buffers{$id} .= $bytes;

					while (1) {
						last if length($buffers{$id}) < 4;

			      my $payload_length = unpack('N', substr($buffers{$id}, 0, 4));

			      # If we don't have the full payload yet, wait for next event loop tick
			      last if length($buffers{$id}) < (4 + $payload_length);

			      # Extract header and data cleanly using 4-argument substr for speed
			      substr($buffers{$id}, 0, 4, '');
			      my $sereal_blob = substr($buffers{$id}, 0, $payload_length, '');

			      my $wsm = eval { $decoder->decode($sereal_blob) };

            if ($@) {
                warn "Worker $$: Failed to parse Sereal: $@";
                next;
            }
            next unless ref $wsm eq 'HASH';
            next if JawnOS::Transport::tcp()
                && !JawnOS::Transport::token_ok($wsm->{'token'});
						# The 'device' group is the embedded output bus, not a
						# browser app: deliver to the socket the websocket worker
						# holds for that chip. No chip connected means nothing goes
						# out; the caller already chose its HTTP fallback.
						if (($wsm->{'app'} || '') eq 'device') {
							&subs::device_ws_deliver($wsm);
						}
						else {
							&websocket_sender($wsm);
						}

						$stream->write($wsm->{'uuid'}) if defined $wsm->{'uuid'} && $wsm->{'uuid'};
					}
				});
				$stream->on(close => sub {
					delete $buffers{$id};
				});
			});
		};
		my $err = $@;
		$log->error('ws socket ' . ($file || 'tcp') . ' could not bind: ' . ($err || 'no acceptor')) if $err || !defined $server;
		return $server;
	}

	# One accessor for the per-app listener: native binds one path per app, TCP
	# binds one shared port (the payload names the app). A caller that only has
	# its app name asks here instead of touching $ws_server directly.
	sub ws_server_ensure($app) {
		return $ws_server->{$app} if $ws_server->{$app};
		if (JawnOS::Transport::tcp()) {
			my $server = $ws_server->{'__tcp'};
			return $server if $server && defined Mojo::IOLoop->acceptor($server);
			return $ws_server->{'__tcp'} = &ws_server_socket({ app => 'ws' });
		}
		return $ws_server->{$app} = &ws_server_socket({ app => $app });
	}

	my $mailfile = &subs::ws_dir() . '/mailws';

	my $mailws_server;
	my $mailws_listener = sub {
		my $args = JawnOS::Transport::server_args('mailws', path => $mailfile) or return;
		if (!JawnOS::Transport::tcp()) {
			# the loader no longer binds the per-app sockets (a fork child must),
			# so this process makes the folder rather than finding it made
			my $ws_folder = &subs::ws_dir();
			`mkdir -p $ws_folder` unless -d $ws_folder;
			unlink $mailfile if -e $mailfile;
		}
		$mailws_server = eval { Mojo::IOLoop->server($args => sub ($loop,$stream,$id) {
			$stream->handle->autoflush(1);
			$stream->high_water_mark(8 * 1024 * 1024);
			$buffers{$id} = '';
			$stream->on(read => sub ($stream, $bytes) {
				$buffers{$id} .= $bytes;

				while (1) {
					last if length($buffers{$id}) < 4;

			      my $payload_length = unpack('N', substr($buffers{$id}, 0, 4));

			      # If we don't have the full payload yet, wait for next event loop tick
			      last if length($buffers{$id}) < (4 + $payload_length);

			      # Extract header and data cleanly using 4-argument substr for speed
			      substr($buffers{$id}, 0, 4, '');
			      my $sereal_blob = substr($buffers{$id}, 0, $payload_length, '');
			      my $m = eval { $decoder->decode($sereal_blob) };
		        if ($@) {
		            warn "Worker $$: Failed to parse mail message: $@";
		            next;
		        }
		        next unless ref $m eq 'HASH';
		        next if JawnOS::Transport::tcp()
		            && !JawnOS::Transport::token_ok($m->{'token'});

					# one sender matches it against every tab's address
					my $count = &mailws_sender($m);

					# mail_arrival marked what the server just accepted: the tab socket
					# hears it for the start menu dot, and when no mailbox is watching
					# that thread the regular notification speaks
					if ($m->{'arrival'}) {
						&Websocket::send('tab', { type => 'mail_arrival', uuid => $m->{'uuid'}, message => $m->{'arrival_message'}, timestamp => $m->{'timestamp'} || &subs::rightNow() });
						unless ($count) {
							&notification_sender({ app => 'mailbox', role => 'all', title => 'Mail', message => $m->{'arrival_message'} || 'New mail', image => '/images/decipherable/envelope.png' });
						}
					}

				  $stream->write($m->{'uuid'});
				}
		    });
				$stream->on(close => sub {
						delete $buffers{$id};
				});
			});
		};
		$log->error('mailws could not bind: ' . $@) if $@;
	};
	$mailws_listener->();
	# like the per-app sockets above, the mail socket is put back up if it dies
	Mojo::IOLoop->recurring(5 => sub {
		my $is_running = defined Mojo::IOLoop->acceptor($mailws_server) ? 1 : 0;
		if (!$is_running) { $mailws_listener->(); }
	});
	sub websocket_close($app) {
		return if JawnOS::Transport::tcp();   # one shared listener serves every app
		$app = $app;
		unless (grep { $app eq $_ } @{$gb::ws_apps}) {
			if (scalar keys %{$gb::ws->{$app}} == 0) {
				Mojo::IOLoop->remove($ws_server->{$app});
				my $folder = &subs::ws_dir();
				my $file = $folder . '/' . &subs::path_name($app);
				`rm -R $file` if -e $file;
				delete $ws_server->{$app};
			}

		}
	}
}

# An unfiled letter's pace: a guest speaks at most this many times a minute.
our %mailws_untrusted_rate = ();

if ($ENV{PURPOSE} && ($ENV{PURPOSE} ne "alarm" && $ENV{PURPOSE} ne "watch" && $ENV{PURPOSE} ne "teletype" && $ENV{PURPOSE} ne "coding")) {

	app->sessions->samesite('lax');
	$ENV{MOJO_MAX_MESSAGE_SIZE} = 1023423423473741824;
	app->renderer->cache->max_keys(0);
	app->sessions->encrypted(1);
	# Every page is served over TLS; the plain loopback socket carries a
	# short-lived token instead (see ws_plain_token).
	app->sessions->secure(1);
	app->secrets($gb::secret_maker);
	app->sessions->cookie_name($ENV{'cookie_name'});
	if ($config->{'environment'} eq 'production') {
		app->log->level('error');
	} else {
		app->log->level('debug');
	}

}
else {
	1;
}

1;