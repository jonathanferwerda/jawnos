#!/usr/bin/perl
# model_duplicates.pl - merge catalogue rows that name the same thing twice.
#
# A catalogue row is a model or an option: the entries an app's picker lists.
# Register's Add minted a fresh uuid on every press and the sync rail merges
# rows by uuid, so entering the same entry again (on a machine that had not
# synced the first, or simply a second time) left two rows with the same app and
# name and nothing ever joined them. The picker then showed the name twice.
#
# An option name is unique only inside its option category: two "regular" sizes
# in different categories are two real options, so the category is part of the
# key for an option row. A model needs no such key.
#
# This tool finds every duplicate key, keeps the row the records point at and
# that carries a configuration, repoints the records that name a loser, and
# tombstones then deletes the losers so every peer drops them too. A bare SQL
# delete would be undone by the next pull: the deletion travels on the sync rail.
#
#   perl scripts/model_duplicates.pl                       dry run, every app
#   perl scripts/model_duplicates.pl --app news            dry run, one app
#   perl scripts/model_duplicates.pl --app news --apply    merge that app
#   perl scripts/model_duplicates.pl --apply --yes         merge every app
#
# --app may be repeated or comma separated. A pair is left for a person when the
# row it would drop carries a behaviour flag the kept row does not (save_app, a
# default, a schedule or a delay); --force overrides that refusal. --database
# and --no-backup exist for QA against a scratch database: the live run takes a
# backup before it writes anything.
#
# The kept row is the one with the most appointments naming it, then the most
# settings, then the newest stamp. Every write moves server_time forward, so the
# repoint and the tombstone win the peer merge instead of the stale row.

use strict;
use warnings;

use FindBin qw($Bin);
use Cwd qw(abs_path);
use DBI;
use File::Basename qw(dirname);
use JSON::PP ();
use File::Path qw(make_path);
use POSIX qw(strftime);

our @TABLES = qw(model option);

my ($apply, $no_backup, $yes, $force, $database, @apps) = (0, 0, 0, 0, '', ());

for (my $i = 0; $i < @ARGV; $i++) {
	my $a = $ARGV[$i];
	if ($a eq '--apply')          { $apply = 1 }
	elsif ($a eq '--no-backup')   { $no_backup = 1 }
	elsif ($a eq '--yes')         { $yes = 1 }
	elsif ($a eq '--force')       { $force = 1 }
	elsif ($a eq '--help' || $a eq '-h') {
		print "usage: $0 [--apply] [--yes] [--force] [--app NAME[,NAME]] [--database PATH] [--no-backup]\n";
		exit 0;
	}
	elsif ($a =~ /^--database=(.+)$/) { $database = $1 }
	elsif ($a eq '--database' && defined $ARGV[$i + 1]) { $database = $ARGV[++$i] }
	elsif ($a =~ /^--app=(.+)$/) { push @apps, grep { length } split /,/, $1 }
	elsif ($a eq '--app' && defined $ARGV[$i + 1]) { push @apps, grep { length } split /,/, $ARGV[++$i] }
	else { die "unknown argument: $a\n" }
}

my $root = abs_path("$Bin/..");
$database ||= "$root/database/jawnos.db";
die "no database at $database\n" unless -f $database;
$database = abs_path($database);

my $json = JSON::PP->new->utf8->allow_nonref;
my $dbh = DBI->connect("dbi:SQLite:dbname=$database", '', '', {
	RaiseError => 1,
	PrintError => 0,
	AutoCommit => 1,
	sqlite_busy_timeout => 15000,
	sqlite_unicode => 1,
});

sub has_table {
	my ($table) = @_;
	return $dbh->selectrow_array("select 1 from sqlite_master where type = 'table' and name = ?", undef, $table) ? 1 : 0;
}

die "no model table at $database\n" unless has_table('model');
die "no sync_log table; refusing to delete without a tombstone\n" if $apply && !has_table('sync_log');

sub signatorial {
	# The identity beside the database being changed, not beside the checkout the
	# tool happens to run from: a worktree has an identity of its own, and a
	# tombstone signed with it would name a machine that is not the one deleting.
	my @files = (
		dirname($database) . '/.jawnos_signatorial_id',
		"$root/database/.jawnos_signatorial_id",
		(defined $ENV{'HOME'} && length $ENV{'HOME'} ? "$ENV{'HOME'}/.jawnos_signatorial_id" : ()),
	);
	my %seen;
	for my $file ( grep { defined $_ && !$seen{$_}++ } @files ) {
		next unless defined $file && -f $file;
		open(my $fh, '<', $file) or next;
		my $id = <$fh>;
		close $fh;
		next unless defined $id;
		$id =~ s/\s+//g;
		return $id if $id =~ /^[0-9a-f]{16,64}$/i;
	}
	return '';
}

