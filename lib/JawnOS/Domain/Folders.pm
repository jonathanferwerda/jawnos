package subs;

# Folders: extracted from subroutines.pl (package subs). Loaded on
# demand by lib/JawnOS/Domain/Loader.pm.
use strict;
use warnings;
use utf8;
use feature 'signatures';
no warnings 'experimental::signatures';
no warnings 'experimental::args_array_with_signatures';

use Clone qw(clone);
use Data::Dumper;
use Date::Parse;
use Digest::SHA qw(sha256_hex);
use Encode qw(encode_utf8);
use Fcntl qw(:flock);
use File::Copy;
use File::Find;
use File::Path;
use File::Slurp;
use IPC::Open2;
use JSON::PP ();
use List::Util qw(shuffle);
use MIME::Base64;
use Math::Trig qw(cartesian_to_spherical spherical_to_cartesian great_circle_distance rad2deg deg2rad great_circle_bearing great_circle_direction great_circle_destination);
use Mojo::IOLoop;
use Mojo::JSON qw(decode_json encode_json);
use Mojo::Util qw/md5_sum xml_escape html_unescape term_escape quote unquote secure_compare url_escape url_unescape network_contains punycode_decode punycode_encode b64_decode b64_encode/;
use POSIX ();   # mktime: a local-time epoch that still predates 1970
use Text::Unidecode;
use Time::Duration;
use Time::HiRes qw(gettimeofday time);
use Time::Local;
use Time::Piece;
use Unicode::Normalize qw(NFC);

our $database;
our $find_program;
our $gb;
our $universal_splitter;

# Take the entries naming a path out of one decoded blob: an entry goes whole,
# a bare path in a list goes alone, and an attachment wrapped around an entry
# goes with it. Returns how many were dropped.
sub folders_entry_trim_in {
	my ($blob, $wanted) = @_;
	my $dropped = 0;
	if (ref $blob eq 'ARRAY') {
		my @kept;
		foreach my $item ( @{$blob} ) {
			if (ref $item) {
				if (&folders_entry_names($item, $wanted)) { $dropped++; next }
				$dropped += &folders_entry_trim_in($item, $wanted);
			}
			elsif (defined $item && $wanted->{$item}) {
				$dropped++;
				next;
			}
			push @kept, $item;
		}
		@{$blob} = @kept;
	}
	elsif (ref $blob eq 'HASH') {
		foreach my $key ( keys %{$blob} ) {
			next unless ref $blob->{$key};
			$dropped += &folders_entry_trim_in($blob->{$key}, $wanted);
		}
	}
	return $dropped;
}

# Take a path out of the rows besides an appointment that write one down - a
# mailbox's attachments, the store's rows - so a file that is taken away is not
# still named by them. A folder covers the files under it, and a row that
# changed is stamped with the time so the other machines hear about it.
# Returns how many entries were taken out.
sub folders_entry_trim {
	my $path = shift;
	return 0 unless (defined $path && length $path);
	my @names = (-d $path) ? &folders_job_files([ { path => $path } ]) : ( $path );
	my %wanted = map { $_ => 1 } @names;
	my $trimmed = 0;
	foreach my $place ( &file_reference_places() ) {
		next unless ($place->{'shape'} eq 'entries');
		next if ($place->{'table'} eq 'appointments');
		my $table = $place->{'table'};
		my $column = $place->{'column'};
		my $rows = eval { &db_query("select rowid, $column from $table where $column is not null and $column != ''")->hashes } || [];
		foreach my $row ( @{$rows} ) {
			my $blob = eval { return decode_json $row->{$column} };
			next unless ref $blob;
			my $touched = 0;
			if (ref $blob eq 'HASH' && &folders_entry_names($blob, \%wanted)) {
				$touched = 1;
				$blob = [];
			}
			else {
				$touched = &folders_entry_trim_in($blob, \%wanted);
			}
			next unless $touched;
			&db_update($table, { $column => encode_json $blob, server_time => &rightNow() }, { rowid => $row->{'rowid'} });
			$trimmed += $touched;
		}
	}
	return $trimmed;
}

