#!/usr/bin/perl
#

use strict;
use Net::FTP;

my $dir = "$ENV{'LJHOME'}/src/ibill-templates/";
my @accts = qw(100 101 102);

foreach my $acct (@accts)
{
    my $file = "g91961$acct.hmf";
    print "Generating $file...\n";
    open (T, "$dir/template.html")
	or die "Can't open $dir/template.html.\n";
    open (P, ">>$dir/$file")
	or die "Can't write to $file\n";
    while (<T>) {
	s/\[SACCT\]/$acct/g;
	print P $_;
    }
}

print "Uploading to ftp.ibill.com...\n";
print "Enter password (will echo): ";
my $pass = <STDIN>;
chop $pass;

my $ftp = Net::FTP->new("ftp.ibill.com");
unless ($ftp->login("a91961", $pass)) {
    die "Couldn't login.\n";
}
foreach my $acct (@accts)
{
    my $file = "g91961$acct.hmf";
    print "Putting: $file\n";
    $ftp->put($file);
}
$ftp->quit;
print "Done.\n";


