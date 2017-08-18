#!/usr/bin/perl
#
# <LJDEP>
# lib: DBI::, Digest::MD5, URI::URL
# lib: cgi-bin/ljconfig.pl, cgi-bin/ljlang.pl, cgi-bin/ljpoll.pl
# lib: cgi-bin/cleanhtml.pl
# link: htdocs/paidaccounts/index.bml, htdocs/users, htdocs/view/index.bml
# hook: canonicalize_url, name_caps, name_caps_short, post_create
# hook: validate_get_remote
# </LJDEP>

package LJ;

use strict;
use Carp;
use lib "$ENV{'LJHOME'}/cgi-bin";
use DBI;
use DBI::Role;
use DBIx::StateKeeper;
use Digest::MD5 ();
use Digest::SHA1 ();
use HTTP::Date ();
use LJ::MemCache;
use LJ::User;
use Time::Local ();
use Storable ();
use Compress::Zlib ();
use IO::Socket::INET qw{};
use Unicode::MapUTF8;
use LJ::Entry;

do "$ENV{'LJHOME'}/cgi-bin/ljr_readconf.pl";
do "$ENV{'LJHOME'}/cgi-bin/ljconfig.pl";
do "$ENV{'LJHOME'}/cgi-bin/ljdefaults.pl";

sub END { LJ::end_request(); }

# tables on user databases (ljlib-local should define @LJ::USE_TABLES_LOCAL)
# this is here and no longer in bin/upgrading/update-db-{general|local}.pl
# so other tools (in particular, the inter-cluster user mover) can verify
# that it knows how to move all types of data before it will proceed.
@LJ::USER_TABLES = ("userbio", "cmdbuffer", "dudata",
                    "log2", "logtext2", "logprop2", "logsec2",
                    "talk2", "talkprop2", "talktext2", "talkleft",
                    "userpicblob2", "events",
                    "ratelog", "loginstall", "sessions", "sessions_data",
                    "s1usercache", "modlog", "modblob",
                    "userproplite2", "links", "s1overrides", "s1style",
                    "s1stylecache", "userblob", "userpropblob",
                    "clustertrack2", "captcha_session", "reluser2",
                    "tempanonips", "inviterecv", "invitesent",
                    "memorable2", "memkeyword2", "userkeywords",
                    "friendgroup2", "userpicmap2", "userpic2",
                    "s2stylelayers2", "s2compiled2", "userlog",
                    "logtags", "logtagsrecent", "logkwsum",
                    "recentactions", "usertags", "pendcomments",
                    "embedcontent", "embedcontent_preview",
                    );

# keep track of what db locks we have out
%LJ::LOCK_OUT = (); # {global|user} => caller_with_lock

require "$ENV{'LJHOME'}/cgi-bin/ljlib-local.pl"
    if -e "$ENV{'LJHOME'}/cgi-bin/ljlib-local.pl";

require "taglib.pl";
require "ljtextutil.pl";

# if this is a dev server, alias LJ::D to Data::Dumper::Dumper
if ($LJ::IS_DEV_SERVER) {
    eval "use Data::Dumper ();";
    *LJ::D = \&Data::Dumper::Dumper;
}

$LJ::DBIRole = new DBI::Role {
    'timeout' => $LJ::DB_TIMEOUT,
    'sources' => \%LJ::DBINFO,
    'default_db' => "livejournal",
    'time_check' => 60,
    'time_report' => \&dbtime_callback,
};

LJ::MemCache::init();

# $LJ::PROTOCOL_VER is the version of the client-server protocol
# used uniformly by server code which uses the protocol.
$LJ::PROTOCOL_VER = ($LJ::UNICODE ? "1" : "0");

# user.dversion values:
#    0: unclustered  (unsupported)
#    1: clustered, not pics (unsupported)
#    2: clustered
#    3: weekuserusage populated  (Note: this table's now gone)
#    4: userproplite2 clustered, and cldversion on userproplist table
#    5: overrides clustered, and style clustered
#    6: clustered memories, friend groups, and keywords (for memories)
#    7: clustered userpics, keyword limiting, and comment support
$LJ::MAX_DVERSION = 7;

# constants
use constant ENDOFTIME => 2147483647;
$LJ::EndOfTime = 2147483647;  # for string interpolation

# width constants. BMAX_ constants are restrictions on byte width (of utf-8 text),
# CMAX_ on character width (character means byte unless $LJ::UNICODE,
# in which case it means a UTF-8 character).

use constant BMAX_SUBJECT => 255; # *_SUBJECT for journal events, not comments
use constant CMAX_SUBJECT => 255;
use constant BMAX_COMMENT => 29000;
use constant CMAX_COMMENT => 14300;
use constant BMAX_MEMORY  => 150;
use constant CMAX_MEMORY  => 80;
use constant BMAX_NAME    => 100;
use constant CMAX_NAME    => 50;
use constant BMAX_KEYWORD => 80;
use constant CMAX_KEYWORD => 40;
use constant BMAX_PROP    => 255;   # logprop[2]/talkprop[2]/userproplite (not userprop)
use constant CMAX_PROP    => 255;
use constant BMAX_GRPNAME => 60;
use constant CMAX_GRPNAME => 30;
use constant BMAX_GRPNAME2 => 90; # introduced in dversion6, when we widened the groupname column
use constant CMAX_GRPNAME2 => 40; # but we have to keep the old GRPNAME around while dversion5 exists
use constant BMAX_EVENT   => 80000; #item text, in utf-8
use constant CMAX_EVENT   => 40000; #item text, in chars
use constant BMAX_INTEREST => 100;
use constant CMAX_INTEREST => 50;
use constant BMAX_UPIC_COMMENT => 255;
use constant CMAX_UPIC_COMMENT => 120;

# declare views (calls into ljviews.pl)
@LJ::views = qw(lastn friends calendar day);
%LJ::viewinfo = (
                 "lastn" => {
                     "creator" => \&LJ::S1::create_view_lastn,
                     "des" => "Most Recent Events",
                 },
                 "calendar" => {
                     "creator" => \&LJ::S1::create_view_calendar,
                     "des" => "Calendar",
                 },
                 "day" => {
                     "creator" => \&LJ::S1::create_view_day,
                     "des" => "Day View",
                 },
                 "friends" => {
                     "creator" => \&LJ::S1::create_view_friends,
                     "des" => "Friends View",
                     "owner_props" => ["opt_usesharedpic", "friendspagetitle"],
                 },
                 "friendsfriends" => {
                     "creator" => \&LJ::S1::create_view_friends,
                     "des" => "Friends of Friends View",
                     "styleof" => "friends",
                 },
                 "data" => {
                     "creator" => \&LJ::Feed::create_view,
                     "des" => "Data View (RSS, etc.)",
                     "owner_props" => ["opt_whatemailshow", "no_mail_alias"],
                 },
                 "rss" => {  # this is now provided by the "data" view.
                     "des" => "RSS View (XML)",
                 },
                 "res" => {
                     "des" => "S2-specific resources (stylesheet)",
                 },
                 "pics" => {
                     "des" => "FotoBilder pics (root gallery)",
                 },
                 "info" => {
                     # just a redirect to userinfo.bml for now.
                     # in S2, will be a real view.
                     "des" => "Profile Page",
                 },
                 "tag" => {
                    "creator" => \&LJ::S1::create_view_lastn,
                    "des" => "Filtered Most Recent Events",
                 },
                 
                 );

## we want to set this right away, so when we get a HUP signal later
## and our signal handler sets it to true, perl doesn't need to malloc,
## since malloc may not be thread-safe and we could core dump.
## see LJ::clear_caches and LJ::handle_caches
$LJ::CLEAR_CACHES = 0;

# DB Reporting UDP socket object
$LJ::ReportSock = undef;

# DB Reporting handle collection. ( host => $dbh )
%LJ::DB_REPORT_HANDLES = ();


## if this library is used in a BML page, we don't want to destroy BML's
## HUP signal handler.
if ($SIG{'HUP'}) {
    my $oldsig = $SIG{'HUP'};
    $SIG{'HUP'} = sub {
        &{$oldsig};
        LJ::clear_caches();
    };
} else {
    $SIG{'HUP'} = \&LJ::clear_caches;
}

# given two db roles, returns true only if the two roles are for sure
# served by different database servers.  this is useful for, say,
# the moveusercluster script:  you wouldn't want to select something
# from one db, copy it into another, and then delete it from the
# source if they were both the same machine.
# <LJFUNC>
# name: LJ::use_diff_db
# class:
# des:
# info:
# args:
# des-:
# returns:
# </LJFUNC>
sub use_diff_db {
    $LJ::DBIRole->use_diff_db(@_);
}

sub get_blob_domainid
{
    my $name = shift;
    my $id = {
        "userpic" => 1,
        "phonepost" => 2,
        "captcha_audio" => 3,
        "captcha_image" => 4,
        "fotobilder" => 5,
    }->{$name};
    # FIXME: add hook support, so sites can't define their own
    # general code gets priority on numbers, say, 1-200, so verify
    # hook returns a number 201-255
    return $id if $id;
    die "Unknown blob domain: $name";
}

sub locker {
    return $LJ::LOCKER_OBJ if $LJ::LOCKER_OBJ;
    eval "use DDLockClient ();";
    die "Couldn't load locker client: $@" if $@;

    return $LJ::LOCKER_OBJ =
  new DDLockClient (
        servers => [ @LJ::LOCK_SERVERS ],
        lockdir => $LJ::LOCKDIR || "$LJ::HOME/locks",
        );
}

sub mogclient {
    return $LJ::MogileFS if $LJ::MogileFS;

    if (%LJ::MOGILEFS_CONFIG && $LJ::MOGILEFS_CONFIG{hosts}) {
        eval "use MogileFS;";
        die "Couldn't load MogileFS: $@" if $@;

        $LJ::MogileFS = new MogileFS (
                                      domain => $LJ::MOGILEFS_CONFIG{domain},
                                      root   => $LJ::MOGILEFS_CONFIG{root},
                                      hosts  => $LJ::MOGILEFS_CONFIG{hosts},
                                      )
            or die "Could not initialize MogileFS";

        # set preferred ip list if we have one
        $LJ::MogileFS->set_pref_ip(\%LJ::MOGILEFS_PREF_IP)
            if %LJ::MOGILEFS_PREF_IP;
    }

    return $LJ::MogileFS;
}

# <LJFUNC>
# name: LJ::get_dbh
# class: db
# des: Given one or more roles, returns a database handle.
# info:
# args:
# des-:
# returns:
# </LJFUNC>
sub get_dbh {
    my $opts = ref $_[0] eq "HASH" ? shift : {};
    # supported options:
    #    'raw':  don't return a DBIx::StateKeeper object

    unless (exists $opts->{'max_repl_lag'}) {
  # for slave or cluster<n>slave roles, don't allow lag
  if ($_[0] =~ /slave$/) {
      $opts->{'max_repl_lag'} = $LJ::MAX_REPL_LAG || 100_000;
  }
    }

    if ($LJ::DEBUG{'get_dbh'} && $_[0] ne "logs") {
        my $errmsg = "get_dbh(@_) at \n";
        my $i = 0;
        while (my ($p, $f, $l) = caller($i++)) {
            next if $i > 3;
            $errmsg .= "  $p, $f, $l\n";
        }
        warn $errmsg;
    }

    my $mapping;
  ROLE:
    foreach my $role (@_) {
  # let site admin turn off global master write access during
  # maintenance

  return undef if $LJ::DISABLE_MASTER && $role eq "master";
        if (($mapping = $LJ::WRAPPED_DB_ROLE{$role}) && ! $opts->{raw}) {
      if (my $keeper = $LJ::REQ_DBIX_KEEPER{$role}) {
    return $keeper->set_database() ? $keeper : undef;
      }
            my ($canl_role, $dbname) = @$mapping;
            my $tracker;
            # DBIx::StateTracker::new will die if it can't connect to the database,
            # so it's wrapper in an eval
            eval {
                $tracker =
                    $LJ::REQ_DBIX_TRACKER{$canl_role} ||=
                    DBIx::StateTracker->new(sub { LJ::get_dbirole_dbh({unshared=>1},
                                                                      $canl_role) });
            };
            if ($tracker) {
                my $keeper = DBIx::StateKeeper->new($tracker, $dbname);
                $LJ::REQ_DBIX_KEEPER{$role} = $keeper;
    return $keeper->set_database() ? $keeper : undef;
            }
            next ROLE;
        }

        my $db = LJ::get_dbirole_dbh($opts, $role);
        return $db if $db;
    }
    return undef;
}


# <LJFUNC>
# name: LJ::get_dbirole_dbh
# class: db
# des: Internal function for get_dbh(). Uses the DBIRole to fetch a dbh, with
#      hooks into db stats-generation if that's turned on.
# info:
# args: opts, role
# des-opts: A hashref of options.
# des-role: The database role.
# returns: A dbh.
# </LJFUNC>
sub get_dbirole_dbh {
    print(@_);
    my $dbh = $LJ::DBIRole->get_dbh( @_ ) or return undef;
    if ( $LJ::DB_LOG_HOST && $LJ::HAVE_DBI_PROFILE ) {
        $LJ::DB_REPORT_HANDLES{ $dbh->{Name} } = $dbh;

        # :TODO: Explain magic number
        $dbh->{Profile} ||= "2/DBI::Profile";

        # And turn off useless (to us) on_destroy() reports, too.
        undef $DBI::Profile::ON_DESTROY_DUMP;
    }

    return $dbh;
}

# <LJFUNC>
# name: LJ::get_lock
# des: get a mysql lock on a given key/dbrole combination
# returns: undef if called improperly, true on success, die() on failure
# args: db, dbrole, lockname, wait_time?
# des-dbrole: the role this lock should be gotten on, either 'global' or 'user'
# des-lockname: the name to be used for this lock
# des-wait_time: an optional timeout argument, defaults to 10 seconds
# </LJFUNC>
sub get_lock
{
    my ($db, $dbrole, $lockname, $wait_time) = @_;
    return undef unless $db && $lockname;
    return undef unless $dbrole eq 'global' || $dbrole eq 'user';

    my $curr_sub = (caller 1)[3]; # caller of current sub

    # die if somebody already has a lock
    die "LOCK ERROR: $curr_sub; can't get lock from: $LJ::LOCK_OUT{$dbrole}\n"
        if exists $LJ::LOCK_OUT{$dbrole};

    # get a lock from mysql
    $wait_time ||= 10;
    $db->do("SELECT GET_LOCK(?,?)", undef, $lockname, $wait_time)
        or return undef;

    # successfully got a lock
    $LJ::LOCK_OUT{$dbrole} = $curr_sub;
    return 1;
}

# <LJFUNC>
# name: LJ::may_lock
# des: see if we COULD get a mysql lock on a given key/dbrole combination,
#      but don't actually get it.
# returns: undef if called improperly, true on success, die() on failure
# args: db, dbrole
# des-dbrole: the role this lock should be gotten on, either 'global' or 'user'
# </LJFUNC>
sub may_lock
{
    my ($db, $dbrole) = @_;
    return undef unless $db && ($dbrole eq 'global' || $dbrole eq 'user');

    # die if somebody already has a lock
    if ($LJ::LOCK_OUT{$dbrole}) {
        my $curr_sub = (caller 1)[3]; # caller of current sub
        die "LOCK ERROR: $curr_sub; can't get lock from $LJ::LOCK_OUT{$dbrole}\n";
    }

    # see if a lock is already out
    return undef if exists $LJ::LOCK_OUT{$dbrole};

    return 1;
}

# <LJFUNC>
# name: LJ::release_lock
# des: release a mysql lock on a given key/dbrole combination
# returns: undef if called improperly, true on success, die() on failure
# args: db, dbrole, lockname
# des-dbrole: the role this lock should be gotten on, either 'global' or 'user'
# des-lockname: the name to be used for this lock
# </LJFUNC>
sub release_lock
{
    my ($db, $dbrole, $lockname) = @_;
    return undef unless $db && $lockname;
    return undef unless $dbrole eq 'global' || $dbrole eq 'user';

    # get a lock from mysql
    $db->do("SELECT RELEASE_LOCK(?)", undef, $lockname);
    delete $LJ::LOCK_OUT{$dbrole};

    return 1;
}

# <LJFUNC>
# name: LJ::get_newids
# des: Lookup an old global ID and see what journal it belongs to and its new ID.
# info: Interface to [dbtable[oldids]] table (URL compatability)
# returns: Undef if non-existent or unconverted, or arrayref of [$userid, $newid].
# args: area, oldid
# des-area: The "area" of the id.  Legal values are "L" (log), to lookup an old itemid,
#           or "T" (talk) to lookup an old talkid.
# des-oldid: The old globally-unique id of the item.
# </LJFUNC>
sub get_newids
{
    my $sth;
    my $db = LJ::get_dbh("oldids") || LJ::get_db_reader();
    return $db->selectrow_arrayref("SELECT userid, newid FROM oldids ".
                                   "WHERE area=? AND oldid=?", undef,
                                   $_[0], $_[1]);
}

sub get_groupmask
{
    # TAG:FR:ljlib:get_groupmask
    my ($journal, $remote) = @_;
    return 0 unless $journal && $remote;

    my $jid = LJ::want_userid($journal);
    my $fid = LJ::want_userid($remote);
    return 0 unless $jid && $fid;

    my $memkey = [$jid,"frgmask:$jid:$fid"];
    my $mask = LJ::MemCache::get($memkey);
    unless (defined $mask) {
        my $dbr = LJ::get_db_reader();
        die "No database reader available" unless $dbr;

        $mask = $dbr->selectrow_array("SELECT groupmask FROM friends ".
                                      "WHERE userid=? AND friendid=?",
                                      undef, $jid, $fid);
        LJ::MemCache::set($memkey, $mask+0);
    }

    return $mask+0;  # force it to a numeric scalar
}

# <LJFUNC>
# name: LJ::get_timeupdate_multi
# des: Get the last time a list of users updated
# args: opt?, uids
# des-opt: optional hashref, currently can contain 'memcache_only' and 'max_age'
#          to only retrieve data from memcache
# des-uids: list of userids to load timeupdates for
# returns: hashref; uid => unix timeupdate
#
# --not used any more, see below
# </LJFUNC>
sub get_timeupdate_multi {
    my ($opt, @uids) = @_;

    # allow optional opt hashref as first argument
    unless (ref $opt eq 'HASH') {
        push @uids, $opt;
        $opt = {};
    }
    return {} unless @uids;

    my $oldest = $opt->{'max_age'} ? (time() - $opt->{'max_age'}) : 0;

    # L.P.: MemCache::get_multi() is not good for 10^4 entries (ljr_fif).
    # need_bind of a large size also not a good idea.

    my @memkeys = map { [$_, "tu:$_"] } @uids;
    my $mem = LJ::MemCache::get_multi(@memkeys) || {};

    my @need;
    my %timeupdate; # uid => timeupdate
    foreach (@uids) {
        if ($mem->{"tu:$_"}) {
            my $ttt = unpack("N", $mem->{"tu:$_"});
            $timeupdate{$_} = $ttt  if $ttt > $oldest;
        } else {
            push @need, $_;
        }
    }

    # if everything was in memcache, return now
    return \%timeupdate if $opt->{'memcache_only'} || ! @need;

    # fill in holes from the database.  safe to use the reader because we
    # only do an add to memcache, whereas postevent does a set, overwriting
    # any potentially old data
    my $dbr = LJ::get_db_reader();
    my $need_bind = join(",", map { "?" } @need);
    my $sth = $dbr->prepare("SELECT userid, UNIX_TIMESTAMP(timeupdate) " .
                            "FROM userusage WHERE userid IN ($need_bind)");
    $sth->execute(@need);
    while (my ($uid, $tu) = $sth->fetchrow_array) {
        $timeupdate{$uid} = $tu  if $tu > $oldest;

        # set memcache for this row
        LJ::MemCache::add([$uid, "tu:$uid"], pack("N", $tu));
    }

    return \%timeupdate;
}


# Simplified and optimized version of LJ::get_timeupdate_multi
# args: period in seconds, userids hashref
# returns: hashref
#     uid => unix timeupdate
#
sub get_timeupdate_multi_fast {
    my ($max_age, $hint) = @_;

    unless ($max_age) {
       return LJ::get_timeupdate_multi(keys %$hint); #fallfack :(
    }

    my $store_max_age = $LJ::MAX_FRIENDS_VIEW_AGE || 3600*24*56; # 8 weeks default
    my $cut_age = $max_age ? time() - $max_age : time() - $store_max_age;

    my %timeupdate;
    my $updates = LJ::MemCache::get("blob:timeupdate");
    if ($updates && @$updates > 1 && $updates->[0] == @$updates) {
       my $i = 1; my $imax = @$updates -1;
       while ($i < $imax) {
           my ($uid, $tu) = ($updates->[$i++], $updates->[$i++]);
           $timeupdate{$uid} = $tu  if $tu > $cut_age && (!$hint || exists $hint->{$uid});
       }
       return \%timeupdate;
    }

    $updates = [0];
    my $dbr = LJ::get_db_reader();
    my $sth = $dbr->prepare("SELECT userid, UNIX_TIMESTAMP(timeupdate)  FROM userusage " .
                            "WHERE timeupdate > DATE_SUB(NOW(), INTERVAL $store_max_age SECOND)");
    $sth->execute();
    while (my ($uid, $tu) = $sth->fetchrow_array) {
        push @$updates, ($uid, $tu);
        $timeupdate{$uid} = $tu  if $tu > $cut_age && (!$hint || exists $hint->{$uid});
    }
    $updates->[0] = @$updates;
    LJ::MemCache::set("blob:timeupdate", $updates, 60);  # 1 minute

    return \%timeupdate;
}


