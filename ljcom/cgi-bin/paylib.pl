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

require "$ENV{'LJHOME'}/cgi-bin/ljlib.pl";

package LJ::Pay;

use strict;
use vars qw(%account %bonus %capinf @coupon %product %color %size);
use Time::Local ();  # used by /paidaccounts/usepaypal.bml, at least.
use LWP;
use LWP::UserAgent;

# hard-coded ljcom cap info

%capinf = (
           'new'   => { 'bit' => 0, 'name' => 'New User' },
           'free'  => { 'bit' => 1, 'name' => 'Free User' },
           'early' => { 'bit' => 2, 'name' => 'Early Adopter' },
           'paid'  => { 'bit' => 3, 'name' => 'Paid User' },
           'perm'  => { 'bit' => 4, 'name' => 'Permanent Account' },
         );

%account = (
            2 => { 'name' => '2 months', 'amount' => 5 },
            6 => { 'name' => '6 months', 'amount' => 15 },
            12 => { 'name' => '12 months', 'amount' => 25 },
            );

# list of dollar amount
@coupon = (5, 15, 25);

# bonus features are of 2 types:
# - "bool" are either on or off (userpics), 'cap' key is required
# - "sized" have a magnitude associated with them (how much disk quota)
%bonus = ( 
           # userpics are a 'bool' item
           'userpic' => {
               'name' => 'Extra Userpics',
               'type' => 'bool',
               'cap' => 9, # cap bit to activate for user
               'items' => {
                   # quantities
                   2 => { 'name' => '2 months', 'amount' => 2 },
                   6 => { 'name' => '6 months', 'amount' => 6 },
                   12 => { 'name' => '12 months', 'amount' => 10 }
               }
           },

           # disk quota is a 'sized' item
           'diskquota' => {
               'name' => 'Disk Quota',
               'type' => 'sized',
               'cap' => undef, # optional
               'apply_hook' => \&LJ::Pay::diskquota_apply_hook,
               'items' => {
                   # size => quantity (months)
                   # - prices are NOT determined.  these are just made up numbers for testing.
                   250 => {
                       'name' => '250 MiB',
                       'qty' => {
                           2 => { 'name' => '2 months', 'amount' => 10 },
                           6 => { 'name' => '6 months', 'amount' => 20 },
                           12 => { 'name' => '12 months', 'amount' => 36 },
                       }
                   },
                   500 => {
                       'name' => '500 MiB',
                       'qty' => {
                           2 => { 'name' => '2 months', 'amount' => 20 },
                           6 => { 'name' => '6 months', 'amount' => 40 },
                           12 => { 'name' => '12 months', 'amount' => 72 },
                       }
                   },
                   1024 => {
                       'name' => '1024 MiB',
                       'qty' => {
                           2 => { 'name' => '2 months', 'amount' => 30 },
                           6 => { 'name' => '6 months', 'amount' => 60 },
                           12 => { 'name' => '12 months', 'amount' => 100 },
                       }
                   },

               }
           }
          );

# now allow a mechanism for individual bonus items to be disabled
foreach my $itemname (keys %bonus) {
    next unless $LJ::DISABLED{"bonus-$itemname"};

    delete $bonus{$itemname};
}

%product = (
            "clothes-short" => 
            [ "Short-Sleeved Shirt", [ qw(white black grey orange bluedusk leaf )]],
            "clothes-long" => 
            [ "Long-Sleeved Shirt", [ qw(white black grey navyblue )]],
            "clothes-polo" => 
            [ "Embroidered Polo Shirt", [ qw(white black grey navyblue )]],
            "clothes-babydoll" => 
            [ "\"Baby Doll\" Fitted Shirt", [ qw(white black grey pink royalblue )]],
            "clothes-hooded" =>
            [ "Hooded Sweatshirt", [ qw(grey black) ], "disable_coupons"],
            "clothes-twillhat" =>
            [ "Stonewashed Cap", [ qw(khaki black navyblue) ]],
           );

%color = (
          'white' => "White",
          'black' => "Black",
          'grey' => "Grey",
          'navyblue' => "Navy Blue",
          'royalblue' => "Royal Blue",
          'bluedusk' => "Blue Dusk",
          'pink' => "Pink",
          'leaf' => "Leaf Green",
          'orange' => "Orange",
          'khaki' => "Khaki",
          );

%size = (
         'os' => [0, "One Size Fits All"],
         's' => [1, "Small"],
         'm' => [2, "Medium"],
         'l' => [3, "Large"],
         'xl' => [4, "X-Large"],
         'xxl' => [5, "XX-Large"],
         '3xl' => [6, "3X-Large"],
         '4xl' => [7, "4X-Large"],
         );

## hook called from create.bml after an account is made
sub post_create 
{
    my $o = shift;
    my $userid = $o->{'userid'};
    my $user = $o->{'user'};
    my $dbh = LJ::get_db_writer();
    
    return unless $o->{'code'};
    my ($acid, $auth) = LJ::acct_code_decode($o->{'code'});
    return unless $acid;

    # check to see if this account was created using an
    # acid that was created as the result of a payment.
    # in other words, we might now need to make the 
    # account paid.

    # old table
    my $payid = $dbh->selectrow_array("SELECT payid FROM acctpay WHERE acid=$acid");
    if ($payid) {
        # trust that paid users gave valid email address (so email alias then works immediately)
        LJ::update_user($userid, { status => 'A' });
        # now that userid != 0, they'll be mailed and setup 
        # with a minute if the cronjob is running.
        $dbh->do("UPDATE payments SET userid=$userid WHERE payid=$payid");
        return;
    }

    # new table
    my $piid = $dbh->selectrow_array("SELECT piid FROM acctpayitem WHERE acid=$acid");
    if ($piid) {
        # trust that paid users gave valid email address (so email alias then works immediately)
        LJ::update_user($userid, { status => 'A' });
        # do the payment immediately
        my ($item, $qty) = $dbh->selectrow_array("SELECT item, qty FROM payitems ".
                                                 "WHERE piid=$piid");
        my $mo = $item eq "paidacct" ? $qty : 0;
        $mo = 99 if $item eq "perm";
        LJ::Pay::add_paid_months($userid, $mo);
        return;
    }
}

sub diskquota_apply_hook
{
    my ($u, $item) = @_;

    # we have successfully done nothing
    return 1 unless $LJ::FB_QUOTA_NOTIFY;

    my $dbh = LJ::get_db_writer();
    my ($size, $exptime) = $dbh->selectrow_array("SELECT size, UNIX_TIMESTAMP(expdate) " .
                                                 "FROM paidexp WHERE userid=? AND item=?",
                                                 undef, $u->{userid}, $item);
    return undef unless $size && $exptime; # eh?

    # add cmdbuffer job to send XML-RPC request to FotoBilder later
    return LJ::cmd_buffer_add($u->{clusterid}, $u->{userid},
                              "pay_fb_xmlrpc", 
                              {
                                  item    => $item,
                                  size    => $size,
                                  exptime => $exptime,
                              });
}

# uuid:  userid
# what:  paidaccount, etc ('what' db field)
# trans: 'P' => pay, 'X' => expire
sub update_paytrans
{
    my ($uuid, $what, $chflag) = @_;

    my $uid = LJ::want_userid($uuid);
    return undef unless $uid && $what && $chflag;

    my $dbh = LJ::get_db_writer()
        or return undef;

    # load all transitions for this user
    my @trans = @{ 
        $dbh->selectall_arrayref
            ("SELECT time, action FROM paytrans WHERE userid=? AND what=?",
             undef, $uid, $what) || [] 
         };

    # now trans => ([ time, action ], ...)

    my $time = time();
    my $action = '';

    # currently paidaccount is the only 'what'
    if ($what eq 'paidaccount') {

        my $renew_thresh = 14; # days between 'renew' and 'return'

        # evpent definitions:
        #  * 'new'    - user has never paid for an account before, this is 
        #               their first payment
        #  * 'ext'    - user extended their account while it was still active
        #  * 'renew'  - user paid before, expired, then re-purchased within 
        #               $renew_thresh days of expiration
        #  * 'return' - user paid before, expired, then re-purchased after 
        #               $renew thresh days of expiration
        #  * 'expire' - user had paid account expire

        # adding paid months to account
        if ($chflag eq 'P') {

            # if this is the first purchase we've seen, then their account is new
            if (! @trans) {
                $action = 'new';

            # if we've seen purchases before, we must look at their last expiration
            # to see if this should be considered a 'return' or a 'renew'
            } else {

                # find last expiration/pay actions a user had
                my $lexp = 0;
                my $lpay = 0;
                foreach my $tr (@trans) {
                    $lexp = $tr->[0] if $tr->[1] eq 'expire' && $tr->[0] > $lexp;
                    $lpay = $tr->[0] if $tr->[1] ne 'expire' && $tr->[0] > $lpay;
                }

                $action = 'ext' if $lpay && (! $lexp || $lexp < $lpay && $time > $lpay);
                $action ||= $lexp && $lexp < ($time - 86400 * $renew_thresh) ?
                    'return' : 'renew';
            }

        # expiring an existing paid account
        } elsif ($chflag eq 'X') {
            $action = 'expire';
        }
    }

    # insert transition into db
    $dbh->do("INSERT INTO paytrans VALUES (?,?,?,?)", 
             undef, $uid, $time, $what, $action)
        or return undef;

    return 1;
}

sub add_paid_time
{
    my ($userid, $time, $bonus_added) = @_;  # or 99 months for perm
    $userid += 0;
    return undef unless $userid && (! $bonus_added || ref $bonus_added);

    # figure out the amount of time, as well
    # as what type of units it is measured in
    $time = ref $time ? $time : [ $time, 'month' ];

    my ($timeval, $units) = @$time;
    return undef unless $timeval > 0;
    $units = lc($units);
    $units ||= "month";
    return undef unless $units eq 'month' || $units eq 'day';

    my $dbh = LJ::get_db_writer()
        or return undef;

    my $is_perm = $timeval == 99 && $units eq 'month';

    # permanent account
    if ($is_perm) {

        # add permanent and paid caps
        LJ::modify_caps($userid, ['paid', 'perm'],[])
            or return undef;

        # create paiduser row
        $dbh->do("INSERT IGNORE INTO paiduser (userid) VALUES (?)", undef, $userid);

    # regular
    } else {

        # add paid cap
        LJ::modify_caps($userid, ['paid'], [])
            or return undef;

        $dbh->do("INSERT INTO paiduser (userid, paiduntil) VALUES (?, DATE_ADD(NOW(), INTERVAL ? $units))",
                 undef, $userid, $timeval);
        if ($dbh->err) {
            # already an paying member; renewing:
            $dbh->do("UPDATE paiduser SET paiduntil=DATE_ADD(GREATEST(IFNULL(paiduntil, NOW()), NOW()), INTERVAL ? $units) " .
                     "WHERE userid=?", undef, $timeval, $userid)
                or return undef;
        }
    }

    # at this point the paid time has been applied.  any failure could cause the 
    # caller to retry us later and cause paid time to be applied twice.

    # log this paid account activation
    LJ::statushistory_add($userid, undef, 'pay_modify',
                          "adding paid ${units}s: " . ($is_perm ? "perm" : $timeval));

    $LJ::CACHE_PAIDGROUP ||= LJ::get_userid("paidmembers");

    # get a fresh userid from the database
    my $u = LJ::load_userid($userid, "force");

    if ($u->{'journaltype'} eq "P" && $LJ::CACHE_PAIDGROUP) {
        # add as friend to paidmembers group (if it exists on this server)
        LJ::add_friend($LJ::CACHE_PAIDGROUP, $userid);
    }

    LJ::load_user_props($u, 'no_mail_alias');
    # add email alias, if account is validated
    if ($u->{'status'} eq "A" &&
        ! $u->{'no_mail_alias'} &&
        ! exists $LJ::FIXED_ALIAS{$u->{'user'}}) {
        $dbh->do("INSERT IGNORE INTO email_aliases (alias, rcpt) VALUES (?,?)",
                 undef, "$u->{'user'}\@$LJ::USER_DOMAIN", $u->{'email'});
    }

    # note the transition for stats
    LJ::Pay::update_paytrans($userid, 'paidaccount', 'P')
        or return undef;

    # FIXME: If the bonus-activation operation fails, then any
    #        pending bonus items won't be applied to the account being
    #        given paid time.  Further, if we return undef from here on
    #        failure, callers such as bin/maint/pay.pl could retry us
    #        endlessly, adding time each time the above code is executed,
    #        then dying when trying to add the bonus features.  We need
    #        to queue up the activation action on failure and return true

    # add any extra bonus feature time that needs to be added
    @$bonus_added = LJ::Pay::activate_frozen_bonus($userid);

    return 1;
}

sub add_paid_months {
    &nodb;
    my ($userid, $months, $bonus_added) = @_;  # or 99 months for perm

    return LJ::Pay::add_paid_time(@_);
}

sub remove_paid_months
{
    &nodb;
    my ($userid, $months, $it) = @_;  # or 99 months for perm
    $userid += 0;
    return undef unless $userid && $months >= 0;
    return 1 unless $months;

    my $dbh = LJ::get_db_writer();
    my $pre = $dbh->selectrow_hashref("SELECT u.caps, p.paiduntil FROM user u LEFT JOIN paiduser p ".
                                      "ON p.userid=u.userid WHERE u.userid=?", undef, $userid);


    # 99 months means we're working on a permanent account
    my $is_perm = $months == 99;

    # subtract $months from paid time, unless perm
    $dbh->do("UPDATE paiduser SET paiduntil=DATE_SUB(paiduntil, INTERVAL ? MONTH) ".
             "WHERE userid=?", undef, $months, $userid)
        unless $is_perm;

    # remove them from being a paid user if their time has run out
    LJ::Pay::remove_paid_account($userid, undef, $is_perm)
        unless $dbh->selectrow_array("SELECT paiduntil > NOW() FROM paiduser WHERE userid=?", undef, $userid);

    # log this change to statushistory
    my $post = $dbh->selectrow_hashref("SELECT u.caps, p.paiduntil FROM user u LEFT JOIN paiduser p ".
                                       "ON p.userid=u.userid WHERE u.userid=?", undef, $userid);

    my $extra = $it ? " payment: $it->{'payid'}\[$it->{'piid'}]" : "";
    LJ::statushistory_add($userid, undef, "revoke",
                          "item=paidacct; $months months; was: caps $pre->{'caps'}/$pre->{'paiduntil'}, ".
                          "now: $post->{'caps'}/$post->{'paiduntil'}$extra");

    return 1;
}

