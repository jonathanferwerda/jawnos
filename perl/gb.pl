#!/usr/bin/perl


use strict;
no warnings;

require './perl/subroutines.pl';
use Mojo::Cache;


package gb;
our $pwd = `pwd`;
chomp $pwd;
our $count = 0;
our $duty_time = &subs::rightNow();
our $ws = {};
our $remote_ws = {};
our $mailws = {};
our $paperboy = {};
our $subprocessed = 0;
our $remote = {};
our $pamphlet = "";
our $syncing = 'no';
our $ws_workers = 1;
our $signatorial;
our $suds;
our $vault_pull_last;
our $secret_maker;
our $father_time = {};
our $utility_functions_watcher = 0;
our @ports = qw/PORT_AHOY PORT_MSG PORT_BELL PORT_ARM PORT_BESTOW PORT_DOCK PORT_COMS/;
our $pen = { '__statements' => [], '__lexicon' => [] };
our $universal_splitter = "--simple--split--and--whatnot--";
our $jcache = Mojo::Cache->new(max_keys => 100);
our $user_agent = 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/115.0.0.0 Safari/537.36';
require "./perl/gb/01_state_and_defaults.pl";
require "./perl/gb/02_labels_and_collectives.pl";
require "./perl/gb/03_engines_and_tools.pl";
require "./perl/gb/04_budget_and_calendar.pl";
require "./perl/gb/05_abilities_and_studio.pl";
require "./perl/gb/06_movements_and_inputs.pl";
require "./perl/gb/07_master_plan.pl";
require "./perl/gb/08_taunts_and_hardware.pl";