# Every place a path is written down, so that sealing a file or opening one
# keeps whatever points at it pointing at it: an appointment's file array, a
# mailbox's attachments (each one wrapped around a file entry), and the store's
# rows, which carry the same kind of entries as an appointment does. A backup
# remembers its sealed file as a bare path, so it is here too.
sub file_reference_places {
	return (
		{ table => 'appointments', column => 'file', shape => 'entries', standard => 1, app => 1 },
		{ table => 'mailbox', column => 'attachments', shape => 'entries' },
		{ table => 'model', column => 'file', shape => 'entries' },
		{ table => 'model', column => 'files', shape => 'entries' },
		{ table => 'option', column => 'file', shape => 'entries' },
		{ table => 'option', column => 'files', shape => 'entries' },
		{ table => 'option_category', column => 'file', shape => 'entries' },
		{ table => 'subcategory', column => 'file', shape => 'entries' },
		{ table => 'backups', column => 'enc_file', shape => 'path' }
	);
}

# Walk a decoded blob and hang every path in it off the map, so a path can be
# found again by what it names: an entry's f or thumb, an attachment wrapped
# around an entry, or a bare path in a list. What was found is kept with the
# blob it sits in, so the spot can be written back to.
sub file_reference_index {
	my ($blob, $info, $paths) = @_;
	return unless ref $blob;
	if (ref $blob eq 'ARRAY') {
		for (my $spot = 0; $spot < scalar @{$blob}; $spot++) {
			my $item = $blob->[$spot];
			if (ref $item) { &file_reference_index($item, $info, $paths); next }
			next unless (defined $item && length $item);
			push @{ $paths->{$item} }, { info => $info, kind => 'list', blob => $blob, spot => $spot };
		}
	}
	elsif (ref $blob eq 'HASH') {
		foreach my $kind ( qw/f thumb/ ) {
			next unless (defined $blob->{$kind} && length $blob->{$kind});
			push @{ $paths->{ $blob->{$kind} } }, { info => $info, kind => $kind, blob => $blob };
		}
		foreach my $key ( keys %{$blob} ) {
			next unless ref $blob->{$key};
			&file_reference_index($blob->{$key}, $info, $paths);
		}
	}
}

# Every path the rows write down, read once, as a map from each path to where
# it was found, so a job sealing or opening a whole folder can look a selection
# up without dialing the database file by file. The looking is done on decoded
# values: the JSON written by this house escapes the slashes, so the stored
# text is no way to find a path in.
sub file_reference_read {
	my $read = { paths => {} };
	foreach my $place ( &file_reference_places() ) {
		my $table = $place->{'table'};
		my $column = $place->{'column'};
		my $select = "rowid, $column" . ($place->{'standard'} ? ', encryption_standard' : '') . ($place->{'app'} ? ', app' : '');
		my $found = eval { &db_query("select $select from $table where $column is not null and $column != ''")->hashes } || [];
		foreach my $row ( @{$found} ) {
			my $info = {
				table => $table,
				column => $column,
				shape => $place->{'shape'},
				flagged => $place->{'standard'} ? 1 : 0,
				rowid => $row->{'rowid'},
				row_standard => $row->{'encryption_standard'},
				app => ($place->{'app'} ? ($row->{'app'} || '') : '')
			};
			if ($place->{'shape'} eq 'entries') {
				my $blob = eval { return decode_json $row->{$column} };
				next unless ref $blob;
				$info->{'blob'} = $blob;
				&file_reference_index($blob, $info, $read->{'paths'});
			}
			else {
				$info->{'value'} = $row->{$column};
				push @{ $read->{'paths'}->{ $row->{$column} } }, { info => $info, kind => 'path' };
			}
		}
	}
	return $read;
}

# What the rows remember about a path, from a set already read: the name the
# file went in under, and the encryption standard the row carries, the two
# things opening a seal again needs to hand the file back the way it was.
# Undefined when nothing points at the path.
sub file_reference_remembered {
	my ($read, $path) = @_;
	return undef unless (defined $path && length $path && ref $read);
	my $spots = $read->{'paths'}->{$path};
	return undef unless $spots;
	foreach my $spot ( @{$spots} ) {
		next unless ($spot->{'kind'} eq 'f');
		return { of => $spot->{'blob'}->{'of'}, standard => $spot->{'info'}->{'row_standard'} };
	}
	return undef;
}

