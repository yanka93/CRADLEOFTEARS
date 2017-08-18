#!/usr/bin/perl
#

use strict;
use vars qw(%maint %maintinfo);
use lib "$ENV{'LJHOME'}/cgi-bin";  # extra XML::Encoding files in cgi-bin/XML/*
use LWP::UserAgent;
use XML::RSS;
use HTTP::Status;
use Image::Size;
require "ljprotocol.pl";
require "parsefeed.pl";
require "cleanhtml.pl";
require "talklib.pl";
require LWPx::ParanoidAgent;
require LJR::unicode;

use utf8;
binmode STDOUT, ":utf8";

my $dumpxml = sub {
  my ($xdata, $username) = @_;

  open(my $outfile, ">$ENV{'LJHOME'}/logs/syn_err_" . $username . ".xml");
  print $outfile "$xdata";
  close($outfile);
};

my $err = sub {
  my ($msg) = @_;
  print $msg . "\n";
  return;
};

my $get_picture = sub {
  my ($userid, $url) = @_;

  my $MAX_UPLOAD = 102400;

  my $ua = LWPx::ParanoidAgent->new(timeout => 30, max_size => $MAX_UPLOAD + 1024);
  $ua->agent("Synsuck::Userpic; $LJ::SITENAME; $LJ::ADMIN_EMAIL");
  
  my $res = $ua->get($url);
  my $picdata = $res->content;

  return $err->("some error while getting userpic") if !($res && $res->is_success);
  return $err->("404 while getting userpic") if ($res && $res->{"_rc"} eq 404);
  return $err->("userpic size is bigger than we want") if length($picdata) > $MAX_UPLOAD;

  my ($sx, $sy, $filetype) = Image::Size::imgsize(\$picdata);
  return $err->("can't ge userpic size") unless defined $sx;
  return $err->("unknown userpic filetype") unless $filetype eq "GIF" || $filetype eq "JPG" || $filetype eq "PNG";
  return $err->("userpic is bigger than we want") if $sx > 150 || $sy > 150;

  my $contenttype;
  if ($filetype eq "GIF") { $contenttype = 'G'; }
  elsif ($filetype eq "PNG") { $contenttype = 'P'; }
  elsif ($filetype eq "JPG") { $contenttype = 'J'; }

  my $base64 = Digest::MD5::md5_base64($picdata);
  
  my $picid = LJ::alloc_global_counter('P') or return;
      
  my $dbh = LJ::get_db_writer();
  $dbh->do(
    "INSERT INTO userpic2" .
    "(picid, userid, fmt, width, height, picdate, md5base64, location, state, url) " .
    "VALUES (?, ?, ?, ?, ?, NOW(), ?, ?, 'N', ?)",
    undef, $picid, $userid, $contenttype, $sx, $sy, $base64, undef, $url);
  $dbh->do(
    "INSERT INTO userpicblob2 (userid, picid, imagedata) VALUES (?,?,?)",
    undef, $userid, $picid, $picdata);
    
  my $su = LJ::load_userid($userid);
  LJ::update_user($su, { defaultpicid => $picid });
};

