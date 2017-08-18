#!/usr/bin/perl -w

use strict;
use Simple; # corrected LJ::Simple
use XML::Parser;
use POSIX;

require "$ENV{'LJHOME'}/cgi-bin/ljlib.pl";
require "ljr-defaults.pl";
require "ljr-links.pl";
require LJR::Distributed;
require LJR::unicode;
require "$ENV{'LJHOME'}/cgi-bin/talklib.pl";
require "ipics.pl";

my $err = sub {
  my %res = ();

  $res{"err"} = 1;
  $res{"errtext"} = join ("\n", @_);
  return \%res;
};
my $xmlerrt;
my $xmlerr = sub {
  my $expat = shift;

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

  $xmlerrt = join("\n", @_);
  $xmlerrt .= $cstack;
  $expat->finish();
};

my $dumpxml = sub {
  my ($xdata, $username) = @_;

  my $t = `date +"%T"`;
  $t = substr($t, 0, length($t) - 1);
  open(my $outfile, ">$ENV{'LJHOME'}/logs/err_" . $username . "_" . $t . ".xml");
  print $outfile "$xdata";
  close($outfile);
};

# kind of global variables
my $DEBUG=1;

my $got_max_commentid;
my $empty_num = 0;

my $ru; # current remote user (the one being cached and imported)
my $cmode;
my $xml_maxid = 0;
my $soft_cached_default_pics;
my $soft_cached_keyworded_pics;
my $posters_without_names; # lj bug workaround: http://rt.livejournal.org/Ticket/Display.html?id=762

sub cstatus_print {
  my $statustr = join("", @_);

  eval { LJR::Import::import_log($statustr); };

  if ($@) {
    print $@ . "\n";
  }

  if ($DEBUG) {
    eval { LJR::Import::log_print($statustr); };
    
    if ($@) {
      print $statustr . "\n";
    }
  }
}


# comment processing
my $skip_tags = qr/^(livejournal|comments|usermaps|nextid)$/; 
my $maxid = qr/^(maxid)$/;
my $comment_tag = qr/^(comment)$/;
my $usermap_tag = qr/^(usermap)$/;
my $data_tags = qr/^(subject|body|date)$/;
my $prop_tag = qr/^(property)$/;

LJ::load_props("talk");
return $err->("Can't load talkprops.") unless $LJ::CACHE_PROP{talk};
my @tprops;
foreach my $k (keys %{$LJ::CACHE_PROP{talk}}) {
  push(@tprops, $k);
}
my $tprops = join("|", @tprops);
my $known_props = qr/^($tprops)$/;

my %comment = (); # current comment structure
my $cid = ""; # current tag (inside comment tag)
my $ctext = ""; # current value of $cid


