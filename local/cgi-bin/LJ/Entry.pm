package LJ;

use Class::Autouse qw (
  LJ::EmbedModule
);


# <LJFUNC>
# name: LJ::get_posts_raw
# des: Gets raw post data (text and props) efficiently from clusters.
# info: Fetches posts from clusters, trying memcache and slaves first if available.
# returns: hashref with keys 'text', 'prop', and values being hashrefs
#          with keys "jid:jitemid".  values of that are as follows:
#          text: [ $subject, $body ], props: { ... };
#          replycount scalar returned within props.
#          
# args: opts?, id+
# des-opts: An optional hashref of options:
#            - memcache_only:  Don't fall back on the database.
#            - prop_only:  Retrieve only props, for efficiensy.
# des-id: An arrayref of [ clusterid, ownerid, itemid ].
# </LJFUNC>
sub get_posts_raw
{
    my $opts = ref $_[0] eq "HASH" ? shift : {};
    my $ret = {};
    my $sth;

    LJ::load_props('log');

    # throughout this function, the concept of an "id"
    # is the key to identify a single post.
    # it is of the form "$jid:$jitemid".

    # build up a list for each cluster of what we want to get,
    # as well as a list of all the keys we want from memcache.
    my %cids;      # cid => 1
    my $needtext;  # text needed:  $cid => $id => 1
    my $needprop;  # props needed: $cid => $id => 1
    my $needrc;    # replycounts needed: $cid => $id => 1
    my @mem_keys;

    # if we're loading entries for a friends page,
    # silently failing to load a cluster is acceptable.
    # but for a single user, we want to die loudly so they don't think
    # we just lost their journal.
    my $single_user;

    # because the memcache keys for logprop don't contain
    # which cluster they're in, we also need a map to get the
    # cid back from the jid so we can insert into the needfoo hashes.
    # the alternative is to not key the needfoo hashes on cluster,
    # but that means we need to grep out each cluster's jids when
    # we do per-cluster queries on the databases.
    my %cidsbyjid;
    foreach my $post (@_) {
        my ($cid, $jid, $jitemid) = @{$post};
        my $id = "$jid:$jitemid"; #!!!
        if (not defined $single_user) {
            $single_user = $jid;
        } elsif ($single_user and $jid != $single_user) {
            # multiple users
            $single_user = 0;
        }
        $cids{$cid} = 1;
        $cidsbyjid{$jid} = $cid;

        unless ($opts->{prop_only}) {
            $needtext->{$cid}{$id} = 1;
            push @mem_keys, [$jid, "logtext:$cid:$id"];
            $needrc->{$cid}{$id} = 1;
            push @mem_keys, [$jid, "rp:$id"];
        }
        $needprop->{$cid}{$id} = 1;
        push @mem_keys, [$jid, "logprop:$id"];
    }

    # first, check memcache.
    my $mem = LJ::MemCache::get_multi(@mem_keys) || {};
    while (my ($k, $v) = each %$mem) {
        next unless defined $v;
        next unless $k =~ /(\w+):(?:\d+:)?(\d+):(\d+)/;
        my ($type, $jid, $jitemid) = ($1, $2, $3);
        my $cid = $cidsbyjid{$jid};
        my $id = "$jid:$jitemid";
        if ($type eq "logtext") {
            delete $needtext->{$cid}{$id};
            $ret->{text}{$id} = $v;
        } elsif ($type eq "logprop" && ref $v eq "HASH") {
            delete $needprop->{$cid}{$id};
            $ret->{prop}{$id} = $v;
        } elsif ($type eq "rp") {
            delete $needrc->{$cid}{$id};
            $ret->{replycount}{$id} = $v;
        }
    }

    # we may be done already.
    return $ret if $opts->{memcache_only};
    return $ret unless values %$needtext or values %$needprop
        or values %$needrc;

    # otherwise, hit the database.
    foreach my $cid (keys %cids) {
        # for each cluster, get the text/props we need from it.
        my $cneedtext = $needtext->{$cid} || {};
        my $cneedprop = $needprop->{$cid} || {};
        my $cneedrc   = $needrc->{$cid} || {};

        next unless %$cneedtext or %$cneedprop or %$cneedrc;

        my $make_in = sub {
            my @in;
            foreach my $id (@_) {
                my ($jid, $jitemid) = map { $_ + 0 } split(/:/, $id);
                push @in, "(journalid=$jid AND jitemid=$jitemid)";
            }
            return join(" OR ", @in);
        };

        # now load from each cluster.
        my $fetchtext = sub {
            my $db = shift;
            return unless %$cneedtext;
            my $in = $make_in->(keys %$cneedtext);
            $sth = $db->prepare("SELECT journalid, jitemid, subject, event ".
                                "FROM logtext2 WHERE $in");
            $sth->execute;
            while (my ($jid, $jitemid, $subject, $event) = $sth->fetchrow_array) {
                LJ::text_uncompress(\$event);
                my $id = "$jid:$jitemid";
                my $val = [ $subject, $event ];
                $ret->{text}{$id} = $val;
                LJ::MemCache::add([$jid, "logtext:$cid:$id"], $val, 7200);
                delete $cneedtext->{$id};
            }
        };

        my $fetchprop = sub {
            my $db = shift;
            return unless %$cneedprop;
            my $in = $make_in->(keys %$cneedprop);
            $sth = $db->prepare("SELECT journalid, jitemid, propid, value ".
                                "FROM logprop2 WHERE $in");
            $sth->execute;
            my %gotid;
            while (my ($jid, $jitemid, $propid, $value) = $sth->fetchrow_array) {
                my $id = "$jid:$jitemid";
                my $propname = $LJ::CACHE_PROPID{'log'}->{$propid}{name};
                $ret->{prop}{$id}{$propname} = $value;
                $gotid{$id} = 1;
            }
            foreach my $id (keys %gotid) {
                my ($jid, $jitemid) = map { $_ + 0 } split(/:/, $id);
                LJ::MemCache::add([$jid, "logprop:$id"], $ret->{prop}{$id}); #7200
                delete $cneedprop->{$id};
            }
        };

        my $fetchrc = sub {
            my $db = shift;
            return unless %$cneedrc;
            my $in = $make_in->(keys %$cneedrc);
            $sth = $db->prepare("SELECT journalid, jitemid, replycount FROM log2 WHERE $in");
            $sth->execute;
            while (my ($jid, $jitemid, $rc) = $sth->fetchrow_array) {
                my $id = "$jid:$jitemid";
                $ret->{replycount}{$id} = $rc;
                LJ::MemCache::add([$jid, "rp:$id"], $rc);
                delete $cneedrc->{$id};
            }
        };

        my $dberr = sub {
            die "Couldn't connect to database" if $single_user;
            next;
        };

        # run the fetch functions on the proper databases, with fallbacks if necessary.
        my ($dbcm, $dbcr);
        if (@LJ::MEMCACHE_SERVERS or $opts->{use_master}) {
            $dbcm ||= LJ::get_cluster_master($cid) or $dberr->();
            $fetchtext->($dbcm) if %$cneedtext;
            $fetchprop->($dbcm) if %$cneedprop;
            $fetchrc->($dbcm) if %$cneedrc;
        } else {
            $dbcr ||= LJ::get_cluster_reader($cid);
            if ($dbcr) {
                $fetchtext->($dbcr) if %$cneedtext;
                $fetchprop->($dbcr) if %$cneedprop;
                $fetchrc->($dbcr) if %$cneedrc;
            }
            # if we still need some data, switch to the master.
            if (%$cneedtext or %$cneedprop) {
                $dbcm ||= LJ::get_cluster_master($cid) or $dberr->();
                $fetchtext->($dbcm);
                $fetchprop->($dbcm);
                $fetchrc->($dbcm);
            }
        }

        # and finally, if there were no errors,
        # insert into memcache the absence of props
        # for all posts that didn't have any props.
        foreach my $id (keys %$cneedprop) {
            my ($jid, $jitemid) = map { $_ + 0 } split(/:/, $id);
            LJ::MemCache::add([$jid, "logprop:$id"], {} );
        }
    }

    # move replycount into prop : we could not do this before prop are set because prop hash will rewrite replycount...
    while (my ($k, $v) = each %{$ret->{"replycount"}||{}}) { 	 
        $ret->{prop}{$k}{replycount} = $ret->{replycount}{$k}; 	 
    }

    return $ret;
}


