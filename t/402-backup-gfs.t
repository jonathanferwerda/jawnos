# tests-for: lib/JawnOS/Domain/Backup.pm
# covers:    the GFS plan (daily plus the first of each week/month/year), the
#            pre-seal compression tiers, the codec footer, the decrypt+
#            decompress reader, and the archive-card quota prune.

use strict;
use warnings;
no warnings 'once';

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Temp qw(tempdir);
use File::Slurp qw(write_file read_file);
use Time::Piece;
use DBI;
use JawnOSTest;

subs::preload('backup_retention_keep backup_retention_settings backup_period_keys backup_compress backup_decompress '
	. 'backup_codec backup_open_sealed backup_archive_prune backup_archive_usage '
	. 'backup_path_allowed backup_archive_owner backup_mirror_archive backup_offsite_dir backup_offsite_copy backup_offsite_prune '
	. 'backup_verify_file backup_sha256 backup_human_bytes backup_storage_summary encrypter_legacy openssl_file_crypt');

sub stamp_for {
	my ($date) = @_;
	return Time::Piece->strptime($date . ' 12:00:00', '%Y-%m-%d %H:%M:%S')->epoch * 1000;
}

sub archive_for {
	my ($dir, $date) = @_;
	my $file = "$dir/jawnos_" . stamp_for($date) . '.enc';
	write_file($file, 'archive');
	return $file;
}

# --- period keys -------------------------------------------------------------
my $keys = subs::backup_period_keys(stamp_for('2026-11-24'));
is( $keys->{'day'}, '2026-11-24', 'the day key is the local date' );
is( $keys->{'month'}, '2026-11', 'the month key is year-month' );
is( $keys->{'year'}, '2026', 'the year key is the year' );
like( $keys->{'week'}, qr/^2026-\d{2}$/, 'the week key is an ISO year-week' );

