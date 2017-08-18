#!/usr/bin/perl -w

use strict;
use Simple; # corrected LJ::Simple
use POSIX;
use XML::Parser;
use Unicode::String;
use Unicode::MapUTF8 qw(to_utf8 from_utf8 utf8_supported_charset);

require "$ENV{'LJHOME'}/cgi-bin/ljlib.pl";
require "ljr-defaults.pl";
require "ljr-links.pl";
require LJR::Distributed;
require LJR::unicode;
require LWPx::ParanoidAgent;
require "ipics.pl";
require "$ENV{'LJHOME'}/cgi-bin/ljprotocol.pl";

my $DEBUG=1;

# shared variables (between flat and xml mode) 
my $ru; # remote user
my %rfg=(); # remote friend groups
my ($ritem_id, $ranum, $rhtml_id); # remote entry ids
my $local_u; # local user being imported into
my $flags; # ljprotocol.pl flags
my $do_overwrite; # overwrite entries

my $warns;

# flat mode parameters
my $REMOTE_MAX_GET = 50; # livejournal.com lets us download no more than 50 events for a given day

# XML mode functions and variables
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

my $dumptofile = sub {
  my ($fdata, $filename, $ext) = @_;

  my $t = `date +"%T"`;
  $t = substr($t, 0, length($t) - 1);
  open(my $outfile, ">$ENV{'LJHOME'}/logs/" . $filename .  "_" . $t . $ext);
  print $outfile "$fdata";
  close($outfile);
};

my %xentry = (); # current entry
my $ctext = ""; # current field value

my $root_tags = qr/^(livejournal)$/;
my $entry_tag = qr/^(entry)$/;
my $entry_data_tag = qr/^(itemid|eventtime|logtime|subject|event|security|allowmask|current_music|current_mood)$/;


# error handling
my $err = sub {
  my %res = ();

  $res{"err"} = 1;
  $res{"errtext"} = join ("\n", @_);
  
  if ($warns) {
    $res{"warns"} = $warns;
  }
  
  return \%res;
};

my $warn = sub {
  print "WARNING: " . join ("\n", @_);
  print "\n";
  
  if (!$warns || length($warns) < 255) {
    $warns .= $warns . join(" ", @_);
    if (substr($warns, 0, 244) ne $warns) {
      $warns = substr($warns, 0, 244) + "; and more";
    }
  }
};

sub jstatus_print {
  my $statustr = join("", @_);

  if ($DEBUG) {
    eval { LJR::Import::import_log($statustr); };

    if ($@) {
      print $@ . "\n";
      print $statustr . "\n";
    }
  }
}

# overwrite entry
sub check_overwrite {
  my ($local_u, $ru_id, $ritem_id, $overwrite) = @_;

  my $r = LJR::Distributed::get_local_itemid ($local_u, $ru_id, $ritem_id. "I");
  return $err->($r->{"errtext"}) if $r->{"err"};

  if ($r->{"itemid"} && $overwrite eq "1") {
    my %req = (
      'username' => $local_u->{'user'},
      'ownerid' => $local_u->{'user'},
      'clientversion' => $LJR::LJ_CLIENT,
      'ver' => $LJ::PROTOCOL_VER,
      'selecttype' => 'one',
      'itemid' => $r->{"itemid"},
      'getmenus' => 0,
      'lineendings' => "unix",
      'truncate' => 0,
      );

    my $err1;
    my $items = LJ::Protocol::do_request("getevents", \%req, \$err1, $flags);
    if ($err1) {
      my $errstr = LJ::Protocol::error_message($err1);
      return $err->($errstr);
    }

    my $h = @{$items->{events}}[0];
    LJ::delete_entry($local_u, $h->{itemid});

    $r = LJR::Distributed::get_local_itemid ($local_u, $ru_id, $ritem_id, "I");
    return $err->($r->{"errtext"}) if $r->{"err"};
  }
  elsif ($r->{"itemid"} && $overwrite eq "0") {
    return {"continue" => 0};
  }

  return {"continue" => 1};
}