$maintinfo{'synsuck'}{opts}{locking} = "per_host";
$maint{'synsuck'} = sub
{
    my $maxcount = shift || 0;
    my $verbose = $LJ::LJMAINT_VERBOSE;

    my %child_jobs; # child pid => [ userid, lock ]

    my $process_user = sub {
        my $urow = shift;
        return unless $urow;

        my ($user, $userid, $synurl, $lastmod, $etag, $lastmod_feed, $readers) =
            map { $urow->{$_} } qw(user userid synurl lastmod etag lastmod_feed numreaders);

        # we're a child process now, need to invalidate caches and
        # get a new database handle
        LJ::start_request();

        my $dbh = LJ::get_db_writer();

        # see if things have changed since we last looked and acquired the lock.
        # otherwise we could 1) check work, 2) get lock, and between 1 and 2 another
        # process could do both steps.  we don't want to duplicate work already done.
        my $now_checknext = $dbh->selectrow_array("SELECT checknext FROM syndicated ".
                                                  "WHERE userid=?", undef, $userid);
        return if $now_checknext ne $urow->{checknext};

        my $ua = LWP::UserAgent->new("timeout" => 30);
        my $reader_info = $readers ? "; $readers readers" : "";
        $ua->agent("$LJ::SITENAME ($LJ::ADMIN_EMAIL; for $LJ::SITEROOT/users/$user/" . $reader_info . ")");

        my $delay = sub {
            my $minutes = shift;
            my $status = shift;

            # add some random backoff to avoid waves building up
            $minutes += int(rand(5));

            $dbh->do("UPDATE syndicated SET lastcheck=NOW(), checknext=DATE_ADD(NOW(), ".
                     "INTERVAL ? MINUTE), laststatus=? WHERE userid=?",
                     undef, $minutes, $status, $userid);
        };

        print "[$$] Synsuck: fetching $user ($synurl)\n" if $verbose;

        my $req = HTTP::Request->new("GET", $synurl);
        $req->header('If-Modified-Since', $lastmod)
            if $lastmod;
        $req->header('If-None-Match', $etag)
            if $etag;

        my ($content, $too_big);
        my $max_size = $LJ::SYNSUCK_MAX_SIZE || 500; # in kb
        my $res = eval {
          $ua->request($req, sub {
            if (length($content) > 1024*$max_size) { $too_big = 1; return; }
            $content .= $_[0];
          }, 4096);
        };
        if ($@) { $delay->(120, "lwp_death"); return; }
        if ($too_big) { $delay->(60, "toobig"); return; }
  
        if ($res->is_error()) {
            # http error
            print "  HTTP error! " . $res->status_line() . "\n" if $verbose;

            $delay->(3*60, "httperror");

            # overload rssparseerror here because it's already there -- we'll
            # never have both an http error and a parse error on the
            # same request
            
            LJ::set_userprop($userid, "rssparseerror", $res->status_line());
            return;
        }
        
        # check if not modified
        if ($res->code() == RC_NOT_MODIFIED) {
            print "  not modified.\n" if $verbose;
            $delay->($readers ? 30 : 12*60, "notmodified");
            return;
        }

        my $r_lastmod = $res->header('Last-Modified');
        my $r_etag = $res->header('ETag');

        # check again (feedburner.com, blogspot.com, etc.)
        if (($etag && $etag eq $r_etag) || ($lastmod && $lastmod eq $r_lastmod)) {
            print "  not modified.\n" if $verbose;
            $delay->($readers ? 30 : 12*60, "notmodified");
            return;
        }

        # force utf8; this helps from time to time  ???
        LJR::unicode::force_utf8(\$content);
	
        # parsing time...
        my ($feed, $error) = LJ::ParseFeed::parse_feed($content);
        if ($error) {
            # parse error!
            print "Parse error! $error\n" if $verbose;
            $delay->(3*60, "parseerror");
            $error =~ s! at /.*!!;
            $error =~ s/^\n//; # cleanup of newline at the beggining of the line
            LJ::set_userprop($userid, "rssparseerror", $error);
            $dumpxml->($content, $user);
            return;
        }

        my $r_lastmod_feed = $feed->{'lastmod'};
        my $r_lastmod_lastBuildDate = $feed->{'lastBuildDate'};
			
 print " $lastmod \n $r_lastmod \n   $etag \n   $r_etag \n $lastmod_feed \n $r_lastmod_feed \n   $r_lastmod_lastBuildDate \n ";

        # check last-modified for bogus web-servers
        if ($lastmod_feed && $lastmod_feed eq $r_lastmod_feed) {
            print "  not modified..\n" if $verbose;
            $delay->($readers ? 30 : 12*60, "notmodified");
            return;
        }

# print " $lastmod \n $r_lastmod \n   $etag \n   $r_etag \n $lastmod_feed \n $r_lastmod_feed \n   $r_lastmod_lastBuildDate \n ";

        # another sanity check
        unless (ref $feed->{'items'} eq "ARRAY") {
            $delay->(3*60, "noitems");
            return;
        }

        # update userpic
        my $cur_pic = $dbh->selectrow_array(
          "SELECT url FROM userpic2, user WHERE user.userid=? and
          userpic2.userid=user.userid and userpic2.picid=user.defaultpicid",
          undef, $userid);
        if (
          ($feed->{'image'} && $cur_pic && $cur_pic ne $feed->{'image'}) ||
          ($feed->{'image'} && !$cur_pic)
          ) {
          $dbh->do("delete from userpic2 WHERE userid=?", undef, $userid);
          $dbh->do("delete from userpicblob2 WHERE userid=?", undef, $userid);
          $dbh->do("update user set user.defaultpicid=NULL where userid=?", undef, $userid);

          print "[$$] Synsuck: $user -- trying to fetch userpic from: " .
            $feed->{'image'} . " \n" if $verbose;
    
          $get_picture->($userid, $feed->{'image'});
        }

        my @items = reverse @{$feed->{'items'}};


        # delete existing items older than the age which can show on a
        # friends view.
        my $su = LJ::load_userid($userid);
        my $udbh = LJ::get_cluster_master($su);
        unless ($udbh) {
            $delay->(15, "nodb");
            return;
        }

        # TAG:LOG2:synsuck_delete_olderitems
#        my $secs = ($LJ::MAX_FRIENDS_VIEW_AGE || 3600*24*14)+0;  # 2 week default.
#        my $sth = $udbh->prepare("SELECT jitemid, anum FROM log2 WHERE journalid=? AND ".
#                                 "logtime < DATE_SUB(NOW(), INTERVAL $secs SECOND)");
#        $sth->execute($userid);
#        die $udbh->errstr if $udbh->err;
#        while (my ($jitemid, $anum) = $sth->fetchrow_array) {
#            print "DELETE itemid: $jitemid, anum: $anum... \n" if $verbose;
#            if (LJ::delete_entry($su, $jitemid, 0, $anum)) {
#                print "success.\n" if $verbose;
#            } else {
#                print "fail.\n" if $verbose;
#            }
#        }


        my $count = $udbh->selectrow_array("SELECT COUNT(*) FROM log2 WHERE journalid=$userid");
        print "count = $count \n";

        my $extra = $count - $LJ::MAX_SCROLLBACK_FRIENDS_SINGLE_USER_ACTIVITY;
        if ($extra > 0) {
            my $sth = $udbh->prepare("SELECT jitemid FROM logprop2 WHERE journalid=$userid".
                                     " ORDER BY jitemid ASC LIMIT $extra");
            $sth->execute();
            while (my ($jitemid) = $sth->fetchrow_array) {

                print "DELETE itemid: $jitemid... \n" if $verbose;
                if (LJ::delete_entry($su, $jitemid)) {
                    print "success.\n" if $verbose;
                } else {
                    print "fail.\n" if $verbose;
                }
            }
        }

        # determine if link tags are good or not, where good means
        # "likely to be a unique per item".  some feeds have the same
        # <link> element for each item, which isn't good.
        # if we have unique ids, we don't compare link tags

        my ($compare_links, $have_ids) = 0;
        {
            my %link_seen;
            foreach my $it (@items) {
                $have_ids = 1 if $it->{'id'};
                next unless $it->{'link'};
                $link_seen{$it->{'link'}} = 1;
            }
            $compare_links = 1 if !$have_ids and $feed->{'type'} eq 'rss' and
                scalar(keys %link_seen) == scalar(@items);
        }

        # if we have unique links/ids, load them for syndicated
        # items we already have on the server.  then, if we have one
        # already later and see it's changed, we'll do an editevent
        # instead of a new post.
        my %existing_item = ();
        if ($have_ids || $compare_links) {
            my $p = $have_ids ? LJ::get_prop("log", "syn_id") :
                LJ::get_prop("log", "syn_link");
            my $sth = $udbh->prepare("SELECT jitemid, value FROM logprop2 WHERE ".
                                     "journalid=? AND propid=? ORDER BY jitemid DESC LIMIT 1000"); # need last 100
            $sth->execute($su->{'userid'}, $p->{'id'});

            while (my ($jitemid, $id) = $sth->fetchrow_array) {
	    
                if (!defined $existing_item{$id}) {
                    $existing_item{$id} = $jitemid;
#                   print "Got it: $jitemid, $id\n" if $verbose;
                } else {
                    # remove duplicates - if any:
                    print "DELETE duplicated itemid: $jitemid, $id ...\n" if $verbose;
                    if (LJ::delete_entry($su, $jitemid)) {
                        print "success.\n" if $verbose;
                    } else {
                        print "fail.\n" if $verbose;
                    }
                }
            }
        }

        # post these items
        my $newcount = 0;
        my $errorflag = 0;
        my $mindate;  # "yyyy-mm-dd hh:mm:ss";
        my $notedate = sub {
            my $date = shift;
            $mindate = $date if ! $mindate || $date lt $mindate;
        };

        LJ::load_user_props($su, { use_master => 1 }, "newesteventtime");
        ###  if ($su->{'newesteventtime'} eq $oldevent->{'eventtime'}) {
        ###      LJ::set_userprop($su, "newesteventtime", undef);
        ###  }

        foreach my $it (@items) {

            if ($it->{'time'} && $it->{'time'} lt $su->{'newesteventtime'}) {
##                print "---- " . $it->{'subject'} . "\n" if $verbose;
                next;
            } elsif ($it->{'time'} && $it->{'time'} eq $su->{'newesteventtime'}) {
                print "==== " . $it->{'subject'} . "\n" if $verbose;
            } else {
                print "++++ " . $it->{'subject'} . "\n" if $verbose;
            }


            my $dig = LJ::md5_struct($it)->b64digest;
            my $prevadd = $dbh->selectrow_array("SELECT MAX(dateadd) FROM synitem WHERE ".
                                                "userid=? AND item=?", undef,
                                                $userid, $dig);
            if ($prevadd) {
                $notedate->($prevadd);
                next;
            }

            my $now_dateadd = $dbh->selectrow_array("SELECT NOW()");
            die "unexpected format" unless $now_dateadd =~ /^\d\d\d\d\-\d\d\-\d\d \d\d:\d\d:\d\d$/;

            $dbh->do("INSERT INTO synitem (userid, item, dateadd) VALUES (?,?,?)",
                     undef, $userid, $dig, $now_dateadd);
            $notedate->($now_dateadd);

            $newcount++;
            print "[$$] $dig - $it->{'subject'}\n" if $verbose;
            $it->{'text'} =~ s/^\s+//;
            $it->{'text'} =~ s/\s+$//;

            # process lj-cuts
            while ($it->{'text'} =~ /\G(.*?)<a\ name\=\"cutid(\d+)\"\>\<\/a\>(.*)/sg) {
              my $before = $1;
              my $cutid = $2;
              my $rcut = $3;
              $rcut =~ s/<a\ name\=\"cutid$cutid\"\>\<\/a\>/\<\/lj\-cut\>/;
              $it->{'text'} = $before . "<lj-cut>" . $rcut;
            }
            
            my $htmllink;
            if (defined $it->{'link'}) {
                $htmllink = "<p class='ljsyndicationlink'>" .
                    "<a href='$it->{'link'}'>$it->{'link'}</a></p>";
            }

            # Show the <guid> link if it's present and different than the
            # <link>.
            # [zilla: 267] Patch: Chaz Meyers <lj-zilla@thechaz.net>
            if ( defined $it->{'id'} && $it->{'id'} ne $it->{'link'}
                     && $it->{'id'} =~ m!^http://! )
                {
                    $htmllink .= "<p class='ljsyndicationlink'>" .
                        "<a href='$it->{'id'}'>$it->{'id'}</a></p>";
                }

            # rewrite relative URLs to absolute URLs, but only invoke the HTML parser
            # if we see there's some image or link tag, to save us some work if it's
            # unnecessary (the common case)
            if ($it->{'text'} =~ /<(?:img|a)\b/i) {
                # TODO: support XML Base?  http://www.w3.org/TR/xmlbase/
                my $base_href = $it->{'link'} || $synurl;
                LJ::CleanHTML::resolve_relative_urls(\$it->{'text'}, $base_href);
            }
      
      

            # $own_time==1 means we took the time from the feed rather than localtime
            my ($own_time, $year, $mon, $day, $hour, $min);

            if ($it->{'time'} && 
                $it->{'time'} =~ m!^(\d\d\d\d)-(\d\d)-(\d\d) (\d\d):(\d\d)!) {
                $own_time = 1;
                ($year, $mon, $day, $hour, $min) = ($1,$2,$3,$4,$5);
            } else {
                $own_time = 0;
                my @now = localtime();
                ($year, $mon, $day, $hour, $min) = 
                    ($now[5]+1900, $now[4]+1, $now[3], $now[2], $now[1]);
            }


            my $command = "postevent";
            my $req = {
                'username' => $user,
                'ver' => 1,
                'subject' => $it->{'subject'},
                'event' => "$it->{'text'}",
                'year' => $year,
                'mon' => $mon,
                'day' => $day,
                'hour' => $hour,
                'min' => $min,
                'props' => {
                'syn_link' => $it->{'link'},
                'opt_nocomments' => 1,
                },
            };
            $req->{'props'}->{'syn_id'} = $it->{'id'} 
                if $it->{'id'};

            my $flags = {
                'nopassword' => 1,
            };

            # if the post contains html linebreaks, assume it's preformatted.
            if ($it->{'text'} =~ /<(?:p|br)\b/i) {
                $req->{'props'}->{'opt_preformatted'} = 1;
            }

            # do an editevent if we've seen this item before
            my $id = $have_ids ? $it->{'id'} : $it->{'link'};
            my $old_itemid = $existing_item{$id};
            if ($id && $old_itemid) {
                $newcount--; # cancel increment above
                $command = "editevent";
                $req->{'itemid'} = $old_itemid;
                
                # the editevent requires us to resend the date info, which
                # we have to go fetch first, in case the feed doesn't have it
                
                # TAG:LOG2:synsuck_fetch_itemdates
                unless($own_time) {
                    my $origtime = 
                        $udbh->selectrow_array("SELECT eventtime FROM log2 WHERE ".
                                               "journalid=? AND jitemid=?", undef,
                                               $su->{'userid'}, $old_itemid);
                    $origtime =~ /(\d\d\d\d)-(\d\d)-(\d\d) (\d\d):(\d\d)/;
                    $req->{'year'} = $1;
                    $req->{'mon'} = $2;
                    $req->{'day'} = $3;
                    $req->{'hour'} = $4;
                    $req->{'min'} = $5;
                }
            }

            my $err;
    
            my $res = LJ::Protocol::do_request($command, $req, \$err, $flags);
    
            unless ($res && ! $err) {
                print "  Error: $err\n" if $verbose;
                $errorflag = 1;
            }
        }

        # delete some unneeded synitems.  the limit 1000 is because
        # historically we never deleted and there are accounts with
        # 222,000 items on a myisam table, and that'd be quite the
        # delete hit.
        # the 14 day interval is because if a remote site deleted an
        # entry, it's possible for the oldest item that was previously
        # gone to reappear, and we want to protect against that a
        # little.
        if ($LJ::SYNITEM_CLEAN) {
            $dbh->do("DELETE FROM synitem WHERE userid=? AND ".
                     "dateadd < ? - INTERVAL 14 DAY LIMIT 1000",
                     undef, $userid, $mindate);
        }
        $dbh->do("UPDATE syndicated SET oldest_ourdate=? WHERE userid=?",
                 undef, $mindate, $userid);

        # bail out if errors, and try again shortly
        if ($errorflag) {
            $delay->(30, "posterror");
            return;
        }
            
        # update syndicated account's userinfo if necessary
        LJ::load_user_props($su, "url", "urlname");
        {
            my $title = $feed->{'title'};
            $title = $su->{'user'} unless LJ::is_utf8($title);
            $title =~ s/[\n\r]//g;
            if ($title && $title ne $su->{'name'}) {
                LJ::update_user($su, { name => $title });
            }
            if ($title) {
                LJ::set_userprop($su, "urlname", $title);
            } else {
                LJ::set_userprop($su, "urlname", $su->{'url'});
            }

            my $link = $feed->{'link'};
            if ($link && $link ne $su->{'url'}) {
                LJ::set_userprop($su, "url", $link);
            }

            my $des = $feed->{'description'};
            if ($des) {
                my $bio;
                if ($su->{'has_bio'} eq "Y") {
                    $bio = $udbh->selectrow_array("SELECT bio FROM userbio WHERE userid=?", undef,
                                                  $su->{'userid'});
                }
                if ($bio ne $des && $bio !~ /\[LJ:KEEP\]/) {
                    if ($des) {
                        $su->do("REPLACE INTO userbio (userid, bio) VALUES (?,?)", undef,
                                $su->{'userid'}, $des);
                    } else {
                        $su->do("DELETE FROM userbio WHERE userid=?", undef, $su->{'userid'});
                    }
                    LJ::update_user($su, { has_bio => ($des ? "Y" : "N") });
                    LJ::MemCache::delete([$su->{'userid'}, "bio:$su->{'userid'}"]);
                }
            }
        }

        # decide when to poll next (in minutes). 
        # FIXME: this is super lame.  (use hints in RSS file!)
        my $int = $newcount ? 15 : 30;
        my $status = $newcount ? "ok" : "nonew";
        my $updatenew = $newcount ? ", lastnew=NOW()" : "";
        
        # update reader count while we're changing things, but not
        # if feed is stale (minimize DB work for inactive things)
        if ($newcount || ! defined $readers) {
            $readers = $dbh->selectrow_array("SELECT COUNT(*) FROM friends WHERE ".
                                             "friendid=?", undef, $userid);
        }

        # if readers are gone, don't check for a whole day
        $int = 60*24 if $readers && $readers < 2 || !$readers;

        $dbh->do("UPDATE syndicated SET checknext=DATE_ADD(NOW(), INTERVAL $int MINUTE), ".
                 "lastcheck=NOW(), lastmod=?, etag=?, lastmod_feed=? , laststatus=?, numreaders=? $updatenew ".
                 "WHERE userid=$userid", undef, $r_lastmod, $r_etag, $r_lastmod_feed, $status, $readers);
    };

    ###
    ### child process management
    ###

    # get the next user to be processed
    my @all_users;
    my $get_next_user = sub {
        return shift @all_users if @all_users;

        # need to get some more rows
        my $dbh = LJ::get_db_writer();
        my $current_jobs = join(",", map { $dbh->quote($_->[0]) } values %child_jobs);
        my $in_sql = " AND u.userid NOT IN ($current_jobs)" if $current_jobs;
        my $sth = $dbh->prepare("SELECT u.user, s.userid, s.synurl, s.lastmod, " .
                                "       s.etag, s.lastmod_feed, s.numreaders, s.checknext " .
                                "FROM user u, syndicated s " .
                                "WHERE u.userid=s.userid AND u.statusvis='V' " .
                                "AND s.checknext < NOW()$in_sql " .
                                "ORDER BY RAND() LIMIT 500");
        $sth->execute;
        while (my $urow = $sth->fetchrow_hashref) {
            push @all_users, $urow;
        }

        return undef unless @all_users;
        return shift @all_users;
    };

    # fork and manage child processes
    my $max_threads = $LJ::SYNSUCK_MAX_THREADS || 1;
    print "[$$] PARENT -- using $max_threads workers\n" if $verbose;

    my $threads = 0;
    my $userct = 0;
    my $keep_forking = 1;
    while ( $maxcount == 0 || $userct < $maxcount ) {

        if ($threads < $max_threads && $keep_forking) {
            my $urow = $get_next_user->();
            unless ($urow) {
                $keep_forking = 0;
                next;
            }

            my $lockname = "synsuck-user-" . $urow->{user};
            my $lock = LJ::locker()->trylock($lockname);
            next unless $lock;
            print "Got lock on '$lockname'. Running\n" if $verbose;

            # spawn a new process
            if (my $pid = fork) {
                # we are a parent, nothing to do?
                $child_jobs{$pid} = [$urow->{'userid'}, $lock];
                $threads++;
                $userct++;
            } else {
                # handles won't survive the fork
                LJ::disconnect_dbs();
                $process_user->($urow);
                exit 0;
            }

        # wait for child(ren) to die
        } else {
            my $child = wait();
            last if $child == -1;
            delete $child_jobs{$child};
            $threads--;
        }
    }

    # Now wait on any remaining children so we don't leave zombies behind.
    while ( %child_jobs ) {
        my $child = wait();
        last if $child == -1;
        delete $child_jobs{ $child };
        $threads--;
    }

    print "[$$] $userct users processed\n" if $verbose;
    return;
};

1;


# Local Variables:
# mode: perl
# c-basic-indent: 4
# indent-tabs-mode: nil
# End:
