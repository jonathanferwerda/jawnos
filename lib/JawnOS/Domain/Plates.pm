package subs;

# Plates: the ground a home plate covers. A plate is a point with one or more
# areas - a circle, a box, a path with a width, or a polygon - and a pattern flag
# may carry cached branches, each with its own areas. Everything here reads the
# same JSON the configure panel writes and the map draws, so a fix is judged by
# one rule on every machine.
#
# Distances inside a small area are planar metres (equirectangular about the
# area's own latitude); a circle uses the WGS84 geodesic the GPS reports against.
# That is plenty at house scale and keeps a path's segment test cheap.

use strict;
use warnings;
use utf8;

use Math::Trig qw(pi);

my $METRES_PER_DEG_LAT = 111194.9;

sub plate_default_radius_m { return 200 }

sub _plate_number {
	my ($value, $default) = @_;
	return $default unless defined $value && $value =~ /^-?\d+(?:\.\d+)?$/;
	return 0 + $value;
}

sub _plate_metres_per_deg_lon {
	my ($lat) = @_;
	return $METRES_PER_DEG_LAT * cos($lat * pi / 180);
}

sub _plate_xy {
	my ($lat0, $lon0, $lat, $lon) = @_;
	return ( ($lon - $lon0) * _plate_metres_per_deg_lon($lat0), ($lat - $lat0) * $METRES_PER_DEG_LAT );
}

sub _plate_segment_metres {
	my ($px, $py, $ax, $ay, $bx, $by) = @_;
	my $dx = $bx - $ax;
	my $dy = $by - $ay;
	my $len2 = ($dx * $dx) + ($dy * $dy);
	my $t = $len2 > 0 ? ((($px - $ax) * $dx) + (($py - $ay) * $dy)) / $len2 : 0;
	$t = 0 if $t < 0;
	$t = 1 if $t > 1;
	my $x = $ax + ($t * $dx);
	my $y = $ay + ($t * $dy);
	return sqrt((($px - $x) ** 2) + (($py - $y) ** 2));
}

# A shape's name, accepting the spellings a caller or an older row may use.
sub plate_area_shape {
	my ($area) = @_;
	return '' unless ref $area eq 'HASH';
	my $shape = lc($area->{'shape'} || $area->{'kind'} || '');
	return 'circle' if $shape eq 'point' || $shape eq 'radius' || $shape eq 'circle';
	return 'box' if $shape eq 'rectangle' || $shape eq 'rect' || $shape eq 'box';
	return 'path' if $shape eq 'line' || $shape eq 'corridor' || $shape eq 'path' || $shape eq 'river';
	return 'polygon' if $shape eq 'area' || $shape eq 'polygon';
	return $shape;
}

