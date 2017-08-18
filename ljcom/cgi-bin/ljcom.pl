#!/usr/bin/perl
#
# LiveJournal.com-specific library
#
# This file is NOT licensed under the GPL.  As with everything in the
# "ljcom" CVS repository, this file is the property of Danga
# Interactive and is made available to the public only as a reference
# as to the best way to modify/extend the base LiveJournal server code
# (which is licensed under the GPL).
#
# Feel free to read and learn from things in "ljcom", but don't use it verbatim
# because we don't want your site looking like LiveJournal.com (our logo
# and site scheme are our identity and we don't want to confuse users)
# and we're sick of getting everybody's payment notifications when
# they use our payment system without any modifications.
#

BEGIN {
    # kill the LJ definition of LJ::is_utf8 so we can override it without warnings
    {
        no strict;
        local $^W = 0;
        *stab = *{"main::LJ::"};
        undef $stab{is_utf8};
    }

}

@LJ::USER_TABLES_LOCAL = ("phonepostentry", "phoneposttrans");

$LJ::BML_DENY_CONFIG = "guide, clients, files";

$LJ::ACCOUNTS_EMAIL = "accounts\@livejournal.com";

%LJ::FIXED_ALIAS = (
                    'lj' => 'lj',        # discarded
                    'lj_notify' => 'lj', # also discarded
                    'test' => 'brad@danga.com',
                    'postmaster' => 'lisa@grrl.org',
                    'webmaster' => 'lj',
                    'support' => 'lj',
                    'abuse' => 'lj',
                    'privacy' => 'lj',
                    'feedback' => 'lj',
                    'press' => 'lj',
                    'bradfitz' => 'brad@danga.com',
                    'paypal' => 'brad@danga.com',
                    'accounts' => 'lj',
                    'frank' => 'brad@danga.com',
                    'lj_coreadmins' => 'brad@danga.com, lisa@grrl.org, nbarkas@moduli.net',
                    'cvs-commits' => 'brad@danga.com, whitaker@danga.com, jproulx@livejournal.com, '.
                                     'mellon@pobox.com, martine@danga.com, mahlon@danga.com, ged@danga.com',
                    'moodthemes' => 'evan@livejournal.com', # aliases to aliases!
                    'bot-watchers' => 'brad@danga.com',
                    );

@LJ::LANGS = qw(en_LJ en_GB de da es fr it ru ja pt eo he nl hu ga is fi  nb sv pl zh lv tr ms)
    unless @LJ::LANGS > 1;

