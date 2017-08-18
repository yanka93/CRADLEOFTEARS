#!/usr/bin/perl
#

package LJ::Support;

use strict;
use Digest::MD5 qw(md5_hex);

require "$ENV{'LJHOME'}/cgi-bin/sysban.pl";

## pass $id of zero or blank to get all categories
sub load_cats
{
    my ($id) = @_;
    my $hashref = {};
    $id += 0;
    my $where = $id ? "WHERE spcatid=$id" : "";
    my $dbr = LJ::get_db_reader();
    my $sth = $dbr->prepare("SELECT * FROM supportcat $where");
    $sth->execute;
    $hashref->{$_->{'spcatid'}} = $_ while ($_ = $sth->fetchrow_hashref);
    return $hashref;
}

sub load_email_to_cat_map
{
    my $map = {};
    my $dbr = LJ::get_db_reader();
    my $sth = $dbr->prepare("SELECT * FROM supportcat ORDER BY sortorder DESC");
    $sth->execute;
    while (my $sp = $sth->fetchrow_hashref) {
        next unless ($sp->{'replyaddress'});
        $map->{$sp->{'replyaddress'}} = $sp;
    }
    return $map;
}

sub calc_points
{
    my ($sp, $secs) = @_;
    my $base = $sp->{_cat}->{'basepoints'};    
    $secs = int($secs / (3600*6));
    my $total = ($base + $secs);
    if ($total > 10) { $total = 10; }
    $total ||= 1;
    return $total;
}

sub init_remote
{
    my $remote = shift;
    return unless $remote;
    LJ::load_user_privs($remote, 
                        qw(supportclose supporthelp 
                           supportdelete supportread
                           supportviewinternal supportmakeinternal
                           supportmovetouch supportviewscreened
                           supportchangesummary));
}

# given all the categories, maps a catkey into a cat
sub get_cat_by_key
{
    my ($cats, $cat) = @_;
    foreach (keys %$cats) {
        if ($cats->{$_}->{'catkey'} eq $cat) {
            return $cats->{$_};
        }
    }
    return undef;
}

sub filter_cats
{
    my $remote = shift;
    my $cats = shift;

    return grep {
        can_read_cat($_, $remote);
    } sorted_cats($cats);
}

sub sorted_cats
{
    my $cats = shift;
    return sort { $a->{'catname'} cmp $b->{'catname'} } values %$cats;
}

# takes raw support request record and puts category info in it
# so it can be used in other functions like can_*
sub fill_request_with_cat
{
    my ($sp, $cats) = @_;
    $sp->{_cat} = $cats->{$sp->{'spcatid'}};
}

sub is_poster
{
    my ($sp, $remote, $auth) = @_;

    # special case with non-logged in requesters that use miniauth
    if ($auth && $auth eq mini_auth($sp)) {
        return 1;
    }
    return 0 unless $remote;

    if ($sp->{'reqtype'} eq "email") {
        if ($remote->{'email'} eq $sp->{'reqemail'} && $remote->{'status'} eq "A") {
            return 1;
        }
    } elsif ($sp->{'reqtype'} eq "user") {
        if ($remote->{'userid'} eq $sp->{'requserid'}) { return 1; }
    }
    return 0;
}

sub can_see_helper
{
    my ($sp, $remote) = @_;
    if ($sp->{_cat}->{'hide_helpers'}) { 
        if (can_help($sp, $remote)) {
            return 1;
        }
        if (LJ::check_priv($remote, "supportviewinternal", $sp->{_cat}->{'catkey'})) {
            return 1;
        }
        if (LJ::check_priv($remote, "supportviewscreened", $sp->{_cat}->{'catkey'})) {
            return 1;
        }
        return 0;
    }
    return 1;
}

sub can_read
{
    my ($sp, $remote, $auth) = @_;
    return (is_poster($sp, $remote, $auth) ||
            can_read_cat($sp->{_cat}, $remote));
}

sub can_read_cat
{
    my ($cat, $remote) = @_;
    return unless ($cat);
    return ($cat->{'public_read'} || 
            LJ::check_priv($remote, "supportread", $cat->{'catkey'}));
}

