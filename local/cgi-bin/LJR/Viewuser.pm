package LJR::Viewuser;

use strict;
use Carp;
use lib "$ENV{'LJHOME'}/cgi-bin";
use DBI;
use DBI::Role;
use DBIx::StateKeeper;     

# A function to canonicalize sitename: take one of the possible
# abbreviations for a given known site, and returns the siteid
# from the list. Otherwise, assume that abbreivation is actually the
# full URL, and return it "as is", without the possible leading http://.
#
# We check the known servers database for "site=servername" or "site
# contains serverurl without the leading www"; make additional
# explicit matchings if necessary (presently none are necessary), et
# voila. 
#

sub canonical_sitenum {
    my ($site)=@_;

# Cut away leading http://
    $site =~ s|http://(.*)|$1|;

    my $dbh = LJ::get_db_reader();
    my $sth = $dbh->prepare(
      "SELECT serverid FROM alienservers WHERE servername=?"
      );
    
    $sth->execute($site);
    return LJ::error($dbh) if $dbh->err;
#
# Match $site=servername (e.g. "LJ")
#
    if ($sth->rows) {
      my ($guu) = $sth->fetchrow_array;
      return $guu;
    }
    $sth->finish;

    $sth = $dbh->prepare(
      "SELECT serverid, REPLACE(serverurl, 'www.', '') FROM alienservers"
      );
    $sth->execute;
    return LJ::error($dbh) if $dbh->err;
#
# Scan all known servers and match "serverurl without www is
#    contained in $site"
#
    while (my ($hale, $guu) = $sth->fetchrow_array) {
	if (index ($site, $guu) !=-1) {
	  return $hale;
	}
    }

    if ( (lc($site) eq "ljr") || ($site =~ m/.*${LJ::DOMAIN}.*/) )
#
# 0 means ourselves
#
       {return 0;}  
#    elsif ( ($site eq "LJ") || ($site =~ m/.*livejournal\.com.*/) )
#       {return 1;}  
#    elsif ( ($site eq "GJ") || ($site =~ m/.*greatestjournal\.com.*/) )
#       {return 2;}  
#    elsif ( ($site eq "NPJ") || ($site =~ m/.*npj\.ru.*/) )
#       {return 3;}  
   else {return $site};

}

#
# Provides a representation of a user. 
#
# Format: we receive a username and a site, where site is either a
# number or a string. If a non-zero number, this is a known site; we take
# information about it from the alianservers table in the db. If
# zero, site is ourselves. If a string, we do not know anything about
# the site and treat it as an OpenID guest; we assume site is the URL.
#
# We return the HTML code.
#
# <lj user="username" site="sitename"> should be expand to
#  ljuser( $username, {'site'=> canonical_sitenum($sitename), 
#           'type'=>'P'} )
#
#  For lj comm, replace 'P' with 'C'
#

