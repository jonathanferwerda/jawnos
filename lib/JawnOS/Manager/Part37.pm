package Manager;

# Manager helpers, part 37 of 37. Moved out of Manager.pl so a
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
use JawnOS::Platform::Runner;
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

sub terminal_input_bytes {
	my $input = shift;
	return '' unless defined $input && length $input;
	my %named = (
		Enter => "\r", Return => "\r",
		Backspace => "\x7f", Delete => "\x1b[3~", Insert => "\x1b[2~",
		Tab => "\t", Escape => "\x1b", Esc => "\x1b",
		ArrowUp => "\x1b[A", ArrowDown => "\x1b[B", ArrowRight => "\x1b[C", ArrowLeft => "\x1b[D",
		Home => "\x1b[H", End => "\x1b[F",
		PageUp => "\x1b[5~", PageDown => "\x1b[6~",
		F1 => "\x1bOP", F2 => "\x1bOQ", F3 => "\x1bOR", F4 => "\x1bOS",
		F5 => "\x1b[15~", F6 => "\x1b[17~", F7 => "\x1b[18~", F8 => "\x1b[19~",
		F9 => "\x1b[20~", F10 => "\x1b[21~", F11 => "\x1b[23~", F12 => "\x1b[24~"
	);
	return $named{$input} if exists $named{$input};
	# A lone modifier is a key event, not a character: printing its name was the
	# old "Shift" and "Control" appearing in the middle of a command.
	return '' if $input =~ /^(?:Shift|ShiftLeft|ShiftRight|Control|ControlLeft|ControlRight|Alt|AltLeft|AltRight|AltGraph|Meta|MetaLeft|MetaRight|OS|Super|Hyper|CapsLock|NumLock|ScrollLock|Fn|FnLock|Symbol|SymbolLock|ContextMenu|Dead|Process|Unidentified)$/;
	utf8::encode($input) if utf8::is_utf8($input);
	return $input;
}

sub terminal_shell_clean {
	my ($spec) = @_;
	$spec = {} unless ref $spec eq 'HASH';
	my $host = $spec->{'host'} // '';
	my $user = $spec->{'user'} // '';
	my $port = $spec->{'port'} // 8022;
	$host = '' unless $host =~ /^[A-Za-z0-9._:\-\[\]]{1,255}$/;
	$user = '' unless $user =~ /^[A-Za-z0-9._\-]{1,64}$/;
	if ($host ne '' && $user eq '') {
		$user = `whoami`;
		chomp $user;
		$user = '' unless $user =~ /^[A-Za-z0-9._\-]{1,64}$/;
	}
	$port = 8022 unless $port =~ /^\d+$/ && $port > 0 && $port < 65536;
	return { host => $host, user => ($host ne '' ? $user : ''), port => 0 + $port };
}

