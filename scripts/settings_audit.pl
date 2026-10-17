#!/usr/bin/perl
# settings_audit.pl - compare the live settings table with a sealed snapshot.
#
#   perl scripts/settings_audit.pl --list
#   perl scripts/settings_audit.pl [--backup <path>] [--setting pos,mab] [--app a,b]
#                                  [--contains word] [--all] [--limit N] [--json]
#   perl scripts/settings_audit.pl --setting pos,mab --apply
#
# The sync can trade a local value for a peer's older one (a backdated row, or a
# row whose server_time was newer than the value it carried). This shows every
# settings row whose value differs from a snapshot, with both write times, and
# - with --apply - puts the snapshot's value back stamped with the current time,
# so every machine takes it on the next sync.
#
# Defaults to durable settings only (window geometry, open tabs, door state and
# other churn are left out), and to a dry run. Nothing is written without
# --apply, and --apply takes a fresh safety snapshot first.
use strict;
use warnings;
use FindBin;
require Mojo::JSON;
chdir "$FindBin::Bin/.." or die "cannot find the jawnos root: $!";
require './subroutines.pl';

my ($backup, $json, $apply, $list, $all, $limit, $yes, $setting_like, $no_limit);
my (@settings, @apps, $contains);
$limit = 100;
for (my $i = 0; $i < @ARGV; $i++) {
	my $a = $ARGV[$i];
	$backup = $ARGV[$i + 1] if $a eq '--backup' && defined $ARGV[$i + 1];
	$json = 1 if $a eq '--json';
	$apply = 1 if $a eq '--apply';
	$list = 1 if $a eq '--list';
	$all = 1 if $a eq '--all';
	$yes = 1 if $a eq '--yes';
	$no_limit = 1 if $a eq '--no-limit';
	$setting_like = 1 if $a eq '--setting-like';
	@settings = grep { length } split /,/, $ARGV[$i + 1] if $a eq '--setting' && defined $ARGV[$i + 1];
	@apps = grep { length } split /,/, $ARGV[$i + 1] if $a eq '--app' && defined $ARGV[$i + 1];
	$contains = $ARGV[$i + 1] if $a eq '--contains' && defined $ARGV[$i + 1];
	$limit = $ARGV[$i + 1] if $a eq '--limit' && defined $ARGV[$i + 1] && $ARGV[$i + 1] =~ /^\d+$/;
}

my @snapshots = sort {
	my ($b1) = $b =~ /jawnos_(\d+)\.enc$/;
	my ($a1) = $a =~ /jawnos_(\d+)\.enc$/;
	($b1 || 0) <=> ($a1 || 0);
} glob(&subs::backups_dir() . '/jawnos_*.enc');

if ($list) {
	print "settings audit - snapshots in " . &subs::backups_dir() . "\n\n";
	foreach my $s ( @snapshots ) {
		my ($ms) = $s =~ /jawnos_(\d+)\.enc$/;
		printf "%-48s %s  %.1f MB\n", $s, &subs::iso_local($ms), (-s $s) / 1048576;
	}
	exit 0;
}

$backup ||= $snapshots[0];
unless ($backup && -e $backup) {
	print "settings audit: there is no snapshot to compare against (run --list)\n";
	exit 1;
}

my ($snap_ms) = $backup =~ /jawnos_(\d+)\.enc$/;
$snap_ms = (stat($backup))[9] * 1000 unless $snap_ms;

# The snapshot is a separate SQLite file; the durable filter is the same SQL the
# sync trigger uses, so the audit does not drown in window state.
my $where = $all ? '' : ' where ' . &subs::durable_settings_where();
my $old_db = &subs::records_backup_decrypt($backup);
unless ($old_db) {
	print "settings audit: could not unseal $backup (key or format)\n";
	exit 1;
}
my $old = eval { Mojo::SQLite->new('sqlite:' . $old_db)->db->query('select app,setting,subsetting,device,value,server_time,uuid from settings' . $where . ' order by cast(server_time as integer) asc')->hashes };
unless ($old) {
	print "settings audit: could not read the snapshot's settings\n";
	unlink $old_db;
	exit 1;
}
my $live = eval { &subs::db_query('select app,setting,subsetting,device,value,server_time,uuid from settings' . $where . ' order by cast(server_time as integer) asc')->hashes };
unless ($live) {
	print "settings audit: could not read the live settings\n";
	unlink $old_db;
	exit 1;
}

