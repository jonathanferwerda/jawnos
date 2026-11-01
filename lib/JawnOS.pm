package JawnOS;

# The application object: full Mojolicious, one class. The route actions live in
# lib/JawnOS/Controller (package Manager, a Mojolicious::Controller subclass),
# the bootstrap, helpers and package state in lib/JawnOS/Manager.pm, and the
# route table in lib/JawnOS/Routes.

use Mojo::Base 'Mojolicious';

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
	return $self;
}

1;
