#!/usr/bin/perl
#
# JawnOS first-run setup wizard.
#
#   perl scripts/jawnos_setup.pl [--port 3210] [--no-browser]
#   perl scripts/jawnos_setup.pl --seed [--name NAME] [--email EMAIL]
#         [--domain DOMAIN] [--archive-dir PATH] [--device computer|server|mobile]
#         [--language en|zh|fr|...] [--code NNNN]
#
# --seed does the same work with no browser and no prompts: it writes config.json
# and builds the database from the factory seed, printing the unlock code. That is
# what a container or an appliance calls on first boot. Answers come from the
# options above or from JAWNOS_NAME, JAWNOS_EMAIL, JAWNOS_DOMAIN,
# JAWNOS_ARCHIVE_DIR, JAWNOS_DEVICE, JAWNOS_LANGUAGE and JAWNOS_UNLOCK_CODE;
# anything left out takes the same default the wizard would.
#
# A small web app that walks a new user through:
#   1. dependency status
#   2. writing config.json
#   3. creating a brand-new, encrypted database (mirrors /manager/configure/new_database)
#
# It exits 0 once setup is finished, at which point the `jawn` launcher carries on
# and boots the normal server.

use strict;
use warnings;
use FindBin qw($Bin);
use Mojolicious::Lite;
use Mojo::IOLoop;
use Mojo::JSON qw(decode_json encode_json);
use JSON::PP ();
use Mojo::SQLite;
use File::Slurp qw(read_file write_file);
use File::Path qw(make_path);
use Crypt::Simple;
use Digest::MD5 qw(md5_hex);
use Getopt::Long qw(GetOptions);
use Cwd ();

# run from the repo root (the parent of scripts/)
my $root = Cwd::abs_path("$Bin/..");
chdir $root or die "cannot chdir to $root: $!";
require "./language.pl";

my $port       = 3210;
my $no_browser = 0;
no warnings 'once';
my $splitter   = $gb::universal_splitter || "--simple--split--and--whatnot--";
use warnings 'once';

my $seed = 0;
my %seed_opt;
GetOptions(
	'port=i'        => \$port,
	'no-browser'    => \$no_browser,
	'seed'          => \$seed,
	'name=s'        => \$seed_opt{'name'},
	'email=s'       => \$seed_opt{'email'},
	'domain=s'      => \$seed_opt{'domain'},
	'archive-dir=s' => \$seed_opt{'archive_dir'},
	'device=s'      => \$seed_opt{'device'},
	'language=s'    => \$seed_opt{'language'},
	'code=s'        => \$seed_opt{'code'},
) or die "bad options\n";

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
sub jawn_home {
	my $p = shift;
	my $h = $ENV{'HOME'} || '';
	$p =~ s{^~}{$h};
	return $p;
}

sub randstr {
	my $len = shift || 20;
	my @c = ( 'A' .. 'Z', 'a' .. 'z', 0 .. 9 );
	my $s = '';
	$s .= $c[ int( rand(@c) ) ] for 1 .. $len;
	return $s;
}

sub encrypter {
	my ( $secret, $content ) = @_;
	local *encrypt;
	local *decrypt;
	Crypt::Simple->import( passphrase => $secret );
	return encrypt($content);
}

sub decrypter {
	my ( $secret, $content ) = @_;
	local *encrypt;
	local *decrypt;
	Crypt::Simple->import( passphrase => $secret );
	return decrypt($content);
}

# The factory seed database/initial.enc is sealed under this code (must match
# scripts/factory_seed.pl). It is not a secret - it guards an empty factory
# template - so it ships in the clear: provisioning opens the seed with it and
# re-seals the result under the user's own unlock code.
our $FACTORY_CODE = 'JAWNOS-FACTORY-SEED-v1';

sub config_exists { return -e './config.json'; }

sub read_config {
	return unless config_exists();
	my $json = read_file('./config.json');
	my $c = eval { decode_json $json };
	return ref $c eq 'HASH' ? $c : undef;
}

