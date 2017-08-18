#!/usr/bin/perl
#
# <LJDEP>
# link: htdocs/userinfo.bml, htdocs/go.bml, htdocs/tools/memadd.bml, htdocs/editjournal.bml
# link: htdocs/tools/tellafriend.bml
# img: htdocs/img/btn_prev.gif, htdocs/img/memadd.gif, htdocs/img/btn_edit.gif
# img: htdocs/img/btn_next.gif, htdocs/img/btn_tellafriend.gif
# </LJDEP>

use strict;
package LJ::Talk;

# dataversion for rate limit logging
our $RATE_DATAVER = "1";

sub get_subjecticons
{
    my %subjecticon;
    $subjecticon{'types'} = [ 'sm', 'md' ];
    $subjecticon{'lists'}->{'md'} = [
            { img => "md01_alien.gif",    w => 32,  h => 32 },
            { img => "md02_skull.gif",    w => 32,  h => 32 },
            { img => "md05_sick.gif",   w => 25,  h => 25 },
            { img => "md06_radioactive.gif",  w => 20,  h => 20 },
            { img => "md07_cool.gif",   w => 20,  h => 20 },
            { img => "md08_bulb.gif",   w => 17,  h => 23 },
            { img => "md09_thumbdown.gif",  w => 25,  h => 19 },
            { img => "md10_thumbup.gif",  w => 25,  h => 19 }
    ];
    $subjecticon{'lists'}->{'sm'} = [
            { img => "sm01_smiley.gif",   w => 15,  h => 15 },
            { img => "sm02_wink.gif",   w => 15,  h => 15 },
            { img => "sm03_blush.gif",    w => 15,  h => 15 },
            { img => "sm04_shock.gif",    w => 15,  h => 15 },
            { img => "sm05_sad.gif",    w => 15,  h => 15 },
            { img => "sm06_angry.gif",    w => 15,  h => 15 },
            { img => "sm07_check.gif",    w => 15,  h => 15 },
            { img => "sm08_star.gif",   w => 20,  h => 18 },
            { img => "sm09_mail.gif",   w => 14,  h => 10 },
            { img => "sm10_eyes.gif",   w => 24,  h => 12 }
    ];

    # assemble ->{'id'} portion of hash.  the part of the imagename before the _
    foreach (keys %{$subjecticon{'lists'}}) {
            foreach my $pic (@{$subjecticon{'lists'}->{$_}}) {
            next unless ($pic->{'img'} =~ /^(\D{2}\d{2})\_.+$/);
            $subjecticon{'pic'}->{$1} = $pic;
            $pic->{'id'} = $1;
            }
    }

    return \%subjecticon;
}

# entryid-commentid-emailrecipientpassword hash
sub ecphash {
    my ($itemid, $talkid, $password) = @_;
    return "ecph-" . Digest::MD5::md5_hex($itemid . $talkid . $password);
}

# Returns talkurl with GET args added (don't pass #anchors to this :-)
sub talkargs {
    my $talkurl = shift;
    my $args = join("&", grep {$_} @_);
    my $sep;
    $sep = ($talkurl =~ /\?/ ? "&" : "?") if $args;
    return "$talkurl$sep$args";
}

# Returns HTML to display an image, given the image id as an argument.
sub show_image
{
    my $pics = shift;
    my $id = shift;
    my $extra = shift;
    return unless defined $pics->{'pic'}->{$id};
    my $p = $pics->{'pic'}->{$id};
    my $pfx = "$LJ::IMGPREFIX/talk";
    return "<img src='$pfx/$p->{'img'}' border='0' ".
        "width='$p->{'w'}' height='$p->{'h'}' valign='middle' $extra />";
}

# Returns 'none' icon.
sub show_none_image
{
    my $extra = shift;
    my $img = 'none.gif';
    my $w = 15;
    my $h = 15;
    my $pfx = "$LJ::IMGPREFIX/talk";
    return "<img src='$pfx/$img' border='0' ".
        "width='$w' height='$h' valign='middle' $extra />";
}

sub link_bar
{
    my $opts = shift;
    my ($u, $up, $remote, $headref, $itemid) = 
        map { $opts->{$_} } qw(u up remote headref itemid);
    my $ret;

    my @linkele;
    
    my $mlink = sub {
        my ($url, $piccode) = @_;
        return ("<a href=\"$url\">" . 
                LJ::img($piccode, "", { 'align' => 'absmiddle' }) .
                "</a>");
    };

    my $jarg = "journal=$u->{'user'}&";
    my $jargent = "journal=$u->{'user'}&amp;";

    # << Previous
    push @linkele, $mlink->("/go.bml?${jargent}itemid=$itemid&amp;dir=prev", "prev_entry");
    $$headref .= "<link href='/go.bml?${jargent}itemid=$itemid&amp;dir=prev' rel='Previous' />\n";
    
    # memories
    unless ($LJ::DISABLED{'memories'}) {
        push @linkele, $mlink->("/tools/memadd.bml?${jargent}itemid=$itemid", "memadd");
    }
    
    if (defined $remote && ($remote->{'user'} eq $u->{'user'} ||
                            $remote->{'user'} eq $up->{'user'} || 
                            LJ::can_manage($remote, $u)))
    {
        push @linkele, $mlink->("/editjournal.bml?${jargent}itemid=$itemid", "editentry");
    }

    unless ($LJ::DISABLED{tags}) {
        if (defined $remote && LJ::Tags::can_add_tags($u, $remote)) {
            push @linkele, $mlink->("/edittags.bml?${jargent}itemid=$itemid", "edittags");
        }
    }
    
    unless ($LJ::DISABLED{'tellafriend'}) {
        push @linkele, $mlink->("/tools/tellafriend.bml?${jargent}itemid=$itemid", "tellfriend");
    }
    
    ## >>> Next
    push @linkele, $mlink->("/go.bml?${jargent}itemid=$itemid&amp;dir=next", "next_entry");
    $$headref .= "<link href='/go.bml?${jargent}itemid=$itemid&amp;dir=next' rel='Next' />\n";
    
    if (@linkele) {
        $ret .= BML::fill_template("standout", {
            'DATA' => "<table><tr><td valign='middle'>" .
                join("&nbsp;&nbsp;", @linkele) . 
                "</td></tr></table>",
            });
    }

    return $ret;
}

sub init 
{
    my ($form) = @_;
    my $init = {};  # structure to return

    my $journal = $form->{'journal'};
    my $ju = undef;
    my $item = undef;        # hashref; journal item conversation is in

    # defaults, to be changed later:
    $init->{'itemid'} = $form->{'itemid'}+0;
    $init->{'ditemid'} = $init->{'itemid'};
    $init->{'thread'} = $form->{'thread'}+0;
    $init->{'dthread'} = $init->{'thread'};
    $init->{'clustered'} = 0;
    $init->{'replyto'} = $form->{'replyto'}+0;
    $init->{'style'} = $form->{'style'} ? "mine" : undef;
    
    if ($journal) {
        # they specified a journal argument, which indicates new style.
        $ju = LJ::load_user($journal);
        return { 'error' => BML::ml('talk.error.nosuchjournal')} unless $ju;
        return { 'error' => BML::ml('talk.error.bogusargs')} unless $ju->{'clusterid'};
        $init->{'clustered'} = 1;
        foreach (qw(itemid replyto)) {
            next unless $init->{$_};
            $init->{'anum'} = $init->{$_} % 256;
            $init->{$_} = int($init->{$_} / 256);
            last;
        }
        $init->{'thread'} = int($init->{'thread'} / 256)
            if $init->{'thread'};
    } else {
        # perhaps it's an old URL for a user that's since been clustered.
        # look up the itemid and see what user it belongs to.
        if ($form->{'itemid'}) {
            my $itemid = $form->{'itemid'}+0;
            my $newinfo = LJ::get_newids('L', $itemid);
            if ($newinfo) {
                $ju = LJ::load_userid($newinfo->[0]);
                return { 'error' => BML::ml('talk.error.nosuchjournal')} unless $ju;
                $init->{'clustered'} = 1;
                $init->{'itemid'} = $newinfo->[1];
                $init->{'oldurl'} = 1;
                if ($form->{'thread'}) {
                    my $tinfo = LJ::get_newids('T', $init->{'thread'});
                    $init->{'thread'} = $tinfo->[1] if $tinfo;
                }
            } else {
                return { 'error' => BML::ml('talk.error.noentry') };
            }
        } elsif ($form->{'replyto'}) {
            my $replyto = $form->{'replyto'}+0;
            my $newinfo = LJ::get_newids('T', $replyto);
            if ($newinfo) {
                $ju = LJ::load_userid($newinfo->[0]);
                return { 'error' => BML::ml('talk.error.nosuchjournal')} unless $ju;
                $init->{'replyto'} = $newinfo->[1];
                $init->{'oldurl'} = 1;
            } else {
                return { 'error' => BML::ml('talk.error.noentry') };
            }
        }
    }

    $init->{'journalu'} = $ju;
    return $init;
}

# $u, $itemid
sub get_journal_item
{
    my ($u, $itemid, $props_only) = @_;
    return unless $u && $itemid;

    $itemid += 0;

    my $item = LJ::get_log2_row($u, $itemid);
    return undef unless $item;

    $item->{'alldatepart'} = LJ::alldatepart_s2($item->{'eventtime'});
    
    $item->{'itemid'} = $item->{'jitemid'};    # support old & new keys
    $item->{'ownerid'} = $item->{'journalid'}; # support old & new keys

    if ($props_only) {
        LJ::fill_items_with_text_props([$item], $u, {'props_only' => 1});
        return $item;
    }

    LJ::fill_items_with_text_props([$item], $u);

    $item->{'subject'} = $item->{'text'}->[0];
    $item->{'event'}   = $item->{'text'}->[1];

    return $item;
}

sub check_viewable
{
    my ($remote, $item, $form, $errref) = @_;
    # note $form no longer used
    
    my $err = sub {
        $$errref = "<?h1 <?_ml Error _ml?> h1?><?p $_[0] p?>";
        return 0;
    };

    unless (LJ::can_view($remote, $item)) {
        return $err->(BML::ml('talk.error.mustlogin'))
            unless defined $remote;
        return $err->(BML::ml('talk.error.notauthorised'));
    }

    return 1;
}

# <LJFUNC>
# name: LJ::Talk::can_delete
# des: Determines if a user can delete a comment or entry.  Basically, you can
#       delete anything you've posted.  You can delete anything posted in something
#       you own (i.e. a comment in your journal, a comment to an entry you made in
#       a community).  You can also delete any item in an account you have the
#       "A"dministration edge for.
# args: remote, u, up, userpost
# des-remote: User object we're checking access of.  From LJ::get_remote.
# des-u: Username or object of the account the thing is located in.
# des-up: Username or object of person who owns the parent of the thing.  (I.e. the poster
#           of the entry a comment is in.)
# des-userpost: Username (NOT object) of person who posted the item.
# returns: Boolean indicating whether remote is allowed to delete the thing
#           specified by the other options.
# </LJFUNC>
sub can_delete {
    my ($remote, $u, $up, $userpost) = @_; # remote, journal, posting user, commenting user
    return 0 unless $remote;
    return 1 if $remote->{'user'} eq $userpost ||
                $remote->{'user'} eq (ref $u ? $u->{'user'} : $u) ||
                $remote->{'user'} eq (ref $up ? $up->{'user'} : $up) ||
                LJ::can_manage($remote, $u);
    return 0;
}

sub can_screen {
    my ($remote, $u, $up, $userpost) = @_;
    return 0 unless $remote;
    return 1 if $remote->{'user'} eq $u->{'user'} ||
                $remote->{'user'} eq (ref $up ? $up->{'user'} : $up) ||
                LJ::can_manage($remote, $u);
    return 0;
}

sub can_unscreen {
    return LJ::Talk::can_screen(@_);
}

sub can_view_screened {
    return LJ::Talk::can_delete(@_);
}

sub can_freeze {
    return LJ::Talk::can_screen(@_);
}

sub can_unfreeze {
    return LJ::Talk::can_unscreen(@_);
}

# <LJFUNC>
# name: LJ::Talk::screening_level
# des: Determines the screening level of a particular post given the relevent information.
# args: journalu, jitemid
# des-journalu: User object of the journal the post is in.
# des-jitemid: Itemid of the post.
# returns: Single character that indicates the screening level.  Undef means don't screen
#       anything, 'A' means screen All, 'R' means screen Anonymous (no-remotes), 'F' means
#       screen non-friends.
# </LJFUNC>
sub screening_level {
    my ($journalu, $jitemid) = @_;
    die 'LJ::screening_level needs a user object.' unless ref $journalu;
    $jitemid += 0;
    die 'LJ::screening_level passed invalid jitemid.' unless $jitemid;
    
    # load the logprops for this entry
    my %props;
    LJ::load_log_props2($journalu->{userid}, [ $jitemid ], \%props);

    # determine if userprop was overriden
    my $val = $props{$jitemid}{opt_screening};
    return if $val eq 'N'; # N means None, so return undef
    return $val if $val;

    # now return userprop, as it's our last chance
    LJ::load_user_props($journalu, 'opt_whoscreened');
    return if $journalu->{opt_whoscreened} eq 'N';
    return $journalu->{opt_whoscreened};
}

sub update_commentalter {
    my ($u, $itemid) = @_;
    LJ::set_logprop($u, $itemid, { 'commentalter' => time() });
}

sub update_screenedcommentalter {
    my ($u, $itemid) = @_;
    LJ::set_logprop($u, $itemid, { 'screenedcommentalter' => time() }); #we decoupled screenedcommentalter from commentalter on 14 Nov 2010; screenedcommentalter added to  logproplist db.
}

# <LJFUNC>
# name: LJ::Talk::get_comments_in_thread
# class: web
# des: Gets a list of comment ids that are contained within a thread, including the
#   comment at the top of the thread.  You can also limit this to only return comments
#   of a certain state.
# args: u, jitemid, jtalkid, onlystate, screenedref
# des-u: user object of user to get comments from
# des-jitemid: journal itemid to get comments from
# des-jtalkid: journal talkid of comment to use as top of tree
# des-onlystate: if specified, return only comments of this state (e.g. A, F, S...)
# returns: undef on error, array reference of jtalkids on success
# </LJFUNC>
sub get_comments_in_thread {
    my ($u, $jitemid, $jtalkid, $onlystate) = @_;
    $u = LJ::want_user($u);
    $jitemid += 0;
    $jtalkid += 0;
    $onlystate = uc $onlystate;
    return undef unless $u && $jitemid && $jtalkid && 
                        (!$onlystate || $onlystate =~ /^\w$/);

    # get all comments to post
    my $comments = LJ::Talk::get_talk_data($u, 'L', $jitemid) || {};

    # see if our comment exists
    return undef unless $comments->{$jtalkid};

    # create relationship hashref and count screened comments in post
    my %parentids;
    $parentids{$_} = $comments->{$_}{parenttalkid} foreach keys %$comments;

    # now walk and find what to update
    my %to_act;
    foreach my $id (keys %$comments) {
        my $act = ($id == $jtalkid);
        my $walk = $id;
        while ($parentids{$walk}) {
            if ($parentids{$walk} == $jtalkid) {
                # we hit the one we want to act on
                $act = 1;
                last;
            }
            last if $parentids{$walk} == $walk;

            # no match, so move up a level
            $walk = $parentids{$walk};
        }

        # set it as being acted on
        $to_act{$id} = 1 if $act && (!$onlystate || $comments->{$id}{state} eq $onlystate);
    }

    # return list from %to_act
    return [ keys %to_act ];
}


# <LJFUNC>
# name: LJ::Talk::delete_all_comments
# des: deletes all comments from a post, permanently, for when a post is deleted
# info: The tables [dbtable[talk2]], [dbtable[talkprop2]], [dbtable[talktext2]],
#       are deleted from, immediately.
# args: u, nodetype, nodeid (=jitemid)
# des-nodetype: The thread nodetype (probably 'L' for log items)
# des-nodeid: The thread nodeid for the given nodetype (probably the jitemid from the log2 row)
# returns: boolean; success value
# </LJFUNC>
sub delete_all_comments {
    my ($u, $nodetype, $jitemid) = @_;

    my $dbcm = LJ::get_cluster_master($u);
    return 0 unless $dbcm && $u->writer;

    my $jid = $u->{'userid'};

    # delete comments
    my ($t, $loop) = (undef, 1);
    my $chunk_size = 200;
    while ($loop &&
           ($t = $dbcm->selectcol_arrayref("SELECT jtalkid FROM talk2 WHERE ".
                                           "nodetype=? AND journalid=? ".
                                           "AND nodeid=? LIMIT $chunk_size", undef,
                                           $nodetype, $jid, $jitemid))
           && $t && @$t)
    {
        my $in = join(',', map { $_+0 } @$t);
        return 1 unless $in;
        foreach my $table (qw(talkprop2 talktext2 talk2)) {
            $u->do("DELETE FROM $table WHERE journalid=? AND jtalkid IN ($in)",
                   undef, $jid);
        }
        # decrement memcache
        LJ::MemCache::decr([$u->{'userid'}, "talk2ct:$jid"], scalar(@$t));
        $loop = 0 unless @$t == $chunk_size;
    }

    # clean unused cache
    LJ::MemCache::delete([$jid, "talk2:$jid:$nodetype:$jitemid"]);
    LJ::MemCache::delete([$jid, "rp:$jid:$jitemid"]);
    LJ::MemCache::delete([$jid, "logprop:$jid:$jitemid"]); #invalidate
    
    return 1;
}

