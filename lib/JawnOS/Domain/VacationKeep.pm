package subs;

# The keep list: the apps the person wants to keep running while the house is
# away. A budgeted app on the budget keep list keeps counting, a scheduled app
# on the routine keep list still runs, and a notice app on the notification keep
# list still speaks. The lists live under policy.keep_apps in the vacation
# setting, so every machine reads the same answer.
#
# Loaded on demand by lib/JawnOS/Domain/Loader.pm.
use strict;
use warnings;
use utf8;

our $vacation_app;

our @VACATION_KEEP_KINDS = qw(budgets routines notifications);

# Security, calls and access are kept by default. They are also the notices a
# house still wants to hear while nobody is home, so they belong on the card even
# before anyone has saved a notification setting.
our @VACATION_KEEP_NOTICES = qw(security customs phone access gate box_office);

# The three lists, normalized. A missing or malformed setting reads as the
# defaults, never as an error.
sub vacation_keep_lists {
	my $data = &subs::vacation_settings();
	my $keep = $data->{'policy'}->{'keep_apps'};
	$keep = {} unless ref $keep eq 'HASH';
	return {
		budgets => [ @{ (ref $keep->{'budgets'} eq 'ARRAY' ? $keep->{'budgets'} : []) } ],
		routines => [ @{ (ref $keep->{'routines'} eq 'ARRAY' ? $keep->{'routines'} : []) } ],
		notifications => [ @{ (ref $keep->{'notifications'} eq 'ARRAY' ? $keep->{'notifications'} : []) } ],
	};
}

sub _vacation_keep_president {
	my $app = $vacation_app;
	return (defined $app && length $app) ? $app : '__president';
}

# The distinct app names one SQL statement offers, in insertion-safe order.
# A fresh or empty database has no table a query can use, so an eval keeps that
# a quiet empty list rather than a dead card.
sub _vacation_keep_apps {
	my ($sql, @bind) = @_;
	my $rows = eval { &subs::db_raw($sql, @bind) };
	$rows = [] unless ref $rows eq 'ARRAY';
	my $president = &_vacation_keep_president();
	my %seen;
	my @apps;
	foreach my $row (@{$rows}) {
		my $app = $row->{'app'};
		next unless defined $app && !ref $app && length $app;
		next if $app eq $president;
		next if $seen{$app}++;
		push @apps, $app;
	}
	return \@apps;
}

# The apps the card offers for one kind: the budgets, routines or notices the
# house already knows about. Sorted by the raw name; the card sorts by the name a
# person reads.
sub vacation_keep_candidates {
	my ($kind) = @_;
	$kind = '' unless defined $kind;
	return [] unless grep { $_ eq $kind } @VACATION_KEEP_KINDS;
	my $president = &_vacation_keep_president();
	my @apps;
	if ($kind eq 'budgets') {
		@apps = @{ &_vacation_keep_apps(
			'select distinct app from settings where setting = ? and value is not null and app is not null and app != ?',
			'budget', '',
		) };
	}
	elsif ($kind eq 'routines') {
		my %seen;
		my @rows = (
			@{ &_vacation_keep_apps(
				"select distinct app from appointments where source = 'schedule' and app is not null and app != ?",
				'',
			) },
			@{ &_vacation_keep_apps(
				'select distinct app from settings where setting = ? and value is not null and app is not null and app != ?',
				'tasks', '',
			) },
		);
		foreach my $app (@rows) {
			next if $app eq $president;
			next if $seen{$app}++;
			push @apps, $app;
		}
	}
	elsif ($kind eq 'notifications') {
		@apps = @{ &_vacation_keep_apps(
			"select distinct app from settings where setting = 'notification' and value = 'on' and app is not null and app != ?",
			'',
		) };
		my %seen = map { $_ => 1 } @apps;
		foreach my $app (@VACATION_KEEP_NOTICES) {
			next if $seen{$app}++;
			push @apps, $app;
		}
	}
	@apps = sort { $a cmp $b } grep { defined $_ && length $_ && $_ ne $president } @apps;
	return \@apps;
}

# Put an app into or out of one keep list. The person's choice is saved through
# the vacation setting, so the budget, alarm and notification readers see it on
# their next call. Returns the new lists, or undef when the request is refused.
sub vacation_keep_toggle {
	my ($app, $kind, $on) = @_;
	$kind = '' unless defined $kind;
	return undef unless grep { $_ eq $kind } @VACATION_KEEP_KINDS;
	return undef unless defined $app && !ref $app && length $app;
	return undef if $app eq &_vacation_keep_president();
	my $want = (defined $on && $on =~ /^(?:on|1|true|yes)$/i) ? 1 : 0;
	my $data = &subs::vacation_settings();
	$data->{'policy'} = {} unless ref $data->{'policy'} eq 'HASH';
	my $keep = $data->{'policy'}->{'keep_apps'};
	$keep = $data->{'policy'}->{'keep_apps'} = {} unless ref $keep eq 'HASH';
	my @list = grep { defined $_ && length $_ && $_ ne $app }
		@{ (ref $keep->{$kind} eq 'ARRAY' ? $keep->{$kind} : []) };
	push @list, $app if $want;
	$keep->{$kind} = \@list;
	&subs::vacation_save($data);
	return &vacation_keep_lists();
}

# Every app the card should show, once, with the checkbox state for each kind.
# The union matters: an app that is kept but is no longer a candidate must still
# be visible, or it could never be unticked.
sub vacation_keep_rows {
	my $lists = &vacation_keep_lists();
	my %kept;
	my %seen;
	my @rows;
	foreach my $kind (@VACATION_KEEP_KINDS) {
		$kept{$kind} = { map { $_ => 1 } @{ $lists->{$kind} || [] } };
	}
	foreach my $kind (@VACATION_KEEP_KINDS) {
		foreach my $app (@{ &vacation_keep_candidates($kind) }, @{ $lists->{$kind} || [] }) {
			next unless defined $app && !ref $app && length $app;
			next if $seen{$app}++;
			push @rows, {
				app => $app,
				formatted_name => &subs::format_name($app),
				budgets => ($kept{'budgets'}->{$app} ? 1 : 0),
				routines => ($kept{'routines'}->{$app} ? 1 : 0),
				notifications => ($kept{'notifications'}->{$app} ? 1 : 0),
			};
		}
	}
	@rows = sort {
		$a->{'formatted_name'} cmp $b->{'formatted_name'}
			|| $a->{'app'} cmp $b->{'app'}
	} @rows;
	return \@rows;
}

1;
