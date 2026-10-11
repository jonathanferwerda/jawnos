#!/usr/bin/perl

# Bump the JawnOS patch version in ./VERSION (e.g. 0.1.1 -> 0.1.2).
# Run this before each commit until 0.2, when the minor bump becomes manual.

use strict;
use warnings;
use File::Slurp qw(read_file write_file);

my $file = './VERSION';
my $v = eval { read_file($file) } || '0.1.0';
$v =~ s/\s+$//;
$v = '0.1.0' unless $v =~ /^\d+\.\d+\.\d+$/;

my ($major, $minor, $patch) = split /\./, $v;
$v = "$major.$minor." . ($patch + 1);
write_file($file, "$v\n");
print "$v\n";
