use strict;

use XMLRPC::Lite;
use Digest::MD5;
use Time::Local;

use LJR::Distributed;
use LJR::xmlrpc;
use LJR::Viewuserstandalone;

require "$ENV{'LJHOME'}/cgi-bin/ljpoll.pl";

package LJR::Gate;

$LJR::Gate::clientver = 'LJR::Gate/0.02';

sub Authenticate {
  my ($server, $user, $pass) = @_;
  
  my $xmlrpc = new XMLRPC::Lite;
  $xmlrpc->proxy("http://" . $server . "/interface/xmlrpc", timeout => 60);
  
  my $xmlrpc_ret = LJR::xmlrpc::xmlrpc_call($xmlrpc, "LJ.XMLRPC.getchallenge");
  return $xmlrpc_ret if $xmlrpc_ret->{"err_text"};

  my $challenge = $xmlrpc_ret->{'result'}->{'challenge'};
  my $response = Digest::MD5::md5_hex($challenge . Digest::MD5::md5_hex($pass));

  my $xmlrpc_req = {
    'username' => $user,
    'auth_method' => 'challenge',
    'auth_challenge' => $challenge,
    'auth_response' => $response,
    'ver' => 1,
    'clientver' => $LJR::Gate::clientver,
  };

  $xmlrpc_ret = LJR::xmlrpc::xmlrpc_call($xmlrpc, "LJ.XMLRPC.login", $xmlrpc_req);
  return $xmlrpc_ret if $xmlrpc_ret->{"err_text"};
  
  return $xmlrpc;
}