# Put the new paths where the old ones were written down, in a set already
# read, and write back only the rows that changed. Each pair is named by the
# path it was, and carries where it went and the name it went in under; a
# moved folder hands its prefixes over instead, and every path under them gets
# its pair worked out from them. A row that changed is stamped with the time
# so the other machines hear about it, and an appointment that had a file
# sealed or opened says which encryption standard it is under now, the way
# file_encrypter and file_decrypter say it.
sub file_reference_apply {
	my ($read, $pairs, $folders) = @_;
	return 0 unless (ref $read && ref $pairs);
	# a folder that moved takes everything under it along
	foreach my $from ( keys %{$folders || {}} ) {
		my $to = $folders->{$from};
		next unless (defined $to && length $to);
		my $stem = $from;
		$stem =~ s{/+$}{};
		my $to_stem = $to;
		$to_stem =~ s{/+$}{};
		my $under = $stem . '/';
		$pairs->{$stem} = { to => $to_stem } if ($read->{'paths'}->{$stem});
		foreach my $path ( keys %{ $read->{'paths'} } ) {
			next unless (substr($path, 0, length $under) eq $under);
			$pairs->{$path} = { to => $to_stem . substr($path, length $stem) };
		}
	}
	return 0 unless (scalar keys %{$pairs});
	my $standard;
	my $clear = 0;
	foreach my $pair ( values %{$pairs} ) {
		$standard = $pair->{'standard'} if (defined $pair->{'standard'} && length $pair->{'standard'});
		$clear = 1 if $pair->{'clear_standard'};
	}
	my %dirty;
	foreach my $from ( keys %{$pairs} ) {
		my $pair = $pairs->{$from};
		my $spots = $read->{'paths'}->{$from};
		next unless $spots;
		foreach my $spot ( @{$spots} ) {
			my $info = $spot->{'info'};
			if ($spot->{'kind'} eq 'path') {
				next unless (defined $info->{'value'} && $info->{'value'} eq $from);
				$info->{'value'} = $pair->{'to'};
			}
			elsif ($spot->{'kind'} eq 'list') {
				next unless ($spot->{'blob'}->[ $spot->{'spot'} ] eq $from);
				$spot->{'blob'}->[ $spot->{'spot'} ] = $pair->{'to'};
			}
			else {
				next unless (defined $spot->{'blob'}->{ $spot->{'kind'} } && $spot->{'blob'}->{ $spot->{'kind'} } eq $from);
				$spot->{'blob'}->{ $spot->{'kind'} } = $pair->{'to'};
				$spot->{'blob'}->{'server_time'} = &rightNow();
				$spot->{'blob'}->{'of'} = $pair->{'of'} if ($pair->{'of'} && $spot->{'kind'} eq 'f' && !$spot->{'blob'}->{'of'});
			}
			$dirty{$info} = $info;
		}
	}
	foreach my $info ( values %dirty ) {
		my $set = { server_time => &rightNow() };
		$set->{ $info->{'column'} } = ($info->{'shape'} eq 'entries') ? encode_json $info->{'blob'} : $info->{'value'};
		if ($info->{'flagged'}) {
			$set->{'encryption_standard'} = $standard if defined $standard;
			$set->{'encryption_standard'} = undef if $clear;
		}
		&db_update($info->{'table'}, $set, { rowid => $info->{'rowid'} });
	}
	return scalar keys %dirty;
}

