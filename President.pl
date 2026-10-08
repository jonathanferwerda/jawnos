#!/usr/bin/perl

use strict;
use warnings;
$| = 1; # Enable command autoflush

use FindBin qw($Bin);

# Change directory to the script's home location
chdir($Bin) or die "Cannot change directory to $Bin: $!";
package President;
print $0 ."\n";
print `pwd` . "\n";
my $self = $$;
print "I am $self\n";
use Mojolicious::Lite;
use Mojo::IOLoop;
use Mojo::Server::Daemon;
use Mojo::Server::Morbo;
use Mojo::Server::Prefork;
use Mojo::Server::Hypnotoad;
use Data::Dumper;
use File::Slurp;
use Mojo::Util qw/md5_sum /;
use Time::Local;
use Time::Piece;
use Time::Duration;
use Date::Parse;
use Sereal::Encoder qw(encode_sereal SRL_SNAPPY SRL_ZSTD);
use Sereal::Decoder qw(decode_sereal);
my $encoder = Sereal::Encoder->new({ compress => SRL_ZSTD, compress_level => 3 });
my $decoder = Sereal::Decoder->new();
use Mojo::JSON qw(decode_json encode_json);
use Mojo::Reactor::Poll;
use Clone qw(clone);
use Minion;
use threads 'exit' => 'threads_only';

no warnings 'uninitialized'; 
my $working_dir = $0;
my $present_dir = `pwd`;

my $dump_dir = &home('~/.president');
$gb::dump_dir = $dump_dir;
#`rm -R $dump_dir/*` if -e $dump_dir;
`mkdir $dump_dir` unless -e $dump_dir;
`mkdir ./server` unless -e './server';
my $duty_file = &home('~/.president/on_duty');
`touch $duty_file`;
write_file($duty_file, 0);
my $status_file = &home('~/.president/status');
`touch $status_file`;
my $pid_file = &home('~/.president/pid');
`touch $pid_file`;
write_file($pid_file, $$);
my $config_file = read_file('./config.json');
my $config = decode_json $config_file;
our $logfile = &home($config->{'logfile'});
if (-e $logfile) {
#	`shred -u $logfile`;
}
`touch $logfile` if not -e $logfile;
our $log = Mojo::Log->new(path => $logfile);
if ($working_dir ne $present_dir) {
	my @folder = split '/', $working_dir;
	pop @folder;
	my $new_dir = join '/', @folder;
	print 'chdir to ' . $new_dir . "\n";
	chdir $new_dir;
	print `pwd` . "\n";

}
#`espeak "president has begun"`;


my $environment = shift;

my $cache_dir = &home('~/') . '.president';
`mkdir -p $cache_dir` unless -e $cache_dir;

require './gb.pl';

# The archive root (config.json archive_dir) gets one folder per location type,
# made here if it is missing. A blank archive_dir means this machine is not an
# archive and nothing happens.
my $archive_root = &subs::archive_scaffolder();
if ($archive_root->{'enabled'}) {
	my @made = @{$archive_root->{'created'}};
	$log->info('archive root ' . $archive_root->{'dir'} . (@made ? ' created: ' . join(', ', @made) : ' already in place'));
}

$SIG{INT} = sub {
	print "President Died, Ctrl+C! Performing cleanup logic...\n";
	#`rm -R $dump_dir/*` if -e $dump_dir;
	exit 0;
};

my @sockets = qw/ws alarm/;
foreach my $s ( @sockets ) {
	unlink $gb::tmp_dir . '/' . $s;
}
my $random_number;
if (!$config->{'working_port'}) {
	$random_number = 0;
	until ($random_number > 1024 && $random_number < 60000) {
		$random_number = int(rand(59999));
	}
} else {
	$random_number = $config->{'working_port'} < 60000 ? $config->{'working_port'} : 45545;
}
my $on_duty = 0;
my $hour = localtime( &subs::rightNow() / 1000 )->strftime( "%H");

my $domain = $config->{'domain'} || '127.0.0.1';
#my $domain = '127.0.0.1';

my $device = &device_setter();
if ($device eq 'mobile') {
	`termux-wake-lock`;
	`sshd`;
}

if ($config->{'open_browser'} eq 'yes') {
	if ($device eq 'mobile') {
		threads->create(sub() { 
			`termux-open https://127.0.0.1:$random_number/manager & `
		});
	}
	elsif ($device eq 'computer') {
		threads->create(sub() { 
			`export DISPLAY=:0`;
			my $chrome = `chromium https://$domain:$random_number/manager &`;
		});
	}
}
if ($environment) {
	if ($environment =~ /^dev/) {
		$config->{'environment'} = 'development';
	}
	elsif ($environment =~ /^pro/) {
		$config->{'environment'} = 'production';
	}

}
my $port = $random_number;
my $watch_port = $port + 2;
my $ws_port = $port + 1;
my $dock_port = $config->{'port'};
my $tty_port = $port + 3;
my $mail_port = $port + 4;
my $alarm_port = $port + 5;
if ($config->{'environment'} eq 'development') {
	$ws_port = $port;
	$alarm_port = $port;
}


