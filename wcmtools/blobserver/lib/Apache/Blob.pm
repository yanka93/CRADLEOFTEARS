#!/usr/bin/perl
# vim:ts=4 sw=4 et:

package Apache::Blob;

use strict;
use File::Path;
use Fcntl ':flock';
use Apache::Constants qw(:common HTTP_BAD_REQUEST HTTP_NO_CONTENT M_GET M_PUT M_DELETE);
use lib "$ENV{'BLOBHOME'}";

my $ROOT = "$ENV{'BLOBHOME'}/root";

sub handler
{
    my $r = shift;
    $r->set_handlers(PerlTransHandler => [ \&trans ]);
    return OK;
}

sub trans
{
    my $r = shift;
    my $uri = $r->uri;

    my $path = $ROOT . $uri;

    if ($r->method_number == M_GET) {
        # get requests just go through to the file system.
        $r->handler("perl-script");
        $r->push_handlers(PerlHandler => sub {
            my $r = shift;
            # let apache handle it.
            $r->filename($path);
            return DECLINED;
        });
        return OK;
    } elsif ($r->method_number == M_PUT ||
             $r->method_number == M_DELETE) {
        # /cluster/u1/u2/u3/type/m1/m2
        #  1       2  3  4  5    6  7
        return HTTP_BAD_REQUEST unless $uri =~ m#^/\d+/\d+/\d+/\d+/\w+/\d+/\d+\.\w+$#;
        $r->handler("perl-script");
        $r->push_handlers(PerlHandler => sub {
            my $r = shift;
            return delete_blob($r) if $r->method_number == M_DELETE;
            return HTTP_NO_CONTENT if $r->method_number == M_PUT && save_blob($r, $path);
            return SERVER_ERROR;
        });
        return OK;
    }
    return HTTP_BAD_REQUEST;
}

# directory listing
#   sub dir_trans
#   {
#       my ($r, $uri) = @_;
#       if ($uri =~ m#^/(\d+)/(\d+)/(\w+)/?$#) {
#           my ($cid, $uid) = ($1, $2, $3);
#           $r->handler("perl-script");
#           $r->notes(dir => make_path($cid, $uid));
#           $r->push_handlers(PerlHandler => \&dirlisting);
#           return OK;
#       }
#       if ($uri =~ m#^/(\d+)/(\d+)/?$#) {
#           my ($cid, $uid) = ($1, $2);
#           $r->handler("perl-script");
#           $r->notes(dir => make_path($cid, $uid));
#           $r->push_handlers(PerlHandler => \&dirlisting);
#           return OK;
#       }
#       return 400;
#   }

#   sub dirlisting
#   {
#       my $r = shift;
#       return 404 unless (opendir(DIR, $r->notes('dir')));
#       $r->content_type("text/plain");
#       $r->send_http_header();
#       foreach my $f (readdir(DIR)) {
#           next if $f eq '.' or $f eq '..';
#           $r->print("$f\n");
#       }
#       closedir(DIR);
#       return OK;
#   }

# blob access
#   sub blob_trans
#   {
#       my ($r, $uri, $cid, $uid, $mid) = @_;
#       my $path = make_path($cid, $uid, $mid);
#
#       if ($r->method_number == M_PUT) {
#       } else {
#           return 404 unless -r $path;
#           $r->handler("perl-script");
#           $r->push_handlers(PerlHandler => sub {
#               my $r = shift;
#               
#               # these content-types aren't exactly correct.
#               if ($blobtype eq 'audio') {
#                   $r->content_type("audio/mp3");
#               } else {
#                   $r->content_type("application/octet-stream");
#               }
#               $r->send_http_header();
#
#               # let apache handle sending the file.
#               $r->filename($path);
#               return DECLINED;
#           });
#       }
#   }

sub make_dirs
{
    my $filename = shift;
    my $dir = File::Basename::dirname($filename);
    eval { File::Path::mkpath($dir, 0, 0775); };
    return $@ ? 0 : 1;
}

sub save_blob
{
    my ($r, $path) = @_;

    my $length = $r->header_in("Content-Length");

    make_dirs($path);   
    open(FILE, ">$path.tmp") or die "couldn't make $path";
    binmode(FILE);
    flock(FILE, LOCK_EX) or die "couldn't lock";

    my ($buff, $lastsize);
    my $got = 0;
    my $nextread = 4096;
    $r->soft_timeout("save_blob"); # ?
    while ($got <= $length && ($lastsize = $r->read_client_block($buff, $nextread))) {
        $r->reset_timeout;
        $got += $lastsize;
        print FILE $buff;
        if ($length - $got < 4096) { $nextread = $length - $got; }
    }
    $r->kill_timeout;

    flock(FILE, LOCK_UN) or die "couldn't unlock";
    close(FILE) or die "couldn't close";

    if ($got != $length) {
        unlink("$path.tmp");
        return 0;
    }

    if (-s "$path.tmp" == $length) {
        return 1 if rename("$path.tmp", $path);
    }

    unlink("$path.tmp");
    return 0;
}

sub delete_blob
{
    my $r = shift;
    my $uri = $r->uri;
    my $path = $ROOT . $uri;
    return NOT_FOUND unless -e $path;
    
    unlink($path) or return SERVER_ERROR;

    for (1..2) {
        next unless $uri =~ s!/[^/]+$!!;
        $path = $ROOT . $uri;
        last unless rmdir $path;
    }

    return HTTP_NO_CONTENT;
}

