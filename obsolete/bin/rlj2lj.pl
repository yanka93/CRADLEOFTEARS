#!/usr/bin/perl -w
use strict;
use XMLRPC::Lite;
use Digest::MD5 qw(md5_hex);
use DBI;
use Time::Local;
use lib "$ENV{'LJHOME'}/cgi-bin";
use LJR::Viewuserstandalone;

do $ENV{'LJHOME'} . "/cgi-bin/ljconfig.pl";
#
#���������
#

#�������� ���������� � �����
my $qhost = $LJ::DBINFO{'master'}->{'host'};
my $quser = $LJ::DBINFO{'master'}->{'user'};
my $qpass = $LJ::DBINFO{'master'}->{'pass'};
my $qsock = $LJ::DBINFO{'master'}->{'sock'};
my $qport = $LJ::DBINFO{'master'}->{'port'};
#my $qdb = $LJ::DBINFO{'master'}->{'dbname'};
my $qdb = "prod_ljgate";

#����, � �������� ��������
my $source_site = "127.0.0.2";

#����, �� ������� ��������
my $dest_site = "www.livejournal.com";

#������� ������������� � ������� ��:��:��
#(�� ���� ������������� ������ 15 ����� ����� ��������� ���
#00:15:00
my $sync_freq = "00:10:00";

#������� �� ������� ����� �������, �� ������� ���������� ����,
#� �������, �� ������� ���������� �������� LJ-������ (������
#���������� ��������� �������� ������������, � ����� �������������
#������������� �� ����� ������, ��� �������� LJ, ����).
#������� ����������� � ���������� ������. ���� ����� ����� ������
#������� �������, ������� ������ ���� ������������� ������, ������ ---
#�������� ����, �������������.
my $time_diff = 0;

#��������� ����������

#�������, ������� ��������
my $source_user;
my $source_pass;

#�������, � ������� ��������
my $dest_user;
my $dest_pass;

#����� ����� ��������� ������ � ������ ����������������
#��������� (�� ����� � ����� ��������)
my %journals;

open (STDERR, "+>>$ENV{LJHOME}/logs/ljgate.log") || die "Can't open logfile:$!";

#��������� ����� ����������� ����������
my ($fr_hour,$fr_min,$fr_sec);
my ($ls_year,$ls_month,$ls_day,$ls_hour,$ls_min,$ls_sec);
($fr_hour,$fr_min,$fr_sec) = split(/:/,$sync_freq);
my $lastsync = (time() - ($fr_hour * 60 * 60)
                    - ($fr_min * 60)
	            - $fr_sec);
$lastsync = $lastsync + $time_diff;
($ls_sec,$ls_min,$ls_hour,$ls_day,$ls_month,$ls_year) = localtime($lastsync);
$ls_year += 1900;
$ls_month += 1;
$ls_month=sprintf("%.02d",$ls_month);
$ls_day=sprintf("%.02d",$ls_day); 
$ls_sec=sprintf("%.02d",$ls_sec);
$ls_min=sprintf("%.02d",$ls_min); 
$ls_hour=sprintf("%.02d",$ls_hour); 
$lastsync = $ls_year."-".
            $ls_month."-".
            $ls_day." ".
            $ls_hour.":".
            $ls_min.":".
            $ls_sec;
#print "$lastsync\n";

#����������� � �����
my $dbh = DBI->connect(
   "DBI:mysql:mysql_socket=$qsock;hostname=$qhost;port=$qport;database=$qdb",
   $quser, $qpass,
   ) || die  localtime(time) . ": Can't connect to database\n";

