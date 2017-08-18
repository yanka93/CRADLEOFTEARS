#!/usr/bin/perl
#

use strict;
package LJ::S2;

sub DayPage
{
    my ($u, $remote, $opts) = @_;

    my $p = Page($u, $opts);
    $p->{'_type'} = "DayPage";
    $p->{'view'} = "day";
    $p->{'entries'} = [];

    my $user = $u->{'user'};
    my $journalbase = LJ::journal_base($user, $opts->{'vhost'});

    if ($u->{'journaltype'} eq "R" && $u->{'renamedto'} ne "") {
        $opts->{'redir'} = LJ::journal_base($u->{'renamedto'}, $opts->{'vhost'}) .
            "/calendar" . $opts->{'pathextra'};
        return 1;
    }

    if ($u->{'opt_blockrobots'}) {
        $p->{'head_content'} .= LJ::robot_meta_tags();
    }

    my $get = $opts->{'getargs'};

    my $month = $get->{'month'};
    my $day = $get->{'day'};
    my $year = $get->{'year'};
    my @errors = ();

    if ($opts->{'pathextra'} =~ m!^/(\d\d\d\d)/(\d\d)/(\d\d)\b!) {
        ($month, $day, $year) = ($2, $3, $1);
    }
    
    $opts->{'errors'} = [];
    if ($year !~ /^\d+$/) { push @{$opts->{'errors'}}, "Corrupt or non-existant year."; }
    if ($month !~ /^\d+$/) { push @{$opts->{'errors'}}, "Corrupt or non-existant month."; }
    if ($day !~ /^\d+$/) { push @{$opts->{'errors'}}, "Corrupt or non-existant day."; }
    if ($month < 1 || $month > 12 || int($month) != $month) { push @{$opts->{'errors'}}, "Invalid month."; }
    if ($year < 1970 || $year > 2038 || int($year) != $year) { push @{$opts->{'errors'}}, "Invalid year: $year"; }
    if ($day < 1 || $day > 31 || int($day) != $day) { push @{$opts->{'errors'}}, "Invalid day."; }
    if (scalar(@{$opts->{'errors'}})==0 && $day > LJ::days_in_month($month, $year)) { push @{$opts->{'errors'}}, "That month doesn't have that many days."; }
    return if @{$opts->{'errors'}};

    $p->{'date'} = Date($year, $month, $day);
    
    my $secwhere = "AND security='public'";
    my $viewall = 0;
    my $viewsome = 0; # see public posts from suspended users
    if ($remote) {

        # do they have the viewall priv?
        if ($get->{'viewall'} && LJ::check_priv($remote, "canview")) {
            LJ::statushistory_add($u->{'userid'}, $remote->{'userid'}, 
                                  "viewall", "day: $user, statusvis: $u->{'statusvis'}");
            $viewall = LJ::check_priv($remote, 'canview', '*');
            $viewsome = $viewall || LJ::check_priv($remote, 'canview', 'suspended');
        }

        if ($remote->{'userid'} == $u->{'userid'} || $viewall) {
            $secwhere = "";   # see everything
        } elsif ($remote->{'journaltype'} eq 'P') {
            my $gmask = LJ::get_groupmask($u, $remote);
            $secwhere = "AND (security='public' OR (security='usemask' AND allowmask & $gmask))"
                if $gmask;
        }
    }

    my $dbcr = LJ::get_cluster_reader($u);
    unless ($dbcr) {
        push @{$opts->{'errors'}}, "Database temporarily unavailable";
        return;
    }

    # load the log items
    my $dateformat = "%Y %m %d %H %i %s %w"; # yyyy mm dd hh mm ss day_of_week
    my $sth = $dbcr->prepare("SELECT jitemid AS itemid, posterid, security, DATE_FORMAT(eventtime, \"$dateformat\") AS 'alldatepart', anum ".
                             "FROM log2 " .
                             "WHERE journalid=$u->{'userid'} AND year=$year AND month=$month AND day=$day $secwhere " . 
                             "ORDER BY eventtime, logtime LIMIT 200");
    $sth->execute;

    my @items;
    push @items, $_ while $_ = $sth->fetchrow_hashref;
    my @itemids = map { $_->{'itemid'} } @items;

    # load 'opt_ljcut_disable_lastn' prop for $remote.
    LJ::load_user_props($remote, "opt_ljcut_disable_lastn");
    
    ### load the log properties
    my %logprops = ();
    my $logtext;
    LJ::load_log_props2($dbcr, $u->{'userid'}, \@itemids, \%logprops);
    $logtext = LJ::get_logtext2($u, @itemids);

    my (%apu, %apu_lite);  # alt poster users; UserLite objects
    foreach (@items) {
        next unless $_->{'posterid'} != $u->{'userid'};
        $apu{$_->{'posterid'}} = undef;
    }
    if (%apu) {
        LJ::load_userids_multiple([map { $_, \$apu{$_} } keys %apu], [$u]);
        $apu_lite{$_} = UserLite($apu{$_}) foreach keys %apu;
    }

    # load tags
    my $tags = LJ::Tags::get_logtags($u, \@itemids);

    my $userlite_journal = UserLite($u);

  ENTRY:
    foreach my $item (@items)
    {
        my ($posterid, $itemid, $security, $alldatepart, $anum) = 
            map { $item->{$_} } qw(posterid itemid security alldatepart anum);

        my $replycount = $logprops{$itemid}->{'replycount'};
        my $subject = $logtext->{$itemid}->[0];
        my $text = $logtext->{$itemid}->[1];
        if ($get->{'nohtml'}) {
            # quote all non-LJ tags
            $subject =~ s{<(?!/?lj)(.*?)>} {&lt;$1&gt;}gi;
            $text    =~ s{<(?!/?lj)(.*?)>} {&lt;$1&gt;}gi;
        }

        # don't show posts from suspended users
        next ENTRY if $apu{$posterid} && $apu{$posterid}->{'statusvis'} eq 'S' && ! $viewsome;

	if ($LJ::UNICODE && $logprops{$itemid}->{'unknown8bit'}) {
	    LJ::item_toutf8($u, \$subject, \$text, $logprops{$itemid});
	}

        LJ::CleanHTML::clean_subject(\$subject) if $subject;

        my $ditemid = $itemid*256 + $anum;

        LJ::CleanHTML::clean_event(\$text, { 'preformatted' => $logprops{$itemid}->{'opt_preformatted'},
                                             'cuturl' => LJ::item_link($u, $itemid, $anum),
                                             'ljcut_disable' => $remote->{'opt_ljcut_disable_lastn'}, });
        LJ::expand_embedded($u, $ditemid, $remote, \$text);

        my $nc = "";
        $nc .= "nc=$replycount" if $replycount && $remote && $remote->{'opt_nctalklinks'};

        my $permalink = "$journalbase/$ditemid.html";
        my $readurl = $permalink;
        $readurl .= "?$nc" if $nc;
        my $posturl = $permalink . "?mode=reply";

        my $comments = CommentInfo({
            'read_url' => $readurl,
            'post_url' => $posturl,
            'count' => $replycount,
            'maxcomments' => ($replycount >= LJ::get_cap($u, 'maxcomments')) ? 1 : 0,
            'enabled' => ($u->{'opt_showtalklinks'} eq "Y" && ! $logprops{$itemid}->{'opt_nocomments'}) ? 1 : 0,
            'screened' => ($logprops{$itemid}->{'hasscreened'} && $remote &&
                           ($remote->{'user'} eq $u->{'user'} || LJ::can_manage($remote, $u))) ? 1 : 0,
        });

        my $userlite_poster = $userlite_journal;
        my $pu = $u;
        if ($u->{'userid'} != $posterid) {
            $userlite_poster = $apu_lite{$posterid} or die "No apu_lite for posterid=$posterid";
            $pu = $apu{$posterid};
        }
        my $userpic = Image_userpic($pu, 0, $logprops{$itemid}->{'picture_keyword'});

        my @taglist;
        while (my ($kwid, $kw) = each %{$tags->{$itemid} || {}}) {
            push @taglist, Tag($u, $kwid => $kw);
        }
        @taglist = sort { $a->{name} cmp $b->{name} } @taglist;

        if ($opts->{enable_tags_compatibility} && @taglist) {
            $text .= LJ::S2::get_tags_text($opts->{ctx}, \@taglist);
        }

        my $entry = Entry($u, {
            'subject' => $subject,
            'text' => $text,
            'dateparts' => $alldatepart,
            'security' => $security,
            'props' => $logprops{$itemid},
            'itemid' => $ditemid,
            'journal' => $userlite_journal,
            'poster' => $userlite_poster,
            'comments' => $comments,
            'tags' => \@taglist,
            'userpic' => $userpic,
            'permalink_url' => $permalink,
        });

        push @{$p->{'entries'}}, $entry;
    }

    if (@{$p->{'entries'}}) {
        $p->{'has_entries'} = 1;
        $p->{'entries'}->[0]->{'new_day'} = 1;
        $p->{'entries'}->[-1]->{'end_day'} = 1;
    }

    # calculate previous day
    my $pdyear = $year;
    my $pdmonth = $month;
    my $pdday = $day-1;
    if ($pdday < 1)
    {
        if (--$pdmonth < 1)
        {
          $pdmonth = 12;
          $pdyear--;
        }
        $pdday = LJ::days_in_month($pdmonth, $pdyear);
    }

    # calculate next day
    my $nxyear = $year;
    my $nxmonth = $month;
    my $nxday = $day+1;
    if ($nxday > LJ::days_in_month($nxmonth, $nxyear))
    {
        $nxday = 1;
        if (++$nxmonth > 12) { ++$nxyear; $nxmonth=1; }
    }
    
    $p->{'prev_url'} = "$u->{'_journalbase'}/" . sprintf("%04d/%02d/%02d/", $pdyear, $pdmonth, $pdday); 
    $p->{'prev_date'} = Date($pdyear, $pdmonth, $pdday);
    $p->{'next_url'} = "$u->{'_journalbase'}/" . sprintf("%04d/%02d/%02d/", $nxyear, $nxmonth, $nxday); 
    $p->{'next_date'} = Date($nxyear, $nxmonth, $nxday);

    return $p;
}

1;
