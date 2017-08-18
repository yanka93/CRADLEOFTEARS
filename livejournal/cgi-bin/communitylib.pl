#!/usr/bin/perl

package LJ;

use strict;

# <LJFUNC>
# name: LJ::get_sent_invites
# des: Get a list of sent invitations from the past 30 days.
# args: cuserid
# des-cuserid: a userid or u object of the community to get sent invitations for
# returns: hashref of arrayrefs with keys userid, maintid, recvtime, status, args (itself
#   a hashref if what abilities the user would be given)
# </LJFUNC>
sub get_sent_invites {
    my $cu = shift;
    $cu = LJ::want_user($cu);
    return undef unless $cu;

    # now hit the database for their recent invites
    my $dbcr = LJ::get_cluster_def_reader($cu);
    return LJ::error('db') unless $dbcr;
    my $data = $dbcr->selectall_arrayref('SELECT userid, maintid, recvtime, status, args FROM invitesent ' .
                                         'WHERE commid = ? AND recvtime > UNIX_TIMESTAMP(DATE_SUB(NOW(), INTERVAL 30 DAY))',
                                          undef, $cu->{userid});

    # now break data down into usable format for caller
    my @res;
    foreach my $row (@{$data || []}) {
        my $temp = {};
        LJ::decode_url_string($row->[4], $temp);
        push @res, {
            userid => $row->[0]+0,
            maintid => $row->[1]+0,
            recvtime => $row->[2],
            status => $row->[3],
            args => $temp,
        };
    }

    # all done
    return \@res;    
}

# <LJFUNC>
# name: LJ::send_comm_invite
# des: Sends an invitation to a user to join a community with the passed abilities.
# args: uuserid, cuserid, muserid, attrs
# des-uuserid: a userid or u object of the user to invite
# des-cuserid: a userid or u object of the community to invite the user to
# des-muserid: a userid or u object of the maintainer doing the inviting
# des-attrs: a hashref of abilities this user should have (e.g. member, post, unmoderated, ...)
# returns: 1 for success, undef if failure
# </LJFUNC>
sub send_comm_invite {
    my ($u, $cu, $mu, $attrs) = @_;
    $u = LJ::want_user($u);
    $cu = LJ::want_user($cu);
    $mu = LJ::want_user($mu);
    return undef unless $u && $cu && $mu;

    # step 1: if the user has banned the community, don't accept the invite
    return LJ::error('comm_user_has_banned') if LJ::is_banned($cu, $u);

    # step 2: outstanding invite?
    my $dbcr = LJ::get_cluster_def_reader($u);
    return LJ::error('db') unless $dbcr;
    my $argstr = $dbcr->selectrow_array('SELECT args FROM inviterecv WHERE userid = ? AND commid = ? ' .
                                        'AND recvtime > UNIX_TIMESTAMP(DATE_SUB(NOW(), INTERVAL 30 DAY))',
                                        undef, $u->{userid}, $cu->{userid});

    # step 3: exceeded outstanding invitation limit?  only if no outstanding invite
    unless ($argstr) {
        my $cdbcr = LJ::get_cluster_def_reader($cu);
        return LJ::error('db') unless $cdbcr;
        my $count = $cdbcr->selectrow_array("SELECT COUNT(*) FROM invitesent WHERE commid = ? AND userid <> ? AND status = 'outstanding'",
                                            undef, $cu->{userid}, $u->{userid});
        my $fr = LJ::get_friends($cu) || {};
        my $max = int(scalar(keys %$fr) / 10); # can invite up to 1/10th of the community
        $max = 50 if $max < 50;                # or 50, whichever is greater
        return LJ::error('comm_invite_limit') if $count > $max;
    }
 
    # step 4: setup arg string as url-encoded string
    my $newargstr = join('=1&', map { LJ::eurl($_) } @$attrs) . '=1';
    
    # step 5: delete old stuff (lazy cleaning of invite tables)
    return LJ::error('db') unless $u->writer;
    $u->do('DELETE FROM inviterecv WHERE userid = ? AND ' .
           'recvtime < UNIX_TIMESTAMP(DATE_SUB(NOW(), INTERVAL 30 DAY))',
           undef, $u->{userid});

    return LJ::error('db') unless $cu->writer;
    $cu->do('DELETE FROM invitesent WHERE commid = ? AND ' .
            'recvtime < UNIX_TIMESTAMP(DATE_SUB(NOW(), INTERVAL 30 DAY))',
            undef, $cu->{userid});

    # step 6: branch here to update or insert
    if ($argstr) {
        # merely an update, so just do it quietly
        $u->do("UPDATE inviterecv SET args = ? WHERE userid = ? AND commid = ?",
               undef, $newargstr, $u->{userid}, $cu->{userid});

        $cu->do("UPDATE invitesent SET args = ?, status = 'outstanding' WHERE userid = ? AND commid = ?",
                undef, $newargstr, $cu->{userid}, $u->{userid});
    } else {
         # insert new data, as this is a new invite
         $u->do("INSERT INTO inviterecv VALUES (?, ?, ?, UNIX_TIMESTAMP(), ?)",
                undef, $u->{userid}, $cu->{userid}, $mu->{userid}, $newargstr);

         $cu->do("REPLACE INTO invitesent VALUES (?, ?, ?, UNIX_TIMESTAMP(), 'outstanding', ?)",
                 undef, $cu->{userid}, $u->{userid}, $mu->{userid}, $newargstr);
    }

    # step 7: error check database work
    return LJ::error('db') if $u->err || $cu->err;

    # success
    return 1;
}