sub can_bounce
{
    my ($sp, $remote) = @_;
    if ($sp->{_cat}->{'public_read'}) {
        if (LJ::check_priv($remote, "supportclose", "")) { return 1; }
    }
    my $catkey = $sp->{_cat}->{'catkey'};
    if (LJ::check_priv($remote, "supportclose", $catkey)) { return 1; }
    return 0;
}

sub can_lock
{
    my ($sp, $remote) = @_;
    return 1 if $sp->{_cat}->{public_read} && LJ::check_priv($remote, 'supportclose', '');
    return 1 if LJ::check_priv($remote, 'supportclose', $sp->{_cat}->{catkey});
    return 0;
}

sub can_close
{
    my ($sp, $remote, $auth) = @_;
    if (is_poster($sp, $remote, $auth)) { return 1; }
    if ($sp->{_cat}->{'public_read'}) {
        if (LJ::check_priv($remote, "supportclose", "")) { return 1; }
    }
    my $catkey = $sp->{_cat}->{'catkey'};
    if (LJ::check_priv($remote, "supportclose", $catkey)) { return 1; }
    return 0;
}

sub can_append
{
    my ($sp, $remote, $auth) = @_;
    if (is_poster($sp, $remote, $auth)) { return 1; }
    return 0 unless $remote;
    return 0 unless $remote->{'statusvis'} eq "V";
    if ($sp->{_cat}->{'allow_screened'}) { return 1; }
    if (can_help($sp, $remote)) { return 1; }
    return 0;
}

sub is_locked
{
    my $sp = shift;
    my $spid = ref $sp ? $sp->{spid} : $sp+0;
    return undef unless $spid;
    my $props = LJ::Support::load_props($spid);
    return $props->{locked} ? 1 : 0;
}

sub lock
{
    my $sp = shift;
    my $spid = ref $sp ? $sp->{spid} : $sp+0;
    return undef unless $spid;
    my $dbh = LJ::get_db_writer();
    $dbh->do("REPLACE INTO supportprop (spid, prop, value) VALUES (?, 'locked', 1)", undef, $spid);
}

sub unlock
{
    my $sp = shift;
    my $spid = ref $sp ? $sp->{spid} : $sp+0;
    return undef unless $spid;
    my $dbh = LJ::get_db_writer();
    $dbh->do("DELETE FROM supportprop WHERE spid = ? AND prop = 'locked'", undef, $spid);
}

# privilege policy:
#   supporthelp with no argument gives you all abilities in all public_read categories
#   supporthelp with a catkey arg gives you all abilities in that non-public_read category
#   supportread with a catkey arg is required to view requests in a non-public_read category
#   all other privs work like:
#      no argument = global, where category is public_read or user has supportread on that category
#      argument = local, priv applies in that category only if it's public or user has supportread
sub support_check_priv
{
    my ($sp, $remote, $priv) = @_;
    return 1 if can_help($sp, $remote);
    return 0 unless can_read_cat($sp->{_cat}, $remote);
    return 1 if LJ::check_priv($remote, $priv, '') && $sp->{_cat}->{public_read};
    return 1 if LJ::check_priv($remote, $priv, $sp->{_cat}->{catkey});
    return 0;
}

# can they read internal comments?  if they're a helper or have
# extended supportread (with a plus sign at the end of the category key)
sub can_read_internal
{
    my ($sp, $remote) = @_;
    return 1 if LJ::Support::support_check_priv($sp, $remote, 'supportviewinternal'); 
    return 1 if LJ::check_priv($remote, "supportread", $sp->{_cat}->{catkey}."+");
    return 0;
}

sub can_make_internal
{
    return LJ::Support::support_check_priv(@_, 'supportmakeinternal');
}

sub can_read_screened
{
    return LJ::Support::support_check_priv(@_, 'supportviewscreened');
}

sub can_perform_actions
{
    return LJ::Support::support_check_priv(@_, 'supportmovetouch');
}

sub can_change_summary
{
    return LJ::Support::support_check_priv(@_, 'supportchangesummary');
}

sub can_help
{
    my ($sp, $remote) = @_;
    if ($sp->{_cat}->{'public_read'}) {
        if ($sp->{_cat}->{'public_help'}) {
            return 1;
        }
        if (LJ::check_priv($remote, "supporthelp", "")) { return 1; }
    }
    my $catkey = $sp->{_cat}->{'catkey'};
    if (LJ::check_priv($remote, "supporthelp", $catkey)) { return 1; }
    return 0;
}