# <LJFUNC>
# name: LJ::Talk::delete_comments
# des: deletes comments, but not the relational information, so threading doesn't break
# info: The tables [dbtable[talkprop2]] and [dbtable[talktext2]] are deleted from.  [dbtable[talk2]]
#       just has its state column modified to 'D'.
# args: u, nodetype, nodeid, talkids+
# des-nodetype: The thread nodetype (probably 'L' for log items)
# des-jitemid: The thread nodeid for the given nodetype (probably the jitemid from the log2 row)
# des-talkids: arraylist of talkids to delete.
# returns: scalar integer; number of items deleted.
# </LJFUNC>
sub delete_comments {
    my ($u, $nodetype, $jitemid, $talkids) = @_;

    return 0 unless $u->writer;

    my $jid = $u->{'userid'}+0;
    my $in = join(',', map { $_+0 } @$talkids);
    return 1 unless $in;
    my $where = "WHERE journalid=$jid AND jtalkid IN ($in)";

    my $num = $u->talk2_do($nodetype, $jitemid, undef,
                           "UPDATE talk2 SET state='D' $where AND state IN ('A','F')");
    my $screened = 0;
    $screened = $u->talk2_do($nodetype, $jitemid, undef,
                           "UPDATE talk2 SET state='D' $where AND state='S'")
                                                  if $num != scalar @$talkids;

    if ($num > 0 || $screened > 0) {
        $u->do("UPDATE talktext2 SET subject=NULL, body=NULL $where");
        $u->do("DELETE FROM talkprop2 WHERE $where");
        LJ::replycount_do($u, $jitemid, "decr", $num) if $num;
        LJ::Talk::screenedcount_do($u, $jitemid, "decr", $screened) if $screened;
    }
    return $num + $screened;
}

# <LJFUNC>
# name: LJ::Talk::delete_thread
# class: web
# des: Deletes an entire thread of comments.
# args: u, jitemid, jtalkid
# des-u: Userid or user object to delete thread from.
# des-jitemid: Journal itemid of item to delete comments from.
# des-jtalkid: Journal talkid of comment at top of thread to delete.
# returns: 1 on success; undef on error
# </LJFUNC>
sub delete_thread {
    my ($u, $jitemid, $jtalkid) = @_;

    # get comments and delete 'em
    my $ids = LJ::Talk::get_comments_in_thread($u, $jitemid, $jtalkid);
    LJ::Talk::delete_comments($u, "L", $jitemid, $ids);
    return 1;
}

# <LJFUNC>
# name: LJ::Talk::freeze_thread
# class: web
# des: Freezes an entire thread of comments.
# args: u, jitemid, jtalkid
# des-u: Userid or user object to freeze thread from.
# des-jitemid: Journal itemid of item to freeze comments from.
# des-jtalkid: Journal talkid of comment at top of thread to freeze.
# returns: 1 on success; undef on error
# </LJFUNC>
sub freeze_thread {
    my ($u, $jitemid, $jtalkid) = @_;

    # now we need to update the states
    my $ids = LJ::Talk::get_comments_in_thread($u, $jitemid, $jtalkid, 'A');
    LJ::Talk::freeze_comments($u, "L", $jitemid, 0, $ids);
    return 1;
}

# <LJFUNC>
# name: LJ::Talk::unfreeze_thread
# class: web
# des: unfreezes an entire thread of comments.
# args: u, jitemid, jtalkid
# des-u: Userid or user object to unfreeze thread from.
# des-jitemid: Journal itemid of item to unfreeze comments from.
# des-jtalkid: Journal talkid of comment at top of thread to unfreeze.
# returns: 1 on success; undef on error
# </LJFUNC>
sub unfreeze_thread {
    my ($u, $jitemid, $jtalkid) = @_;

    # now we need to update the states
    my $ids = LJ::Talk::get_comments_in_thread($u, $jitemid, $jtalkid, 'F');
    LJ::Talk::freeze_comments($u, "L", $jitemid, 1, $ids);
    return 1;
}

# <LJFUNC>
# name: LJ::Talk::freeze_comments
# class: web
# des: Freezes comments.  This is the internal helper function called by
#   freeze_thread/unfreeze_thread.  Use those if you wish to freeze or
#   unfreeze a thread.  This function just freezes specific comments.
# args: u, nodetype, nodeid, unfreeze, ids
# des-u: Userid or object of user to manipulate comments in.
# des-nodetype: Nodetype of the thing containing the specified ids.  Typically "L".
# des-nodeid: Id of the node to manipulate comments from.
# des-unfreeze: If 1, unfreeze instead of freeze.
# des-ids: Array reference containing jtalkids to manipulate.
# returns: 1 on success; undef on error
# </LJFUNC>
sub freeze_comments {
    my ($u, $nodetype, $nodeid, $unfreeze, $ids) = @_;
    $u = LJ::want_user($u);
    $nodeid += 0;
    $unfreeze = $unfreeze ? 1 : 0;
    return undef unless LJ::isu($u) && $nodetype =~ /^\w$/ && $nodeid && @$ids;

    # get database and quote things
    return undef unless $u->writer;
    my $quserid = $u->{userid}+0;
    my $qnodetype = $u->quote($nodetype);
    my $qnodeid = $nodeid+0;

    # now perform action    
    my $in = join(',', map { $_+0 } @$ids);
    my $newstate = $unfreeze ? 'A' : 'F';
    my $res = $u->talk2_do($nodetype, $nodeid, undef,
                           "UPDATE talk2 SET state = '$newstate' " .
                           "WHERE journalid = $quserid AND nodetype = $qnodetype " .
                           "AND nodeid = $qnodeid AND jtalkid IN ($in)");
    return undef unless $res;
    return 1;
}

sub screen_comments {
    my ($u, $jitemid, $talkids) = @_;
    return undef unless LJ::isu($u);

    my $in = join (',', map { $_+0 } @$talkids);
    return unless $in;

    my $uid = $u->{'userid'} + 0;

    my $updated = $u->talk2_do("L", $jitemid, undef,
                               "UPDATE talk2 SET state='S' ".
                               "WHERE journalid=$uid AND jtalkid IN ($in) ".
                               "AND nodetype='L' AND nodeid=$jitemid ".
                               "AND state NOT IN ('S','D')");
    return undef unless $updated;

    if ($updated > 0) {
        LJ::replycount_do($u, $jitemid, "decr", $updated);
        LJ::Talk::screenedcount_do($u, $jitemid, "incr", $updated);
    }

    return;
}

sub unscreen_comments {
    my ($u, $jitemid, $talkids) = @_;
    return undef unless LJ::isu($u);

    my $in = join (',', map { $_+0 } @$talkids);
    return unless $in;

    my $uid = $u->{'userid'} + 0;

    my $updated = $u->talk2_do("L", $jitemid, undef,
                               "UPDATE talk2 SET state='A' ".
                               "WHERE journalid=$uid AND jtalkid IN ($in) ".
                               "AND nodetype='L' AND nodeid=$jitemid ".
                               "AND state='S'");
    return undef unless $updated;

    if ($updated > 0) {
        LJ::replycount_do($u, $jitemid, "incr", $updated);
        LJ::Talk::screenedcount_do($u, $jitemid, "decr", $updated);
    }

    return;
}

sub screenedcount_do {
    my ($u, $jitemid, $incrdecr, $updated) = @_;  #like replycount_do

    my $uid = $u->{'userid'} + 0;
    my $hasscreened = 0;

    if (!defined $updated) { $updated = 1; }
    if ($incrdecr eq "decr") { $updated = - $updated; }

    my $r = LJ::MemCache::get([$uid,"logprop:$uid:$jitemid"]);
    if ($r && defined $r->{'hasscreened'} && $r->{'hasscreened'} + $updated > 0) { # 'hasscreened' = 1  legacy value (lots of records in db)
        $hasscreened = $r->{'hasscreened'} + $updated;
    } else {
        my $dbcm = LJ::get_cluster_master($u);
        $hasscreened = $dbcm->selectrow_array("SELECT COUNT(*) FROM talk2 " .
                                              "WHERE journalid=$uid AND nodeid=$jitemid AND nodetype='L' AND state='S'");
    }

    LJ::set_logprop($u, $jitemid, { 'hasscreened' => $hasscreened });
    LJ::Talk::update_screenedcommentalter($u, $jitemid); # timestamp
}


# retrieves data from the talk2 table (but preferrably memcache)
# returns a hashref (key -> { 'talkid', 'posterid', 'datepost', 
#                             'parenttalkid', 'state' } , or undef on failure
sub get_talk_data
{
    my ($u, $nodetype, $nodeid) = @_;
    return undef unless LJ::isu($u);
    return undef unless $nodetype =~ /^\w$/;
    return undef unless $nodeid =~ /^\d+$/;

    my $ret = {};

    # check for data in memcache
    my $DATAVER = "1";  # single character
    my $memkey = [$u->{'userid'}, "talk2:$u->{'userid'}:$nodetype:$nodeid"];
    my $lockkey = $memkey->[1];
    my $packed = LJ::MemCache::get($memkey);

    my $memcache_good = sub {
        return $packed && substr($packed,0,1) eq $DATAVER &&
            length($packed) % 16 == 1;
    };

    my $memcache_decode = sub {
        my $n = (length($packed) - 1) / 16;
        for (my $i=0; $i<$n; $i++) {
            my ($f1, $parent, $poster, $time) = unpack("NNNN",substr($packed,$i*16+1,16));
            my $state = chr($f1 & 255);
            my $talkid = $f1 >> 8;
            $ret->{$talkid} = {
                talkid => $talkid,
                state => $state,
                posterid => $poster,
                datepost => LJ::mysql_time($time),
                parenttalkid => $parent,
            };
        }
        return $ret;
    };
    
    return $memcache_decode->() if $memcache_good->();

    my $dbcr = LJ::get_cluster_def_reader($u);
    return undef unless $dbcr;

    my $lock = $dbcr->selectrow_array("SELECT GET_LOCK(?,10)", undef, $lockkey);
    return undef unless $lock;

    # it's quite likely (for a popular post) that the memcache was 
    # already populated while we were waiting for the lock
    $packed = LJ::MemCache::get($memkey);
    if ($memcache_good->()) {
        $dbcr->selectrow_array("SELECT RELEASE_LOCK(?)", undef, $lockkey);
        $memcache_decode->();
        return $ret;
    }

    my $memval = $DATAVER;
    my $sth = $dbcr->prepare("SELECT t.jtalkid AS 'talkid', t.posterid, ".
                             "t.datepost, t.parenttalkid, t.state ".
                             "FROM talk2 t ".
                             "WHERE t.journalid=? AND t.nodetype=? AND t.nodeid=?");
    $sth->execute($u->{'userid'}, $nodetype, $nodeid);
    die $dbcr->errstr if $dbcr->err;
    my $rp_ourcount = 0;
    my $screened_ourcount = 0;
    while (my $r = $sth->fetchrow_hashref) {
        $ret->{$r->{'talkid'}} = $r;
        my $state = $r->{'state'};
        $memval .= pack("NNNN",
                        ($r->{'talkid'} << 8) + ord($state),
                        $r->{'parenttalkid'},
                        $r->{'posterid'},
                        LJ::mysqldate_to_time($r->{'datepost'}));

        # comments are counted if they're 'A'pproved or 'F'rozen
        $rp_ourcount++ if $state eq "A" || $state eq "F";
        $screened_ourcount++ if $state eq "S";
    }
    LJ::MemCache::set($memkey, $memval, 7200);

    #Fix replycount if desynchronized:
    my $rp_count = get_replycount($u, $nodeid);
    unless ($rp_ourcount == $rp_count) {
        $u->do("UPDATE log2 SET replycount=? WHERE journalid=? AND jitemid=?",
               undef, $rp_ourcount, $u->{'userid'}, $nodeid);

        my $rp_memkey = [$u->{'userid'}, "rp:$u->{'userid'}:$nodeid"];
        LJ::MemCache::set($rp_memkey, $rp_ourcount);

        print STDERR "Fixing replycount for $u->{'userid'}/$nodeid from $rp_count to $rp_ourcount\n";
    }
#    #Fix hasscreened if desynchronized:
#    my $r = LJ::MemCache::get([$u->{'userid'},"logprop:$u->{'userid'}:$nodeid"]);
#    unless ($r && $r->{'hasscreened'} == $screened_ourcount) {
#        LJ::set_logprop($u, $nodeid, { 'hasscreened' => $screened_ourcount });
#    }

    $dbcr->selectrow_array("SELECT RELEASE_LOCK(?)", undef, $lockkey);

    return $ret;
    
}