sub terminal_shell_label {
	my ($spec) = @_;
	my $who = `whoami`;
	chomp $who;
	my $host = `hostname`;
	chomp $host;
	return ((($spec->{'user'} // '') ne '') ? $spec->{'user'} : $who) . '@' . $spec->{'host'}
		if (($spec->{'host'} // '') ne '');
	return $who . '@' . $host;
}

sub terminal_session_id_clean {
	my $id = shift // '';
	$id =~ s/[^A-Za-z0-9_\-]//g;
	$id = substr($id, 0, 64);
	$id = 't' . &subs::random_string_creator(12) if length($id) < 4;
	return $id;
}

sub terminal_sessions_note {
	my ($id, $session, $state) = @_;
	my $now = &subs::rightNow();
	# cache is local and never synced: which shells are alive is this machine's
	# own fact, not house data another machine should adopt.
	my $map = &subs::cache_get({ app => 'terminal', context => 'sessions' }) || {};
	$map = {} unless ref $map eq 'HASH';
	if (($state // '') eq 'ended') {
		delete $map->{$id};
	}
	else {
		my $spec = $session->{'spec'} || {};
		$map->{$id} = {
			id => $id,
			label => &terminal_shell_label($spec),
			host => $spec->{'host'} || '',
			user => $spec->{'user'} || '',
			port => $spec->{'port'} || '',
			state => $state,
			at => $now
		};
		foreach my $k ( keys %{$map} ) {
			delete $map->{$k} if (($map->{$k}->{'at'} || 0) < $now - 86400000);
		}
	}
	&subs::cache_set({ app => 'terminal', context => 'sessions', warranty => '-1d' }, $map);
}

sub terminal_session_for {
	my ($id) = @_;
	return undef unless ref $gb::terminal_sessions eq 'HASH';
	if ($id && $gb::terminal_sessions->{$id}) { return $gb::terminal_sessions->{$id}; }
	my @ids = keys %{$gb::terminal_sessions};
	return $gb::terminal_sessions->{$ids[0]} if scalar(@ids) == 1;
	return undef;
}

sub terminal_session_stop {
	my ($id, $quiet) = @_;
	my $session = $gb::terminal_sessions->{$id};
	return unless $session;
	delete $gb::terminal_sessions->{$id};
	if (my $fork = $session->{'fork'}) {
		eval {
			$fork->write("exit\r");
			$fork->close;
			$fork->stop('TERM');
		};
	}
	&terminal_sessions_note($id, $session, 'ended') unless $quiet;
	unless ($quiet) {
		&Websocket::send('server', { terminal_id => $id, terminal_shell => {
			state => 'ended',
			label => &terminal_shell_label($session->{'spec'} || {}),
			message => &subs::ui('The shell ended.')
		} });
	}
}

sub terminal_session_start {
	my ($id, $spec) = @_;
	$id = &terminal_session_id_clean($id);
	$spec = &terminal_shell_clean($spec);
	&terminal_session_stop($id, 1);
	my $session = { id => $id, spec => $spec, live => 0, rows => 24, cols => 80 };
	my $fork = JawnOS::Platform::Runner->new;
	$fork->conduit({ raw => 1, type => 'pty' });
	$fork->on(read => sub {
		my ($f, $bytes) = @_;
		return unless $gb::terminal_sessions->{$id} && $gb::terminal_sessions->{$id}->{'fork'} == $f;
		&Websocket::send('server', { terminal => encode_base64($bytes), terminal_id => $id });
		if (!$session->{'live'}) {
			$session->{'live'} = 1;
			my $state = (($spec->{'host'} // '') ne '') ? 'live' : 'local';
			&Websocket::send('server', { terminal_id => $id, terminal_shell => {
				state => $state, label => &terminal_shell_label($spec),
				host => $spec->{'host'}, user => $spec->{'user'}, port => $spec->{'port'}
			} });
			&terminal_sessions_note($id, $session, $state);
		}
	});
	$fork->on(close => sub {
		my ($f) = @_;
		return unless $gb::terminal_sessions->{$id} && $gb::terminal_sessions->{$id}->{'fork'} == $f;
		delete $gb::terminal_sessions->{$id};
		&Websocket::send('server', { terminal_id => $id, terminal_shell => {
			state => 'ended',
			label => &terminal_shell_label($spec),
			message => &subs::ui('The shell ended.')
		} });
		&terminal_sessions_note($id, $session, 'ended');
	});
	# stty sane matters: IO::Pty hands the child a raw pty, so without it the shell
	# neither echoes the keys a person types nor turns Ctrl+C into a signal.
	my ($program, @args) = ('sh', '-c', 'stty sane 2>/dev/null; exec bash -i');
	my %env = (
		%ENV,
		INPUTRC => '/dev/null',
		PROMPT_COMMAND => '',
		TERM => 'xterm-256color',
		COLORTERM => 'truecolor',
		TERM_PROGRAM => 'JawnOS',
		LANG => ($ENV{'LANG'} || 'C.UTF-8')
	);
	my $state = 'local';
	if (($spec->{'host'} // '') ne '') {
		$state = 'connecting';
		($program, @args) = ('ssh', '-tt', '-p', $spec->{'port'},
			'-o', 'StrictHostKeyChecking=accept-new',
			'-o', 'ConnectTimeout=10',
			'-o', 'ServerAliveInterval=30',
			$spec->{'user'} . '@' . $spec->{'host'});
	}
	$fork->start({ program => $program, program_args => \@args, env => \%env });
	$session->{'fork'} = $fork;
	$gb::terminal_sessions->{$id} = $session;
	my $label = &terminal_shell_label($spec);
	my $notice = "\r\n\x1b[38;5;114m[JawnOS]\x1b[0m "
		. ($state eq 'local' ? &subs::ui('local shell') : &subs::ui('connecting to') . ' ' . $label)
		. "\r\n";
	Mojo::IOLoop->timer(0 => sub {
		return unless $gb::terminal_sessions->{$id} && $gb::terminal_sessions->{$id}->{'fork'} == $fork;
		&Websocket::send('server', {
			terminal => encode_base64($notice),
			terminal_id => $id,
			terminal_shell => { state => $state, label => $label, host => $spec->{'host'}, user => $spec->{'user'}, port => $spec->{'port'} }
		});
	});
	# The fork is forked on the next tick, so the pty handle exists a moment later.
	Mojo::IOLoop->timer(0.4 => sub {
		return unless $gb::terminal_sessions->{$id} && $gb::terminal_sessions->{$id}->{'fork'} == $fork;
		if (my $pty = $fork->read_handle) {
			eval { $pty->set_winsize($session->{'rows'}, $session->{'cols'}, 0, 0) };
		}
	});
	&terminal_sessions_note($id, $session, $state);
	return $session;
}

sub terminal_session_write {
	my ($id, $bytes) = @_;
	my $session = &terminal_session_for($id);
	return unless $session && $session->{'fork'} && defined $bytes && length $bytes;
	$session->{'fork'}->write($bytes);
}

sub terminal_session_resize {
	my ($id, $rows, $cols) = @_;
	my $session = &terminal_session_for($id);
	return unless $session;
	$session->{'rows'} = $rows;
	$session->{'cols'} = $cols;
	if (my $fork = $session->{'fork'}) {
		if (my $pty = $fork->read_handle) {
			eval { $pty->set_winsize($rows, $cols, 0, 0) };
		}
	}
}

sub terminal_session_status {
	my ($id) = @_;
	my $session = &terminal_session_for($id);
	return unless $session;
	my $spec = $session->{'spec'} || {};
	my $state = (($spec->{'host'} // '') ne '')
		? ($session->{'live'} ? 'live' : 'connecting')
		: 'local';
	&Websocket::send('server', { terminal_id => $session->{'id'}, terminal_shell => {
		state => $state, label => &terminal_shell_label($spec),
		host => $spec->{'host'}, user => $spec->{'user'}, port => $spec->{'port'}
	} });
}

sub terminal_pty_runner {
	return;
}

sub paperRoute($msg) {
	my ($db,$database,$sql) = &subs::database_grabber();
	my $original_msg = $msg;
	if ( eval { encode_json $msg }) {
		my $m = encode_json $msg;
		if (eval { $sql->db } && $sql->dsn !~ /:$/) {
			my $server_time = &subs::rightNow();
			my $uuid = &subs::random_string_creator(20);
			&subs::db_insert('websocket_messages', {
				timestamp => $original_msg->{'timestamp'},
				message => $m,
				server_time => $server_time,
				uuid => $uuid,
				sent_count => 0,
				environment => 'papers'
			});
		}
	}
}

sub websocket_sender($wsm) {
	my $returner;
	my $return_msg = { save => [] };
	# The message travels as the bytes encode_json made. Mojo encodes a plain
	# string to UTF-8 again when it builds a text frame, so an emoji or an accent
	# would reach the browser double-encoded (and reach the phone's SMS bridge as
	# mojibake). Hand the frame characters instead, and encode exactly once.
	my $wire = $wsm->{'message'};
	utf8::decode($wire) if defined $wire && length $wire && !utf8::is_utf8($wire);
	if ($wsm->{'environment'} eq 'papers') {
		foreach my $subscriber ( keys %{$gb::paperboy} ) {
			$gb::paperboy->{$subscriber}->send($wire);
		}
	}
	else {
		my $original_msg = eval { return decode_json $wsm->{'message'} } || {};
		#return unless $original_msg->{'app'};
		if ($original_msg->{'pty'}) {
			&terminal_session_write($original_msg->{'terminal_id'}, $original_msg->{'input'});
		}
		my $msg = $original_msg;
		my $app = $wsm->{'app'};
		my $server_time = $wsm->{'server_time'};
		my $timestamp = $wsm->{'timestamp'};
		# the overlay/open/key/console pushes are how a locked device is driven
		# and how the phone hears about the lock; everything else that a server
		# pushes to a tab is dropped for a device the padlock gate considers
		# locked. The rule is the HTTP gate's own: this connection's device, so a
		# screen whose per-device unlock is still in the future keeps receiving
		# even when the house-wide pl_time has expired.
		my $locked_ok = $original_msg->{'padlock'} || $original_msg->{'padlock_open'} || $original_msg->{'padlock_key_show'} || $original_msg->{'console'};
		my $server_push = ($app eq 'server' && !$locked_ok) ? 1 : 0;
		my $recipient_locked = sub {
			my ($conn) = @_;
			return 0 unless $server_push && $conn;
			my $dev = $conn->{'device_uuid'} || '';
			# padlock_locked_now falls back to the house-wide stamp when the
			# connection has no device of its own, so an unpaired socket keeps
			# the old global answer instead of being fed while the house is locked.
			return &padlock_locked_now(undef, $dev);
		};
		# One recipient, one guarded write. A connection the loop has already
		# finished still sits in the registry until its finish handler runs, and a
		# write to it used to fail the whole broadcast: every tab behind it in the
		# hash lost the frame. Failure now drops that one connection and the rest
		# of the push continues - a reconnect resyncs what it missed.
		my $deliver = sub {
			my ($target, $conn, $key) = @_;
			return 0 unless $conn;
			my $ok = eval { $conn->send($wire); 1 };
			unless ($ok) {
				delete $target->{$app}->{$key} if defined $key;
			}
			return $ok ? 1 : 0;
		};
		my $count = 0;

		foreach my $ws ( $gb::ws, $gb::remote_ws ) {
			if ($count != 0) {
				my @app = split /\@/, $app;
				$app = $app[0];
			}
			else {

			}
			if ($original_msg->{'remote_only'}) {
				if ($original_msg->{'remote_only'} eq 'yes' && $count == 0) {
					next;
				}
			}
			if ( $original_msg->{'destination'}) {
				if (my $conn = $ws->{$app}->{$wsm->{'destination'}}) {
					$deliver->($ws, $conn, $wsm->{'destination'}) unless eval { $recipient_locked->($conn) };
				}
				elsif ($wsm->{'server_time'} > &subs::rightNow() - 10000) {
					push @{$return_msg->{'save'}}, $wsm;
				}
			}
			elsif ($original_msg->{'not_me'}) {
				foreach my $w ( keys %{$ws->{$app}} ) {
					if (my $conn = $ws->{$app}->{$w}) {
						next if $w eq $original_msg->{'browser_tab_id'};
						next if eval { $recipient_locked->($conn) };
						if ($msg->{'role'} && $msg->{'role'} ne 'all') {
							if ($msg->{'role'} ne $conn->{'privilege'}) {
								next;
							}
						}
						$returner = $deliver->($ws, $conn, $w);
					}
				}
			}
			else {
				foreach my $w ( keys %{$ws->{$app}}) {
					if (my $conn = $ws->{$app}->{$w}) {
						next if eval { $recipient_locked->($conn) };
						if ($msg->{'role'} && $msg->{'role'} ne 'all') {
							if ($msg->{'role'} ne $conn->{'privilege'}) {
								next;
							}
						}
						$returner = $deliver->($ws, $conn, $w);
					}
				}
			}
			$count++;
		}

	}
	return $return_msg;
}

sub mail_construct_columns() {
	return map { $gb::social_constructs->{$_}->{'sing'} } sort keys %{$gb::social_constructs};
}

sub mailws_constructs($picker) {
	my $constructs = {};
	foreach my $k ( keys %{$gb::social_constructs} ) {
		my $value = $picker->{$k};
		$value = undef unless defined $value && length $value;
		$constructs->{$k} = $value || $gb::social_constructs->{$k}->{'def'};
	}
	return $constructs;
}

sub mailws_trusted($c) {
	my $privilege = $c->session('privilege');
	return ($privilege eq 'citizen' || $privilege eq 'resident') ? 1 : 0;
}

sub mailws_picker_dialled($picker) {
	return 0 unless ref $picker eq 'HASH';
	foreach my $k ( keys %{$gb::social_constructs} ) {
		return 1 if defined $picker->{$k} && length $picker->{$k};
	}
	return 0;
}

sub mail_channel_key($constructs) {
	return join "\x1f", map { defined $constructs->{$_} ? $constructs->{$_} : '' } sort keys %{$gb::social_constructs};
}

sub mail_public_channels() {
	my $channels = eval { return decode_json &subs::setting_grabber({ app => 'mail', setting => 'public_channels' }) } || [];
	my @out;
	foreach my $ch ( @{$channels} ) {
		push @out, &mailws_constructs($ch) if ref $ch eq 'HASH';
	}
	return \@out;
}

sub mail_public_channel_allows($picker) {
	return 0 unless &mailws_picker_dialled($picker);
	my $key = &mail_channel_key(&mailws_constructs($picker));
	foreach my $ch ( @{&mail_public_channels()} ) {
		return 1 if &mail_channel_key($ch) eq $key;
	}
	return 0;
}

sub mail_channel_label($constructs) {
	return join ' ', map { &subs::format_name($constructs->{$_->{'name'}}) }
		sort { $a->{'order'} <=> $b->{'order'} } values %{$gb::social_constructs};
}

sub mailws_untrusted_throttle($id) {
	my $now = time();
	my $entry = $mailws_untrusted_rate{$id};
	if (!$entry || $now - $entry->{'at'} > 60) {
		$entry = $mailws_untrusted_rate{$id} = { at => $now, count => 0 };
	}
	$entry->{'count'}++;
	return $entry->{'count'} <= 20 ? 1 : 0;
}

sub mailws_address($c, $picker) {
	my $address = {};
	if ($c->session('privilege') eq 'guest' && $c->session('ticket_uuid')) {
		if ($picker && &mail_public_channel_allows($picker)) {
			$address->{'picker'} = &mailws_constructs($picker);
		}
		else {
			$address->{'ticket'} = $c->session('ticket_uuid');
		}
	}
	else {
		my $phone = $c->param('phone');
		my $email = $c->param('email');
		my $contact = $c->param('mail_contact');
		if ($phone && $phone ne 'null' && $phone ne 'undefined') {
			$address->{'phone'} = $phone;
		}
		elsif ($email && $email ne 'null' && $email ne 'undefined') {
			$address->{'email'} = $email;
		}
		elsif ($contact && $contact ne 'null') {
			$address->{'contact'} = $contact;
		}
		else {
			$address->{'picker'} = &mailws_constructs($picker);
		}
	}
	return $address;
}

sub mailws_message_constructs($m) {
	return undef if $m->{'phone'} || $m->{'email'} || $m->{'mail_contact'} || $m->{'contact'};
	my $picker = $m->{'picker'};
	$picker = eval { return decode_json $picker } unless ref $picker eq 'HASH';
	$picker = {} unless ref $picker eq 'HASH';
	return &mailws_constructs($picker);
}

sub mailws_address_matches($address, $m, $constructs) {
	return 0 unless $address;
	if ($m->{'phone'}) {
		return (defined $address->{'phone'} && $address->{'phone'} eq $m->{'phone'}) ? 1 : 0;
	}
	if ($m->{'email'}) {
		return (defined $address->{'email'} && lc $address->{'email'} eq lc $m->{'email'}) ? 1 : 0;
	}
	my $contact = $m->{'mail_contact'} || $m->{'contact'};
	if ($contact) {
		return 1 if defined $address->{'contact'} && $address->{'contact'} eq $contact;
		return 1 if defined $address->{'ticket'} && $address->{'ticket'} eq $contact;
		return 0;
	}
	return 0 unless $address->{'picker'} && $constructs;
	foreach my $k ( keys %{$constructs} ) {
		my $watched = $address->{'picker'}->{$k};
		return 0 unless defined $watched && $watched eq $constructs->{$k};
	}
	return 1;
}

sub mailws_sender($m) {
	my $constructs = &mailws_message_constructs($m);
	my $pmsg = encode_json $m;
	# Mojo encodes a plain string to UTF-8 when it builds a text frame, so the
	# JSON bytes above would be encoded a second time and an emoji would land in
	# the browser as mojibake. Send characters, encoded once.
	my $wire = $pmsg;
	utf8::decode($wire) if !utf8::is_utf8($wire);
	my $sent = 0;
	foreach my $bti ( keys %{$gb::mailws} ) {
		my $entry = $gb::mailws->{$bti};
		next unless $entry && $entry->{'tx'};
		next unless &mailws_address_matches($entry->{'address'}, $m, $constructs);
		my $ok = eval { $entry->{'tx'}->send($wire); 1 };
		unless ($ok) {
			warn "Worker $$: mail send failed for $bti: $@";
			delete $gb::mailws->{$bti};
			next;
		}
		$sent++;
	}
	return $sent;
}

1;