#
# returns a row from log2, trying memcache
# accepts $u + $jitemid
# returns hash with: posterid, eventtime, logtime,
# security, allowmask, journalid, jitemid, anum.

sub get_log2_row
{
    my ($u, $jitemid, $db) = @_;
    my $jid = $u->{'userid'};

    my $memkey = [$jid, "log2:$jid:$jitemid"];
    my ($row, $item);

    $row = LJ::MemCache::get($memkey);

    if ($row) {
        @$item{'posterid', 'eventtime', 'logtime', 'allowmask', 'ditemid'} = unpack("NNNNN", $row);
        $item->{'security'} = ($item->{'allowmask'} == 0 ? 'private' :
                               ($item->{'allowmask'} == 2**31 ? 'public' : 'usemask'));
        $item->{'journalid'} = $jid;
        @$item{'jitemid', 'anum'} = ($item->{'ditemid'} >> 8, $item->{'ditemid'} % 256);
        $item->{'eventtime'} = LJ::mysql_time($item->{'eventtime'}, 1);
        $item->{'logtime'} = LJ::mysql_time($item->{'logtime'}, 1);

        return $item;
    }

    $db = LJ::get_cluster_def_reader($u) unless $db;
    return undef unless $db;

    my $sql = "SELECT posterid, eventtime, logtime, security, allowmask, " .
              "anum FROM log2 WHERE journalid=? AND jitemid=?";

    $item = $db->selectrow_hashref($sql, undef, $jid, $jitemid);
    return undef unless $item;
    $item->{'journalid'} = $jid;
    $item->{'jitemid'} = $jitemid;
    $item->{'ditemid'} = $jitemid*256 + $item->{'anum'};

    my ($sec, $eventtime, $logtime);
    $sec = $item->{'allowmask'};
    $sec = 0 if $item->{'security'} eq 'private';
    $sec = 2**31 if $item->{'security'} eq 'public';
    $eventtime = LJ::mysqldate_to_time($item->{'eventtime'}, 1);
    $logtime = LJ::mysqldate_to_time($item->{'logtime'}, 1);

    $row = pack("NNNNN", $item->{'posterid'}, $eventtime, $logtime, $sec,
                $item->{'ditemid'});
    LJ::MemCache::set($memkey, $row);

    return $item;
}

# local function.
# Get 8 weeks worth of recent items, in rlogtime order, using memcache.
# accepts ($jid, $clusterid, $timeupdate, $notafter, $notbefore).
# - $notafter - max value for rlogtime
# - $notbefore - min value for rlogtime, optional
# - $timeupdate is the timeupdate for this user, as far as the caller knows,
# in UNIX time.
# returns arrayref of the following:
# [$rlogtime, $posterid, $eventtime, $allowmask, $ditemid]

sub get_log2_recent_log
{
    my ($jid, $cid, $timeupdate, $notafter, $notbefore) = @_;

    my $DATAVER = "3"; # 1 char

    my $memkey = [$jid, "log2lt:$jid"];
    my $lockkey = $memkey->[1];
    my ($rows, $ret);

    $rows = LJ::MemCache::get($memkey);
    $ret = [];

    my $rows_decode = sub {
        return 0
            unless $rows && substr($rows, 0, 1) eq $DATAVER;
        my $tu = unpack("N", substr($rows, 1, 4));

        # if update time we got from upstream is newer than recorded
        # here, this data from memcache is unreliable
        return 0 if $timeupdate > $tu;

        my $n = (length($rows) - 5 )/20;
        for (my $i=0; $i<$n; $i++) {
            #was: pack("NNNNN",  $rlogtime, $posterid, $eventtime, $allowmask, $ditemid);
            my @item = unpack("NNNNN", substr($rows, $i*20+5, 20));
            next if $notbefore and $item[0] < $notbefore; # rlogtime
            last if $notafter and $item[0] > $notafter; # rlogtime
            push @$ret, \@item;
        }
        return 1;
    };

    return $ret
        if $rows_decode->();

    #clear otherwise:
    LJ::MemCache::delete($memkey) if $rows;
    $rows = "";

    my $db = LJ::get_cluster_def_reader($cid);
    # if we use slave or didn't get some data, don't store in memcache
    my $dont_store = 0;
    unless ($db) {
        $db = LJ::get_cluster_reader($cid);
        $dont_store = 1;
        return undef unless $db;
    }


    # get reliable log2lt data from the db

    my $max_age = $LJ::MAX_FRIENDS_VIEW_AGE || 3600*24*56; # 8 weeks default

    my $sql = "SELECT rlogtime, posterid, eventtime, jitemid, " .
        "security, allowmask, anum, replycount FROM log2 " .
        "USE INDEX (rlogtime) WHERE journalid=? AND " .
        "rlogtime <= ($LJ::EndOfTime - UNIX_TIMESTAMP()) + $max_age";

    my $sth = $db->prepare($sql);
    $sth->execute($jid);
    my @row;
    while (my @arr = $sth->fetchrow_array) { push @row, \@arr; }
    @row = sort { $a->[0] <=> $b->[0] } @row; #rlogtime
    my $i = 0;

    foreach (@row) {
        my ($rlogtime, $posterid, $eventtime, $jitemid, $security, $allowmask, $anum, $replycount) = @$_; #in $sql order!
        $eventtime = LJ::mysqldate_to_time($eventtime, 1);

        $allowmask = 0 if $security eq 'private';
        $allowmask = 2**31 if $security eq 'public';

        my $ditemid = $jitemid*256 + $anum;

        $rows .= pack("NNNNN",  $rlogtime, $posterid, $eventtime, $allowmask, $ditemid);

        unless (($notafter and $rlogtime > $notafter) || ($notbefore and $rlogtime < $notbefore)) {
            push @$ret,  [$rlogtime, $posterid, $eventtime, $allowmask, $ditemid];
        }

        if ($i++ < 50) {
            LJ::MemCache::add([$jid, "rp:$jid:$jitemid"], $replycount);
        }
        if ($i > $LJ::MAX_SCROLLBACK_FRIENDS_SINGLE_USER_ACTIVITY) {
            last;  #limit log2lt: to a reasonable size
        }
    }

    $rows = $DATAVER . pack("N", $timeupdate) . $rows;
    LJ::MemCache::add($memkey, $rows,  $timeupdate + $max_age) unless $dont_store;

    return $ret;
}

# public function, called from  get_friend_items()
sub get_log2_recent_user
{
    my $opts = shift;
    my $ret = [];

    my $journalid = $opts->{'userid'};
    my $clusterid = $opts->{'clusterid'};

    my $log = LJ::get_log2_recent_log($journalid, $clusterid, $opts->{'timeupdate'}, $opts->{'notafter'}, $opts->{'notbefore'});

    my $left = $opts->{'itemshow'};
    my $remote = $opts->{'remote'};
    my $remoteid = $remote->{'userid'};
    my $valid_remote_journaltype = $remote->{'journaltype'} eq "P" || $remote->{'journaltype'} eq "I";
    my $mask;

    foreach my $i (@$log) {
        last unless $left;

        ## filter security and provide proper format for the caller:

        my ($rlogtime, $posterid, $eventtime, $allowmask, $ditemid) = @$i;

        my $security = $allowmask == 0 ? 'private' :
                            ($allowmask == 2**31 ? 'public' : 'usemask');

        next unless $remote || $security eq 'public';
        next if $security eq 'private'
            and $journalid != $remoteid;

        if ($security eq 'usemask') {
            next unless $valid_remote_journaltype;
            my $permit = ($journalid == $remoteid);
            unless ($permit) {
                $mask = LJ::get_groupmask($journalid, $remoteid)  unless defined $mask;
                $permit = $allowmask+0 & $mask+0;
            }
            next unless $permit;
        }

        my ($jitemid, $anum) = ($ditemid >> 8, $ditemid % 256);

        push @$ret, [$rlogtime, $jitemid, $posterid, $eventtime, $anum, $ditemid, $security, $journalid];
        $left--;
    }

    return $ret;
}


# called from go.bml
sub get_itemid_near2
{
    my ($u, $ditemid, $direction) = @_;

    $ditemid += 0;
    my $jitemid = $ditemid >> 8;

    my ($inc, $order);
    if ($direction eq "next") {
        ($inc, $order) = (1, "DESC");
    } elsif ($direction eq "prev") {
        ($inc, $order) = (-1, "ASC");
    } else {
        return 0;
    }

    my $dbr = LJ::get_cluster_reader($u);
    my $jid = $u->{'userid'}+0;

    # $remote  nujen dlia svjaznosti ssylok.
    my $remote = LJ::get_remote();
    my $mask;

    my $item;

    while (1) {
        $jitemid += $inc;
        # TODO: try get_log2_row()
        #($anum, $security, $allowmask) = $dbr->selectrow_array(
        #        "SELECT anum, security, allowmask ".
        #        " FROM log2 WHERE journalid=$jid AND jitemid=$jitemid");
        $item = get_log2_row($u, $jitemid, $dbr);
        last unless $item;

        my $security = $item->{'security'};
        # usually exits from the first try, unless security:
        last if $security eq 'public';
        last if $security eq 'private' && $remote && $jid == $remote->{'userid'};

        if ($security eq 'usemask' && $remote) {
            next unless $remote->{'journaltype'} eq "P" || $remote->{'journaltype'} eq "I";
            my $permit = ($jid == $remote->{'userid'});
            unless ($permit) {
                $mask = LJ::get_groupmask($jid, $remote->{'userid'})  unless defined $mask;
                $permit = $item->{'allowmask'} & $mask+0;
            }
            last if $permit;
        }
        next;
    }
    return  $item->{'jitemid'}*256 + $item->{'anum'}  if ($item);
    #return 0;  # deleted posts can be a problem


    # old, unused code, use as fallback
    $jitemid = $ditemid >> 8;
    my $field = $u->{'journaltype'} eq "P" ? "revttime" : "rlogtime";

    my $stime = $dbr->selectrow_array("SELECT $field FROM log2 WHERE ".
                                      "journalid=$jid AND jitemid=$jitemid");
    return 0 unless $stime;

    my $day = 86400;
    foreach my $distance ($day, $day*7, $day*30, $day*90) {
        my ($one_away, $further) = ($stime - $inc, $stime - $inc*$distance);
        if ($further < $one_away) {
            # swap them, BETWEEN needs lower number first
            ($one_away, $further) = ($further, $one_away);
        }
        my ($id, $anum) =
            $dbr->selectrow_array("SELECT jitemid, anum FROM log2 WHERE journalid=$jid ".
                                  "AND $field BETWEEN $one_away AND $further ".
                                  "ORDER BY $field $order LIMIT 1");
        if ($id) {
            return wantarray() ? ($id, $anum) : ($id*256 + $anum);
        }
    }
    return 0;
}


sub set_logprop
{
    my ($u, $jitemid, $hashref, $logprops) = @_;  # hashref to set, hashref of what was done

    $jitemid += 0;
    my $uid = $u->{'userid'} + 0;
    my $kill_mem = 0;
    my $del_ids;
    my $ins_values;
    while (my ($k, $v) = each %{$hashref||{}}) {
        my $prop = LJ::get_prop("log", $k);
        next unless $prop;
        $kill_mem = 1;
        if ($v) {
            $ins_values .= "," if $ins_values;
            $ins_values .= "($uid, $jitemid, $prop->{'id'}, " . $u->quote($v) . ")";
            $logprops->{$k} = $v;
        } else {
            $del_ids .= "," if $del_ids;
            $del_ids .= $prop->{'id'};
        }
    }

    $u->do("REPLACE INTO logprop2 (journalid, jitemid, propid, value) ".
           "VALUES $ins_values") if $ins_values;
    $u->do("DELETE FROM logprop2 WHERE journalid=? AND jitemid=? ".
           "AND propid IN ($del_ids)", undef, $u->{'userid'}, $jitemid) if $del_ids;

    LJ::MemCache::delete([$uid,"logprop:$uid:$jitemid"]) if $kill_mem;
}

