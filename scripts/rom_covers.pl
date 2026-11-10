#!/usr/bin/perl
# Fetch box art for the emulated shelf from the libretro thumbnails tree.
#
#   perl scripts/rom_covers.pl [--force] [--system=<id>]
#
# The manager calls this through `sudo -n`; it writes one JSON row to
# /run/jawnos-games/covers.json, which the shelf polls. The pure title and URL
# rules live in JawnOS::RomCovers, so this file owns only the network and the
# files:
#
#   * one listing per system and kind, cached for a week under ~/.cache;
#   * a cover stored as <roms>/<system>/images/<rom>.png, never over an existing
#     file unless --force;
#   * a pause between downloads, because the thumbnail host is a shared service.
#
# A run that cannot fetch five covers in a row stops and says which failure came
# first: a machine with no network should not spend a minute timing out.
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Digest::SHA qw(sha1_hex);
use File::Basename qw(basename dirname);
use File::Path qw(make_path);
use JSON::PP ();
use POSIX ();
use JawnOS::Games ();
use JawnOS::RomCovers ();

my $ROOT = $ENV{'JAWNOS_GAMES_ROOT'} // '/home/jawn/roms';
my $STATE = $ENV{'JAWNOS_COVERS_STATE'} // '/run/jawnos-games/covers.json';
my $CACHE = $ENV{'JAWNOS_COVERS_CACHE'};
if (!defined $CACHE || !length $CACHE) {
	$CACHE = (defined $ENV{'HOME'} && length $ENV{'HOME'})
		? "$ENV{'HOME'}/.cache/jawnos/covers"
		: '/home/jawn/.cache/jawnos/covers';
}
my $TTL = $ENV{'JAWNOS_COVERS_TTL'};
$TTL = 7 * 24 * 60 * 60 unless defined $TTL && $TTL =~ /^\d+$/;