sub load_props
{
    my $spid = shift;
    return unless $spid;

    my %props = (); # prop => value

    my $dbr = LJ::get_db_reader();
    my $sth = $dbr->prepare("SELECT prop, value FROM supportprop WHERE spid=?");
    $sth->execute($spid);
    while (my ($prop, $value) = $sth->fetchrow_array) {
        $props{$prop} = $value;
    }

    return \%props;
}

# $loadreq is used by /abuse/report.bml and
# ljcmdbuffer.pl to signify that the full request
# should not be loaded.  To simplify code going live,
# Whitaker and I decided to not try and merge it
# into the new $opts hash.

# $opts->{'db_force'} loads the request from a
# global master.  Needed to prevent a race condition
# where the request may not have replicated to slaves
# in the time needed to load an auth code.

sub load_request
{
    my ($spid, $loadreq, $opts) = @_;
    my $sth;

    $spid += 0;

    # load the support request
    my $db = $opts->{'db_force'} ? LJ::get_db_writer() : LJ::get_db_reader();

    $sth = $db->prepare("SELECT * FROM support WHERE spid=$spid");
    $sth->execute;
    my $sp = $sth->fetchrow_hashref;

    return undef unless $sp;

    # load the category the support requst is in
    $sth = $db->prepare("SELECT * FROM supportcat WHERE spcatid=$sp->{'spcatid'}");
    $sth->execute;
    $sp->{_cat} = $sth->fetchrow_hashref;

    # now load the user's request text, if necessary
    if ($loadreq) {
        $sp->{body} = $db->selectrow_array("SELECT message FROM supportlog WHERE spid = ? AND type = 'req'",
					   undef, $sp->{spid});
    }

    return $sp;
}

sub load_response
{
    my $splid = shift;
    my $sth;

    $splid += 0;

    # load the support request
    my $dbh = LJ::get_db_writer();
    $sth = $dbh->prepare("SELECT * FROM supportlog WHERE splid=$splid");
    $sth->execute;
    my $res = $sth->fetchrow_hashref;

    return $res;
}

sub get_answer_types
{
    my ($sp, $remote, $auth) = @_;
    my @ans_type;

    if (is_poster($sp, $remote, $auth)) {
        push @ans_type, ("comment", "More information");
        return @ans_type;
    }

    if (can_help($sp, $remote)) {
        push @ans_type, ("screened" => "Screened Response", 
                         "answer" => "Answer",                         
                         "comment" => "Comment or Question");
    } elsif ($sp->{_cat}->{'allow_screened'}) {
        push @ans_type, ("screened" => "Screened Response");
    }

    if (can_make_internal($sp, $remote) &&
        ! $sp->{_cat}->{'public_help'})
    {
        push @ans_type, ("internal" => "Internal Comment / Action");
    }

    if (can_bounce($sp, $remote)) {
        push @ans_type, ("bounce" => "Bounce to Email & Close");
    }

    return @ans_type;
}