# LJ::Talk::load_comments($u, $remote, $nodetype, $nodeid, $opts)
#
# nodetype: "L" (for log) ... nothing else has been used
# noteid: the jitemid for log.
# opts keys:
#   thread -- jtalkid to thread from ($init->{'thread'} or $GET{'thread'} >> 8)
#   page -- $GET{'page'}
#   view -- $GET{'view'} (picks page containing view's ditemid)
#   up -- [optional] hashref of user object who posted the thing being replied to
#         only used to make things visible which would otherwise be screened?
#   out_error -- set by us if there's an error code:
#        nodb:  database unavailable
#        noposts:  no posts to load
#   out_pages:  number of pages
#   out_page:  page number being viewed
#   out_itemfirst:  first comment number on page (1-based, not db numbers)
#   out_itemlast:  last comment number on page (1-based, not db numbers)
#   out_pagesize:  size of each page
#   out_items:  number of total top level items
#
#   userpicref -- hashref to load userpics into, or undef to
#                 not load them.
#   userref -- hashref to load users into, keyed by userid
#
# returns:
#   array of hashrefs containing keys:
#      - talkid (jtalkid)
#      - posterid (or zero for anon)
#      - userpost (string, or blank if anon)
#      - upost    ($u object, or undef if anon)
#      - datepost (mysql format)
#      - parenttalkid (or zero for top-level)
#      - state ("A"=approved, "S"=screened, "D"=deleted stub)
#      - userpic number
#      - picid   (if userpicref AND userref were given)
#      - subject
#      - body
#      - props => { propname => value, ... }
#      - children => [ hashrefs like these ]
#      - _loaded => 1 (if fully loaded, subject & body)
#        unknown items will never be _loaded
#      - _show => {0|1}, if item is to be ideally shown (0 if deleted or screened)
sub load_comments
{
    my ($u, $remote, $nodetype, $nodeid, $opts) = @_;

    my $n = $u->{'clusterid'};
    my $viewall = $opts->{viewall};

    my $posts = LJ::Talk::get_talk_data($u, $nodetype, $nodeid);  # hashref, talkid -> talk2 row, or undef
    unless ($posts) {
        $opts->{'out_error'} = "nodb";
        return;
    }
    my %users_to_load;  # userid -> 1
    my @posts_to_load;  # talkid scalars
    my %children;       # talkid -> [ childenids+ ]

    my $uposterid = $opts->{'up'} ? $opts->{'up'}->{'userid'} : 0;

    my $post_count = 0;
    {
        my %showable_children;  # $id -> $count

        foreach my $post (sort { $b->{'talkid'} <=> $a->{'talkid'} } values %$posts) {
            # see if we should ideally show it or not.  even if it's 
            # zero, we'll still show it if it has any children (but we won't show content)
            my $should_show = $post->{'state'} eq 'D' ? 0 : 1; 
            unless ($viewall) {
                $should_show = 0 if
                    $post->{'state'} eq "S" && ! ($remote && ($remote->{'userid'} == $u->{'userid'} ||
                                                              $remote->{'userid'} == $uposterid ||
                                                              $remote->{'userid'} == $post->{'posterid'} ||
                                                              LJ::can_manage($remote, $u) ));
            }
            $post->{'_show'} = $should_show;
            $post_count += $should_show;

            # make any post top-level if it says it has a parent but it isn't 
            # loaded yet which means either a) row in database is gone, or b)
            # somebody maliciously/accidentally made their parent be a future
            # post, which could result in an infinite loop, which we don't want.
            $post->{'parenttalkid'} = 0 
                if $post->{'parenttalkid'} && ! $posts->{$post->{'parenttalkid'}};

            $post->{'children'} = [ map { $posts->{$_} } @{$children{$post->{'talkid'}} || []} ];

            # increment the parent post's number of showable children,
            # which is our showability plus all those of our children
            # which were already computed, since we're working new to old
            # and children are always newer.
            # then, if we or our children are showable, add us to the child list
            my $sum = $should_show + $showable_children{$post->{'talkid'}};
            if ($sum) {
                $showable_children{$post->{'parenttalkid'}} += $sum;
                unshift @{$children{$post->{'parenttalkid'}}}, $post->{'talkid'};
            }
        }
    }

    # with a wrong thread number, silently default to the whole page
    my $thread = $opts->{'thread'}+0;
    $thread = 0 unless $posts->{$thread};

    unless ($thread || $children{$thread}) {
        $opts->{'out_error'} = "noposts";
        return;
    }

    my $page_size = $opts->{'page_size'}+0;
    my $max_subjects = $opts->{'max_subjects'}+0;
    my $threading_point = $opts->{'threading_point'}+0;
    if (defined $opts->{'uncollapse'}) { 
	$threading_point= 1000; $max_subjects=1000; $page_size=500;
    }

    # Read discussion - http://lj.rossia.org/users/tiphareth/1089636.html
    $page_size = $LJ::TALK_PAGE_SIZE  unless $page_size; #default 25
    $max_subjects = $LJ::TALK_MAX_SUBJECTS  unless $max_subjects; #default 200
    $threading_point = $LJ::TALK_THREAD_POINT  unless $threading_point; #default 150


    # we let the page size initially get bigger than normal for awhile,
    # but if it passes threading_point, then everything's in page_size
    # chunks:
    $page_size = $threading_point if $post_count < $threading_point;
    
    my $top_replies = $thread ? 1 : scalar(@{$children{$thread}});
    my $pages = int($top_replies / $page_size);
    if ($top_replies % $page_size) { $pages++; }
    
    my @top_replies = $thread ? ($thread) : @{$children{$thread}};
    my $page_from_view = 0;
    if ($opts->{'view'} && !$opts->{'page'}) {
        # find top-level comment that this comment is under
        my $viewid = $opts->{'view'} >> 8;
        while ($posts->{$viewid} && $posts->{$viewid}->{'parenttalkid'}) {
            $viewid = $posts->{$viewid}->{'parenttalkid'};
        }
        for (my $ti = 0; $ti < @top_replies; ++$ti) {
            if ($posts->{$top_replies[$ti]}->{'talkid'} == $viewid) {
                $page_from_view = int($ti/$page_size)+1;
                last;
            }
        }
    }
    my $page = int($opts->{'page'}) || $page_from_view || 1;
    $page = $page < 1 ? 1 : $page > $pages ? $pages : $page;
    
    my $itemfirst = $page_size * ($page-1) + 1;
    my $itemlast = $page==$pages ? $top_replies : ($page_size * $page);
    
    @top_replies = @top_replies[$itemfirst-1 .. $itemlast-1];
    
    push @posts_to_load, @top_replies;
    
    # mark child posts of the top-level to load, deeper
    # and deeper until we've hit the page size.  if too many loaded,
    # just mark that we'll load the subjects;
    my @check_for_children = @posts_to_load;
    my (@subjects_to_load, @subjects_ignored);
    while (@check_for_children) {
        my $cfc = shift @check_for_children;
        next unless defined $children{$cfc};
        foreach my $child (@{$children{$cfc}}) {
            if (@posts_to_load < 3 * $page_size) {
# Replaced $page_size by 3*$page_size.
# Hopefully the result will be closer to nesting. -- M. V.
                push @posts_to_load, $child;
            } else {
                if (@subjects_to_load < $max_subjects) {
                    push @subjects_to_load, $child;
                } else {
                    push @subjects_ignored, $child;
                }
            }
            push @check_for_children, $child;
        }
    }

    $opts->{'out_pages'} = $pages;
    $opts->{'out_page'} = $page;
    $opts->{'out_itemfirst'} = $itemfirst;
    $opts->{'out_itemlast'} = $itemlast;
    $opts->{'out_pagesize'} = $page_size;
    $opts->{'out_items'} = $top_replies;
    
    # load text of posts
    my ($posts_loaded, $subjects_loaded);
    $posts_loaded = LJ::get_talktext2($u, @posts_to_load);
    $subjects_loaded = LJ::get_talktext2($u, {'onlysubjects'=>1}, @subjects_to_load) if @subjects_to_load;
    foreach my $talkid (@posts_to_load) {
        next unless $posts->{$talkid}->{'_show'};
        $posts->{$talkid}->{'_loaded'} = 1;
        $posts->{$talkid}->{'subject'} = $posts_loaded->{$talkid}->[0];
        $posts->{$talkid}->{'body'} = $posts_loaded->{$talkid}->[1];
        $users_to_load{$posts->{$talkid}->{'posterid'}} = 1;
    }
    foreach my $talkid (@subjects_to_load) {
        next unless $posts->{$talkid}->{'_show'};
        $posts->{$talkid}->{'subject'} = $subjects_loaded->{$talkid}->[0];
        $users_to_load{$posts->{$talkid}->{'posterid'}} ||= 0.5;  # only care about username
    }
    foreach my $talkid (@subjects_ignored) {
        next unless $posts->{$talkid}->{'_show'};
        $posts->{$talkid}->{'subject'} = "...";
        $users_to_load{$posts->{$talkid}->{'posterid'}} ||= 0.5;  # only care about username
    }

    # load meta-data
    {
        my %props;
        LJ::load_talk_props2($u, \@posts_to_load, \%props);
        foreach (keys %props) {
            next unless $posts->{$_}->{'_show'};
            $posts->{$_}->{'props'} = $props{$_};
        }
    }

    if ($LJ::UNICODE) {
        foreach (@posts_to_load) {
            if ($posts->{$_}->{'props'}->{'unknown8bit'}) {
                LJ::item_toutf8($u, \$posts->{$_}->{'subject'},
                                \$posts->{$_}->{'body'},
                                {});
                $posts->{$_}->{'props'}->{'unknown8bit'} = 0;  ## ???
                print STDERR "Fixing item_toutf8 in load_comments $u->{'userid'} $nodeid $thread $_ \n";
              }
        }
    }

    # load users who posted
    delete $users_to_load{0};
    my %up = ();
    if (%users_to_load) {
        LJ::load_userids_multiple([ map { $_, \$up{$_} } keys %users_to_load ]);

        # fill in the 'userpost' member on each post being shown
        while (my ($id, $post) = each %$posts) {
            my $up = $up{$post->{'posterid'}};
            next unless $up;
            $post->{'upost'}    = $up;
            $post->{'userpost'} = $up->{'user'};
        }
    }

    # optionally give them back user refs
    if (ref($opts->{'userref'}) eq "HASH") {
        my %userpics = ();
        # copy into their ref the users we've already loaded above.
        while (my ($k, $v) = each %up) {
            $opts->{'userref'}->{$k} = $v;
        }

        # optionally load userpics
        if (ref($opts->{'userpicref'}) eq "HASH") {
            my @load_pic;
            foreach my $talkid (@posts_to_load) {
                my $post = $posts->{$talkid};
                my $kw;
                if ($post->{'props'} && $post->{'props'}->{'picture_keyword'}) {
                    $kw = $post->{'props'}->{'picture_keyword'};
                }
                my $pu = $opts->{'userref'}->{$post->{'posterid'}};
                my $id = LJ::get_picid_from_keyword($pu, $kw);
                $post->{'picid'} = $id;
                push @load_pic, [ $pu, $id ];
            }
            LJ::load_userpics($opts->{'userpicref'}, \@load_pic);
        }
    }
    return map { $posts->{$_} } @top_replies;
}

