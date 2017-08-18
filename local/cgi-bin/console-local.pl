use LJ::MemCache;
use Golem;

$cmd{'syn_delete'} = {
    'handler' => \&syn_delete,
    'privs' => [qw(syn_edit)],
    'des' => "Deletes syndication. Totally.",
    'argsummary' => '<username>',
    'args' => [
               'username' => "The username of the syndicated journal.",
               ],
    };

$cmd{'accounts_by_ip'} = {
    'handler' => \&accounts_by_ip,
    'privs' => [qw(finduser)],
    'des' => "Find accounts registered from given ip",
    'argsummary' => '<ip>',
    'args' => [
               'ip' => "IP address or beginning of IP address",
               ],
    };

$cmd{'expunge_user'} = {
    'handler' => \&expunge_user,
    'privs' => [qw(suspend)],
    'des' => "Expunge malicious user products. For accounts with a lot of comments you might need to run this command several times.",
    'argsummary' => '<username> <userid>',
    'args' => [
               'username' => "Malicious username",
               'userid' => "Malicious userid (must match username)",
               ],
    };

$cmd{'expunge_anonymous_comments'} = {
    'handler' => \&expunge_anonymous_comments,
    'privs' => [qw(suspend)],
    'des' => "Expunge all anonymous comments for a given post.",
    'argsummary' => '<username> <itemid> <talkid>',
    'args' => [
               'username' => "The username of the journal comment is in",
               'itemid' => "The itemid of the post to have a comment deleted from it",
               'talkid' => "delete comments starting this thread, 0 for all",

                   # note: the ditemid, actually, but that's too internals-ish?
               ],
     };


$cmd{'ljr_fif'} = {
    'handler' => \&ljr_fif,
    'privs' => [qw(siteadmin)],
    'des' => "ljr_fif manipulation.",
    'argsummary' => 'add|delete|list_excluded [<username>]',
    'args' => [
               'username' => "The username.",
               ],
    };

$cmd{'net'} = {
    'handler' => \&net,
    'privs' => [qw(siteadmin)],
    'des' => "ip blocks manipulation.",
    'argsummary' => 'add [CIDR] name|delete <CIDR>|ban_new_accounts <CIDR>|ban_comments <CIDR>|list',
    'args' => [
               'username' => "The username.",
               ],
    };