sub write_config {
	my $data = shift;
	write_file( './config.json', JSON::PP->new->canonical->pretty->utf8->encode($data) );
}

# a stable file the cookie-signing md5 is derived from
sub ensure_signatorial {
	my $given = shift || '';
	my $file = $given ne '' ? jawn_home($given) : jawn_home('~/.jawnos_signatorial');
	return $file if -e $file;
	my $dir = $file;
	$dir =~ s{/[^/]+$}{};
	eval { make_path($dir) } if $dir ne '' && !-d $dir;
	write_file( $file, randstr(64) . "\n" );
	return $file;
}

# a fresh machine's identity: generated once and persisted, never derived from
# the picture folder (so it is stable, and every container gets its own).
sub ensure_signatorial_id {
	my $file = jawn_home('~/.jawnos_signatorial_id');
	return $file if -e $file && -s $file;
	my $id = md5_hex( randstr(64) . time() . $$ );
	if (open my $fh, '>', $file) {
		chmod 0600, $file;
		print $fh $id, "\n";
		close $fh;
	}
	return $file;
}

sub default_search_engines {
	return [
		{ name => 'Google',     url => 'https://www.google.com/search?q=' },
		{ name => 'DuckDuckGo', url => 'https://duckduckgo.com/?q=' },
		{ name => 'Wikipedia',  url => 'https://en.wikipedia.org/wiki/' },
	];
}