sub talkform {
    # Takes a hashref with the following keys / values:
    # remote:      optional remote u object
    # journalu:    prequired journal u object
    # parpost:     parent post object
    # replyto:     init->replyto
    # ditemid:     init->ditemid
    # form:        optional full form hashref
    # do_captcha:  optional toggle for creating a captcha challenge
    # require_tos: optional toggle to include TOS requirement form
    # errors:      optional error arrayref
    my $opts = shift;
    return "Invalid talkform values." unless ref $opts eq 'HASH';

    my $ret;
    my ($remote, $journalu, $parpost, $form) =
        map { $opts->{$_} } qw(remote journalu parpost form);

    my $pics = LJ::Talk::get_subjecticons();

    # early bail if the user can't be making comments yet
    return $LJ::UNDERAGE_ERROR
        if $remote && $remote->underage;

    # once we clean out talkpost.bml, this will need to be changed.
    BML::set_language_scope('/talkpost.bml');

    # make sure journal isn't locked
    return "Sorry, this journal is locked and comments cannot be posted to it at this time."
        if $journalu->{statusvis} eq 'L';

    # check max comments
    my $jitemid = $opts->{'ditemid'} >> 8;
    return "Sorry, this entry already has the maximum number of comments allowed."
        if LJ::Talk::Post::over_maxcomments($journalu, $jitemid);

    if ($parpost->{'state'} eq "S") {
        $ret .= "<div class='ljwarnscreened'>$BML::ML{'.warnscreened'}</div>";
    }
    $ret .= "<form method='post' action='$LJ::SITEROOT/talkpost_do.bml' id='postform'>";

    # Login challenge/response
    my $authchal = LJ::challenge_generate(900); # 15 minute auth token
    $ret .= "<input type='hidden' name='chal' id='login_chal' value='$authchal' />";
    $ret .= "<input type='hidden' name='response' id='login_response' value='' />";

    if ($opts->{errors} && @{$opts->{errors}}) {
        $ret .= '<ul>';
        $ret .= "<li><b>$_</b></li>" foreach @{$opts->{errors}};
        $ret .= '</ul>';
        $ret .= "<hr />";
    }

    # hidden values
    my $parent = $opts->{replyto}+0;
    $ret .= LJ::html_hidden("replyto", $opts->{replyto},
                            "parenttalkid", $parent,
                            "itemid", $opts->{ditemid},
                            "journal", $journalu->{'user'});

    # rate limiting challenge
    {
        my ($time, $secret) = LJ::get_secret();
        my $rchars = LJ::rand_chars(20);
        my $chal = $opts->{ditemid} . "-$journalu->{userid}-$time-$rchars";
        my $res = Digest::MD5::md5_hex($secret . $chal);
        $ret .= LJ::html_hidden("chrp1", "$chal-$res");
    }

    # if we know the user who is posting (error on talkpost_do POST action),
    # then see if we 
    if ($opts->{require_tos}) {
        $ret .= LJ::tosagree_html('comment', $form->{agree_tos}, BML::ml('tos.error'));
    }

    my $oid_identity = $remote ? $remote->openid_identity : undef;
    my $ljc_oid_identity = 0;
    
    if ($oid_identity) {
      $ljc_oid_identity = 
        $oid_identity !~ /http:\/\/.+\.livejournal.com\/$/ &&
        $oid_identity !~ /http:\/\/users.livejournal.com\/.+\/$/ ?
        0 : 1;
    }

    # Default radio button
    # 4 possible scenarios:
    # remote - initial form load, error and redisplay
    # no remote - initial load, error and redisplay
    my $whocheck = sub {
        my $type = shift;
        my $default = " checked='checked'";

        if (LJ::OpenID::consumer_enabled()) {
          return $default if $type eq 'ljc_openid' &&
            ! $form->{'usertype'} &&
            ! $remote &&
            ! $oid_identity &&
            ! $ljc_oid_identity;

          return $default if
            $type eq 'ljc_openid_cookie' &&
            (
              $form->{'usertype'} eq 'openid_cookie' ||
              (defined $oid_identity && $ljc_oid_identity)
            );
        }

        # Initial page load (no remote)
        return $default if $type eq 'anonymous' &&
            ! $form->{'usertype'} && ! $remote && ! $oid_identity;

        # Anonymous
        return $default if $type eq 'anonymous' &&
            $form->{'usertype'} eq 'anonymous';

        if (LJ::OpenID::consumer_enabled()) {
            # OpenID
            return $default if $type eq 'openid' &&
                $form->{'usertype'} eq 'openid';

            return $default if $type eq 'openid_cookie' &&
                ($form->{'usertype'} eq 'openid_cookie' ||
                (defined $oid_identity));
        }

        # Remote user, remote equals userpost
        return $default if $type eq 'remote' &&
                           ($form->{'usertype'} eq 'cookieuser' ||
                            $form->{'userpost'} eq $form->{'cookieuser'});

        # Possible remote, using ljuser field
        if ($type eq 'ljuser') {
        return $default if
            # Remote user posting as someone else.
            ($form->{'userpost'} && $form->{'userpost'} ne $form->{'cookieuser'} && $form->{'usertype'} ne 'anonymous') ||
            ($form->{'usertype'} eq 'user' && ! $form->{'userpost'});
        }

        return;
    };

    # from registered user or anonymous?
    $ret .= "<table>\n";
    $ret .= "<tr><td align='right' valign='top'>$BML::ML{'.opt.from'}</td>";
    $ret .= "<td>";
    $ret .= "<table>"; # Internal for "From" options
    my $screening = LJ::Talk::screening_level($journalu, $opts->{ditemid} >> 8);

    if ($journalu->{'opt_whocanreply'} eq "all") {
        $ret .= "<tr valign='center'>";
        $ret .= "<td align='center'><img src='$LJ::IMGPREFIX/anonymous.gif' onclick='handleRadios(0);'/></td>";
        $ret .= "<td align='center'><input type='radio' name='usertype' value='anonymous' id='talkpostfromanon'" .
                $whocheck->('anonymous') .
                " /></td>";
        $ret .= "<td align='left'><b><label for='talkpostfromanon'>$BML::ML{'.opt.anonymous'}</label></b>";
        $ret .= " " . $BML::ML{'.opt.willscreen'} if $screening;
        $ret .= "</td></tr>\n";
    }
    else {
        $ret .= "<tr valign='middle'>";
        $ret .= "<td align='center' width='20'><img src='$LJ::IMGPREFIX/anonymous.gif' /></td>";
        $ret .= "<td align='center'>(  )</td>";
        $ret .= "<td align='left' colspan='2'><font color='#c0c0c0'><b>$BML::ML{'.opt.anonymous'}</b></font>$BML::ML{'.opt.noanonpost'}</td>";
        $ret .= "</tr>\n";
    }

    if (LJ::OpenID::consumer_enabled()) {
      if ($journalu->{'opt_whocanreply'} eq "all" or $journalu->{'opt_whocanreply'} eq "reg") {
        # OpenID!!
        # Logged in
        if (defined $oid_identity && !$ljc_oid_identity) {
          # Don't worry about a real href since js hides the row anyway
          my $other_user = "<script lanaguage='JavaScript'>if (document.getElementById) {document.write(\"&nbsp;<a href='#' onClick='otherOIDUser();return false;'>[other]</a>\");}</script>";

          $ret .= "<tr valign='middle' id='oidli' name='oidli'>";
          $ret .= "<td align='center'><img src='$LJ::IMGPREFIX/openid-profile.gif' onclick='handleRadios(4);' /></td><td align='center'><input type='radio' name='usertype' value='openid_cookie' id='talkpostfromoidli'" .
              $whocheck->('openid_cookie') . "/>";
          $ret .= "</td><td align='left'><b><label for='talkpostfromoid' onclick='handleRadios(4);return false;'>OpenID identity:</label></b> ";

          $ret .= "<i>" . $remote->display_name . "</i>";
          $ret .= $other_user . " ";

          $ret .= $BML::ML{'.opt.willscreen'} if $screening eq "A" || $screening eq "F";
          $ret .= "</td></tr>\n";
        }

        # logged out
        $ret .= "<tr valign='middle' id='oidlo' name='oidlo'>";
        $ret .= "<td align='center'><img src='$LJ::IMGPREFIX/openid-profile.gif' onclick='handleRadios(3);' /></td><td align='center'><input type='radio' name='usertype' value='openid' id='talkpostfromoidlo'" .
            $whocheck->('openid') . "/>";
        $ret .= "</td><td align='left'><b><label for='talkpostfromoidlo' onclick='handleRadios(3);return false;'>OpenID</label></b> ";

        if (defined $LJ::HELPURL{'openid'}) {
          $ret .= "<a href='$LJ::HELPURL{'openid'}'><img src='$LJ::IMGPREFIX/help.gif' alt='$BML::ML{'Help'}' title='$BML::ML{'Help'}' width='14' height='14' border='0' /></a> ";
        }

        $ret .= $BML::ML{'.opt.willscreen'} if $screening eq "A" || $screening eq "F";
        $ret .= "</td></tr>\n";

        # URL: [    ]  Verify? [ ]
        my $url_def = $form->{'oidurl'} || $oid_identity if defined $oid_identity;

        $ret .= "<tr valign='middle' align='left' id='oid_more'><td colspan='2'></td><td>";
        $ret .= "Identity URL:&nbsp;<input class='textbox' name='oidurl' maxlength='60' size='53' id='oidurl' value='$url_def' /> ";
        $ret .= "<br /><label for='oidlogincheck'>$BML::ML{'.loginq'}&nbsp;</label><input type='checkbox' name='oiddo_login' id='oidlogincheck' ";
        $ret .= "checked='checked' " if $form->{'oiddo_login'};
        $ret .= "/></td></tr>\n";

        # LiveJournal.com user

        # logged in
        if (defined $oid_identity && $ljc_oid_identity) {
          # Don't worry about a real href since js hides the row anyway
          my $other_user = "<script lanaguage='JavaScript'>if (document.getElementById) {document.write(\"&nbsp;<a href='#' onClick='otherLJCOIDUser();return false;'>[other]</a>\");}</script>";

          $ret .= "<tr valign='middle' id='ljc_oidli' name='ljc_oidli'>";
          $ret .= "<td valign='top' align='center'><img src='$LJ::IMGPREFIX/userinfo-lj.gif' onclick='handleRadios(104);' /></td><td valign='top' align='center'><input type='radio' name='usertype' value='openid_cookie' id='talkpostfromljcoidli'" .
              $whocheck->('ljc_openid_cookie') . "/>";
          $ret .= "</td><td align='left'><b><label for='talkpostfromljcoid' onclick='handleRadios(104);return false;'>пользователь LiveJournal.com:</label></b> ";

          $ret .= "<i>" . $remote->display_name . "</i>";
          $ret .= $other_user . " ";

          $ret .= $BML::ML{'.opt.willscreen'} if $screening eq "A" || $screening eq "F";

          # email field for logged-in openid commentators
          if ($remote->openid_identity && !$remote->{'email'}) {
            $ret .= "<br/><strong>E-mail для ответов:</strong>&nbsp;";
            $ret .= LJ::html_text({ 'name' => 'email', 'value' => '', 'size' => '40', 'maxlength' => '50' });
            $ret .= "<font size=-1 color=red><br/>Пока вы не введете e-mail, вы не сможете получать ответы по e-mail.";
            $ret .= "<br/>Внимание: на указанный e-mail будет выслано подтверждение.</font>";
          }

          $ret .= "</td></tr>\n";
        }

        $ret .= "<tr valign='middle' align='left' id='ljc_oidlo' name='ljc_oidlo'>";
        $ret .= "<td align='center'><img src='$LJ::IMGPREFIX/userinfo-lj.gif' onclick='handleRadios(103);return false;' /></td>";
        $ret .= "<td align='center'><input type='radio' name='usertype' value='ljc_openid' id='talkpostfromljcoidlo'" .
          $whocheck->('ljc_openid') . " /></td>";
        $ret .= "<td align='left'><b><label for='talkpostfromljcoidlo' onclick='handleRadios(103);return false;'>пользователь LiveJournal.com</label></b> ";
        $ret .= $BML::ML{'.opt.willscreen'} if $screening eq "A" || $screening eq "F";
        $ret .= "</td></tr>\n";

        $ret .= "<tr valign='middle' align='left' id='ljc_oid_more'><td colspan='2'></td><td>";
        $ret .= "<table cellspacing=0 cellpadding=0><tr><td>имя пользователя:&nbsp;</td><td>";
        $ret .= "<input class='textbox' name='ljc_oidurl' maxlength='30' size='33' id='ljc_oidurl' value='" . $BML::COOKIE{'LJR_lastljuser'} . "' /> ";
        $ret .= "&nbsp;<input type='checkbox' name='oiddo_login' id='logincheckljc' checked='checked'/>&nbsp;<label for='ljc_howlong'>помнить&nbsp;</label>";
        $ret .= "<select name='ljc_howlong' id='ljc_howlong'><option value=a>1 день <option value=b>1 неделю <option selected value=c>1 месяц <option value=d>1 год </select>";
        $ret .= "</td></tr><tr><td colspan=2>";
        $ret .= "<font size=2>Вы должны предварительно войти в LiveJournal.com</font><br/>";
        $ret .= "</td></tr>";
        if (!$BML::COOKIE{'LJR_confirmedemailthisyear'}) {
          $ret .= "<tr><td><font size=-2>&nbsp;<br/></font></td></tr>";
          $ret .= "<tr><td>E-mail для ответов:&nbsp;</td><td>";
          $ret .= LJ::html_text({ 'name' => 'email', 'value' => '', 'size' => '40', 'maxlength' => '50' });
          $ret .= "</td></tr><tr><td colspan=2>";
          $ret .= "<font size=-1 color=red>Вы сможете оставлять комментарии, даже если не введете e-mail.<br/>Но вы не сможете получать уведомления об ответах на ваши комментарии!";
          $ret .= "<br/>Внимание: на указанный адрес будет выслано подтверждение.</font>";
          $ret .= "</td></tr>";
        }
        $ret .= "</table></td></tr>\n";
      }
      else {
        # OpenID - At some point we will include "trusted"
        $ret .= "<tr valign='middle'>";
        $ret .= "<td align='center'><img src='$LJ::IMGPREFIX/openid-profile.gif' onclick='handleRadios(3);' /></td>";
        $ret .= "<td align='center'>(  )</td>";
        $ret .= "<td align='left' colspan='2'><font color='#c0c0c0'<b>OpenID</b></font>";

        if (defined $LJ::HELPURL{'openid'}) {
          $ret .= "<a href='$LJ::HELPURL{'openid'}'><img src='$LJ::IMGPREFIX/help.gif' alt='$BML::ML{'Help'}' title='$BML::ML{'Help'}' width='14' height='14' border='0' /></a> ";
        }

        $ret .= "</td></tr>\n";
      }
    }


    if ($remote && !defined $oid_identity) {
        $ret .= "<tr valign='middle' id='ljuser_row'>";
        my $logged_in = LJ::ehtml($remote->display_name);

        # Don't worry about a real href since js hides the row anyway
        my $other_user = "<script lanaguage='JavaScript'>if (document.getElementById) {document.write(\"&nbsp;<a href='#' onClick='otherLJUser();return false;'>[other]</a>\");}</script>";

        if (LJ::is_banned($remote, $journalu)) {
            $ret .= "<td align='center'><img src='$LJ::IMGPREFIX/userinfo.gif' /></td>";
            $ret .= "<td align='center'>( )</td>";
            $ret .= "<td align='left'><span class='ljdeem'>" . BML::ml(".opt.loggedin", {'username'=>"<i>$logged_in</i>"}) . "</font>" . BML::ml(".opt.bannedfrom", {'journal'=>$journalu->{'user'}}) . $other_user . "</td>";
        } else {
            $ret .= "<td align='center'><img src='$LJ::IMGPREFIX/userinfo.gif'  onclick='handleRadios(1);' /></td><td align='center'><input type='radio' name='usertype' value='cookieuser' id='talkpostfromremote'" .
                     $whocheck->('remote') .
                     " /></td>";
            $ret .= "<td align='left'><label for='talkpostfromremote'>" . BML::ml(".opt.loggedin", {'username'=>"<i>$logged_in</i>"}) . "</label>\n";

            $ret .= $other_user;

            $ret .= "<input type='hidden' name='cookieuser' value='$remote->{'user'}' id='cookieuser' />\n";
            if ($screening eq 'A' ||
                ($screening eq 'F' && !LJ::is_friend($journalu, $remote))) {
                $ret .= " " . $BML::ML{'.opt.willscreen'};
            }
            $ret .= "</td>";
        }
        $ret .= "</tr>\n";
    }

    # LJR user:
    $ret .= "<tr valign='middle' id='otherljuser_row' name='otherljuser_row'>";
    $ret .= "<td align='center'><img src='$LJ::IMGPREFIX/pencil.gif' onclick='handleRadios(2);' /></td><td align='center'><input type='radio' name='usertype' value='user' id='talkpostfromlj'" .
        $whocheck->('ljuser') . "/>";
    $ret .= "</td><td align='left'><b><label for='talkpostfromlj' onclick='handleRadios(2); return false;'>$BML::ML{'.opt.ljuser2'}</label></b> ";
    $ret .= $BML::ML{'.opt.willscreenfriend'} if $screening eq 'F';
    $ret .= $BML::ML{'.opt.willscreen'} if $screening eq 'A';
    $ret .= "</td></tr>\n";

    if ($remote && ! defined $oid_identity) {
        $ret .= "<script language='JavaScript'>\n";
        $ret .= "<!--\n";
        $ret .= "if (document.getElementById) {\n";
        $ret .= "var radio_user = document.getElementById(\"talkpostfromlj\");\n";
        $ret .= "if (!radio_user.checked) {\n";
        $ret .= "var otherljuser_row = document.getElementById(\"otherljuser_row\");\n";
        $ret .= "otherljuser_row.style.display = 'none';\n";
        $ret .= "}\n";
        $ret .= "}\n";
        $ret .= "//-->\n";
        $ret .= "</script>";
   }

    # Username: [    ] Password: [    ]  Login? [ ]
    $ret .= "<tr valign='middle' align='left' id='lj_more'><td colspan='2'></td><td>";
    my $ljuser_def = ($form->{'userpost'} ne $form->{'cookieuser'} && $form->{'usertype'} ne 'anonymous') ?
                     BML::eall($form->{userpost}) : "$remote->{'user'}" unless $oid_identity;

    $ret .= "<table><tr><td>";
    $ret .= "$BML::ML{'Username'}:</td><td>";
    $ret .= "<input class='textbox' name='userpost' size='13' maxlength='15' id='username' value='$ljuser_def' onclick='this.value=\"\"' ";
    $ret .= "style='background: url($LJ::IMGPREFIX/userinfo.gif) no-repeat; background-color: #fff; background-position: 0px 1px; padding-left: 18px; color: #00C; font-weight: bold;'/>";

    $ret .= "</td></tr><tr><td>";
    $ret .= "$BML::ML{'Password'}:</td><td>";
    $ret .= "<input class='textbox' name='password' type='password' maxlength='30' size='18' id='password' />";
    $ret .= "</td></tr><tr><td colspan='2'>";
    $ret .= "<label for='logincheck'>$BML::ML{'.loginq'}&nbsp;</label><input type='checkbox' name='do_login' id='logincheck' /></td></tr></table>";
    $ret .= "</td></tr>\n";

    # Link to create an account
    if (!$remote || defined $oid_identity) {
        $ret .= "<tr valign='middle' align='left'><td colspan='2'></td><td><span style='font-size: 8pt; font-style: italic;'>";
        $ret .= BML::ml('.noaccount', {'aopts' => "href='$LJ::SITEROOT/create.bml'"});
        $ret .= "</span></td></tr>\n";
    }

    my $basesubject = $form->{subject} || "";
    if ($opts->{replyto} && !$basesubject && $parpost->{'subject'}) {
        $basesubject = $parpost->{'subject'};
        $basesubject =~ s/^Re:\s*//i;
        $basesubject = "Re: $basesubject";
    }

    # Closing internal "From" table
    $ret .= "</td></tr></table>";

    # subject
    $basesubject = BML::eall($basesubject) if $basesubject;
    $ret .= "<tr valign='top'><td align='right'>$BML::ML{'.opt.subject'}</td><td><input class='textbox' type='text' size='50' maxlength='100' name='subject' id='subject' value=\"$basesubject\" onKeyPress='subjectNoHTML(event);'/>\n";

    # Subject Icon toggle button
    {
        my $subjicon = $form->{subjecticon} || 'none';
        my $foundicon = 0;
        $ret .= "<input type='hidden' id='subjectIconField' name='subjecticon' value='$subjicon'>\n";
        $ret .= "<script type='text/javascript' language='Javascript'>\n";
        $ret .= "<!--\n";
        $ret .= "if (document.getElementById) {\n";
        $ret .= "document.write(\"";
        if ($subjicon eq 'none') {
            $ret .= LJ::ejs(LJ::Talk::show_none_image("id='subjectIconImage' style='cursor:pointer;cursor:hand' align='absmiddle' ".
                                                      "onclick='subjectIconListToggle();' ".
                                                      "title='Click to change the subject icon'"));
        } else {
            foreach my $type (@{$pics->{types}}) { 
                foreach (@{$pics->{lists}->{$type}}) {
                    if ($_->{id} eq $subjicon) {
                        $ret .= LJ::Talk::show_image($pics, $subjicon, 
                                                     "id='subjectIconImage' onclick='subjectIconListToggle();' style='cursor:pointer;cursor:hand'");
                        $foundicon = 1;
                        last;
                    }
                }
                last if $foundicon == 1;
            }
        }
        if ($foundicon == 0 && $subjicon ne 'none') {
            $ret .= LJ::ejs(LJ::Talk::show_none_image("id='subjectIconImage' style='cursor:pointer;cursor:hand' align='absmiddle' ".
                                                      "onclick='subjectIconListToggle();' ".
                                                      "title='Click to change the subject icon'"));
        }
        $ret .="\");\n";

        # spit out a pretty table of all the possible subjecticons
        $ret .= "document.write(\"";
        $ret .= "<blockquote style='display:none;' id='subjectIconList'>";
        $ret .= "<table border='0' cellspacing='5' cellpadding='0' style='border: 1px solid #AAAAAA'>\");\n";

        foreach my $type (@{$pics->{'types'}}) {
            
            $ret .= "document.write(\"<tr>\");\n";

            # make an option if they don't want an image
            if ($type eq $pics->{'types'}->[0]) { 
                $ret .= "document.write(\"";
                $ret .= "<td valign='middle' align='center'>";
                $ret .= LJ::Talk::show_none_image(
                        "id='none' onclick='subjectIconChange(this);' style='cursor:pointer;cursor:hand' title='No subject icon'");
                $ret .= "</td>\");\n";
            }

            # go through and make clickable image rows.
            foreach (@{$pics->{'lists'}->{$type}}) {
                $ret .= "document.write(\"";
                $ret .= "<td valign='middle' align='center'>";
                $ret .= LJ::Talk::show_image($pics, $_->{'id'}, 
                        "id='$_->{'id'}' onclick='subjectIconChange(this);' style='cursor:pointer;cursor:hand'");
                $ret .= "</td>\");\n";
            }
            
            $ret .= "document.write(\"</tr>\");\n";
            
        }
        # end that table, bar!
        $ret .= "document.write(\"</table></blockquote>\");\n";

        $ret .= "}\n";
        $ret .="//-->\n";
        $ret .= "</script>\n";
    }

    # finish off subject line
    $ret .= "<div id='ljnohtmlsubj' class='ljdeem'><span style='font-size: 8pt; font-style: italic;'>$BML::ML{'.nosubjecthtml'}</span></div>\n";

    $ret .= "<div id='userpics'>";
    my %res;
    if ($remote) {
        LJ::do_request({ "mode" => "login",
                         "ver" => ($LJ::UNICODE ? "1" : "0"),
                         "user" => $remote->{'user'},
                         "getpickws" => 1,
                       }, \%res, { "noauth" => 1, "userid" => $remote->{'userid'} });
    }
    if ($res{'pickw_count'}) {
        $ret .= BML::ml('.label.picturetouse2',
                        {
                            'aopts'=>"href='$LJ::SITEROOT/allpics.bml?user=$remote->{'user'}'"}) . " ";
        my @pics;
        for (my $i=1; $i<=$res{'pickw_count'}; $i++) {
            push @pics, $res{"pickw_$i"};
        }
        @pics = sort { lc($a) cmp lc($b) } @pics;
        $ret .= LJ::html_select({'name' => 'prop_picture_keyword', 
                                 'selected' => $form->{'prop_picture_keyword'}, },
                                ("", $BML::ML{'.opt.defpic'}, map { ($_, $_) } @pics));

        if (defined $LJ::HELPURL{'userpics'}) {
            $ret .= " <a href='$LJ::HELPURL{'userpics'}'><img src='$LJ::IMGPREFIX/help.gif' alt='$BML::ML{'Help'}' title='$BML::ML{'Help'}' width='14' height='14' border='0' /></a>";
        }
    }
    $ret .= "</div>";
    $ret .= "</td></tr>\n";

    # textarea for their message body
    $ret .= "<tr valign='top'><td align='right'>$BML::ML{'.opt.message'}<br />";

    # only show on initial compostion
    my $quickquote;
    unless ($opts->{errors} && @{$opts->{errors}}) {
        # quick quote button
        $quickquote = "<br />" . LJ::ejs('<input type="button" value="Quote&gt;&gt;" onmousedown="quote();" onclick="quote();" />');
    }

    $ret .= "<script type='text/javascript' language='JavaScript'>\n<!--\n";
    $ret .= <<"QQ";

var helped = 0; var pasted = 0;
function quote () {
    var text = '';

    if (document.getSelection) {
        text = document.getSelection();
    } else if (document.selection) {
        text = document.selection.createRange().text;
    } else if (window.getSelection) {
        text = window.getSelection();
    }

    if (text == '') {
        if (helped != 1 && pasted != 1) {
            helped = 1; alert("If you'd like to quote a portion of the original message, highlight it then press 'Quote'");
        }
        return false;
    } else {
        pasted = 1;
    }

    var element = text.search(/\\n/) == -1 ? 'q' : 'blockquote';
    var textarea = document.getElementById('commenttext');
    textarea.focus();
    textarea.value = textarea.value + "<" + element + ">" + text + "</" + element + ">";
    textarea.caretPos = textarea.value;
    textarea.focus();
    return false;
}
if (document.getElementById && (document.getSelection || document.selection || window.getSelection)) {
    // Opera clears the paste buffer before mouse events, useless here
    if (navigator.userAgent.indexOf("Opera") == -1) { document.write('$quickquote'); }
}
QQ
    $ret .= "-->\n</script>\n";

    $ret .= "</td><td style='width: 90%'>";
    $ret .= "<textarea class='textbox' rows='10' cols='75' wrap='soft' name='body' id='commenttext'>$form->{body}</textarea><br/>";

    # Display captcha challenge if over rate limits.
    if ($opts->{do_captcha}) {
        my ($wants_audio, $captcha_sess, $captcha_chal);
        $wants_audio = 1 if lc($form->{answer}) eq 'audio';

        # Captcha sessions 
        my $cid = $journalu->{clusterid};
        $captcha_chal = $form->{captcha_chal} || LJ::challenge_generate(900);
        $captcha_sess = LJ::get_challenge_attributes($captcha_chal);
        my $dbcr = LJ::get_cluster_reader($journalu);

        my $try = 0;
        if ($form->{captcha_chal}) {
            $try = $dbcr->selectrow_array('SELECT trynum FROM captcha_session ' .
                                          'WHERE sess=?', undef, $captcha_sess);
        }
        $ret .= '<br /><br />';

        # Visual challenge
        if (! $wants_audio && ! $form->{audio_chal}) {
            $ret .= "<div class='formitemDesc'>$BML::ML{'/create.bml.captcha.desc'}</div>";
            $ret .= "<img src='/captcha/image.bml?chal=$captcha_chal&amp;cid=$cid&amp;try=$try' width='175' height='35' />";
            $ret .= "<br /><br />$BML::ML{'/create.bml.captcha.answer'}";
        }
        # Audio challenge
        else {
            $ret .= "<div class='formitemDesc'>$BML::ML{'/create.bml.captcha.audiodesc'}</div>";
            $ret .= "<a href='/captcha/audio.bml?chal=$captcha_chal&amp;cid=$cid&amp;try=$try'>$BML::ML{'/create.bml.captcha.play'}</a> &nbsp; ";
            $ret .= LJ::html_hidden(audio_chal => 1);
        }
        $ret .= LJ::html_text({ name =>'answer', size =>15 });
        $ret .= LJ::html_hidden(captcha_chal => $captcha_chal);
        $ret .= '<br />';
    }

    if ($LJ::SPELLER) {
        $ret .= "<label for='spellcheck'>$BML::ML{'talk.spellcheck'}:</label> <input type='checkbox' name='do_spellcheck' value='1' id='spellcheck' /> ";
    }

    $ret .= "<label for='prop_opt_preformatted'>$BML::ML{'.opt.noautoformat'}</label>";
    $ret .= LJ::html_check(
                           {
                               name  => 'prop_opt_preformatted',
                               id    => 'prop_opt_preformatted',
                               value => 1,
                               selected => $form->{'prop_opt_preformatted'}
                           }
    );
    
    if (defined $LJ::HELPURL{'noautoformat'}) {
        $ret .= " <a href='$LJ::HELPURL{'noautoformat'}'><img src='$LJ::IMGPREFIX/help.gif' alt='$BML::ML{'Help'}' title='$BML::ML{'Help'}' width='14' height='14' border='0' /></a>";
    }

    # post and preview buttons
    my $limit = LJ::CMAX_COMMENT; # javascript String.length uses characters
    $ret .= <<LOGIN;
    <br />
    <script language="JavaScript" type='text/javascript'> 
        <!--
        function checkLength() {
            if (!document.getElementById) return true;
            var textbox = document.getElementById('commenttext');
            if (!textbox) return true;
            if (textbox.value.length > $limit) {
                alert('Sorry, but your comment of ' + textbox.value.length + ' characters exceeds the maximum character length of $limit.  Please try shortening it and then post again.');
                return false;
            }
            return true;
        }
        
        if (document.getElementById && document.getElementById('postform')) {
            document.write("<input name='submitpost' onclick='return checkLength() && sendForm(\\"postform\\", \\"username\\")' type='submit' value='$BML::ML{'.opt.submit'}' />");
            document.write("&nbsp;");
            document.write("<input name='submitpreview' onclick='return checkLength() && sendForm(\\"postform\\", \\"username\\")' type='submit' value='$BML::ML{'talk.btn.preview'}' />");
        } else {
            document.write("<input type='submit' name='submitpost' value='$BML::ML{'.opt.submit'}' />");
            document.write("&nbsp;");
            document.write("<input type='submit' name='submitpreview' value='$BML::ML{'talk.btn.preview'}' />");
        }
        // -->
    </script>
    <noscript>
        <input type='submit' name='submitpost' value='$BML::ML{'.opt.submit'}' />
        &nbsp;
        <input type='submit' name='submitpreview' value='$BML::ML{'talk.btn.preview'}' />
    </noscript>
LOGIN

    if ($journalu->{'opt_logcommentips'} eq "A") {
        $ret .= "<br />$BML::ML{'.logyourip'}";
        $ret .= LJ::help_icon("iplogging", " ");
    }
    if ($journalu->{'opt_logcommentips'} eq "S") {
        $ret .= "<br />$BML::ML{'.loganonip'}";
        $ret .= LJ::help_icon("iplogging", " ");
    }

    $ret .= "</td></tr></td></tr></table>\n";

    # Some JavaScript to help the UI out

    $ret .= "<script type='text/javascript' language='JavaScript'>\n";
    $ret .= "var usermismatchtext = \"" . LJ::ejs($BML::ML{'.usermismatch'}) . "\";\n";
    $ret .= "</script><script type='text/javascript' language='JavaScript' src='$LJ::JSPREFIX/talkpost.js'></script>";
    $ret .= "</form>\n";

    return $ret;
}