sub plate_area_points {
	my ($area) = @_;
	return [] unless ref $area eq 'HASH' && ref $area->{'points'} eq 'ARRAY';
	my @points;
	foreach my $p ( @{ $area->{'points'} } ) {
		next unless ref $p eq 'HASH';
		my $lat = _plate_number( $p->{'lat'} // $p->{'latitude'}, undef );
		my $lon = _plate_number( $p->{'lon'} // $p->{'longitude'}, undef );
		push @points, { lat => $lat, lon => $lon } if defined $lat && defined $lon;
	}
	return \@points;
}

sub plate_area_anchor {
	my ($area) = @_;
	return undef unless ref $area eq 'HASH';
	my $shape = plate_area_shape($area);
	if ($shape eq 'circle') {
		my $lat = _plate_number( $area->{'lat'} // $area->{'latitude'}, undef );
		my $lon = _plate_number( $area->{'lon'} // $area->{'longitude'}, undef );
		return { lat => $lat, lon => $lon } if defined $lat && defined $lon;
	}
	if ($shape eq 'box') {
		my $nw = ref $area->{'nw'} eq 'HASH' ? $area->{'nw'} : {};
		my $se = ref $area->{'se'} eq 'HASH' ? $area->{'se'} : {};
		my $nlat = _plate_number( $nw->{'lat'} // $nw->{'latitude'}, undef );
		my $nlon = _plate_number( $nw->{'lon'} // $nw->{'longitude'}, undef );
		my $slat = _plate_number( $se->{'lat'} // $se->{'latitude'}, undef );
		my $slon = _plate_number( $se->{'lon'} // $se->{'longitude'}, undef );
		return { lat => ($nlat + $slat) / 2, lon => ($nlon + $slon) / 2 }
			if defined $nlat && defined $nlon && defined $slat && defined $slon;
	}
	my $points = plate_area_points($area);
	return $points->[0] if scalar @{$points};
	my $lat = _plate_number( $area->{'lat'} // $area->{'latitude'}, undef );
	my $lon = _plate_number( $area->{'lon'} // $area->{'longitude'}, undef );
	return { lat => $lat, lon => $lon } if defined $lat && defined $lon;
	return undef;
}

# The nominal reach of a shape: the radius of a circle, half a path's width, or
# half a box's / polygon's diagonal. The stop-side "three radii is a certain
# leave" rule reads this, so a long corridor is judged by its width, not its length.
sub plate_area_reach_km {
	my ($area) = @_;
	return 0 unless ref $area eq 'HASH';
	my $shape = plate_area_shape($area);
	if ($shape eq 'circle') {
		my $r = _plate_number( $area->{'radius_m'} // $area->{'range_m'}, undef );
		$r = _plate_number( $area->{'distance'}, undef ) * 1000 if !defined $r && defined $area->{'distance'};
		$r = plate_default_radius_m() unless defined $r && $r > 0;
		return $r / 1000;
	}
	if ($shape eq 'path') {
		my $w = _plate_number( $area->{'width_m'} // $area->{'width'}, undef );
		$w = 30 unless defined $w && $w > 0;
		return ($w / 2) / 1000;
	}
	if ($shape eq 'box') {
		my $nw = ref $area->{'nw'} eq 'HASH' ? $area->{'nw'} : {};
		my $se = ref $area->{'se'} eq 'HASH' ? $area->{'se'} : {};
		my $nlat = _plate_number( $nw->{'lat'} // $nw->{'latitude'}, undef );
		my $nlon = _plate_number( $nw->{'lon'} // $nw->{'longitude'}, undef );
		my $slat = _plate_number( $se->{'lat'} // $se->{'latitude'}, undef );
		my $slon = _plate_number( $se->{'lon'} // $se->{'longitude'}, undef );
		return 0 unless defined $nlat && defined $nlon && defined $slat && defined $slon;
		my ($dx, $dy) = _plate_xy( ($nlat + $slat) / 2, ($nlon + $slon) / 2, $nlat, $nlon );
		return sqrt(($dx * $dx) + ($dy * $dy)) / 1000;
	}
	my $points = plate_area_points($area);
	if (scalar @{$points}) {
		my ($minlat, $maxlat, $minlon, $maxlon) = ($points->[0]->{'lat'}, $points->[0]->{'lat'}, $points->[0]->{'lon'}, $points->[0]->{'lon'});
		foreach my $p ( @{$points} ) {
			$minlat = $p->{'lat'} if $p->{'lat'} < $minlat;
			$maxlat = $p->{'lat'} if $p->{'lat'} > $maxlat;
			$minlon = $p->{'lon'} if $p->{'lon'} < $minlon;
			$maxlon = $p->{'lon'} if $p->{'lon'} > $maxlon;
		}
		my ($dx, $dy) = _plate_xy( ($minlat + $maxlat) / 2, ($minlon + $maxlon) / 2, $maxlat, $maxlon );
		return sqrt(($dx * $dx) + ($dy * $dy)) / 1000;
	}
	return 0;
}

sub plate_area_contains {
	my ($area, $lat, $lon) = @_;
	return 0 unless ref $area eq 'HASH';
	return 0 unless defined $lat && defined $lon;
	my $shape = plate_area_shape($area);
	if ($shape eq 'circle') {
		my $a = plate_area_anchor($area);
		return 0 unless $a;
		my $r = plate_area_reach_km($area) * 1000;
		my $d = &subs::geodesic_offset($a->{'lat'}, $a->{'lon'}, $lat, $lon)->{'metres'};
		return $d <= $r ? 1 : 0;
	}
	if ($shape eq 'box') {
		my $nw = ref $area->{'nw'} eq 'HASH' ? $area->{'nw'} : {};
		my $se = ref $area->{'se'} eq 'HASH' ? $area->{'se'} : {};
		my $nlat = _plate_number( $nw->{'lat'} // $nw->{'latitude'}, undef );
		my $nlon = _plate_number( $nw->{'lon'} // $nw->{'longitude'}, undef );
		my $slat = _plate_number( $se->{'lat'} // $se->{'latitude'}, undef );
		my $slon = _plate_number( $se->{'lon'} // $se->{'longitude'}, undef );
		return 0 unless defined $nlat && defined $nlon && defined $slat && defined $slon;
		# A foreign or hand-edited row may store the corners in either order. The
		# map's hit test has always treated them as a box; navigation must agree.
		my ($minlat, $maxlat) = $nlat < $slat ? ($nlat, $slat) : ($slat, $nlat);
		my ($minlon, $maxlon) = $nlon < $slon ? ($nlon, $slon) : ($slon, $nlon);
		return ($lat <= $maxlat && $lat >= $minlat && $lon >= $minlon && $lon <= $maxlon) ? 1 : 0;
	}
	my $points = plate_area_points($area);
	if ($shape eq 'path') {
		return 0 unless scalar @{$points};
		my $lat0 = $points->[0]->{'lat'};
		my $lon0 = $points->[0]->{'lon'};
		my ($x, $y) = _plate_xy($lat0, $lon0, $lat, $lon);
		my @xy = map { my ($px, $py) = _plate_xy($lat0, $lon0, $_->{'lat'}, $_->{'lon'}); [$px, $py] } @{$points};
		my $half = plate_area_reach_km($area) * 1000;
		if (scalar @xy == 1) {
			return sqrt(($x * $x) + ($y * $y)) <= $half ? 1 : 0;
		}
		for (my $i = 1; $i < scalar @xy; $i++) {
			return 1 if _plate_segment_metres($x, $y, $xy[$i - 1][0], $xy[$i - 1][1], $xy[$i][0], $xy[$i][1]) <= $half;
		}
		return 0;
	}
	if ($shape eq 'polygon') {
		return 0 unless scalar @{$points} >= 3;
		my $lat0 = $points->[0]->{'lat'};
		my $lon0 = $points->[0]->{'lon'};
		my ($x, $y) = _plate_xy($lat0, $lon0, $lat, $lon);
		my @xy = map { my ($px, $py) = _plate_xy($lat0, $lon0, $_->{'lat'}, $_->{'lon'}); [$px, $py] } @{$points};
		my $inside = 0;
		for (my $i = 0, my $j = scalar(@xy) - 1; $i < scalar @xy; $j = $i++) {
			my ($xi, $yi) = @{ $xy[$i] };
			my ($xj, $yj) = @{ $xy[$j] };
			if ((($yi > $y) != ($yj > $y)) && ($x < (($xj - $xi) * ($y - $yi) / ($yj - $yi)) + $xi)) {
				$inside = !$inside;
			}
		}
		return $inside ? 1 : 0;
	}
	my $a = plate_area_anchor($area);
	return 0 unless $a;
	my $d = &subs::geodesic_offset($a->{'lat'}, $a->{'lon'}, $lat, $lon)->{'metres'};
	return $d <= plate_default_radius_m() ? 1 : 0;
}

sub plate_area_distance_km {
	my ($area, $lat, $lon) = @_;
	return 1_000_000 unless ref $area eq 'HASH';
	return 1_000_000 unless defined $lat && defined $lon;
	return 0 if plate_area_contains($area, $lat, $lon);
	my $shape = plate_area_shape($area);
	if ($shape eq 'circle') {
		my $a = plate_area_anchor($area);
		return 1_000_000 unless $a;
		my $d = &subs::geodesic_offset($a->{'lat'}, $a->{'lon'}, $lat, $lon)->{'metres'};
		my $r = plate_area_reach_km($area) * 1000;
		return ($d - $r) / 1000;
	}
	if ($shape eq 'box') {
		my $nw = ref $area->{'nw'} eq 'HASH' ? $area->{'nw'} : {};
		my $se = ref $area->{'se'} eq 'HASH' ? $area->{'se'} : {};
		my $nlat = _plate_number( $nw->{'lat'} // $nw->{'latitude'}, undef );
		my $nlon = _plate_number( $nw->{'lon'} // $nw->{'longitude'}, undef );
		my $slat = _plate_number( $se->{'lat'} // $se->{'latitude'}, undef );
		my $slon = _plate_number( $se->{'lon'} // $se->{'longitude'}, undef );
		return 1_000_000 unless defined $nlat && defined $nlon && defined $slat && defined $slon;
		my ($cx, $cy) = (($nlat + $slat) / 2, ($nlon + $slon) / 2);
		my ($x, $y) = _plate_xy($cx, $cy, $lat, $lon);
		my ($hx, $hy) = _plate_xy($cx, $cy, $nlat, $nlon);
		my $dx = abs($x) - abs($hx);
		my $dy = abs($y) - abs($hy);
		$dx = 0 if $dx < 0;
		$dy = 0 if $dy < 0;
		return sqrt(($dx * $dx) + ($dy * $dy)) / 1000;
	}
	my $points = plate_area_points($area);
	if (($shape eq 'path' || $shape eq 'polygon') && scalar @{$points}) {
		my $lat0 = $points->[0]->{'lat'};
		my $lon0 = $points->[0]->{'lon'};
		my ($x, $y) = _plate_xy($lat0, $lon0, $lat, $lon);
		my @xy = map { my ($px, $py) = _plate_xy($lat0, $lon0, $_->{'lat'}, $_->{'lon'}); [$px, $py] } @{$points};
		my $best;
		if (scalar @xy == 1) {
			$best = sqrt(($x * $x) + ($y * $y));
		}
		else {
			for (my $i = 1; $i < scalar @xy; $i++) {
				my $d = _plate_segment_metres($x, $y, $xy[$i - 1][0], $xy[$i - 1][1], $xy[$i][0], $xy[$i][1]);
				$best = $d if !defined $best || $d < $best;
			}
		}
		return 1_000_000 unless defined $best;
		my $half = $shape eq 'path' ? (plate_area_reach_km($area) * 1000) : 0;
		return ($best - $half) / 1000;
	}
	my $a = plate_area_anchor($area);
	return 1_000_000 unless $a;
	my $d = &subs::geodesic_offset($a->{'lat'}, $a->{'lon'}, $lat, $lon)->{'metres'};
	return ($d - plate_default_radius_m()) / 1000;
}

# Every area a plate covers: its own areas, the areas of its cached pattern
# branches, or - for an old point-and-radius row - one circle. A pattern with no
# branches covers nothing until it is refreshed; its region is a search box, not
# a plate, so it must not become a circle by accident.
sub plate_areas {
	my ($plate) = @_;
	return [] unless ref $plate eq 'HASH';
	my @out;
	if (ref $plate->{'areas'} eq 'ARRAY') {
		foreach my $a ( @{ $plate->{'areas'} } ) {
			push @out, $a if ref $a eq 'HASH';
		}
	}
	if (ref $plate->{'branches'} eq 'ARRAY') {
		foreach my $b ( @{ $plate->{'branches'} } ) {
			next unless ref $b eq 'HASH';
			if (ref $b->{'areas'} eq 'ARRAY') {
				foreach my $a ( @{ $b->{'areas'} } ) {
					push @out, $a if ref $a eq 'HASH';
				}
			}
			elsif (defined $b->{'latitude'} && length $b->{'latitude'} && defined $b->{'longitude'} && length $b->{'longitude'}) {
				push @out, { shape => 'circle', lat => 0 + $b->{'latitude'}, lon => 0 + $b->{'longitude'}, radius_m => _plate_number($b->{'radius_m'}, 250) };
			}
		}
	}
	return \@out if scalar @out;
	# An explicit empty list means the person cleared the ground; the legacy
	# point must not quietly turn that back into a circle.
	return [] if exists $plate->{'areas'};
	return [] if (($plate->{'kind'} || '') eq 'pattern');
	my $lat = _plate_number($plate->{'latitude'}, undef);
	my $lon = _plate_number($plate->{'longitude'}, undef);
	if (defined $lat && defined $lon) {
		my $r = _plate_number($plate->{'radius_m'}, undef);
		$r = _plate_number($plate->{'distance'}, undef) * 1000 if !defined $r && defined $plate->{'distance'};
		$r = plate_default_radius_m() unless defined $r && $r > 0;
		return [ { shape => 'circle', lat => $lat, lon => $lon, radius_m => $r } ];
	}
	return [];
}

sub plate_anchor {
	my ($plate) = @_;
	return undef unless ref $plate eq 'HASH';
	# A pattern flag is positioned by its search region on the map editor; keep
	# the marker in the same place on every other reader. The branches remain
	# the ground plate_contains tests.
	if (($plate->{'kind'} || '') eq 'pattern' && ref $plate->{'match'} eq 'HASH'
		&& ref $plate->{'match'}{'region'} eq 'HASH') {
		my $rlat = _plate_number($plate->{'match'}{'region'}{'lat'}, undef);
		my $rlon = _plate_number($plate->{'match'}{'region'}{'lon'}, undef);
		return { lat => $rlat, lon => $rlon } if defined $rlat && defined $rlon;
	}
	foreach my $a ( @{ plate_areas($plate) } ) {
		my $anchor = plate_area_anchor($a);
		return $anchor if $anchor;
	}
	my $lat = _plate_number($plate->{'latitude'}, undef);
	my $lon = _plate_number($plate->{'longitude'}, undef);
	return { lat => $lat, lon => $lon } if defined $lat && defined $lon;
	return undef;
}

sub plate_contains {
	my ($plate, $lat, $lon) = @_;
	return 0 unless ref $plate eq 'HASH';
	foreach my $a ( @{ plate_areas($plate) } ) {
		return 1 if plate_area_contains($a, $lat, $lon);
	}
	return 0;
}

sub plate_distance_km {
	my ($plate, $lat, $lon) = @_;
	return 1_000_000 unless ref $plate eq 'HASH';
	my $best;
	foreach my $a ( @{ plate_areas($plate) } ) {
		my $d = plate_area_distance_km($a, $lat, $lon);
		return 0 if $d == 0;   # inside is final; no later area can be closer
		$best = $d if !defined $best || $d < $best;
	}
	return defined $best ? $best : 1_000_000;
}

sub plate_reach_km {
	my ($plate) = @_;
	return 0 unless ref $plate eq 'HASH';
	my $best = 0;
	foreach my $a ( @{ plate_areas($plate) } ) {
		my $r = plate_area_reach_km($a);
		$best = $r if $r > $best;
	}
	return $best;
}

sub plate_has_ground {
	my ($plate) = @_;
	return 0 unless ref $plate eq 'HASH';
	# A pattern's ground is its cached branches; its region is a search box, not
	# a place. An empty pattern still has its own (empty) ground, so it must not
	# fall back to the app's default plate and start matching the house.
	return 1 if (($plate->{'kind'} || '') eq 'pattern');
	# An explicit areas/branches key owns the ground even when it is empty: a
	# person who deleted the last shape cleared this plate, and it must match
	# nothing rather than quietly inherit the app's default place.
	return 1 if exists $plate->{'areas'};
	return 1 if exists $plate->{'branches'};
	return 1 if defined $plate->{'latitude'} && length $plate->{'latitude'}
		&& defined $plate->{'longitude'} && length $plate->{'longitude'};
	return 0;
}

# The ground a duty is judged by: its own when it has one, else the app's base
# plate. A duty with neither is left as it is and matches nothing.
sub plate_ground_for {
	my ($duty, $base) = @_;
	return $duty if plate_has_ground($duty);
	return $base if ref $base eq 'HASH' && plate_has_ground($base);
	return $duty;
}

sub _plate_area_normalize {
	my ($area) = @_;
	return undef unless ref $area eq 'HASH';
	my $shape = plate_area_shape($area);
	if ($shape eq 'circle') {
		my $anchor = plate_area_anchor($area);
		return undef unless $anchor;
		my $r = plate_area_reach_km($area) * 1000;
		$r = plate_default_radius_m() unless $r > 0;
		return { shape => 'circle', lat => sprintf('%.7f', $anchor->{'lat'}), lon => sprintf('%.7f', $anchor->{'lon'}), radius_m => sprintf('%.0f', $r) };
	}
	if ($shape eq 'box') {
		my $nw = ref $area->{'nw'} eq 'HASH' ? $area->{'nw'} : {};
		my $se = ref $area->{'se'} eq 'HASH' ? $area->{'se'} : {};
		my $nlat = _plate_number( $nw->{'lat'} // $nw->{'latitude'}, undef );
		my $nlon = _plate_number( $nw->{'lon'} // $nw->{'longitude'}, undef );
		my $slat = _plate_number( $se->{'lat'} // $se->{'latitude'}, undef );
		my $slon = _plate_number( $se->{'lon'} // $se->{'longitude'}, undef );
		return undef unless defined $nlat && defined $nlon && defined $slat && defined $slon;
		# Canonical corners: nw is north-west of se. The map already writes this
		# order; a hand-edited or foreign row may not, and the box test is by
		# min/max either way.
		my ($minlat, $maxlat) = $nlat < $slat ? ($nlat, $slat) : ($slat, $nlat);
		my ($minlon, $maxlon) = $nlon < $slon ? ($nlon, $slon) : ($slon, $nlon);
		return { shape => 'box', nw => { lat => sprintf('%.7f', $maxlat), lon => sprintf('%.7f', $minlon) }, se => { lat => sprintf('%.7f', $minlat), lon => sprintf('%.7f', $maxlon) } };
	}
	if ($shape eq 'path' || $shape eq 'polygon') {
		my $points = plate_area_points($area);
		return undef if $shape eq 'path' && !scalar @{$points};
		return undef if $shape eq 'polygon' && scalar @{$points} < 3;
		my $w = _plate_number( $area->{'width_m'} // $area->{'width'}, undef );
		$w = 30 unless defined $w && $w > 0;
		my %out = (
			shape => $shape,
			points => [ map { { lat => sprintf('%.7f', $_->{'lat'}), lon => sprintf('%.7f', $_->{'lon'}) } } @{$points} ]
		);
		$out{'width_m'} = sprintf('%.0f', $w) if $shape eq 'path';
		return \%out;
	}
	my $anchor = plate_area_anchor($area);
	return undef unless $anchor;
	return { shape => 'circle', lat => sprintf('%.7f', $anchor->{'lat'}), lon => sprintf('%.7f', $anchor->{'lon'}), radius_m => sprintf('%.0f', plate_default_radius_m()) };
}

# Make a plate the shape the client and the matcher expect: every area gets a
# canonical shape and numbers, a legacy point becomes its circle, a branch keeps
# its own areas, and the top-level anchor/radius mirror the first area so older
# readers still see a point and a radius. Safe to run more than once.
sub plate_normalize {
	my ($plate) = @_;
	return $plate unless ref $plate eq 'HASH';
	my $kind = lc($plate->{'kind'} || $plate->{'type'} || 'area');
	$kind = 'pattern' if $kind eq 'pattern' || $kind eq 'brand' || $kind eq 'chain';
	$kind = 'area' unless $kind eq 'pattern';
	$plate->{'kind'} = $kind;
	my $explicit_areas = exists $plate->{'areas'};
	my @areas;
	if (ref $plate->{'areas'} eq 'ARRAY') {
		foreach my $a ( @{ $plate->{'areas'} } ) {
			my $n = _plate_area_normalize($a);
			push @areas, $n if $n;
		}
	}
	my @branches;
	if (ref $plate->{'branches'} eq 'ARRAY') {
		foreach my $b ( @{ $plate->{'branches'} } ) {
			next unless ref $b eq 'HASH';
			my %out = %{$b};
			my @bareas;
			if (ref $b->{'areas'} eq 'ARRAY') {
				foreach my $a ( @{ $b->{'areas'} } ) {
					my $n = _plate_area_normalize($a);
					push @bareas, $n if $n;
				}
			}
			elsif (defined $b->{'latitude'} && length $b->{'latitude'} && defined $b->{'longitude'} && length $b->{'longitude'}) {
				my $r = _plate_number($b->{'radius_m'}, 250);
				$r = 250 unless $r > 0;
				push @bareas, { shape => 'circle', lat => sprintf('%.7f', 0 + $b->{'latitude'}), lon => sprintf('%.7f', 0 + $b->{'longitude'}), radius_m => sprintf('%.0f', $r) };
			}
			next unless @bareas;
			$out{'areas'} = \@bareas;
			push @branches, \%out;
		}
	}
	if (!@areas && !@branches && $kind ne 'pattern' && !$explicit_areas) {
		my $lat = _plate_number($plate->{'latitude'}, undef);
		my $lon = _plate_number($plate->{'longitude'}, undef);
		if (defined $lat && defined $lon) {
			my $r = _plate_number($plate->{'radius_m'}, undef);
			$r = _plate_number($plate->{'distance'}, undef) * 1000 if !defined $r && defined $plate->{'distance'};
			$r = plate_default_radius_m() unless defined $r && $r > 0;
			push @areas, { shape => 'circle', lat => sprintf('%.7f', $lat), lon => sprintf('%.7f', $lon), radius_m => sprintf('%.0f', $r) };
		}
	}
	if (@areas) { $plate->{'areas'} = \@areas; }
	elsif ($explicit_areas) { $plate->{'areas'} = []; }
	else { delete $plate->{'areas'}; }
	if (@branches) { $plate->{'branches'} = \@branches; }
	else { delete $plate->{'branches'}; }
	if (@areas || @branches) {
		my $anchor = plate_anchor($plate);
		if ($anchor) {
			$plate->{'latitude'} = sprintf('%.7f', $anchor->{'lat'});
			$plate->{'longitude'} = sprintf('%.7f', $anchor->{'lon'});
		}
		my $reach = plate_reach_km($plate);
		$plate->{'distance'} = sprintf('%.3f', $reach) if $reach > 0;
	}
	else {
		# No ground at all: drop the legacy point/radius mirror too, or an old
		# reader (and the client's synthetic-circle fallback) would still see the
		# shape the person just deleted.
		delete $plate->{'latitude'};
		delete $plate->{'longitude'};
		delete $plate->{'distance'};
	}
	return $plate;
}

# Escape a person's brand/name for an Overpass regex string. quotemeta handles
# the regex metacharacters; a literal double quote would end the string, and a
# control character has no place in a query.
sub plate_branch_escape {
	my ($text) = @_;
	$text = '' unless defined $text;
	$text =~ s/^\s+|\s+$//g;
	$text =~ s/[\x00-\x1f]//g;
	return '' unless length $text;
	my $escaped = quotemeta($text);
	$escaped =~ s/"/\\"/g;
	return $escaped;
}

# One store, one branch: the same Walmart is often a node and a building way.
# Keep the first of a set that sits within `metres` of one already kept.
sub plate_branch_dedupe {
	my ($branches, $metres) = @_;
	$metres = 150 unless defined $metres && $metres > 0;
	my @out;
	foreach my $b ( @{ ref $branches eq 'ARRAY' ? $branches : [] } ) {
		next unless ref $b eq 'HASH';
		my $lat = _plate_number( $b->{'lat'} // $b->{'latitude'}, undef );
		my $lon = _plate_number( $b->{'lon'} // $b->{'longitude'}, undef );
		next unless defined $lat && defined $lon;
		my $dup = 0;
		foreach my $o (@out) {
			my $d = &subs::geodesic_offset($o->{'lat'}, $o->{'lon'}, $lat, $lon)->{'metres'};
			if ($d <= $metres) { $dup = 1; last; }
		}
		next if $dup;
		push @out, { %{$b}, lat => $lat, lon => $lon };
	}
	return \@out;
}

1;