sub file_request
{
    my $errors = shift;
    my $o = shift;

    my $email = $o->{'reqtype'} eq "email" ? $o->{'reqemail'} : "";
    my $log = { 'uniq' => $o->{'uniq'},
                'email' => $email };
    my $userid = 0;

    unless ($email) {
        if ($o->{'reqtype'} eq "user") {
            my $u = LJ::load_userid($o->{'requserid'});
            $userid = $u->{'userid'};

            $log->{'user'} = $u->{'user'};
            $log->{'email'} = $u->{'email'};

            if (LJ::sysban_check('support_user', $u->{'user'})) {
                return LJ::sysban_block($userid, "Support request blocked based on user", $log);
            }

            $email = $u->{'email'};
        }
    }

    if (LJ::sysban_check('support_email', $email)) {
        return LJ::sysban_block($userid, "Support request blocked based on email", $log);
    }
    if (LJ::sysban_check('support_uniq', $o->{'uniq'})) {
        return LJ::sysban_block($userid, "Support request blocked based on uniq", $log);
    }

    my $reqsubject = LJ::trim($o->{'subject'});
    my $reqbody = LJ::trim($o->{'body'});

    unless ($reqsubject) {
        push @$errors, "You must enter a problem summary.";
    }
    unless ($reqbody) {
        push @$errors, "You did not enter a support request.";
    }

    my $cats = LJ::Support::load_cats();
    push @$errors, "Invalid support category" unless $cats->{$o->{'spcatid'}+0};

    if (@$errors) { return 0; }

    my $dbh = LJ::get_db_writer();
    
    my $dup_id = 0;
    my $qsubject = $dbh->quote($reqsubject);
    my $qbody = $dbh->quote($reqbody);
    my $qreqtype = $dbh->quote($o->{'reqtype'});
    my $qrequserid = $o->{'requserid'}+0;
    my $qreqname = $dbh->quote($o->{'reqname'});
    my $qreqemail = $dbh->quote($o->{'reqemail'});
    my $qspcatid = $o->{'spcatid'}+0;

    my $scat = $cats->{$qspcatid}; 

    # make the authcode
    my $authcode = LJ::make_auth_code(15);
    my $qauthcode = $dbh->quote($authcode);

    my $md5 = md5_hex("$qreqname$qreqemail$qsubject$qbody");
    my $sth;
 
    $dbh->do("LOCK TABLES support WRITE, duplock WRITE");
    $sth = $dbh->prepare("SELECT dupid FROM duplock WHERE realm='support' AND reid=0 AND userid=$qrequserid AND digest='$md5'");
    $sth->execute;
    ($dup_id) = $sth->fetchrow_array;
    if ($dup_id) {
        $dbh->do("UNLOCK TABLES");
        return $dup_id;
    }

    my ($urlauth, $url, $spid);  # used at the bottom

    my $sql = "INSERT INTO support (spid, reqtype, requserid, reqname, reqemail, state, authcode, spcatid, subject, timecreate, timetouched, timeclosed, timelasthelp) VALUES (NULL, $qreqtype, $qrequserid, $qreqname, $qreqemail, 'open', $qauthcode, $qspcatid, $qsubject, UNIX_TIMESTAMP(), UNIX_TIMESTAMP(), 0, 0)";
    $sth = $dbh->prepare($sql);
    $sth->execute;
    
    if ($dbh->err) { 
        my $error = $dbh->errstr;
        $dbh->do("UNLOCK TABLES");
        push @$errors, "<b>Database error:</b> (report this)<br>$error";
        return 0;
    }
    $spid = $dbh->{'mysql_insertid'};

    $dbh->do("INSERT INTO duplock (realm, reid, userid, digest, dupid, instime) VALUES ('support', 0, $qrequserid, '$md5', $spid, NOW())");
    $dbh->do("UNLOCK TABLES");
    
    unless ($spid) { 
        push @$errors, "<b>Database error:</b> (report this)<br>Didn't get a spid."; 
        return 0;
    }

    # save meta-data for this request
    my @data;
    my $add_data = sub {
        my $q = $dbh->quote($_[1]);
        return unless $q && $q ne 'NULL';
        push @data, "($spid, '$_[0]', $q)";
    };
    $add_data->($_, $o->{$_}) foreach qw(uniq useragent);
    $dbh->do("INSERT INTO supportprop (spid, prop, value) VALUES " . join(',', @data));

    $dbh->do("INSERT INTO supportlog (splid, spid, timelogged, type, faqid, userid, message) ".
             "VALUES (NULL, $spid, UNIX_TIMESTAMP(), 'req', 0, $qrequserid, $qbody)");

    my $body;
    my $miniauth = mini_auth({ 'authcode' => $authcode });
    $url = "$LJ::SITEROOT/support/see_request.bml?id=$spid";
    $urlauth = "$url&auth=$miniauth";

    $body = "Your $LJ::SITENAME support request regarding \"$o->{'subject'}\" has been filed and will be answered as soon as possible.  Your request tracking number is $spid.\n\n";
    $body .= "You can track your request's progress or add information here:\n\n  ";
    $body .= $urlauth;
    $body .= "\n\nIf you figure out the problem before somebody gets back to you, please cancel your request by clicking this:\n\n  ";
    $body .= "$LJ::SITEROOT/support/act.bml?close;$spid;$authcode";
   
    unless ($scat->{'no_autoreply'})
    {
      LJ::send_mail({ 
          'to' => $email,
          'from' => $LJ::BOGUS_EMAIL,
          'fromname' => "$LJ::SITENAME Support",
          'charset' => 'utf-8',
          'subject' => "Support Request \#$spid",
          'body' => $body  
          });
    }

    # attempt to buffer job to send email (but don't care if it fails)
    LJ::do_to_cluster(sub {
        # first parameter is cluster id
        return LJ::cmd_buffer_add(shift(@_), 0, 'support_notify', { spid => $spid, type => 'new' });
    });
    
    # and we're done
    return $spid;
}