# export_comments.bml xml handling routines
sub xmlh_comment_start() {
  my $expat = shift;
  my @params = @_;
  
  if ($params[0] =~ /$skip_tags/) {
    # skip valid but meaningless tags
  }
  elsif ($cmode eq "comment_meta" && $params[0] =~ /$usermap_tag/) {
    shift @params; # skip "usermap"

    my %usermap = ();
    %usermap = @params;

    if ($usermap{id} && $usermap{user}) {
      my $r = {
        serverid => $ru->{serverid},
        userid => $usermap{id},
        username => $usermap{user},
        };

      $r = LJR::Distributed::get_cached_user($r);
      return $xmlerr->($expat, $r->{errtext}) if $r->{err};

      $r = LJR::Distributed::get_imported_user($r);
      return $xmlerr->($expat, $r->{errtext}) if $r->{err};

      $r = LJR::Distributed::set_cu_field($r, "local_commenterid", $r->{commenterid});
      return $xmlerr->($expat, $r->{errtext}) if $r->{err};

      if (!$soft_cached_default_pics->{$usermap{id}}) {
        my $iu = LJ::load_userid ($r->{local_commenterid});
#        cstatus_print(
#          "caching default userpic for " . $r->{username} .
#          " (" . $r->{local_commenterid} . ":" . $iu->{user} . ")"
#          );

        my $e = import_pics(
          $ru->{servername},
          $usermap{user},
          "",
          $iu->{user},
          "", 1);
        return $xmlerr->($expat, "importing default userpic for [" . $usermap{user} . "]:", $e->{errtext})
          if $e->{err};

        $soft_cached_default_pics->{$usermap{id}} = 1;
      }
    }
    elsif ($usermap{id} && !$usermap{user}) {
      $posters_without_names->{$usermap{id}} = 1;
    }
    else {
      return $xmlerr->($expat,
        "Unknown XML-structure: " . join (" ", @params),
        "at line " . $expat->current_line);
    }
  }
  elsif ($params[0] =~ /$comment_tag/) {
    # we're starting to process new comment
    shift @params;

    %comment = ();
    %comment = @params; # grab all comment attributes
  }
  elsif ($cmode eq "comment_body" && $params[0] =~ /$data_tags/) {
    $cid = $params[0];
    $ctext = "";
  }
  elsif ($cmode eq "comment_body" && $params[0] =~ /$prop_tag/) {
    shift @params; # skip "property"

    # skip "name" attribute name
    if (shift @params && $params[0] =~ /$known_props/) {
      $cid = $params[0];
      $ctext = "";
    }
  }
  elsif ($params[0] =~ /$maxid/) {
    $ctext = "";
  }
  else {
    return $xmlerr->($expat,
      "Unknown XML-structure: " . join (" ", @params),
      "at line " . $expat->current_line);
  }
}
sub xmlh_comment_end() {
  my $expat = shift;
  my @params = @_;

  if ($params[0] =~ /$skip_tags/) {
    # almost finished
  }
  elsif ($cmode eq "comment_meta" && $params[0] =~ /$usermap_tag/) {
    # nop
  }
  elsif ($params[0] =~ /$comment_tag/) {
    if ($cmode eq "comment_body") {
      
#      print $comment{"id"} . "\n";
#      print "COMMENT\n";
#      while ((my $k, my $v) = each(%comment)) {
#        print $k . ":" . $v . "\n";
#      }
#      print "/COMMENT\n";

      $comment{ru_id} = $ru->{ru_id};

      if (
        $comment{props} &&
        $comment{props}->{"picture_keyword"} &&
        $comment{posterid} &&
        !$soft_cached_keyworded_pics->{$comment{posterid}}->{$comment{props}->{"picture_keyword"}}
        ) {

        my $r = {
          serverid => $ru->{serverid},
          userid => $comment{posterid},
          };

        $r = LJR::Distributed::get_cached_user($r);
        return $xmlerr->($expat, $r->{errtext}) if $r->{err};

        $r = LJR::Distributed::get_imported_user($r);
        return $xmlerr->($expat, $r->{errtext} . "(userid: " . $comment{'posterid'} . ")") if $r->{err};

        $r = LJR::Distributed::get_cu_field($r, "local_commenterid");
        return $xmlerr->($expat, $r->{errtext}) if $r->{err};

        my $iu = LJ::load_userid ($r->{local_commenterid});
        #cstatus_print ("caching userpic " . $comment{props}->{"picture_keyword"} . " for " . $r->{username} . ":" . $iu->{user});

        my $e = import_pics (
          $ru->{servername},
          $r->{username},
          "",
          $iu->{user},
          $comment{props}->{"picture_keyword"},
          0);
        return $xmlerr->($expat, $e->{errtext}) if $e->{err};

        $soft_cached_keyworded_pics->{$comment{posterid}}->{$comment{props}->{"picture_keyword"}} = 1;
      }

      LJR::Links::make_ljr_hrefs(
        LJR::Links::get_server_url($ru->{"servername"}, "base"),
	$ru->{"servername"}, \$comment{body}
	);

      if ($comment{'posterid'} && $posters_without_names->{$comment{'posterid'}}) {
        $comment{'posterid'} = undef;
      }
      if (!$comment{'body'} && $comment{'state'} ne "D") {
        $comment{'body'} = "LJR::Import warning: no comment body during import.";
      }
      
      my $c = LJR::Distributed::cache_comment (\%comment);
      return $xmlerr->($expat, $c->{'errtext'}) if $c->{'err'};

      if (!$ru->{cached_comments_maxid} ||
        $comment{id} > $ru->{cached_comments_maxid}) {
        $ru->{cached_comments_maxid} = $comment{id};
      }
    }

    $got_max_commentid++;
    $empty_num = 0;
  }
  elsif ($params[0] =~ /$data_tags/) {
    $comment{$cid} = $ctext;
  }
  elsif ($params[0] =~ /$prop_tag/) {
    $comment{props}->{$cid} = $ctext;
  }
  elsif ($params[0] =~ /$maxid/) {
    $xml_maxid = $ctext;

    if ($cmode eq "comment_body" && $xml_maxid > $ru->{remote_meta_maxid}) {
      my $tmid = $got_max_commentid;
      my $txid = $xml_maxid;
      my $tempty = $empty_num;

      $got_max_commentid = $ru->{remote_meta_maxid};
      my $e = get_usermaps_cycled(
        $ru->{servername},
        $ru->{username},
        $ru->{pass},
        $got_max_commentid + 1);
      return $xmlerr->($expat, $e->{errtext}) if $e->{err};

      # restore comment_body xml-parsing mode
      $xml_maxid = $txid;
      $got_max_commentid = $tmid;
      $empty_num = $tempty;
      $cmode = "comment_body";
    }
  }
  else {
    return $xmlerr->($expat,
      "Unknown tag: " . join (" ", @params),
      "at line " . $expat->current_line
      );
  }
}
sub xmlh_comment_char() {
  my $expat = shift;
  my $tt = join("", @_);
  $ctext = $ctext . $tt;
}

sub get_usermaps_cycled {
  my ($server, $username, $pass, $startid) = @_;

  my $comments_map = {};
  my $do_login = 1;

  $LJ::Simple::network_retries = $LJR::NETWORK_RETRIES;
  $LJ::Simple::network_sleep = $LJR::NETWORK_SLEEP;
  $LJ::Simple::LJ_Client = $LJR::LJ_CLIENT;
  $LJ::Simple::UserAgent = $LJR::USER_AGENT;

  my $i = 0;
  my $remote_lj;

  while (1) {
    if ($do_login) {
      $remote_lj = new LJ::Simple ({
        site => $server,
        user => $username,
        pass => $pass,
        pics  => 0,
        moods => 0,
        });
      return $err->("Can't login to remote site.", $LJ::Simple::error) unless defined $remote_lj;

      if (!$remote_lj->GenerateCookie()) {
        if (!$remote_lj->GenerateCookie()) {
          return $err->("Can't generate login cookie.", $LJ::Simple::error);
        }
      }

      $do_login = 0;
    }

    # do not process those which were processed once
    if ($comments_map->{$startid}) {
      $startid++;
      next;
    }

    my $res = $remote_lj->GetRawData(
      {"url" => "/export_comments.bml?get=comment_meta&startid=" . $startid}
      );

    if ($res && $res->{content}) {
      $cmode = "comment_meta";

      my $xdata = $res->{content};
      LJR::unicode::force_utf8(\$xdata);
      eval { LJ::text_out(\$xdata); };

      my $p1 = new XML::Parser (
        Handlers => {
          Start  => \&xmlh_comment_start,
          End    => \&xmlh_comment_end,
          Char   => \&xmlh_comment_char
        });

      $xml_maxid = 0;
      $xmlerrt = "";

      eval { $p1->parse($xdata); };
      if ($@) {
        if ($i < $LJR::NETWORK_RETRIES) {
          if ($xdata =~ /Login Required/) {
            $do_login = 1;
          }

          $i++;
          LJR::NETWORK_SLEEP;
          next;
        }
        else {
          $dumpxml->($xdata, $username);
          return $err->("Runtime error parsing XML (meta, $startid): ", $@);
        }
      }
      if ($xmlerrt) {
        $dumpxml->($xdata, $username);
        return $err->("Error parsing XML (meta, $startid): ", $xmlerrt);
      }

      # xml was processed successfully
      $comments_map->{$startid} = 1;

      cstatus_print ("prefetched $got_max_commentid (skipped $empty_num) of $xml_maxid comments");
      if ($got_max_commentid + $empty_num < $xml_maxid) {
        $empty_num++;
        $startid = $got_max_commentid + $empty_num;
        next;
      }
      else {
        $got_max_commentid = 0 unless $got_max_commentid;
        $ru = LJR::Distributed::set_cu_field($ru, "remote_meta_maxid", $got_max_commentid);
        return $err->($ru->{errtext}) if $ru->{err};
        return undef;
      }
    }
    else {
      if ($i < $LJR::NETWORK_RETRIES) {
        LJR::NETWORK_SLEEP; $i++; next;
      }
      else {
        return $err->("can't get comments metadata: " . $LJ::Simple::error);
      }
    }
  }
}

