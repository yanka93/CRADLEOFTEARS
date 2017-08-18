#!/usr/bin/perl
#

use strict;
use vars qw(%maint);

$maint{'expiring'} = sub
{
    require "$ENV{'LJHOME'}/cgi-bin/paylib.pl";
    my $dbh = LJ::get_db_writer();
    my $sth;

    # NOTES:
    # We mail people about 10 days before, 3 days before,
    # and when their account expires.  But because we have
    # to plan for this script not running all the time, here
    # are the rules/ranges we play by:
    #
    #
    #   10          8          3      2    0
    #  ------------------------+-----------+.....
    #   ^-----------^          ^------^    ^>>>>
    #   "Expiring..."          "Soon!"    "Expired"
    #
    #   First, expire all accounts t>=0, and email them.
    #
    #   Second, mail all accounts expiring in 2-3 days,
    #   provided they haven't been mailed in the past 5 days.
    #   (less than 2 days would be considered too rude,
    #    considering we'll be mailing them again in a day
    #    or so to say it expired.)
    #
    #   Third, mail all accounts expiring 8-10 days, again
    #   if they haven't been mailed in past 5 days.

    # what time is it on the database?
    my $nowu = $dbh->selectrow_array("SELECT UNIX_TIMESTAMP()");

    if (abs($nowu - time()) > 30*60) {
        die "Database and host clock differ too much.  Something might be wrong.\n";
    }
    
    # do expirations
    print "-I- Doing expirations.\n";

    # paid accounts
    $sth = $dbh->prepare("SELECT userid FROM paiduser ".
                         "WHERE paiduntil < NOW() AND paiduntil > '0000-00-00'");
    $sth->execute;
    die $dbh->errstr if $dbh->err;
    while (my ($userid) = $sth->fetchrow_array)
    {

        # about to modify account, get a lock on the user,
        # try again later if we fail to get a lock
        next unless LJ::Pay::get_lock($userid);

        # re-verify $u object and skip if the expiration data no longer matches
        my $u = $dbh->selectrow_hashref("SELECT u.* FROM user u, paiduser pu ".
                                        "WHERE pu.userid=? AND u.userid=pu.userid AND u.caps&16=0 AND ".
                                        "      pu.paiduntil < NOW() AND pu.paiduntil > '0000-00-00'",
                                        undef, $userid);
        unless ($u) {
            LJ::Pay::release_lock($userid);
            next;
        }

        # expire the account
        print "Expiring $u->{'user'}...\n";

        # remove paid time, this %res is coming from LJ::Pay::freeze_bonus
        my $bonus_ref = [];
        my $res = LJ::Pay::remove_paid_account($u, $bonus_ref);

        # release lock on this account
        LJ::Pay::release_lock($userid);

        # did an error occur above?
        unless ($res) {
            LJ::statushistory_add($userid, undef, "pay_modify", 
                                  "error trying to expire paid account");
            next;
        }

        # and send them an email, if they're not self-deleted/suspended
        if ($u->{'statusvis'} eq "V") {
            my $bonus_msg;
            if (@$bonus_ref) {
                $bonus_msg = "Additionally, the following bonus features have been deactivated " .
                             "from your account.  Any remaining time has been saved and will " .
                             "be reapplied if you later decide to renew your paid account.\n\n" .
                             join("\n", map {  "   - " . LJ::Pay::product_name($_->{'item'}, $_->{'size'}, undef, "short") . 
                                               ": $_->{'daysleft'} days saved" } 
                                  sort { $a->{'item'} cmp $b->{'item'} } @$bonus_ref) . "\n\n";
            }

            # email the user
            LJ::send_mail({ 'to' => $u->{'email'},
                            'from' => $LJ::ACCOUNTS_EMAIL,
                            'wrap' => 1,
                            'charset' => 'utf-8',
                            'subject' => 'Paid Account Expired',
                            'body' => ("Your $LJ::SITENAMESHORT paid account for user \"$u->{'user'}\" has expired.\n\n".
                                       $bonus_msg .
                                       "You can continue to use the site, but without all the paid features.  If ".
                                       "you'd like to renew your subscription, visit:\n\n".
                                       "   $LJ::SITEROOT/pay/\n\n".
                                       "And if you have any questions or requests, feel free to ask.  We want ".
                                       "to keep you happy.  :)\n\n".
                                       "Thanks,\n".
                                       "$LJ::SITENAMESHORT Team\n"),
                                   });
        }
    }

    # bonus features
    $sth = $dbh->prepare("SELECT userid, item, size FROM paidexp " .
                         "WHERE (daysleft=0 OR daysleft IS NULL) AND ".
                         "      expdate < NOW() AND expdate > '0000-00-00'");
    $sth->execute;
    die $dbh->errstr if $dbh->err;
    while (my ($userid, $item, $size) = $sth->fetchrow_array)
    {

        # get a u object
        my $u = LJ::load_userid($userid, "force");
        
        # going to modify this account, get a lock.
        # but try again later if we can't get one
        next unless LJ::Pay::get_lock($userid);

        # expire the feature
        print "Expiring $u->{'user'} bonus feature: $item..\n";

        # expire this bonus feature
        my $res = LJ::Pay::expire_bonus($userid, $item);

        # finished doing account modifications
        LJ::Pay::release_lock($userid);

        # an error occurred above, log to statushistory
        unless ($res) {
            LJ::statushistory_add($userid, undef, "pay_modify", 
                                  "error trying to expire bonus feature: $item");
            next;
        }

        # and send them an email, if they're not self-deleted/suspended
        if ($u->{'statusvis'} eq "V") {
            my $name = LJ::Pay::product_name($item, $size, undef, "short");
            LJ::send_mail({ 'to' => $u->{'email'},
                            'from' => $LJ::ACCOUNTS_EMAIL,
                            'fromname' => $LJ::SITENAMESHORT,
                            'wrap' => 1,
                            'charset' => 'utf-8',
                            'subject' => 'Bonus Feature Expired',
                            'body' => ("$u->{'name'},\n\n".
                                       "The following bonus feature of your $LJ::SITENAMESHORT paid " .
                                       "account for user \"$u->{'user'}\" has expired.\n\n" .
                                       "   - $name\n\n" .
                                       "If you'd like this feature reactivated, you can " .
                                       "renew your subscription.  To do so, visit:\n\n" .
                                       "   $LJ::SITEROOT/pay/\n\n".
                                       "Thanks,\n".
                                       "$LJ::SITENAMESHORT Team\n"),
                                   });
        }
    }


    # do reminders
    foreach my $range ([2,3,"warn"], [8,10,"soon"]) {
        my $rlo = $range->[0];
        my $rhi = $range->[1];
        my $level = $range->[2];

        # expiring paid accounts
        my $subject = $level eq "soon" ? "Account Expiring Soon" : "Account Expiration Warning";
        print "-I- Do $rlo-$rhi day reminders...\n";
        $sth = $dbh->prepare("SELECT u.*, pu.paiduntil, pu.paidreminder ".
                             "FROM user u, paiduser pu ".
                             "WHERE u.userid=pu.userid AND u.caps&16=0 AND u.caps&8 ".
                             "AND u.statusvis='V' ".
                             "AND pu.paiduntil BETWEEN DATE_ADD(NOW(), INTERVAL $rlo DAY) ".
                             "AND DATE_ADD(NOW(), INTERVAL $rhi DAY) ".
                             "AND (pu.paidreminder IS NULL ".
                             "OR pu.paidreminder < DATE_SUB(NOW(), INTERVAL 5 DAY))");
        $sth->execute;
        die $dbh->errstr if $dbh->err;
        while (my $u = $sth->fetchrow_hashref)
        {
            my $uexp = LJ::mysqldate_to_time($u->{'paiduntil'});
            my $days = int(($uexp - $nowu) / 86400 + 0.5);
            print "Mailing user $u->{'user'} about $days days...\n";
            $dbh->do("UPDATE paiduser SET paidreminder=NOW() WHERE userid=?", undef, $u->{'userid'});
            LJ::send_mail({ 'to' => $u->{'email'},
                            'from' => $LJ::ACCOUNTS_EMAIL,
                            'fromname' => $LJ::SITENAMESHORT,
                            'wrap' => 1,
                            'charset' => 'utf-8',
                            'subject' => $subject,
                            'body' => ("$u->{'name'},\n\n".
                                       "Your $LJ::SITENAMESHORT paid account for user \"$u->{'user'}\" is expiring ".
                                       "in $days days, at which time it'll revert to free account status.\n\n".
                                       "If you're still using and enjoying the site, please renew your ".
                                       "subscription before it runs out and help support the project. ".
                                       "(Servers and bandwidth don't come free, unfortunately...)\n\n".
                                       "   $LJ::SITEROOT/pay/\n\n".
                                       "And if you have any questions or requests, feel free to ask.  We want ".
                                       "to keep you happy.  :)\n\n".
                                       "Thanks,\n".
                                       "$LJ::SITENAMESHORT Team\n"),
                                   });
        }

        # expiring bonus feature reminders
        my $subject = $level eq "soon" ? "Subscription Expiring Soon" : "Subscription Expiration Warning";
        $sth = $dbh->prepare("SELECT u.*, px.item, px.size, px.expdate FROM user u, paidexp px ".
                             "WHERE u.userid=px.userid AND u.statusvis='V' AND ".
                             "      px.expdate BETWEEN DATE_ADD(NOW(), INTERVAL $rlo DAY) AND ".
                             "                         DATE_ADD(NOW(), INTERVAL $rhi DAY)".
                             "      AND (px.lastmailed IS NULL ".
                             "      OR px.lastmailed < DATE_SUB(NOW(), INTERVAL 5 DAY))");
        $sth->execute;
        die $dbh->errstr if $dbh->err;
        while (my $u = $sth->fetchrow_hashref)
        {
            my $expdate = LJ::mysqldate_to_time($u->{'expdate'});
            my $days = int(($expdate - $nowu) / 86400 + 0.5);
            print "Mailing user $u->{'user'} about $days days...\n";
            $dbh->do("UPDATE paidexp SET lastmailed=NOW() WHERE userid=? AND item=?",
                     undef, $u->{'userid'}, $u->{'item'});
            my $bonus_name = LJ::Pay::product_name($u->{'item'}, $u->{'size'}, undef, "short");
            LJ::send_mail({ 'to' => $u->{'email'},
                            'from' => $LJ::ACCOUNTS_EMAIL,
                            'fromname' => $LJ::SITENAMESHORT,
                            'wrap' => 1,
                            'charset' => 'utf-8',
                            'subject' => $subject,
                            'body' => ("$u->{'name'},\n\n".
                                       "Your $LJ::SITENAMESHORT paid account for user \"$u->{'user'}\" has ".
                                       "bonus features expiring soon.  In $days days, your ".
                                       "$bonus_name will expire and you will be reverted to the standard ".
                                       "set of features included with your paid account.\n\n".
                                       "If you're still using and enjoying your $bonus_name, please ".
                                       "renew your subscription at the $LJ::SITENAMESHORT store:\n\n".
                                       "   $LJ::SITEROOT/pay/\n\n".
                                       "If you have any further questions, feel free to ask.  We'll do our ".
                                       "best to help.\n\n".
                                       "Thanks,\n".
                                       "$LJ::SITENAMESHORT Team\n"),
                                   });
        }
    }
    
    print "-I- Done.\n";
};

1;
