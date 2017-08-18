#!/usr/bin/perl

use strict;
use Image::Size ();
use Simple; # corrected LJ::Simple
require "$ENV{'LJHOME'}/cgi-bin/ljlib.pl";
require "ljr-defaults.pl";
require "ljr-links.pl";
require LJR::Distributed;
require LWPx::ParanoidAgent;

# error handling
my $err = sub {
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

# example:
my $DEBUG = 0;

sub cache_remote_pics {
  my ($remote_site, $remote_user, $remote_pass, $local_userid) = @_;
  my $ua;
  my $res;
  my %remote_urls = ();
  my %remote_keywords = ();
  my %remote_comments = ();
  my $default_pic = "";

  my $i = 0;
  my $content;

  # get remote pictures list with keywords
  if ($remote_pass ne "") {
    $LJ::Simple::network_retries = $LJR::NETWORK_RETRIES;
    $LJ::Simple::network_sleep = $LJR::NETWORK_SLEEP;
    $LJ::Simple::LJ_Client = $LJR::LJ_CLIENT;
    $LJ::Simple::UserAgent = $LJR::USER_AGENT;

    my $ljs_site = $remote_site;
    if ($ljs_site =~ /^http\:\/\/(.*)/) {
      $ljs_site = $1;
    }

    my $remote_lj = new LJ::Simple ({
      site => $ljs_site,
      user => $remote_user,
      pass => $remote_pass,
      pics  => 0,
      moods => 0,
      });
    return $err->("Can't login to remote site.", $LJ::Simple::error)
      unless defined($remote_lj);

    if (!$remote_lj->GenerateCookie()) {
      return $err->("Can't generate login cookie.", $LJ::Simple::error);
    }

    $res = $remote_lj->GetRawData({
      "url" => "/allpics.bml",
      });
    if (!($res && $res->{content})) {
      return $err->("LJ::Simple: Can't get remote user pictures: $remote_user\n");
    }

    $content = $res->{content};
  }
  else {
    while(1) {
      $ua = LWPx::ParanoidAgent->new(timeout => 60);
      $ua->agent($LJR::USER_AGENT);
      # TODO: parameterize allpics.bml
      $res = $ua->get($remote_site . "/allpics.bml?user=" . $remote_user);
    
      if (!($res && $res->is_success) && $i < $LJR::NETWORK_RETRIES) {
        LJR::NETWORK_SLEEP(); $i++; next;
      }
      else {
        last;
      }
    }
    if (!($res && $res->is_success)) {
      return $err->("LWPx: Can't get remote user pictures: $remote_user\n");
    }

    $content = $res->content;
  }

  my $ru = LJR::Distributed::get_remote_server($remote_site);
  return $err->($ru->{"errtext"}) if $ru->{"err"};

  $ru->{username} = $remote_user;
  $ru = LJR::Distributed::get_cached_user($ru);

  $i = 0;

  my $dbh = LJ::get_db_writer();
  return $err->("Can't get database writer!") unless $dbh;

  $dbh->do("DELETE FROM ljr_cached_userpics WHERE ru_id=?", undef, $ru->{ru_id});
  return $err->($dbh->errstr) if $dbh->err;

  my $iru;
  my $userpic_base = LJR::Links::get_server_url($remote_site, "userpic_base");

  # extract pic urls and keywords

  if ($content =~ m!<\s*?body.*?>(.+)</body>!si) {
    $content = $1;

    while ($content =~
      /\G.*?($userpic_base\/(\d+)\/(\d+))(.*?)($userpic_base\/(\d+)\/(\d+)|$)(.*)/sg
      ) {
      my $picurl = $1;
      my $props = $4;
      my $cuserid = $3;
      my $cpicid = $2;
      $content = $5 . $8;

      my $is_default = 0;

      # save userid
      if (!$iru->{ru_id}) {
        $iru = LJR::Distributed::get_remote_server($remote_site);
        return $err->($ru->{"errtext"}) if $ru->{"err"};

        $iru->{username} = $remote_user;
        $iru->{userid} = $cuserid;

        $iru = LJR::Distributed::get_cached_user($iru);
        return $err->($ru->{"errtext"}) if $ru->{"err"};
      }

      if ($props =~ /(.*?)Keywords\:\<\/b\>\ (.*?)\<br\ \/\>(.*?)\<\/td\>/s) {
        $remote_keywords{$picurl} = $2;
        $remote_comments{$picurl} = $3;
        $remote_comments{$picurl} =~ s/^\s+|\s+$//;
      }
      if ($props =~ /\<u\>Default\<\/u\>/s) {
        $default_pic = $picurl;
        $is_default = 1;
      }

      my @keywords = "";
      if ($remote_keywords{$picurl}) {
        @keywords = split(/\s*,\s*/, $remote_keywords{$picurl});
        @keywords = grep { s/^\s+//; s/\s+$//; $_; } @keywords;
      }
      elsif ($is_default) {
        @keywords = ("");
      }

      foreach my $kw (@keywords) {
        if($remote_urls{$cpicid}) {
          $dbh->do("UPDATE ljr_cached_userpics set keyword=?, is_default=?, comments=?
            where ru_id=? and remote_picid=?",
            undef, $kw, $is_default, $remote_comments{$picurl},
            $ru->{ru_id}, $cpicid);
          return $err->($dbh->errstr) if $dbh->err;
        }
        else {
          $dbh->do("INSERT INTO ljr_cached_userpics VALUES (?,?,?,?,?)",
            undef, $ru->{ru_id}, $cpicid, $kw,
            $is_default, $remote_comments{$picurl});
          return $err->($dbh->errstr) if $dbh->err;
        }
      }
      $remote_urls{$cpicid} = $picurl;
    }
  }
  return undef;
}

sub import_pics {
  my (
    $remote_site, $remote_user, $remote_pass,
    $local_user, $o_keyword, $o_default
    ) = @_;

  my $MAX_UPLOAD = 40960;

  my %remote_ids = ();
  my %remote_urls = ();
  my %remote_keywords = ();
  my %remote_comments = ();
  my $default_pic = "";

  my $ru = LJR::Distributed::get_remote_server($remote_site);
  return $err->($ru->{"errtext"}) if $ru->{"err"};

  $ru->{username} = $remote_user;
  $ru = LJR::Distributed::get_cached_user($ru);

  # load user object (force, otherwise get error outside of apache)
  my $u = LJ::load_user($local_user, 1);
  return $err->("Invalid local user: " . $local_user) unless $u;

  # prepare database connections (for different versions of user objects)
  my ($dbcm, $dbcr, $sth);
  $dbcm = LJ::get_cluster_master($u);
  return $err->("Can't get cluster master!") unless $dbcm;
  $dbcr = LJ::get_cluster_def_reader($u);
  return $err->("Can't get cluster reader!") unless $dbcr;
  my $dbh = LJ::get_db_writer();
  return $err->("Can't get database writer!") unless $dbh;
  my $dbr = LJ::get_db_reader();
  return $err->("Can't get database reader!") unless $dbr;

  my $e;

  if (!$o_keyword && !$o_default) {
    $e = cache_remote_pics($remote_site, $remote_user, $remote_pass, $u->{userid});
    return $e if $e->{err};
  }
  else {
    $sth = $dbr->prepare(
      "SELECT ru_id FROM ljr_cached_userpics WHERE ru_id=? GROUP BY ru_id");
    $sth->execute($ru->{ru_id});
    my $ruid = $sth->fetchrow_hashref;
    $sth->finish;

    if (!$ruid) {
      $e = cache_remote_pics($remote_site, $remote_user, $remote_pass, $u->{userid});
      return $e if $e->{err};
    }
  }

  # get ru->{userid} which should come up after caching remote pic props
  $ru = LJR::Distributed::get_cached_user($ru);

  if ($o_keyword) {
    $sth = $dbr->prepare(
      "SELECT remote_picid, keyword, is_default, comments " .
      "FROM ljr_cached_userpics WHERE ru_id=? and keyword=?");
    $sth->execute($ru->{ru_id}, $o_keyword);
  }
  elsif ($o_default) {
    $sth = $dbr->prepare(
      "SELECT remote_picid, keyword, is_default, comments " .
      "FROM ljr_cached_userpics WHERE ru_id=? and is_default=1");
    $sth->execute($ru->{ru_id});
  }
  else {
    $sth = $dbr->prepare(
      "SELECT remote_picid, keyword, is_default, comments " .
      "FROM ljr_cached_userpics WHERE ru_id=?");
    $sth->execute($ru->{ru_id});
  }

  my $i = 0;
  while (my $rpic = $sth->fetchrow_hashref) {
    my $picurl = $remote_site . "/userpic/" . $rpic->{remote_picid} . "/" . $ru->{userid};

    $remote_ids{$i} = $rpic->{remote_picid};
    $remote_urls{$rpic->{remote_picid}} = $picurl;

    $remote_comments{$picurl} = $rpic->{comments};
    $remote_keywords{$picurl} =
      (($remote_keywords{$picurl}) ? $remote_keywords{$picurl} . "," : "") .
      $rpic->{keyword};

    if ($rpic->{is_default}) {
      $default_pic = $picurl;
    }

    print
      $picurl . ":" .
      $remote_ids{$i} . ":" .
      $remote_comments{$picurl} . ":" .
      $remote_keywords{$picurl} . "\n"
      if $DEBUG;

    $i++;
  }
  $sth->finish;

  RPICID: foreach my $rpicid (sort {$a <=> $b} values %remote_ids) {
    my $local_picid = $dbr->selectrow_array(
      "SELECT local_picid FROM ljr_remote_userpics " .
      "WHERE ru_id=? and remote_picid=? and local_userid = ?",
      undef, $ru->{ru_id}, $rpicid, $u->{userid});

    if ($local_picid) {
      my $r_picid = $dbr->selectrow_array(
        "SELECT picid FROM userpic2 WHERE picid=?",
        undef, $local_picid);

      if (!$r_picid) {
        $u->do("DELETE FROM ljr_remote_userpics WHERE local_picid=?", undef, $local_picid);
        $local_picid = undef;
      }
      else {
        next RPICID;
      }
    }
    
    my %POST = ();

    $POST{urlpic} = $remote_urls{$rpicid};
    $POST{keywords} = $remote_keywords{$remote_urls{$rpicid}};
    $POST{comments} = $remote_comments{$remote_urls{$rpicid}};
    $POST{url} = "";
    if ($default_pic eq $remote_urls{$rpicid}) {
      $POST{make_default} = 1;
    }

    # get remote picture and validate it
    my $ua;
    my $res;
    my ($sx, $sy, $filetype);

    $i = 0;
    while(1) {
      $ua = LWPx::ParanoidAgent->new(
        timeout => 60,
        max_size => $MAX_UPLOAD + 1024);
        $ua->agent($LJR::USER_AGENT);
      $res = $ua->get($POST{urlpic});

      # if the picture doesn't exist on the remote server
      # then we get 404 http error and remove it from our cache
      if ($res &&
        ($res->{"_rc"} eq 404 || $res->{"_rc"} eq 503)
	) {
        $dbh->do("DELETE FROM ljr_cached_userpics WHERE ru_id=? and remote_picid=?",
          undef, $ru->{ru_id}, $rpicid);
        return $err->($dbh->errstr) if $dbh->err;

        next RPICID;
      }

      $POST{userpic} = $res->content if $res && $res->is_success;

      ($sx, $sy, $filetype) = Image::Size::imgsize(\$POST{'userpic'});
      
      if (!(
        $res && $res->is_success && defined($sx) &&
        length($POST{'userpic'}) <= $MAX_UPLOAD &&
        ($filetype eq "GIF" || $filetype eq "JPG" || $filetype eq "PNG") &&
        $sx <= 100 && $sy <= 100
        ) &&
        $i < $LJR::NETWORK_RETRIES) {
        LJR::NETWORK_SLEEP(); $i++; next;
      }
      else {
        last;
      }
    }
    if (!($res && $res->is_success)) {
      return $err->("Can't get remote user picture: ",
        $remote_user, $local_user, $o_keyword, $o_default, $POST{urlpic},
        $res->status_line);
    }
    if (!defined $sx) {
      print ("Invalid image: " . $POST{urlpic} . "\n");
      next RPICID;
    }

    if (length($POST{'userpic'}) > $MAX_UPLOAD) {
      return $err->("Picture " . $POST{urlpic} . "is too large");
    }

    return $err->("Unsupported filetype: " . $POST{urlpic})
      unless ($filetype eq "GIF" || $filetype eq "JPG" || $filetype eq "PNG");
    return $err->("Image too large: " . $POST{urlpic}) if ($sx > 150 || $sy > 150);

    my $base64 = Digest::MD5::md5_base64($POST{'userpic'});

    # see if it's a duplicate
    my $picid;
    my $contenttype;
    if ($filetype eq "GIF") { $contenttype = 'G'; }
    elsif ($filetype eq "PNG") { $contenttype = 'P'; }
    elsif ($filetype eq "JPG") { $contenttype = 'J'; }

    $picid = $dbcr->selectrow_array(
      "SELECT picid FROM userpic2 WHERE userid=? AND fmt=? AND md5base64=?",
      undef, $u->{'userid'}, $contenttype, $base64);
    $picid = 0 unless defined($picid);

    print "trying to insert into db\n" if $DEBUG;

    # if picture isn't a duplicate, insert it
    if ($picid == 0) {

      # Make a new global picid
      $picid = LJ::alloc_global_counter('P') or
          return $err->('Unable to allocate new picture id');

      $u->do(
        "INSERT INTO userpic2 (picid, userid, fmt, width, height, " .
        "picdate, md5base64, location, state) " .
        "VALUES (?, ?, ?, ?, ?, NOW(), ?, ?, 'N')",
        undef, $picid, $u->{'userid'}, $contenttype, $sx, $sy, $base64, undef);
      return $err->($u->errstr) if $u->err;

      my $clean_err = sub {
        if ($picid) {
          $u->do(
            "DELETE FROM userpic2 WHERE userid=? AND picid=?",
            undef, $u->{'userid'}, $picid);

          $u->do(
            "DELETE FROM userpicblob2 WHERE userid=? AND picid=?",
            undef, $u->{'userid'}, $picid);
        }
        return $err->(@_);
      };

      ### insert the blob
      $u->do(
        "INSERT INTO userpicblob2 (userid, picid, imagedata) VALUES (?,?,?)",
        undef, $u->{'userid'}, $picid, $POST{'userpic'});
      return $clean_err->($u->errstr) if $u->err;

      # make it their default pic?
      if ($POST{'make_default'}) {
        LJ::update_user($u, { defaultpicid => $picid });
        $u->{'defaultpicid'} = $picid;
      }
      
      # set default keywords?
      if ($POST{'keywords'} && $POST{'keywords'} ne '') {
        print "storing keywords\n" if $DEBUG;

        $sth = $dbcr->prepare("SELECT kwid, picid FROM userpicmap2 WHERE userid=?");
        $sth->execute($u->{'userid'});

        my @exist_kwids;
        while (my ($kwid, $picid) = $sth->fetchrow_array) {
          $exist_kwids[$kwid] = $picid;
        }

        my @keywords = split(/\s*,\s*/, $POST{'keywords'});
        @keywords = grep { s/^\s+//; s/\s+$//; $_; } @keywords;

        my (@bind, @data);
        my $c = 0;

        foreach my $kw (@keywords) {
          my $kwid = LJ::get_keyword_id($u, $kw);
          next unless $kwid; # Houston we have a problem! This should always return an id.

          if ($c > $LJ::MAX_USERPIC_KEYWORDS) {
            return $clean_err->("Too many userpic keywords: " . LJ::ehtml($kw));
          }

          if ($exist_kwids[$kwid]) { # Already used on another picture
            # delete existing pic while there's newer one
            $u->do("
              delete ljr_remote_userpics, ljr_cached_userpics
              from ljr_cached_userpics, ljr_remote_userpics
              where
                ljr_cached_userpics.ru_id = ljr_remote_userpics.ru_id and
                ljr_cached_userpics.remote_picid = ljr_remote_userpics.remote_picid and
              ljr_remote_userpics.local_userid = ? and local_picid = ?",
              undef, $u->{'userid'}, $exist_kwids[$kwid]);

            $u->do("DELETE FROM userpicmap2 WHERE userid=? AND picid=?",
              undef, $u->{'userid'}, $exist_kwids[$kwid]);

            $u->do("DELETE FROM userpicblob2 WHERE userid=? AND picid=?",
              undef, $u->{'userid'}, $exist_kwids[$kwid]);

            $u->do("DELETE FROM userpic2 WHERE userid=? AND picid=?",
              undef, $u->{'userid'}, $exist_kwids[$kwid]);
          }

          push @bind, '(?, ?, ?)';
          push @data, $u->{'userid'}, $kwid, $picid;

          $c++;
        }

        if (@data && @bind) {
          my $bind = join(',', @bind);

          $u->do(
            "INSERT INTO userpicmap2 (userid, kwid, picid) VALUES $bind",
            undef, @data);
        }
      }

      # set default comments and the url
      my (@data, @set);
      if ($POST{'comments'} && $POST{'comments'} ne '') {
        push @set, 'comment=?';
        push @data, LJ::text_trim($POST{'comments'}, $LJ::BMAX_UPIC_COMMENT, $LJ::CMAX_UPIC_COMMENT);
      }

      if ($POST{'url'} ne '') {
        push @set, 'url=?';
        push @data, $POST{'url'};
      }

      if (@set) {
        my $set = join(',', @set);

        $u->do("UPDATE userpic2 SET $set WHERE userid=? AND picid=?",
               undef, @data, $u->{'userid'}, $picid);
        return $err->($u->errstr) if $u->err;
      }
    
      $u->do("INSERT INTO ljr_remote_userpics VALUES (?,?,?,?)",
        undef, $ru->{ru_id}, $rpicid, $u->{userid}, $picid);
      return $err->($u->errstr) if $u->err;
    }
  }

  return undef;
}

return 1;
