#!/usr/bin/perl
#

use strict;
use vars qw(%maint);

$maint{'pay_mail'} = sub
{
    require "$ENV{'LJHOME'}/cgi-bin/paylib.pl";

    my $dbh = LJ::get_db_writer();

    my $sth;
    my $now = time();

    # we don't mail receipts (yet?) to non-users paying, or carts w/ no price (eg coppa verifications)
    $dbh->do("UPDATE payments SET mailed='X' WHERE mailed='N' AND forwhat='cart' AND (userid=0 OR amount=0)");

    $sth = $dbh->prepare("SELECT u.user, u.email, u.name, p.* FROM payments p, user u ".
                         "WHERE p.userid=u.userid AND p.mailed='N' ".
                         "AND (IFNULL(p.giveafter,0) = 0 OR $now >= p.giveafter)");
    $sth->execute;
    die $dbh->errstr if $dbh->err;
    while (my $p = $sth->fetchrow_hashref)
    {

        my $note_msg = sub {
            return "" unless $p->{'notes'};

            # this will get run through Text::Wrap when it's emailed
            my $notes = $p->{'notes'};
            $notes =~ s/\n/\n   /g;

            return "Here are some notes associated with this payment:\n\n" .
                   "   $notes\n\n";
        };

        if ($p->{'forwhat'} eq "cart") {
            my $cart = "$p->{'payid'}-$p->{'anum'}";
            LJ::send_mail({
                'to' => $p->{'email'},
                'from' => $LJ::ACCOUNTS_EMAIL,
                'fromname' => $LJ::SITENAMESHORT,
                'wrap' => 1,
                'charset' => 'utf-8',
                'subject' => "Payment received (Order $cart)",
                'body' => ("Your payment of \$$p->{'amount'} for order $cart was received and the order is now being processed.\n\n".
                           "For your reference, you can view the order here:\n\n".
                           "   $LJ::SITEROOT/pay/?c=$cart\n\n".
                           $note_msg->() .
                           "We thank you for supporting the site,\n\n".
                           "$LJ::SITENAMESHORT Team"
                           )});
            $dbh->do("UPDATE payments SET mailed='Y' WHERE payid=$p->{'payid'}");
            next;
        }

        if ($p->{'forwhat'} eq "rename") {
            my $token = LJ::Pay::new_rename_token($dbh, $p->{'payid'})
              or next;

            LJ::send_mail({
                'to' => $p->{'email'},
                'from' => $LJ::ACCOUNTS_EMAIL,
                'fromname' => $LJ::SITENAMESHORT,
                'wrap' => 1,
                'charset' => 'utf-8',
                'subject' => "Rename Token",
                'body' => ("Here is the username rename token you purchased:\n\n".
                           "   $token\n\n".
                           "You can use it here:\n\n".
                           "   $LJ::SITEROOT/rename/use.bml?token=$token\n\n".
                           "For more information regarding account renames, read:\n\n".
                           "   $LJ::SITEROOT/rename/\n\n".
                           $note_msg->() .
                           "$LJ::SITENAMESHORT Team"
                           ),
                       });

            $dbh->do("UPDATE payments SET mailed='Y', used='Y' WHERE payid=$p->{'payid'}");
            next;
        }

        my $howmany = $p->{'months'} == 99 ? "UNLIMITED" : $p->{'months'};
        print "$p->{'payid'}: Mailing $p->{'email'} ($howmany) ...\n";
        $p->{'notes'} =~ s/\r//g;

        my $msg;
        $msg .= "$p->{'name'} ...\n\n";
        $msg .= "Your $LJ::SITENAMESHORT payment of \$$p->{'amount'} was received $p->{'daterecv'}";
        if ($p->{'forwhat'} eq "account") {
            $msg .= " and your account has been credited with $howmany more months";
        }
        $msg .= ".\n\n";

        $msg .= $note_msg->();

        $msg .= "We thank you for supporting the site,\n\n$LJ::SITENAMESHORT Team";
        
        LJ::send_mail({
            'to' => $p->{'email'},
            'from' => $LJ::ACCOUNTS_EMAIL,
            'fromname' => $LJ::SITENAMESHORT,
            'wrap' => 1,
            'charset' => 'utf-8',
            'subject' => "$LJ::SITENAMESHORT Payment Received -- \#$p->{'payid'}",
            'body' => $msg,
        });

        $dbh->do("UPDATE payments SET mailed='Y' WHERE payid=$p->{'payid'}");
    }

};