my @threads;
sub manager_starter() {
	my $ws_tty_port = $tty_port + 1;
	$ENV{PORT_AHOY} = $random_number;
	$ENV{PORT_MSG} = $ws_port;
	$ENV{PORT_BELL} = $alarm_port;
	$ENV{PORT_BESTOW} = $tty_port;
	$ENV{PORT_DOCK} = $dock_port;
	$ENV{PORT_COMS} = $ws_tty_port;
	$ENV{PORT_MAIL} = $mail_port;
	$ENV{PORT_ARM} = $watch_port;
	$ENV{PORT_ENV} = $config->{'environment'};
	$ENV{PORT_SSH} = $config->{'ssh_port'};
	$ENV{cookie_name} = 'president';

	my $certs = "";

	if (-e './server/fullchain.pem' && -e './server/privkey.pem') {
		$certs = "?cert=./server/fullchain.pem&key=./server/privkey.pem";
	}
	my $time_count = 0;
	my $now = &subs::rightNow();
	write_file($duty_file, $now);

	$ENV{'MOJO_MAX_LINE_SIZE'} = "64000";
	if ($config->{'environment'} eq 'development') {
		&subs::subprocessor(sub {
		#  $SIG{'KILL'} = sub { threads->exit(); };
			print "Starting Locker Server on port " . $dock_port . "\n";
			$ENV{MOJO_LISTEN} = 'https://*:' . $dock_port . $certs;
			$ENV{PURPOSE} = 'locker';
			my $morbo = Mojo::Server::Morbo->new;
			$morbo->backend->watch(['./', './templates']);
			$morbo = $morbo->daemon(Mojo::Server::Daemon->new);
			$morbo->run('./Manager.pl');
		}, { name => 'Dev Locker Server' });
		if ($ENV{PORT_AHOY} != $ENV{PORT_MSG}) {
			&subs::subprocessor(sub {
			#  $SIG{'KILL'} = sub { threads->exit(); };
				print "Starting WS Server on port " . $ws_port . "\n";
				$ENV{MOJO_LISTEN} = 'https://*:' . $ws_port . $certs;
				$ENV{PURPOSE} = 'websocket';
				my $morbo = Mojo::Server::Morbo->new;
				$morbo->backend->watch(['./', './templates']);
				$morbo = $morbo->daemon(Mojo::Server::Daemon->new);
				$morbo->run('./Manager.pl');
			}, { name => 'Dev WS Server' });
		}
		&subs::subprocessor(sub {
		#  $SIG{'KILL'} = sub { threads->exit(); };
			print "Starting Main Server on port " . $port . "\n";
			$ENV{MOJO_LISTEN} = 'https://*:' . $port . $certs;
			$ENV{PURPOSE} = 'main';
			my $morbo = Mojo::Server::Morbo->new;
			$morbo = $morbo->daemon(Mojo::Server::Daemon->new);
			$morbo->backend->watch(['./', './templates']);
			$morbo->run('./Manager.pl');
		}, { name => 'Dev Main Server' });
	}
	elsif ($config->{'environment'} eq 'production') {

		&subs::subprocessor(sub {
		 # $SIG{'KILL'} = sub { threads->exit(); };
			print "Starting Pro Locker Server on port " . $dock_port . "\n";
			$ENV{MOJO_LISTEN} = 'https://*:' . $dock_port . $certs;
			$ENV{PURPOSE} = 'locker';
			my $prefork = Mojo::Server::Prefork->new(listen => [ $ENV{MOJO_LISTEN} ]);
			$prefork->heartbeat_timeout(200);
			$prefork->load_app('./Manager.pl');
			$prefork->workers(1);
			$prefork->run;
			$log->info('after locker server');
		}, { name => 'Pro Locker Server' });

		&subs::subprocessor(sub {
		#  $SIG{'KILL'} = sub { threads->exit(); };
			print "Starting Pro WS Server on port " . $ws_port . "\n";
			$ENV{MOJO_LISTEN} = 'https://*:' . $ws_port . $certs;
			$ENV{PURPOSE} = 'websocket';
			my $prefork = Mojo::Server::Prefork->new(listen => [ $ENV{MOJO_LISTEN} ]);
			$prefork->heartbeat_timeout(200);
			$prefork->load_app('./Manager.pl');
			$prefork->workers(1);
			$prefork->run;
			$log->info('after ws server');
		}, { name => 'Pro WS Server' });

		&subs::subprocessor(sub {
		#  $SIG{'KILL'} = sub { threads->exit(); };
			print "Starting Pro Prefork Main Server on port " . $port . "\n";
			$ENV{MOJO_LISTEN} = 'https://*:' . $port . $certs;
			$ENV{PURPOSE} = 'main';
			my $prefork = Mojo::Server::Prefork->new(listen => [ $ENV{MOJO_LISTEN} ]);
			$prefork->heartbeat_timeout(200);
			$prefork->load_app('./Manager.pl');
			$prefork->workers(7);
			$prefork->run;
			$log->info('after main server');
		}, { name => 'Pro Main Server' });
		&subs::subprocessor(sub {
		 # $SIG{'KILL'} = sub { threads->exit(); };
			print "Starting Pro Prefork Alarm Server on port " . $alarm_port . "\n";
			$ENV{MOJO_LISTEN} = 'https://*:' . $alarm_port . $certs;
			$ENV{PURPOSE} = 'alarm';
			my $prefork = Mojo::Server::Prefork->new(listen => [ $ENV{MOJO_LISTEN} ]);
			$prefork->heartbeat_timeout(200);
			$prefork->load_app('./Alarm.pl');
			$prefork->workers(1);
			$prefork->run;
			$log->info('after alarm server');
		}, { name => 'Pro Alarm Server' });

	}
	else {
		print "I have no environment!\n";
	}

	if ($device ne 'server') {
		&subs::subprocessor(sub {
		#  $SIG{'KILL'} = sub { threads->exit(); };
			$ENV{PURPOSE} = "watch";
			$ENV{MOJO_LISTEN} = 'https://*:' . $watch_port . $certs;
			if ($config->{'environment'} eq 'development') {
				print "Starting Development Watch Server on $watch_port\n";
				my $morbo = Mojo::Server::Morbo->new;
				$morbo = $morbo->daemon(Mojo::Server::Daemon->new);
				$morbo->run('./watch.pl');
			}
			elsif ($config->{'environment'} eq 'production') {
				print "Starting Pro Watch Server on port " . $watch_port . "\n";
				my $prefork = Mojo::Server::Prefork->new(listen => [ $ENV{MOJO_LISTEN} ]);
				$prefork->heartbeat_timeout(200);
				$prefork->load_app('./watch.pl');
				$prefork->workers(4);
				$prefork->run;
			}
		}, { name => 'Watch Server' });

		&subs::subprocessor(sub {
		 # $SIG{'KILL'} = sub { threads->exit(); };
			$ENV{PURPOSE} = "teletype";
			$ENV{MOJO_LISTEN} = 'https://*:' . $tty_port . $certs;
			if ($config->{'environment'} eq 'development') {
				print "Starting Development TTY Server on $tty_port\n";
				my $morbo = Mojo::Server::Morbo->new;
				$morbo = $morbo->daemon(Mojo::Server::Daemon->new);
				$morbo->run('./teletype.pl');
			}
			elsif ($config->{'environment'} eq 'production') {
				print "Starting Pro TTY Server on port " . $tty_port . "\n";
				my $prefork = Mojo::Server::Prefork->new(listen => [ $ENV{MOJO_LISTEN} ]);
				$prefork->heartbeat_timeout(200);
				$prefork->load_app('./teletype.pl');
				$prefork->workers(3);
				$prefork->run;
			}
		}, { name => 'TTY Server' });
		&subs::subprocessor(sub {
		#  $SIG{'KILL'} = sub { threads->exit(); };
			$ENV{MOJO_LISTEN} = 'http://*:' . $ws_tty_port ;
			if ($config->{'environment'} eq 'development') {
				print "Starting Development TTYws Server on $ws_tty_port\n";
				my $morbo = Mojo::Server::Morbo->new;
				$morbo = $morbo->daemon(Mojo::Server::Daemon->new);
				$morbo->run('./teletype.pl');
			}
			elsif ($config->{'environment'} eq 'production') {
				print "Starting Pro TTYws Server on port " . $ws_tty_port . "\n";
				my $prefork = Mojo::Server::Prefork->new(listen => [ $ENV{MOJO_LISTEN} ]);
				$prefork->heartbeat_timeout(200);
				$prefork->load_app('./teletype.pl');
				$prefork->workers(1);
				$prefork->run;
			}
		}, { name => 'TTY WS Server' });
	}




	my $uthr;
	my @results;
	my $f_status = read_file($status_file);
	my $socket_watch = &socket_watch($dump_dir . '/memory');
	if (-e $status_file) {

		write_file($status_file, 'good');
		print "wrote status good\n";
	}
	if (`ollama -v` =~ /client version is/) {
		&subs::subprocessor(sub {
			`OLLAMA_IGPU_ENABLE=1 OLLAMA_VULKAN=1 HIP_VISIBLE_DEVICES=-1 OLLAMA_NOHISTORY=1 ollama serve`;
		});
	}
	&subs::subprocessor(sub {

		Mojo::IOLoop->timer(2 => sub {
			&utility_functions();
		});
		Mojo::IOLoop->recurring(2 => sub {
			if ($gb::utility_functions_watcher == 0) {

				$gb::utility_functions_watcher = 1;
				$log->info('starting utility functions');

			}
#			my $is_running = defined Mojo::IOLoop->acceptor($socket_watch) ? 1 : 0;


			my $f_status = read_file($status_file);
			if ($f_status eq '') {
				write_file($status_file, 'good');
				print "wrote status good\n";
			}

		});
		Mojo::IOLoop->start;
	}, { name => 'utility functions' });

	# The archive queue's worker. Jobs are enqueued from the web process into
	# the same SQLite file under ~/.president; one at a time, so a slow link is
	# never asked for two files at once and the queue keeps its order.
	&subs::subprocessor(sub {
		my $minion = &subs::minion_grabber();
		my $worker = $minion->worker;
		$worker->status->{jobs} = 1;
		$worker->run;
	}, { name => 'Minion Worker' });
	Mojo::IOLoop->start;
	END {
		print "quitting now!\n";
		print "They dead\n";
	}
}