sub append_request
{
    my $sp = shift;  # support request to be appended to.
    my $re = shift;  # hashref of attributes of response to be appended
    my $sth;

    # $re->{'body'}
    # $re->{'type'}    (req, answer, comment, internal, screened)
    # $re->{'faqid'}
    # $re->{'remote'}  (remote if known)
    # $re->{'uniq'}    (uniq of remote)

    my $remote = $re->{'remote'};
    my $posterid = $remote ? $remote->{'userid'} : 0;

    # check for a sysban
    my $log = { 'uniq' => $re->{'uniq'} };
    if ($remote) {

        $log->{'user'} = $remote->{'user'};
        $log->{'email'} = $remote->{'email'};

        if (LJ::sysban_check('support_user', $remote->{'user'})) {
            return LJ::sysban_block($remote->{'userid'}, "Support request blocked based on user", $log);
        }
        if (LJ::sysban_check('support_email', $remote->{'email'})) {
            return LJ::sysban_block($remote->{'userid'}, "Support request blocked based on email", $log);
        }
    }

    if (LJ::sysban_check('support_uniq', $re->{'uniq'})) {
        my $userid = $remote ? $remote->{'userid'} : 0;
        return LJ::sysban_block($userid, "Support request blocked based on uniq", $log);
    }

    my $message = $re->{'body'};
    $message =~ s/^\s+//;
    $message =~ s/\s+$//;

    my $dbh = LJ::get_db_writer();

    my $qmessage = $dbh->quote($message);
    my $qtype = $dbh->quote($re->{'type'});

    my $qfaqid = $re->{'faqid'}+0;
    my $quserid = $posterid+0;
    my $spid = $sp->{'spid'}+0;

    my $sql = "INSERT INTO supportlog (splid, spid, timelogged, type, faqid, userid, message) VALUES (NULL, $spid, UNIX_TIMESTAMP(), $qtype, $qfaqid, $quserid, $qmessage)";
    $dbh->do($sql);
    my $splid = $dbh->{'mysql_insertid'};

    if ($posterid) {
        # add to our index of recently replied to support requests per-user.
        $dbh->do("INSERT IGNORE INTO support_youreplied (userid, spid) VALUES (?, ?)", undef,
                 $posterid, $spid);
        die $dbh->errstr if $dbh->err;

        # and also lazily clean out old stuff:
        $sth = $dbh->prepare("SELECT s.spid FROM support s, support_youreplied yr ".
                             "WHERE yr.userid=? AND yr.spid=s.spid AND s.state='closed' ".
                             "AND s.timeclosed < UNIX_TIMESTAMP() - 3600*72");
        $sth->execute($posterid);
        my @to_del;
        push @to_del, $_ while ($_) = $sth->fetchrow_array;
        if (@to_del) {
            my $in = join(", ", map { $_ + 0 } @to_del);
            $dbh->do("DELETE FROM support_youreplied WHERE userid=? AND spid IN ($in)",
                     undef, $posterid);
        }
    }

    # attempt to buffer job to send email (but don't care if it fails)
    LJ::do_to_cluster(sub {
        # first parameter is cluster id
        return LJ::cmd_buffer_add(shift(@_), 0, 'support_notify', { spid => $spid, splid => $splid, type => 'update' });
    });

    return $splid;    
}