# <LJFUNC>
# name: LJ::load_log_props2
# class:
# des:
# info:
# args: db?, uuserid, listref, hashref
# des-:
# returns:
# </LJFUNC>
sub load_log_props2
{
    my $db = isdb($_[0]) ? shift @_ : undef;

    my ($uuserid, $listref, $hashref) = @_;
    my $userid = want_userid($uuserid);
    return unless ref $hashref eq "HASH";

    my %needprops;
    my %needrc;
    my %rc;
    my @memkeys;
    foreach (@$listref) {
        my $id = $_+0;
        $needprops{$id} = 1;
        $needrc{$id} = 1;
        push @memkeys, [$userid, "logprop:$userid:$id"];
        push @memkeys, [$userid, "rp:$userid:$id"];
    }
    return unless %needprops || %needrc;

    my $mem = LJ::MemCache::get_multi(@memkeys) || {};
    while (my ($k, $v) = each %$mem) {
        next unless $k =~ /(\w+):(\d+):(\d+)/;
        if ($1 eq 'logprop') {
            next unless ref $v eq "HASH";
            delete $needprops{$3};
            $hashref->{$3} = $v;
        }
        if ($1 eq 'rp') {
            delete $needrc{$3};
            $rc{$3} = $v;
        }
    }

    foreach (keys %rc) {
        $hashref->{$_}{'replycount'} = $rc{$_};
    }

    return unless %needprops || %needrc;

    unless ($db) {
        my $u = LJ::load_userid($userid);
        $db = @LJ::MEMCACHE_SERVERS ? LJ::get_cluster_def_reader($u) :  LJ::get_cluster_reader($u);
        return unless $db;
    }

    if (%needprops) {
        LJ::load_props("log");
        my $in = join(",", keys %needprops);
        my $sth = $db->prepare("SELECT jitemid, propid, value FROM logprop2 ".
                                 "WHERE journalid=? AND jitemid IN ($in)");
        $sth->execute($userid);
        while (my ($jitemid, $propid, $value) = $sth->fetchrow_array) {
            $hashref->{$jitemid}->{$LJ::CACHE_PROPID{'log'}->{$propid}->{'name'}} = $value;
        }
        foreach my $id (keys %needprops) {
            LJ::MemCache::add([$userid,"logprop:$userid:$id"], $hashref->{$id} || {}); #7200
          }
    }

    if (%needrc) {
        my $in = join(",", keys %needrc);
        my $sth = $db->prepare("SELECT jitemid, replycount FROM log2 WHERE journalid=? AND jitemid IN ($in)");
        $sth->execute($userid);
        while (my ($jitemid, $rc) = $sth->fetchrow_array) {
            $hashref->{$jitemid}->{'replycount'} = $rc;
            LJ::MemCache::add([$userid, "rp:$userid:$jitemid"], $rc);
        }
    }


}

# <LJFUNC>
# name: LJ::delete_entry
# des: Deletes a user's journal entry
# args: uuserid, jitemid, quick?, anum?
# des-uuserid: Journal itemid or $u object of journal to delete entry from
# des-jitemid: Journal itemid of item to delete.
# des-quick: Optional boolean.  If set, only [dbtable[log2]] table
#            is deleted from and the rest of the content is deleted
#            later using [func[LJ::cmd_buffer_add]].
# des-anum: The log item's anum, which'll be needed to delete lazily
#           some data in tables which includes the anum, but the
#           log row will already be gone so we'll need to store it for later.
# returns: boolean; 1 on success, 0 on failure.
# </LJFUNC>
sub delete_entry
{
    my ($uuserid, $jitemid, $quick, $anum) = @_;
    my $jid = LJ::want_userid($uuserid);
    my $u = ref $uuserid ? $uuserid : LJ::load_userid($jid);
    $jitemid += 0;

    my $and = "";
    if (defined $anum) { $and = "AND anum=" . ($anum+0); }

    my $dc = $u->log2_do(undef, "DELETE FROM log2 WHERE journalid=$jid AND jitemid=$jitemid $and");
    return 0 unless $dc;
    LJ::MemCache::delete([$jid, "log2:$jid:$jitemid"]);
    LJ::MemCache::decr([$jid, "log2ct:$jid"]);
    LJ::memcache_kill($jid, "dayct");

    # delete tags
    LJ::Tags::delete_logtags($u, $jitemid);

    # if this is running the second time (started by the cmd buffer),
    # the log2 row will already be gone and we shouldn't check for it.
    if ($quick) {
        return 1 if $dc < 1;  # already deleted?
        return LJ::cmd_buffer_add($u->{clusterid}, $jid, "delitem", {
            'itemid' => $jitemid,
            'anum' => $anum,
        });
    }

    # delete from clusters
    foreach my $t (qw(logtext2 logprop2 logsec2)) {
        $u->do("DELETE FROM $t WHERE journalid=$jid AND jitemid=$jitemid");
    }
    $u->dudata_set('L', $jitemid, 0);

    # delete all comments
    LJ::Talk::delete_all_comments($u, 'L', $jitemid);

    # clean unused cache -
    LJ::MemCache::delete([$jid, "logtext:$u->{clusterid}:$jid:$jitemid"]);
    LJ::MemCache::delete([$jid, "logprop:$jid:$jitemid"]);
    LJ::MemCache::delete([$jid, "rss:$jid"]);

    return 1;
}

