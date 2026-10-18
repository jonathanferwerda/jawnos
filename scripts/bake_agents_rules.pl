#!/usr/bin/perl

# Bake the Coding agent's protocols out of AGENTS.md into a tracked file.
#
# AGENTS.md is gitignored (it carries fixtures and a login-token path), so it
# cannot ride the repo; a fresh clone or another machine would not have it. This
# copies just the protocol sections - the rules the coding agent must follow -
# into docs/coding_agent_protocols.md, which IS tracked, so every machine has
# them. The pre-commit hook runs this whenever AGENTS.md changes.
#
#   perl scripts/bake_agents_rules.pl          # regenerate (prints when changed)
#
# Idempotent: writes only when the result differs.

use strict;
use warnings;
use File::Slurp qw(read_file write_file);

my $src = 'AGENTS.md';
my $out = 'docs/coding_agent_protocols.md';

# Nothing to bake without the source (a fresh clone has only the baked file).
exit 0 unless -f $src;

my $text = read_file($src);

# The sections that are protocol, not map: the stop rule, how to run/restart, the
# crash-resilient work protocol, and the Rules (which carry the finishing routine).
# Matched by heading prefix.
my @keep = ( qr/^RULE\s*1\b/i, qr/^Run\s*&\s*restart/i, qr/^Crash-resilient\b/i, qr/^Rules\b/i );

my @sections;
my ($head, @body);
foreach my $line ( split /\n/, $text, -1 ) {
	if ($line =~ /^##\s+(.+?)\s*$/) {
		push @sections, { head => $head, body => join("\n", @body) } if defined $head;
		$head = $1;
		@body = ();
		next;
	}
	push @body, $line if defined $head;
}
push @sections, { head => $head, body => join("\n", @body) } if defined $head;

my $picked = '';
foreach my $s ( @sections ) {
	next unless grep { $s->{'head'} =~ $_ } @keep;
	$picked .= '## ' . $s->{'head'} . "\n" . $s->{'body'} . "\n\n";
}
$picked =~ s/\s+$//;

my $doc = <<"HEAD";
# Coding agent protocols

GENERATED — do not edit by hand. Built from AGENTS.md (gitignored, so it cannot
ride the repo) by scripts/bake_agents_rules.pl; the pre-commit hook refreshes it
whenever AGENTS.md changes. This is what the Coding agent is told to follow on
every machine.

$picked
HEAD

my $old = eval { read_file($out) } // '';
exit 0 if $old eq $doc;

write_file($out, $doc);
print "bake_agents_rules: wrote $out\n";
