use strict;
package LJ::S2;

sub RecentPage
{
    my ($u, $remote, $opts) = @_;

    my $p = Page($u, $opts);
    $p->{'_type'} = "RecentPage";
    $p->{'view'} = "recent";
    $p->{'entries'} = [];

    my $user = $u->{'user'};
    my $journalbase = LJ::journal_base($user, $opts->{'vhost'});

    if ($u->{'journaltype'} eq "R" && $u->{'renamedto'} ne "") {
        $opts->{'redir'} = LJ::journal_base($u->{'renamedto'}, $opts->{'vhost'});
        return;
    }

    LJ::load_user_props($remote, "opt_nctalklinks", "opt_ljcut_disable_lastn");

    my $get = $opts->{'getargs'};

    if ($opts->{'pathextra'}) {
        $opts->{'badargs'} = 1;
        return 1;
    }

    if ($u->{'opt_blockrobots'} || $get->{'skip'}) {
        $p->{'head_content'} .= LJ::robot_meta_tags();
    }

    $p->{'head_content'} .= qq{<link rel="openid.server" href="$LJ::OPENID_SERVER" />\n}
        if LJ::OpenID::server_enabled();

    my $itemshow = S2::get_property_value($opts->{'ctx'}, "page_recent_items")+0;
    if ($itemshow < 1) { $itemshow = 20; }
    elsif ($itemshow > 50) { $itemshow = 50; }

    my $skip = $get->{'skip'}+0;
    my $maxskip = $LJ::MAX_HINTS_LASTN-$itemshow;
    if ($skip < 0) { $skip = 0; }
    if ($skip > $maxskip) { $skip = $maxskip; }

    my $dayskip = $get->{'dayskip'}+0;

    # do they want to view all entries, regardless of security?
    my $viewall = 0;
    my $viewsome = 0;
    if ($get->{'viewall'} && LJ::check_priv($remote, "canview")) {
        LJ::statushistory_add($u->{'userid'}, $remote->{'userid'},
                              "viewall", "lastn: $user, statusvis: $u->{'statusvis'}");
        $viewall = LJ::check_priv($remote, 'canview', '*');
        $viewsome = $viewall || LJ::check_priv($remote, 'canview', 'suspended');
    }

    ## load the items
    my $err;
    my @items = LJ::get_recent_items({
        'u' => $u,
        'clustersource' => 'slave',
        'viewall' => $viewall,
        'remote' => $remote,
        'itemshow' => $itemshow,
        'skip' => $skip,
        'dayskip' => $dayskip,
        'tags' => $opts->{tags},
        'dateformat' => 'S2',
        'order' => ($u->{'journaltype'} eq "C" || $u->{'journaltype'} eq "Y")  # community or syndicated
            ? "logtime" : "",
        'err' => \$err,
    });

    die $err if $err;

    my $lastdate = "";
    my $itemnum = 0;
    my $lastentry = undef;

    my (%apu, %apu_lite);  # alt poster users; UserLite objects
    foreach (@items) {
        next unless $_->{'posterid'} != $u->{'userid'};
        $apu{$_->{'posterid'}} = undef;
    }
    if (%apu) {
        LJ::load_userids_multiple([map { $_, \$apu{$_} } keys %apu], [$u]);
        $apu_lite{$_} = UserLite($apu{$_}) foreach keys %apu;
    }

    my $userlite_journal = UserLite($u);

  ENTRY:
    foreach my $item (@items)
    {
        my ($posterid, $itemid, $security, $alldatepart) =
            map { $item->{$_} } qw(posterid itemid security alldatepart);

        my $props = $item->{'props'};

        my $replycount = $props->{'replycount'};
        my $subject = $item->{'text'}->[0];
        my $text    = $item->{'text'}->[1];
        if ($get->{'nohtml'}) {
            # quote all non-LJ tags
            $subject =~ s{<(?!/?lj)(.*?)>} {&lt;$1&gt;}gi;
            $text    =~ s{<(?!/?lj)(.*?)>} {&lt;$1&gt;}gi;
        }

        # don't show posts from suspended users unless the user doing the viewing says to (and is allowed)
        next ENTRY if $apu{$posterid} && $apu{$posterid}->{'statusvis'} eq 'S' && !$viewsome;

        my $date = substr($alldatepart, 0, 10);
        my $new_day = 0;
        if ($date ne $lastdate) {
            $new_day = 1;
            $lastdate = $date;
            $lastentry->{'end_day'} = 1 if $lastentry;
        }

        $itemnum++;
        LJ::CleanHTML::clean_subject(\$subject) if $subject;

        my $ditemid = $itemid * 256 + $item->{'anum'};
        LJ::CleanHTML::clean_event(\$text, { 'preformatted' => $props->{'opt_preformatted'},
                                              'cuturl' => LJ::item_link($u, $itemid, $item->{'anum'}),
                                              'ljcut_disable' => $remote->{"opt_ljcut_disable_lastn"}, });
        LJ::expand_embedded($u, $ditemid, $remote, \$text);

        my $nc = "";
        $nc .= "nc=$replycount" if $replycount; # && $remote && $remote->{'opt_nctalklinks'};

        my $permalink = "$journalbase/$ditemid.html";
        my $readurl = $permalink;
        $readurl .= "?$nc" if $nc;
        my $posturl = $permalink . "?mode=reply";

        my $comments = CommentInfo({
            'read_url' => $readurl,
            'post_url' => $posturl,
            'count' => $replycount,
            'maxcomments' => ($replycount >= LJ::get_cap($u, 'maxcomments')) ? 1 : 0,
            'enabled' => ($u->{'opt_showtalklinks'} eq "Y" && ! $props->{'opt_nocomments'}) ? 1 : 0,
            'screened' => ($props->{'hasscreened'} && ($remote->{'user'} eq $u->{'user'}|| LJ::can_manage($remote, $u))) ? 1 : 0,
        });

        my $userlite_poster = $userlite_journal;
        my $pu = $u;
        if ($u->{'userid'} != $posterid) {
            $userlite_poster = $apu_lite{$posterid} or die "No apu_lite for posterid=$posterid";
            $pu = $apu{$posterid};
        }
        my $userpic = Image_userpic($pu, 0, $props->{'picture_keyword'});

        my $entry = $lastentry = Entry($u, {
            'subject' => $subject,
            'text' => $text,
            'dateparts' => $alldatepart,
            'security' => $security,
            'props' => $props,
            'itemid' => $ditemid,
            'journal' => $userlite_journal,
            'poster' => $userlite_poster,
            'comments' => $comments,
            'new_day' => $new_day,
            'end_day' => 0,   # if true, set later
            'userpic' => $userpic,
            'permalink_url' => $permalink,
            'enable_tags_compatibility' => [$opts->{enable_tags_compatibility}, $opts->{ctx}],
        });

        push @{$p->{'entries'}}, $entry;

    } # end huge while loop

    # mark last entry as closing.
    $p->{'entries'}->[-1]->{'end_day'} = 1 if $itemnum;

    #### make the skip links
    my $nav = {
        '_type' => 'RecentNav',
        'version' => 1,
        'skip' => $skip,
        'count' => $itemnum,
    };

    # if we've skipped down, then we can skip back up
    if ($skip) {
        my $newskip = $skip - $itemshow;
        $newskip = 0 if $newskip <= 0;
        $nav->{'forward_skip'} = $newskip;
        $nav->{'forward_url'} = LJ::make_link("$p->{base_url}/", { skip => ($newskip || ""), tag => (LJ::eurl($get->{tag}) || ""), dayskip => ($dayskip || "") });
        $nav->{'forward_count'} = $itemshow;
    }

    # unless we didn't even load as many as we were expecting on this
    # page, then there are more (unless there are exactly the number shown
    # on the page, but who cares about that)
    unless ($itemnum != $itemshow) {
        $nav->{'backward_count'} = $itemshow;
        if ($skip == $maxskip) {
            my $date_slashes = $lastdate;  # "yyyy mm dd";
            $date_slashes =~ s! !/!g;
            $nav->{'backward_url'} = "$p->{'base_url'}/day/$date_slashes";
        } else {
            my $newskip = $skip + $itemshow;
            $nav->{'backward_url'} = LJ::make_link("$p->{'base_url'}/", { skip => ($newskip || ""), tag => (LJ::eurl($get->{tag}) || ""), dayskip => ($dayskip || "") });
            $nav->{'backward_skip'} = $newskip;
        }
    }

    $p->{'nav'} = $nav;
    return $p;
}

1;