$maint{'pay_updateaccounts'} = sub
{
    require "$ENV{'LJHOME'}/cgi-bin/paylib.pl";

    my $dbh = LJ::get_db_writer()
        or die "Could not contact global database master";

    # for some reason, use of purchased codes doesn't always apply payment
    # to account when it's created.  some code path involved when paypal
    # servers are being lame isn't as robust, or something.  in any case,
    # this query fixes it:
    my $sth = $dbh->prepare
        ("SELECT ac.rcptid, p.payid ".
         "FROM acctcode ac, acctpay ap, payments p ".
         "WHERE p.userid=0 AND p.used='N' AND p.payid=ap.payid AND ".
         "      ap.acid=ac.acid AND ac.rcptid <> 0");
    $sth->execute;
    while (my ($userid, $payid) = $sth->fetchrow_array) {
        $dbh->do("UPDATE payments SET userid=$userid WHERE payid=$payid AND userid=0");
        print "Fix payid=$payid to userid=$userid.\n";
    }

    # and now, back to what this maint task is supposed to do:
    my $now = time();
    $sth = $dbh->prepare("SELECT payid, userid, months, forwhat, amount, method, datesent ".
                         "FROM payments WHERE used='N' ".
                         "AND (IFNULL(giveafter,0) = 0 OR $now >= giveafter)");
    $sth->execute;
    die $dbh->errstr if $dbh->err;
    my @used = ();
    while (my $p = $sth->fetchrow_hashref)
    {
        my $userid = $p->{'userid'};

        # check userids of all the affected clusterids before deciding whether to process this payment
        my %userids = $userid ? ($userid => 1) : ();
        if ($p->{'forwhat'} eq 'cart') {
            my $s = $dbh->prepare("SELECT rcptid FROM payitems WHERE payid=? AND rcptid>0");
            $s->execute($p->{'payid'});
            die $dbh->errstr if $dbh->err;
            while (my $uid = $s->fetchrow_array) {
                $userids{$uid} = 1;
            }
        }

        if (%userids) {
            # call into LJ::load_userids_multi() to get clusterids for these users
            # -- cheap because we load all payment userids later during processing

            my $users = LJ::load_userids(keys %userids);

            # verify we can get all of the handles necessary to complete this request
            my $dirty = 0;
            foreach (values %$users) {
                $dirty = $_->{clusterid}, last unless $_->writer;
            }

            if ($dirty) {
                print "Cluster $dirty unreachable, skipping payment: $p->{payid}\n";
                next;
            }
        }

        print "Payment: $p->{'payid'} ($p->{'forwhat'})\n";

        # mail notification of large orders... but only if it was automatically processed
        if ($LJ::ACCOUNTS_EMAIL && $LJ::LARGE_ORDER_NOTIFY &&
            ($p->{'method'} eq "cc" || $p->{'method'} eq "paypal") &&
            $p->{'amount'} > $LJ::LARGE_ORDER_NOTIFY) {

            my $dollars = sub { sprintf("\$%.02f", shift()) };
            print "Sending large order notification: " . $dollars->($p->{'amount'}) . "\n";

            LJ::send_mail({
                'to' => $LJ::ACCOUNTS_EMAIL,
                'from' => $LJ::ACCOUNTS_EMAIL,
                'wrap' => 1,
                'charset' => 'utf-8',
                'subject' => "Large order processed: " . $dollars->($p->{'amount'}) .
                             " [payid: $p->{'payid'}]",
                'body' => "This warning has been sent because the following order of over " .
                          $dollars->($LJ::LARGE_ORDER_NOTIFY) .
                          " has been processed on $LJ::SITENAMESHORT.\n\n" .

                          "        Amount: " . $dollars->($p->{'amount'}) . "\n" .
                          "         Payid: $p->{'payid'}\n" .
                          "        Method: $p->{'method'}\n" .
                          "     Date Sent: $p->{'datesent'}\n\n"
                          });
        }

        # park this payment as used
        push @used, $p->{'payid'};

        # if a cart, mark each item in the cart as ready to be processed, 
        # then we'll do that below.
        if ($p->{'forwhat'} eq "cart") {
            $dbh->do("UPDATE payitems SET status='pend' WHERE ".
                     "payid=? AND status='cart'", undef, $p->{'payid'});

            next;
        }

        ### legacy support from here on.

        # needs to be for a user
        next unless $userid;

        # if permanent account, ignore this legacy (non-cart) payment
        my $u = LJ::load_userid($userid);
        next if $u->{'caps'} & (1 << $LJ::Pay::capinf{'perm'}->{'bit'});

        # if there is an error adding paid months, remove from used list
        # so we'll try again later
        unless (LJ::Pay::add_paid_months($userid, $p->{'months'})) {
            pop @used;
        }
    }

    # @used is only populated in legacy (non-cart) case
    if (@used) {
        my $usedin = join(", ", @used);
        $dbh->do("UPDATE payments SET used='Y' WHERE payid IN ($usedin)");
    }

    my %pay;
    my $get_payment = sub {
        my $id = shift;
        return $pay{$id} if $pay{$id};
        return $pay{$id} =
            $dbh->selectrow_hashref("SELECT * FROM payments WHERE payid=?",
                                    undef, $id);
    };

    # get pending cart items
    my %payitems = ( 'paidacct' => [], 'other' => [] );
    $sth = $dbh->prepare("SELECT * FROM payitems WHERE status='pend'");
    $sth->execute;
    while (my $pi = $sth->fetchrow_hashref) {
        my $key = $pi->{'item'} eq 'perm' ? 'perm' : 
            $pi->{'item'} eq 'paidacct' ? 'paidacct' : 'other';
        push @{$payitems{$key}}, $pi;
    }
    my %bonus_failure = ();

    # paid accounts are special because they have to apply before bonus features
    foreach my $pi (@{$payitems{'perm'}}, @{$payitems{'paidacct'}}, @{$payitems{'other'}}) {
        next if $pi->{'giveafter'} > $now; # delayed payment

        my $pp = $get_payment->($pi->{'payid'});
        my $bu = LJ::load_userid($pp->{'userid'}); # buying user, no force needed

        my $email = $pi->{'rcptemail'};
        my $ru;  # rcpt user
        if ($pi->{'rcptid'}) {
            $ru = LJ::load_userid($pi->{'rcptid'}, "force");
            $email = $ru->{'email'};
        }
        
        # optional gift header
        my $msg;
        if ($bu && $bu->{'userid'} != $pi->{'rcptid'}) {
            if ($pi->{'anon'}) {
                $msg .= "(the following is an anonymous gift)\n\n"
            } else {
                $msg .= "(the following is a gift from $LJ::SITENAMESHORT user \"$bu->{'user'}\")\n\n";
            }
        }

        my ($token, $tokenid);
        my $close = sub {
            $dbh->do("UPDATE payitems SET status='done', token=?, tokenid=? ".
                     "WHERE piid=? AND status='pend'", undef, $token,
                     $tokenid, $pi->{'piid'});
        };

        # paid/perm accounts
        if ($pi->{'item'} eq "paidacct" || $pi->{'item'} eq "perm") {
            my $isacct = $pi->{'item'} eq "paidacct";

            my $has_perm = $ru && $ru->{'caps'} & (1 << $LJ::Pay::capinf{'perm'}->{'bit'});

            # send 'em a token
            if ($pi->{'rcptid'} == 0 || $has_perm) { # rcpt is an email address, or perm acct
                $token = LJ::acct_code_generate($bu ? $bu->{userid} : 0);
                my ($acid, $auth) = LJ::acct_code_decode($token);
                $dbh->do("INSERT INTO acctpayitem (piid, acid) VALUES (?,?)",
                         undef, $pi->{'piid'}, $acid);
                
                $tokenid = $acid;
                
                my $what;
                if ($isacct) {
                    $what = "$pi->{'qty'} month(s) of paid account time";
                } else {
                    $what = "a permanent account";
                }

                $msg .= "The following code will give $what to any $LJ::SITENAMESHORT account:\n\n";
                $msg .= "   $token\n\n";
                $msg .= "To apply it to an existing account, visit:\n\n";
                $msg .= "   $LJ::SITEROOT/paidaccounts/apply.bml?code=$token\n\n";
                $msg .= "To create a new account using it, visit:\n\n";
                $msg .= "   $LJ::SITEROOT/create.bml?code=$token\n\n";

                LJ::send_mail({
                    'to' => $email,
                    'from' => $LJ::ACCOUNTS_EMAIL,
                    'fromname' => $LJ::SITENAMESHORT,
                    'wrap' => 1,
                    'charset' => 'utf-8',
                    'subject' => $isacct ? "Paid account" : "Permanent account",
                    'body' => $msg,
                });
                $close->();
                # don't need to release lock, no rcptid
                next;
            }

            # just set it up now, and tell them it's done.
            # no need to release lock since no $ru anyway
            next unless $ru;

            my $mo;
            $mo = $pi->{'qty'} if $isacct;
            $mo = 99 if $pi->{'item'} eq "perm";
            my $bonus_ref = [];

            # modifying paid account status, need to get a lock on the account,
            # try again later if we fail to get a lock
            next unless LJ::Pay::get_lock($ru);

            my $res = LJ::Pay::add_paid_months($ru->{'userid'}, $mo, $bonus_ref);

            # finished modifying account, can unconditionally release lock and finish payitem now
            LJ::Pay::release_lock($ru);

            # some sort of error occurred, log to payvars and try again later
            unless ($res) {
                LJ::Pay::payvar_append($pi->{'payid'}, "error",
                                       "[" . LJ::mysql_time() . "] unable to apply: item=$pi->{'item'}, qty=$pi->{'qty'}.");
                next;
            }

            # account changes were successful: close transaction, only need to send email now
            $close->();

            # finish composing email to send to user
            my $bonus_added;
            if (@$bonus_ref) {
                $bonus_added = "Additionally, the following previously deactivated bonus features\n" .
                               "have been reactivated so you can use the time remaining on them:\n\n" .
                               join("\n", map { "   - " . LJ::Pay::product_name($_->{'item'}, $_->{'size'}, undef, "short") .
                                                ": $_->{'daysleft'} days applied" }
                                    sort { $a->{'item'} cmp $b->{'item'} } @$bonus_ref) .
                               "\n\n";
            }

            if ($isacct) {
                $msg .= "$mo months of paid account time have been added to your $LJ::SITENAMESHORT account for user \"$ru->{'user'}\".\n\n$bonus_added$LJ::SITENAMESHORT Team";
            } else {
                $msg .= "Your $LJ::SITENAMESHORT account \"$ru->{'user'}\" has been upgraded to a permanent account.\n\n$bonus_added$LJ::SITENAMESHORT Team";
            }

            # send notification email
            LJ::send_mail({
                'to' => $email,
                'from' => $LJ::ACCOUNTS_EMAIL,
                'fromname' => $LJ::SITENAMESHORT,
                'wrap' => 1,
                'charset' => 'utf-8',
                'subject' => $isacct ? "Paid Account" : "Permanent Account",
                'body' => $msg,
            });

            next;
        }
        
        # rename tokens
        elsif ($pi->{'item'} eq "rename") {
            next unless ($token, $tokenid) = LJ::Pay::new_rename_token($dbh, $pp->{'payid'});

            # send email notification
            LJ::send_mail({
                'to' => $email,
                'from' => $LJ::ACCOUNTS_EMAIL,
                'fromname' => $LJ::SITENAMESHORT,
                'wrap' => 1,
                'charset' => 'utf-8',
                'subject' => "Rename Token",
                'body' => "${msg}$LJ::SITENAMESHORT username rename token:\n\n".
                    "   $token\n\n".
                    "You can use it here:\n\n".
                    "   $LJ::SITEROOT/rename/use.bml?token=$token\n\n".
                    "For more information regarding account renames, read:\n\n".
                    "   $LJ::SITEROOT/rename/\n\n".
                    "$LJ::SITENAMESHORT Team",
                });

            $close->();
            next;
        }

        # clothing items
        elsif ($pi->{'item'} eq "clothes") {
            $dbh->do("INSERT IGNORE INTO shipping (payid, status, dateready) VALUES (?, 'needs', NOW())",
                     undef, $pp->{'payid'}) and $close->();
            next;
        }

        # coupons
        elsif ($pi->{'item'} eq "coupon") {

            # subitem used to be type-dollaramount, but that was redundant
            my ($type) = split('-', $pi->{'subitem'});

            # If amt < 0, this item is a previously purchased coupon being applied
            # to this cart.  So we shouldn't generate a new tokenid for it, especially
            # since it will have rcptid=0, so we wouldn't know where to mail it anyway.
            if ($type eq  'dollaroff' && $pi->{'amt'} > 0) {

                ($tokenid, $token) =
                    LJ::Pay::new_coupon("dollaroff", $pi->{'amt'}, $pi->{'rcptid'}, $pp->{'payid'});

                # if there was an error, try again later
                next unless $tokenid;

                LJ::send_mail({
                    'to' => $email,
                    'from' => $LJ::ACCOUNTS_EMAIL,
                    'fromname' => $LJ::SITENAMESHORT,
                    'wrap' => 1,
                    'charset' => 'utf-8',
                    'subject' => "Coupon Purchase",
                    'body' => "${msg}$LJ::SITENAMESHORT coupon code:\n\n".
                        "   $token\n\n".
                        "You can redeem it for \$$pi->{amt} USD in $LJ::SITENAMESHORT merchandise and/or services:\n\n".
                        "$LJ::SITENAMESHORT store:\n" .
                        "   - $LJ::SITEROOT/store/\n\n" .
                        "$LJ::SITENAMESHORT services:\n" .
                        "   - $LJ::SITEROOT/pay/\n\n" .

                        "NOTE: Your coupon is only valid for one use, so be sure that your order's " .
                        "value is greater than or equal to \$$pi->{amt} USD.\n\n" .

                        "$LJ::SITENAMESHORT Team",
                    });

            # close, but preserve token info
            } else {
                ($token, $tokenid) = ($pi->{'token'}, $pi->{'tokenid'});
            }
            $close->();
            next;
        }

        # bonus features
        elsif (LJ::Pay::is_bonus($pi)) {

            # if a bonus item of this type failed to apply, don't try to apply any more
            next if exists $bonus_failure{"$pi->{'payid'}-$pi->{'item'}-$pi->{'subitem'}"};

            # get a lock since we're about to modify their account,
            # try again later if we can't get a lock
            next unless LJ::Pay::get_lock($ru);

            # apply the bonus item to the recipient user's account
            my $res = LJ::Pay::apply_bonus_item($ru, $pi);

            # release lock and close regardless of results of operation
            LJ::Pay::release_lock($ru);

            # if an error, log to payvars (call above also logged to statushistory) and skip the email
            unless ($res) {
                LJ::Pay::payvar_append($pi->{'payid'}, "error",
                                       "[" . LJ::mysql_time() . "] unable to apply: item=$pi->{'item'},  size=" .
                                       (split("-", $pi->{'subitem'}))[0] . ", qty=$pi->{'qty'}. invalid cart?");

                # if there was a failure, all bonus items of this type were marked 
                # as failed, so we shouldn't try to process any more of them
                $bonus_failure{"$pi->{'payid'}-$pi->{'item'}-$pi->{'subitem'}"}++;

                next;
            }

            # at this point time is applied, just need to send mail.  so close.
            $close->();

            # send notification email to user
            my $name = LJ::Pay::product_name($pi);
            LJ::send_mail({
                'to' => $email,
                'from' => $LJ::ACCOUNTS_EMAIL,
                'fromname' => $LJ::SITENAMESHORT,
                'wrap' => 1,
                'charset' => 'utf-8',
                'subject' => $name,
                'body' => "${msg}Your $LJ::SITENAMESHORT account for user \"$ru->{'user'}\" has been " .
                    "credited with the following bonus feature:\n\n" .
                    "   - $name\n\n" .
                    "Your account has been updated so you can use your new feature immediately.\n\n" .
                    "$LJ::SITENAMESHORT Team"
            });

            next;

        # just close -- shipping, coppa, etc
        } else {
            $close->();
            next;
        }
    }
};