sub acct_code_from_payid
{
    &nodb;

    my $payid = shift;
    $payid += 0;

    my $dbh = LJ::get_db_writer();

    my $sth;

    $dbh->do("LOCK TABLES acctpay WRITE, acctcode WRITE");

    # does one already exist?
    $sth = $dbh->prepare("SELECT acctcode.acid, acctcode.auth FROM acctcode, acctpay ".
                         "WHERE acctcode.acid=acctpay.acid AND acctpay.payid=$payid");
    $sth->execute;
    my ($acid, $auth) = $sth->fetchrow_array;
    if ($acid) {
        $dbh->do("UNLOCK TABLES");
        return LJ::acct_code_encode($acid, $auth);
    }

    # if not, let's add one.
    my $code = LJ::acct_code_generate(0);
    if ($code) {
        ($acid, $auth) = LJ::acct_code_decode($code);
        $dbh->do("REPLACE INTO acctpay (payid, acid) VALUES ($payid, $acid)");
    }
    $dbh->do("UNLOCK TABLES");
    return $code;
}

sub new_rename_token
{
    &nodb;

    my $payid = shift;

    my $dbh = LJ::get_db_writer();

    my $code = LJ::rand_chars(10);
    $dbh->do("INSERT INTO renames (token, payid) VALUES (?, ?)",
             undef, $code, $payid)
      or return undef;
    my $renid = $dbh->{'mysql_insertid'}
      or return undef;

    my $token = sprintf("%06x%s", $renid, $code);
    return wantarray() ? ($token, $renid) : $token;
}

sub register_payment
{
    &nodb;

    my $o = shift;
    my $sth;
    my $error = $o->{'error'};

    my $zuid = $o->{'zerouserid'};
    my $userid = 0;
    my $user = "???";

    unless ($zuid) {
        $user = lc($o->{'user'});
        $user =~ s/\W//g;
        $userid = LJ::get_userid($user);
        unless ($userid) {
            $$error = "Invalid user ($user)";
            return 0;
        }
    }

    my $dbh = LJ::get_db_writer();

    my $out_payid = $o->{'out_payid'};
    my $qdatesent = $dbh->quote($o->{'datesent'});
    my $qamount = $dbh->quote($o->{'amount'}+0);
    my $qmonths = $dbh->quote($o->{'months'}+0);
    my $qnotes = $dbh->quote($o->{'notes'});
    my $qmethod = $dbh->quote($o->{'method'});
    my $qwhat = $dbh->quote($o->{'what'});
    my $qgiveafter = $dbh->quote($o->{'giveafter'});

    my $payid;
    my $digest = Digest::MD5::md5_hex($o->{'unique_id'});

    # prevent duplicates (quite common from paypal -> pp_notify.bml)
    if ($o->{'unique_id'})
    {
        $dbh->do("LOCK TABLES payments WRITE, duplock WRITE");

        $sth = $dbh->prepare("SELECT dupid FROM duplock WHERE realm='payments' AND reid=0 AND ".
                             "userid=$userid AND digest='$digest'");
        $sth->execute;
        ($payid) = $sth->fetchrow_array;
        if ($payid) {
            $dbh->do("UNLOCK TABLES");
            $$out_payid = $payid;
            return $userid;
        }
    }

    my ($mailed, $used) = ("N", "N");
    $mailed = "Y" if $o->{'never_mail'};
    $used   = "Y" if $o->{'never_use'};

    ### now, insert a payment
    $sth = $dbh->prepare("INSERT INTO payments (userid, datesent, daterecv, amount, months, used, mailed, notes, method, forwhat, giveafter) ".
                         "VALUES ($userid, $qdatesent, NOW(), $qamount, $qmonths, '$used', '$mailed', $qnotes, $qmethod, $qwhat, $qgiveafter)");
    $sth->execute;
    if ($dbh->err) {
        $$error = "Database error: " . $dbh->errstr;
        $dbh->do("UNLOCK TABLES");
        return 0;
    }
    $payid = $sth->{'mysql_insertid'};

    if ($o->{'unique_id'})
    {
        $dbh->do("INSERT INTO duplock (realm, reid, userid, digest, dupid, instime) ".
                 "VALUES ('payments', 0, $userid, '$digest', $payid, NOW())");
        $dbh->do("UNLOCK TABLES");
    }

    ### insert payment search values
    if ($o->{'search'}) {
        my $s = $o->{'search'};
        foreach my $k (keys %$s) {
            my $v = $s->{$k};
            my $vals = ref $v eq "ARRAY" ? $v : [ $v ];
            foreach (@$vals) {
                $dbh->do("INSERT INTO paymentsearch (payid, ikey, ival) VALUES ($payid, ?, ?)",
                         undef, $k, $_);
            }
        }
    }

    my $whoenter = $o->{'remote'}->{'user'} || "auto";
    my $msgbody = "Entered by $whoenter: payment# $payid for $user\n\n";
    $msgbody .= "AMOUNT: $o->{'amount'}   MONTHS: $o->{'months'}\n";
    $msgbody .= "METHOD: $o->{'method'}   WHAT: $o->{'what'}\n";
    $msgbody .= "DATE: $o->{'datesent'}\n";
    $msgbody .= "NOTES:\n$o->{'notes'}\n";

    LJ::send_mail({ 'to' => 'paypal@livejournal.com',
                    'from' => 'lj_noreply@livejournal.com',
                    'charset' => 'utf-8',
                    'subject' => "Payment \#$payid -- $user",
                    'body' => $msgbody,
                });

    $$out_payid = $payid;
    return $userid;
}

sub paypal_parse_custom
{
    my $custom_str = shift;

    my %custom;
    foreach my $pair (split(/&/, $custom_str))
    {
        my ($key, $value) = split(/=/, $pair);
        foreach (\$key, \$value) {
            tr/+/ /;
            s/%([a-fA-F0-9][a-fA-F0-9])/pack("C", hex($1))/eg;
        }
        $custom{$key} = $value;
    }

    return \%custom;
}

sub register_paypal_payment
{
    &nodb;

    my $pp = shift;
    my $o = shift;
    my $error = $o->{'error'};

    my %custom = %{ LJ::Pay::paypal_parse_custom($pp->{custom}) || {}};

    # for some reason, every few weeks a payment comes in without the
    # 'newacct' parameter.  so this hack adds it.  some broken browser
    # out there?
    $custom{'newacct'} = 1
        if ($custom{'months'} && ! defined $custom{'user'});


    # cart support (new payment system)
    if ($custom{'cart'}) {

        my $dbh = LJ::get_db_writer();

        my $cartobj = LJ::Pay::load_cart($custom{'cart'});
        unless ($cartobj) { $$error = "Invalid cart"; return 0; }
        if ($cartobj->{'mailed'} ne "C") { 
            # cart is already paid for?  or paypal is being
            # dumb (as usual) and sending a dup notification,
            # so let's see if the txn matches from previous
            my $old_txn = $dbh->selectrow_array("SELECT ival FROM paymentsearch ".
                                                "WHERE payid=? AND ikey='pptxnid'", undef,
                                                $cartobj->{'payid'});
            
            # tell paypal we're cool if this is a dup
            return 1 if $old_txn && $old_txn eq $pp->{'txn_id'};
            
            $$error = "Cart is already paid for"; return 0; 
        }
        unless ($cartobj->{'amount'} * 100 ==
                $pp->{'payment_gross'} * 100) {
            $$error = "Payment gross ($pp->{'payment_gross'} doesn't match cart price ($cartobj->{'amount'})";
            return 0;
        }

        my $s = {
            'ppemail' => $pp->{'payer_email'},
            'pptxnid' => $pp->{'txn_id'},
            'pplastname' => $pp->{'last_name'},
        };
        foreach my $k (keys %$s) {
            $dbh->do("INSERT INTO paymentsearch (payid, ikey, ival) VALUES (?, ?, ?)",
                     undef, $cartobj->{'payid'}, $k, $s->{$k});
        }

        $dbh->do("UPDATE payments SET mailed='N', used='N', ".
                 "       method='paypal', daterecv=NOW() ".
                 "WHERE payid=? AND mailed='C'",
                 undef, $cartobj->{'payid'});
        if ($dbh->err) { $$error = "Database error"; return 0; }
        return 1;
    }

    # old payment system
    
    unless (($account{$custom{'months'}}->{'amount'} == $pp->{'payment_gross'}) ||
            ($custom{'months'} == 99 && $pp->{'payment_gross'} == 100) ||
            ($custom{'what'} eq "rename" && $pp->{'payment_gross'} == 15))
    {
        $$error = "Payment gross not valid for that month value";
        return 0;
    }

    my %mon2num = qw(Jan 1 Feb 2 Mar 3 Apr 4 May 5 Jun 6
                     Jul 7 Aug 8 Sep 9 Oct 10 Nov 11 Dec 12);

    my $pp_to_sql_date = sub {
        my $ppdate = shift;
        if ($ppdate =~ /\b(\w\w\w) (\d{1,2}), (\d\d\d\d)\b/) {
            my ($year, $month, $day);
            $year = $3;
            $month = $mon2num{$1};
            $day = $2;
            return sprintf("%04d-%02d-%02d", $year, $month, $day);
        }
        return "";
    };

    # is this for a new account?  need to generate an account code
    # and mail it to the user.
    if ($custom{'newacct'})
    {
        my %pay;
        my $payid = 0;

        my @emails = ($pp->{'payer_email'});
        if ($custom{'email'} && 
            $custom{'email'} ne $pp->{'payer_email'}) {
            push @emails, $custom{'email'};
        }

        $pay{'zerouserid'} = 1;  # no userid yet.  new acccount.
        $pay{'datesent'} = $pp_to_sql_date->($pp->{'payment_date'});
        $pay{'method'} = "paypal";
        $pay{'notes'} = "PayPal Transaction ID: " . $pp->{'txn_id'} . "\n";
        $pay{'what'} = "account";  # one of (account, rename, gift)
        $pay{'unique_id'} = $pp->{'txn_id'} . $pp->{'payment_status'};
        $pay{'error'} = $error;
        $pay{'out_payid'} = \$payid;
        $pay{'search'} = {
            'ppemail' => \@emails,
            'pptxnid' => $pp->{'txn_id'},
            'pplastname' => $pp->{'last_name'},
        };
        $pay{'notes'} .= "Payment Status: $pp->{'payment_status'}\n";

        if ($pp->{'payment_status'} eq "Completed")
        {
            $pay{'amount'} = $pp->{'payment_gross'};
            $pay{'months'} = $custom{'months'};

            register_payment(\%pay);

            if ($payid)
            {
                my $code = acct_code_from_payid($payid);
                unless ($code) { return 0; }

                LJ::send_mail({
                    'to' => join(", ", @emails),
                    'from' => $LJ::ACCOUNTS_EMAIL,
                    'charset' => 'utf-8',
                    'subject' => 'Account code',
                    'body' => "Here is your account creation code you can use to start setting up your journal:\n\n    $code\n\nOr, just click or copy/paste this:\n\n    $LJ::SITEROOT/create.bml?code=$code\n",
                });

                return 1;
            }
            return 0;
        }

        # any non-complete payment we enter is just a placeholder for
        # paymentsearch indexes to point back to.
        $pay{'never_mail'} = $pay{'never_use'} = 1;

        if ($pp->{'payment_status'} eq "Pending")
        {
            $pay{'notes'} .= "Pending Reason: $pp->{'pending_reason'}\n";
            $pay{'notes'} .= "\nLiveJournal has been notified of your payment.  If you paid with an eCheck, your account code will be emailed to you when the check clears.\n";
        }

        register_payment(\%pay);
        return 0 unless $payid;

        LJ::send_mail({
            'to' => $pp->{'payer_email'},
            'from' => $LJ::ACCOUNTS_EMAIL,
            'charset' => 'utf-8',
            'subject' => "LiveJournal Payment Info ($payid)",
            'body' => "PayPal has notified LiveJournal of your payment.  We've logged this transaction as \#$payid.  Its current status is shown below:\n\n$pay{'notes'}\n",
        });
        return 1;
    }

    # handle incomplete payments for the general case (when we know username
    # of buyer)
    if ($pp->{'payment_status'} ne "Completed")
    {
        my %pay;
        $pay{'user'} = $custom{'user'};
        $pay{'method'} = "paypal";
        $pay{'unique_id'} = $pp->{'txn_id'} . $pp->{'payment_status'};
        $pay{'datesent'} = $pp_to_sql_date->($pp->{'payment_date'});
        $pay{'notes'} = "PayPal Transaction ID: " . $pp->{'txn_id'} . "\n";
        $pay{'notes'} .= "Payment Status: $pp->{'payment_status'}\n";
        $pay{'error'} = $error;
        $pay{'search'} = {
            'ppemail' => $pp->{'payer_email'},
            'pptxnid' => $pp->{'txn_id'},
            'pplastname' => $pp->{'last_name'},
        };
        $pay{'never_use'} = 1;  # but we do mail them.

        if ($pp->{'payment_status'} eq "Pending") {
            $pay{'notes'} .= "Pending Reason: $pp->{'pending_reason'}\n\n";
            $pay{'notes'} .= "You will get another email when this payment clears (or fails).";
        }

        return 1 if register_payment(\%pay);
        return 0;
    }

    # not a gift.
    if ($custom{'for'} eq "") {
        my %pay;
        $pay{'user'} = $custom{'user'};
        $pay{'months'} = $custom{'months'}+0;
        $pay{'amount'} = $pp->{'payment_gross'};
        $pay{'datesent'} = $pp_to_sql_date->($pp->{'payment_date'});
        $pay{'what'} = $custom{'what'} eq "rename" ? "rename" : "account";  # one of (account, rename, gift)
        $pay{'method'} = "paypal";
        $pay{'notes'} = "PayPal Transaction ID: " . $pp->{'txn_id'};
        $pay{'unique_id'} = $pp->{'txn_id'};
        $pay{'error'} = $error;

        $pay{'search'} = {
            'ppemail' => $pp->{'payer_email'},
            'pptxnid' => $pp->{'txn_id'},
            'pplastname' => $pp->{'last_name'},
        };

        if (register_payment(\%pay)) { return 1; }
        return 0;
    }

    # gift:  process one payment for buyer and one for recipient.
    if ($custom{'for'}) {
        my $giftfor = $custom{'for'};
        my $buyer_ret;
        my $recipient_ret;
        my %pay;

        ## buyer's reciept.
        %pay = ();
        $pay{'user'} = $custom{'user'};
        $pay{'months'} = $LJ::GIVER_BONUS{$custom{'months'}}+0; # no months for buyer, unless specified
        $pay{'amount'} = $pp->{'payment_gross'};
        $pay{'datesent'} = $pp_to_sql_date->($pp->{'payment_date'});
        $pay{'what'} = "gift";  # one of (account, rename, gift)
        $pay{'method'} = "paypal";
        $pay{'notes'} = "PayPal Transaction ID: " . $pp->{'txn_id'} . "\nGift for $giftfor.";
        $pay{'unique_id'} = $pp->{'txn_id'} . "BUYER"; # must be unique (see below)
        $pay{'error'} = $error;
        $pay{'search'} = {
            'ppemail' => $pp->{'payer_email'},
            'pptxnid' => $pp->{'txn_id'},
            'pplastname' => $pp->{'last_name'},
        };
        $buyer_ret = register_payment(\%pay);

        ## recipient's reciept
        %pay = ();
        $pay{'giveafter'} = $custom{'giveafter'};
        $pay{'user'} = $giftfor;
        $pay{'months'} = $custom{'months'};
        $pay{'amount'} = 0; # recipient didn't pay
        $pay{'datesent'} = $pp_to_sql_date->($pp->{'payment_date'});
        $pay{'what'} = "account";  # one of (account, rename, gift)
        $pay{'method'} = "paypal";
        my $fromwho = $custom{'anon'} ? "(anonymous user)" : $custom{'user'};
        $pay{'notes'} = "PayPal Transaction ID: " . $pp->{'txn_id'} . "\nGift from: $fromwho.";
        $pay{'unique_id'} = $pp->{'txn_id'} . "RCPT"; # must be unique (see above)
        $pay{'error'} = $error;
        $pay{'search'} = {
            'ppemail' => $pp->{'payer_email'},
            'pptxnid' => $pp->{'txn_id'},
            'pplastname' => $pp->{'last_name'},
        };
        $recipient_ret = register_payment(\%pay);

        ## did they both succeed?
        return ($buyer_ret && $recipient_ret);
    }

}