# <LJFUNC>
# name: LJ::get_friend_items
# des: Return friend items for a given user, filter, and period.
# args: dbarg?, opts
# des-opts: Hashref of options:
#           - u
#           - remote
#           - itemshow
#           - skip
#           - dayskip (!)
#           - filter  (opt) defaults to all
#           - friends (opt) friends rows loaded via LJ::get_friends()
#           - friends_u (opt) u objects of all friends loaded
#           - dateformat:  either "S2" for S2 code, or anything else for S1
#           - common_filter:  set true if this is the default view
#           - friendsoffriends: load friends of friends, not just friends
#           - showtypes: /[PYC]/
# returns: Array of item hashrefs containing the same elements
# </LJFUNC>
sub get_friend_items
{
    &nodb;
    my $opts = shift;

    my $u = $opts->{'u'};
    my $userid = $u->{'userid'};
    return () if $LJ::FORCE_EMPTY_FRIENDS{$userid};

    my $remote = $opts->{'remote'};
    my $remoteid = $remote ? $remote->{'userid'} : 0;

    my $itemshow = $opts->{'itemshow'}+0;
    my $skip = $opts->{'skip'}+0;
    my $getitems = $itemshow + $skip;

    my $filter = $opts->{'filter'}+0;

    my $max_age = $LJ::MAX_FRIENDS_VIEW_AGE || 3600*24*56; # 8 weeks default

    my $timeskip = 3600*24*($opts->{'dayskip'}+0);

    # sanity check:
    $skip = 0 if $skip < 0;

#use Time::HiRes qw(gettimeofday tv_interval);
#my $t0 = [gettimeofday];
#my @elapsed;
#push @elapsed, (tv_interval ($t0));
#print STDERR "@elapsed \n";

    my $debug = 0; my @stat = ();
    my $fif_optimized = ! $opts->{'friendsoffriends'} &&
                         (($LJ::LJR_FIF && LJ::get_userid($LJ::LJR_FIF) == $userid) ||
                          ($LJ::LJR_SYN && LJ::get_userid($LJ::LJR_SYN) == $userid));

    # given a hash of friends rows, strip out rows with invalid journals (twit)
    my $twit_friends = sub {
        my $friends = shift;

        # delete objects based on twit_list
        my $list = get_twit_list($remoteid);
        foreach my $twit (@$list) {
           delete $friends->{$twit}  if exists $friends->{$twit};
        }
    };

    # given a hash of friends rows, strip out rows with invalid journaltype
    my $filter_journaltypes = sub {
        my ($friends, $friends_u, $valid_types) = @_;
        return unless $friends && $friends_u;

        push (@stat, scalar keys %$friends) if $debug;

        # delete objects based on twit_list
        $twit_friends->($friends);

        # load u objects for all the given
        LJ::load_userids_multiple([ map { $_, \$friends_u->{$_} } keys %$friends ]);

        # delete u objects based on 'showtypes' and 'statusvis'
        $valid_types ||= uc($opts->{'showtypes'});

        foreach my $fid (keys %$friends_u) {
            my $fu = $friends_u->{$fid};
            if ($fu->{'statusvis'} ne "V" || #check_twit($remoteid, $fid) ||
                $valid_types && index(uc($valid_types), $fu->{journaltype}) == -1)
            {
                delete $friends_u->{$fid};
                delete $friends->{$fid};
            }
        }
        push (@stat, scalar keys %$friends) if $debug;

        # all args passed by reference
        return;
    };

    my @friends_buffer = ();

    ######################################
    # normal friends mode (journals for /friends page)
    my $fill_friends_buffer = sub
    {
        # get all friends for this user and groupmask
        my $friends = LJ::get_friends($userid, $filter) || {};
        push (@stat, scalar keys %$friends) if $debug;

        # get update times for friendids, strip out too old
        my $timeupdate = LJ::get_timeupdate_multi_fast($max_age, $friends) || {};

        # strip out invalid friend journals
        my %friends_u;
        $filter_journaltypes->($timeupdate, \%friends_u);

        # now push a properly formatted @friends_buffer row
        foreach my $fid (keys %friends_u) {
            push @friends_buffer, [ $fid, $timeupdate->{$fid}, $friends->{$fid}, $friends_u{$fid} ];
        }
    };

    ######################################
    # normal friends mode for ljr_fif (optimized ljr_fif/friends page)
    $fill_friends_buffer = sub
    {
        $max_age = 3600*24*5  if $skip < 101 && $timeskip ==0;

        # get recently changed ids
        my $timeupdate = LJ::get_timeupdate_multi_fast($max_age);
        push (@stat, scalar keys %$timeupdate) if $debug;

        # get all friends for this user and groupmask, within %$timeupdate entries
        my $friends = LJ::get_friends($userid, $filter, undef, undef, $timeupdate) || {};

        # strip out invalid friend journals
        my %friends_u;
        $filter_journaltypes->($friends, \%friends_u);

        # now push a properly formatted @friends_buffer row
        foreach my $fid (keys %friends_u) {
            push @friends_buffer, [ $fid, $timeupdate->{$fid}, $friends->{$fid}, $friends_u{$fid} ];
        }
    } if $fif_optimized;

    #################################################
    # memcached friends of friends mode (journals for /friendsfriends page)
    $fill_friends_buffer = sub
    {
        # get journal's friends
        my $friends = LJ::get_friends($userid, $filter) || {};

        # strip out invalid friend journaltypes
        my %friends_u;
        $filter_journaltypes->($friends, \%friends_u, "P");

        # get friends of friends
        my $ffriends = LJ::get_friends_multi($friends, $filter) || {};  # hash arg!

        # exclude self, if happen
        delete $ffriends->{$userid} if exists $ffriends->{$userid};

        # get update times for friendsfriends, strip out too old
        my $ff_tu = LJ::get_timeupdate_multi_fast($max_age, $ffriends);

        # strip out invalid friendsfriends journaltypes
        my %ffriends_u;
        $filter_journaltypes->($ff_tu, \%ffriends_u);

        # build friends buffer
        foreach my $ffid (keys %ffriends_u) {
            # since this is ff mode, we'll force colors to ffffff on 000000
            $ffriends->{$ffid}->{'fgcolor'} = "#000000";
            $ffriends->{$ffid}->{'bgcolor'} = "#ffffff";

            push @friends_buffer, [ $ffid, $ff_tu->{$ffid}, $ffriends->{$ffid}, $ffriends_u{$ffid} ];
        }

    } if $opts->{'friendsoffriends'} && @LJ::MEMCACHE_SERVERS;

    ##############################################
    # old friends of friends mode (journals for /friendsfriends page)
    # - use this when there are no memcache servers
    $fill_friends_buffer = sub
    {
        # load all user's friends of friends
        # TAG:FR:ljlib:old_friendsfriends_getitems
        my %f;
        my $dbr = LJ::get_db_reader();
        my $sth = $dbr->prepare(qq{
            SELECT f.friendid, f.groupmask, UNIX_TIMESTAMP(uu.timeupdate),
            u.journaltype FROM friends f, userusage uu, user u
            WHERE f.userid=? AND f.friendid=uu.userid AND u.userid=f.friendid AND u.journaltype='P'
        });
        $sth->execute($userid);
        while (my ($id, $mask, $time, $jt) = $sth->fetchrow_array) {
            next if $id == $userid; # don't follow user's own friends
            $f{$id} = { 'userid' => $id, 'timeupdate' => $time, 'jt' => $jt,
                        'relevant' => ($filter && !($mask & $filter)) ? 0 : 1 , };
        }

        # load some friends of friends (most 20 queries)
        my $fct = 0;
        foreach my $fid (sort { $f{$b}->{'timeupdate'} <=> $f{$a}->{'timeupdate'} } keys %f)
        {
            next unless $f{$fid}->{'jt'} eq "P" && $f{$fid}->{'relevant'};
            last if ++$fct > 20;
            my $extra;
            if ($opts->{'showtypes'}) {
                my @in;
                if ($opts->{'showtypes'} =~ /P/) { push @in, "'P'"; }
                if ($opts->{'showtypes'} =~ /Y/) { push @in, "'Y'"; }
                if ($opts->{'showtypes'} =~ /C/) { push @in, "'C','S','N'"; }
                $extra = "AND u.journaltype IN (".join (',', @in).")" if @in;
            }

            # TAG:FR:ljlib:old_friendsfriends_getitems2
            my $sth = $dbr->prepare(qq{
                SELECT u.*, UNIX_TIMESTAMP(uu.timeupdate) AS timeupdate
                FROM friends f, userusage uu, user u WHERE f.userid=? AND
                    f.friendid=uu.userid AND f.friendid=u.userid AND u.statusvis='V' $extra
                    AND uu.timeupdate > DATE_SUB(NOW(), INTERVAL 14 DAY) LIMIT 100
            });
            $sth->execute($fid);
            while (my $u = $sth->fetchrow_hashref) {
                my $uid = $u->{'userid'};
                next if $f{$uid} || $uid == $userid;  # we don't wanna see our friends
                next if check_twit($remoteid, $uid);

                # timeupdate
                my $time = $u->{'timeupdate'};
                delete $u->{'timeupdate'}; # not a proper $u column??

                push @friends_buffer, [ $uid, $time, {}, $u ];
            }
        }

    } if $opts->{'friendsoffriends'} && ! @LJ::MEMCACHE_SERVERS;
    ######################################


    $fill_friends_buffer->();

    ## sort is suboptimal for  $#friends_buffer >> $getitems, but $#friends_buffer < 500 in fact
    @friends_buffer = sort { $b->[1] <=> $a->[1] } @friends_buffer; #latest first

my $s4 = 0;
    my $get_next_friend = sub {
        my ($mintime) = @_;

        return undef  unless @friends_buffer && $friends_buffer[0]->[1] >= $mintime;
$s4++;
        return shift @friends_buffer;
    };

    my $lastmax = $LJ::EndOfTime - time() + $max_age;
    my $lastmin = $LJ::EndOfTime - time() + $timeskip; # 0 if $timeskip == 0  ??
    my @items = ();             # what we'll return
    my $itemsleft = $getitems;  # even though we got a bunch, potentially, they could be old
    my $fr;

    while ($itemsleft && ($fr = $get_next_friend->( $LJ::EndOfTime - $lastmax )))
    {
        # load the next recent updating friend's recent items
        my $friendid = $fr->[0];

        $opts->{'friends'}->{$friendid} = $fr->[2];  # friends row
        $opts->{'friends_u'}->{$friendid} = $fr->[3]; # friend u object

        my $newitems = LJ::get_log2_recent_user({
            'clusterid' => $fr->[3]->{'clusterid'},
            'userid' => $friendid,
            'remote' => $remote,
            'itemshow' => $itemsleft,
            'notafter' => $lastmax,  # reverse time!
            'notbefore' => $lastmin,
            'timeupdate' => $fr->[1],
        });
        next unless @$newitems;

        $itemsleft--; # we'll need at least one less for the next friend

        # sort all the total items by rlogtime (recent at beginning).
        # if there's an in-second tie, the "newer" post is determined by
        # the higher jitemid, which means nothing if the posts are in the same
        # journal, but means everything if they are (which happens almost never
        # for a human, but all the time for RSS feeds, once we remove the
        # synsucker's 1-second delay between postevents)
        #
        # while we can merge sorted arrays (@newitems already sorted rlogtime),
        # doing append and sort performs faster and less error-prone
        #
        push @items, @$newitems;

        if (@items >= $getitems)
        {
            @items = sort {$a->[0] <=> $b->[0] ||        # rlogtime
                           $b->[1] <=> $a->[1]} @items;  # jitemid
            @items = splice(@items, 0, $getitems);

            $lastmax = $items[-1]->[0];  # rlogtime

            # stop looping if we know the next friend's newest entry
            # is older than the oldest one we've already loaded.
        }
    }
    @items = sort {$a->[0] <=> $b->[0] ||        # rlogtime
                   $b->[1] <=> $a->[1]} @items;  # jitemid
    @items = splice(@items, 0, $getitems)  if @items > $getitems;

print STDERR "debug get_friend_items(): userid $userid -> $stat[0] $stat[1] $stat[2](twit $remoteid) $stat[3](statusvis);  used $s4, getitems $getitems\n" if $debug;

    # remove skipped ones
    splice(@items, 0, $skip) if $skip;

    my @friend_items = ();       # what we'll return, in hashref format

    # convert and fill
    foreach (@items) {
        ### fields really used by the caller:  qw(ownerid posterid itemid security alldatepart), 'anum'.
	#
        my $item = {};
        # $_ = [$rlogtime, $jitemid, $posterid, $eventtime, $anum, $ditemid, $security, $journalid]
        @$item{'rlogtime', 'itemid', 'posterid', 'alldatepart', 'anum', 'ditemid', 'security', 'ownerid'} = @$_;
	# renamed: jitemid->itemid, eventtime->alldatepart,  userid=journalid->ownerid)
        push @friend_items, $item;


        #set owner
        $opts->{'owners'}->{$item->{'ownerid'}} = 1;

        # date conversion
        if ($opts->{'dateformat'} eq "S2") {
            $item->{'alldatepart'} = LJ::alldatepart_s2(LJ::mysql_time($item->{'alldatepart'}, 1)); #was: eventtime
        } else {
            $item->{'alldatepart'} = LJ::alldatepart_s1(LJ::mysql_time($item->{'alldatepart'}, 1)); #was: eventtime
        }
    }


    LJ::fill_items_with_text_props(\@friend_items, $opts->{'friends_u'}, {'multiowner' => 1});

    #LJ::MemCache::add([$userid, "Test1:$userid"],  \@friend_items, 300) if ($remoteid && $userid == 4);

    return @friend_items;
}

# <LJFUNC>
# name: LJ::get_recent_items
# class:
# des: Returns journal entries for a given account.
# info:
# args: dbarg, opts
# des-opts: Hashref of options with keys:
#           -- u: $u object
#           -- err: scalar ref to return error code/msg in
#           -- remote: remote user's $u
#           -- tags: arrayref of tag strings to return entries with
#           -- clustersource: if value 'slave', uses replicated databases
#           -- order: if 'logtime', sorts by logtime, not eventtime
#           -- friendsview: if true, sorts by logtime, not eventtime
#           -- notafter: upper bound inclusive for rlogtime/revttime (depending on sort mode),
#              defaults to no limit
#           -- itemshow: items to show
#           -- skip: items to skip
#           -- dayskip (!)
#           -- viewall: if set, no security is used.
#           -- dateformat: if "S2", uses S2's 'alldatepart' format.
#
# returns: array of hashrefs containing keys:
#          -- itemid (the jitemid)
#          -- posterid
#          -- security
#          -- alldatepart (in S1 or S2 fmt, depending on 'dateformat' req key)
#          -- ownerid (if in 'friendsview' mode)
#          -- rlogtime (if in 'friendsview' mode)
#          -- text (array)
#          -- props (hash)
# </LJFUNC>
sub get_recent_items
{
    &nodb;
    my $opts = shift;

    my $sth;

    my @items = ();             # what we'll return
    my $err = $opts->{'err'};

    my $userid = $opts->{'u'}->{'userid'};

    my $remote = $opts->{'remote'};
    my $remoteid = $remote ? $remote->{'userid'} : 0;

    my $clusterid = $opts->{'u'}->{'clusterid'};
    my @sources = ("cluster$clusterid");
    if (my $ab = $LJ::CLUSTER_PAIR_ACTIVE{$clusterid}) {
        @sources = ("cluster${clusterid}${ab}");
    }
    unshift @sources, ("cluster${clusterid}lite", "cluster${clusterid}slave")
        if $opts->{'clustersource'} eq "slave";
    my $logdb = LJ::get_dbh(@sources);

    my $sort_key = "revttime";

    # community/friend views need to post by log time, not event time
    $sort_key = "rlogtime" if ($opts->{'order'} eq "logtime" ||
                               $opts->{'friendsview'});

    # 'notafter':
    #   the friends view doesn't want to load things that it knows it
    #   won't be able to use.  if this argument is zero or undefined,
    #   then we'll load everything less than or equal to 1 second from
    #   the end of time.  we don't include the last end of time second
    #   because that's what backdated entries are set to.  (so for one
    #   second at the end of time we'll have a flashback of all those
    #   backdated entries... but then the world explodes and everybody
    #   with 32 bit time_t structs dies)
    my $notafter = $opts->{'notafter'} + 0 || $LJ::EndOfTime - 1;
    my $timewhere = " $sort_key <= $notafter ";

    my $skip = $opts->{'skip'}+0;
    my $itemshow = $opts->{'itemshow'}+0;
    #sanity check:
    my $max_hints = $LJ::MAX_HINTS_LASTN;  # temporary
    if ($itemshow > $max_hints) { $itemshow = $max_hints; }
    my $maxskip = $max_hints - $itemshow;
    if ($skip < 0) { $skip = 0; }
    if ($skip > $maxskip) { $skip = $maxskip; }

    my $t = 3600*24*($opts->{'dayskip'}+0);
    if ($t) {
        $timewhere .= "AND $sort_key > ($LJ::EndOfTime - UNIX_TIMESTAMP()) + $t ";
    }

    my $mask = 0;
    if ($remote &&
      ($remote->{'journaltype'} eq "P" || $remote->{'journaltype'} eq "I") &&
      $remoteid != $userid) {
        $mask = LJ::get_groupmask($userid, $remoteid);
    }

    # decide what level of security the remote user can see
    my $secwhere = "";
    if ($userid == $remoteid || $opts->{'viewall'}) {
        # no extra where restrictions... user can see all their own stuff
        # alternatively, if 'viewall' opt flag is set, security is off.
    } elsif ($mask) {
        # can see public or things with them in the mask
        $secwhere = "AND (security='public' OR (security='usemask' AND allowmask & $mask != 0)) ";
    } else {
        # not a friend?  only see public.
        $secwhere = "AND security='public' ";
    }

    # because LJ::get_friend_items needs rlogtime for sorting.
    my $extra_sql;
    if ($opts->{'friendsview'}) {
        $extra_sql .= "journalid AS 'ownerid', rlogtime, ";
    }

    # if we need to get by tag, get an itemid list now
    my $jitemidwhere;
    if ($opts->{tags}) {

        # from keyword to tag
        $opts->{tagids} = [];
        my $tags = LJ::Tags::get_usertags($opts->{'u'}, { remote => $remote });
        my %kwref = ( map { $tags->{$_}->{name} => $_ } keys %{$tags || {}} );
        foreach (@{$opts->{tags}}) {
             push @{$opts->{tagids}}, $kwref{$_} if $kwref{$_};
        }
        unless (scalar @{$opts->{tagids}}) { return (); }

        # select jitemids uniquely
        my $in = join(',', map { $_+0 } @{$opts->{tagids}});
        my $jitemids = $logdb->selectcol_arrayref(qq{
                SELECT DISTINCT jitemid FROM logtags WHERE journalid = ? AND kwid IN ($in)
            }, undef, $userid);
        die $logdb->errstr if $logdb->err;

        # set $jitemidwhere iff we have jitemids
        if (@$jitemids) {
            $jitemidwhere = " AND jitemid IN (" .
                            join(',', map { $_+0 } @$jitemids) .
                            ")";
        } else {
            # no items, so show no entries
            return ();
        }
    }

    my $sql;

    my $dateformat = "%a %W %b %M %y %Y %c %m %e %d %D %p %i %l %h %k %H";
    if ($opts->{'dateformat'} eq "S2") {
        $dateformat = "%Y %m %d %H %i %s %w"; # yyyy mm dd hh mm ss day_of_week
    }

    $sql = qq{
        SELECT jitemid AS 'itemid', posterid, security, $extra_sql
               DATE_FORMAT(eventtime, "$dateformat") AS 'alldatepart', anum
        FROM log2 USE INDEX ($sort_key)
        WHERE journalid=$userid AND $timewhere $secwhere $jitemidwhere
        ORDER BY $sort_key
        LIMIT $skip,$itemshow
    };

    unless ($logdb) {
        $$err = "nodb" if ref $err eq "SCALAR";
        return ();
    }

    $sth = $logdb->prepare($sql);
    $sth->execute;
    if ($logdb->err) { die $logdb->errstr; }

    # keep track of the last alldatepart, and a per-minute buffer -- ??? zachem eto ???
    my $last_time;
    my @buf;
    my $flush = sub {
        return unless @buf;
        push @items, sort { $b->{itemid} <=> $a->{itemid} } @buf;
        @buf = ();
    };

    while (my $li = $sth->fetchrow_hashref) {

        $flush->() if $li->{alldatepart} ne $last_time;
        push @buf, $li;
        $last_time = $li->{alldatepart};
    }
    $flush->();


    LJ::fill_items_with_text_props(\@items, $opts->{'u'});

    #LJ::MemCache::add([$userid, "Test:$userid"],  \@items, 300) if ($remoteid && $userid == 4);

    return @items;
}

# <LJFUNC>
# name: LJ::register_authaction
# des: Registers a secret to have the user validate.
# info: Some things, like requiring a user to validate their email address, require
#       making up a secret, mailing it to the user, then requiring them to give it
#       back (usually in a URL you make for them) to prove they got it.  This
#       function creates a secret, attaching what it's for and an optional argument.
#       Background maintenance jobs keep track of cleaning up old unvalidated secrets.
# args: dbarg?, userid, action, arg?
# des-userid: Userid of user to register authaction for.
# des-action: Action type to register.   Max chars: 50.
# des-arg: Optional argument to attach to the action.  Max chars: 255.
# returns: 0 if there was an error.  Otherwise, a hashref
#          containing keys 'aaid' (the authaction ID) and the 'authcode',
#          a 15 character string of random characters from
#          [func[LJ::make_auth_code]].
# </LJFUNC>
sub register_authaction
{
    &nodb;
    my $dbh = LJ::get_db_writer();

    my $userid = shift;  $userid += 0;
    my $action = $dbh->quote(shift);
    my $arg1 = $dbh->quote(shift);

    # make the authcode
    my $authcode = LJ::make_auth_code(15);
    my $qauthcode = $dbh->quote($authcode);

    $dbh->do("INSERT INTO authactions (aaid, userid, datecreate, authcode, action, arg1) ".
             "VALUES (NULL, $userid, NOW(), $qauthcode, $action, $arg1)");

    return 0 if $dbh->err;
    return { 'aaid' => $dbh->{'mysql_insertid'},
             'authcode' => $authcode,
         };
}

# <LJFUNC>
# class: logging
# name: LJ::statushistory_add
# des: Adds a row to a user's statushistory
# info: See the [dbtable[statushistory]] table.
# returns: boolean; 1 on success, 0 on failure
# args: dbarg?, userid, adminid, shtype, notes?
# des-userid: The user being acted on.
# des-adminid: The site admin doing the action.
# des-shtype: The status history type code.
# des-notes: Optional notes associated with this action.
# </LJFUNC>
sub statushistory_add
{
    &nodb;
    my $dbh = LJ::get_db_writer();

    my $userid = shift;
    $userid = LJ::want_userid($userid) + 0;

    my $actid  = shift;

    my $qshtype = $dbh->quote(shift);
    my $qnotes  = $dbh->quote(shift);

    $dbh->do("INSERT INTO statushistory (userid, adminid, shtype, notes) ".
             "VALUES ($userid, $actid, $qshtype, $qnotes)");
    return $dbh->err ? 0 : 1;
}

