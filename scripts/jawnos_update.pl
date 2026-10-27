#!/usr/bin/perl
#
# Boot-time self-update for an image installed from a USB stick.
#
# jawnos-firstboot seeds /home/jawn/jawnos from /opt/jawnos/tree exactly once,
# and that copy has no .git. The app's own updater can only fast-forward a
# checkout, so a stick-installed house would otherwise stay frozen at the
# image's build until it was re-imaged. This program makes the seeded tree a
# real checkout on the first boot that reaches GitHub, follows origin/main on
# later boots, and installs any new Perl modules into the user's own ~/perl5
# (which `jawn` already puts on @INC, so they persist on the state partition).
#
# It never runs `git clean` and never forces: after first boot /home/jawn/jawnos
# is a person's working tree, so local changes are left alone and only a clean
# tree moves. Every outcome is logged with a timestamp and ends with a
# JAWNOS_UPDATE_STATUS= line, so update_now (Dev -> Update now) and the boot
# unit share one vocabulary and one implementation.
#
# exit 0 for every handled outcome: a boot unit must never fail the boot.

use strict;
use warnings;
use POSIX qw(strftime);

my $repo        = $ENV{'JAWNOS_REPO'}        || '/home/jawn/jawnos';
my $home        = $ENV{'JAWNOS_HOME'}        || '/home/jawn';
my $remote      = $ENV{'JAWNOS_REMOTE'}      || 'https://github.com/jonathanferwerda/jawnos.git';
my $branch      = $ENV{'JAWNOS_BRANCH'}      || 'main';
my $seed        = $ENV{'JAWNOS_SEED_TREE'}   || '/opt/jawnos/tree';
my $version_url = $ENV{'JAWNOS_VERSION_URL'} || "https://raw.githubusercontent.com/jonathanferwerda/jawnos/$branch/VERSION";
my $log         = $ENV{'JAWNOS_UPDATE_LOG'}  || '/var/log/jawnos-update.log';
my $run_as      = $ENV{'JAWNOS_USER'}        || 'jawn';
my $log_max     = 262144;
my $log_keep    = 131072;

# The root filesystem is volatile on the live image, but a log that grows for
# every boot still wastes RAM; keep the newest half once it passes 256 KB.
sub trim_log {
    return unless -f $log && -w $log;
    my $size = -s $log;
    return unless defined $size && $size > $log_max;
    open(my $in, '<', $log) or return;
    seek($in, $size - $log_keep, 0);
    local $/;
    my $tail = <$in>;
    close $in;
    return unless defined $tail;
    open(my $out, '>', $log) or return;
    print $out "(older log trimmed)\n", $tail;
    close $out;
}

sub log_line {
    my ($message) = @_;
    $message = '' unless defined $message;
    $message =~ s/\s+$//;
    my $line = strftime('%Y-%m-%d %H:%M:%S', localtime) . " $message\n";
    if (open(my $fh, '>>', $log)) {
        print $fh $line;
        close $fh;
    }
    # stdout goes to the journal under the boot unit and into update_now's
    # output under the app; either way the line is not lost when /var/log is
    # not writable (the app runs as the person, not root).
    print $line;
}

# The boot unit runs as root so it can write /var/log, but everything that
# touches the checkout belongs to the person who uses it: root-owned .git
# objects would break every later git command the app runs. Drop to $run_as
# when root; a normal user (the in-app button) runs directly.
sub as_user {
    my @command = @_;
    if ($> == 0 && $run_as ne 'root' && getpwnam($run_as)) {
        return ('runuser', '-u', $run_as, '--', 'env', "HOME=$home", @command);
    }
    return @command;
}

# stderr is merged so a failed fetch or compile reports its real reason.
sub capture {
    my @command = &as_user(@_);
    open(my $fh, '-|', 'sh', '-c', 'exec "$@" 2>&1', 'sh', @command)
        or return (127, "cannot run $command[0]: $!");
    local $/;
    my $output = <$fh>;
    close $fh;
    return ($? >> 8, defined $output ? $output : '');
}

sub capture_in_repo {
    return &capture('sh', '-c', 'cd "$1" || exit 125; shift; exec "$@"', 'sh', $repo, @_);
}

sub git {
    return &capture('git', '-C', $repo, @_);
}

sub git_value {
    my ($code, $value) = &git(@_);
    $value = '' unless defined $value;
    $value =~ s/\s+$//;
    return ($code, $value);
}

sub which {
    my ($name) = @_;
    for my $dir (split /:/, ($ENV{'PATH'} || '')) {
        next unless length $dir;
        return "$dir/$name" if -x "$dir/$name";
    }
    return '';
}

