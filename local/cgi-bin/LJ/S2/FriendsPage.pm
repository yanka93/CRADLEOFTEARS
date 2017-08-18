#!/usr/bin/perl
#

use strict;
package LJ::S2;

eval "use LJR::Distributed;";
my $ljr = $@ ? 0 : 1;

if ($ljr) {
  use LJR::Distributed;
}

sub FriendsPage
{
    my ($u, $remote, $opts) = @_;

    my $p = Page($u, $opts);
    $p->{'_type'} = "FriendsPage";
    $p->{'view'} = "friends";
    $p->{'entries'} = [];
    $p->{'friends'} = {};
    $p->{'friends_title'} = LJ::ehtml($u->{'friendspagetitle'});
    $p->{'filter_active'} = 0;
    $p->{'filter_name'} = "";

    my $sth;
    my $user = $u->{'user'};

    # see how often the remote user can reload this page.  
    # "friendsviewupdate" time determines what granularity time
    # increments by for checking for new updates
    my $nowtime = time();

    # update delay specified by "friendsviewupdate"
    my $newinterval = LJ::get_cap_min($remote, "friendsviewupdate") || 1;

    # when are we going to say page was last modified?  back up to the 
    # most recent time in the past where $time % $interval == 0
    my $lastmod = $nowtime;
    $lastmod -= $lastmod % $newinterval;

    # see if they have a previously cached copy of this page they
    # might be able to still use.
    my $ims = $opts->{'r'}->header_in('If-Modified-Since');
    if ($ims) {
        my $theirtime = LJ::http_to_time($ims);

        # send back a 304 Not Modified if they say they've reloaded this 
        # document in the last $newinterval seconds:
        unless ($theirtime < $lastmod) {
            $opts->{'handler_return'} = 304;
            return 1;
        }
    }
    $opts->{'r'}->header_out('Last-Modified', LJ::time_to_http($lastmod));

    my $get = $opts->{'getargs'};

    my $ret;

    if ($get->{'mode'} eq "live") {
        $ret .= "<html><head><title>${user}'s friends: live!</title></head>\n";
        $ret .= "<frameset rows=\"100%,0%\" border=0>\n";
        $ret .= "  <frame name=livetop src=\"friends?mode=framed\">\n";
        $ret .= "  <frame name=livebottom src=\"friends?mode=livecond&amp;lastitemid=0\">\n";
        $ret .= "</frameset></html>\n";
        return $ret;
    }

    if ($u->{'journaltype'} eq "R" && $u->{'renamedto'} ne "") {
        $opts->{'redir'} = LJ::journal_base($u->{'renamedto'}, $opts->{'vhost'}) . "/friends";
        return 1;
    }

    LJ::load_user_props($remote, "opt_nctalklinks", "opt_stylemine", "opt_imagelinks", "opt_ljcut_disable_friends");

    # load options for image links
    my ($maximgwidth, $maximgheight) = (undef, undef);
    ($maximgwidth, $maximgheight) = ($1, $2)
        if ($remote && $remote->{'userid'} == $u->{'userid'} &&
            $remote->{'opt_imagelinks'} =~ m/^(\d+)\|(\d+)$/);

    ## never have spiders index friends pages (change too much, and some 
    ## people might not want to be indexed)
    $p->{'head_content'} .= LJ::robot_meta_tags();

    my $itemshow = S2::get_property_value($opts->{'ctx'}, "page_friends_items")+0;
    if ($itemshow < 1) { $itemshow = 20; }
    elsif ($itemshow > 50) { $itemshow = 50; }
    
    my $skip = $get->{'skip'}+0;
    my $maxskip = ($LJ::MAX_SCROLLBACK_FRIENDS || 1000) - $itemshow;
    if ($skip > $maxskip) { $skip = $maxskip; }
    if ($skip < 0) { $skip = 0; }
    my $itemload = $itemshow+$skip;

    my $dayskip = $get->{'dayskip'}+0;

    my $filter;
    my $group;
    my $common_filter = 1;

    if (defined $get->{'filter'} && $remote && $remote->{'user'} eq $user) {
        $filter = $get->{'filter'}; 
        $common_filter = 0;
        $p->{'filter_active'} = 1;
        $p->{'filter_name'} = "";
    } else {
        if ($opts->{'pathextra'}) {
            $group = $opts->{'pathextra'};
            $group =~ s!^/!!;
            $group =~ s!/$!!;
            if ($group) { $group = LJ::durl($group); $common_filter = 0; }
        }
        if ($group) {
            $p->{'filter_active'} = 1;
            $p->{'filter_name'} = LJ::ehtml($group);
        }
        my $grp = LJ::get_friend_group($u, { 'name' => $group || "Default View" });
        my $bit = $grp->{'groupnum'};
        my $public = $grp->{'is_public'};
        if ($bit && ($public || ($remote && $remote->{'user'} eq $user))) { 
            $filter = (1 << $bit);
        } elsif ($group) {
            $opts->{'badfriendgroup'} = 1;
            return 1;
        }
    }
    
    if ($opts->{'view'} eq "friendsfriends") {
        $p->{'friends_mode'} = "friendsfriends";
    }

    if ($get->{'mode'} eq "livecond") 
    {
        ## load the itemids
        my @items = LJ::get_friend_items({
            'u' => $u,
            'remote' => $remote,
            'itemshow' => 1,
            'skip' => 0,
            'filter' => $filter,
            'common_filter' => $common_filter,
        });
        my $first = @items ? $items[0]->{'itemid'} : 0;

        $ret .= "time = " . scalar(time()) . "<br />";
        $opts->{'headers'}->{'Refresh'} = "30;URL=$LJ::SITEROOT/users/$user/friends?mode=livecond&lastitemid=$first";
        if ($get->{'lastitemid'} == $first) {
            $ret .= "nothing new!";
        } else {
            if ($get->{'lastitemid'}) {
                $ret .= "<b>New stuff!</b>\n";
                $ret .= "<script language=\"JavaScript\">\n";
                $ret .= "window.parent.livetop.location.reload(true);\n";     
                $ret .= "</script>\n";
                $opts->{'trusted_html'} = 1;
            } else {
                $ret .= "Friends Live! started.";
            }
        }
        return $ret;
    }
    
    ## load the itemids 
    my %friends;
    my %friends_row;
    my @items = LJ::get_friend_items({
        'u' => $u,
        'remote' => $remote,
        'itemshow' => $itemshow,
        'skip' => $skip,
        'dayskip' => $dayskip,
        'filter' => $filter,
        'common_filter' => $common_filter,
        'friends_u' => \%friends,
        'friends' => \%friends_row,
        'showtypes' => $get->{'show'},
        'friendsoffriends' => $opts->{'view'} eq "friendsfriends",
        'dateformat' => 'S2',
    });

    while ($_ = each %friends) {
        # we expect fgcolor/bgcolor to be in here later
        $friends{$_}->{'fgcolor'} = $friends_row{$_}->{'fgcolor'} || '#ffffff';
        $friends{$_}->{'bgcolor'} = $friends_row{$_}->{'bgcolor'} || '#000000';
    }

    return $p unless %friends;

    my %posters;
    {
        my @posterids;
        foreach my $item (@items) {
            next if $friends{$item->{'posterid'}};
            push @posterids, $item->{'posterid'};
        }
        LJ::load_userids_multiple([ map { $_ => \$posters{$_} } @posterids ])
            if @posterids;
    }

    my %objs_of_picid;
    my @userpic_load;
    
    my %lite;   # posterid -> s2_UserLite
    my $get_lite = sub {
        my $id = shift;
        return $lite{$id} if $lite{$id};
        return $lite{$id} = UserLite($posters{$id} || $friends{$id});
    };
    
    my $eventnum = 0;
    my $hiddenentries = 0;
  ENTRY:
    foreach my $item (@items) 
    {
        my ($friendid, $posterid, $itemid, $security, $alldatepart) = 
            map { $item->{$_} } qw(ownerid posterid itemid security alldatepart);

        my $fru = $friends{$friendid};
        my ($friend, $poster);
        $friend = $poster = $fru->{'user'};
        $p->{'friends'}->{$fru->{'user'}} ||= Friend($fru);

        my $clusterid = $item->{'clusterid'}+0;

        my $props = $item->{'props'};

        my $replycount = $props->{'replycount'};    
        my $subject = $item->{'text'}->[0];
        my $text    = $item->{'text'}->[1];
        if ($get->{'nohtml'}) {
            # quote all non-LJ tags
            $subject =~ s{<(?!/?lj)(.*?)>} {&lt;$1&gt;}gi;
            $text    =~ s{<(?!/?lj)(.*?)>} {&lt;$1&gt;}gi;
        }

        LJ::CleanHTML::clean_subject(\$subject) if $subject;

        my $ditemid = $itemid * 256 + $item->{'anum'};

        my $stylemine = "";
        $stylemine .= "style=mine" if $remote && $remote->{'opt_stylemine'} &&
                                      $remote->{'userid'} != $friendid;

        LJ::CleanHTML::clean_event(\$text, { 'preformatted' => $props->{'opt_preformatted'},
                                             'cuturl' => LJ::item_link($fru, $itemid, $item->{'anum'}, $stylemine), 
                                             'maximgwidth' => $maximgwidth,
                                             'maximgheight' => $maximgheight,
               'ljcut_disable' => $remote->{'opt_ljcut_disable_friends'}, });
        LJ::expand_embedded($fru, $ditemid, $remote, \$text);

        my $userlite_poster = $get_lite->($posterid);
        my $userlite_journal = $get_lite->($friendid);

        # get the poster user
        my $po = $posters{$posterid} || $friends{$posterid};  

        # don't allow posts from suspended users
        if ($po->{'statusvis'} eq 'S') {
            $hiddenentries++; # Remember how many we've skipped for later
            next ENTRY;
        }

        # do the picture
        my $picid = 0;
        my $picu = undef;
        if ($friendid != $posterid && S2::get_property_value($opts->{ctx}, 'use_shared_pic')) {
            # using the community, the user wants to see shared pictures
            $picu = $fru;

            # use shared pic for community
            $picid = $fru->{defaultpicid};
        } else {
            # we're using the poster for this picture
            $picu = $po;

            # check if they specified one
            $picid = LJ::get_picid_from_keyword($po, $props->{picture_keyword})
                if $props->{picture_keyword};
            
            # fall back on the poster's default
            $picid ||= $po->{defaultpicid};
        }

        my $nc = "";
        $nc .= "nc=$replycount" if $replycount; # && $remote && $remote->{'opt_nctalklinks'};

        my $journalbase = LJ::journal_base($fru);
        my $permalink = "$journalbase/$ditemid.html";
        my $readurl = LJ::Talk::talkargs($permalink, $nc, $stylemine);
        my $posturl = LJ::Talk::talkargs($permalink, "mode=reply", $stylemine);
        my $synurl = "";

        if ($ljr && $props->{'syn_link'}) {
          my $rs = LJR::Distributed::match_remote_server($props->{'syn_link'});
          if ($rs->{"servertype"} eq "lj") {
            $readurl = $props->{'syn_link'};
            $posturl = $props->{'syn_link'} . "?mode=reply";
            $replycount = 'Read';
          }
          else {
            $posturl = $props->{'syn_link'};
            $replycount = undef;
          }
          $synurl = $props->{'syn_link'};
        }

        my $comments = CommentInfo({
            'read_url' => $readurl,
            'post_url' => $posturl,
            'syn_url'  => $synurl,
            'count' => $replycount,
            'maxcomments' => ($replycount >= LJ::get_cap($u, 'maxcomments')) ? 1 : 0,
            'enabled' => ($fru->{'opt_showtalklinks'} eq "Y" &&
                          ! $props->{'opt_nocomments'} ||
                          $props->{'syn_link'}
                          ) ? 1 : 0,
            'screened' => ($remote && LJ::can_manage($remote, $fru) && $props->{'hasscreened'}) ? 1 : 0,
        });

        my $moodthemeid = $u->{'opt_forcemoodtheme'} eq 'Y' ?
            $u->{'moodthemeid'} : $fru->{'moodthemeid'};

        my $entry = Entry($u, {
            'subject' => $subject,
            'text' => $text,
            'dateparts' => $alldatepart,
            'security' => $security,
            'props' => $props,
            'itemid' => $ditemid,
            'journal' => $userlite_journal,
            'poster' => $userlite_poster,
            'comments' => $comments,
            'new_day' => 0,  # setup below
            'end_day' => 0,  # setup below
            'userpic' => undef,
            'permalink_url' => $permalink,
            'base_url' => $journalbase,
            'moodthemeid' => $moodthemeid,
            'enable_tags_compatibility' => [$opts->{enable_tags_compatibility}, $opts->{ctx}],
        });
        $entry->{'_ymd'} = join('-', map { $entry->{'time'}->{$_} } qw(year month day));

        if ($picid && $picu) {
            push @userpic_load, [ $picu, $picid ];
            push @{$objs_of_picid{$picid}}, \$entry->{'userpic'};
        }

        push @{$p->{'entries'}}, $entry;
        $eventnum++;
        
    } # end while

    # set the new_day and end_day members.
    if ($eventnum) {
        for (my $i = 0; $i < $eventnum; $i++) {
            my $entry = $p->{'entries'}->[$i];
            $entry->{'new_day'} = 1;
            my $last = $i;
            for (my $j = $i+1; $j < $eventnum; $j++) {
                my $ej = $p->{'entries'}->[$j];
                if ($ej->{'_ymd'} eq $entry->{'_ymd'}) {
                    $last = $j;
                }
            }
            $p->{'entries'}->[$last]->{'end_day'} = 1;
            $i = $last;
        }
    }

    # load the pictures that were referenced, then retroactively populate
    # the userpic fields of the Entries above
    my %userpics;
    LJ::load_userpics(\%userpics, \@userpic_load);

    foreach my $picid (keys %userpics) {
        my $up = Image("$LJ::USERPIC_ROOT/$picid/$userpics{$picid}->{'userid'}",
                       $userpics{$picid}->{'width'},
                       $userpics{$picid}->{'height'});
        foreach (@{$objs_of_picid{$picid}}) { $$_ = $up; }
    }

    # make the skip links
    my $nav = {
        '_type' => 'RecentNav',
        'version' => 1,
        'skip' => $skip,
        'count' => $eventnum,
    };

    my $base = "$u->{'_journalbase'}/$opts->{'view'}";
    if ($group) {
        $base .= "/" . LJ::eurl($group);
    }

    # $linkfilter is distinct from $filter: if user has a default view,
    # $filter is now set according to it but we don't want it to show in the links.
    # $incfilter may be true even if $filter is 0: user may use filter=0 to turn
    # off the default group
    my $linkfilter = $get->{'filter'} + 0;
    my $incfilter = defined $get->{'filter'};

    # if we've skipped down, then we can skip back up
    if ($skip) {
        my %linkvars;
        $linkvars{'filter'} = $linkfilter if $incfilter;
        $linkvars{'show'} = $get->{'show'} if $get->{'show'} =~ /^\w+$/;
        my $newskip = $skip - $itemshow;
        if ($newskip > 0) { $linkvars{'skip'} = $newskip; }
        else { $newskip = 0; }
        $linkvars{'dayskip'} = $dayskip if $dayskip;
        $nav->{'forward_url'} = LJ::make_link($base, \%linkvars);
        $nav->{'forward_skip'} = $newskip;
        $nav->{'forward_count'} = $itemshow;
    }

    ## unless we didn't even load as many as we were expecting on this
    ## page, then there are more (unless there are exactly the number shown 
    ## on the page, but who cares about that)
    # Must remember to count $hiddenentries or we'll have no skiplinks when > 1
    unless (($eventnum + $hiddenentries) != $itemshow || $skip == $maxskip) {
        my %linkvars;
        $linkvars{'filter'} = $linkfilter if $incfilter;
        $linkvars{'show'} = $get->{'show'} if $get->{'show'} =~ /^\w+$/;
        my $newskip = $skip + $itemshow;
        $linkvars{'skip'} = $newskip;
        $linkvars{'dayskip'} = $dayskip if $dayskip;
        $nav->{'backward_url'} = LJ::make_link($base, \%linkvars);
        $nav->{'backward_skip'} = $newskip;
        $nav->{'backward_count'} = $itemshow;
    }

    $p->{'nav'} = $nav;

    if ($get->{'mode'} eq "framed") {
        $p->{'head_content'} .= "<base target='_top' />";
    }

    return $p;
}

1;