# Useful untainting regexen
%LJ::REGEX = (
    httpuri => qr{(http://(?:(?:(?:(?:(?:[a-zA-Z\d](?:(?:[a-zA-Z\d]|-)*[a-zA-Z\d])?)\.)*(?:[a-zA-Z](?:(?:[a-zA-Z\d]|-)*[a-zA-Z\d])?))|(?:(?:\d+)(?:\.(?:\d+)){3}))(?::(?:\d+))?)(?:/(?:(?:(?:(?:[a-zA-Z\d\$\_.+!*'(),-]|(?:%[a-fA-F\d]{2}))|[;:@&=])*)(?:/(?:(?:(?:[a-zA-Z\d\$\_.+!*'(),-]|(?:%[a-fA-F\d]{2}))|[;:@&=])*))*)(?:\?(?:(?:(?:[a-zA-Z\d\$\_.+!*'(),-]|(?:%[a-fA-F\d]{2}))|[;:@&=])*))?)?)}x,

);


package LJ::Contrib;

# is the given user an acked contributor themselves?
sub is_acked
{
    my ($userid) = @_;
    my $dbr = LJ::get_db_reader();
    return undef unless $dbr and $userid;
    return $dbr->selectrow_array("SELECT COUNT(*) FROM contributed WHERE userid=? AND acks > 0",
                                 undef, $userid);
}

# make $coid acked by $userid
sub ack
{
    my ($coid, $userid) = @_;
    my $dbh = LJ::get_db_writer();
    return undef unless $dbh and $userid and $coid;

    # see if contribution exists
    my $co = $dbh->selectrow_hashref("SELECT * FROM contributed WHERE coid=?",
                                     undef, $coid);
    return 0 unless $co;

    ## Lock the Tables
    $dbh->do("LOCK TABLES contributedack WRITE, contributed WRITE");
    
    ## add the ack
    $dbh->do("REPLACE INTO contributedack (coid, ackuserid) VALUES (?,?)",
             undef, $coid, $userid);

    ## see how many acks it has now.
    my $newcount = $dbh->selectrow_array("SELECT COUNT(*) FROM contributedack WHERE coid=?",
                                         undef, $coid);
    $newcount += 0;

    ## update the contributed table
    $dbh->do("UPDATE contributed SET acks=? WHERE coid=?", undef,
             $newcount, $coid);

    ## Unlock tables
    $dbh->do("UNLOCK TABLES");
    return 1;
}

package LJ::LJcom;

use Inline (C => 'DATA',
            DIRECTORY => $ENV{LJ_INLINE_DIR} || "$ENV{'LJHOME'}/Inline",
	    );
use strict;

{
    eval {
        Inline->init();
    };
    if ($@) {
        die "You seem to have Inline.pm, but you haven't run \$LJHOME/bin/lj-inline.pl\n";
    }
}

sub country_of_ip {
    my $ip = shift;
    return undef unless $LJ::OPTMOD_GEOIP;
    my $gi = $LJ::CACHE_GEOIP_HANDLE ||= Geo::IP::PurePerl->open("$LJ::HOME/cgi-bin/GeoIP.dat");
    return $gi->country_code_by_addr($ip);
}

# old-name (off, on, paid, early (& new))
sub acct_name_short {
    my $caps = shift;
    if ($caps & 0x10) {
        return "on";
    } elsif ($caps & 0x08) {
        return "paid";
    } elsif ($caps & 0x04) {
        return "early";
    } elsif ($caps & 0x02) {
        return "off";
    } elsif ($caps & 0x01) {
        return "new";
    }
    return "??";
}

sub acct_name {
    my $caps = shift;
    my $paiduntil = shift;

    my $v;
    if ($paiduntil)
    {
       $v = $caps & 0x08 && $caps & 0x04 ?
           BML::ml('ljcom.userinfo.types.paid_early_expiring', { 'paiduntil' => $paiduntil }) :
           BML::ml('ljcom.userinfo.types.paid_expiring', { 'paiduntil' => $paiduntil });
    } else {
       $v = $caps & 0x10 && $caps & 0x04 ?
                           $BML::ML{'ljcom.userinfo.types.permanent_early'} :
            $caps & 0x10 ? $BML::ML{'ljcom.userinfo.types.permanent'} :
            $caps & 0x08 && $caps & 0x04 ? 
                           $BML::ML{'ljcom.userinfo.types.paid_early'} :
            $caps & 0x08 ? $BML::ML{'ljcom.userinfo.types.paid'} :
            $caps & 0x04 ? $BML::ML{'ljcom.userinfo.types.early'} :
            $caps & 0x02 ? $BML::ML{'ljcom.userinfo.types.free'} : 
            $caps & 0x01 ? $BML::ML{'ljcom.userinfo.types.trial'} :
            undef;
    }
    return $v;
}

sub is_goatvote_poll {
    my ($po, $qs) = @_;

    # to be a goatvote poll:
    #   the name must have "GoatVote:" prepended
    #   the poster must have siteadmin:goatvote
    # after that, we don't care.  but if a poll is in this format, we can process
    # the data as if it's a goatvote poll.

    # load the questions
    return 0 unless $po->{name} =~ /^GoatVote:/i;

    # now check user permissions
    my $u = LJ::load_userid($po->{posterid});
    return 0 unless LJ::check_priv($u, 'siteadmin', 'goatvote');

    # now make sure the format is right
    @$qs = sort { $a->{pollqid} <=> $b->{pollqid} } @$qs;

    # check one two...
    return 0 unless scalar @$qs >= 2;
    return 0 unless $qs->[0]{type} eq 'radio';
    return 0 unless $qs->[1]{type} eq 'text';

    # okay, it is!
    return 1;
}

sub expresslane_html_comment {
    my ($u, $r) = @_;
    return '' unless $r && $u && LJ::get_cap($u, 'paid');

    my ($free_ct, $free_age) = ($r->header_in('X-Queue-Count')+0, $r->header_in('X-Queue-Age')+0);
    return "<!-- LiveJournal ExpressLane: You received this page before $free_ct free users" .
           ($free_age > 0 ? ", saving approximately $free_age seconds" : '') . "! -->\n";
};

LJ::register_setter("latest_optout", sub {
    &LJ::nodb;
    my ($u, $remote, $key, $value, $err) = @_;

    unless ($value =~ /^(?:yes|no)$/i) {
        $$err = "Illegal value.  Must be 'yes' or 'no'.";
        return 0;
    }

    $value = lc $value eq 'yes' ? 1 : 0;
    LJ::set_userprop($u, "latest_optout", $value);
    return 1;
});

LJ::register_setter("no_mail_alias", sub {
    &LJ::nodb;
    my ($u, $remote, $key, $value, $err) = @_;

    my $dbh = LJ::get_db_writer();

    unless ($value =~ /^[01]$/) {
        $$err = "Illegal value.  Must be '0' or '1'.";
        return 0;
    }
    
    if ($value) {
        $dbh->do("DELETE FROM email_aliases WHERE alias=?", undef,
                 "$u->{'user'}\@$LJ::USER_DOMAIN");
    } elsif ($u->{'status'} eq "A" && LJ::get_cap($u, "useremail")) {
        $dbh->do("REPLACE INTO email_aliases (alias, rcpt) VALUES (?,?)",
                 undef, "$u->{'user'}\@$LJ::USER_DOMAIN", $u->{'email'});
    }

    LJ::set_userprop($u, "no_mail_alias", $value);
    return 1;
});

LJ::clear_hooks();

LJ::register_hook("name_caps", \&acct_name);
LJ::register_hook("name_caps_short", \&acct_name_short);
LJ::register_hook('s2_head_content_extra', \&expresslane_html_comment);

# if a user gets marked underage, we need to clear out their personally
# identifying information
LJ::register_hook('set_underage', sub {
    my $opts = shift;
    return unless $opts->{on}; # only care if turned on

    # update records in the user table
    my $u = $opts->{u};
    LJ::update_user($u, {
        name => $u->{user},
        bdate => undef,
        allow_infoshow => 'N',
        allow_contactshow => 'N',
        has_bio => 'N',
        txtmsg_status => 'off',
        status => 'T',
    });

    # the only thing we have left on 
    return if $u->{statusvis} eq 'X';

    # now empty their bio information
    $u->do("DELETE FROM userbio WHERE userid=?", undef, $u->{'userid'});
    $u->dudata_set('B', 0, 0);

    # clear a ton of userprops
    my @toclear = qw(
        country state city zip icq aolim yahoo msn
        url urlname gender jabber journaltitle journalsubtitle
        friendspagetitle external_foaf_url
    );
    foreach my $prop (@toclear) {
        LJ::set_userprop($u, $prop, undef);
    }
});

# hook to handle creating a button to email someone about spam
LJ::register_hook('spamreport_notification', sub {
    my ($remote, $opts) = @_;

    # they can send in either 'ip => foo' or 'posterid => foo' but we
    # only care about posterid for now
    my $posterid;
    return unless $posterid = $opts->{posterid};
    my $poster = LJ::want_user($posterid);

    # verify we got the remote user and a poster
    $remote = LJ::want_user($remote);
    return undef unless $remote && $poster;

    if ($poster->openid_identity) {
        return "<p><span style='color: red;'>WARNING:</span> The account you are viewing (" .
                LJ::ljuser($poster) . ") is an OpenID identity and has no email address.</p>";
    }

    # step 1) find related users by email
    my $dbr = LJ::get_db_reader();
    return "<?p Database temporarily unavailable, unable to check warning status. p?>"
        unless $dbr;
    my $users = $dbr->selectall_hashref('SELECT * FROM user WHERE email = ?', 'userid', undef, $poster->{email});
    return "<?p Error: no users found matching poster's email address. p?>"
        unless $users && ref $users eq 'HASH' && %$users;

    # now see if any of these have been warned
    my $in = join(',', map { ref $_ ? ($_->{userid} + 0) : 0 } values %$users);
    my $warnings = $dbr->selectall_arrayref("SELECT adminid, shdate, userid FROM statushistory " . 
                                            "WHERE userid IN ($in) AND shtype = 'spam_warning'");
    return "<?p Database error checking for previous warnings. p?>"
        if $dbr->err || !defined $warnings;

    # now construct html
    my ($ret, %emailcounts, %emails);
    foreach my $warning (@$warnings) {
        my $date = $warning->[1];
        if ($date =~ /^(\d\d\d\d)(\d\d)(\d\d)(\d\d)(\d\d)(\d\d)$/) {
            $date = "$1-$2-$3 $4:$5:$6";
        }
        my $admin = LJ::load_userid($warning->[0]);
        my $warned = LJ::load_userid($warning->[2]);

        # come up with notes about this warning
        my $notes = 'none';
        if (LJ::u_equals($poster, $warned)) {
            $notes = 'user match';
        } elsif (lc $poster->{email} eq lc $warned->{email}) {
            $notes = 'email match';
            if ($warned->{status} ne 'A') {
                $notes .= ' (<b>unvalidated email</b>)';
            }
        }

        # query if we haven't queried based on this email address before
        if (!$emailcounts{$warned->{email}}) {
            my $rows = $dbr->selectall_arrayref("SELECT mailid, userid, timesent, subject FROM abuse_mail " .
                                                "WHERE type='abuse' AND mailto = ?", undef, $warned->{email});
            $emailcounts{$warned->{email}} = 1;

            foreach my $row (@{$rows || []}) {
                my ($mailid, $userid, $timesent, $subject) = @$row;
                my $u = LJ::load_userid($userid);

                $emails{$timesent} = "<tr><td>$timesent</td><td>$warned->{email}</td><td>" .
                                     LJ::ljuser($u) . "</td><td>" .
                                     "<a href='/admin/sendmail/query.bml?mode=view&mailid=$mailid'>$subject</a></td></tr>\n";
            }
        }

        # now construct output
        $ret .= "<tr><td>$date</td><td>" . LJ::ljuser($admin) . "</td><td>" . LJ::ljuser($warned) . "</td>";
        $ret .= "<td>$notes</td></tr>\n";
    }
    my $cols = join('', map { "<th style='text-align: left;'>$_</th>" } qw(Date Admin Warned Notes) );
    $ret = "<table width='600'><tr>$cols</tr>$ret</table>" if $ret;

    # now append emails
    if (%emails) {
        $ret .= "<table style='width: 600px; margin-top: 10px;'>";
        $ret .= "<tr>" . join('', map { "<th style='text-align: left;'>$_</th>" } qw(Date Email Admin Subject) ) . "</tr>";
        $ret .= join('', map { $emails{$_} } sort { $a cmp $b } keys %emails);
        $ret .= "</table>";
    }

    # get message to put into body for sending
    my $message = LJ::load_include('spam-warning');
    $message =~ s/\[\[user\]\]/$poster->{user}/ig;

    # now construct the parts of the email
    $ret .= "<form method='post' action='/admin/sendmail/send.bml?action=preview'>";
    $ret .= LJ::html_hidden(email => $poster->{email},
                            bcc => $remote->{email},
                            subject => "Your LiveJournal Account",
                            request => '000000',
                            message => $message,
                            extra => "spam-notification;$poster->{userid}",
                            from => "abuse",);
    $ret .= '<p align="center">' . LJ::html_submit('Send Warning Email') . '</p>';

    # include unvalidated email warning
    unless ($poster->{status} eq 'A') {
        $ret .= "<p><span style='color: red;'>WARNING:</span> The account you are viewing (" .
                LJ::ljuser($poster) . ") has an <b>unvalidated email address</b>.</p>";
    }

    # return
    $ret = "<?standout $ret standout?></form><br />";
    return $ret;
});


### Fetch the value for the given I<field> from the specified I<arghash>,
### untaint it with the given I<pattern>, and return the results. If the
### I<pattern> has match-groups in it, the values matched with them will be the
### returned values. Otherwise, the entire input will be returned.
sub untaint {
    my ( $arghash, $field, $pattern ) = @_;

    return '' unless exists $arghash->{$field} && defined $arghash->{$field};
	my $input = $arghash->{$field};
    $pattern = qr{$pattern}i unless ref $pattern eq 'Regexp';

    my @matches = ( $input =~ $pattern ) or return '';
    return @matches if $1;
    return $input;
}


# hook to do transforms for posting pictures from FB
LJ::register_hook('transform_update_postpics', sub {
    my ($GET, $POST) = @_;

    my (
        @ids,
        $picsize,
        $columns,
        $caporient,
        $border,
        @pics,
        @rows,
        $row,
        $nextrow,
        $pic,
        $imgtag,
        $imgcell,
        $capcell,
        @html,
       );


    # Untaint and split the picture ids to post
    @ids = split /:/, $1 if exists $POST->{ids} && $POST->{ids} =~ m{^([\d:]+)};

    return unless $POST->{'wizard-picsize'} =~ m{^([tsf])$}i;
    $picsize = $1;
    $columns = $1 if exists $POST->{'wizard-columns'}
        && $POST->{'wizard-columns'} =~ m{^([1-4])$};
    $caporient = $1 if exists $POST->{'wizard-caporient'}
        && $POST->{'wizard-caporient'} =~ m{^([arbl0])$};
    $border = 1 if $POST->{'wizard-border'};

    # Default/bound some values if not defined or valid -- Large picsize
    if ( $picsize eq 'f' ) {
        $columns = 1;
    }

    # Medium picsize
    elsif ( $picsize eq 's' ) {
        $columns = 1 if $columns < 1;
        $columns = 2 if $columns > 2;
    }

    # Thumbnail picsize
    else {
        $columns = 1 if $columns < 1;
        $columns = 4 if $columns > 4;
    }

    # Make sure the caption orientation will work with the number of columns
    # defined.
    if ( $columns == 1 || $columns == 3 ) {
        $caporient = 'b' unless $caporient eq '0' || $caporient eq 'a';
    }

    # Build the array of ids to flow into the chosen layout
    @pics = map {{
        id        => $_,
        captitle  => untaint( $POST, "subj$_", qr{([\t\r\n\x20-\xff]*)} ),
        capdesc   => untaint( $POST, "desc$_", qr{([\t\r\n\x20-\xff]*)} ),
        img       => untaint( $POST, "${picsize}img$_", $LJ::REGEX{httpuri} ),
        imgwidth  => untaint( $POST, "${picsize}w$_", qr{(\d+)} ),
        imgheight => untaint( $POST, "${picsize}h$_", qr{(\d+)} ),
        url       => untaint( $POST, "url$_", $LJ::REGEX{httpuri} ),
    }} @ids;


    # Build a table for the pics and their captions
    while ( @pics ) {
        $row = [];
        $nextrow = [];

        # Fill up each row with the specified number of columns
        while ( @$row < $columns ) {
            $pic = shift @pics;

            # If there's a picture to add, do so
            if ( $pic ) {
                $imgtag = sprintf q{<img src="%s" alt="%s" height="%d" width="%d" border="0" />},
                                   @{$pic}{qw[img captitle imgheight imgwidth]};
                $imgcell = sprintf q{<a href="%s">%s</a>},
                                   $pic->{url}, $imgtag;
                $capcell = sprintf qq{<strong>%s</strong><br />\n\t\t%s},
                                   @{$pic}{qw[captitle capdesc]};
            }

            # Otherwise it'll be a blank cell
            else {
                $imgcell = '';
                $capcell = '';
            }

            ## Now arrange the caption relative to the pic if there is a caption

            # Above
            if ( $caporient eq 'a' ) {
                push @$row, $capcell;
                push @$nextrow, $imgcell;
            }

            # Below
            elsif ( $caporient eq 'b' ) {
                push @$row, $imgcell;
                push @$nextrow, $capcell;
            }

            # Leftish captions, then the image, then rightish captions
            else {
                push @$row, $capcell if $caporient eq 'l';
                push @$row, $imgcell;
                push @$row, $capcell if $caporient eq 'r';
            }
        }

        push @rows, $row;
        push @rows, $nextrow if @$nextrow;
    }

    # Mangle the rows into an indented HTML table
    @html = ();

    push @html, (
        "  <!-- Posted pictures -->",
        "  <table>"
       );
    foreach my $row ( @rows ) {
        push @html, (
            "    <tr>",
            (map { "      <td>$_</td>" } @$row),
            "    </tr>",
           );
    }
    push @html, "  </table>\n  <!-- End of Posted pictures -->\n\n";

    # Stick the results into the posted event
    $POST->{event} = join "\n", @html;
    return;
});

# hook to hit akamai to remove a userpic
LJ::register_hook('expunge_userpic', sub {
    my ($picid, $userid) = @_;
    $picid += 0;
    $userid += 0;
    return undef unless $picid && $userid;

    # now hit akamai
    my $res = SOAP::Lite
        ->service($LJ::AKAMAI{service})
        ->purgeRequest($LJ::AKAMAI{username}, $LJ::AKAMAI{password}, $LJ::AKAMAI{network},
                       [''], ["$LJ::USERPIC_ROOT/$picid/$userid"]);

    # see if there was an error
    my ($code, $msg) = ($res->{resultCode}, $res->{resultMsg});
    if ($code == 300) {
        return [ 'info', "Akamai cache purged successfully." ];
    } else {
        return [ 'error', "Error $code: $msg (CACHE NOT PURGED)" ];
    }
});

# cluster definition hook
LJ::register_hook('cluster_description', sub {
    my $clusterid = $_[0]+0;
    my ($ob, $cb) = $_[1] ? ('<strong>', '</strong>') : ('', '');

    my ($cid, $scid) = ($clusterid, undef);
    ($cid, $scid) = ($1, $2) if $clusterid =~ /^(\d)(\d+)$/;
    
    my $text = $ob . ($LJ::CLUSTERNAME{$cid} || $cid) . $cb;
    $text .= ", subcluster $ob$scid$cb" if defined $scid;
    return $text;
});

# hook to override show_poll for GoatVote polls
LJ::register_hook('alternate_show_poll_html', sub {
    my ($po, $mode, $qs) = @_;

    # if mode is enter, we don't handle
    return undef if $mode eq 'enter';

    # if it's not a goatvote...
    return undef unless LJ::LJcom::is_goatvote_poll($po, $qs);

    # return a link to the goatvote page
    LJ::Poll::clean_poll(\$po->{name}) if $po->{name};
    my $ret = "<b><a href=\"$LJ::SITEROOT/poll/goatvote.bml?id=$po->{pollid}\">Poll \#$po->{pollid}:" .
              "</a></b> <i>$po->{name}</i><br />Open to: <b>$po->{whovote}</b>, results viewable " .
              "to: <b>$po->{whoview}</b><br />This is a GoatVote poll.  Current results are " .
              "<a href=\"$LJ::SITEROOT/poll/goatvote.bml?id=$po->{pollid}\">available elsewhere</a>.  You " .
              "can also <a href=\"$LJ::SITEROOT/poll/?id=$po->{pollid}&mode=enter\">fill out the poll</a>.";
    return $ret;
});

# extra viewing line HTML
LJ::register_hook('extra_poll_description', sub {
    my ($po, $qs) = @_;

    # if it's a goatvote
    return '' unless LJ::LJcom::is_goatvote_poll($po, $qs);

    # okay return our string
    return "You may view the <a href=\"$LJ::SITEROOT/poll/goatvote.bml?id=$po->{pollid}\">" .
           'GoatVote results in progress</a>.';
});

# hook to show goatvote in poll pregenerator
LJ::register_hook('poll_pregeneration_html', sub {
    my ($u, $is_authas) = @_;
    return unless LJ::check_priv($u, 'siteadmin', 'goatvote');

    # okay, show them the options
    my $getextra = $is_authas ? "authas=$u->{'user'}&" : '';
    my $body = "<?h1 Pregenerated Polls h1?><?p The following types of polls can automatically be " .
               "generated to assist you in quickly and easily creating a poll. p?>";
    $body .= "<ul><li><a href=\"create.bml?${getextra}pregen=1\">GoatVote</a></li></ul>";
    $body .= "<?p Or, use the form below to begin creating your very own poll. p?>";
    return $body;
});

# actually pregenerate a poll
LJ::register_hook('pregenerate_poll', sub {
    my ($u, $pgid) = @_;
    return undef unless $pgid && LJ::check_priv($u, 'siteadmin', 'goatvote'); # only one option for now

    # throw a goatvoate together
    if ($pgid == 1) {
        return {
            count => 3,
            name => 'GoatVote: ',
            whovote => 'all',
            whoview => 'all',
            pq => [
                {
                    type => 'radio',
                    question => 'What point of view do you most agree with?',
                    opts => 5,
                    opt => [ '', '', '', '', '' ],
                }, {
                    type => 'text',
                    question => 'What URL supports this point of view best?',
                    size => 30,
                    maxlength => 255,
                }, {
                    type => 'text',
                    question => 'What other URL supports this point of view?',
                    size => 30,
                    maxlength => 255,
                }
            ],
        };
    }

    # caller expects a hashref
    return {};
});

LJ::register_hook("get_cap_bit", sub {
    my $name = shift;
    return undef unless $name;

    return $LJ::Pay::capinf{$name}->{'bit'};
});

# Register hooks for turning on/off certain cap bits
# This needs to be expanded to activate/deactivate bonus
# features, etc, but right now we just be sure to run 
# LJ::activate_userpics()
LJ::register_hook("modify_caps", sub {
    my $arg = shift;

    # 1-4 = free-perm, 9 = extra userpics
    foreach (1..4, 9) {
        next unless $arg->{'cap_on_mod'}->{$_} || $arg->{'cap_off_mod'}->{$_};

        # only run once, with newest caps...
        $arg->{'u'}->{'caps'} = $arg->{'newcaps'};
        return LJ::activate_userpics($arg->{'u'});
    }

    return 1;
});

# check for a user diskquota cap.  returning undef defers the check to normal means
LJ::register_hook("check_cap_disk_quota", sub {
    my $u = shift;
    return undef unless $u;

    my $dbr = LJ::get_db_reader();
    my $size = $dbr->selectrow_array("SELECT size FROM paidexp WHERE userid=? AND item='diskquota'",
                                     undef, $u->{'userid'});
    return $size || undef;
});

LJ::register_hook("ssl_check", sub {
    my $r = $_[0]{r};
    return
        $r->header_in("X-LJ-SSL") ||
        ($LJ::IS_DEV_SERVER && $r->header_in("Host") eq "secure.$LJ::DOMAIN");
});

LJ::register_hook("post_create", \&LJ::Pay::post_create);

LJ::register_hook("create.bml_opts", sub {
    my $ar = shift;
    my $ret = $ar->{ret};
    my $get = $ar->{get};
    my $post = $ar->{post};

    $$ret .= "<li><div class='formitem'><div class='formitemName'>$BML::ML{'ljcom.accounttype'}</div>";
    $$ret .= "<div style='margin: 10px 0 10px 0px'>";

    my $valid_code = 0;
    my $code = $get->{code} || $post->{code};
    if ($code) {
        my $dbr = LJ::get_db_reader();
        my ($acid, $auth) = LJ::acct_code_decode($code);

        if (my $piid = $dbr->selectrow_array("SELECT piid FROM acctpayitem WHERE acid=?",
                                             undef, $acid))
        {
            my ($item, $qty) = $dbr->selectrow_array("SELECT item, qty FROM payitems ".
                                                     "WHERE piid=?", undef, $piid);

            if ($item eq 'perm') {
                $$ret .= "Permanent Account";
            } else {
                $$ret .= "Paid for " . ($qty+0) . " Months";
            }
            $$ret .= ", from code: $code";

            $valid_code++;
        }
    }

    unless ($valid_code) {
        my @atypes = ([  0, $BML::ML{'ljcom.account.free'} ],
                      [  2, $BML::ML{'ljcom.account.paid2'} ],
                      [  6, $BML::ML{'ljcom.account.paid6'} ],
                      [ 12, $BML::ML{'ljcom.account.paid12'} ]);

        my $cur_type = $post->{'ljcom_atype'}+0;
        foreach my $at (@atypes) {
            $$ret .= LJ::html_check({ name => 'ljcom_atype', id => "ljcom_atype_$at->[0]", 
                                      value => $at->[0],
                                      type => 'radio', selected => ($cur_type == $at->[0]) });
            $$ret .= " <label for='ljcom_atype_$at->[0]'>$at->[1]</label><br />\n";
        }
    }

    $$ret .= "</div>";


    # if they've already got a code for paid time, no reason to show the feature list
    return if $valid_code;

    $$ret .= '
<table cellspacing="1" cellpadding="4" border="0" width="100%">
<tr>
<td class="tablehead" style="text-align: left;">'.$BML::ML{'ljcom.account.feature'}.'</td>
<td class="tablehead">'.$BML::ML{'ljcom.account.free'}.'</td>

<td class="tablehead">'.$BML::ML{'ljcom.account.paid'}.'</td>
</tr>';
    
    my @features = (
                    [ "$BML::ML{'ljcom.account.feature.ownblog'}", "Y", "Y" ],
                    [ "$BML::ML{'ljcom.account.feature.styles'}", "$BML::ML{'ljcom.account.feature.limit'}", "Y" ],
                    [ "$BML::ML{'ljcom.account.feature.syn'}", "Y", "Y" ],
                    [ "$BML::ML{'ljcom.account.feature.pp'}", "N", "Y" ],
                    [ "$BML::ML{'ljcom.account.feature.search'}", "N", "Y" ],
                    [ "$BML::ML{'ljcom.account.feature.photo'}", "N", "Y" ],

                    );
    my %map = ("N" => "-",
               "Y"=> "<img src='$LJ::IMGPREFIX/blue_check.gif' width='15' height='15' alt='Yes' />");
    foreach my $f (@features) {
        my ($name, $free, $paid) = @$f;
        $free = $map{$free} || $free;
        $paid = $map{$paid} || $paid;
        $$ret .= "<tr><td class='tablelabel'>$name</td>".
            "<td class='tablecontent'>$free</td>".
            "<td class='tablecontent'>$paid</td></tr>\n";
    }
    $$ret .= "<tr><td rowspan='3' class='tablebottom'>" . 
        BML::ml('ljcom.account.feature.full2', { aopts => "target='_new' href='$LJ::SITEROOT/site/accounts.bml'" }) .
        "</td></tr></table>\n";
    
    $$ret .= "</div></li>";

    return;
});

LJ::register_hook("create.bml_postsession", sub {
    my $ar = shift;
    my $post = $ar->{post};
    my $redir = $ar->{redirect};
    my $u = $ar->{u};

    my $atype = int($post->{'ljcom_atype'});
    $atype = 0 unless $LJ::Pay::account{$atype};
    LJ::set_userprop($u, "create_accttype", $atype || "free");
    return unless $atype || $u->underage;

    my $cartobj = LJ::Pay::new_cart($u);
    my $rv = LJ::Pay::add_cart_item($cartobj, {
        item => 'paidacct',
        qty => $post->{ljcom_atype},
        amt => $LJ::Pay::account{$atype}->{amount},
        rcptid => $u->{userid},
    }) if $atype;
    my $rv2 = LJ::Pay::add_cart_item($cartobj, {
        item => 'coppa',
        rcptid => $u->{userid},
    }) if $u->underage;
    if ($cartobj && ($rv || !$atype) && ($rv2 || !$u->underage)) {
        my $c = $cartobj->{payid} . "-" . $cartobj->{anum};
        if ($u->underage) {
            my $extra = $u->underage_status eq 'O' ? '&o=1' : '';
            $$redir = "$LJ::SITEROOT/agecheck/?c=$c$extra";
        } else {
            $$redir = "$LJ::SITEROOT/pay/?c=$c";
        }
    }
});

LJ::register_hook("userinfo_rows", sub {
    my $args = shift;
    my $u = $args->{'u'};
    my $dbr = $args->{'dbr'};
    my $remote = $args->{'remote'};
    my @ret;
    return if $u->{journaltype} eq "I";
    $ret[0] = "<a href='/support/faqbrowse.bml?faqid=38' style='white-space: nowrap'>$BML::ML{'ljcom.userinfo.accounttype'}</a>";

    my $paid = $u->{'caps'} & 8;
    my $perm = $u->{'caps'} & 16;
    if ($remote && $paid && ! $perm && 
        ($remote->{'userid'} == $u->{'userid'} ||
         $u->{'journaltype'} ne 'P' &&
         LJ::check_rel($u->{'userid'}, $remote->{'userid'}, 'A')))
    {
        my $paiduntil = $dbr->selectrow_array("SELECT paiduntil FROM paiduser ".
                                              "WHERE userid=$u->{'userid'}");
        $ret[1] = LJ::LJcom::acct_name($u->{'caps'}, substr($paiduntil, 0, 10));
    } else {
        $ret[1] = LJ::LJcom::acct_name($u->{'caps'});
    }
    return @ret;    
});

LJ::register_hook("update.bml_disable_can_post", sub {
    my $arg = shift;
    ${$arg->{title}} = "Trial account expired";
    ${$arg->{body}} = "Your 30 day LiveJournal trial account has expired.  For more information on what you can do at this point, check out the <a href='/trial/'>LiveJournal Trial Page</a>.";
    return 1;
});


LJ::register_hook("login_add_opts", sub {
    my $args = shift;
    my $u = $args->{'u'};
    my $form = $args->{'form'};
    my $optref = $args->{'opts'};

    if (LJ::get_cap($u, "fastserver") && ! $form->{'notfast'}) {
        push @$optref, "FS"; # fast server
    }
});

LJ::register_hook("post_logout", sub {
    my $site_domain = $LJ::SITEROOT;
    $site_domain =~ s!^\w+://!!;
    $site_domain =~ s!(:\d+)?/.*!!;
        
    # feb-24-2003: fastserver cookie is now unused, but we'll delete it for awhile
    foreach (qw(ljfastserver betatest)) {
        BML::set_cookie($_, "", undef, $LJ::COOKIE_PATH, $LJ::COOKIE_DOMAIN);
    }
});

LJ::register_hook("userinfo_html_by_user", sub {
    my $o = shift;
    my $r = $o->{'ret'};
    my $u = $o->{'u'};
    return unless (LJ::get_cap($u, "paid"));
    $$r .= "<a href='/paidaccounts/'><img src='$LJ::IMGPREFIX/talk/md10_thumbup.gif' width='25' height='19' alt='$BML::ML{'ljcom.userinfo.paiduser'}' style='vertical-align: middle; border: 0;' /></a>";
});

LJ::register_hook("userinfo_local_props", sub {
    my $o = shift;
    push @{$o->{props}}, 'no_mail_alias';
});

LJ::register_hook("canonicalize_url", sub {
    my $u = shift;
    $$u =~ s!^http://livejournal\.com!http://www.livejournal.com!;
    if ($$u =~ m!^http://www\.livejournal\.com!) {
        $$u =~ s!&nc=\d+!!;
    }
    
    foreach my $pattern (qw(
                            \.(jpg|jpeg|gif|png)$
                            selectsmart\.com
                            /test
                            /quiz
                            quiz\.html
                            test\.html
                            elitechild\.com
                            livejournal\.com/user
                            ))
    {
        next unless $$u =~ /$pattern/i;
        $$u = "";
        return;
    }

    # strip anchor names (to prevent some online tests from showing up
    # a billion times)
    $$u =~ s/\#.+//;
});

LJ::register_hook("expand_embedded", sub {
    LJ::PhonePost::show_phoneposts(@_);
});

LJ::register_hook("url_phonepost", sub {
    my ($u, $dppid, $ext) = @_;
    my $host = $LJ::FILES_DOMAIN || "files.livejournal.com";
    return "http://$host/$u->{'user'}/phonepost/$dppid.$ext";
});

LJ::register_hook("data_handler:phonepost", sub {
    my ($user, $pathextra) = @_;
    if ($pathextra =~ m#^/(\d+)\.(mp3|ogg|wav)$#) {
        my $dppid = $1;
        return sub {
            my $r = shift;
            my $u = LJ::load_user($user);
            return LJ::PhonePost::apache_content($r, $u, $dppid);
        };
    }
    return undef;
});

LJ::register_hook("files_handler:phonepost", sub {
    my ($user, $pathextra) = @_;
    if ($pathextra =~ m#^/(\d+)\.(mp3|ogg|wav)$#) {
        my $dppid = $1;
        return sub {
            my $r = shift;
            my $u = LJ::load_user($user);
            return LJ::PhonePost::apache_content($r, $u, $dppid);
        };
    }
    return undef;
});

LJ::register_hook("modify_login_menu", sub {
    my $a = shift;
    my $u = $a->{'u'};
    my $user = $a->{'user'};
    my $menu = $a->{'menu'};

    unless ($u->{'caps'} & (8|4)) { # unless perm or paid
        LJ::load_user_props($u, 'browselang');
        my $text = LJ::Lang::get_text($u->{'browselang'}, 'ljcom.menu.upgrade');
        push @$menu, { 'text' => $text,
                       'url' => "$LJ::SITEROOT/paidaccounts/", };
    }
});

LJ::register_hook("validate_get_remote", sub {
    my $a = shift;
    my $caps = $a->{'caps'};
    my $criterr = $a->{'criterr'};
    my $sopts = $a->{'sopts'};

    if ($sopts =~ /\.FS\b/ && ! LJ::get_cap($caps, 'fastserver')) {
        $$criterr = 1;   # forged fastserver session option!
        return 0;
    }

    return 1;
});

LJ::register_hook("emailconfirmed", sub {
    &LJ::nodb;
    my ($u) = @_;
    return unless LJ::get_cap($u, "useremail");
    return if exists $LJ::FIXED_ALIAS{$u->{'user'}};

    LJ::load_user_props($u, { 'use_master' => 1 }, "no_mail_alias");
    return if $u->{'no_mail_alias'};

    my $dbh = LJ::get_db_writer();
    $dbh->do("REPLACE INTO email_aliases (alias, rcpt) VALUES (?,?)",
             undef, "$u->{'user'}\@$LJ::USER_DOMAIN", $u->{'email'});
});

LJ::register_hook("bad_password", sub {
    return undef if $LJ::NO_PASSWORD_CHECK;

    my $arg = shift;
    my $u = ref $arg eq 'HASH' ? $arg : undef;

    # only scalar password passed
    unless ($u) {
        return undef unless $LJ::OPTMOD_CRACKLIB;
        my $reason = Crypt::Cracklib::fascist_check($arg);
        return $reason eq 'ok' ? undef : $reason;
    }

    # u hashref passed
    my $reason = $LJ::OPTMOD_CRACKLIB ? 
        Crypt::Cracklib::fascist_check($u->{'password'}) : "ok";
    return $reason unless $reason eq 'ok';

    # we have a $u passed, we can do smart checking
    my $user = lc($u->{'user'});
    my $pass = lc($u->{'password'});
    my $email = lc($u->{'email'});
    my $name = lc($u->{'name'});
    my $ml_code = undef;

    # username matches
    if ($user && (index($pass, $user) >= 0 || index($user, $pass) >= 0)) {
        $ml_code = 'ljcom.badpass.username';
    }

    # email matches
    elsif ($email && (index($pass, $email) >= 0 || index($email, $pass) >= 0)) {
        $ml_code = 'ljcom.badpass.email';
    }

    # real name matches
    elsif ($name && (index($pass, $name) >= 0 || index ($name, $pass) >= 0)) {
        $ml_code = 'ljcom.badpass.realname';
    }

    if ($ml_code) {
        LJ::load_user_props($u, 'browselang');
        return LJ::Lang::get_text($u->{'lang'}, $ml_code);
    }

    # no match
    return undef;

});

# meetup links
LJ::register_hook("interests_bml", sub {
    my $arg = shift;
    my $db = LJ::get_db_reader();
    my $r = $db->selectrow_hashref("SELECT urlkey, name FROM meetup_ints WHERE intid=?", undef,
                                   $arg->{'intid'});
    return unless $r;
    my $ret = $arg->{'ret'};
    my $name = LJ::ehtml($r->{'name'});
    my $urlargs;
    my $remote = $arg->{'remote'};
    if ($remote) {
        LJ::load_user_props($db, $remote, "zip");
        if ($remote->{'zip'}) {  
            $urlargs .= "?zip=$remote->{'zip'}";
        }
    }
    my $moreinfo;
    if ($LJ::HELPURL{'meetup'}) {
        $moreinfo = BML::ml('ljcom.meetup.moreinfo', {'link' => $LJ::HELPURL{'meetup'}});
    }
    my $link = "<a href=\"http://$r->{'urlkey'}.meetup.com/$urlargs\">";
    $link .= BML::ml('ljcom.meetup.link', { 'name' => $name}) . "</a>";
    $$ret .= "<?h1 $BML::ML{'ljcom.meetup.head'} h1?>";
    $$ret .= "<?p " . BML::ml('ljcom.meetup.text', { 'link' => $link }) . " $moreinfo p?>";
});

sub LJ::is_utf8 {
    return isLegalUTF8String($_[0], length($_[0]));
}

LJ::register_hook("s1_style_select", sub {
    my $arg = shift;
    my $styleid = $arg->{'styleid'};
    my $u = $arg->{'u'};
    if ($arg->{'view'} eq "lastn" && $u->{'journaltype'} eq "Y" && $u->{'password'} eq "" &&
        $LJ::SYN_LASTN_S1) {
        $$styleid = $LJ::SYN_LASTN_S1;
    }
});

LJ::register_hook("force_s1", sub {
    my $u = shift;
    my $forceflag = shift;

    # Force syndicated accounts to S1
    if ( $u->{journaltype} eq 'Y' ) {
        $$forceflag = 1;
    }
});

LJ::register_hook("finduser_extrainfo", sub {
    my $arg = shift;
    my $u = $arg->{'u'};
    my $dbh = $arg->{'dbh'};
    my $ret;
    if ($u->{'caps'} & 16) {
        $ret .= "  Permanent account.\n";
    }
    if ($u->{'caps'} & 8) {
        my $unt = $dbh->selectrow_array("SELECT paiduntil FROM paiduser WHERE userid=?", undef,
                                        $u->{'userid'});
        $ret .= "  Paid until: $unt\n";
    }
});

LJ::register_hook("support_see_request_html", sub {
    my $arg = shift;
    my $sp = $arg->{'sp'};
    my $cat = $sp->{_cat}->{'catkey'};
    my $ret = $arg->{'retref'};
    my $email = $arg->{'email'};
    my $u = $arg->{'u'};
    my $remote = $arg->{'remote'};

    my $manage = LJ::remote_has_priv($remote, "moneysearch") || LJ::remote_has_priv($remote, "moneyview");

    if ($cat eq "accounts" && $manage) {
        $$ret .= "<p align='center'><b>";
        $$ret .= "[<a href='/admin/accounts/paidsearch.bml?method=email&amp;value=" . LJ::eurl($email) . "'>paidsearch: email</a>] ";
        if ($sp->{'requserid'}) {
            $$ret .= "[<a href='/admin/accounts/paidsearch.bml?method=user&amp;value=$u->{'user'}'>paidsearch: user</a>] ";
        }
        $$ret .= "</b></p>";
    }

});

LJ::register_hook("recent_action_flags", sub {
    # these flags live in their own site-local namespace
    # and must be prepended with '_' to avoid collisions

    return { phonepost     => '_F',            # 'F'onepost, meh
             phonepost_mp3 => '_M' }->{$_[0]}; # 'M'p3 
});

LJ::register_hook("postpost", sub {
    my $arg = shift;
    my $uo = $arg->{'journal'};
    return if $uo->{'journaltype'} eq "Y";  # no syndicated
    my $up = $arg->{'poster'};

    # if the poster has opted out, don't record the post
    LJ::load_user_props($up, "latest_optout");
    return if $up->{latest_optout};

    # setup security
    my $security = $arg->{'security'};
    $security = $arg->{'allowmask'} == 1 ? 'friends' : 'custom'
        if ($security eq 'usemask');

    # see if it has a public image in it.  heuristic:  it's an http://
    # URL in an image tag, or it's alone and has a popular image extension
    my $img;
    if ($security eq "public" &&
        ($arg->{'event'} =~ m!<img.+src=([\'\"])(http://[^\'\"]+?)\1!i ||
         $arg->{'event'} =~ m!<img.+src=(http://\S+?)[\s\>\'\"]!i ||
         $arg->{'event'} =~ m!(http://\S+\.(?:gif|jpe?g|png)\b)!i)) {
        $img = $2 || $1;

        # make sure image is good and hasn't been used in last 4 hours
        unless (length($img) < 100 && $img !~ /[\n\r]/ &&
            LJ::MemCache::add("ljcom_imgused:$img", 1, 3600*4)) {
            undef $img;
        }
    }

    LJ::cmd_buffer_add($uo->{clusterid}, $uo->{'userid'}, "ljcom_newpost", {
        'timepost' => time(),
        'journalid' => $uo->{'userid'},
        'posterid' => $up->{'userid'},
        'itemid' => $arg->{'itemid'},
        'anum' => $arg->{'anum'},
        'security' => $security,
        'img' => $img,
        'taglist' => $arg->{'props'}->{'taglist'},
    });
});

# TEMP: Log unknown8bit posts to decide if they can be disabled later
# see also table definition in update-db-local.pl
LJ::register_hook("postpost", sub {
    my $entry = shift;
    return unless $LJ::DEBUG{'survey_8bit'} && $entry->{'props'}->{'unknown8bit'};
    my $dbh = LJ::get_db_writer();
    $dbh->do("REPLACE INTO survey_v0_8bit (userid, timepost) VALUES (?, UNIX_TIMESTAMP())", 
             undef, $entry->{'poster'}->{'userid'});
});

LJ::register_hook("cmdbuf:ljcom_newpost:start", sub {
    my ($dbh) = @_;
    $LJ::CACHE_RECENTPOSTS_CHANGES = 0;
    $LJ::CACHE_RECENTPOSTS ||= LJ::MemCache::get("blob:ljcom_latestposts2") || [];

    $LJ::CACHE_RECENTIMG_CHANGES = 0;
    $LJ::CACHE_RECENTIMG ||= LJ::MemCache::get("blob:ljcom_latestimg") || [];
});

LJ::register_hook("cmdbuf:ljcom_newpost:too_old", sub { 60*60*2 });

LJ::register_hook("cmdbuf:ljcom_newpost:run", sub {
    my ($dbh, $db, $c) = @_;
    my $args = $c->{'args'};

    my $recent = $LJ::CACHE_RECENTPOSTS;
    my $uj = LJ::load_userid($args->{'journalid'});
    my $up = LJ::load_userid($args->{'posterid'});
    return unless $uj->{'statusvis'} eq "V" && $up->{'statusvis'} eq "V";

    LJ::load_user_props($uj, "journaltitle");

    my $rp = {};
    $rp->{$_} = $args->{$_}+0 foreach qw(timepost itemid anum);
    $rp->{security} = $args->{security};
    $rp->{clusterid} = $up->{clusterid}+0;
    $rp->{tags} = [ split(/\s*,\s*/, $args->{taglist}) ];
    $rp->{journalu} = {
        user => $uj->{user},
        userid => $uj->{userid}+0,
        journaltype => $uj->{journaltype},
    },
    $rp->{journalp} = {
        user => $up->{user},
        userid => $up->{userid}+0,
        name => $up->{name},
    };

    push @$recent, $rp;
    $LJ::CACHE_RECENTPOSTS_CHANGES++;

    if ($args->{'img'}) {
        my $rimg = $LJ::CACHE_RECENTIMG;
        push @$rimg, [ $args->{'img'}, $rp->{journalu}, $args->{'itemid'}, $args->{'anum'} ];
        $LJ::CACHE_RECENTIMG_CHANGES++;
    }
});

LJ::register_hook("cmdbuf:ljcom_newpost:finish", sub {
    my ($dbh) = @_;
    return unless $LJ::CACHE_RECENTPOSTS_CHANGES;
    my $recent = $LJ::CACHE_RECENTPOSTS;
    my $rimg = $LJ::CACHE_RECENTIMG;

    my $show_max = $LJ::STATS_LATESTPOSTS_MAX || 1000;

    @$recent = sort { $b->{'timepost'} <=> $a->{'timepost'}  } @$recent;
    splice(@$recent, $show_max) if @$recent > $show_max;

    LJ::MemCache::set("blob:ljcom_latestposts2", $recent);

    if ($LJ::CACHE_RECENTIMG_CHANGES) {
        my $size = @$rimg;
        splice(@$rimg, 0, $size - $show_max) if $size > $show_max;
        LJ::MemCache::set("blob:ljcom_latestimg", $rimg);
    }
    LJ::MemCache::set("blob:ljcom_latestposts_stats",
                      [ scalar(@$recent),
                        $recent->[0]->{timepost},
                        $recent->[-1]->{timepost} ]);
});

# returns 1 if too fast, 0 if okay
LJ::register_hook("ccpay_rate_check", sub {
    my ($tries, $lasttry) = @_;
    
    # TRIES     : LIMIT
    #   -  1.. 3:  0 sec
    #   -  4.. 6:  5 sec
    #   -  7..10: 15 sec
    #   - 11..19: 60 sec
    #   - 20....: 30 min
    
    my $now = time();
    return 0 if $tries <= 3;
    return 0 if $tries <= 6 && $lasttry < $now - 5;
    return 0 if $tries <= 10 && $lasttry < $now - 15;
    return 0 if $tries <= 19 && $lasttry < $now - 60;
    return 0 if $lasttry < $now - 1800;
    return 1;
});

LJ::register_hook("cmdbuf:pay_fb_xmlrpc:run", sub {
    my ($dbh, $db, $c) = @_;

    return undef unless $LJ::FB_SITEROOT && $LJ::FB_QUOTA_NOTIFY;

    my $args = $c->{args};
    my $userid = $c->{journalid};

    # args: item, size, exp

    my $u = LJ::load_userid($userid);
    return undef unless $u;

    eval "use XMLRPC::Lite (); 1;"
        or return undef;

    return XMLRPC::Lite 
        ->new( proxy => "$LJ::FB_SITEROOT/interface/xmlrpc",
               timeout => 5 )
        ->call('FB.XMLRPC.set_quota', # xml-rpc method call
               { user => $u->{user},
                 item => $args->{item},
                 size => $args->{size},
                 exptime => $args->{exptime},
             });
});

# given an S2 context, give back a BML langid.
LJ::register_hook("set_s2bml_lang", sub {
    my ($ctx, $langref) = @_;

    my $lang = S2::get_property_value($ctx, 'lang_current');

    $lang = 'en' unless grep(/$lang/, @LJ::LANGS);
    $lang = 'en_LJ' if ($lang eq 'en');

    $$langref = $lang;
});

# what tables bin/moveucluster.pl should move that aren't general code
LJ::register_hook("moveucluster_local_tables", sub {
    return {
        'phonepostentry' => 'userid',
        'phoneposttrans' => 'journalid',
    };
});

# remove transcription group userprop
LJ::register_hook("delete_friend_group", sub {
    my ($u, $bit) = @_;
    LJ::load_user_props($u, 'pp_transallow');
    LJ::set_userprop($u, 'pp_transallow', -1) if $bit == $u->{pp_transallow};
});

LJ::register_hook("userinfo_join_community", sub {
    my $o = shift;
    my $r = $o->{'ret'};
    my $u = $o->{'u'};
    $$r .= BML::ml('/userinfo.bml.membership.paidmembers') if $u->{'user'} eq "paidmembers";
    return;
});

LJ::register_hook("forbid_request", sub {
    my $r = shift;
    my $ua = $r->header_in("User-Agent");
    my $ip = $r->connection->remote_ip;
    # @BAN_UA can be either scalar substrings of user-agents, or
    # an arrayref of [ $substr, $ip ] which makes the substring
    # match conditional on it matching that IP
    foreach (@LJ::BAN_UA) {
        if (ref) {
            return 1 if $_->[1] eq $ip && index($ua, $_->[0]) != -1;
        } else {
            return 1 if index($ua, $_) != -1;
        }
    }
    return 0;
});

LJ::register_hook("bot_director", sub {
    my ($pre, $post) = @_;
    return "$pre If you are running a bot please visit this policy page outlining rules you must respect. $LJ::SITEROOT/bots/ $post"
});

# control panel nag box
LJ::register_hook('control_panel_extra_info', sub {
    my ($u, $ret) = @_;

    $$ret .= "<div id='ExtraInfo'>";
    if (LJ::get_cap($u, "paid")) {
        $$ret .= "For a complete summary of the LiveJournal.com services to which you are currently subscribed, visit the ";
        $$ret .= "<a href='/paidaccounts/status.bml?authas=$u->{user}'><strong>Paid Account Status</strong></a> page.";
        # render account summary
        $$ret .= LJ::Pay::account_summary($u);
    } else {
        $$ret .= "Nearly all of LiveJournal's functionality is available free of charge. However, if you're happy ";
        $$ret .= "with the service you're being provided, we encourage you to show your support and get a ";
        $$ret .= "<a href='/paidaccounts/'><strong>paid account</strong></a>.";
    }
    $$ret .= "</div>";
});

# control panel extra column
LJ::register_hook('control_panel_column', sub {
    my ($u, $ret) = @_;
    my $authas = ref $u ? "?authas=$u->{user}" : "";

    $$ret .= BML::fill_template('block', { 
        'HEADER' => "Paid Account Information", 
        'ABOUT' => "Additional information and options for paid accounts.",
        'LIST' => "<li><a href='/paidaccounts/status.bml$authas' title='Review expiration dates for all paid services'>Paid Account Status</a></li>".
                  "<li><a href='./files.bml$authas' title='Manage your available disk space'>File Manager</a></li>".
                  "<li><a href='./phonepost.bml' title='<?_ml .information.phonepost.about _ml?>'><?_ml .information.phonepost _ml?></a></li>"
    });
});

LJ::register_hook('entryforminfo', sub {
     my $ret .= "<table style='width: 26em; margin-left: auto; margin-right: auto'><tr valign='top'><td style='text-align: center; border-right: 1px dashed #adadad; width: 50%;'>";

     $ret .= "<strong><a href='/paidaccounts/'>Paid account</a> options:</strong>";
     $ret .= "<ul style='text-align: left'><li><a href='/phonepost/'>Post by Phone</a></li>";
     $ret .= "<li><a href='/manage/'>Post by E-mail</a></li>";
     $ret .= "<li><a href='/poll/create.bml'>Create a Poll</a></li></ul>";

     $ret .= "</td><td style='text-align: center'>";

     $ret .= "<strong>Download a client:</strong><ul style='text-align: left'>";
     $ret .= "<li><a href='/download/index.bml?platform=X+Window+System'>Linux</a> (Unix)</li>";
     $ret .= "<li><a href='/download/index.bml?platform=Macintosh'>Macintosh</a></li>";
     $ret .= "<li><a href='/download/index.bml?platform=Windows'>Windows</a></li>";
     $ret .= "<li><a href='/download/index.bml'>Others</a>&hellip;</li></ul>";

     $ret .= "</td></tr></table>\n";
     return $ret;
});

# args: { userid , ppid }
# appends enclosure or "" to rss $ret string
LJ::register_hook('pp_rss_enclosure', sub {
    my $opts = shift;
    return LJ::PhonePost::make_link( undef, $opts->{userid},
        ( $opts->{ppid} >> 8 ), 'rss' );
});

# args: name
# return: formatted name for local config
LJ::register_hook('identity_display_name', sub {
    my $name = shift;
    $name =~ s/\[(live|dead)journal\.com\]/\[${1}journal\]/;
    $name =~ s/^(.+)\.(live|dead)journal\.com$/${1} \[${2}journal\]/;

    return $name;
});

LJ::register_hook('offsite_journal_search', sub {
    my $u = shift;
    my $ret;

    my $user = LJ::ehtml($u->{'user'});

    $ret .= qq{
        <?h1 LJSeek Search h1?>
            <?p
                <b>Note:</b> This search is provided by an independent company, <a href='http://www.ljseek.com/'>LJSeek</a>, and is provided solely as a convenience.  We are not responsible for the resulting content or search results.
                p?>

                <?standout
                <form action="http://www.ljseek.com/search.php" method="get"><br>
                <input type="hidden" name="users" value="$user" />
                <table cellspacing="0" cellpadding="0" border="0">
                <tr>
                <td valign="center"><p class="search"><b>Search Term:&nbsp;</b></td>
                <td valign="center"><input type="text" name="q" size="25">&nbsp;</td>
                <td valign="center"><select name="sortby">
                <option value="4" selected>sort by time & relevance</option>
                <option value="1">sort by relevance</option>
                <option value="2">sort by time, desc</option>
                <option value="3">sort by time, asc</option>
                </select>&nbsp;</td>
                <td valign="center"><input type="submit" value="Find!"></td>
                </tr>
                <tr>
                <td valign="top" align="right" colspan="2"><table border="0" cellspacing="0" cellpadding="0"><tr>
                <td><input type="checkbox" name="strict"></td>
                <td valign="top" nobr class="text"><b>exact phrase</b></td>
                </tr></table></td>
                <td colspan="2">&nbsp;</td>
                </tr></table></form>
                standout?>
    };
    return $ret;
});

__DATA__
__C__

/*
 * Copyright 2001 Unicode, Inc.
 * 
 * Disclaimer
 * 
 * This source code is provided as is by Unicode, Inc. No claims are
 * made as to fitness for any particular purpose. No warranties of any
 * kind are expressed or implied. The recipient agrees to determine
 * applicability of information provided. If this file has been
 * purchased on magnetic or optical media from Unicode, Inc., the
 * sole remedy for any claim will be exchange of defective media
 * within 90 days of receipt.
 * 
 * Limitations on Rights to Redistribute This Code
 * 
 * Unicode, Inc. hereby grants the right to freely use the information
 * supplied in this file in the creation of products supporting the
 * Unicode Standard, and to make copies of this file in any form
 * for internal or external distribution as long as this notice
 * remains attached.
 */


typedef unsigned char UTF8;	
typedef unsigned char Boolean;

#define false		0
#define true		1

static const char trailingBytesForUTF8[256] = {
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,
    2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,3,3,3,3,3,3,3,3,4,4,4,4,5,5,5,5
};

static Boolean isLegalUTF8(UTF8 *source, int length) {
	UTF8 a;
	UTF8 *srcptr = source+length;
	switch (length) {
	default: return false;
		/* Everything else falls through when "true"... */
	case 4: if ((a = (*--srcptr)) < 0x80 || a > 0xBF) return false;
	case 3: if ((a = (*--srcptr)) < 0x80 || a > 0xBF) return false;
	case 2: if ((a = (*--srcptr)) > 0xBF) return false;
		switch (*source) {
		    /* no fall-through in this inner switch */
		    case 0xE0: if (a < 0xA0) return false; break;
		    case 0xF0: if (a < 0x90) return false; break;
		    case 0xF4: if (a > 0x8F) return false; break;
		    default:  if (a < 0x80) return false;
		}
    	case 1: if (*source >= 0x80 && *source < 0xC2) return false;
		if (*source > 0xF4) return false;
	}
	return true;
}

/********************* End code from Unicode, Inc. ***************/

/*
 * Author: Brad Fitzpatrick
 *
 */

Boolean isLegalUTF8String(char *str, int len)
{
    UTF8 *cp = str;
    int i;
    while (*cp) {
	/* how many bytes follow this character? */
	int length = trailingBytesForUTF8[*cp]+1;

	/* check for early termination of string: */
	for (i=1; i<length; i++) {
	    if (cp[i] == 0) return false;
	}

	/* is this a valid group of characters? */
	if (!isLegalUTF8(cp, length))
	    return false;

	cp += length;
    }

    /* if we didn't make it to the end, there must've been an internal null 
     * in the perl string, which we're saying is bogus utf-8, since there's
     * no point for users giving us null chars.                             */
    return (cp == str+len) ? true : false;
}
