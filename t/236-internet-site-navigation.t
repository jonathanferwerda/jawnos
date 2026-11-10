# tests-for: lib/JawnOS/Domain/Appointment.pm lib/JawnOS/Domain/Loader.pm desktop/jawnos_desktop/browser.py perl/help/topics_web.pl
# covers:    one mapped appointment follows a site across its pages and subdomains, and a tick stop that was only navigation reopens the same appointment

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use JawnOSTest;

# Force the lazy domain modules the tick reaches before we override any of
# their subs: a later require would replace the test's override.
require JawnOS::Domain::Appointment;
require JawnOS::Domain::Name;
require JawnOS::Domain::Calendar;
require JawnOS::Domain::Generate;
require JawnOS::Domain::Resolve;
require JawnOS::Domain::Render;
require JawnOS::Domain::Say;
require JawnOS::Domain::Embedded2;
require JawnOS::Domain::File;

my $root = root();

# ------------------------------------------------------------ host matching
# key_name is the registrable domain so the site totals stay one row; the URL is
# where a subdomain survives. The most specific assignment wins, so a person can
# give marketplace.facebook.com its own app while the rest of facebook.com stays
# with Facebook.
my $map = {
	'facebook.com'             => 'facebook',
	'marketplace.facebook.com' => 'marketplace',
};
is( &subs::internet_site_app_for_host( $map, 'facebook.com' ),             'facebook',    'the site itself' );
is( &subs::internet_site_app_for_host( $map, 'www.facebook.com' ),         'facebook',    'www is the site' );
is( &subs::internet_site_app_for_host( $map, 'm.facebook.com' ),           'facebook',    'another subdomain is the site' );
is( &subs::internet_site_app_for_host( $map, 'marketplace.facebook.com' ), 'marketplace', 'an explicit subdomain wins' );
is( &subs::internet_site_app_for_host( $map, 'www.marketplace.facebook.com' ), 'marketplace', 'and its children win too' );
is( &subs::internet_site_app_for_host( $map, 'wikipedia.org' ),            '',            'an unassigned site has no app' );
is( &subs::internet_site_app_for_host( $map, 'com' ),                      '',            'a bare TLD is never a match' );

is( &subs::internet_site_host( 'https://marketplace.facebook.com/x?y=1', 'facebook.com' ),
	'marketplace.facebook.com', 'the URL keeps the subdomain' );
is( &subs::internet_site_host( '', 'facebook.com' ), 'facebook.com', 'a span with no URL falls back to its key' );
is( &subs::internet_site_host( 'https://user:pw@example.com:8443/x', 'example.com' ), 'example.com',
	'userinfo and the port are not part of the host' );

# -------------------------------------------------------------- the desktop
# The phone always kept its span across a same-site page move; the desktop closed
# and reopened on every URL, which is what turned one visit into many spans.
my $browser = read_file("$root/desktop/jawnos_desktop/browser.py");
like( $browser, qr/if self\._current and self\._current\["key"\] == key:\n\s+# A page-to-page move/,
	'a same-site URL change keeps the desktop span open' );
unlike( $browser, qr/self\._current\["url"\] == url/, 'the URL alone no longer ends the visit' );

# -------------------------------------------------------------- the manager
# The tick runs against the test copy of the database. Its panel and window
# side effects are stubbed, and the clock is pinned so the resume window is a
# fixed number of milliseconds.
my $app  = 'testsiteapp';
my $NOW  = 1_800_000_000_000;
my $base = $NOW - 10 * 60_000;
my %cache;

sub span {
	my ( $start, $end, $url ) = @_;
	&subs::db_insert( 'usage_sessions', {
		device     => 'computer',
		kind       => 'site',
		key_name   => 'facebook.com',
		started_at => $start,
		ended_at   => $end,
		idle_ms    => 0,
		source     => 'browser',
		hostname   => '',
		title      => '',
		url        => $url,
		server_time => $end,
		ost        => $end,
	} );
}

sub sessions {
	my $rows = &subs::db_query( 'select * from appointments where app = ? order by cast(timestamp as integer)', $app )->hashes || [];
	return $rows;
}