# <LJFUNC>
# name: LJ::mark_entry_as_spam
# class: web
# des: Copies an entry in a community into the global spamreports table
# args: journalu, jitemid
# des-journalu: User object of journal (community) entry was posted in.
# des-jitemid: ID of this entry.
# returns: 1 for success, 0 for failure
# </LJFUNC> 
sub mark_entry_as_spam {
    my ($journalu, $jitemid) = @_;
    $journalu = LJ::want_user($journalu);
    $jitemid += 0;
    return 0 unless $journalu && $jitemid;

    my $dbcr = LJ::get_cluster_def_reader($journalu);
    my $dbh = LJ::get_db_writer();
    return 0 unless $dbcr && $dbh;

    my $item = LJ::get_log2_row($journalu, $jitemid);
    return 0 unless $item;
  
    # step 1: get info we need
    my $logtext = LJ::get_logtext2($journalu, $jitemid);
    my ($subject, $body, $posterid) = ($logtext->{$jitemid}[0], $logtext->{$jitemid}[1], $item->{posterid});
    return 0 unless $body;

    # step 2: insert into spamreports
    $dbh->do('INSERT INTO spamreports (reporttime, posttime, journalid, posterid, subject, body, report_type) ' .
             'VALUES (UNIX_TIMESTAMP(), UNIX_TIMESTAMP(?), ?, ?, ?, ?, \'entry\')', 
              undef, $item->{logtime}, $journalu->{userid}, $posterid, $subject, $body);
  
    return 0 if $dbh->err;
    return 1;
}

# replycount_do
# input: $u, $jitemid, $action, $value
# action is one of: "init", "incr", "decr"
# $value is amount to incr/decr, 1 by default

sub replycount_do {
    my ($u, $jitemid, $action, $value) = @_;
    $value = 1 unless defined $value;
    my $uid = $u->{'userid'};
    my $memkey = [$uid, "rp:$uid:$jitemid"];

    # "init" is easiest and needs no lock (called before the entry is live)
    if ($action eq 'init') {
        LJ::MemCache::set($memkey, 0);
        return 1;
    }

    return 0 unless $action eq 'decr' || $action eq 'incr';
    return 0 unless $u->writer;


    if ($action eq 'decr') { $value = - $value; }

    $u->do("UPDATE log2 SET replycount=replycount+$value WHERE journalid=$uid AND jitemid=$jitemid");

    my $rc = $u->selectrow_array("SELECT replycount FROM log2 WHERE journalid=$uid AND jitemid=$jitemid");
    LJ::MemCache::set($memkey, $rc) if defined $rc;
    LJ::MemCache::delete("/comments/$jitemid/$uid");
    LJ::Talk::update_commentalter($u, $jitemid); # timestamp

    return 1;
}

# <LJFUNC>
# name: LJ::get_logtext2
# des: Efficiently retrieves a large number of journal entry text, trying first
#      slave database servers for recent items, then the master in
#      cases of old items the slaves have already disposed of.  See also:
#      [func[LJ::get_talktext2]].
# args: u, opts?, jitemid*
# returns: hashref with keys being jitemids, values being [ $subject, $body ]
# des-opts: Optional hashref of special options.  Currently only 'usemaster'
#           key is supported, which always returns a definitive copy,
#           and not from a cache or slave database.
# des-jitemid: List of jitemids to retrieve the subject & text for.
# </LJFUNC>
sub get_logtext2
{
    my $u = shift;
    my $clusterid = $u->{'clusterid'};
    my $journalid = $u->{'userid'}+0;

    my $opts = ref $_[0] ? shift : {};

    # return structure.
    my $lt = {};
    return $lt unless $clusterid;

    # keep track of itemids we still need to load.
    my %need;
    my @mem_keys;
    foreach (@_) {
        my $id = $_+0;
        $need{$id} = 1;
        push @mem_keys, [$journalid,"logtext:$clusterid:$journalid:$id"];
    }

    # pass 0: memory, avoiding databases
    unless ($opts->{'usemaster'}) {
        my $mem = LJ::MemCache::get_multi(@mem_keys) || {};
        while (my ($k, $v) = each %$mem) {
            next unless $v;
            $k =~ /:(\d+):(\d+):(\d+)/;
            delete $need{$3};
            $lt->{$3} = $v;
        }
    }

    return $lt unless %need;

    # pass 1 (slave) and pass 2 (master)
    foreach my $pass (1, 2) {
        next unless %need;
        next if $pass == 1 && $opts->{'usemaster'};
        my $db = $pass == 1 ? LJ::get_cluster_reader($clusterid) :
            LJ::get_cluster_def_reader($clusterid);
        next unless $db;

        my $jitemid_in = join(", ", keys %need);
        my $sth = $db->prepare("SELECT jitemid, subject, event FROM logtext2 ".
                               "WHERE journalid=$journalid AND jitemid IN ($jitemid_in)");
        $sth->execute;
        while (my ($id, $subject, $event) = $sth->fetchrow_array) {
            LJ::text_uncompress(\$event);
      
      unless ($opts->{'text-only'}) {
        LJR::Distributed::sign_imported_entry ($journalid, $id, \$event);
      }
      
            my $val = [ $subject, $event ];
            $lt->{$id} = $val;
            LJ::MemCache::add([$journalid,"logtext:$clusterid:$journalid:$id"], $val, 7200);
            delete $need{$id};
        }
    }
    return $lt;
}


