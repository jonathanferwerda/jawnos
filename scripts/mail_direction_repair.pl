#!/usr/bin/env perl
# mail_direction_repair.pl - put an sms row's direction back from the record the
# phone's own message store left beside it.
#
#   perl scripts/mail_direction_repair.pl [--apply] [--verbose] [--json]
#                                         [--window MS]
#
# sms_list_check writes one appointment per message the phone's store hands over,
# and its notes open with that store's own type: "Sent: ...", "Inbox: ...". An
# older import then filed the mailbox row 'public', and the depublicizer rewrote
# every public row 'sent', so a reply could come to wear the house's name. This
# reads the surviving appointment note and puts the mailbox row's status back to
# sent/inbox. It is a dry run unless --apply is given, is idempotent, and never
# touches a row a person marked 'ignored'.
#
# The phone's live sms list is only the newest few messages; the appointment log
# is the whole history this house filed, so the log is the source here. New
# messages are filed correctly by sms_list_check itself.
use strict;
use warnings;
use FindBin;
require Mojo::JSON;
# Run against the tree that holds the live database. A measurement or repair
# from a worktree must not bootstrap a second house database there.
my $root = $ENV{'JAWNOS_ROOT'} || "$FindBin::Bin/..";
chdir $root or die "cannot find the jawnos root at $root: $!";
require './perl/subroutines.pl';

my ($apply, $verbose, $json, $window, $duplicates, $seal_plain, $thread_dupes, $same_window) = (0, 0, 0, 0, 0, 0, 0, 5000);
for (my $i = 0; $i < @ARGV; $i++) {
	$apply = 1 if $ARGV[$i] eq '--apply';
	$verbose = 1 if $ARGV[$i] eq '--verbose';
	$json = 1 if $ARGV[$i] eq '--json';
	$duplicates = 1 if $ARGV[$i] eq '--duplicates';
	$seal_plain = 1 if $ARGV[$i] eq '--seal-plain';
	$thread_dupes = 1 if $ARGV[$i] eq '--thread-duplicates';
	if ($ARGV[$i] eq '--same-window' && defined $ARGV[$i + 1] && $ARGV[$i + 1] =~ /^[0-9]+$/) {
		$same_window = 0 + $ARGV[$i + 1];
		$i++;
	}
	if ($ARGV[$i] eq '--window' && defined $ARGV[$i + 1] && $ARGV[$i + 1] =~ /^[0-9]+$/) {
		$window = 0 + $ARGV[$i + 1];
		$i++;
	}
}
die "usage: $0 [--apply] [--verbose] [--json] [--window MS] [--same-window MS] [--duplicates] [--seal-plain] [--thread-duplicates]\n" if @ARGV && $ARGV[0] =~ /^-h/;

my $suds = subs::suds_grabber();