$maint{'pay_lookupstates'} = sub 
{
    require "$ENV{'LJHOME'}/cgi-bin/paylib.pl";
    require "$ENV{'LJHOME'}/cgi-bin/statslib.pl";

    my $get_dbr = sub {
        my @roles = ('slow');
        push @roles, ('slave', 'master') unless $LJ::STATS_FORCE_SLOW;
        return LJ::get_dbh({raw=>1}, @roles)
            or die "couldn't connect to database";
    };

    my $dbr = $get_dbr->();

    # see where we got to on our last run
    my $min_payid = $dbr->selectrow_array("SELECT value FROM blobcache WHERE bckey='pay_lookupstates_pos'")+0;
    my $max_payid = $dbr->selectrow_array("SELECT MAX(payid) FROM payments")+0;
    my $to_do = $max_payid - $min_payid;

    print " -I- $to_do rows to process... ";
    unless ($to_do) {
        print "done\n\n";
        return;
    }
    print "\n";
    
    # we'll call into LJ::Stats since it has handy functions
    my $blocks = LJ::Stats::num_blocks($to_do);

    # get some userprop ids
    my $propid = LJ::get_prop("user", "sidx_loc")->{id};

    foreach my $block (1..$blocks) {
        my ($low, $high) = LJ::Stats::get_block_bounds($block, $min_payid);
        print LJ::Stats::block_status_line($block, $blocks);

        # make sure our database handles aren't stale
        $LJ::DBIRole->clear_req_cache();
        $dbr = $get_dbr->()
            or die "Couldn't connect to global db reader";

        # find all payids that don't have a corresponding paystate row
        my $rows = $dbr->selectall_arrayref
            ("SELECT p.payid, p.userid FROM payments p " .
             "LEFT JOIN paystates s ON s.payid=p.payid " .
             "WHERE s.payid IS NULL AND p.userid > 0 " .
             "AND p.payid BETWEEN $low AND $high");

        next unless @$rows; # probably won't happen

        my %payids_of_userid = (); # userid => [ payids ]
        foreach (@$rows) {
            my ($payid, $userid) = @$_;
            push @{$payids_of_userid{$userid}}, $payid;
        }
        my @userids = keys %payids_of_userid;

        my $userid_bind = join(",", map { "?" } @userids);
        my $st_data = $dbr->selectall_arrayref
            ("SELECT userid, value FROM userprop " .
             "WHERE upropid=? AND userid IN ($userid_bind)",
             undef, $propid, @userids);

        # save userprop data for setting later
        my %state_of_userid = map { $_ => "??" } @userids;
        foreach (@$st_data) {
            my ($userid, $value) = @$_;

            my ($ctry, $st) = LJ::Pay::check_country_state((split("-", $value))[0,1]);

            # only care about states of 'US'
            $state_of_userid{$userid} = $ctry || '??';
            $state_of_userid{$userid} .= "-" . ($st || '??') if $ctry eq 'US';
        }

        # save results in DB
        my @vals = ();
        my $bind = "";
        while (my ($userid, $state) = each %state_of_userid) {
            foreach (@{$payids_of_userid{$userid}}) {
                push @vals, $_ => $state;
                $bind .= "(?,?),";
            }
        }
        chop $bind;

        my $dbh = LJ::get_db_writer();
        $dbh->do("REPLACE INTO paystates VALUES $bind", undef, @vals);
        die "ERROR: " . $dbh->errstr if $dbh->err;

        # now save where we got to for subsequent runs
        $dbh->do("REPLACE INTO blobcache (bckey, dateupdate, value) " .
                 "VALUES ('pay_lookupstates_pos', NOW(), ?)",
                 undef, $max_payid);
        die "ERROR: " . $dbh->errstr if $dbh->err;
    }

    # we're all done
    print " -I- Processed $to_do rows... done\n\n";
};

