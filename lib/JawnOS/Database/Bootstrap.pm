package JawnOS::Database::Bootstrap;

# The two ways a house gets its first database, in one place so the setup
# wizard and the app's own first request cannot drift apart:
#
#   seed_from_factory   database/initial.enc -> jawnos.db, through openssl
#   build_from_schema   database/schema.sql  -> jawnos.db, through DBD::SQLite
#
# Nothing here runs `sqlite3` or `tail`. A clean Windows box has neither, and
# the runtime already carries DBD::SQLite. The seed's appended cipher note is
# read in Perl and cut off before openssl sees the file: openssl would otherwise
# try to decrypt the note as well.
#
# The domain layer (lib/JawnOS/Domain/Key.pm, subs::database_bootstrap) and
# scripts/jawnos_setup.pl both call these functions. The setup script loads
# before subroutines.pl, which is why the shared code lives in a module rather
# than in a domain sub.

use strict;
use warnings;

use Exporter 'import';
our @EXPORT_OK = qw(
	seed_from_factory build_from_schema backup_database
	read_seed seed_cipher openssl_path
);

# The splitter factory_seed.pl appends, and the code it seals the seed under.
# Both are also constants of the shipped seed, not secrets: the seed is an empty
# factory template. Callers may override them for a fixture.
our $DEFAULT_SPLITTER     = '--simple--split--and--whatnot--';
our $DEFAULT_FACTORY_CODE = 'JAWNOS-FACTORY-SEED-v1';

# The cipher the seed is sealed with when its note cannot be read.
our $DEFAULT_CIPHER = 'aes-256-cbc';

sub _splitter {
	my (%opt) = @_;
	my $splitter = $opt{'splitter'};
	return $splitter if defined $splitter && length $splitter;
	return $DEFAULT_SPLITTER;
}

sub _factory_code {
	my (%opt) = @_;
	my $code = $opt{'factory_code'};
	return $code if defined $code && length $code;
	return $DEFAULT_FACTORY_CODE;
}

# The seed is ciphertext followed by the splitter and an encrypted note naming
# the cipher. Read the lot in Perl and cut at the last splitter. Returns the
# ciphertext and the note; a seed with no note is all ciphertext.
sub read_seed {
	my ($seed, %opt) = @_;
	my $splitter = _splitter(%opt);
	open(my $in, '<:raw', $seed) or return;
	my $raw = do { local $/; <$in> };
	close $in;
	return unless defined $raw;
	my $cut = rindex($raw, $splitter);
	return ($raw, '') if $cut < 0;
	return (substr($raw, 0, $cut), substr($raw, $cut + length $splitter));
}

# The cipher named in the seed's note, or undef when the note is absent or
# unreadable. The note is one Crypt::Simple value; only something that looks
# like a cipher name is trusted.
sub _note_cipher {
	my ($note, %opt) = @_;
	return undef unless defined $note && length $note;
	my $plain = eval { _decrypt(_factory_code(%opt), $note) };
	return undef unless defined $plain;
	$plain =~ s/^\s+|\s+$//g;
	return undef unless $plain =~ /^[a-z0-9-]+$/i;
	return $plain;
}

sub seed_cipher {
	my ($seed, %opt) = @_;
	my (undef, $note) = read_seed($seed, %opt);
	return _note_cipher($note, %opt);
}

sub _decrypt {
	my ($secret, $content) = @_;
	require Crypt::Simple;
	no warnings 'once';
	local *encrypt;
	local *decrypt;
	Crypt::Simple->import(passphrase => $secret);
	return decrypt($content);
}

# openssl from PATH, or the copy beside Strawberry Perl on Windows. Returns
# undef rather than dying: the caller falls back to the schema.
sub openssl_path {
	require JawnOS::Platform;
	my $path = JawnOS::Platform::tool_path('openssl');
	return $path if $path;
	my $perl = $^X;
	if ($perl =~ m{^(.*?)[/\\]perl[/\\]bin[/\\]perl(?:\.exe)?$}i) {
		my $candidate = "$1/c/bin/openssl.exe";
		return $candidate if -f $candidate;
	}
	return undef;
}

# Decrypt the factory seed into $db. Returns (1) on success, (0, reason) on a
# failure worth reporting. The note wins over %opt{'standard'} when it names a
# cipher, which is how the setup wizard selected a seed's cipher before.
sub seed_from_factory {
	my ($seed, $db, %opt) = @_;
	return (0, "the seed $seed is missing") unless defined $seed && -e $seed;

	my $openssl = $opt{'openssl'} || openssl_path();
	return (0, 'openssl is not available') unless $openssl;

	my ($ciphertext, $note) = read_seed($seed, %opt);
	return (0, "the seed $seed is unreadable") unless defined $ciphertext && length $ciphertext;

	my $standard = $opt{'standard'} || $DEFAULT_CIPHER;
	my $named = _note_cipher($note, %opt);
	$standard = $named if defined $named && length $named;

	my $tmp = "$db.seed.$$";
	open(my $out, '>:raw', $tmp) or return (0, "cannot write $tmp: $!");
	my $written = print {$out} $ciphertext;
	close $out;
	return (0, "cannot write $tmp") unless $written;

	my $rc = system($openssl, 'enc', '-d',
		'-k', _factory_code(%opt), "-$standard", '-pbkdf2',
		'-in', $tmp, '-out', $db);
	unlink $tmp;
	eval { chmod 0600, $db };
	return (1) if $rc == 0 && -e $db && -s $db > 5000;
	return (0, "openssl could not decrypt the seed with $standard");
}

# Build $db from the shipped schema with DBD::SQLite. The schema is many
# statements and has no triggers, which is exactly what
# sqlite_allow_multiple_statements is for. Returns (1) or (0, reason).
sub build_from_schema {
	my ($schema, $db) = @_;
	return (0, "$schema is missing") unless defined $schema && -e $schema;
	open(my $in, '<', $schema) or return (0, "cannot read $schema: $!");
	my $sql_text = do { local $/; <$in> };
	close $in;
	return (0, "$schema is empty") unless defined $sql_text && length $sql_text;

	require DBI;
	my $dbh = eval {
		DBI->connect("dbi:SQLite:dbname=$db", '', '',
			{ RaiseError => 1, PrintError => 0 });
	};
	return (0, $@ || "cannot open $db") unless $dbh;

	my $ok = eval {
		$dbh->{'sqlite_allow_multiple_statements'} = 1;
		$dbh->do($sql_text);
		1;
	};
	my $error = $@ || '';
	eval { $dbh->disconnect };
	eval { chmod 0600, $db };
	return (1) if $ok && -e $db && -s $db > 5000;
	return (0, $error || 'the schema produced no database');
}

# Copy $source into $dest atomically through SQLite's own backup API, which is
# what `sqlite3 .backup` did. Returns (1) or (0, reason).
sub backup_database {
	my ($source, $dest) = @_;
	return (0, "$source is missing") unless defined $source && -e $source;
	return (0, 'no backup destination') unless defined $dest && length $dest;
	unlink $dest if -e $dest;

	require DBI;
	my $dbh = eval {
		DBI->connect("dbi:SQLite:dbname=$source", '', '',
			{ RaiseError => 1, PrintError => 0 });
	};
	return (0, $@ || "cannot open $source") unless $dbh;
	my $ok = eval { $dbh->sqlite_backup_to_file($dest); 1 };
	my $error = $@ || '';
	eval { $dbh->disconnect };
	return (1) if $ok && -e $dest;
	return (0, $error || "the backup produced no file at $dest");
}

1;
