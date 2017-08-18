#!/usr/bin/perl
# vim: set ts=4 sw=4 et :

# some variable names:
#  - phonepostid, bid, blobid:  all refer to a blob id.
#  - dppid:  display phonepost id; comparable to a ditemid, but for a phone post.

use strict;

use lib "$ENV{'LJHOME'}/cgi-bin";
use LJ::Blob;

package LJ::PhonePost;

my $datatypes = {
    0 => { ext => 'mp3', mime => 'audio/mp3' },
    1 => { ext => 'ogg', mime => 'application/ogg' },
    2 => { ext => 'wav', mime => 'audio/wav' },
};

sub may_transcribe {
    my ($u, $remote) = @_;
    return 0 if $remote && $remote->{journaltype} ne 'P';
    return 1 if $remote && $remote->{userid} == $u->{userid};
    LJ::load_user_props($u, 'pp_transallow');
    return 0 if $u->{pp_transallow} == -1;
    my $groupmask = LJ::get_groupmask($u, $remote);
    return 1 if ! $u->{pp_transallow} && $groupmask;
    return ($groupmask & (1 << $u->{pp_transallow})) ? 1 : 0;
}

sub get_phonepost_entry {
    my ($u, $bid) = @_;
    my ($ppe, $memkey);

    $memkey = [$u->{userid}, "ppe:$u->{userid}:$bid"];
    $ppe = LJ::MemCache::get($memkey);

    return $ppe if $ppe;

    my $dbcr = LJ::get_cluster_def_reader($u);
    $ppe = $dbcr->selectrow_hashref(qq{
            SELECT ppe.jitemid, ppe.posttime, ppe.anum, 
                   ppe.filetype, ub.length, ppe.lengthsecs, ppe.location
            FROM   phonepostentry ppe, userblob ub
            WHERE  ub.journalid=? AND ppe.userid=ub.journalid
            AND    ub.domain=? AND ub.blobid=? AND ppe.blobid=ub.blobid
            }, undef, $u->{'userid'}, LJ::get_blob_domainid("phonepost"), $bid);
    LJ::MemCache::set($memkey, $ppe || 0);
    return $ppe;
}

sub apache_content {
    my ($r, $u, $dppid) = @_;
    my $bid = $dppid >> 8;
    my $ppe = get_phonepost_entry($u, $bid);
    return 404 unless $ppe && $ppe->{jitemid} && $ppe->{anum} == $dppid % 256;

    # check security of item
    my $logrow = LJ::get_log2_row($u, $ppe->{jitemid});
    return 404 unless $logrow;

    if ($u->{statusvis} eq 'S' || $logrow->{security} ne "public") {
        # get the remote, ignoring IP, since the request is coming
        # from Akamai/Speedera/etc and the IP won't match
        my $remote = LJ::get_remote({ ignore_ip => 1 });

        my %GET = $r->args;

        my $viewall = 0;
        my $viewsome = 0;
        if ($remote && $GET{viewall} && LJ::check_priv($remote, "canview")) {
            LJ::statushistory_add($u->{'userid'}, $remote->{'userid'}, 
                                  "viewall", "phonepost: $u->{user}, itemid: $ppe->{jitemid}, statusvis: $u->{'statusvis'}");

            $viewall = LJ::check_priv($remote, 'canview', '*');
            $viewsome = $viewall || LJ::check_priv($remote, 'canview', 'suspended');
        }

        unless ($viewall || $viewsome && $logrow->{security} eq 'public') {
            return 403 unless LJ::can_view($remote, $logrow);
        }
    }

    # future:  if length is NULL, then it's an external reference and we redirect
    $r->header_out("Cache-Control", "must-revalidate, private");
    $r->header_out("Content-Length", $ppe->{length});
    $r->content_type( $datatypes->{ $ppe->{filetype} }->{mime} );

    # handle IMS requests
    my $last_mod = LJ::time_to_http($ppe->{posttime});
    if (my $ims = $r->header_in("If-Modified-Since")) {
        return 304 if $ims eq $last_mod;
    }

    $r->header_out("Last-Modified", $last_mod);
    if ($r->header_only) {
        $r->send_http_header();
        return 200;
    }

    my $buffer;
    if ($ppe->{location} eq 'mogile') {
        # Mogile
        if ( !$LJ::REPROXY_DISABLE{phoneposts} &&
             $r->header_in('X-Proxy-Capabilities') &&
             $r->header_in('X-Proxy-Capabilities') =~ /\breproxy-file\b/i )
        {
            my @paths = LJ::mogclient()->get_paths( "pp:$u->{userid}:$bid", 1 );

            # reproxy url
            if ($paths[0] =~ m/^http:/) {
                $r->header_out('X-REPROXY-URL', join(' ', @paths));
            }
            # reproxy file
            else {
                $r->header_out('X-REPROXY-FILE', $paths[0]);
            }
            $r->send_http_header();
        }
        else {
            $buffer = LJ::mogclient()->get_file_data("pp:$u->{userid}:$bid");
            $r->send_http_header();
            return 500 unless $buffer && ref $buffer;
            $r->print($$buffer);
        }

    }
    else {
        # BlobServer
        $r->send_http_header();
        my $ret = LJ::Blob::get_stream($u, 'phonepost',
                                       $datatypes->{ $ppe->{filetype} }->{ext}, $bid, sub {
            $buffer .= $_[0];
            if (length($buffer) > 50_000) {
                $r->print($buffer);
                undef $buffer;
            }
        });
        $r->print($buffer) if length($buffer);
        return 500 unless $ret;
    }

    return 200;
}

