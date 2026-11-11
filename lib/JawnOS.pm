package JawnOS;

# The application object: full Mojolicious, one class. The route actions live in
# lib/JawnOS/Controller (package Manager, a Mojolicious::Controller subclass),
# the bootstrap, helpers and package state in lib/JawnOS/Manager.pm, and the
# route table in lib/JawnOS/Routes.

use Mojo::Base 'Mojolicious';

# Response compression. A rendered app window is ~42 KB of HTML and gzips to
# ~10 KB; before this only the JS bundle compressed, so every dynamic text
# response is squeezed here instead of in each route.
my %GZIP_TYPE = map { $_ => 1 } qw(
	text/html text/plain text/css text/javascript
	application/javascript application/json image/svg+xml
);

sub gzip_type_ok {
	my ($type) = @_;
	return 0 unless defined $type && length $type;
	$type = lc $type;
	$type =~ s/;.*//s;
	$type =~ s/\s+//g;
	return $GZIP_TYPE{$type} ? 1 : 0;
}

# Accept-Encoding is a q-value list: `gzip;q=0` is a refusal, and a bare
# /\bgzip\b/ match would read it as consent.
sub gzip_accepted {
	my ($header) = @_;
	return 0 unless defined $header && length $header;
	my $wildcard;
	for my $entry (split /,/, $header) {
		$entry =~ s/^\s+//;
		$entry =~ s/\s+$//;
		next unless length $entry;
		my ($token) = split /;/, $entry, 2;
		$token = lc $token;
		$token =~ s/\s+$//;
		my $q = 1;
		$q = $1 + 0 if $entry =~ /(?:^|;)\s*q\s*=\s*([0-9.]+)/i;
		return $q > 0 ? 1 : 0 if $token eq 'gzip';
		$wildcard = $q if $token eq '*';
	}
	return defined $wildcard && $wildcard > 0 ? 1 : 0;
}

# Pure: decide and compress from the five response facts (plus the request
# method, which HEAD needs) so the rule is testable without booting the app.
# Returns the gzip bytes, or undef to leave the response untouched.
sub gzip_body_for {
	my ($accept_encoding, $status, $content_type, $existing_encoding, $body, $method) = @_;
	return undef unless defined $status && "$status" eq '200';
	$method = 'GET' unless defined $method && length $method;
	return undef if uc $method eq 'HEAD';
	return undef if defined $existing_encoding && length $existing_encoding;
	return undef unless gzip_accepted($accept_encoding);
	return undef unless gzip_type_ok($content_type);
	return undef if !defined $body || ref $body || length $body < 1024;
	my $bytes = $body;
	# Mojo puts a body's internal bytes on the wire, so wide text is encoded
	# the same way before it is compressed.
	utf8::encode($bytes) if utf8::is_utf8($bytes);
	my $out = '';
	my $ok = eval {
		require IO::Compress::Gzip;
		IO::Compress::Gzip::gzip(\$bytes => \$out);
	};
	return undef unless $ok && length $out;
	return $out;
}

# One Content-Security-Policy for the app's own HTML pages, installed by an
# after_dispatch hook in perl/hooks.pl. It is deliberately conservative rather
# than strict: `script-src` allows inline script and eval because the templates
# carry inline handlers and eval'd fragments, and every window would break
# under a nonce tomorrow. That honesty cuts both ways: 'unsafe-inline' also
# leaves an injected inline script executable, so this policy blocks exfil
# directions (object-src, base-uri, frame-ancestors) and external code, not
# inline XSS. The follow-up is a nonce/`strict-dynamic` migration, template by
# template, which is what would let 'unsafe-inline' go.
#
# The directives mirror the app's real needs: ws:/wss: for the manager socket,
# https: for peer machines, remote media and the saved-web pages, data:/blob:
# for generated images and recorded audio, and no object/embed at all.
sub content_security_policy {
	return join('; ',
		"default-src 'self'",
		"script-src 'self' 'unsafe-inline' 'unsafe-eval'",
		"style-src 'self' 'unsafe-inline'",
		"img-src 'self' data: blob: https:",
		"media-src 'self' data: blob: https:",
		"connect-src 'self' ws: wss: https:",
		"font-src 'self' data:",
		"frame-src 'self' https:",
		"object-src 'none'",
		"base-uri 'self'",
		"form-action 'self'",
		"frame-ancestors 'self'",
	);
}

