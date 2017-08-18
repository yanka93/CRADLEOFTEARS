#!/usr/bin/perl
#
# <LJDEP>
# lib: Sys::Hostname, Getopt::Long, Fcntl::, POSIX::
# </LJDEP>

use strict;
use Sys::Hostname;
use Getopt::Long;
use Fcntl;
use POSIX qw(tmpnam);

my %DEFAULT = (
               'search' => 'lj',
               'ns1' => '10.2.0.1',
               );

my %MACHINE = (
               "stan" => {
                   'ipco' => '10.0.0.3',
                   'do_web' => 1,
                   'web_slave' => 1,
                   'paid_web_slave' => 1,
               },
               "kyle" => {
                   'ipco' => '10.0.0.4',
                   'do_web' => 1,
                   'web_slave' => 1,
                   'web_master' => 1,
               },
               "wendy" => {
                   'ipco' => '10.0.0.5',
                   'do_web' => 1,
                   'web_slave' => 1,
               },
               "bebe" => {
                   'ipco' => '10.0.0.6',
                   'do_web' => 1,
                   'web_slave' => 1,
               },
               "terrance" => {
                   'ipco' => '10.0.0.7',
                   'do_web' => 1,
                   'web_slave' => 1,
               },
               "phillip" => {
                   'ipco' => '10.0.0.8',
                   'do_web' => 1,
                   'web_slave' => 1,
                   'paid_web_slave' => 1,
               },
               "ike" => {
                   'ipco' => '10.0.0.11',
                   'do_web' => 1,
                   'web_slave' => 1,
               },
               "pip" => {
                   'ipco' => '10.0.0.12',
                   'do_web' => 1,
                   'web_slave' => 1,
               },
               "kenny" => {
                   'ipco' => '10.0.0.1',
                   'db_slave' => 1,
               },
               "cartman" => {
                   'ipco' => '10.0.0.2',
                   'db_master' => 1,
               },
               "mackey" => {
                   'ipco' => '10.0.0.9',
                   'db_slave' => 1,
               },
               "hat" => {
                   'ipco' => '10.0.0.10',
                   'db_slave' => 1,
               },
               "marklar" => {
                   'ip' => '216.231.32.128',
                   'ipco' => '10.0.0.15',
                   'db_slave' => 1,
               },
               "CRADLEOFTEARS" => {
                    'ip' => '192.168.93.93',
                    'ipco' => '10.0.2.15',
                    'db_master' => 1,
                    'do_web' => 1
                }
               );
use Sys::Hostname;
my $machine = hostname;
#unless ($machine =~ /^lj-(\w+)(\.livejournal\.com)?$/) {
#    die "Weird hostname.\n";
#}
print $machine;
my $DRY = 0;
my $HELP = 0;
exit 1 unless GetOptions(
                         'dryrun|n' => \$DRY,
                         'help' => \$HELP,
                         );

if ($HELP || ! defined $MACHINE{$machine}) {
    die("Usage: machine_config.pl [opts]\n\nWhere opts can be:\n".
        "--dryrun   -n    Don't change any config files; just show changes.\n".
        "--help     -h    This message.\n");
}

my $host = { %DEFAULT };
$host->{'name'} = $machine;
foreach (keys %{$MACHINE{$machine}}) {
    $host->{$_} = $MACHINE{$machine}->{$_};
}

print "Host information: ($host->{'name'})\n";
foreach (sort keys %{$host}) {
    printf "  %10s : %s\n", $_, $host->{$_};
}

setup_resolve_conf($host);
setup_hosts($host);
setup_httpd($host) if ($host->{'do_web'});

#####################

sub write_file
{
    my $file = shift;
    my $new = shift;
    my $old;

    open (IN, $file);
    while (<IN>) {
        $old .= $_;
    }
    close IN;

    if ($new ne $old) {
        if ($DRY) {
            my $tmp = tmpnam();
            die "temp file exists!\n" if (-e $tmp);
            print "$file needs updating!\n";
            open (OUT, ">$tmp");
            print OUT $new;
            close OUT;
            print `diff -u $file $tmp`;
            unlink $tmp;
        } else {
            print "Updating: $file\n";
            open (OUT, ">$file");
            print OUT $new;
            close OUT;
        }
    }
}

sub setup_resolve_conf
{
    my $host = shift;
    my $file = "/etc/resolv.conf";
    my $new;

    if (exists($host->{'search'})) {
        $new .= "search\t$host->{'search'}\n";
    }

    foreach my $ns (qw(ns1)) {
        next unless ($host->{$ns});
        $new .= "nameserver\t$host->{$ns}\n";
    }

    write_file($file, $new);
}

