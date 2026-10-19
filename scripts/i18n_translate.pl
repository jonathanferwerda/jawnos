#!/usr/bin/perl
#
# i18n_translate.pl - fill the per-language UI/help catalogs.
#
#   perl scripts/i18n_extract.pl
#   perl scripts/i18n_translate.pl                 # every listed language
#   perl scripts/i18n_translate.pl --langs fr,de   # just those
#   perl scripts/i18n_translate.pl --limit 20      # a small first pass
#
# Reads i18n/strings.json (the extractor's output), asks the local Ollama for a
# translation of each missing string, and writes i18n/ui-<code>.json. It is
# resumable: strings already present are skipped, and the file is saved after
# every batch, so a dropped run can be repeated.
#
# The default model is gemma4:cloud, the free Ollama plan model on this box.
# Pass --model to use another. Nothing here runs at app startup; it is a build
# step, and the generated catalogs are committed with the feature.

use strict;
use warnings;
use utf8;
use FindBin qw($Bin);
use Cwd ();
use Getopt::Long qw(GetOptions);
use Mojo::JSON qw(encode_json decode_json);
use Mojo::UserAgent;
use File::Slurp qw(read_file write_file);
use Encode qw(decode);
use JSON::PP ();
use Time::HiRes qw(sleep);
use Unicode::Normalize qw(NFC);

binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';

my $root = Cwd::abs_path("$Bin/..");
chdir $root or die "cannot chdir to $root: $!\n";
require "./language.pl";
no warnings 'once';

my $model       = 'gemma4:cloud';
my $limit       = 0;
my $batch_chars = 6000;
my $batch_count = 35;
my $retries     = 2;
my $pause       = 0.15;
my $dry_run     = 0;
my $langs_opt   = '';
GetOptions(
	'model=s'       => \$model,
	'limit=i'       => \$limit,
	'batch-chars=i' => \$batch_chars,
	'batch-count=i' => \$batch_count,
	'retries=i'     => \$retries,
	'sleep=f'       => \$pause,
	'dry-run'       => \$dry_run,
	'langs=s'       => \$langs_opt,
) or die "bad options\n";

my $catalog_file = 'i18n/strings.json';
unless ( -e $catalog_file ) {
	die "missing $catalog_file - run perl scripts/i18n_extract.pl first\n";
}
my $data = decode_json( scalar read_file($catalog_file) );
my @strings = map { $_->{'text'} } @{ $data->{'strings'} || [] };
die "no strings in $catalog_file\n" unless @strings;
@strings = @strings[ 0 .. $limit - 1 ] if $limit > 0;

my @targets = grep { $_->{'code'} ne 'en' } @language::languages;
if ( length $langs_opt ) {
	my %want = map { $_ => 1 } split /\s*,\s*/, $langs_opt;
	@targets = grep { $want{ $_->{'code'} } } @targets;
}
die "no target languages\n" unless @targets;

my $ua = Mojo::UserAgent->new(
	connect_timeout    => 5,
	inactivity_timeout => 240,
	request_timeout    => 300,
);

sub load_done {
	my ($file) = @_;
	return {} unless -e $file;
	my $raw = read_file($file);
	my $d = eval { decode_json($raw) };
	return ref $d eq 'HASH' ? $d : {};
}

sub save_done {
	my ( $file, $done ) = @_;
	write_file( $file, JSON::PP->new->canonical->pretty->utf8->encode($done) );
}

sub json_object_from {
	my ($text) = @_;
	return undef unless defined $text && length $text;
	my $start = index( $text, '{' );
	return undef if $start < 0;
	# A balanced scan, not the last brace: the model may put a sentence after
	# the object, and a brace in that sentence would swallow the JSON.
	my $depth = 0;
	my $in = 0;
	my $esc = 0;
	my $end = -1;
	for my $i ( $start .. length($text) - 1 ) {
		my $c = substr( $text, $i, 1 );
		if ($in) {
			if ($esc) { $esc = 0 }
			elsif ( $c eq '\\' ) { $esc = 1 }
			elsif ( $c eq '"' ) { $in = 0 }
			next;
		}
		if ( $c eq '"' ) { $in = 1 }
		elsif ( $c eq '{' ) { $depth++ }
		elsif ( $c eq '}' ) {
			$depth--;
			if ( $depth == 0 ) { $end = $i; last }
		}
	}
	return undef if $end < 0;
	my $slice = substr( $text, $start, $end - $start + 1 );
	$slice = decode('UTF-8', $slice) unless utf8::is_utf8($slice);
	my $parsed = eval { JSON::PP->new->utf8(0)->decode($slice) };
	warn "json parse: $@\n" if $@;
	return $parsed;
}

sub norm_key {
	my $s = shift // '';
	$s = NFC($s);
	$s =~ s/\s+/ /g;
	$s =~ s/^\s+|\s+$//g;
	return $s;
}

sub pick_translation {
	my ( $got, $wanted ) = @_;
	return $got->{$wanted} if defined $got->{$wanted} && length $got->{$wanted};
	my $nw = &norm_key($wanted);
	foreach my $k ( keys %{$got} ) {
		next unless defined $got->{$k} && length $got->{$k};
		return $got->{$k} if &norm_key($k) eq $nw;
	}
	return undef;
}

