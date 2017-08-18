require "$ENV{'LJHOME'}/cgi-bin/ljcom.pl";

LJ::register_hook('emailconfirmed',
  sub {
    my $u = shift;
    BML::set_cookie("LJR_confirmedemailthisyear", '1',
      time() + 3600*24*365, $LJ::COOKIE_PATH, $LJ::COOKIE_DOMAIN);
    return $text;
  }
);

sub get_new_userid {
  my $ruserid = 0; # scope

  my $dbr = LJ::get_db_reader();

  if (! $LJ::LJR_IMPORTED_USERIDS) {
    $ruserid = $dbr->selectrow_array(
      "select max(userid) from user"
      );
  }
  else {
    $ruserid = $dbr->selectrow_array(
      "select max(userid) from user where userid < $LJ::LJR_IMPORTED_USERIDS"
      );
  }

  if ($ruserid) {
    $ruserid++;
  }
  
  return $ruserid;
}

sub get_new_importedid {
  my $ruserid = 0; # scope
  my $dbr = LJ::get_db_reader();
  $ruserid = $dbr->selectrow_array(
    "select max(userid) from user where userid >= $LJ::LJR_IMPORTED_USERIDS",
    );

  if ($ruserid) {
    $ruserid++;
  }
  else {
    $ruserid = $LJ::LJR_IMPORTED_USERIDS;
  }
  
  return $ruserid;
}

sub get_callstack {
  my $cstack;
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
  return $cstack;
}

# should be used when you need to concatenate string
# which might be undefined and you want empty string ("")
# instead of perl warnings about uninitialized values
#
sub safe_string {
  my ($str) = @_;

  if ($str) {
    return $str;
  }
  else {
    return "";
  }
}

# check_unfriend
# takes 2 userids, returns 1 if one unfriended another, 0 otherwise
# args userid1, userid2

sub check_twit
{
    my ($userid, $twitid) = @_;
    return undef unless $userid;     return undef unless $twitid;
    $dbh = LJ::get_db_reader();
    return $err->("Can't get database reader!") unless $dbh;
    my $sth = $dbh->prepare("SELECT * FROM twits WHERE".
                       " userid=$userid AND twitid=$twitid");
    $sth->execute() || print STDERR "Couldn't execute" . $sth->errstr;
#    print STDERR "rows $sth->rows"; 
    if ($sth->rows) { return 1;}  else {return 0;}
}

# takes userid, returns arrayref of its twitid's
#
sub get_twit_list
{
    my ($userid) = @_;
    return undef unless $userid;

    $db = LJ::get_db_reader();
    return $err->("Can't get database reader!") unless $db;
    return $db->selectcol_arrayref("SELECT twitid FROM
               twits WHERE userid=?",  undef, $userid);
}