# <LJFUNC>
# name: LJ::accept_comm_invite
# des: Accepts an invitation a user has received.  This does all the work to make the
#   user join the community as well as sets up privileges.
# args: uuserid, cuserid
# des-uuserid: a userid or u object of the user to get pending invites for
# des-cuserid: a userid or u object of the community to reject the invitation from
# returns: 1 for success, undef if failure
# </LJFUNC>
sub accept_comm_invite {
    my ($u, $cu) = @_;
    $u = LJ::want_user($u);
    $cu = LJ::want_user($cu);
    return undef unless $u && $cu;

    # get their invite to make sure they have one
    my $dbcr = LJ::get_cluster_def_reader($u);
    return LJ::error('db') unless $dbcr;
    my $argstr = $dbcr->selectrow_array('SELECT args FROM inviterecv WHERE userid = ? AND commid = ? ' .
                                        'AND recvtime > UNIX_TIMESTAMP(DATE_SUB(NOW(), INTERVAL 30 DAY))',
                                        undef, $u->{userid}, $cu->{userid});
    return undef unless $argstr;

    # decode to find out what they get
    my $args = {};
    LJ::decode_url_string($argstr, $args);

    # valid invite.  let's accept it as far as the community listing us goes.
    # 0, 0 means don't add comm to user's friends list, and don't auto-add P edge.
    LJ::join_community($u, $cu, 0, 0) if $args->{member};
    
    # now grant necessary abilities
    my %edgelist = (
        post => 'P',
        preapprove => 'N',
        moderate => 'M',
        admin => 'A',
    );
    foreach (keys %edgelist) {
        LJ::set_rel($cu->{userid}, $u->{userid}, $edgelist{$_}) if $args->{$_};
    }

    # now we can delete the invite and update the status on the other side
    return LJ::error('db') unless $u->writer;
    $u->do("DELETE FROM inviterecv WHERE userid = ? AND commid = ?",
           undef, $u->{userid}, $cu->{userid});

    return LJ::error('db') unless $cu->writer;
    $cu->do("UPDATE invitesent SET status = 'accepted' WHERE commid = ? AND userid = ?",
            undef, $cu->{userid}, $u->{userid});

    # done
    return 1;
}

# <LJFUNC>
# name: LJ::reject_comm_invite
# des: Rejects an invitation a user has received.
# args: uuserid, cuserid
# des-uuserid: a userid or u object of the user to get pending invites for
# des-cuserid: a userid or u object of the community to reject the invitation from
# returns: 1 for success, undef if failure
# </LJFUNC>
sub reject_comm_invite {
    my ($u, $cu) = @_;
    $u = LJ::want_user($u);
    $cu = LJ::want_user($cu);
    return undef unless $u && $cu;

    # get their invite to make sure they have one
    my $dbcr = LJ::get_cluster_def_reader($u);
    return LJ::error('db') unless $dbcr;
    my $test = $dbcr->selectrow_array('SELECT userid FROM inviterecv WHERE userid = ? AND commid = ? ' .
                                      'AND recvtime > UNIX_TIMESTAMP(DATE_SUB(NOW(), INTERVAL 30 DAY))',
                                      undef, $u->{userid}, $cu->{userid});
    return undef unless $test;

    # now just reject it
    return LJ::error('db') unless $u->writer;
    $u->do("DELETE FROM inviterecv WHERE userid = ? AND commid = ?",
              undef, $u->{userid}, $cu->{userid});

    return LJ::error('db') unless $cu->writer;
    $cu->do("UPDATE invitesent SET status = 'rejected' WHERE commid = ? AND userid = ?",
            undef, $cu->{userid}, $u->{userid});

    # done
    return 1;
}

