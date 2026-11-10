#!/usr/bin/perl
# media_stub_audit.pl - find the one- and three-byte stubs a broken sync merge
# wrote over real media, and (with a peer) fetch the real file back.
#
#   perl scripts/media_stub_audit.pl
#   perl scripts/media_stub_audit.pl --json
#   perl scripts/media_stub_audit.pl --root ~/Pictures --root ~/Documents
#   perl scripts/media_stub_audit.pl --from <remote_uuid> --apply
#
# /file_open answers a file it cannot serve with a plain word: "no" (auth/lock),
# "none" (nothing to send) or "not found". MIME::Base64 is lenient, so a merge
# that decoded that word as the file body wrote decode_base64("no") = the one
# byte 0x9e or decode_base64("none") = 0x9e 0x89 0xde over the media path. An
# empty body wrote a zero-byte file. Those stubs then travelled to every machine
# that pulled the row, and a main_image naming one draws nothing.
#
# This audit lists them. Nothing is written without --apply, and --apply only
# replaces a stub when --from names a peer and subs::synced_file_payload accepts
# the answer - a peer that also holds a stub is refused, so a stub never
# overwrites a stub. A successful fetch is written beside the stub and renamed
# into place, so a short answer cannot leave half a picture.
#
# The fix that stops new stubs is in Manager/Part17.pm (synced_file_payload).
use strict;
use warnings;
use FindBin;
use File::Find;
use Mojo::File;
require Mojo::JSON;
chdir "$FindBin::Bin/.." or die "cannot find the jawnos root: $!";
require './perl/subroutines.pl';

# The scan is a plain function so a test can drive it against a throwaway tree
# with no database; main is the CLI wrapper.
sub media_stub_scan {
	my ($roots) = @_;
	my (@files, $bytes);
	my %seen_root;
	$bytes = 0;
	foreach my $root ( @{$roots} ) {
		next unless defined $root && length $root;
		my $real = &subs::home($root);
		next unless -d $real;
		$seen_root{$real} = 1;
		File::Find::find({
			no_chdir => 1,
			wanted => sub {
				my $path = $File::Find::name;
				return unless -f $path && $path =~ /\.enc\z/i;
				return unless &subs::file_sentinel_stub($path);
				my $size = -s $path || 0;
				$bytes += $size;
				push @files, { path => $path, size => $size };
			},
		}, $real);
	}
	@files = sort { $a->{'path'} cmp $b->{'path'} } @files;
	my %by_root;
	my %kind = (one => 0, three => 0, empty => 0);
	foreach my $f ( @files ) {
		my ($root) = grep { index($f->{'path'}, $_) == 0 } keys %seen_root;
		$root //= '(other)';
		$by_root{$root}++;
		$kind{'empty'}++ if $f->{'size'} == 0;
		$kind{'one'}++ if $f->{'size'} == 1;
		$kind{'three'}++ if $f->{'size'} == 3;
	}
	return {
		roots => [ sort keys %seen_root ],
		files => \@files,
		total => scalar @files,
		bytes => $bytes,
		kind => \%kind,
		by_root => \%by_root,
	};
}

# The appointment row that names this file, found by its basename. The row's
# path is the peer's own path, which is what --apply must ask the peer for.
sub media_stub_references {
	my $by_base = {};
	my $rows = eval { &subs::db_query("select app, uuid, file from appointments where file is not null and file != ''")->hashes } || [];
	foreach my $row ( @{$rows} ) {
		my $files = eval { return Mojo::JSON::decode_json($row->{'file'}) } || [];
		$files = [ $files ] if ref $files eq 'HASH';
		foreach my $fi ( @{$files} ) {
			next unless ref $fi eq 'HASH';
			foreach my $key ( qw(f thumb preview) ) {
				my $path = $fi->{$key};
				next unless defined $path && length $path;
				my ($base) = $path =~ m{([^/]+)\z};
				next unless defined $base && length $base;
				$by_base->{$base} ||= { app => $row->{'app'}, uuid => $row->{'uuid'}, peer_path => $path };
			}
		}
	}
	return $by_base;
}

# The file an app's main_image setting resolves to on this machine, using the
# same fallback the gallery uses for a row another machine wrote.
sub media_stub_main_image_path {
	my ($app, $value) = @_;
	return '' unless defined $value && length $value;
	return '' if $value =~ /\Adata:image\//i;
	return $value if -e $value;
	my ($destination, $asset) = &subs::file_device_renamer({ file => $value, app => $app, type => 'image' });
	my $local = (defined $destination && defined $asset) ? $destination . $asset : '';
	return (-e $local) ? $local : '';
}

sub media_stub_main_images {
	my $rows = eval { &subs::db_query("select app, device, value from settings where setting = 'main_image' and value is not null and value != ''")->hashes } || [];
	my @out;
	foreach my $row ( @{$rows} ) {
		my $local = &media_stub_main_image_path($row->{'app'}, $row->{'value'});
		next unless length $local;
		next unless &subs::file_sentinel_stub($local);
		push @out, {
			app => $row->{'app'},
			device => $row->{'device'},
			value => $row->{'value'},
			local => $local,
			size => (-s $local || 0),
		};
	}
	return [ sort { $a->{'app'} cmp $b->{'app'} } @out ];
}

sub media_stub_heal {
	my ($agent, $file, $peer_path) = @_;
	my $url = $agent->{'manager'} . '/file_open?as_is=yes&file=' . &subs::url_escape_utf8($peer_path);
	my $res = eval { $agent->{'ua'}->get($url)->result };
	return (0, 'no answer') unless $res;
	return (0, 'HTTP ' . ($res->code || '?')) unless $res->is_success;
	my $bytes = &subs::synced_file_payload($res->body, $file->{'path'});
	return (0, 'the peer answered with a refusal or a stub') unless defined $bytes && length $bytes;
	my $temp = $file->{'path'} . '.heal.' . int(rand(1_000_000));
	eval { Mojo::File->new($temp)->spurt($bytes) };
	unless (-e $temp && (-s $temp || 0) == length($bytes)) {
		unlink $temp;
		return (0, 'could not write beside the stub');
	}
	unless (rename $temp, $file->{'path'}) {
		unlink $temp;
		return (0, 'could not replace the stub');
	}
	return (1, undef);
}

sub main {
	my (@argv) = @_;
	my ($json, $apply, $no_db, $check, $from, $limit);
	$limit = 200;
	my @roots;
	for (my $i = 0; $i < @argv; $i++) {
		my $a = $argv[$i];
		$json = 1 if $a eq '--json';
		$apply = 1 if $a eq '--apply';
		$no_db = 1 if $a eq '--no-db';
		$check = 1 if $a eq '--check';
		push @roots, $argv[$i + 1] if $a eq '--root' && defined $argv[$i + 1];
		$from = $argv[$i + 1] if $a eq '--from' && defined $argv[$i + 1];
		$limit = $argv[$i + 1] if $a eq '--limit' && defined $argv[$i + 1] && $argv[$i + 1] =~ /^\d+$/;
	}

	unless (@roots) {
		# The configured media homes, not a guessed default: a machine that keeps
		# pictures elsewhere must still be scanned where it actually writes them.
		my $device = &subs::device_setter();
		my $misc = &subs::misc_setting_list();
		foreach my $key ( qw(photo_location music_location rec_location video_location document_location download_location scan_location) ) {
			my $value = $misc->{$device}->{$key} // $misc->{'all'}->{$key};
			push @roots, $value if defined $value && length $value;
		}
	}
	if ($apply && !(defined $from && length $from)) {
		print "media stub audit: --apply needs --from <remote_uuid> to say which machine to ask\n";
		return 1;
	}
	my $agent;
	if ($apply) {
		$agent = &subs::remote_agent_for($from);
		if ($agent->{'error'}) {
			print 'media stub audit: ' . $agent->{'error'} . "\n";
			return 1;
		}
	}

	my $scan = &media_stub_scan(\@roots);
	my $refs = $no_db ? {} : &media_stub_references();
	my $mains = $no_db ? [] : &media_stub_main_images();

	my ($healed, @refused) = (0);
	if ($apply) {
		foreach my $file ( @{ $scan->{'files'} } ) {
			my ($base) = $file->{'path'} =~ m{([^/]+)\z};
			my $ref = $refs->{$base} || {};
			my $peer_path = $ref->{'peer_path'} || $file->{'path'};
			my ($ok, $why) = &media_stub_heal($agent, $file, $peer_path);
			if ($ok) { $healed++ }
			else { push @refused, { path => $file->{'path'}, why => $why } }
		}
	}

	if ($json) {
		my @stubs;
		foreach my $file ( @{ $scan->{'files'} } ) {
			last if scalar @stubs >= $limit;
			my ($base) = $file->{'path'} =~ m{([^/]+)\z};
			push @stubs, { path => $file->{'path'}, size => $file->{'size'}, ref => $refs->{$base} || {} };
		}
		print Mojo::JSON::encode_json({
			roots => $scan->{'roots'},
			total => $scan->{'total'},
			bytes => $scan->{'bytes'},
			kind => $scan->{'kind'},
			by_root => $scan->{'by_root'},
			stubs => \@stubs,
			main_images => $mains,
			healed => $healed,
			refused => \@refused,
		}), "\n";
		return 0;
	}

	printf "media stub audit - %d stub(s), %d byte(s) across %d root(s)\n",
		$scan->{'total'}, $scan->{'bytes'}, scalar @{ $scan->{'roots'} };
	printf "  %d one-byte (0x9e, from \"no\"), %d three-byte (0x9e 89 de, from \"none\"), %d empty\n",
		$scan->{'kind'}->{'one'}, $scan->{'kind'}->{'three'}, $scan->{'kind'}->{'empty'};
	foreach my $root ( sort keys %{ $scan->{'by_root'} } ) {
		printf "  %-8d %s\n", $scan->{'by_root'}->{$root}, $root;
	}
	if (scalar @{$mains}) {
		print "\nmain_image rows that resolve to a stub (the blank icons):\n";
		foreach my $m ( @{$mains} ) {
			printf "  %-24s %-8s %s -> %s\n", $m->{'app'}, $m->{'device'}, $m->{'value'}, $m->{'local'};
		}
	}
	if ($scan->{'total'} > $limit) {
		printf "\n(first %d paths below; --limit N raises it)\n", $limit;
	}
	my $shown = 0;
	foreach my $file ( @{ $scan->{'files'} } ) {
		last if $shown++ >= $limit;
		my ($base) = $file->{'path'} =~ m{([^/]+)\z};
		my $ref = $refs->{$base};
		printf "  %d  %s%s\n", $file->{'size'}, $file->{'path'},
			($ref ? '  [' . $ref->{'app'} . ' ' . $ref->{'uuid'} . ']' : '');
	}
	if ($apply) {
		printf "\nhealed %d stub(s)", $healed;
		printf ", refused %d", scalar @refused if @refused;
		print "\n";
		foreach my $r ( @refused[0 .. ($#refused > 19 ? 19 : $#refused)] ) {
			print '  REFUSED  ' . $r->{'path'} . ' - ' . $r->{'why'} . "\n";
		}
		print "  (first 20 refusals)\n" if @refused > 20;
	}
	print $apply ? "\ndone.\n" : "\ndone - nothing written.\n";
	return ($check && $scan->{'total'} > 0) ? 1 : 0;
}

exit(main(@ARGV)) unless caller;

1;
