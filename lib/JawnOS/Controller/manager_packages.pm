package Manager;

# manager_packages: the Packages app - what software this machine runs and the
# five changes it may make to it.
#
# The reads answer JSON and the page; the writes (refresh the index, upgrade,
# install, remove, install a file) each require an approved house session, a
# guest browser is refused, and every write also needs confirm=1. The domain
# layer (JawnOS::Domain::Packages) builds argv lists, takes the one operation
# lock, uses sudo -n and logs each command; this file only decides who may ask.
use strict;
use warnings;
use utf8;

use File::Spec ();

# A session that may see the machine's software at all. An approved login on
# this house is required; a guest ticket, even a peer's, is not enough for a
# page that can remove a kernel.
sub packages_house_session {
	my ($c) = @_;
	return 0 unless ($c->session('authentication') || '') eq 'approved';
	return 0 if &subs::guest_browser_session($c->session('privilege'), $c->session('source'));
	return 1;
}

sub packages_refusal {
	my ($c, $label, $status, $error) = @_;
	&subs::log_writer('packages: refused ' . $label);
	$c->render(json => { ok => 0, refused => 1, error => $error }, status => $status);
	return 0;
}

sub packages_reading_gate {
	my ($c, $label) = @_;
	$label ||= 'read';
	return 1 if &packages_house_session($c);
	return &packages_refusal($c, $label, 403,
		&subs::ui('Only an approved session on this machine may manage packages.'));
}

sub packages_write_gate {
	my ($c, $label) = @_;
	$label ||= 'a change';
	return 0 unless &packages_reading_gate($c, $label);
	return 1 if ($c->param('confirm') || '') eq '1';
	return &packages_refusal($c, $label, 400,
		&subs::ui('This change was not confirmed.'));
}

sub packages_action_log {
	my ($c, $label) = @_;
	my $who = $c->session('person_uuid') || $c->session('signatorial') || 'the house';
	&subs::log_writer('packages: ' . $label . ' by ' . $who);
	return;
}

# GET /manager/packages
sub action_54020 {
	my $c = shift;
	return unless &packages_reading_gate($c, 'open');
	&packages_action_log($c, 'open');
	my $status = eval { &subs::packages_status() } || { ok => 0, error => 'the package status could not be read' };
	my $contents = $c->render_to_string(
		template => 'apps/packages',
		status   => $status,
	);
	my $window = &window_maker({
		user_agent => $c->param('user_agent'),
		app        => 'packages',
		contents   => $contents,
	}, $c->param('timestamp'));
	$c->render(json => { window => $window });
}

# GET /manager/packages/status
sub action_54021 {
	my $c = shift;
	return unless &packages_reading_gate($c, 'status');
	&packages_action_log($c, 'status');
	$c->render(json => eval { &subs::packages_status() }
		|| { ok => 0, error => 'the package status could not be read' });
}

# GET /manager/packages/list
sub action_54022 {
	my $c = shift;
	return unless &packages_reading_gate($c, 'list');
	&packages_action_log($c, 'list');
	$c->render(json => eval { &subs::packages_list({ backend => $c->param('backend') }) }
		|| { ok => 0, error => 'the installed packages could not be listed' });
}

# GET /manager/packages/outdated
sub action_54023 {
	my $c = shift;
	return unless &packages_reading_gate($c, 'outdated');
	&packages_action_log($c, 'outdated');
	$c->render(json => eval { &subs::packages_outdated({ backend => $c->param('backend') }) }
		|| { ok => 0, error => 'the outdated packages could not be listed' });
}

# GET /manager/packages/search?term=...
sub action_54024 {
	my $c = shift;
	return unless &packages_reading_gate($c, 'search');
	&packages_action_log($c, 'search');
	$c->render(json => eval { &subs::packages_search($c->param('term'), { backend => $c->param('backend') }) }
		|| { ok => 0, error => 'the search failed' });
}

# POST /manager/packages/update
sub action_54025 {
	my $c = shift;
	return unless &packages_write_gate($c, 'update');
	&packages_action_log($c, 'update');
	$c->render(json => eval { &subs::packages_update({ backend => $c->param('backend') }) }
		|| { ok => 0, error => 'the package index could not be refreshed' });
}

# POST /manager/packages/upgrade
sub action_54026 {
	my $c = shift;
	return unless &packages_write_gate($c, 'upgrade');
	&packages_action_log($c, 'upgrade');
	$c->render(json => eval { &subs::packages_upgrade({ backend => $c->param('backend') }) }
		|| { ok => 0, error => 'the upgrade did not run' });
}

# POST /manager/packages/install
sub action_54027 {
	my $c = shift;
	return unless &packages_write_gate($c, 'install');
	my $name = $c->param('name');
	&packages_action_log($c, 'install ' . (defined $name ? $name : ''));
	$c->render(json => eval { &subs::packages_install($name, { backend => $c->param('backend') }) }
		|| { ok => 0, error => 'the install did not run' });
}

# POST /manager/packages/remove
sub action_54028 {
	my $c = shift;
	return unless &packages_write_gate($c, 'remove');
	my $name = $c->param('name');
	&packages_action_log($c, 'remove ' . (defined $name ? $name : ''));
	$c->render(json => eval { &subs::packages_remove($name, { backend => $c->param('backend') }) }
		|| { ok => 0, error => 'the removal did not run' });
}

# POST /manager/packages/purge
#
# Remove keeps the package's configuration. Purge is the separate promise: the
# package and the files it left behind. It takes the same lock and confirm gate
# as every other write, and is logged under its own name.
sub action_54030 {
	my $c = shift;
	return unless &packages_write_gate($c, 'purge');
	my $name = $c->param('name');
	&packages_action_log($c, 'purge ' . (defined $name ? $name : ''));
	$c->render(json => eval { &subs::packages_purge($name, { backend => $c->param('backend') }) }
		|| { ok => 0, error => 'the purge did not run' });
}

# POST /manager/packages/file (multipart upload)
#
# The upload is saved into the app's own directory and the domain checks the
# path still resolves inside it before any argv is built. The file is removed
# once the install has stopped, whether it worked or not.
sub action_54029 {
	my $c = shift;
	return unless &packages_write_gate($c, 'install from file');
	my $upload = $c->req->uploads->[0];
	unless ($upload) {
		return $c->render(json => { ok => 0, error => &subs::ui('Choose a package file to install.') }, status => 400);
	}
	my $dir = eval { &subs::packages_upload_dir() };
	unless (defined $dir && -d $dir) {
		return $c->render(json => { ok => 0, error => &subs::ui('The upload directory is not available.') }, status => 500);
	}
	my $name = &subs::path_name($upload->filename || '');
	$name = 'upload' unless defined $name && length $name;
	$name .= '.deb' unless $name =~ /\.(?:deb|pkg\.tar\.(?:zst|xz|gz|bz2))$/i;
	my $path = File::Spec->catfile($dir, &subs::random_string_creator(8) . '-' . $name);
	unless (eval { $upload->move_to($path); 1 }) {
		return $c->render(json => { ok => 0, error => &subs::ui('The uploaded file could not be saved.') }, status => 500);
	}
	&packages_action_log($c, 'install from file ' . $name);
	my $answer = eval { &subs::packages_install_file($path) }
		|| { ok => 0, error => 'the file install did not run' };
	unlink $path;
	return $c->render(json => $answer);
}

1;