sub ExportEntry {
  my ($u, $req, $security, $jitemid, $anum) = @_;

  return "User [" . $u->{'user'} . "] is not gated." unless LJR::Distributed::is_gated_local($u->{'user'});

  my $dbr = LJ::get_db_reader();
  return "Can't get database reader!" unless $dbr;
  
  my $r;
  $r = $dbr->selectrow_hashref (
    "SELECT * FROM ljr_export_settings WHERE user=?",
    undef, $u->{'user'});

  my $ru;
  $ru = LJR::Distributed::get_cached_user({ 'ru_id' => $r->{'ru_id'}});
  $ru = LJR::Distributed::get_remote_server_byid($ru);
  
  my $xmlrpc = new XMLRPC::Lite;
  $xmlrpc->proxy($ru->{'servername'} . "/interface/xmlrpc", timeout => 60);
  
  my $xmlrpc_ret;
  my $xmlrpc_req;
  my $challenge;
  my $response;
  
  my $real_event;
  my $real_subject;

  my $last_status;

  if ($req->{'event'} !~ /\S/) {
    $last_status = "removed entry.";

    $real_event = $req->{'event'};
    $real_subject = $req->{'subject'};
  }
  else {
    my $item_url = LJ::item_link($u, $jitemid, $anum);
    $last_status = "exported <a href=$item_url>entry</a>";
    
    $real_event = LJR::Viewuserstandalone::expand_ljuser_tags($req->{'event'});
    $real_subject = LJR::Viewuserstandalone::expand_ljuser_tags($req->{'subject'});
    
    my $i=0;
    while ($real_event =~ /lj-cut/ig) { $i++ };
    while ($real_event =~ /\/lj-cut/ig) { $i-- };
    if ($i gt 0) {
      $real_event .= "</lj-cut>";
    }
    LJ::Poll::replace_polls_with_links(\$real_event);
    LJ::EmbedModule->expand_entry($u, \$real_event, ('content_only' => 1));
    
    unless ($req->{'props'}->{'opt_nocomments'}) {
      LJR::Distributed::sign_exported_gate_entry($u, $jitemid, $anum, \$real_event);
    }
  }
  
  $security = $req->{'sequrity'} if !$security && $req->{'security'};
  $security = "public" unless $security;

  $xmlrpc_req = {
    'username' => $ru->{'username'},
    'auth_method' => 'challenge',
    'ver' => 1,
    'clientver' => $LJR::Gate::clientver,
    'subject' => $real_subject,
    'event' => $real_event,
    'year' => $req->{'year'},
    'mon' => $req->{'mon'},
    'day' => $req->{'day'},
    'hour' => $req->{'hour'},
    'min' => $req->{'min'},
    'security' => $security,
    'allowmask' => $req->{'allowmask'},
    'props' => {
      'current_moodid' => $req->{'props'}->{'current_moodid'},
      'current_mood' => $req->{'props'}->{'current_mood'},
      'current_music' => $req->{'props'}->{'current_music'},
      'picture_keyword' => $req->{'props'}->{'picture_keyword'},
      'taglist' => $req->{'props'}->{'taglist'},
      'opt_backdated' => $req->{'props'}->{'opt_backdated'},
      'opt_preformatted' => $req->{'props'}->{'opt_preformatted'},
      'opt_nocomments' => 1,
    },
  };

  my $is_invalid_remote_journal = sub {
    my ($error_message) = @_;
    if (
      $error_message =~ /Invalid password/ ||
      $error_message =~ /Selected journal no longer exists/ ||
      $error_message =~ /account is suspended/ ||
      $error_message =~ /Invalid username/
      ) {
      return 1;
    }
    return 0;
  };
  
  my $is_invalid_remote_entry = sub {
    my ($error_message) = @_;
    if ($error_message =~ /Can\'t edit post from requested journal/) {
      return 1;
    }
    return 0;
  };

  my $post_new_event = sub {
    $xmlrpc_ret = LJR::xmlrpc::xmlrpc_call($xmlrpc, "LJ.XMLRPC.getchallenge");
    return $xmlrpc_ret->{"err_text"} if $xmlrpc_ret->{"err_text"};
    $challenge = $xmlrpc_ret->{'result'}->{'challenge'};
    $response = Digest::MD5::md5_hex($challenge . Digest::MD5::md5_hex($r->{'remote_password'}));
    $xmlrpc_req->{'auth_challenge'} = $challenge;
    $xmlrpc_req->{'auth_response'} = $response;

    my $item_time = Time::Local::timelocal(0, $req->{'min'}, $req->{'hour'},
      $req->{'day'}, $req->{'mon'} - 1, $req->{'year'});
    
    if ((time - $item_time) > 60*60*24) {
      $xmlrpc_req->{'props'}->{'opt_backdated'} = 1;
    }
    
    $xmlrpc_ret = LJR::xmlrpc::xmlrpc_call($xmlrpc, "LJ.XMLRPC.postevent", $xmlrpc_req);
    if ($xmlrpc_ret->{'err_text'}) {
      if ($is_invalid_remote_journal->($xmlrpc_ret->{'err_text'})) {
        $r = LJR::Distributed::update_export_status($u->{'user'}, 0, "ERROR: " . $xmlrpc_ret->{'err_text'});
      }
      else {
        $r = LJR::Distributed::update_export_status($u->{'user'}, 1, "ERROR: " . $xmlrpc_ret->{'err_text'});
      }
      return $xmlrpc_ret->{"err_text"} . " " . ($r->{'err'} ? $r->{'errtext'} : "");
    }

    my $rhtml_id = $xmlrpc_ret->{'result'}->{'itemid'} * 256 +
      $xmlrpc_ret->{'result'}->{'anum'};

    $r = LJR::Distributed::store_remote_itemid(
      $u,
      $jitemid,
      $ru->{'ru_id'},
      $xmlrpc_ret->{'result'}->{'itemid'},
      $rhtml_id,
      "E"
      );
    return
      "store_remote_itemid: " . $u->{'user'} . "," .
      $jitemid . "," . $ru->{'ru_id'} . "," .
      $xmlrpc_ret->{'result'}->{'itemid'} . "," . $rhtml_id . ": " .
      $r->{"errtext"} if $r->{"err"};
  };
  
  my $ritem = LJR::Distributed::get_remote_itemid($u->{'userid'}, $jitemid, "E");
  if ($ritem && ($req->{'props'}->{'revnum'} || $req->{'event'} !~ /\S/)) {
    $xmlrpc_ret = LJR::xmlrpc::xmlrpc_call($xmlrpc, "LJ.XMLRPC.getchallenge");
    return $xmlrpc_ret->{"err_text"} if $xmlrpc_ret->{"err_text"};
    $challenge = $xmlrpc_ret->{'result'}->{'challenge'};
    $response = Digest::MD5::md5_hex($challenge . Digest::MD5::md5_hex($r->{'remote_password'}));
    $xmlrpc_req->{'auth_challenge'} = $challenge;
    $xmlrpc_req->{'auth_response'} = $response;

    $xmlrpc_req->{'itemid'} = $ritem->{'ritemid'};
    
    $xmlrpc_ret = LJR::xmlrpc::xmlrpc_call($xmlrpc, "LJ.XMLRPC.editevent", $xmlrpc_req);
    if ($xmlrpc_ret->{'err_text'}) {
      if ($is_invalid_remote_entry->($xmlrpc_ret->{'err_text'})) {
        LJR::Distributed::remove_remote_itemid($u, $jitemid, $ru->{'ru_id'}, $ritem->{'ritemid'}, "E");
        my $errmsg = $post_new_event->();
        return $errmsg if $errmsg;
      }
      elsif ($is_invalid_remote_journal->($xmlrpc_ret->{'err_text'})) {
        $r = LJR::Distributed::update_export_status($u->{'user'}, 0, "ERROR: " . $xmlrpc_ret->{'err_text'});
        return $xmlrpc_ret->{"err_text"} . " " . ($r->{'err'} ? $r->{'errtext'} : "");
      }
      $r = LJR::Distributed::update_export_status($u->{'user'}, 1, "ERROR: " . $xmlrpc_ret->{'err_text'});
      return $xmlrpc_ret->{"err_text"} . " " . ($r->{'err'} ? $r->{'errtext'} : "");
    }
    if ($req->{'event'} !~ /\S/) {
      LJR::Distributed::remove_remote_itemid($u, $jitemid, $ru->{'ru_id'}, $ritem->{'ritemid'}, "E");
    }

  }
  else {
    my $errmsg = $post_new_event->();
    return $errmsg if $errmsg;
  }
  
  $r = LJR::Distributed::update_export_status($u->{'user'}, 1, "OK: $last_status");
  return $r->{'errtext'} if $r->{'err'};
    
  return;
}