# <LJFUNC>
# name: LJ::record_anon_comment_ip
# class: web
# des: Records the IP address of an anonymous comment
# args: journalu, jtalkid, ip
# des-journalu: User object of journal comment was posted in.
# des-jtalkid: ID of this comment.
# des-ip: IP address of the poster.
# returns: 1 for success, 0 for failure
# </LJFUNC> 
sub record_anon_comment_ip {
    my ($journalu, $jtalkid, $ip) = @_;
    $journalu = LJ::want_user($journalu);
    $jtalkid += 0;
    return 0 unless LJ::isu($journalu) && $jtalkid && $ip;

    $journalu->do("INSERT INTO tempanonips (reporttime, journalid, jtalkid, ip) VALUES (UNIX_TIMESTAMP(),?,?,?)",
                  undef, $journalu->{userid}, $jtalkid, $ip);
    return 0 if $journalu->err;
    return 1;
}

# <LJFUNC>
# name: LJ::mark_comment_as_spam
# class: web
# des: Copies a comment into the global spamreports table
# args: journalu, jtalkid
# des-journalu: User object of journal comment was posted in.
# des-jtalkid: ID of this comment.
# returns: 1 for success, 0 for failure
# </LJFUNC> 
sub mark_comment_as_spam {
    my ($journalu, $jtalkid) = @_;
    $journalu = LJ::want_user($journalu);
    $jtalkid += 0;
    return 0 unless $journalu && $jtalkid;

    my $dbcr = LJ::get_cluster_def_reader($journalu);
    my $dbh = LJ::get_db_writer();

    # step 1: get info we need
    my $row = LJ::Talk::get_talk2_row($dbcr, $journalu->{userid}, $jtalkid);
    my $temp = LJ::get_talktext2($journalu, $jtalkid);
    my ($subject, $body, $posterid) = ($temp->{$jtalkid}[0], $temp->{$jtalkid}[1], $row->{posterid});
    return 0 unless $body;

    # step 2: get ip if anon
    my $ip;
    unless ($posterid) {
        $ip = $dbcr->selectrow_array('SELECT ip FROM tempanonips WHERE journalid=? AND jtalkid=?',
                                      undef, $journalu->{userid}, $jtalkid);
        return 0 if $dbcr->err;

        # we want to fail out if we have no IP address and this is anonymous, because otherwise
        # we have a completely useless spam report.  pretend we were successful, too.
        return 1 unless $ip;

        # we also want to log this attempt so that we can do some throttling
        my $rates = LJ::MemCache::get("spamreports:anon:$ip") || $RATE_DATAVER;
        $rates .= pack("N", time);
        LJ::MemCache::set("spamreports:anon:$ip", $rates);
    }
    
    # step 3: insert into spamreports
    $dbh->do('INSERT INTO spamreports (reporttime, posttime, ip, journalid, posterid, subject, body) ' .
             'VALUES (UNIX_TIMESTAMP(), UNIX_TIMESTAMP(?), ?, ?, ?, ?, ?)', 
             undef, $row->{datepost}, $ip, $journalu->{userid}, $posterid, $subject, $body);
    return 0 if $dbh->err;
    return 1;
}

# <LJFUNC>
# name: LJ::Talk::get_talk2_row
# class: web
# des: Gets a row of data from talk2.
# args: dbcr, journalid, jtalkid
# des-dbcr: Database handle to read from.
# des-journalid: Journal id that comment is posted in.
# des-jtalkid: Journal talkid of comment.
# returns: Hashref of row data, or undef on error.
# </LJFUNC>
sub get_talk2_row {
    my ($dbcr, $journalid, $jtalkid) = @_;
    return $dbcr->selectrow_hashref('SELECT journalid, jtalkid, nodetype, nodeid, parenttalkid, ' .
                                    '       posterid, datepost, state ' .
                                    'FROM talk2 WHERE journalid = ? AND jtalkid = ?',
                                    undef, $journalid+0, $jtalkid+0);
}

# get a comment count for a journal entry.
sub get_replycount {
    my ($ju, $jitemid) = @_;
    $jitemid += 0;
    return undef unless $ju && $jitemid;

    my $memkey = [$ju->{'userid'}, "rp:$ju->{'userid'}:$jitemid"];
    my $count = LJ::MemCache::get($memkey);
    return $count if defined $count;

    my $dbcr = LJ::get_cluster_def_reader($ju);
    return unless $dbcr;

    $count = $dbcr->selectrow_array("SELECT replycount FROM log2 WHERE " .
                                    "journalid=? AND jitemid=?", undef,
                                    $ju->{'userid'}, $jitemid);
    LJ::MemCache::add($memkey, $count);
    return $count;
}

package LJ::Talk::Post;

sub format_text_mail {
    my ($targetu, $parent, $comment, $talkurl, $item) = @_;
    my $dtalkid = $comment->{talkid}*256 + $item->{anum};

    $Text::Wrap::columns = 20000; # was 76; -- temp hack!!!

    my $who = "Somebody";
    if ($comment->{u}) {
        $who = "$comment->{u}{name} ($comment->{u}{user})";
    }

    my $text = "";
    if (LJ::u_equals($targetu, $comment->{u})) {
        if ($parent->{ispost}) {
            $who = "$parent->{u}{name} ($parent->{u}{user})";
            $text .= "You left a comment in a post by $who.  ";
            $text .= "The entry you replied to was:";
        } else {
            $text .= "You left a comment in reply to another comment.  ";
            $text .= "The comment you replied to was:";
        }
    } elsif (LJ::u_equals($targetu, $item->{entryu})) {
        if ($parent->{ispost}) {
            $text .= "$who replied to your $LJ::SITENAMESHORT post in which you said:";
        } else {
            $text .= "$who replied to another comment somebody left in your $LJ::SITENAMESHORT post.  ";
            $text .= "The comment they replied to was:";
        }
    } else {
        $text .= "$who replied to your $LJ::SITENAMESHORT comment in which you said:";
    }
    $text .= "\n\n";
    $text .= indent($parent->{body}, ">") . "\n\n";
    $text .= (LJ::u_equals($targetu, $comment->{u}) ? 'Your' : 'Their') . " reply was:\n\n";
    if ($comment->{subject}) {
        $text .= Text::Wrap::wrap("  Subject: ",
                                  "           ",
                                  $comment->{subject}) . "\n\n";
    }
    $text .= indent($comment->{body});
    $text .= "\n\n";

    my $can_unscreen = $comment->{state} eq 'S' && 
                       LJ::Talk::can_unscreen($targetu, $item->{journalu}, $item->{entryu},
                                              $comment->{u} ? $comment->{u}{user} : undef);

    if ($comment->{state} eq 'S') {
        $text .= "This comment was screened.  ";
        $text .= $can_unscreen ? 
                 "You must respond to it or unscreen it before others can see it.\n\n" :
                 "Someone else must unscreen it before you can reply to it.\n\n";
    }

    my $opts = "";
    $opts .= "Options:\n\n";
    $opts .= "  - View the discussion:\n";
    $opts .= "    " . LJ::Talk::talkargs($talkurl, "thread=$dtalkid") . "\n";
    $opts .= "  - View all comments on the entry:\n";
    $opts .= "    $talkurl\n";
    $opts .= "  - Reply to the comment:\n";
    $opts .= "    " . LJ::Talk::talkargs($talkurl, "replyto=$dtalkid") . "\n";
    if ($can_unscreen) {
        $opts .= "  - Unscreen the comment:\n";
        $opts .= "    $LJ::SITEROOT/talkscreen.bml?mode=unscreen&journal=$item->{journalu}{user}&talkid=$dtalkid\n";
    }
    if (LJ::Talk::can_delete($targetu, $item->{journalu}, $item->{entryu}, 
                                $comment->{u} ? $comment->{u}{user} : undef)) {
        $opts .= "  - Delete the comment:\n";
        $opts .= "    $LJ::SITEROOT/delcomment.bml?journal=$item->{journalu}{user}&id=$dtalkid\n";
    }
    
    my $footer = "";
    $footer .= "-- $LJ::SITENAME\n\n";
    $footer .= "(If you'd prefer to not get these updates, go to $LJ::SITEROOT/editinfo.bml and turn off the relevant options.)";
    return Text::Wrap::wrap("", "", $text) . "\n" . $opts . "\n" . Text::Wrap::wrap("", "", $footer);
}

sub format_html_mail {
    my ($targetu, $parent, $comment, $encoding, $talkurl, $item) = @_;
    my $ditemid =    $item->{itemid}*256 + $item->{anum};
    my $dtalkid = $comment->{talkid}*256 + $item->{anum};
    my $threadurl = LJ::Talk::talkargs($talkurl, "thread=$dtalkid");

    my $who = "Somebody";
    if ($comment->{u}) {
        $who = "$comment->{u}{name} ".
            "(<a href=\"$LJ::SITEROOT/userinfo.bml?user=$comment->{u}{user}\">$comment->{u}{user}</a>)";
    }

    my $html = "";
    $html .= "<head><meta http-equiv=\"Content-Type\" content=\"text/html; charset=$encoding\" /></head>\n<body>\n";

    my $intro;
    my $cleanbody = $parent->{body};
# Identity comments should be cleaned together with anons - MV, July 2014
    my $anon_comment_t = ($comment->{'u'}->identity() || !$comment->{u});
    if (LJ::u_equals($targetu, $comment->{u})) {
        if ($parent->{ispost}) {
            $who = "$parent->{u}{name} " .
                "(<a href=\"$LJ::SITEROOT/userinfo.bml?user=$parent->{u}{user}\">$parent->{u}{user}</a>)";
            $intro = "You replied to <a href=\"$talkurl\">a $LJ::SITENAMESHORT post</a> in which $who said:";
            LJ::CleanHTML::clean_event(\$cleanbody, {preformatted => $parent->{preformat}});
        } else {
            $intro = "You replied to a comment somebody left in ";
            $intro .= "<a href=\"$talkurl\">a $LJ::SITENAMESHORT post</a>.  ";
            $intro .= "The comment you replied to was:";
            LJ::CleanHTML::clean_comment(\$cleanbody, 
                              { 'preformatted' => $parent->{preformat}, 
                                'anon_comment' => $anon_comment_t });
# was: !$comment->{u} });
        }
    } elsif (LJ::u_equals($targetu, $item->{entryu})) {
        if ($parent->{ispost}) {
            $intro = "$who replied to <a href=\"$talkurl\">your $LJ::SITENAMESHORT post</a> in which you said:";
            LJ::CleanHTML::clean_comment(\$cleanbody, 
                           { 'preformatted' => $parent->{preformat}, 
                             'anon_comment' => $anon_comment_t });
        } else {
            $intro = "$who replied to another comment somebody left in ";
            $intro .= "<a href=\"$talkurl\">your $LJ::SITENAMESHORT post</a>.  ";
            $intro .= "The comment they replied to was:";
            LJ::CleanHTML::clean_comment(\$cleanbody, 
                           { 'preformatted' => $parent->{preformat}, 
                             'anon_comment' => $anon_comment_t });
        }
    } else {
        $intro = "$who replied to <a href=\"$talkurl\">your $LJ::SITENAMESHORT comment</a> ";
        $intro .= "in which you said:";
        LJ::CleanHTML::clean_comment(\$cleanbody, 
                       { 'preformatted' => $parent->{preformat}, 
                         'anon_comment' => $anon_comment_t });
    }

    my $pichtml;
    if ($comment->{u} && $comment->{u}{defaultpicid} || $comment->{pic}) {
        my $picid = $comment->{pic} ? $comment->{pic}{'picid'} : $comment->{u}{'defaultpicid'};
        unless ($comment->{pic}) {
            my %pics;
            LJ::load_userpics(\%pics, [ $comment->{u}, $comment->{u}{'defaultpicid'} ]);
            $comment->{pic} = $pics{$picid};
            # load_userpics doesn't return picid, but we rely on it above
            $comment->{pic}{'picid'} = $picid;
        }
        if ($comment->{pic}) {
            $pichtml = "<img src=\"$LJ::USERPIC_ROOT/$picid/$comment->{pic}{'userid'}\" align='absmiddle' ".
                "width='$comment->{pic}{'width'}' height='$comment->{pic}{'height'}' ".
                "hspace='1' vspace='2' alt='' /> ";
        }
    }

    if ($pichtml) {
        $html .= "<table><tr valign='top'><td>$pichtml</td><td width='100%'>$intro</td></tr></table>\n";
    } else {
        $html .= "<table><tr valign='top'><td width='100%'>$intro</td></tr></table>\n";
    }
    $html .= blockquote($cleanbody);

    $html .= "\n\n" . (LJ::u_equals($targetu, $comment->{u}) ? 'Your' : 'Their') . " reply was:\n\n";
    $cleanbody = $comment->{body};
    LJ::CleanHTML::clean_comment(\$cleanbody, $comment->{preformat});
    my $pics = LJ::Talk::get_subjecticons();
    my $icon = LJ::Talk::show_image($pics, $comment->{subjecticon}); 

    my $heading;
    if ($comment->{subject}) {
        $heading = "<b>Subject:</b> " . LJ::ehtml($comment->{subject});
    }
    $heading .= $icon;
    $heading .= "<br />" if $heading;
    # this needs to be one string so blockquote handles it properly.
    $html .= blockquote("$heading$cleanbody");

    my $can_unscreen = $comment->{state} eq 'S' && 
                       LJ::Talk::can_unscreen($targetu, $item->{journalu}, $item->{entryu},
                                              $comment->{u} ? $comment->{u}{user} : undef);

    if ($comment->{state} eq 'S') {
        $html .= "<p>This comment was screened.  ";
        $html .= $can_unscreen ? 
                 "You must respond to it or unscreen it before others can see it.</p>\n" :
                 "Someone else must unscreen it before you can reply to it.</p>\n";
    }

    $html .= "<p>From here, you can:\n";
    $html .= "<ul><li><a href=\"$threadurl\">View the thread</a> starting from this comment</li>\n";
    $html .= "<li><a href=\"$talkurl\">View all comments</a> to this entry</li>\n";
    $html .= "<li><a href=\"" . LJ::Talk::talkargs($talkurl, "replyto=$dtalkid") . "\">Reply</a> at the webpage</li>\n";
    if ($can_unscreen) {
        $html .= "<li><a href=\"$LJ::SITEROOT/talkscreen.bml?mode=unscreen&journal=$item->{journalu}{user}&talkid=$dtalkid\">Unscreen the comment</a></li>";
    }
    if (LJ::Talk::can_delete($targetu, $item->{journalu}, $item->{entryu}, 
                                $comment->{u} ? $comment->{u}{user} : undef)) {
        $html .= "<li><a href=\"$LJ::SITEROOT/delcomment.bml?journal=$item->{journalu}{user}&id=$dtalkid\">Delete the comment</a></li>";
    }
    $html .= "</ul></p>";

    my $want_form = $comment->{state} eq 'A' || $can_unscreen;  # this should probably be a preference, or maybe just always off.
    if ($want_form) {
        $html .= "If your mail client supports it, you can also reply here:\n";
        $html .= "<blockquote><form method='post' target='ljreply' action=\"$LJ::SITEROOT/talkpost_do.bml\">\n";

        $html .= LJ::html_hidden(
            usertype     =>  "user",
            parenttalkid =>  $comment->{talkid},
            itemid       =>  $ditemid,
            journal      =>  $item->{journalu}{user},
            userpost     =>  $targetu->{user},
            ecphash      =>  LJ::Talk::ecphash($item->{itemid}, $comment->{talkid}, $targetu->{password})
        );

        $html .= "<input type='hidden' name='encoding' value='$encoding' />" unless $encoding eq "UTF-8";
        my $newsub = $comment->{subject};
        unless (!$newsub || $newsub =~ /^Re:/) { $newsub = "Re: $newsub"; }
        $html .= "<b>Subject: </b> <input name='subject' size='40' value=\"" . LJ::ehtml($newsub) . "\" />";
        $html .= "<p><b>Message</b><br /><textarea rows='10' cols='50' wrap='soft' name='body'></textarea>";
        $html .= "<br /><input type='submit' value=\"Post Reply\" />";
        $html .= "</form></blockquote>\n";
    }
    $html .= "<p><font size='-1'>(If you'd prefer to not get these updates, go to <a href=\"$LJ::SITEROOT/editinfo.bml\">your user profile page</a> and turn off the relevant options.)</font></p>\n";
    $html .= "</body>\n";

    return $html;
}