sub verify_paypal_transaction
{
    my $hash = shift;
    my $opts = shift;

    my $ua = LWP::UserAgent->new(timeout => 6,
                                 agent => "LJ-PayPalAuth/0.1");

    # Create a request
    my @urls = ('https://www.paypal.com/cgi-bin/webscr?cmd=_notify-validate',
                'http://www.bradfitz.com/cgi-bin/paypalproxy.cgi');
    foreach my $url (@urls) {
        my $req = new HTTP::Request POST => $url;
        $req->content_type('application/x-www-form-urlencoded');
        $req->content(join("&", map { LJ::eurl($_) . "=" . LJ::eurl($hash->{$_}) } keys %$hash));
        
        # Pass request to the user agent and get a response back
        my $res = $ua->request($req);
        
        # Check the outcome of the response
        if ($res->is_success) {
            if ($res->content eq "VERIFIED") { return 1; }
            ${$opts->{'error'}} = "Invalid";
            return 0;
        }
    }
    ${$opts->{'error'}} = "Connection Problem";
    return 0;
}

sub LJ::Pay::load_cart {
    my $cart = shift;
    return undef unless $cart =~ /^(\d+)-(\d+)$/;
    my ($payid, $anum) = ($1, $2);
    my $dbh = LJ::get_db_writer();
    my $cartobj = $dbh->selectrow_hashref("SELECT * FROM payments ".
                                          "WHERE payid=$payid AND anum=$anum ".
                                          "AND forwhat='cart'");
    return undef unless $cartobj;
    $cartobj->{'items'} = [];
    my $sth = $dbh->prepare("SELECT * FROM payitems WHERE payid=$payid ORDER BY piid");
    $sth->execute;
    while (my $pi = $sth->fetchrow_hashref) {
        push @{$cartobj->{'items'}}, $pi;
    }
    return $cartobj;
}

sub LJ::Pay::new_cart {
    my $remote = shift;
    my $dbh = LJ::get_db_writer();
    my $anum = int(rand()*65536);
    my $userid = $remote ? $remote->{'userid'} : 0;
    $dbh->do("INSERT INTO payments (forwhat, anum, userid, datesent, used, mailed) ".
             "VALUES ('cart', $anum, $userid, NOW(), 'C', 'C')");
    my $payid = $dbh->{'mysql_insertid'};
    return undef unless $payid;
    LJ::Pay::payvar_append($payid, "creator_ip", LJ::get_remote_ip());
    return LJ::Pay::load_cart("$payid-$anum");
}

sub LJ::Pay::payvar_add {
    my ($payid, $k, $v) = @_;
    my $dbh = LJ::get_db_writer();
    LJ::Pay::payvar_append($payid, $k, $v)
        unless $dbh->selectrow_array("SELECT payid FROM payvars ".
                                     "WHERE payid=? AND pkey=? AND pval=?",
                                     undef, $payid, $k, $v);
}

sub LJ::Pay::payvar_append {
    my ($payid, $k, $v) = @_;
    my $dbh = LJ::get_db_writer();
    $dbh->do("INSERT INTO payvars (payid, pkey, pval) VALUES (?,?,?)",
             undef, $payid, $k, $v);
}

sub LJ::Pay::payvar_set {
    my ($payid, $k, $v) = @_;
    my $dbh = LJ::get_db_writer();
    $dbh->do("DELETE FROM payvars WHERE payid=? AND pkey=?", undef,
             $payid, $k);
    LJ::Pay::payvar_append($payid, $k, $v)
}

sub LJ::Pay::payid_set_state {
    my ($payid, $ctry, $st) = @_;
    return undef unless $payid;
    $ctry ||= "??";
    $st   ||= "??";

    my $str = $ctry;
    $str .= "-$st" if $ctry eq 'US';

    # if we don't know the state, we insert a literal "??" into the db
    my $dbh = LJ::get_db_writer();
    return $dbh->do("REPLACE INTO paystates (payid, state) VALUES (?,?)",
                    undef, $payid, $str);
}

sub LJ::Pay::check_country_state {
    my ($ctry, $st, $err) = @_;
    $ctry = uc($ctry); $st = uc($st);

    my (%country, %state);
    LJ::load_codes({ country => \%country,  # "us" => "United States"
                     state   => \%state });

    # validate given country
    unless ($country{$ctry}) {
        while (my ($key, $val) = each %country) {
            next unless $ctry eq uc($val); # "UNITED STATES" eq "UNITED STATES"
            $ctry = uc($key);              # "US"
        }
    }
    unless ($country{$ctry}) {
        $$err = "Invalid country: $ctry" if $ctry;
        return (undef, undef);
    }

    # don't handle non-US states right now
    return ($ctry, undef) unless $ctry eq 'US';

    # now, did they specify a state code or state name?
    $st = uc(LJ::trim($st));

    # full state name specified, get state code from that
    unless ($state{$st}) {
        while (my ($key, $val) = each %state) {
            next unless $st eq uc($val); # "OHIO" eq "OHIO"
            $st = uc($key);              # "US"
        }
    }
    unless ($state{$st}) {
        $$err = "Invalid US state: $st" if $st;
        return ($ctry, undef);
    }

    # now $st should be a state code
    return ($ctry, $st);
}

sub LJ::Pay::add_cart_item {
    my $cartobj = shift;
    my $item = shift;
    return LJ::error("no cart") unless $cartobj;
    my $dbh = LJ::get_db_writer();
    $dbh->do("INSERT INTO payitems (payid, status, item, subitem, qty, rcptid, amt, rcptemail, anon, giveafter, token, tokenid) ".
             "VALUES (?,?,?,?,?,?,?,?,?,?,?,?)", undef,
             $cartobj->{'payid'}, "cart",
             map { $item->{$_} } qw(item subitem qty rcptid amt rcptemail anon giveafter token tokenid));
    return LJ::error($dbh) if $dbh->err;

    my $piid = $dbh->{'mysql_insertid'};
    return LJ::error("Couldn't get piid") unless $piid;
    $item->{'piid'} = $piid;
    push @{$cartobj->{'items'}}, $item;
    LJ::Pay::update_cart_total($cartobj);

    return $item;
}

sub LJ::Pay::remove_cart_items {
    my $cartobj = shift;
    my @items = @_;
    return 0 unless $cartobj;
    return 1 unless @items;

    my @ids = map { (ref $_ eq "HASH" ? $_->{'piid'} : $_) + 0 } @items;
    my $in = join(',', @ids);
    my @cp_ids = map { $_->{tokenid}+0 } grep { ref $_ eq "HASH" && $_->{item} eq 'coupon' } @items;

    my $dbh = LJ::get_db_writer();

    # when removing a coupon from the cart, set the payid column back to NULL
    if (@cp_ids) {
        my $cp_in = join(',', @cp_ids);
        $dbh->do("UPDATE coupon SET payid=0 WHERE cpid IN ($cp_in)");
    }

    $dbh->do("DELETE FROM payitems WHERE piid IN ($in) AND payid=?",
             undef, $cartobj->{'payid'});

    # remove items from the cartobj
    @{$cartobj->{'items'}} = grep { my $id = $_->{'piid'}; ! grep { $id == $_ } @ids; } @{$cartobj->{'items'}};

    LJ::Pay::update_cart_total($cartobj);
    return 1;
}

sub LJ::Pay::update_shipping_cost {
    my ($cartobj, $country) = @_;
    return 0 unless $cartobj;

    # should only have one shipping cost line
    my @shipi = grep { $_->{'item'} eq "shipping" } @{$cartobj->{'items'}};
    my $shipi;

    # figure out shipping cost ($5, $3, $5, $3....)
    my $ship_cost = 0;
    my $last = 0;
    foreach (grep { $_->{'item'} eq "clothes" } @{$cartobj->{'items'}}) {
        my $this_cost = 5;
        $this_cost = 3 if $last == 5;
        $ship_cost += $this_cost;
        $last = $this_cost;
    }

    # shipping on clothing only if outside US/Canada/Territories and order amt is non-zero
    if ((grep { $_->{'item'} eq "clothes" } @{$cartobj->{'items'}}) &&
        $country ne "US" && # United States
        $country ne "CA" && # Canada
        $country ne "PR" && # Puerto Rico
        $country ne "GU")   # Guam
    {
        # get the first one, or make one
        $shipi = shift @shipi;
        unless ($shipi) {
            $shipi = {
                'item' => 'shipping',
                'rcptid' => 0,
                'amt' => $ship_cost,
            };
            die "Couldn't add shipping cost" unless 
                LJ::Pay::add_cart_item($cartobj, $shipi);
        }
    }

    # delete extra shipping items
    LJ::Pay::remove_cart_items($cartobj, @shipi) if @shipi;

    # update shipping cost, if they're subject to shipping
    if ($shipi && $shipi->{'amt'} != $ship_cost) {
        $shipi->{'amt'} = $ship_cost;
        my $dbh = LJ::get_db_writer();
        $dbh->do("UPDATE payitem SET amt=? WHERE piid=?", undef,
                 $ship_cost, $shipi->{'piid'});
        LJ::Pay::update_cart_total($cartobj);
    }
    
    return 1;
}

sub LJ::Pay::is_tangible {
    my $it = shift;
    return ($it->{'item'} eq 'clothes' || $it->{'item'} eq 'coupon');
}


