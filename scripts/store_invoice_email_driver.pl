#!/usr/bin/env perl
# store_invoice_email_driver.pl - drive the store's own flow with a live
# session, exactly as a browser would: the computer_repair item's consultation
# model with a hard drive option at $100 total -> quote -> invoice -> the
# store's own compose window -> send.
#
# The one address mail may go to is below, and every send verifies the
# recipient before posting. Without --dry-run the letter really leaves.
#
# Run from the repo root, with a curl cookie jar holding a live session
# (from the box_office ticket url):
#
#   perl scripts/store_invoice_email_driver.pl [cookie_file] [--dry-run]
#
# An expired session answers the first call with the denial page, and the
# driver stops there instead of pretending.
use strict;
use warnings;
use Mojo::UserAgent;
use Mojo::Cookie::Response;
use Mojo::DOM;
use Mojo::JSON qw(decode_json encode_json);
require "./subroutines.pl";

my $ALLOWED = 'jonathan.ferwerda@outlook.com';
my $ITEM = 'computer_repair';
my $MODEL = 'consultation';
my $OPTION = 'hard_drive';
my $TOTAL = 100;

my ($cookie_file, $dry_run) = ('/tmp/jawn_cookies.txt', 0);
foreach my $arg (@ARGV) {
	if ($arg eq '--dry-run') { $dry_run = 1; }
	elsif (-e $arg) { $cookie_file = $arg; }
}
my $base = 'https://127.0.0.1:3000';

my $ua = Mojo::UserAgent->new;
$ua->insecure(1);
open my $cookies, '<', $cookie_file or die "no cookie file $cookie_file\n";
while (my $line = <$cookies>) {
	next if $line =~ /^#/ && $line !~ /^#HttpOnly_/;
	my ($domain, $flag, $cpath, $secure, $expires, $cname, $cvalue) = split "\t", $line;
	next unless defined $cvalue;
	$domain =~ s/^#HttpOnly_//;
	$cvalue =~ s/\s+$//;
	$ua->cookie_jar->add(Mojo::Cookie::Response->new(name => $cname, value => $cvalue, domain => $domain, path => $cpath, secure => 1));
}
die "no cookies loaded from $cookie_file\n" unless scalar @{$ua->cookie_jar->all};

sub json_answer {
	my ($res, $what) = @_;
	my $type = $res->headers->content_type || '';
	die "$what: session refused (got $type)\n" unless $type =~ /json/;
	my $decoded = eval { decode_json $res->body };
	die "$what: bad json\n" unless $decoded;
	return $decoded;
}

# ---- who the letter is for: the customer that address belongs to ------------
my $cx_row = &subs::db_query('select app, value from settings where setting = ? and value = ? order by app', 'email', $ALLOWED)->hashes->[0];
die "no customer carries $ALLOWED\n" unless $cx_row;
my $cx_uuid = &subs::setting_grabber({ app => $cx_row->{'app'}, setting => 'uuid' });
die "customer $cx_row->{app} has no uuid\n" unless $cx_uuid;
print "customer: $cx_row->{app} ($cx_uuid)\n";

# ---- the model and option the quote is built from ---------------------------
my $model = &subs::db_query('select * from model where app = ? and name = ?', $ITEM, $MODEL)->hashes->[0];
die "no $MODEL model on $ITEM\n" unless $model;
my $option = &subs::db_query('select * from option where app = ? and name = ?', $ITEM, $OPTION)->hashes->[0];
die "no $OPTION option on $ITEM\n" unless $option;
my $option_category = '';
my $chars = eval { decode_json $option->{'characteristics'} } || [];
foreach my $ch ( @{$chars} ) {
	next unless $ch->{'name'} eq 'option_category';
	my $oc = &subs::db_select('option_category', undef, { uuid => $ch->{'value'} })->hashes->[0];
	$option_category = $oc->{'name'} if $oc;
}
$option_category ||= 'misc';
print "model: $model->{name} ($model->{price}) option: $option->{name} (group $option_category)\n";

my $tax_rate = &subs::setting_grabber({ app => 'me', setting => 'sales_tax' }) || 1;
my $model_price = &subs::numeric_formatter($model->{'price'} || 0);
my $option_price = &subs::numeric_formatter($TOTAL) - $model_price;
my $tax = ($tax_rate * $TOTAL) - $TOTAL;

my $ts = &subs::rightNow();
my $quote = {
	info => {},
	item => $ITEM,
	uuid => 'new',
	movement => 'income',
	timestamp => $ts,
	model => {
		timestamp => $ts, uuid => $model->{'uuid'}, name => $model->{'name'},
		price => $model_price, quantity => 1, unit => ($model->{'unit'} || $model->{'name'}),
		discount => '', cost => '', tax => 0, tax_rate => $tax_rate, description => ''
	},
	options => {
		$option_category => [ {
			uuid => $option->{'uuid'}, category => $option_category, cost => '', price => $option_price,
			description => '', quantity => 1, unit => ($option->{'unit'} || $option->{'name'}),
			discount => '', name => $option->{'name'}, timestamp => $ts, tax => 0, tax_rate => $tax_rate
		} ]
	},
	numbers => { subtotal => $TOTAL, cost => 0, markup => 1, discount => 0, tax => $tax, total => $TOTAL, tax_rate => $tax_rate }
};