sub get_usermaps {
  my ($server, $username, $pass, $startid) = @_;

  $ru = LJR::Distributed::get_remote_server($server);
  return $err->($ru->{"errtext"}) if $ru->{"err"};
  $ru->{username} = $username;
  $ru->{pass} = $pass;
  $ru = LJR::Distributed::get_cached_user($ru);
  return $err->($ru->{"errtext"}) if $ru->{"err"};

  $got_max_commentid = $startid - 1;

  cstatus_print ("caching commented users.");

  my $e = get_usermaps_cycled($server, $username, $pass, $startid);
  return $err->($e->{errtext}) if $e->{err};
}

sub get_comments_cycled {
  my ($server, $username, $pass, $startid) = @_;

  my $comments_map = {};
  my $do_login = 1;

  $ru = LJR::Distributed::get_remote_server($server) unless $ru->{serverid};
  return $err->($ru->{"errtext"}) if $ru->{"err"};

  $ru->{username} = $username;

  $ru = LJR::Distributed::get_cached_user($ru);
  return $err->($ru->{"errtext"}) if $ru->{"err"};

  $LJ::Simple::network_retries = $LJR::NETWORK_RETRIES;
  $LJ::Simple::network_sleep = $LJR::NETWORK_SLEEP;
  $LJ::Simple::LJ_Client = $LJR::LJ_CLIENT;
  $LJ::Simple::UserAgent = $LJR::USER_AGENT;

  my $i = 0;
  my $h_counter;
  my $remote_lj;
  
  while (1) {
    if ($do_login) {
      $remote_lj = new LJ::Simple ({
        site => $server,
        user => $username,
        pass => $pass,
        pics  => 0,
        moods => 0,
        });
      return $err->("Can't login to remote site.", $LJ::Simple::error) unless defined $remote_lj;
  
      if (!$remote_lj->GenerateCookie()) {
        if (!$remote_lj->GenerateCookie()) {
          return $err->("Can't generate login cookie.", $LJ::Simple::error);
        }
      }

      $do_login = 0;
    }

    # do not process those which were processed once
    if ($comments_map->{$startid}) {
      $startid++;
      next;
    }

    my $res = $remote_lj->GetRawData(
      {"url" => "/export_comments.bml?get=comment_body&props=1&startid=" . $startid}
      );

    if ($res && $res->{content}) {
      my $xdata = $res->{content};
      LJR::unicode::force_utf8(\$xdata);
      eval { LJ::text_out(\$xdata); };

      $cmode = "comment_body";
      my $p1 = new XML::Parser (
        Handlers => {
          Start  => \&xmlh_comment_start,
          End    => \&xmlh_comment_end,
          Char   => \&xmlh_comment_char
        });

      $xmlerrt = "";
      eval { $p1->parse($xdata); };
      if ($@) {
        if ($i < $LJR::NETWORK_RETRIES) {
          if ($xdata =~ /Login Required/) {
            $do_login = 1;
          }

          $i++;
          LJR::NETWORK_SLEEP;
          next;
        }
        else {
          $dumpxml->($xdata, $username);
          return $err->("Runtime error parsing XML (body, $startid): ", $@);
        }
      }
      if ($xmlerrt) {
        $dumpxml->($xdata, $username);
        return $err->("Error parsing XML (body, $startid): ", $xmlerrt);
      }

      # remember last cached comment number (which is equal to its id)
      $ru = LJR::Distributed::set_cu_field(
        $ru, "cached_comments_maxid",
        $ru->{cached_comments_maxid});
      return $err->($ru->{errtext}) if $ru->{err};

      # xml was processed successfully
      $comments_map->{$startid} = 1;

      cstatus_print ("getting comments. last id: $ru->{cached_comments_maxid}, skipping: $empty_num, just walked: $startid, max: $ru->{remote_meta_maxid}");
      if ($ru->{cached_comments_maxid} + $empty_num < $ru->{remote_meta_maxid}) {
        if ($empty_num > 0) {
          $empty_num =
            (POSIX::floor($ru->{cached_comments_maxid} / 100) + 1) * 100 -
            $ru->{cached_comments_maxid} +
            $h_counter * 100;

          $h_counter++;
        }
        else {
          $empty_num++;
          $h_counter = 0;
        }

        $startid = $ru->{cached_comments_maxid} + $empty_num;
        next;
      }
      else {
        return undef;
      }
    }
    else {
      if ($i < $LJR::NETWORK_RETRIES) {
        LJR::NETWORK_SLEEP; $i++; next;
      }
      else {
        return $err->("can't get comments: " . $LJ::Simple::error);
      }
    }
  }
}