our ($db_handle, $sql_handle, $current_db_path,$db_duties);
our ($mem_db_handle, $sql_memory);

sub get_internal_db {
    # 1. Test if the handle exists AND the plain file path string is still valid on disk
    return $db_handle if $db_handle && $current_db_path && -e $current_db_path;
    
    my $dir = $config->{'start_dir'};
    $dir =~ s/\/$//gi;
    
    my @databases = sort { -M $b <=> -M $a } grep { /\.db$/ && -s $_ > 5000 } glob("$dir/*.db");
    my $database = $databases[0];

    if ($database) {
        # 2. Cache the clean, raw path string for the next iteration's file test
        $current_db_path = $database;
        
        $sql_handle = Mojo::SQLite->new('sqlite:' . $database);
        $log->info('using ' . $database); # This will now fire ONLY when the file changes or drops!
        $db_handle  = $sql_handle->db;
        # This handle lives as long as the process, sharing the file with the web
        # process, pen.pl and the device scripts. Without this it fails the moment
        # another writer is mid-transaction.
        $db_handle->query('PRAGMA busy_timeout=15000;');

        # --- Instantiate Pristine In-Memory Database Environment ---
        $sql_memory    = Mojo::SQLite->new('sqlite::memory:');
        $mem_db_handle = $sql_memory->db;
        
        # Apply blistering fast execution parameters into RAM context
        $mem_db_handle->query('PRAGMA synchronous = OFF');
        $mem_db_handle->query('PRAGMA journal_mode = MEMORY');

        # --- Hot Sync: Copy the freshly loaded Disk database into RAM ---
       eval {
            # $mem_db_handle->dbh drops straight into the underlying DBI layer.
            # sqlite_backup_from_file reads the disk file and populates RAM in one shot.
            $mem_db_handle->dbh->sqlite_backup_from_file($database);
            $log->info('Successfully hot-swapped and mirrored data blocks into RAM.');
        };
        if ($@) {
            warn "Failed to mirror database into RAM: $@";
        }
        
        return $db_handle;
    }
    return undef;
}