my $key = sub {
	my ($r) = @_;
	return join "\x1f", map { defined $_ ? $_ : '' } ($r->{'app'}, $r->{'setting'}, $r->{'device'}, $r->{'subsetting'});
};
my (%old, %new);
# The table still holds older duplicate rows for some keys (the pre-NULL-safe
# writes left them). The effective value is the newest row, so let the newest
# one win the hash; otherwise an old duplicate would look like a live value.
$old{ $key->($_) } = $_ foreach @{$old};
$new{ $key->($_) } = $_ foreach @{$live};

my $matches = sub {
	my ($r) = @_;
	my $app = defined $r->{'app'} ? $r->{'app'} : '';
	my $setting = defined $r->{'setting'} ? $r->{'setting'} : '';
	return 0 if scalar @apps && !grep { lc($_) eq lc($app) } @apps;
	if (scalar @settings) {
		my $hit = grep { $setting_like ? index(lc($setting), lc($_)) >= 0 : lc($_) eq lc($setting) } @settings;
		return 0 unless $hit;
	}
	if (defined $contains && length $contains) {
		my $hay = join ' ', $app, $setting, (defined $r->{'subsetting'} ? $r->{'subsetting'} : '');
		return 0 unless index(lc($hay), lc($contains)) >= 0;
	}
	return 1;
};

