#!/usr/bin/perl
#
# JawnOS first-run setup wizard.
#
#   perl scripts/jawnos_setup.pl [--port 3210] [--no-browser]
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
use Getopt::Long qw(GetOptions);

# run from the repo root (the parent of scripts/)
my $root = "$Bin/..";
chdir $root or die "cannot chdir to $root: $!";

my $port       = 3210;
my $no_browser = 0;
no warnings 'once';
my $splitter   = $gb::universal_splitter || "--simple--split--and--whatnot--";
use warnings 'once';

GetOptions( 'port=i' => \$port, 'no-browser' => \$no_browser ) or die "bad options\n";

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
	my $name     = $params->{'name'} || 'initial';
	my $code     = $params->{'code'};
	my $standard = $params->{'encryption_standard'} || 'aes-256-ctr';
	my $start    = jawn_home( $cfg->{'start_dir'} || '~/' );
	$start =~ s{/?$}{/};

	unless ( $code && $code =~ /^[0-9]{4,12}$/ ) {
		return { error => 'The unlock code must be 4-12 digits.' };
	}
	unless ( -e 'database/schema.sql' ) {
		return { error => 'database/schema.sql is missing.' };
	}
	unless ( -d $start ) {
		return { error => "The start directory does not exist: $start" };
	}

	my $tmp = jawn_home('~/.president');
	make_path($tmp) unless -d $tmp;

	my $live_db  = $start . $name . '.db';
	my $enc_file = $start . $name . '.enc';
	my $working  = $tmp . '/setup_' . randstr(10) . '.db';

	# fresh database from the shipped schema
	unlink $working if -e $working;
	my $build = `sqlite3 $working < database/schema.sql 2>&1`;
	if ( $? != 0 || !-e $working ) {
		return { error => "Could not build the database: $build" };
	}

	my $sql = Mojo::SQLite->new('sqlite:' . $working);
	my $db  = $sql->db;
	$db->query('PRAGMA journal_mode=WAL');
	$db->query('PRAGMA synchronous=NORMAL');

	my $now = time() * 1000;
	$db->insert( 'security', {
		level       => 1,
		database    => $live_db,
		timestamp   => $now,
		server_time => $now,
		credential  => encrypter( $code, $code ),
		uuid        => randstr(30),
	} );

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

	$db->query('PRAGMA wal_checkpoint(TRUNCATE)');
	undef $db;
	undef $sql;

	# encrypt exactly the way the app expects
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

	return { ok => 1, enc_file => $enc_file, database => $live_db, code => $code };
}

# ---------------------------------------------------------------------------
# wizard HTML
# ---------------------------------------------------------------------------
sub WIZARD_HTML {
	return <<'HTML';
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
			<div><label>Start directory (database + files live here)</label><input id="cfg_start_dir" value="~/"></div>
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

	<div class="step locked" id="step-db">
		<h2>3. Database</h2>
		<p class="note">A fresh database is created from the shipped schema and encrypted with a numeric code you choose. You'll type that code at the gate to unlock JawnOS.</p>
		<div class="row">
			<div><label>Database name</label><input id="db_name" value="initial"></div>
			<div><label>Unlock code (4-12 digits)</label><input id="db_code" inputmode="numeric" pattern="[0-9]*" value=""></div>
		</div>
		<p class="note">Leave the code blank to auto-generate one.</p>
		<div class="msg" id="db-msg"></div>
		<br><button onclick="makeDatabase()">Create database</button>
		<div id="db-result" style="display:none;margin-top:16px;">
			<div class="note">Your unlock code is:</div>
			<div class="code" id="db-code-out"></div>
			<div class="note">Write it down &mdash; you'll enter it at the gate login screen.</div>
		</div>
	</div>

	<div class="step locked" id="step-finish">
		<h2>4. Finish</h2>
		<p class="note">When you're ready, start JawnOS. This wizard will close.</p>
		<button onclick="finish()">Start JawnOS</button>
	</div>
</div>
<script>
function unlock(id) { document.getElementById(id).classList.remove('locked'); }
function val(id) { return document.getElementById(id).value; }

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
			html += '<p class="note">To install what is missing, stop this wizard (Ctrl+C in the terminal) and run:<br><code>perl scripts/jawnos_deps.pl</code></p>';
		} else { unlock('step-config'); }
		body.innerHTML = html;
	} catch (e) { body.innerHTML = '<span class="bad">' + e + '</span>'; }
}

async function post(url, data) {
	var r = await fetch(url, { method: 'POST', headers: {'Content-Type':'application/x-www-form-urlencoded'}, body: 'data=' + encodeURIComponent(JSON.stringify(data)) });
	return await r.json();
}

async function saveConfig() {
	var data = {
		name: val('cfg_name'), device: val('cfg_device'), email: val('cfg_email'),
		domain: val('cfg_domain'), start_dir: val('cfg_start_dir'), port: val('cfg_port'),
		signatorial: val('cfg_signatorial'),
		folders: val('cfg_folders').split('\n').map(function(s){return s.trim();}).filter(Boolean)
	};
	var m = document.getElementById('config-msg');
	m.innerHTML = 'saving&hellip;';
	var res = await post('api/config', data);
	if (res.ok) {
		m.innerHTML = '<span class="ok">Saved. Signatorial: ' + res.signatorial + '</span>';
		unlock('step-db');
	} else { m.innerHTML = '<span class="bad">' + (res.error || 'failed') + '</span>'; }
}

async function makeDatabase() {
	var code = val('db_code');
	if (!code) { code = String(Math.floor(10000000 + Math.random() * 89999999)); }
	var m = document.getElementById('db-msg');
	m.innerHTML = 'building&hellip;';
	var res = await post('api/database', { name: val('db_name'), code: code });
	if (res.ok) {
		m.innerHTML = '<span class="ok">Created ' + res.enc_file + '</span>';
		document.getElementById('db-code-out').textContent = res.code;
		document.getElementById('db-result').style.display = 'block';
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
	my $data = eval { decode_json $out } || { ok => 0, error => 'could not run the dependency check' };
	$c->render( json => $data );
};

post '/api/config' => sub {
	my $c = shift;
	my $in = eval { decode_json $c->param('data') } || {};
	my $existing = read_config() || {};

	my $start_dir = $in->{'start_dir'} || '~/';
	$start_dir =~ s{/?$}{/};

	my $sig = ensure_signatorial( $in->{'signatorial'} );

	my $cfg = {
		%$existing,
		name           => $in->{'name'} || 'Laptop',
		birthday       => $in->{'birthday'} || 'Jan. 1 2000 12pm',
		device         => $in->{'device'} || 'computer',
		domain         => $in->{'domain'} || '127.0.0.1',
		email          => $in->{'email'} || 'me@email.com',
		environment    => $in->{'environment'} || 'production',
		start_dir      => $start_dir,
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

	write_config($cfg);
	$c->render( json => { ok => 1, config => $cfg, signatorial => $sig } );
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