# <LJFUNC>
# name: LJ::make_link
# des: Takes a group of key=value pairs to append to a url
# returns: The finished url
# args: url, vars
# des-url: A string with the URL to append to.  The URL
#          shouldn't have a question mark in it.
# des-vars: A hashref of the key=value pairs to append with.
# </LJFUNC>
sub make_link
{
    my $url = shift;
    my $vars = shift;
    my $append = "?";
    foreach (keys %$vars) {
        next if ($vars->{$_} eq "");
        $url .= "${append}${_}=$vars->{$_}";
        $append = "&";
    }
    return $url;
}

# <LJFUNC>
# class: time
# name: LJ::ago_text
# des: Converts integer seconds to English time span
# info: Turns a number of seconds into the largest possible unit of
#       time. "2 weeks", "4 days", or "20 hours".
# returns: A string with the number of largest units found
# args: secondsold
# des-secondsold: The number of seconds from now something was made.
# </LJFUNC>
sub ago_text
{
    my $secondsold = shift;
    return "Never." unless defined $secondsold;
    my $num;
    my $unit;
    if ($secondsold > 60*60*24*7) {
        $num = int($secondsold / (60*60*24*7));
        $unit = "week";
    } elsif ($secondsold > 60*60*24) {
        $num = int($secondsold / (60*60*24));
        $unit = "day";
    } elsif ($secondsold > 60*60) {
        $num = int($secondsold / (60*60));
        $unit = "hour";
    } elsif ($secondsold > 60) {
        $num = int($secondsold / (60));
        $unit = "minute";
    } else {
        $num = $secondsold;
        $unit = "second";
    }
    return "$num $unit" . ($num==1?"":"s") . " ago";
}

# <LJFUNC>
# name: LJ::get_authas_user
# des: Given a username, will return a user object if remote is an admin for the
#      username.  Otherwise returns undef
# returns: user object if authenticated, otherwise undef.
# args: user
# des-opts: Username of user to attempt to auth as.
# </LJFUNC>
sub get_authas_user {
    my $user = shift;
    return undef unless $user;

    # get a remote
    my $remote = LJ::get_remote();
    return undef unless $remote;

    # remote is already what they want?
    return $remote if $remote->{'user'} eq $user;

    # load user and authenticate
    my $u = LJ::load_user($user);
    return undef unless $u;
    return undef unless $u->{clusterid};

    # does $u have admin access?
    return undef unless LJ::can_manage($remote, $u);

    # passed all checks, return $u
    return $u;
}

# <LJFUNC>
# name: LJ::shared_member_request
# des: Registers an authaction to add a user to a
#      shared journal and sends an approval email
# returns: Hashref; output of LJ::register_authaction()
#          includes datecreate of old row if no new row was created
# args: ju, u, attr?
# des-ju: Shared journal user object
# des-u: User object to add to shared journal
# </LJFUNC>
sub shared_member_request {
    my ($ju, $u) = @_;
    return undef unless ref $ju && ref $u;

    my $dbh = LJ::get_db_writer();

    # check for duplicates
    my $oldaa = $dbh->selectrow_hashref("SELECT aaid, authcode, datecreate FROM authactions " .
                                        "WHERE userid=? AND action='shared_invite' AND used='N' " .
                                        "AND NOW() < datecreate + INTERVAL 1 HOUR " .
                                        "ORDER BY 1 DESC LIMIT 1",
                                        undef, $ju->{'userid'});
    return $oldaa if $oldaa;

    # insert authactions row
    my $aa = LJ::register_authaction($ju->{'userid'}, 'shared_invite', "targetid=$u->{'userid'}");
    return undef unless $aa;

    # if there are older duplicates, invalidate any existing unused authactions of this type
    $dbh->do("UPDATE authactions SET used='Y' WHERE userid=? AND aaid<>? " .
             "AND action='shared_invite' AND used='N'",
             undef, $ju->{'userid'}, $aa->{'aaid'});

    my $body = "The maintainer of the $ju->{'user'} shared journal has requested that " .
        "you be given posting access.\n\n" .
        "If you do not wish to be added to this journal, just ignore this email.  " .
        "However, if you would like to accept posting rights to $ju->{'user'}, click " .
        "the link below to authorize this action.\n\n" .
        "     $LJ::SITEROOT/approve/$aa->{'aaid'}.$aa->{'authcode'}\n\n" .
        "Regards\n$LJ::SITENAME Team\n";

    LJ::send_mail({
        'to' => $u->{'email'},
        'from' => $LJ::ADMIN_EMAIL,
        'fromname' => $LJ::SITENAME,
        'charset' => 'utf-8',
        'subject' => "Community Membership: $ju->{'name'}",
        'body' => $body
        });

    return $aa;
}

# <LJFUNC>
# name: LJ::is_valid_authaction
# des: Validates a shared secret (authid/authcode pair)
# info: See [func[LJ::register_authaction]].
# returns: Hashref of authaction row from database.
# args: dbarg?, aaid, auth
# des-aaid: Integer; the authaction ID.
# des-auth: String; the auth string. (random chars the client already got)
# </LJFUNC>
sub is_valid_authaction
{
    &nodb;

    # we use the master db to avoid races where authactions could be
    # used multiple times
    my $dbh = LJ::get_db_writer();
    my ($aaid, $auth) = @_;
    return $dbh->selectrow_hashref("SELECT * FROM authactions WHERE aaid=? AND authcode=?",
                                   undef, $aaid, $auth);
}

# <LJFUNC>
# name: LJ::mark_authaction_used
# des: Marks an authaction as being used.
# args: aaid
# des-aaid: Either an authaction hashref or the id of the authaction to mark used.
# returns: 1 on success, undef on error.
# </LJFUNC>
sub mark_authaction_used
{
    my $aaid = ref $_[0] ? $_[0]->{aaid}+0 : $_[0]+0
        or return undef;
    my $dbh = LJ::get_db_writer()
        or return undef;
    $dbh->do("UPDATE authactions SET used='Y' WHERE aaid = ?", undef, $aaid);
    return undef if $dbh->err;
    return 1;
}

# <LJFUNC>
# name: LJ::get_mood_picture
# des: Loads a mood icon hashref given a themeid and moodid.
# args: themeid, moodid, ref
# des-themeid: Integer; mood themeid.
# des-moodid: Integer; mood id.
# des-ref: Hashref to load mood icon data into.
# returns: Boolean; 1 on success, 0 otherwise.
# </LJFUNC>
sub get_mood_picture
{
    my ($themeid, $moodid, $ref) = @_;
    my $moods_encountered;

    LJ::load_mood_theme($themeid) unless $LJ::CACHE_MOOD_THEME{$themeid};
    LJ::load_moods() unless $LJ::CACHED_MOODS;
    do
    {
        if ($LJ::CACHE_MOOD_THEME{$themeid} &&
            $LJ::CACHE_MOOD_THEME{$themeid}->{$moodid}) {
            %{$ref} = %{$LJ::CACHE_MOOD_THEME{$themeid}->{$moodid}};
            if ($ref->{'pic'} =~ m!^/!) {
                $ref->{'pic'} =~ s!^/img!!;
                $ref->{'pic'} = $LJ::IMGPREFIX . $ref->{'pic'};
            }
            $ref->{'moodid'} = $moodid;
            return 1;
        } else {
          if ($moods_encountered->{$moodid}) {
            $moodid = 0;
          }
          else {
            $moods_encountered->{$moodid} = 1;
            $moodid = (defined $LJ::CACHE_MOODS{$moodid} ?
                       $LJ::CACHE_MOODS{$moodid}->{'parent'} : 0);
          }
        }
    }
    while ($moodid);
    return 0;
}

# mood id to name (or undef)
sub mood_name
{
    my ($moodid) = @_;
    LJ::load_moods() unless $LJ::CACHED_MOODS;
    my $m = $LJ::CACHE_MOODS{$moodid};
    return $m ? $m->{'name'} : undef;
}

# mood name to id (or undef)
sub mood_id
{
    my ($mood) = @_;
    return undef unless $mood;
    LJ::load_moods() unless $LJ::CACHED_MOODS;
    foreach my $m (values %LJ::CACHE_MOODS) {
        return $m->{'id'} if $mood eq $m->{'name'};
    }
    return undef;
}

sub get_moods
{
    LJ::load_moods() unless $LJ::CACHED_MOODS;
    return \%LJ::CACHE_MOODS;
}

# <LJFUNC>
# class: time
# name: LJ::http_to_time
# des: Converts HTTP date to Unix time.
# info: Wrapper around HTTP::Date::str2time.
#       See also [func[LJ::time_to_http]].
# args: string
# des-string: HTTP Date.  See RFC 2616 for format.
# returns: integer; Unix time.
# </LJFUNC>
sub http_to_time {
    my $string = shift;
    return HTTP::Date::str2time($string);
}

sub mysqldate_to_time {
    my ($string, $gmt) = @_;
    return undef unless $string =~ /^(\d\d\d\d)-(\d\d)-(\d\d)(?: (\d\d):(\d\d)(?::(\d\d))?)?$/;
    my ($y, $mon, $d, $h, $min, $s) = ($1, $2, $3, $4, $5, $6);
    my $calc = sub {
        $gmt ?
            Time::Local::timegm($s, $min, $h, $d, $mon-1, $y) :
            Time::Local::timelocal($s, $min, $h, $d, $mon-1, $y);

            #Error converting 2106-02-07 06:28:16: Day too big - 49710 > 24853
            #Cannot handle date (16, 28, 06, 07, 1, 2106) at /home/lj-admin/lj/cgi-bin/ljlib.pl line 1419
    };

    my $ret;
    ## try to do it.  it'll die if the day is bogus
    #$ret = eval { $calc->(); };
    #return $ret unless $@;

    # Year 2038 fix:
    $y = 2037 if $y > 2037;
    $y = 1970 if $y < 1970;
    # then fix the day up, if so.
    my $max_day = LJ::days_in_month($mon, $y);
    $d = $max_day if $d > $max_day;

    $ret = eval { $calc->(); };
    return $ret unless $@;
    
    print STDERR "Error converting $string: " . $@;
    return 0;
}

# <LJFUNC>
# class: time
# name: LJ::time_to_http
# des: Converts a Unix time to an HTTP date.
# info: Wrapper around HTTP::Date::time2str to make an
#       HTTP date (RFC 1123 format)  See also [func[LJ::http_to_time]].
# args: time
# des-time: Integer; Unix time.
# returns: String; RFC 1123 date.
# </LJFUNC>
sub time_to_http {
    my $time = shift;
    return HTTP::Date::time2str($time);
}

# <LJFUNC>
# name: LJ::time_to_cookie
# des: Converts unix time to format expected in a Set-Cookie header
# args: time
# des-time: unix time
# returns: string; Date/Time in format expected by cookie.
# </LJFUNC>
sub time_to_cookie {
    my $time = shift;
    $time = time() unless defined $time;

    my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = gmtime($time);
    $year+=1900;

    my @day = qw{Sunday Monday Tuesday Wednesday Thursday Friday Saturday};
    my @month = qw{Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec};

    return sprintf("$day[$wday], %02d-$month[$mon]-%04d %02d:%02d:%02d GMT",
                   $mday, $year, $hour, $min, $sec);
}

# http://www.w3.org/TR/NOTE-datetime
# http://www.w3.org/TR/xmlschema-2/#dateTime
sub time_to_w3c {
    my ($time, $ofs) = @_;
    my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = gmtime($time);

    $mon++;
    $year += 1900;

    $ofs =~ s/([\-+]\d\d)(\d\d)/$1:$2/;
    $ofs = 'Z' if $ofs =~ /0000$/;
    return sprintf("%04d-%02d-%02dT%02d:%02d:%02d$ofs",
                   $year, $mon, $mday,
                   $hour, $min, $sec);
}

