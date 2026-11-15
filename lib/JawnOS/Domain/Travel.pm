package subs;

# Travel: what a Travel view covers, and how far away a place on it is.
#
# Loaded on demand by lib/JawnOS/Domain/Loader.pm.
use strict;
use warnings;
use utf8;

use Math::Trig qw(deg2rad rad2deg atan tan);

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

# The ground distance (metres) and the initial bearing (degrees clockwise from
# north) from one place to another, on the WGS84 ellipsoid.
#
# Math::Trig's great_circle_distance is a sphere: "this is not accurate enough
# for navigational purposes" (its own words), because the earth is flattened -
# 0.3% short over a house-sized walk, but tens of metres over a county. Vincenty's
# inverse formulae put the same two points on the ellipsoid the GPS in a phone
# actually uses (a = 6378137 m, f = 1/298.257223563) and agree with the reference
# solution to a fraction of a millimetre, in plain Perl and with no new module.
#
# Vincenty does not converge for near-antipodal pairs (a few degrees either side
# of the far side of the globe); those fall back to the spherical formula, whose
# answer there is right to a millimetre anyway because the path is half the world
# long. The bearing is always the initial one; for the distances this house shows
# (a walk, a county) it is the same to a hundredth of a degree either way.
sub geodesic_offset {
	my ( $lat1, $lon1, $lat2, $lon2 ) = @_;
	foreach my $value ( $lat1, $lon1, $lat2, $lon2 ) {
		return { metres => 0, bearing => 0 } unless defined $value && $value =~ /^\s*-?\d+(?:\.\d+)?\s*$/;
	}
	$lat1 += 0;
	$lon1 += 0;
	$lat2 += 0;
	$lon2 += 0;

	my $a = 6378137.0;                 # WGS84 semi-major axis, metres
	my $f = 1 / 298.257223563;         # WGS84 flattening
	my $b = $a * ( 1 - $f );

	my $L = deg2rad( $lon2 - $lon1 );
	my $U1 = atan( ( 1 - $f ) * tan( deg2rad($lat1) ) );
	my $U2 = atan( ( 1 - $f ) * tan( deg2rad($lat2) ) );
	my ( $sinU1, $cosU1 ) = ( sin($U1), cos($U1) );
	my ( $sinU2, $cosU2 ) = ( sin($U2), cos($U2) );

	my $lambda = $L;
	my ( $sinSigma, $cosSigma, $sigma, $sinAlpha, $cos2Alpha, $cos2SigmaM );
	my $converged = 0;
	for ( my $i = 0; $i < 200; $i++ ) {
		my $sinLambda = sin($lambda);
		my $cosLambda = cos($lambda);
		my $t1 = $cosU2 * $sinLambda;
		my $t2 = ( $cosU1 * $sinU2 ) - ( $sinU1 * $cosU2 * $cosLambda );
		$sinSigma = sqrt( ( $t1 * $t1 ) + ( $t2 * $t2 ) );
		# the same point twice is no distance and no direction
		return { metres => 0, bearing => 0 } if $sinSigma == 0;
		$cosSigma = ( $sinU1 * $sinU2 ) + ( $cosU1 * $cosU2 * $cosLambda );
		$sigma = atan2( $sinSigma, $cosSigma );
		$sinAlpha = ( $cosU1 * $cosU2 * $sinLambda ) / $sinSigma;
		$cos2Alpha = 1 - ( $sinAlpha * $sinAlpha );
		$cos2SigmaM = $cos2Alpha ? ( $cosSigma - ( ( 2 * $sinU1 * $sinU2 ) / $cos2Alpha ) ) : 0;
		my $C = ( $f / 16 ) * $cos2Alpha * ( 4 + ( $f * ( 4 - ( 3 * $cos2Alpha ) ) ) );
		my $previous = $lambda;
		$lambda = $L + ( ( 1 - $C ) * $f * $sinAlpha
			* ( $sigma + ( $C * $sinSigma
				* ( $cos2SigmaM + ( $C * $cosSigma * ( -1 + ( 2 * $cos2SigmaM * $cos2SigmaM ) ) ) ) ) ) );
		if ( abs( $lambda - $previous ) < 1e-12 ) { $converged = 1; last; }
	}

	if ( !$converged ) {
		return &geodesic_offset_sphere( $lat1, $lon1, $lat2, $lon2 );
	}

	my $u2 = $cos2Alpha * ( ( $a * $a - $b * $b ) / ( $b * $b ) );
	my $A = 1 + ( ( $u2 / 16384 ) * ( 4096 + ( $u2 * ( -768 + ( $u2 * ( 320 - ( 175 * $u2 ) ) ) ) ) ) );
	my $B = ( $u2 / 1024 ) * ( 256 + ( $u2 * ( -128 + ( $u2 * ( 74 - ( 47 * $u2 ) ) ) ) ) );
	my $deltaSigma = $B * $sinSigma * ( $cos2SigmaM
		+ ( ( $B / 4 ) * ( ( $cosSigma * ( -1 + ( 2 * $cos2SigmaM * $cos2SigmaM ) ) )
			- ( ( $B / 6 ) * $cos2SigmaM * ( -3 + ( 4 * $sinSigma * $sinSigma ) )
				* ( -3 + ( 4 * $cos2SigmaM * $cos2SigmaM ) ) ) ) ) );
	my $metres = $b * $A * ( $sigma - $deltaSigma );

	my $bearing = rad2deg( atan2(
		$cosU2 * sin($lambda),
		( $cosU1 * $sinU2 ) - ( $sinU1 * $cosU2 * cos($lambda) )
	) );
	$bearing += 360 while $bearing < 0;
	$bearing -= 360 while $bearing >= 360;
	return { metres => $metres, bearing => $bearing };
}