# Pure: whether this response is one of the app's own HTML pages and so wants
# the policy. JSON, assets, PDFs and media do not. A route that set its own
# policy keeps it: the caller passes the header's current value. `/file_open`
# is skipped because rock_and_roll serves a file's raw bytes under the default
# text/html when it cannot name a better type, so that body is data, not a page.
sub csp_applies {
	my ($content_type, $path, $existing) = @_;
	return 0 if defined $existing && length $existing;
	return 0 unless defined $content_type && length $content_type;
	my $type = lc $content_type;
	$type =~ s/;.*//s;
	$type =~ s/\s+//g;
	return 0 unless $type eq 'text/html';
	return 0 if defined $path && $path eq '/file_open';
	return 1;
}

# Set the policy on a response's headers when it belongs there. The hook calls
# this and nothing else, so the rule can be exercised on a plain Mojo::Headers
# without starting the tree. Returns 1 when it set the header.
sub apply_csp {
	my ($headers, $path) = @_;
	return 0 unless $headers && $headers->can('content_type');
	return 0 unless csp_applies(
		$headers->content_type, $path, $headers->header('Content-Security-Policy')
	);
	$headers->header('Content-Security-Policy' => content_security_policy());
	return 1;
}

sub startup {
	my $self = shift;

	# Manager.pm is the old Manager.pl without its routes: config, state,
	# helpers, the schema hook and the session settings. It calls app() while it
	# loads (plugin, hook, app->sessions), so publish the app object first.
	$Manager::APP = $self;
	require 'JawnOS/Manager.pm';

	$self->plugin('RenderFile');

	# Manager is the controller class. Mojolicious resolves `controller => 'Manager'`
	# against a namespace, and a top-level package is stored in %main::, so the
	# controller named Manager is reached as main::Manager (same stash as Manager).
	my $r = $self->routes;
	$r->namespaces(['main']);

	# Lite used the caller as the template class and had no namespace prefix;
	# keep both so templates/apps/*.ep and public/ resolve exactly as before.
	$self->static->classes->[0]   = 'Manager';
	$self->renderer->classes->[0] = 'Manager';

	require JawnOS::Routes;
	JawnOS::Routes->register($self, $r);

	# The tree runs inside a PTY, and the prefork request workers are background
	# process groups there: the tree leader holds the terminal's foreground
	# group. A child that reads the inherited stdin - every interactive ffmpeg
	# does, even when it is only writing a thumbnail - raises SIGTTIN, and the
	# default action stops the whole worker group. The web port then goes silent
	# until the master restarts the tree, and the same request repeats after the
	# restart. Ignore the terminal job-control stops in the worker (the rest of
	# its request group inherits the disposition), the way a daemon does. The
	# prefork manager's own TTIN/TTOU autoscale handlers live in another process
	# and are not touched; the workers reset these to DEFAULT before this hook.
	$self->hook(before_dispatch => sub {
		$SIG{TTIN} = 'IGNORE';
		$SIG{TTOU} = 'IGNORE';
	});

	# after_dispatch sees the finished response exactly once, just before it is
	# written, which is the only place every route's HTML, JSON and CSS meets.
	$self->hook(after_dispatch => sub {
		my $c = shift;
		my $res = $c->res;
		my $headers = $res->headers;
		my $type = $headers->content_type;
		return unless gzip_type_ok($type);
		# $res->body would slurp a file asset; static media stays as it is.
		my $content = $res->content;
		my $asset = $content->isa('Mojo::Content::Single') ? $content->asset : undef;
		return unless $asset && $asset->isa('Mojo::Asset::Memory');
		my $gzipped = gzip_body_for(
			$c->req->headers->accept_encoding,
			$res->code, $type, $headers->content_encoding,
			$asset->slurp, $c->req->method,
		);
		return unless defined $gzipped;
		$headers->content_encoding('gzip');
		$headers->vary('Accept-Encoding');
		$headers->remove('Content-Length');
		$res->body($gzipped);
	});

	return $self;
}

1;
