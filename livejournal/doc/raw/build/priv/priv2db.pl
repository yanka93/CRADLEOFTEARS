#!/usr/bin/perl
#

use strict;

unless (-d $ENV{'LJHOME'}) {
    die "\$LJHOME not set.\n";
}

require "$ENV{'LJHOME'}/doc/raw/build/docbooklib.pl";
require "$ENV{'LJHOME'}/cgi-bin/ljlib.pl";

my $dbr = LJ::get_dbh("slave", "master");
my $sth;

sub dump_privs
{
    my $privs = shift;

    print "<variablelist>\n  <title>User Privileges</title>\n";
    foreach my $priv (sort keys %$privs)
    {

        my ($des, $args) = split(/arg=/, $privs->{$priv}->{'des'});
        my $scope = $privs->{$priv}->{'scope'};

        print "<varlistentry>\n";
        print "<term><literal role=\"priv\">$priv</literal>";
        print " -- (scope: $scope)" if $scope eq "local"; 
        print "</term>\n";

        print "<listitem><formalpara>\n";
        print "<title>$privs->{$priv}->{'name'}</title>\n";
        cleanse(\$des);
        print "<para>$des</para>\n";

        print "<para><emphasis>Argument:</emphasis> $args</para>\n" if $args;
        print "</formalpara></listitem>\n";

        print "</varlistentry>\n";
    }
    print "</variablelist>\n";
}

my %privs;

$sth = $dbr->prepare("SELECT * FROM priv_list");
$sth->execute;
while (my ($prlid, $privcode, $privname, $des, $is_public, $scope) = $sth->fetchrow_array) {
    $privs{$privcode} = { 'public' => $is_public, 'name' => $privname, 'des' => $des, 'scope' => $scope};
}

dump_privs(\%privs);