my @changes;
foreach my $k ( sort keys %old ) {
	my $o = $old{$k};
	my $n = $new{$k};
	next unless $matches->($o);
	my $ov = defined $o->{'value'} ? $o->{'value'} : '';
	if (!$n) {
		push @changes, { status => 'dropped', old => $o, live => undef, setting => $o->{'setting'}, app => $o->{'app'} };
		next;
	}
	my $nv = defined $n->{'value'} ? $n->{'value'} : '';
	next if $ov eq $nv;
	my $os = 0 + ($o->{'server_time'} || 0);
	my $ns = 0 + ($n->{'server_time'} || 0);
	push @changes, {
		status => ($ns && $os && $ns < $os) ? 'backdated' : 'changed',
		old => $o, live => $n, setting => $o->{'setting'}, app => $o->{'app'},
	};
}
# A row the snapshot never held is new, not a loss; only list it with --all.
if ($all) {
	foreach my $k ( sort keys %new ) {
		next if $old{$k};
		next unless $matches->($new{$k});
		push @changes, { status => 'new', old => undef, live => $new{$k}, setting => $new{$k}->{'setting'}, app => $new{$k}->{'app'} };
	}
}
@changes = sort { ($a->{'app'} || '') cmp ($b->{'app'} || '') || ($a->{'setting'} || '') cmp ($b->{'setting'} || '') || ($a->{'old'}->{'subsetting'} // $a->{'live'}->{'subsetting'} // '') cmp ($b->{'old'}->{'subsetting'} // $b->{'live'}->{'subsetting'} // '') } @changes;

unlink $old_db;
unlink $old_db . '-wal';
unlink $old_db . '-shm';

if ($json && !$apply) {
	print Mojo::JSON::encode_json({
		backup => $backup, snapshot_time => $snap_ms,
		changes => [ map { _change_json($_) } @changes ],
	}), "\n";
	exit 0;
}

my %tally;
$tally{ $_->{'status'} }++ foreach @changes;
printf "settings audit - snapshot %s (%s)\n", $backup, &subs::iso_local($snap_ms);
printf "%d differing row(s): %d changed, %d backdated, %d dropped%s\n\n",
	scalar(@changes), ($tally{'changed'} || 0), ($tally{'backdated'} || 0), ($tally{'dropped'} || 0),
	($all ? ', ' . ($tally{'new'} || 0) . ' new' : '');
unless (scalar @changes) { print "nothing differs in the selected settings.\n"; exit 0; }

my $shown = 0;
foreach my $c ( @changes ) {
	last if !$no_limit && $limit && $shown >= $limit;
	$shown++;
	my $o = $c->{'old'};
	my $n = $c->{'live'};
	my $dev = ($n && defined $n->{'device'}) ? $n->{'device'} : ($o ? $o->{'device'} : '');
	my $sub = ($n && defined $n->{'subsetting'}) ? $n->{'subsetting'} : ($o ? $o->{'subsetting'} : '');
	printf "%-9s %s/%s%s%s\n", $c->{'status'}, ($c->{'app'} // ''), ($c->{'setting'} // ''),
		(defined $sub && length $sub ? '[' . $sub . ']' : ''),
		(defined $dev && length $dev ? ' @' . $dev : '');
	printf "          was: %s  (%s)\n", _short($o ? $o->{'value'} : undef), ($o ? &subs::iso_local($o->{'server_time'}) : '-');
	printf "          now: %s  (%s)\n", _short($n ? $n->{'value'} : undef), ($n ? &subs::iso_local($n->{'server_time'}) : '-');
}
printf "\n... %d more row(s); raise --limit or pass --no-limit\n", scalar(@changes) - $shown if $shown < scalar @changes;
print "\ndone - nothing written. Re-run with --apply (and a --setting/--app filter) to put the snapshot values back.\n" unless $apply;

if ($apply) {
	my $selected = scalar @changes;
	if (!$setting_like && !scalar @settings && !scalar @apps && !defined $contains && $selected > 20 && !$yes) {
		print "\nrefusing to restore $selected rows without a filter; name --setting, --app or --contains, or pass --yes\n";
		exit 1;
	}
	my $fresh = &subs::records_backup_ensure_fresh(600000);
	unless ($fresh->{'fresh'}) {
		print "\nrefusing to apply: no snapshot younger than ten minutes could be taken\n";
		exit 1;
	}
	print "\nsafety snapshot: " . ($fresh->{'made'} ? 'taken now - ' : 'using ') . $fresh->{'path'} . "\n";
	my ($restored, $failed) = (0, 0);
	foreach my $c ( @changes ) {
		my $o = $c->{'old'};
		next unless $o;   # a 'new' row is not something a restore can put back
		my $ok = eval {
			&subs::setting_setter({
				app => $o->{'app'},
				setting => $o->{'setting'},
				subsetting => $o->{'subsetting'},
				device => $o->{'device'},
				value => $o->{'value'},
				server_time => &subs::rightNow(),
			});
			1;
		};
		if ($ok) { $restored++; }
		else { $failed++; print "failed: " . ($o->{'app'} // '') . '/' . ($o->{'setting'} // '') . ": $@\n"; }
	}
	printf "settings audit APPLIED: %d restored, %d failed\n", $restored, $failed;
}

sub _change_json {
	my ($c) = @_;
	my $o = $c->{'old'};
	my $n = $c->{'live'};
	return {
		status => $c->{'status'},
		app => $c->{'app'}, setting => $c->{'setting'},
		subsetting => ($n && defined $n->{'subsetting'}) ? $n->{'subsetting'} : ($o ? $o->{'subsetting'} : undef),
		device => ($n && defined $n->{'device'}) ? $n->{'device'} : ($o ? $o->{'device'} : undef),
		old => ($o ? { value => $o->{'value'}, server_time => 0 + ($o->{'server_time'} || 0), uuid => $o->{'uuid'} } : undef),
		live => ($n ? { value => $n->{'value'}, server_time => 0 + ($n->{'server_time'} || 0), uuid => $n->{'uuid'} } : undef),
	};
}

sub _short {
	my ($v) = @_;
	return '(none)' unless defined $v;
	$v =~ s/\s+/ /g;
	return length($v) > 160 ? substr($v, 0, 157) . '...' : $v;
}
