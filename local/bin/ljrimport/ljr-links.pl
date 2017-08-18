#!/usr/bin/perl

use strict;

package LJR::Links;

sub get_server_url {
  my ($canonical_url, $type) = @_;
  
  if ($canonical_url eq "http://www.livejournal.com") {
    if ($type eq "base") {
      return "livejournal.com";
    }
    if ($type eq "userpic_base") {
      return "http://userpic.livejournal.com";
    }
  }
}

sub make_ljr_hrefs {
  my ($server_patt, $server_full, $text) = @_;

  my $content = $$text;
  $$text = "";
  my $url;
  my $orig_url;
  my $orig_url_text;

  return unless $content;

  # replace valid html hyperlinks (<a href=http://www.livejournal.com/users/username/111.html>url_text</a>)
  # with <ljr-href url="/users/username/111.html" site="http://www.livejournal.com">url_text</ljr-href>
  #
  while ($content =~
    /\G(.*?)(\<a.*?href.*?=(\s?\"\s?)?(.*?)(\s?\"\s?)?\>(.*?)\<\/a\>)(.*)/sgi
    ) {
    $$text .= $1;
    $orig_url = $2;
    $orig_url_text = $6;
    $url = $4;
    $content = $7;

    # relative link (to the server from which we're importing)
    if ($url =~ /^(\/users\/.*?\/\d*?\.html(.*?$))/) { # (\?thread=\d*\#t\d*)|$
      $$text .= "<ljr-href url=\"$1\" site=\"$server_full\">$orig_url_text</ljr-href>";
    }
    # relative link to oldstyle talkread.bml
    elsif ($url =~ /^\/talkread.bml?\?journal=(.*?)\&itemid=(\d+)/) {
      $$text .= "<ljr-href url=\"/users/$1/$2.html\" site=\"$server_full\">$orig_url_text</ljr-href>";
    }
    # absolute link to oldstyle talkread.bml
    elsif ($url =~ /^http:\/\/(www\.|)$server_patt\/talkread.bml\?journal=(.*?)\&itemid=(\d+)/) {
      $$text .= "<ljr-href url=\"/users/$2/$3.html\" site=\"$server_full\">$orig_url_text</ljr-href>";
    }
    # free users own two types of urls (first is canonical)
    #   http://www.livejournal.com/users/free_user/123456.html
    #   http://www.livejournal.com/~free_user/123456.html
    elsif ($url =~ /^http:\/\/(www\.|)$server_patt(((\/~(\w*?)\/)|(\/users\/.*?\/))(\d*?\.html(.*?$)))/) { # (\?thread=\d*\#t\d*)|$
      if ($5) {
        $$text .= "<ljr-href url=\"/users/$5/$7\" site=\"$server_full\">$orig_url_text</ljr-href>";
      }
      else {
        $$text .= "<ljr-href url=\"$2\" site=\"$server_full\">$orig_url_text</ljr-href>";
      }
    }
    # payed users might own http://payeduser.livejournal.com/123456.html urls
    elsif ($url =~ /^http:\/\/(\w*?)\.$server_patt\/(\d*?\.html(.*?$))/) { # (\?thread=\d*\#t\d*)|$
      $$text .= "<ljr-href url=\"/users/$1/$2\" site=\"$server_full\">$orig_url_text</ljr-href>";
    }
    else {
      $$text .= $orig_url;
    }
  }
  $$text .= $content;

  $content = $$text;
  $$text = "";


  # replace strings like http://www.livejournal.com/users/lookslikeentry/123456.html with
  # <ljr-href url="/users/lookslikeentry/123456.html" site="http://www.livejournal.com">http://www.livejournal.com/users/lookslikeentry/123456.html</ljr-href>
  #
  # now these can be only absolute links starting with http://
  while ($content =~
    /\G(.*?(^|[\ \t\r\n\f]))(http:\/\/.*?)(($|[\ \t\r\n\f]).*)/sg
    ) {
    $$text .= $1;
    $orig_url = $3;
    $orig_url_text = $3;
    $url = $3;
    $content = $4;

    # free users (copied from above)
    if ($url =~ /^http:\/\/(www\.|)$server_patt(((\/~(\w*?)\/)|(\/users\/.*?\/))(\d*?\.html(.*?$)))/) { # (\?thread=\d*\#t\d*)|$
      if ($5) {
        $$text .= "<ljr-href url=\"/users/$5/$7\" site=\"$server_full\">$orig_url_text</ljr-href>";
      }
      else {
        $$text .= "<ljr-href url=\"$2\" site=\"$server_full\">$orig_url_text</ljr-href>";
      }
    }
    # oldstyle talkread.bml
    elsif ($url =~ /^http:\/\/(www\.|)$server_patt\/talkread.bml\?journal=(.*?)\&itemid=(\d+)/) {
      $$text .= "<ljr-href url=\"/users/$2/$3.html\" site=\"$server_full\">$orig_url_text</ljr-href>";
    }
    # payed users (copied from above)
    elsif ($url =~ /^http:\/\/(\w*?)\.$server_patt\/(\d*?\.html(.*?$))/) { # (\?thread=\d*\#t\d*)|$
      $$text .= "<ljr-href url=\"/users/$1/$2\" site=\"$server_full\">$orig_url_text</ljr-href>";
    }
    else {
      $$text .= $orig_url;
    }
  }
  $$text .= $content;
}

return 1;
