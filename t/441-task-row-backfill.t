# tests-for: scripts/task_row_backfill.pl
# covers:    the dropped-completion repair - it finds only a completed entry
#           whose appointment is gone, writes it through the checkbox writer at
#           its own moment, links the session it was done in, and writes nothing
#           without --apply or on a re-run.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Mojo::JSON qw(decode_json encode_json);

my $root = "$FindBin::Bin/..";
require "$root/scripts/task_row_backfill.pl";

{
	package GapRows;
	sub new { my ($class, $rows) = @_; return bless { rows => $rows }, $class }
	sub hashes { return $_[0]->{'rows'} }
	sub hash { return $_[0]->{'rows'}[0] }
}

my $home = tempdir(CLEANUP => 1);
make_path("$home/.president");

my (%settings, %sessions, %pointer, %present);
my (@writes, @persisted);

{
	no warnings "redefine";
	no warnings "once";
	local *subs::rightNow = sub { return 1_800_000_000_000 };
	local *subs::home = sub {
		my ($p) = @_;
		$p =~ s{^~/}{};
		return "$home/$p";
	};
	local *subs::db_query = sub {
		my ($sql, @args) = @_;
		if ($sql =~ /from settings where setting = \?/) {
			return GapRows->new([ map { { app => $_, value => $settings{$_} } } sort keys %settings ]);
		}
		if ($sql =~ /where uuid = \?/) {
			my $u = $args[0] // '';
			return GapRows->new($pointer{$u} ? [ $pointer{$u} ] : []);
		}
		if ($sql =~ /source = 'task' and data like/) {
			my ($pattern) = @args;
			my ($u) = ($pattern // '') =~ /"task_uuid":"([^"]+)"/;
			return GapRows->new($present{$u} ? [ $present{$u} ] : []);
		}
		if ($sql =~ /from appointments/ && $sql =~ /where app = \?/ && $sql =~ /type in/) {
			return GapRows->new($sessions{ $args[0] } || []);
		}
		return GapRows->new([]);
	};
	local *subs::task_writer = sub {
		my ($c, $d) = @_;
		push @writes, { %{$d} };
		$pointer{ 'row-' . $d->{'uuid'} } = { uuid => 'row-' . $d->{'uuid'} };
		my $list = decode_json($settings{ $d->{'app'} });
		foreach my $e ( @{$list} ) {
			next unless ($e->{'uuid'} // '') eq ($d->{'uuid'} // '');
			$e->{'last_appt_uuid'} = 'row-' . $d->{'uuid'};
			$e->{'last_server_time'} = $d->{'server_time'};
		}
		return $list;
	};
	local *subs::setting_setter = sub {
		my ($req) = @_;
		push @persisted, { %{$req} };
		$settings{ $req->{'app'} } = $req->{'value'};
		return 1;
	};
	local *subs::setting_grabber = sub {
		my ($req) = @_;
		return $settings{ $req->{'app'} };
	};

	my $entry = sub {
		my (%o) = @_;
		return {
			uuid => $o{'uuid'}, task => $o{'task'},
			appt => $o{'appt'} // 'on',
			completed => $o{'completed'} // 'on',
			last_completed => $o{'last_completed'},
			colour => '#abc',
			%{ $o{'extra'} || {} },
		};
	};

	$settings{'shower'} = encode_json([
		$entry->(uuid => 'u1', task => 'getting_undressed', last_completed => 1_700_000_100_000),
		$entry->(uuid => 'u2', task => 'drying', last_completed => 1_700_000_200_000),
		$entry->(uuid => 'u3', task => 'off_task', completed => 'off', last_completed => 1_700_000_300_000),
		$entry->(uuid => 'u4', task => 'no_appt', appt => 'off', last_completed => 1_700_000_400_000),
		$entry->(uuid => 'u5', task => 'has_row', last_completed => 1_700_000_500_000,
			extra => { last_appt_uuid => 'kept-row' }),
		$entry->(uuid => 'u6', task => 'row_without_pointer', last_completed => 1_700_000_600_000),
	]);
	$pointer{'kept-row'} = { uuid => 'kept-row' };
	$present{'u6'} = { uuid => 'found-by-provenance', server_time => 1_700_000_650_000 };
	$pointer{'found-by-provenance'} = $present{'u6'};
	$sessions{'shower'} = [
		{ uuid => 'session-1', type => 'stop', timestamp => 1_700_000_050_000,
			stop_timestamp => 1_700_000_150_000, duration => 100_000,
			project => 'shower', account => '', movement => '' },
	];

	my ($rc, $out) = run_cli();
	is($rc, 0, 'the dry run exits clean');
	like($out, qr/dropped task completions: 3 across 1 list/, 'the two lost rows and the lost pointer are named');
	is(scalar @writes, 0, 'and nothing is written');
	is(scalar @persisted, 0, 'and no checklist is saved');

	@writes = ();
	@persisted = ();
	($rc, $out) = run_cli('--apply');
	is($rc, 0, '--apply exits clean');
	is(scalar @writes, 2, 'the two dropped completions are written');
	my %by = map { $_->{'uuid'} => $_ } @writes;
	is($by{'u1'}{'timestamp'}, 1_700_000_100_000, 'the row keeps the completion moment');
	is($by{'u1'}{'completed_at'}, 1_700_000_100_000, 'and the checklist is marked at that moment');
	is($by{'u1'}{'name'}, 'completed', 'the checkbox field is completed');
	is($by{'u1'}{'value'}, 'on', 'set on');
	is($by{'u1'}{'papp'}, 'shower', 'the list owner travels');
	like($out, qr/linked row_without_pointer .*found-by-provenance/, 'the lost pointer is linked without a second row');
	is($by{'u1'}{'parent_uuid'}, 'session-1', 'a completion inside a session links to it');
	ok(!defined $by{'u2'}{'parent_uuid'}, 'one after the session does not');
	ok($by{'u1'}{'quiet_child'}, 'the repair is quiet');
	is(scalar @persisted, 3, 'each list save is written, including the pointer repair');
	my %saved = map { $_->{'uuid'} => $_ } @{ decode_json($settings{'shower'}) };
	is($saved{'u1'}{'last_appt_uuid'}, 'row-u1', 'the checklist keeps the row it wrote');
	is($saved{'u2'}{'last_appt_uuid'}, 'row-u2', 'both dropped completions get a pointer');
	is($saved{'u3'}{'last_appt_uuid'}, undef, 'an off task is left alone');
	is($saved{'u4'}{'last_appt_uuid'}, undef, 'an appt-off task is left alone');
	is($saved{'u5'}{'last_appt_uuid'}, 'kept-row', 'an existing row keeps its pointer');
	is($saved{'u6'}{'last_appt_uuid'}, 'found-by-provenance', 'a row found by provenance gets its pointer back');

	@writes = ();
	@persisted = ();
	($rc, $out) = run_cli('--apply');
	is(scalar @writes, 0, 'a second pass writes nothing');
	like($out, qr/no dropped task completions found/, 'because no gap remains');
}

sub run_cli {
	my (@args) = @_;
	my $buf = '';
	open my $fh, '>', \$buf or die "capture: $!";
	my $rc;
	{
		local *STDOUT = $fh;
		$rc = main(@args);
	}
	close $fh;
	return ($rc, $buf);
}

done_testing();
