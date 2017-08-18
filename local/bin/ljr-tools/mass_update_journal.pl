#!/usr/bin/perl -w
#
# replaces text in all journal entries. use with caution.
#

BEGIN {
  $ENV{'LJHOME'} = "/home/lj-admin/lj";
};

use strict;
use lib $ENV{'LJHOME'}."/cgi-bin";
require "$ENV{'LJHOME'}/cgi-bin/ljlib.pl";

my $dbh = LJ::get_dbh("master");

my ($journal, $from_text, $to_text, $do) = @ARGV;

die("usage: $0 journal_name from_text to_text")
  unless $journal && $from_text && $to_text;

$do = 'no' unless $do;

my $u = LJ::load_user($journal);

die("Invalid journal [$journal]") unless $u;

print "Loaded:  $u->{'name'} [$u->{'userid'}] \n";

my $sth = $dbh->prepare("select * from logtext2 where journalid = ?");
$sth->execute($u->{'userid'});

while (my $r = $sth->fetchrow_hashref()) {
  if ($r->{'event'} =~ /$from_text/) {
    print "journal entry [$r->{'jitemid'}] matches\n";
#    print "journal entry [$r->{'jitemid'}] matches:\n$r->{'event'}\n";
    $r->{'event'} =~ s/$from_text/$to_text/g;
#    print "replaced:\n$r->{'event'}\n\n";

    if ($do eq 'process') {
      $dbh->do("UPDATE logtext2 set event = ? where journalid=? and jitemid=?",
        undef, $r->{'event'}, $r->{'journalid'}, $r->{'jitemid'});
      if ($dbh->err) {
        die("Error while updating entry [$r->{'jitemid'}]: " . $dbh->errstr);
      }
    }
  }
}

print "do not forget to restart memcache" if $do eq 'process';
print "finished\n";
