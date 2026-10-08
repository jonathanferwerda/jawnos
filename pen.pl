#!/usr/bin/perl

use Mojo::SQLite;
use Data::Dumper;
use Mojo::JSON qw(decode_json encode_json);
use Mojo::IOLoop;
use WebService::Ollama qw/ollama/;
require './subroutines.pl';
use File::Slurp;
my $msg = shift;
my $database = shift;
die unless -e $database;
my $config_file = read_file('./config.json');
my $config = decode_json $config_file;
our $logfile = &subs::home($config->{'logfile'});
our $log = Mojo::Log->new(path => $logfile);
my $suds = &subs::suds_grabber();

my $sql = Mojo::SQLite->new('sqlite:' . $database, sqlite_use_immediate_transaction => 0);
# This process holds the file open for its whole life, so wait for whoever else is
# writing instead of failing the moment they are.
$sql->db->query('PRAGMA busy_timeout=15000;');
my $ollama = WebService::Ollama->new(base_url => 'http://localhost:11434', model => 'qwen2.5-coder:7b');
my $tally  = eval { return decode_json &subs::note_decrypter($suds,read_file(&subs::home('~/.president/pen'))) } || {};
my $history = [];
if ( scalar @{$tally->{'__statements'}} == 0 ) {

	my $statements = &subs::db_query('select * from mailbox order by server_time desc limit 5')->hashes;


	foreach my $st ( @{$statements} ) {
		my $old_message = &subs::note_decrypter($suds, $st->{'body'});
		$tally = &statement_preparer($old_message,$tally);
		push @{$tally->{'__statements'}}, $old_message;
		my $role = $st->{'contact'} eq 'pen' ? 'assistant' : 'user';
		push @{$history}, {role => 'user', message => $old_message };
	}
}

$tally = &statement_preparer($msg, $tally);

sub statement_preparer() {
	my $msg = shift;
	my $tally = shift;
	my @msg = split ' ', $msg;
	my @lexicon = @{$tally->{'__lexicon'}};
	for (my $w = 0; $w <= scalar @msg; $w++) {
		my $ms = $msg[$w];
		$tally = &word_reader($ms, $tally);

		for (my $n = 0; $n <= scalar @msg; $n++ ) {
			my $word;
			foreach my $wor ( $n .. scalar @msg ) {
				$word .= '_' . $msg[$wor];
				unless ( grep { $_ eq $word } @lexicon ) {
					push @lexicon, $word;
					&word_reader($word, $tally);
				}
			}
		}
	}
	@{$tally->{'__lexicon'}} = @lexicon;
	return $tally;
}

sub word_reader() {
	my $m = shift;
	my $tally = shift;
	$m =~ s/^_//gi;
	$m =~ s/_$//gi;
#	$log->info('Word: ' . $m);
	$m = &subs::unformat_name($m);
	my $ms = &subs::settings_grabber({ app => $m, benign => 1 });
	if (scalar keys %{$ms} > 0 ) { #$log->info('settings for ' . $m . ' ' . scalar keys %{$ms} ); 
}
	$tally->{$ms->{'app'}}->{'setting'} = $ms if scalar keys %{$ms} > 2;
	foreach my $mk ( keys %{$ms} ) {
		if ($mk =~ /^sc_/gi) {
			my $mak = $mk;
			$mak =~ s/^sc_//gi;
			$tally->{$ms->{'app'}}->{'sc'}->{$mak} = decode_json $ms->{$mk};
		}
	}
	foreach my $mo ( qw/model option option_category subcategory/ ) {
	#	my $mos = &subs::db_select($mo, undef, { name => $mo })->hashes;
	#	$tally->{$ms->{'app'}}->{$mo} = $mos if scalar @{$mos} > 0;
	}
	return $tally;
}

push @{$tally->{'__statements'}}, $data->{'msg'};
#$log->info(Dumper $tally->{'__lexicon'});

my $jtally = encode_json $tally;
$log->info($jtally);
write_file(&subs::home('~/.president/pen'),&subs::note_encrypter($suds,$jtally));


my $return_msg = join ' ', grep { $_ !~ /^__/gi } keys %{$tally};



push @{$history}, { role => 'user', message => $msg };
my $SYSTEM_PROMPT = {
  role    => 'system',
  content => 'You are a fun assistant who makes loads of jokes'
};
my $ai_response_accumulator = '';


my $response = $ollama->chat(
  messages => [ $SYSTEM_PROMPT, @{$history} ],
  stream   => 0, # Instructs Ollama to stream token by token

  # 4. The Streaming Callback Function
  # a ($chunk) sub is a prototype, not a signature, here - it left the name a
  # package global that nothing writes, so the chunk is taken from @_ by hand
  stream_cb => sub {
      my ($chunk) = @_;
      # $chunk is a WebService::Ollama::Response object containing the new token
      my $token = $chunk->message->{content};
      $ai_response_accumulator .= $token;

      # Send the single raw token immediately over the WebSocket connection
#        $ws->send({ json => { type => 'token', data => $token } });
			$log->info($token);
  }
);

$log->info(Dumper $response);

my $msg_data = {
	uuid => &subs::random_string_creator(25),
	timestamp => &subs::rightNow(),
	server_time => &subs::rightNow(),
	body => $response->{'message'}->{'content'},
	manager_file => &subs::manager_file_maker('pen'),
	status => 'public',
	contact => 'pen'
};
&subs::db_insert('mailbox', $msg_data);
my $returner = encode_json $msg_data;
print $returner;


