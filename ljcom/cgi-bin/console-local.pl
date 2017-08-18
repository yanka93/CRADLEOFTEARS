#!/usr/bin/perl
#

package LJ::Con;

my $success = sub {
    my ($out, $msg) = @_;
    push @$out, [ "", $msg ];
    return 1;
};
my $fail = sub {
    my ($out, $msg) = @_;
    push @$out, [ "error", $msg ];
    return 0;
};
my $usage = sub {
    my ($out, $cmdname) = @_;
    return $fail->($out, "usage: $cmdname $cmd{$cmdname}{argsummary}");
};

$cmd{'contrib'} = {
    'handler' => \&contrib_edit,
    'des' => "Adds/Acks Contributions.",
    'argsummary' => '<command> [<username>/<ackid>] [<contribtype>] [<msg>] [<url>]',
    'args' => [
               'command' => "Either 'ack' to ack a contrib, 'add' to add a contrib.",
               'username' => "The username for the contribution to add.",
               'ackid' => "Id of the contribution to ack.",
	       'contribtype' => "'code' for Coding, 'doc' for documentation, 'creative' for artwork, 'biz' for buisness, 'other' for other",
	       'msg' => "description of what they did",
	       'url' => "[optional] url with more information",
               ],
    };

$cmd{'payment_credit'} = {
    'handler' => \&payment_credit,
    'privs' => [qw(moneyenter)],
    'des' => "Give payment credit to an existing user from either an account code or a payid.  Marks the associated code as then used by that username.",
    'argsummary' => '<thing> <id> to <username>',
    'args' => [
               'thing' => "Either 'code' or 'payment'.",
               'id' => "If code, the code; if payment, the payid.",
               'username' => "The username to give the time to.",
               ],
    };

$cmd{'unpay'} = {
    'handler' => \&unpay,
    'privs' => [qw(moneyenter)],
    'des' => "Takes away paid time from a user for a bogus/accidental payment, while also changing the payment record to 0 months and 0 dollars, and making a note in the statushistory table why the payment was removed, and what the payment's old values were.",
    'argsummary' => '<user> <payid> <reason>',
    'args' => [
               'user' => 'Username of person to remove time from.  Or, use "!" (without the quotes) for no user, when you just want to zero out a payment and/or its associated account code.',
               'payid' => 'Payment ID# to delete',
               'reason' => 'The reason the payment is being deleted.  Not sent to user, only put in user\'s statushistory.',
               ],
    };

$cmd{'inventory'} = {
    'handler' => \&inventory,
    'privs' => [qw(moneyenter shipping)],
    'des' => "View or modify inventory.",
    'argsummary' => '<command> [<item> <value>]',
    'args' => [
               'command' => 'Either "show" to show current inventory, "add" to add &lt;value&gt; units of &lt;item&gt;, or "remove" to remove &lt;value&gt; units of &lt;item&gt;, or "price" to change the price of &lt;item&gt; to &lt;value&gt;.',
               'item' => 'Inventory code.',
               'value' => 'Number to change inventory by, or new cost.',
               ],
    };

