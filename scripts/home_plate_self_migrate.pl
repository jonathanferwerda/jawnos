#!/usr/bin/env perl
# home_plate_self_migrate.pl - a plate only ever triggers its own app.
#
# Older duties could name another app (self=off, app=<other>): the plate belonged
# to one app but started/stopped a different one. This moves each such duty onto
# the app it names, carrying the plate's coordinates with it, so every plate now
# triggers only the app it is filed under. A dry run by default; --apply writes.
#
#   perl scripts/home_plate_self_migrate.pl [--apply]
use strict;
use warnings;
use FindBin;
require Mojo::JSON;
chdir "$FindBin::Bin/.." or die "cannot find the jawnos root: $!";
require './subroutines.pl';

my $apply = grep { $_ eq '--apply' } @ARGV;

my %duties;      # app -> [ duty, ... ]
my %plate;       # app -> the app's base home_plate
my %touched;     # app -> 1 when its duty list changed

foreach my $row ( @{ &subs::db_query("select app, value from settings where setting='home_plate_duties' and value is not null and value != '[]'")->hashes } ) {
	next unless $row->{'app'};
	$duties{ $row->{'app'} } = eval { return Mojo::JSON::decode_json($row->{'value'}) } || [];
}
foreach my $app ( keys %duties ) {
	$plate{$app} = eval { return Mojo::JSON::decode_json(&subs::setting_grabber({ app => $app, setting => 'home_plate' })) } || {};
}

my $moved = 0;
foreach my $owner ( sort keys %duties ) {
	my @keep;
	foreach my $duty ( @{ $duties{$owner} } ) {
		my $target = $duty->{'app'} || '';
		my $self = $duty->{'self'} || '';
		if ($self eq 'off' && length $target && $target ne $owner) {
			# the plate moves to the app it names, and becomes that app's own plate
			$duty->{'self'} = 'on';
			$duty->{'app'} = $target;
			unless (length($duty->{'latitude'} || '') && length($duty->{'longitude'} || '')) {
				$duty->{'latitude'} = $plate{$owner}->{'latitude'};
				$duty->{'longitude'} = $plate{$owner}->{'longitude'};
			}
			my $list = $duties{$target} ||= [];
			@{$list} = grep { ($_->{'uuid'} || '') ne ($duty->{'uuid'} || '') } @{$list};
			push @{$list}, $duty;
			if (!$plate{$target}->{'latitude'} && $duty->{'latitude'}) {
				$plate{$target} = {
					app => $target, type => 'home_plate', uuid => &subs::random_string_creator(22),
					timestamp => &subs::rightNow(), server_time => &subs::rightNow(),
					latitude => $duty->{'latitude'}, longitude => $duty->{'longitude'}
				};
				$touched{$target} = 1;
			}
			$touched{$target} = 1;
			$touched{$owner} = 1;
			$moved++;
			print "move  $owner -> $target  action=$duty->{'action'}  distance=$duty->{'distance'}  uuid=$duty->{'uuid'}\n";
			next;
		}
		if ($self ne 'on' || ($duty->{'app'} || '') ne $owner) {
			$duty->{'self'} = 'on';
			$duty->{'app'} = $owner;
			$touched{$owner} = 1;
		}
		push @keep, $duty;
	}
	$duties{$owner} = \@keep;
}

print "moved $moved duty(ies) across apps\n";
if (!$apply) {
	print "dry run: nothing written. Run with --apply to write.\n";
	exit 0;
}

foreach my $app ( sort keys %touched ) {
	&subs::setting_setter({ app => $app, setting => 'home_plate_duties', value => Mojo::JSON::encode_json($duties{$app} || []) });
	if ($plate{$app}->{'latitude'} && !&subs::setting_grabber({ app => $app, setting => 'home_plate' })) {
		&subs::setting_setter({ app => $app, setting => 'home_plate', value => Mojo::JSON::encode_json($plate{$app}) });
	}
	print "saved $app\n";
}
print "done\n";