# if $u_embed and $ditemid are given, they represent an entry
# in which a phonepost tag has been embedded.

sub make_link {
    my ($remote, $uuid, $phonepostid, $mode, $u_embed, $ditemid) = @_;
    $phonepostid += 0;

    # mode can either be 'notrans', 'bare', or 'rss'
    $mode = "notrans" if $mode && $mode !~ /bare|rss/;

    my $u = ref $uuid ? $uuid : LJ::load_userid($uuid);
    return $mode eq 'rss' ? "" : "<b>[Invalid user]</b>" unless $u;
    my $userid = $u->{'userid'};

    my $ppe = get_phonepost_entry($u, $phonepostid);
    return $mode eq 'rss' ? "" : "<b>[Invalid audio link]</b>" unless $ppe;

    if ($u_embed && $ditemid) {
        # have to check whether the link is embeddable in this entry
        if ($u_embed->{'userid'} == $userid && 
            $ditemid>>8 == $ppe->{'jitemid'}) {

            # it's the original entry, we're ok
        } else {
            my $accdenied = "<b>[Access to audio link denied]</b>";

            # log2 row in which the tag is embedded
            my $row = LJ::get_log2_row($u_embed, $ditemid >> 8);

            # the original log2 row of this tag
            my $row_orig = LJ::get_log2_row($u, $ppe->{'jitemid'});
            return $mode eq 'rss' ? "" : $accdenied unless $row && $row_orig;

            if ($row_orig->{'security'} eq "public" && 
                $row->{'posterid'} == $userid &&
                $u_embed->{'userid'} != $userid) {

                # it's public and moved by the same 
                # user to a different journal, we're okay
            } else {
                return $mode eq 'rss' ? "" : $accdenied;
            }
        }
    }

    my $link;
    my $dppid = ($phonepostid << 8) + $ppe->{anum};
    my $ext = $datatypes->{ $ppe->{filetype} }->{ext};
    my $path = LJ::run_hook("url_phonepost", $u, $dppid, $ext) || 
        LJ::journal_base($u) . "/data/phonepost/$dppid.$ext";

    # make link and just return that if in bare mode
    $link = $ppe->{location} eq 'none' ?
        "<img src='$LJ::IMGPREFIX/phonepost2.gif' alt='' width='35' height='33' />" :
        "<a href='$path'><img src='$LJ::IMGPREFIX/phonepost2.gif' alt='' " .
        "width='35' height='33' border='0' /></a>";
    return $link if $mode eq 'bare';

    my $K = $ppe->{length} ? int($ppe->{length} / 1024) . "K" : "";
    my $secs = $ppe->{lengthsecs};
    my $duration = $secs ? sprintf("%d:%02d", int($secs/60), $secs%60) : "";

    # support rss 'enclosures' - podcasting.
    if ($mode eq 'rss') {
        $link = "<enclosure url=\"$path\" length=\"$ppe->{length}\" " .
                "type=\"$datatypes->{ $ppe->{filetype} }->{mime}\" />";
        return $link;
    }

    # return full table
    my $ret = "<table cellspacing='5' cellpadding='0' border='0' class='ljphonepost'><tr>";
    $ret .= "<td valign='top'>$link</td>";
    $ret .= "<td valign='top'><strong>";
    $ret .= $ppe->{location} eq 'none' ? "PhonePost" : "<a href='$path'>PhonePost</a>";
    $ret .= "</strong><br /><em>$K</em>&nbsp;$duration</td>";

    unless ($mode eq 'notrans') {
        my $trans_url = "$LJ::SITEROOT/phonepost/transcribe.bml?user=$u->{user}&amp;ppid=$dppid";
        $ret .= "<td valign='top'><a href='$LJ::SITEROOT/phonepost/about.bml'><img src='$LJ::IMGPREFIX/help.gif' width='14' height='14' border='0' alt='(Help)' /></a></td>";
        my $trans = LJ::PhonePost::get_latest_trans($u, $phonepostid);
        if ($trans) {
        my $by;
        if ($trans->{revid} == 1) {
            $by = LJ::ljuser(LJ::get_username($trans->{posterid}));
        } else {
            # multiple users transcribing, or just multiple transcriptions of one user?
            my $memkey = [$u->{userid},"ppetu:$u->{userid}:$phonepostid"];
            my $tu = LJ::MemCache::get($memkey);
            unless (defined $tu) {
                my $dbr = LJ::get_cluster_reader($u);
                $tu = $dbr->selectrow_array("SELECT COUNT(DISTINCT(posterid)) " .
                                            "FROM phoneposttrans " .
                                            "WHERE journalid=? AND blobid=?",
                                            undef, $u->{'userid'}, $phonepostid + 0);
                LJ::MemCache::set($memkey, $tu);
            }
            $by = ($tu == 1) ? LJ::ljuser(LJ::get_username($trans->{posterid})) : "multiple users";
        }
            my $text = LJ::ehtml($trans->{body});
            $text =~ s/\n/<br \/>/g;

            $ret .= "<td valign='top'><blockquote cite='$path'>&ldquo;$text&rdquo;</blockquote><br />".
                "<a href='$trans_url'>Transcribed</a> by: $by</td>";
        } elsif (LJ::PhonePost::may_transcribe($u, $remote)) {
            $ret .= "<td valign='top'>(<a href='$trans_url'>transcribe</a>)</td>";
        } else {
            $ret .= "<td valign='top'>(no transcription available)</td>";
        }
    }

    $ret .= "</tr></table>";
    return $ret;

}

