#!/usr/bin/perl

# The download manifest both release publishers write.
#
# `server/downloads.json` is tracked and served from raw.githubusercontent, so
# jawnos.ca sees a release only after the change is committed. Rewriting the
# file on every publish left the checkout dirty even when the build it names
# was already there, because the `generated` stamp moved. A publish for the
# same build must leave the file byte-for-byte alone; a real change is still
# written for the release routine to commit.
#
# This is a library, not a command: app_publish.pl and mkosi_publish.pl require
# it. Each passes its own encoder and decoder, so the file keeps the exact
# spelling (Mojo::JSON for the app, canonical pretty JSON::PP for the image).

package PublishManifest;

use strict;
use warnings;

use JSON::PP ();

# update($path, $payload, $encode, $decode) -> 1 written, 0 unchanged.
#
# $payload holds the top-level keys this publisher owns (`app` or `desktop`);
# the other keys already in the file are preserved. `generated` is ignored when
# deciding whether anything changed, and is refreshed only on a real write.
sub update {
	my ($path, $payload, $encode, $decode) = @_;
	my $data = {};
	if (-f $path) {
		my $text = '';
		if (open(my $fh, '<', $path)) { local $/; $text = <$fh>; close $fh; }
		$data = eval { $decode->($text) } || {} if length $text;
	}
	my $merged = { %$data, %{ $payload || {} } };
	return 0 if _canonical($data) eq _canonical($merged);

	my @t = gmtime(time());
	$merged->{'generated'} = sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ',
		$t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0]);
	my $json = $encode->($merged);
	return 0 unless defined $json;
	open(my $out, '>', $path) or return 0;
	print {$out} $json;
	close $out;
	return 1;
}

# A stable string for the manifest without its generated stamp. The values are
# ordinary JSON shapes; a boolean is a blessed scalar, so its truth value is the
# comparison (the `ok` flags are the only ones either publisher writes).
sub _canonical {
	my ($value) = @_;
	return JSON::PP->new->canonical->allow_nonref->encode(_normal($value));
}

sub _normal {
	my ($value) = @_;
	return undef unless defined $value;
	if (ref $value eq 'HASH') {
		return {
			map { $_ => _normal($value->{$_}) }
			grep { $_ ne 'generated' } keys %$value
		};
	}
	if (ref $value eq 'ARRAY') {
		return [ map { _normal($_) } @$value ];
	}
	return $value ? 1 : 0 if ref $value;
	return $value;
}

1;