# userid may be undef/0 in the setting to zero case
sub set_points
{
    my ($spid, $userid, $points) = @_;
    
    my $dbh = LJ::get_db_writer();
    if ($points) {
        $dbh->do("REPLACE INTO supportpoints (spid, userid, points) ".
                 "VALUES (?,?,?)", undef, $spid, $userid, $points);
    } else {
        $userid ||= $dbh->selectrow_array("SELECT userid FROM supportpoints WHERE spid=?",
                                          undef, $spid);
        $dbh->do("DELETE FROM supportpoints WHERE spid=?", undef, $spid);
    }
    
    $dbh->do("REPLACE INTO supportpointsum (userid, totpoints, lastupdate) ".
             "SELECT userid, SUM(points), UNIX_TIMESTAMP() FROM supportpoints ".
             "WHERE userid=? GROUP BY 1", undef, $userid) if $userid;
}

sub touch_request
{
    my ($spid) = @_;

    # no touching if the request is locked
    return 0 if LJ::Support::is_locked($spid);

    my $dbh = LJ::get_db_writer();

    $dbh->do("UPDATE support".
             "   SET state='open', timeclosed=0, timetouched=UNIX_TIMESTAMP()".
             " WHERE spid=?",
	     undef, $spid)
      or return 0;

    set_points($spid, undef, 0);

    return 1;
}

sub mail_response_to_user
{
    my $sp = shift;
    my $splid = shift;

    $splid += 0;

    my $res = load_response($splid);
    
    my $email;
    if ($sp->{'reqtype'} eq "email") {
        $email = $sp->{'reqemail'};
    } else {
        my $u = LJ::load_userid($sp->{'requserid'});
        $email = $u->{'email'};
    }

    my $spid = $sp->{'spid'}+0;
    my $faqid = $res->{'faqid'}+0;

    my $type = $res->{'type'};

    # don't mail internal comments (user shouldn't see) or 
    # screened responses (have to wait for somebody to approve it first)
    return if ($type eq "internal" || $type eq "screened");

    # the only way it can be zero is if it's a reply to an email, so it's
    # problem the person replying to their own request, so we don't want
    # to mail them:
    return unless ($res->{'userid'});
    
    # also, don't send them their own replies:
    return if ($sp->{'requserid'} == $res->{'userid'});

    my $body = "";
    my $dbh = LJ::get_db_writer();
    my $what = $type eq "answer" ? "an answer to" : "a comment on";
    $body .= "Below is $what your support question regarding \"$sp->{'subject'}\"\n";

    my $miniauth = mini_auth($sp);
    $body .= "($LJ::SITEROOT/support/see_request.bml?id=$spid&auth=$miniauth).\n\n";

    $body .= "="x70 . "\n\n";
    if ($faqid) {
        my $faqname = "";
        my $sth = $dbh->prepare("SELECT question FROM faq WHERE faqid=$faqid");
        $sth->execute;
        ($faqname) = $sth->fetchrow_array;
        if ($faqname) {
            $body .= "FAQ REFERENCE: $faqname\n";
            $body .= "$LJ::SITEROOT/support/faqbrowse.bml?faqid=$faqid";
            $body .= "\n\n";
        }
    }

    $body .= "$res->{'message'}\n\nDid this answer your question?\nYES:\n";

    $body .= "$LJ::SITEROOT/support/act.bml?close;$spid;$sp->{'authcode'}";
    $body .= ";$splid" if $type eq "answer";
    $body .= "\nNO:\n$LJ::SITEROOT/support/see_request.bml?id=$spid&auth=$miniauth\n\n";
    $body .= "If you are having problems using any of the links in this email, please try copying and pasting the *entire* link into your browser's address bar rather than clicking on it.";

    my $fromemail = $LJ::BOGUS_EMAIL;
    if ($sp->{_cat}->{'replyaddress'}) {
        my $miniauth = mini_auth($sp);
        $fromemail = $sp->{_cat}->{'replyaddress'};
        # insert mini-auth stuff:
        my $rep = "+${spid}z$miniauth\@";
        $fromemail =~ s/\@/$rep/;
    }

    LJ::send_mail({ 
        'to' => $email,
        'from' => $fromemail,
        'fromname' => "$LJ::SITENAME Support",
        'charset' => 'utf-8',
        'subject' => "Re: $sp->{'subject'}",
        'body' => $body  
        });

    if ($type eq "answer") {
        $dbh->do("UPDATE support SET timelasthelp=UNIX_TIMESTAMP() WHERE spid=$spid");
    }
}

sub mini_auth
{
    my $sp = shift;
    return substr($sp->{'authcode'}, 0, 4);
}

1;