sub indent {
    my $a = shift;
    my $leadchar = shift || " ";
    $Text::Wrap::columns = 20000; # was 76; -- temp hack!!!
    return Text::Wrap::fill("$leadchar ", "$leadchar ", $a);
}

sub blockquote {
    my $a = shift;
    return "<blockquote style='border-left: #000040 2px solid; margin-left: 0px; margin-right: 0px; padding-left: 15px; padding-right: 0px'>$a</blockquote>";
}

sub generate_messageid {
    my ($type, $journalu, $did) = @_;
    # $type = {"entry" | "comment"}
    # $journalu = $u of journal
    # $did = display id of comment/entry

    my $jid = $journalu->{userid};
    return "<$type-$jid-$did\@$LJ::DOMAIN>";
}

# entryu     : user who posted the entry this comment is under.
# journalu   : journal this entry is in.
# parent     : comment/entry this post is in response to.
# comment    : the comment itself.
# item       : entry this comment falls under.
sub mail_comments {
    my ($entryu, $journalu, $parent, $comment, $item) = @_;
    my $itemid = $item->{itemid};
    my $ditemid = $itemid*256 + $item->{anum};
    my $dtalkid = $comment->{talkid}*256 + $item->{anum};
    my $talkurl = LJ::journal_base($journalu) . "/$ditemid.html";
    my $threadurl = LJ::Talk::talkargs($talkurl, "thread=$dtalkid");

    # check to see if parent post is from a registered livejournal user, and 
    # mail them the response
    my $parentcomment = "";
    my $parentmailed = "";  # who if anybody was just mailed

    # message ID of the mythical top-level journal entry (which
    # currently is never emailed) so mail clients can group things
    # together with a comment ancestor if parents are missing
    my $top_msgid = generate_messageid("entry", $journalu, $ditemid);
    # find first parent
    my $par_msgid;
    if (my $ptid = $parent->{talkid}) {
        $par_msgid = generate_messageid("comment", $journalu,
                                        $ptid * 256 + $item->{anum});
    } else {
        # is a reply to the top-level
        $par_msgid = $top_msgid;
        $top_msgid = "";  # so it's not duplicated
    }
    # and this message ID
    my $this_msgid = generate_messageid("comment", $journalu, $dtalkid);

    # if a response to another comment, send a mail to the parent commenter.
    if ($parent->{talkid}) {  
        my $dbcr = LJ::get_cluster_def_reader($journalu);

        # get row of data
        my $row = LJ::Talk::get_talk2_row($dbcr, $journalu->{userid}, $parent->{talkid});
        my $paruserid = $row->{posterid};

        # now get body of comment
        my $temp = LJ::get_talktext2($journalu, $parent->{talkid});
        my $parbody = $temp->{$parent->{talkid}}[1];
        LJ::text_uncompress(\$parbody);
        $parentcomment = $parbody;

        my %props = ($parent->{talkid} => {});
        LJ::load_talk_props2($journalu, [$parent->{talkid}], \%props);
        $parent->{preformat} = $props{$parent->{talkid}}->{'opt_preformatted'};

        # convert to UTF-8 if necessary
        my $parentsubject = $parent->{subject};
        if ($LJ::UNICODE && $props{$parent->{talkid}}->{'unknown8bit'}) {
            LJ::item_toutf8($journalu, \$parentsubject, \$parentcomment, {});
            $props{$parent->{talkid}}->{'unknown8bit'} = 0;  ## ???
            print STDERR "Fixing item_toutf8 in mail_comments $journalu->{'userid'} $itemid $parent->{talkid} $comment->{talkid} \n";
        }
        
        if ($paruserid) {
            my $paru = LJ::load_userid($paruserid);
            LJ::load_user_props($paru, 'mailencoding');
            LJ::load_codes({ "encoding" => \%LJ::CACHE_ENCODINGS } )
                unless %LJ::CACHE_ENCODINGS;

            # we don't want to send email to a parent if the email address on the
            # parent's user is the same as the email address on this comment's user
            # is_diff_email: also so we don't auto-vivify $comment->{u}
            my $is_diff_email = !$comment->{u} || 
                $paru->{'email'} ne $comment->{u}{'email'};
                
            if ($paru->{'opt_gettalkemail'} eq "Y" &&
                $is_diff_email &&
                $paru->{'status'} eq "A")
            {
                $parentmailed = $paru->{'email'};
                my $encoding = $paru->{'mailencoding'} ? $LJ::CACHE_ENCODINGS{$paru->{'mailencoding'}} : "KOI8-R";
                my $part;

                my $headersubject = $comment->{subject};
                if ($LJ::UNICODE && $encoding ne "UTF-8") {
                    $headersubject = Unicode::MapUTF8::from_utf8({-string=>$headersubject, -charset=>$encoding}); 
                }

                if (!LJ::is_ascii($headersubject)) {
                    $headersubject = MIME::Words::encode_mimeword($headersubject, 'B', $encoding);
                }

                my $fromname = $comment->{u} ? LJ::User::display_name($comment->{u}) . " - $LJ::SITENAMEABBREV Comment" : "$LJ::SITENAMESHORT Comment";

                my $msg =  new MIME::Lite ('From' => "$LJ::BOGUS_EMAIL ($fromname)",
                                           'To' => $paru->{'email'},
                                           'Subject' => ($headersubject || "Reply to your comment..."),
                                           'Type' => 'multipart/alternative',
                                           'Message-Id' => $this_msgid,
                                           'In-Reply-To:' => $par_msgid,
                                           'References' => "$top_msgid $par_msgid",
                                           );
                $msg->add('X-LJ-JOURNAL' => $journalu->{'user'}); # for mail filters

                $parent->{u} = $paru;
                $parent->{body} = $parentcomment;
                $parent->{ispost} = 0;
                $item->{entryu} = $entryu;
                $item->{journalu} = $journalu;
                my $text = format_text_mail($paru, $parent, $comment, $talkurl, $item);
 
                if ($LJ::UNICODE && $encoding ne "UTF-8") {
                    $text = Unicode::MapUTF8::from_utf8({-string=>$text, -charset=>$encoding}); 
                }
                $part = $msg->attach('Type' => 'TEXT',
                                     'Data' => $text,
                                     'Encoding' => 'quoted-printable',
                                     );
                $part->attr("content-type.charset" => $encoding);
#                    if $LJ::UNICODE;

                if ($paru->{'opt_htmlemail'} eq "Y") {
                    my $html = format_html_mail($paru, $parent, $comment, $encoding, $talkurl, $item);
                    if ($LJ::UNICODE && $encoding ne "UTF-8") {
                        $html = Unicode::MapUTF8::from_utf8({-string=>$html, -charset=>$encoding}); 
                    }
                    $part = $msg->attach('Type' => 'text/html',
                                         'Data' => $html,
                                         'Encoding' => 'quoted-printable',
                                         );
                    $part->attr("content-type.charset" => $encoding)
                        if $LJ::UNICODE;
                }

                LJ::send_mail($msg);
            }
        }
    }

    # send mail to the poster of the entry
    if ($entryu->{'opt_gettalkemail'} eq "Y" &&
        !$item->{props}->{'opt_noemail'} &&
        !LJ::u_equals($comment->{u}, $entryu) &&
        $entryu->{'email'} ne $parentmailed &&
        $entryu->{'status'} eq "A") 
    {
        LJ::load_user_props($entryu, 'mailencoding');
        LJ::load_codes({ "encoding" => \%LJ::CACHE_ENCODINGS } )
            unless %LJ::CACHE_ENCODINGS;
        my $encoding = $entryu->{'mailencoding'} ? $LJ::CACHE_ENCODINGS{$entryu->{'mailencoding'}} : "KOI8-R";
        my $part;

        my $headersubject = $comment->{subject};
        if ($LJ::UNICODE && $encoding ne "UTF-8") {
            $headersubject = Unicode::MapUTF8::from_utf8({-string=>$headersubject, -charset=>$encoding}); 
        }

        if (!LJ::is_ascii($headersubject)) {
            $headersubject = MIME::Words::encode_mimeword($headersubject, 'B', $encoding);
        }

        my $fromname = $comment->{u} ? LJ::User::display_name($comment->{u}) . " - $LJ::SITENAMEABBREV Comment" : "$LJ::SITENAMESHORT Comment";
  
        my $msg =  new MIME::Lite ('From' => "$LJ::BOGUS_EMAIL ($fromname)",
                                   'To' => $entryu->{'email'},
                                   'Subject' => ($headersubject || "Reply to your post..."),
                                   'Type' => 'multipart/alternative',
                                   'Message-Id' => $this_msgid,
                                   'In-Reply-To:' => $par_msgid,
                                   'References' => "$top_msgid $par_msgid",
                                   );
        $msg->add('X-LJ-JOURNAL' => $journalu->{'user'}); # for mail filters

        my $quote = $parentcomment ? $parentcomment : $item->{'event'};

        # if this is a response to a comment inside our journal,
        # we don't know who made the parent comment
        # (and it's potentially anonymous).
        if ($parentcomment) {
            $parent->{u} = undef;
            $parent->{body} = $parentcomment;
            $parent->{ispost} = 0;
        } else {
            $parent->{u} = $entryu;
            $parent->{body} = $item->{'event'},
            $parent->{ispost} = 1; 
            $parent->{preformat} = $item->{'props'}->{'opt_preformatted'};
        }
        $item->{entryu} = $entryu;
        $item->{journalu} = $journalu;

        my $text = format_text_mail($entryu, $parent, $comment, $talkurl, $item);

        if ($LJ::UNICODE && $encoding ne "UTF-8") {
            $text = Unicode::MapUTF8::from_utf8({-string=>$text, -charset=>$encoding}); 
        }
        $part = $msg->attach('Type' => 'TEXT',
                             'Data' => $text,
                             'Encoding' => 'quoted-printable',
                             );
        $part->attr("content-type.charset" => $encoding)
            if $LJ::UNICODE;
        
        if ($entryu->{'opt_htmlemail'} eq "Y") {
            my $html = format_html_mail($entryu, $parent, $comment, $encoding, $talkurl, $item);
            if ($LJ::UNICODE && $encoding ne "UTF-8") {
                $html = Unicode::MapUTF8::from_utf8({-string=>$html, -charset=>$encoding}); 
            }
            $part = $msg->attach('Type' => 'text/html',
                                 'Data' => $html,
                                 'Encoding' => 'quoted-printable',
                                 );
            $part->attr("content-type.charset" => $encoding);
#                if $LJ::UNICODE;
        }
        
        LJ::send_mail($msg);
    }

    # now send email to the person who posted the comment we're using?  only if userprop
    # opt_getselfemail is turned on.  no need to check for active/suspended accounts, as
    # they couldn't have posted if they were.  (and if they did somehow, we're just emailing
    # them, so it shouldn't matter.)
    my $u = $comment->{u};
    LJ::load_user_props($u, 'opt_getselfemail', 'mailencoding') if $u;
    if ($u && $u->{'opt_getselfemail'} && LJ::get_cap($u, 'getselfemail')) {
        LJ::load_codes({ "encoding" => \%LJ::CACHE_ENCODINGS } )
            unless %LJ::CACHE_ENCODINGS;
        my $encoding = $u->{'mailencoding'} ? $LJ::CACHE_ENCODINGS{$u->{'mailencoding'}} : "KOI8-R";
        my $part;

        my $headersubject = $comment->{subject};
        if ($LJ::UNICODE && $encoding ne "UTF-8") {
            $headersubject = Unicode::MapUTF8::from_utf8({-string=>$headersubject, -charset=>$encoding}); 
        }

        if (!LJ::is_ascii($headersubject)) {
            $headersubject = MIME::Words::encode_mimeword($headersubject, 'B', $encoding);
        }

        my $msg = new MIME::Lite ('From' => "$LJ::BOGUS_EMAIL ($u->{'user'} - $LJ::SITENAMEABBREV Comment)",
                                  'To' => $u->{'email'},
                                  'Subject' => ($headersubject || "Comment you posted..."),
                                  'Type' => 'multipart/alternative',
                                  'Message-Id' => $this_msgid,
                                  'In-Reply-To:' => $par_msgid,
                                  'References' => "$top_msgid $par_msgid",
                                  );
        $msg->add('X-LJ-JOURNAL' => $journalu->{'user'}); # for mail filters

        my $quote = $parentcomment ? $parentcomment : $item->{'event'};

        # if this is a response to a comment inside our journal,
        # we don't know who made the parent comment
        # (and it's potentially anonymous).
        if ($parentcomment) {
            $parent->{u} = undef;
            $parent->{body} = $parentcomment;
            $parent->{ispost} = 0;
        } else {
            $parent->{u} = $entryu;
            $parent->{body} = $item->{'event'},
            $parent->{ispost} = 1; 
            $parent->{preformat} = $item->{'props'}->{'opt_preformatted'};
        }
        $item->{entryu} = $entryu;
        $item->{journalu} = $journalu;

        my $text = format_text_mail($u, $parent, $comment, $talkurl, $item);

        if ($LJ::UNICODE && $encoding ne "UTF-8") {
            $text = Unicode::MapUTF8::from_utf8({-string=>$text, -charset=>$encoding}); 
        }
        $part = $msg->attach('Type' => 'TEXT',
                             'Data' => $text,
                             'Encoding' => 'quoted-printable',
                             );
        $part->attr("content-type.charset" => $encoding)
            if $LJ::UNICODE;
        
        if ($u->{'opt_htmlemail'} eq "Y") {
            my $html = format_html_mail($u, $parent, $comment, $encoding, $talkurl, $item);
            if ($LJ::UNICODE && $encoding ne "UTF-8") {
                $html = Unicode::MapUTF8::from_utf8({-string=>$html, -charset=>$encoding}); 
            }
            $part = $msg->attach('Type' => 'text/html',
                                 'Data' => $html,
                                 'Encoding' => 'quoted-printable',
                                 );
            $part->attr("content-type.charset" => $encoding);
#                if $LJ::UNICODE;
        }
        
        LJ::send_mail($msg);

    }
}

