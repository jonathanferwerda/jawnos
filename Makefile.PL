use strict;
no warnings;

use ExtUtils::MakeMaker;

WriteMakefile(
  VERSION   => '0.01',
  PREREQ_PM => {
    'Mojolicious' => '9.33'
  },
  test => {TESTS => 't/*.t'}
);