sub net {
		my ($dbh, $remote, $args, $out) = @_;
    my $err = sub { push @$out, [ "error", $_[0] ]; 0; };

    return $err->("This command needs at least 1 argument.")
      if @$args < 1;
	
    return $err->("Golem is not plugged-into this site.")
      unless $Golem::on;

    my $action = $args->[1];
    my $cidr = $args->[2];

    my $net_list = sub {
      my $dbr = LJ::get_db_reader();
      return $err->("Can't get database reader!") unless $dbr;
    
      my $sth = $dbr->prepare("select net_v4.* from net_v4");
      $sth->execute();
      die $dbr->errstr if $dbr->err;
    
      push @$out, [ '', "Known ip_v4 networks" ];
      while (my $row = $sth->fetchrow_hashref) {
      	my $tnet = Golem::get_net_by_id($row->{'id'}, {"with_props" => 1});

      	my $str = $tnet->{'net_with_mask'} . " [" . $row->{'name'} . "]";

    		if ($tnet->{'props'}->{'data'}->{'ban_new_accounts'}) {
    			$str .= ", ban_new_accounts";
    		}
    		if ($tnet->{'props'}->{'data'}->{'ban_comments'}) {
					$str .= ", ban_comments in ";
    			foreach my $userid (keys %{$tnet->{'props'}->{'data'}->{'ban_comments'}}) {
    				next unless $userid;

    				my $u = LJ::load_userid($userid);
    				if ($u) {
    					$str .= $u->{'user'} . ",";
    				}
    				else {
    					$str .= $userid . " (user does not exist),";
    				}
    			}
    			chop($str);
    		}

        push @$out, [ '', $str ];
      }
    };

    if ($action eq "list") {
    	$net_list->();
    }
    else {
      my $start_ip = $cidr;
      $start_ip =~ s/\/.+//o;

      my $net_mask;
      if ($cidr =~ /\//o) {
      	$net_mask = $cidr;
	      $net_mask =~ s/.+\///o;
	    }

      if (!$net_mask) {
	      $net_mask = "32";
	      push @$out, ['', "Netmask not specified, assuming /32"];
	    }

      return $err->("Invalid CIDR format. Required: 1.2.3.4/32")
  			unless $start_ip && $net_mask;

  		return $err->("Invalid IP address.")
  			unless Golem::is_ipv4($start_ip);

  		if ($action eq "add") {
  			my $name;
  			my $j = 3;
  			while ($args->[$j]) {
  				$name .= $args->[$j] . " ";
  				$j++;
  			}
  			chop($name) if $name;

  			return $err->("Please specify some net details")
  				unless $name;

  			my $sip = Golem::ipv4_str2int($start_ip);
  			my $eip = $sip + Golem::ipv4_mask2offset($net_mask);
			
			if ($eip - $sip > 10000) {
			  return $err->("IP block should be less than 10000 addresses.");
			}

  			for (my $i = $sip; $i <= $eip; $i++) {
  				my $tnet = Golem::get_containing_net($i);
  				if (!$tnet) {
  					$tnet = Golem::get_net($i, "32");
  				}

  				if ($tnet) {
  					return $err->("IP [" .
  						Golem::ipv4_int2str($i) .
  						"] is already contained in net [" . $tnet->{'ip_str'} . "/" . $tnet->{'mask'} . "]\n");
  				}
  			}

  			my $tnet = Golem::insert_net({
		      "ip_str" => $start_ip,
    		  "mask" => $net_mask,
      		"name" => $name
		      });

  			if ($tnet && !$tnet->{'err'}) {
	  			push @$out, ['', "Created net [" . $tnet->{'ip_str'} . "/" . $tnet->{'mask'} . "]\n"];
					
					$net_list->();
	  		}
	  		else {
	  			return $err->("Error creating net: " . $tnet->{'errstr'});
	  		}
  		}
  		elsif ($action eq "delete") {
  			my $tnet = Golem::get_net($start_ip, $net_mask);
  			if ($tnet) {
  				my $r = Golem::delete_net($tnet);
  				if ($r && !$r->{'err'}) {
  					push @$out, ['', "Deleted net [$start_ip/$net_mask]\n"];

  					$net_list->();
  				}
  				else {
  					return $err->("Error deleting net: " . $r->{'errstr'});
  				}
  			}
  			else {
  				return $err->("Net [$start_ip/$net_mask] does not exist.");
  			}
  		}
  		elsif ($action eq "ban_new_accounts") {
  			my $tnet = Golem::get_net($start_ip, $net_mask, {"with_props" => 1});
  			if ($tnet) {
  				$tnet->{'props'}->{'data'}->{'ban_new_accounts'} = 1;
  				$tnet = Golem::save_net($tnet);

  				if ($tnet && $tnet->{'err'}) {
  					return $err->("Error saving net [$start_ip/$net_mask]: " . $tnet->{'errstr'});
  				}
  				else {
  					$net_list->();
  				}
  			}
  			else {
  				return $err->("Net [$start_ip/$net_mask] does not exist.");
  			}
  		}
  		elsif ($action eq "ban_comments") {
  			my $u = LJ::load_user($args->[3]);
  			return $err->("ban_comments needs username as last parameter")
  				unless $u;

  			my $tnet = Golem::get_net($start_ip, $net_mask, {"with_props" => 1});
  			if ($tnet) {
  				$tnet->{'props'}->{'data'}->{'ban_comments'} = {}
  					unless defined($tnet->{'props'}->{'data'}->{'ban_comments'});

  				$tnet->{'props'}->{'data'}->{'ban_comments'}->{$u->{'userid'}} = time();
  				$tnet = Golem::save_net($tnet);

  				if ($tnet && $tnet->{'err'}) {
  					return $err->("Error saving net [$start_ip/$net_mask]: " . $tnet->{'errstr'});
  				}
  				else {
  					$net_list->();
  				}
  			}
  			else {
  				return $err->("Net [$start_ip/$net_mask] does not exist.");
  			}
  		}
		}
    
    return 1;
}