# takes in a cart object and returns the following hash keys/values:
#
# adj_amt_tot: total adjusted price of cart after coupons are applied
# adj_amt_int: total adjusted price of intangible items in cart after coupons are applied
# adj_amt_tan: total adjusted price of tangible items in cart after coupons are applied
# adj_amt_cp:  total adjusted price of coupons being _purchased_ after coupons are applied
#
# cart_amt_tot: total unadjusted price of cart before coupons are applied
# cart_amt_int: total unadjusted price of intangible items in cart before coupons are applied
# cart_amt_tan: total unadjusted price of tangible items in cart before coupons are applied
# cart_amt_cp: total unadjusted price of coupons being _purchased_ before coupons are applied
#
# cp_amt_tot: total dollar amount of coupons in the cart (all types)
# cp_amt_gen: total dollar amount of general (universal) coupons in cart
# cp_amt_int: total dollar amount of intangible-only coupons in cart
# cp_amt_tan: total dollar amount of tangible-only coupons in cart
#
# cp_used_tot: total dollar amount of used coupons of all types
# cp_used_gen: total dollar amount of general (universal) coupons applied to cart
# cp_used_int: total dollar amount of intangible-only coupons applied to cart
# cp_used_tan: total dollar amount of tangible-only coupons applied to cart
# 
# cp_unused_tot: total dollar amount of unused coupons of all types
# cp_unused_gen: total dollar amount of general (universal) coupons unused
# cp_unused_int: total dollar amount of unused intangible-only coupons in cart
# cp_unused_tan: total dollar amount of unused tangible-only coupons in cart
#    
sub LJ::Pay::coupon_reduce {
    my $cartobj = shift;

    # types for the following hashes:
    # - tot: total amount for all item types
    # - gen: general (universal) amount
    # - tan: tangible-only amount
    # - int: intangible-only amount

    my %cp_amt    = (); # type => total coupon amount of this type
    my %cp_unused = (); # type => total coupon amount unused of this type
    my %cp_used   = (); # type => total coupon amount used of this type

    # types for the following hashes:
    # - tot: total amount of all item types
    # - tan: tangible item amount
    # - int: intangible item amount
    # - cp: coupons the user is buying

    my %cart_amt  = (); # type => total amount in cart of this type
    my %adj_amt   = (); # type => adjusted cart amount of this type after coupons applied 

    foreach my $it (@{$cartobj->{'items'}}) {

        # item being purchased
        if ($it->{amt} > 0) {

            my $type = LJ::Pay::is_tangible($it) ? 'tan' : 'int';

            # NOTE: if the user is buying a coupon with a positive dollar amount, then it is a 
            # general coupon that can be used to buy anything.  we can't apply any coupons to 
            # other coupon prices or else we open up a hole by which users can transcent their
            # tangible/intangible limitations for free.  bleh.
            $type = 'cp' if $it->{item} eq 'coupon';

            # add to purchase total for this type
            $cart_amt{$type} += $it->{amt};

            # also update total cart amount
            $cart_amt{tot} += $it->{amt};

        # applying a coupon given to them
        } elsif ($it->{item} eq "coupon") {

            # keep a tally of total amount of coupons being used
            # on this order (NOT purchased via this order)
            if ($it->{subitem} =~ /^dollaroff(tan|int)?/) {
                $cp_amt{$1 || 'gen'} += abs($it->{amt});
                $cp_amt{tot} += abs($it->{amt});

            # otherwise could be a 'freeclothingitem' coupon type
            # -- just treat this as a tangible coupon and it will be
            #    handled properly
            } elsif ($it->{subitem} =~ /^freeclothingitem/) {
                $cp_amt{tan} += abs($it->{amt});
            }
        }
    }

    # coupons being _purchased_ don't get adjusted, but for the sake of uniformity,
    # we'll go ahead and add a key for their 'adjusted price' and set it the same as
    # their total
    $adj_amt{cp} = $cart_amt{cp};

    # 1) apply coupons applying to items of each type
    #    - how much coupon was unused?
    #    - how much still needs to be paid for?
    foreach my $type (qw(tan int)) {

        # assume we'll use all of it and correct later
        $adj_amt{$type} = $cart_amt{$type} - $cp_amt{$type};
        $cp_unused{$type} = 0;

        # if less than 0, we used too much, so decide how much was unused
        if ($adj_amt{$type} < 0) {
            $cp_unused{$type} = abs($adj_amt{$type}); # unused coupons of this type
            $adj_amt{$type} = 0;                      # adjusted amount is 0
        }
    }

    # 2) if we have general purpose coupons and there are balances
    #    left, apply those to the adjusted amounts now
    $cp_unused{gen} = $cp_amt{gen}; # haven't used any general coupons yet
    foreach my $type (qw(tan int)) {

        # assume we'll use all of it and correct later
        $adj_amt{$type} -= $cp_unused{gen};
        $cp_unused{gen} = 0;

        # if less than 0, we used too much, so decide how much was unused
        if ($adj_amt{$type} < 0) {
            $cp_unused{gen} = abs($adj_amt{$type}); # unused general coupons
            $adj_amt{$type} = 0;                    # adjusted amount is 0
        }

    }

    # fill in how much was used
    %cp_used = map { $_ => $cp_amt{$_} - $cp_unused{$_} } qw(gen tan int);

    # total (gen) adjusted amount is total cart amount - sum(all coupons used)
    $adj_amt{tot} = $cart_amt{tot};
    $adj_amt{tot} -= $cp_used{$_} foreach qw(gen tan int);

    # total coupon usage
    $cp_used{tot} = $cart_amt{tot} - $adj_amt{tot};
    $cp_unused{tot} = $cp_amt{tot} - $cp_used{tot};
    
    return {

        # adjusted amounts
        (map { ("adj_amt_$_" => $adj_amt{$_}+0) } qw(tot cp tan int)),

        # cart totals for different cateogires
        (map { ("cart_amt_$_" => $cart_amt{$_}+0) } qw(tot cp tan int)),

        # total acoupon amounts in cart
        (map { ("cp_amt_$_" => $cp_amt{$_}+0) } qw(tot gen tan int)),

        # coupon amounts used
        (map { ("cp_used_$_" => $cp_used{$_}+0) } qw(tot gen tan int)),

        # coupon amounts unused
        (map { ("cp_unused_$_" => $cp_unused{$_}+0) } qw(tot gen tan int)),
    };
}

sub LJ::Pay::send_coupon_email {
    my ($u, $token, $amt, $type) = @_;
    return undef unless $u && $token && defined $amt;
    my $email = ref $u ? $u->{'email'} : $u;
    return undef unless $email;

    my $inttxt;
    if ($type eq 'int') {
        $inttxt .= "This coupon is only valid for intangible items such as paid accounts ";
        $inttxt .= "and bonus features.  It cannot be used to buy other coupons or to ";
        $inttxt .= "buy clothing.\n\n";
    } elsif ($type eq 'tan') {
        $inttxt .= "This coupon is only valid for tangible items such as tee shirts and ";
        $inttxt .= "hoodies.  It cannot be used to buy other coupons or intangible items ";
        $inttxt .= "such as paid accounts.\n\n";
    }

    my $storetxt;
    unless ($type eq 'int') {
        $storetxt .= "$LJ::SITENAMESHORT store:\n";
        $storetxt .= "   - $LJ::SITEROOT/store/\n\n";
    }

    # print dollars
    my $damt = sub { sprintf("\$%.02f", shift()) };

    return LJ::send_mail({
        'to' => $email,
        'from' => $LJ::ACCOUNTS_EMAIL,
        'fromname' => $LJ::SITENAMESHORT,
        'wrap' => 1,
        'charset' => 'utf-8',
        'subject' => "Coupon",
        'body' => 
            "$LJ::SITENAMESHORT coupon code:\n\n".
            "   $token\n\n".

            # possibly a notice saying this is an intangible coupon
            $inttxt .

            "You can redeem it for " . $damt->($amt) . " USD in $LJ::SITENAMESHORT " .
            "merchandise and/or services:\n\n".

            "$LJ::SITENAMESHORT services:\n" .
            "   - $LJ::SITEROOT/pay/\n\n" .

            $storetxt .

            "NOTE: Your coupon is only valid for one use, so be sure that your order's " .
            "value is greater than or equal to " . $damt->($amt) . " USD.\n\n" .

            "$LJ::SITENAMESHORT Team",
    });
}

# somewhat generic function, but for now it just sets allow_pay once we have received a
# valid payment from a user... so they don't run into open proxy + etc restrictions later
sub LJ::Pay::note_payment_from_user {
    my $u = shift;
    return undef unless LJ::isu($u);

    # need to load the userprop unless it exists
    unless (exists $u->{allow_pay}) {
        LJ::load_user_props($u, 'allow_pay')
            or return undef;;
    }

    # nothing to do if allow_pay is already set
    return 1 if $u->{allow_pay} eq 'Y';

    # set allow_pay on this user if necessary
    if (LJ::set_userprop($u, 'allow_pay', 'Y')) {

        # log to statushistory
        my $sys_id = LJ::get_userid('system');
        LJ::statushistory_add($u, $sys_id, "allow_pay", "automatically allowing payments after successful transaction");

        # successfully set
        return 1;
    }

    # error setting userprop above
    return undef;
}

sub LJ::Pay::send_fraud_email {
    my ($cartobj, $u) = @_;
    return undef unless $cartobj;

    # assure $u is valid with 'fraud_watch' loaded,
    # or undef if the cart has no rcptid
    if ($cartobj->{userid}) {
        $u ||= LJ::load_userid($cartobj->{userid});

        LJ::load_user_props($u, 'fraud_watch')
            unless $u && exists $u->{fraud_watch};

    } else {
        undef $u;
    }

    # find items in cart, then load userids for items which have rcptids
    my @items = @{$cartobj->{items}||[]};
    my $ru = LJ::load_userids(map { $_->{rcptid} } grep { $_->{rcptid} } @items);

    # build array of fraud-watched recipient user objects and the items they are purchasing
    my @fraud_rcpt = ();
    foreach my $it (@items) {
        my $ruobj = $ru->{$it->{rcptid}} or next;

        LJ::load_user_props($ruobj, 'fraud_watch');
        push @fraud_rcpt, [$it, $ruobj] if $ruobj->{fraud_watch};
    }

    # if there's anything to mail, do it now
    if (my $u_watch = $u && $u->{fraud_watch} or @fraud_rcpt) {

        # if there are recipients on fraud watch, make a list of
        # their usernames and what they're trying to buy
        my $rcpt_txt = "";
        if (@fraud_rcpt) {
            $rcpt_txt .= "Cart recipient information: (only users with active fraud watches)\n\n";
            foreach (@fraud_rcpt) {
                my ($it, $fu) = @$_;
                $rcpt_txt .= "        User: $fu->{user}\n";
                $rcpt_txt .= "        Item: " . LJ::Pay::product_name($it) . "\n\n";
            }
        }

        LJ::send_mail({
            'to' => $LJ::ACCOUNTS_EMAIL,
            'from' => $LJ::ACCOUNTS_EMAIL,
            'wrap' => 1,
            'charset' => 'utf-8',
            'subject' => "Fraud alert: Payment #$cartobj->{payid}",
            'body' => "This warning has been sent because a payment transaction has been " .
                      "processed on $LJ::SITENAMESHORT.  One or more of the users involved " .
                      "with this payment are on a fraud watch.\n\n" .
                    
                      "For full information about this payment, see the link below:\n\n" .
                    
                      "    $LJ::SITEROOT/admin/accounts/paiddetails.bml?payid=$cartobj->{payid}\n\n" .

                      "Cart owner information:\n\n" .

                      "        User: " . ($u ? $u->{user} : $cartobj->{rcptemail}) . "\n" .
                      "       Watch: " . ($u_watch ? "yes" : "no") . "\n" .
                      "       Payid: $cartobj->{'payid'}\n" .
                      "        Time: " . LJ::mysql_time() . "\n\n" .
                    
                      $rcpt_txt,

        }) or return undef;
    }

    return 1;
}

sub LJ::Pay::update_cart_total {
    my $cartobj = shift;
    return 0 unless $cartobj;
    my $dbh = LJ::get_db_writer();

    # clothing piids which have been coupon'ed already
    my %free_clothes;

    foreach my $it (@{$cartobj->{'items'}}) {
        next unless $it->{'item'} eq "coupon";
        my ($type, $arg) = split(/-/, $it->{'subitem'});
        next unless $type eq "freeclothingitem";

        my $amt = 0;

        # find most expensive item of clothing that
        # hasn't been given free already
        my ($max, $maxid);
        foreach my $clit (@{$cartobj->{'items'}}) {
            next unless $clit->{'item'} eq "clothes";
            next if $free_clothes{$clit->{'piid'}};
            next if $clit->{'amt'} < $max;

            # check to see if this product type is flagged as not
            # being valid for free clothing items
            my $cltype = (split("-", $clit->{'subitem'}))[0];
            next if $LJ::Pay::product{"clothes-$cltype"}->[2];

            $max = $clit->{'amt'};
            $maxid = $clit->{'piid'};
        }
        if ($max) {
            $amt = $max;
            $free_clothes{$maxid} = 1;
        }
        
        # remove zero dollar coupons from cart
        if ($amt == 0) {
            $dbh->do("DELETE FROM payitems WHERE piid=?", undef, $it->{'piid'});
            next;
        }

        if ($amt != $it->{'amt'}) {
            $it->{'amt'} = -$amt;
            $dbh->do("UPDATE payitems SET amt=? WHERE piid=?", undef, $it->{'amt'}, $it->{'piid'});
        }
    }

    # analyze cart items to find total amounts
    my $amts = LJ::Pay::coupon_reduce($cartobj);

    # update payments with adjusted price of cart after coupons are applied
    $dbh->do("UPDATE payments SET amount=? WHERE payid=? AND mailed='C' AND forwhat='cart'",
             undef, $amts->{'adj_amt_tot'}, $cartobj->{'payid'});
    return 1;
}

sub LJ::Pay::can_mod_cart {
    my $cartobj = shift;
    return 0 unless $cartobj;
    return 0 if $cartobj->{method};
    return 1;
}

sub LJ::Pay::can_checkout_cart {
    my $cartobj = shift;
    return 0 unless $cartobj;
    return 0 unless $cartobj->{mailed} eq 'C';
    return 0 unless @{$cartobj->{items}};
    return 1;
}

sub LJ::Pay::cart_contains_coppa {
    my $cartobj = shift;
    return 0 unless $cartobj && @{$cartobj->{items}};
    return scalar grep { $_->{item} eq 'coppa' } @{$cartobj->{items}};
}

sub LJ::Pay::cart_needs_shipping {
    my $cartobj = shift;
    return 0 unless $cartobj && @{$cartobj->{'items'}};
    return scalar grep { LJ::Pay::item_needs_shipping($_) } @{$cartobj->{'items'}};
}

sub LJ::Pay::item_needs_shipping {
    return ($_[0]->{'item'} eq "clothes");
}