# XML handlers
sub xmlh_entry_start() {
  my $expat = shift;
  my @params = @_;
  
  if ($params[0] =~ /$root_tags/) {
    # skip valid but meaningless tags
  }
  elsif ($params[0] =~ /$entry_tag/) {
    # we're starting to process new entry
    shift @params;

    %xentry = ();
  }
  elsif ($params[0] =~ /$entry_data_tag/) {
    $ctext = "";
  }
  else {
    return $xmlerr->($expat,
      "Unknown XML-structure: " . join (" ", @params),
      "at line " . $expat->current_line);
  }
}
sub xmlh_entry_end() {
  my $expat = shift;
  my @params = @_;

  if ($params[0] =~ /$root_tags/) {
    # almost finished
  }
  elsif ($params[0] =~ /$entry_tag/) {
    my $xe = xml_create_entry(\%xentry);
    return $xmlerr->($expat, "xml_create_entry: " . $xe->{errtext}) if $xe && $xe->{err};
  }
  elsif ($params[0] =~ /$entry_data_tag/) {
    $xentry{$params[0]} = $ctext;
#    print $params[0] . " => " . $ctext . "\n";
  }
  else {
    return $xmlerr->($expat,
      "Unknown tag: " . join (" ", @params),
      "at line " . $expat->current_line
      );
  }
}
sub xmlh_entry_char() {
  my $expat = shift;
  my $tt = join("",  @_);
  $ctext = $ctext . $tt;
}

# should be called after populating shared variables (see section above)
sub xml_create_entry {
  my ($xentry) = @_;

  return $err->("XML import: can't extract remote itemid.") unless $xentry->{"itemid"};
  $ritem_id = int($xentry->{"itemid"} / 256); # export.bml returns html_id instead of item_id

  my $is_gated = LJR::Distributed::get_local_itemid($local_u, $ru->{'ru_id'}, $ritem_id, "E");
  return $err->($is_gated->{"errtext"}) if $is_gated->{"err"};
  return {"err" => 0} if $is_gated->{'itemid'};
  
  my $r = check_overwrite($local_u, $ru->{'ru_id'}, $ritem_id, $do_overwrite);
  return $err->($r->{"errtext"}) if $r->{"err"};
  return unless $r->{"continue"};

  my ($min,$hour,$mday,$mon,$year);

  if ($xentry->{"eventtime"} =~ /(\d\d\d\d)\-(\d\d)\-(\d\d)\ (\d\d)\:(\d\d)/o) {
    $year = $1;
    $mon = $2;
    $mday = $3;
    $hour = $4;
    $min = $5;
  }
  else {
    return $err->("XML import: can't extract eventtime. remote itemid = " . $ritem_id);
  }

  my $moodid;
  if ($xentry->{"current_mood"}) {
    $moodid = LJ::mood_id($xentry->{"current_mood"});
  }

  LJR::Links::make_ljr_hrefs(
    LJR::Links::get_server_url($ru->{"servername"}, "base"),
    $ru->{"servername"}, \$xentry->{"event"}
    );
            
#  LJR::unicode::utf8ize(\$xentry->{"event"});
#  LJR::unicode::utf8ize(\$xentry->{"subject"});
#  LJR::unicode::utf8ize(\$xentry->{"current_mood"});
#  LJR::unicode::utf8ize(\$xentry->{"current_music"});
  
  # LJ now exports lj-polls (previously
  # they exported only links to polls)
  $xentry->{'event'} =~ s/<lj-poll>.+<\/lj-poll>//sog;

  my %req = (
    'mode' => 'postevent',
    'ljr-import' => 1,
    'ver' => $LJ::PROTOCOL_VER,
    'clientversion' => $LJR::LJ_CLIENT,
    'user' => $local_u->{'user'},
    'username' => $local_u->{'user'},
    'usejournal' => $local_u->{'user'},
    'getmenus' => 0,
    'lineendings' => "unix",
    'event' => $xentry->{"event"},
    'subject' => $xentry->{"subject"},
    'year' => $year,
    'mon' => $mon,
    'day' => $mday,
    'hour' => $hour,
    'min' => $min,
    'props' => {
      'current_moodid' => $moodid,
      'current_mood' => $xentry->{"current_mood"},
      'current_music' => $xentry->{"current_music"},
      'opt_preformatted' => 0,
      'opt_nocomments' => 0,
      'taglist' => "",
      'picture_keyword' => "",
      'opt_noemail' => 0,
      'unknown8bit' => 0,
      'opt_backdated' => 1,
    },
  );

  if ($xentry->{"security"} eq "public" || $xentry->{"security"} eq "private") {
    $req{'security'} = $xentry->{"security"};
    $req{'allowmask'} = 0;
  }
  elsif ($xentry->{"security"} eq "usemask" && $xentry->{"allowmask"} == 1) {
    $req{'security'} = 'usemask';
    $req{'allowmask'} = 1;
  }
  else {
    $req{'security'} = 'usemask';

    my @groups = ();
    foreach my $grp_id (keys %rfg) {
      if ($xentry->{"allowmask"}+0 & 1 << $grp_id) {
        push @groups, $rfg{$grp_id}->{name};
      }
    }

    my $mask = 0;
    while (my $grpname = shift @groups) {
      my $group = LJ::get_friend_group($local_u, {'name' => $grpname});
      if ($group) {
        $mask = $mask | (1 << $group->{groupnum});
      }
    }
    $req{'allowmask'} = $mask;
  }
  
  my %res = ();
  LJ::do_request(\%req, \%res, $flags);
  if ($res{"success"} ne "OK" && $res{"errmsg"} =~ "Missing required argument") {
    $warn->($res{"errmsg"} . " while processing " . $xentry->{"eventtime"});
    return;
  }
  if ($res{"success"} ne "OK" && $res{"errmsg"} =~ "Post too large") {
    $dumptofile->($req{'event'}, "large_" . $local_u->{'user'}, ".raw");
  }

  return $err->($xentry->{"eventtime"} . ": " . $res{"errmsg"}) unless $res{"success"} eq "OK";

  $r = LJR::Distributed::store_remote_itemid(
    $local_u,
    $res{"itemid"},
    $ru->{ru_id},
    $ritem_id,
    $xentry->{"itemid"});
  return $err->($xentry->{"eventtime"} . ": " . $r->{"errtext"}) if $r->{"err"};
  
  return {"err" => 0};
}