# New secondary helper for your socket routing logic
sub get_mem_db {
    &get_internal_db(); # Ensures the disk database is resolved/synced first if missing
    return $mem_db_handle;
}



sub socket_watch() {
	my ($watch_file) = @_;
	my $memory = {};
	my %buffers;
	Mojo::IOLoop->recurring(5 => sub {
		my $disk_db = get_internal_db();
    while ( my $du = shift @{$db_duties} ) {

			eval {
				if ($du->{'type'} eq 'query') {
					my $disk_err;

				#	eval { $disk_db->query($du->{query}, @{$du->{params}}); };
					$disk_err = $@;
				
					if ($disk_err && $disk_err !~ /duplicate|already exists/i) {
						die $disk_err; # Only throw fatal disk errors, skip schema duplicate errors
					}
				} elsif ($du->{'type'} eq 'insert') {
				#	my $disk_success = $disk_db->insert($du->{table}, $du->{data});
				#	my $assigned_id  = $disk_success->last_insert_id;
				#	$log->info('insert on ' . $du->{table});
				} elsif ( $du->{'type'} eq 'update') {
		    #	$disk_db->update($du->{table}, $du->{data}, $du->{params});
				}
				elsif ( $du->{'type'} eq 'delete') {
					$log->info($du->{'table'});
					$log->info(Dumper $du->{'params'});
        #  $disk_db->delete($du->{table}, $du->{params});
				}
			};
      if ($@) {
          # If an unexpected error happened, put it back at the front of the queue
          unshift @{$db_duties}, $du;
          last; # Stop the current interval loop execution
      }
		}
	});
	eval {
		my $server = Mojo::IOLoop->server({ path => $watch_file } => sub {
			my ($loop,$stream,$id) = @_;
			$stream->handle->autoflush(1);
			$stream->high_water_mark(8 * 1024 * 1024);

			$buffers{$id} = '';
			$stream->on(read => sub {

				my ($stream, $bytes) = @_;

				$buffers{$id} .= $bytes;

				while (1) {
					last if length($buffers{$id}) < 4;

					# 1. Peek at the first 4 bytes without removing them
					my $payload_length = unpack('N', substr($buffers{$id}, 0, 4));

					# 2. Check if the entire packet (4 bytes header + data blob) is present
					last if length($buffers{$id}) < (4 + $payload_length);

					# 3. NOW remove the 4 bytes header from the front of the string
					substr($buffers{$id}, 0, 4, ''); 

					# 4. Extract the exact length of the binary blob safely
					my $sereal_blob = substr($buffers{$id}, 0, $payload_length, '');
	        
	        my $query = eval { $decoder->decode($sereal_blob) };
          my $req = $query;

	        if ($@) {
            warn "Worker $$: Failed to parse Sereal: $@";
            next;
	        }


					
          my $duty = $query->{'duty'} // '';
          my $p    = $query->{'params'} // {};
          if ($duty =~ /^(cache_|global_)/) {
						my $data;
		        if ($duty eq 'cache_get') {
		          $data = $memory->{$p->{'app'}}->{$p->{'context'}}->{$p->{'subcontext'}};
		        } elsif ($duty eq 'cache_set') {
		          $memory->{$p->{'app'}}->{$p->{'context'}}->{$p->{'subcontext'}} = $query->{'data'};
		          $data = $query->{'data'};
		        } elsif ($duty eq 'cache_delete') {
		          delete $memory->{$p->{'app'}}->{$p->{'context'}}->{$p->{'subcontext'}};
		        }
						elsif ($duty eq 'global_get') {
							my $variable = $p->{'variable'};
							my $target_variable = "gb::$variable";
							no strict 'refs'; 
							my $raw_value = $$target_variable;

							if (ref($raw_value)) {
									$data = $raw_value;
							} else {
									$data = { value => $raw_value };
							}
						}
						elsif ($duty eq 'global_set') {
							my $variable = $p->{'variable'};
							my $target_variable = "gb::$variable";
							no strict 'refs';
							if ($query->{'data'}) {
								$$target_variable = $query->{'data'};
							}
						}

		        eval {
		          my $jwsm = $encoder->encode($data);
		          my $packet = pack('N', length($jwsm)) . $jwsm;
		          $stream->write($packet => sub{});
		        };
					}
					elsif ($duty eq 'ai') {

						$log->info('A.I. Called');

						$log->info(Dumper $query);






					}
					elsif ($duty eq 'db_file_get') {
						# Call your internal resolver to find the latest active database path string
						my $db = get_internal_db(); 
						
						# Send the absolute file path ($current_db_path) straight back up the wire!
						eval {
								my $jwsm = $encoder->encode({ success => 1, data => { path => $current_db_path || '' } });
								my $packet = pack('N', length($jwsm)) . $jwsm;
								$stream->write($packet => sub{});
						};
					}
					else {
					  my $disk_db = get_internal_db();
					  my $mem_db  = get_mem_db();
					  
					  unless ($disk_db && $mem_db) {
					      $stream->write($encoder->encode({ error => 'No database available' }) => sub{});
					      return;
					  }
					  
					  my $res;
						eval {
						  # --- SELECT / READ (RAM Only - Instant) ---
		          if ($req->{duty} eq 'select') {
								my $table   = $req->{table};
								my $columns = $req->{columns};
								my $params  = ref $req->{params} eq 'HASH' ? { %{$req->{params}} } : $req->{params};
								my $filters = ref $req->{filters} eq 'HASH' ? { %{$req->{filters}} } : $req->{filters};
								
								my $rows_ref = defined $filters 
									? $mem_db->select($table, $columns, $params, $filters)->hashes->to_array
									: $mem_db->select($table, $columns, $params)->hashes->to_array;
								
								$res = { rows => $rows_ref || [] };
		          }
		          # --- RAW SQL QUERY (RAM for SELECTs, Write-Through for Mutations) ---
							# --- RAW QUERY (RAM Only for SELECTs, Write-Through for Mutations) ---
							elsif ($req->{duty} eq 'query') {
								if ($req->{query} =~ /^\s*select/i) {
									$res = { rows => $mem_db->query($req->{query}, @{$req->{params}})->hashes->to_array };
								} else {

									push @{$db_duties}, { type => 'query', query => $req->{query}, params => $req->{params} };
									my $mem_res = $mem_db->query($req->{query}, @{$req->{params}});

									$res = { affected => $mem_res->rows };
								}
							}

							elsif ($req->{duty} eq 'insert') {
								my $success;
								if ($req->{'db'} eq 'disk') {
									$success = $disk_db->insert($req->{table}, $req->{data});
								} else {
									push @{$db_duties}, { type => 'insert', data => $req->{data}, table => $req->{table} };
									$success = $mem_db->insert($req->{table}, $req->{data});
								}
								my $assigned_id  = $success->last_insert_id;								
								$res = { last_insert_id => $assigned_id };
							}
		          elsif ($req->{duty} eq 'update') {
								my $success;
								if ($req->{'db'} eq 'disk') {
		              $success = $disk_db->update($req->{table}, $req->{data}, $req->{params});
								} else {
									push @{$db_duties}, { type => 'update', data => $req->{data}, table => $req->{table}, params => $req->{params} };
		              $success = $mem_db->update($req->{table}, $req->{data}, $req->{params});
								}
	              $res = { affected => $success->rows };
		          }
		          elsif ($req->{duty} eq 'delete') {
								my $success;
								if ($req->{'db'} eq 'disk') {
		              $success = $disk_db->delete($req->{table}, $req->{params});
								} else {
									push @{$db_duties}, { type => 'delete', params => $req->{params}, table => $req->{table} };
		              $success = $mem_db->delete($req->{table}, $req->{params});
								}
		            $res = { affected => $success->rows };
		          }
						};
						if ($@) {
								$log->info($req->{'table'} . ' ' . $query->{'duty'});
								$log->info(Dumper $req->{'params'});
								$log->info(Dumper $req->{'data'});
						    $stream->write($encoder->encode({ error => $@ }) => {});
						} else {
					      my $jwsm = $encoder->encode({ success => 1, data => $res });
					      my $packet = pack('N', length($jwsm)) . $jwsm;
					      $stream->write($packet => sub{});
						#    $stream->write($encoder->encode({ success => 1, data => $res }));
						}
						

					}


					if ($@) { warn "Worker $$: Failed to send 'stop' state: $@" }
				}
				if (length($buffers{$id}) == 0) {
					$buffers{$id} = ''; # Clears out underlying allocated C-buffers in Perl's core
				}
			});
			$stream->on(close => sub {
				delete $buffers{$id};
			});
		});
		return $server;
	}
}