#�������� �� ���� ID ��������, ������� ����� ����������������
my $sqh = $dbh->prepare("SELECT userid,alienid
                      FROM rlj2lj");
$sqh->execute;

my $result;

#�������� ���������� ������� � ��� %journals
while ($result = $sqh->fetchrow_hashref) {
    $journals{$result->{'userid'}} = $result->{'alienid'};
}

#�������������� ��������� ��������� XMLRPC
my $xmlrpc = new XMLRPC::Lite;

#�������������� �������
foreach (keys(%journals)) {
    #�������� �� ���� ���������� ������������ ��������� �������
    $sqh = $dbh->prepare("SELECT our_user,our_pass
                          FROM our_user
                          WHERE userid=$_");
    $sqh->execute;
    ($source_user,$source_pass) = $sqh->fetchrow_array;

    #�������� �� ���� ���������� ������������ ������ �������
    $sqh = $dbh->prepare("SELECT alien,alienpass
                          FROM alien
                          WHERE alienid=$journals{$_}");
    $sqh->execute;
    ($dest_user,$dest_pass) = $sqh->fetchrow_array;

    #�������� ��� ������, ����������� ��� ����Σ����
    #����� ����������� ����������
    eval {
	sync_journals($source_site,$source_user,$source_pass,
	      $dest_site,$dest_user,$dest_pass,
	      $lastsync,$_);
    };
    if ($@) {
	print STDERR localtime(time) . ": Syncronizing $source_user failed\n";
    }   
}


###SUBROUTINES###


#������������� ���������
sub sync_journals{
 my ($source_site,$souce_user,$source_pass,
     $dest_site,$dest_user,$dest_pass,
     $lastsync, $user_id);

 #�������� ������ ������������ ������ � ������/������
 #���������������� ��������� �� ������ � �����������
 ($source_site,$souce_user,$source_pass,
  $dest_site,$dest_user,$dest_pass,$lastsync,$user_id) = @_;

 my $proxy = "http://" . $source_site . "/interface/xmlrpc";
 $xmlrpc->proxy($proxy);

 #XMLRPC object, for login call
 my $get_challenge;

 #Challenge (random string from server for secure login)
 my $challenge;

 #String for md5 hash of server challenge and password
 my $response;

 #�������� ���� ������-����� � ��������� �������
 eval {
     $get_challenge = xmlrpc_call("LJ.XMLRPC.getchallenge");
     $challenge = $get_challenge->{'challenge'};
     $response = md5_hex($challenge . md5_hex($source_pass));
 };
 #Error handling (russian over ssh doesn't work, sorry)
 if ($@) {
     print STDERR localtime(time) . ": Login on $source_site failed\n";
     die;
 };

 #XMLRPC object, for "getevents" call
 my $getevents;

 #�������� ��� ���������, ����������� �� ������� ��������� �������������
 eval {
     $getevents = xmlrpc_call('LJ.XMLRPC.getevents', {
	'username' => $source_user,
	'auth_method' => 'challenge',
	'auth_challenge' => $challenge,
	'auth_response' => $response,
	'ver' => 1,
	'selecttype' => 'syncitems',
	'lastsync' => $lastsync,
	'lineendings' => 'unix',
    });
 };
 #Error handling
 if ($@) {
     print STDERR localtime(time) . ": Getevents on $source_site failed\n";
     die;
 }

 $proxy = "http://" . $dest_site . "/interface/xmlrpc";
 $xmlrpc->proxy($proxy);

 #�������� ���� ������-����� � �������, �� ������� �������� ������
 eval {
     $get_challenge = xmlrpc_call("LJ.XMLRPC.getchallenge");
     $challenge = $get_challenge->{'challenge'};
     $response = md5_hex($challenge . md5_hex($dest_pass));
 };
 #Error handling
 if ($@) {
     print STDERR localtime(time) . ": Login on $dest_site failed\n";
     print STDERR "debug1: " . $@;
     print STDERR "\n\n";
     die;
 }

 my $entry;

 my( $entry_date, $entry_time, $sec, $min, $hour, $day, $month, $year );

 my $fields;

 my $postevent;

 foreach $entry (@{$getevents->{'events'}}) {
    #�������� ���� ������-����� � �������, �� ������� ��������� ������
    eval {
	$get_challenge = xmlrpc_call("LJ.XMLRPC.getchallenge");
	$challenge = $get_challenge->{'challenge'};
	$response = md5_hex($challenge . md5_hex($dest_pass));
    };
    #Error handling
    if ($@) {
	print STDERR localtime(time) . ": Login on $dest_site failed\n";
        print STDERR "debug2: " . $@;
        print STDERR "\n\n";
	die;
    }

    ($entry_date, $entry_time) = split(/ /,$entry->{'eventtime'});
    ($year, $month, $day) = split(/-/,$entry_date);
    ($hour, $min, $sec) = split(/:/,$entry_time);
    #�������� � ����� ������ �� ����, ������� ����� ���� �����������
    $fields = {
	'username' => $dest_user,
	'auth_method' => 'challenge',
	'auth_challenge' => $challenge,
	'auth_response' => $response,
	'ver' => 1,
	'subject' => ($entry->{'subject'})? 
	              LJR::Viewuserstandalone::expand_ljuser_tags($entry->{'subject'})
		       : "",
	'year' => $year,
	'mon' => $month,
	'day' => $day,
	'hour' => $hour,
	'min' => $min,
    };
    #�������� ������� ������� ���������� ������
    if (!$entry->{'security'}) {
	 $fields->{'security'} = 'public';
    } else {
	$fields->{'security'} = $entry->{'security'};
	if ($entry->{'allowmask'}) {
	    $fields->{'allowmask'} = $entry->{'allowmask'};
	}
    };
    #������ ������ � �����������
    if ($entry->{'props'}->{'current_mood'})
    {
	$fields->{'props'}->{'current_mood'} = 
	    $entry->{'props'}->{'current_mood'};
    }
    if ($entry->{'props'}->{'mood_id'})
    {
	$fields->{'props'}->{'mood_id'} =
	    $entry->{'props'}->{'mood_id'};
    }
    if ($entry->{'props'}->{'current_music'})
    {
	$fields->{'props'}->{'current_music'} = 
            $entry->{'props'}->{'current_music'};
    }
    if ($entry->{'props'}->{'opt_backdated'})
    {
	$fields->{'props'}->{'opt_backdated'} = 
            $entry->{'props'}->{'opt_backdated'};
    }

    #��������� ����������� � ���������� ������
    $fields->{'props'}->{'opt_nocomments'} = 1;

    #��������� � ������ ������ ������ �� ����������� � �������� �������
    my $talklink_line = "<div style=\"text-align:right\">".
	               "<font size=\"-2\"><a href=\"".
	               $entry->{'url'}.
                       "\">Comments</a> | <a href=\"".
                       $entry->{'url'}.
                       "?mode=reply\">Comment on this</a></div>";
    $fields->{'event'} = LJR::Viewuserstandalone::expand_ljuser_tags($entry->{'event'}).$talklink_line;
    
#    print STDERR "\n" . $fields->{'event'} . "\n";
    
    #���������� ��������� ������...
    unless ($entry->{'props'}->{'revnum'}) {
	eval {
	    $postevent = xmlrpc_call('LJ.XMLRPC.postevent', $fields);
	    #���������� ������������ ID ��������� �������� �
	    #ID �������������� �������� � ������� rlj_lj_id
	    $sqh = $dbh->prepare ("INSERT INTO rlj_lj_id(userid,ljr_id,lj_id)
                                   VALUES ($user_id, 
                                   $entry->{'itemid'},
                                   $postevent->{'itemid'})");
	    $sqh->execute;
        };
	#��������� ����������: ���� �� ������ ����� XMLRPC
        if ($@) {
	    print STDERR localtime(time) . ": Posting event on $dest_site failed\n";
            print STDERR "debug3: " . $@;
            print STDERR "\n\n";
        };

    #...��� ����������� ţ, ���� ��� ����� ��������� ����� �������
    } else {
	#���� � ���� ID ����������� ������ ��������-�����
	$sqh = $dbh->prepare ("SELECT lj_id
                               FROM rlj_lj_id
                               WHERE userid=$user_id
                                AND ljr_id=$entry->{'itemid'}");
	$sqh->execute;

	#ID ������ � ��������-�����
	my $lj_id;

	#���� �����, ����������� ������ � ��������� ID...
	if (($lj_id) = $sqh->fetchrow_array) {
	    $fields->{'itemid'} = $lj_id;
	    eval {
		$postevent = xmlrpc_call('LJ.XMLRPC.editevent', $fields);
	    };
	    #��������� �������������� ��������
	    if ($@) {
		print STDERR localtime(time) . ": Editing event on $dest_site failed\n";
                print STDERR "debug4: " . $@;
                print STDERR "\n\n";
	    };
	#...� ���� ���, ���������� ţ ����
	#� ����� ���������� �������������
	} else {
	    #���� ������ �����, �� ������ ������ ţ...
	    if (timelocal($ls_sec,$ls_min,$ls_hour,$ls_day,$ls_month,$ls_year)<
		 timelocal($sec, $min, $hour, $day, $month, $year))
	    {
		eval {
		    $postevent = xmlrpc_call('LJ.XMLRPC.postevent', $fields);
		    #���������� ������������ ID ��������� �������� �
		    #ID �������������� �������� � ������� rlj_lj_id
		    $sqh = $dbh->prepare (
				   "INSERT INTO rlj_lj_id(userid,ljr_id,lj_id)
                                   VALUES ($user_id, 
                                   $entry->{'itemid'},
                                   $postevent->{'itemid'})");
		    $sqh->execute;
		};
		#��������� ����������: ���� �� ������ ����� XMLRPC
		if ($@) {
		    print STDERR localtime(time) . ": Posting event on $dest_site failed\n";
                    print STDERR "debug5: " . $@;
                    print STDERR "\n\n";
		};
	    #...����� ������ ţ � ��������� backdate
	    } else {
		$fields->{'props'}->{'opt_backdated'} = 1;
		eval {
		    $postevent = xmlrpc_call('LJ.XMLRPC.postevent', $fields);
		    #���������� ������������ ID ��������� �������� �
		    #ID �������������� �������� � ������� rlj_lj_id
		    $sqh = $dbh->prepare (
				   "INSERT INTO rlj_lj_id(userid,ljr_id,lj_id)
                                   VALUES ($user_id, 
                                   $entry->{'itemid'},
                                   $postevent->{'itemid'})");
		    $sqh->execute;
		};
		#��������� ����������: ���� �� ������ ����� XMLRPC
		if ($@) {
		    print STDERR localtime(time) . ": Posting event on $dest_site failed\n";
                    print STDERR "debug4: " . $@;
                    print STDERR "\n\n";
		};
	    };
	};
    };
  };
};

sub xmlrpc_call {
    my ($method, $req) = @_;
    my $res = $xmlrpc->call($method, $req);
    if ($res && $res->fault) {
        print STDERR "XML-RPC Error:\n".
        " String: " . $res->faultstring . "\n" .
        " Code: " . $res->faultcode . "\n";
        die;
    }
    elsif (!$res) {
        print STDERR "Unknown XML-RPC Error.\n";
        die;
    }
    return $res->result;
}