# The worker half of paste: put what was cut or copied into the folder being
# looked at. A move on one disk is a rename; anything else is copied file by
# file and the source taken away once it has landed, so a selection can cross
# disks, and a folder goes with everything in it. A move also hands the rows
# that pointed at a file its new path, once the old one has gone; a copy
# leaves what points at the original pointing at it. Errors are collected
# rather than thrown on the first bad file, and the job stops itself when the
# dialog asks it to.
sub folders_copy_job {
	my ($job, $data) = @_;
	my $to = $data->{'to'};
	unless (defined $to && length $to && -d $to) { $job->fail('the folder to paste into is not there'); return }
	my $move = $data->{'move'} ? 1 : 0;
	my @items = @{$data->{'items'} || []};
	my $total = 0;
	foreach my $item ( @items ) {
		$total += scalar &folders_job_files([ $item ]);
	}
	my @errors;
	my ($copied, $moved, $bytes, $count) = (0, 0, 0, 0);
	# a move is what sends the rows to new paths - a copy leaves what points at
	# the original pointing at it
	my $references = $move ? &file_reference_read() : undef;
	my %moved_files;
	my %moved_folders;
	my $since_apply = 0;
	foreach my $item ( @items ) {
		my $path = $item->{'path'};
		unless (defined $path && length $path && -e $path) {
			push @errors, ($path || '?') . ': it is not there';
			next;
		}
		my @parts = split '/', $path;
		my $name = pop @parts;
		my $dest = $to . '/' . $name;
		if (-e $dest) {
			push @errors, $name . ': something with that name is already there';
			next;
		}
		my $source_is_folder = -d $path;
		# the whole of a move on one disk, and the cheap way round the rest
		if ($move && rename($path, $dest)) {
			$moved++;
			$since_apply++;
			if ($source_is_folder) { $moved_folders{$path} = $dest; }
			else { $moved_files{$path} = { to => $dest }; }
			next;
		}
		my @mine = $source_is_folder ? &folders_job_files([ $item ]) : ( $path );
		my $landed = 1;
		foreach my $file ( @mine ) {
			$count++;
			if ($count % 10 == 0) {
				$job->note(progress => ($move ? 'moved' : 'copied') . " $copied of $total files, $bytes bytes");
				if (($job->info->{'notes'} || {})->{'cancel'}) {
					&file_reference_apply($references, \%moved_files, \%moved_folders);
					$job->note(progress => "stopped after $copied files");
					$job->finish({ copied => $copied, moved => $moved, bytes => $bytes, files => $total, cancelled => 1 });
					return;
				}
			}
			my $relative = $name;
			if ($source_is_folder) {
				my $tail = substr($file, length($path));
				$tail =~ s{^/+}{};
				$relative = $name . '/' . $tail;
			}
			my $target = $to . '/' . $relative;
			my @upper = split '/', $target;
			pop @upper;
			my $parent = join '/', @upper;
			File::Path::make_path($parent) unless -d $parent;
			unless (-d $parent && File::Copy::copy($file, $target)) {
				push @errors, $relative . ': it could not be copied';
				$landed = 0;
				next;
			}
			my @stat = stat($file);
			utime $stat[9], $stat[9], $target if $stat[9];
			$bytes += (-s $target) || 0;
			$copied++;
		}
		if ($move && $landed) {
			my $error = &folders_job_take_away($path);
			push @errors, $error if $error;
			unless ($error) {
				# the old paths have gone, so the rows go to the new ones
				$moved++;
				$since_apply++;
				if ($source_is_folder) { $moved_folders{$path} = $dest; }
				else { $moved_files{$path} = { to => $dest }; }
			}
		}
		# the moved paths are handed over in stretches, so a long paste is not
		# left pointing at places its files have left
		if ($since_apply >= 100) {
			&file_reference_apply($references, \%moved_files, \%moved_folders);
			$since_apply = 0;
		}
	}
	# whatever moved is pointed at where it moved to
	&file_reference_apply($references, \%moved_files, \%moved_folders);
	my $result = { copied => $copied, moved => $moved, bytes => $bytes, files => $total };
	if (scalar @errors) {
		$result->{'errors'} = \@errors;
		$job->fail($result);
		return;
	}
	$job->note(progress => ($move ? "moved $moved" : "copied $copied of $total") . ", $bytes bytes");
	$job->finish($result);
}

# The worker half of encrypting: every file the selection names is sealed the
# way an app's files are sealed - openssl with the encryption standard and the
# suds as the password, a name of its own, and the plaintext shredded behind
# it - so the folder gives nothing away by its names. Whatever row pointed at
# the plaintext is pointed at the seal instead, and remembers the name the file
# went in under, so decrypting can hand it back the way it was. Files already
# sealed are left alone.
sub folders_encrypt_job {
	my ($job, $data) = @_;
	my $suds = $data->{'suds'};
	unless (defined $suds && length $suds) { $job->fail('there is no suds to seal with'); return }
	my $standard = &setting_grabber({ app => 'misc', setting => 'encryption_standard' }) || "aes-256-ctr";
	my @files = grep { $_ !~ /\.enc$/i } &folders_job_files($data->{'items'});
	my @errors;
	my ($sealed, $bytes, $count) = (0, 0, 0);
	# everything that points at a path, read once, so a whole folder does not
	# dial the database file by file
	my $references = &file_reference_read();
	my %moved;
	foreach my $file ( @files ) {
		$count++;
		$job->note(progress => "sealed $sealed of " . scalar(@files) . " files, $bytes bytes") if $count % 5 == 0;
		if (($job->info->{'notes'} || {})->{'cancel'}) {
			&file_reference_apply($references, \%moved);
			$job->note(progress => "stopped after $sealed files");
			$job->finish({ sealed => $sealed, bytes => $bytes, files => scalar(@files), cancelled => 1 });
			return;
		}
		my @parts = split '/', $file;
		my $name = pop @parts;
		my $base = join '/', @parts;
		my @ext = split /\./, $name;
		my $ext = pop @ext;
		my $sealed_path = (length $base ? $base . '/' : '') . &random_string_creator(20) . '.' . $ext . '.enc';
		my $status = system('openssl', 'enc', '-e', '-k', $suds, "-$standard", '-pbkdf2', '-in', $file, '-out', $sealed_path);
		unless ($status == 0 && -e $sealed_path && (-s $sealed_path) > 0) {
			unlink $sealed_path;
			push @errors, $name . ': it could not be sealed';
			next;
		}
		system('shred', '-u', $file);
		$moved{$file} = { to => $sealed_path, of => $name, standard => $standard };
		$sealed++;
		$bytes += (-s $sealed_path) || 0;
		# hand the rows their new paths in stretches, so a job taken down in the
		# middle leaves at most a stretch unpointed
		&file_reference_apply($references, \%moved) if ($sealed % 100 == 0);
	}
	# whatever points at the plaintext points at the seal instead, and remembers
	# the name it went in under
	&file_reference_apply($references, \%moved);
	my $result = { sealed => $sealed, bytes => $bytes, files => scalar @files };
	if (scalar @errors) {
		$result->{'errors'} = \@errors;
		$job->fail($result);
		return;
	}
	$job->note(progress => "sealed $sealed of " . scalar(@files) . " files, $bytes bytes");
	$job->finish($result);
}