# --- the GFS plan ------------------------------------------------------------
my $dir = tempdir(CLEANUP => 1);
my @dates = qw(
	2023-01-01 2024-01-01 2025-01-01 2026-01-01
	2026-10-01 2026-11-01 2026-11-02 2026-11-03 2026-11-04 2026-11-05
	2026-12-01
);
my @files = map { archive_for($dir, $_) } @dates;
my %file_for;
foreach my $i (0 .. $#dates) { $file_for{$dates[$i]} = $files[$i]; }
my $plan = subs::backup_retention_keep(\@files, 2);
my %keep = map { $_ => 1 } @{ $plan->{'keep'} || [] };

ok( $keep{$file_for{'2026-12-01'}}, 'the newest snapshot is always kept' );
ok( $keep{$file_for{'2026-11-05'}}, 'the second daily is kept' );
ok( !$keep{$file_for{'2026-11-04'}}, 'an older snapshot on the same day is not daily' );
ok( $keep{$file_for{'2026-11-02'}}, 'the first snapshot of a week is kept' );
ok( !$keep{$file_for{'2026-11-03'}}, 'a mid-week snapshot is not' );
ok( $keep{$file_for{'2026-11-01'}}, 'the first of the month is kept' );
ok( $keep{$file_for{'2026-10-01'}}, 'an older monthly snapshot is kept' );
ok( $keep{$file_for{'2026-01-01'}}, 'the first of the current year is kept' );
ok( $keep{$file_for{'2025-01-01'}}, 'the previous year is kept' );
ok( $keep{$file_for{'2024-01-01'}}, 'the third year is kept' );
ok( $keep{$file_for{'2023-01-01'}}, 'a sparse older month still fills the twelve-month tier' );

# A custom plan from the Enc panel: each tier can be zeroed independently.
my $custom = subs::backup_retention_keep(\@files, { days => 0, weeks => 2, months => 1, years => 1 });
my %custom_keep = map { $_ => 1 } @{ $custom->{'keep'} || [] };
ok( $custom_keep{$file_for{'2026-12-01'}}, 'custom plan: the newest is always kept' );
ok( !$custom_keep{$file_for{'2026-11-05'}}, 'custom plan: zero days keeps no daily' );
ok( $custom_keep{$file_for{'2026-11-02'}}, 'custom plan: two weeks keeps the previous week first' );
ok( $custom_keep{$file_for{'2026-01-01'}}, 'custom plan: one year keeps the year first' );
ok( !$custom_keep{$file_for{'2025-01-01'}}, 'custom plan: one year drops the earlier year' );

# --- compression -------------------------------------------------------------
my $sample = "$dir/sample.bin";
my $text = join '', map { chr(($_ * 31 + 7) & 255) } 1 .. 40000;
write_file($sample, $text);

foreach my $tier (qw(fast best)) {
	my ($coded, $codec) = subs::backup_compress($sample, $tier);
	if ($codec eq 'none') {
		skip "no zstd or gzip on this machine ($tier)", 2;
		next;
	}
	like( $codec, $tier eq 'best' ? qr/^(?:zstd-19|gzip-9)$/ : qr/^(?:zstd-1|gzip-1)$/,
		"$tier names the expected compression level" );
	my $out = "$dir/$tier.out";
	ok( subs::backup_decompress($codec, $coded, $out), "$tier decompresses" );
	is( read_file($out), $text, "$tier round-trips the bytes" );
}

# --- the footer and the decrypt+decompress reader ----------------------------
my $secret = 'test-house-key';
is( subs::backup_codec($secret, ''), 'none', 'an old footer with no codec is uncompressed' );
is( subs::backup_codec($secret, subs::encrypter_legacy(undef, 'zstd-19')), 'zstd-19',
	'the codec footer opens under the public empty key' );
is( subs::backup_codec($secret, subs::encrypter_legacy(undef, 'brotli-1')), undef,
	'a codec this build does not know is refused' );

SKIP: {
	my $openssl = grep { -x "$_/openssl" } split /:/, ($ENV{'PATH'} || '');
	skip 'no openssl binary', 7 unless $openssl;
	my ($coded, $codec) = subs::backup_compress($sample, 'fast');
	my $sealed = "$dir/sealed.enc";
	ok( subs::openssl_file_crypt('e', 'aes-256-ctr', $secret, $coded, $sealed, 0, 1),
		'the snapshot is sealed' );
	my $old_split = $gb::universal_splitter;
	$gb::universal_splitter = '--test-split--';
	my $footer = $gb::universal_splitter . subs::encrypter_legacy(undef, 'aes-256-ctr')
		. $gb::universal_splitter . subs::encrypter_legacy(undef, $codec);
	open(my $af, '>>', $sealed) or die "append $sealed: $!";
	print $af $footer;
	close $af;
	my $out = "$dir/opened.bin";
	my $scratch = "$dir/";
	local *subs::home = sub { return $_[0] =~ /\.president/ ? $scratch : $_[0] };
	ok( subs::backup_open_sealed($sealed, $secret, $out, 0), 'the sealed snapshot opens' );
	is( read_file($out), $text, 'and decompresses to the original bytes' );
	is( scalar( () = glob($scratch . '*.coded') ), 0, 'the decrypted scratch is removed' );

	# The monthly drill: a real database passes, a sealed non-database fails.
	my $tiny = "$dir/tiny.db";
	my $dbh = DBI->connect("dbi:SQLite:dbname=$tiny", '', '', { RaiseError => 1, PrintError => 0 });
	$dbh->do('create table probe (x text)');
	$dbh->do("insert into probe values ('ok')");
	$dbh->disconnect;
	my ($tiny_coded, $tiny_codec) = subs::backup_compress($tiny, 'fast');
	my $tiny_sealed = "$dir/tiny.enc";
	ok( subs::openssl_file_crypt('e', 'aes-256-ctr', $secret, $tiny_coded, $tiny_sealed, 0, 1),
		'the tiny database is sealed' );
	my $tiny_footer = $gb::universal_splitter . subs::encrypter_legacy(undef, 'aes-256-ctr')
		. $gb::universal_splitter . subs::encrypter_legacy(undef, $tiny_codec);
	open(my $tf, '>>', $tiny_sealed) or die "append $tiny_sealed: $!";
	print $tf $tiny_footer;
	close $tf;
	my $good = subs::backup_verify_file($tiny_sealed, $secret);
	ok( $good->{'ok'}, 'a real database passes the verification' );
	is( scalar( () = glob($scratch . '*.verify.db*') ), 0, 'the verification scratch is removed' );
	my $bad = subs::backup_verify_file($sealed, $secret);
	ok( !$bad->{'ok'}, 'a sealed non-database fails the verification' );
	$gb::universal_splitter = $old_split;
}

# --- the peer-export handshake ----------------------------------------------
# A newer peer must not send a compressed container to a puller that still
# expects SQLite bytes directly. The pull asks for it, and the export checks.
my $part10 = read_file("$FindBin::Bin/../lib/JawnOS/Manager/Part10.pm");
like( $part10, qr/backup_now\?reason=remote_update&async=1&compress=1/,
	'a peer pull asks for the compressed container' );
my $backup_src = read_file("$FindBin::Bin/../lib/JawnOS/Domain/Backup.pm");
like( $backup_src, qr/param\('compress'\)/, 'the export checks the puller capability' );
like( $backup_src, qr/if \$may_compress/, 'and writes the codec footer only when it may' );
# The card folder is only used while the card is mounted; an empty mountpoint
# on the eMMC must not grow a Backups folder.
like( $backup_src, qr/archive_card_mounted/,
	'the archive-card Backups folder waits for the mount' );

# --- the archive-card quota --------------------------------------------------
my $card = tempdir(CLEANUP => 1);
my @card_files = map { archive_for($card, $_) } qw(2026-11-01 2026-11-02 2026-11-03);
foreach my $file (@card_files) {
	open(my $fh, '>', $file) or die "write $file: $!";
	print $fh 'x' x 400;
	close $fh;
}
my $prune;
{
	local *subs::backup_archive_dir = sub { $card };
	local *subs::backup_quota_percent = sub { 10 };
	local *subs::backup_archive_capacity = sub { 1000 };   # 10% = 100 bytes
	local *subs::backup_retention_settings = sub { { days => 1, weeks => 0, months => 0, years => 0 } };
	local *subs::backup_prune_remove = sub { unlink $_[0]; 1 };
	local *subs::log_writer = sub { };
	$prune = subs::backup_archive_prune();
}
is( $prune->{'enabled'}, 1, 'the card prune runs when a quota is set' );
is( $prune->{'cap'}, 100, 'the cap is the quota share of the card' );
ok( $prune->{'removed'} >= 2, 'the quota removes older copies' );
is( scalar( () = glob("$card/jawnos_*.enc") ), 1, 'only the newest copy stays' );

# --- the second medium and the path gate -------------------------------------
my $offsite = tempdir(CLEANUP => 1);
my $stamp_new = 1795478403416;
my $stamp_old = 1795392003353;
my $source = "$dir/jawnos_$stamp_new.enc";
write_file($source, 'x' x 6000);
my ($copied, $again);
{
	local *subs::backup_offsite_dir = sub { $offsite };
	local *subs::backup_archive_dir = sub { undef };
	$copied = subs::backup_offsite_copy($source);
	$again = subs::backup_offsite_copy($source);
}
ok( $copied, 'the newest sealed file is copied to the second medium' );
is( read_file("$offsite/jawnos_$stamp_new.enc"), 'x' x 6000, 'the offsite bytes match' );
ok( $again, 'a second copy of the same bytes succeeds without rewriting' );
write_file("$offsite/jawnos_$stamp_old.enc", 'y' x 6000);
my $offsite_prune;
{
	local *subs::backup_offsite_dir = sub { $offsite };
	local *subs::backup_retention_settings = sub { { days => 1, weeks => 0, months => 0, years => 0 } };
	local *subs::backup_prune_remove = sub { unlink $_[0]; 1 };
	$offsite_prune = subs::backup_offsite_prune();
}
ok( $offsite_prune->{'enabled'}, 'the offsite prune runs' );
ok( !-e "$offsite/jawnos_$stamp_old.enc", 'the offsite history follows the same plan' );
ok( -e "$offsite/jawnos_$stamp_new.enc", 'and the newest offsite copy stays' );

my $local_dir = tempdir(CLEANUP => 1);
my $card_dir = tempdir(CLEANUP => 1);
write_file("$local_dir/jawnos.enc", 'x');
write_file("$card_dir/jawnos.enc", 'x');
{
	local *subs::backups_dir = sub { $local_dir };
	local *subs::backup_archive_dir = sub { $card_dir };
	ok( subs::backup_path_allowed("$local_dir/jawnos.enc"), 'a local restore path is allowed' );
	ok( subs::backup_path_allowed("$card_dir/jawnos.enc"), 'a card restore path is allowed' );
	ok( !subs::backup_path_allowed('/tmp/not-a-backup.enc'), 'a path outside both is refused' );
}

# --- the card names its machine ----------------------------------------------
my $owned = tempdir(CLEANUP => 1);
my $owned_name = "jawnos_$stamp_new.enc";
{
	local *subs::backup_archive_dir = sub { $owned };
	local *subs::backup_quota_percent = sub { 10 };
	local *subs::signatorial_designer = sub { 'machine-a' };
	ok( subs::backup_mirror_archive($source), 'the machine writes its card' );
	is( subs::backup_archive_owner($owned), 'machine-a', 'the card names the machine' );
	ok( subs::backup_path_allowed("$owned/$owned_name"), 'its own card path is allowed' );
}
{
	local *subs::backup_archive_dir = sub { $owned };
	local *subs::backup_quota_percent = sub { 10 };
	local *subs::signatorial_designer = sub { 'machine-b' };
	ok( !subs::backup_path_allowed("$owned/$owned_name"), 'another machine refuses the card path' );
	ok( !subs::backup_mirror_archive($source), 'and does not write to the card' );
}

# --- the Enc storage readout -------------------------------------------------
is( subs::backup_human_bytes(0), '0 B', 'zero bytes' );
is( subs::backup_human_bytes(1024), '1.0 KB', 'kibibytes are shown as KB' );
is( subs::backup_human_bytes(3 * 1024 * 1024), '3.0 MB', 'megabytes are shown as MB' );

my $read_local = tempdir(CLEANUP => 1);
my $read_card = tempdir(CLEANUP => 1);
write_file("$read_local/jawnos.enc", 'a' x 1000);
write_file("$read_local/jawnos_1795478403416.enc", 'b' x 2000);
write_file("$read_card/jawnos_1795392003353.enc", 'c' x 500);
my $read;
{
	local *subs::backups_dir = sub { $read_local };
	local *subs::backup_archive_dir = sub { $read_card };
	local *subs::backup_archive_owner = sub { 'machine-a' };
	local *subs::signatorial_designer = sub { 'machine-a' };
	local *subs::backup_quota_percent = sub { 10 };
	local *subs::backup_archive_capacity = sub { 10000 };
	$read = subs::backup_storage_summary();
}
is( $read->{'local'}, 3000, 'local usage sums the stable and dated files' );
is( $read->{'card'}->{'usage'}, 500, 'card usage sums its copies' );
is( $read->{'card'}->{'cap'}, 1000, 'the card cap is the quota share' );
is( $read->{'card'}->{'quota'}, 10, 'the card quota is reported' );
ok( !$read->{'card'}->{'foreign'}, 'its own card is not foreign' );
{
	local *subs::backups_dir = sub { $read_local };
	local *subs::backup_archive_dir = sub { $read_card };
	local *subs::backup_archive_owner = sub { 'machine-b' };
	local *subs::signatorial_designer = sub { 'machine-a' };
	local *subs::backup_quota_percent = sub { 10 };
	local *subs::backup_archive_capacity = sub { 10000 };
	my $foreign = subs::backup_storage_summary();
	ok( $foreign->{'card'}->{'foreign'}, 'another machine\'s card is marked foreign' );
}

done_testing();
