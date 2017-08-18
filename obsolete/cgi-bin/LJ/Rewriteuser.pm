# Package that handles redirects of the form:
# http://[sitename]/users/name1/[digits].html[anything else] =>
#   http://[sitename]/users/name2/[digits].html[anything else]
#      if digits < maxid 
# Maxid is a prescribed number, name 1 and name 2 are prescribd usernames.
# The same works for http://[sitename]/~name1/...
# name 2 must be an existing users
#
# How it works:
# all processing of *.html passes through Apache::Livejournal::trans
# A hook has been added to that function that calls 
# LJ:Rewriteuser::uri_check, then uri_rew
# The list of known redirects is kept in a table "rewriteusers" in
# the livejournal database; this package also provides functions
# to work with this table in a safe way.
#
# Additionally, the part in LJ::alloc_user_counter which gives id to
# new entries has been modified in the following way: instead of
# taking max of all the existing entries, it now checks whether we
# have a redirect in the table, and if "yes", takes max of all
# existing entries and maxid from redirect table
#
# Table structure:
#+----------+------------------+------+-----+---------+-------+
#| Field    | Type             | Null | Key | Default | Extra |
#+----------+------------------+------+-----+---------+-------+
#| fromuser | char(15)         |      | PRI |         |       |
#| touser   | char(15)         |      |     |         |       |
#| maxid    | int(10) unsigned |      |     | 0       |       |
#+----------+------------------+------+-----+---------+-------+


package LJ::Rewriteuser;

use strict;

use Carp;                                                                                                                
use lib "$ENV{'LJHOME'}/cgi-bin";                                                                                        
use DBI;                                                                                                                 
use DBI::Role;                                                                                                           
use DBIx::StateKeeper;
#use LJ;

my %REWRITE=();

# Check whether uri needs to be rewritten

sub uri_check {
    my ($uri)=@_;

# Scan the redirect table to see whether username matches

    foreach my $rwuser (keys %REWRITE){
	if ($uri =~ m|users/$rwuser/(\d+)|i) {if($1 < $REWRITE{$rwuser}{'maxnum'}){ return 1;}}
	if ($uri =~ m|~$rwuser/(\d+).html|i) {if($1 < $REWRITE{$rwuser}{'maxnum'}){ return 1;}}
	if ($uri =~ m|community/$rwuser/(\d+).html|i) {if($1 < $REWRITE{$rwuser}{'maxnum'}){ return 1;}}
    }
    return 0;
}

# Rewrite uri (if it's needed -- if not, return the intact original)

sub uri_rew {
    my ($uri)=@_;
    if(uri_check($uri)){
	foreach my $rwuser (keys %REWRITE){
		foreach my $type ("~","users/","community/"){
			my $to=$type.$rwuser;
			my $from=$type.$REWRITE{$rwuser}{'newname'};
			$uri =~ s|$to|$from|i;
		}
	}
    }
    return $uri;
}

# Check the database for redirects, and if yes, return maxid (to
# give it to LJ:alloc_user_counter). If not, return 0.

sub get_min_jid {
    my ($journalid)= @_;
    my $user=LJ::get_username($journalid);
    foreach my $rwuser (keys %REWRITE){
	if ($rwuser eq $user){
	    return ($REWRITE{$rwuser}{'maxnum'} / 256)+1;
	}
    }
    return 0;
}

# Check whether there is a redirect from name1, if yes, return
# name2, if not, return 0

sub get_rewrite {
    my ($fromuser)= @_;
    if($REWRITE{$fromuser}) {return $REWRITE{$fromuser}{'newname'};}
    else {return 0;}
}

# The function to init the redirect table in the database during
# httpd restart

sub init {
	my $dbh = LJ::get_db_writer();
        my $sth = $dbh->prepare("SELECT fromuser, touser, maxid FROM rewriteusers");                    
        $sth->execute;                                                                                                   
        while (my ($from, $to, $maxid) = $sth->fetchrow_array) {                                                              
	    $REWRITE{$from}{'newname'}=$to;
	    $REWRITE{$from}{'maxnum'}=$maxid;
        }                            
}

# Remove a redirect from the table

sub delete_rewrite_hash{
	my ($fromuser) = @_;
	delete($REWRITE{$fromuser});
	my $dbh = LJ::get_db_writer();
	$dbh->do("DELETE FROM rewriteusers WHERE fromuser = ?", undef, $fromuser);
}

# Add a redirect to the table

sub insert_rewrite_hash{
	my ($from, $to, $maxid) =@_;
        $REWRITE{$from}{'newname'}=$to;                                                                                           
        $REWRITE{$from}{'maxnum'}=$maxid; 
	my $dbh = LJ::get_db_writer();
	$dbh->do("INSERT INTO rewriteusers VALUES (?, ?, ?)", undef, $from, $to, $maxid);
}
init();

1;