# <LJFUNC>
# name: LJ::load_talk_props2
# des: Retrieves comments properties.
# info:
# args:
# des-:
# returns:
# </LJFUNC>
sub load_talk_props2
{
    my ($u, $listref, $hashref) = @_;
    my $userid = $u->{'userid'}+0;

    $hashref = {} unless ref $hashref eq "HASH";

    my %need;
    my @memkeys;
    foreach (@$listref) {
        my $id = $_+0;
        $need{$id} = 1;
        push @memkeys, [$userid,"talkprop:$userid:$id"];
    }
    return $hashref unless %need;

    my $mem = LJ::MemCache::get_multi(@memkeys) || {};
    while (my ($k, $v) = each %$mem) {
        next unless $k =~ /(\d+):(\d+)/ && ref $v eq "HASH";
        delete $need{$2};
        $hashref->{$2}->{$_[0]} = $_[1] while @_ = each %$v;
    }
    return $hashref unless %need;

    my $db;
    if (@LJ::MEMCACHE_SERVERS) {
        $db = @LJ::MEMCACHE_SERVERS ? LJ::get_cluster_def_reader($u) :  LJ::get_cluster_reader($u);
        return $hashref unless $db;
    }

    LJ::load_props("talk");
    my $in = join(',', keys %need);
    my $sth = $db->prepare("SELECT jtalkid, tpropid, value FROM talkprop2 ".
                           "WHERE journalid=? AND jtalkid IN ($in)");
    $sth->execute($userid);
    while (my ($jtalkid, $propid, $value) = $sth->fetchrow_array) {
        my $p = $LJ::CACHE_PROPID{'talk'}->{$propid};
        next unless $p;
        $hashref->{$jtalkid}->{$p->{'name'}} = $value;
    }
    foreach my $id (keys %need) {
        LJ::MemCache::add([$userid,"talkprop:$userid:$id"], $hashref->{$id} || {}, 3600);
    }
    return $hashref;
}


# <LJFUNC>
# name: LJ::get_talktext2
# des: Retrieves comments text. Tries slave servers first, then master.
# info: Efficiently retreives batches of comment text. Will try alternate
#       servers first. See also [func[LJ::get_logtext2]].
# returns: Hashref with the talkids as keys, values being [ $subject, $event ].
# args: u, opts?, jtalkids
# des-opts: A hashref of options. 'onlysubjects' will only retrieve subjects.
# des-jtalkids: A list of talkids to get text for.
# </LJFUNC>
sub get_talktext2
{
    my $u = shift;
    my $clusterid = $u->{'clusterid'};
    my $journalid = $u->{'userid'}+0;

    my $opts = ref $_[0] ? shift : {};

    # return structure.
    my $lt = {};
    return $lt unless $clusterid;

    # keep track of itemids we still need to load.
    my %need;
    my @mem_keys;
    foreach (@_) {
        my $id = $_+0;
        push @mem_keys, [$journalid,"talktext:$clusterid:$journalid:$id"];
    }

    # try the memory cache
    my $mem = LJ::MemCache::get_multi(@mem_keys) || {};
    foreach (@_) {
        my $id = $_+0;
        my $v = $mem->{"talktext:$clusterid:$journalid:$id"};
        if (defined $v) {
           $lt->{$id} = $v;
        } else {
           $need{$id} = 1;
        }
    }
    return $lt unless %need;

    # pass 1 (slave) and pass 2 (master)
    foreach my $pass (1, 2) {
        next unless %need;
        my $db = $pass == 1 ? LJ::get_cluster_reader($clusterid) :
            LJ::get_cluster_def_reader($clusterid);
        next unless $db;
        my $in = join(",", keys %need);
        my $sth = $db->prepare("SELECT jtalkid, subject, body FROM talktext2 ".
                               "WHERE journalid=$journalid AND jtalkid IN ($in)");
        $sth->execute;
        while (my ($id, $subject, $body) = $sth->fetchrow_array) {
            LJ::text_uncompress(\$body);
            $lt->{$id} = [ $subject, $body ];
            LJ::MemCache::add([$journalid,"talktext:$clusterid:$journalid:$id"], [$subject, $body], 3600);
            delete $need{$id};
        }
    }
    return $lt;
}


# <LJFUNC>
# name: LJ::item_link
# class: component
# des: Returns URL to view an individual journal item.
# info: The returned URL may have an ampersand in it.  In an HTML/XML attribute,
#       these must first be escaped by, say, [func[LJ::ehtml]].  This
#       function doesn't return it pre-escaped because the caller may
#       use it in, say, a plain-text email message.
# args: u, itemid, anum?
# des-itemid: Itemid of entry to link to.
# des-anum: If present, $u is assumed to be on a cluster and itemid is assumed
#           to not be a $ditemid already, and the $itemid will be turned into one
#           by multiplying by 256 and adding $anum.
# returns: scalar; unescaped URL string
# </LJFUNC>
sub item_link
{
    my ($u, $itemid, $anum, @args) = @_;
    my $ditemid = $itemid*256 + $anum;

    # XXX: should have an option of returning a url with escaped (&amp;)
    #      or non-escaped (&) arguments.  a new link object would be best.
    my $args = @args ? "?" . join("&amp;", @args) : "";
    return LJ::journal_base($u) . "/$ditemid.html$args";
}

# <LJFUNC>
# name: LJ::expand_embedded
# class:
# des:
# info:
# args:
# des-:
# returns:
# </LJFUNC>
sub expand_embedded
{
    &nodb;
    my ($u, $ditemid, $remote, $eventref, %opts) = @_;

    LJ::Poll::show_polls($ditemid, $remote, $eventref);
    LJ::EmbedModule->expand_entry($u, $eventref, %opts);
    LJ::run_hooks("expand_embedded", $u, $ditemid, $remote, $eventref, %opts);
}