sub unpay
{
    my ($dbh, $remote, $args, $out) = @_;

    my $user = LJ::canonical_username($args->[1]);
    if ($args->[1] eq "!") { $user = "!"; }

    my $payid = $args->[2];
    my $reason = $args->[3];

    my $err = sub {
        my $err = shift;
        my $lock = shift;
        push @$out, [ "error", $err ];
        if ($lock) {
            my $qlock = $dbh->quote($lock);
            $dbh->do("SELECT RELEASE_LOCK($qlock)");	    
        }
        return 0;
    };

    return $err->("$remote->{'user'}, you are not authorized to use this command.")
        unless (LJ::check_priv($dbh, $remote, "moneyenter"));

    return $err->("No reason given")
        unless $reason;

    return $err->("Invalid or missing username argument")
        unless $user;

    return $err->("Invalid payid format (not a number")
        unless ($payid =~ /^\d+$/);

    my $p = $dbh->selectrow_hashref("SELECT * FROM payments WHERE payid=$payid");
    my $u;
    if ($user eq "!") {
        $u = {
            'userid' => 0,
        };
    } else {
        $u = LJ::load_user($user, "force");
    }
    
    return $err->("The unpay command doesn't work with the new payment system")
        if $p->{'forwhat'} eq "cart";
    
    return $err->("Payment not found")
        unless $p;

    return $err->("User not found")
        unless $u;

    return $err->("That payment doesn't belong to that user")
        unless ($p->{'userid'} == $u->{'userid'});

    return $err->("That payment has no months or money associated with it.")
        unless ($p->{'amount'} ne "0.00" || $p->{'months'});

    my $lockname = "unpay-$user-$payid";
    my $status;

    # start pseudo-transaction
    $status = $dbh->selectrow_array("SELECT GET_LOCK('$lockname',10)");
    return $err->("Failed to get lock on necessary tables to do unpay, try again.")
        unless $status;
    
    my $months = $p->{'months'}+0;

    my $logtext = ("Removing payid \#$payid ($p->{'months'} months & $p->{'amount'} ".
                   "dollars).  Reason: " . $reason);

    # add to status history
    if ($u->{'userid'}) {
        $status = LJ::statushistory_add($dbh, $u->{'userid'}, $remote->{'userid'},
                                        "unpay", $logtext);
    } else {
        $dbh->do("UPDATE payments SET notes=concat(notes, ?) WHERE payid=$payid", undef,
                 "\nUNPAY: $logtext");
    }

    $err->("Couldn't append statushistory table, aborting", $lockname)
        unless $status;


    # update payment record
    $dbh->do("UPDATE payments SET months=0, amount=0, used='Y' WHERE payid=$payid");
    $err->("Couldn't update payment record, aborting", $lockname)
        if $dbh->err;

    # subtract time from user
    $dbh->do("UPDATE paiduser SET paiduntil=DATE_SUB(paiduntil, INTERVAL $months MONTH) WHERE userid=$p->{'userid'}");
    $err->("Couldn't subtract time from user, aborting", $lockname)
        if $dbh->err;

    # end transaction
    $dbh->do("SELECT RELEASE_LOCK('$lockname')");

    push @$out, [ "", "Done." ];    
}

sub payment_credit
{
    my ($dbh, $remote, $args, $out) = @_;

    my $thing = $args->[1];
    my $id = $args->[2];
    my $to = $args->[3];
    my $username = $args->[4];

    unless ($remote->{'priv'}->{'moneyenter'}) {
        push @$out, [ "error", "$remote->{'user'}, you are not authorized to use this command." ];
        return 0;
    }

    unless ($thing eq "code" || $thing eq "payment") {
        push @$out, [ "error", "Invalid first argument." ];
        return 0;
    }

    unless ($to eq "to") {
        push @$out, [ "error", "Third argument isn't 'to'" ];
        return 0;
    }

    my $u = LJ::load_user($username, "force");
    unless ($u) {
        push @$out, [ "error", "User doesn't exist." ];
        return 0;
    }

    my $payid;
    my $acid;

    if ($thing eq "code") 
    {
        my $code = $id;
        ($acid, undef) = LJ::acct_code_decode($code);
        my $err;
        unless (LJ::acct_code_check($dbh, $code, \$err)) {
            push @$out, [ "error", "Bad code: $err." ];
            return 0;
        }
        my $sth = $dbh->prepare("SELECT payid FROM acctpay WHERE acid=$acid");
        $sth->execute;
        ($payid) = $sth->fetchrow_array;

        unless ($payid) {
            push @$out, [ "error", "This code doesn't have an associated payment." ];
            return 0;
        }
    }

    if ($thing eq "payment") {
        $payid = $id+0;

        my $sth = $dbh->prepare("SELECT acid FROM acctpay WHERE payid=$payid");
        $sth->execute;
        ($acid) = $sth->fetchrow_array;

        unless ($acid) {
            push @$out, [ "error", "This payment doesn't have an associated code." ];
            return 0;
        }

    }

    my $sth = $dbh->prepare("SELECT * FROM payments WHERE payid=$payid");
    $sth->execute;
    my $p = $sth->fetchrow_hashref;
    unless ($p) {
        push @$out, [ "error", "Payment not found." ];
        return 0;
    }
    unless ($p->{'userid'} == 0) {
        push @$out, [ "error", "Payment already assigned... not open." ];
        return 0;
    }

    # guess everything's good.
    $dbh->do("UPDATE payments SET userid=$u->{'userid'} WHERE payid=$payid");
    $dbh->do("UPDATE acctcode SET rcptid=$u->{'userid'} WHERE acid=$acid");

    push @$out, [ "", "Done." ];
}

