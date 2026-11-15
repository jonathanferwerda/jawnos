#!/bin/sh
# Count the lines the house wrote, once a night, and leave the run where
# Configure -> Plat -> QA reads it.
#
#   qa/loc_nightly.sh                 # count the tree and publish the report
#   QA_ROOT=/tmp/qa STAMP=20260101T000000Z qa/loc_nightly.sh   # a rehearsal
#
# Driven by qa/systemd/jawnos-qa-loc.timer (02:30, nightly). The count itself is
# scripts/loc.pl --json, so the panel and a person see the same number: the
# authored lines, with vendored libraries and generated data left out.
#
# The report is one directory per run under $QA_ROOT/reports/loc/<stamp>/:
#   report.json   the document the panel renders
#   status.txt    the one word the panel falls back to
# A table per language and a flat metrics object (authored_code and friends),
# which is also the point the panel's trend reads, so a night that cannot run
# leaves no point rather than a zero.
#
# A count is only attributable to a tree if the tree is named: the note always
# carries the short SHA and a `+dirty` marker, because loc.pl reads the tracked
# files as they are on disk and a nightly on a dirty checkout is counting edits
# nobody committed. `skipped` means there was no checkout or no git to list it.

set -eu

REPO=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
QA_ROOT=${QA_ROOT:-$HOME/jawnos-qa}
STAMP=${STAMP:-$(date -u +%Y%m%dT%H%M%SZ)}
RUN_DIR="$QA_ROOT/loc/$STAMP"
JSON="$RUN_DIR/loc.json"
METRICS="$RUN_DIR/metrics.json"
TSV="$RUN_DIR/languages.tsv"
KEEP_DAYS=14

# The count only reads the index; a read-only checkout must not be refreshed.
GIT_OPTIONAL_LOCKS=0
export GIT_OPTIONAL_LOCKS

mkdir -p "$QA_ROOT/loc"

# One count at a time: a manual run and the timer would otherwise write the
# same stamp directory.
if command -v flock > /dev/null 2>&1; then
	exec 9> "$QA_ROOT/loc/.lock"
	if ! flock -n 9; then
		echo "qa-loc: another count is running (lock $QA_ROOT/loc/.lock)" >&2
		exit 3
	fi
fi

mkdir -p "$RUN_DIR"

# $1 status, $2 note, then optional --table/--metrics arguments.
publish() {
	status=$1
	note=$2
	shift 2
	perl "$REPO/scripts/qa_report.pl" --kind=loc --schedule=nightly \
		--status "$status" --title 'Line count' --note "$note" --stamp "$STAMP" \
		"$@" --root "$QA_ROOT" >/dev/null 2>&1 \
		|| { echo "qa-loc: could not write the report" >&2; return 1; }
}

skip() {
	publish skipped "$1"
	echo "qa-loc: skipped - $1"
	exit 0
}

command -v git > /dev/null 2>&1 || skip 'git is not installed, so there is no tracked tree to count'
git -C "$REPO" rev-parse --git-dir > /dev/null 2>&1 || skip 'no git checkout here, so there is no tracked tree to count'

# Named before the count, so a run that fails still says which tree failed.
SHA=$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo unknown)
DIRTY=
if [ -n "$(git -C "$REPO" status --porcelain 2>/dev/null)" ]; then
	DIRTY='+dirty'
fi

if ! perl "$REPO/scripts/loc.pl" --json > "$JSON" 2> "$RUN_DIR/loc.err"; then
	reason=$(tail -1 "$RUN_DIR/loc.err" 2>/dev/null || :)
	publish failed "the count failed at $SHA$DIRTY${reason:+: $reason}"
	echo "qa-loc: the count failed" >&2
	exit 1
fi

# The panel's two documents from the one count: flat metrics (the trend reads
# authored_code from here) and a table per language.
SUMMARY=$(perl -MJSON::PP -e '
	my ($json, $metrics, $tsv) = @ARGV;
	open(my $fh, "<", $json) or die "loc: $json: $!\n";
	local $/;
	my $doc = JSON::PP::decode_json(<$fh>);
	close $fh;
	my $total = $doc->{"total"} || {};
	my $vendored = $doc->{"vendored"} || {};
	my %m = (
		authored_code   => 0 + ($total->{"code"} // 0),
		authored_lines  => 0 + ($total->{"lines"} // 0),
		authored_files  => 0 + ($total->{"files"} // 0),
		comment_lines   => 0 + ($total->{"comment"} // 0),
		blank_lines     => 0 + ($total->{"blank"} // 0),
		vendored_lines  => 0 + ($vendored->{"lines"} // 0),
	);
	open(my $mf, ">", $metrics) or die "loc: $metrics: $!\n";
	print {$mf} JSON::PP->new->canonical->pretty->encode(\%m);
	close $mf;
	open(my $tf, ">", $tsv) or die "loc: $tsv: $!\n";
	print {$tf} "Language\tFiles\tLines\tCode\n";
	for my $row (@{ $doc->{"languages"} || [] }) {
		print {$tf} join("\t", $row->{"language"} // "",
			map { 0 + ($row->{$_} // 0) } qw(files lines code)), "\n";
	}
	printf {$tf} "TOTAL\t%d\t%d\t%d\n", @m{qw(authored_files authored_lines authored_code)};
	close $tf;
	sub commas { my $n = shift; 1 while $n =~ s/^(-?\d+)(\d{3})/$1,$2/; return $n; }
	print commas($m{"authored_code"}), " authored lines in ", commas($m{"authored_files"}), " files";
' "$JSON" "$METRICS" "$TSV") || {
	publish failed 'the count could not be turned into a report'
	echo "qa-loc: the count could not be turned into a report" >&2
	exit 1
}

publish ok "$SUMMARY at $SHA$DIRTY" --table "Languages:$TSV" --metrics "$METRICS"
echo "qa-loc: $SUMMARY at $SHA$DIRTY"

# The report tree ages out through qa_report.pl on every write; the run dirs
# (count, metrics, table) follow the same 14 days here.
find "$QA_ROOT/loc" -mindepth 1 -maxdepth 1 -type d -mtime +"$KEEP_DAYS" \
	-exec rm -rf {} + 2>/dev/null || :

exit 0
