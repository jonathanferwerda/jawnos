use strict;
no warnings;

use ExtUtils::MakeMaker;

WriteMakefile(
  NAME      => 'JawnOS',
  VERSION   => '0.01',
  PREREQ_PM => {
    'Mojolicious' => '9.33'
  },
  TEST_REQUIRES => {
    'Test::More'  => '0',
    'DBI'         => '0',
    'DBD::SQLite' => '0'
  },
  test => {TESTS => 't/*.t'}
);
