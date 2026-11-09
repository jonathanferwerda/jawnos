package JawnOS::Routes;

use strict;
use warnings;

# Every route, in the order it was declared. Modules are loaded here so a new
# route group only has to appear in @NAMES; matching order is by the line the
# route had in Manager.pl, so first-match-wins behaves as it always did.
our @NAMES = qw(Root_misc apps_misc box_office_misc crest_misc download_program_misc embedded_misc file_open_misc gate_misc i18n_misc js_misc mail_misc mail_ws manager_box_office manager_budget manager_budget2 manager_clock manager_configure manager_configure2 manager_configure3 manager_configure4 manager_configure5 manager_crypto manager_device manager_embedded manager_folders manager_folders2 manager_gallery manager_help manager_mail manager_mail2 manager_market manager_market2 manager_misc manager_misc2 manager_misc3 manager_misc4 manager_misc5 manager_misc6 manager_misc7 manager_misc8 manager_misc9 manager_misc10 manager_misc11 manager_misc12 manager_misc13 manager_misc14 manager_people manager_people2 manager_phone manager_power manager_relational manager_sco manager_sound manager_security manager_security2 manager_security3 manager_store manager_store2 manager_transaction manager_transaction2 manager_travel manager_watch manager_weather manager_ws manifest_json_misc mugshot_misc observer_misc passkey_misc pay_misc privacy_misc public_view_misc sesh_check store_misc teletype_misc watch_misc);

sub register {
	my ($class, $app, $r) = @_;
	my @all;
	for my $name (@NAMES) {
		require "JawnOS/Routes/$name.pm";
		require "JawnOS/Controller/$name.pm";
		push @all, "JawnOS::Routes::$name"->routes;
	}
	for my $e (sort { $a->[0] <=> $b->[0] } @all) {
		my ($idx, $method, $path, $action) = @$e;
		$r->$method($path)->to(controller => 'Manager', action => $action);
	}
	return $r;
}

1;