sub LJ::Pay::reserve_items {
    my $cartobj = shift;
    my $out_list = shift;  # listref to push out of stock product names onto
    die "Can't reserve items in undef cart.\n" unless $cartobj;
    my @prods = grep { $_->{'item'} eq "clothes" } @{$cartobj->{'items'}};
    return 1 unless @prods;
    
    my $dbh = LJ::get_db_writer();

    my %need;
    foreach my $pr (@prods) {
        next if $pr->{'qty_res'} >= $pr->{'qty'};
        my $pkey = "$pr->{'item'}-$pr->{'subitem'}";

        $need{$pkey}->{'count'} += $pr->{'qty'} - $pr->{'qty_res'};
        push @{$need{$pkey}->{'items'}}, $pr;
        $need{$pkey}->{'item'} = $pr->{'item'};
        $need{$pkey}->{'subitem'} = $pr->{'subitem'};
    }

    foreach my $pr (keys %need) {
        my $n = $need{$pr};
        my $avail = $dbh->selectrow_array("SELECT avail FROM inventory WHERE item=? AND subitem=?",
                                          undef, $n->{'item'}, $n->{'subitem'});
        next if $avail >= $n->{'count'};
        push @$out_list, LJ::Pay::product_name($n->{'item'}, $n->{'subitem'});
    }

    # fail if items were out of stock
    return 0 if @$out_list;

    # reserve items if they're in stock (yes, this is racy, but that's
    # the least of the hellish inventory management problems)
    foreach my $pr (keys %need) {
        my $n = $need{$pr};
        $dbh->do("UPDATE inventory SET avail=avail-? WHERE item=? AND subitem=?",
                 undef, $n->{'count'}, $n->{'item'}, $n->{'subitem'});
        foreach my $it (@{$n->{'items'}}) {
            $dbh->do("UPDATE payitems SET qty_res=qty WHERE piid=? AND payid=?",
                     undef, $it->{'piid'}, $it->{'payid'});
        }
    }
    return 1;
}

sub LJ::Pay::product_name {
    # @_: item, subitem, qty, short?

    my $item = shift;
    my ($subitem, $qty, $short) = @_;

    # case 1: $it, $short
    if (ref $item eq 'HASH') {
        # allow 'subitem' or size key so that we can pass either
        # a row from payitems or a row from paidexp with the "short" flag
	$subitem = $item->{'subitem'} || $item->{'size'};
	$qty = $item->{'qty'};
	$item = $item->{'item'};
        $short = shift;
    }
    # otherwise, case 2: $item, $subitem, $qty, $short?

    # now we should have all the right vars

    if ($item eq "clothes") {
        my ($type, $color, $size) = split(/-/, $subitem);
        return join(' ',
                    $LJ::Pay::size{$size}->[1],
                    $LJ::Pay::color{$color},
                    $LJ::Pay::product{"clothes-$type"}->[0]);
    }

    if ($item eq "paidacct") {
	return "Paid Account" . ($short ? "" : " - $LJ::Pay::account{$qty}->{'name'}");
    }

    if ($item eq "perm") {
	return "Permanent Account";
    }

    if ($item eq "rename") {
	return "Rename Token";
    }

    if ($item eq "coppa") {
        return "Age Verification (for COPPA)";
    }

    if ($item eq "coupon") {
        my ($type) = split(/-/, $subitem);
        if ($type eq "freeclothingitem") {
            return "Free clothing item";
        }
        if ($type =~ /^dollaroff(int|tan)?/) {
            return "Coupon" . ($1 ? ($1 eq 'tan' ? ", tangible" : ", intangible") : "");
        }
    }

    if (LJ::Pay::is_bonus($item, 'bool')) {
	my $bitem = $LJ::Pay::bonus{$item};
        return $bitem->{'name'} . ($short ? "" : (" - " . ($bitem->{'items'}->{$qty}->{'name'} || $qty)));
    }

    if (LJ::Pay::is_bonus($item, 'sized')) {
        my $bitem = $LJ::Pay::bonus{$item};

        my $size = (split("-", $subitem))[0];
        my $sizeit = $bitem->{'items'}->{$size};
        my $qtyit = $sizeit->{'qty'}->{$qty};

        return ($sizeit->{'name'} || $size) . " " . $bitem->{'name'} .
            ($short ? "" : (" - " . ($sizeit->{'qty'}->{$qty}->{'name'} || $qty)));
    }

    return "$item-$subitem";
}

# there was a race condition when 'pay_updateaccounts' and 'expiring' ran at the same time,
# so now we get a lock and re-verify our data afterwards; closures to make things simple
sub LJ::Pay::get_lock {
    my $u = shift;
    my $userid = LJ::want_userid($u);
    return undef unless $userid;

    my $key = "acctupdate:$userid";
    my $dbh = LJ::get_db_writer();
    return LJ::get_lock($dbh, "global", $key);
};

sub LJ::Pay::release_lock {
    my $u = shift;
    my $userid = LJ::want_userid($u);
    return undef unless $userid;

    my $dbh = LJ::get_db_writer();
    my $key = "acctupdate:$userid";
    return LJ::release_lock($dbh, "global", $key);
};

# is the given item a paidaccount add-on?
# thereby requiring checks for paid account existence?
sub LJ::Pay::is_bonus {
    my ($it, $type) = @_;
    my $item = ref $it eq 'HASH' ? $it->{'item'} : $it;
    return undef unless defined $LJ::Pay::bonus{$item};
    return undef if $type && $LJ::Pay::bonus{$item}->{'type'} ne $type;
    return 1;
};

# given a cart can we add a given item?
sub LJ::Pay::can_apply_sized_bonus {
    my ($u, $cartobj, $item, $size, $qty) = @_;
    my $userid = LJ::want_userid($u);

    # easy/obvious checks
    return undef unless $userid && LJ::Pay::is_bonus($item, 'sized');

    # if the caller doesn't specify a qty they are trying to add, just
    # validate items already in the cart
    $qty ||= 0;

    # is there immediately applying paid time in the cart?
    my $cart_paid_immed = undef;

    # now go through the current cart and see what they have already
    if ($cartobj) {

        # will be used for checks later on "dimension signature"
        my ($prev_exp, $prev_size) = LJ::Pay::get_bonus_dim($userid, $item);

        foreach my $it (@{$cartobj->{'items'}}) {
            next unless $it->{'rcptid'} == $userid;

            # collect information on when paid account starts in this cart
            $cart_paid_immed = 1
                if $it->{'item'} eq 'paidacct' && ! $it->{'giveafter'};

            next unless $it->{'item'} eq $item;

            # can't have a giveafter date on sized items
            return undef if $it->{'giveafter'};

            # subitem field contains a few useful bits of info
            my ($itsize, $curr_exp, $curr_size) = split("-", $it->{'subitem'});

            # if no size specified, then just verify that all sizes in the cart are equal
            $size ||= $itsize;
            
            # can buy multiple items, but only of the same size
            return undef if $itsize != $size;

            # when applying sized bonus, we have to make sure that no other sized bonus features have been
            # applied since this one was added to the cart, so check the previous "dimension signature"
            # to decide if this item can be legally applied
            return undef unless $prev_exp == $curr_exp && $prev_size == $curr_size;

            # this is an extension to something already in the cart
            $qty += $it->{'qty'};

            # can't have more than 12 months in cart
            return undef if $qty > 12;
        }
    }

    # now time to run some checks on the database
    my $dbh = LJ::get_db_writer();

    # if no paid account in cart starting immediately, check in the database 
    # to see if there is currently paid time there
    unless ($cart_paid_immed) {

        # sometimes users have the paid cap with no paiduser row in the database, eg when
        # they have a permanent account ... assume if they have a perm account then
        # they are paid forever
        unless ($dbh->selectrow_array("SELECT COUNT(*) FROM paiduser WHERE userid=? AND paiduntil>NOW()", undef, $userid)) {

            # if the query above failed, check to see if they have the paid cap
            $u = LJ::want_user($u);
            return undef unless $u && $u->{'caps'} & (1 << $LJ::Pay::capinf{'perm'}->{'bit'});
        }
    }

    # now let's see what's in the database, with regards to this bonus item
    my $row = $dbh->selectrow_hashref("SELECT *, " .
                                      "(NOW() + INTERVAL ? MONTH <= expdate) AS 'is_short', " .
                                      "(IF(size=?, expdate, NOW()) + INTERVAL ? MONTH > NOW() + INTERVAL 12 MONTH) AS 'is_long' " .
                                      "FROM paidexp WHERE userid=? AND item=?", undef, $qty, $size, $qty, $userid, $item);

    # if nothing in database, the checks we've already done are sufficient
    return 1 unless $row;

    # now we know there was a $row in the db

    # can't apply if they already have stored, therefore presumably no paid account?
    return undef if $row->{'daysleft'};

    # can't apply if expiration date won't extend past that of their current time
    # unless the size is the same as their current size
    return undef if $row->{'is_short'} && $row->{'size'} != $size;

    # can't apply more than one year in the future
    return undef if $row->{'is_long'};

    # can't downgrade to a lower size
    return undef if $size < $row->{'size'};

    return 1;
};

sub LJ::Pay::can_apply_bool_bonus {
    my ($u, $cartobj, $item) = @_;
    my $userid = LJ::want_userid($u);

    # easy/obvious checks
    return undef unless $userid && LJ::Pay::is_bonus($item, 'bool');

    # when does paid time in the cart begin?
    my $cart_paid_start = undef;
    my $cart_bonus_start = undef;

    if ($cartobj) {

        # check the cart to see if we can immediately exonerate this bonus feature
        # without even looking in the database.
        foreach my $it (@{$cartobj->{'items'}}) {
            next unless $it->{'rcptid'} == $userid;

            # can't buy bool bonus features for permanent accounts
            return undef if $it->{'item'} eq 'perm';

            # calculate starting time of first applying amount of paid time in the cart
            if ($it->{'item'} eq 'paidacct') {

                if ($it->{'giveafter'}) {
                    $cart_paid_start = $it->{'giveafter'} if ! defined $cart_paid_start || $it->{'giveafter'} < $cart_paid_start;
                    next;
                }

                # no giveafter time, applies immediately
                $cart_paid_start = 0;
                next;
            }

            # calculate starting time of this bonus item
            if ($it->{'item'} eq $item) {

                if ($it->{'giveafter'}) {
                    $cart_bonus_start = $it->{'giveafter'} if ! defined $cart_bonus_start || $it->{'giveafter'} < $cart_bonus_start;
                    next;
                }

                # no giveafter time, applies immediately
                $cart_bonus_start = 0;
                next;
            }
        }

        # immediately applying paid account == we're in the clear
        # - note that undef == 0 returns true since undef gets converted to numeric 
        #   context (0) before the comparison is done, blah perl
        return 1 if defined $cart_paid_start && $cart_paid_start == 0;
        return 1 if defined $cart_bonus_start && defined $cart_paid_start &&
                    $cart_bonus_start >= $cart_paid_start;
    }

    # is the specified userid a permanent account?  if so there's a problem
    $u = LJ::load_userid($userid, "force");
    return undef if ! $u || $u->{'caps'} & (1 << $LJ::Pay::capinf{'perm'}->{'bit'});

    # can be applied if they have a currently unexpired paid account
    my $dbh = LJ::get_db_writer();
    my $paiduntil = $dbh->selectrow_array("SELECT UNIX_TIMESTAMP(paiduntil) FROM paiduser WHERE userid=? AND paiduntil>NOW()",
                                          undef, $userid);

    # at this point we know that paid time in the cart doesn't immediately
    # exonerate the bonus feature, because we would have returned already
    return undef if ! $paiduntil || $paiduntil < $cart_bonus_start;

    # everything checked out
    return 1;
}

# get dimensions of current sized bonus block
sub LJ::Pay::get_bonus_dim {
    my ($u, $itemname) = @_;
    my $userid = LJ::want_userid($u);
    return undef unless $userid;

    my $dbh = LJ::get_db_writer();
    my ($exptime, $size) = $dbh->selectrow_array("SELECT UNIX_TIMESTAMP(expdate), size " .
                                                 "FROM paidexp WHERE userid=? AND item=?",
                                                 undef, $userid, $itemname);
    return ($exptime || 0, $size || 0);
}