# ---------------------------------------------------------------------------
# database creation (mirrors Manager.pl's /manager/configure/new_database)
# ---------------------------------------------------------------------------
sub make_database {
	my ( $cfg, $params ) = @_;
	my $code     = $params->{'code'};
	my $standard = $params->{'encryption_standard'} || 'aes-256-cbc';

	unless ( $code && $code =~ /^[0-9]{4,12}$/ ) {
		return { error => 'The unlock code must be 4-12 digits.' };
	}

	my $tmp = jawn_home('~/.president');
	make_path($tmp) unless -d $tmp;

	# one machine, one database: it lives in the install's database/ dir, its
	# sealed copy beside it in database/backups/. There is no start directory to
	# pick and no database to name.
	my $live_db  = "$root/database/jawnos.db";
	my $enc_file = "$root/database/backups/jawnos.enc";
	make_path("$root/database/backups") unless -d "$root/database/backups";
	my $working  = $tmp . '/setup_' . randstr(10) . '.db';
	unlink $working if -e $working;

	# the template: the factory seed when it is there and opens, else a fresh
	# database from the shipped schema. The seed carries the factory settings
	# (appearance and configuration defaults); the schema build carries the same
	# few defaults inserted below.
	my $seeded = 0;
	if ( -e 'database/initial.enc' ) {
		my $seed_standard = $standard;
		my $data = `tail database/initial.enc`;
		my ( undef, $app ) = split /\Q$splitter\E/, $data, 2;
		my $decoded = $app ? decrypter( $FACTORY_CODE, $app ) : '';
		$seed_standard = $decoded if $decoded && $decoded =~ /^[a-z0-9-]+$/i;
		`openssl enc -d -k "$FACTORY_CODE" -$seed_standard -pbkdf2 -in database/initial.enc -out $working 2>/dev/null`;
		$seeded = 1 if -s $working > 5000;
	}
	unless ($seeded) {
		unless ( -e 'database/schema.sql' ) {
			return { error => 'database/schema.sql is missing.' };
		}
		my $build = `sqlite3 $working < database/schema.sql 2>&1`;
		if ( $? != 0 || !-e $working ) {
			return { error => "Could not build the database: $build" };
		}
	}

	my $sql = Mojo::SQLite->new('sqlite:' . $working);
	my $db  = $sql->db;
	$db->query('PRAGMA journal_mode=WAL');
	$db->query('PRAGMA synchronous=NORMAL');

	# the unlock code is this machine's key canary: replace whatever the seed or
	# the schema carried
	my $now = time() * 1000;
	my $level_one = $db->query('select uuid from security where level = 1')->hash;
	if ($level_one) {
		$db->update( 'security', {
			credential  => encrypter( $code, $code ),
			database    => $live_db,
			server_time => $now,
		}, { uuid => $level_one->{'uuid'} } );
	}
	else {
		$db->insert( 'security', {
			level       => 1,
			database    => $live_db,
			timestamp   => $now,
			server_time => $now,
			credential  => encrypter( $code, $code ),
			uuid        => randstr(30),
		} );
	}

	# a schema build starts with no settings; the seed already carries them
	unless ($seeded) {
		foreach my $s (
			[ 'misc', 'encryption_standard', $standard ],
			[ 'me',   'name',                $cfg->{'name'} || 'Me' ],
			[ 'me',   'warranty',            '-10d' ],
			[ 'me',   'currency',            'CAD' ],
			[ 'me',   'worth',               '0' ],
		) {
			$db->insert( 'settings', {
				app         => $s->[0],
				setting     => $s->[1],
				value       => $s->[2],
				timestamp   => $now,
				server_time => $now,
				device      => $cfg->{'device'} || 'computer',
				uuid        => randstr(20),
			} );
		}
	}

	# keep only this machine's kind: the seed carries the palette and settings for
	# every kind of machine, and setting_grabber reads the row for this device
	# only - the others are dead weight a configure panel would otherwise show
	my $this_device = $cfg->{'device'} || 'computer';
	$db->query( 'delete from settings where device is not null and device <> ?', $this_device );

	# the interface language chosen at install. It is a house-wide setting, so the
	# row carries device 'all' and every machine and device tab reads it.
	my $language = &language::valid( $cfg->{'language'} );
	$db->query( 'delete from settings where app = ? and setting = ?', 'misc', 'language' );
	$db->insert( 'settings', {
		app         => 'misc',
		setting     => 'language',
		value       => $language,
		timestamp   => $now,
		server_time => $now,
		device      => 'all',
		uuid        => randstr(20),
	} );

	$db->query('PRAGMA wal_checkpoint(TRUNCATE)');
	undef $db;
	undef $sql;

	# the live database is written straight out - no gate pick-a-database step -
	# and a copy is sealed beside it exactly the way the app expects
	`cp -f $working $live_db`;
	my $temp_backup = $working . '.1.db';
	`sqlite3 $working ".backup '$temp_backup'"`;
	`openssl enc -e -k "$code" -$standard -pbkdf2 -in $temp_backup -out $enc_file`;
	unless ( -e $enc_file && -s $enc_file > 100 ) {
		return { error => 'openssl failed to encrypt the database.' };
	}
	my $appendage = $splitter . encrypter( $code, $standard );
	if ( open my $fh, '>>', $enc_file ) {
		binmode $fh;
		print $fh $appendage;
		close $fh;
	}

	`shred -u $working $temp_backup $working-wal $working-shm 2>/dev/null`;
	`rm -f $working-wal $working-shm $temp_backup`;

	return { ok => 1, enc_file => $enc_file, database => $live_db, code => $code, seeded => $seeded };
}