my $FORCE = 0;
my $ONLY = undef;
my $BAD = undef;
foreach my $arg (@ARGV) {
	if ($arg eq '--force') { $FORCE = 1; }
	elsif ($arg =~ /^--system=(.*)\z/) { $ONLY = $1; }
	elsif ($arg eq '--system') { $ONLY = shift(@ARGV) // ''; }
	else { $BAD = $arg; last; }
}

my $JSON = JSON::PP->new->canonical(1);
my %STATUS = (
	state => 'running',
	done => 0,
	total => 0,
	started => time,
	finished => 0,
	fetched => 0,
	skipped => 0,
	error => '',
);

sub write_status {
	my $dir = dirname($STATE);
	make_path($dir) unless -d $dir;
	my $tmp = "$STATE.tmp.$$";
	open(my $fh, '>', $tmp) or return;
	print $fh $JSON->encode(\%STATUS);
	close $fh;
	rename $tmp, $STATE;
	chmod 0644, $STATE;
}

sub finish {
	my ($state, $error) = @_;
	$STATUS{'state'} = $state;
	$STATUS{'error'} = $error if defined $error;
	$STATUS{'finished'} = time;
	write_status();
	exit($state eq 'done' ? 0 : 1);
}

sub which {
	my ($name) = @_;
	foreach my $dir (split /:/, ($ENV{'PATH'} || '/usr/bin:/bin')) {
		next unless length $dir;
		return "$dir/$name" if -x "$dir/$name";
	}
	return undef;
}

# One URL, one temp file, an argv list and no shell. curl and wget agree on the
# little that matters here: no output, fail on an HTTP error, write the bytes.
my ($failures, $first_error) = (0, undef);

my $SEQ = 0;
sub fetch_url {
	my ($url) = @_;
	return undef unless defined $url && length $url;
	make_path($CACHE) unless -d $CACHE;
	my $tmp = "$CACHE/.download." . $$ . '.' . (++$SEQ);
	my $ok = 0;
	my $curl = which('curl');
	if (defined $curl) {
		$ok = system($curl, '--silent', '--show-error', '--fail', '--location',
			'--max-time', '30', '--output', $tmp, $url) == 0;
	}
	elsif (my $wget = which('wget')) {
		$ok = system($wget, '-q', '-O', $tmp, $url) == 0;
	}
	else {
		return undef;
	}
	my $bytes;
	if ($ok && -f $tmp) {
		if (open(my $fh, '<', $tmp)) {
			binmode $fh;
			local $/;
			$bytes = <$fh>;
			close $fh;
		}
	}
	unlink $tmp;
	return defined $bytes ? $bytes : undef;
}

# The parsed listing, from the cache while it is young enough. A listing that
# comes back empty is a miss, not an empty shelf, so it is not cached.
sub cached_listing {
	my ($system, $kind) = @_;
	my $url = JawnOS::RomCovers::listing_url($system, $kind);
	return undef unless defined $url;
	my $file = "$CACHE/listing-" . sha1_hex("$system\n$kind") . '.json';
	if (-f $file && (time - (stat($file))[9]) < $TTL) {
		if (open(my $fh, '<', $file)) {
			local $/;
			my $raw = <$fh> // '';
			close $fh;
			my $parsed = eval { JSON::PP->new->decode($raw) };
			return $parsed if ref $parsed eq 'HASH' && %{ $parsed };
		}
	}
	my $html = fetch_url($url);
	unless (defined $html && length $html) {
		$failures++;
		$first_error //= 'The thumbnail listing for ' . $kind . ' could not be downloaded.';
		return undef;
	}
	my $parsed = JawnOS::RomCovers::listing_parse($html, $url);
	return undef unless ref $parsed eq 'HASH' && %{ $parsed };
	make_path($CACHE) unless -d $CACHE;
	my $tmp = "$file.tmp.$$";
	if (open(my $fh, '>', $tmp)) {
		print $fh $JSON->encode($parsed);
		close $fh;
		rename $tmp, $file;
	}
	return $parsed;
}

sub chown_game {
	my (@paths) = @_;
	return unless @paths;
	system('chown', 'jawn:jawn', @paths);
}

write_status();
finish('failed', "Unknown option: $BAD.") if defined $BAD;

my $library = JawnOS::Games::scan($ROOT);
unless (ref $library eq 'HASH' && $library->{'ok'}) {
	finish('failed', 'The ROM folder could not be read.');
}
my @games = @{ $library->{'games'} || [] };
@games = grep { defined $_->{'system'} && $_->{'system'} eq $ONLY } @games
	if defined $ONLY && length $ONLY;
my @work = grep { $FORCE || !defined $_->{'art'} || !length($_->{'art'} // '') } @games;
$STATUS{'total'} = scalar @work;
write_status();
finish('done') unless @work;

my %by_system;
push @{ $by_system{$_->{'system'}} }, $_ for @work;

foreach my $system (sort keys %by_system) {
	my $folder = JawnOS::RomCovers::folder_for($system);
	foreach my $game (@{ $by_system{$system} }) {
		unless (defined $folder) {
			$STATUS{'skipped'}++;
			$STATUS{'done'}++;
			write_status();
			next;
		}
		my $base = basename($game->{'file'});
		$base =~ s/\.[^.]+$//;
		my $dest = "$ROOT/$system/images/$base.png";
		my ($stored, $matched) = (0, 0);
		foreach my $kind (@JawnOS::RomCovers::KIND) {
			my $listing = cached_listing($system, $kind);
			next unless $listing;
			my $name = JawnOS::RomCovers::best_match([ sort keys %{ $listing } ], $base);
			next unless defined $name;
			$matched = 1;
			my $answer = JawnOS::RomCovers::cover_fetch(
				$listing->{$name}, $dest, sub { fetch_url($_[0]) }, { force => $FORCE });
			if ($answer->{'ok'}) {
				$failures = 0;
				if ($answer->{'skipped'}) {
					$STATUS{'skipped'}++;
				}
				else {
					$STATUS{'fetched'}++;
					chown_game($dest, dirname($dest));
					select(undef, undef, undef, 0.25 + rand(0.15));
				}
				$stored = 1;
				last;
			}
			$failures++;
			$first_error = $answer->{'error'} unless defined $first_error;
			last;   # the title was found; a later kind would not fix a download
		}
		$STATUS{'skipped'}++ unless $stored || $matched;
		$STATUS{'done'}++;
		write_status();
		if ($failures >= 5) {
			finish('failed', 'Cover lookup stopped after repeated failures: '
				. ($first_error // 'the thumbnail host did not answer.'));
		}
	}
}

finish('done');

1;