# NOTE: this used to do a lot more, before we had DNS running 
#       internally.
sub setup_hosts
{
    my $host = shift;
    my $file = "/etc/hosts";
    my $new;

    $new .= "127.0.0.1\tlocalhost\n";
    write_file($file, $new);
}

sub setup_httpd
{
    my $host = shift;
    my $file = "/usr/local/apache/conf/httpd.conf";
    my $new;

    $new .= <<"END_CONF";
ServerType standalone
ServerRoot "/usr/local/apache"
PidFile /usr/local/apache/logs/httpd.pid
ScoreBoardFile /usr/local/apache/logs/httpd.scoreboard
Timeout 30

## keep-alive
KeepAlive Off
MaxKeepAliveRequests 200
KeepAliveTimeout 50

MinSpareServers 15
MaxSpareServers 40
StartServers 170
MaxClients 255
MaxRequestsPerChild 0


# Dynamic Shared Object (DSO) Support
# Note: The order is which modules are loaded is important.  Don't change
# the order below without expert advice.

LoadModule vhost_alias_module libexec/mod_vhost_alias.so
LoadModule env_module         libexec/mod_env.so
LoadModule config_log_module  libexec/mod_log_config.so
#LoadModule mime_magic_module  libexec/mod_mime_magic.so
LoadModule mime_module        libexec/mod_mime.so
#LoadModule negotiation_module libexec/mod_negotiation.so
LoadModule status_module      libexec/mod_status.so
LoadModule info_module        libexec/mod_info.so
LoadModule includes_module    libexec/mod_include.so
LoadModule autoindex_module   libexec/mod_autoindex.so
LoadModule dir_module         libexec/mod_dir.so
LoadModule cgi_module         libexec/mod_cgi.so
#LoadModule asis_module        libexec/mod_asis.so
#LoadModule imap_module        libexec/mod_imap.so
LoadModule action_module      libexec/mod_actions.so
#LoadModule speling_module     libexec/mod_speling.so
#LoadModule userdir_module     libexec/mod_userdir.so
LoadModule alias_module       libexec/mod_alias.so
LoadModule rewrite_module     libexec/mod_rewrite.so
LoadModule access_module      libexec/mod_access.so
LoadModule auth_module        libexec/mod_auth.so
#LoadModule anon_auth_module   libexec/mod_auth_anon.so
#LoadModule dbm_auth_module    libexec/mod_auth_dbm.so
#LoadModule digest_module      libexec/mod_digest.so
#LoadModule proxy_module       libexec/libproxy.so
#LoadModule cern_meta_module   libexec/mod_cern_meta.so
LoadModule expires_module     libexec/mod_expires.so
#LoadModule headers_module     libexec/mod_headers.so
LoadModule usertrack_module   libexec/mod_usertrack.so
LoadModule unique_id_module   libexec/mod_unique_id.so
LoadModule setenvif_module    libexec/mod_setenvif.so
LoadModule fastcgi_module     libexec/mod_fastcgi.so
#LoadModule php4_module        libexec/libphp4.so

#  Reconstruction of the complete module list from all available modules
#  (static and shared ones) to achieve correct module execution order.
#  [WHENEVER YOU CHANGE THE LOADMODULE SECTION ABOVE UPDATE THIS, TOO]
ClearModuleList
AddModule mod_vhost_alias.c
AddModule mod_env.c
AddModule mod_log_config.c
#AddModule mod_mime_magic.c
AddModule mod_mime.c
#AddModule mod_negotiation.c
AddModule mod_status.c
AddModule mod_info.c
AddModule mod_include.c
AddModule mod_autoindex.c
AddModule mod_dir.c
AddModule mod_cgi.c
#AddModule mod_asis.c
#AddModule mod_imap.c
AddModule mod_actions.c
#AddModule mod_speling.c
#AddModule mod_userdir.c
AddModule mod_alias.c
AddModule mod_rewrite.c
AddModule mod_access.c
AddModule mod_auth.c
#AddModule mod_auth_anon.c
#AddModule mod_auth_dbm.c
#AddModule mod_digest.c
#AddModule mod_proxy.c
#AddModule mod_cern_meta.c
AddModule mod_expires.c
#AddModule mod_headers.c
AddModule mod_usertrack.c
AddModule mod_unique_id.c
AddModule mod_so.c
AddModule mod_setenvif.c
AddModule mod_fastcgi.c
#AddModule mod_php4.c

ExtendedStatus On
Port 80
END_CONF

    if ($host->{'ip'} && ! $host->{'web_slave'}) {
        $new .= "Listen $host->{'ip'}:80\n";
    }

    $new .= <<"END_CONF";
Listen $host->{'ipco'}:80

User lj
Group lj

ServerAdmin webmaster\@livejournal.com
ServerName lj-$host->{'name'}.livejournal.com

DocumentRoot "/usr/local/apache/htdocs"

<Location /status>
    SetHandler server-status
    Order deny,allow
    Deny from all
    Allow from 10.0 66.31.142.7
</Location>

<IfModule mod_dir.c>
    DirectoryIndex index.html index.bml
</IfModule>
<Directory "/home/lj">
    Options Indexes FollowSymLinks ExecCGI
#for speed, instead of "All"
    AllowOverride None   

    Order allow,deny
    Allow from all
</Directory>

SendBufferSize 131072

#######################################
END_CONF
    if ($host->{'ip'} && ! $host->{'web_slave'}) {
        $new .= "NameVirtualHost $host->{'ip'}:80\n";
    }

    $new .= <<"END_CONF";
NameVirtualHost $host->{'ipco'}:80

FastCgiSuexec Off
FastCgiConfig -maxClassProcesses 10  -startDelay 1 -idle-timeout 20

END_CONF
    
    if ($host->{'web_master'}) {
        $new .= <<"END_CONF";

# site's down message.
Listen 10.0.0.4:81
NameVirtualHost 10.0.0.4:81
<VirtualHost 10.0.0.4:81>
  SetEnv LJHOME /home/lj
   FastCgiServer /home/lj/sites/sitedown/index.cgi -processes 1
   ServerName livejournal.com
   ServerAlias *.livejournal.com
   DocumentRoot /home/lj/sites/sitedown/
   DirectoryIndex index.cgi
   ErrorDocument 404 /index.cgi 
   <Location /index.cgi>
     SetHandler fastcgi-script
   </Location>
</VirtualHost>

### mrtg.livejournal.com
Listen 10.0.0.4:88
NameVirtualHost 10.0.0.4:88
<VirtualHost 10.0.0.4:88>
  SetEnv LJHOME /home/lj
  ServerName mrtg.livejournal.com
  ServerAlias mrtg.livejournal.com

  ServerAdmin webmaster\@livejournal.com
  DocumentRoot /home/lj/sites/mrtg/
  DirectoryIndex index.cgi
  AddHandler cgi-script .cgi
  Options -Indexes +ExecCGI

  # Putting netsaint's aliases here for now.
  Alias /netsaint/ /usr/local/netsaint/share/
  ScriptAlias /cgi-bin/netsaint/ /usr/local/netsaint/sbin/

  ErrorLog /dev/null
  TransferLog /dev/null

</VirtualHost>
END_CONF

    }

    $new .= "    <VirtualHost";
    if ($host->{'ip'} && $host->{'web_master'}) {
        $new .= " $host->{'ip'}:80";
    }
    $new .= " $host->{'ipco'}:80>\n";
    $new .="     SetEnv LJHOME /home/lj\n";
    {
        my %fcgi = ('/home/lj/htdocs/users' => 10,
                    '/home/lj/cgi-bin/log.cgi' => 4,
                    '/home/lj/cgi-bin/404notfound.cgi' => 1,
                    '/home/lj/htdocs/customview.cgi' => 4,
                    '/home/lj/cgi-bin/bmlp.pl' => 7,
                    '/home/lj/cgi-bin/sbmlp.pl' => 3,
                    '/home/lj/htdocs/userpic' => 1);

        if ($host->{'name'} eq "kenny") {
            $fcgi{'/home/lj/htdocs/users'} = 5;
            $fcgi{'/home/lj/htdocs/customview.cgi'} = 2;
            $fcgi{'/home/lj/cgi-bin/bmlp.pl'} = 4;
            $fcgi{'/home/lj/cgi-bin/sbmlp.pl'} = 2;
            $fcgi{'/home/lj/cgi-bin/log.cgi'} = 2;
        }
        foreach my $app (sort keys %fcgi)
        {
            $new .= "  FastCgiServer $app -processes $fcgi{$app} -initial-env LJHOME=/home/lj\n";
        }
    }
    
    ########## rewrite stuff.  no interpolation.
    $new .= <<'END_CONF';
  RewriteEngine on
  RewriteLog /home/lj/logs/rewrite.log
  RewriteLogLevel 0

  RewriteCond %{HTTP_HOST} ^(www\.)?livejournal\.com$ [NC]
  RewriteRule ^/~([a-z0-9_]+)(/?.*)$ /users/$1$2 [L,PT,NS]

  RewriteCond %{REQUEST_URI} !\.bml
  RewriteRule ^/community/([a-z0-9_]+)(/?.*)$ /users/$1$2 [L,PT,NS]

  RewriteCond %{HTTP_HOST} ^([a-z0-9_\-]+)\.livejournal\.com$ [NC]
  RewriteCond %1 !^www$ [NC]
  RewriteRule ^(.+) %{HTTP_HOST}$1  [C]
  RewriteRule ^([a-z0-9_\-]+)\.livejournal\.com(.+)  /users/$1$2  [L,PT,NS]

  RewriteCond %{HTTP_HOST} ^(www\.)?livejournal\.com$ [NC]
  RewriteRule ^/confirm/([a-z0-9]+\.[a-z0-9]+) http://www.livejournal.com/register.bml?$1 [L,R]

  # if they send any Host header with letters (an IP address or blank
  # is okay) then it has to be www.livejournal.com or livejournal.com
  # (optional port, too)
  RewriteCond %{HTTP_HOST} [a-z] [NC]
  RewriteCond %{HTTP_HOST} !^(www\.)?livejournal\.com(:[0-9]+)?$ [NC]
  RewriteRule . . [F]

END_CONF

    $new .= <<"END_CONF";

  AddType text/rdf rdf
  AddType text/plain TCL
  AddType application/x-httpd-cgi CGI

  Options +ExecCGI

  ServerName lj-$host->{'name'}.livejournal.com
  ServerAlias livejournal.com *.livejournal.com
  ServerAdmin webmaster\@livejournal.com
  DocumentRoot /home/lj/htdocs/
  ScriptAlias /cgi-bin/ /home/lj/cgi-bin/
  
  ErrorDocument 403 /403.html
END_CONF

  if ($host->{'paid_web_slave'}) {
    $new .= "  ErrorDocument 500 /500-paid.html\n";
  } else {
    $new .= "  ErrorDocument 500 /500.html\n";
  }

    $new .= <<"END_CONF";
  ErrorDocument 404 /cgi-bin/404notfound.cgi
# RedirectMatch 301 ^/users/?\$ http://www.livejournal.com/directory.bml

  AddType text/bml BML
  Action text/bml /cgi-bin/bmlp.pl
  AddType text/sbml SBML
  Action text/sbml /cgi-bin/sbmlp.pl
  DirectoryIndex index.html index.bml

  SetEnvIf Request_URI "^/img/" no-log
  SetEnvIf Request_URI "^/userpic/" no-log
  SetEnvIf Request_URI "^/status" no-log
  LogFormat "%h %l %u %t \\"%r\\" %s %b \\"%{Referer}i\\" \\"%{User-Agent}i\\" \\"%{Host}i\\"" ljlog
  ErrorLog "|/usr/local/apache/bin/rotatelogs /home/lj/logs/error-$host->{'name'} 3600"
  CustomLog "|/usr/local/apache/bin/rotatelogs /home/lj/logs/access-$host->{'name'} 3600" ljlog env=!no-log

  <Location /cgi-bin/404notfound.cgi>
    SetHandler fastcgi-script
  </Location>
  <Location /userpic>
    SetHandler fastcgi-script
  </Location>
  <Location /users>
    SetHandler fastcgi-script
  </Location>
  <Location /cgi-bin/log.cgi>
    ErrorDocument 500 /500-log.html
    SetHandler fastcgi-script
  </Location>
  <Location /cgi-bin/bmlp.pl>
    SetHandler fastcgi-script
  </Location>
  <Location /cgi-bin/sbmlp.pl>
    SetHandler fastcgi-script
  </Location>
  <Location /customview.cgi>
    SetHandler fastcgi-script
  </Location>
  <Directory /home/lj/htdocs/img>
    AllowOverride None
    Options None
    ExpiresActive on
    ExpiresByType image/gif "access plus 1 month"
    ExpiresByType image/jpeg "access plus 1 month"
  </Directory>

  <FilesMatch "~\$">
    Deny from all
  </FilesMatch>

  <Directory /home/lj/htdocs/inc/>
    Deny from all
  </Directory>

  <Directory /home/lj/htdocs/admin/brad/>
    AuthUserFile /home/lj/pass-gen.txt
    AuthName "Brad only area"
    AuthType Basic
    require user bradfitz
    Options +Indexes
  </Directory>

  <Directory /home/lj/htdocs/files/>
    Options -ExecCGI
  </Directory>

</VirtualHost>

# backup image server (load balancer will prefer thttpd/tux/etc first)
Listen $host->{'ipco'}:8081
NameVirtualHost $host->{'ipco'}:8081
<VirtualHost $host->{'ipco'}:8081>
   ServerName img.livejournal.com
   DocumentRoot /home/lj/htdocs/img
   DirectoryIndex index.html
   Options -ExecCGI
</VirtualHost>

# AccessFileName: The name of the file to look for in each directory
# for access control information.
#
AccessFileName .htaccess

<Files ~ "^\\.ht">
    Order allow,deny
    Deny from all
</Files>
<Files ~ "~\$">
    Order allow,deny
    Deny from all
</Files>
<Files ~ "\\.core\$">
    Order allow,deny
    Deny from all
</Files>

UseCanonicalName Off

<IfModule mod_mime.c>
    TypesConfig /usr/local/apache/conf/mime.types
</IfModule>

## MIME
DefaultType text/plain
<IfModule mod_mime_magic.c>
    MIMEMagicFile /usr/local/apache/conf/magic
</IfModule>

HostnameLookups Off

ErrorLog "|/usr/local/apache/bin/rotatelogs /usr/local/apache/logs/error_log 86400"
LogLevel error
CustomLog /dev/null common

ServerSignature On

<IfModule mod_alias.c>
    Alias /icons/ "/usr/local/apache/icons/"
    <Directory "/usr/local/apache/icons">
        Options Indexes
        AllowOverride None
        Order allow,deny
        Allow from all
    </Directory>
</IfModule>

<IfModule mod_autoindex.c>

    #
    # FancyIndexing is whether you want fancy directory indexing or standard
    #
    IndexOptions FancyIndexing SuppressDescription SuppressColumnSorting FoldersFirst NameWidth=*

    #
    # AddIcon* directives tell the server which icon to show for different
    # files or filename extensions.  These are only displayed for
    # FancyIndexed directories.
    #
    AddIconByEncoding (CMP,/icons/compressed.gif) x-compress x-gzip

    AddIconByType (TXT,/icons/text.gif) text/*
    AddIconByType (IMG,/icons/image2.gif) image/*
    AddIconByType (SND,/icons/sound2.gif) audio/*
    AddIconByType (VID,/icons/movie.gif) video/*

    AddIcon /icons/rpm.gif   .rpm
    AddIcon /icons/debian.gif   .deb
    AddIcon /icons/binary.gif .bin .exe
    AddIcon /icons/binhex.gif .hqx
    AddIcon /icons/tar.gif .tar
    AddIcon /icons/world2.gif .wrl .wrl.gz .vrml .vrm .iv
    AddIcon /icons/compressed.gif .Z .z .tgz .gz .zip
    AddIcon /icons/a.gif .ps .ai .eps
    AddIcon /icons/layout.gif .html .shtml .htm .pdf
    AddIcon /icons/text.gif .txt
    AddIcon /icons/c.gif .c
    AddIcon /icons/p.gif .pl .py
    AddIcon /icons/f.gif .for
    AddIcon /icons/dvi.gif .dvi
    AddIcon /icons/uuencoded.gif .uu
    AddIcon /icons/script.gif .conf .sh .shar .csh .ksh .tcl
    AddIcon /icons/tex.gif .tex
    AddIcon /icons/bomb.gif core

    AddIcon /icons/back.gif ..
    AddIcon /icons/hand.right.gif README
    AddIcon /icons/folder.gif ^^DIRECTORY^^
    AddIcon /icons/blank.gif ^^BLANKICON^^

    #
    # DefaultIcon is which icon to show for files which do not have an icon
    # explicitly set.
    #
    DefaultIcon /icons/unknown.gif
    ReadmeName README
    HeaderName HEADER
    IndexIgnore .??* *~ *# HEADER* RCS CVS *,v *,t
</IfModule>

<IfModule mod_mime.c>
    AddEncoding x-compress Z
    AddEncoding x-gzip gz tgz
    AddType application/x-httpd-php .php
    AddType application/x-httpd-php-source .phps
    AddType application/x-tar .tgz
</IfModule>

<IfModule mod_setenvif.c>
    BrowserMatch "Mozilla/2" nokeepalive
    BrowserMatch "MSIE 4\.0b2;" nokeepalive downgrade-1.0 force-response-1.0
    BrowserMatch "RealPlayer 4\.0" force-response-1.0
    BrowserMatch "Java/1\.0" force-response-1.0
    BrowserMatch "JDK/1\.0" force-response-1.0
</IfModule>

END_CONF

    write_file($file, $new);
}