sub get_latest_trans {
    my ($u, $id) = @_;
    $id += 0;

    my $memkey = [$u->{userid},"ppelt:$u->{userid}:$id"];
    my $lt = LJ::MemCache::get($memkey);
    unless (defined $lt) {
        my $dbcr = LJ::get_cluster_def_reader($u);
        return undef unless $dbcr;

        $lt = "";
        my $latest = $dbcr->selectrow_array("SELECT MAX(revid) FROM phoneposttrans ".
                "WHERE journalid=? AND blobid=?", undef,
                $u->{userid}, $id);
        if ($latest) {
            $lt = $dbcr->selectrow_hashref("SELECT revid,posterid,posttime,subject,body ".
                    "FROM phoneposttrans WHERE journalid=? ".
                    "AND blobid=? AND revid=?", undef,
                    $u->{userid}, $id, $latest);
        }
        LJ::MemCache::set($memkey, $lt);
    }
    return $lt;
}

sub show_phoneposts {
    my ($u_embed, $ditemid, $remote, $eventref) = @_;

    my $replace = sub {
        my $tag = shift;
        my ($user, $userid, $uobj, $phid, $blobid, $dpid);

        # old tag <lj-phonepost user='foo' phonepostid='1' />
        # new tag <lj-phonepost journalid='1234567' dpid='10000422' />
        if ($tag =~ m!^journalid=['"](\d+)['"]\s*dpid=['"](\d+)['"]\s*/?$!) {
            ($userid, $dpid)=($1,$2);

            # prefer phonepostid and userid
            $phid = $dpid >> 8 if $dpid;

        } elsif ($tag =~ m!^(user=['"](\S+)['"])?\s*(phonepostid=['"](\d+)['"])?\s*(userid=['"](\d+)['"])?\s*(blobid=['"](\d+)['"])?\s*/?$!) {
            ($user,$phid,$userid,$blobid)=($2,$4,$6,$8);

            # prefer phonepostid and userid
            $phid = $blobid >> 8
                unless $phid or not $blobid;
            do {
                $uobj = LJ::load_user($user);
                $userid = $uobj->{'userid'};
            } unless $userid or $user eq "";
        }

        return "<b>[Invalid audio link]</b>" unless $phid and $userid;

        return make_link($remote, $userid, $phid, 0, $u_embed, $ditemid);
    };
    $$eventref =~ s!<lj-phonepost\s*([^>]*)>!$replace->($1)!eg;
}

1;