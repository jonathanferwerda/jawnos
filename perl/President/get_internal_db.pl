# Part of perl/President.pl (package President). The index requires this file
# at the line where the sub used to be defined. `our $current_db_path;` stays
# in the index at its original spot; `use vars` names that same package global
# (and the logger) so the sub compiles under strict.
package President;
use strict;
use warnings;
no warnings qw(uninitialized once);
use vars qw($log $current_db_path);

sub get_internal_db {
    # The machine's one database, at its fixed install path. No handle is opened
    # here on purpose: the web process, pen.pl and the device scripts are the
    # database's readers and writers, and a handle held open in this process only
    # pinned the WAL and kept a stale copy of the data around.
    return $current_db_path if $current_db_path && -e $current_db_path;

    my $database = &subs::database_path();
    if ($database && -e $database && -s $database > 5000) {
        $current_db_path = $database;
        $log->info('using ' . $database);
        return $current_db_path;
    }
    return undef;
}

1;