# <LJFUNC>
# name: LJ::item_toutf8
# des: convert one item's subject, text and props to UTF8.
#      item can be an entry or a comment (in which cases props can be
#      left empty, since there are no 8bit talkprops).
# args: u, subject, text, props
# des-u: user hashref of the journal's owner
# des-subject: ref to the item's subject
# des-text: ref to the item's text
# des-props: hashref of the item's props
# returns: nothing.
# </LJFUNC>
sub item_toutf8
{
    my ($u, $subject, $text, $props) = @_;
    return unless $LJ::UNICODE;

    my $convert = sub {
        my $rtext = shift;
        my $error = 0;
        my $res = LJ::text_convert($$rtext, $u, \$error);
        if ($error) {
            LJ::text_out($rtext);
        } else {
            $$rtext = $res;
        };
        return;
    };

    $convert->($subject);
    $convert->($text);
    foreach(keys %$props) {
        $convert->(\$props->{$_});
    }
    return;
}


# Called from get_friend_items, get_recent_items, get_journal_item, few others.
#
# A single place to pickup text, props, tags, convert utf-8, and fill items' properies.
#    $items: arrayref;
#    $u: user object, or hashref of user objects by uid (= multiowner);
#    $opts fields:  multiowner, only_subject, props_only.
#
# TODO: should be optimized / rewtitten from scratch.
#
# Usage: fill_items_with_text_props(\@items, $u);
#        fill_items_with_text_props(\@friend_items, $opts->{'friends_u'}, {'multiowner' => 1});
#
sub fill_items_with_text_props {
    my ($items, $u, $opts) = @_;

    if ($opts->{'multiowner'}) { # $u - hashref of user objects by ownerid
        # required fields: ownerid, itemid

        my @ids;
        foreach (@$items) {
            push @ids,  [ $u->{$_->{'ownerid'}}->{'clusterid'}, $_->{'ownerid'}, $_->{'itemid'} ];
        }

        # load the text and props of the entries
        my $res = LJ::get_posts_raw({}, @ids); #key {text or prop}{"$ownerid:$itemid"}

        # load tags
        my $tags;
        $tags = LJ::Tags::get_logtagsmulti(\@ids); #key  "$ownerid:$itemid"

        foreach (@$items) {
            $_->{'text'} = $res->{text}{"$_->{'ownerid'}:$_->{'itemid'}"};
            $_->{'props'} = $res->{prop}{"$_->{'ownerid'}:$_->{'itemid'}"};

            if ($LJ::UNICODE && $_->{'props'}->{'unknown8bit'}) {
                # artefact, very very small fraction of old items affected
                LJ::item_toutf8($u->{$_->{'ownerid'}},
                                \$_->{'text'}->[0], \$_->{'text'}->[1], $_->{'props'});
                ###$_->{'props'}->{'unknown8bit'} = 0; #no change: memcache logtext,logprop always in sync with db
                print STDERR "Fixing item_toutf8 in friend_items $_->{'ownerid'} $_->{'itemid'} \n";
            }

            if ($tags) {
                # $taglist = [ split(/\s*,\s*/, $_->{'props'}->{taglist}) ]; #unknown8bit ? edittags?
                my @taglist =  values %{$tags->{"$_->{'ownerid'}:$_->{'itemid'}"}}; #$kwid => $kw
                @taglist = sort { $a cmp $b } @taglist;
                $_->{'props'}->{'tags'} = \@taglist;
            }
        }

    } else { #single owner: $u - user object
        # required fields: itemid

        my @ids;
        foreach (@$items) {
            push @ids,  [ $u->{'clusterid'}, $u->{'userid'}, $_->{'itemid'} ];
        }

        # load the text and props of the entries
        my $res;
        if ($opts->{'props_only'}) {
            $res = LJ::get_posts_raw({'prop_only' => 1}, @ids);
        } else {
            $res = LJ::get_posts_raw({}, @ids);
        }

        # load tags
        my $tags;
        $tags = LJ::Tags::get_logtagsmulti(\@ids) unless $opts->{'only_subject'} || $opts->{'props_only'};

        foreach (@$items) {
            $_->{'text'} = $res->{text}{"$u->{'userid'}:$_->{'itemid'}"};
            $_->{'props'} = $res->{prop}{"$u->{'userid'}:$_->{'itemid'}"};

            if ($LJ::UNICODE && $_->{'props'}->{'unknown8bit'} && $logtext) {
                # artefact, very very small fraction of old items affected
                LJ::item_toutf8($u,
                                \$_->{'text'}->[0], \$_->{'text'}->[1], $_->{'props'});
                ###$_->{'props'}->{'unknown8bit'} = 0; #no change: memcache logtext,logprop always in sync with db
                print STDERR "Fixing item_toutf8 in recent_items $u->{'userid'} $_->{'itemid'} \n";
            }

            if ($tags) {
                # $taglist = [ split(/\s*,\s*/, $_->{'props'}->{taglist}) ];
                my @taglist =  values %{$tags->{"$u->{'userid'}:$_->{'itemid'}"}}; #$kwid => $kw
                @taglist = sort { $a cmp $b } @taglist;
                $_->{'props'}->{'tags'} = \@taglist;
            }
        }
    }

    #foreach (@$items) {
        #TODO
        #my $subject = $_->{'text'}->[0];

        # see if we have a subject and clean it
        #if ($subject) {
        #    $subject =~ s/[\r\n]/ /g;
        #    LJ::CleanHTML::clean_subject_all(\$subject);
        #    $_->{'text'}->[0] = $subject;
        #}
    #}
}


1;
