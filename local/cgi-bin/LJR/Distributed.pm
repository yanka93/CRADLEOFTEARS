use strict;

package LJR::Distributed;

my $warn = sub {
  print join ("\n", @_);
  print "\n";
};

my $err = sub {
  if (ref($_[0])) {
    my $dbh = shift;
    $dbh->rollback;
  }
  my %res = ();

  my $cstack = "\ncallstack:";
  my $i = 0;
  while ( 1 ) {
    my $tfunc = (caller($i))[3];
    if ($tfunc && $tfunc ne "") {
      if ($tfunc !~ /\_\_ANON\_\_/) {
        $cstack .= " " . $tfunc;
      }
      $i = $i + 1;
    }
    else {
      last;
    }
  }

  $res{"err"} = 1;
  $res{"errtext"} = join ("\n", @_);
  $res{"errtext"} .= $cstack;
  return \%res;
};

#
# created from LJ::Talk::Post::enter_comment
#
sub create_imported_comment {
  my ($journalu, $parent, $item, $comment) = @_;

  return $err->("Invalid user object passed.") unless LJ::isu($journalu);

  my $partid = $parent->{talkid};
  my $itemid = $item->{jitemid};
  my $posterid = $comment->{u} ? $comment->{u}{userid} : 0;

  # TODO: change this to be remote server specific
  my $time_float = "-3";
  my $comment_time;
  if ($comment->{datetime}) {
    $comment_time = "'" . $comment->{datetime} . "' + INTERVAL " . $time_float . " HOUR";
  }
  else {
    # deleted comments
    $comment_time = "'1970-01-01T00:00:00Z'";
  }

  my $jtalkid = LJ::alloc_user_counter($journalu, "T");
  return $err->("Could not generate a talkid necessary to import comment.") unless $jtalkid; 

  my $errstr;
  $journalu->talk2_do(
    "L", $itemid, \$errstr,
    "INSERT INTO talk2 ".
    "(journalid, jtalkid, nodetype, nodeid, parenttalkid, posterid, datepost, state) ".
    "VALUES (?,?,'L',?,?,?," . $comment_time . ",?)",
    $journalu->{userid}, $jtalkid, $itemid, $partid, $posterid, $comment->{state}
    );
  return $err->("error creating imported comment: " . $errstr) if ($errstr);

  $comment->{talkid} = $jtalkid;

  # add to poster's talkleft table, or the xfer place
  if ($posterid) {
    my $table;
    my $db = LJ::get_cluster_master($comment->{u});

    if ($db) {
      # remote's cluster is writable
      $table = "talkleft";
    } else {
      # log to global cluster, another job will move it later.
      $db = LJ::get_db_writer();
      $table = "talkleft_xfp";
    }
    my $pub  = $item->{'security'} eq "public" ? 1 : 0;
    if ($db) {
      $db->do(
        "INSERT INTO $table (userid, posttime, journalid, nodetype, ".
        "nodeid, jtalkid, publicitem) VALUES (?, UNIX_TIMESTAMP(" . $comment_time . "), " .
        "?, 'L', ?, ?, ?)",
        undef, $posterid, $journalu->{userid}, $itemid, $jtalkid, $pub);
      return $err->($db->errstr) if $db->err;
    } else {
      # both primary and backup talkleft hosts down.  can't do much now.
    }
  }

  $journalu->do(
    "INSERT INTO talktext2 (journalid, jtalkid, subject, body) ".
    "VALUES (?, ?, ?, ?)", undef,
    $journalu->{userid}, $jtalkid, $comment->{subject}, 
    LJ::text_compress($comment->{body})
    );
  return $err->($journalu->errstr) if $journalu->err;

  my %talkprop = %{$comment->{props}}; # propname -> value

  if (%talkprop) {
    my $values;
    my $hash = {};
    foreach (keys %talkprop) {
      my $p = LJ::get_prop("talk", $_);
      next unless $p;
      $hash->{$_} = $talkprop{$_};
      my $tpropid = $p->{'tpropid'};
      my $qv = $journalu->quote($talkprop{$_});
      $values .= "($journalu->{'userid'}, $jtalkid, $tpropid, $qv),";
    }
    
    if ($values) {
      chop $values;
      $journalu->do("INSERT INTO talkprop2 (journalid, jtalkid, tpropid, value) VALUES $values");
      return $err->($journalu->errstr) if $journalu->err;
    }
  }

  # update the "replycount" summary field of the log table
  if ($comment->{state} eq 'A' || $comment->{state} eq 'F') {
    LJ::replycount_do($journalu, $itemid, "incr");
  }

  # update the "hasscreened" property of the log item if needed
  if ($comment->{state} eq 'S') {
    LJ::Talk::screenedcount_do($journalu, $itemid, "incr");
  }
    
  return $comment;
}

