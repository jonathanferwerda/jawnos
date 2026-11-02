package QaSetting;

# The house settings the QA nightlies read, and the one clamp they share.
#
# Configure -> Plat -> QA writes `__president/qa_note_limit` and
# `__president/qa_coding_agent`; qa/ux/run and qa/coding_night/run.pl read the
# same rows here, without booting the app or the domain layer. Every live read
# uses a `mode=ro` SQLite URI, so a nightly can never write the house database.
#
# The clamp is the contract: 1..25, default 3. It is duplicated in
# lib/JawnOS/Domain/Remote.pm for the panel's server-side check (that file is
# the app, this one is the fence); t/88 asserts both answers match.

use strict;
use warnings;

use File::Spec;

our $VERSION = '1';

our $NOTE_LIMIT_DEFAULT = 3;
our $NOTE_LIMIT_MIN     = 1;
our $NOTE_LIMIT_MAX     = 25;

sub note_limit_default { return $NOTE_LIMIT_DEFAULT }
sub note_limit_min     { return $NOTE_LIMIT_MIN }
sub note_limit_max     { return $NOTE_LIMIT_MAX }

# A value the panel or the command line holds, made safe for a query and a
# loop. Non-numeric is the default, not a guess; a number is clamped, never
# multiplied into a range.
sub clamp_note_limit {
	my ($value) = @_;
	return $NOTE_LIMIT_DEFAULT
		unless defined $value && $value =~ /^\s*[+-]?\d+\s*$/;
	my $n = int($value);
	return $NOTE_LIMIT_MIN if $n < $NOTE_LIMIT_MIN;
	return $NOTE_LIMIT_MAX if $n > $NOTE_LIMIT_MAX;
	return $n;
}

sub ro_uri {
	my ($db) = @_;
	my $abs = File::Spec->rel2abs($db);
	return "file:$abs?mode=ro";
}

sub _read {
	my ($cmd) = @_;
	open(my $fh, '-|', @{$cmd}) or return '';
	local $/;
	my $out = <$fh> // '';
	close $fh;
	return $out;
}

# Rows as Perl hashes. `allow_error` keeps a missing table (a fresh database
# with no settings rows yet) from killing a dry run.
sub sqlite_json {
	my ($db, $sql, %opt) = @_;
	my $out = _read(['sqlite3', '-json', '-cmd', '.timeout 5000', ro_uri($db), $sql]);
	my $rows = length $out ? eval { require JSON::PP; JSON::PP->new->utf8->decode($out) } : [];
	return $rows if ref $rows eq 'ARRAY';
	return [] if $opt{'allow_error'};
	die "QaSetting: sqlite3 returned unreadable JSON: $@\n";
}

sub sql_quote {
	my ($value) = @_;
	$value = '' unless defined $value;
	$value =~ s/'/''/g;
	return "'$value'";
}

# A house setting, preferring the house row (device 'all') over a per-device
# one, the same order qa/device_target.pl uses. '' when there is no row.
sub read_setting {
	my ($db, $setting) = @_;
	return '' unless defined $db && -f $db;
	my $sql = "select value from settings"
		. " where app = '__president' and setting = " . sql_quote($setting)
		. " order by case when device = 'all' then 0 else 1 end,"
		. " cast(server_time as integer) desc limit 1";
	my $rows = sqlite_json($db, $sql, allow_error => 1);
	return '' unless ref $rows eq 'ARRAY' && @{$rows};
	my $value = $rows->[0]->{'value'} // '';
	$value =~ s/^\s+|\s+$//g;
	return $value;
}

sub read_note_limit {
	my ($db) = @_;
	return clamp_note_limit( read_setting($db, 'qa_note_limit') );
}

sub read_coding_agent {
	my ($db) = @_;
	return read_setting($db, 'qa_coding_agent');
}

1;