sub enter_comment {
    my ($journalu, $parent, $item, $comment, $errref) = @_;

    my $partid = $parent->{talkid};
    my $itemid = $item->{itemid};

    my $err = sub {
        $$errref = join(": ", @_);
        return 0;
    };

    return $err->("Invalid user object passed.")
        unless LJ::isu($journalu);

    use Golem;
    my $tnet = Golem::get_containing_net(LJ::get_remote_ip(), {"with_props" => 1});
    $tnet = Golem::get_net(LJ::get_remote_ip(), 32, {"with_props" => 1}) unless $tnet;
    if ($tnet && $tnet->{'props'}->{'data'}->{'ban_comments'} &&
      $tnet->{'props'}->{'data'}->{'ban_comments'}->{$journalu->{'userid'}}) {
      return $err->('Sorry, you are not allowed to leave comments.');
    }

    my $jtalkid = LJ::alloc_user_counter($journalu, "T");
    return $err->("Database Error", "Could not generate a talkid necessary to post this comment.")
        unless $jtalkid; 

    # insert the comment
    my $posterid = $comment->{u} ? $comment->{u}{userid} : 0;
    
    my $errstr;
    $journalu->talk2_do("L", $itemid, \$errstr,
                 "INSERT INTO talk2 ".
                 "(journalid, jtalkid, nodetype, nodeid, parenttalkid, posterid, datepost, state) ".
                 "VALUES (?,?,'L',?,?,?,NOW(),?)",
                 $journalu->{userid}, $jtalkid, $itemid, $partid, $posterid, $comment->{state});
    if ($errstr) {
        return $err->("Database Error",
            "There was an error posting your comment to the database.  " .
            "Please report this.  The error is: <b>$errstr</b>");
    }

    LJ::MemCache::incr([$journalu->{'userid'}, "talk2ct:$journalu->{'userid'}"]);

    $comment->{talkid} = $jtalkid;

    # record IP if anonymous
    LJ::Talk::record_anon_comment_ip($journalu, $comment->{talkid}, LJ::get_remote_ip()) 
        unless $posterid;
    
    # add to poster's talkleft table, or the xfer place
    if ($posterid) {
        my $table;
        my $db = LJ::get_cluster_master($comment->{u});

        if ($db) {
            # remote's cluster is writable
            $table = "talkleft";
        } else {
            # log to global cluster, another job will move it later.
            $db = LJ::get_db_writer();
            $table = "talkleft_xfp";
        }
        my $pub  = $item->{'security'} eq "public" ? 1 : 0;
        if ($db) {
            $db->do("INSERT INTO $table (userid, posttime, journalid, nodetype, ".
                    "nodeid, jtalkid, publicitem) VALUES (?, UNIX_TIMESTAMP(), ".
                    "?, 'L', ?, ?, ?)", undef,
                    $posterid, $journalu->{userid}, $itemid, $jtalkid, $pub);
            
            LJ::MemCache::incr([$posterid, "talkleftct:$posterid"]);
        } else {
            # both primary and backup talkleft hosts down.  can't do much now.
        }
    }

    $journalu->do("INSERT INTO talktext2 (journalid, jtalkid, subject, body) ".
                  "VALUES (?, ?, ?, ?)", undef,
                  $journalu->{userid}, $jtalkid, $comment->{subject}, 
                  LJ::text_compress($comment->{body}));
    die $journalu->errstr if $journalu->err;

    my $memkey = "$journalu->{'clusterid'}:$journalu->{'userid'}:$jtalkid";
    LJ::MemCache::set([$journalu->{'userid'},"talktext:$memkey"], [$comment->{subject}, $comment->{body}]); #$comment->{unknown8bit} ?

    # dudata
    my $bytes = length($comment->{subject}) + length($comment->{body});
    # we used to do a LJ::dudata_set(..) on 'T' here, but decided
    # we could defer that.  to find size of a journal, summing
    # bytes in dudata is too slow (too many seeks)

    my %talkprop;   # propname -> value
    # meta-data
    $talkprop{'unknown8bit'} = 1 if $comment->{unknown8bit};
    $talkprop{'subjecticon'} = $comment->{subjecticon};

    $talkprop{'picture_keyword'} = $comment->{picture_keyword};

    $talkprop{'opt_preformatted'} = $comment->{preformat} ? 1 : 0;
    if ($journalu->{'opt_logcommentips'} eq "A" || 
        ($journalu->{'opt_logcommentips'} eq "S" && $comment->{usertype} ne "user")) 
    {
        my $ip = BML::get_remote_ip();
        my $proxies = join(", ", LJ::filter_out_ip($ip, BML::get_client_header('X-Forwarded-For')));
        my $old_fs = $/;
        $/ = ", ";
        chomp($proxies);
        $/ = $old_fs;
        $ip = "$ip, via $proxies" if $proxies;
        $talkprop{'poster_ip'} = $ip;
    }

    # remove blank/0 values (defaults)
    foreach (keys %talkprop) { delete $talkprop{$_} unless $talkprop{$_}; }

    # update the talkprops
    LJ::load_props("talk");
    if (%talkprop) {
        my $values;
        my $hash = {};
        foreach (keys %talkprop) {
            my $p = LJ::get_prop("talk", $_);
            next unless $p;
            $hash->{$_} = $talkprop{$_};
            my $tpropid = $p->{'tpropid'};
            my $qv = $journalu->quote($talkprop{$_});
            $values .= "($journalu->{'userid'}, $jtalkid, $tpropid, $qv),";
        }
        if ($values) {
            chop $values;
            $journalu->do("INSERT INTO talkprop2 (journalid, jtalkid, tpropid, value) ".
                      "VALUES $values");
            die $journalu->errstr if $journalu->err;
        }
        LJ::MemCache::set([$journalu->{'userid'}, "talkprop:$journalu->{'userid'}:$jtalkid"], $hash);
    }

    # record up to 25 (or $LJ::TALK_MAX_URLS) urls from a comment
    my (%urls, $dbh);
    if ($LJ::TALK_MAX_URLS && 
        ( %urls = map { $_ => 1 } LJ::get_urls($comment->{body}) ) &&
        ( $dbh = LJ::get_db_writer() )) # don't log if no db available
    {
        my (@bind, @vals);
        my $ip = LJ::get_remote_ip();
        while (my ($url, undef) = each %urls) {
            push @bind, '(?,?,?,?,UNIX_TIMESTAMP(),?)';
            push @vals, $posterid, $journalu->{userid}, $ip, $jtalkid, $url;
            last if @bind >= $LJ::TALK_MAX_URLS;
        }
        my $bind = join(',', @bind);
        my $sql = qq{
            INSERT DELAYED INTO commenturls
                (posterid, journalid, ip, jtalkid, timecreate, url)
            VALUES $bind
        };
        $dbh->do($sql, undef, @vals);
    }
    
    # update the "replycount" summary field of the log table
    if ($comment->{state} eq 'A') {
        LJ::replycount_do($journalu, $itemid, "incr");
    }

    # update the "hasscreened" property of the log item if needed
    if ($comment->{state} eq 'S') {
        LJ::Talk::screenedcount_do($journalu, $itemid, "incr");
    }
    
    return $jtalkid;
}

# XXX these strings should be in talk, but moving them means we have
# to retranslate.  so for now we're just gonna put it off.
my $SC = '/talkpost_do.bml';

sub init {
    my ($form, $remote, $need_captcha, $errret) = @_;
    my $sth;

    my $err = sub {
        my $error = shift;
        push @$errret, $error;

        my $ip = LJ::get_remote_ip();
        print STDERR "$ip talklib.pl:  $error\n";
        # change return status from 200 to 403:
        BML::set_status(403); # 403 Forbidden

        return undef;
    };
    my $bmlerr = sub {
        return $err->($BML::ML{$_[0]});
    };

    my $init = LJ::Talk::init($form);
    return $err->($init->{error}) if $init->{error}; 

    my $journalu = $init->{'journalu'};
    return $bmlerr->('talk.error.nojournal') unless $journalu;
    return $err->($LJ::MSG_READONLY_USER) if LJ::get_cap($journalu, "readonly");

    return $err->("Account is locked, unable to post comment.") if $journalu->{statusvis} eq 'L';

    my $r = Apache->request;
    $r->notes("journalid" => $journalu->{'userid'});

    my $dbcr = LJ::get_cluster_def_reader($journalu);
    return $bmlerr->('error.nodb') unless $dbcr;

    my $itemid = $init->{'itemid'}+0;

    my $item = LJ::Talk::get_journal_item($journalu, $itemid);

    if ($init->{'oldurl'} && $item) {
        $init->{'anum'} = $item->{'anum'};
        $init->{'ditemid'} = $init->{'itemid'}*256 + $item->{'anum'};
    }

    unless ($item && $item->{'anum'} == $init->{'anum'}) {
        return $bmlerr->('talk.error.noentry');
    }

    my $iprops = $item->{'props'};
    my $ditemid = $init->{'ditemid'}+0;

    my $talkurl = LJ::journal_base($journalu) . "/$ditemid.html";
    $init->{talkurl} = $talkurl;

    ### load users
    LJ::load_userids_multiple([
                               $item->{'posterid'} => \$init->{entryu},
                               ], [ $journalu ]);
    LJ::load_user_props($journalu, "opt_logcommentips");

    if ($form->{'userpost'} && $form->{'usertype'} ne "user") {
        unless ($form->{'usertype'} eq "cookieuser" &&
                $form->{'userpost'} eq $form->{'cookieuser'}) {
            $bmlerr->("$SC.error.confused_identity");
        }
    }

    # anonymous/cookie users cannot authenticate with ecphash
    if ($form->{'ecphash'} && $form->{'usertype'} ne "user") {
        $bmlerr->("$SC.error.badusername");
        return undef;
    }

    my $cookie_auth;
    if ($form->{'usertype'} eq "cookieuser") {
        $bmlerr->("$SC.error.lostcookie")
            unless ($remote && $remote->{'user'} eq $form->{'cookieuser'});
        return undef if @$errret;
        
        $cookie_auth = 1;
        $form->{'userpost'} = $remote->{'user'};
        $form->{'usertype'} = "user";
    }
    # XXXevan hack:  remove me when we fix preview.
    $init->{cookie_auth} = $cookie_auth;

    # test accounts may only comment on other test accounts.
    if ((grep { $form->{'userpost'} eq $_ } @LJ::TESTACCTS) && 
        !(grep { $journalu->{'user'} eq $_ } @LJ::TESTACCTS))
    {
        $bmlerr->("$SC.error.testacct");
    }

    my $userpost = lc($form->{'userpost'});
    my $up;             # user posting
    my $exptype;        # set to long if ! after username
    my $ipfixed;        # set to remote  ip if < after username
    my $used_ecp;       # ecphash was validated and used

    if ($form->{'usertype'} eq "user") {
        if ($form->{'userpost'}) {

            # parse inline login opts
            if ($form->{'userpost'} =~ s/[!<]{1,2}$//) {
                $exptype = 'long' if index($&, "!") >= 0;
                $ipfixed = LJ::get_remote_ip() if index($&, "<") >= 0;
            }

            $up = LJ::load_user($form->{'userpost'});
            if ($up) {
                ### see if the user is banned from posting here
                if (LJ::is_banned($up, $journalu)) {
                    $bmlerr->("$SC.error.banned");
                }

                unless ($up->{'journaltype'} eq "P" ||
                        ($up->{'journaltype'} eq "I" && $cookie_auth)) {
                    $bmlerr->("$SC.error.postshared");
                }

                # if we're already authenticated via cookie, then userpost was set
                # to the authenticated username, so we got into this block, but we
                # don't want to re-authenticate, so just skip this
                unless ($cookie_auth) {

                    # if ecphash present, authenticate on that
                    if ($form->{'ecphash'}) {

                        if ($form->{'ecphash'} eq
                            LJ::Talk::ecphash($itemid, $form->{'parenttalkid'}, $up->{'password'}))
                        {
                            $used_ecp = 1;
                        } else {
                            $bmlerr->("$SC.error.badpassword");
                        }

                    # otherwise authenticate on username/password
                    } else {
                        my $ok;
                        if ($form->{response}) {
                            $ok = LJ::challenge_check_login($up, $form->{chal}, $form->{response});
                        } else {
                            $ok = LJ::auth_okay($up, $form->{'password'}, $form->{'hpassword'});
                        }
                        $bmlerr->("$SC.error.badpassword") unless $ok;
                    }
                }

                # if the user chooses to log in, do so
                if ($form->{'do_login'} && ! @$errret) {
                    $init->{didlogin} = $up->make_login_session($exptype, $ipfixed);
                }
            } else {
                $bmlerr->("$SC.error.badusername");
            }
        } else {
            $bmlerr->("$SC.error.nousername");
        }
    }

    # OpenID
    if (LJ::OpenID::consumer_enabled() && (
      ($form->{'usertype'} eq 'openid' || $form->{'usertype'} eq 'openid_cookie') ||
      ($form->{'usertype'} eq 'ljc_openid')
      )) {
        
        if ($form->{'usertype'} eq 'ljc_openid' && $form->{'ljc_oidurl'}) {
          $form->{'oidurl'} = "http://www.livejournal.com/users/" . $form->{'ljc_oidurl'};
#          $form->{'oiddo_login'} = 1;
          $form->{'exptype'} = "long";
        }

        return $err->("No OpenID identity URL entered") unless $form->{'oidurl'};

        use LJ::OpenID;  # to-TOP
        
        if ($remote && defined $remote->openid_identity &&
          (
            $form->{'usertype'} eq 'openid_cookie' ||
            $form->{'usertype'} eq 'openid' && $remote->openid_identity eq $form->{'oidurl'} ||
            $form->{'usertype'} eq 'ljc_openid' && (
              $remote->openid_identity eq "http://www.livejournal.com/users/" . $form->{'ljc_oidurl'} . "/" ||
              $remote->openid_identity eq "http://" . $form->{'ljc_oidurl'} . ".livejournal.com/" ||
              $remote->openid_identity eq "http://users.livejournal.com/" . $form->{'ljc_oidurl'} . "/"
            )
          )
        ) {

          $up = $remote;

          ### see if the user is banned from posting here
          if (LJ::is_banned($up, $journalu)) {
            $bmlerr->("$SC.error.banned");
          }

          if ($form->{'oiddo_login'}) {
            $up->make_login_session($form->{'exptype'}, $form->{'ipfixed'});
    
            if ($form->{'ljc_howlong'}) {
              my $ljc_days = 1;
              if ($form->{'ljc_howlong'} eq "a") {
                $ljc_days = 1;
              }
              if ($form->{'ljc_howlong'} eq "b") {
                $ljc_days = 7;
              }
              if ($form->{'ljc_howlong'} eq "c") {
                $ljc_days = 31;
              }
              if ($form->{'ljc_howlong'} eq "d") {
                $ljc_days = 365;
              }
              BML::set_cookie("ljsession", $BML::COOKIE{'ljsession'}, time() + 60*60*24*$ljc_days, $LJ::COOKIE_PATH, $LJ::COOKIE_DOMAIN);
            }
          }
        } else { # First time through
            my $csr = LJ::OpenID::consumer();
            my $exptype = $form->{'exptype'} ? $form->{'exptype'} : 'short';
            my $etime = $form->{'etime'} ? $form->{'etime'} : 0;
            my $ipfixed = 0;

            # parse inline login opts
            if ($form->{'oidurl'} =~ s/[!<]{1,2}$//) {
                if (index($&, "!") >= 0) {
                    $exptype = 'long';
                    $etime = time()+60*60*24*60;
                }
                $ipfixed = LJ::get_remote_ip() if index($&, "<") >= 0;
            }

            my $tried_local_ref = LJ::OpenID::blocked_hosts($csr);

            my $claimed_id = $csr->claimed_identity($form->{'oidurl'});

            unless ($claimed_id) {
                return $err->("Your OpenID is blocked. Please use another OpenID provider.") if $$tried_local_ref;
                return $err->("No claimed id: ".$csr->err);
            }

            # Store their cleaned up identity url vs what they
            # actually typed in
            $form->{'oidurl'} = $claimed_id->claimed_url();

            # Store the entry
            my $pendcid = LJ::alloc_user_counter($journalu, "C");

            $err->("Unable to allocate pending id") unless $pendcid;

            # Since these were gotten from the oidurl and won't
            # persist in the form data
            $form->{'exptype'} = $exptype;
            $form->{'etime'} = $etime;
            $form->{'ipfixed'} = $ipfixed;
            my $penddata = Storable::nfreeze($form);

            $err->("Unable to get database handle to store pending comment") unless $journalu->writer;

            $journalu->do("INSERT INTO pendcomments (jid, pendcid, data, datesubmit) VALUES (?, ?, ?, UNIX_TIMESTAMP())", undef, $journalu->{'userid'}, $pendcid, $penddata);

            $err->($journalu->errstr) if $journalu->err;

            my $check_url = $claimed_id->check_url(
                                                   return_to      => "$LJ::SITEROOT/talkpost_do.bml?jid=$journalu->{'userid'}&pendcid=$pendcid",
                                                   trust_root     => "http://*.$LJ::DOMAIN/",
                                                   delayed_return => 1,
                                                   );
            # Don't redirect them if errors
            return undef if @$errret;
            return BML::redirect($check_url);
        }
    }

    # validate the challenge/response value (anti-spammer)
    unless ($used_ecp) {
        my $chrp_err;
        if (my $chrp = $form->{'chrp1'}) {
            my ($c_ditemid, $c_uid, $c_time, $c_chars, $c_res) = 
                split(/\-/, $chrp);
            my $chal = "$c_ditemid-$c_uid-$c_time-$c_chars";
            my $secret = LJ::get_secret($c_time);
            my $res = Digest::MD5::md5_hex($secret . $chal);
            if ($res ne $c_res) {
                $chrp_err = "invalid";
            } elsif ($c_time < time() - 2*60*60) {
                $chrp_err = "too_old" if $LJ::REQUIRE_TALKHASH_NOTOLD;
            }
        } else {
            $chrp_err = "missing";
        }
        if ($chrp_err) {
            my $ip = LJ::get_remote_ip();
            if ($LJ::DEBUG_TALKSPAM) {
                my $ruser = $remote ? $remote->{user} : "[nonuser]";
                print STDERR "talkhash error: from $ruser \@ $ip - $chrp_err - $talkurl\n";
            }
            if ($LJ::REQUIRE_TALKHASH) {
                return $err->("Sorry, form expired.  Press back, copy text, reload form, paste into new form, and re-submit.")
                    if $chrp_err eq "too_old";
                return $err->("Missing parameters");
            }
        }
    }

    # check that user can even view this post, which is required
    # to reply to it
    ####  Check security before viewing this post
    unless (LJ::can_view($up, $item)) {
        $bmlerr->("$SC.error.mustlogin") unless (defined $up);
        $bmlerr->("$SC.error.noauth");
        return undef;
    }

    # If the reply is to a comment, check that it exists.
    # if it's screened, check that the user has permission to
    # reply and unscreen it

    my $parpost;
    my $partid = $form->{'parenttalkid'}+0;

    if ($partid) {
        $parpost = LJ::Talk::get_talk2_row($dbcr, $journalu->{userid}, $partid);
        unless ($parpost) {
            $bmlerr->("$SC.error.noparent");
        }

        # can't use $remote because we may get here
        # with a reply from email. so use $up instead of $remote
        # in the call below.

        if ($parpost && $parpost->{'state'} eq "S" && 
            !LJ::Talk::can_unscreen($up, $journalu, $init->{entryu}, $init->{entryu}{'user'})) {
            $bmlerr->("$SC.error.screened");
        }
    }
    $init->{parpost} = $parpost;

    # don't allow anonymous comments on syndicated items
    if ($journalu->{'journaltype'} eq "Y" && $journalu->{'opt_whocanreply'} eq "all") {
        $journalu->{'opt_whocanreply'} = "reg";
    }

    if (
      ($journalu->{'opt_whocanreply'} eq "friends" && $form->{'usertype'} ne "user") ||
      ($journalu->{'opt_whocanreply'} eq "reg" &&
       $form->{'usertype'} ne "user" &&
       $form->{'usertype'} ne "openid" &&
       $form->{'usertype'} ne "openid_cookie" &&
       $form->{'usertype'} ne "cookieuser" &&
       $form->{'usertype'} ne "ljc_openid")
      ) {
        $bmlerr->("$SC.error.noanon");
    }

    if ($iprops->{'opt_nocomments'}) {
        $bmlerr->("$SC.error.nocomments");
    }

    if ($up) {
        if ($up->{'status'} eq "N" && $up->{'journaltype'} ne "I") {
            $bmlerr->("$SC.error.noverify");
        }
        if ($up->{'statusvis'} eq "D") {
            $bmlerr->("$SC.error.deleted");
        } elsif ($up->{'statusvis'} eq "S") {
            $bmlerr->("$SC.error.suspended");
        }
    }

    if ($journalu->{'opt_whocanreply'} eq "friends") {
        if ($up) {
            if ($up->{'userid'} != $journalu->{'userid'}) {
                unless (LJ::is_friend($journalu, $up)) {
                    $err->(BML::ml("$SC.error.notafriend", {'user'=>$journalu->{'user'}}));
                }
            }
        } else {
            $err->(BML::ml("$SC.error.friendsonly", {'user'=>$journalu->{'user'}}));
        }
    }

    $bmlerr->("$SC.error.blankmessage") unless $form->{'body'} =~ /\S/;

    # in case this post comes directly from the user's mail client, it
    # may have an encoding field for us.
    if ($form->{'encoding'}) {
        $form->{'body'} = Unicode::MapUTF8::to_utf8({-string=>$form->{'body'}, -charset=>$form->{'encoding'}});
        $form->{'subject'} = Unicode::MapUTF8::to_utf8({-string=>$form->{'subject'}, -charset=>$form->{'encoding'}});
    }
    
    # unixify line-endings
    $form->{'body'} =~ s/\r\n/\n/g;

    # now check for UTF-8 correctness, it must hold

    return $err->("<?badinput?>") unless LJ::text_in($form);

    $init->{unknown8bit} = 0;
    unless (LJ::is_ascii($form->{'body'}) && LJ::is_ascii($form->{'subject'})) {
        if ($LJ::UNICODE) {
            # no need to check if they're well-formed, we did that above
        } else {
            # so rest of site can change chars to ? marks until
            # default user's encoding is set.  (legacy support)
            $init->{unknown8bit} = 1;
        }
    }

    my ($bl, $cl) = LJ::text_length($form->{'body'});
    if ($cl > LJ::CMAX_COMMENT) {
        $err->(BML::ml("$SC.error.manychars", {'current'=>$cl, 'limit'=>LJ::CMAX_COMMENT}));
    } elsif ($bl > LJ::BMAX_COMMENT) {
        $err->(BML::ml("$SC.error.manybytes", {'current'=>$bl, 'limit'=>LJ::BMAX_COMMENT}));
    }
    # the Subject can be silently shortened, no need to reject the whole comment
    $form->{'subject'} = LJ::text_trim($form->{'subject'}, 100, 100);

    my $subjecticon = "";
    if ($form->{'subjecticon'} ne "none" && $form->{'subjecticon'} ne "") {
        $subjecticon = LJ::trim(lc($form->{'subjecticon'}));
    }

    # figure out whether to post this comment screened
    my $state = 'A';
    my $screening = LJ::Talk::screening_level($journalu, $ditemid >> 8);
    if ($screening eq 'A' ||
      ($screening eq 'R' && !$up) || 
# was: $form->{'usertype'} eq "anonymous") || 
# This causes problems with people filling this form as openid,
# and posting as anonymous - MV
      ($screening eq 'F' && !($up && LJ::is_friend($journalu, $up)))) {
        $state = 'S';
    }
    $state = 'A' if LJ::Talk::can_unscreen($up, $journalu, $init->{entryu}, $init->{entryu}{user});

    my $parent = {
        state     => $parpost->{state},
        talkid    => $partid,
    };
    my $comment = {
        u               => $up,
        usertype        => $form->{'usertype'},
        subject         => $form->{'subject'},
        body            => $form->{'body'},
        unknown8bit     => $init->{unknown8bit},
        subjecticon     => $subjecticon,
        preformat       => $form->{'prop_opt_preformatted'},
        picture_keyword => $form->{'prop_picture_keyword'},
        state           => $state,
    };

    $init->{item} = $item;
    $init->{parent} = $parent;
    $init->{comment} = $comment;

    # anti-spam captcha check
    if (ref $need_captcha eq 'SCALAR') {

        # see if they're in the second+ phases of a captcha check.
        # are they sending us a response?
        if ($form->{captcha_chal}) {

            # assume they won't pass and re-set the flag
            $$need_captcha = 1;

            # if they typed "audio", we don't double-check if they still need
            # a captcha (they still do), they just want an audio version.
            if (lc($form->{answer}) eq 'audio') {
                return;
            }

            my ($capid, $anum) = LJ::Captcha::session_check_code($form->{captcha_chal},
                                                                 $form->{answer}, $journalu);

            return $err->("Incorrect response to spam robot challenge.") unless $capid && $anum;
            my $expire_u = $comment->{'u'} || LJ::load_user('system');
            LJ::Captcha::expire($capid, $anum, $expire_u->{userid});

        } else {

            my $show_captcha = sub {
                return 1 if $LJ::HUMAN_CHECK{'comment_html_auth'};

                # Anonymous commenter
                return 1 if $LJ::HUMAN_CHECK{'comment_html_anon'} && ! LJ::isu($comment->{'u'});

                # Identity commenter
                return 1 if $LJ::HUMAN_CHECK{'comment_html_anon'} &&
                    $comment->{'u'}->identity() &&
                    ! LJ::is_friend($journalu, $comment->{'u'});
            };

            $$need_captcha =
                ($LJ::HUMAN_CHECK{anonpost} || $LJ::HUMAN_CHECK{authpost}) &&
                ! LJ::Talk::Post::check_rate($comment->{'u'}, $journalu, $talkurl);

            if ($show_captcha->()) {
                # see if they have any tags or URLs
                if ($form->{'body'} =~ /<[a-z]/i) {
                    # strip white-listed bare tags w/o attributes,
                    # then see if they still have HTML.  if so, it's
                    # questionable.  (can do evil spammy-like stuff w/
                    # attributes and other elements)
                    my $body_copy = $form->{'body'};
                    $body_copy =~ s/<(?:q|blockquote|b|strong|i|em|cite|sub|sup|var|del|tt|code|pre|p)>//ig;
                    $$need_captcha = 1 if $body_copy =~ /<[a-z]/i;
                }
                # multiple URLs is questionable too
#                $$need_captcha = 1 if
#                    $form->{'body'} =~ /\b(?:http|ftp)\b.+\b(?:http|ftp)\b/s;
                $$need_captcha = 1 if
                    $form->{'body'} =~ /\b(?:http|ftp):\/\//s;
            }

            # if the user is anonymous and the IP is marked, ignore rates and always human test.
            $$need_captcha = 1 if $LJ::HUMAN_CHECK{anonpost} &&
                ! $comment->{'u'} &&
                LJ::sysban_check('talk_ip_test', LJ::get_remote_ip());

            if ($$need_captcha) {
                return $err->("Please confirm you are a human below.");
            }
        }
    }

    return undef if @$errret;
    return $init;
}