$maint{'pay_unreserve'} = sub
{
    use strict;
    require "$ENV{'LJHOME'}/cgi-bin/ljlib.pl";

    print "Unreserving inventory...\n";

    my $dbh = LJ::get_db_writer()
        or die "couldn't get master db handle";

    my $sth = $dbh->prepare(qq{
        SELECT pi.* FROM payitems pi, payments p 
        WHERE  pi.payid=p.payid 
            AND pi.qty_res > 0 AND pi.status='cart' AND p.mailed='C' 
            AND ( 
                 (p.method='cc' and p.datesent < DATE_SUB(NOW(), INTERVAL 3 DAY)) 
                 OR 
                 (p.datesent < DATE_SUB(NOW(), INTERVAL 12 DAY)) 
                )
        });
    die $dbh->errstr if $dbh->err;
    $sth->execute;

    while (my $it = $sth->fetchrow_hashref) {
        print "$it->{'piid'}: $it->{'item'} $it->{'subitem'} $it->{'qty_res'}\n";

        $dbh->do("UPDATE inventory SET avail=avail+? WHERE item=? AND subitem=?",
                 undef, $it->{'qty_res'}, $it->{'item'}, $it->{'subitem'});
        die $dbh->errstr if $dbh->err;

        $dbh->do("UPDATE payitems SET qty_res=0 WHERE piid=?", undef, $it->{'piid'});
        die $dbh->errstr if $dbh->err;
    }
};