# upgrade or extend the length of a bonus item
sub LJ::Pay::apply_bonus_item {
    my ($u, $item, $subitem, $qty, $payid) = @_;

    # allow u/payitem objects passed optionally
    my $userid = LJ::want_userid($u);
    if (ref $item) {
        $subitem = $item->{'subitem'};
        $qty = $item->{'qty'};
        $payid = $item->{'payid'};
        $item = $item->{'item'};
    }

    # userid and item are required regardless of bonus feature type
    return undef unless $userid && $item;
    
    my $dbh = LJ::get_db_writer();

    # does an existing paidexp row exist?
    my $exp = $dbh->selectrow_hashref("SELECT userid, item, size, expdate, daysleft, " .
                                      "UNIX_TIMESTAMP(expdate) AS 'exptime', " .
                                      "(expdate > NOW()) AS 'unexpired' " .
                                      "FROM paidexp WHERE userid=? AND item=?",
                                      undef, $userid, $item);

    # if no row in database, fill in $exp with good values
    $exp ||= {
        'userid' => $userid,
        'item' => $item,
        'size' => 0,
        'expdate' => undef,
        'daysleft' => 0,
        'exptime' => 0,
        'unexpired' => 0,
    };

    my $new_size = $exp->{'size'};

    # activate cap if necessary
    if (my $cap = $LJ::Pay::bonus{$item}->{'cap'}) {
        LJ::modify_caps($userid, [$cap], [])
            or return undef;
    }

    # actions for 'sized' bonus feature type
    # -- need to check that account is still in size/exp state it was in
    #    when this item was purchased so people can't be comp'd more than
    #    once for existing paid time on upgrades

    my $sized_upgrade = 0;

    if (LJ::Pay::is_bonus($item, 'sized')) {
        return undef unless $subitem;

        # make sure exp/size signature in subitem still matches
        my ($it_size, $old_exptime, $old_size) = split("-", $subitem);

        # if a payid is passed, then first check to make sure that no other payitems
        # in this cart have been applied, altering the exp/size signature and making
        # this check return false-positives

        unless ($payid &&
                $dbh->selectrow_array("SELECT COUNT(*) FROM payitems " .
                                      "WHERE payid=? AND item=? AND subitem=? AND status='done'",
                                      undef, $payid, $item, $subitem))
        {

            # zero-fill
            $old_exptime ||= 0;
            $old_size ||= 0;

            # check for exptime/size mismatch, now that we know it's necessary
            unless ($old_exptime == $exp->{'exptime'} && $old_size == $exp->{'size'}) {

                # all bonus items of this type have the same size and exptime/oldsize signature
                # by the rules applied to them when they entered the cart.
                #
                # so if one item fails, we go ahead and mark them all as having failed.
                # the caller (pay.pl) will have to be smart enough to know to not try to process
                # subsequent items of the failed bonus type

                LJ::statushistory_add($userid, undef, 'pay_modify',
                                      "ERROR: cannot apply bonus feature: $item, " .
                                      "${old_exptime}x${old_size} != $exp->{'exptime'}x$exp->{'size'}");

                $dbh->do("UPDATE payitems SET status='done' WHERE payid=? AND item=? AND subitem=?",
                         undef, $payid, $item, $subitem);

                return undef;
            }
        }

        # could either be upgrade or extension, but either way we adopt the item's size
        $new_size = $it_size;

        # means that we are upgrading a sized bonus item, so the time added should start
        # from now, not the current expdate
        $sized_upgrade = 1 unless $old_size == $new_size;
    }

    # insert a new row, or add time to old one
    # - this code somewhat duplicates functionality from LJ::Pay::activate_frozen_bonus
    #   but we need to extend the expdate by $qty months anyway, so we'll just do the
    #   daysleft activation here as well, avoiding some queries
    {
        # expdate calculation is tricky
        # [(expdate || NOW()) + INTERVAL $qty MONTH] + INTERVAL $daysleft DAY

        # expiration extends off current expdate if there's a currently unexpired item of
        # the same size.  otherwise it's an upgrade and starts from NOW()
        my $expdate = $exp->{'unexpired'} && ! $sized_upgrade
            ? $dbh->quote($exp->{'expdate'}) : "NOW()";

        if ($qty) {
            my $qqty = $dbh->quote($qty || 0);
            $expdate = "($expdate + INTERVAL $qqty MONTH)";
        }
        if ($exp->{'daysleft'}) {
            my $qdaysleft = $dbh->quote($exp->{'daysleft'});
            $expdate = "($expdate + INTERVAL $qdaysleft DAY)";
        }

        # update / insert paidexp row
        $dbh->do("REPLACE INTO paidexp (userid, item, size, expdate, daysleft) " .
                 "VALUES (?, ?, ?, $expdate, 0)", undef, $userid, $item, $new_size);
        return undef if $dbh->err;
    }

    # call any application hooks for this bonus feature
    my $apply_hook = $LJ::Pay::bonus{$item}->{'apply_hook'};
    if ($apply_hook && ref $apply_hook eq 'CODE') {
        # apply_hook needs a real $u object
        $u = ref $u ? $u : LJ::load_userid($u);
        $apply_hook->($u, $item);
    }

    # log this bonus feature activation
    {
        my $msg = "adding bonus feature: item=$item; ";
        if (LJ::Pay::is_bonus($item, 'sized')) {
            $msg .= "size=$exp->{'size'}";
            $msg .= "=>$new_size" if $exp->{'size'} != $new_size;
            $msg .= "; ";
        }
        $msg .= "old_expdate=$exp->{'expdate'}; applying $qty months, $exp->{'daysleft'} existing days";

        LJ::statushistory_add($userid, undef, 'pay_modify', $msg);
    }

    return 1;
}

sub LJ::Pay::expire_bonus {
    my ($u, $item) = @_;

    # allow u/payitem objects passed optionally
    my $userid = LJ::want_userid($u);
    $item = $item->{'item'} if ref $item;
    return undef unless $userid;
    
    my $dbh = LJ::get_db_writer();

    # we can either operate on one given item or all items for a user
    my $itemand = (" AND item=" . $dbh->quote($item)) if $item;

    # hard-validate constraints on the paidexp table in here
    # - this is probably done by the caller too, but outside of a lock
    my $sth = $dbh->prepare("SELECT item FROM paidexp WHERE userid=?$itemand " .
                            "AND (daysleft=0 OR daysleft IS NULL) " .
                            "AND expdate < NOW() AND expdate > '0000-00-00'");
    $sth->execute($userid);
    my @activated = ();
    while (my ($item) = $sth->fetchrow_array) {
        next unless LJ::Pay::is_bonus($item);

        # remove cap if there's one associated with this bonus item
        if (my $cap = $LJ::Pay::bonus{$item}->{'cap'}) {
            LJ::modify_caps($userid, [], [$cap])
                or return undef;
        }

        # remove paidexp row
        $dbh->do("DELETE FROM paidexp WHERE userid=? AND item=?", undef, $userid, $item);

        # log this bonus feature expiration
        LJ::statushistory_add($u, undef, 'pay_modify', "expiring bonus feature: $item");
    }

    return 1;
}

# activates frozen bonus features
# - returns array of hashrefs: { item => { itemname, size, days_activated }
sub LJ::Pay::activate_frozen_bonus {
    my ($u, $item) = @_; # item is optional

    # allow u/payitem objects passed optionally
    my $userid = LJ::want_userid($u);
    $item = $item->{'item'} if ref $item;
    return undef unless $userid;
    
    my $dbh = LJ::get_db_writer();

    # we can either operate on one given item or all items for a user
    my $itemand = (" AND item=" . $dbh->quote($item)) if $item;

    # see if there is existing time
    my $sth = $dbh->prepare("SELECT item, size, expdate, daysleft, (expdate > NOW()) AS 'unexpired' " .
                            "FROM paidexp WHERE daysleft>0 AND userid=?$itemand");
    $sth->execute($userid);
    my @activated = ();
    while (my ($item, $size, $expdate, $daysleft, $unexpired) = $sth->fetchrow_array) {
        next unless LJ::Pay::is_bonus($item);

        # it would generally suffice to set expdate to NOW() + INTERVAL daysleft DAY, but to be more
        # robust we want to handle the case where there are daysleft in the db, but the item isn't
        # expired yet
        my $base = $unexpired ? $dbh->quote($expdate) : "NOW()";

        # update database if we found some (need select above to fetch daysleft)
        $dbh->do("UPDATE paidexp SET expdate=($base + INTERVAL ? DAY), daysleft=0 " .
                 "WHERE userid=? AND item=?", undef, $daysleft, $userid, $item);
        return undef if $dbh->err;

        # reactivate caps if necessary
        if (my $cap = $LJ::Pay::bonus{$item}->{'cap'}) {
            LJ::modify_caps($userid, [$cap], [])
                or return undef;
        }

        # log this bonus feature activation
        LJ::statushistory_add($userid, undef, 'pay_modify', 
                              "adding bonus feature: item=$item; old_expdate=$expdate; " .
                              "applying $daysleft existing days");

        push @activated, { 'item' => $item, 'size' => $size, 'daysleft' => $daysleft };
    }

    return @activated;
}

# activates frozen bonus features
# - returns array of hashrefs: { item, size, daysleft frozen }
sub LJ::Pay::freeze_bonus {
    my ($u, $item) = @_; # item is optional

    # allow u/payitem objects passed optionally
    my $userid = LJ::want_userid($u);
    $item = $item->{'item'} if ref $item;
    return undef unless $userid;
    
    my $dbh = LJ::get_db_writer();

    # we can either operate on one given item or all items for a user
    my $itemand = $item ? (" AND item=" . $dbh->quote($item)) : "";

    # see if there is existing time
    my $sth = $dbh->prepare("SELECT item, size, (TO_DAYS(expdate)-TO_DAYS(NOW())+daysleft) AS 'new_daysleft' " .
                            "FROM paidexp WHERE expdate>NOW() AND userid=?$itemand");
    $sth->execute($userid);
    my @deactivated = ();
    while (my ($item, $size, $new_daysleft) = $sth->fetchrow_array) {

        # this shouldn't ever get triggered
        next unless LJ::Pay::is_bonus($item);

        # remove cap (if necessary) and run applicable hooks
        if (my $cap = $LJ::Pay::bonus{$item}->{'cap'}) {
            LJ::modify_caps($userid, [], [$cap])
                or return 0;
        }

        # set expdate to now and save current time in daysleft
        # - to be robust, handle the case where there are currently daysleft but the expdate>NOW(),
        #   even though it technically shouldn't happen.
        if ($new_daysleft) {
            $dbh->do("UPDATE paidexp SET daysleft=?, expdate=NOW() " .
                     "WHERE userid=? AND item=?", undef, $new_daysleft, $userid, $item);

        # if daysleft ended up being 0 above, delete the row
        } else {
            $dbh->do("DELETE FROM paidexp WHERE userid=? AND item=? AND (daysleft=0 OR daysleft IS NULL)",
                     undef, $userid, $item);
        }

        # log this bonus feature expiration
        LJ::statushistory_add($u, undef, 'pay_modify',
                              "deactivating bonus feature due to paid account expiration: item=$item; ".
                              "saving $new_daysleft extra days");

        # return a list of deactivated rows
        push @deactivated, { 'item' => $item, 'size' => $size, 'daysleft' => $new_daysleft };
    }

    return @deactivated;
}

# returns 1 on success, undef on error
# - bonus_ref: opt, reference in which to return output of LJ::Pay::freeze_bonus
# - perm: opt, set to remove permanent status
sub LJ::Pay::remove_paid_account {
    my ($userid, $bonus_ref, $perm) = @_;
    my $u = ref $userid ? $userid : LJ::load_userid($userid, "force");
    return undef unless $u;

    # remove paid user cap
    {
        my @cap_remove = 'paid';
        push @cap_remove, 'perm' if $perm;

        LJ::modify_caps($u, [], [ @cap_remove ])
            or return undef;
    }

    # delete paiduser/email alias rows
    my $dbh = LJ::get_db_writer();
    $dbh->do("DELETE FROM paiduser WHERE userid=?", undef, $u->{'userid'});
    $dbh->do("DELETE FROM email_aliases WHERE alias=?", undef, "$u->{'user'}\@$LJ::USER_DOMAIN")
        unless exists $LJ::FIXED_ALIAS{$u->{'user'}};

    # note the transition for stats
    LJ::Pay::update_paytrans($userid, 'paidaccount', 'X')
        or return undef;

    # log this paid account expiration
    my $name = $perm ? "perm" : "paid";
    LJ::statushistory_add($u, undef, 'pay_modify', "expiring $name account");

    # returns list/hash of item => { paidexp row }
    @$bonus_ref = LJ::Pay::freeze_bonus($u);

    return 1;
}

sub LJ::Pay::is_valid_cart {
    my $cartobj = shift;

    # do some checks on the cart to make sure that it is valid/intact?
    my $dbh;

    # iterate over all items and make sure that each one is allowed to be there
    my %done = ();
    my $found_coppa = undef;
    foreach my $it (@{$cartobj->{'items'}}) {

        # cache that we checked this userid, item combination
        {
            my $key = "$it->{'rcptid'}-$it->{'item'}";
            next if $done{$key};
            $done{$key} = 1;
        }

        # run checks for 'sized' bonus item types
        if (LJ::Pay::is_bonus($it, 'sized')) {
            return undef unless LJ::Pay::can_apply_sized_bonus($it->{'rcptid'}, $cartobj, $it->{'item'});

        # run checks for 'bool' bonus item types
        } elsif (LJ::Pay::is_bonus($it, 'bool')) {
            return undef unless LJ::Pay::can_apply_bool_bonus($it->{'rcptid'}, $cartobj, $it->{'item'});

        # check for attempted use of already used coupons
        } elsif ($it->{'item'} eq 'coupon' && $it->{'amt'} < 0) {
            $dbh ||= LJ::get_db_writer();
            my $payid = $dbh->selectrow_array("SELECT payid FROM coupon WHERE cpid=?",
                                              undef, $it->{'tokenid'});
            return undef unless $payid && $payid == $cartobj->{'payid'};


        } elsif ($it->{'item'} eq 'coppa') {
            return undef if $found_coppa;
            return undef unless $it->{'rcptid'};

            my $rcpt = LJ::load_userid($it->{'rcptid'});
            return undef unless $rcpt->{userid} == $cartobj->{userid} && $rcpt->underage;

            $found_coppa = 1;
        }
    }

    if ($cartobj->{userid} && ! $found_coppa) {
        my $u = LJ::load_userid($cartobj->{userid}) or return undef; # invalid user on cart

        # no coppa found and cart owner is underage
        return undef if $u->underage;
    }

    return 1;
}

sub LJ::Pay::get_bool_bonus_price {
    my ($item, $qty) = @_;

    # allow passing of an $it hash
    if (ref $item eq 'HASH') {
        $qty = $item->{'qty'};
        $item = $item->{'item'};
    }

    return undef unless $item && $qty && LJ::Pay::is_bonus($item, 'bool');

    return $LJ::Pay::bonus{$item}->{'items'}->{$qty}->{'amount'};
}

