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
