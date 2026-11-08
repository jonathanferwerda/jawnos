package QaSetting;

# The house settings the QA nightlies read, and the one clamp they share.
#
# Configure -> Plat -> QA writes `__president/qa_note_limit`,
# `__president/qa_coding_agent`, `__president/qa_ux_model` and the three
# nightly times (`qa_night_time`, `qa_ux_time`, `qa_coding_time`); qa/ux/run and
# qa/coding_night/run.pl read the same rows here, without booting the app or the
# domain layer. Every live read uses a `mode=ro` SQLite URI, so a nightly can
# never write the house database.
#
# The clamp is the contract: 1..25, default 3, and a time is `HH:MM` between
# 00:00 and 23:59 or it is rejected. Both are duplicated in
# lib/JawnOS/Domain/Remote.pm for the panel's server-side check (that file is
# the app, this one is the fence); t/88 and t/90 assert both answers match.

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

# `__president/qa_ux_model`: the model the 05:30 UX loop judges with. The
# coding night reads Configure -> Platform -> Coding (mail/coding_assistant);
# this is the UX loop's own choice, so changing the night's model cannot move
# the Guide's evaluation role. '' means no model: the loop skips, never passes.
sub read_ux_model {
	my ($db) = @_;
	return read_setting($db, 'qa_ux_model');
}

# --- what the coding night works on ----------------------------------------
# `__president/qa_coding_lanes`: a comma list of the sources the 06:00 night
# draws work from. `notes` is the original queue; `security` takes the new
# high findings from the nightly audit's report and `installers` takes the
# packages the installer check reports missing. Canonical order, unknown names
# dropped, and an empty value reads as the default (notes) - the panel refuses
# to store an empty choice, so a night never silently has nothing to do.
our @CODING_LANES = qw(notes security installers);

sub coding_lanes { return @CODING_LANES }
sub coding_lanes_default { return 'notes' }

sub clamp_coding_lanes {
	my ($value) = @_;
	my @asked = ref $value eq 'ARRAY'
		? @{$value}
		: split /[\s,]+/, (defined $value ? $value : '');
	# keep the canonical order, not the order the caller sent
	my %on = map { $_ => 1 } @asked;
	my @out = grep { $on{$_} } @CODING_LANES;
	return @out ? @out : (coding_lanes_default());
}

sub read_coding_lanes {
	my ($db) = @_;
	return clamp_coding_lanes( read_setting($db, 'qa_coding_lanes') );
}

# The three nightly times, in HH:MM. They are house settings (device 'all') and
# the panel validates them; this reader is the fenced copy, so a script that has
# no app can still answer with the same rules. Anything that is not 00:00-23:59
# reads as the default: a bad row never becomes an unreadable timer.
our %NIGHT_TIME_DEFAULT = (
	qa_night_time  => '05:00',
	qa_ux_time     => '05:30',
	qa_coding_time => '06:00',
);

sub night_time_default {
	my ($setting) = @_;
	return $NIGHT_TIME_DEFAULT{$setting} // '';
}

sub clamp_time {
	my ($value) = @_;
	return '' unless defined $value;
	$value =~ s/^\s+//;
	$value =~ s/\s+$//;
	return '' unless $value =~ /^(\d{1,2}):(\d{2})$/;
	my ( $hour, $minute ) = ( $1 + 0, $2 + 0 );
	return '' if $hour > 23 || $minute > 59;
	return sprintf('%02d:%02d', $hour, $minute);
}

sub read_night_time {
	my ($db, $setting) = @_;
	my $clean = clamp_time( read_setting( $db, $setting ) );
	return length $clean ? $clean : night_time_default($setting);
}

1;