sub LJ::Pay::get_sized_bonus_price {
    my ($u, $cartobj, $item, $size, $qty) = @_;

    my $userid = LJ::want_userid($u);

    # allow passing of an $it hash
    if (ref $item eq 'HASH') {
        # get size from subitem
        $size = (split("-", $item->{'subitem'}))[0];
        $qty = $item->{'qty'};
        $item = $item->{'item'};
    }

    # easy/obvious checks
    return undef unless $userid && LJ::Pay::is_bonus($item, 'sized') && $size > 0;

    # total price of this item with no comp
    my $total_price = $LJ::Pay::bonus{$item}->{'items'}->{$size}->{'qty'}->{$qty}->{'amount'};

    # no negative prices allowed
    $total_price = 0 if $total_price < 0;

    # if there is already an item of this size in the cart, it already received a comp, so don't do it again
    return $total_price
        if grep { $_->{'rcptid'} == $userid && $_->{'item'} eq $item && 
                  (split("-", $_->{'subitem'}))[0] == $size } @{$cartobj->{'items'}};

    my $dbh = LJ::get_db_writer();
    my $row = $dbh->selectrow_hashref("SELECT TO_DAYS(expdate)-TO_DAYS(NOW()) AS 'curr_days', " .
                                      "TO_DAYS(NOW() + INTERVAL ? MONTH)-TO_DAYS(NOW()) AS 'new_days', " .
                                      "size AS 'curr_size' FROM paidexp WHERE userid=? AND item=?",
                                      undef, $qty, $userid, $item);
    $row->{'new_size'} = $size;
    $row->{'curr_days'} = 0 if $row->{'curr_days'} < 0;

    # if current size is what they're trying to buy or there are no current days, there is no comp'ing to be done
    return $total_price if $row->{'curr_size'} == $row->{'new_size'} || $row->{'curr_days'} == 0;

    # find areas of new/existing rectangles to be bought
    my $old_area = $row->{'curr_size'} * $row->{'curr_days'};
    my $new_area = $row->{'new_size'} * $row->{'new_days'};
    my $rate = $old_area / ($new_area || 1);

    # calculate comp'd price to subtract from the total
    my $comp_amt = $total_price * $rate;

    # return final price to user.
    my $final_price = sprintf("%.02f", $total_price - $comp_amt);

    # don't let final price be < 0
    $final_price = 0 if $final_price < 0;

    return $final_price;
}

# return list of bonus items available for purchase,
# to be plugged into LJ::html_select()
sub LJ::Pay::bonus_item_list {
    my ($u, $cartobj) = @_; # purchasing user

    my @bool;
    my @sized;
    foreach my $itemname (keys %LJ::Pay::bonus) {
        my $bitem = $LJ::Pay::bonus{$itemname};
        next unless ref $bitem eq 'HASH' && ref $bitem->{'items'} eq 'HASH'; # eh?

        # bool type
        if ($bitem->{'type'} eq 'bool') {
            foreach my $qty (sort { $b <=> $a } keys %{$bitem->{'items'}}) {
                my $amt = $bitem->{'items'}->{$qty}->{'amount'};
                push @bool, ("$itemname-$qty", 
                             LJ::Pay::product_name($itemname, undef, $qty) . " (\$$amt.00 USD)");
            }

            next;
        }

        # sized type
        if ($u && $bitem->{'type'} eq 'sized') {
            foreach my $size (reverse sort { $a <=> $b } keys %{$bitem->{'items'}}) {
                my $sizeit = $bitem->{'items'}->{$size};
                foreach my $qty (sort { $b <=> $a } keys %{$sizeit->{'qty'}}) {

                    # do a bunch of checks, $u probably is $remote since gifts aren't allowed
                    next unless LJ::Pay::can_apply_sized_bonus($u, $cartobj, $itemname, $size, $qty);

                    # will be interpretted as item-subitem-qty
                    my $amt = $sizeit->{'qty'}->{$qty}->{'amount'};
                    my $amt_comp = LJ::Pay::get_sized_bonus_price($u, $cartobj, $itemname, $size, $qty);
                    push @sized, ("$itemname-$size-$qty",
                                  LJ::Pay::product_name($itemname, $size, $qty) . " (\$$amt.00 USD" .
                                  ($amt == $amt_comp ? "" : "; to upgrade: \$$amt_comp") . ")");
                }
            }

            next;
        }
    }

    return (@bool, @sized);
}

sub LJ::Pay::postal_address_text {
    return join("\n", @LJ::PAY_POSTAL_ADDRESS, @_);
}

sub LJ::Pay::postal_address_html {
    return join('<br />', @LJ::PAY_POSTAL_ADDRESS, @_);
}

sub LJ::Pay::account_summary {
    my $u = shift;
    return undef unless $u;

    # find account name
    my $acctname;
    my $eff_cap;
    foreach my $capkey (sort { $LJ::Pay::capinf{$a}->{'bit'} <=> $LJ::Pay::capinf{$b}->{'bit'} } keys %LJ::Pay::capinf) {
        my $cap = $LJ::Pay::capinf{$capkey};
        next unless $u->{'caps'} & 1 << $cap->{'bit'};
        $acctname = $cap->{'name'};
        $eff_cap = $capkey;
    }

    # get paid account expiration date, but only if the user is paid (not perm)
    my $dbh = LJ::get_db_writer();
    my $paid_exp;
    if ($eff_cap eq 'paid') {
        $paid_exp = $dbh->selectrow_array("SELECT paiduntil FROM paiduser WHERE userid=? " .
                                          "AND paiduntil > NOW()",
                                          undef, $u->{'userid'});
    }

    my $trim = sub { return substr($_[0], 0, 10); };

    my $ret;

    # account type
    $ret .= "<ul>";
    $ret .= "<li><b>$acctname</b>";
    $ret .= " - expiring <i>" . $trim->($paid_exp) . "</i>" if $paid_exp;
    $ret .= "</li>";

    # bonus features
    my $sth = $dbh->prepare("SELECT * FROM paidexp WHERE userid=? AND (expdate>NOW() OR daysleft>0)");
    $sth->execute($u->{'userid'});
    my $bonus = "<ul>";
    my $ct;
    while (my $exp = $sth->fetchrow_hashref) {

        $bonus .= "<li>" . LJ::Pay::product_name($exp, "short") . " - ";

        # enabled has 2 cases:
        # - item has associated cap and it's enabled on $u
        # - daysleft == 0, meaning expdate > NOW() by query above
        my $bit = $LJ::Pay::bonus{$exp->{'item'}}->{'cap'};
        my $has_cap = $u->{'caps'} & 1 << $bit;
        my $enabled = defined $bit && $has_cap || $exp->{'daysleft'} == 0;

        # active
        if ($enabled) {
            $bonus .= "Active, expiring <i>" . $trim->($exp->{'expdate'}) . "</i>";

        # inactive
        } else {
            $bonus .= "Inactive, $exp->{'daysleft'} days remaining";
        }
        $bonus .= "</li>";
        
        $ct++;
    }
    $ret .= "$bonus</ul>" if $ct;
        
    $ret .= "</ul>";

    return $ret;
}

sub LJ::Pay::quota_summary {
    my $u = shift;

    # disk quota usage
    my $diskquota = LJ::Blob::get_disk_usage($u);
    my $diskmax = LJ::get_cap($u, "disk_quota") * 1024**2;
    return undef unless $diskquota && $diskmax;

    my $size = sub {
        my $bytes = shift;

        # print in mb
        return sprintf("%.2f MiB", $bytes / 1024**2)
            if $bytes > 1024**2;
        
        # print in k
        return sprintf("%.2fkb", $bytes / 1024);
    };

    my $pct = sub {
        return sprintf("%.2f%%", ($_[0] / $_[1]) * 100);
    };

    my $ret;

    $ret .= "<ul>";
    $ret .= "<li>Total: " . $size->($diskquota) . " of " . $size->($diskmax);
    $ret .= " (" . $pct->($diskquota, $diskmax) . ")</li>";

    $ret .= "<ul>";
    my @blobtypes = (['userpic', "Userpics"], ['phonepost', 'PhonePost']);
    push @blobtypes, ['fotobilder', 'Photo Hosting'] if LJ::get_cap($u, 'fb_account');
    foreach (@blobtypes) {
        my ($domain, $name) = @$_;
        
        my $used = LJ::Blob::get_disk_usage($u, $domain);
        $ret .= "<li>$name: " . $size->($used);
        $ret .= " (" . $pct->($used, $diskmax) . ")</li>";
    }
    $ret .= "</ul></ul>";

    return $ret;

};