# Whether the start of a file reads as text. Plain text has no type File::Type
# knows, so it is the one thing a content check misses, and a password that
# does not fit never comes out as words: a stream of random bytes is printable
# about two fifths of the time, so a head that is printable throughout is not
# something a wrong password produces.
sub folders_reads_as_text {
	my $head = shift;
	return 0 unless (defined $head && length $head);
	return 0 if $head =~ /\0/;
	my $printable = ($head =~ tr/\t\n\r\x20-\x7e//);
	return (($printable / length($head)) > .95) ? 1 : 0;
}

# The worker half of decrypting: every sealed file the selection names is
# opened with the first password that works - the suds the request handed
# over, since that is what the folders app seals with, then the padlock
# secrets the way file_decrypter tries them - under the standard the row it
# belongs to carries, falling back to the setting. It lands under the name the
# rows that point at it remember it by, and whatever pointed at the seal is
# pointed at the plaintext. The seal is only shredded once its plaintext is
# safely out, so a file no password opens is left exactly as it was.
sub folders_decrypt_job {
	my ($job, $data) = @_;
	my $suds = $data->{'suds'};
	my $standard = &setting_grabber({ app => 'misc', setting => 'encryption_standard' }) || "aes-256-ctr";
	my @passwords = ( $suds );
	my $secrets = &db_query('select * from security where level != ? and level != ? order by server_time DESC','padlock','door');
	foreach my $p ( @{$secrets->hashes} ) {
		my $secret = &decrypter($suds, $p->{'credential'});
		push @passwords, $secret if (defined $secret && length $secret);
	}
	my @files = grep { /\.enc$/i } &folders_job_files($data->{'items'});
	my @errors;
	my ($opened, $bytes, $count) = (0, 0, 0);
	# everything that points at a path, read once, so a whole folder does not
	# dial the database file by file
	my $references = &file_reference_read();
	my %moved;
	foreach my $file ( @files ) {
		$count++;
		$job->note(progress => "opened $opened of " . scalar(@files) . " files, $bytes bytes") if $count % 5 == 0;
		if (($job->info->{'notes'} || {})->{'cancel'}) {
			&file_reference_apply($references, \%moved);
			$job->note(progress => "stopped after $opened files");
			$job->finish({ opened => $opened, bytes => $bytes, files => scalar(@files), cancelled => 1 });
			return;
		}
		my @parts = split '/', $file;
		my $name = pop @parts;
		# what the rows that point at the seal remember: the name the file went
		# in under, so it can come back as itself, and the standard it was
		# sealed with, which beats the setting when the two disagree
		my $remembered = &file_reference_remembered($references, $file) || {};
		my $path = $file;
		$path =~ s/\.enc$//i;
		if (defined $remembered->{'of'} && $remembered->{'of'} =~ /\S/) {
			my $original = $remembered->{'of'};
			$original =~ s{.*/}{};
			my @folder = split '/', $file;
			pop @folder;
			my $folder = join '/', @folder;
			$path = (length $folder ? $folder . '/' : '') . $original;
		}
		if (-e $path) {
			push @errors, $name . ': something with that name is already there';
			next;
		}
		my @standards = ( $remembered->{'standard'}, $standard );
		my %seen_standard;
		@standards = grep { defined $_ && length $_ && !$seen_standard{$_}++ } @standards;
		my $temp = $file . '.opening';
		my $opened_it = 0;
		foreach my $which ( @standards ) {
			foreach my $secret ( @passwords ) {
				next unless (defined $secret && length $secret);
				unlink $temp if -e $temp;
				my $status = system('openssl', 'enc', '-d', '-k', $secret, "-$which", '-pbkdf2', '-in', $file, '-out', $temp);
				next unless ($status == 0 && -e $temp);
				# nothing in the stream says which password is the one, so the
				# opening is read as a file the way file_decrypter reads one: a
				# password that gives back a type - or words - is the password
				my $head = '';
				if (open my $fh, '<', $temp) { binmode $fh; read $fh, $head, 1024; close $fh; }
				my $type = &plaintext_verdict($head);
				if (defined $type) { $opened_it = 1; last }
				# a file that was empty seals to a block or two, and opens to nothing
				if ((-s $temp) == 0 && (-s $file) <= 48) { $opened_it = 1; last }
			}
			last if $opened_it;
		}
		unless ($opened_it) {
			unlink $temp if -e $temp;
			push @errors, $name . ': no password opened it';
			next;
		}
		rename $temp, $path;
		system('shred', '-u', $file);
		$moved{$file} = { to => $path, clear_standard => 1 };
		$opened++;
		$bytes += (-s $path) || 0;
		# hand the rows their new paths in stretches, so a job taken down in the
		# middle leaves at most a stretch unpointed
		&file_reference_apply($references, \%moved) if ($opened % 100 == 0);
	}
	# whatever points at the seal points at what came out of it
	&file_reference_apply($references, \%moved);
	my $result = { opened => $opened, bytes => $bytes, files => scalar @files };
	if (scalar @errors) {
		$result->{'errors'} = \@errors;
		$job->fail($result);
		return;
	}
	$job->note(progress => "opened $opened of " . scalar(@files) . " files, $bytes bytes");
	$job->finish($result);
}

# The sealed files under the given roots: dir_listing's find(1), with the name
# filter left to the child, so a home with a hundred thousand files costs one
# process to ask.
sub sealed_files_under {
	my ($roots) = @_;
	my @roots = grep { defined $_ && length $_ && -d $_ } @{ $roots || [] };
	return () unless @roots;
	my @out;
	my $listed = 0;
	my $find = &find_program();
	if ($find) {
		if (open(my $fh, '-|', $find, @roots, '-type', 'f', '-iname', '*.enc', '-print0')) {
			$listed = 1;
			local $/ = "\0";
			while (defined(my $path = <$fh>)) {
				chop $path;
				push @out, $path if length $path;
			}
			close $fh;
		}
	}
	unless ($listed) {
		find({ no_chdir => 1, wanted => sub { push @out, $File::Find::name if -f $_ && /\.enc$/i } }, @roots);
	}
	return sort @out;
}

# system() with the child's stderr sent to /dev/null: openssl enc -d chatters
# "bad decrypt" on every wrong password, and a reseal pass tries many.
sub system_quiet {
	my @command = @_;
	open my $saved, '>&', \*STDERR or return system(@command);
	open STDERR, '>', '/dev/null' or do { close $saved; return system(@command) };
	my $status = system(@command);
	open STDERR, '>&', $saved;
	close $saved;
	return $status;
}

# A database backup is not a folder seal: backup_now appends its standard
# after the ciphertext, marked with the universal splitter (the restore path
# splits on it), so the tail tells the two apart without opening anything. The
# marker is 31 characters, which random ciphertext does not spell by accident.
sub reads_as_backup {
	my ($file) = @_;
	my $size = -s $file or return 0;
	my $take = $size > 512 ? 512 : $size;
	open my $fh, '<', $file or return 0;
	binmode $fh;
	seek $fh, $size - $take, 0;
	my $tail = '';
	read $fh, $tail, $take;
	close $fh;
	my $splitter = $gb::universal_splitter;
	return (defined $tail && defined $splitter && length $splitter && index($tail, $splitter) >= 0) ? 1 : 0;
}

# The rotation's tail on disk: walk the sealed files and put every one that
# opens under an old key back under the current one. The passwords are the ones
# a rotation leaves reachable - the current suds first, so an already re-sealed
# file is recognised and left alone, then every secret the security rows derive
# (the wrapped old keys among them, which is what finds the old seals). Nothing
# is ever lost to a guess: the original seal is replaced only once the new one
# is written and opens back to the identical bytes, a file no password opens is
# counted and left exactly as it was, database backups (recognised by the
# standard they append after the ciphertext) are left whole, and a file written
# since the rotation
# (mtime past `before`) is skipped without opening, since it is already under
# the new key. Batched by a time budget; when the budget runs out the job
# queues its own follow-up carrying a cursor - the walk is sorted, so the next
# run starts where this one stopped instead of re-walking the whole home.
# Where the sealed files live: the home plus every media location the misc
# settings name (music, download, photo, document, video, scan, rec). On a phone
# those point at /sdcard/... rather than the Termux home, so walking only ~ would
# leave a rotation's tail of /sdcard seals untouched.
sub folders_reseal_roots {
	my @roots = ( &home('~/') );
	foreach my $l ( &location_types() ) {
		my $loc = &setting_grabber({ app => 'misc', setting => $l . '_location' });
		push @roots, &home($loc) if (defined $loc && length $loc);
	}
	my %seen;
	return [ grep { !$seen{$_}++ } @roots ];
}

sub folders_reseal_job {
	my ($job, $data) = @_;
	my $suds = eval { &suds_grabber() };
	unless ($suds) { $job->fail('there is no key on this machine'); return }
	my $standard = &setting_grabber({ app => 'misc', setting => 'encryption_standard' }) || 'aes-256-ctr';
	my @passwords = ( $suds );
	my $secrets = &db_query('select * from security where level != ? and level != ? order by server_time DESC', 'padlock', 'door');
	foreach my $p ( @{$secrets->hashes} ) {
		my $secret = &decrypter($suds, $p->{'credential'});
		push @passwords, $secret if (defined $secret && length $secret);
	}
	my %seen;
	@passwords = grep { !$seen{$_}++ } @passwords;
	my $before = $data->{'before'} || 0;
	my $budget = $data->{'budget'} || 600;
	my $after = defined $data->{'after'} ? $data->{'after'} : '';
	my $roots = (ref $data->{'roots'} && scalar @{$data->{'roots'}}) ? $data->{'roots'} : &folders_reseal_roots();
	my $references = &file_reference_read();
	my $started = time();
	my @files = &sealed_files_under($roots);
	my ($resealed, $current, $unopened, $skipped, $backups, $passed, $count) = (0, 0, 0, 0, 0, 0, 0);
	my (@errors, $out_of_time, $cancelled);
	my $last = $after;
	foreach my $file ( @files ) {
		$count++;
		$job->note(progress => "re-sealed $resealed, current $current of " . scalar(@files) . " sealed files") if $count % 10 == 0;
		# a run that ran out of time left its cursor: everything at or before it
		# is already walked (the list is sorted, so this stays stable)
		if (length $after && $file le $after) { $passed++; next; }
		if (($job->info->{'notes'} || {})->{'cancel'}) { $cancelled = 1; last; }
		if (time() - $started > $budget) { $out_of_time = 1; last; }
		$last = $file;
		$job->note(cursor => $last) if $count % 25 == 0;
		# written since the rotation: already under the new key (stat is in
		# seconds, the stamps in milliseconds)
		if ($before && ((stat($file))[9] || 0) * 1000 > $before) { $skipped++; next; }
		# a database backup carries its standard appended after the ciphertext
		# (backup_now), so it is not a folder seal at all: leave it whole
		if (&reads_as_backup($file)) { $backups++; next; }
		my $remembered = &file_reference_remembered($references, $file) || {};
		my @standards = ( $remembered->{'standard'}, $standard );
		my %seen_standard;
		@standards = grep { defined $_ && length $_ && !$seen_standard{$_}++ } @standards;
		my $clear = $file . '.opening';
		my ($opened_with, $opened_standard);
		foreach my $which ( @standards ) {
			foreach my $password ( @passwords ) {
				next unless (defined $password && length $password);
				unlink $clear if -e $clear;
				my $status = &system_quiet('openssl', 'enc', '-d', '-k', $password, "-$which", '-pbkdf2', '-in', $file, '-out', $clear);
				next unless ($status == 0 && -e $clear);
				# nothing in the stream says which password is the one, so the
				# opening is read as a file the way the decrypt job reads one
				my $head = '';
				if (open my $fh, '<', $clear) { binmode $fh; read $fh, $head, 1024; close $fh; }
				my $type = &plaintext_verdict($head);
				if (defined $type || ((-s $clear) == 0 && (-s $file) <= 48)) {
					$opened_with = $password;
					$opened_standard = $which;
					last;
				}
			}
			last if defined $opened_with;
		}
		unless (defined $opened_with) {
			system('shred', '-u', $clear) if -e $clear;
			$unopened++;
			next;
		}
		if ($opened_with eq $suds) {
			system('shred', '-u', $clear) if -e $clear;
			$current++;
			next;
		}
		# an old seal: put it back under the current key. The original file is
		# only replaced once the new seal exists and opens to the same bytes.
		my $seal = $file . '.resealing';
		my $verify = $file . '.verifying';
		unlink $seal if -e $seal;
		my $status = system('openssl', 'enc', '-e', '-k', $suds, "-$opened_standard", '-pbkdf2', '-in', $clear, '-out', $seal);
		if ($status != 0 || !-e $seal || (-s $seal) == 0) {
			push @errors, $file . ': it could not be sealed again';
			system('shred', '-u', $clear) if -e $clear;
			unlink $seal if -e $seal;
			next;
		}
		unlink $verify if -e $verify;
		$status = system('openssl', 'enc', '-d', '-k', $suds, "-$opened_standard", '-pbkdf2', '-in', $seal, '-out', $verify);
		my $same = ($status == 0 && -e $verify) ? (system('cmp', '-s', $clear, $verify) == 0 ? 1 : 0) : 0;
		if (!$same) {
			push @errors, $file . ': the new seal did not open back to the same bytes';
			system('shred', '-u', $clear) if -e $clear;
			system('shred', '-u', $verify) if -e $verify;
			unlink $seal if -e $seal;
			next;
		}
		unless (rename $seal, $file) {
			push @errors, $file . ': the new seal could not take its place';
			system('shred', '-u', $clear) if -e $clear;
			system('shred', '-u', $verify) if -e $verify;
			unlink $seal if -e $seal;
			next;
		}
		system('shred', '-u', $clear) if -e $clear;
		system('shred', '-u', $verify) if -e $verify;
		$resealed++;
	}
	my $result = { resealed => $resealed, current => $current, unopened => $unopened, skipped => $skipped, backups => $backups, passed => $passed, cursor => $last, files => scalar @files };
	if (scalar @errors) { $result->{'errors'} = \@errors; $job->fail($result); return; }
	$result->{'cancelled'} = 1 if $cancelled;
	$job->note(progress => "re-sealed $resealed, current $current, unopened $unopened of " . scalar(@files));
	$job->finish($result);
	# out of time, not out of files: hand the next stretch to a fresh job (a
	# driver that carries the cursor itself passes nofollow)
	if ($out_of_time && length $last && !$data->{'nofollow'}) {
		my $run = ($data->{'run'} || 1) + 1;
		eval { &minion_grabber()->enqueue('folders_reseal' => [ { before => $before, budget => $budget, run => $run, roots => $data->{'roots'}, after => $last } ] => { attempts => 2 }) } if $run <= 20;
	}
	return;
}

# --- key propagation -----------------------------------------------------------
# A rotation has to reach the rest of the house, or the machines drift apart:
# each one ends up holding a different key, and only the machine that rotated
# can read what it sealed. So a rotation queues a push: the new key is handed
# to every linked machine over the signed peer rail, wrapped under the key it
# replaced. Only a machine still on that key can open it, and a machine on a
# different lineage fails the unwrap and keeps its own - divergence is not
# healed by adopting a stranger's key. A machine that is away needs no push: the
# canary syncs with the database, its next key resolution finds a vault that no
# longer validates and pulls the new key the way a keyless machine does.
sub key_push_envelope {
	my $Knew = &suds_grabber();
	return unless $Knew;
	my $rows = &db_query('select credential from security where level = ? order by server_time desc', 'oldkey')->hashes;
	foreach my $row ( @{$rows} ) {
		my $Kold = &crypt_simple_unwrap($Knew, $row->{'credential'});
		next unless defined $Kold && length $Kold;
		my $proved = &encrypter($Kold, $Knew);
		next unless defined $proved && length $proved;
		return { proved => $proved, from => &suds_id($Kold) };
	}
	return;
}

1;