sub contrib_edit
{
    my ($dbh, $remote, $args, $out) = @_;
    my $err = sub { push @$out, [ "error", $_[0] ]; 0; };

    return $err->("This command has 2 or more arguments") unless @$args >= 2;
    return $err->("Must be logged in.") unless $remote;

    my $cmd = $args->[1];
    if ($cmd eq "add")
    { 
        return $err->("Not enough arguments for add.") 
            unless @$args == 5 or @$args == 6;
        my $user = $args->[2];
        my $cat  = $args->[3];
        my $des  = $args->[4];
        my $url  = $args->[5];
      
        my $u = LJ::load_user($user, "force");
        return $err->("Invalid user $user") unless $u;
        my $userid = $u->{'userid'};
        return $err->("type can only be: 'code','doc','creative','biz','other'") unless 
            ($cat eq "code" or $cat eq "doc" or $cat eq "creative" or 
             $cat eq "biz" or $cat eq "other");

        $dbh->do("INSERT INTO contributed (userid, cat, des, url, dateadd) ".
                 "VALUES (?,?,?,?,NOW())", undef, $userid, $cat, $des, $url);
        return $err->("error adding contribution") if $dbh->err;

    } elsif ($cmd eq "ack") {

        return $err->("Not enough arguments for ack.") unless @$args == 3;
        return $err->("You have to be an acknowledged contributor before you can acknowledge other people.")
            unless LJ::Contrib::is_acked($remote->{'userid'});

        my $coid = $args->[2]+0;

        LJ::Contrib::ack($coid, $remote->{'userid'});
        
    } else {
       return $err->("Unknown Command Type");
    }

    push @$out, [ '', "Success." ];
    return 1;
}

sub inventory
{
    my ($dbh, $remote, $args, $out) = @_;

    my $cmd = $args->[1];
    my $item = $args->[2];
    my $val = $args->[3];

    unless ($remote->{'priv'}->{'moneyenter'} || $remote->{'priv'}->{'shipping'}) {
        push @$out, [ "error", "$remote->{'user'}, you are not authorized to use this command." ];
        return 0;
    }

    unless ($cmd =~ /show|add|remove|price/) {
        push @$out, [ "error", "Invalid inventory command." ];
        return 0;
    }

    if ($cmd eq "show") {
        my $sth = $dbh->prepare("SELECT item, subitem, qty, avail, price FROM inventory ".
                                "ORDER BY item, subitem");
        $sth->execute;
        push @$out, [ '', "qty  avl  price  item" ];
        push @$out, [ '', "==== ==== ====== =============================" ];
        while ($_ = $sth->fetchrow_hashref) {
            push @$out, [ '', sprintf("%4d %4d \$%5.02f %s-%s",
                                      $_->{'qty'}, $_->{'avail'}, $_->{'price'}, 
                                      $_->{'item'}, $_->{'subitem'}) ];
        }
        return 1;
    }

    my $subitem;
    unless ($item =~ /^(\w+?)-(.+)$/) {
        push @$out, [ "error", "Invalid item format." ];
        return 0;
    }
    ($item, $subitem) = ($1, $2);

    if ($cmd eq "add" || $cmd eq "remove") {
        my $dir = $cmd eq "add" ? "+" : "-";
        my $ro = $dbh->do("UPDATE inventory SET qty=qty $dir ?, avail=avail $dir ? ".
                          "WHERE item=? AND subitem=?",
                          undef, $val, $val, $item, $subitem);
        if ($ro > 0) {
            push @$out, [ "", "$item-$subitem changed." ];
            return 1;
        }
        push @$out, [ "error", "No change made." ];
        return 0;
    }

    if ($cmd eq "price") {
        my $price = $val;
        $price =~ s/\$//;
        unless ($price =~ /^(\d+)(\.\d\d)?$/ && $1) {
            push @$out, [ "error", "Invalid price." ];
            return 0
        }
        my $ro = $dbh->do("UPDATE inventory SET price=? ".
                          "WHERE item=? AND subitem=?",
                          undef, $price, $item, $subitem);
        if ($ro > 0) {
            push @$out, [ "", "$item-$subitem price changed." ];
            return 1;
        }
        push @$out, [ "error", "No change made." ];
        return 0;
    }

    return 0;
}