# Same dotted comparison as subs::version_cmp: the first three components,
# numerically, with missing parts as zero (so 0.1.112 beats 0.1.79).
sub version_cmp {
    my ($left, $right) = @_;
    my @l = split /\./, (defined $left ? $left : '');
    my @r = split /\./, (defined $right ? $right : '');
    for my $i (0 .. 2) {
        my $x = ($l[$i] // 0) + 0;
        my $y = ($r[$i] // 0) + 0;
        return $x <=> $y if $x != $y;
    }
    return 0;
}

sub version_newer {
    my ($candidate, $mine) = @_;
    return 0 unless defined $candidate && $candidate =~ /\d/;
    return 0 unless grep { /\d/ } split /\./, (defined $mine ? $mine : '');
    return &version_cmp($candidate, $mine) > 0 ? 1 : 0;
}

sub local_version {
    open(my $fh, '<', "$repo/VERSION") or return '';
    my $v = <$fh>;
    close $fh;
    $v = '' unless defined $v;
    $v =~ s/\s+//g;
    return $v;
}

# The published VERSION is the authority. A short timeout keeps a boot with no
# route from waiting on the network; an empty answer means "stay as seeded".
sub published_version {
    my ($code, $out) = &capture('curl', '-fsSL', '--connect-timeout', '4', '--max-time', '8', $version_url);
    return '' if $code != 0;
    $out =~ s/\s+//g;
    return $out;
}

# The same @INC shape `jawn` exports: the local::lib base plus its arch dirs.
sub perl_libs {
    my $base = "$home/perl5/lib/perl5";
    return '' unless -d $base;
    my @dirs = ($base);
    if (opendir(my $dh, $base)) {
        for my $name (sort readdir $dh) {
            next if $name eq '.' || $name eq '..';
            my $dir = "$base/$name";
            push @dirs, $dir if -d $dir && ($name =~ /-linux-/ || $name =~ /-linux$/ || $name =~ /^[0-9]+\.[0-9]+/);
        }
        closedir $dh;
    }
    return join ':', @dirs;
}

sub summarise {
    my ($text) = @_;
    my $line = join ' | ', grep { /\S/ } split /\n/, (defined $text ? $text : '');
    $line = substr($line, 0, 1000) . '...' if length $line > 1000;
    return $line;
}

sub finish {
    my ($status, $detail) = @_;
    $detail = '' unless defined $detail;
    $detail =~ s/\s+/ /g;
    $detail = substr($detail, 0, 300);
    &log_line("result: $status" . (length $detail ? " - $detail" : ''));
    print "JAWNOS_UPDATE_STATUS=$status\n";
    exit 0;
}

# --- the two ways in ---------------------------------------------------------
# A seeded tree has no history to return to, so a failed first bootstrap rolls
# back by putting the image's own tree back and dropping the .git this run made.
sub bootstrap {
    my ($code, $out) = &git('init', '--quiet');
    return (0, "git init failed: $out") if $code;
    my ($url_code) = &git('remote', 'get-url', 'origin');
    if ($url_code) {
        ($code, $out) = &git('remote', 'add', 'origin', $remote);
        return (0, "git remote add failed: $out") if $code;
    }
    ($code, $out) = &git('fetch', '--depth', '1', 'origin', $branch);
    return (0, "git fetch failed: $out") if $code;
    # reset --hard, never clean: the commit supplies tracked files, and the
    # house's untracked/ignored files (database, config.json, voices, releases)
    # are not in that tree, so they are left untouched.
    ($code, $out) = &git('reset', '--hard', 'FETCH_HEAD');
    return (0, "git reset failed: $out") if $code;
    # The fetch landed on an unborn branch (master on older git); make main the
    # local branch so later fetches compare HEAD with origin/main as usual.
    &git('branch', '-M', $branch);
    &git('branch', '--set-upstream-to', "origin/$branch", $branch);
    return (1, '');
}

sub fast_forward {
    my ($code, $dirty) = &git('status', '--porcelain', '--untracked-files=no');
    return ('dirty', $dirty) if $code == 0 && $dirty =~ /\S/;
    ($code, my $out) = &git('fetch', '--quiet', 'origin', $branch);
    return ('error', $out) if $code;
    my (undef, $head)   = &git_value('rev-parse', 'HEAD');
    my (undef, $origin) = &git_value('rev-parse', "origin/$branch");
    return ('error', "cannot read HEAD or origin/$branch") unless $head && $origin;
    return ('current', '') if $head eq $origin;
    if (&git('merge-base', '--is-ancestor', 'HEAD', "origin/$branch") == 0) {
        my ($merge_code, $merge_out) = &git('merge', '--ff-only', "origin/$branch");
        return ($merge_code == 0 ? 'updated' : 'error', $merge_out);
    }
    return ('ahead', "local commits are not on origin/$branch; left alone")
        if &git('merge-base', '--is-ancestor', "origin/$branch", 'HEAD') == 0;
    return ('diverged', "local and published history have diverged; left alone");
}

sub rollback {
    my ($had_git, $old_sha) = @_;
    if ($had_git && $old_sha) {
        my ($code, $out) = &git('reset', '--hard', $old_sha);
        return ($code == 0, $out);
    }
    # A fresh bootstrap has no earlier commit. Put the shipped tree back over
    # the checkout (no --delete: the person's ignored files are not in the
    # seed) and remove the .git this run created, so the next boot retries.
    my $rsync = &which('rsync');
    my ($code, $out);
    if ($rsync) {
        ($code, $out) = &capture_in_repo($rsync, '-a', "$seed/", './');
    }
    else {
        ($code, $out) = &capture_in_repo('cp', '-a', "$seed/.", './');
    }
    return (0, "seed restore failed: $out") if $code;
    ($code, $out) = &capture_in_repo('rm', '-rf', '.git');
    return (0, "could not remove the failed checkout: $out") if $code;
    return (1, '');
}

# New versions name new modules; the image's system Perl only has the ones it
# shipped with. Install into the person's own lib, never with sudo, and keep
# the code update even when this fails: a dependency problem is not a reason
# to run an older tree.
sub install_dependencies {
    return unless -f "$repo/scripts/jawnos_deps.pl";
    my $lib = "$home/perl5";
    my ($code, $out) = &capture_in_repo('perl', 'scripts/jawnos_deps.pl', '--local-lib', $lib, '--no-extras', '--install');
    &log_line('perl modules: ' . &summarise($out));
    &log_line("perl modules: install failed (code kept, exit $code)") if $code;
    ($code, $out) = &capture_in_repo('perl', 'scripts/jawnos_deps.pl', '--extras-only', '--install');
    &log_line('extras: ' . &summarise($out));
    &log_line("extras: install failed (code kept, exit $code)") if $code;
    return 1;
}

sub compiles {
    my $libs = &perl_libs();
    my @command = ('perl', '-c', 'Manager.pl');
    unshift @command, 'env', "PERL5LIB=$libs" if length $libs;
    my ($code, $out) = &capture_in_repo(@command);
    &log_line('perl -c Manager.pl: ' . &summarise($out));
    return $code == 0;
}

sub main {
    &trim_log();

    &finish('error', "no checkout at $repo") unless -d $repo;
    my $mine = &local_version();
    &finish('error', "no VERSION in $repo") unless $mine =~ /\d/;
    my $published = &published_version();
    # No route to GitHub (or no published VERSION): stay exactly as seeded and
    # let the next boot try again.
    &finish('error', 'no network or no published VERSION; leaving the tree as seeded')
        unless length $published;
    &finish('current', "local $mine is not older than published $published")
        unless &version_newer($published, $mine);

    my $had_git = -d "$repo/.git" ? 1 : 0;
    my $old_sha = '';
    if ($had_git) {
        my (undef, $head) = &git_value('rev-parse', 'HEAD');
        $old_sha = $head;
    }

    &log_line("start: repo=$repo local=$mine published=$published git=" . ($had_git ? 'yes' : 'no'));

    if ($had_git) {
        my ($status, $detail) = &fast_forward();
        &finish($status, $detail) unless $status eq 'updated';
        &log_line("fast-forwarded origin/$branch");
    }
    else {
        my ($ok, $error) = &bootstrap();
        &finish('error', "bootstrap failed: $error") unless $ok;
        &log_line("bootstrapped a checkout from $remote ($branch)");
    }

    # The code is already in place before the dependency step, so a slow or
    # failed install can never undo it. The syntax check comes after the
    # modules, because a new module the code `use`s is part of the update.
    &install_dependencies();
    unless (&compiles()) {
        my ($ok, $error) = &rollback($had_git, $old_sha);
        &finish('error', $ok ? 'perl -c failed; previous tree restored'
                             : "perl -c failed; rollback failed: $error");
    }

    &finish('updated', "now at $published");
}

eval { &main(); 1 };
if ($@) {
    my $error = $@;
    $error =~ s/\s+/ /g;
    &finish('error', "unexpected: $error");
}
&finish('error', 'updater ended without a result');