# <LJFUNC>
# name: LJ::get_pending_invites
# des: Gets a list of pending invitations for a user to join a community.
# args: uuserid
# des-uuserid: a userid or u object of the user to get pending invites for
# returns: [ [ commid, maintainerid, time, args(url encoded) ], [ ... ], ... ] or
#   undef if failure
# </LJFUNC>
sub get_pending_invites {
    my $u = shift;
    $u = LJ::want_user($u);
    return undef unless $u;

    # hit up database for invites and return them
    my $dbcr = LJ::get_cluster_def_reader($u);
    return LJ::error('db') unless $dbcr;
    my $pending = $dbcr->selectall_arrayref('SELECT commid, maintid, recvtime, args FROM inviterecv WHERE userid = ? ' .
                                            'AND recvtime > UNIX_TIMESTAMP(DATE_SUB(NOW(), INTERVAL 30 DAY))', 
                                            undef, $u->{userid});
    return undef if $dbcr->err;
    return $pending;
}

# <LJFUNC>
# name: LJ::leave_community
# des: Makes a user leave a community.  Takes care of all reluser and friend stuff.
# args: uuserid, ucommid, defriend
# des-uuserid: a userid or u object of the user doing the leaving
# des-ucommid: a userid or u object of the community being left
# des-defriend: remove comm from user's friends list
# returns: 1 if success, undef if error of some sort (ucommid not a comm, uuserid not in
#   comm, db error, etc)
# </LJFUNC>
sub leave_community {
    my ($uuid, $ucid, $defriend) = @_;
    my $u = LJ::want_user($uuid);
    my $cu = LJ::want_user($ucid);
    $defriend = $defriend ? 1 : 0;
    return LJ::error('comm_not_found') unless $u && $cu;

    # defriend comm -> user
    return LJ::error('comm_not_comm') unless $cu->{journaltype} =~ /[CS]/;
    my $ret = LJ::remove_friend($cu->{userid}, $u->{userid});
    return LJ::error('comm_not_member') unless $ret; # $ret = number of rows deleted, should be 1 if the user was in the comm

    # clear edges that effect this relationship
    foreach my $edge (qw(P N A M)) {
        LJ::clear_rel($cu->{userid}, $u->{userid}, $edge);
    }

    # defriend user -> comm?
    return 1 unless $defriend;
    LJ::remove_friend($u, $cu);

    # don't care if we failed the removal of comm from user's friends list...
    return 1;
}

# <LJFUNC>
# name: LJ::join_community
# des: Makes a user join a community.  Takes care of all reluser and friend stuff.
# args: uuserid, ucommid, friend?, noauto?
# des-uuserid: a userid or u object of the user doing the joining
# des-ucommid: a userid or u object of the community being joined
# des-friend: 1 to add this comm to user's friends list, else not
# des-noauto: if defined, 1 adds P edge, 0 does not; else, base on community postlevel
# returns: 1 if success, undef if error of some sort (ucommid not a comm, uuserid already in
#   comm, db error, etc)
# </LJFUNC>
sub join_community {
    my ($uuid, $ucid, $friend, $canpost) = @_;
    my $u = LJ::want_user($uuid);
    my $cu = LJ::want_user($ucid);
    $friend = $friend ? 1 : 0;
    return LJ::error('comm_not_found') unless $u && $cu;
    return LJ::error('comm_not_comm') unless $cu->{journaltype} eq 'C';

    # friend comm -> user
    LJ::add_friend($cu->{userid}, $u->{userid});

    # add edges that effect this relationship... if the user sent a fourth
    # argument, use that as a bool.  else, load commrow and use the postlevel.
    my $addpostacc = 0;
    if (defined $canpost) {
        $addpostacc = $canpost ? 1 : 0;
    } else {
        my $crow = LJ::get_community_row($cu);
        $addpostacc = $crow->{postlevel} eq 'members' ? 1 : 0;
    }
    LJ::set_rel($cu->{userid}, $u->{userid}, 'P') if $addpostacc;

    # friend user -> comm?
    return 1 unless $friend;
    LJ::add_friend($u->{userid}, $cu->{userid}, { defaultview => 1 });

    # done
    return 1;
}