$cmd{'allow_pay'} = 
   {
       des        => "Permit or deny a user's ability to pay.",
       privs      => [qw(moneyenter)],
       argsummary => '<action> <usernames>',
       args       => [
                      action    => "'permit', or 'deny'",
                      username => "Username to allow to pay (with permit) or block payments (with deny)",
                      ],
       handler => sub {
           my ($dbh, $remote, $args, $out) = @_;

           return $fail->($out, "Not logged in.") unless $remote;
           return $fail->($out, "You don't have privileges needed to run this command.") 
               unless $remote->{'priv'}->{'moneyenter'};

           # check syntax and parse out some information
           my $myname = shift @$args;
           my $action = shift @$args or return $usage->($out, $myname);
           my $user   = shift @$args or return $usage->($out, $myname);

           my $act = $action eq 'permit' ? 'Y' : 'N';

           return $usage->($out, $myname) unless $args;
           return $usage->($out, $myname) unless $action =~ /^(permit|deny)$/;
           return $usage->($out, $myname) unless $user;

           # make changes and revoke
           my $userid = LJ::get_userid($dbh, $user);
           return $fail->($out, "Skipping invalid username: '$_'") unless $userid;

           LJ::set_userprop($userid, 'allow_pay', $act)
               or return $fail->($out, "Error setting 'allow_pay' userprop.  Database Unavailable?");

           # log to statushistory
           LJ::statushistory_add($userid, $remote->{userid}, "allow_pay", ucfirst($action) . "ing payments");

           $success->($out, ucfirst($action) . "ing payment for user $user");
           return 1;
       }

   };

$cmd{'got_assignment'} = 
   {
       des        => "Mark a user as sending in the assignment agreement paperwork for the bazaar.",
       privs      => [qw(moneyenter)],
       argsummary => '<user>',
       args       => [
                      user => "Username who sent in the assignment agreement.",
                      ],
       handler => sub {
           my ($dbh, $remote, $args, $out) = @_;

           return $fail->($out, "Not logged in.") unless $remote;
           return $fail->($out, "You don't have privileges needed to run this command.") 
               unless $remote->{'priv'}->{'moneyenter'};

           # check syntax and parse out some information
           my $myname = shift @$args;
           my $user   = shift @$args or return $usage->($out, $myname);

           my $u = LJ::load_user($user, "force");
           return $fail->($out, "User not found") unless $u;

           LJ::set_userprop($u, "legal_assignagree", 1)
               or return $fail->($out, "Error setting userprop.  Database unavailable?");

           $success->($out, "Assignment agreement flag set for $u->{'user'}");
           return 1;
       }
   };

$cmd{'bazaar_pay'} = 
   {
       des        => "Subtract money from a user's bazaar balance.",
       privs      => [qw(moneyenter)],
       argsummary => '<user> <amt>',
       args       => [
                      user => "Username to subtract balance from.",
                      amt => "Amount to subtract.",
                      ],
       handler => sub {
           my ($dbh, $remote, $args, $out) = @_;

           return $fail->($out, "Not logged in.") unless $remote;
           return $fail->($out, "You don't have privileges needed to run this command.") 
               unless $remote->{'priv'}->{'moneyenter'};

           # check syntax and parse out some information
           my $myname = shift @$args;
           my $user   = shift @$args;
           my $amt    = shift @$args;
           unless ($user ne "" && $amt =~ /^\d+(\.\d\d)?$/) {
               return $usage->($out, $myname);
           }

           my $u = LJ::load_user($user, "force");
           return $fail->($out, "User not found") unless $u;

           LJ::load_user_props($u, "legal_assignagree");
           unless ($u->{'legal_assignagree'}) {
               return $fail->($out, "Error:  no assignment agreement from $u->{'user'}.  Use the 'got_assignment' command if you have it.");
           }

           if (LJ::Pay::bazaar_remove_balance($u, $amt)) {
               LJ::statushistory_add($u->{'userid'}, $remote->{'userid'}, "bzrbaldecr", "Removing \$$amt");
               return $success->($out, "Success.");
           }

           return $fail->($out, "Error:  balance wasn't large enough?");
       }
   };