# <LJFUNC>
# name: LJ::get_urls
# des: Returns a list of all referenced URLs from a string
# args: text
# des-text: Text to extra URLs from
# returns: list of URLs
# </LJFUNC>
sub get_urls
{
    return ($_[0] =~ m!http://[^\s\"\'\<\>]+!g);
}

# <LJFUNC>
# name: LJ::record_meme
# des: Records a URL reference from a journal entry to the meme table.
# args: dbarg?, url, posterid, itemid, journalid?
# des-url: URL to log
# des-posterid: Userid of person posting
# des-itemid: Itemid URL appears in.  This is the display itemid,
#             which is the jitemid*256+anum from the [dbtable[log2]] table.
# des-journalid: Optional, journal id of item, if item is clustered.  Otherwise
#                this should be zero or undef.
# </LJFUNC>
sub record_meme
{
    my ($url, $posterid, $itemid, $jid) = @_;
    return if $LJ::DISABLED{'meme'};

    $url =~ s!/$!!;  # strip / at end
    LJ::run_hooks("canonicalize_url", \$url);

    # canonicalize_url hook might just erase it, so
    # we don't want to record it.
    return unless $url;

    my $dbh = LJ::get_db_writer();
    $dbh->do("REPLACE INTO meme (url, posterid, journalid, itemid) " .
             "VALUES (?, ?, ?, ?)", undef, $url, $posterid, $jid, $itemid);
}

# <LJFUNC>
# name: LJ::name_caps
# des: Given a user's capability class bit mask, returns a
#      site-specific string representing the capability class name.
# args: caps
# des-caps: 16 bit capability bitmask
# </LJFUNC>
sub name_caps
{
    return undef unless LJ::are_hooks("name_caps");
    my $caps = shift;
    return LJ::run_hook("name_caps", $caps);
}

# <LJFUNC>
# name: LJ::name_caps_short
# des: Given a user's capability class bit mask, returns a
#      site-specific short string code.
# args: caps
# des-caps: 16 bit capability bitmask
# </LJFUNC>
sub name_caps_short
{
    return undef unless LJ::are_hooks("name_caps_short");
    my $caps = shift;
    return LJ::run_hook("name_caps_short", $caps);
}

# <LJFUNC>
# name: LJ::get_cap
# des: Given a user object or capability class bit mask and a capability/limit name,
#      returns the maximum value allowed for given user or class, considering
#      all the limits in each class the user is a part of.
# args: u_cap, capname
# des-u_cap: 16 bit capability bitmask or a user object from which the
#            bitmask could be obtained
# des-capname: the name of a limit, defined in doc/capabilities.txt
# </LJFUNC>
sub get_cap
{
    my $caps = shift;   # capability bitmask (16 bits), or user object
    my $cname = shift;  # capability limit name
    my $u = ref $caps ? $caps : undef;
    if (! defined $caps) { $caps = 0; }
    elsif ($u) { $caps = $u->{'caps'}; }
    my $max = undef;

    # allow a way for admins to force-set the read-only cap
    # to lower writes on a cluster.
    if ($cname eq "readonly" && $u &&
        ($LJ::READONLY_CLUSTER{$u->{clusterid}} ||
         $LJ::READONLY_CLUSTER_ADVISORY{$u->{clusterid}} &&
         ! LJ::get_cap($u, "avoid_readonly"))) {

        # HACK for desperate moments.  in when_needed mode, see if
        # database is locky first
        my $cid = $u->{clusterid};
        if ($LJ::READONLY_CLUSTER_ADVISORY{$cid} eq "when_needed") {
            my $now = time();
            return 1 if $LJ::LOCKY_CACHE{$cid} > $now - 15;

            my $dbcm = LJ::get_cluster_master($u->{clusterid});
            return 1 unless $dbcm;
            my $sth = $dbcm->prepare("SHOW PROCESSLIST");
            $sth->execute;
            return 1 if $dbcm->err;
            my $busy = 0;
            my $too_busy = $LJ::WHEN_NEEDED_THRES || 300;
            while (my $r = $sth->fetchrow_hashref) {
                $busy++ if $r->{Command} ne "Sleep";
            }
            if ($busy > $too_busy) {
                $LJ::LOCKY_CACHE{$cid} = $now;
                return 1;
            }
        } else {
            return 1;
        }
    }

    # underage/coppa check etc
    if ($cname eq "underage" && $u &&
        ($LJ::UNDERAGE_BIT &&
         $caps & 1 << $LJ::UNDERAGE_BIT)) {
        return 1;
    }

    # is there a hook for this cap name?
    if (LJ::are_hooks("check_cap_$cname")) {
  die "Hook 'check_cap_$cname' requires full user object"
      unless defined $u;

  my $val = LJ::run_hook("check_cap_$cname", $u);
  return $val if defined $val;

  # otherwise fall back to standard means
    }

    # otherwise check via other means
    foreach my $bit (keys %LJ::CAP) {
        next unless ($caps & (1 << $bit));
        my $v = $LJ::CAP{$bit}->{$cname};
        next unless (defined $v);
        next if (defined $max && $max > $v);
        $max = $v;
    }
    return defined $max ? $max : $LJ::CAP_DEF{$cname};
}

# <LJFUNC>
# name: LJ::get_cap_min
# des: Just like [func[LJ::get_cap]], but returns the minimum value.
#      Although it might not make sense at first, some things are
#      better when they're low, like the minimum amount of time
#      a user might have to wait between getting updates or being
#      allowed to refresh a page.
# args: u_cap, capname
# des-u_cap: 16 bit capability bitmask or a user object from which the
#            bitmask could be obtained
# des-capname: the name of a limit, defined in doc/capabilities.txt
# </LJFUNC>
sub get_cap_min
{
    my $caps = shift;   # capability bitmask (16 bits), or user object
    my $cname = shift;  # capability name
    if (! defined $caps) { $caps = 0; }
    elsif (isu($caps)) { $caps = $caps->{'caps'}; }
    my $min = undef;
    foreach my $bit (keys %LJ::CAP) {
        next unless ($caps & (1 << $bit));
        my $v = $LJ::CAP{$bit}->{$cname};
        next unless (defined $v);
        next if (defined $min && $min < $v);
        $min = $v;
    }
    return defined $min ? $min : $LJ::CAP_DEF{$cname};
}

# <LJFUNC>
# name: LJ::are_hooks
# des: Returns true if the site has one or more hooks installed for
#      the given hookname.
# args: hookname
# </LJFUNC>
sub are_hooks
{
    my $hookname = shift;
    return defined $LJ::HOOKS{$hookname};
}

# <LJFUNC>
# name: LJ::clear_hooks
# des: Removes all hooks.
# </LJFUNC>
sub clear_hooks
{
    %LJ::HOOKS = ();
}

# <LJFUNC>
# name: LJ::run_hooks
# des: Runs all the site-specific hooks of the given name.
# returns: list of arrayrefs, one for each hook ran, their
#          contents being their own return values.
# args: hookname, args*
# des-args: Arguments to be passed to hook.
# </LJFUNC>
sub run_hooks
{
    my ($hookname, @args) = @_;
    my @ret;
    foreach my $hook (@{$LJ::HOOKS{$hookname} || []}) {
        push @ret, [ $hook->(@args) ];
    }
    return @ret;
}

# <LJFUNC>
# name: LJ::run_hook
# des: Runs single site-specific hook of the given name.
# returns: return value from hook
# args: hookname, args*
# des-args: Arguments to be passed to hook.
# </LJFUNC>
sub run_hook
{
    my ($hookname, @args) = @_;
    return undef unless @{$LJ::HOOKS{$hookname} || []};
    return $LJ::HOOKS{$hookname}->[0]->(@args);
    return undef;
}

# <LJFUNC>
# name: LJ::register_hook
# des: Installs a site-specific hook.
# info: Installing multiple hooks per hookname is valid.
#       They're run later in the order they're registered.
# args: hookname, subref
# des-subref: Subroutine reference to run later.
# </LJFUNC>
sub register_hook
{
    my $hookname = shift;
    my $subref = shift;
    push @{$LJ::HOOKS{$hookname}}, $subref;
}

# <LJFUNC>
# name: LJ::register_setter
# des: Installs code to run for the "set" command in the console.
# info: Setters can be general or site-specific.
# args: key, subref
# des-key: Key to set.
# des-subref: Subroutine reference to run later.
# </LJFUNC>
sub register_setter
{
    my $key = shift;
    my $subref = shift;
    $LJ::SETTER{$key} = $subref;
}

register_setter('synlevel', sub {
    my ($dba, $u, $remote, $key, $value, $err) = @_;
    unless ($value =~ /^(title|summary|full)$/) {
        $$err = "Illegal value.  Must be 'title', 'summary', or 'full'";
        return 0;
    }
    
    LJ::set_userprop($u, 'opt_synlevel', $value);
    return 1;
});

register_setter("newpost_minsecurity", sub {
    my ($dba, $u, $remote, $key, $value, $err) = @_;
    unless ($value =~ /^(public|friends|private)$/) {
        $$err = "Illegal value.  Must be 'public', 'friends', or 'private'";
        return 0;
    }
    # Don't let commmunities be private
    if ($u->{'journaltype'} eq "C" && $value eq "private") {
        $$err = "newpost_minsecurity cannot be private for communities";
        return 0;
    }
    $value = "" if $value eq "public";
    LJ::set_userprop($u, "newpost_minsecurity", $value);
    return 1;
});

register_setter("stylesys", sub {
    my ($dba, $u, $remote, $key, $value, $err) = @_;
    unless ($value =~ /^[sS]?(1|2)$/) {
        $$err = "Illegal value.  Must be S1 or S2.";
        return 0;
    }
    $value = $1 + 0;
    LJ::set_userprop($u, "stylesys", $value);
    return 1;
});

register_setter("maximagesize", sub {
    my ($dba, $u, $remote, $key, $value, $err) = @_;
    unless ($value =~ m/^(\d+)[x,|](\d+)$/) {
        $$err = "Illegal value.  Must be width,height.";
        return 0;
    }
    $value = "$1|$2";
    LJ::set_userprop($u, "opt_imagelinks", $value);
    return 1;
});

register_setter("opt_ljcut_disable_lastn", sub {
    my ($dba, $u, $remote, $key, $value, $err) = @_;
    unless ($value =~ /^(0|1)$/) {
      $$err = "Illegal value. Must be '0' or '1'";
  return 0;
    }
    LJ:set_userprop($u, "opt_ljcut_disable_lastn", $value);
    return 1;
});

register_setter("opt_ljcut_disable_friends", sub {
    my ($dba, $u, $remote, $key, $value, $err) = @_;
    unless ($value =~ /^(0|1)$/) {
      $$err = "Illegal value. Must be '0' or '1'";
  return 0;
    }
    LJ:set_userprop($u, "opt_ljcut_disable_friends", $value);
    return 1;
});

register_setter("disable_quickreply", sub {
    my ($dba, $u, $remote, $key, $value, $err) = @_;
    unless ($value =~ /^(0|1)$/) {
      $$err = "Illegal value. Must be '0' or '1'";
  return 0;
    }
    LJ:set_userprop($u, "opt_no_quickreply", $value);
    return 1;
});

# <LJFUNC>
# name: LJ::make_auth_code
# des: Makes a random string of characters of a given length.
# returns: string of random characters, from an alphabet of 30
#          letters & numbers which aren't easily confused.
# args: length
# des-length: length of auth code to return
# </LJFUNC>
sub make_auth_code
{
    my $length = shift;
    my $digits = "abcdefghjkmnpqrstvwxyz23456789";
    my $auth;
    for (1..$length) { $auth .= substr($digits, int(rand(30)), 1); }
    return $auth;
}

# <LJFUNC>
# name: LJ::acid_encode
# des: Given a decimal number, returns base 30 encoding
#      using an alphabet of letters & numbers that are
#      not easily mistaken for each other.
# returns: Base 30 encoding, alwyas 7 characters long.
# args: number
# des-number: Number to encode in base 30.
# </LJFUNC>
sub acid_encode
{
    my $num = shift;
    my $acid = "";
    my $digits = "abcdefghjkmnpqrstvwxyz23456789";
    while ($num) {
        my $dig = $num % 30;
        $acid = substr($digits, $dig, 1) . $acid;
        $num = ($num - $dig) / 30;
    }
    return ("a"x(7-length($acid)) . $acid);
}

# <LJFUNC>
# name: LJ::acid_decode
# des: Given an acid encoding from [func[LJ::acid_encode]],
#      returns the original decimal number.
# returns: Integer.
# args: acid
# des-acid: base 30 number from [func[LJ::acid_encode]].
# </LJFUNC>
sub acid_decode
{
    my $acid = shift;
    $acid = lc($acid);
    my %val;
    my $digits = "abcdefghjkmnpqrstvwxyz23456789";
    for (0..30) { $val{substr($digits,$_,1)} = $_; }
    my $num = 0;
    my $place = 0;
    while ($acid) {
        return 0 unless ($acid =~ s/[$digits]$//o);
        $num += $val{$&} * (30 ** $place++);
    }
    return $num;
}

# <LJFUNC>
# name: LJ::acct_code_generate
# des: Creates invitation code(s) from an optional userid
#      for use by anybody.
# returns: Code generated (if quantity 1),
#          number of codes generated (if quantity>1),
#          or undef on failure.
# args: dbarg?, userid?, quantity?
# des-userid: Userid to make the invitation code from,
#             else the code will be from userid 0 (system)
# des-quantity: Number of codes to generate (default 1)
# </LJFUNC>
sub acct_code_generate
{
    &nodb;
    my $userid = int(shift);
    my $quantity = shift || 1;

    my $dbh = LJ::get_db_writer();

    my @authcodes = map {LJ::make_auth_code(5)} 1..$quantity;
    my @values = map {"(NULL, $userid, 0, '$_')"} @authcodes;
    my $sql = "INSERT INTO acctcode (acid, userid, rcptid, auth) "
            . "VALUES " . join(",", @values);
    my $num_rows = $dbh->do($sql) or return undef;

    if ($quantity == 1) {
        my $acid = $dbh->{'mysql_insertid'} or return undef;
        return acct_code_encode($acid, $authcodes[0]);
    } else {
        return $num_rows;
    }
}

# <LJFUNC>
# name: LJ::acct_code_encode
# des: Given an account ID integer and a 5 digit auth code, returns
#      a 12 digit account code.
# returns: 12 digit account code.
# args: acid, auth
# des-acid: account ID, a 4 byte unsigned integer
# des-auth: 5 random characters from base 30 alphabet.
# </LJFUNC>
sub acct_code_encode
{
    my $acid = shift;
    my $auth = shift;
    return lc($auth) . acid_encode($acid);
}

# <LJFUNC>
# name: LJ::acct_code_decode
# des: Breaks an account code down into its two parts
# returns: list of (account ID, auth code)
# args: code
# des-code: 12 digit account code
# </LJFUNC>
sub acct_code_decode
{
    my $code = shift;
    return (acid_decode(substr($code, 5, 7)), lc(substr($code, 0, 5)));
}

# <LJFUNC>
# name: LJ::acct_code_check
# des: Checks the validity of a given account code
# returns: boolean; 0 on failure, 1 on validity. sets $$err on failure.
# args: dbarg?, code, err?, userid?
# des-code: account code to check
# des-err: optional scalar ref to put error message into on failure
# des-userid: optional userid which is allowed in the rcptid field,
#             to allow for htdocs/create.bml case when people double
#             click the submit button.
# </LJFUNC>
sub acct_code_check
{
    &nodb;
    my $code = shift;
    my $err = shift;     # optional; scalar ref
    my $userid = shift;  # optional; acceptable userid (double-click proof)

    my $dbh = LJ::get_db_writer();

    unless (length($code) == 12) {
        $$err = "Malformed code; not 12 characters.";
        return 0;
    }

    my ($acid, $auth) = acct_code_decode($code);

    my $ac = $dbh->selectrow_hashref("SELECT userid, rcptid, auth ".
                                     "FROM acctcode WHERE acid=?",
                                     undef, $acid);

    unless ($ac && $ac->{'auth'} eq $auth) {
        $$err = "Invalid account code.";
        return 0;
    }

    if ($ac->{'rcptid'} && $ac->{'rcptid'} != $userid) {
        $$err = "This code has already been used: $code";
        return 0;
    }

    # is the journal this code came from suspended?
    my $u = LJ::load_userid($ac->{'userid'});
    if ($u && $u->{'statusvis'} eq "S") {
        $$err = "Code belongs to a suspended account.";
        return 0;
    }

    return 1;
}

# <LJFUNC>
# name: LJ::load_mood_theme
# des: Loads and caches a mood theme, or returns immediately if already loaded.
# args: dbarg?, themeid
# des-themeid: the mood theme ID to load
# </LJFUNC>
sub load_mood_theme
{
    &nodb;
    my $themeid = shift;
    return if $LJ::CACHE_MOOD_THEME{$themeid};
    return unless $themeid;

    # check memcache
    my $memkey = [$themeid, "moodthemedata:$themeid"];
    return if $LJ::CACHE_MOOD_THEME{$themeid} = LJ::MemCache::get($memkey) and
        %{$LJ::CACHE_MOOD_THEME{$themeid} || {}};

    # fall back to db
    my $dbh = LJ::get_db_writer()
        or return 0;

    $LJ::CACHE_MOOD_THEME{$themeid} = {};

    my $sth = $dbh->prepare("SELECT moodid, picurl, width, height FROM moodthemedata WHERE moodthemeid=?");
    $sth->execute($themeid);
    return 0 if $dbh->err;

    while (my ($id, $pic, $w, $h) = $sth->fetchrow_array) {
        $LJ::CACHE_MOOD_THEME{$themeid}->{$id} = { 'pic' => $pic, 'w' => $w, 'h' => $h };
    }

    # set in memcache
    LJ::MemCache::set($memkey, $LJ::CACHE_MOOD_THEME{$themeid})
        if %{$LJ::CACHE_MOOD_THEME{$themeid} || {}};

    return 1;
}

# <LJFUNC>
# name: LJ::load_props
# des: Loads and caches one or more of the various *proplist tables:
#      logproplist, talkproplist, and userproplist, which describe
#      the various meta-data that can be stored on log (journal) items,
#      comments, and users, respectively.
# args: dbarg?, table*
# des-table: a list of tables' proplists to load.  can be one of
#            "log", "talk", "user", or "rate"
# </LJFUNC>
sub load_props
{
    my $dbarg = ref $_[0] ? shift : undef;
    my @tables = @_;
    my $dbr;
    my %keyname = qw(log  propid
                     talk tpropid
                     user upropid
                     rate rlid
                     );

    foreach my $t (@tables) {
        next unless defined $keyname{$t};
        next if defined $LJ::CACHE_PROP{$t};
        my $tablename = $t eq "rate" ? "ratelist" : "${t}proplist";
        $dbr ||= LJ::get_db_reader();
        my $sth = $dbr->prepare("SELECT * FROM $tablename");
        $sth->execute;
        while (my $p = $sth->fetchrow_hashref) {
            $p->{'id'} = $p->{$keyname{$t}};
            $LJ::CACHE_PROP{$t}->{$p->{'name'}} = $p;
            $LJ::CACHE_PROPID{$t}->{$p->{'id'}} = $p;
        }
    }
}

# <LJFUNC>
# name: LJ::get_prop
# des: This is used to retrieve
#      a hashref of a row from the given tablename's proplist table.
#      One difference from getting it straight from the database is
#      that the 'id' key is always present, as a copy of the real
#      proplist unique id for that table.
# args: table, name
# returns: hashref of proplist row from db
# des-table: the tables to get a proplist hashref from.  can be one of
#            "log", "talk", or "user".
# des-name: the name of the prop to get the hashref of.
# </LJFUNC>
sub get_prop
{
    my $table = shift;
    my $name = shift;
    unless (defined $LJ::CACHE_PROP{$table}) {
        LJ::load_props($table);
        return undef unless $LJ::CACHE_PROP{$table};
    }
    return $LJ::CACHE_PROP{$table}->{$name};
}

# <LJFUNC>
# name: LJ::load_codes
# des: Populates hashrefs with lookup data from the database or from memory,
#      if already loaded in the past.  Examples of such lookup data include
#      state codes, country codes, color name/value mappings, etc.
# args: dbarg?, whatwhere
# des-whatwhere: a hashref with keys being the code types you want to load
#                and their associated values being hashrefs to where you
#                want that data to be populated.
# </LJFUNC>
sub load_codes
{
    &nodb;
    my $req = shift;

    my $dbr = LJ::get_db_reader();

    foreach my $type (keys %{$req})
    {
        my $memkey = "load_codes:$type";
        unless ($LJ::CACHE_CODES{$type} ||= LJ::MemCache::get($memkey))
        {
            $LJ::CACHE_CODES{$type} = [];
            my $sth = $dbr->prepare("SELECT code, item, sortorder FROM codes WHERE type=?");
            $sth->execute($type);
            while (my ($code, $item, $sortorder) = $sth->fetchrow_array)
            {
                push @{$LJ::CACHE_CODES{$type}}, [ $code, $item, $sortorder ];
            }
            @{$LJ::CACHE_CODES{$type}} =
                sort { $a->[2] <=> $b->[2] } @{$LJ::CACHE_CODES{$type}};
            LJ::MemCache::set($memkey, $LJ::CACHE_CODES{$type}, 60*15);
        }

        foreach my $it (@{$LJ::CACHE_CODES{$type}})
        {
            if (ref $req->{$type} eq "HASH") {
                $req->{$type}->{$it->[0]} = $it->[1];
            } elsif (ref $req->{$type} eq "ARRAY") {
                push @{$req->{$type}}, { 'code' => $it->[0], 'item' => $it->[1] };
            }
        }
    }
}

# <LJFUNC>
# name: LJ::debug
# des: When $LJ::DEBUG is set, logs the given message to
#      the Apache error log.  Or, if $LJ::DEBUG is 2, then
#      prints to STDOUT.
# returns: 1 if logging disabled, 0 on failure to open log, 1 otherwise
# args: message
# des-message: Message to log.
# </LJFUNC>
sub debug
{
    return 1 unless ($LJ::DEBUG);
    if ($LJ::DEBUG == 2) {
        print $_[0], "\n";
        return 1;
    }
    my $r = Apache->request;
    return 0 unless $r;
    $r->log_error($_[0]);
    return 1;
}

# <LJFUNC>
# name: LJ::auth_okay
# des: Validates a user's password.  The "clear" or "md5" argument
#      must be present, and either the "actual" argument (the correct
#      password) must be set, or the first argument must be a user
#      object ($u) with the 'password' key set.  Note that this is
#      the preferred way to validate a password (as opposed to doing
#      it by hand) since this function will use a pluggable authenticator
#      if one is defined, so LiveJournal installations can be based
#      off an LDAP server, for example.
# returns: boolean; 1 if authentication succeeded, 0 on failure
# args: u, clear, md5, actual?, ip_banned?
# des-clear: Clear text password the client is sending. (need this or md5)
# des-md5: MD5 of the password the client is sending. (need this or clear).
#          If this value instead of clear, clear can be anything, as md5
#          validation will take precedence.
# des-actual: The actual password for the user.  Ignored if a pluggable
#             authenticator is being used.  Required unless the first
#             argument is a user object instead of a username scalar.
# des-ip_banned: Optional scalar ref which this function will set to true
#                if IP address of remote user is banned.
# </LJFUNC>
sub auth_okay
{
    my $u = shift;
    my $clear = shift;
    my $md5 = shift;
    my $actual = shift;
    my $ip_banned = shift;
    return 0 unless isu($u);

    $actual ||= $u->{'password'};

    my $user = $u->{'user'};

    # set the IP banned flag, if it was provided.
    my $fake_scalar;
    my $ref = ref $ip_banned ? $ip_banned : \$fake_scalar;
    if (LJ::login_ip_banned($u)) {
        $$ref = 1;
        return 0;
    } else {
        $$ref = 0;
    }

    my $bad_login = sub {
        LJ::handle_bad_login($u);
        return 0;
    };

    # setup this auth checker for LDAP
    if ($LJ::LDAP_HOST && ! $LJ::AUTH_CHECK) {
        require LJ::LDAP;
        $LJ::AUTH_CHECK = sub {
            my ($user, $try, $type) = @_;
            die unless $type eq "clear";
            return LJ::LDAP::is_good_ldap($user, $try);
        };
    }

    ## custom authorization:
    if (ref $LJ::AUTH_CHECK eq "CODE") {
        my $type = $md5 ? "md5" : "clear";
        my $try = $md5 || $clear;
        my $good = $LJ::AUTH_CHECK->($user, $try, $type);
        return $good || $bad_login->();
    }

    ## LJ default authorization:
    return 0 unless $actual;
    return 1 if ($md5 && lc($md5) eq LJ::hash_password($actual));
    return 1 if ($clear eq $actual);
    return $bad_login->();
}

# Implement Digest authentication per RFC2617
# called with Apache's request oject
# modifies outgoing header fields appropriately and returns
# 1/0 according to whether auth succeeded. If succeeded, also
# calls LJ::set_remote() to set up internal LJ auth.
# this routine should be called whenever it's clear the client
# wants/the server demands digest auth, and if it returns 1,
# things proceed as usual; if it returns 0, the caller should
# $r->send_http_header(), output an auth error message in HTTP
# data and return to apache.
# Note: Authentication-Info: not sent (optional and nobody supports
# it anyway). Instead, server nonces are reused within their timeout
# limits and nonce counts are used to prevent replay attacks.

sub auth_digest {
    my ($r) = @_;

    my $decline = sub {
        my $stale = shift;

        my $nonce = LJ::challenge_generate(180); # 3 mins timeout
        my $authline = "Digest realm=\"lj\", nonce=\"$nonce\", algorithm=MD5, qop=\"auth\"";
        $authline .= ", stale=\"true\"" if $stale;
        $r->header_out("WWW-Authenticate", $authline);
        $r->status_line("401 Authentication required");
        return 0;
    };

    unless ($r->header_in("Authorization")) {
        return $decline->(0);
    }

    my $header = $r->header_in("Authorization");

    # parse it
    # TODO: could there be "," or " " inside attribute values, requiring
    # trickier parsing?

    my @vals = split(/[, \s]/, $header);
    my $authname = shift @vals;
    my %attrs;
    foreach (@vals) {
        if (/^(\S*?)=(\S*)$/) {
            my ($attr, $value) = ($1,$2);
            if ($value =~ m/^\"([^\"]*)\"$/) {
                $value = $1;
            }
            $attrs{$attr} = $value;
        }
    }

    # sanity checks
    unless ($authname eq 'Digest' && $attrs{'qop'} eq 'auth' &&
            $attrs{'realm'} eq 'lj' && $attrs{'algorithm'} eq 'MD5') {
        return $decline->(0);
    }

    my %opts;
    LJ::challenge_check($attrs{'nonce'}, \%opts);

    return $decline->(0) unless $opts{'valid'};

    # if the nonce expired, force a new one
    return $decline->(1) if $opts{'expired'};

    # check the nonce count
    # be lenient, allowing for error of magnitude 1 (Mozilla has a bug,
    # it repeats nc=00000001 twice...)
    # in case the count is off, force a new nonce; if a client's
    # nonce count implementation is broken and it doesn't send nc= or
    # always sends 1, this'll at least work due to leniency above

    my $ncount = hex($attrs{'nc'});

    unless (abs($opts{'count'} - $ncount) <= 1) {
        return $decline->(1);
    }

    # the username
    my $user = LJ::canonical_username($attrs{'username'});
    my $u = LJ::load_user($user);

    return $decline->(0) unless $u;

    # don't allow empty passwords

    return $decline->(0) unless $u->{'password'};

    # recalculate the hash and compare to response

    my $a1src="$u->{'user'}:lj:$u->{'password'}";
    my $a1 = Digest::MD5::md5_hex($a1src);
    my $a2src = $r->method . ":$attrs{'uri'}";
    my $a2 = Digest::MD5::md5_hex($a2src);
    my $hashsrc = "$a1:$attrs{'nonce'}:$attrs{'nc'}:$attrs{'cnonce'}:$attrs{'qop'}:$a2";
    my $hash = Digest::MD5::md5_hex($hashsrc);

    return $decline->(0)
        unless $hash eq $attrs{'response'};

    # set the remote
    LJ::set_remote($u);

    return $u;
}


# Create a challenge token for secure logins
sub challenge_generate
{
    my ($goodfor, $attr) = @_;

    $goodfor ||= 60;
    $attr ||= LJ::rand_chars(20);

    my ($stime, $secret) = LJ::get_secret();

    # challenge version, secret time, secret age, time in secs token is good for, random chars.
    my $s_age = time() - $stime;
    my $chalbare = "c0:$stime:$s_age:$goodfor:$attr";
    my $chalsig = Digest::MD5::md5_hex($chalbare . $secret);
    my $chal = "$chalbare:$chalsig";

    return $chal;
}

# Return challenge info.
# This could grow later - for now just return the rand chars used.
sub get_challenge_attributes
{
    return (split /:/, shift)[4];
}

# Validate a challenge string previously supplied by challenge_generate
# return 1 "good" 0 "bad", plus sets keys in $opts:
# 'valid'=1/0 whether the string itself was valid
# 'expired'=1/0 whether the challenge expired, provided it's valid
# 'count'=N number of times we've seen this challenge, including this one,
#           provided it's valid and not expired
# $opts also supports in parameters:
#   'dont_check_count' => if true, won't return a count field
# the return value is 1 if 'valid' and not 'expired' and 'count'==1
sub challenge_check {
    my ($chal, $opts) = @_;
    my ($valid, $expired, $count) = (1, 0, 0);

    my ($c_ver, $stime, $s_age, $goodfor, $rand, $chalsig) = split /:/, $chal;
    my $secret = LJ::get_secret($stime);
    my $chalbare = "$c_ver:$stime:$s_age:$goodfor:$rand";

    # Validate token
    $valid = 0
        unless $secret && $c_ver eq 'c0'; # wrong version
    $valid = 0
        unless Digest::MD5::md5_hex($chalbare . $secret) eq $chalsig;

    $expired = 1
        unless (not $valid) or time() - ($stime + $s_age) < $goodfor;

    # Check for token dups
    if ($valid && !$expired && !$opts->{dont_check_count}) {
        if (@LJ::MEMCACHE_SERVERS) {
            $count = LJ::MemCache::incr("chaltoken:$chal", 1);
            unless ($count) {
                LJ::MemCache::add("chaltoken:$chal", 1, $goodfor);
                $count = 1;
            }
        } else {
            my $dbh = LJ::get_db_writer();
            my $rv = $dbh->do("SELECT GET_LOCK(?,5)", undef, $chal);
            if ($rv) {
                $count = $dbh->selectrow_array("SELECT count FROM challenges WHERE challenge=?",
                                               undef, $chal);
                if ($count) {
                    $dbh->do("UPDATE challenges SET count=count+1 WHERE challenge=?",
                             undef, $chal);
                    $count++;
                } else {
                    $dbh->do("INSERT INTO challenges SET ctime=?, challenge=?, count=1",
                         undef, $stime + $s_age, $chal);
                    $count = 1;
                }
            }
            $dbh->do("SELECT RELEASE_LOCK(?)", undef, $chal);
        }
        # if we couldn't get the count (means we couldn't store either)
        # , consider it invalid
        $valid = 0 unless $count;
    }

    if ($opts) {
        $opts->{'expired'} = $expired;
        $opts->{'valid'} = $valid;
        $opts->{'count'} = $count;
    }

    return ($valid && !$expired && ($count==1 || $opts->{dont_check_count}));
}


# Validate login/talk md5 responses.
# Return 1 on valid, 0 on invalid.
sub challenge_check_login
{
    my ($u, $chal, $res, $banned, $opts) = @_;
    return 0 unless $u;
    my $pass = $u->{'password'};
    return 0 if $pass eq "";

    # set the IP banned flag, if it was provided.
    my $fake_scalar;
    my $ref = ref $banned ? $banned : \$fake_scalar;
    if (LJ::login_ip_banned($u)) {
        $$ref = 1;
        return 0;
    } else {
        $$ref = 0;
    }

    # check the challenge string validity
    return 0 unless LJ::challenge_check($chal, $opts);

    # Validate password
    my $hashed = Digest::MD5::md5_hex($chal . Digest::MD5::md5_hex($pass));
    if ($hashed eq $res) {
        return 1;
    } else {
        LJ::handle_bad_login($u);
        return 0;
    }
}

# <LJFUNC>
# name: LJ::is_friend
# des: Checks to see if a user is a friend of another user.
# returns: boolean; 1 if user B is a friend of user A or if A == B
# args: usera, userb
# des-usera: Source user hashref or userid.
# des-userb: Destination user hashref or userid. (can be undef)
# </LJFUNC>
sub is_friend
{
    &nodb;

    my ($ua, $ub) = @_[0, 1];

    $ua = LJ::want_userid($ua);
    $ub = LJ::want_userid($ub);

    return 0 unless $ua && $ub;
    return 1 if $ua == $ub;

    # get group mask from the first argument to the second argument and
    # see if first bit is set.  if it is, they're a friend.  get_groupmask
    # is memcached and used often, so it's likely to be available quickly.
    return LJ::get_groupmask(@_[0, 1]) & 1;
}

# <LJFUNC>
# name: LJ::is_banned
# des: Checks to see if a user is banned from a journal.
# returns: boolean; 1 iff "user" is banned from "journal"
# args: user, journal
# des-user: User hashref or userid.
# des-journal: Journal hashref or userid.
# </LJFUNC>
sub is_banned
{
    &nodb;

    # get user and journal ids
    my $uid = LJ::want_userid(shift);
    my $jid = LJ::want_userid(shift);
    return 1 unless $uid && $jid;

    # for speed: common case is non-community posting and replies
    # in own journal.  avoid db hit.
    return 0 if ($uid == $jid);

    # edge from journal -> user
    return LJ::check_rel($jid, $uid, 'B');
}

# <LJFUNC>
# name: LJ::get_remote_noauth
# des: returns who the remote user says they are, but doesn't check
#      their login token.  disadvantage: insecure, only use when
#      you're not doing anything critical.  advantage:  faster.
# returns: hashref containing only key 'user', not 'userid' like
#          [func[LJ::get_remote]].
# </LJFUNC>
sub get_remote_noauth
{
    my $sess = $BML::COOKIE{'ljsession'};
    return { 'user' => $1 } if $sess =~ /^ws:(\w+):/;
    return undef;
}

# <LJFUNC>
# name: LJ::clear_caches
# des: This function is called from a HUP signal handler and is intentionally
#      very very simple (1 line) so we don't core dump on a system without
#      reentrant libraries.  It just sets a flag to clear the caches at the
#      beginning of the next request (see [func[LJ::handle_caches]]).
#      There should be no need to ever call this function directly.
# </LJFUNC>
sub clear_caches
{
    $LJ::CLEAR_CACHES = 1;
}

# <LJFUNC>
# name: LJ::handle_caches
# des: clears caches if the CLEAR_CACHES flag is set from an earlier
#      HUP signal that called [func[LJ::clear_caches]], otherwise
#      does nothing.
# returns: true (always) so you can use it in a conjunction of
#          statements in a while loop around the application like:
#          while (LJ::handle_caches() && FCGI::accept())
# </LJFUNC>
sub handle_caches
{
    return 1 unless $LJ::CLEAR_CACHES;
    $LJ::CLEAR_CACHES = 0;

    do "$ENV{'LJHOME'}/cgi-bin/ljconfig.pl";
    do "$ENV{'LJHOME'}/cgi-bin/ljdefaults.pl";

    $LJ::DBIRole->flush_cache();

    %LJ::CACHE_PROP = ();
    %LJ::CACHE_STYLE = ();
    $LJ::CACHED_MOODS = 0;
    $LJ::CACHED_MOOD_MAX = 0;
    %LJ::CACHE_MOODS = ();
    %LJ::CACHE_MOOD_THEME = ();
    %LJ::CACHE_USERID = ();
    %LJ::CACHE_USERNAME = ();
    %LJ::CACHE_CODES = ();
    %LJ::CACHE_USERPROP = ();  # {$prop}->{ 'upropid' => ... , 'indexed' => 0|1 };
    %LJ::CACHE_ENCODINGS = ();
    return 1;
}

# <LJFUNC>
# name: LJ::start_request
# des: Before a new web request is obtained, this should be called to
#      determine if process should die or keep working, clean caches,
#      reload config files, etc.
# returns: 1 if a new request is to be processed, 0 if process should die.
# </LJFUNC>
sub start_request
{
    handle_caches();
    # TODO: check process growth size

    # clear per-request caches
    LJ::unset_remote();               # clear cached remote
    $LJ::ACTIVE_CRUMB = '';           # clear active crumb
    %LJ::CACHE_USERPIC = ();          # picid -> hashref
    %LJ::CACHE_USERPIC_INFO = ();     # uid -> { ... }
    %LJ::REQ_CACHE_USER_NAME = ();    # users by name
    %LJ::REQ_CACHE_USER_ID = ();      # users by id
    %LJ::REQ_CACHE_REL = ();          # relations from LJ::check_rel()
    %LJ::REQ_CACHE_DIRTY = ();        # caches calls to LJ::mark_dirty()
    %LJ::S1::REQ_CACHE_STYLEMAP = (); # styleid -> uid mappings
    %LJ::REQ_DBIX_TRACKER = ();       # canonical dbrole -> DBIx::StateTracker
    %LJ::REQ_DBIX_KEEPER = ();        # dbrole -> DBIx::StateKeeper
    %LJ::REQ_HEAD_HAS = ();           # avoid code duplication for js

    # we use this to fake out get_remote's perception of what
    # the client's remote IP is, when we transfer cookies between
    # authentication domains.  see the FotoBilder interface.
    $LJ::_XFER_REMOTE_IP = undef;

    # clear the handle request cache (like normal cache, but verified already for
    # this request to be ->ping'able).
    $LJ::DBIRole->clear_req_cache();

    # need to suck db weights down on every request (we check
    # the serial number of last db weight change on every request
    # to validate master db connection, instead of selecting
    # the connection ID... just as fast, but with a point!)
    $LJ::DBIRole->trigger_weight_reload();

    # reset BML's cookies
    eval { BML::reset_cookies() };

    # check the modtime of ljconfig.pl and reload if necessary
    # only do a stat every 10 seconds and then only reload
    # if the file has changed
    my $now = time();
    if ($now - $LJ::CACHE_CONFIG_MODTIME_LASTCHECK > 10) {
        my $modtime = (stat("$ENV{'LJHOME'}/cgi-bin/ljconfig.pl"))[9];
        if ($modtime > $LJ::CACHE_CONFIG_MODTIME) {
            # reload config and update cached modtime
            $LJ::CACHE_CONFIG_MODTIME = $modtime;
            eval {
                do "$ENV{'LJHOME'}/cgi-bin/ljconfig.pl";
                do "$ENV{'LJHOME'}/cgi-bin/ljdefaults.pl";

                # reload MogileFS config
                if (LJ::mogclient()) {
                    LJ::mogclient()->reload
                        ( domain => $LJ::MOGILEFS_CONFIG{domain},
                          root   => $LJ::MOGILEFS_CONFIG{root},
                          hosts  => $LJ::MOGILEFS_CONFIG{hosts}, );
                    LJ::mogclient()->set_pref_ip(\%LJ::MOGILEFS_PREF_IP)
                        if %LJ::MOGILEFS_PREF_IP;
                }
            };
            $LJ::IMGPREFIX_BAK = $LJ::IMGPREFIX;
            $LJ::STATPREFIX_BAK = $LJ::STATPREFIX;
            $LJ::LOCKER_OBJ = undef;
            $LJ::DBIRole->set_sources(\%LJ::DBINFO);
            LJ::MemCache::reload_conf();
            if ($modtime > $now - 60) {
                # show to stderr current reloads.  won't show
                # reloads happening from new apache children
                # forking off the parent who got the inital config loaded
                # hours/days ago and then the "updated" config which is
                # a different hours/days ago.
                #
                # only print when we're in web-context
                print STDERR "ljconfig.pl reloaded\n"
                    if eval { Apache->request };
            }
        }
        $LJ::CACHE_CONFIG_MODTIME_LASTCHECK = $now;
    }

    return 1;
}


# <LJFUNC>
# name: LJ::end_request
# des: Clears cached DB handles/trackers/keepers (if $LJ::DISCONNECT_DBS is
#      true) and disconnects MemCache handles (if $LJ::DISCONNECT_MEMCACHE is
#      true).
# </LJFUNC>
sub end_request
{
    LJ::flush_cleanup_handlers();
    LJ::disconnect_dbs() if $LJ::DISCONNECT_DBS;
    LJ::MemCache::disconnect_all() if $LJ::DISCONNECT_MEMCACHE;
}

# <LJFUNC>
# name: LJ::flush_cleanup_handlers
# des: Runs all cleanup handlers registered in @LJ::CLEANUP_HANDLERS
# </LJFUNC>
sub flush_cleanup_handlers {
    while (my $ref = shift @LJ::CLEANUP_HANDLERS) {
        next unless ref $ref eq 'CODE';
        $ref->();
    }
}

# <LJFUNC>
# name: LJ::disconnect_dbs
# des: Clear cached DB handles and trackers/keepers to partitioned DBs.
# </LJFUNC>
sub disconnect_dbs {
    # clear cached handles
    $LJ::DBIRole->disconnect_all( { except => [qw(logs)] });

    # and cached trackers/keepers to partitioned dbs
    while (my ($role, $tk) = each %LJ::REQ_DBIX_TRACKER) {
        $tk->disconnect if $tk;
    }
    %LJ::REQ_DBIX_TRACKER = ();
    %LJ::REQ_DBIX_KEEPER = ();
}

# <LJFUNC>
# name: LJ::load_userpics
# des: Loads a bunch of userpic at once.
# args: dbarg?, upics, idlist
# des-upics: hashref to load pictures into, keys being the picids
# des-idlist: [$u, $picid] or [[$u, $picid], [$u, $picid], +] objects
# also supports depreciated old method of an array ref of picids
# </LJFUNC>
sub load_userpics
{
    &nodb;
    my ($upics, $idlist) = @_;

    return undef unless ref $idlist eq 'ARRAY' && $idlist->[0];

    # deal with the old calling convention, just an array ref of picids eg. [7, 4, 6, 2]
    if (! ref $idlist->[0] && $idlist->[0]) { # assume we have an old style caller
        my $in = join(',', map { $_+0 } @$idlist);
        my $dbr = LJ::get_db_reader();
        my $sth = $dbr->prepare("SELECT userid, picid, width, height " .
                                "FROM userpic WHERE picid IN ($in)");

        $sth->execute;
        while ($_ = $sth->fetchrow_hashref) {
            my $id = $_->{'picid'};
            undef $_->{'picid'};
            $upics->{$id} = $_;
        }
        return;
    }

    # $idlist needs to be an arrayref of arrayrefs,
    # HOWEVER, there's a special case where it can be
    # an arrayref of 2 items:  $u (which is really an arrayref)
    # as well due to 'fields' and picid which is an integer.
    #
    # [$u, $picid] needs to map to [[$u, $picid]] while allowing
    # [[$u1, $picid1], [$u2, $picid2], [etc...]] to work.
    if (scalar @$idlist == 2 && ! ref $idlist->[1]) {
        $idlist = [ $idlist ];
    }

    my @load_list;
    foreach my $row (@{$idlist})
    {
        my ($u, $id) = @$row;
        next unless ref $u;

        if ($LJ::CACHE_USERPIC{$id}) {
            $upics->{$id} = $LJ::CACHE_USERPIC{$id};
        } elsif ($id+0) {
            push @load_list, [$u, $id+0];
        }
    }
    return unless @load_list;

    if (@LJ::MEMCACHE_SERVERS) {
        my @mem_keys = map { [$_->[1],"userpic.$_->[1]"] } @load_list;
        my $mem = LJ::MemCache::get_multi(@mem_keys) || {};
        while (my ($k, $v) = each %$mem) {
            next unless $v && $k =~ /(\d+)/;
            my $id = $1;
            $upics->{$id} = LJ::MemCache::array_to_hash("userpic", $v);
        }
        @load_list = grep { ! $upics->{$_->[1]} } @load_list;
        return unless @load_list;
    }

    my %db_load;
    my @load_list_d6;
    foreach my $row (@load_list) {
        # ignore users on clusterid 0
        next unless $row->[0]->{clusterid};

        if ($row->[0]->{'dversion'} > 6) {
            push @{$db_load{$row->[0]->{'clusterid'}}}, $row;
        } else {
            push @load_list_d6, $row;
        }
    }

    foreach my $cid (keys %db_load) {
        my $dbcr = LJ::get_cluster_def_reader($cid);
        unless ($dbcr) {
            print STDERR "Error: LJ::load_userpics unable to get handle; cid = $cid\n";
            next;
        }

        my (@bindings, @data);
        foreach my $row (@{$db_load{$cid}}) {
            push @bindings, "(userid=? AND picid=?)";
            push @data, ($row->[0]->{userid}, $row->[1]);
        }
        next unless @data && @bindings;

        my $sth = $dbcr->prepare("SELECT userid, picid, width, height, fmt, state, ".
                                 "       UNIX_TIMESTAMP(picdate) AS 'picdate', location, flags ".
                                 "FROM userpic2 WHERE " . join(' OR ', @bindings));
        $sth->execute(@data);

        while (my $ur = $sth->fetchrow_hashref) {
            my $id = delete $ur->{'picid'};
            $upics->{$id} = $ur;

            # force into numeric context so they'll be smaller in memcache:
            foreach my $k (qw(userid width height flags picdate)) {
                $ur->{$k} += 0;
            }
            $ur->{location} = uc(substr($ur->{location}, 0, 1));

            $LJ::CACHE_USERPIC{$id} = $ur;
            LJ::MemCache::set([$id,"userpic.$id"], LJ::MemCache::hash_to_array("userpic", $ur));
        }
    }

    # following path is only for old style d6 userpics... don't load any if we don't
    # have any to load
    return unless @load_list_d6;

    my $dbr = LJ::get_db_writer();
    my $picid_in = join(',', map { $_->[1] } @load_list_d6);
    my $sth = $dbr->prepare("SELECT userid, picid, width, height, contenttype, state, ".
                            "       UNIX_TIMESTAMP(picdate) AS 'picdate' ".
                            "FROM userpic WHERE picid IN ($picid_in)");
    $sth->execute;
    while (my $ur = $sth->fetchrow_hashref) {
        my $id = delete $ur->{'picid'};
        $upics->{$id} = $ur;

        # force into numeric context so they'll be smaller in memcache:
        foreach my $k (qw(userid width height picdate)) {
            $ur->{$k} += 0;
        }
        $ur->{location} = "?";
        $ur->{flags} = undef;
        $ur->{fmt} = {
            'image/gif' => 'G',
            'image/jpeg' => 'J',
            'image/png' => 'P',
        }->{delete $ur->{contenttype}};

        $LJ::CACHE_USERPIC{$id} = $ur;
        LJ::MemCache::set([$id,"userpic.$id"], LJ::MemCache::hash_to_array("userpic", $ur));
    }
}

# <LJFUNC>
# name: LJ::expunge_userpic
# des: Expunges a userpic so that the system will no longer deliver this userpic.  If
#   your site has off-site caching or something similar, you can also define a hook
#   "expunge_userpic" which will be called with a picid and userid when a pic is
#   expunged.
# args: u, picid
# des-picid: Id of the picture to expunge.
# des-u: User object
# returns: undef on error, or the userid of the picture owner on success.
# </LJFUNC>
sub expunge_userpic {
    # take in a picid and expunge it from the system so that it can no longer be used
    my ($u, $picid) = @_;
    $picid += 0;
    return undef unless $picid && ref $u;

    # get the pic information
    my $state;

    if ($u->{'dversion'} > 6) {
        my $dbcm = LJ::get_cluster_master($u);
        return undef unless $dbcm && $u->writer;

        $state = $dbcm->selectrow_array('SELECT state FROM userpic2 WHERE userid = ? AND picid = ?',
                                        undef, $u->{'userid'}, $picid);

        return $u->{'userid'} if $state eq 'X'; # already expunged

        # else now mark it
        $u->do("UPDATE userpic2 SET state='X' WHERE userid = ? AND picid = ?", undef, $u->{'userid'}, $picid);
        return LJ::error($dbcm) if $dbcm->err;
        $u->do("DELETE FROM userpicmap2 WHERE userid = ? AND picid = ?", undef, $u->{'userid'}, $picid);
    } else {
        my $dbr = LJ::get_db_reader();
        return undef unless $dbr;

        $state = $dbr->selectrow_array('SELECT state FROM userpic WHERE picid = ?',
                                       undef, $picid);

        return $u->{'userid'} if $state eq 'X'; # already expunged

        # else now mark it
        my $dbh = LJ::get_db_writer();
        return undef unless $dbh;
        $dbh->do("UPDATE userpic SET state='X' WHERE picid = ?", undef, $picid);
        return LJ::error($dbh) if $dbh->err;
        $dbh->do("DELETE FROM userpicmap WHERE userid = ? AND picid = ?", undef, $u->{'userid'}, $picid);
    }

    # now clear the user's memcache picture info
    LJ::MemCache::delete([$u->{'userid'}, "upicinf:$u->{'userid'}"]);

    # call the hook and get out of here
    my $rval = LJ::run_hook('expunge_userpic', $picid, $u->{'userid'});
    return ($u->{'userid'}, $rval);
}

# <LJFUNC>
# name: LJ::activate_userpics
# des: Sets/unsets userpics as inactive based on account caps
# args: uuserid
# returns: nothing
# </LJFUNC>
sub activate_userpics
{
    # this behavior is optional, but enabled by default
    return 1 if $LJ::ALLOW_PICS_OVER_QUOTA;

    my $u = shift;
    return undef unless LJ::isu($u);

    # if a userid was given, get a real $u object
    $u = LJ::load_userid($u, "force") unless isu($u);

    # should have a $u object now
    return undef unless isu($u);

    # can't get a cluster read for expunged users since they are clusterid 0,
    # so just return 1 to the caller from here and act like everything went fine
    return 1 if $u->{'statusvis'} eq 'X';

    my $userid = $u->{'userid'};

    # active / inactive lists
    my @active = ();
    my @inactive = ();
    my $allow = LJ::get_cap($u, "userpics");

    # get a database handle for reading/writing
    my $dbh = LJ::get_db_writer();
    my $dbcr = LJ::get_cluster_def_reader($u);

    # select all userpics and build active / inactive lists
    my $sth;
    if ($u->{'dversion'} > 6) {
        return undef unless $dbcr;
        $sth = $dbcr->prepare("SELECT picid, state FROM userpic2 WHERE userid=?");
    } else {
        return undef unless $dbh;
        $sth = $dbh->prepare("SELECT picid, state FROM userpic WHERE userid=?");
    }
    $sth->execute($userid);
    while (my ($picid, $state) = $sth->fetchrow_array) {
        next if $state eq 'X'; # expunged, means userpic has been removed from site by admins
        if ($state eq 'I') {
            push @inactive, $picid;
        } else {
            push @active, $picid;
        }
    }

    # inactivate previously activated userpics
    if (@active > $allow) {
        my $to_ban = @active - $allow;

        # find first jitemid greater than time 2 months ago using rlogtime index
        # ($LJ::EndOfTime - UnixTime)
        my $jitemid = $dbcr->selectrow_array("SELECT jitemid FROM log2 USE INDEX (rlogtime) " .
                                             "WHERE journalid=? AND rlogtime > ? LIMIT 1",
                                             undef, $userid, $LJ::EndOfTime - time() + 86400*60);

        # query all pickws in logprop2 with jitemid > that value
        my %count_kw = ();
        my $propid = LJ::get_prop("log", "picture_keyword")->{'id'};
        my $sth = $dbcr->prepare("SELECT value, COUNT(*) FROM logprop2 " .
                                 "WHERE journalid=? AND jitemid > ? AND propid=?" .
                                 "GROUP BY value");
        $sth->execute($userid, $jitemid, $propid);
        while (my ($value, $ct) = $sth->fetchrow_array) {
            # keyword => count
            $count_kw{$value} = $ct;
        }

        my $keywords_in = join(",", map { $dbh->quote($_) } keys %count_kw);

        # map pickws to picids for freq hash below
        my %count_picid = ();
        if ($keywords_in) {
            my $sth;
            if ($u->{'dversion'} > 6) {
                $sth = $dbcr->prepare("SELECT k.keyword, m.picid FROM userkeywords k, userpicmap2 m ".
                                      "WHERE k.keyword IN ($keywords_in) AND k.kwid=m.kwid AND k.userid=m.userid " .
                                      "AND k.userid=?");
            } else {
                $sth = $dbh->prepare("SELECT k.keyword, m.picid FROM keywords k, userpicmap m " .
                                     "WHERE k.keyword IN ($keywords_in) AND k.kwid=m.kwid " .
                                     "AND m.userid=?");
            }
            $sth->execute($userid);
            while (my ($keyword, $picid) = $sth->fetchrow_array) {
                # keyword => picid
                $count_picid{$picid} += $count_kw{$keyword};
            }
        }

        # we're only going to ban the least used, excluding the user's default
        my @ban = (grep { $_ != $u->{'defaultpicid'} }
                   sort { $count_picid{$a} <=> $count_picid{$b} } @active);

        @ban = splice(@ban, 0, $to_ban) if @ban > $to_ban;
        my $ban_in = join(",", map { $dbh->quote($_) } @ban);
        if ($u->{'dversion'} > 6) {
            $u->do("UPDATE userpic2 SET state='I' WHERE userid=? AND picid IN ($ban_in)",
                   undef, $userid) if $ban_in;
        } else {
            $dbh->do("UPDATE userpic SET state='I' WHERE userid=? AND picid IN ($ban_in)",
                     undef, $userid) if $ban_in;
        }
    }

    # activate previously inactivated userpics
    if (@inactive && @active < $allow) {
        my $to_activate = $allow - @active;
        $to_activate = @inactive if $to_activate > @inactive;

        # take the $to_activate newest (highest numbered) pictures
        # to reactivated
        @inactive = sort @inactive;
        my @activate_picids = splice(@inactive, -$to_activate);

        my $activate_in = join(",", map { $dbh->quote($_) } @activate_picids);
        if ($activate_in) {
            if ($u->{'dversion'} > 6) {
                $u->do("UPDATE userpic2 SET state='N' WHERE userid=? AND picid IN ($activate_in)",
                       undef, $userid);
            } else {
                $dbh->do("UPDATE userpic SET state='N' WHERE userid=? AND picid IN ($activate_in)",
                         undef, $userid);
            }
        }
    }

    # delete userpic info object from memcache
    LJ::MemCache::delete([$userid, "upicinf:$userid"]);

    return 1;
}

# <LJFUNC>
# name: LJ::get_userpic_info
# des: Given a user gets their user picture info
# args: uuid, opts (optional)
# des-u: user object or userid
# des-opts: hash of options, 'load_comments'
# returns: hash of userpicture information
# for efficiency, we store the userpic structures
# in memcache in a packed format.
#
# memory format:
# [
#   version number of format,
#   userid,
#   "packed string", which expands to an array of {width=>..., ...}
#   "packed string", which expands to { 'kw1' => id, 'kw2' => id, ...}
# ]
# </LJFUNC>

sub get_userpic_info
{
    my ($uuid, $opts) = @_;
    return undef unless $uuid;
    my $userid = LJ::want_userid($uuid);
    my $u = LJ::want_user($uuid); # This should almost always be in memory already
    return undef unless $u && $u->{clusterid};

    # in the cache, cool, well unless it doesn't have comments or urls
    # and we need them
    if (my $cachedata = $LJ::CACHE_USERPIC_INFO{$userid}) {
        my $good = 1;
        if ($u->{'dversion'} > 6) {
            $good = 0 if $opts->{'load_comments'} && ! $cachedata->{'_has_comments'};
            $good = 0 if $opts->{'load_urls'} && ! $cachedata->{'_has_urls'};
        }
        return $cachedata if $good;
    }

    my $VERSION_PICINFO = 3;

    my $memkey = [$u->{'userid'},"upicinf:$u->{'userid'}"];
    my ($info, $minfo);

    if ($minfo = LJ::MemCache::get($memkey)) {
        # the pre-versioned memcache data was a two-element hash.
        # since then, we use an array and include a version number.

        if (ref $minfo eq 'HASH' ||
            $minfo->[0] != $VERSION_PICINFO) {
            # old data in the cache.  delete.
            LJ::MemCache::delete($memkey);
        } else {
            my (undef, $picstr, $kwstr) = @$minfo;
            $info = {
                'pic' => {},
                'kw' => {},
            };
            while (length $picstr >= 7) {
                my $pic = { userid => $u->{'userid'} };
                ($pic->{picid},
                 $pic->{width}, $pic->{height},
                 $pic->{state}) = unpack "NCCA", substr($picstr, 0, 7, '');
                $info->{pic}->{$pic->{picid}} = $pic;
            }

            my ($pos, $nulpos);
            $pos = $nulpos = 0;
            while (($nulpos = index($kwstr, "\0", $pos)) > 0) {
                my $kw = substr($kwstr, $pos, $nulpos-$pos);
                my $id = unpack("N", substr($kwstr, $nulpos+1, 4));
                $pos = $nulpos + 5; # skip NUL + 4 bytes.
                $info->{kw}->{$kw} = $info->{pic}->{$id} if $info;
            }
        }

        if ($u->{'dversion'} > 6) {

            # Load picture comments
            if ($opts->{'load_comments'}) {
                my $commemkey = [$u->{'userid'}, "upiccom:$u->{'userid'}"];
                my $comminfo = LJ::MemCache::get($commemkey);

                if ($comminfo) {
                    my ($pos, $nulpos);
                    $pos = $nulpos = 0;
                    while (($nulpos = index($comminfo, "\0", $pos)) > 0) {
                        my $comment = substr($comminfo, $pos, $nulpos-$pos);
                        my $id = unpack("N", substr($comminfo, $nulpos+1, 4));
                        $pos = $nulpos + 5; # skip NUL + 4 bytes.
                        $info->{'pic'}->{$id}->{'comment'} = $comment;
                    }
                    $info->{'_has_comments'} = 1;
                } else { # Requested to load comments, but they aren't in memcache
                         # so force a db load
                    undef $info;
                }
            }

            # Load picture urls
            if ($opts->{'load_urls'} && $info) {
                my $urlmemkey = [$u->{'userid'}, "upicurl:$u->{'userid'}"];
                my $urlinfo = LJ::MemCache::get($urlmemkey);

                if ($urlinfo) {
                    my ($pos, $nulpos);
                    $pos = $nulpos = 0;
                    while (($nulpos = index($urlinfo, "\0", $pos)) > 0) {
                        my $url = substr($urlinfo, $pos, $nulpos-$pos);
                        my $id = unpack("N", substr($urlinfo, $nulpos+1, 4));
                        $pos = $nulpos + 5; # skip NUL + 4 bytes.
                        $info->{'pic'}->{$id}->{'url'} = $url;
                    }
                    $info->{'_has_urls'} = 1;
                } else { # Requested to load urls, but they aren't in memcache
                         # so force a db load
                    undef $info;
                }
            }
        }
    }

    my %minfocom; # need this in this scope
    my %minfourl;
    unless ($info) {
        $info = {
            'pic' => {},
            'kw' => {},
        };
        my ($picstr, $kwstr);
        my $sth;
        my $dbcr = LJ::get_cluster_def_reader($u);
        my $db = @LJ::MEMCACHE_SERVERS ? LJ::get_db_writer() : LJ::get_db_reader();
        return undef unless $dbcr && $db;

        if ($u->{'dversion'} > 6) {
            $sth = $dbcr->prepare("SELECT picid, width, height, state, userid, comment, url ".
                                  "FROM userpic2 WHERE userid=?");
        } else {
            $sth = $db->prepare("SELECT picid, width, height, state, userid ".
                                "FROM userpic WHERE userid=?");
        }
        $sth->execute($u->{'userid'});
        my @pics;
        while (my $pic = $sth->fetchrow_hashref) {
            next if $pic->{state} eq 'X'; # no expunged pics in list
            push @pics, $pic;
            $info->{'pic'}->{$pic->{'picid'}} = $pic;
            $minfocom{int($pic->{picid})} = $pic->{comment} if $u->{'dversion'} > 6
                && $opts->{'load_comments'} && $pic->{'comment'};
            $minfourl{int($pic->{'picid'})} = $pic->{'url'} if $u->{'dversion'} > 6
                && $opts->{'load_urls'} && $pic->{'url'};
        }


        $picstr = join('', map { pack("NCCA", $_->{picid},
                                 $_->{width}, $_->{height}, $_->{state}) } @pics);

        if ($u->{'dversion'} > 6) {
            $sth = $dbcr->prepare("SELECT k.keyword, m.picid FROM userpicmap2 m, userkeywords k ".
                                  "WHERE k.userid=? AND m.kwid=k.kwid AND m.userid=k.userid");
        } else {
            $sth = $db->prepare("SELECT k.keyword, m.picid FROM userpicmap m, keywords k ".
                                "WHERE m.userid=? AND m.kwid=k.kwid");
        }
        $sth->execute($u->{'userid'});
        my %minfokw;
        while (my ($kw, $id) = $sth->fetchrow_array) {
            next unless $info->{'pic'}->{$id};
            next if $kw =~ /[\n\r\0]/;  # used to be a bug that allowed these to get in.
            $info->{'kw'}->{$kw} = $info->{'pic'}->{$id};
            $minfokw{$kw} = int($id);
        }
        $kwstr = join('', map { pack("Z*N", $_, $minfokw{$_}) } keys %minfokw);

        $memkey = [$u->{'userid'},"upicinf:$u->{'userid'}"];
        $minfo = [ $VERSION_PICINFO, $picstr, $kwstr ];
        LJ::MemCache::set($memkey, $minfo);

        if ($u->{'dversion'} > 6) {

            if ($opts->{'load_comments'}) {
                $info->{'comment'} = \%minfocom;
                my $commentstr = join('', map { pack("Z*N", $minfocom{$_}, $_) } keys %minfocom);

                my $memkey = [$u->{'userid'}, "upiccom:$u->{'userid'}"];
                LJ::MemCache::set($memkey, $commentstr);

                $info->{'_has_comments'} = 1;
            }

            if ($opts->{'load_urls'}) {
                my $urlstr = join('', map { pack("Z*N", $minfourl{$_}, $_) } keys %minfourl);

                my $memkey = [$u->{'userid'}, "upicurl:$u->{'userid'}"];
                LJ::MemCache::set($memkey, $urlstr);

                $info->{'_has_urls'} = 1;
            }
        }
    }

    $LJ::CACHE_USERPIC_INFO{$u->{'userid'}} = $info;
    return $info;
}

# <LJFUNC>
# name: LJ::get_pic_from_keyword
# des: Given a userid and keyword, returns the pic row hashref
# args: u, keyword
# des-keyword: The keyword of the userpic to fetch
# returns: hashref of pic row found
# </LJFUNC>
sub get_pic_from_keyword
{
    my ($u, $kw) = @_;
    my $info = LJ::get_userpic_info($u);
    return undef unless $info;
    return $info->{'kw'}{$kw};
}

sub get_picid_from_keyword
{
    my ($u, $kw, $default) = @_;
    $default ||= (ref $u ? $u->{'defaultpicid'} : 0);
    return $default unless $kw;
    my $info = LJ::get_userpic_info($u);
    return $default unless $info;
    my $pr = $info->{'kw'}{$kw};
    return $pr ? $pr->{'picid'} : $default;
}

# <LJFUNC>
# name: LJ::server_down_html
# des: Returns an HTML server down message.
# returns: A string with a server down message in HTML.
# </LJFUNC>
sub server_down_html
{
    return "<b>$LJ::SERVER_DOWN_SUBJECT</b><br />$LJ::SERVER_DOWN_MESSAGE";
}

sub get_db_reader {
    return LJ::get_dbh("slave", "master");
}

sub get_db_writer {
    return LJ::get_dbh("master");
}

# <LJFUNC>
# name: LJ::get_cluster_reader
# class: db
# des: Returns a cluster slave for a user, or cluster master if no slaves exist.
# args: uarg
# des-uarg: Either a userid scalar or a user object.
# returns: DB handle.  Or undef if all dbs are unavailable.
# </LJFUNC>
sub get_cluster_reader
{
    my $arg = shift;
    my $id = isu($arg) ? $arg->{'clusterid'} : $arg;
    my @roles = ("cluster${id}slave", "cluster${id}");
    if (my $ab = $LJ::CLUSTER_PAIR_ACTIVE{$id}) {
        $ab = lc($ab);
        # master-master cluster
        @roles = ("cluster${id}${ab}") if $ab eq "a" || $ab eq "b";
    }
    return LJ::get_dbh(@roles);
}

# <LJFUNC>
# name: LJ::get_cluster_def_reader
# class: db
# des: Returns a definitive cluster reader for a given user, used
#      when the caller wants the master handle, but will only
#      use it to read.
# args: uarg
# des-uarg: Either a clusterid scalar or a user object.
# returns: DB handle.  Or undef if definitive reader is unavailable.
# </LJFUNC>
sub get_cluster_def_reader
{
    my @dbh_opts = scalar(@_) == 2 ? (shift @_) : ();
    my $arg = shift;
    my $id = isu($arg) ? $arg->{'clusterid'} : $arg;
    return LJ::get_cluster_reader(@dbh_opts, $id) if
        $LJ::DEF_READER_ACTUALLY_SLAVE{$id};
    return LJ::get_dbh(@dbh_opts, LJ::master_role($id));
}

# <LJFUNC>
# name: LJ::get_cluster_master
# class: db
# des: Returns a cluster master for a given user, used when the caller
#      might use it to do a write (insert/delete/update/etc...)
# args: uarg
# des-uarg: Either a clusterid scalar or a user object.
# returns: DB handle.  Or undef if master is unavailable.
# </LJFUNC>
sub get_cluster_master
{
    my @dbh_opts = scalar(@_) == 2 ? (shift @_) : ();
    print(@dbh_opts);
    my $arg = shift;
    my $id = isu($arg) ? $arg->{'clusterid'} : $arg;
    return undef if $LJ::READONLY_CLUSTER{$id};
    return LJ::get_dbh(@dbh_opts, LJ::master_role($id));
}

# returns the DBI::Role role name of a cluster master given a clusterid
sub master_role {
    my $id = shift;
    my $role = "cluster${id}";
    if (my $ab = $LJ::CLUSTER_PAIR_ACTIVE{$id}) {
        $ab = lc($ab);
        # master-master cluster
        $role = "cluster${id}${ab}" if $ab eq "a" || $ab eq "b";
    }
    return $role;
}

# <LJFUNC>
# name: LJ::make_graphviz_dot_file
# class:
# des:
# info:
# args:
# des-:
# returns:
# </LJFUNC>
sub make_graphviz_dot_file
{
    &nodb;
    my $user = shift;

    # the code below is inefficient.  let sites disable it.
    return if $LJ::DISABLED{'graphviz_dot'};

    my $dbr = LJ::get_db_reader();

    my $quser = $dbr->quote($user);
    my $sth;
    my $ret;

    my $u = LJ::load_user($user);
    return unless $u;

    $ret .= "digraph G {\n";
    $ret .= "  node [URL=\"$LJ::SITEROOT/userinfo.bml?user=\\N\"]\n";
    $ret .= "  node [fontsize=10, color=lightgray, style=filled]\n";
    $ret .= "  \"$user\" [color=yellow, style=filled]\n";

    # TAG:FR:ljlib:make_graphviz_dot_file1
    my @friends = ();
    $sth = $dbr->prepare("SELECT friendid FROM friends WHERE userid=$u->{'userid'} AND userid<>friendid");
    $sth->execute;
    while ($_ = $sth->fetchrow_hashref) {
        push @friends, $_->{'friendid'};
    }

    # TAG:FR:ljlib:make_graphviz_dot_file2
    my $friendsin = join(", ", map { $dbr->quote($_); } ($u->{'userid'}, @friends));
    my $sql = "SELECT uu.user, uf.user AS 'friend' FROM friends f, user uu, user uf WHERE f.userid=uu.userid AND f.friendid=uf.userid AND f.userid<>f.friendid AND uu.statusvis='V' AND uf.statusvis='V' AND (f.friendid=$u->{'userid'} OR (f.userid IN ($friendsin) AND f.friendid IN ($friendsin)))";
    $sth = $dbr->prepare($sql);
    $sth->execute;
    while ($_ = $sth->fetchrow_hashref) {
        $ret .= "  \"$_->{'user'}\"->\"$_->{'friend'}\"\n";
    }

    $ret .= "}\n";

    return $ret;
}

# <LJFUNC>
# name: LJ::make_remote
# des: Returns a minimal user structure ($remote-like) from
#      a username and userid.
# args: user, userid
# des-user: Username.
# des-userid: User ID.
# returns: hashref with 'user' and 'userid' keys, or undef if
#          either argument was bogus (so caller can pass
#          untrusted input)
# </LJFUNC>
sub make_remote
{
    my $user = LJ::canonical_username(shift);
    my $userid = shift;
    if ($user && $userid && $userid =~ /^\d+$/) {
        return { 'user' => $user,
                 'userid' => $userid, };
    }
    return undef;
}

# <LJFUNC>
# name: LJ::get_cluster_description
# des: Get descriptive text for a cluster id.
# args: clusterid, bold?
# des-clusterid: id of cluster to get description of
# des-bold: 1 == bold cluster name and subcluster id, else don't
# returns: string representing the cluster description
# </LJFUNC>
sub get_cluster_description {
    my ($cid, $dobold) = @_;
    $cid += 0;
    my $text = LJ::run_hook('cluster_description', $cid, $dobold ? 1 : 0);
    return $text if $text;

    # default behavior just returns clusterid
    return $cid;
}

# <LJFUNC>
# name: LJ::load_moods
# class:
# des:
# info:
# args:
# des-:
# returns:
# </LJFUNC>
sub load_moods
{
    return if $LJ::CACHED_MOODS;
    my $dbr = LJ::get_db_reader();
    my $sth = $dbr->prepare("SELECT moodid, mood, parentmood FROM moods");
    $sth->execute;
    while (my ($id, $mood, $parent) = $sth->fetchrow_array) {
        $LJ::CACHE_MOODS{$id} = { 'name' => $mood, 'parent' => $parent, 'id' => $id };
        if ($id > $LJ::CACHED_MOOD_MAX) { $LJ::CACHED_MOOD_MAX = $id; }
    }
    $LJ::CACHED_MOODS = 1;
}

# <LJFUNC>
# name: LJ::do_to_cluster
# des: Given a subref, this function will pick a random cluster and run the subref,
#   passing it the cluster id.  If the subref returns a 1, this function will exit
#   with a 1.  Else, the function will call the subref again, with the next cluster.
# args: subref
# des-subref: Reference to a sub to call; @_ = (clusterid)
# returns: 1 if the subref returned a 1 at some point, undef if it didn't ever return
#   success and we tried every cluster.
# </LJFUNC>
sub do_to_cluster {
    my $subref = shift;

    # start at some random point and iterate through the clusters one by one until
    # $subref returns a true value
    my $size = @LJ::CLUSTERS;
    my $start = int(rand() * $size);
    my $rval = undef;
    my $tries = $size > 15 ? 15 : $size;
    foreach (1..$tries) {
        # select at random
        my $idx = $start++ % $size;

        # get subref value
        $rval = $subref->($LJ::CLUSTERS[$idx]);
        last if $rval;
    }

    # return last rval
    return $rval;
}

# <LJFUNC>
# name: LJ::cmd_buffer_add
# des: Schedules some command to be run sometime in the future which would
#      be too slow to do syncronously with the web request.  An example
#      is deleting a journal entry, which requires recursing through a lot
#      of tables and deleting all the appropriate stuff.
# args: db, journalid, cmd, hargs
# des-db: Global db handle to run command on, or user clusterid if cluster
# des-journalid: Journal id command affects.  This is indexed in the
#                [dbtable[cmdbuffer]] table so that all of a user's queued
#                actions can be run before that user is potentially moved
#                between clusters.
# des-cmd: Text of the command name.  30 chars max.
# des-hargs: Hashref of command arguments.
# </LJFUNC>
sub cmd_buffer_add
{
    my ($db, $journalid, $cmd, $args) = @_;

    return 0 unless $cmd;

    my $cid = ref $db ? 0 : $db+0;
    $db = $cid ? LJ::get_cluster_master($cid) : $db;
    my $ab = $LJ::CLUSTER_PAIR_ACTIVE{$cid};

    return 0 unless $db;

    my $arg_str = "";
    if (ref $args eq 'HASH') {
        foreach (sort keys %$args) {
            $arg_str .= LJ::eurl($_) . "=" . LJ::eurl($args->{$_}) . "&";
        }
        chop $arg_str;
    } else {
        $arg_str = $args || "";
    }

    my $rv;
    if ($ab && ($ab eq 'a' || $ab eq 'b')) {
        # get a lock
        my $locked = $db->selectrow_array("SELECT GET_LOCK('cmd-buffer-$cid',10)");
        return 0 unless $locked; # 10 second timeout elapsed

        # a or b -- a goes odd, b goes even!
        my $max = $db->selectrow_array('SELECT MAX(cbid) FROM cmdbuffer');
        $max += $ab eq 'a' ? ($max & 1 ? 2 : 1) : ($max & 1 ? 1 : 2);

        # insert command
        $db->do('INSERT INTO cmdbuffer (cbid, journalid, instime, cmd, args) ' .
                'VALUES (?, ?, NOW(), ?, ?)', undef,
                $max, $journalid, $cmd, $arg_str);
        $rv = $db->err ? 0 : 1;

        # release lock
        $db->selectrow_array("SELECT RELEASE_LOCK('cmd-buffer-$cid')");
    } else {
        # old method
        $db->do("INSERT INTO cmdbuffer (journalid, cmd, instime, args) ".
                "VALUES (?, ?, NOW(), ?)", undef,
                $journalid, $cmd, $arg_str);
        $rv = $db->err ? 0 : 1;
    }

    return $rv;
}

# <LJFUNC>
# name: LJ::mysql_time
# des:
# class: time
# info:
# args:
# des-:
# returns:
# </LJFUNC>
sub mysql_time
{
    my ($time, $gmt) = @_;
    $time ||= time();
    my @ltime = $gmt ? gmtime($time) : localtime($time);
    return sprintf("%04d-%02d-%02d %02d:%02d:%02d",
                   $ltime[5]+1900,
                   $ltime[4]+1,
                   $ltime[3],
                   $ltime[2],
                   $ltime[1],
                   $ltime[0]);
}

# gets date in MySQL format, produces s2dateformat
# s1 dateformat is:
# "%a %W %b %M %y %Y %c %m %e %d %D %p %i %l %h %k %H"
# sample string:
# Tue Tuesday Sep September 03 2003 9 09 30 30 30th AM 22 9 09 9 09
# Thu Thursday Oct October 03 2003 10 10 2 02 2nd AM 33 9 09 9 09

sub alldatepart_s1
{
    my $time = shift;
    my ($sec,$min,$hour,$mday,$mon,$year,$wday) =
        gmtime(LJ::mysqldate_to_time($time, 1));
    my $ret = "";

    $ret .= LJ::Lang::day_short($wday+1) . " " .
      LJ::Lang::day_long($wday+1) . " " .
      LJ::Lang::month_short($mon+1) . " " .
      LJ::Lang::month_long($mon+1) . " " .
      sprintf("%02d %04d %d %02d %d %02d %d%s ",
              $year % 100, $year + 1900, $mon+1, $mon+1,
              $mday, $mday, $mday, LJ::Lang::day_ord($mday));
    $ret .= $hour < 12 ? "AM " : "PM ";
    $ret .= sprintf("%02d %d %02d %d %02d", $min,
                    ($hour+11)%12 + 1,
                    ($hour+ 11)%12 +1,
                    $hour,
                    $hour);

    return $ret;
}


# gets date in MySQL format, produces s2dateformat
# s2 dateformat is: yyyy mm dd hh mm ss day_of_week
sub alldatepart_s2
{
    my $time = shift;
    my ($sec,$min,$hour,$mday,$mon,$year,$wday) =
        gmtime(LJ::mysqldate_to_time($time, 1));
    return
        sprintf("%04d %02d %02d %02d %02d %02d %01d",
                $year+1900,
                $mon+1,
                $mday,
                $hour,
                $min,
                $sec,
                $wday);
}


# <LJFUNC>
# name: LJ::get_keyword_id
# class:
# des: Get the id for a keyword.
# args: uuid?, keyword, autovivify?
# des-uuid: User object or userid to use.  Pass this only if you want to use the userkeywords
#   clustered table!  If you do not pass user information, the keywords table on the global
#   will be used.
# des-keyword: A string keyword to get the id of.
# returns: Returns a kwid into keywords or userkeywords, depending on if you passed a user or
#   not.  If the keyword doesn't exist, it is automatically created for you.
# des-autovivify: If present and 1, automatically create keyword.  If present and 0, do not
#   automatically create the keyword.  If not present, default behavior is the old style --
#   yes, do automatically create the keyword.
# </LJFUNC>
sub get_keyword_id
{
    &nodb;

    # see if we got a user? if so we use userkeywords on a cluster
    my $u;
    if (@_ >= 2) {
        $u = LJ::want_user(shift);
        return undef unless $u;
    }

    my ($kw, $autovivify) = @_;
    $autovivify = 1 unless defined $autovivify;

    # setup the keyword for use
    unless ($kw =~ /\S/) { return 0; }
    $kw = LJ::text_trim($kw, LJ::BMAX_KEYWORD, LJ::CMAX_KEYWORD);

    # get the keyword and insert it if necessary
    my $kwid;
    if ($u && $u->{dversion} > 5) {
        # new style userkeywords -- but only if the user has the right dversion
        $kwid = $u->selectrow_array('SELECT kwid FROM userkeywords WHERE userid = ? AND keyword = ?',
                                    undef, $u->{userid}, $kw);
        $kwid = 0 unless defined($kwid);
        if ($autovivify && ! $kwid) {
            # create a new keyword
            $kwid = LJ::alloc_user_counter($u, 'K');
            return undef unless $kwid;

            # attempt to insert the keyword
            my $rv = $u->do("INSERT IGNORE INTO userkeywords (userid, kwid, keyword) VALUES (?, ?, ?)",
                            undef, $u->{userid}, $kwid, $kw) + 0;
            return undef if $u->err;

            # at this point, if $rv is 0, the keyword is already there so try again
            unless ($rv) {
                $kwid = $u->selectrow_array('SELECT kwid FROM userkeywords WHERE userid = ? AND keyword = ?',
                                            undef, $u->{userid}, $kw) + 0;
            }
        }
    } else {
        # old style global
        my $dbh = LJ::get_db_writer();
        my $qkw = $dbh->quote($kw);

        # Making this a $dbr could cause problems due to the insertion of
        # data based on the results of this query. Leave as a $dbh.
        $kwid = $dbh->selectrow_array("SELECT kwid FROM keywords WHERE keyword=$qkw");
        if ($autovivify && ! $kwid) {
            $dbh->do("INSERT INTO keywords (kwid, keyword) VALUES (NULL, $qkw)");
            $kwid = $dbh->{'mysql_insertid'};
        }
    }
    return $kwid;
}

# <LJFUNC>
# name: LJ::delete_user
# class:
# des:
# info:
# args:
# des-:
# returns:
# </LJFUNC>
sub delete_user
{
                # TODO: Is this function even being called?
                # It doesn't look like it does anything useful
    my $dbh = shift;
    my $user = shift;
    my $quser = $dbh->quote($user);
    my $sth;
    $sth = $dbh->prepare("SELECT user, userid FROM useridmap WHERE user=$quser");
    my $u = $sth->fetchrow_hashref;
    unless ($u) { return; }

    ### so many issues.
}

# <LJFUNC>
# name: LJ::hash_password
# class:
# des:
# info:
# args:
# des-:
# returns:
# </LJFUNC>
sub hash_password
{
    return Digest::MD5::md5_hex($_[0]);
}

# <LJFUNC>
# name: LJ::can_use_journal
# class:
# des:
# info:
# args:
# des-:
# returns:
# </LJFUNC>
sub can_use_journal
{
    &nodb;
    my ($posterid, $reqownername, $res) = @_;

    ## find the journal owner's info
    my $uowner = LJ::load_user($reqownername);
    unless ($uowner) {
        $res->{'errmsg'} = "Journal \"$reqownername\" does not exist.";
        return 0;
    }
    my $ownerid = $uowner->{'userid'};

    # the 'ownerid' necessity came first, way back when.  but then
    # with clusters, everything needed to know more, like the
    # journal's dversion and clusterid, so now it also returns the
    # user row.
    $res->{'ownerid'} = $ownerid;
    $res->{'u_owner'} = $uowner;

    ## check if user has access
    return 1 if LJ::check_rel($ownerid, $posterid, 'P');

    # let's check if this community is allowing post access to non-members
    LJ::load_user_props($uowner, "nonmember_posting");
    if ($uowner->{'nonmember_posting'}) {
        my $dbr = LJ::get_db_reader() or die "nodb";
        my $postlevel = $dbr->selectrow_array("SELECT postlevel FROM ".
                                              "community WHERE userid=$ownerid");
        return 1 if $postlevel eq 'members';
    }

    # is the poster an admin for this community?
    return 1 if LJ::can_manage($posterid, $uowner);

    $res->{'errmsg'} = "You do not have access to post to this journal.";
    return 0;
}

# <LJFUNC>
# name: LJ::days_in_month
# class: time
# des: Figures out the number of days in a month.
# args: month, year?
# des-month: Month
# des-year: Year.  Necessary for February.  If undefined or zero, function
#           will return 29.
# returns: Number of days in that month in that year.
# </LJFUNC>
sub days_in_month
{
    my ($month, $year) = @_;
    if ($month == 2)
    {
        return 29 unless $year;  # assume largest
        if ($year % 4 == 0)
        {
          # years divisible by 400 are leap years
          return 29 if ($year % 400 == 0);

          # if they're divisible by 100, they aren't.
          return 28 if ($year % 100 == 0);

          # otherwise, if divisible by 4, they are.
          return 29;
        }
    }
    return ((31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31)[$month-1]);
}

sub day_of_week
{
    my ($year, $month, $day) = @_;
    my $time = Time::Local::timelocal(0,0,0,$day,$month-1,$year);
    return (localtime($time))[6];
}

# <LJFUNC>
# name: LJ::blocking_report
# des: Log a report on the total amount of time used in a slow operation to a
#      remote host via UDP.
# args: host, time, notes, type
# des-host: The DB host the operation used.
# des-type: The type of service the operation was talking to (e.g., 'database',
#           'memcache', etc.)
# des-time: The amount of time (in floating-point seconds) the operation took.
# des-notes: A short description of the operation.
# </LJFUNC>
sub blocking_report {
    my ( $host, $type, $time, $notes ) = @_;

    if ( $LJ::DB_LOG_HOST ) {
        unless ( $LJ::ReportSock ) {
            my ( $host, $port ) = split /:/, $LJ::DB_LOG_HOST, 2;
            return unless $host && $port;

            $LJ::ReportSock = new IO::Socket::INET (
                PeerPort => $port,
                Proto    => 'udp',
                PeerAddr => $host
               ) or return;
        }

        my $msg = join( "\x3", $host, $type, $time, $notes );
        $LJ::ReportSock->send( $msg );
    }
}

# <LJFUNC>
# name: LJ::color_fromdb
# des: Takes a value of unknown type from the db and returns an #rrggbb string.
# args: color
# des-color: either a 24-bit decimal number, or an #rrggbb string.
# returns: scalar; #rrggbb string, or undef if unknown input format
# </LJFUNC>
sub color_fromdb
{
    my $c = shift;
    return $c if $c =~ /^\#[0-9a-f]{6,6}$/i;
    return sprintf("\#%06x", $c) if $c =~ /^\d+$/;
    return undef;
}

# <LJFUNC>
# name: LJ::color_todb
# des: Takes an #rrggbb value and returns a 24-bit decimal number.
# args: color
# des-color: scalar; an #rrggbb string.
# returns: undef if bogus color, else scalar; 24-bit decimal number, can be up to 8 chars wide as a string.
# </LJFUNC>
sub color_todb
{
    my $c = shift;
    return undef unless $c =~ /^\#[0-9a-f]{6,6}$/i;
    return hex(substr($c, 1, 6));
}

# <LJFUNC>
# name: LJ::event_register
# des: Logs a subscribable event, if anybody's subscribed to it.
# args: dbarg?, dbc, etype, ejid, eiarg, duserid, diarg
# des-dbc: Cluster master of event
# des-type: One character event type.
# des-ejid: Journalid event occurred in.
# des-eiarg: 4 byte numeric argument
# des-duserid: Event doer's userid
# des-diarg: Event's 4 byte numeric argument
# returns: boolean; 1 on success; 0 on fail.
# </LJFUNC>
sub event_register
{
    &nodb;
    my ($dbc, $etype, $ejid, $eiarg, $duserid, $diarg) = @_;
    my $dbr = LJ::get_db_reader();

    # see if any subscribers first of all (reads cheap; writes slow)
    return 0 unless $dbr;
    my $qetype = $dbr->quote($etype);
    my $qejid = $ejid+0;
    my $qeiarg = $eiarg+0;
    my $qduserid = $duserid+0;
    my $qdiarg = $diarg+0;

    my $has_sub = $dbr->selectrow_array("SELECT userid FROM subs WHERE etype=$qetype AND ".
                                        "ejournalid=$qejid AND eiarg=$qeiarg LIMIT 1");
    return 1 unless $has_sub;

    # so we're going to need to log this event
    return 0 unless $dbc;
    $dbc->do("INSERT INTO events (evtime, etype, ejournalid, eiarg, duserid, diarg) ".
             "VALUES (NOW(), $qetype, $qejid, $qeiarg, $qduserid, $qdiarg)");
    return $dbc->err ? 0 : 1;
}

# <LJFUNC>
# name: LJ::procnotify_add
# des: Sends a message to all other processes on all clusters.
# info: You'll probably never use this yourself.
# args: cmd, args?
# des-cmd: Command name.  Currently recognized: "DBI::Role::reload" and "rename_user"
# des-args: Hashref with key/value arguments for the given command.  See
#           relevant parts of [func[LJ::procnotify_callback]] for required args for different commands.
# returns: new serial number on success; 0 on fail.
# </LJFUNC>
sub procnotify_add
{
    &nodb;
    my ($cmd, $argref) = @_;
    my $dbh = LJ::get_db_writer();
    return 0 unless $dbh;

    my $args = join('&', map { LJ::eurl($_) . "=" . LJ::eurl($argref->{$_}) }
                    sort keys %$argref);
    $dbh->do("INSERT INTO procnotify (cmd, args) VALUES (?,?)",
             undef, $cmd, $args);

    return 0 if $dbh->err;
    return $dbh->{'mysql_insertid'};
}

# <LJFUNC>
# name: LJ::procnotify_callback
# des: Call back function process notifications.
# info: You'll probably never use this yourself.
# args: cmd, argstring
# des-cmd: Command name.
# des-argstring: String of arguments.
# returns: new serial number on success; 0 on fail.
# </LJFUNC>
sub procnotify_callback
{
    my ($cmd, $argstring) = @_;
    my $arg = {};
    LJ::decode_url_string($argstring, $arg);

    if ($cmd eq "rename_user") {
        # this looks backwards, but the cache hash names are just odd:
        delete $LJ::CACHE_USERNAME{$arg->{'userid'}};
        delete $LJ::CACHE_USERID{$arg->{'user'}};
        return;
    }

    # ip bans
    if ($cmd eq "ban_ip") {
        $LJ::IP_BANNED{$arg->{'ip'}} = $arg->{'exptime'};
        return;
    }

    if ($cmd eq "unban_ip") {
        delete $LJ::IP_BANNED{$arg->{'ip'}};
        return;
    }

    # uniq key bans
    if ($cmd eq "ban_uniq") {
        $LJ::UNIQ_BANNED{$arg->{'uniq'}} = $arg->{'exptime'};
        return;
    }

    if ($cmd eq "unban_uniq") {
        delete $LJ::UNIQ_BANNED{$arg->{'uniq'}};
        return;
    }
}

sub procnotify_check
{
    my $now = time;
    return if $LJ::CACHE_PROCNOTIFY_CHECK + 30 > $now;
    $LJ::CACHE_PROCNOTIFY_CHECK = $now;

    my $dbr = LJ::get_db_reader();
    if (!$dbr) {
      warn("procnotify_check: can't get database reader");
      return;
    }
    my $max = $dbr->selectrow_array("SELECT MAX(nid) FROM procnotify");
    return unless defined $max;
    my $old = $LJ::CACHE_PROCNOTIFY_MAX;
    if (defined $old && $max > $old) {
        my $sth = $dbr->prepare("SELECT cmd, args FROM procnotify ".
                                "WHERE nid > ? AND nid <= $max ORDER BY nid");
        $sth->execute($old);
        while (my ($cmd, $args) = $sth->fetchrow_array) {
            LJ::procnotify_callback($cmd, $args);
        }
    }
    $LJ::CACHE_PROCNOTIFY_MAX = $max;
}

sub dbtime_callback {
    my ($dsn, $dbtime, $time) = @_;
    my $diff = abs($dbtime - $time);
    if ($diff > 2) {
        $dsn =~ /host=([^:\;\|]*)/;
        my $db = $1;
        print STDERR "Clock skew of $diff seconds between web($LJ::SERVER_NAME) and db($db)\n";
    }
}

# We're not always running under mod_perl... sometimes scripts (syndication sucker)
# call paths which end up thinking they need the remote IP, but don't.
sub get_remote_ip
{
  my $ip;
  eval {
    $ip = Apache->request->connection->remote_ip;
    my $ip2 = Apache->request->header_in("X-Forwarded-For");
    
    $ip = LJ::get_real_remote_ip($ip, $ip2);
  };
  return $ip || $ENV{'FAKE_IP'};
}

sub md5_struct
{
    my ($st, $md5) = @_;
    $md5 ||= Digest::MD5->new;
    unless (ref $st) {
        # later Digest::MD5s die while trying to
        # get at the bytes of an invalid utf-8 string.
        # this really shouldn't come up, but when it
        # does, we clear the utf8 flag on the string and retry.
        # see http://zilla.livejournal.org/show_bug.cgi?id=851
        eval { $md5->add($st); };
        if ($@) {
            $st = pack('C*', unpack('C*', $st));
            $md5->add($st);
        }
        return $md5;
    }
    if (ref $st eq "HASH") {
        foreach (sort keys %$st) {
            md5_struct($_, $md5);
            md5_struct($st->{$_}, $md5);
        }
        return $md5;
    }
    if (ref $st eq "ARRAY") {
        foreach (@$st) {
            md5_struct($_, $md5);
        }
        return $md5;
    }
}

sub rand_chars
{
    my $length = shift;
    my $chal = "";
    my $digits = "abcdefghijklmnopqrstuvwzyzABCDEFGHIJKLMNOPQRSTUVWZYZ0123456789";
    for (1..$length) {
        $chal .= substr($digits, int(rand(62)), 1);
    }
    return $chal;
}

# ($time, $secret) = LJ::get_secret();       # will generate
# $secret          = LJ::get_secret($time);  # won't generate
# ($time, $secret) = LJ::get_secret($time);  # will generate (in wantarray)
sub get_secret
{
    my $time = int($_[0]);
    return undef if $_[0] && ! $time;
    my $want_new = ! $time || wantarray;

    if (! $time) {
        $time = time();
        $time -= $time % 3600;  # one hour granularity
    }

    my $memkey = "secret:$time";
    my $secret = LJ::MemCache::get($memkey);
    return $want_new ? ($time, $secret) : $secret if $secret;

    my $dbh = LJ::get_db_writer();
    return undef unless $dbh;
    $secret = $dbh->selectrow_array("SELECT secret FROM secrets ".
                                    "WHERE stime=?", undef, $time);
    if ($secret) {
        LJ::MemCache::set($memkey, $secret) if $secret;
        return $want_new ? ($time, $secret) : $secret;
    }

    # return if they specified an explicit time they wanted.
    # (calling with no args means generate a new one if secret
    # doesn't exist)
    return undef unless $want_new;

    # don't generate new times that don't fall in our granularity
    return undef if $time % 3600;

    $secret = LJ::rand_chars(32);
    $dbh->do("INSERT IGNORE INTO secrets SET stime=?, secret=?",
             undef, $time, $secret);
    # check for races:
    $secret = get_secret($time);
    return ($time, $secret);
}

# <LJFUNC>
# name: LJ::get_reluser_id
# des: for reluser2, numbers 1 - 31999 are reserved for livejournal stuff, whereas
#       numbers 32000-65535 are used for local sites.  if you wish to add your
#       own hooks to this, you should define a hook "get_reluser_id" in ljlib-local.pl
#       no reluser2 types can be a single character, those are reserved for the
#       reluser table so we don't have namespace problems.
# args: type
# des-type: the name of the type you're trying to access, e.g. "hide_comm_assoc"
# returns: id of type, 0 means it's not a reluser2 type
# </LJFUNC>
sub get_reluser_id {
    my $type = shift;
    return 0 if length $type == 1; # must be more than a single character
    my $val =
        {
            'hide_comm_assoc' => 1,
        }->{$type}+0;
    return $val if $val;
    return 0 unless $type =~ /^local-/;
    return LJ::run_hook('get_reluser_id', $type)+0;
}

# <LJFUNC>
# name: LJ::load_rel_user
# des: Load user relationship information. Loads all relationships of type 'type' in
#      which user 'userid' participates on the left side (is the source of the
#      relationship).
# args: db?, userid, type
# arg-userid: userid or a user hash to load relationship information for.
# arg-type: type of the relationship
# returns: reference to an array of userids
# </LJFUNC>
sub load_rel_user
{
    my $db = isdb($_[0]) ? shift : undef;
    my ($userid, $type) = @_;
    return undef unless $type and $userid;
    my $u = LJ::want_user($userid);
    $userid = LJ::want_userid($userid);
    my $typeid = LJ::get_reluser_id($type)+0;
    if ($typeid) {
        # clustered reluser2 table
        $db = LJ::get_cluster_reader($u);
        return $db->selectcol_arrayref("SELECT targetid FROM reluser2 WHERE userid=? AND type=?",
                                       undef, $userid, $typeid);
    } else {
        # non-clustered reluser global table
        $db ||= LJ::get_db_reader();
        return $db->selectcol_arrayref("SELECT targetid FROM reluser WHERE userid=? AND type=?",
                                       undef, $userid, $type);
    }
}

# <LJFUNC>
# name: LJ::load_rel_target
# des: Load user relationship information. Loads all relationships of type 'type' in
#      which user 'targetid' participates on the right side (is the target of the
#      relationship).
# args: db?, targetid, type
# arg-targetid: userid or a user hash to load relationship information for.
# arg-type: type of the relationship
# returns: reference to an array of userids
# </LJFUNC>
sub load_rel_target
{
    my $db = isdb($_[0]) ? shift : undef;
    my ($targetid, $type) = @_;
    return undef unless $type and $targetid;
    my $u = LJ::want_user($targetid);
    $targetid = LJ::want_userid($targetid);
    my $typeid = LJ::get_reluser_id($type)+0;
    if ($typeid) {
        # clustered reluser2 table
        $db = LJ::get_cluster_reader($u);
        return $db->selectcol_arrayref("SELECT userid FROM reluser2 WHERE targetid=? AND type=?",
                                       undef, $targetid, $typeid);
    } else {
        # non-clustered reluser global table
        $db ||= LJ::get_db_reader();
        return $db->selectcol_arrayref("SELECT userid FROM reluser WHERE targetid=? AND type=?",
                                       undef, $targetid, $type);
    }
}

# <LJFUNC>
# name: LJ::_get_rel_memcache
# des: Helper function: returns memcached value for a given (userid, targetid, type) triple, if valid
# args: userid, targetid, type
# arg-userid: source userid, nonzero
# arg-targetid: target userid, nonzero
# arg-type: type (reluser) or typeid (rel2) of the relationship
# returns: undef on failure, 0 or 1 depending on edge existence
# </LJFUNC>
sub _get_rel_memcache {
    return undef unless @LJ::MEMCACHE_SERVERS;
    return undef if $LJ::DISABLED{memcache_reluser};

    my ($userid, $targetid, $type) = @_;
    return undef unless $userid && $targetid && defined $type;

    # memcache keys
    my $relkey  = [$userid,   "rel:$userid:$targetid:$type"]; # rel $uid->$targetid edge
    my $modukey = [$userid,   "relmodu:$userid:$type"      ]; # rel modtime for uid
    my $modtkey = [$targetid, "relmodt:$targetid:$type"    ]; # rel modtime for targetid

    # do a get_multi since $relkey and $modukey are both hashed on $userid
    my $memc = LJ::MemCache::get_multi($relkey, $modukey);
    return undef unless $memc && ref $memc eq 'HASH';

    # [{0|1}, modtime]
    my $rel = $memc->{$relkey->[1]};
    return undef unless $rel && ref $rel eq 'ARRAY';

    # check rel modtime for $userid
    my $relmodu = $memc->{$modukey->[1]};
    return undef if ! $relmodu || $relmodu > $rel->[1];

    # check rel modtime for $targetid
    my $relmodt = LJ::MemCache::get($modtkey);
    return undef if ! $relmodt || $relmodt > $rel->[1];

    # return memcache value if it's up-to-date
    return $rel->[0] ? 1 : 0;
}

# <LJFUNC>
# name: LJ::_set_rel_memcache
# des: Helper function: sets memcache values for a given (userid, targetid, type) triple
# args: userid, targetid, type
# arg-userid: source userid, nonzero
# arg-targetid: target userid, nonzero
# arg-type: type (reluser) or typeid (rel2) of the relationship
# returns: 1 on success, undef on failure
# </LJFUNC>
sub _set_rel_memcache {
    return 1 unless @LJ::MEMCACHE_SERVERS;

    my ($userid, $targetid, $type, $val) = @_;
    return undef unless $userid && $targetid && defined $type;
    $val = $val ? 1 : 0;

    # memcache keys
    my $relkey  = [$userid,   "rel:$userid:$targetid:$type"]; # rel $uid->$targetid edge
    my $modukey = [$userid,   "relmodu:$userid:$type"      ]; # rel modtime for uid
    my $modtkey = [$targetid, "relmodt:$targetid:$type"    ]; # rel modtime for targetid

    my $now = time();
    my $exp = $now + 3600*6; # 6 hour
    LJ::MemCache::set($relkey, [$val, $now], $exp);
    LJ::MemCache::set($modukey, $now, $exp);
    LJ::MemCache::set($modtkey, $now, $exp);

    return 1;
}

# <LJFUNC>
# name: LJ::check_rel
# des: Checks whether two users are in a specified relationship to each other.
# args: db?, userid, targetid, type
# arg-userid: source userid, nonzero; may also be a user hash.
# arg-targetid: target userid, nonzero; may also be a user hash.
# arg-type: type of the relationship
# returns: 1 if the relationship exists, 0 otherwise
# </LJFUNC>
sub check_rel
{
    my $db = isdb($_[0]) ? shift : undef;
    my ($userid, $targetid, $type) = @_;
    return undef unless $type && $userid && $targetid;

    my $u = LJ::want_user($userid);
    $userid = LJ::want_userid($userid);
    $targetid = LJ::want_userid($targetid);

    my $typeid = LJ::get_reluser_id($type)+0;
    my $eff_type = $typeid || $type;

    my $key = "$userid-$targetid-$eff_type";
    return $LJ::REQ_CACHE_REL{$key} if defined $LJ::REQ_CACHE_REL{$key};

    # did we get something from memcache?
    my $memval = LJ::_get_rel_memcache($userid, $targetid, $eff_type);
    return $memval if defined $memval;

    # are we working on reluser or reluser2?
    my $table;
    if ($typeid) {
        # clustered reluser2 table
        $db = LJ::get_cluster_reader($u);
        $table = "reluser2";
    } else {
        # non-clustered reluser table
        $db ||= LJ::get_db_reader();
        $table = "reluser";
    }

    # get data from db, force result to be {0|1}
    my $dbval = $db->selectrow_array("SELECT COUNT(*) FROM $table ".
                                     "WHERE userid=? AND targetid=? AND type=? ",
                                     undef, $userid, $targetid, $eff_type)
        ? 1 : 0;

    # set in memcache
    LJ::_set_rel_memcache($userid, $targetid, $eff_type, $dbval);

    # return and set request cache
    return $LJ::REQ_CACHE_REL{$key} = $dbval;
}

# <LJFUNC>
# name: LJ::set_rel
# des: Sets relationship information for two users.
# args: dbs?, userid, targetid, type
# arg-userid: source userid, or a user hash
# arg-targetid: target userid, or a user hash
# arg-type: type of the relationship
# returns: 1 if set succeeded, otherwise undef
# </LJFUNC>
sub set_rel
{
    &nodb;
    my ($userid, $targetid, $type) = @_;
    return undef unless $type and $userid and $targetid;

    my $u = LJ::want_user($userid);
    $userid = LJ::want_userid($userid);
    $targetid = LJ::want_userid($targetid);

    my $typeid = LJ::get_reluser_id($type)+0;
    my $eff_type = $typeid || $type;

    # working on reluser or reluser2?
    my ($db, $table);
    if ($typeid) {
        # clustered reluser2 table
        $db = LJ::get_cluster_master($u);
        $table = "reluser2";
    } else {
        # non-clustered reluser global table
        $db = LJ::get_db_writer();
        $table = "reluser";
    }
    return undef unless $db;

    # set in database
    $db->do("REPLACE INTO $table (userid, targetid, type) VALUES (?, ?, ?)",
            undef, $userid, $targetid, $eff_type);
    return undef if $db->err;

    # set in memcache
    LJ::_set_rel_memcache($userid, $targetid, $eff_type, 1);

    return 1;
}

# <LJFUNC>
# name: LJ::set_rel_multi
# des: Sets relationship edges for lists of user tuples.
# args: @edges
# arg-edges: array of arrayrefs of edges to set: [userid, targetid, type]
#            Where: 
#               userid: source userid, or a user hash
#               targetid: target userid, or a user hash
#               type: type of the relationship
# returns: 1 if all sets succeeded, otherwise undef
# </LJFUNC>
sub set_rel_multi {
    return _mod_rel_multi({ mode => 'set', edges => \@_ });
}

# <LJFUNC>
# name: LJ::clear_rel_multi
# des: Clear relationship edges for lists of user tuples.
# args: @edges
# arg-edges: array of arrayrefs of edges to clear: [userid, targetid, type]
#            Where: 
#               userid: source userid, or a user hash
#               targetid: target userid, or a user hash
#               type: type of the relationship
# returns: 1 if all clears succeeded, otherwise undef
# </LJFUNC>
sub clear_rel_multi {
    return _mod_rel_multi({ mode => 'clear', edges => \@_ });
}

# <LJFUNC>
# name: LJ::_mod_rel_multi
# des: Sets/Clears relationship edges for lists of user tuples.
# args: $opts
# arg-opts: keys: mode  => {clear|set}
#                 edges =>  array of arrayrefs of edges to set: [userid, targetid, type]
#                    Where: 
#                       userid: source userid, or a user hash
#                       targetid: target userid, or a user hash
#                       type: type of the relationship
# returns: 1 if all updates succeeded, otherwise undef
# </LJFUNC>
sub _mod_rel_multi
{
    my $opts = shift;
    return undef unless @{$opts->{edges}};

    my $mode = $opts->{mode} eq 'clear' ? 'clear' : 'set';
    my $memval = $mode eq 'set' ? 1 : 0;

    my @reluser  = (); # [userid, targetid, type]
    my @reluser2 = ();
    foreach my $edge (@{$opts->{edges}}) {
        my ($userid, $targetid, $type) = @$edge;
        $userid = LJ::want_userid($userid);
        $targetid = LJ::want_userid($targetid);
        next unless $type && $userid && $targetid;

        my $typeid = LJ::get_reluser_id($type)+0;
        my $eff_type = $typeid || $type;

        # working on reluser or reluser2?
        push @{$typeid ? \@reluser2 : \@reluser}, [$userid, $targetid, $eff_type];
    }

    # now group reluser2 edges by clusterid
    my %reluser2 = (); # cid => [userid, targetid, type]
    my $users = LJ::load_userids(map { $_->[0] } @reluser2);
    foreach (@reluser2) {
        my $cid = $users->{$_->[0]}->{clusterid} or next;
        push @{$reluser2{$cid}}, $_;
    }
    @reluser2 = ();

    # try to get all required cluster masters before we start doing database updates
    my %cache_dbcm = ();
    foreach my $cid (keys %reluser2) {
        next unless @{$reluser2{$cid}};

        # return undef immediately if we won't be able to do all the updates
        $cache_dbcm{$cid} = LJ::get_cluster_master($cid)
            or return undef;
    }

    # if any error occurs with a cluster, we'll skip over that cluster and continue
    # trying to process others since we've likely already done some amount of db 
    # updates already, but we'll return undef to signify that everything did not
    # go smoothly
    my $ret = 1;

    # do clustered reluser2 updates
    foreach my $cid (keys %cache_dbcm) {
        # array of arrayrefs: [userid, targetid, type]
        my @edges = @{$reluser2{$cid}};

        # set in database, then in memcache.  keep the two atomic per clusterid
        my $dbcm = $cache_dbcm{$cid};

        my @vals = map { @$_ } @edges;

        if ($mode eq 'set') {
            my $bind = join(",", map { "(?,?,?)" } @edges);
            $dbcm->do("REPLACE INTO reluser2 (userid, targetid, type) VALUES $bind",
                      undef, @vals);
        }

        if ($mode eq 'clear') {
            my $where = join(" OR ", map { "(userid=? AND targetid=? AND type=?)" } @edges);
            $dbcm->do("DELETE FROM reluser2 WHERE $where", undef, @vals);
        }

        # don't update memcache if db update failed for this cluster
        if ($dbcm->err) {
            $ret = undef;
            next;
        }

        # updates to this cluster succeeded, set memcache
        LJ::_set_rel_memcache(@$_, $memval) foreach @edges;
    }

    # do global reluser updates
    if (@reluser) {

        # nothing to do after this block but return, so we can
        # immediately return undef from here if there's a problem
        my $dbh = LJ::get_db_writer()
            or return undef;

        my @vals = map { @$_ } @reluser; 

        if ($mode eq 'set') {
            my $bind = join(",", map { "(?,?,?)" } @reluser);
            $dbh->do("REPLACE INTO reluser (userid, targetid, type) VALUES $bind",
                     undef, @vals);
        }

        if ($mode eq 'clear') {
            my $where = join(" OR ", map { "userid=? AND targetid=? AND type=?" } @reluser);
            $dbh->do("DELETE FROM reluser WHERE $where", undef, @vals);
        }

        # don't update memcache if db update failed for this cluster
        return undef if $dbh->err;

        # $_ = [userid, targetid, type] for each iteration
        LJ::_set_rel_memcache(@$_, $memval) foreach @reluser;
    }

    return $ret;
}


# <LJFUNC>
# name: LJ::clear_rel
# des: Deletes a relationship between two users or all relationships of a particular type
#      for one user, on either side of the relationship. One of userid,targetid -- bit not
#      both -- may be '*'. In that case, if, say, userid is '*', then all relationship
#      edges with target equal to targetid and of the specified type are deleted.
#      If both userid and targetid are numbers, just one edge is deleted.
# args: dbs?, userid, targetid, type
# arg-userid: source userid, or a user hash, or '*'
# arg-targetid: target userid, or a user hash, or '*'
# arg-type: type of the relationship
# returns: 1 if clear succeeded, otherwise undef
# </LJFUNC>
sub clear_rel
{
    &nodb;
    my ($userid, $targetid, $type) = @_;
    return undef if $userid eq '*' and $targetid eq '*';

    my $u = LJ::want_user($userid);
    $userid = LJ::want_userid($userid) unless $userid eq '*';
    $targetid = LJ::want_userid($targetid) unless $targetid eq '*';
    return undef unless $type && $userid && $targetid;

    my $typeid = LJ::get_reluser_id($type)+0;

    if ($typeid) {
        # clustered reluser2 table
        return undef unless $u->writer;

        $u->do("DELETE FROM reluser2 WHERE " . ($userid ne '*' ? "userid=$userid AND " : "") .
               ($targetid ne '*' ? "targetid=$targetid AND " : "") . "type=$typeid");

        return undef if $u->err;
    } else {
        # non-clustered global reluser table
        my $dbh = LJ::get_db_writer()
            or return undef;

        my $qtype = $dbh->quote($type);
        $dbh->do("DELETE FROM reluser WHERE " . ($userid ne '*' ? "userid=$userid AND " : "") .
                 ($targetid ne '*' ? "targetid=$targetid AND " : "") . "type=$qtype");

        return undef if $dbh->err;
    }

    # if one of userid or targetid are '*', then we need to note the modtime
    # of the reluser edge from the specified id (the one that's not '*')
    # so that subsequent gets on rel:userid:targetid:type will know to ignore
    # what they got from memcache
    my $eff_type = $typeid || $type;
    if ($userid eq '*') {
        LJ::MemCache::set([$targetid, "relmodt:$targetid:$eff_type"], time());
    } elsif ($targetid eq '*') {
        LJ::MemCache::set([$userid, "relmodu:$userid:$eff_type"], time());

    # if neither userid nor targetid are '*', then just call _set_rel_memcache
    # to update the rel:userid:targetid:type memcache key as well as the 
    # userid and targetid modtime keys
    } else {
        LJ::_set_rel_memcache($userid, $targetid, $eff_type, 0);
    }

    return 1;
}

# $dom: 'S' == style, 'P' == userpic, 'A' == stock support answer
#       'C' == captcha, 'E' == external user
sub alloc_global_counter
{
    my ($dom, $recurse) = @_;
    return undef unless $dom =~ /^[SPCEA]$/;
    my $dbh = LJ::get_db_writer();
    return undef unless $dbh;

    my $newmax;
    my $uid = 0; # userid is not needed, we just use '0'

    my $rs = $dbh->do("UPDATE counter SET max=LAST_INSERT_ID(max+1) WHERE journalid=? AND area=?",
                      undef, $uid, $dom);
    if ($rs > 0) {
        $newmax = $dbh->selectrow_array("SELECT LAST_INSERT_ID()");
        return $newmax;
    }

    return undef if $recurse;

    # no prior counter rows - initialize one.
    if ($dom eq "S") {
        $newmax = $dbh->selectrow_array("SELECT MAX(styleid) FROM s1stylemap");
    } elsif ($dom eq "P") {
        $newmax = $dbh->selectrow_array("SELECT MAX(picid) FROM userpic");
    } elsif ($dom eq "C") {
        $newmax = $dbh->selectrow_array("SELECT MAX(capid) FROM captchas");
    } elsif ($dom eq "E") {
        # if there is no extuser counter row, start making extuser names at
        # 'ext_1'  - ( the 0 here is incremented after the recurse )
        $newmax = 0; 
    } elsif ($dom eq "A") {
        $newmax = $dbh->selectrow_array("SELECT MAX(ansid) FROM support_answers");
    } else {
        die "No alloc_global_counter initalizer for domain '$dom'";
    }
    $newmax += 0;
    $dbh->do("INSERT IGNORE INTO counter (journalid, area, max) VALUES (?,?,?)",
            undef, $uid, $dom, $newmax) or return undef;
    return LJ::alloc_global_counter($dom, 1);
}

sub note_recent_action {
    my ($cid, $action) = @_;

    # accept a user object
    $cid = ref $cid ? $cid->{clusterid}+0 : $cid+0;
    return undef unless $cid;

    my $flag = { post => 'P' }->{$action};

    if (! $flag && LJ::are_hooks("recent_action_flags")) {
        $flag = LJ::run_hook("recent_action_flags", $action);
        die "Invalid flag received from hook: $flag"
            unless $flag =~ /^_\w$/; # must be prefixed with '_'
    }

    # should have a flag by now
    return undef unless $flag;

    my $dbcm = LJ::get_cluster_master($cid)
        or return undef;

    # append to recentactions table
    $dbcm->do("INSERT INTO recentactions VALUES (?)", undef, $flag);
    return undef if $dbcm->err;

    return 1;
}

sub is_web_context {
  return $ENV{MOD_PERL} ? 1 : 0;
}

# given a unix time, returns;
#   ($week, $ubefore)
# week: week number (week 0 is first 3 days of unix time)
# ubefore:  seconds before the next sunday, divided by 10
sub weekuu_parts {
    my $time = shift;
    $time -= 86400*3;  # time from the sunday after unixtime 0
    my $WEEKSEC = 86400*7;
    my $week = int(($time+$WEEKSEC) / $WEEKSEC);
    my $uafter = int(($time % $WEEKSEC) / 10);
    my $ubefore = int(60480 - ($time % $WEEKSEC) / 10);
    return ($week, $uafter, $ubefore);
}

sub weekuu_before_to_time
{
    my ($week, $ubefore) = @_;
    my $WEEKSEC = 86400*7;
    my $time = $week * $WEEKSEC + 86400*3;
    $time -= 10 * $ubefore;
    return $time;
}

sub weekuu_after_to_time
{
    my ($week, $uafter) = @_;
    my $WEEKSEC = 86400*7;
    my $time = ($week-1) * $WEEKSEC + 86400*3;
    $time += 10 * $uafter;
    return $time;
}

sub is_open_proxy
{
    my $ip = shift;
    eval { $ip ||= Apache->request; };
    return 0 unless $ip;
    if (ref $ip) { $ip = $ip->connection->remote_ip; }

    my $dbr = LJ::get_db_reader();
    my $stat = $dbr->selectrow_hashref("SELECT status, asof FROM openproxy WHERE addr=?",
                                       undef, $ip);

    # only cache 'clear' hosts for a day; 'proxy' for two days
    $stat = undef if $stat && $stat->{'status'} eq "clear" && $stat->{'asof'} > 0 && $stat->{'asof'} < time()-86400;
    $stat = undef if $stat && $stat->{'status'} eq "proxy" && $stat->{'asof'} < time()-2*86400;

    # open proxies are considered open forever, unless cleaned by another site-local mechanism
    return 1 if $stat && $stat->{'status'} eq "proxy";

    # allow things to be cached clear for a day before re-checking
    return 0 if $stat && $stat->{'status'} eq "clear";

    # no RBL defined?
    return 0 unless @LJ::RBL_LIST;

    my $src = undef;
    my $rev = join('.', reverse split(/\./, $ip));
    foreach my $rbl (@LJ::RBL_LIST) {
        my @res = gethostbyname("$rev.$rbl");
        if ($res[4]) {
            $src = $rbl;
            last;
        }
    }

    my $dbh = LJ::get_db_writer();
    if ($src) {
        $dbh->do("REPLACE INTO openproxy (addr, status, asof, src) VALUES (?,?,?,?)", undef,
                 $ip, "proxy", time(), $src);
        return 1;
    } else {
        $dbh->do("INSERT IGNORE INTO openproxy (addr, status, asof, src) VALUES (?,?,?,?)", undef,
                 $ip, "clear", time(), $src);
        return 0;
    }
}

# loads an include file, given the bare name of the file.
#   ($filename)
# returns the text of the file.  if the file is specified in %LJ::FILEEDIT_VIA_DB
# then it is loaded from memcache/DB, else it falls back to disk.
sub load_include {
    my $file = shift;
    return unless $file && $file =~ /^[a-zA-Z0-9-_\.]{1,255}$/;

    # okay, edit from where?
    if ($LJ::FILEEDIT_VIA_DB || $LJ::FILEEDIT_VIA_DB{$file}) {
        # we handle, so first if memcache...
        my $val = LJ::MemCache::get("includefile:$file");
        return $val if $val;

        # straight database hit
        my $dbh = LJ::get_db_writer();
        $val = $dbh->selectrow_array("SELECT inctext FROM includetext ".
                                     "WHERE incname=?", undef, $file);
        LJ::MemCache::set("includefile:$file", $val, time() + 3600);
        return $val;
    }

    # hit it up from the file, if it exists
    my $filename = "$ENV{'LJHOME'}/htdocs/inc/$file";
    return unless -e $filename;

    # get it and return it
    my $val;
    open (INCFILE, $filename)
        or return "Could not open include file: $file.";
    { local $/ = undef; $val = <INCFILE>; }
    close INCFILE;
    return $val;
}

# <LJFUNC>
# name: LJ::bit_breakdown
# des: Breaks down a bitmask into an array of bits enabled.
# args: mask
# des-mask: The number to break down.
# returns: A list of bits enabled.  E.g., 3 returns (0, 2) indicating that bits 0 and 2 (numbering
#          from the right) are currently on.
# </LJFUNC>
sub bit_breakdown {
    my $mask = shift()+0;

    # check each bit 0..31 and return only ones that are defined
    return grep { defined }
           map { $mask & (1<<$_) ? $_ : undef } 0..31;
}

sub last_error_code
{
    return $LJ::last_error;
}

sub last_error
{
    my $err = {
        'utf8' => "Encoding isn't valid UTF-8",
        'db' => "Database error",
        'comm_not_found' => "Community not found",
        'comm_not_comm' => "Account not a community",
        'comm_not_member' => "User not a member of community",
        'comm_invite_limit' => "Outstanding invitation limit reached",
        'comm_user_has_banned' => "Unable to invite; user has banned community",
    };
    my $des = $err->{$LJ::last_error};
    if ($LJ::last_error eq "db" && $LJ::db_error) {
        $des .= ": $LJ::db_error";
    }
    return $des || $LJ::last_error;
}

sub error
{
    my $err = shift;
    if (isdb($err)) {
        $LJ::db_error = $err->errstr;
        $err = "db";
    } elsif ($err eq "db") {
        $LJ::db_error = "";
    }
    $LJ::last_error = $err;
    return undef;
}

# to be called as &nodb; (so this function sees caller's @_)
sub nodb {
    shift @_ if
        ref $_[0] eq "LJ::DBSet" || ref $_[0] eq "DBI::db" ||
        ref $_[0] eq "DBIx::StateKeeper" || ref $_[0] eq "Apache::DBI::db";
}

sub isdb { return ref $_[0] && (ref $_[0] eq "DBI::db" ||
                                ref $_[0] eq "DBIx::StateKeeper" ||
                                ref $_[0] eq "Apache::DBI::db"); }

sub no_utf8_flag {
  return pack('U*', unpack('C*', $_[0]));
}

sub conf_test {
    my ($conf, @args) = @_;
    return 0 unless $conf;
    return $conf->(@args) if ref $conf eq "CODE";
    return $conf;
}

use vars qw($AUTOLOAD);
sub AUTOLOAD {
    if ($AUTOLOAD eq "LJ::send_mail") {
        require "$ENV{'LJHOME'}/cgi-bin/ljmail.pl";
        goto &$AUTOLOAD;
    }
    croak "Undefined subroutine: $AUTOLOAD";
}

# LJ::S1::get_public_styles lives here in ljlib.pl so that
# cron jobs can call LJ::load_user_props without including
# ljviews.pl
package LJ::S1;

sub get_public_styles {

    my $opts = shift;

    # Try memcache if no extra options are requested
    my $memkey = "s1pubstyc";
    my $pubstyc = {};
    unless ($opts) {
        my $pubstyc = LJ::MemCache::get($memkey);
        return $pubstyc if $pubstyc;
    }

    # not cached, build from db
    my $sysid = LJ::get_userid("system");

    # all cols *except* formatdata, which is big and unnecessary for most uses.
    # it'll be loaded by LJ::S1::get_style
    my $cols = "styleid, styledes, type, is_public, is_embedded, ".
        "is_colorfree, opt_cache, has_ads, lastupdate";
    $cols .= ", formatdata" if $opts->{'formatdata'};

    # first try new table
    my $dbh = LJ::get_db_writer();
    my $sth = $dbh->prepare("SELECT userid, $cols FROM s1style WHERE userid=? AND is_public='Y'");
    $sth->execute($sysid);
    $pubstyc->{$_->{'styleid'}} = $_ while $_ = $sth->fetchrow_hashref;

    # fall back to old table
    unless (%$pubstyc) {
        $sth = $dbh->prepare("SELECT user, $cols FROM style WHERE user='system' AND is_public='Y'");
        $sth->execute();
        $pubstyc->{$_->{'styleid'}} = $_ while $_ = $sth->fetchrow_hashref;
    }
    return undef unless %$pubstyc;

    # set in memcache
    unless ($opts) {
        my $expire = time() + 60*30; # 30 minutes
        LJ::MemCache::set($memkey, $pubstyc, $expire);
    }

    return $pubstyc;
}

# this package also doesn't belong in ljlib.pl, and should probably be
# moved back to ljemailgateway.pl soon, but the web code needed this,
# as well as the mailgated code, so putting it in weblib.pl doesn't
# work, and making modperl-subs.pl include ljemailgateway.pl was
# problematic during the woody-sarge transition (still happening), so
# for now it's here in ljlib.
package LJ::Emailpost;

# Retreives an allowed email addr list for a given user object.
# Returns a hashref with addresses / flags.
# Used for ljemailgateway and manage/emailpost.bml
sub get_allowed_senders {
    my $u = shift;
    my (%addr, @address);

    LJ::load_user_props($u, 'emailpost_allowfrom');
    @address = split(/\s*,\s*/, $u->{emailpost_allowfrom});
    return undef unless scalar(@address) > 0;

    my %flag_english = ( 'E' => 'get_errors' );

    foreach my $add (@address) {
        my $flags;
        $flags = $1 if $add =~ s/\((.+)\)$//;
        $addr{$add} = {};
        if ($flags) {
            $addr{$add}->{$flag_english{$_}} = 1 foreach split(//, $flags);
        }
    }

    return \%addr;
}

# Inserts email addresses into the database.
# Adds flags if needed.
# Used in manage/emailpost.bml
sub set_allowed_senders {
    my ($u, $addr) = @_;
    my %flag_letters = ( 'get_errors' => 'E' );

    my @addresses;
    foreach (keys %$addr) {
        my $email = $_;
        my $flags = $addr->{$_};
        if (%$flags) {
            $email .= '(';
            foreach my $flag (keys %$flags) {
                $email .= $flag_letters{$flag};
            }
            $email .= ')';
        }
        push(@addresses, $email);
    }
    close T;
    LJ::set_userprop($u, "emailpost_allowfrom", join(", ", @addresses));
}

1;