# The millisecond-date bug wrote a mailbox row each time its import retried, so
# a thread can hold hundreds of copies of one message, all marked 'sent'. The
# records audit already names which copy to keep and which to tombstone; this
# pass runs only its mailbox half, never the appointment repairs.
my @dupe_actions;
my @same_event;
my %same_seen;
my %dupe_stats = (tombstone => 0, 'repair-date' => 0);
if ($duplicates) {
	my $report = subs::records_audit(0);
	foreach my $r ( @{ $report->{'mailbox_bad_dates'} || [] } ) {
		my $fix = $r->{'fix'} or next;
		if (($r->{'suggested'} // '') eq 'tombstone') {
			push @dupe_actions, { action => 'tombstone', row => $r, why => $r->{'why'} };
			subs::records_mailbox_tombstone($r) if $apply;
		}
		else {
			push @dupe_actions, { action => 'repair-date', row => $r, fix => $fix, why => $r->{'why'} };
			subs::records_mailbox_repair_date($r->{'uuid'}, $fix) if $apply;
		}
	}
	$dupe_stats{ $_->{'action'} }++ for @dupe_actions;
}

# A legacy public sms was kept as plain words; once its status says inbox the
# reader expects a sealed body and would show a blank bubble. Seal any readable
# plain phone body that no key opens, so the conversation and its preview read.
my @sealed;
if ($seal_plain) {
	my $rows = subs::db_query(
		"select uuid,timestamp,status,phone,body,ost from mailbox where phone is not null and phone != ''"
	)->hashes;
	foreach my $r ( @{$rows} ) {
		my $raw = $r->{'body'} // '';
		next unless length $raw;
		next if $raw =~ /^JS1:/;
		my $text = subs::note_decrypter($suds, $raw, $r->{'ost'});
		next if defined $text && length $text;
		my $copy = $raw;
		next unless eval { utf8::decode($copy) };
		next if $copy =~ /[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/;
		# readable words either carry a space or are short; a ciphertext is long
		next unless $copy =~ /\s/ || length($copy) <= 40;
		my $sealed_body = subs::note_encrypter($suds, $raw, $r->{'timestamp'});
		next unless defined $sealed_body && length $sealed_body;
		push @sealed, { row => $r };
		subs::db_query(
			'update mailbox set body = ?, server_time = ? where uuid = ?',
			$sealed_body, subs::rightNow(), $r->{'uuid'}
		) if $apply;
	}
}

# The direction the phone's store recorded. The domain helper names it once for
# the app; a tree from before it landed still runs this repair by reading the
# same prefix here.
my $direction_from_note = sub {
	my ($plain) = @_;
	my $want = eval { subs::mail_direction_from_note($plain) };
	return $want if defined $want;
	return undef unless defined $plain && length $plain;
	my ($type) = $plain =~ /^\s*(Sent|Inbox|Draft|Received|Recieved)\s*:/i;
	return undef unless defined $type;
	$type = lc $type;
	return 'sent' if $type eq 'sent';
	return 'draft' if $type eq 'draft';
	return 'inbox';
};

# What a row currently says: sent, inbox, or undef when the status does not
# name a direction (public, draft, an empty one).
my $row_direction = sub {
	my ($r) = @_;
	my $st = lc( $r->{'status'} // '' );
	return 'sent' if $st eq 'sent';
	return 'inbox' if $st eq 'inbox' || $st eq 'received' || $st eq 'recieved';
	return undef;
};

# The mailbox stores a number bare (digits, no leading country code); a contact
# setting may keep the leading 1 or formatting. Both sides are normalized so a
# person's leading-1 line still joins their bare mailbox rows.
my $norm_phone = sub {
	my ($p) = @_;
	$p //= '';
	$p =~ s/\D+//g;
	$p =~ s/^1//;
	return $p;
};

# The phone line(s) a person's appointment app can be reached on. An appointment
# names the person, the mailbox row names the number, so this is the join.
my $lines = subs::contact_lines('phone');
my %phones_by_app;
foreach my $app ( keys %{$lines} ) {
	my %seen;
	my @values = grep { defined $_ && length $_ && !$seen{$_}++ }
		map { $norm_phone->( $_->{'value'} ) } @{ $lines->{$app} || [] };
	$phones_by_app{$app} = \@values if @values;
}

# A mailbox body may be sealed; a plain one is read as it stands. Both sides are
# flattened the same way so the store's body can identify the right row when a
# timestamp is not unique.
my $plain_body = sub {
	my ($raw, $ost) = @_;
	return '' unless defined $raw && length $raw;
	my $text = subs::note_decrypter($suds, $raw, $ost);
	$text = $raw unless defined $text && length $text;
	$text =~ s/<br\s*\/?>/ /gi;
	$text =~ s/<[^>]+>//g;
	$text =~ s/[\r\n]+/ /g;
	$text =~ s/\s+/ /g;
	$text =~ s/^\s+|\s+$//g;
	return $text;
};

my @appointments = @{ subs::db_query(
	'select uuid, app, timestamp, notes, ost, server_time from appointments where type = ? order by timestamp asc',
	'sms'
)->hashes };

# The appointment note's direction, keyed by normalized number and timestamp.
my %note_type;
foreach my $a ( @appointments ) {
	my $plain = subs::note_decrypter($suds, $a->{'notes'}, $a->{'ost'}) // '';
	my $type = $direction_from_note->($plain);
	next unless defined $type && $type ne 'draft';
	foreach my $ph ( @{ $phones_by_app{ $a->{'app'} } || [] } ) {
		$note_type{"$ph|$a->{'timestamp'}"} = $type;
	}
}

my %wanted;
my %stats = (
	appointments => scalar @appointments,
	no_phone => 0, no_type => 0, no_mailbox => 0, ambiguous => 0,
	ignored => 0, already => 0, conflict => 0, would_change => 0,
);

# A message sent from Chat is filed twice: once live, then again when the
# phone's own store is read back. The rows carry the same words and number and
# land within a few seconds. Cluster on that and keep one row per direction, so
# a sent/received pair that happens to say the same words is not collapsed. The
# appointment note names the direction of the copy that has one.
my @thread_actions;
my %thread_stats = (clusters => 0, extras => 0, fixes => 0);
if ($thread_dupes) {
	my $rows = subs::db_query(
		"select uuid,timestamp,status,phone,manager_file,body,ost from mailbox
		 where phone is not null and phone != '' and coalesce(status,'') != 'ignored'
		 order by timestamp asc"
	)->hashes;
	my %groups;
	foreach my $r ( @{$rows} ) {
		my $ph = $norm_phone->( $r->{'phone'} );
		next unless length $ph;
		my $body = lc( $plain_body->($r->{'body'}, $r->{'ost'}) );
		next unless length $body;
		$r->{'ph'} = $ph;
		$r->{'note'} = $note_type{"$ph|$r->{'timestamp'}"};
		# A screened call's transcript is filed with no author and the
		# caller's header; it came in, so it belongs on the caller's side.
		$r->{'note'} = 'inbox' if !defined $r->{'note'} && ($r->{'manager_file'} // '') eq '' && $body =~ /^call from:/;
		push @{ $groups{"$ph|$body"} }, $r;
	}
	my $flush = sub {
		my (@cluster) = @_;
		return unless @cluster > 1;
		$thread_stats{'clusters'}++;
		my %by_dir;
		foreach my $r ( @cluster ) {
			my $dir = $r->{'note'} // $row_direction->($r) // 'unknown';
			push @{ $by_dir{$dir} }, $r;
		}
		foreach my $dir ( keys %by_dir ) {
			my @grp = sort { (0 + $a->{'timestamp'}) <=> (0 + $b->{'timestamp'}) } @{ $by_dir{$dir} };
			next unless @grp > 1;
			my @noted = grep { defined $_->{'note'} && $_->{'note'} eq $dir } @grp;
			my $keep = @noted ? $noted[0] : $grp[0];
			my $cur = $row_direction->($keep);
			if ( $dir ne 'unknown' && (!defined $cur || $cur ne $dir) ) {
				$thread_stats{'fixes'}++;
				push @thread_actions, { action => 'fix', row => $keep, from => ($keep->{'status'} // ''), to => $dir };
				subs::db_query('update mailbox set status = ?, server_time = ? where uuid = ?', $dir, subs::rightNow(), $keep->{'uuid'}) if $apply;
				$keep->{'status'} = $dir;
			}
			foreach my $drop ( grep { $_->{'uuid'} ne $keep->{'uuid'} } @grp ) {
				$thread_stats{'extras'}++;
				push @thread_actions, { action => 'tombstone', row => $drop, kept => $keep->{'uuid'} };
				subs::records_mailbox_tombstone($drop) if $apply;
			}
		}
	};
	foreach my $key ( keys %groups ) {
		my @g = sort { (0 + $a->{'timestamp'}) <=> (0 + $b->{'timestamp'}) } @{ $groups{$key} };
		my @cluster;
		foreach my $r ( @g ) {
			if ( @cluster && (0 + $r->{'timestamp'}) - (0 + $cluster[-1]->{'timestamp'}) > $same_window ) {
				$flush->(@cluster);
				@cluster = ();
			}
			push @cluster, $r;
		}
		$flush->(@cluster) if @cluster;
	}
	# A row with a known direction takes it even when it has no twin to
	# cluster with (a screened call transcript is one row, for example).
	foreach my $r ( @{$rows} ) {
		next unless defined $r->{'note'};
		my $cur = $row_direction->($r);
		next if defined $cur && $cur eq $r->{'note'};
		$thread_stats{'fixes'}++;
		push @thread_actions, { action => 'fix', row => $r, from => ($r->{'status'} // ''), to => $r->{'note'} };
		subs::db_query('update mailbox set status = ?, server_time = ? where uuid = ?', $r->{'note'}, subs::rightNow(), $r->{'uuid'}) if $apply;
		$r->{'status'} = $r->{'note'};
	}
}

foreach my $a ( @appointments ) {
	my $phones = $phones_by_app{ $a->{'app'} } || [];
	if ( !@{ $phones } ) { $stats{'no_phone'}++; next; }
	my $plain = subs::note_decrypter($suds, $a->{'notes'}, $a->{'ost'}) // '';
	my $want = $direction_from_note->($plain);
	if ( !defined $want || $want eq 'draft' ) { $stats{'no_type'}++; next; }
	my $note_body = $plain;
	$note_body =~ s/^\s*[^:]*:\s*//;
	$note_body = $plain_body->($note_body);

	my $lo = $a->{'timestamp'};
	my $hi = $lo;
	if ($window) {
		$lo = (0 + $lo) - $window;
		$hi = (0 + $hi) + $window;
	}
	my $candidates = subs::db_query(
		'select uuid, timestamp, status, phone, manager_file, body, ost from mailbox
		 where cast(timestamp as integer) between ? and ?',
		$lo, $hi
	)->hashes;
	my %wanted_phones = map { $_ => 1 } @{$phones};
	my @rows = grep { defined $_->{'phone'} && $wanted_phones{ $norm_phone->($_->{'phone'}) } } @{$candidates};
	if ( !@rows ) { $stats{'no_mailbox'}++; next; }

	# The row at the appointment's own timestamp is the record; a window is only
	# for a copy whose stored time is slightly off. A window must never borrow a
	# row whose own appointment names the other direction (the echo test files a
	# sent and an inbox appointment a second apart over one stored message).
	my @exact = grep { (0 + $_->{'timestamp'}) == (0 + $a->{'timestamp'}) } @rows;
	my @pool = @exact ? @exact : @rows;
	if ( $window && !@exact ) {
		@pool = grep {
			my $own = $note_type{ $norm_phone->($_->{'phone'}) . '|' . $_->{'timestamp'} };
			!defined $own || $own eq $want;
		} @pool;
		if ( !@pool ) { $stats{'ambiguous'}++; next; }
	}

	my $pick;
	my @dup_extra;
	if ( @pool == 1 ) {
		$pick = $pool[0];
		if ( $window && !@exact && $note_body ne '' && $plain_body->($pick->{'body'}, $pick->{'ost'}) ne $note_body ) {
			$stats{'ambiguous'}++;
			next;
		}
	}
	else {
		my @body_match = grep { $note_body ne '' && $plain_body->($_->{'body'}, $_->{'ost'}) eq $note_body } @pool;
		if ( @body_match == 1 ) { $pick = $body_match[0]; }
		elsif ( @body_match > 1 ) {
			# The same event can be filed twice, one copy sent and one inbox,
			# when the live send and the phone's import both wrote it. The
			# appointment's type says which copy is the real record; the rest
			# are the same message and are tombstones, not a second bubble.
			my @correct = grep { ($row_direction->($_) // '') eq $want } @body_match;
			if ( @correct ) {
				$pick = $correct[0];
				@dup_extra = grep { $_->{'uuid'} ne $pick->{'uuid'} } @body_match;
			}
			else {
				$pick = $body_match[0];
				@dup_extra = @body_match[1 .. $#body_match];
			}
		}
		else { $stats{'ambiguous'}++; next; }
	}

	my $current = lc( $pick->{'status'} // '' );
	if ( $current eq 'ignored' ) { $stats{'ignored'}++; next; }
	foreach my $dup ( @dup_extra ) {
		next if $same_seen{ $dup->{'uuid'} }++;
		push @same_event, { uuid => $dup->{'uuid'}, phone => $dup->{'phone'}, status => $dup->{'status'}, kept => $pick->{'uuid'} };
		subs::records_mailbox_tombstone($dup) if $apply;
	}
	my $current_direction = ($current eq 'sent') ? 'sent'
		: ($current eq 'inbox' || $current eq 'received' || $current eq 'recieved') ? 'inbox'
		: undef;
	if ( defined $current_direction && $current_direction eq $want ) { $stats{'already'}++; next; }

	if ( exists $wanted{ $pick->{'uuid'} } && $wanted{ $pick->{'uuid'} }->{'status'} ne $want ) {
		delete $wanted{ $pick->{'uuid'} };
		$stats{'conflict'}++;
		next;
	}
	$wanted{ $pick->{'uuid'} } = {
		status => $want,
		from => $current,
		row => $pick,
		app => $a->{'app'},
		body => $note_body,
	};
}

$stats{'would_change'} = scalar keys %wanted;

my @changes = map { $wanted{$_} } sort {
	(0 + ($wanted{$a}->{'row'}->{'timestamp'} // 0)) <=> (0 + ($wanted{$b}->{'row'}->{'timestamp'} // 0))
} keys %wanted;

if ($apply) {
	my $now = subs::rightNow();
	foreach my $c ( @changes ) {
		subs::db_query(
			'update mailbox set status = ?, server_time = ? where uuid = ?',
			$c->{'status'}, $now, $c->{'row'}->{'uuid'}
		);
		$c->{'applied'} = 1;
	}
}

if ($json) {
	print Mojo::JSON::encode_json({
		apply => $apply ? 1 : 0,
		window => $window,
		stats => \%stats,
		duplicates => ($duplicates ? { stats => \%dupe_stats, actions => [ map { { action => $_->{'action'}, uuid => $_->{'row'}->{'uuid'}, phone => $_->{'row'}->{'phone'}, why => $_->{'why'} } } @dupe_actions ] } : undef),
		sealed => [ map { { uuid => $_->{'row'}->{'uuid'}, phone => $_->{'row'}->{'phone'}, status => $_->{'row'}->{'status'} } } @sealed ],
		same_event => [ @same_event ],
		thread_duplicates => ($thread_dupes ? { stats => \%thread_stats, actions => [ map { { action => $_->{'action'}, uuid => $_->{'row'}->{'uuid'}, phone => $_->{'row'}->{'phone'}, to => $_->{'to'}, kept => $_->{'kept'} } } @thread_actions ] } : undef),
		changes => [ map {
			{
				uuid => $_->{'row'}->{'uuid'},
				phone => $_->{'row'}->{'phone'},
				app => $_->{'app'},
				timestamp => $_->{'row'}->{'timestamp'},
				from => $_->{'from'},
				to => $_->{'status'},
				applied => $_->{'applied'} ? 1 : 0,
			}
		} @changes ],
	}), "\n";
	exit 0;
}

printf "mail direction repair - %s, %d sms appointment(s)\n", ($apply ? 'APPLIED' : 'dry run'), $stats{'appointments'};
if ($duplicates) {
	printf "mailbox duplicates - %d tombstone, %d repair-date\n", $dupe_stats{'tombstone'}, $dupe_stats{'repair-date'};
	if ($verbose) {
		printf "  %s %-14s %s  %s\n", $_->{'action'}, ($_->{'row'}->{'phone'} // ''), $_->{'row'}->{'uuid'}, ($_->{'why'} // '')
			for @dupe_actions;
	}
}
if ($seal_plain) {
	printf "plain phone bodies - %s %d\n", ($apply ? 'sealed' : 'would seal'), scalar(@sealed);
	if ($verbose) {
		printf "  %-10s %-14s %s\n", ($_->{'row'}->{'status'} // ''), ($_->{'row'}->{'phone'} // ''), $_->{'row'}->{'uuid'}
			for @sealed;
	}
}
if (@same_event) {
	printf "same-event duplicates - %s %d\n", ($apply ? 'tombstoned' : 'would tombstone'), scalar(@same_event);
	if ($verbose) {
		printf "  %-14s %s (kept %s)\n", ($_->{'phone'} // ''), $_->{'uuid'}, $_->{'kept'}
			for @same_event;
	}
}
if ($thread_dupes) {
	printf "thread duplicates - %d cluster(s), %s %d extra row(s), %d direction fix(es)\n",
		$thread_stats{'clusters'}, ($apply ? 'tombstoned' : 'would tombstone'),
		$thread_stats{'extras'}, $thread_stats{'fixes'};
	if ($verbose) {
		foreach my $a ( @thread_actions ) {
			if ($a->{'action'} eq 'fix') {
				printf "  fix %-14s %s -> %s\n", ($a->{'row'}->{'phone'} // ''), ($a->{'from'} // '?'), $a->{'to'};
			}
			else {
				printf "  tombstone %-14s %s (kept %s)\n", ($a->{'row'}->{'phone'} // ''), $a->{'row'}->{'uuid'}, $a->{'kept'};
			}
		}
	}
}
printf "already right %d | would change %d | ignored %d | ambiguous %d | no mailbox row %d | no phone %d | no type %d | conflict %d\n",
	$stats{'already'}, $stats{'would_change'}, $stats{'ignored'}, $stats{'ambiguous'},
	$stats{'no_mailbox'}, $stats{'no_phone'}, $stats{'no_type'}, $stats{'conflict'};

foreach my $c ( @changes ) {
	my $preview = $c->{'body'};
	$preview = substr($preview, 0, 54) . (length($preview) > 54 ? '...' : '');
	printf "  %s %-12s %-14s %s -> %s  %s\n",
		($c->{'applied'} ? 'set' : 'would set'),
		$c->{'app'} // '',
		$c->{'row'}->{'phone'} // '',
		$c->{'from'} // '?',
		$c->{'status'},
		$preview;
}