sub ljuser {
    # we assume $opts->{'site'} to be a siteid of a known site or a full
    # URL of a site we do not have in db
    my $user = shift;
    my $opts = shift;
    my $u;
    my $native=0;
    my $known=0;

    my $name="";
    my $url;
    my $uicon;
    my $cicon;
    my $commdir;
    my $udir;
    my $lj_type;

# If site is not given, assume native (siteid=0)
    unless ($opts->{'site'}) {$opts->{'site'}=0;}

# Check if site is a number
    if($opts->{'site'} =~ m/(\d+)/) 
    { $known=1; }

    if($known) {

# Site a number (known site)

	$opts->{'site'} = $opts->{'site'}+0;

	# now we've got default - $LJ::DOMAIN

	if ($opts->{'site'}==0){

        # local
	    $url=$LJ::DOMAIN;
	    $cicon='community.gif'; # default local commicon
	    $uicon='userinfo.gif'; # default local usericon
	    $commdir='community/';
	    $udir='users/';
	    $lj_type='Y';

	    $native=1;
	} else {

        # alien but known --
	# go to db to get $name

	       my $dbh = LJ::get_db_writer();
	       my $sth = $dbh->prepare("SELECT serverurl, servername, udir, uicon, cdir, cicon, ljtype FROM alienservers WHERE serverid=?");
	       $sth->execute($opts->{'site'});                                                                                                                       
		($url, $name, $udir, $uicon, $commdir, $cicon, $lj_type) = $sth->fetchrow_array;       
	    $native=0;
	}
    } else {

# site is not a number -- unknown alien site

	$name=$opts->{'site'};
	$url=$opts->{'site'};
	$uicon='openid-profile.gif'; # default unknown alien usericon
	$cicon='openid-profile.gif'; # default unknown alien commicon
	$commdir='';
	$udir='';
	$lj_type='N';
	$native=0;

    }
                                                                                                           
    if ($native){                 

# If the user is local, we do some processing: check validity, check
# whether user or community, etc.

#        my $do_dynamic = $LJ::DYNAMIC_LJUSER || ($user =~ /^ext_/);                                            
#        if ($do_dynamic && ! isu($user) && ! $opts->{'type'}) {                                                
            # Try to automatically pick the user type, but still                                               
            # make something if we can't (user doesn't exist?)                                                 
            $user = LJ::load_user($user) || $user;                                                             
                                                                                                               
            my $hops = 0;                                                                                      
                                                                                                               
            # Traverse the renames to the final journal                                                        
            while (ref $user and $user->{'journaltype'} eq 'R'                                                 
               and ! $opts->{'no_follow'} && $hops++ < 5) {                                                    
                                                                                                               
        	LJ::load_user_props($user, 'renamedto');                                                           
        	last unless length $user->{'renamedto'};                                                           
        	$user = LJ::load_user($user->{'renamedto'});                                                       
                                                                                                               
            }                                                                                                  
#	}                                                                                                          
                                                                                                               
    	    if (LJ::isu($user)) {                                                                                          
		$u = $user;                                                                                            
    		$opts->{'type'} = $user->{'journaltype'};                                                              
                # Mark accounts as deleted that aren't visible, memorial, or locked                                    
	        $opts->{'del'} = $user->{'statusvis'} ne 'V' &&                                                        
    		    $user->{'statusvis'} ne 'M' &&                                                                     
        	    $user->{'statusvis'} ne 'L';                                                                       
        	$user = $user->{'user'};                                                                               
	    }
    }
  

# End of local-specific part
  
    my $andfull = $opts->{'full'} ? "&amp;mode=full" : "";                                                     
    my $img = $opts->{'imgroot'} || $LJ::IMGPREFIX;                                                            
    my $strike = $opts->{'del'} ? ' text-decoration: line-through;' : '';                                      
    my $make_tag = sub {                                                                                       
        my ($s, $n, $fil, $dir) = @_;                                                                          
	$n = lc ($n);

	    if ($n eq ""){
                return "<span class='ljruser' style='white-space: nowrap;$strike'><a href='http://$s/userinfo.bml?user=$user$andfull'><img src='$img/$fil' alt='[info]' style='vertical-align: bottom; border: 0;' /></a><a href='http://$s/$dir$user/'><b>$user</b></a></span>";
	    } else { 
		if ($lj_type eq 'Y') {

# If the site is known and has an lj-type engine, then we now how to
# refer to userinfo; make the info icon link to this
	
	    return "<span class='ljruser' style='white-space: nowrap;$strike'><a href='http://$s/userinfo.bml?user=$user$andfull'><img src='$img/$fil' alt='[info]' style='vertical-align: bottom; border: 0;' /></a><a href='http://$s/$dir$user/'><b>$user\@$n</b></a></span>";
		} elsif ($known) {

# If not lj-type, but known, let the info icon link to the user journal

		    return "<span class='ljruser' style='white-space: nowrap;$strike'><a href='http://$s/$dir$user/'><img src='$img/$fil' alt='[info]' style='vertical-align: bottom; border: 0;' /></a><a href='http://$s/$dir$user/'><b>$user\@$n</b></a></span>";
		} else {

# Unknown site. Treat as openid

		    return "<span class='ljruser' style='white-space: nowrap;$strike'><a href='http://$s/$dir$user/'><img src='$img/$fil' alt='[info]' style='vertical-align: bottom; border: 0;' /></a><a href='http://$s/$dir$user/'><b>$user</b> [$n]</a></span>";
                }
	    }
        };                                                                                                     
                                                                                                               
        if ($opts->{'type'} eq 'C') {                                                                          
            return $make_tag->( $url, $name, $cicon, $commdir);                            
        } elsif ($opts->{'type'} eq 'Y') {                                                                     
            return $make_tag->( $url, $name, 'syndicated.gif', 'users/');                               
        } elsif ($opts->{'type'} eq 'N') {                                                                     
            return $make_tag->( $url, $name, 'newsinfo.gif', 'users/');                                 
        } elsif ($opts->{'type'} eq 'I') {                                                                     
            return $u->ljuser_display($opts);                                                                  
        } else {                                                                                               
            return $make_tag->( $url, $name, $uicon, $udir);                                 
        }                                                                                                      
};

1;