# ---- save the quote ---------------------------------------------------------
my $res = $ua->post($base . '/store/quote/save' => form => {
	quote => encode_json($quote), movement => 'income', timestamp => $ts,
	item => $ITEM, uuid => 'new', cx => $cx_uuid
})->result;
my $saved = &json_answer($res, 'quote save');
my $quote_id = $saved->{'quote'}->{'id'} or die "quote save: no id came back\n";
print "quote saved: $quote_id\n";

# ---- the appointment the save wrote (found by the id it printed under) ------
my $q = &subs::db_query('select * from appointments where app = ? and type = ? and data like ? order by server_time desc limit 1',
	$cx_row->{'app'}, 'quote', '%"id":"' . $quote_id . '"%')->hashes->[0];
die "no quote appointment found for $quote_id\n" unless $q;
print "quote appointment: $q->{'uuid'}\n";

# ---- the quote becomes an invoice -------------------------------------------
$res = $ua->post($base . '/store/quote/move' => form => {
	timestamp => &subs::rightNow(), uuid => $q->{'uuid'}, cx_uuid => $cx_uuid,
	action => 'invoice', type => 'quote'
})->result;
die "move failed: " . $res->code . "\n" unless $res->is_success && $res->headers->content_type !~ /json/;
my $inv = &subs::db_query('select * from appointments where app = ? and type = ? and data like ? order by server_time desc limit 1',
	$cx_row->{'app'}, 'invoice', '%"id":"' . $quote_id . '"%')->hashes->[0];
die "no invoice found for $quote_id\n" unless $inv;
my $idata = eval { decode_json $inv->{'data'} } || {};
print "invoice: $inv->{'uuid'} total=$idata->{'numbers'}->{'total'} balance=$idata->{'numbers'}->{'balance'}\n";

# ---- the store's compose window for that invoice ----------------------------
$res = $ua->get($base . '/store/email?type=invoice&uuid=' . $inv->{'uuid'} . '&cx_uuid=' . $cx_uuid . '&timestamp=' . &subs::rightNow())->result;
my $compose = &json_answer($res, 'compose');
die "compose: no html\n" unless $compose->{'html'};
my $dom = Mojo::DOM->new($compose->{'html'});

my $to = $dom->at('#email_compose_to') ? $dom->at('#email_compose_to')->attr('value') : undef;
print "compose to: [" . ($to || '') . "]\n";
die "REFUSING TO SEND: recipient is not $ALLOWED\n" unless (defined $to && lc $to eq $ALLOWED);

my $form_uuid = $dom->at('.email_compose_form') ? ($dom->at('.email_compose_form')->attr('uuid') || '') : '';
my $from = $dom->at('#email_compose_from option') ? $dom->at('#email_compose_from option')->attr('value') : undef;
my $magic = $dom->at('.email_compose_body') ? ($dom->at('.email_compose_body')->attr('magic_vars') || '') : '';

my @atts;
for my $d ( $dom->find('.email_attachment_data')->each ) {
	my $att = eval { decode_json $d->text };
	push @atts, $att if $att;
}
print "attachments: ", scalar @atts, " (", join(', ', map { $_->{'type'} } @atts), ")\n";
die "no invoice attachment in the compose\n" unless scalar @atts == 1 && $atts[0]->{'type'} eq 'printer';

if ($dry_run) {
	print "dry run: everything built, nothing sent. invoice $inv->{'uuid'} waits unread.\n";
	exit 0;
}

my $total = &subs::price_formatter($idata->{'numbers'}->{'total'});
my $subject = 'Invoice ' . $quote_id . ' from ' . &subs::format_name(&subs::setting_grabber({ app => 'me', setting => 'store_name' }) || 'the shop');
my $body = "Hello,\n\nThank you for your business. Invoice $quote_id is attached, coming to $total.\n\nSee you soon.\n";

$res = $ua->post($base . '/manager/mail/email/send' => form => {
	from => $from, to => $to, subject => $subject, body => $body,
	uuid => $form_uuid, attachments => encode_json(\@atts),
	timestamp => &subs::rightNow(), sender => 'computer', magic_vars => $magic
})->result;
my $answer = &json_answer($res, 'send');
print "send route returned: $answer\n";
die "the send did not succeed\n" unless $answer eq 'success';

my $row = &subs::db_query('select uuid, status, subject from mailbox where email = ? order by server_time desc limit 1', $ALLOWED)->hashes->[0] || {};
print "mail row: $row->{'uuid'} status=$row->{'status'}\n";
print "decrypted subject: ", &subs::note_decrypter(&subs::suds_grabber(), $row->{'subject'}), "\n";