sub utility_stopper() {
	foreach my $t ( keys %{$gb::timeouts} ) {
		Mojo::IOLoop->remove($gb::timeouts->{$t}->{'loop'}) if $gb::timeouts->{$t}->{'loop'};
		$gb::timeouts->{$t}->{'subroutine'} = undef if $gb::timeouts->{$t}->{'subroutine'};
	}
	$log->info('Loop is crashing at ' . localtime(&subs::rightNow() / 1000 )->strftime('%a %D %I:%M:%S%P'));

	$gb::utility_functions_watcher = 0;
}

&manager_starter();

sub utility_functions() {

	$gb::utility_functions_watcher = 1;
	print "Starting Alarm Clock\n";

	require './Alarm.pl';
	# Keep a pristine copy of the built-in utilities so newly added ones show up
	# for installs that already have their utilities configured.
	$gb::utility_defaults = clone $gb::timeouts unless $gb::utility_defaults;
	$gb::alarm_running = 0;
	$gb::budget_running = 0;
	$gb::utility_running = 0;
	$gb::housekeeping_running = 0;
	$gb::clothesline_running = 0;

	# The last utility state we persisted, so idle ticks don't keep rewriting the
	# setting and pinging every tab.
	my $last_controls_json;

	sub utility_controller() {
		my $data = shift;
		$data->{'send_beacon'} = 0;
		my ($db,$database,$sql) = &subs::database_grabber();
		if ($db) {
			my $signatorial = &subs::signatorial_designer();
			my $controls = eval { return decode_json &subs::setting_grabber({ app => '__president', setting => 'utility_controller' }) } || {};
			if (scalar keys %{$controls} == 0) {
				foreach my $dt ( ( $signatorial, @gb::device_types ) ) {
					$controls->{$dt} = clone $gb::timeouts;
				}
				my $jcontrols = encode_json $controls;
				&subs::setting_setter({ app => '__president', setting => 'utility_controller', value => $jcontrols });
				$gb::timeouts = $controls->{$signatorial};
			} 
			else {
				# pick up any utilities added since this install was configured
				if ($gb::utility_defaults && $controls->{$signatorial}) {
					my $added = 0;
					foreach my $t ( keys %{$gb::utility_defaults} ) {
						unless (exists $controls->{$signatorial}->{$t}) {
							$controls->{$signatorial}->{$t} = clone $gb::utility_defaults->{$t};
							$added = 1;
						}
					}
					if ($added) {
						$controls->{$signatorial}->{'__settings'}->{'last_change'} = &subs::rightNow();
						my $jcontrols = encode_json $controls;
						&subs::setting_setter({ app => '__president', setting => 'utility_controller', value => $jcontrols });
					}
				}
				if ($controls->{$signatorial}->{'__settings'}->{'last_change'} > $gb::timeouts->{'__settings'}->{'last_change'}) {

					foreach my $t ( keys %{$gb::timeouts} ) {
						Mojo::IOLoop->remove($gb::timeouts->{$t}->{'loop'}) if $gb::timeouts->{$t}->{'loop'};
					}
					$gb::timeouts = $controls->{$signatorial};
					$gb::utility_running = 0;
				}
			}
			if ($gb::utility_running == 0) {
				$gb::utility_running = 1;
				&utility_definer();
				my %realtime_timeouts;

				foreach my $t ( keys %{$gb::timeouts} ) {
					if ($t eq 'manager' && (!$gb::timeouts->{$t}->{'interval'} || $gb::timeouts->{$t}->{'interval'} < (10 * 60)) ) {
						$gb::timeouts->{$t}->{'interval'} = 10 * 60;
					}
					Mojo::IOLoop->remove($gb::timeouts->{$t}->{'loop'}) if $gb::timeouts->{$t}->{'loop'};
					if ($gb::timeouts->{$t}->{'subroutine'} && $gb::timeouts->{$t}->{'toggle'} eq 'on') {
						$gb::timeouts->{$t}->{'loop'} = Mojo::IOLoop->recurring($gb::timeouts->{$t}->{'interval'} / ($gb::timeouts->{$t}->{'interval_divider'} ? $gb::timeouts->{$t}->{'interval_divider'} : 1 ) => sub() {
    				  local $SIG{ALRM} = sub { die "TIMEOUT_EXCEEDED\n" };
							my $success = 0;
							eval {

				        alarm($gb::timeouts->{$t}->{'timeout'});
								$gb::timeouts->{$t}->{'subroutine'}->();
								$success = 1;
								alarm(0);
							};
							if ($@) {
									alarm(0);
									if ($@ eq "TIMEOUT_EXCEEDED\n") {
										  $log->error("Task '$t' took too long and was safely stopped.");
									} else {
										  $log->error("Task '$t' threw an error but we caught it: $@");
									}
							}

							if ($gb::timeouts->{$t}->{'beacon'} eq 'on') {
								&subs::beacon_appt_writer();
							}
							if ($success == 1) {
								$gb::timeouts->{$t}->{'last_run'} = &subs::rightNow();
							}
						});
					}
				}
				Mojo::IOLoop->start unless Mojo::IOLoop->is_running;

			}
			my $now = &subs::rightNow();
			my $writable = 0;
			foreach my $t ( keys %{$controls->{$signatorial}} ) {
				if ($gb::timeouts->{$t}->{'toggle'} eq 'on') {
					if ($now - $gb::timeouts->{$t}->{'last_run'} > $gb::timeouts->{$t}->{'interval'} * 5 * 1000) {
						$controls->{$signatorial}->{$t}->{'status'} = 'bad';
						$writable = 1;
					}
					else { 
						$controls->{$signatorial}->{$t}->{'status'} = 'good';
						$writable = 1;
					}
					$controls->{$signatorial}->{$t}->{'last_run'} = $gb::timeouts->{$t}->{'last_run'};
				}
				else {
					$controls->{$signatorial}->{$t}->{'last_run'} = undef;
					$controls->{$signatorial}->{$t}->{'status'} = undef;
				}
			}
			if ($writable == 1) {
				my $jcontrols = encode_json $controls;
				# Only persist + broadcast when something actually changed. This used
				# to rewrite the setting and message every tab several times a minute
				# even when nothing had moved.
				if (!defined $last_controls_json || $jcontrols ne $last_controls_json) {
					$last_controls_json = $jcontrols;
					&subs::setting_setter({ app => '__president', setting => 'utility_controller', value => $jcontrols });
					&Websocket::send('tab', { utility_controller => 'yes' });
				}
			}
		}
		else {
			
		}
		return $data;
	}


	my $timer_id;

	$timer_id = Mojo::IOLoop->recurring(5 => sub {


			my $data = &utility_controller();
		

	});
	&utility_controller();

	$gb::utility_functions_watcher = 1;
	return 1;


	sub utility_definer() {
		$gb::timeouts->{'alarm_haircut'}->{'subroutine'} = sub {
			if ($gb::alarm_haircut_running != 1) {
				$gb::alarm_haircut_running = 1;
				$gb::alarm_haircut_running = 0;
			}
			eval { &Alarm::alarm_haircut() if $config->{'environment'} eq 'production'; };
		};

		$gb::timeouts->{'budget'}->{'subroutine'} = sub {
			if ($gb::budget_running == 0) {
				$gb::budget_running = 1;
				$gb::budget_running = eval { return &Alarm::budget_watcher(); };
			}
		};

		$gb::timeouts->{'sms'}->{'subroutine'} = sub {
			if ($device eq 'mobile') {
				eval { my $returner = &subs::sms_list_check(); };
			}
		};
		$gb::timeouts->{'backups'}->{'subroutine'} = sub {
			eval {
				my ($db,$database,$sql) = &subs::database_grabber();
				if ($db) {
					my $c = &subs::controller_builder();
					my $suds = &subs::suds_grabber();
					$c->session('suds' => $suds);
					$c->param('reason' => 'backup');
					if ($suds ne '') {
						eval { &subs::backup_now($c); };
					}
				}
			};
		};

		$gb::timeouts->{'clothesline'}->{'subroutine'} = sub {
			eval {
				if ($gb::clothesline_running == 0) {
					$gb::clothesline_running = 1;
					&subs::hang_to_dry();
					$gb::clothesline_running = 0;
				}
			};
		};
		$gb::timeouts->{'tasks'}->{'subroutine'} = sub {
			eval {
				if ($gb::tasks_running == 0) {
					$gb::tasks_running = 1;
					$gb::tasks_running = &subs::task_checker();
				}
			}
		};


		$gb::timeouts->{'headless_browser'}->{'subroutine'} = sub {
			eval { &subs::headless_browser(); };
		};

		$gb::timeouts->{'telephone_check'}->{'subroutine'} = sub {
			if ($device eq 'mobile') {
				eval {
					&subs::telephone_contacts_check();
					&subs::telephone_call_log_check();
				}
			}
		};

		$gb::timeouts->{'email_sender'}->{'subroutine'} = sub {
			eval { &subs::email_sender(); }
		};

		$gb::timeouts->{'email_receiver'}->{'subroutine'} = sub {
			eval { &subs::email_receiver('auto'); }
		};

		$gb::timeouts->{'tunnels'}->{'subroutine'} = sub {
			eval {
				my $now = &subs::rightNow();
				if ($now - $gb::timeouts->{'tunnels'}->{'lasted_run'} >= $gb::timeouts->{'tunnels'}->{'interval'} * 1000) {
					my $duty;
					if ($now - $gb::timeouts->{'tunnels'}->{'lasted_run'} > ($gb::timeouts->{'tunnels'}->{'interval'} * 1000 * 12)) {
						$duty = 'restart';
					}
					my $network = &subs::network_interface_reporter();
					my $addresses;
					my $old_addresses = $gb::timeouts->{'tunnels'}->{'addresses'};
					foreach my $nic ( keys %{$network} ) {
						push @{$addresses}, { ip => $network->{$nic}->{'ip'}, gw => $network->{$nic}->{'gw'} };
						if (!grep { $_->{'ip'} eq $network->{$nic}->{'ip'} && $_->{'gw'} eq $network->{$nic}->{'gw'}  } @{$old_addresses}) {
							&subs::db_delete('continent', { type => 'temporary', signatorial => &subs::signatorial_designer() });
							$duty = 'restart';
						}
					}
					$gb::timeouts->{'tunnels'}->{'network'} = $network;
					$gb::timeouts->{'tunnels'}->{'addresses'} = $addresses;
					$gb::timeouts->{'tunnels'}->{'lasted_run'} = $now;
					eval { &subs::tunnel_checker({ duty => $duty, interval => $gb::timeouts->{'tunnels'}->{'interval'} }); };
				}
			};
		};
		$gb::timeouts->{'remote_machine_sync'}->{'subroutine'} = sub {
			my $now = &subs::rightNow();
			if ($now - $gb::timeouts->{'remote_machine_sync'}->{'lasted_run'} >= $gb::timeouts->{'remote_machine_sync'}->{'interval'} * 1000) {
				$gb::timeouts->{'remote_machine_sync'}->{'lasted_run'} = $now;
				eval {
					$gb::syncing = 1;
					my $gimme;
					my $hour = localtime( &subs::rightNow() / 1000 )->strftime( "%H");
					if ($hour == 4) {
						$gimme = '3d';
					}
					&subs::remote_machine_negotiator({ gimme => $gimme });
					$gb::syncing = 0;
				};
			}
		};
		my $cpu_worker = [];
		$gb::timeouts->{'htop'}->{'subroutine'} = sub {
			eval {
				my $device = &subs::device_setter();
				my $total = 0;
				$total += $_ for (1 .. 10_000_000);
				my ($user, $system, $cuser, $csystem) = times;
				my $cpu = {
					timestamp => &subs::rightNow(),
					user => $user,
					'system' => $system,
					total => $user + $system
				};

				my $cache_change = 0;
				if (scalar @{$cpu_worker} > 0) {
					my $count = scalar @{$cpu_worker} - 1;
					foreach my $t ( qw/user system total/) {
						$cpu->{'c_' . $t} = $cpu->{$t} - $cpu_worker->[$count]->{$t};
						my $percentage = sprintf("%.3f", $cpu->{'c_' . $t} / (($cpu->{'timestamp'} - $cpu_worker->[$count]->{'timestamp'}) / 1000) * 100);
						$cpu->{'p_' . $t} = $percentage;
						$cache_change = 1;
					}
					splice @{$cpu_worker}, 2;
				} else {
				}
				push @{$cpu_worker}, $cpu;
				if ($cache_change == 1) {
					my ($db,$database) = &subs::database_grabber();
					if ($db) {
						my $cache_data = &subs::cache_get({ app => '__president', context => 'htop', subcontext => 'current' }) || {};
						$cache_data->{'history'} = [] unless $cache_data->{'history'};
						if ($device eq 'mobile') {
							my $tbs = `termux-battery-status`;
							my $battery = eval { return decode_json $tbs } || {};
							if ($battery->{'percentage'}) {
								$cpu->{'battery'}->{'percentage'} = $battery->{'percentage'};
								$cpu->{'battery'}->{'temperature'} = $battery->{'temperature'};
								$cpu->{'battery'}->{'status'} = &subs::unformat_name($battery->{'status'});
								$cpu->{'battery'}->{'power'} = $battery->{'current'};
							}
						}
						elsif ( -e '/sys/class/power_supply/BAT0/capacity' ) {
							my $battery = {
								percentage => `cat /sys/class/power_supply/BAT0/capacity`,
								status => &subs::unformat_name(`cat /sys/class/power_supply/BAT0/status`),
								power => `cat /sys/class/power_supply/BAT0/power_now`
							};
							foreach my $k ( keys %{$battery} ) {
								chomp $battery->{$k};
							}
							if ($battery->{'percentage'}) {
								$battery->{'power'} = sprintf("%.2f", $battery->{'power'} / 1000);
								$cpu->{'battery'} = $battery;
							}
						}
						my (@battery_average,$battery_sum);
						if ($cpu->{'battery'}->{'status'} eq 'discharging') {
							my $last = $cpu;
							@{$cache_data->{'history'}} = grep { $_->{'battery'}->{'percentage'} >= $cpu->{'battery'}->{'percentage'} } @{$cache_data->{'history'}};
							foreach my $h (reverse @{$cache_data->{'history'}}) {
								my $hb = $h->{'battery'};
								my $lhb = $last->{'battery'};
								if ($hb->{'status'} ne 'discharging') {
									last;
								}
								elsif ($lhb->{'percentage'} < $hb->{'percentage'}) {
									my $time_diff = ($last->{'timestamp'} - $h->{'timestamp'}) / 1000;
									my $p_diff = $lhb->{'percentage'} - $hb->{'percenttage'};
									my $p_per_t = $p_diff / $time_diff;


									my $p_drop = $p_per_t;
									my $pm_drop = $p_drop * 60;
									my $ph_drop = $p_drop * 60 * 60;
									$cpu->{'battery'}->{'pps'} = sprintf("%.3f", $p_drop) if scalar @battery_average > 0;
									$cpu->{'battery'}->{'ppm'} = sprintf("%.3f", $pm_drop) if scalar @battery_average > 0;
									$cpu->{'battery'}->{'pph'} = sprintf("%.3f", $ph_drop) if scalar @battery_average > 0;
									push @battery_average, $p_per_t;
									$battery_sum += $p_per_t;
								}
							}
							$cache_data->{'average'}->{'battery'}, {
								pps => sprintf("%.3f", $battery_sum / scalar @battery_average),
								ppm => sprintf("%.3f", $battery_sum / scalar @battery_average / 60),
								pph => sprintf("%.3f", $battery_sum / scalar @battery_average / 60 / 60) 
							} if scalar @battery_average > 0;
						}


						$cache_data->{'current'} = $cpu;
						push @{$cache_data->{'history'}}, $cpu;
						my $sums = {};
						foreach my $hist ( @{$cache_data->{'history'}} ) {
							foreach my $col ( qw/p_user p_system p_total/ ) {
									$hist->{$col} =~ s/[^0-9.]//gi;
									$sums->{$col} += $hist->{$col};
							}
						}
						foreach my $col ( qw/p_user p_system p_total/ ) {
							$cache_data->{'average'}->{$col} = sprintf("%.3f", $sums->{$col} / scalar @{$cache_data->{'history'}});
						}

						splice @{$cache_data->{'history'}}, 10;
						&subs::cache_set({ app => '__president', context => 'htop', subcontext => 'current', warranty => '-1d' }, $cache_data);
						&Websocket::send('server', { console => 'htopViewer();' });
					}
				}
			};
		};

		$gb::timeouts->{'housekeeping'}->{'subroutine'} = sub {
			if ($gb::housekeeping_running == 0) {
				$gb::housekeeping_running = 1;
			#	$gb::housekeeping_running = &Alarm::housekeeping();
			}
		};
		$gb::timeouts->{'warehouse_expiry'}->{'subroutine'} = sub {
			eval {
				if ($gb::warehouse_expiry_running == 0) {
					$gb::warehouse_expiry_running = 1;
					$gb::warehouse_expiry_running = &subs::warehouse_expiry_sweep() ? 0 : 1;
				}
			};
		};
		$gb::timeouts->{'navigation'}->{'subroutine'} = sub {
			eval {
				&subs::headless_navigation();
			};
		};

		$gb::timeouts->{'manager'}->{'subroutine'} = sub {

		};
	}
}




# Resolve ~ once; this used to shell out to `echo $HOME` on every call.
my $home_dir;
sub home() {
	my ($inhabitant) = @_;
	unless (defined $home_dir) {
		$home_dir = $ENV{HOME};
		if (!defined $home_dir || $home_dir eq '') {
			$home_dir = (getpwuid($<))[7] || '';
		}
	}
	$inhabitant =~ s/~/$home_dir/;
	return $inhabitant;
}

sub device_setter() {
	my $device = 'computer';
	if ($config->{'device'}) {
		$device = $config->{'device'};
	}
	else {
		my $uname = `uname -a`;
		if ($uname =~ /Android/gi) {
			$device = 'mobile';
		}
		elsif ($uname =~ /Debian/gi) {
			$device = 'server';
		}
	}
	return $device;
}