sub create_imported_comments {
  my ($ru, $local_user, $throttle_num, $throttle_sec) = @_;

  if (!$throttle_num) {
    $throttle_num = 1000;
  }
  if (!$throttle_sec) {
    $throttle_sec = 20;
  }

  my $dbr = LJ::get_db_reader();
  return $err->("Can't get database reader!") unless $dbr;

  # local journal where comment is to be created
  my $journalu = LJ::load_user($local_user, 1);

  $ru = LJR::Distributed::get_cu_field($ru, "cached_comments_maxid");
  $ru->{cached_comments_maxid} = 0 if not defined $ru->{cached_comments_maxid};

  $ru = LJR::Distributed::remote_local_assoc($ru, $journalu);
  return $err->("error while getting remote-local association: " . $ru->{errtext})
    if $ru->{err};

  # check if someone deleted imported comments,
  # delete inconsistent ljr_remote_comments entries and
  # update corresponding ljr_remote_users.created_comments_maxid
  my $sth_cc = $dbr->prepare("SELECT count(*) from ljr_remote_comments l
    LEFT JOIN talk2 t on l.local_journalid = t.journalid and l.local_jtalkid = t.jtalkid
    WHERE l.local_journalid = ? and t.journalid is NULL;");
  $sth_cc->execute($journalu->{"userid"});

  my $deleted_num;
  if (($deleted_num = $sth_cc->fetchrow_array) && $deleted_num && $deleted_num gt 0) {
    my $dbh = LJ::get_db_writer();
    return $err->("Can't get database writer!") unless $dbh;

    $dbh->do(
      "DELETE ljr_remote_comments FROM
      ljr_remote_comments LEFT JOIN talk2 ON
      ljr_remote_comments.local_journalid = talk2.journalid AND
      ljr_remote_comments.local_jtalkid = talk2.jtalkid
      WHERE
        ljr_remote_comments.local_journalid = ? and
        talk2.journalid is NULL;",
      undef, $journalu->{"userid"});
    return $err->($dbh->errstr) if $dbh->err;
    
    $dbh->do ("UPDATE ljr_remote_users
      SET created_comments_maxid = created_comments_maxid - ?
      WHERE ru_id=? and local_journalid=?",
      undef, $deleted_num, $ru->{"ru_id"}, $journalu->{"userid"}
      );
    return $err->($dbh->errstr) if $dbh->err;

    $ru->{"created_comments_maxid"} = $ru->{"created_comments_maxid"} - $deleted_num;
  }
  $sth_cc->finish;

  # if we haven't posted all the cached comments, do it now
  if ($ru->{"created_comments_maxid"} < $ru->{"cached_comments_maxid"}) {
    LJ::load_props("talk");
    return $err->("Can't load talkprops.") unless $LJ::CACHE_PROP{talk};

    my $sth = $dbr->prepare("
      SELECT ljr_cached_comments.* FROM ljr_cached_comments LEFT JOIN ljr_remote_comments
      ON ljr_cached_comments.cc_id = ljr_remote_comments.cc_id and
      ljr_remote_comments.local_journalid = ?
      WHERE ljr_cached_comments.ru_id = ? and ljr_remote_comments.cc_id is NULL
      ");
    $sth->execute($journalu->{"userid"}, $ru->{"ru_id"});
 
    my $up; # local user which owns imported comment
    my $item; # local journal entry where the comment is to be imported
    my $parent; # parent comment (0 for comments to the entry)
    my $comment; # comment being created
    my $i = 0; # counter

    while (my $r = $sth->fetchrow_hashref) {
      if ($r->{posterid}) {
        $up = LJR::Distributed::get_cached_user({ru_id => $r->{ru_id}});

        $up->{ru_id} = 0;
        $up->{userid} = $r->{posterid};
        $up->{username} = "";
        $up = LJR::Distributed::get_cached_user($up);
        
        $up = LJR::Distributed::get_cu_field($up, "local_commenterid");
        $up = LJ::load_userid ($up->{local_commenterid});
      }
      else {
        $up = undef;
      }

      $item = LJR::Distributed::get_local_itemid ($journalu, $r->{ru_id}, $r->{jitemid});
      
      if (!$item->{itemid}) {
        $warn->("Can't find corresponding local entry while importing " .
          $journalu->{name} .
          " (remote entry " . $r->{ru_id} . ":" . $r->{jitemid} . ").");
        next;
      }

      $item = $item->{item};
      
      if ($r->{"parentid"}) {
        $parent = LJR::Distributed::get_local_commentid(
          $journalu->{"userid"}, $r->{"ru_id"}, $r->{"parentid"});
    
        if (!$parent->{"talkid"}) {
          $warn->(
            "Can't find corresponding parent comment while importing " .
            $journalu->{"name"} .
            " (remote parent id: " . $r->{"parentid"} . "), " .
            "attaching to the local entry (" . $item->{"jitemid"} . ")"
            );
                $parent->{"talkid"} = 0;
        }
      }
      else {
        $parent->{"talkid"} = 0;
      }

      my $sth1 = $dbr->prepare("SELECT tpropid, value FROM ljr_cached_comprops WHERE cc_id=?");
      $sth1->execute($r->{cc_id});

      my %props = ();
      while (my $p = $sth1->fetchrow_hashref) {
        $props{$LJ::CACHE_PROPID{talk}->{$p->{tpropid}}->{name}} = $p->{value};
      }
      
      $sth1->finish();

      $comment = {
        u => $up,
        subject => $r->{subject},
        body => $r->{body},
        state => $r->{state},
        datetime => $r->{date},
        props => \%props,
        };

      $comment = LJR::Distributed::create_imported_comment($journalu, $parent, $item, $comment);
      return $err->("error while creating imported comment: " . $comment->{errtext})
        if $comment->{err};

      my $dbh = LJ::get_db_writer();
      return $err->("Can't get database writer!") unless $dbh;
  
      $dbh->do(
        "INSERT INTO ljr_remote_comments VALUES (?,?,?)",
        undef, $r->{cc_id}, $journalu->{userid}, $comment->{talkid});
      return $err->($dbh->errstr) if $dbh->err;

      $dbh->do("UPDATE ljr_remote_users
        SET created_comments_maxid = ?
        WHERE ru_id=? and local_journalid=?",
        undef, $r->{commentid}, $ru->{ru_id}, $journalu->{userid}
        );
      return $err->($dbh->errstr) if $dbh->err;

      $i = $i + 1;
      if ($i % $throttle_num == 0) {
        sleep $throttle_sec;
      }
    }
    $sth->finish();
  }

  return $ru;
}

sub cache_comment {
  my ($c) = @_;

  if ($c->{id}) {
    $c->{commentid} = $c->{id};
  }
  if (!$c->{state}) {
    $c->{state} = "A";
  }
  
  return $err->("cache_comment: no ru_id specified.") unless $c->{ru_id};
  return $err->("cache_comment: no comment id specified.") unless $c->{commentid};
  return $err->("cache_comment: no jitemid specified.") unless $c->{jitemid};

  if ($c->{state} ne "D") {
    return $err->("cache_comment: no body specified.") unless $c->{body};
    return $err->("cache_comment: no date specified.") unless $c->{date};
  }
  else {
    $c->{body} = "" unless $c->{body};
    $c->{date} = "" unless $c->{date};
  }

  if (!$c->{posterid}) {
    $c->{posterid} = 0;
  }
  if (!$c->{parentid}) {
    $c->{parentid} = 0;
  }
  if (!$c->{subject}) {
    $c->{subject} = "";
  }

  my $dbr = LJ::get_db_reader();
  return $err->("Can't get database reader!") unless $dbr;

  my $cc_id1 = $dbr->selectrow_array(
    "SELECT cc_id FROM ljr_cached_comments " .
    "WHERE ru_id=? and commentid=?",
    undef, $c->{ru_id}, $c->{commentid});

  if ($cc_id1) {
    my $existing_comment = $dbr->selectrow_hashref(
      "SELECT * FROM ljr_cached_comments " .
      "WHERE ru_id=? and commentid=?",
      undef, $c->{ru_id}, $c->{commentid});
    
    # it just works (somehow clears some UTF8 flag)
    $c->{body} = pack('C*', unpack('C*', $c->{body}))
      if $c->{body};
    $c->{subject} = pack('C*', unpack('C*', $c->{subject}))
      if $c->{subject};

    if (
      $c->{jitemid} != $existing_comment->{jitemid} ||
      $c->{parentid} != $existing_comment->{parentid} ||
      $c->{subject} ne $existing_comment->{subject} ||
      $c->{body} ne $existing_comment->{body} ||
      $c->{date} ne $existing_comment->{date} ||
      ($c->{posterid} != 0 && $c->{posterid} != $existing_comment->{posterid})
      ) {

      my $ru = LJR::Distributed::get_cached_user({ru_id => $c->{ru_id}});
      return $err->("There already exists different comment id=$c->{commentid} for user $ru->{username} (ru_id = $ru->{ru_id}).!") ;
    }

    my $dbh = LJ::get_db_writer();
    return $err->("Can't get database writer!") unless $dbh;
    
    $dbh->do(
      "UPDATE ljr_cached_comments " .
      "SET posterid=?, state=? " .
      "WHERE ru_id=? and commentid=?",
      undef, $c->{posterid}, $c->{state}, $c->{ru_id}, $c->{commentid});
    return $err->($dbh->errstr) if $dbh->err;
  }
  else {
    my $dbh = LJ::get_db_writer();
    return $err->("Can't get database writer!") unless $dbh;

    # start transaction
    $dbh->begin_work;
    return $err->($dbh->errstr) if $dbh->err;

    $dbh->do(
      "INSERT INTO ljr_cached_comments " .
      "(ru_id, commentid, posterid, state, jitemid, parentid, " .
      "subject, body, date) VALUES " .
      "(?,?,?,?,?,?,?,?,?)",
      undef, $c->{ru_id}, $c->{commentid}, $c->{posterid}, $c->{state},
      $c->{jitemid}, $c->{parentid}, $c->{subject}, $c->{body}, $c->{date});
    return $err->($dbh, $dbh->errstr) if $dbh->err;

    # get newly cached comment id
    $c->{cc_id} = $dbh->{mysql_insertid};

    # save props
    LJ::load_props("talk");
    return $err->($dbh, "Can't load talkprops.") unless $LJ::CACHE_PROP{talk};

    if ($c->{props}) {
      foreach my $k (keys %{$c->{props}}) {
        if (${$LJ::CACHE_PROP{talk}}{$k}->{tpropid}) {
          $dbh->do(
            "INSERT INTO ljr_cached_comprops VALUES (?, ?, ?) ",
            undef,
            $c->{cc_id},
            ${$LJ::CACHE_PROP{talk}}{$k}->{tpropid},
            $c->{props}->{$k}
          );
          return $err->($dbh,
        "Error caching property \"" . $k . "\": " . $dbh->errstr)
      if $dbh->err;
  }
      }
    }

    $dbh->commit;
    return $err->($dbh->errstr) if $dbh->err;
  }

  return $c;
}

#
# copied from LJ::alloc_global_counter
#
sub alloc_global_counter {
  my ($dom, $recurse) = @_;

  return $err->("alloc_global_counter: invalid domain!") unless $dom =~ /^[I]$/;
  my $dbh = LJ::get_db_writer();
  return $err->("Can't get database writer!") unless $dbh;

  my $newmax;
  my $uid = 0; # userid is not needed, we just use '0'

  my $rs = $dbh->do(
    "UPDATE ljr_counter
    SET max=LAST_INSERT_ID(max+1) WHERE journalid=? AND area=?",
    undef, $uid, $dom);

  if ($rs > 0) {
    $newmax = $dbh->selectrow_array("SELECT LAST_INSERT_ID()");
    return $newmax;
  }

  return undef if $recurse;

  # no prior counter rows - initialize one.
  if ($dom eq "I") {
    $newmax = 0; 
  }
  $newmax += 0;

  $dbh->do("INSERT IGNORE INTO ljr_counter (journalid, area, max) VALUES (?,?,?)",
    undef, $uid, $dom, $newmax) or return undef;
  return LJR::Distributed::alloc_global_counter($dom, 1);
}

#
# copied from LJ::User::load_identity_user
#
sub get_imported_user {
  my ($ru) = @_;
  
  return $err->("remote_serverid is not specified.")
    unless $ru->{serverid};
  return $err->("remote_username is not specified.")
    unless $ru->{username};

  my $dbr = LJ::get_db_reader();
  return $err->("Can't get database reader!") unless $dbr;

  $ru = LJR::Distributed::get_remote_server_byid($ru);
  return $err->("Server " . $ru->{serverid} . "doesn't exist!") unless $ru->{"servername"};

  my $serverurl = $ru->{servername};
  my $identity = $serverurl . "/users/" . $ru->{username};

  my $uid = $dbr->selectrow_array(
    "SELECT userid FROM identitymap WHERE idtype=? AND identity=?",
    undef, "G", $identity);

  if (!$uid) {
    my $impuser = 'imp_' . LJR::Distributed::alloc_global_counter('I');

    $uid = LJ::create_account({
        caps => undef,
        user => $impuser,
        name => $impuser,
        journaltype => 'I',
        imported => 1,
      });
    return $err->("can't create account!") unless $uid;

    my $dbh = LJ::get_db_writer();
    return $err->("Can't get database writer!") unless $dbh;

    $dbh->do(
      "INSERT INTO identitymap (idtype, identity, userid) VALUES (?,?,?)",
      undef, "G", $identity, $uid);
    return $err->($dbh->errstr) if $dbh->err;

    $uid = $dbr->selectrow_array(
      "SELECT userid FROM identitymap WHERE idtype=? AND identity=?",
      undef, "G", $identity);
    return $err->("can't get identity userid for " . $identity) unless $uid;
  }

  $ru->{commenterid} = $uid;
  return $ru;
}

#
# gets ljr_cached_users field (identified with ru_id)
#
sub get_cu_field {
  my ($ru, $field) = @_;

  my $truid;
  if (ref($ru)) {
    $truid = $ru->{ru_id}
  }
  else {
    $truid = $ru;
  }
  
  return $err->("get_cu_field: ru_id is not specified.")
    unless $truid;
  return $err->("get_cu_field: field is not specified.")
    unless $field;

  my $dbr = LJ::get_db_reader();
  return $err->("Can't get database reader!") unless $dbr;

  my $tvalue = $dbr->selectrow_array(
    "SELECT $field FROM ljr_cached_users " .
    "WHERE ru_id=?", undef, $truid);

  if (ref($ru)) {
    $ru->{$field} = $tvalue;
    return $ru;
  }
  else {
    return $tvalue;
  }
}

#
# currently overwrites everything. maybe it shouldn't.
#
sub set_cu_field {
  my ($ru, $field, $value) = @_;

  return $err->("set_cu_field: no ru_id in ru hashref.")
    unless $ru->{ru_id};
  return $err->("set_cu_field: field is not specified (ru_id = $ru->{ru_id}).")
    unless $field;
  return $err->("set_cu_field: field value is not specified (field = $field).")
    unless defined($value);

  my $dbr = LJ::get_db_reader();
  return $err->("Can't get database reader!") unless $dbr;

  my $existing_field_value = $dbr->selectrow_array(
    "SELECT $field FROM ljr_cached_users WHERE ru_id = ?", undef, $ru->{ru_id});
  
  if (
    defined($existing_field_value) && defined($value) && $existing_field_value != $value ||
    $existing_field_value && !defined($value) ||
    !defined($existing_field_value) && $value
    ) {
    my $dbh = LJ::get_db_writer();
    return $err->("Can't get database writer!") unless $dbh;

    if ($existing_field_value) {
      $warn->(
        "ljr_cached_users: overwriting " . $field .  " [" . $existing_field_value . "] " .
        "with [ " . $value . " ] " .
        "for ru_id = " . $ru->{ru_id});
    }

    $dbh->do(
      "UPDATE ljr_cached_users SET $field = ? WHERE ru_id = ?",
      undef, $value, $ru->{ru_id});
    return $err->("error updating ljr_cached_users.${field}: " . $dbh->errstr) if $dbh->err;
  }

  $ru->{$field} = $value;
  return $ru;
}

sub match_remote_server {
  my ($remote_server) = @_;
  my %res = ();

  return $err->("no server name specified!") unless $remote_server;

  my $dbr = LJ::get_db_reader();
  return $err->("Can't get database reader!") unless $dbr;
  
  if ($remote_server =~ /.*\.(\w+\.\w+)\/?/) {
    $remote_server = $1;
  }
  
  my ($serverid, $servername, $servertype) = $dbr->selectrow_array(
    "SELECT remote_serverid, canonical_url, blog_type FROM ljr_remote_servers " .
    "WHERE canonical_url like '%" . $remote_server . "'");

  $res{"serverid"} = $serverid;
  $res{"servertype"} = $servertype;
  $res{"servername"} = $servername;
  return \%res;
}

# <LJFUNC>
# name: LJR::Distributed::get_remote_server
# des: get remote server identification at the local site
# returns: $hashref->{serverid} or $hashref->{err} and $hashref->{errtext}
# args: remote_server
# des-remote_server: canonical name of the remote server
# </LJFUNC>
sub get_remote_server {
  my ($remote_server) = @_;
  my %res = ();

  return $err->("no server name specified!") unless $remote_server;

  my $dbr = LJ::get_db_reader();
  return $err->("Can't get database reader!") unless $dbr;

  # TODO: maybe we'll have to change this to support https or smth else?
  # TODO: note that we'll have to change LJ::Simple also, which currently
  # TODO: work only with http://
  if ($remote_server !~ /^http\:\/\//) {
    $remote_server = "http://" . $remote_server;
  }

  my ($serverid, $servertype) = $dbr->selectrow_array(
    "SELECT remote_serverid, blog_type FROM ljr_remote_servers " .
    "WHERE canonical_url=?", undef, $remote_server);

  if (!$serverid) {
    my $dbh = LJ::get_db_writer();
    return $err->("Can't get database writer!") unless $dbh;

    $dbh->do(
      "INSERT INTO ljr_remote_servers (canonical_url) VALUES (?)",
      undef, $remote_server);
    return $err->($dbh->errstr) if $dbh->err;

    $serverid = $dbh->{mysql_insertid};
    return $err->("Can't get serverid!") unless $serverid;
  }

  $res{"serverid"} = $serverid;
  $res{"servertype"} = $servertype;
  $res{"servername"} = $remote_server;
  return \%res;
}

sub get_remote_server_byid {
  my ($ru) = @_;

  if ($ru->{"serverid"}) {
    my $dbr = LJ::get_db_reader();
    return $err->("No database reader available!") unless $dbr;
    
    ($ru->{"servername"}, $ru->{"servertype"}) =
      $dbr->selectrow_array(
        "SELECT canonical_url, blog_type " .
        "FROM ljr_remote_servers WHERE remote_serverid=?",
        undef, $ru->{serverid});
  }
  return $ru;
}

sub remote_local_assoc {
  my ($ru, $u) = @_;

  return $err->("remote_local_assoc: no ru_id in ru hashref.")
    unless $ru->{ru_id};
  return $err->("remote_local_assoc: no userid in user hashref.")
    unless $u->{userid};

  my $dbr = LJ::get_db_reader();
  return $err->("No database reader available!") unless $dbr;
  
  my ($r) = $dbr->selectrow_array(
    "SELECT count(*) FROM ljr_remote_users " .
    "WHERE ru_id=? and local_journalid=?",
    undef, $ru->{ru_id}, $u->{userid});
  if ($r) {
    $ru->{created_comments_maxid} = $dbr->selectrow_array(
      "SELECT created_comments_maxid FROM ljr_remote_users " .
      "WHERE ru_id=? and local_journalid=?",
      undef, $ru->{ru_id}, $u->{userid});

    $ru->{assoc_existed} = 1;
  }
  else {
    $ru->{assoc_existed} = 0;
    $ru->{created_comments_maxid} = 0;

    my $dbh = LJ::get_db_writer();
    return $err->("Can't get database writer!") unless $dbh;

    $dbh->do(
      "INSERT ljr_remote_users SET ru_id = ?, local_journalid = ?",
      undef, $ru->{ru_id}, $u->{userid},
      );
    return $err->($dbh->errstr) if $dbh->err;
  }

  return $ru;
}

sub change_identity {
  my ($dbh, $remote_serverid, $old_username, $new_username) = @_;

  my $dbr = LJ::get_db_reader();
  return $err->("No database reader available!") unless $dbr;

  my ($serverurl, $servertype) = $dbr->selectrow_array(
    "SELECT canonical_url, blog_type FROM ljr_remote_servers " .
    "WHERE remote_serverid=?", undef, $remote_serverid);
  return $err->("Server " . $remote_serverid . "doesn't exist!") unless $serverurl;

  my $old_identity = $serverurl . "/users/" . $old_username;
  my $new_identity = $serverurl . "/users/" . $new_username;

  my $uid = $dbr->selectrow_array(
    "SELECT userid FROM identitymap WHERE idtype=? AND identity=?",
    undef, "G", $old_identity);
  return $err->("can't get identity userid for " . $old_identity) unless ($uid);

  $dbh->do(
    "UPDATE identitymap SET identity = ? WHERE userid = ?",
    undef, $new_identity, $uid);
  return $err->("Error changing identity: " . $dbh->errstr) if $dbh->err;

  return {'err' => 0};
}

# <LJFUNC>
# name: LJR::Distributed::get_cached_user
# des: get cached user hashref
# des:   $ru->{ru_id}
# des:   $ru->{serverid}
# des:   $ru->{userid}
# des:   $ru->{username}
# des:   $ru->{type}
# returns: $ru or $ru->{err} and $ru->{errtext}
# args: $ru->{serverid} && ($ru->{userid} and/or $ru->{username})
# </LJFUNC>
sub get_cached_user {
  my ($ru) = @_;

  my $dbr = LJ::get_db_reader();
  return $err->("No database reader available!") unless $dbr;
  my $dbh = LJ::get_db_writer();
  return $err->("Can't get database writer!") unless $dbh;

  if ($ru->{'ru_id'}) {
    ($ru->{'serverid'}, $ru->{'userid'}, $ru->{'username'}) =
      $dbr->selectrow_array(
        "SELECT remote_serverid, remote_userid, remote_username " .
        "FROM ljr_cached_users WHERE ru_id=?",
        undef, $ru->{'ru_id'});
  }
  else {
    return $err->("remote_serverid is not specified.") unless $ru->{'serverid'};

    my $remote_type;
    if ($ru->{'type'}) {
      $remote_type = $ru->{'type'}
    }
    else {
      $remote_type = "P";
    }

    if ($ru->{'username'} && $ru->{'userid'}) {
      my $update_ljr_cached_users = sub {
        $dbh->do(
          "UPDATE ljr_cached_users
           SET remote_userid = ?, remote_username = ?
           WHERE ljr_cached_users.ru_id = ?",
          undef, $ru->{'userid'}, $ru->{'username'}, $ru->{'ru_id'});
        return $err->($dbh, $dbh->errstr) if $dbh->err;

        $ru->{'type'} = $dbr->selectrow_array(
          "SELECT remote_type FROM ljr_cached_users WHERE ru_id = ?",
          undef, $ru->{'ru_id'});

        return;
      };

      my $rename_remote_user = sub {
        my ($ru_id, $old_username, $new_username) = @_;

        my $rename_seq = $dbr->selectrow_array(
          "SELECT max(rename_seq) FROM ljr_remote_renamed WHERE ru_id=?",
          undef, $ru_id);

        $rename_seq++;

        # save old username
        $dbh->do(
          "INSERT ljr_remote_renamed (ru_id, rename_seq, old_username, new_username)
          VALUES (?, ?, ?, ?)",
          undef, $ru_id, $rename_seq, $old_username, $new_username);
        return $err->($dbh, $dbh->errstr) if $dbh->err;

        # update identitymap
        my $r = change_identity($dbh, $ru->{'serverid'}, $old_username, $new_username);
        return $err->($dbh, $r->{"errtext"}) if $r->{"err"};

        return;
      };

      my $reid_remote_user = sub {
        my ($remote_username, $old_ru_id, $new_ru_id) = @_;

        my $reid_seq = $dbr->selectrow_array(
          "SELECT max(reid_seq) FROM ljr_remote_reided " .
          "WHERE remote_serverid=? and remote_username=?",
          undef, $ru->{'serverid'}, $remote_username);

        $reid_seq++;

        $dbh->do(
          "INSERT INTO ljr_remote_reided (remote_serverid, remote_username, 
          reid_seq, old_ru_id, new_ru_id) VALUES (?, ?, ?, ?, ?)",
          undef, $ru->{'serverid'}, $remote_username, $reid_seq, $old_ru_id, $new_ru_id);
        return $err->($dbh, $dbh->errstr) if $dbh->err;

        return;
      };

      my ($username_ru_id, $username_userid, $username_local_commenterid) = $dbr->selectrow_array(
        "SELECT ru_id, remote_userid, local_commenterid FROM ljr_cached_users " .
        "WHERE remote_serverid=? and remote_username=?",
        undef, $ru->{'serverid'}, $ru->{'username'});

      my ($userid_ru_id, $userid_username, $userid_local_commenterid) = $dbr->selectrow_array(
        "SELECT ru_id, remote_username, local_commenterid FROM ljr_cached_users " .
        "WHERE remote_serverid=? and remote_userid=?",
        undef, $ru->{'serverid'}, $ru->{'userid'});

      my $r;

      if ($username_ru_id && $userid_ru_id) {
        if ($username_userid && $userid_username) {
          if ($username_ru_id ne $userid_ru_id) {
    
            $warn->("get_cached_user: " .
              $ru->{'username'} . " points to ${username_userid}, " .
              $ru->{'userid'} . " points to ${userid_username}; " .
              "trying to solve.");

            $dbh->begin_work;

            $r = $reid_remote_user->($ru->{'username'}, $username_ru_id, $userid_ru_id);
            return $err->("gcu1.1: " . $r->{'errtext'}) if $r->{'err'};

            my $has_ex = 1;
            my $ex_suff;
            my $ex_name;
            
            while ($has_ex) {
              $ex_name = "ex_" . $ru->{'username'} . ($ex_suff ? ("_" . $ex_suff) : "");

              $has_ex = $dbh->selectrow_array(
                "SELECT count(remote_username) FROM ljr_cached_users
                 WHERE remote_serverid=? and remote_username=?",
                undef, $ru->{'serverid'}, $ex_name);

              $ex_suff = $ex_suff + 1;
            }
                
            $r = $rename_remote_user->($username_ru_id, $ru->{'username'}, $ex_name);
            return $err->("gcu1.2: " . $ru->{'username'} . ": " . $r->{'errtext'}) if $r->{'err'};

            $dbh->do(
              "UPDATE ljr_cached_users SET remote_username = ?
               WHERE ljr_cached_users.ru_id = ?",
              undef, $ex_name, $username_ru_id);
            return $err->($dbh, "gcu1.3: ${ex_name}:" . $dbh->errstr) if $dbh->err;

            $r = $rename_remote_user->($userid_ru_id, $userid_username, $ru->{'username'});
            return $err->("gcu1.4: " . $r->{'errtext'}) if $r->{'err'};

            $dbh->do(
              "UPDATE ljr_cached_users SET remote_username = ?
               WHERE ljr_cached_users.ru_id = ?",
              undef, $ru->{'username'}, $userid_ru_id);
            return $err->($dbh, "gcu1.5: " . $dbh->errstr) if $dbh->err;

            $ru->{'ru_id'} = $userid_ru_id;

            $r = $update_ljr_cached_users->();
            return $err->("gcu1.6: " . $r->{'errtext'}) if $r->{'err'};

            $dbh->commit;
          }
          else {
            $ru->{'ru_id'} = $username_ru_id;
            $r = $update_ljr_cached_users->();
            return $err->("gcu1.7: " . $r->{'errtext'}) if $r->{'err'};
          }
        }
        elsif (! $username_userid && ! $username_local_commenterid && $userid_username) {
          $dbh->begin_work;
          $ru->{'ru_id'} = $userid_ru_id;

          # ljr_cached_users for $ru->{'username'} doesn't have remote_userid
          # it's bogus. deleting it.
          $dbh->do ("DELETE FROM ljr_cached_users WHERE ru_id=?", undef, $username_ru_id);
          return $err->($dbh, "gcu1.2: " . $dbh->errstr) if $dbh->err;

          if ($userid_username ne $ru->{'username'}) {
            $r = $rename_remote_user->($ru->{'ru_id'}, $userid_username, $ru->{'username'});
            return $err->("gcu1.2: " . $r->{'errtext'}) if $r->{'err'};
          }

          $r = $update_ljr_cached_users->();
          return $err->("gcu1.2: " . $r->{'errtext'}) if $r->{'err'};

          $dbh->commit;
        }
        else {
          return $err->("ljr_cached_users inconsistency type 1 for $ru->{username} and $ru->{userid}.")
        }
      }
      elsif ($username_ru_id) {
        $dbh->begin_work;
  
        if ($username_userid && $username_userid ne $ru->{'userid'}) {
            my $has_ex = 1;
            my $ex_suff;
            my $ex_name;
            
            while ($has_ex) {
              $ex_name = "ex_" . $ru->{'username'} . ($ex_suff ? ("_" . $ex_suff) : "");

              $has_ex = $dbr->selectrow_array(
                "SELECT count(remote_username) FROM ljr_cached_users
                 WHERE remote_serverid=? and remote_username=?",
                undef, $ru->{'serverid'}, $ex_name);

              $ex_suff = $ex_suff + 1;
            }

          $r = $rename_remote_user->($username_ru_id, $ru->{'username'}, $ex_name);
          return $err->("gcu2.1: " . $r->{'errtext'}) if $r->{'err'};

          $dbh->do(
            "UPDATE ljr_cached_users SET remote_username = ?
             WHERE ljr_cached_users.ru_id = ?",
            undef, $ex_name, $username_ru_id);
          return $err->($dbh, "gcu2.2: " . $dbh->errstr) if $dbh->err;

          $dbh->do(
            "INSERT INTO ljr_cached_users
            (remote_serverid, remote_username, remote_userid, remote_type)
            VALUES (?, ?, ?, ?)",
            undef, $ru->{'serverid'}, $ru->{'username'}, $ru->{'userid'}, $remote_type);
          return $err->($dbh, "gcu2.3: " . $dbh->errstr) if $dbh->err;

          $ru->{'ru_id'} = $dbh->{mysql_insertid};

          $r = $reid_remote_user->($ru->{'username'}, $username_ru_id, $ru->{'ru_id'});
          return $err->("gcu2.4: " . $r->{'errtext'}) if $r->{'err'};
        }
        else {
          $ru->{'ru_id'} = $username_ru_id;
        }
        
        $r = $update_ljr_cached_users->();
        return $err->("gcu2.5: " . $r->{'errtext'}) if $r->{'err'};

        $dbh->commit;
      }
      elsif ($userid_ru_id) {
        $dbh->begin_work;
        $ru->{'ru_id'} = $userid_ru_id;

        if ($userid_username && $userid_username ne $ru->{'username'}) {
          $r = $rename_remote_user->($ru->{'ru_id'}, $userid_username, $ru->{'username'});
          return $err->("gcu3: " . $r->{'errtext'}) if $r->{'err'};
        }

        $r = $update_ljr_cached_users->();
        return $err->("gcu3: " . $r->{'errtext'}) if $r->{'err'};

        $dbh->commit;
      }
      else {
        $dbh->do(
          "INSERT ljr_cached_users
           (remote_serverid, remote_userid, remote_username, remote_type)
           VALUES (?, ?, ?, ?)",
          undef, $ru->{'serverid'}, $ru->{'userid'}, $ru->{'username'}, $remote_type);
        return $err->("gcu4: " . $dbh->errstr) if $dbh->err;

        $ru->{'ru_id'} = $dbh->{mysql_insertid};
        $ru->{'type'} = $remote_type;
      }
    }
    elsif ($ru->{'username'} && !$ru->{'userid'}) {
      my ($ru_id_1, $ljr_userid, $ljr_type);

      ($ru_id_1, $ljr_userid, $ljr_type) = $dbr->selectrow_array(
        "SELECT ru_id, remote_userid, remote_type FROM ljr_cached_users " .
        "WHERE remote_serverid=? and remote_username=?",
        undef, $ru->{'serverid'}, $ru->{'username'});

      # maybe the user was renamed at the remote site
      if (!$ru_id_1) {
        ($ru_id_1, $ljr_userid, $ljr_type) = $dbr->selectrow_array(
          "SELECT ljr_remote_renamed.ru_id, ljr_cached_users.remote_userid, ljr_cached_users.remote_type " .
          "FROM ljr_remote_renamed, ljr_cached_users " .
          "WHERE ljr_remote_renamed.old_username = ? and ljr_cached_users.remote_serverid = ? " .
          "and ljr_remote_renamed.ru_id = ljr_cached_users.ru_id",
          undef, $ru->{'username'}, $ru->{'serverid'});
      }

      if ($ru_id_1) {
        $ru->{'ru_id'} = $ru_id_1;
        $ru->{'userid'} = $ljr_userid;
        $ru->{'type'} = $ljr_type;
      }
      else {
        # TODO: try to get userid from userinfo.bml
        # and maybe from lj_gate
        $dbh->do(
          "INSERT INTO ljr_cached_users
            (remote_serverid, remote_username, remote_type)
            VALUES (?, ?, ?)",
          undef, $ru->{'serverid'}, $ru->{'username'}, $remote_type);
        return $err->($dbh->errstr) if $dbh->err;

        $ru->{'ru_id'} = $dbh->{mysql_insertid};
        $ru->{'type'} = $remote_type;
      }
    }
    elsif ($ru->{'userid'} && !$ru->{'username'}) {
      my ($ru_id_2, $ljr_username, $ljr_type) = $dbr->selectrow_array(
        "SELECT ru_id, remote_username, remote_type FROM ljr_cached_users " .
        "WHERE remote_serverid=? and remote_userid=?",
        undef, $ru->{'serverid'}, $ru->{'userid'});
      if ($ru_id_2) {
        $ru->{'ru_id'} = $ru_id_2;
        $ru->{'username'} = $ljr_username;
        $ru->{'type'} = $ljr_type;
      }
      else {
        $dbh->do(
          "INSERT INTO ljr_cached_users
            (remote_serverid, remote_userid, remote_type)
            VALUES (?, ?, ?)",
          undef, $ru->{'serverid'}, $ru->{'userid'}, $remote_type);
        return $err->($dbh->errstr) if $dbh->err;

        $ru->{'ru_id'} = $dbh->{mysql_insertid};
        $ru->{'type'} = $remote_type;
      }
    }
    elsif (!$ru->{'userid'} && !$ru->{'username'}) {
      return $err->("no userid and username supplied.");
    }
  }

  return $ru;
}

sub get_local_commentid {
  my ($local_userid, $ru_id, $remote_talkid) = @_;
  my %res = ();

  my $dbr = LJ::get_db_reader();
  return $err->("No database reader available!") unless $dbr;

  my $jtalkid;
  my $local_user;

  if ($local_userid) {
    $jtalkid = $dbr->selectrow_array(
      "SELECT local_jtalkid FROM ljr_cached_comments, ljr_remote_comments " .
      "WHERE ru_id = ? and commentid = ? and ljr_cached_comments.cc_id = ljr_remote_comments.cc_id " . 
      "and local_journalid = ?",
      undef, $ru_id, $remote_talkid, $local_userid);
    return $err->("Can't find remote comment (" . $ru_id . ":" . $remote_talkid .
      ") for local user $local_userid.") unless $jtalkid;
  }
  else {
    ($local_userid, $jtalkid) = $dbr->selectrow_array(
      "SELECT local_journalid, local_jtalkid FROM ljr_cached_comments, ljr_remote_comments " .
      "WHERE ru_id = ? and commentid = ? and ljr_cached_comments.cc_id = ljr_remote_comments.cc_id " .
      "limit 1",
      undef, $ru_id, $remote_talkid);
    return $err->("Can't find remote comment (" . $ru_id . ":" . $remote_talkid . ")")
      unless $local_userid && $jtalkid;

    $local_user = LJ::load_userid ($local_userid);
  }

  $res{"journalid"} = $local_user->{"userid"};
  $res{"journalname"} = $local_user->{"user"};
  $res{"talkid"} = $jtalkid;
  return \%res;
}

# <LJFUNC>
# name: LJR::Distributed::get_local_itemid
# des: returns local itemid corresponding to remote entry
# returns: $hashref->{itemid} or $hashref->{err} and $hashref->{errtext}
# args: local_user, remote_server, remote_journal, remote_itemid
# des-local_user: user object of journal into which we're importing
# des-remote_server: remote serverid
# des-remote_journal: remote journalid
# des-remote_itemid: remote jitemid
# </LJFUNC>
sub get_local_itemid {
  my ($local_user, $ru_id, $remote_itemid, $type) = @_;
  my %res = ();

  my $dbr = LJ::get_db_reader();
  return $err->("No database reader available!") unless $dbr;
  
  $type = "I" unless $type;
  
  my $jitemid;
  my $item;

  if ($local_user) {
    # find first jitemid
    $jitemid = $dbr->selectrow_array(
      "SELECT local_jitemid FROM ljr_remote_entries " .
      "WHERE local_journalid=? and sync_type=? and ru_id=? and remote_jitemid=?",
      undef, $local_user->{"userid"}, $type, $ru_id, $remote_itemid);
  }
  else {
    my $tid;
    ($tid, $jitemid) = $dbr->selectrow_array(
      "SELECT local_journalid, local_jitemid FROM ljr_remote_entries " .
      "WHERE ru_id=? and sync_type=? and remote_jitemid=? limit 1",
      undef, $ru_id, $type, $remote_itemid);
    $local_user = LJ::load_userid ($tid);

    return $err->("Error loading user $tid") unless $local_user;
  }

  # check that local entry is still there
  if ($jitemid) {
    $item = LJ::get_log2_row($local_user, $jitemid);

    # if it's not there then break association
    if (!$item) {
      $jitemid = 0;

      my $dbh = LJ::get_db_writer();
      return $err->("Can't get database writer!") unless $dbh;

      $dbh->do(
        "DELETE FROM ljr_remote_entries WHERE
  local_journalid=? and sync_type=? and
        ru_id=? and remote_jitemid=?",
        undef, $local_user->{"userid"}, $type, $ru_id, $remote_itemid);
      return $err->($dbh->errstr) if $dbh->err;
    }
  }
  else {
    $jitemid = 0;
  }

  $res{"journalid"} = $local_user->{"userid"};
  $res{"journalname"} = $local_user->{"user"};
  $res{"itemid"} = $jitemid;
  $res{"item"} = $item;
  return \%res;
}


# <LJFUNC>
# name: LJR::Distributed::store_remote_itemid
# des: associates remote entry with local entry
# returns: 1 or $hashref->{err} and $hashref->{errtext}
# args: local_user, remote_server, remote_journal, remote_itemid
# des-local_user: user object of journal into which we're importing
# des-local_jitemd: local journal entry id
# des-remote_server: remote serverid
# des-remote_journal: remote journalid
# des-remote_itemid: remote jitemid
# </LJFUNC>
sub store_remote_itemid {
  my ($local_user, $local_jitemid, $ru_id, $remote_itemid, $remote_htmlid, $type) = @_;
  my %res = ();
  
  my $dbh = LJ::get_db_writer();
  return $err->("Can't get database writer!") unless $dbh;
  
  $type = "I" unless $type;

  $dbh->do("INSERT INTO ljr_remote_entries VALUES (?,?,?,?,?,?)",
    undef, $local_user->{"userid"}, $local_jitemid, $ru_id, $remote_itemid, $remote_htmlid, $type);
  return $err->($dbh->errstr) if $dbh->err;

  return \%res;
}

sub remove_remote_itemid {
  my ($local_user, $local_jitemid, $ru_id, $remote_itemid, $type) = @_;
  my %res = ();
  
  my $dbh = LJ::get_db_writer();
  return $err->("Can't get database writer!") unless $dbh;
  
  $dbh->do("delete from ljr_remote_entries where local_journalid=? and local_jitemid=?
    and ru_id=? and remote_jitemid=? and sync_type=?",
    undef, $local_user->{"userid"}, $local_jitemid, $ru_id, $remote_itemid, $type);
  return $err->($dbh->errstr) if $dbh->err;

  return \%res;
}

#
# get remote item id
# type: I for imported items, E for exported (gated) items
#
sub get_remote_itemid {
  my ($local_journalid, $local_jitemid, $type) = @_;
  my $res = {};

  my $dbr = LJ::get_db_reader();
  return $err->("Can't get database reader!") unless $dbr;

  $type = "I" unless $type;
  
  my ($ru_id, $ritemid, $rhtmlid) = $dbr->selectrow_array(
    "select ru_id, remote_jitemid, remote_htmlid from ljr_remote_entries " .
    "WHERE local_journalid=? and local_jitemid=? and sync_type=?",
    undef, $local_journalid, $local_jitemid, $type);
  
  if ($ru_id) {
    $res->{"ru_id"} = $ru_id;
    $res->{"ritemid"} = $ritemid;
    $res->{"rhtmlid"} = $rhtmlid;
    
    $res = LJR::Distributed::get_cached_user($res);
    return undef unless $res->{"username"};
    
    $res = LJR::Distributed::get_remote_server_byid($res);
    return undef unless $res->{"servername"};

    $res->{"original_entry"} =
      $res->{"servername"} . "/users/" .
      $res->{"username"} . "/" .
      $res->{"rhtmlid"} . ".html";
    
    return $res;
  }
  else {
    return undef;
  }
}

sub sign_imported_entry {
  my ($journalid, $entryid, $event) = @_;

  my $ru = LJR::Distributed::get_remote_itemid ($journalid, $entryid);

  if ($ru && $ru->{"original_entry"}) {
    $$event .=
      "\n\n<tt><font size=0>" .
      "<a href=/import-faq.bml>Imported event</a>&nbsp;" .
      "<a href=" . $ru->{"original_entry"} . ">Original</a>" .
      "</font></tt>";
  }
}

sub sign_exported_rss_entry {
  my ($u, $jitemid, $anum, $event) = @_;
  my $item_url = LJ::item_link($u, $jitemid, $anum);
  
  my $dbr = LJ::get_db_reader();
  my ($font, $color, $ljr_es_lastmod) = $dbr->selectrow_array(
    "SELECT font_name, font_color FROM ljr_export_settings WHERE user=?",
    undef, $u->{'user'});

  $font = "gdLargeFont" unless $font;
  $color = "blue" unless $color;
  
  my $img = LJR::GD::generate_number(0, $font, $color, "   ");
  my $padded_width = $img->width;
  my $padded_height = $img->height;
  #my $replycounturl = $LJ::SITEROOT . "/comments/" . $jitemid . "/" . $u->{'userid'} ;
  my $ditemid = $jitemid * 256 + $anum;
  my $replycounturl = $LJ::SITEROOT . "/numreplies/" . $u->{'user'} . "/" . $ditemid ;

  my $talklink =
    "<br /><br /><div style=\"text-align:left\">" .
    "<font size=\"-2\"><a href=\"" . $item_url . "\">" .
    "<img src=\"" . $replycounturl . "\"" .
    " border=0 width=$padded_width height=$padded_height " .
    " alt=\"number of comments\" style=\"border:0px;\" />" .
    " <strong>Comments</strong></a>" .
    "</div>";
  $$event .= $talklink;
}

sub sign_exported_gate_entry {
  my ($u, $jitemid, $anum, $event) = @_;
  my $item_url = LJ::item_link($u, $jitemid, $anum);

  my $dbr = LJ::get_db_reader();
  my ($font, $color, $ljr_es_lastmod) = $dbr->selectrow_array(
    "SELECT font_name, font_color FROM ljr_export_settings WHERE user=?",
    undef, $u->{'user'});

  $font = "gdLargeFont" unless $font;
  $color = "blue" unless $color;
  
  my $img = LJR::GD::generate_number(0, $font, $color, "   ");
  my $padded_width = $img->width;
  my $padded_height = $img->height;
  #my $replycounturl = $LJ::SITEROOT . "/comments/" . $jitemid . "/" . $u->{'userid'} ;
  my $ditemid = $jitemid * 256 + $anum;
  my $replycounturl = $LJ::SITEROOT . "/numreplies/" . $u->{'user'} . "/" . $ditemid ;

  my $talklink =
    "<div style=\"text-align:right\">" .
    "<font size=\"-2\">(<a href=\"" . $item_url . "\">" .
    "<img src=\"" . $replycounturl . "\"" .
    " border=0 width=$padded_width height=$padded_height " .
    " alt=\"number of comments\" style=\"border:0px;\" />" .
    " <strong>Comments</strong></a> |<a href=\"" .
    $item_url .
    "?mode=reply\">Comment on this</a>)</div>";
  $$event .= $talklink;
}

sub update_export_status {
  my ($local_user, $mode, $status_text) = @_;
  
  my $dbr = LJ::get_db_reader();
  return $err->("Can't get database reader!") unless $dbr;
  my $dbh = LJ::get_db_writer();
  return $err->("Can't get database writer!") unless $dbh;

  my $u = LJ::load_user($local_user, 1);
  return $err->("Invalid local user: " . $local_user) unless $u;

  my ($record_exists) = $dbr->selectrow_array(
    "select count(*) from ljr_export_settings where user=? ",
    undef, $local_user);
  
  return err->("Export is not configured for $local_user") unless $record_exists;
  
  if ($mode) {
    $mode = 1;
  }
  else {
    $mode = 0;
  }
  
  $dbh->do (
    "UPDATE ljr_export_settings set enabled=?, update_time=NOW(), last_status=? WHERE user=?",
    undef, $mode, $status_text, $local_user
    );
  return $err->($dbh->errstr) if $dbh->err;
}

sub update_export_settings {
  my ($local_user, $ru_id, $remote_password) = @_;
  
  my $dbr = LJ::get_db_reader();
  return $err->("Can't get database reader!") unless $dbr;
  my $dbh = LJ::get_db_writer();
  return $err->("Can't get database writer!") unless $dbh;

  my $u = LJ::load_user($local_user, 1);
  return $err->("Invalid local user: " . $local_user) unless $u;

  return $err->("ru_id or remote_password not specified") unless $ru_id && $remote_password;
  
  my ($record_exists) = $dbr->selectrow_array(
    "select count(*) from ljr_export_settings where user=? ",
    undef, $local_user);

  if ($record_exists) {
    $dbh->do(
      "UPDATE ljr_export_settings SET ru_id=?, remote_password=?, update_time=NOW() WHERE user=?",
      undef, $ru_id, $remote_password, $local_user
      );
    return $err->($dbh->errstr) if $dbh->err;
  }
  else {
    $dbh->do(
      "INSERT INTO ljr_export_settings " .
      "(user, ru_id, remote_password, update_time) " .
      "VALUES (?,?,?,NOW())",
      undef, $local_user, $ru_id, $remote_password
      );
    return $err->($dbh->errstr) if $dbh->err;
  }
  return LJR::Distributed::update_export_status($local_user, 1, "OK: Updated settings.");
}

sub is_gated_local {
  my ($username) = @_;

  my $dbr = LJ::get_db_reader();
  return $err->("Can't get database reader!") unless $dbr;
  
  my ($exported) = $dbr->selectrow_array(
    "select enabled from ljr_export_settings where user=?",
    undef, $username);
  
  return $exported;
}

sub is_gated_remote {
  my ($server, $username) = @_;
  
  return $err->("Server and username must be specified.") unless $server && $username;

  my $dbr = LJ::get_db_reader();
  return $err->("Can't get database reader!") unless $dbr;

  my $ru = LJR::Distributed::get_remote_server($server);
  return $err->($ru->{"errtext"}) if $ru->{"err"};
  
  $ru->{'username'} = $username;
  $ru = LJR::Distributed::get_cached_user($ru);
  return $err->($ru->{"errtext"}) if $ru->{"err"};
  
  my ($exported) = $dbr->selectrow_array(
    "select count(*) from ljr_export_settings where ru_id=?",
    undef, $ru->{'ru_id'});

  return $exported;
}