# <LJFUNC>
# name: LJ::get_community_row
# des: Gets data relevant to a community such as their membership level and posting access.
# args: ucommid
# des-ucommid: a userid or u object of the community
# returns: a hashref with user, userid, name, membership, and postlevel data from the
#   user and community tables; undef if error
# </LJFUNC>
sub get_community_row {
    my $ucid = shift;
    my $cu = LJ::want_user($ucid);
    return unless $cu;

    # hit up database
    my $dbr = LJ::get_db_reader();
    my ($membership, $postlevel) = 
        $dbr->selectrow_array('SELECT membership, postlevel FROM community WHERE userid=?',
                              undef, $cu->{userid});
    return if $dbr->err;
    return unless $membership && $postlevel;

    # return result hashref
    my $row = {
        user => $cu->{user},
        userid => $cu->{userid},
        name => $cu->{name},
        membership => $membership,
        postlevel => $postlevel,
    };
    return $row;
}

# <LJFUNC>
# name: LJ::get_pending_members
# des: Gets a list of userids for people that have requested to be added to a community
#   but haven't yet actually been approved or rejected.
# args: comm
# des-comm: a userid or u object of the community to get pending members of
# returns: an arrayref of userids of people with pending membership requests
# </LJFUNC>
sub get_pending_members {
    my $comm = shift;
    my $cu = LJ::want_user($comm);
    
    # database request
    my $dbr = LJ::get_db_reader();
    my $args = $dbr->selectcol_arrayref('SELECT arg1 FROM authactions WHERE userid = ? ' .
                                        "AND action = 'comm_join_request' AND used = 'N'",
                                        undef, $cu->{userid}) || [];

    # parse out the args
    my @list;
    foreach (@$args) {
        push @list, $1+0 if $_ =~ /^targetid=(\d+)$/;
    }
    return \@list;
}

# <LJFUNC>
# name: LJ::approve_pending_member
# des: Approves someone's request to join a community.  This updates the authactions table
#   as appropriate as well as does the regular join logic.  This also generates an email to
#   be sent to the user notifying them of the acceptance.
# args: commid, userid
# des-commid: userid of the community
# des-userid: userid of the user doing the join
# returns: 1 on success, 0/undef on error
# </LJFUNC>
sub approve_pending_member {
    my ($commid, $userid) = @_;
    my $cu = LJ::want_user($commid);
    my $u = LJ::want_user($userid);
    return unless $cu && $u;

    # step 1, update authactions table
    my $dbh = LJ::get_db_writer();
    my $count = $dbh->do("UPDATE authactions SET used = 'Y' WHERE userid = ? AND arg1 = ?",
                         undef, $cu->{userid}, "targetid=$u->{userid}");
    return unless $count;

    # step 2, make user join the community
    return unless LJ::join_community($u->{userid}, $cu->{userid});

    # step 3, email the user
    my $email = "Dear $u->{name},\n\n" .
                "Your request to join the \"$cu->{user}\" community has been approved.  If you " .
                "wish to add this community to your friends page reading list, click the link below.\n\n" .
                "\t$LJ::SITEROOT/friends/add.bml?user=$cu->{user}\n\n" .
                "Regards,\n$LJ::SITENAME Team";
    LJ::send_mail({
        to => $u->{email},
        from => $LJ::COMMUNITY_EMAIL,
        fromname => $LJ::SITENAME,
        charset => 'utf-8',
        subject => "Your Request to Join $cu->{user}",
        body => $email,
    });
    return 1;
}