# ---------------------------------------------------------------------------
# the one config + database step, shared by the wizard and --seed
# ---------------------------------------------------------------------------
sub build_config {
	my ( $in, $existing ) = @_;
	$in       ||= {};
	$existing ||= {};

	my $sig = ensure_signatorial( $in->{'signatorial'} );

	my $cfg = {
		%$existing,
		name           => $in->{'name'} || 'Laptop',
		language       => &language::valid( $in->{'language'} || $existing->{'language'} ),
		birthday       => $in->{'birthday'} || 'Jan. 1 2000 12pm',
		device         => $in->{'device'} || 'computer',
		domain         => $in->{'domain'} || '127.0.0.1',
		email          => $in->{'email'} || 'me@email.com',
		environment    => $in->{'environment'} || 'production',
		logfile        => $existing->{'logfile'} || '~/manager.log',
		port           => $in->{'port'} || '3000',
		working_port   => $existing->{'working_port'} || '45545',
		ws_port        => $existing->{'ws_port'} || '3001',
		ssh_port       => $existing->{'ssh_port'} || '8022',
		open_browser   => $existing->{'open_browser'} || 'yes',
		signatorial    => $sig,
		folders        => $in->{'folders'} || [ '~/Music', '~/Downloads', '~/Videos', '~/Pictures', '~/Documents' ],
		scanners       => $existing->{'scanners'} || [],
		search_engines => $existing->{'search_engines'} || default_search_engines(),
	};

	# start_dir is gone from the database's life: the one database lives in the
	# install's database/ dir, so the key is never written and a stale one from an
	# older config.json is dropped.
	delete $cfg->{'start_dir'};

	# archive_dir is a misc setting the panel owns, but a fresh seed wants it too:
	# on an appliance the second drive is mounted and named here once.
	$cfg->{'archive_dir'} = '' unless defined $cfg->{'archive_dir'};
	$cfg->{'archive_dir'} = $in->{'archive_dir'} if defined $in->{'archive_dir'};

	return ( $cfg, $sig );
}

sub run_setup {
	my $in = shift || {};
	my $existing = read_config() || {};
	&ensure_signatorial_id();
	my ( $cfg, $sig ) = build_config( $in, $existing );

	write_config($cfg);

	# zero touch: build the machine's one database now, from the factory seed, so
	# the first boot only asks for the code below. An install that already has its
	# database is left alone (re-running --setup only re-writes config.json).
	my $code;
	my $created = 0;
	unless ( -e "$root/database/jawnos.db" ) {
		$code = ( defined $in->{'code'} && $in->{'code'} =~ /^[0-9]{4,12}$/ )
			? $in->{'code'}
			: sprintf( '%08d', int( rand(100000000) ) );
		my $made = make_database( $cfg, { code => $code } );
		unless ( $made->{'ok'} ) {
			return { ok => 0, error => $made->{'error'} || 'could not build the database' };
		}
		$created = 1;
	}

	return { ok => 1, config => $cfg, signatorial => $sig, code => $code, created => $created };
}