sub expunge_user {
    my ($dbh, $remote, $args, $out) = @_;
    my $err = sub { push @$out, [ "error", $_[0] ]; 0; };
    my $do_out = sub { push @$out, [ "", $_[0] ]; 1; };

    return $err->("This command takes 2 arguments") unless @$args eq 3;
    return $err->("You are not authorized to use this command.")
        unless ($remote && $remote->{'priv'}->{'suspend'});

    my $in_user = $args->[1];
    my $in_userid = $args->[2];

    my $u = LJ::load_user($in_user);
    return $err->("Supplied userid doesn't match user name.")
      unless $u->{'userid'} eq $in_userid;

    # copied from delete_all_comments (from talklib.pl)
    my $dbcm = LJ::get_cluster_master($u);
    return 0 unless $dbcm && $u->writer;

    my ($t, $loop) = (undef, 1);
    my $chunk_size = 200;

    my %affected_journals;
    my $n = 0;

    while ($loop &&
      ($t = $dbcm->selectrow_arrayref("SELECT journalid, jtalkid, nodetype, nodeid, state FROM talk2 WHERE ".
                                      "posterid=? LIMIT $chunk_size", undef, $u->{'userid'}))
       && $t && @$t)
    {
        my @processed = @$t;
        while(@processed) {
          my $state = pop @processed;
          my $nodeid = pop @processed;
          my $nodetype = pop @processed;
          my $jtalkid = pop @processed;
          my $journalid = pop @processed;

          $affected_journals{$journalid} = 1;
          $n++;

          foreach my $table (qw(talkprop2 talktext2 talk2)) {
            $u->do("DELETE FROM $table WHERE journalid=? AND jtalkid=?",
                   undef, $journalid, $jtalkid);
          }
          # (NB!) slow and suboptimal
          # (NB!) replycount will be updated on demand
          # (Sic!) may break threads consistency!!!

          my $memkey = [$journalid, "talk2:$journalid:$nodetype:$nodeid"];
          LJ::MemCache::delete($memkey);

          my $tu = LJ::load_userid($journalid);
          LJ::Talk::update_commentalter($tu, $nodeid);
        }
    }

    foreach my $j (keys %affected_journals) {
      my $tu = LJ::load_userid($j);
      LJ::wipe_major_memcache($tu); # is it ever needed?
    }
    my $m = scalar keys %affected_journals;

    $do_out->("$in_user: $n comments expunged from $m journals.");
}

sub expunge_anonymous_comments {
    my ($dbh, $remote, $args, $out) = @_;
    my $err = sub { push @$out, [ "error", $_[0] ]; 0; };
    my $do_out = sub { push @$out, [ "", $_[0] ]; 1; };

    return $err->("This command takes 3 arguments") unless @$args eq 4;
    return $err->("You are not authorized to use this command.")
        unless ($remote && $remote->{'priv'}->{'suspend'});

    my $in_user = $args->[1];

    my $dtalkid = $args->[3]+0;
    my $jtalkid_min = $dtalkid >> 8;

    my $ditemid = $args->[2]+0;
    my $jitemid = $ditemid >> 8;
    my $nodetype = 'L';

    my $u = LJ::load_user($in_user);
    return $err->("Supplied userid doesn't exists.")
      unless $u;

    my $dbcm = LJ::get_cluster_master($u);
    return 0 unless $dbcm && $u->writer;

    my $journalid = $u->{'userid'};
    my $nodeid = $jitemid;
    $jtalkid_min--; #start from this

    # see also delete_all_comments (from talklib.pl) for right sql request
    my $t = $dbcm->selectcol_arrayref("SELECT jtalkid FROM talk2 WHERE ".
                      "journalid=? AND nodeid=? ".
                      "AND posterid=0 AND jtalkid>?",
                       undef,
                       $journalid, $nodeid, $jtalkid_min);
    return 0 unless $t;

    my $num = LJ::Talk::delete_comments($u, $nodetype, $jitemid, $t);

    LJ::MemCache::delete([$journalid, "talk2:$journalid:$nodetype:$nodeid"]);
    LJ::MemCache::delete([$journalid, "talk2ct:$journalid"]);

    $do_out->("$num anonymous comments deleted.");

    return 1;
}

sub accounts_by_ip {
    my ($dbh, $remote, $args, $out) = @_;
    my $err = sub { push @$out, [ "error", $_[0] ]; 0; };
    my $do_out = sub { push @$out, [ "", $_[0] ]; 1; };
    
    return $err->("This command takes 1 argument") unless @$args eq 2;
    return $err->("You are not authorized to use this command.")
        unless ($remote && $remote->{'priv'}->{'finduser'});

    my $ip = $args->[1];
    
    my $dbr = LJ::get_db_reader();
    return $err->("Can't get database reader!") unless $dbr;

    my $sth = $dbh->prepare("SELECT userid, ip, FROM_UNIXTIME(logtime) FROM userlog where action = 'account_create' and ip like ?");
    $sth->execute($ip . "%");
    die $dbh->errstr if $dbh->err;
    
    while (my @row = $sth->fetchrow_array) {
      my $userid = $row[0];
      my $tip = $row[1];
      my $date = $row[2];
      my $u = LJ::load_userid($userid);
      my $user = $u->{'user'}; 
      my $status = $u->{'statusvis'};

      $do_out->("$user $tip $date $status");
    }
    return 1;
}