# The spherical answer, kept only for the antipodal pairs Vincenty cannot settle.
# Plain latitudes in, metres and a clockwise-from-north bearing out, so a caller
# reads the same shape from either path.
sub geodesic_offset_sphere {
	my ( $lat1, $lon1, $lat2, $lon2 ) = @_;
	my $radius = 6371008.8;            # the mean radius, metres
	my $phi1 = deg2rad($lat1);
	my $phi2 = deg2rad($lat2);
	my $dphi = deg2rad( $lat2 - $lat1 );
	my $dlambda = deg2rad( $lon2 - $lon1 );
	my $h = ( sin( $dphi / 2 ) ** 2 ) + ( cos($phi1) * cos($phi2) * ( sin( $dlambda / 2 ) ** 2 ) );
	$h = 1 if $h > 1;
	my $metres = 2 * $radius * atan2( sqrt($h), sqrt( 1 - $h ) );
	my $bearing = rad2deg( atan2(
		sin($dlambda) * cos($phi2),
		( cos($phi1) * sin($phi2) ) - ( sin($phi1) * cos($phi2) * cos($dlambda) )
	) );
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

# One row per place in a list that is already nearest-first. The continent files
# a fix on every action, so one app appears several times at the same spot (a
# morning's taps at the kitchen table) and the map groups those within 50 m -
# the list does the same, keeping the nearest of each. Two visits of the same app
# in different places stay two rows: only near-coincident fixes collapse.
sub travel_collapse_places {
	my ( $rows, $metres ) = @_;
	return [] unless ref $rows eq 'ARRAY';
	$metres = 50 unless defined $metres && $metres =~ /^\d+(?:\.\d+)?$/;
	my @kept;
	foreach my $row ( @{$rows} ) {
		next unless ref $row eq 'HASH';
		my $dupe = 0;
		foreach my $seen ( grep { ( $_->{'app'} // '' ) eq ( $row->{'app'} // '' ) } @kept ) {
			next unless defined $seen->{'latitude'} && defined $row->{'latitude'};
			my $offset = &geodesic_offset( $seen->{'latitude'}, $seen->{'longitude'}, $row->{'latitude'}, $row->{'longitude'} );
			if ( $offset->{'metres'} <= $metres ) { $dupe = 1; last; }
		}
		push @kept, $row unless $dupe;
	}
	return \@kept;
}

1;
