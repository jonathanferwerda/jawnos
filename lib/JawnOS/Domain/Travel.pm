package subs;

# Travel: what a Travel view covers, and how far away a place on it is.
#
# Loaded on demand by lib/JawnOS/Domain/Loader.pm.
use strict;
use warnings;
use utf8;

use Math::Trig qw(deg2rad rad2deg);

# The rules the house uses when it speaks about ground: metres for a short
# distance, kilometres for a long one, and a compass point rather than a raw
# bearing, because "140 m NE" is what a person reads on a walk.
my @TRAVEL_COMPASS = qw(N NE E SE S SW W NW);

# The window a Travel view covers, in milliseconds.
#
# The Start and End fields are distances from the moment being looked at ("an
# hour ago"), not moments of their own. They are saved as an age so opening
# Travel a week later still means an hour, instead of the week that a fixed
# moment would have stretched to by then.
#
# `start_time`/`end_time` are the older shape - a fixed moment with no age
# beside it. They are still honoured here, in the order they were written, so
# a caller that has not migrated them yet reads what it used to; the viewer
# drops such a pair once (see travel_window_legacy) rather than letting a
# stale moment define the view forever.
#
# With neither, the window is the time scope either side of the moment, which
# is what the viewer has always opened on.
sub travel_window {
	my ($opts) = @_;
	$opts = {} unless ref $opts eq 'HASH';
	my $settings = ref $opts->{'settings'} eq 'HASH' ? $opts->{'settings'} : {};
	my $timestamp = $opts->{'timestamp'};
	$timestamp = &rightNow() unless defined $timestamp && $timestamp =~ /^\d+$/;

	my $length = &time_span_length($opts->{'scope'} || 'fiveminute');
	$length = 5 * 60 * 1000 unless defined $length && $length > 0;
	my ( $start, $end ) = ( $timestamp - $length, $timestamp + $length );

	my $start_age = $settings->{'start_ago'};
	my $end_age = $settings->{'end_ago'};
	if ( defined $start_age && $start_age =~ /^-?\d+(?:\.\d+)?$/ ) {
		$start = $timestamp - $start_age;
	}
	elsif ( defined $settings->{'start_time'} && $settings->{'start_time'} =~ /^\d+$/ ) {
		$start = $settings->{'start_time'} + 0;
	}
	if ( defined $end_age && $end_age =~ /^-?\d+(?:\.\d+)?$/ ) {
		$end = $timestamp - $end_age;
	}
	elsif ( defined $settings->{'end_time'} && $settings->{'end_time'} =~ /^\d+$/ ) {
		$end = $settings->{'end_time'} + 0;
	}

	# a window typed backwards is still the window that was asked for
	( $start, $end ) = ( $end, $start ) if $end < $start;
	return { start => int($start), end => int($end) };
}

# Whether the saved window is a fixed moment from a version before the fields
# were read as ages. Such a moment only grows more wrong with every day it is
# left in place, so the viewer drops it once and opens on Now instead.
sub travel_window_legacy {
	my ($settings) = @_;
	return 0 unless ref $settings eq 'HASH';
	return 0 if ( defined $settings->{'start_ago'} && length $settings->{'start_ago'} );
	return 0 if ( defined $settings->{'end_ago'} && length $settings->{'end_ago'} );
	return 1 if ( defined $settings->{'start_time'} && length $settings->{'start_time'} );
	return 1 if ( defined $settings->{'end_time'} && length $settings->{'end_time'} );
	return 0;
}

# The ground distance (metres) and the compass bearing (degrees clockwise from
# north) from one place to another. The haversine formula on the sphere the rest
# of the house measures on (6372.8 km) is exact enough for a place read off a
# map. Fed plain latitudes: Math::Trig's great_circle_distance takes a latitude
# too, and the old call gave it a colatitude, which is why every bearing in the
# list used to be wrong.
sub travel_offset {
	my ( $lat1, $lon1, $lat2, $lon2 ) = @_;
	foreach my $value ( $lat1, $lon1, $lat2, $lon2 ) {
		return { metres => 0, bearing => 0 } unless defined $value && $value =~ /^-?\d+(?:\.\d+)?$/;
	}
	my $radius = 6372800;
	my $phi1 = deg2rad($lat1);
	my $phi2 = deg2rad($lat2);
	my $dphi = deg2rad( $lat2 - $lat1 );
	my $dlambda = deg2rad( $lon2 - $lon1 );
	my $a = ( sin( $dphi / 2 ) ** 2 ) + ( cos($phi1) * cos($phi2) * ( sin( $dlambda / 2 ) ** 2 ) );
	$a = 1 if $a > 1;
	my $metres = 2 * $radius * atan2( sqrt($a), sqrt( 1 - $a ) );
	my $y = sin($dlambda) * cos($phi2);
	my $x = ( cos($phi1) * sin($phi2) ) - ( sin($phi1) * cos($phi2) * cos($dlambda) );
	my $bearing = rad2deg( atan2( $y, $x ) );
	$bearing += 360 while $bearing < 0;
	$bearing -= 360 while $bearing >= 360;
	return { metres => $metres, bearing => $bearing };
}

# How far away something is, in the unit a person would say it in: metres up to
# a kilometre, one decimal place to ten, whole kilometres beyond that.
sub travel_distance_phrase {
	my ($metres) = @_;
	return '' unless defined $metres && $metres =~ /^-?\d+(?:\.\d+)?$/;
	$metres = abs($metres);
	return sprintf( '%.0f m', $metres ) if $metres < 950;
	my $km = $metres / 1000;
	return sprintf( '%.1f km', $km ) if $km < 10;
	return sprintf( '%.0f km', $km );
}

# The eight-point compass name for a bearing in degrees.
sub travel_compass {
	my ($degrees) = @_;
	return '' unless defined $degrees && $degrees =~ /^-?\d+(?:\.\d+)?$/;
	my $at = $degrees + 0;
	$at += 360 while $at < 0;
	$at -= 360 while $at >= 360;
	my $point = int( ( $at + 22.5 ) / 45 ) % 8;
	return $TRAVEL_COMPASS[$point];
}

1;