sub syn_delete
{
    my ($dbh, $remote, $args, $out) = @_;
    my $err = sub { push @$out, [ "error", $_[0] ]; 0; };

    return $err->("This command has 1 argument") unless @$args == 2;

    return $err->("You are not authorized to use this command.")
        unless ($remote && $remote->{'priv'}->{'syn_edit'});

    my $user = $args->[1];
    my $u = LJ::load_user($user);
    my $du = $u;
    my $uid = $u->{'userid'};

    return $err->("Invalid user $user") unless $u;
    return $err->("Not a syndicated account") unless $u->{'journaltype'} eq 'Y';

    # copied from bin/deleteusers.pl
    my $runsql = sub {
        my $db = $dbh;
        if (ref $_[0]) { $db = shift; }
        my $user = shift;
        my $sql = shift;
        $db->do($sql);
        return ! $db->err;
    };
    
    my $dbcm = LJ::get_cluster_master($du);

    # delete userpics
    {
        if ($du->{'dversion'} > 6) {
            $ids = $dbcm->selectcol_arrayref("SELECT picid FROM userpic2 WHERE userid=$uid");
        } else {
            $ids = $dbh->selectcol_arrayref("SELECT picid FROM userpic WHERE userid=$uid");
        }
  my $in = join(",",@$ids);
  if ($in) {
      $runsql->($dbcm, $user, "DELETE FROM userpicblob2 WHERE userid=$uid AND picid IN ($in)");
            if ($du->{'dversion'} > 6) {
                
                return $err->("error deleting from userpic2: " . $dbh->errstr)
                  unless $runsql->($dbcm, $user, "DELETE FROM userpic2 WHERE userid=$uid");

                return $err->("error deleting from userpicmap2: " . $dbh->errstr)
                  unless $runsql->($dbcm, $user, "DELETE FROM userpicmap2 WHERE userid=$uid");

                return $err->("error deleting from userkeywords: " . $dbh->errstr)
                  unless $runsql->($dbcm, $user, "DELETE FROM userkeywords WHERE userid=$uid");
            } else {
                return $err->("error deleting from userpic: " . $dbh->errstr)
                  unless $runsql->($dbh, $user, "DELETE FROM userpic WHERE userid=$uid");

                return $err->("error deleting from userpicmap: " . $dbh->errstr)
                  unless $runsql->($dbh, $user, "DELETE FROM userpicmap WHERE userid=$uid");
            }
  }
    }


    # delete posts
    while (($ids = $dbcm->selectall_arrayref("SELECT jitemid, anum FROM log2 WHERE journalid=$uid LIMIT 100")) && @{$ids})
    {
  foreach my $idanum (@$ids) {
      my ($id, $anum) = ($idanum->[0], $idanum->[1]);
      LJ::delete_entry($du, $id, 0, $anum);
  }
    }

    # misc:
    $runsql->($user, "DELETE FROM userusage WHERE userid=$uid");
    $runsql->($user, "DELETE FROM friends WHERE userid=$uid");
    $runsql->($user, "DELETE FROM friends WHERE friendid=$uid");
    $runsql->($user, "DELETE FROM friendgroup WHERE userid=$uid");
    $runsql->($dbcm, $user, "DELETE FROM friendgroup2 WHERE userid=$uid");
    $runsql->($user, "DELETE FROM memorable WHERE userid=$uid");
    $runsql->($dbcm, $user, "DELETE FROM memorable2 WHERE userid=$uid");
    $runsql->($dbcm, $user, "DELETE FROM userkeywords WHERE userid=$uid");
    $runsql->($dbcm, $user, "DELETE FROM memkeyword2 WHERE userid=$uid");
    $runsql->($user, "DELETE FROM userbio WHERE userid=$uid");
    $runsql->($dbcm, $user, "DELETE FROM userbio WHERE userid=$uid");
    $runsql->($user, "DELETE FROM userinterests WHERE userid=$uid");
    $runsql->($user, "DELETE FROM userprop WHERE userid=$uid");
    $runsql->($user, "DELETE FROM userproplite WHERE userid=$uid");   
    $runsql->($user, "DELETE FROM txtmsg WHERE userid=$uid");   
    $runsql->($user, "DELETE FROM overrides WHERE user='$du->{'user'}'");
    $runsql->($user, "DELETE FROM priv_map WHERE userid=$uid");
    $runsql->($user, "DELETE FROM infohistory WHERE userid=$uid");
    $runsql->($user, "DELETE FROM reluser WHERE userid=$uid");
    $runsql->($user, "DELETE FROM reluser WHERE targetid=$uid");
    $runsql->($user, "DELETE FROM userlog WHERE userid=$uid");
    $runsql->($user, "DELETE FROM syndicated WHERE userid=$uid");

    return $err->("error updating user uid $uid: " . $dbh->errstr)
      unless $runsql->($user, "UPDATE user SET statusvis='X', statusvisdate=NOW(), password='' WHERE userid=$uid");

    push @$out, [ '', "Deleted syndication accout $user." ];
    # log to statushistory
    LJ::statushistory_add($u->{userid}, $remote->{userid}, 'synd_delete',
                          "Syndication deleted.");
        
    LJ::MemCache::set("uidof:$user", "");
    return 1;
}