sub get_comments {
  my ($server, $username, $pass, $startid) = @_;

  cstatus_print ("caching comments");

  LJ::disconnect_dbs();

  $soft_cached_keyworded_pics = {};
  $soft_cached_default_pics = {};
  $posters_without_names = {};

  $ru = LJR::Distributed::get_remote_server($server);
  return $err->($ru->{"errtext"}) if $ru->{"err"};
  $ru->{username} = $username;
  $ru->{pass} = $pass;
  $ru = LJR::Distributed::get_cached_user($ru);
  return $err->($ru->{"errtext"}) if $ru->{"err"};

  my $e; # for possible errors

  $ru = LJR::Distributed::get_cu_field($ru, "cached_comments_maxid");
  $ru->{cached_comments_maxid} = 0 if not defined $ru->{cached_comments_maxid};

  # don't want to download cached comments again
  $startid = $ru->{cached_comments_maxid} + 1
    if $ru->{cached_comments_maxid} > $startid;

  $ru = LJR::Distributed::get_cu_field($ru, "remote_meta_maxid");
  $ru->{remote_meta_maxid} = 0 if not defined $ru->{remote_meta_maxid};

  # try to minimize possible further delays
  $got_max_commentid = $ru->{remote_meta_maxid};
  $e = get_usermaps_cycled($server, $username, $pass, $got_max_commentid + 1);
  return $err->($e->{errtext}) if $e->{err};

  # get remote comments and cache them
  $got_max_commentid = $startid - 1;
  $e = get_comments_cycled($server, $username, $pass, $startid);
  return $err->($e->{errtext}) if $e->{err};

  $soft_cached_keyworded_pics = {};
  $soft_cached_default_pics = {};
  $posters_without_names = {};

  return undef;
}

sub create_imported_comments {
  my ($remote_site, $remote_user, $local_user) = @_;

  LJ::disconnect_dbs();

  my $ru = LJR::Distributed::get_remote_server($remote_site);
  return $err->($ru->{"errtext"}) if $ru->{"err"};

  $ru->{username} = $remote_user;
  $ru = LJR::Distributed::get_cached_user($ru);
  return $err->($ru->{"errtext"}) if $ru->{"err"};

  cstatus_print("creating comments.");

  $ru = LJR::Distributed::create_imported_comments($ru, $local_user);
  return $err->($ru->{"errtext"}) if $ru->{"err"};

  return undef;
}


return 1;