sub ask_batch {
	my ( $lang, $batch ) = @_;
	my $native = $lang->{'native'} || $lang->{'name'};
	my $code   = $lang->{'code'};
	my $system = 'You translate software interface and help text precisely. Reply only with a JSON object and no commentary.';
	my $batch_json = JSON::PP->new->utf8(0)->encode($batch);
	my $user   = "Translate every string in this JSON array into $native ($code).\n"
		. "Rules:\n"
		. "- Return ONLY a JSON object whose keys are the exact input strings and whose values are the translations.\n"
		. "- Do not omit, merge, split or add keys.\n"
		. "- Preserve placeholders such as {0} and {1}, HTML entities, punctuation, file paths, code identifiers, and product names (JawnOS, Jawn, Ollama, Piper, Linux, Windows, Android) exactly.\n"
		. "- Translate UI labels naturally. Keep help text complete; do not summarize it.\n"
		. "- If a string is only a product name or code token, keep it unchanged.\n"
		. "Input JSON array:\n" . $batch_json;

	my $payload = {
		model    => $model,
		stream   => JSON::PP::false,
		options  => { temperature => 0.1, num_predict => 12000 },
		messages => [
			{ role => 'system', content => $system },
			{ role => 'user',   content => $user },
		],
	};

	for my $try ( 1 .. $retries + 1 ) {
		my $tx = eval { $ua->post( 'http://127.0.0.1:11434/api/chat' => json => $payload ) };
		unless ($tx && $tx->result && $tx->result->is_success) {
			my $err = $tx ? ( $tx->error->{'message'} || 'request failed' ) : $@;
			warn "  $code: $err (attempt $try)\n";
			sleep 2;
			next;
		}
		my $body = eval { $tx->result->json };
		my $content = ref $body eq 'HASH' ? $body->{'message'}{'content'} : undef;
		my $obj = json_object_from($content);
		if ( ref $obj eq 'HASH' ) {
			return $obj;
		}
		if ( ref $obj eq 'ARRAY' && scalar( @{$obj} ) == scalar( @{$batch} ) ) {
			my %as_hash;
			@as_hash{ @{$batch} } = @{$obj};
			return \%as_hash;
		}
		my $snippet = defined $content ? substr( $content, 0, 240 ) : '(no content)';
		$snippet =~ s/\s+/ /g;
		warn "  $code: reply was not a JSON object (attempt $try): $snippet\n";
		sleep 1;
	}
	return {};
}

foreach my $lang (@targets) {
	my $code = $lang->{'code'};
	my $file = "i18n/ui-$code.json";
	my $done = &load_done($file);
	my @pending = grep { !( defined $done->{$_} && length $done->{$_} ) } @strings;
	my $already = scalar(@strings) - scalar(@pending);
	print "$code ($lang->{'native'}): " . scalar(@pending) . " pending, $already already translated\n";
	next unless @pending;

	my @queue = sort { length($a) <=> length($b) } @pending;
	my $batch_no = 0;
	while (@queue) {
		my ( @batch, $chars );
		$chars = 0;
		while (@queue) {
			my $s = $queue[0];
			last if @batch && ( @batch >= $batch_count || $chars + length($s) > $batch_chars );
			push @batch, shift @queue;
			$chars += length($s);
			last if $chars >= $batch_chars;
		}
		$batch_no++;
		print "  batch $batch_no: " . scalar(@batch) . " strings, $chars chars\n";
		if ($dry_run) {
			next;
		}
		my $got = &ask_batch( $lang, \@batch );
		my @missing;
		foreach my $s (@batch) {
			my $t = &pick_translation( $got, $s );
			if ( defined $t && length $t ) {
				$done->{$s} = $t;
			}
			else {
				push @missing, $s;
			}
		}
		if (@missing && @batch > 1) {
			# The batch reply may have been cut off or malformed. Split the
			# failures in half and ask again before falling back to one by one.
			my $mid = int( @missing / 2 );
			my @halves = ( [ @missing[ 0 .. $mid - 1 ] ], [ @missing[ $mid .. $#missing ] ] );
			foreach my $half (@halves) {
				next unless @{$half};
				my $more = &ask_batch( $lang, $half );
				foreach my $s ( @{$half} ) {
					my $t = &pick_translation( $more, $s );
					$done->{$s} = $t if defined $t && length $t;
				}
			}
			@missing = grep { !( defined $done->{$_} && length $done->{$_} ) } @missing;
		}
		if (@missing) {
			# one more, one string at a time, for the ones the batch missed
			foreach my $s (@missing) {
				my $one = &ask_batch( $lang, [$s] );
				my $t = &pick_translation( $one, $s );
				if ( defined $t && length $t ) {
					$done->{$s} = $t;
				}
				else {
					warn "  $code: still missing: " . substr( $s, 0, 70 ) . "\n";
				}
			}
		}
		&save_done( $file, $done );
		print "  saved $file (" . scalar( keys %{$done} ) . " strings)\n";
		sleep $pause if $pause > 0;
	}
}

print "i18n_translate: done\n";
1;