# do the actual import
sub import_journal {
  my (
    $throttle_speed,
    $remote_site, $remote_protocol, $remote_user, $remote_pass, $remote_shared_journal,
    $local_user, $local_shared_journal, $overwrite
  ) = @_;

  $do_overwrite = $overwrite;
  LJ::disconnect_dbs(); # force reconnection to the database

  if ($remote_shared_journal eq "") {
    $remote_shared_journal = undef;
  }
  if ($local_shared_journal eq "") {
    $local_shared_journal = undef;
  }

  my %gdc_hr = ();
  my %req = ();
  my %lfg = ();
  my %res = ();

  if ($remote_protocol ne "flat" && $remote_protocol ne "xml") {
    return $err->("Unsupported remote protocol $remote_protocol.");
  }

  $LJ::Simple::network_retries = $LJR::NETWORK_RETRIES;
  $LJ::Simple::network_sleep = $LJR::NETWORK_SLEEP;
  $LJ::Simple::LJ_Client = $LJR::LJ_CLIENT;
  $LJ::Simple::UserAgent = $LJR::USER_AGENT;

  # login to the remote site
  my $remote_lj = new LJ::Simple ({
      site => $remote_site,
      user => $remote_user,
      pass => $remote_pass,
      pics  => 0,
      moods => 0,
      });
  if (! defined $remote_lj) {
    return $err->("Can't login to remote site.", $LJ::Simple::error);
  }

  if (!$remote_lj->GenerateCookie()) {
    if (!$remote_lj->GenerateCookie()) {
      return $err->("Can't generate login cookie.", $LJ::Simple::error);
    }
  }

  # since we're able to login with supplied credentials --
  # get and/or cache remote server and remote user ident
  $ru = LJR::Distributed::get_remote_server($remote_site);
  return $err->($ru->{"errtext"}) if $ru->{"err"};

  # try to get userid
  my $idres;
  my $i1 = 0;
  while(1) {
    my $ua = LWPx::ParanoidAgent->new(timeout => 60);
    $ua->agent($LJR::USER_AGENT);
    # TODO: parameterize allpics.bml
    my $url = $ru->{"servername"} . "/users/" . $remote_user . "/info/" ;
    $idres = $ua->get($url);
    
    if (!($idres && ($idres->is_success || $idres->code == 403)) && $i1 < $LJR::NETWORK_RETRIES) {
      my $txt;
      #foreach my $k (keys %$idres) {
      #   $txt .= $k . "->(" . $idres->{$k} ."), ";
      #}
###_content->(500 DNS lookup timeout), _rc->(500), _headers->(HTTP::Headers=HASH(0x2d2ec70)), _msg->(DNS lookup timeout), _request->(HTTP::Request=HASH(0x2c61ac0)),

      $txt .= "_msg->" . $idres->{'_msg'} . ", ";
      foreach my $k (keys %{$idres->{'_headers'}}) {
          $txt .= "\n" . $k . ": " . $idres->{'_headers'}->{$k} ;
      }
      print STDERR "*** $url  $txt\n";

      LJR::NETWORK_SLEEP(); $i1++; next;
    }
    else { last; }
  }
  
  if (!($idres && ($idres->is_success || $idres->code == 403))) {
    return $err->("LWPx: Can't get remote user id: $remote_user\n");
  }
  if ($idres->content && $idres->content =~ /\<b\>$remote_user\<\/b\>\<\/a\>\ \((\d+)\)/s) {
    $ru->{"userid"} = $1;
  }

  $ru->{"username"} = $remote_user;
  $ru = LJR::Distributed::get_cached_user($ru); # populates $ru->{ru_id}
  return $err->($ru->{"errtext"}) if $ru->{"err"};

  # get local user object for user being imported into
  $local_u = LJ::load_user($local_user, 1);
  return $err->("Can't load local user $local_user.") unless $local_u;

  $ru = LJR::Distributed::remote_local_assoc($ru, $local_u);
  return $err->("error while getting remote-local association: " . $ru->{errtext})
    if $ru->{err};

  jstatus_print ("getting userpics");
  my $e = import_pics(
    $ru->{servername},
    $ru->{username},
    $remote_pass,
    $local_user,
    "", 0);
  return $err->("Can't import " . $ru->{username} . ": " . $e->{errtext})
    if $e->{err};

  # clear duplicate protection
  LJ::set_userprop($local_u, "dupsig_post", undef);

  # needed everywhere
  $flags = {
    'u' => $local_u,
    'noauth' => 1,
    'BMAX_EVENT' => 150000,
    'CMAX_EVENT' => 150000,
    'no-cache' => 1,
    'omit_underscore_check' => 1,
    };

  %req = ( 'mode' => 'login',
           'ver' => $LJ::PROTOCOL_VER,
           'clientversion' => $LJR::LJ_CLIENT,
           'user' => $local_u->{'user'},
           'getmenus' => 0,
         );
  %res = ();
  LJ::do_request(\%req, \%res, $flags);
  return $err->($res{'errmsg'}) unless $res{'success'} eq 'OK';

  jstatus_print ("getting friend groups");

  # get remote and local friend groups, mix them up, update on local server
  if (! defined $remote_lj->GetFriendGroups(\%rfg)) {
    return $err->("Failed to get groups on the remote site.", $LJ::Simple::error);
  }

  LJ::Protocol::do_request(
    {
      'mode' => 'getfriendgroups',
      'user' => $local_u->{'user'}, 
      'ver'  => $LJ::PROTOCOL_VER,
      'clientversion' => $LJR::LJ_CLIENT,
      'includegroups' => 1,
      'getmenus' => 0,
    },
    \%res,
    $flags
    );
  if (! $res{'success'} eq "OK") {
    return $err->("Unable to get local user" . $local_u->{'user'} . "groups",
      $res{'success'} . ":" . $res{'errmsg'});
  }

  # convert it to LJ::Simple hash
  while((my $k, my $v) = each %res) {
    $k=~/^frgrp_([0-9]+)_(.*)$/o || next;
    my ($id, $name) = ($1, $2);
    if (!exists $lfg{$id}) {
      $lfg{$id}={
        id  => $id,
        public  => 0,
      };
    }
    ($name eq "sortorder") && ($name="sort");
    $lfg{$id}->{$name}=$v;
  }

  # add nonexisting remote groups (identified by name) to local server
  foreach my $grp_id (keys %rfg) {
    my $e = 0;
    foreach my $lg (values %lfg) {
      if ($lg->{name} eq $rfg{$grp_id}->{name}) {
        $e = 1;
      }
      if ($lg->{name} =~ /default view/i) {
        $e = 1;
      }
    }

    if (!$e) {
      my $egroup = 1;
      foreach my $cgroup (sort { $a <=> $b } keys %lfg) {
        if ($egroup == $cgroup) {
          $egroup++;
        }
      }
      if ($egroup < 31) {
        $lfg{$egroup} = $rfg{$grp_id};
      }
    }
  }

  # create local friend groups (existing + copied)
  my $i = 0;
  %req = (
    'mode' => "editfriendgroups",
    'user' => $local_u->{'user'},
    'clientversion' => $LJR::LJ_CLIENT,
    'ver' => $LJ::PROTOCOL_VER,
    );
  
  # convert LJ::Simple hash back to ljprotocol hash
  foreach my $grpid (keys %lfg) {
    if ($grpid > 0 && $grpid < 31) {

      my $pname = "efg_set_" . $grpid . "_name";
      $req{$pname} = $lfg{$grpid}->{name};
      $i++;
    }
  }

  # do the actual request
  LJ::do_request(\%req, \%res, $flags);
  if (! $res{'success'} eq "OK") {
    return $err->(
      "Unable to update local user" . $local_u->{'user'} . "groups",
      $res{'success'} . ":" . $res{'errmsg'}
      );
  }

  # get remote days with entries
  if (! defined $remote_lj->GetDayCounts(\%gdc_hr, undef)) {
    return $err->("can't get day counts: ", $LJ::Simple::error);
  }

  # import entries by means of export.bml (XML format)
  if ($remote_protocol eq "xml") {
    my $mydc = {};

    foreach (sort {$a<=>$b} keys %gdc_hr) {
      my $timestamp = $_;

      my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) =
        localtime($timestamp);

      $mon++;
      $year = $year + 1900;

      $mydc->{$year}->{$mon} = 0;
      $mydc->{$year}->{$mon} = $mydc->{$year}->{$mon} + $gdc_hr{$timestamp};
    }
    
    foreach (sort {$a <=> $b} keys %{$mydc}) {
      my $y = $_;

      foreach (sort {$a <=> $b} keys %{$mydc->{$y}}) {
        jstatus_print ("getting XML data and creating local entries for " . $_ . "/" . $y);
        
        my $do_login = 0;
  
        while (1) {
          if ($do_login) {
            $remote_lj = new LJ::Simple ({
              site => $remote_site,
              user => $remote_user,
              pass => $remote_pass,
              pics  => 0,
              moods => 0,
            });
            if (! defined $remote_lj) {
              return $err->("Can't login to remote site.", $LJ::Simple::error);
            }
            if (!$remote_lj->GenerateCookie()) {
              if (!$remote_lj->GenerateCookie()) {
                return $err->("Can't generate login cookie.", $LJ::Simple::error);
              }
            }
          }
  
          my $res = $remote_lj->GetRawData({
            "url" => "/export_do.bml",
            "post-data" => {
              "authas" => $remote_user, # "nit",
              "format" => "xml",
              "encid" => 2, # utf-8; for full listing see htdocs/export.bml
              "header" => 1,
              "year" => $y,
              "month" => $_,
              "field_itemid" => 1,
              "field_eventtime" => 1,
              "field_logtime" => 1,
              "field_subject" => 1,
              "field_event" => 1,
              "field_security" => 1,
              "field_allowmask" => 1,
              "field_currents" => 1,
            }});

          if ($res && $res->{content}) {
            my $xdata = $res->{content};
            LJR::unicode::force_utf8(\$xdata);

            my $p1 = new XML::Parser (
              Handlers => {
                Start  => \&xmlh_entry_start,
                End    => \&xmlh_entry_end,
                Char   => \&xmlh_entry_char
              });
            
            eval { $p1->parse($xdata); };
            if ($@) {
              if ($i < $LJR::NETWORK_RETRIES) {
                if ($@ =~ /not\ well\-formed\ \(invalid\ token\)/) {
#                  $xdata <?xml version="1.0" encoding='windows-1251'?>
                }
    
                if ($xdata =~ /Login Required/) {
                  $do_login = 1;
                }

                LJR::NETWORK_SLEEP(); $i++; next;
              }
              else {
                $dumptofile->($xdata, "err_" . $remote_user, ".xml");
                return $err->("Runtime error while parsing XML data: ", $@);
              }
            }
            
            if ($xmlerrt) {
              $dumptofile->($xdata, "err_" . $remote_user, ".xml");
              return $err->("Error while parsing XML data: ", $xmlerrt);
            }

            last;
          }
          else {
            return $err->("Can't get XML data..");
          }
        }
      }
    }
  }
  
  # import entries by means of flat protocol
  if ($remote_protocol eq "flat") {
    # process them, day by day, sleeping a little
    foreach (sort {$a<=>$b} keys %gdc_hr) {
      my $timestamp = $_;

      # download all the entries for a day
      if ($gdc_hr{$timestamp} < $REMOTE_MAX_GET) {
        jstatus_print (
          "getting remote and creating local entries for " .
          strftime ("%a %b %e %Y", localtime($timestamp))
          );

        my %r_entries=(); # remote entries

        if (! defined $remote_lj->GetEntries(\%r_entries,$remote_shared_journal,"day",($timestamp))) {
          if ($LJ::Simple::error =~ "Cannot display this post") {
      $warn->(strftime ("%a %b %e %Y", localtime($timestamp)) . ":" . $LJ::Simple::error);
      next;
    }
    return $err->("can't get remote entries: " . strftime ("%a %b %e %Y", localtime($timestamp)) . ": ",
            $LJ::Simple::error);
        }

        my $rkey=undef;
        my $rentry=undef;
        my $r;

        ENTRIES: while (($rkey, $rentry) = each(%r_entries)) {
          ($ritem_id, $ranum, $rhtml_id) = $remote_lj->GetItemId($rentry);
          my $tevent = $remote_lj->GetEntry($rentry);
          
          my $is_gated = LJR::Distributed::get_local_itemid($local_u, $ru->{'ru_id'}, $ritem_id, "E");
          return $err->($is_gated->{"errtext"}) if $is_gated->{"err"};
          next ENTRIES if $is_gated->{'itemid'};

          $r = check_overwrite($local_u, $ru->{'ru_id'}, $ritem_id, $do_overwrite);
          return $err->($r->{"errtext"}) if $r->{"err"};

          next ENTRIES unless $r->{"continue"};

          my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) =
            localtime($remote_lj->GetDate($rentry));

          $mon++;
          $year = $year + 1900;

          LJR::Links::make_ljr_hrefs(
            LJR::Links::get_server_url($ru->{"servername"}, "base"),
            $ru->{"servername"},
            \$tevent
            );
        
          my $tsubject = $remote_lj->GetSubject($rentry);
          my $tcurrent_mood = $remote_lj->Getprop_current_mood($rentry);
          my $tcurrent_music = $remote_lj->Getprop_current_music($rentry);
          my $ttaglist = $remote_lj->Getprop_taglist($rentry);
    $ttaglist = LJ::trim($ttaglist);
    
          my $tpicture_keyword = $remote_lj->Getprop_picture_keyword($rentry);

#          LJR::unicode::utf8ize(\$tevent);
#          LJR::unicode::utf8ize(\$tsubject);
#          LJR::unicode::utf8ize(\$tcurrent_mood);
#          LJR::unicode::utf8ize(\$tcurrent_music);
#          LJR::unicode::utf8ize(\$ttaglist);
#          LJR::unicode::utf8ize(\$tpicture_keyword);

          %req = ( 'mode' => 'postevent',
                   'ljr-import' => 1,
                   'ver' => $LJ::PROTOCOL_VER,
                   'clientversion' => $LJR::LJ_CLIENT,
                   'user' => $local_u->{'user'},
                   'username' => $local_u->{'user'},
                   'usejournal' => $local_u->{'user'},
                   'getmenus' => 0,
                   'lineendings' => "unix",
                   'event' => $tevent,
                   'subject' => $tsubject,
                   'year' => $year,
                   'mon' => $mon,
                   'day' => $mday,
                   'hour' => $hour,
                   'min' => $min,
                   'props' => {
                     'current_moodid' => $rentry->{prop_current_moodid},
                     'current_mood' => $tcurrent_mood,
                     'current_music' => $tcurrent_music,
                     'opt_preformatted' => $remote_lj->Getprop_preformatted($rentry),
                     'opt_nocomments' => $remote_lj->Getprop_nocomments($rentry),
                     'taglist' => $ttaglist,
                     'picture_keyword' => $tpicture_keyword,
                     'opt_noemail' => $remote_lj->Getprop_noemail($rentry),
                     'unknown8bit' => $remote_lj->Getprop_unknown8bit($rentry),
                     'opt_backdated' => 1,
                   },
                 );

          my @r_protection = $remote_lj->GetProtect($rentry);
          if ($r_protection[0] eq "public" || $r_protection[0] eq "private") {
            $req{'security'} = $r_protection[0];
            $req{'allowmask'} = 0;
          }
          elsif ($r_protection[0] eq "friends") {
            $req{'security'} = 'usemask';
            $req{'allowmask'} = 1;
          }
          elsif ($r_protection[0] eq "groups") {
            $req{'security'} = 'usemask';
            shift @r_protection;

            my $mask=0;
            while (my $grpname = shift @r_protection) {
              my $group = LJ::get_friend_group($local_u, {'name' => $grpname});
              $mask = $mask | (1 << $group->{groupnum});
            }
            $req{'allowmask'} = $mask;
          }

          %res = ();
          LJ::do_request(\%req, \%res, $flags);
          if ($res{"success"} ne "OK" && $res{"errmsg"} =~ "Post too large") {
            $dumptofile->($req{'event'}, "large_" . $local_u->{'user'}, ".raw");
          }
    if ($res{"success"} ne "OK" && $res{"errmsg"} =~ "Invalid text encoding") {
      $warn->($res{"errmsg"});
      next;
    }

    if ($res{"success"} ne "OK" && $res{"errmsg"} =~ "Invalid or malformed tag list") {
      return $err->($res{"errmsg"} . ": [$ttaglist]");
    }

    return $err->($res{'errmsg'}) unless $res{'success'} eq 'OK';
          
    $r = LJR::Distributed::store_remote_itemid(
            $local_u,
            $res{"itemid"},
            $ru->{ru_id},
            $ritem_id,
            $rhtml_id);
          return $err->($r->{"errtext"}) if $r->{"err"};
        }

        sleep($throttle_speed);
      }
      else {
        $warn->("Too much entries for a day. " . $local_u->{'user'} . " " .
          strftime ("%a %b %e %Y", localtime($timestamp))
          );
      }
    } # process them day by day
  }

  if ($warns) {
    my %warns = ('warns' => $warns);
    return \%warns;
  }
  else {
    return undef;
  }
}


return 1;