# returns 1 on success.  0 on fail (with $$errref set)
sub post_comment {
    my ($entryu, $journalu, $comment, $parent, $item, $errref) = @_;

    # unscreen the parent comment if needed
    if ($parent->{state} eq 'S') {
        LJ::Talk::unscreen_comments($journalu, $item->{itemid}, [$parent->{talkid}]);
        $parent->{state} = 'A';
    }

    # make sure they're not underage
    if ($comment->{u} && $comment->{u}->underage) {
        $$errref = $LJ::UNDERAGE_ERROR;
        return 0;
    }

    # check for duplicate entry (double submission)
    # Note:  we don't do it inside a locked section like ljprotocol.pl's postevent,
    # so it's not perfect, but it works pretty well.
    my $posterid = $comment->{u} ? $comment->{u}{userid} : 0;
    my $jtalkid;

    # check for dup ID in memcache.
    my $memkey;
    if (@LJ::MEMCACHE_SERVERS) {
        my $md5_b64 = Digest::MD5::md5_base64(
            join(":", ($comment->{body}, $comment->{subject},
                       $comment->{subjecticon}, $comment->{preformat},
                       $comment->{picture_keyword})));
        $memkey = [$journalu->{userid}, "tdup:$journalu->{userid}:$item->{itemid}-$parent->{talkid}-$posterid-$md5_b64" ];
        $jtalkid = LJ::MemCache::get($memkey);
    }

    # they don't have a duplicate...
    unless ($jtalkid) {
        # XXX do select and delete $talkprop{'picture_keyword'} if they're lying
        my $pic = LJ::get_pic_from_keyword($comment->{u}, $comment->{picture_keyword});
        delete $comment->{picture_keyword} unless $pic && $pic->{'state'} eq 'N';
        $comment->{pic} = $pic;

        # put the post in the database
        my $ditemid = $item->{itemid}*256 + $item->{anum};
        $jtalkid = enter_comment($journalu, $parent, $item, $comment, $errref);
        return 0 unless $jtalkid;

        # save its identifying characteristics to protect against duplicates.
        LJ::MemCache::set($memkey, $jtalkid+0, time()+60*10);

        # send some emails
        mail_comments($entryu, $journalu, $parent, $comment, $item);

        # log the event
        # this function doesn't do anything.
        # LJ::event_register($dbcm, "R", $journalu->{'userid'}, $ditemid);
        # FUTURE: log events type 'T' (thread) up to root
    }

    # the caller wants to know the comment's talkid.
    $comment->{talkid} = $jtalkid;

    # cluster tracking
    LJ::mark_user_active($comment->{u}, 'comment');

    return 1;
}

# XXXevan:  this function should have its functionality migrated to talkpost.
# because of that, it's probably not worth the effort to make it not mangle $form...
sub make_preview {
    my ($talkurl, $cookie_auth, $form) = @_;
    my $ret = "";

    my $cleansubject = $form->{'subject'};
    LJ::CleanHTML::clean_subject(\$cleansubject);

    $ret .= "<?h1 $BML::ML{'/talkpost_do.bml.preview.title'} h1?><?p $BML::ML{'/talkpost_do.bml.preview'} p?><?hr?>";
    $ret .= "<div align=\"center\"><b>(<a href=\"$talkurl\">$BML::ML{'talk.commentsread'}</a>)</b></div>";

    my $event = $form->{'body'};
    my $spellcheck_html;
    if ($LJ::SPELLER && $form->{'do_spellcheck'}) {
        my $s = new LJ::SpellCheck { 'spellcommand' => $LJ::SPELLER,
                                     'color' => '<?hotcolor?>', };
        $spellcheck_html = $s->check_html(\$event);
    }
    LJ::CleanHTML::clean_comment(\$event, $form->{'prop_opt_preformatted'});

    $ret .= "$BML::ML{'/talkpost_do.bml.preview.subject'} " . LJ::ehtml($cleansubject) . "<hr />\n";
    if ($spellcheck_html) {
        $ret .= $spellcheck_html;
        $ret .= "<p>";
    } else {
        $ret .= $event;
    }

    $ret .= "<hr />";
    $ret .= "<div style='width: 90%'><form method='post'><p>\n";
    $ret .= "<input name='subject' size='50' maxlength='100' value='" . LJ::ehtml($form->{'subject'}) . "' /><br />";
    $ret .= "<textarea class='textbox' rows='10' cols='50' wrap='soft' name='body' style='width: 100%'>";
    $ret .= LJ::ehtml($form->{'body'});
    $ret .= "</textarea></p>";

    # change mode:
    delete $form->{'submitpreview'}; $form->{'submitpost'} = 1;
    if ($cookie_auth) {
        $form->{'usertype'} = "cookieuser";
        delete $form->{'userpost'};
    }
    delete $form->{'do_spellcheck'};
    foreach (keys %$form) {
        $ret .= LJ::html_hidden($_, $form->{$_})
            unless $_ eq 'body' || $_ eq 'subject' || $_ eq 'prop_opt_preformatted';
    }

    $ret .= "<br /><input type='submit' value='$BML::ML{'/talkpost_do.bml.preview.submit'}' />\n";
    $ret .= "<input type='submit' name='submitpreview' value='$BML::ML{'talk.btn.preview'}' />\n";
    if ($LJ::SPELLER) {
        $ret .= "<input type='checkbox' name='do_spellcheck' value='1' id='spellcheck' /> <label for='spellcheck'>$BML::ML{'talk.spellcheck'}</label>";
    }
    $ret .= "<p>";
    $ret .= "$BML::ML{'/talkpost.bml.opt.noautoformat'} ".
        LJ::html_check({ 'name' => 'prop_opt_preformatted', 
                         selected => $form->{'prop_opt_preformatted'} });
    $ret .= LJ::help_icon("noautoformat", " ");
    $ret .= "</p>";

    $ret .= "<p> <?de $BML::ML{'/talkpost.bml.allowedhtml'}: ";
    foreach (sort &LJ::CleanHTML::get_okay_comment_tags()) {
        $ret .= "&lt;$_&gt; ";
    }
    $ret .= "de?> </p>";

    $ret .= "</form></div>";
    return $ret;
}

# given a journalu and jitemid, return 1 if the entry
# is over the maximum comments allowed.
sub over_maxcomments {
    my ($journalu, $jitemid) = @_;
    $journalu = LJ::want_user($journalu);
    $jitemid += 0;
    return 0 unless $journalu && $jitemid;

    my $count = LJ::Talk::get_replycount($journalu, $jitemid);
    return ($count >= LJ::get_cap($journalu, 'maxcomments')) ? 1 : 0;
}

# more anti-spammer rate limiting.  returns 1 if rate is okay, 0 if too fast.
sub check_rate {
    my ($remote, $journalu, $talkurl) = @_;

    # we require memcache to do rate limiting efficiently
    return 1 unless @LJ::MEMCACHE_SERVERS;

    # return right away if the account is suspended
    return 0 if $remote && $remote->{'statusvis'} =~ /[SD]/;

    my $ip = LJ::get_remote_ip();
    my $now = time();
    my @watch;

# Now comments from Openid users are treated the same as anonymous
# vis-a-vis spam rates - MV, Nov 2014 (antimakaka)
    if ($remote && ! $remote->openid_identity) {
        # registered human (or human-impersonating robot)
        push @watch,
          [
            "talklog:$remote->{userid}",
            $LJ::RATE_COMMENT_AUTH || [ [ 200, 3600 ], [ 20, 60 ] ],
          ];
    } else {
        # anonymous, per IP address (robot or human)
        push @watch,
          [
            "talklog:$ip",
            $LJ::RATE_COMMENT_ANON ||
                [ [ 300, 3600 ], [ 200, 1800 ], [ 150, 900 ], [ 15, 60 ] ]
          ];

        # anonymous, per journal.
        # this particular limit is intended to combat flooders, instead
        # of the other 'spammer-centric' limits.
        push @watch,
          [
            "talklog:anonin:$journalu->{userid}",
            $LJ::RATE_COMMENT_ANON ||
                [ [ 300, 3600 ], [ 200, 1800 ], [ 150, 900 ], [ 15, 60 ] ]
          ];

        # throttle based on reports of spam
        push @watch,
          [
            "spamreports:anon:$ip",
            $LJ::SPAM_COMMENT_RATE ||
                [ [ 50, 86400], [ 10, 3600 ] ]
          ];
    }


  WATCH:
    foreach my $watch (@watch) {
        my ($key, $rates) = ($watch->[0], $watch->[1]);
        my $max_period = $rates->[0]->[1];
        
        my $log = LJ::MemCache::get($key);
        
        # parse the old log
        my @times;
        if (length($log) % 4 == 1 && substr($log,0,1) eq $RATE_DATAVER) {
            my $ct = (length($log)-1) / 4;
            for (my $i=0; $i<$ct; $i++) {
                my $time = unpack("N", substr($log,$i*4+1,4));
                push @times, $time if $time > $now - $max_period;
            }
        }
        
        # add this event
        push @times, $now unless $key =~ /^spamreports/;
        
        # check rates
        foreach my $rate (@$rates) {
            my ($allowed, $period) = ($rate->[0], $rate->[1]);
            my $events = scalar grep { $_ > $now-$period } @times;
            if ($events > $allowed) {
                
                if ($LJ::DEBUG_TALK_RATE && 
                    LJ::MemCache::add("warn:$key", 1, 600)) {
        
                my $ruser = (exists $remote->{'user'}) ? $remote->{'user'} : 'Not logged in';
                my $nowtime = localtime($now);
                my $body = <<EOM;
Talk spam from $key:
    $events comments > $allowed allowed / $period secs
    Remote user: $ruser
    Remote IP:   $ip
    Time caught: $nowtime
    Posting to:  $journalu->{'user'}
    URL:         $talkurl
EOM
                    LJ::send_mail({
                        'to' => $LJ::DEBUG_TALK_RATE,
                        'from' => $LJ::ADMIN_EMAIL,
                        'fromname' => $LJ::SITENAME,
                        'charset' => 'utf-8',
                        'subject' => "talk spam: $key",
                        'body' => $body,
                    });
                }

                return 0 if $LJ::ANTI_TALKSPAM;
                last WATCH;
            }
        }
        
        # build the new log
        my $newlog = $RATE_DATAVER;
        foreach (@times) {
            $newlog .= pack("N", $_);
        }
        
        LJ::MemCache::set($key, $newlog, $max_period);
    }

    return 1;
}

1;