{
	no warnings 'redefine';
	no warnings 'once';
	local *subs::rightNow = sub { $NOW };
	local *subs::setting_grabber = sub {
		my ($opts) = @_;
		return '{"facebook.com":"' . $app . '"}' if ( $opts->{'app'} || '' ) eq 'internet'
			&& ( $opts->{'setting'} || '' ) eq 'domain_apps';
		return '';
	};
	local *subs::setting_initializer = sub { return { app => $_[0] } };
	local *subs::settings_grabber = sub { return {} };
	local *subs::usual_appointment_maker = sub { return ( undef, undef, undef, undef ) };
	local *subs::app_hidden_now = sub { return 0 };
	local *subs::device_setter = sub { return 'computer' };
	local *subs::intelligent_automation_toggle = sub { return 1 };
	local *subs::ago_calc = sub { return $_[1] // 0 };
	local *Websocket::send = sub { return 1 };
	local *subs::cache_set = sub {
		my ( $key, $value ) = @_;
		$cache{ ( $key->{'context'} // '' ) . '|' . ( $key->{'subcontext'} // '' ) } = $value;
		return 1;
	};
	local *subs::cache_get = sub {
		my ($key) = @_;
		return $cache{ ( $key->{'context'} // '' ) . '|' . ( $key->{'subcontext'} // '' ) };
	};
	local *subs::cache_delete = sub {
		my ($key) = @_;
		delete $cache{ ( $key->{'context'} // '' ) . '|' . ( $key->{'subcontext'} // '' ) };
		return 1;
	};

	&subs::db_delete( 'appointments', { app => $app } );
	&subs::db_delete( 'usage_sessions', { key_name => 'facebook.com' } );

	# Two contiguous spans, then a quiet gap longer than the grace: one
	# appointment starts, then stops at the last span's end.
	span( $base, $base + 30_000, 'https://www.facebook.com/' );
	span( $base + 30_000, $base + 60_000, 'https://www.facebook.com/friends' );
	$NOW = $base + 70_000;
	&subs::internet_site_appointment_tick( { force => 1 } );
	my $rows = sessions();
	is( scalar @{$rows}, 1, 'the first page starts one appointment' );
	my $uuid = $rows->[0]->{'uuid'};
	is( $rows->[0]->{'type'}, 'start', 'and leaves it running' );

	$NOW = $base + 140_000;
	&subs::internet_site_appointment_tick( { force => 1 } );
	$rows = sessions();
	is( $rows->[0]->{'type'}, 'stop', 'the quiet site stops it' );
	is( int( $rows->[0]->{'stop_timestamp'} ), $base + 60_000, 'at the last span end, not at the tick' );

	# A subdomain page resumes within the window: the same row, not a second
	# one, even though the gap was long enough to stop the tick's first run.
	span( $base + 70_000, $base + 100_000, 'https://marketplace.facebook.com/' );
	$NOW = $base + 130_000;
	&subs::internet_site_appointment_tick( { force => 1 } );
	$rows = sessions();
	is( scalar @{$rows}, 1, 'a navigation does not make a second appointment' );
	is( $rows->[0]->{'uuid'}, $uuid, 'the same appointment is reopened' );
	is( $rows->[0]->{'type'}, 'start', 'and it is running again' );
	ok( !defined $rows->[0]->{'stop_seen'} || !length $rows->[0]->{'stop_seen'}, 'with its stop cleared' );

	# Leaving for good closes that same row at the resumed span's end.
	$NOW = $base + 220_000;
	&subs::internet_site_appointment_tick( { force => 1 } );
	$rows = sessions();
	is( scalar @{$rows}, 1, 'still one appointment after the visit ends' );
	is( int( $rows->[0]->{'stop_timestamp'} ), $base + 100_000, 'closed at the resumed span end' );

	# A page more than five minutes after the stop is a real departure, not a
	# pause: it starts a new appointment.
	span( $base + 490_000, $base + 520_000, 'https://www.facebook.com/again' );
	$NOW = $base + 530_000;
	&subs::internet_site_appointment_tick( { force => 1 } );
	$rows = sessions();
	is( scalar @{$rows}, 2, 'a page after five minutes starts a new appointment' );
	is( $rows->[1]->{'type'}, 'start', 'and it is running' );
	isnt( $rows->[1]->{'uuid'}, $uuid, 'with a new uuid' );
}

done_testing();