sub LJ::Pay::render_cart {
    my $cartobj = shift;

    my $ret = shift;
    my $opts = shift;

    my $remote = LJ::get_remote();

    $$ret .= <<HDR;
<table width='95%' cellpadding='2'>
<tr>
   <td width='1%'></td>
   <td width='30%'><b><u>Item</u></b></td>
   <td width='30%'><b><u>Type</u></b></td>
   <td width='30%'><b><u>Recipient</u></b></td>
   <td width='9%' align='right'><b><u>Amount</u></b></td>
</tr>
HDR

my $is_items = 0;
unless ($cartobj && @{$cartobj->{'items'}}) {
    $$ret .= "<tr><td colspan='5'><i>(no items)</i></tr>";
} else {
    $is_items = 1;
    my %name = (
                'paidacct' => 'Paid Account',
                'coupon' => "Coupon",
                'perm' => 'Permanent Account',
                'rename' => 'Rename Token',
                'shipping' => "Shipping Cost",
                'diskquota' => "Disk Quota",
                'userpic' => "Extra Userpics",
                'coppa'   => "Age Verification (for COPPA)",
                );
        
    # load user objects & pics
    my (%user, %pic);
    foreach my $it (@{$cartobj->{'items'}}) {
        next unless $it->{'rcptid'};
        $user{$it->{'rcptid'}} = \$user{$it->{'rcptid'}};
    }
    LJ::load_userids_multiple([ %user ], [ $remote ]);
    if ($opts->{'pics'}) {
        LJ::load_userpics(\%pic, [ map { [ $_, $_->{'defaultpicid'} ] } values %user ]);
    }

    my $ljuopts = {};
    $ljuopts->{'imgroot'} = "$LJ::SSLROOT/img" if $opts->{'secureimg'};
        
    foreach my $it (sort { $b->{'amt'} <=> $a->{'amt'} } @{$cartobj->{'items'}}) {
        my $size;

        $$ret .= "<tr valign='top'><td>";
        $$ret .= LJ::html_check({ 'type' => 'check', 'name' => "del_$it->{'piid'}",
                                  'id' => "del_$it->{'piid'}", 'disabled' => $it->{'item'} eq 'coppa' })
            if $opts->{'remove'};
        $$ret .= "</td><td>";

        # default item name
        my $name = $name{$it->{'item'}} || $it->{'item'};

        # bonus features
        if (LJ::Pay::is_bonus($it)) {
            $name = LJ::Pay::product_name($it, "short");
        }

        # clothing items
        if ($it->{'item'} eq "clothes") {
            my ($style, $col, $sz) = split(/-/, $it->{'subitem'});
            if ($LJ::Pay::product{"clothes-$style"}) {
                $name = $LJ::Pay::product{"clothes-$style"}->[0];
            }
            $name ||= "Unknown Clothing: $name";
            $name .= ", " . $LJ::Pay::color{$col};
            $name = "<b>$name</b>" if $opts->{shipping_labels};
            if ($opts->{'pics'}) {
                $name .= "<br /><img src=\"$LJ::IMGPREFIX/tshirts/thumb/$style-$col.jpg\" width='200' height='191' />";
            }
            $size = $LJ::Pay::size{$sz}->[1];

        }

        # discount coupons
        if ($it->{'item'} eq "coupon") {
            $name = LJ::Pay::product_name($it->{'item'}, $it->{'subitem'});
            $name .= "<br />(<tt>$it->{'token'}</tt>)" if $it->{'token'} && $it->{'amt'} < 0;
        }
        $$ret .= "<label for='del_$it->{'piid'}'>$name</label>";

        # is this an anonymous gift?
        if ($it->{'anon'}) {
            $$ret .= ", anonymous";
        }

        # is there a delivery date?
        if ($it->{'giveafter'}) {
            $$ret .= ", to be delivered ";
            my @gmt = gmtime($it->{'giveafter'});
            $$ret .= sprintf("%04d-%02d-%02d %02d:%02d",
                            $gmt[5]+1900, $gmt[4]+1, $gmt[3],
                            $gmt[2], $gmt[1]);
        }

        # if this is being called from an admin page, optionally show tokens associated
        # with renames, coupons, etc.
        if ($opts->{'tokens'} && $it->{'token'} ne "") {
            my $token = $it->{'token'};
            if ($it->{'item'} eq "paidacct" || $it->{'item'} eq "perm") {
                $token = "<a href='/admin/codetrace.bml?code=$token'>$token</a>";
            }

            # link between payid that bought
            # the coupon and payid which used the coupon
            if ($it->{'item'} eq "coupon") {
                my $dbh = LJ::get_db_writer();
                my ($payid, $ppayid) =
                    $dbh->selectrow_array("SELECT payid, ppayid FROM coupon WHERE cpid=?",
                                          undef, $it->{'tokenid'});

                my $id = $it->{'amt'} < 0 ? $ppayid : $payid;
                $token = "<a href='paiddetails.bml?payid=$id'>$token</a>" if $id;
            }

            if ($it->{'item'} eq "rename") {
                my $dbh = LJ::get_db_writer();
                my ($from, $to, $date) = 
                    $dbh->selectrow_array("SELECT fromuser, touser, rendate FROM renames " .
                                          "WHERE payid=? AND renid=?",
                                          undef, $it->{'payid'}, $it->{'tokenid'});
                if ($from && $to && $date) {
                    $token .= "<br />" . 
                              LJ::ljuser($from, { 'no_follow' => 1 }) . " => " . 
                              LJ::ljuser($to, { 'no_follow' => 1 }) . "<br />@ $date";
                } else {
                    $token .= " (unused)";
                }
            }

            $$ret .= "<br /><b><tt>$token</tt></b>";
        }
        if ($opts->{'piids'}) {
            $$ret .= "<br /><small>[piid: $it->{'piid'} {$it->{'status'}}]</small>";
        }
        $$ret .= "</td><td>";

        # item type column
        if ($it->{'item'} eq "paidacct" ||
            defined $LJ::Pay::bonus{$it->{'item'}}) {

            $$ret .= "$it->{'qty'} months";
        } elsif ($it->{'item'} eq "clothes") {
            $$ret .= $opts->{shipping_labels} ? "<b>$size</b>" : $size;
        } elsif ($it->{'item'} eq "coupon") {
            $$ret .= "\$$it->{'amt'} USD";
        }
        
        $$ret .= "</td><td>";
        if ($it->{'rcptid'}) {
            my $u = $user{$it->{'rcptid'}};
            $$ret .= LJ::ljuser($u->{'user'}, $ljuopts) . " - " . LJ::ehtml($u->{'name'});
            if ($u->{'defaultpicid'} && $opts->{'pics'}) {
                my $p = $pic{$u->{'defaultpicid'}};
                $$ret .= "<br /><img src='$LJ::USERPIC_ROOT/$u->{'defaultpicid'}/$u->{'userid'}' width='$p->{'width'}' height='$p->{'height'}'>";
            }

        } else {
            $$ret .= "<nobr>" . LJ::ehtml($it->{'rcptemail'}) . "</nobr>";
        }
        $$ret .= "</td><td align='right'>";
        $$ret .= sprintf("\$%0.02f", $it->{'amt'});
        $$ret .= "</td></tr>";
    }

}

    # analyze various amounts in this cart
    my $amts = LJ::Pay::coupon_reduce($cartobj);

    # print dollars
    my $damt = sub { sprintf("\$%.02f", shift()) };

    if ($amts->{'cp_used_tot'} > 0) {
        $$ret .= "<tr><td colspan='4' align='right' valign='top'>Subtotal:</td>";
        $$ret .= "<td align='right'>" . $damt->($amts->{'cart_amt_tot'}) . "</td></tr>";
        if ($amts->{'cp_used_gen'} > 0) {
            $$ret .= "<tr><td colspan='4' align='right' valign='top'>General Coupon:</td>";
            $$ret .= "<td align='right'>" . $damt->(-$amts->{'cp_used_gen'}) . "</td></tr>";
        }
        if ($amts->{'cp_used_int'} > 0) {
            $$ret .= "<tr><td colspan='4' align='right' valign='top'>Intangible Coupon:</td>";
            $$ret .= "<td align='right'>" . $damt->(-$amts->{'cp_used_int'}) . "</td></tr>";
        }
        if ($amts->{'cp_used_tan'} > 0) {
            $$ret .= "<tr><td colspan='4' align='right' valign='top'>Tangible Coupon:</td>";
            $$ret .= "<td align='right'>" . $damt->(-$amts->{'cp_used_tan'}) . "</td></tr>";
        }
    }
    $$ret .= "<tr><td colspan='4' align='right' valign='top'><b>Total (USD):</b></td>";
    $$ret .= "<td align='right'>" . $damt->($amts->{'adj_amt_tot'}) . "</td></tr>";

    if ($opts->{'remove'} || ($opts->{'checkout'} && LJ::Pay::can_checkout_cart($cartobj))) {

        # warning of coupons in cart which are not fully utilized
        if ($amts->{'cp_unused_gen'} > 0) {
            $$ret .= "<tr valign='top'><td colspan='5' align='left'>";
            $$ret .= "<b>Warning:</b> You are using " . $damt->($amts->{'cp_amt_gen'});
            $$ret .= " worth of general-purpose coupons on this order.  However, ";
            $$ret .= $damt->($amts->{'cp_unused_gen'}) . " of that is currently unused. ";
            $$ret .= "If you choose to check out now, the " . $damt->($amts->{'cp_unused_gen'});
            $$ret .= " will be wasted!";
            $$ret .= "</td></tr>\n";
        }

        # warning of intangible coupons in cart which are not fully utilized
        if ($amts->{'cp_unused_int'} > 0) {
            $$ret .= "<tr valign='top'><td colspan='5' align='left'>";
            $$ret .= "<b>Warning:</b> You are using " . $damt->($amts->{'cp_amt_int'});
            $$ret .= " worth of coupons which are <i>only</i> valid for intangible ";
            $$ret .= "purchases such as Paid Accounts and Bonus Features. However, ";
            $$ret .= $damt->($amts->{'cp_unused_int'}) . " of that is currently unused. ";
            $$ret .= "If you choose to check out now, the " . $damt->($amts->{'cp_unused_int'});
            $$ret .= " will be wasted!";            
            $$ret .= "</td></tr>\n";
        }

        # warning of tangible coupons in cart which are not fully utilized
        if ($amts->{'cp_unused_tan'} > 0) {
            $$ret .= "<tr valign='top'><td colspan='5' align='left'>";
            $$ret .= "<b>Warning:</b> You are using " . $damt->($amts->{'cp_amt_tan'});
            $$ret .= " worth of coupons which are <i>only</i> valid for tangible ";
            $$ret .= "purchases such as Tee Shirts and Hoodies. However, ";
            $$ret .= $damt->($amts->{'cp_unused_tan'}) . " of that is currently unused. ";
            $$ret .= "If you choose to check out now, the " . $damt->($amts->{'cp_unused_tan'});
            $$ret .= " will be wasted!";            
            $$ret .= "</td></tr>\n";
        }

        if (grep { $_->{'item'} eq 'rename' || $_->{'item'} eq 'coupon' && $_->{'amt'} > 0 }
            @{$cartobj->{'items'}}) {

            $$ret .= "<tr valign='top'><td colspan='5' align='left'>";
            $$ret .= "<b>AOL Users:</b>  To prevent difficulties receiving your rename token ";
            $$ret .= "and/or coupon, please adjust your email settings to allow email from ";
            $$ret .= "$LJ::ACCOUNTS_EMAIL.</td></tr>\n";
        }

        my $has_coppa = LJ::Pay::cart_contains_coppa($cartobj);
        if ($has_coppa) {
            $$ret .= "<tr valign='top'><td colspan='5' align='left'>";
            $$ret .= "<b>Note:</b>  Because your cart contains a <a href='$LJ::SITEROOT/legal/coppa.bml'>COPPA</a> Verification item, ";
            $$ret .= "you must pay for this cart via credit card.</td></tr>\n";
        } 
        
        my $disabled = $is_items ? "" : "disabled='disabled'";
        $$ret .= "<tr valign='top'><td colspan='2'>";
        if ($opts->{'remove'}) {
            $$ret .= "<input type='submit' name='action:removesel' $disabled value='Remove Selected'>";
        }
        $$ret .= "</td><td colspan='4' align='right'>";
        if ($opts->{'checkout'} && LJ::Pay::can_checkout_cart($cartobj)) {

            if ($amts->{'adj_amt_tot'} > 0 || $has_coppa || LJ::Pay::cart_needs_shipping($cartobj)) {
                $$ret .= "Payment method: ";

                my @pay_list = (cc => "Credit Card");

                # if the cart contains a special "coppa" item, then the only vaid method of payment
                # is credit card.
                unless ($has_coppa) {
                    push @pay_list, ( "paypal" => "PayPal",
                                      "check" => "Check",
                                      "moneyorder" => "Money Order",
                                      "cash" => "Cash", );
                }

                $$ret .= LJ::html_select({'name' => 'paymeth', }, @pay_list);
                $$ret .= "\n<input type='submit' name='action:checkout' value='Check out --&gt;'>";

            } else {
                $$ret .= "No charge.  <input type='submit' name='action:checkout' value='Check out --&gt;'>";
            }
        }
        $$ret .= "</td></tr>\n";
    }

    $$ret .= "</table>";

    return 1;
}

sub revoke_payitems
{
    my $dbh = LJ::get_db_writer();
    foreach my $it (@_) {
        next unless $it->{'status'} eq "done";
        
        # revoke a rename token
        if ($it->{'item'} eq "rename") {

            # the rename token might've been used already, in which case it's kinda
            # too late.  but we'll mark the rename as refunded regardless, so maybe
            # later we can write something to flop things back... we'll see.
            $dbh->do("UPDATE renames SET token='----------' WHERE renid=?", undef,
                     $it->{'tokenid'});

            # log to statushistory, but only if there's a userid to associate it with
            LJ::statushistory_add($it->{'rcptid'}, undef, "revoke", "revoking rename token: $it->{'token'}")
                if $it->{'rcptid'};

            next;
        }

        # revoke a paid or permanent account
        if ($it->{'item'} eq "paidacct" || $it->{'item'} eq "perm") {
            my $revid = $it->{'rcptid'};
            if ($it->{'tokenid'}) {
                $dbh->do("UPDATE acctcode SET auth='-----' WHERE acid=?", undef,
                         $it->{'tokenid'});
                # but maybe the code wasn't used yet, so let's check and
                # cancel the revoke, since we stopped it in time
                $revid = $dbh->selectrow_array("SELECT rcptid FROM acctcode WHERE ".
                                               "acid=?", undef, $it->{'tokenid'});
            } 
            my $months = $it->{'item'} eq "perm" ? 99 : $it->{'qty'};
            LJ::Pay::remove_paid_months($revid, $months, $it) if $revid;
            next;
        }

        # revoke a tangible shipping item
        if (LJ::Pay::item_needs_shipping($it)) {
            # delete from shipping so this shipping label won't show up anymore
            $dbh->do("DELETE FROM shipping WHERE payid=?", undef, $it->{'payid'});

            # log to statushistory, but only if there's a userid to associate it with
            LJ::statushistory_add($it->{'rcptid'}, undef, "revoke", 
                                  "revoking shipping item: " . LJ::Pay::product_name($it))
                if $it->{'rcptid'};

            next;
        }

        # revoke bonus features
        if (LJ::Pay::is_bonus($it)) {

            # this function will handle messiness and log to statushistory
            LJ::Pay::remove_bonus_item($it);
            next;
        }
    }
    
    my $in = join(',', map { $_->{'piid'}+0 } @_);
    $dbh->do("UPDATE payitems SET status='refund' WHERE piid IN ($in)") if $in;
}

sub LJ::Pay::remove_bonus_item {
    my $it = shift;
    return undef unless ref $it eq 'HASH';
    return undef unless LJ::Pay::is_bonus($it);

    my $dbh = LJ::get_db_writer();

    # update paidexp
    $dbh->do("UPDATE paidexp SET expdate=expdate - INTERVAL ? MONTH " .
             "WHERE userid=? AND item=?",
             undef, $it->{'qty'}, $it->{'rcptid'}, $it->{'item'});

    # if they're now totally out of time for this bonus feature, we need to
    # delete their paidexp row altogether and possibly remove their cap

    my $newrow = $dbh->selectrow_hashref("SELECT *, (expdate>NOW()) AS 'timeleft' " .
                                         "FROM paidexp WHERE userid=? AND item=?",
                                         undef, $it->{'rcptid'}, $it->{'item'});
    
    unless ($newrow->{'timeleft'}) {

        # delete empty row
        $dbh->do("DELETE FROM paidexp WHERE userid=? AND item=? AND expdate<NOW()",
                 undef, $it->{'rcptid'}, $it->{'item'});

        # update user's cap if necessary
        my $cap = $LJ::Pay::bonus{$it->{'item'}}->{'cap'};
        LJ::modify_caps($it->{'rcptid'}, [], [$cap]) if $cap;
    }

    # log to statushistory
    LJ::statushistory_add($it->{'rcptid'}, undef, 'revoke', 
                          LJ::Pay::product_name($it, "shoort") . "; $it->{'qty'} months");

    return 1;
}

sub bazaar_do_expirations {
    my $uid = shift;
    my $dbh = LJ::get_db_writer();

    my $userclause;
    if ($uid) {
        $uid += 0;
        $userclause = "userid=$uid AND ";
    }

    # do expirations
    $dbh->do("UPDATE bzrbalance SET expired=owed, owed=0 WHERE $userclause ".
             "owed > 0 AND date < DATE_SUB(NOW(), INTERVAL 93 DAY)");
}

sub bazaar_remove_balance {
    my ($u, $amt) = @_;
    my $dbh = LJ::get_db_writer();
    return 0 unless $u;

    my $key = "bzrbaldecr-$u->{'userid'}";
    my $r = $dbh->selectrow_array("SELECT GET_LOCK(?, 3)", undef, $key);
    return 0 unless $r;
    my $unlock = sub {
        $dbh->selectrow_array("SELECT RELEASE_LOCK(?)", undef, $key);
    };

    LJ::Pay::bazaar_do_expirations($u->{'userid'});

    my @owed;
    my $bal;
    my $sth = $dbh->prepare("SELECT bzid, owed FROM bzrbalance ".
                            "WHERE userid=? AND owed > 0 ORDER BY date");
    $sth->execute($u->{'userid'});
    while (my ($bzid, $owed) = $sth->fetchrow_array) {
        push @owed, [ $bzid, $owed ];
        $bal += $owed;
    }

    if ($bal < $amt) {
        $unlock->();
        return 0;
    }

    my $remain = $amt;
    while ($remain >= 0.01 && @owed) {
        my $rec = shift @owed;
        my $remove = $rec->[1] < $remain ? $rec->[1] : $remain;
        my $rv = $dbh->do("UPDATE bzrbalance SET owed=GREATEST(0,owed-?) WHERE userid=? AND bzid=?",
                          undef, $remove, $u->{'userid'}, $rec->[0]);
        $remain -= $remove if $rv;
    }

    $unlock->();
    return 1;
}

sub new_coupon {
    my ($type, $amt, $rcptid, $ppayid) = @_;

    my $dbh = LJ::get_db_writer() or return undef;
    my $auth = LJ::make_auth_code(10);
    $dbh->do("INSERT INTO coupon (auth, type, arg, rcptid, ppayid) " .
             "VALUES (?, ?, ?, ?, ?)", undef, $auth, $type, $amt, $rcptid, $ppayid);
    return undef if $dbh->err;

    my $tokenid = $dbh->{'mysql_insertid'};
    return ($tokenid, "$tokenid-$auth");
}

# to be called as &nodb; (so this function sees caller's @_)
sub nodb {
    shift @_ if
        ref $_[0] eq "LJ::DBSet" || ref $_[0] eq "DBI::db" ||
        ref $_[0] eq "DBIx::StateKeeper" || ref $_[0] eq "Apache::DBI::db";
}


1;
