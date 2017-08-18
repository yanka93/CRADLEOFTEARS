package LJR::Viewuserstandalone;

use strict;

# A function to canonicalize sitename: take one of the possible
# abbreviations for a given known site, and returns the siteid
# from the list. Otherwise, assume that abbreivation is actually the
# full URL, and return it "as is", without the possible leading http://.
# Right now we work case-by-case, since the number of known
# abbreviations is small.
#
#
# Known sites:
#
# 0 -- local
# 1 -- www.livejournal.com
# 2 -- greatestjournal.com
# 3 -- npj.ru
# 4 -- dreamwidth.org 
# TODO: add third level domains

sub canonical_sitenum {
    my ($site)=@_;

    if ( ($site eq "LJR") || ($site =~ m/.*lj\.rossia\.org.*/) )
       {return 0;}  
    elsif ( ($site eq "LJ") || ($site =~ m/.*livejournal\.com.*/) )
       {return 1;}  
    elsif ( ($site eq "GJ") || ($site =~ m/.*greatestjournal\.com.*/) )
       {return 2;}  
    elsif ( ($site eq "NPJ") || ($site =~ m/.*npj\.ru.*/) )
       {return 3;}  
    elsif ( ($site eq "DW") || ($site eq "dw") || ($site =~ m/.*dreamwidth\.org.*/) )
       {return 4;}  
    else {return $site;}
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
#           'type'=>'P','imgroot'=>''} )
#
#  For lj comm, replace 'P' with 'C'; 'imgroot' should be equal to the
#  current value of $LJ::IMGPREFIX -- right now it is differs
#  between test and production!!
#

sub ljuser {
    # we assume $opts->{'site'} to be a siteid of a known site or a full
    # URL of a site we do not have in db
    my $user = shift;
    my $opts = shift;
    my $u;

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
    if($opts->{'site'} =~ m/(\d+)/) {

# Site a number (known site)

	$opts->{'site'} = $opts->{'site'}+0;

	# now we've got default - $LJ::DOMAIN

	if ($opts->{'site'}==0){

        # local
	    $url='lj.rossia.org';
	    $cicon='community.gif'; # default local commicon
	    $uicon='userinfo.gif'; # default local usericon
	    $commdir='community/';
	    $udir='users/';
	    $lj_type='Y';
	} elsif ($opts->{'site'}==1) {
        # LJ
            $name="LJ";
	    $url='www.livejournal.com';
	    $cicon='community-lj.gif';
	    $uicon='userinfo-lj.gif';
	    $commdir='community/';
	    $udir='users/';
	    $lj_type='Y';
	} elsif ($opts->{'site'}==2) {
        # GJ
            $name="GJ";
	    $url='www.greatestjournal.com';
	    $cicon='community-lj.gif';
	    $uicon='userinfo-lj.gif';
	    $commdir='community/';
	    $udir='users/';
	    $lj_type='Y';
	} elsif ($opts->{'site'}==3) {
        # LJ
            $name="NPJ";
	    $url='www.npj.ru';
	    $cicon='community-npj.gif';
	    $uicon='userinfo-npj.gif';
	    $commdir='';
	    $udir='';
	    $lj_type='N';
	} elsif ($opts->{'site'}==4) {
        # DW
            $name="DW";
	    $url='www.dreamwidth.org';
	    $cicon='community-dw.gif';
	    $uicon='userinfo-dw.gif';
	    $commdir='community/';
	    $udir='users/';
	    $lj_type='Y';
        } else { return "[Unknown LJ user tag]"; }

    } else {

# site is not a number -- unknown alien site

	$name=$opts->{'site'};
	$url=$opts->{'site'};
	$uicon=''; # default unknown alien usericon
	$cicon=''; # default unknown alien commicon
	$commdir='community';
	$udir='users';
	$lj_type='N';
    }

  
    my $andfull = $opts->{'full'} ? "&amp;mode=full" : "";

    my $img = $opts->{'imgroot'};
    my $make_tag = sub {
        my ($s, $n, $fil, $dir) = @_;
	    if ($n eq ""){
                return "<span class='ljruser' style='white-space: nowrap;'><a href='http://$s/userinfo.bml?user=$user$andfull'><img src='$img/$fil' alt='[info]' style='vertical-align: bottom; border: 0;' /></a><a href='http://$s/$dir$user/'><b>$user</b></a></span>";
	    } else { 
		if ($lj_type eq 'Y') {

# If the site is known and has an lj-type engine, then we now how to
# refer to userinfo; make the info icon link to this
	
	    return "<span class='ljruser' style='white-space: nowrap;'><a href='http://$s/userinfo.bml?user=$user$andfull'><img src='$img/$fil' alt='[info]' style='vertical-align: bottom; border: 0;' /></a><a href='http://$s/$dir$user/'><b>$user</b> [$n]</a></span>";
		} else {

# If not lj-type, let the info icon link to the user journal

		    return "<span class='ljruser' style='white-space: nowrap;'><a href='http://$s/$dir$user/'><img src='$img/$fil' alt='[info]' style='vertical-align: bottom; border: 0;' /></a><a href='http://$s/$dir$user/'><b>$user</b> [$n]</a></span>";
		}
	    }
        };
        if ($opts->{'type'} eq 'C') {
            return $make_tag->( $url, $name, $cicon, $commdir);
        } else {
            return $make_tag->( $url, $name, $uicon, $udir);
        }
}                  

sub expand_ljuser_tags {

    my ($string)=@_;
    
    return "" unless $string;
    
    my $imgroot='http://lj.rossia.org/img';

    $string=~ s/<lj\s+user=\"?(\w+)\"?\s+site=\"?([^"]+)\"?\s*\/?>/
	ljuser($1,{
	    'site'=>canonical_sitenum($2),
	    'type'=>'P','imgroot'=>$imgroot,
	})
    /egxi;
    $string=~ s/<lj\s+comm=\"?(\w+)\"?\s+site=\"?([^"]+)\"?\s*\/?>/
        ljuser($1,{
            'site'=>canonical_sitenum($2),
            'type'=>'C','imgroot'=>$imgroot,
        })
    /egxi;
    $string=~ s/<ljr\s+user=\"?(\w+)\"?\s*\/?>/
        ljuser($1,{
            'site'=>0,
            'type'=>'P','imgroot'=>$imgroot,
        })
	/egxi;
    $string=~ s/<ljr\s+comm=\"?(\w+)\"?\s*\/?>/
        ljuser($1,{
            'site'=>0,
            'type'=>'C','imgroot'=>$imgroot,
        })
        /egxi;
    return $string;
}

1;