$cmd{'bazaar_status'} = 
   {
       des        => "Show who's owed how much for the bazaar.",
       privs      => [qw(moneyenter)],
       argsummary => '',
       args       => [    ],
       handler => sub {
           my ($dbh, $remote, $args, $out) = @_;

           return $fail->($out, "Not logged in.") unless $remote;
           return $fail->($out, "You don't have privileges needed to run this command.") 
               unless $remote->{'priv'}->{'moneyenter'};

           LJ::Pay::bazaar_do_expirations();

           my $sth = $dbh->prepare("SELECT u.user, SUM(b.owed) FROM user u, bzrbalance b ".
                                   "WHERE u.userid=b.userid AND b.owed > 0 GROUP BY 1");
           $sth->execute;
           while (my ($user, $sum) = $sth->fetchrow_array) {
               push @$out, [ "", sprintf("%-20s = \$%7.02f", $user, $sum) ];
           }

           return $success->($out, "[end]");
       }
   };


$cmd{'rename_redir'} = 
   {
       des        => "Change redirection option of a previously done redirect",
       privs      => [qw(moneyenter)],
       argsummary => '<action> <from_username> <to_username>',
       args       => [
                      action        => "'add' to do redirections, or 'remove' if redirections should not be done",
                      from_username => "Source journal which was renamed",
                      to_username   => "Destination journal to which from_username was renamed"
                      ],
       handler => sub {
           my ($dbh, $remote, $args, $out) = @_;

           return $fail->($out, "Not logged in.") unless $remote;
           return $fail->($out, "You don't have privileges needed to run this command.") 
               unless $remote->{'priv'}->{'moneyenter'};

           shift @$args; # remove command name
           my ($action, $from_username, $to_username) = @$args;

           return $fail->($out, "Invalid action: '$action'")
               unless $action eq 'add' || $action eq 'remove';

           my $from_user = LJ::load_user($from_username);
           return $fail->($out, "Invalid from_username")
               unless $from_user;
           $from_username = $from_user->{'user'};

           my $to_user = LJ::load_user($to_username);
           return $fail->($out, "Invalid to_username")
               unless $to_user;
           $to_username = $to_user->{'user'};

           return $fail->($out, "'$from_username' has already been marked as expunged'")
               if $from_user->{'statusvis'} eq 'X';

           return $fail->($out, "'$from_username' was never renamed to '$to_username'")
               unless $dbh->selectrow_array("SELECT COUNT(*) FROM renames " .
                                            "WHERE fromuser=? AND touser=?",
                                            undef, $from_username, $to_username);

           LJ::load_user_props($from_user, 'renamedto');

           # create a redirection link
           if ($action eq 'add') {
               return $fail->($out, "'$from_username' already redirects to '$to_username'")
                   if $from_user->{'renamedto'} eq $to_username && $from_user->{'statusvis'} eq 'R';

               return $fail->($out, "'$from_username' redirects to another journal?")
                   if $from_user->{'statusvis'} eq 'R' && $from_user->{'renamedto'} &&
                      $from_user->{'renamedto'} ne $to_username;

               # set renamedto prop
               LJ::set_userprop($from_user, "renamedto", $to_username)
                   or return $fail->($out, "Error setting userprop.  Database unavailable?");

               # update user, undelete (checked to see if already expunged earlier)
               LJ::update_user($from_user,
                               { raw => "journaltype='R', statusvis='R', statusvisdate=NOW()" });

               # update email aliases if applicable
               if (LJ::get_cap($from_user, "useremail")) {
                   $dbh->do("INSERT INTO email_aliases VALUES (?,?)", undef,
                            "$to_username\@$LJ::USER_DOMAIN", $to_user->{'email'});
               }

               return $success->($out, "Redirection added for $from_username => $to_username rename action");
           }

           # remove a redirection link
           if ($action eq 'remove') {

               return $fail->($out, "'$from_username' does not redirect to '$to_username'")
                   unless $from_user->{'renamedto'} eq $to_username &&
                          $from_user->{'statusvis'} eq 'R';

               # delete renamedto prop
               LJ::set_userprop($from_user, "renamedto", undef)
                   or return $fail->($out, "Error setting userprop.  Database unavailable?");

               # update user, set deleted
               LJ::update_user($from_user,
                               { raw => "journaltype='R', statusvis='D', statusvisdate=NOW()" });

               # update email aliases if applicable
               $dbh->do("DELETE FROM email_aliases WHERE rcpt=?",
                        undef, "$from_username\@$LJ::USER_DOMAIN");

               return $success->($out, "Redirection removed for $from_username => $to_username rename action");
           }
       }
   };

