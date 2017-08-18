#!/usr/bin/perl

use strict;

package LJ::Feed;

eval "use LJR::Distributed;";
my $ljr = $@ ? 0 : 1;

if ($ljr) {
  use LJR::Distributed;
  require "$ENV{'LJHOME'}/cgi-bin/ljpoll.pl";
}


my %feedtypes = (
    rss  => \&create_view_rss,
    atom => \&create_view_atom,
    foaf => \&create_view_foaf,
);

sub make_feed
{
    my ($r, $u, $remote, $opts) = @_;

    $opts->{pathextra} =~ s!^/(\w+)!!;
    my $feedtype = $1;
    my $viewfunc = $feedtypes{$feedtype};

    unless ($viewfunc) {
        $opts->{'handler_return'} = 404;
        return undef;
    }
    
    $r->notes('codepath' => "feed.$feedtype") if $r;

    if ($u->{'journaltype'} eq "R" && $u->{'renamedto'} ne "") {
        $opts->{'redir'} = LJ::journal_base($u->{'renamedto'}, $opts->{'vhost'}) . "/data/$feedtype";
        return undef;
    }

    my $userid = $u->{'userid'};

    # try cached copy
    # (ljprotocol.pl:  memcache "rss:$userid" deleted if "rsslastmod:$userid" changed)
    my $lastmod = LJ::MemCache::get([$userid, "rsslastmod:$userid"]); # more strict than timeupdate: care of edit!

    my $ims = $r->header_in('If-Modified-Since');
    my $theirtime = LJ::http_to_time($ims) if $ims;

    # If-Modified-Since, try #1
    if (defined $lastmod && $ims && $feedtype ne 'foaf'  && $theirtime >= $lastmod) {
        #$opts->{'handler_return'} = 304; #Not Modified
        $opts->{'notmodified'} = 1;
        return undef;
    }

    # text already in memcache -
    if ($feedtype eq 'rss' && !$remote) {
        my $data = LJ::MemCache::get([$userid, "rss:$userid"]); #{lastmod => $lastmod, text => $ret}
        if ($data) {
            if (!defined $lastmod) {
                LJ::MemCache::set([$userid, "rsslastmod:$userid"], $data->{lastmod});
            }
            $opts->{'cachecontrol'} = 'max-age=600, private, proxy-revalidate';
            $opts->{'contenttype'} = 'text/xml; charset='.$opts->{'saycharset'};
            #$r->header_out("Last-Modified", LJ::time_to_http($data->{lastmod}));
            $r->set_last_modified($data->{lastmod});
            return $data->{text};
        }
    }

    LJ::load_user_props($u, qw/ journaltitle journalsubtitle opt_synlevel /);

    LJ::text_out(\$u->{$_}) 
        foreach ("name", "url", "urlname");
    
    # opt_synlevel will default to 'full'
    $u->{'opt_synlevel'} = 'full' 
        unless $u->{'opt_synlevel'} =~ /^(?:full|summary|title)$/;

    # some data used throughout the channel
    my $journalinfo = {
        u         => $u,
        link      => LJ::journal_base($u) . "/",
        title     => $u->{journaltitle} || $u->{name} || $u->{user},
        subtitle  => $u->{journalsubtitle} || $u->{name},
        builddate => LJ::time_to_http(time()),
    };

    # if we do not want items for this view, just call out
    $opts->{noitems} = 1 if $feedtype eq 'foaf';

    return $viewfunc->($journalinfo, $u, $opts)
        if ($opts->{'noitems'});

    # for syndicated accounts, redirect to the syndication URL
    # However, we only want to do this if the data we're returning
    # is similar. (Not FOAF, for example)

    if ($u->{'journaltype'} eq 'Y') {
        my $dbr = LJ::get_db_reader();
        my $synurl = $dbr->selectrow_array("SELECT synurl FROM syndicated WHERE userid=$userid");
        unless ($synurl) {
            return 'No syndication URL available.';
        }
        $opts->{'redir'} = $synurl;
        return undef;
    }

    ## load the items
    my @items = LJ::get_recent_items({
        'u' => $u,
        'clustersource' => 'slave',
        'remote' => $remote,
        'itemshow' => 25,
        'order' => "logtime",
        'friendsview' => 1,           # this returns rlogtimes
        'dateformat' => "S2",         # S2 format time format is easier
    });

    if (!defined $lastmod) {
        $lastmod = @items ? $LJ::EndOfTime - $items[0]->{'rlogtime'} : 0;
        LJ::MemCache::set([$userid, "rsslastmod:$userid"], $lastmod);

        # If-Modified-Since, try #2
        if ($ims && $theirtime >= $lastmod) {
            #$opts->{'handler_return'} = 304; #Not Modified
            $opts->{'notmodified'} = 1;
            return undef;
        }
    }

    # set last-modified header:
    #$r->header_out("Last-Modified", LJ::time_to_http($lastmod));
    $r->set_last_modified($lastmod); # including $lastmod = 0
    $journalinfo->{'modtime'} = $lastmod;

    #$opts->{'cachecontrol'} = 'max-age=600, proxy-revalidate'; # unless $remote; #hmm
    $opts->{'cachecontrol'} = 'max-age=600, private, proxy-revalidate'; # if $remote;
    $opts->{'contenttype'} = 'text/xml; charset='.$opts->{'saycharset'};


    # email address of journal owner, but respect their privacy settings
    if ($u->{'allow_contactshow'} eq "Y" && $u->{'opt_whatemailshow'} ne "N" && $u->{'opt_mangleemail'} ne "Y") {
        my $cemail;
        
        # default to their actual email
        $cemail = $u->{'email'};
        
        # use their livejournal email if they have one
        if ($LJ::USER_EMAIL && $u->{'opt_whatemailshow'} eq "L" &&
            LJ::get_cap($u, "useremail") && ! $u->{'no_mail_alias'}) {

            $cemail = "$u->{'user'}\@$LJ::USER_DOMAIN";
        } 

        # clean it up since we know we have one now
        $journalinfo->{email} = $cemail;
    } else { $journalinfo->{email} = "$u->{'user'} at lj.rossia.org"; }

    my %posteru = ();  # map posterids to u objects
    LJ::load_userids_multiple([map { $_->{'posterid'}, \$posteru{$_->{'posterid'}} } @items], [$u]);

    my @cleanitems;
  ENTRY:
    foreach my $it (@items) 
    {
        # load required data
        my $itemid  = $it->{'itemid'};
        my $ditemid = $itemid*256 + $it->{'anum'};

        next ENTRY if $posteru{$it->{'posterid'}} && $posteru{$it->{'posterid'}}->{'statusvis'} eq 'S';

        my $props = $it->{'props'};

        # see if we have a subject and clean it
        my $subject = $it->{'text'}->[0];
        if ($subject) {
            $subject =~ s/[\r\n]/ /g;
            LJ::CleanHTML::clean_subject_all(\$subject);
        }

        # an HTML link to the entry. used if we truncate or summarize
        my $readmore = "<b>(<a href=\"$journalinfo->{link}$ditemid.html\">Read more ...</a>)</b>";

        # empty string so we don't waste time cleaning an entry that won't be used
        my $event = $u->{'opt_synlevel'} eq 'title' ? '' : $it->{'text'}->[1];

        # clean the event, if non-empty
        my $ppid = 0;
        if ($event) {

            # users without 'full_rss' get their logtext bodies truncated
            # do this now so that the html cleaner will hopefully fix html we break
            unless (LJ::get_cap($u, 'full_rss')) {
                my $trunc = LJ::text_trim($event, 0, 80);
                $event = "$trunc $readmore" if $trunc ne $event;
            }

            LJ::CleanHTML::clean_event(\$event, {'ljcut_disable'=>1},
                                       { 'preformatted' => $props->{'opt_preformatted'} });
        
            # do this after clean so we don't have to about know whether or not
            # the event is preformatted
            if ($u->{'opt_synlevel'} eq 'summary') {

                # assume the first paragraph is terminated by two <br> or a </p>
                # valid XML tags should be handled, even though it makes an uglier regex
                if ($event =~ m!((<br\s*/?\>(</br\s*>)?\s*){2})|(</p\s*>)!i) {
                    # everything before the matched tag + the tag itself
                    # + a link to read more
                    $event = $` . $& . $readmore;
                }
            }

            LJ::Poll::replace_polls_with_links(\$event);
	    LJ::EmbedModule->expand_entry($u, \$event, ('content_only' => 1));

            $ppid = $1
                if $event =~ m!<lj-phonepost journalid=['"]\d+['"] dpid=['"](\d+)['"] />!; #'
        }

        my $mood;
        if ($props->{'current_mood'}) {
            $mood = $props->{'current_mood'};
        } elsif ($props->{'current_moodid'}) {
            $mood = LJ::mood_name($props->{'current_moodid'}+0);
        }
  
        if ($ljr) {
          LJR::Distributed::sign_exported_rss_entry($u, $it->{'itemid'}, $it->{'anum'}, \$event);
        }

        my $createtime = $LJ::EndOfTime - $it->{rlogtime};

        my $cleanitem = {
            itemid     => $itemid,
            ditemid    => $ditemid,
            subject    => $subject,
            event      => $event,
            createtime => $createtime,
            eventtime  => $it->{alldatepart},  # ugly: this is of a different format than the other two times.
            modtime    => $props->{revtime} || $createtime,
            comments   => ($props->{'opt_nocomments'} == 0),
            music      => $props->{'current_music'},
            mood       => $mood,
            ppid       => $ppid,
            tags       => $props->{'tags'},
        };
        push @cleanitems, $cleanitem;
    }

    # fix up the build date to use entry-time
    # (empty journals show  01 Jan 1970 00:00:00 GMT as build date and Last-Modified time).
    $journalinfo->{'builddate'} = LJ::time_to_http(@items ? $LJ::EndOfTime - $items[0]->{'rlogtime'} : 0),

    return $viewfunc->($journalinfo, $u, $opts, \@cleanitems, $remote, $lastmod);
}


# the creator for the RSS XML syndication view
sub create_view_rss
{
    my ($journalinfo, $u, $opts, $cleanitems, $remote, $lastmod) = @_;

    my $ret;

    # header
    $ret .= "<?xml version='1.0' encoding='$opts->{'saycharset'}' ?>\n";
    $ret .= LJ::run_hook("bot_director", "<!-- ", " -->") . "\n";
    $ret .= "<rss version='2.0' xmlns:lj='http://www.livejournal.org/rss/lj/1.0/'>\n";

    # channel attributes
    $ret .= "<channel>\n";
    $ret .= "  <title>" . LJ::exml($journalinfo->{title}) . "</title>\n";
    $ret .= "  <link>$journalinfo->{link}</link>\n";
    $ret .= "  <description>" . LJ::exml("$journalinfo->{title} - $LJ::SITENAME") . "</description>\n";
    
    if ($u->{'opt_blockrobots'}) {
      $ret .= "  <copyright>noindex</copyright>\n";
    }
    
    $ret .= "  <managingEditor>" . $journalinfo->{title} . "</managingEditor>\n" if $journalinfo->{email};
    $ret .= "  <lastBuildDate>$journalinfo->{builddate}</lastBuildDate>\n";
    $ret .= "  <generator>LiveJournal / $LJ::SITENAME</generator>\n";
    # TODO: add 'language' field when user.lang has more useful information

    ### image block, returns info for their current userpic
    if ($u->{'defaultpicid'}) {
        my $pic = {};
        LJ::load_userpics($pic, [ $u, $u->{'defaultpicid'} ]);
        $pic = $pic->{$u->{'defaultpicid'}}; # flatten
        
        $ret .= "  <image>\n";
        $ret .= "    <url>$LJ::USERPIC_ROOT/$u->{'defaultpicid'}/$u->{'userid'}</url>\n";
        $ret .= "    <title>" . LJ::exml($journalinfo->{title}) . "</title>\n";
        $ret .= "    <link>$journalinfo->{link}</link>\n";
        $ret .= "    <width>$pic->{'width'}</width>\n";
        $ret .= "    <height>$pic->{'height'}</height>\n";
        $ret .= "  </image>\n\n";
    }

    # output individual item blocks

    foreach my $it (@$cleanitems) 
    {
        my $itemid = $it->{itemid};
        my $ditemid = $it->{ditemid};
        $ret .= "<item>\n";
        $ret .= "  <guid isPermaLink='true'>$journalinfo->{link}$ditemid.html</guid>\n";
        $ret .= "  <pubDate>" . LJ::time_to_http($it->{createtime}) . "</pubDate>\n";
        $ret .= "  <title>" . LJ::exml($it->{subject}) . "</title>\n" if $it->{subject};
## hide e-mail for security concern
##        $ret .= "  <author>" . LJ::exml($journalinfo->{email}) . "</author>" if $journalinfo->{email};
        $ret .= "  <link>$journalinfo->{link}$ditemid.html</link>\n";
        # omit the description tag if we're only syndicating titles
        #   note: the $event was also emptied earlier, in make_feed
        unless ($u->{'opt_synlevel'} eq 'title') {
            $ret .= "  <description>" . LJ::exml($it->{event}) . "</description>\n";
        }
        if ($it->{comments}) {
            $ret .= "  <comments>$journalinfo->{link}$ditemid.html</comments>\n";
        }
        $ret .= "  <category>$_</category>\n" foreach map { LJ::exml($_) } @{$it->{tags} || []};
        # support 'podcasting' enclosures
        $ret .= LJ::run_hook( "pp_rss_enclosure",
                { userid => $u->{userid}, ppid => $it->{ppid} }) if $it->{ppid};
        # TODO: add author field with posterid's email address, respect communities
        $ret .= "  <lj:music>" . LJ::exml($it->{music}) . "</lj:music>\n" if $it->{music};
        $ret .= "  <lj:mood>" . LJ::exml($it->{mood}) . "</lj:mood>\n" if $it->{mood};
        $ret .= "</item>\n";
    }

    $ret .= "</channel>\n";
    $ret .= "</rss>\n";

    #store to memcached, anonymous
    LJ::MemCache::set([$u->{userid}, "rss:$u->{userid}"], {lastmod => $lastmod, text => $ret}) unless $remote;
 
    return $ret;
}


# the creator for the Atom view
# keys of $opts:
# saycharset - required: the charset of the feed
# noheader - only output an <entry>..</entry> block. off by default
# apilinks - output AtomAPI links for posting a new entry or 
#            getting/editing/deleting an existing one. off by default
# TODO: define and use an 'lj:' namespace

sub create_view_atom
{
    my ($journalinfo, $u, $opts, $cleanitems) = @_;

    my $ret;

    # prolog line
    $ret .= "<?xml version='1.0' encoding='$opts->{'saycharset'}' ?>\n";
    $ret .= LJ::run_hook("bot_director", "<!-- ", " -->");

    # AtomAPI interface
    my $api = $opts->{'apilinks'} ? "$LJ::SITEROOT/interface/atom" :
                                    "$LJ::SITEROOT/users/$u->{user}/data/atom";

    # header
    unless ($opts->{'noheader'}) {
        $ret .= "<feed version='0.3' xmlns='http://purl.org/atom/ns#'>\n";

        # attributes
        $ret .= "<title mode='escaped'>" . LJ::exml($journalinfo->{title}) . "</title>\n";
        $ret .= "<tagline mode='escaped'>" . LJ::exml($journalinfo->{subtitle}) . "</tagline>\n"
            if $journalinfo->{subtitle};
        $ret .= "<link rel='alternate' type='text/html' href='$journalinfo->{link}' />\n";

        # last update
        $ret .= "<modified>" . LJ::time_to_w3c($journalinfo->{'modtime'}, 'Z')
            . "</modified>";

        # link to the AtomAPI version of this feed
        $ret .= "<link rel='service.feed' type='application/x.atom+xml' title='";
        $ret .= LJ::ehtml($journalinfo->{title});
        $ret .= $opts->{'apilinks'} ? "' href='$api/feed' />" : "' href='$api' />";

        if ($opts->{'apilinks'}) {
            $ret .= "<link rel='service.post' type='application/x.atom+xml' title='Create a new post' href='$api/post' />";
        }
    }

    # output individual item blocks

    foreach my $it (@$cleanitems) 
    {
        my $itemid = $it->{itemid};
        my $ditemid = $it->{ditemid};

        $ret .= "  <entry xmlns=\"http://purl.org/atom/ns#\">\n";
        # include empty tag if we don't have a subject.
        $ret .= "    <title mode='escaped'>" . LJ::exml($it->{subject}) . "</title>\n";
        $ret .= "    <id>urn:lj:$LJ::DOMAIN:atom1:$journalinfo->{u}{user}:$ditemid</id>\n";
        $ret .= "    <link rel='alternate' type='text/html' href='$journalinfo->{link}$ditemid.html' />\n";
        if ($opts->{'apilinks'}) {
            $ret .= "<link rel='service.edit' type='application/x.atom+xml' title='Edit this post' href='$api/edit/$itemid' />";
        }
        $ret .= "    <created>" . LJ::time_to_w3c($it->{createtime}, 'Z') . "</created>\n"
             if $it->{createtime} != $it->{modtime};

        my ($year, $mon, $mday, $hour, $min, $sec) = split(/ /, $it->{eventtime});
        $ret .= "    <issued>" .  sprintf("%04d-%02d-%02dT%02d:%02d:%02d",
                                          $year, $mon, $mday,
                                          $hour, $min, $sec) .  "</issued>\n";
        $ret .= "    <modified>" . LJ::time_to_w3c($it->{modtime}, 'Z') . "</modified>\n";
        $ret .= "    <author>\n";
        $ret .= "      <name>" . LJ::exml($journalinfo->{u}{name}) . "</name>\n";
## hide e-mail for security concern
##        $ret .= "      <email>" . LJ::exml($journalinfo->{email}) . "</email>\n" if $journalinfo->{email};
        $ret .= "    </author>\n";
        $ret .= "    <category term='$_' />\n" foreach map { LJ::exml($_) } @{$it->{tags} || []};
        # if syndicating the complete entry
        #   -print a content tag
        # elsif syndicating summaries
        #   -print a summary tag
        # else (code omitted), we're syndicating title only
        #   -print neither (the title has already been printed)
        #   note: the $event was also emptied earlier, in make_feed
        if ($u->{'opt_synlevel'} eq 'full') {
            $ret .= "    <content type='text/html' mode='escaped'>" . LJ::exml($it->{event}) . "</content>\n";
        } elsif ($u->{'opt_synlevel'} eq 'summary') {
            $ret .= "    <summary type='text/html' mode='escaped'>" . LJ::exml($it->{event}) . "</summary>\n";
        }

        $ret .= "  </entry>\n";
    }

    unless ($opts->{'noheader'}) {
        $ret .= "</feed>\n";
    }

    return $ret;
}

# create a FOAF page for a user
sub create_view_foaf {
    my ($journalinfo, $u, $opts) = @_;
    my $comm = ($u->{journaltype} eq 'C');

    my $ret;

    # return nothing if we're not a user
    unless ($u->{journaltype} eq 'P' || $comm) {
        $opts->{handler_return} = 404;
        return undef;
    }

    # set our content type
    $opts->{contenttype} = 'application/rdf+xml; charset=' . $opts->{saycharset};

    # setup userprops we will need
    LJ::load_user_props($u, qw{
        aolim icq yahoo jabber msn url urlname external_foaf_url
    });

    # create bare foaf document, for now
    $ret = "<?xml version='1.0'?>\n";
    $ret .= LJ::run_hook("bot_director", "<!-- ", " -->");
    $ret .= "<rdf:RDF\n";
    $ret .= "   xml:lang=\"en\"\n";
    $ret .= "   xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\"\n";
    $ret .= "   xmlns:rdfs=\"http://www.w3.org/2000/01/rdf-schema#\"\n";
    $ret .= "   xmlns:foaf=\"http://xmlns.com/foaf/0.1/\"\n";
    $ret .= "   xmlns:dc=\"http://purl.org/dc/elements/1.1/\">\n";

    # precompute some values
    my $digest = Digest::SHA1::sha1_hex('mailto:' . $u->{email});
    
    # channel attributes
    $ret .= ($comm ? "  <foaf:Group>\n" : "  <foaf:Person>\n");
    $ret .= "    <foaf:nick>$u->{user}</foaf:nick>\n";
    if ($u->{bdate} && $u->{bdate} ne "0000-00-00" && !$comm && $u->{allow_infoshow} eq 'Y') {
        my $bdate = $u->{bdate};
        $bdate =~ s/^0000-//;
        $ret .= "    <foaf:dateOfBirth>$bdate</foaf:dateOfBirth>\n";
    }
    $ret .= "    <foaf:mbox_sha1sum>$digest</foaf:mbox_sha1sum>\n";
    $ret .= "    <foaf:page>\n";
    $ret .= "      <foaf:Document rdf:about=\"$LJ::SITEROOT/userinfo.bml?user=$u->{user}\">\n";
    $ret .= "        <dc:title>$LJ::SITENAME Profile</dc:title>\n";
    $ret .= "        <dc:description>Full $LJ::SITENAME profile, including information such as interests and bio.</dc:description>\n";
    $ret .= "      </foaf:Document>\n";
    $ret .= "    </foaf:page>\n";

    # we want to bail out if they have an external foaf file, because 
    # we want them to be able to provide their own information. 
    if ($u->{external_foaf_url}) {
        $ret .= "    <rdfs:seeAlso rdf:resource=\"" . LJ::eurl($u->{external_foaf_url}) . "\" />\n";
        $ret .= ($comm ? "  </foaf:Group>\n" : "  </foaf:Person>\n");
        $ret .= "</rdf:RDF>\n";
        return $ret;
    }

    # contact type information
    my %types = (
        aolim => 'aimChatID',
        icq => 'icqChatID',
        yahoo => 'yahooChatID',
        msn => 'msnChatID',
        jabber => 'jabberID',
    );
    if ($u->{allow_contactshow} eq 'Y') {
        foreach my $type (keys %types) {
            next unless $u->{$type};
            $ret .= "    <foaf:$types{$type}>" . LJ::exml($u->{$type}) . "</foaf:$types{$type}>\n";
        }
    }

    # include a user's journal page and web site info
    $ret .= "    <foaf:weblog rdf:resource=\"" . LJ::journal_base($u) . "/\"/>\n";
    if ($u->{url}) {
        $ret .= "    <foaf:homepage rdf:resource=\"" . LJ::eurl($u->{url});
        $ret .= "\" dc:title=\"" . LJ::exml($u->{urlname}) . "\" />\n";
    }

    # interests, please!
    # arrayref of interests rows: [ intid, intname, intcount ]
    my $intu = LJ::get_interests($u);
    foreach my $int (@$intu) {
        LJ::text_out(\$int->[1]); # 1==interest
        $ret .= "    <foaf:interest dc:title=\"". LJ::exml($int->[1]) . "\" " .
                "rdf:resource=\"$LJ::SITEROOT/interests.bml?int=" . LJ::eurl($int->[1]) . "\" />\n";
    }

    # check if the user has a "FOAF-knows" group
    my $groups = LJ::get_friend_group($u->{userid}, { name => 'FOAF-knows' });
    my $mask = $groups ? 1 << $groups->{groupnum} : 0;

    # now information on who you know, limited to a certain maximum number of users
    my $friends = LJ::get_friends($u->{userid}, $mask);
    my @ids = keys %$friends;
    @ids = splice(@ids, 0, $LJ::MAX_FOAF_FRIENDS) if @ids > $LJ::MAX_FOAF_FRIENDS;

    # now load
    my %users;
    LJ::load_userids_multiple([ map { $_, \$users{$_} } @ids ], [$u]);

    # iterate to create data structure
    foreach my $friendid (@ids) {
        next if $friendid == $u->{userid};
        my $fu = $users{$friendid};
        next if $fu->{statusvis} =~ /[DXS]/ || $fu->{journaltype} ne 'P';
        $ret .= $comm ? "    <foaf:member>\n" : "    <foaf:knows>\n";
        $ret .= "      <foaf:Person>\n";
        $ret .= "        <foaf:nick>$fu->{'user'}</foaf:nick>\n";
        $ret .= "        <rdfs:seeAlso rdf:resource=\"" . LJ::journal_base($fu) ."/data/foaf\" />\n";
        $ret .= "        <foaf:weblog rdf:resource=\"" . LJ::journal_base($fu) . "/\"/>\n";
        $ret .= "      </foaf:Person>\n";
        $ret .= $comm ? "    </foaf:member>\n" : "    </foaf:knows>\n";
    }

    # finish off the document
    $ret .= $comm ? "    </foaf:Group>\n" : "  </foaf:Person>\n";
    $ret .= "</rdf:RDF>\n";

    return $ret;
}

1;