sub when {
	my ($ms) = @_;
	return '-' unless defined $ms && $ms =~ /^\d+$/;
	return strftime('%Y-%m-%d %H:%M UTC', gmtime(int($ms / 1000)));
}

# An option row names its category in `characteristics`; that value is what
# keeps two same-named options in different categories apart.
sub option_category {
	my ($raw) = @_;
	my $chars = eval { $json->decode($raw // '') };
	return '' unless ref $chars eq 'ARRAY';
	for my $c ( @{$chars} ) {
		next unless ref $c eq 'HASH';
		return ($c->{'value'} // '') if ($c->{'name'} // '') eq 'option_category';
	}
	return '';
}

my %category_name;
if (has_table('option_category')) {
	my $cats = $dbh->selectall_arrayref('select uuid, name from option_category', { Slice => {} });
	for my $cat ( @{$cats} ) {
		next unless defined $cat->{'uuid'};
		$category_name{$cat->{'uuid'}} = $cat->{'name'} if defined $cat->{'name'};
	}
}

sub category_label {
	my ($uuid) = @_;
	return '' unless defined $uuid && length $uuid;
	return $category_name{$uuid} // substr($uuid, 0, 8) . '...';
}

my (%refs, %ref_hits);

# Fields a row carries only when somebody configured them. A value field with a
# different value on the loser is a choice, not a loss; these are the ones whose
# disappearance changes what the catalogue does.
sub flag_names {
	my ($r) = @_;
	my @names;
	for my $k ( qw/save_app def/ ) {
		push @names, $k if ($r->{$k} // '') eq 'on';
	}
	for my $k ( qw/def_month def_day def_hour def_wday delay_start delay_stop/ ) {
		my $v = $r->{$k};
		next unless defined $v && length $v;
		next if $v eq '[]' || $v eq '{}';
		push @names, $k;
	}
	return @names;
}

sub value_names {
	my ($r) = @_;
	my @names;
	for my $k ( qw/unit price cost discount markup description manufacturer characteristics file files quantity/ ) {
		my $v = $r->{$k};
		next unless defined $v && length $v;
		next if $v eq '[]' || $v eq '{}';
		push @names, $k;
	}
	return @names;
}

sub configured {
	my ($r) = @_;
	return scalar flag_names($r) + scalar value_names($r);
}

sub row_line {
	my ($r) = @_;
	my $refs = $refs{$r->{'uuid'}} || 0;
	my @config = (flag_names($r), value_names($r));
	return sprintf('%s %-7s refs=%-4d config=%-2d %s',
		substr($r->{'uuid'} // '', 0, 10) . '...',
		($r->{'def'} // '') eq 'on' ? 'DEFAULT' : '',
		$refs, scalar @config,
		scalar @config ? join(',', @config) : '(none)');
}

sub add_hit {
	my ($uuid, $rowid, $field, $index) = @_;
	return unless defined $uuid && length $uuid;
	$refs{$uuid}++;
	push @{$ref_hits{$uuid}}, { rowid => $rowid, field => $field, index => $index };
}

sub pick_keep {
	my @rows = @_;
	@rows = sort {
		($refs{$b->{'uuid'}} || 0) <=> ($refs{$a->{'uuid'}} || 0)
		|| configured($b) <=> configured($a)
		|| (0 + ($b->{'timestamp'} || 0)) <=> (0 + ($a->{'timestamp'} || 0))
		|| (0 + ($b->{'ost'} || 0)) <=> (0 + ($a->{'ost'} || 0))
		|| 0 + ($b->{'rowid'} || 0) <=> 0 + ($a->{'rowid'} || 0)
	} @rows;
	return $rows[0];
}

# A behaviour flag the row to drop carries and the kept row does not would vanish
# with it, so that pair is left for a person unless --force says otherwise.
sub lost_config {
	my ($keep, $drop) = @_;
	my @lost;
	for my $k ( flag_names($drop) ) {
		push @lost, $k unless grep { $_ eq $k } flag_names($keep);
	}
	return @lost;
}

my @rows;
for my $t ( @TABLES ) {
	my $rs = $dbh->selectall_arrayref(
		"select rowid as rowid, app, name, uuid, timestamp, server_time, ost,
		        save_app, unit, def, def_month, def_day, def_hour, def_wday,
		        delay_start, delay_stop, price, cost, discount, markup,
		        description, manufacturer, characteristics, file, files, quantity
		 from $t
		 where name is not null and name != ''
		 order by app, name, cast(ost as integer), rowid",
		{ Slice => {} },
	);
	for my $r ( @{$rs} ) {
		$r->{'table'} = $t;
		$r->{'category'} = ($t eq 'option') ? option_category($r->{'characteristics'}) : '';
		push @rows, $r;
	}
}

my %group;
for my $r ( @rows ) {
	next if scalar @apps && !grep { $_ eq ($r->{'app'} // '') } @apps;
	my $key = join("\0", $r->{'table'}, $r->{'app'} // '', $r->{'name'} // '', $r->{'category'} // '');
	push @{$group{$key}}, $r;
}
my @keys = grep { scalar @{$group{$_}} > 1 } sort keys %group;

if (has_table('appointments')) {
	my $appts = $dbh->selectall_arrayref(
		q{select rowid as rowid, model, option, options from appointments
		  where coalesce(model, '') != '' or coalesce(option, '') != '' or coalesce(options, '') != ''},
		{ Slice => {} },
	);
	for my $a ( @{$appts} ) {
		my $m = eval { $json->decode($a->{'model'} // '') };
		add_hit(($m->{'uuid'} // ''), $a->{'rowid'}, 'model') if ref $m eq 'HASH';
		my $o = eval { $json->decode($a->{'option'} // '') };
		add_hit(($o->{'uuid'} // ''), $a->{'rowid'}, 'option') if ref $o eq 'HASH';
		my $os = eval { $json->decode($a->{'options'} // '') };
		if (ref $os eq 'ARRAY') {
			for my $i ( 0 .. $#{$os} ) {
				next unless ref $os->[$i] eq 'HASH';
				add_hit(($os->[$i]->{'uuid'} // ''), $a->{'rowid'}, 'options', $i);
			}
		}
	}
}

my @plan;
for my $key ( @keys ) {
	my @candidates = @{$group{$key}};
	my ($table, $app, $name, $category) = split /\0/, $key, 4;
	my $keep = pick_keep(@candidates);
	my @drop = grep { $_->{'uuid'} ne $keep->{'uuid'} } @candidates;
	push @plan, {
		table => $table, app => $app, name => $name, category => $category,
		keep => $keep, drop => \@drop,
	};
}

print "catalogue duplicates";
print ' for ' . join(', ', @apps) if scalar @apps;
print ': ' . scalar(@plan) . " group(s)\n";
for my $g ( @plan ) {
	my $label = "$g->{'app'}/$g->{'name'}";
	$label .= ' [' . category_label($g->{'category'}) . ']' if $g->{'table'} eq 'option';
	print "\n$g->{'table'} $label\n";
	print '  keep ' . row_line($g->{'keep'}) . '  ' . when($g->{'keep'}->{'timestamp'} || $g->{'keep'}->{'ost'}) . "\n";
	for my $lose ( @{$g->{'drop'}} ) {
		my @lost = lost_config($g->{'keep'}, $lose);
		print '  drop ' . row_line($lose) . '  ' . when($lose->{'timestamp'} || $lose->{'ost'}) . "\n";
		if (scalar @lost) {
			print '       carries ' . join(',', @lost) . " only on this row - left for a person, or merged with --force\n";
		}
		print '       repoints ' . scalar(@{$ref_hits{$lose->{'uuid'}} || []}) . " record(s), then tombstones and deletes\n" unless scalar(@lost) && !$force;
	}
}

unless ($apply) {
	print "\ndry run: nothing changed. Re-run with --apply (and --app NAME to limit it).\n";
	exit 0;
}

if (!scalar @apps && !$yes) {
	print "\nrefusing to apply every app at once; name --app or pass --yes\n";
	exit 1;
}

unless ($no_backup) {
	my $stamp = strftime('%Y%m%d-%H%M%S', localtime);
	my $dir = "$root/database/backups";
	make_path($dir) unless -d $dir;
	my $backup = "$dir/model_duplicates_$stamp.db";
	my $ok = eval { $dbh->sqlite_backup_to_file($backup); 1 };
	die "backup failed: $@\n" unless $ok;
	my $size = -s $backup || 0;
	die "backup is only $size bytes; refusing to write\n" unless $size > 1_000_000;
	print "\nbackup: $backup ($size bytes)\n";
}

my $now = 0 + int(time() * 1000);
my $sign = signatorial();
my ($deleted, $repointed, $skipped) = (0, 0, 0);
my $remote = has_table('remote_machines')
	? $dbh->selectall_arrayref('select rowid as rowid, deletions from remote_machines', { Slice => {} })
	: [];

sub repoint_record {
	my ($hit, $old, $new, $stamp) = @_;
	my ($model, $option, $options) = $dbh->selectrow_array(
		'select model, option, options from appointments where rowid = ?', undef, $hit->{'rowid'},
	);
	if ($hit->{'field'} eq 'model') {
		my $j = eval { $json->decode($model // '') };
		return 0 unless ref $j eq 'HASH' && ($j->{'uuid'} // '') eq $old;
		$j->{'uuid'} = $new;
		$dbh->do('update appointments set model = ?, server_time = ? where rowid = ?', undef, $json->encode($j), $stamp, $hit->{'rowid'});
		return 1;
	}
	if ($hit->{'field'} eq 'option') {
		my $j = eval { $json->decode($option // '') };
		return 0 unless ref $j eq 'HASH' && ($j->{'uuid'} // '') eq $old;
		$j->{'uuid'} = $new;
		$dbh->do('update appointments set option = ?, server_time = ? where rowid = ?', undef, $json->encode($j), $stamp, $hit->{'rowid'});
		return 1;
	}
	if ($hit->{'field'} eq 'options') {
		my $arr = eval { $json->decode($options // '') };
		return 0 unless ref $arr eq 'ARRAY' && defined $hit->{'index'};
		my $entry = $arr->[$hit->{'index'}];
		return 0 unless ref $entry eq 'HASH' && ($entry->{'uuid'} // '') eq $old;
		$entry->{'uuid'} = $new;
		$dbh->do('update appointments set options = ?, server_time = ? where rowid = ?', undef, $json->encode($arr), $stamp, $hit->{'rowid'});
		return 1;
	}
	return 0;
}

$dbh->begin_work;
eval {
	for my $g ( @plan ) {
		my $keep = $g->{'keep'};
		for my $lose ( @{$g->{'drop'}} ) {
			my $u = $lose->{'uuid'};
			my @lost = lost_config($keep, $lose);
			if (scalar @lost && !$force) {
				$skipped++;
				print "\n$g->{'table'} $g->{'app'}/$g->{'name'}: left $u in place (carries " . join(',', @lost) . ")\n";
				next;
			}
			# Anything naming the loser outside the fields the tool rewrites would
			# be left pointing at a deleted row; refuse that loser and name it.
			my @outside;
			if (has_table('appointments')) {
				my @cols = ($g->{'table'} eq 'model') ? qw/item option options/ : qw/item/;
				for my $col ( @cols ) {
					my $c = $dbh->selectrow_array("select count(*) from appointments where $col like ?", undef, '%' . $u . '%') || 0;
					push @outside, "appointments.$col ($c)" if $c;
				}
			}
			if (has_table('warehouse')) {
				for my $col ( qw/model options/ ) {
					my $c = $dbh->selectrow_array("select count(*) from warehouse where $col like ?", undef, '%' . $u . '%') || 0;
					push @outside, "warehouse.$col ($c)" if $c;
				}
			}
			for my $t ( @TABLES ) {
				my $c = $dbh->selectrow_array(
					"select count(*) from $t where uuid != ? and (characteristics like ? or files like ? or coalesce(file, '') like ?)",
					undef, $u, '%' . $u . '%', '%' . $u . '%', '%' . $u . '%',
				) || 0;
				push @outside, "$t characteristics/files ($c)" if $c;
			}
			if (scalar @outside) {
				$skipped++;
				print "\n$g->{'table'} $g->{'app'}/$g->{'name'}: left $u in place (named by " . join(', ', @outside) . ")\n";
				next;
			}
			for my $hit ( @{$ref_hits{$u} || []} ) {
				$repointed++ if repoint_record($hit, $u, $keep->{'uuid'}, $now);
			}
			$dbh->do(
				'insert into sync_log (server_time, signatorial, tbl, app, uuid, scope) values (?,?,?,?,?,?)',
				undef, $now, $sign, $g->{'table'}, $g->{'app'}, $u, 'single',
			);
			for my $rm ( @{$remote} ) {
				my $dels = eval { $json->decode($rm->{'deletions'} || '[]') } || [];
				push @{$dels}, {
					table => $g->{'table'},
					app => $g->{'app'},
					uuid => $u,
					scope => 'single',
					initialization => $now,
					server_time => $now,
				};
				my $queued = $json->encode($dels);
				$dbh->do('update remote_machines set deletions = ? where rowid = ?', undef, $queued, $rm->{'rowid'});
				$rm->{'deletions'} = $queued;
			}
			$dbh->do("delete from $g->{'table'} where uuid = ?", undef, $u);
			$deleted++;
		}
	}
	$dbh->commit;
	1;
} or do {
	my $err = $@;
	eval { $dbh->rollback };
	die "rolled back: $err\n";
};

print sprintf("\nremoved %d row(s), repointed %d record(s), left %d row(s) in place\n",
	$deleted, $repointed, $skipped);

my $check = $dbh->selectrow_array('pragma integrity_check') || '';
die "integrity check failed: $check\n" unless $check eq 'ok';
print "integrity: ok\n";