# <LJFUNC>
# name: LJ::reject_pending_member
# des: Rejects someone's request to join a community.  Updates authactions and generates
#   an email to the user.
# args: commid, userid
# des-commid: userid of the community
# des-userid: userid of the user doing the join
# returns: 1 on success, 0/undef on error
# </LJFUNC>
sub reject_pending_member {
    my ($commid, $userid) = @_;
    my $cu = LJ::want_user($commid);
    my $u = LJ::want_user($userid);
    return unless $cu && $u;

    # step 1, update authactions table
    my $dbh = LJ::get_db_writer();
    my $count = $dbh->do("UPDATE authactions SET used = 'Y' WHERE userid = ? AND arg1 = ?",
                         undef, $cu->{userid}, "targetid=$u->{userid}");
    return unless $count;

    # step 2, email the user
    my $email = "Dear $u->{name},\n\n" .
                "Your request to join the \"$cu->{user}\" community has been declined.  You " .
                "may wish to contact the maintainer(s) of this community if you are still " .
                "interested in joining.\n\n" .
                "Regards,\n$LJ::SITENAME Team";
    LJ::send_mail({
        to => $u->{email},
        from => $LJ::COMMUNITY_EMAIL,
        fromname => $LJ::SITENAME,
        charset => 'utf-8',
        subject => "Your Request to Join $cu->{user}",
        body => $email,
    });
    return 1;
}

# <LJFUNC>
# name: LJ::comm_join_request
# des: Registers an authaction to add a user to a
#      community and sends an approval email to the maintainers
# returns: Hashref; output of LJ::register_authaction()
#          includes datecreate of old row if no new row was created
# args: comm, u
# des-comm: Community user object
# des-u: User object to add to community
# </LJFUNC>
sub comm_join_request {
    my ($comm, $u) = @_;
    return undef unless ref $comm && ref $u;

    my $arg = "targetid=$u->{userid}";
    my $dbh = LJ::get_db_writer();

    # check for duplicates within the same hour (to prevent spamming)
    my $oldaa = $dbh->selectrow_hashref("SELECT aaid, authcode, datecreate FROM authactions " .
                                        "WHERE userid=? AND arg1=? " .
                                        "AND action='comm_join_request' AND used='N' " .
                                        "AND NOW() < datecreate + INTERVAL 1 HOUR " .
                                        "ORDER BY 1 DESC LIMIT 1",
                                        undef, $comm->{'userid'}, $arg);
    return $oldaa if $oldaa;

    # insert authactions row
    my $aa = LJ::register_authaction($comm->{'userid'}, 'comm_join_request', $arg);
    return undef unless $aa;

    # if there are older duplicates, invalidate any existing unused authactions of this type
    $dbh->do("UPDATE authactions SET used='Y' WHERE userid=? AND aaid<>? AND arg1=? " .
             "AND action='comm_invite' AND used='N'",
             undef, $comm->{'userid'}, $aa->{'aaid'}, $arg);

    # get maintainers of community
    my $adminids = LJ::load_rel_user($comm->{userid}, 'A') || [];
    my $admins = LJ::load_userids(@$adminids);

    # now prepare the emails
    my %dests;
    my $cuser = $comm->{user};
    foreach my $au (values %$admins) {
        next if $dests{$au->{email}}++;
        LJ::load_user_props($au, 'opt_communityjoinemail');
        next if $au->{opt_communityjoinemail} =~ /[DN]/; # Daily, None
        
        my $body = "Dear $au->{name},\n\n" .
                   "The user \"$u->{user}\" has requested to join the \"$cuser\" community.  If you wish " .
                   "to add this user to your community, please click this link:\n\n" .
                   "\t$LJ::SITEROOT/approve/$aa->{aaid}.$aa->{authcode}\n\n" .
                   "Alternately, to approve or reject all outstanding membership requests at the same time, " .
                   "visit the community member management page:\n\n" .
                   "\t$LJ::SITEROOT/community/pending.bml?comm=$cuser\n\n" .
                   "You may also ignore this e-mail.  The request to join will expire after a period of 30 days.\n\n" .
                   "If you wish to no longer receive these e-mails, visit the community management page and " .
                   "set the relevant options:\n\n\t$LJ::SITEROOT/community/manage.bml\n\n" .
                   "Regards,\n$LJ::SITENAME Team\n";

        LJ::send_mail({
            to => $au->{email},
            from => $LJ::COMMUNITY_EMAIL,
            fromname => $LJ::SITENAME,
            charset => 'utf-8',
            subject => "$cuser Membership Request by $u->{user}",
            body => $body,
            wrap => 76,
        });
    }

    return $aa;
}

1;