$maint{'pay_shipping_notify'} = sub
{
    use strict;
    require "$ENV{'LJHOME'}/cgi-bin/ljlib.pl";

    die "no shipping email"
        unless $LJ::SHIPPING_EMAIL;
    die "no shipping contact email" 
        unless $LJ::SHIPPING_CONTACT_EMAIL;

    my $dbh = LJ::get_db_writer()
        or die "couldn't get master db handle";

    my ($ct, $min_date) = 
        $dbh->selectrow_array("SELECT COUNT(*), MIN(dateready) " .
                              "FROM shipping WHERE status='needs'");

    LJ::send_mail({
        'to' => $LJ::SHIPPING_EMAIL,
        'from' => $LJ::ADMIN_EMAIL,
        'fromname' => $LJ::SITENAME,
        'wrap' => 1,
        'charset' => 'utf-8',
        'subject' => "$ct Outstanding $LJ::SITENAME Merchandise Orders",
        'body' => 
            "There are currently $ct outstanding $LJ::SITENAME merchandise orders in need of shipping. " .
            "The oldest of which became ready at $min_date.\n\n" .

            "Visit the following URL for details about currently outstanding orders.  Please print all " .
            "invoices and include a copy of each order's invoice with its shipment, which should be " .
            "the cheaper of UPS Ground or FedEx Ground.\n\n" .

            "   $LJ::SITEROOT/admin/accounts/shipping_labels.bml\n\n" .

            "As orders are shipped, please enter their order numbers at the following URL so that " .
            "$LJ::SITENAME\'s cart system will be able to stop selling merchandise as supplies run out.\n\n" .

            "   $LJ::SITEROOT/admin/accounts/shipping_finish.bml\n\n" .

            "Please contact $LJ::SHIPPING_CONTACT_EMAIL directly with any questions or problems.\n\n" .

            "Regards,\n" .
            "$LJ::SITENAME Team\n",
        });

    print " -I- Emailed $LJ::SHIPPING_EMAIL\n\n";
};

1;