$cmd{'rename_show'} = 
   {
       des        => "View information about a rename.",
       privs      => [qw(moneyenter)],
       argsummary => '<value>',
       args       => [
                      'value' => "A hex or decimal tokenid, a full token string, or the username of a user who was renamed (source user)."
                      ],
       handler => sub {
           my ($dbh, $remote, $args, $out) = @_;

           return $fail->($out, "Not logged in.") unless $remote;
           return $fail->($out, "You don't have privileges needed to run this command.") 
               unless $remote->{'priv'}->{'moneyenter'};

           shift @$args; # remove command name
           my $value = shift @$args;

           return $fail->($out, "You must enter a value")
               unless $value;

           my @ren;
           my $hashref_array = sub {
               return values %{
                   $dbh->selectall_hashref(shift(), 'renid', undef, @_) || {}
               }
           };

           # they probably have this form of the token
           if ($value =~ /^([0-9a-f]{6})(\w{10})$/) {
               push @ren, $hashref_array->("SELECT * FROM renames WHERE renid=? AND token=?", hex $1, $2);

           # or maybe they have the tokenid?
           } elsif ($value =~ /^([0-9a-f]{1,6})/) {

               # try decimal, hex tokenids (user could enter either)
               push @ren, $hashref_array->("SELECT * FROM renames WHERE renid=? OR renid=?", $1, hex $1);

           # perhaps they have the token itself?
           } elsif ($value =~ /^(\w{10})$/) {

               push @ren, $hashref_array->("SELECT * FROM renames WHERE token=?", $1);

           # explicitly disallow special tokens ([movedaway], [manual], etc)
           # Note: "----------" is also a special token, but it's a valid username
           #       so we allow searching for it, 
           } elsif ($value =~ /^\[\w+\]$/) {
               return $fail->($out, "Cannot search for special tokens");
           }

           # if no ren, then maybe they gave a username
           push @ren, $hashref_array->("SELECT * FROM renames WHERE fromuser=?",
                                       LJ::canonical_username($value))
               unless @ren;

           return $fail->($out, "Could not find a matching rename.")
               unless @ren;
                    
           foreach my $ren (@ren) {
               push @$out, map { [ '', "$_: $ren->{$_}" ] } sort keys %$ren;
               push @$out, [ '', '' ];
           }

           return $success->($out, "[end]");
       }
   };

$cmd{'rename_reset'} = 
   {
       des        => "Lets account admins modify friends properties if selected incorrectly during a rename.",
       privs      => [qw(moneyenter)],
       argsummary => '<mode> <user>',
       args       => [
                      'mode' => "'friends' to reset friends, 'friendofs' to reset friends-ofs.",
                      'user' => "The username whose friends list should be cleared."
                      ],
       handler => sub {
           my ($dbh, $remote, $args, $out) = @_;

           return $fail->($out, "Not logged in.") unless $remote;
           return $fail->($out, "You don't have privileges needed to run this command.") 
               unless $remote->{'priv'}->{'moneyenter'};

           shift @$args; # remove command name
           my $mode = shift @$args;
           my $user = shift @$args;

           return $fail->($out, "Invalid mode, valid modes are 'friends' and 'friendofs'")
               unless $mode eq 'friends' || $mode eq 'friendofs';
           
           return $fail->($out, "You must enter a username")
               unless $user;

           my $u = LJ::load_user($user);
           return $fail->($out, "Invalid username")
               unless $u;

           if ($mode eq 'friends') {
               # TAG:FR:console:rename_reset:clear_friends
               # clear the given user's friends

               # delete existing friends
               my $friends = LJ::get_friends($cid, undef, undef, 'force') || {};
               if (LJ::remove_friend($cid, [ keys %$friends ])) {
                   return $success->($out, "Success, friends modified.");
               }

               # some failure?
               return $fail->($out, "Error modifying friends for user: '$user'");
           }

           if ($mode eq 'friendofs') {
               # TAG:FR:console:rename_reset:clear_friendofs
               # who lists this user as a friend?
               my $ids = $dbh->selectcol_arrayref("SELECT userid FROM friends WHERE friendid=?",
                                                  undef, $u->{'userid'}) || [];

               # delete friend edges with this user as the target
               if ($dbh->do("DELETE FROM friends WHERE friendid=?", undef, $u->{'userid'})) {

                   # clear memcache for all friend-ofs
                   LJ::memcache_kill($_, "friends") foreach @$ids;

                   return $success->($out, "Success, friend-ofs modified.");
               }

               # some failure?
               return $fail->($out, "Error modifying friend-ofs for user: '$user'");
           }
       }
   };