# ---------------------------------------------------------------------------
# wizard HTML
# ---------------------------------------------------------------------------
sub WIZARD_HTML {
	no warnings 'once';
	my $current_language = &language::valid( ( read_config() || {} )->{'language'} );
	my $language_options = join '', map {
		'<option value="' . $_->{'code'} . '"' . ( $_->{'code'} eq $current_language ? ' selected' : '' ) . '>' . $_->{'native'} . ' &mdash; ' . $_->{'name'} . '</option>'
	} @language::languages;
	my $html = <<'HTML';
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>JawnOS setup</title>
<style>
	body { font-family: system-ui, sans-serif; margin: 0; background: #101418; color: #e8eaed; }
	.wrap { max-width: 780px; margin: 0 auto; padding: 28px 20px 80px; }
	h1 small { color: #8ab4f8; font-weight: 400; }
	.step { border: 1px solid #2a3038; border-radius: 12px; padding: 18px; margin: 16px 0; background: #171c22; }
	.step.locked { opacity: .45; pointer-events: none; }
	.step h2 { margin: 0 0 12px; font-size: 18px; }
	label { display: block; margin: 10px 0 4px; font-size: 14px; color: #b8c0cc; }
	input, select, textarea { width: 100%; box-sizing: border-box; padding: 9px; border-radius: 8px; border: 1px solid #39414c; background: #0e1317; color: #e8eaed; font-size: 15px; }
	textarea { height: 90px; }
	.row { display: flex; gap: 12px; flex-wrap: wrap; }
	.row > div { flex: 1 1 200px; }
	button { padding: 10px 18px; border-radius: 8px; border: 0; background: #8ab4f8; color: #101418; font-size: 15px; font-weight: 600; cursor: pointer; }
	button.ghost { background: transparent; border: 1px solid #39414c; color: #e8eaed; }
	table { width: 100%; border-collapse: collapse; font-size: 14px; }
	td { padding: 4px 6px; border-bottom: 1px solid #232a31; }
	.ok { color: #6ee7a8; }
	.bad { color: #ff8a80; }
	.code { font-size: 32px; letter-spacing: 8px; font-weight: 700; color: #8ab4f8; }
	.note { color: #b8c0cc; font-size: 14px; }
	.msg { margin-top: 10px; font-size: 14px; }
	pre.install { background: #0e1317; border: 1px solid #39414c; border-radius: 8px; padding: 12px; overflow: auto; max-height: 220px; font-size: 13px; white-space: pre; }
</style>
</head>
<body>
<div class="wrap">
	<h1>JawnOS <small>setup</small></h1>
	<p class="note">This wizard checks your dependencies, writes <code>config.json</code> and builds you a brand-new encrypted database.</p>

	<div class="step" id="step-deps">
		<h2>1. Dependencies</h2>
		<div id="deps-body">checking&hellip;</div>
		<button class="ghost" onclick="loadDeps()">Re-check</button>
	</div>

	<div class="step locked" id="step-config">
		<h2>2. Configuration &mdash; <code>config.json</code></h2>
		<div class="row">
			<div><label>Computer name</label><input id="cfg_name" value="Laptop"></div>
			<div><label>Device</label>
				<select id="cfg_device">
					<option value="computer">computer</option>
					<option value="mobile">mobile</option>
					<option value="server">server</option>
				</select>
			</div>
		</div>
		<div class="row">
			<div><label>Email</label><input id="cfg_email" value="me@email.com"></div>
			<div><label>Domain / host</label><input id="cfg_domain" value="127.0.0.1"></div>
		</div>
		<div class="row">
			<div><label>Language (you can change it later in Configure &rarr; Misc)</label>
				<select id="cfg_language">__LANGUAGE_OPTIONS__</select>
			</div>
		</div>
		<div class="row">
			<div><label>HTTP port</label><input id="cfg_port" value="3000"></div>
		</div>
		<label>Signatorial file (any file that won't change; encrypts cookies &mdash; leave blank to generate one)</label>
		<input id="cfg_signatorial" value="">
		<label>Media folders (one per line)</label>
		<textarea id="cfg_folders">~/Music
~/Downloads
~/Videos
~/Pictures
~/Documents</textarea>
		<div class="msg" id="config-msg"></div>
		<br><button onclick="saveConfig()">Save configuration</button>
	</div>

	<div class="step locked" id="step-finish">
		<h2>3. Finish</h2>
		<p class="note">Your install is built and ready &mdash; there is nothing else to configure, and no database to pick or move. This is your unlock code:</p>
		<div class="code" id="db-code-out"></div>
		<p class="note">Write it down &mdash; you'll enter it at the gate login screen to unlock JawnOS.</p>
		<button onclick="finish()">Start JawnOS</button>
	</div>
</div>
<script>
function unlock(id) { document.getElementById(id).classList.remove('locked'); }
function val(id) { return document.getElementById(id).value; }

function installScript() {
	var pre = document.getElementById('install-script');
	return pre ? pre.textContent : '';
}

function installMsg(text) {
	var m = document.getElementById('install-msg');
	if (!m) { return; }
	m.textContent = text;
	setTimeout(function () { m.textContent = ''; }, 2000);
}

function copyInstall() {
	var text = installScript();
	if (navigator.clipboard && navigator.clipboard.writeText) {
		navigator.clipboard.writeText(text).then(function () { installMsg('Copied'); }, function () { installMsg('Copy failed'); });
	} else {
		installMsg('Copy not supported');
	}
}

function downloadInstall() {
	var blob = new Blob([installScript()], { type: 'text/x-shellscript' });
	var a = document.createElement('a');
	a.href = URL.createObjectURL(blob);
	a.download = 'jawnos-deps.sh';
	document.body.appendChild(a);
	a.click();
	document.body.removeChild(a);
	URL.revokeObjectURL(a.href);
}

async function loadDeps() {
	var body = document.getElementById('deps-body');
	body.innerHTML = 'checking&hellip;';
	try {
		var d = await (await fetch('api/deps')).json();
		if (d.error) { body.innerHTML = '<span class="bad">' + d.error + '</span>'; return; }
		var html = '<table>';
		(d.missing_tools || []).forEach(function (t) {
			html += '<tr><td class="bad">&#10007;</td><td>' + t.label + '</td><td>' + (t.package || '') + '</td></tr>';
		});
		(d.missing_modules || []).forEach(function (m) {
			html += '<tr><td class="bad">&#10007;</td><td colspan="2">' + m + '</td></tr>';
		});
		if (d.ok) { html += '<tr><td class="ok">&#10003;</td><td colspan="2">All dependencies present</td></tr>'; }
		html += '</table>';
		if (!d.ok) {
			html += '<p class="note">Run this to install what is missing, then hit Re-check:</p>';
			html += '<pre id="install-script" class="install"></pre>';
			html += '<div class="row" style="margin-top:8px;">';
			html += '<div><button onclick="copyInstall()">Copy</button> <button class="ghost" onclick="downloadInstall()">Download .sh</button> <span id="install-msg" class="note"></span></div>';
			html += '</div>';
			html += '<p class="note">Or stop this wizard (Ctrl+C in the terminal) and run <code>perl scripts/jawnos_deps.pl</code>.</p>';
		} else { unlock('step-config'); }
		body.innerHTML = html;
		if (!d.ok) {
			var pre = document.getElementById('install-script');
			if (pre) { pre.textContent = d.install_script || '(no commands generated -- install by hand, see the README)'; }
		}
	} catch (e) { body.innerHTML = '<span class="bad">' + e + '</span>'; }
}

async function post(url, data) {
	var r = await fetch(url, { method: 'POST', headers: {'Content-Type':'application/x-www-form-urlencoded'}, body: 'data=' + encodeURIComponent(JSON.stringify(data)) });
	return await r.json();
}

async function saveConfig() {
	var data = {
		name: val('cfg_name'), device: val('cfg_device'), email: val('cfg_email'),
		language: val('cfg_language'),
		domain: val('cfg_domain'), port: val('cfg_port'),
		signatorial: val('cfg_signatorial'),
		folders: val('cfg_folders').split('\n').map(function(s){return s.trim();}).filter(Boolean)
	};
	var m = document.getElementById('config-msg');
	m.innerHTML = 'building your install&hellip;';
	var res = await post('api/config', data);
	if (res.ok) {
		m.innerHTML = '<span class="ok">Saved.</span>';
		document.getElementById('db-code-out').textContent = res.code || '(existing install) ';
		unlock('step-finish');
	} else { m.innerHTML = '<span class="bad">' + (res.error || 'failed') + '</span>'; }
}

async function finish() {
	await post('api/finish', {});
	document.body.innerHTML = '<div class="wrap"><h1>All set.</h1><p>JawnOS is starting&hellip;</p></div>';
}

loadDeps();
</script>
</body>
</html>
HTML
	$html =~ s/__LANGUAGE_OPTIONS__/$language_options/;
	return $html;
}

# ---------------------------------------------------------------------------
# routes
# ---------------------------------------------------------------------------
get '/'       => sub { shift->render( data => WIZARD_HTML(), format => 'html' ) };
get '/wizard' => sub { shift->render( data => WIZARD_HTML(), format => 'html' ) };

get '/api/state' => sub {
	my $c = shift;
	$c->render( json => { config_exists => config_exists() ? 1 : 0, config => read_config() || {} } );
};

get '/api/deps' => sub {
	my $c = shift;
	my $out = `perl scripts/jawnos_deps.pl --json 2>/dev/null`;
	my $data = eval { decode_json $out };
	if ( ref $data ne 'HASH' ) {
		$data = { ok => 0, error => 'could not run the dependency check' };
	}
	elsif ( !$data->{'ok'} ) {
		$data->{'install_script'} = `perl scripts/jawnos_deps.pl --sh 2>/dev/null`;
	}
	$c->render( json => $data );
};

post '/api/config' => sub {
	my $c = shift;
	my $in = eval { decode_json $c->param('data') } || {};
	my $res = run_setup($in);
	unless ( $res->{'ok'} ) {
		return $c->render( json => { ok => 0, error => $res->{'error'} || 'could not build the database' } );
	}
	$c->render( json => { ok => 1, config => $res->{'config'}, signatorial => $res->{'signatorial'}, code => $res->{'code'} } );
};

post '/api/database' => sub {
	my $c = shift;
	my $cfg = read_config();
	return $c->render( json => { error => 'config.json does not exist yet.' } ) unless $cfg;
	my $in  = eval { decode_json $c->param('data') } || {};
	my $res = make_database( $cfg, $in );
	$c->render( json => $res );
};

post '/api/finish' => sub {
	my $c = shift;
	$c->render( json => { ok => 1 } );
	Mojo::IOLoop->timer( 0.5 => sub { exit 0 } );
};

# ---------------------------------------------------------------------------
# non-interactive seed (containers, appliances, unattended installs)
# ---------------------------------------------------------------------------
if ($seed) {
	my $in = {
		name        => $seed_opt{'name'}        || $ENV{'JAWNOS_NAME'},
		email       => $seed_opt{'email'}       || $ENV{'JAWNOS_EMAIL'},
		domain      => $seed_opt{'domain'}      || $ENV{'JAWNOS_DOMAIN'},
		language    => $seed_opt{'language'}    || $ENV{'JAWNOS_LANGUAGE'},
		archive_dir => $seed_opt{'archive_dir'} || $ENV{'JAWNOS_ARCHIVE_DIR'},
		device      => $seed_opt{'device'}      || $ENV{'JAWNOS_DEVICE'},
		code        => $seed_opt{'code'}        || $ENV{'JAWNOS_UNLOCK_CODE'},
	};

	my $res = run_setup($in);
	if ( !$res->{'ok'} ) {
		print STDERR "jawnos_setup: $res->{'error'}\n";
		exit 1;
	}

	print "\n";
	print "JawnOS seeded non-interactively.\n\n";
	print "  config        $root/config.json\n";
	print "  database      $root/database/jawnos.db\n";
	print "  signatorial   " . ( $res->{'config'}->{'signatorial'} || '' ) . "\n";
	if ( $res->{'created'} ) {
		print "  unlock code   $res->{'code'}\n";
		print "\n  The unlock code is the only key to the database. It is not\n";
		print "  stored anywhere else - save it now.\n";
	}
	else {
		print "  database      already present, left untouched\n";
	}
	print "\n";
	print "JAWNOS_CONFIG=$root/config.json\n";
	print "JAWNOS_DATABASE=$root/database/jawnos.db\n";
	print "JAWNOS_UNLOCK_CODE=$res->{'code'}\n" if $res->{'created'};
	exit 0;
}

# ---------------------------------------------------------------------------
# start
# ---------------------------------------------------------------------------
my $url = "http://127.0.0.1:$port/wizard";
print "\n";
print "========================================\n";
print " JawnOS setup wizard\n";
print " $url\n";
print "========================================\n\n";

unless ($no_browser) {
	if ( $ENV{'TERMUX_VERSION'} || -d '/data/data/com.termux' ) {
		system("termux-open $url >/dev/null 2>&1 &");
	}
	elsif ( -x '/usr/bin/xdg-open' ) {
		system("xdg-open $url >/dev/null 2>&1 &");
	}
}

@ARGV = ( 'daemon', '-l', "http://127.0.0.1:$port" );
app->start;