sub ljr_fif
{
    my ($dbh, $remote, $args, $out) = @_;
    my $err = sub { push @$out, [ "error", $_[0] ]; 0; };

    return $err->("This command needs at least 1 argument.")
      if @$args != 2 && @$args != 3;
	
    return $err->("LJR_FIF is not configured for this site.")
      unless $LJ::LJR_FIF;

    my $action = $args->[1];
    my $user = $args->[2];
    
    my $fifid = LJ::get_userid($LJ::LJR_FIF);
    return $err->("Invalid fif $LJ::LJR_FIF") unless $fifid;
    
    if ($action eq "list_excluded") {
      my $dbr = LJ::get_db_reader();
      return $err->("Can't get database reader!") unless $dbr;

      my $sth = $dbr->prepare("select user.*, friends.userid
        from user left outer join friends on
            friends.userid = ? and
            friends.friendid = user.userid
	where
	  user.userid < ? and
	  user.journaltype <> 'I' and
	  user.journaltype <> 'Y' and
	  friends.userid IS NULL;
        ");
      $sth->execute($fifid, $LJ::LJR_IMPORTED_USERIDS);
      die $dbr->errstr if $dbr->err;
    
      push @$out, [ '', "Excluded from ljr_fif friends" ];
      while (my $row = $sth->fetchrow_hashref) {
        push @$out, [ '', $row->{'user'} ];
      }
    }
    else {

      return $err->("You are not authorized to use this command.")
        unless ($remote && $remote->{'priv'}->{'siteadmin'});

      my $userid = LJ::get_userid($user);
      return $err->("Invalid user $user") unless $userid;
    
      my $action_text;
      if ($action eq "add") {
        LJ::add_friend($fifid, $userid);
        $action_text = "Added $user to";
      }
      elsif ($action eq "delete") {
        LJ::remove_friend($fifid, $userid);
        $action_text = "Deleted $user from";
      }

      push @$out, [ '', "$action_text ljr_fif friends." ];
    }
    
    return 1;
}


$cmd{'twit_set'} = {
    'handler' => \&twit_set,
    'des' => 'If you twit somebody you won\'t see his/her entries in ljr-fif.',
    'argsummary' => '<user>',
    'args' => [
               'user' => "This is the user you don't want to see in ljr-fif.",
               ],
    };

$cmd{'twit_unset'} = {
    'handler' => \&twit_set,
    'des' => 'Remove twit on a user.',
    'argsummary' => '<user>',
    'args' => [
               'user' => "The user's entries will be seen in ljr-fif.",
               ],
    };
   
$cmd{'twit_list'} = {
    'handler' => \&twit_list,
    'des' => 'List your twits (the users you don\'t see in ljr_fif).',
    'argsummary' => '[ <user> ]',
    'args' => [
               'user' => "Optional; list twits for any user if you have the 'finduser' priv. (this admin-only feature is broken right now)",
               ],
    };


sub twit_list
{
    my ($dbh, $remote, $args, $out) = @_;

    unless ($remote) {
        push @$out, [ "error", "You must be logged in to use this command." ];
        return 0;
    }

    # journal to list from
    my $j = $remote;

    unless ($remote->{'journaltype'} eq "P") {
        push @$out, [ "error", "You're not logged in as a person account." ];
        return 0;
    }
    
    my $twitedids = load_twit($j->{userid}) || [];
    my $us = LJ::load_userids(@$twitedids);
    my @userlist = map { $us->{$_}{user} } keys %$us;
 
    foreach my $username (@userlist) {
        push @$out, [ 'info', $username ];
    }
    push @$out, [ "info", "$j->{user} has not twitted any other users." ] unless @userlist;
    return 1;
}

sub twit_set
{
    my ($dbh, $remote, $args, $out) = @_;
    my $error = 0;

    unless ($remote) {
        push @$out, [ "error", "You must be logged in to use this command" ];
        return 0;
    }

    # journal to ban from:
    my $j;

    unless ($remote->{'journaltype'} eq "P") {
        push @$out, [ "error", "You're not logged in as a person account." ],
        return 0;
    }

    $j = $remote;
    
    my $user = $args->[1];
    my $twitid = LJ::get_userid($dbh, $user);

    unless ($twitid) {
        $error = 1;
        push @$out, [ "error", "Invalid user \"$user\"" ];
    }
    
    return 0 if ($error);    

    my $qtwitid = $twitid+0;
    my $quserid = $j->{'userid'}+0;

    # exceeded twit limit?
    if ($args->[0] eq 'twit_set') {
        my $twitlist = load_twit($j->{userid}) || [];
        if (scalar(@$twitlist) >= ($LJ::MAX_BANS || 5000)) {
            push @$out, [ "error", "You have reached the maximum number of twits.  Sorry." ];
            return 0;
        }
    }

    if ($args->[0] eq "twit_set") {
        twit_rel_set($j->{userid}, $twitid);
        $j->log_event('twit_set', { actiontarget => $twitid, remote => $remote });
	if (!LJ::check_twit($j->{userid},$twitid)) {
	    push @$out, [ "error", 
                     "An error occured!\n" . 
                "User $user ($twitid) is not twitted by $j->{'user'}." ];
	    return 0; 
	}
        push @$out, [ "info", "User $user ($twitid) twitted by $j->{'user'}." ];
        return 1;
    }

    if ($args->[0] eq "twit_unset") {
        twit_rel_unset($j->{userid}, $twitid);
        $j->log_event('twit_unset', { actiontarget => $twitid, remote => $remote });
	if (LJ::check_twit($j->{userid},$twitid)) {
	    push @$out, [ "error", 
                     "An error occured!\n" . 
                "User $user ($twitid) is still twitted by $j->{'user'}." ];
	    return 0; 
	}
        push @$out, [ "info", "User $user ($twitid) is not twitted by $j->{'user'} in ljr-fif." ];
        return 1;
    }

    return 0;
}


# des: Load user twits table
# UNCLUSTERED! Should be rewritten if we are going clusered
# args: userid
sub load_twit
{
    my $userid = $_[0];
    return undef unless $userid;
    my $u = LJ::want_user($userid);
    $userid = LJ::want_userid($userid);
    $db = LJ::get_db_reader();
    return $err->("Can't get database reader!") unless $db;
    return $db->selectcol_arrayref("SELECT twitid FROM 
           twits WHERE userid=?",  undef, $userid);
}

# des: Add the second user to the twit list of the first
# UNCLUSTERED! Should be rewritten if we are going clusered
# args: userid, twitid
sub twit_rel_set
{
    my ($userid,$twitid) = @_;
    return undef unless $userid;     return undef unless $twitid;
    $db = LJ::get_db_writer();
    return $err->("Can't get database reader!") unless $db;
    $db->do("INSERT INTO twits VALUES ($userid, $twitid)");
}

# des: Remove the second user from the twit list of the first
# UNCLUSTERED! Should be rewritten if we are going clusered
# args: userid, twitid
sub twit_rel_unset
{
    my ($userid,$twitid) = @_;
    return undef unless $userid;     return undef unless $twitid;
    $db = LJ::get_db_writer();
    return $err->("Can't get database reader!") unless $db;
    $db->do("DELETE FROM twits WHERE userid=$userid AND twitid=$twitid");
}

return 1;