$cmd{'fraud_watch'} = 
   {
       des        => "Set or unset the fraud_watch userprop for a given user",
       privs      => [qw(moneyenter)],
       argsummary => '<action> <username>',
       args       => [
                      username => "Username who should have faud_watch set/unset",
                      action   => "Optional.  Either 'add' or 'remove' to set/unset the watch respectively.  Defaults to 'add'.",
                      ],
       handler => sub {
           my ($dbh, $remote, $args, $out) = @_;

           return $fail->($out, "Not logged in.") unless $remote;
           return $fail->($out, "You don't have privileges needed to run this command.") 
               unless $remote->{'priv'}->{'moneyenter'};

           shift @$args; # remove command name
           my ($action, $user) = @$args;

           return $fail->($out, "Invalid action: '$action'")
               unless $action eq 'add' || $action eq 'remove';

           my $u = LJ::load_user($user);
           return $fail->($out, "Invalid username: $user")
               unless $u;

           my $propval = $action eq 'add' ? 1 : 0;
           my $verb = $propval ? 'added' : 'removed';

           LJ::load_user_props($u, 'fraud_watch');

           return $fail->($out, "Fraud watch already $verb, nothing to do. [$u->{fraud_watch}]")
               if $u->{fraud_watch} == $propval;

           # set userprop
           LJ::set_userprop($u, "fraud_watch", $propval)
               or return $fail->($out, "Error setting 'fraud_watch' userprop.  Database unavailable?");

           # log to statushistory
           LJ::statushistory_add($u->{userid}, $remote->{userid}, 'fraud_watch', "fraud watch $verb");

           return $success->($out, "Fraud watch $verb for $u->{user}");
       }
   };

$cmd{'coupon_revoke'} = 
   {
       des        => "Revoke an unused coupon that was given out by the system (for a promo, etc)",
       privs      => [qw(moneyenter)],
       argsummary => '<username> <coupon_token>',
       args       => [
                      username => "Username that owns the coupon to be revoked.",
                      coupon   => "Coupon token.  A full coupon token string to be revoked.",
                      ],
       handler => sub {
           my ($dbh, $remote, $args, $out) = @_;

           return $fail->($out, "Not logged in.") unless $remote;
           return $fail->($out, "You don't have privileges needed to run this command.") 
               unless $remote->{'priv'}->{'moneyenter'};

           shift @$args; # remove command name
           my ($user, $coupon) = @$args;

           my $u = LJ::load_user($user);
           return $fail->($out, "Invalid username: $user")
               unless $u;

           return $fail->($out, "Invalid coupon format") 
               unless $coupon =~ /^(\d+)-(.+)$/;
           my ($cpid, $auth) = ($1, $2);
           my $cp = $dbh->selectrow_hashref
               ("SELECT * FROM coupon WHERE cpid=? AND auth=?", 
                undef, $cpid, $auth);
           return $fail->($out, "Invalid coupon, already revoked?") unless $cp;
           return $fail->($out, "Coupon owner does not match '$user'")
               unless $cp->{rcptid} == $u->{userid};
           return $fail->($out, "This command can only revoke coupons generated automatically " .
                          "by the system.")
               unless $cp->{ppayid} == 0;
           return $fail->($out, "This coupon has already been used in a cart.")
               unless $cp->{payid} == 0;

           $dbh->do("DELETE FROM coupon WHERE cpid=? AND auth=? AND rcptid=?",
                    undef, $cpid, $auth, $u->{userid});
           return $fail->($out, "Database Error: " . $dbh->errstr) if $dbh->err;

           # log to statushistory
           LJ::statushistory_add
               ($u->{userid}, $remote->{userid}, 'coupon_revoke', "Coupon revoked: $coupon");

           return $success->($out, "Coupon revoked: $coupon ($u->{user})");
       }
   };

1;
