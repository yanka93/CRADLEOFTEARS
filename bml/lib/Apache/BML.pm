#!/usr/bin/perl
#

use strict;

package BML::Request;

use fields qw(
	      env blockref lang r blockflags BlockStack
	      file scratch IncludeOpen content_type clean_package package
	      filechanged scheme scheme_file IncludeStack etag location
	      most_recent_mod stop_flag want_last_modified cookies
	      );


package Apache::BML;

use Apache::Constants qw(:common REDIRECT HTTP_NOT_MODIFIED);
use Apache::File ();
use Apache::URI;
use Digest::MD5;
use File::Spec;
BEGIN {
    $Apache::BML::HAVE_ZLIB = eval "use Compress::Zlib (); 1;";
}

# set per request:
use vars qw($cur_req);
use vars qw(%CodeBlockOpts);
# scalar hashrefs of versions below, minus the domain part:
my ($SchemeData, $SchemeFlags); 

# keyed by domain:
my $ML_SCOPE;              # generally the $r->uri, auto set on each request (unless overridden)
my (%SchemeData, %SchemeFlags); # domain -> scheme -> key -> scalars (data has {s} blocks expanded)

# safely global:
use vars qw(%FileModTime %LookItems);  # LookItems: file -> template -> [ data, flags ]
use vars qw(%LookParent);  # file -> parent file
use vars qw(%LookChild);   # file -> child -> 1

my (%CodeBlockMade);

use vars qw($conf_pl $conf_pl_look);  # hashref, made empty before loading a .pl conf file
my %DenyConfig;      # filename -> 1
my %FileConfig;      # filename -> hashref
my %FileLastStat;    # filename -> time we last looked at its modtime

use vars qw($base_recent_mod); 

# the request we're handling (Apache->request).  using this way
# instead of just using Apache->request because when using
# Apache::FakeRequest and non-mod_perl env, I can't seem to get/set
# the value of Apache->request
use vars qw($r);

# regexps to match open and close tokens. (but old syntax (=..=) is deprecated)
my ($TokenOpen, $TokenClose) = ('<\?', '\?>');

tie %BML::ML, 'BML::ML';
tie %BML::COOKIE, 'BML::Cookie';

sub handler
{
    my $r = shift;
    my $file;

    $Apache::BML::r = $r;

    # determine what file we're supposed to work with:
    if (ref $r eq "Apache::FakeRequest") {
        # for testing.  FakeRequest's 'notes' method is busted, always returning
        # true. 
        $file = $r->filename;
        stat($file);
    } elsif ($file = $r->notes("bml_filename")) {
        # when another handler needs to invoke BML directly
        stat($file);
    } else {
        # normal case
        $file = $r->filename;
        $r->finfo;
    }

    unless (-e _) {
        $r->log_error("File does not exist: $file");
        return NOT_FOUND;
    }

    unless (-r _) {
        $r->log_error("File permissions deny access: $file");
        return FORBIDDEN;
    }

    my $modtime = (stat _)[9];

    return FORBIDDEN if $file =~ /\b_config/;

    # create new request
    my $req = $cur_req = fields::new('BML::Request');
    $req->{file} = $file;
    $req->{r}    = $r;
    $req->{BlockStack} = [""];
    $req->{scratch}    = {};  # _CODE blocks can play
    $req->{cookies} = {};

    # setup env
    my $env = $req->{env} = {};

    # walk up directories, looking for _config.bml files, populating env
    my $dir = $file;
    my $docroot = $r->document_root(); $docroot =~ s!/$!!;
    my @dirconfs;
    my %confwant;  # file -> 1, if applicable config

    while ($dir) {
        $dir =~ s!/[^/]*$!!;
        my $conffile = "$dir/_config.bml";
        $confwant{$conffile} = 1;
        push @dirconfs, load_conffile($conffile);
        last if $dir eq $docroot;
    }

    # we now have dirconfs in order from first to apply to last.
    # but a later one may have a subconfig to override, so 
    # go through those first, keeping track of which configs
    # are effective
    my %eff_config;

    foreach my $cfile (@dirconfs) {
        my $conf = $FileConfig{$cfile};
        next unless $conf;
        $eff_config{$cfile} = $conf;
        if ($conf->{'SubConfig'}) {
            foreach my $sconf (keys %confwant) {
                my $sc = $conf->{'SubConfig'}{$sconf};
                $eff_config{$cfile} = $sc if $sc;
            }
        }
    }

    foreach my $cfile (@dirconfs) {
        my $conf = $eff_config{$cfile};
        next unless $conf;
        while (my ($k,$v) = each %$conf) {
            next if exists $env->{$k} || $k eq "SubConfig";
            $env->{$k} = $v;
        }
    }

    # check if there are overrides in pnotes
    # wrapped in eval because Apache::FakeRequest doesn't have
    # pnotes support (as of 2004-04-26 at least)
    eval {
	if (my $or = $r->pnotes('BMLEnvOverride')) {
	    while (my ($k, $v) = each %$or) {
		$env->{$k} = $v;
	    }
	}
    };

    # environment loaded at this point

    if ($env->{'AllowOldSyntax'}) {
        ($TokenOpen, $TokenClose) = ('(?:<\?|\(=)', '(?:\?>|=\))');
    } else {
        ($TokenOpen, $TokenClose) = ('<\?', '\?>');
    }

    # Look for an alternate file, and if it exists, load it instead of the real
    # one.
    if ( exists $env->{TryAltExtension} ) {
        my $ext = $env->{TryAltExtension};

        # Trim a leading dot on the extension to allow '.lj' or 'lj'
        $ext =~ s{^\.}{};

        # If the file already has an extension, put the alt extension between it
        # and the rest of the filename like Apache's content-negotiation.
        if ( $file =~ m{(\.\S+)$} ) {
            my $newfile = $file;
            substr( $newfile, -(length $1), 0 ) = ".$ext";
            if ( -e $newfile ) {
                $modtime = (stat _)[9];
                $file = $newfile;
            }
        }

        elsif ( -e "$file.$ext" ) {
            $modtime = (stat _)[9];
            $file = "$file.$ext";
        }
    }

    # Read the source of the file
    unless (open F, $file) {
        $r->log_error("Couldn't open $file for reading: $!");
        $Apache::BML::r = undef;  # no longer valid
        return SERVER_ERROR;
    }

    my $bmlsource;
    { local $/ = undef; $bmlsource = <F>; }
    close F;

    # consider the file's mod time
    note_mod_time($req, $modtime);

    # and all the config files:
    note_mod_time($req, $Apache::BML::base_recent_mod);

    # if the file changed since we last looked at it, note that
    if (!defined $FileModTime{$file} || $modtime > $FileModTime{$file}) {
        $FileModTime{$file} = $modtime;
        $req->{'filechanged'} = 1;
    }

    # setup cookies
    *BMLCodeBlock::COOKIE = *BML::COOKIE;
    BML::reset_cookies();
    
    # tied interface to BML::ml();
    *BMLCodeBlock::ML = *BML::ML;

    # let BML code blocks see input
    %BMLCodeBlock::GET = ();
    %BMLCodeBlock::POST = ();
    %BMLCodeBlock::FORM = ();  # whatever request method is
    my %input_target = ( GET  => [ \%BMLCodeBlock::GET  ],
                         POST => [ \%BMLCodeBlock::POST ], );
    push @{$input_target{$r->method}}, \%BMLCodeBlock::FORM;
    foreach my $id ([ [ $r->args    ] => $input_target{'GET'}  ],
                    [ [ $r->content ] => $input_target{'POST'} ])
    {
        while (my ($k, $v) = splice @{$id->[0]}, 0, 2) {
            foreach my $dest (@{$id->[1]}) {
                $dest->{$k} .= "\0" if exists $dest->{$k};
                $dest->{$k} .= $v;
            }
        }
    }

    if ($env->{'HOOK-startup'}) {
        eval {
            $env->{'HOOK-startup'}->();
        };
        return report_error($r, "<b>Error running startup hook:</b><br />\n$@")
            if $@;
    }

    my $scheme = $r->notes('bml_use_scheme') ||
        $env->{'ForceScheme'} || 
        $BMLCodeBlock::GET{'usescheme'} || 
        $BML::COOKIE{'BMLschemepref'} || 
        $env->{'DefaultScheme'};
    unless (BML::set_scheme($scheme)) {
        $scheme = $env->{'ForceScheme'} ||
            $env->{'DefaultScheme'};
        BML::set_scheme($scheme);
    }

    my $uri = $r->uri;
    BML::set_language_scope($uri);
    my $lang = BML::decide_language();
    BML::set_language($lang);

    # print on the HTTP header
    my $html = $env->{'_error'};

    bml_decode($req, \$bmlsource, \$html, { DO_CODE => $env->{'AllowCode'} })
        unless $html;

    # force out any cookies we have set
    BML::send_cookies($req);

    $r->register_cleanup(\&reset_codeblock) if $req->{'clean_package'};

    # redirect, if set previously
    if ($req->{'location'}) {
        $r->header_out(Location => $req->{'location'});
        $Apache::BML::r = undef;  # no longer valid
        return REDIRECT;
    }

    # see if we can save some bandwidth (though we already killed a bunch of CPU)
    my $etag;
    if (exists $req->{'etag'}) {
        $etag = $req->{'etag'} if defined $req->{'etag'};
    } else {
        $etag = Digest::MD5::md5_hex($html);
    }
    $etag = '"' . $etag . '"' if defined $etag;

    my $ifnonematch = $r->header_in("If-None-Match");
    if (defined $ifnonematch && defined $etag && $etag eq $ifnonematch) {
        $Apache::BML::r = undef;  # no longer valid
        return HTTP_NOT_MODIFIED;
    }

    my $rootlang = substr($req->{'lang'}, 0, 2);
    unless ($env->{'NoHeaders'}) {
        eval {
            # this will fail while using Apache::FakeRequest, but that's okay.
            $r->content_languages([ $rootlang ]);
        };
    }

    my $modtime_http = modified_time($req);

    my $content_type = $req->{'content_type'} ||
        $env->{'DefaultContentType'} ||
        "text/html";

    unless ($env->{'NoHeaders'}) 
    {
        my $ims = $r->header_in("If-Modified-Since");
        if ($ims && ! $env->{'NoCache'} &&
            $ims eq $modtime_http) 
        {
            $Apache::BML::r = undef;  # no longer valid
            return HTTP_NOT_MODIFIED;
        }

        $r->content_type($content_type);

        if ($env->{'NoCache'}) {        
            $r->header_out("Cache-Control", "no-cache");
            $r->no_cache(1);
        }

        $r->header_out("Last-Modified", $modtime_http)
            if $env->{'Static'} || $req->{'want_last_modified'};

        $r->header_out("Cache-Control", "private, proxy-revalidate");
        $r->header_out("ETag", $etag) if defined $etag;

        # gzip encoding
        my $do_gzip = $env->{'DoGZIP'} && $Apache::BML::HAVE_ZLIB;
        $do_gzip = 0 if $do_gzip && $content_type !~ m!^text/html!;
        $do_gzip = 0 if $do_gzip && $r->header_in("Accept-Encoding") !~ /gzip/;
        my $length = length($html);
        $do_gzip = 0 if $length < 500;
        if ($do_gzip) {
            my $pre_len = $length;
            $r->notes("bytes_pregzip" => $pre_len);
            $html = Compress::Zlib::memGzip($html);
            $length = length($html);
            $r->header_out('Content-Encoding', 'gzip');
            $r->header_out('Vary', 'Accept-Encoding');
        }
        $r->header_out('Content-length', $length);
	
        $r->send_http_header();
    }

    $r->print($html) unless $env->{'NoContent'} || $r->header_only;

    $Apache::BML::r = undef;  # no longer valid
    return OK;
}

sub report_error
{
    my $r = shift;
    my $err = shift;
    
    $r->content_type("text/html");
    $r->send_http_header();
    $r->print($err);

    return OK;  # TODO: something else?
}

sub file_dontcheck
{
    my $file = shift;
    my $now = time;
    return 1 if $FileLastStat{$file} > $now - 10;
    my $realmod = (stat($file))[9];
    $FileLastStat{$file} = $now;
    return 1 if $FileModTime{$file} && $realmod == $FileModTime{$file};
    $FileModTime{$file} = $realmod;
    return 1 if ! $realmod;
    return 0;
}

sub load_conffile
{
    my ($ffile) = @_;  # abs file to load
    die "can't have dollar signs in filenames" if index($ffile, '$') != -1;
    die "not absolute path" unless File::Spec->file_name_is_absolute($ffile);
    my ($volume,$dirs,$file) = File::Spec->splitpath($ffile);

    # see which configs are denied
    my $r = $Apache::BML::r;
    if ($r->dir_config("BML_denyconfig") && ! %DenyConfig) {
        my $docroot = $r->document_root();
        my $deny = $r->dir_config("BML_denyconfig");
        $deny =~ s/^\s+//; $deny =~ s/\s+$//;
        my @denydir = split(/\s*\,\s*/, $deny);
        foreach $deny (@denydir) {
            $deny = dir_rel2abs($docroot, $deny);
            $deny =~ s!/$!!;
            $DenyConfig{"$deny/_config.bml"} = 1;
        }
    }

    return () if $DenyConfig{$ffile};

    my $conf;
    if (file_dontcheck($ffile) && ($FileConfig{$ffile} || ! $FileModTime{$ffile})) {
        return () unless $FileModTime{$ffile};  # file doesn't exist
        $conf = $FileConfig{$ffile};
    }

    if (!$conf && $file =~ /\.pl$/) {
        return () unless -e $ffile;
        my $conf = $conf_pl = {};
        do $ffile;
        undef $conf_pl;
        $FileConfig{$ffile} = $conf;
        return ($ffile);
    }

    unless ($conf) {
        unless (open (C, $ffile)) {
            Apache->log_error("Can't read config file: $file")
                if -e $file;
            return ();
        }

        my $curr_sub;
        $conf = {};
        my $sconf = $conf;

        my $save_config = sub {
            return unless %$sconf;
            
            # expand $env vars and make paths absolute
            foreach my $k (qw(LookRoot IncludePath)) {
                next unless exists $sconf->{$k};
                $sconf->{$k} =~ s/\$(\w+)/$ENV{$1}/g;
                $sconf->{$k} = dir_rel2abs($dirs, $sconf->{$k});
            }
            
            # same as above, but these can be multi-valued, and go into an arrayref
            foreach my $k (qw(ExtraConfig)) {
                next unless exists $sconf->{$k};
                $sconf->{$k} =~ s/\$(\w+)/$1 eq "HTTP_HOST" ? clean_http_host() : $ENV{$1}/eg;
                $sconf->{$k} = [ map { dir_rel2abs($dirs, $_) } grep { $_ }
                                 split(/\s*,\s*/, $sconf->{$k}) ];
            }
            
            # if child config, copy it to parent config
            return unless $curr_sub;
            foreach my $subdir (split(/\s*,\s*/, $curr_sub)) {
                my $subfile = dir_rel2abs($dirs, "$subdir/_config.bml");
                $conf->{'SubConfig'}->{$subfile} = $sconf;
            }
        };

        
        while (<C>) {
            chomp;
            s/\#.*//;
            next unless /(\S+)\s+(.+?)\s*$/;
            my ($k, $v) = ($1, $2);
            if ($k eq "SubConfig:") {
                $save_config->();
                $curr_sub = $v;
                $sconf = {%$sconf};  # clone config seen so far.  SubConfig inherits those.
                next;
            }

            # automatically arrayref-ify certain options
            $v = [ split(/\s*,\s*/, $v) ]
                if $k eq "CookieDomain" && index($v,',') != -1;

            $sconf->{$k} = $v;
        }
        close C;
        $save_config->();
        $FileConfig{$ffile} = $conf;
    }

    my @files = ($ffile);
    foreach my $cfile (@{$conf->{'ExtraConfig'} || []}) {
        unshift @files, load_conffile($cfile);
    }

    return @files;
}

sub compile
{
    eval $_[0];
}

sub reset_codeblock
{
    my BML::Request $req = $Apache::BML::cur_req;
    my $to_clean = $req->{clean_package};

    no strict;
    local $^W = 0;
    my $package = "main::${to_clean}::";
    *stab = *{"main::"};
    while ($package =~ /(\w+?::)/g)
    {
        *stab = ${stab}{$1};
    }
    while (my ($key,$val) = each(%stab))
    {
        return if $DB::signal;
        deleteglob ($key, $val);
    }
}

sub deleteglob
{
    no strict;
    return if $DB::signal;
    my ($key, $val, $all) = @_;
    local(*entry) = $val;
    my $fileno;
    if ($key !~ /^_</ and defined $entry)
    {
        undef $entry;
    }
    if ($key !~ /^_</ and defined @entry)
    {
        undef @entry;
    }
    if ($key ne "main::" && $key ne "DB::" && defined %entry
        && $key !~ /::$/
        && $key !~ /^_</ && $val ne "*BML::COOKIE")
    {
        undef %entry;
    }
    if (defined ($fileno = fileno(*entry))) {
        # do nothing to filehandles?
    }
    if ($all) {
        if (defined &entry) {
                # do nothing to subs?
        }
    }
}

# $type - "THINGER" in the case of <?thinger Whatever thinger?>
# $data - "Whatever" in the case of <?thinger Whatever thinger?>
# $option_ref - hash ref to %BMLEnv
sub bml_block
{
    my BML::Request $req = shift;
    my ($type, $data, $option_ref, $elhash) = @_;
    my $realtype = $type;
    my $previous_block = $req->{'BlockStack'}->[-1];
    my $env = $req->{'env'};

    # Bail out if we're over 200 frames deep
    # :TODO: Make the max depth configurable?
    if ( @{$req->{BlockStack}} > 200 ) {
        my $stackSlice = join " -> ", @{$req->{BlockStack}}[0..10];
        return "<b>[Error: Too deep recursion: $stackSlice]</b>";
    }

    if (exists $req->{'blockref'}->{"$type/FOLLOW_${previous_block}"}) {
        $realtype = "$type/FOLLOW_${previous_block}";
    }

    my $blockflags = $req->{'blockflags'}->{$realtype};

    # executable perl code blocks
    if ($type eq "_CODE")
    {
        return inline_error("_CODE block failed to execute by permission settings")
            unless $option_ref->{'DO_CODE'};

        %CodeBlockOpts = ();
 
	# this will be their package
	my $md5_package = "BMLCodeBlock::" . Digest::MD5::md5_hex($req->{'file'});

	# this will be their handler name
	my $md5_handler = "handler_" . Digest::MD5::md5_hex($data);
	
	# we cache code blocks (of templates) also in each *.bml file's
	# package, since we're too lazy (at the moment) to trace back
	# each code block to its declaration file.
	my $unique_key = $md5_package . $md5_handler;
	
	my $need_compile = ! $CodeBlockMade{$unique_key};

        if ($need_compile) {
	    # compile (which just calls eval) then check for errors.
	    # we put it off to that sub, historically, to make it
	    # show up separate in profiling, but now we cache
	    # everything, so it pretty much never shows up.
            compile(join('',
			 'package ',
			 $md5_package,
			 ';',
			 "no strict;",
			 'use vars qw(%ML %COOKIE %POST %GET %FORM);',
                         "*ML = *BML::ML;",
                         "*COOKIE = *BML::COOKIE;",
                         "*GET = *BMLCodeBlock::GET;",
                         "*POST = *BMLCodeBlock::POST;",
                         "*FORM = *BMLCodeBlock::FORM;",
                         'sub ', $md5_handler, ' {',
			 $data,
			 "\n}"));
            return "<b>[Error: $@]</b>" if $@;

            $CodeBlockMade{$unique_key} = 1;
        }
        
        my $cv = \&{"${md5_package}::${md5_handler}"};
	$req->{clean_package} = $md5_package;
        my $ret = eval { $cv->($req, $req->{'scratch'}, $elhash || {}) };
        if ($@) {
            my $msg = $@;
            if ($env->{'HOOK-codeerror'}) {
                $ret = eval {
                    $env->{'HOOK-codeerror'}->($msg);
                };
                return "<b>[Error running codeerror hook]</b>" if $@;
            } else {
                return "<b>[Error: $msg]</b>"; 
            }
        }

        # don't call bml_decode if BML::noparse() told us not to, there's
	# no data, or it looks like there are no BML tags
        return $ret if $CodeBlockOpts{'raw'} or $ret eq "" or
	    (index($ret, "<?") == -1 && index($ret, "(=") == -1);

        my $newhtml;
        bml_decode($req, \$ret, \$newhtml, {});  # no opts on purpose: _CODE can't return _CODE
        return $newhtml;
    }

    # trim off space from both sides of text data
    $data =~ s/^\s*(.*?)\s*$/$1/s;

    # load in the properties defined in the data
    my %element = ();
    my @elements = ();
    if (index($blockflags, 'F') != -1)
    {
        load_elements(\%element, $data, { 'declorder' => \@elements });
    } 
    elsif (index($blockflags, 'P') != -1)
    {
        my @itm = split(/\s*\|\s*/, $data);
        my $ct = 0;
        foreach (@itm) {
            $ct++;
            $element{"DATA$ct"} = $_;
            push @elements, "DATA$ct";
        }
    }
    else
    {
        # single argument block (goes into DATA element)
        $element{'DATA'} = $data;
        push @elements, 'DATA';
    }

    # check built-in block types (those beginning with an underscore)
    if (rindex($type, '_', 0) == 0) {

        # multi-linguality stuff
        if ($type eq "_ML")
        {
            my $code = $data;
            return $code 
                if $req->{'lang'} eq 'debug';   
            my $getter = $req->{'env'}->{'HOOK-ml_getter'};
            return "[ml_getter not defined]" unless $getter;
            $code = $req->{'r'}->uri . $code
                if rindex($code, '.', 0) == 0;
            return $getter->($req->{'lang'}, $code);
        }

        # an _INFO block contains special internal information, like which
        # look files to include
        if ($type eq "_INFO")
        {
            if ($element{'PACKAGE'}) { $req->{'package'} = $element{'PACKAGE'}; }
            if ($element{'NOCACHE'}) { $req->{'env'}->{'NoCache'} = 1; }
            if ($element{'STATIC'}) { $req->{'env'}->{'Static'} = 1; }
            if ($element{'NOHEADERS'}) { $req->{'env'}->{'NoHeaders'} = 1; }
            if ($element{'NOCONTENT'}) { $req->{'env'}->{'NoContent'} = 1; }
            if ($element{'LOCALBLOCKS'} && $req->{'env'}->{'AllowCode'}) {
                my (%localblock, %localflags);
                load_elements(\%localblock, $element{'LOCALBLOCKS'});
                # look for template types
                foreach my $k (keys %localblock) {
                    if ($localblock{$k} =~ s/^\{([A-Za-z]+)\}//) {
                        $localflags{$k} = $1;
                    }
                }
                my @expandconstants;
                foreach my $k (keys %localblock) {
                    $req->{'blockref'}->{$k} = \$localblock{$k};
                    $req->{'blockflags'}->{$k} = $localflags{$k};
                    if (index($localflags{$k}, 's') != -1) { push @expandconstants, $k; }
                }
                foreach my $k (@expandconstants) {
                    $localblock{$k} =~ s/$TokenOpen([a-zA-Z0-9\_]+?)$TokenClose/${$req->{'blockref'}->{uc($1)} || \""}/og;
                }
            }
            return "";
        }
        
        if ($type eq "_INCLUDE") 
        {
            my $code = 0;
            $code = 1 if ($element{'CODE'});
            foreach my $sec (qw(CODE BML)) {
                next unless $element{$sec};
                if ($req->{'IncludeStack'} && ! $req->{'IncludeStack'}->[-1]->{$sec}) {
                    return inline_error("Sub-include can't turn on $sec if parent include's $sec was off");
                }
            }
            unless ($element{'FILE'} =~ /^[a-zA-Z0-9-_\.]{1,255}$/) {
                return inline_error("Invalid characters in include file name: $element{'FILE'} (code=$code)");
            }

            if ($req->{'IncludeOpen'}->{$element{'FILE'}}++) {
                return inline_error("Recursion detected in includes");
            }
            push @{$req->{'IncludeStack'}}, \%element;
            my $isource = "";
            my $file = $element{'FILE'};

            # first check if we have a DB-edit hook
            my $hook = $req->{'env'}->{'HOOK-include_getter'};
            unless ($hook && $hook->($file, \$isource)) {
                $file = $req->{'env'}->{'IncludePath'} . "/" . $file;
                open (INCFILE, $file) || return inline_error("Could not open include file.");
                { local $/ = undef; $isource = <INCFILE>; }
                close INCFILE;
            }
            
            if ($element{'BML'}) {
                my $newhtml;
                bml_decode($req, \$isource, \$newhtml, { DO_CODE => $code });
                $isource = $newhtml;
            } 
            $req->{'IncludeOpen'}->{$element{'FILE'}}--;
            pop @{$req->{'IncludeStack'}};
            return $isource;
        }
        
        if ($type eq "_COMMENT" || $type eq "_C") {
            return "";
        }

        if ($type eq "_EH") {
            return BML::ehtml($element{'DATA'});
        }
        
        if ($type eq "_EB") {
            return BML::ebml($element{'DATA'});
        }
        
        if ($type eq "_EU") {
            return BML::eurl($element{'DATA'});
        }
        
        if ($type eq "_EA") {
            return BML::eall($element{'DATA'});
        }
        
        return inline_error("Unknown core element '$type'");
    }
        
    $req->{'BlockStack'}->[-1] = $type;
        
    # traditional BML Block decoding ... properties of data get inserted
    # into the look definition; then get BMLitized again
    return inline_error("Undefined custom element '$type'")
        unless defined $req->{'blockref'}->{$realtype};

    my $preparsed = (index($blockflags, 'p') != -1);

    if ($preparsed) {
        ## does block request pre-parsing of elements?
        ## this is required for blocks with _CODE and AllowCode set to 0
        foreach my $k (@elements) {
            my $decoded;
            bml_decode($req, \$element{$k}, \$decoded, $option_ref, \%element);
            $element{$k} = $decoded;
        }
    }
    
    # template has no variables or BML tags:
    return ${$req->{'blockref'}->{$realtype}} if index($blockflags, 'S') != -1;

    my $expanded;
    if ($preparsed) {
        $expanded = ${$req->{'blockref'}->{$realtype}};
    } else {
        $expanded = parsein(${$req->{'blockref'}->{$realtype}}, \%element);
    }

    # {R} flag wants variable interpolation, but no expansion:
    unless (index($blockflags, 'R') != -1)
    {    
        my $out;
        push @{$req->{'BlockStack'}}, "";
        my $opts = { %{$option_ref} };
        if ($preparsed) {
            $opts->{'DO_CODE'} = $req->{'env'}->{'AllowTemplateCode'};
        }
	
	unless (index($expanded, "<?") == -1 && index($expanded, "(=") == -1) {
	    bml_decode($req, \$expanded, \$out, $opts, \%element);
	    $expanded = $out;
	}

        pop @{$req->{'BlockStack'}};
    }

    $expanded = parsein($expanded, \%element) if $preparsed;
    return $expanded;    
}

######## bml_decode
#
# turns BML source into expanded HTML source
#
#   $inref    scalar reference to BML source.  $$inref gets destroyed.
#   $outref   scalar reference to where output is appended.
#   $opts     security flags
#   $elhash   optional elements hashref

use vars qw(%re_decode);
sub bml_decode
{
    my BML::Request $req = shift;
    my ($inref, $outref, $opts, $elhash) = @_;

    my $block = undef;    # what <?block ... block?> are we in?
    my $data = undef;     # what is inside the current block?
    my $depth = 0;     # how many blocks we are deep of the *SAME* type.
    my $re;            # active regular expression for finding closing tag

    pos($$inref) = 0;

  EAT:
    for (;;)
    {
        # currently not in a BML tag... looking for one!
        if (! defined $block) {
            if ($$inref =~ m/
                 \G                             # start where last match left off
                (?>                             # independent regexp:  won't backtrack the .*? below.
                 (.*?)                          # $1 -> optional non-BML stuff before opening tag
                 $TokenOpen           
                 (\w+)                          # $2 -> tag name
                 )
                (?:                             # CASE A: could be 1) immediate tag close, 2) tag close 
                                                #         with data, or 3) slow path, below
                 ($TokenClose) |                # A.1: $3 -> immediate tag close (depth 0)
                 (?:                            # A.2: simple close with data (data has no BML start tag of same tag)
                    ((?:.(?!$TokenOpen\2\b))+?) # $4 -> one or more chars without following opening BML tags
                   \b\2$TokenClose              # matching closing tag
                 ) |
                                                # A.3: final case:  nothing, it's not the fast path.  handle below.
                 )                              # end case A
                /gcosx) 
            {
                $$outref .= $1;
                $block = uc($2);
                $data = $4 || "";

                # fast path:  immediate close or simple data (no opening BML).
                if (defined $4 || $3) {
                    $$outref .= bml_block($req, $block, $data, $opts, $elhash);
                    return if $req->{'stop_flag'};
                    $data = undef;
                    $block = undef;
                    next EAT;
                }

                # slower (nesting) path.
                # fast path (above)  <?foo ...... foo?>
                # fast:              <?foo ... <?bar?> ... foo?>
                # slow (this path):  <?foo ... <?foo?> ... foo?>

                $depth = 1;

                # prepare/find a cached regexp to continue using below
                # continues below, finding an opening/close of existing tag
                $re = $re_decode{$block} ||=
                    qr/($TokenClose) |              # $1 -> immediate token closing
                          (?:
                           (.+?)                    # $2 -> non-BML part to push onto $data
                           (?:
                            ($TokenOpen$block\b) |  # $3 -> increasing depth
                            (\b$block$TokenClose)   # $4 -> decreasing depth
                            )
                           )/isx;

                # falls through below.

            } else {
                # no BML left? append it all and be done.
                $$outref .= substr($$inref, pos($$inref));
                return;
            }
        }

        # continue with slow path.

        # the regexp prepared above looks out for these cases:  (but not in
        # this order)
        #
        #  * Increasing depth:
        #     - some text, then another opening <?foo, increading our depth
        #       (this will always happen somewhere, as this is what defines a slow path)
        #         <?foo bla blah <?foo
        #  * Decreasing depth: (if depth==0, then we're done)
        #     - immediately closing the tag, empty tag
        #         <?foo?>
        #     - closing the tag (if depth == 0, then we're done)
        #         <?foo blah blah foo?>

        if ($$inref =~ m/\G$re/gc) {
            if ($1) { 
                # immediate close
                $depth--;
                $data .= $1 if $depth;  # add closing token if we're still in another tag
            } elsif ($3) { 
                # increasing depth of same block
                $data .= $2;            # data before opening bml tag
                $data .= $3;            # the opening tag itself
                $depth++;
            } elsif ($4) {
                # decreasing depth of same block
                $data .= $2;            # data before closing tag
                $depth--;
                $data .= $4 if $depth;  # add closing tag itself, if we're still in another tag
            }
        } else {
            $$outref .= inline_error("BML block '$block' has no close");
            return;
        }

        # handle finished blocks
        if ($depth == 0) {
            $$outref .= bml_block($req, $block, $data, $opts, $elhash);
            return if $req->{'stop_flag'};
            $data = undef;
            $block = undef;
        }
    }
}

# takes a scalar with %%FIELDS%% mixed in and replaces
# them with their correct values from an anonymous hash, given
# by the second argument to this call
sub parsein
{
    my ($data, $hashref) = @_;
    $data =~ s/%%(\w+)%%/$hashref->{uc($1)}/eg;
    return $data;
}

sub inline_error
{
    return "[Error: <b>@_</b>]";
}

# returns lower-cased, trimmed string
sub trim
{
    my $a = $_[0];
    $a =~ s/^\s*(.*?)\s*$/$1/s;
    return $a;
}

sub load_look_perl
{
    my ($file) = @_;

    $conf_pl_look = {};
    eval { do $file; };
    if ($@) {
        print STDERR "Error evaluating BML block conf file $file: $@\n";
        return 0;
    }
    $LookItems{$file} = $conf_pl_look;
    undef $conf_pl_look;

    return 1;
}

sub load_look
{
    my $file = shift;
    my BML::Request $req = shift;  # optional

    my $dontcheck = file_dontcheck($file);
    if ($dontcheck) {
        return 0 unless $FileModTime{$file};
        note_mod_time($req, $FileModTime{$file}) if $req;
        return 1;
    }
    note_mod_time($req, $FileModTime{$file}) if $req;

    if ($file =~ /\.pl$/) {
        return load_look_perl($file);
    }

    my $target = $LookItems{$file} = {};

    foreach my $look ($file, keys %{$LookChild{$file}||{}}) {
        delete $SchemeData->{$look};
        delete $SchemeFlags->{$look};
    }

    open (LOOK, $file);
    my $look_file;
    { local $/ = undef; $look_file = <LOOK>; }
    close LOOK;
    load_elements($target, $look_file);
    
    # look for template types
    while (my ($k, $v) = each %$target) {
        if ($v =~ s/^\{([A-Za-z]+)\}//) {
            $v = [ $v, $1 ];
        } else {
            $v = [ $v ];
        }
        $target->{$k} = $v;
    }

    $LookParent{$file} = undef;
    if ($target->{'_PARENT'}) {
        my $parfile = file_rel2abs($file, $target->{'_PARENT'}->[0]);
        if ($parfile && load_look($parfile)) {
            $LookParent{$file} = $parfile;
            $LookChild{$parfile}->{$file} = 1;
        }
    }
    
    return 1;
}

# given a block of data, loads elements found into 
sub load_elements
{
    my ($hashref, $data, $opts) = @_;
    my $ol = $opts->{'declorder'};

    my @lines = split(/\r?\n/, $data);

    while (@lines) {
        my $line = shift @lines;

        # single line declaration:
        # key=>value
        if ($line =~ /^\s*(\w[\w\/]*)=>(.*)/) {
            $hashref->{uc($1)} = $2;
            push @$ol, uc($1);
            next;
        }

        # multi-line declaration:
        # key<=
        # line1
        # line2
        # <=key
        if ($line =~ /^\s*(\w[\w\/]*)<=\s*$/) {
            my $block = uc($1);
            my $endblock = qr/^\s*<=$1\s*$/;
            my $newblock = qr/^\s*$1<=\s*$/;
            my $depth = 1;
            my @out;
            while (@lines) {
                $line = shift @lines;
                if ($line =~ /$newblock/) {
                    $depth++;
                    next;
                } elsif ($line =~ /$endblock/) {
                    $depth--;
                    last unless $depth;
                }
                push @out, $line;
            }
            if ($depth == 0) {
                $hashref->{$block} = join("\n", @out) . "\n";
                push @$ol, $block;
            }
        }

    } # end while (@lines)
}

# given a file, checks it's modification time and sees if it's
# newer than anything else that compiles into what is the document
sub note_file_mod_time
{
    my ($req, $file) = @_;
    note_mod_time($req, (stat($file))[9]);
}

sub note_mod_time
{
    my BML::Request $req = shift;
    my $mod_time = shift;

    if ($req) {
        if ($mod_time > $req->{'most_recent_mod'}) { 
            $req->{'most_recent_mod'} = $mod_time; 
        }
    } else {
        if ($mod_time > $Apache::BML::base_recent_mod) {
            $Apache::BML::base_recent_mod = $mod_time;
        }
    }
}

# formatting
sub modified_time
{
    my BML::Request $req = shift;
    my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = gmtime($req->{'most_recent_mod'});
    my @day = qw{Sun Mon Tue Wed Thu Fri Sat};
    my @month = qw{Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec};
    
    if ($year < 1900) { $year += 1900; }
    
    return sprintf("$day[$wday], %02d $month[$mon] $year %02d:%02d:%02d GMT",
                   $mday, $hour, $min, $sec);
}

# both Cwd and File::Spec suck.  they're portable, but they suck.
# these suck too (slow), but they do what i want.

sub dir_rel2abs {
    my ($dir, $rel) = @_;
    return $rel if $rel =~ m!^/!;
    my @dir = grep { $_ ne "" } split(m!/!, $dir);
    my @rel = grep { $_ ne "" } split(m!/!, $rel);
    while (@rel) {
        $_ = shift @rel;
        next if $_ eq ".";
        if ($_ eq "..") { pop @dir; next; }
        push @dir, $_;
    }
    return join('/', '', @dir);
}

sub file_rel2abs {
    my ($file, $rel) = @_;
    return $rel if $rel =~ m!^/!;
    $file =~ s!(.+/).*!$1!;
    return dir_rel2abs($file, $rel);
}

package BML;

# returns false if remote browser can't handle the HttpOnly cookie atttribute
# (Microsoft extension to make cookies unavailable to scripts)
# it renders cookies useless on some browsers.  by default, returns true.
sub http_only
{
    my $ua = BML::get_client_header("User-Agent");
    return 0 if $ua =~ /MSIE.+Mac_/;
    return 1;
}

sub fill_template
{
    my ($name, $vars) = @_;
    return Apache::BML::parsein(${$Apache::BML::cur_req->{'blockref'}->{uc($name)}},
                                $vars);
}

sub get_scheme
{
    return $Apache::BML::cur_req->{'scheme'};
}

sub set_scheme
{
    my BML::Request $req = $Apache::BML::cur_req;
    my $scheme = shift;
    return 0 if $scheme =~ /\W/;
    unless ($scheme) {
        $scheme = $req->{'env'}->{'ForceScheme'} || 
            $req->{'env'}->{'DefaultScheme'};
    }

    my $file = "$req->{env}{LookRoot}/$scheme.look";

    return 0 unless Apache::BML::load_look($file);

    $req->{'scheme'} = $scheme;
    $req->{'scheme_file'} = $file;
            
    # now we have to combine both of these (along with the VARINIT)
    # and then expand all the static stuff
    unless (exists $SchemeData->{$file}) {
        my $iter = $file;
        my @files;
        while ($iter) {
            unshift @files, $iter;
            $iter = $Apache::BML::LookParent{$iter};
        }

        my $sd = $SchemeData->{$file} = {};
        my $sf = $SchemeFlags->{$file} = {};

        foreach my $file (@files) {
            while (my ($k, $v) = each %{$Apache::BML::LookItems{$file}}) {
                $sd->{$k} = $v->[0];
                $sf->{$k} = $v->[1];
            }
        }
        foreach my $k (keys %$sd) {
            next unless index($sf->{$k}, 's') != -1;
            $sd->{$k} =~ s/$TokenOpen([a-zA-Z0-9\_]+?)$TokenClose/$sd->{uc($1)}/og;
        }
    }

    # now, this request needs a copy of (well, references to) the
    # data above.  can't use that directly, since it might
    # change using _INFO LOCALBLOCKS to declare new file-local blocks
    $req->{'blockflags'} = {
        '_INFO' => 'F', '_INCLUDE' => 'F',
    };
    $req->{'blockref'} = {};
    foreach my $k (keys %{$SchemeData->{$file}}) {
        $req->{'blockflags'}->{$k} = $SchemeFlags->{$file}->{$k};
        $req->{'blockref'}->{$k} = \$SchemeData->{$file}->{$k};
    }

    return 1;
}

sub set_etag
{
    my $etag = shift;
    $Apache::BML::cur_req->{'etag'} = $etag;
}

# when CODE blocks need to look-up static values and such
sub get_template_def
{
    my $blockname = shift;
    my $schemefile = $Apache::BML::cur_req->{'scheme_file'};
    return $SchemeData->{$schemefile}->{uc($blockname)};
}

sub parse_multipart
{
    my ($dest, $error, $max_size) = @_;
    my $r = $Apache::BML::r;
    my $err = sub { $$error = $_[0]; return 0; };

    my $size = $r->header_in("Content-length");
    unless ($size) {
        return $err->("No content-length header: can't parse");
    }
    if ($max_size && $size > $max_size) {
        return $err->("[toolarge] Upload too large");
    }
    
    my $sep;
    unless ($r->header_in("Content-Type") =~ m!^multipart/form-data;\s*boundary=(\S+)!) {
        return $err->("[unknowntype] Unknown content type");
    }
    $sep = $1;

    my $content;
    $r->read($content, $size);
    my @lines = split(/\r\n/, $content);
    my $line = shift @lines;
    return $err->("[parse] Error parsing upload") unless $line eq "--$sep";

    while (@lines) {
        $line = shift @lines;
        my %h;
        while (defined $line && $line ne "") {
            $line =~ /^(\S+?):\s*(.+)/;
            $h{lc($1)} = $2;
            $line = shift @lines;
        }
        while (defined $line && $line ne "--$sep") {
            last if $line eq "--$sep--";
            $h{'body'} .= "\r\n" if $h{'body'};
            $h{'body'} .= $line;
            $line = shift @lines;
        }
        if ($h{'content-disposition'} =~ /name="(\S+?)"/) {
            my $name = $1 || $2;
            $dest->{$name} = $h{'body'};
        }
    }

    return 1;
}

# FIXME: document the hooks
sub parse_multipart_interactive {
    my ($r, $errref, $hooks) = @_;

    # subref to set $@ and $$errref, then return false
    my $err = sub { $$errref = $@ = $_[0], return 0 };

    my $run_hook = sub {
        my $name = shift;
        my $ret = eval { $hooks->{$name}->(@_) };
        if ($@) {
            return $err->($@);
        }
        unless ($ret) {
            return $err->("Hook: '$name' returned false");
        }
        return 1;
    };

    # size hook is optional
    my $size = $r->header_in("Content-length");
    if ($hooks->{size}) {
        $run_hook->('size', $size)
            or return 0;
    }

    unless ($r->header_in("Content-Type") =~ m!^multipart/form-data;\s*boundary=(\S+)!) {
        return $err->("No MIME boundary.  Bogus Content-type? " . $r->header_in("Content-Type"));
    }
    my $sep = "--$1";
    my $seplen = length($sep) + 2;  # plus \r\n

    my $window = '';
    my $to_read = $size;
    my $max_read = 8192;

    my $seen_chunk = 0;  # have we seen any chunk yet?

    my $state = 0;  # what we last parsed
    # 0 = nothing  (looking for a separator)
    # 1 = separator (looking for headers)
    # 0 = headers   (looking for data)
    # 0 = data      (looking for a separator)

    while (1) {
        my $read = -1;
        if ($to_read) {
            $read = $r->read($window, 
                             $to_read < $max_read ? $to_read : $max_read,
                             length($window));
            $to_read -= $read;

	    # prevent loops.  Opera, in particular, alerted us to
	    # this bug, since it doesn't upload proper MIME on
	    # reload and its Content-Length header is correct,
	    # but its body tiny
            if ($read == 0) {
                return $err->("No data from client.  Possibly a refresh?");
            }
        }
        
        # starting case, or data-reading case (looking for separator)
        if ($state == 0) {
            my $idx = index($window, $sep);

            # didn't find a separator.  emit the previous data
            # which we know for sure is data and not a possible
            # new separator
            if ($idx == -1) {
                # bogus if we're done reading and didn't find what we're
                # looking for:
                if ($read == -1) {
                    return $err->("Couldn't find separator, no more data to read");
                }

                if ($seen_chunk) {

                    # data hook is required
                    my $len = length($window) - $seplen;
                    $run_hook->('data', $len, substr($window, 0, $len, ''))
                        or return 0;
                }
                next;
            }

            # we found a separator.  emit the previous read's
            # data and enddata.
            if ($seen_chunk) {
                my $len = $idx - 2;
                if ($len > 0) {

                    # data hook is required
                    $run_hook->('data', $len, substr($window, 0, $len))
                        or return 0;
                }
                
                # enddata hook is required
                substr($window, 0, $idx, '');
                $run_hook->('enddata')
                    or return 0;
            }

            # we're now looking for a header
            $seen_chunk = 1;
            $state = 1;

            # have we hit the end?
            return 1 if $to_read <= 2 && length($window) <= $seplen + 4; 
        }

        # read a separator, looking for headers
        if ($state == 1) {
            my $idx = index($window, "\r\n\r\n");
            if ($idx == -1) {
                if (length($window) > 8192) {
                    return $err->("Window too large: " . length($window) . " bytes > 8192");
                }

                # bogus if we're done reading and didn't find what we're
                # looking for:
                if ($read == -1) {
                    return $err->("Couldn't find headers, no more data to read");
                }

                next;
            }

            # +4 is \r\n\r\n
            my $header = substr($window, 0, $idx+4, '');
            my @lines = split(/\r\n/, $header);

            my %hdval;
            my $lasthd;
            foreach (@lines) {
                if (/^(\S+?):\s*(.+)/) {
                    $lasthd = lc($1);
                    $hdval{$lasthd} = $2;
                } elsif (/^\s+.+/) {
                    $hdval{$lasthd} .= $&;
                }
            }

            my ($name, $filename);
            if ($hdval{'content-disposition'} =~ /\bNAME=\"(.+?)\"/i) {
                $name = $1;
            }
            if ($hdval{'content-disposition'} =~ /\bFILENAME=\"(.+?)\"/i) {
                $filename = $1;
            }

            # newheaders hook is required
            $run_hook->('newheaders', $name, $filename)
                or return 0;

            $state = 0;
        }
        
    }
    return 1;
}


sub reset_cookies
{
    %BML::COOKIE_R = ();
    %BML::COOKIE_M = ();
    $BML::COOKIES_PARSED = 0;
}

sub set_config
{
    my ($key, $val) = @_;
    die "BML::set_config called from non-conffile context.\n" unless $Apache::BML::conf_pl;
    $Apache::BML::conf_pl->{$key} ||= $val;
    #$Apache::BML::config->{$path}->{$key} = $val;
}

sub noparse
{
    $Apache::BML::CodeBlockOpts{'raw'} = 1;
    return $_[0];
}

sub decide_language
{
    my BML::Request $req = $Apache::BML::cur_req;
    my $env = $req->{'env'};

    # GET param 'uselang' takes priority
    my $uselang = $BMLCodeBlock::GET{'uselang'};
    if (exists $env->{"Langs-$uselang"} || $uselang eq "debug") {
        return $uselang;
    }

    # next is their cookie preference
    if ($BML::COOKIE{'langpref'} =~ m!^(\w{2,10})/(\d+)$!) {
        if (exists $env->{"Langs-$1"}) {
            # make sure the document says it was changed at least as new as when
            # the user last set their current language, else their browser might
            # show a cached (wrong language) version.
            note_mod_time($req, $2);
            return $1;
        }
    }
    
    # next is their browser's preference
    my %lang_weight = ();
    my @langs = split(/\s*,\s*/, lc($req->{'r'}->header_in("Accept-Language")));
    my $winner_weight = 0.0;
    my $winner;
    foreach (@langs)
    {
        # do something smarter in future.  for now, ditch country code:
        s/-\w+//;
        
        if (/(.+);q=(.+)/) {
            $lang_weight{$1} = $2;
        } else {
            $lang_weight{$_} = 1.0;
        }
        if ($lang_weight{$_} > $winner_weight && defined $env->{"ISOCode-$_"}) {
            $winner_weight = $lang_weight{$_};
            $winner = $env->{"ISOCode-$_"};
        }
    }
    return $winner if $winner;

    # next is the default language
    return $req->{'env'}->{'DefaultLanguage'} if $req->{'env'}->{'DefaultLanguage'};
    
    # lastly, english.
    return "en";
}

sub register_language
{
    my ($langcode) = @_;
    die "BML::register_language called from non-conffile context.\n" unless $Apache::BML::conf_pl;
    $Apache::BML::conf_pl->{"Langs-$langcode"} ||= 1;
}

sub register_isocode
{
    my ($isocode, $langcode) = @_;
    next unless $isocode =~ /^\w{2,2}$/;
    die "BML::register_isocode called from non-conffile context.\n" unless $Apache::BML::conf_pl;
    $Apache::BML::conf_pl->{"ISOCode-$isocode"} ||= $langcode;
}

# get/set the flag to send the Last-Modified header
sub want_last_modified
{
    $Apache::BML::cur_req->{'want_last_modified'} = $_[0]
        if defined $_[0];
    return $Apache::BML::cur_req->{'want_last_modified'};
}

sub note_mod_time
{
    my $mod_time = shift;
    Apache::BML::note_mod_time($Apache::BML::cur_req, $mod_time);
}

sub redirect
{
    my $url = shift;
    $Apache::BML::cur_req->{'location'} = $url;
    finish_suppress_all();
    return;
}

sub do_later
{
    my $subref = shift;
    return 0 unless ref $subref eq "CODE";
    $Apache::BML::cur_req->{'r'}->register_cleanup($subref);
    return 1;
}

sub register_block
{
    my ($type, $flags, $def) = @_;
    my $target = $Apache::BML::conf_pl_look;
    die "BML::register_block called from non-lookfile context.\n" unless $target;
    $type = uc($type);

    $target->{$type} = [ $def, $flags ];
    return 1;
}

sub register_hook
{
    my ($name, $code) = @_;
    die "BML::register_hook called from non-conffile context.\n" unless $Apache::BML::conf_pl;
    $Apache::BML::conf_pl->{"HOOK-$name"} = $code;
}

sub get_request
{
    # we do this, and not use $Apache::BML::r directly because some non-BML
    # callers sometimes use %BML::COOKIE, so $Apache::BML::r isn't set.
    # the cookie FETCH below calls this function to try and use Apache->request,
    # else fall back to the global one (for use in profiling/debugging)
    my $r;
    eval {
        $r = Apache->request;
    };
    $r ||= $Apache::BML::r;
    return $r;
}

sub get_query_string
{
    return scalar($Apache::BML::r->args);
}

sub get_uri
{
    return $Apache::BML::r->uri;
}

sub get_method
{
    return $Apache::BML::r->method;
}

sub get_path_info
{
    return $Apache::BML::r->path_info;
}

sub get_remote_ip
{
    return $Apache::BML::r->connection()->remote_ip;
}

sub get_remote_host
{
    return $Apache::BML::r->connection()->remote_host;
}

sub get_remote_user
{
    return $Apache::BML::r->connection()->user;
}

sub get_client_header
{
    my $hdr = shift;
    return $Apache::BML::r->header_in($hdr);    
}

# <LJFUNC>
# class: web
# name: BML::self_link
# des: Takes the URI of the current page, and adds the current form data
#      to the url, then adds any additional data to the url.
# returns: scalar; the full url
# args: newvars
# des-newvars: A hashref of information to add/override to the link.
# </LJFUNC>
sub self_link
{
    my $newvars = shift;
    my $link = $Apache::BML::r->uri;
    my $form = \%BMLCodeBlock::FORM;

    $link .= "?";
    foreach (keys %$newvars) {
        if (! exists $form->{$_}) { $form->{$_} = ""; }
    }
    foreach (sort keys %$form) {
        if (defined $newvars->{$_} && ! $newvars->{$_}) { next; }
        my $val = $newvars->{$_} || $form->{$_};
        next unless $val;
        $link .= BML::eurl($_) . "=" . BML::eurl($val) . "&";
    }
    chop $link;
    return $link;
}

sub http_response
{
    my ($code, $msg) = @_;

    my $r = $Apache::BML::r;
    $r->status($code);
    $r->content_type('text/html');
    $r->print($msg);
    finish_suppress_all();
    return;
}

sub finish_suppress_all
{
    finish();
    suppress_headers();
    suppress_content();
}

sub suppress_headers
{
    # set any cookies that we have outstanding
    send_cookies();
    $Apache::BML::cur_req->{'env'}->{'NoHeaders'} = 1;
}

sub suppress_content
{
    $Apache::BML::cur_req->{'env'}->{'NoContent'} = 1;
}

sub finish
{
    $Apache::BML::cur_req->{'stop_flag'} = 1;
}

sub set_content_type
{
    $Apache::BML::cur_req->{'content_type'} = $_[0] if $_[0];
}

# <LJFUNC>
# class: web
# name: BML::set_status
# des: Takes a number to indicate a status (e.g. 404, 403, 410, 500, etc) and sets
#   that to be returned to the client when the request finishes.
# returns: nothing
# args: status
# des-newvars: A number representing the status to return to the client.
# </LJFUNC>
sub set_status
{
    $Apache::BML::r->status($_[0]+0) if $_[0];
}

sub eall
{
    return ebml(ehtml($_[0]));
}


# escape html
sub ehtml
{
    my $a = $_[0];
    $a =~ s/\&/&amp;/g;
    $a =~ s/\"/&quot;/g;
    $a =~ s/\'/&\#39;/g;
    $a =~ s/</&lt;/g;
    $a =~ s/>/&gt;/g;
    return $a;  
}

sub ebml
{
    my $a = $_[0];
    my $ra = ref $a ? $a : \$a;
    $$ra =~ s/\(=(\w)/\(= $1/g;  # remove this eventually (old syntax)
    $$ra =~ s/(\w)=\)/$1 =\)/g;  # remove this eventually (old syntax)
    $$ra =~ s/<\?/&lt;?/g;
    $$ra =~ s/\?>/?&gt;/g;
    return if ref $a;
    return $a;
}

sub get_language
{
    return $Apache::BML::cur_req->{'lang'};
}

sub get_language_default
{
    return $Apache::BML::cur_req->{'env'}->{'DefaultLanguage'} || "en";
}

sub set_language_scope {
    $BML::ML_SCOPE = shift;
}

sub set_language
{
    my ($lang, $getter) = @_;  # getter is optional
    my BML::Request $req = $Apache::BML::cur_req;
    my $r = BML::get_request();
    $r->notes('langpref' => $lang);

    # don't rely on $req (the current BML request) being defined, as
    # we allow callers to use this interface directly from non-BML
    # requests.
    if ($req) {
        $req->{'lang'} = $lang;
        $getter ||= $req->{'env'}->{'HOOK-ml_getter'};
    }

    no strict 'refs';
    if ($lang eq "debug") {
        *{"BML::ml"} = sub {
            return $_[0];
        };
        *{"BML::ML::FETCH"} = sub {
            return $_[1];
        };
    } elsif ($getter) {
        *{"BML::ml"} = sub {
            my ($code, $vars) = @_;
            $code = $BML::ML_SCOPE . $code
                if rindex($code, '.', 0) == 0;
            return $getter->($lang, $code, undef, $vars);
        };
        *{"BML::ML::FETCH"} = sub {
            my $code = $_[1];
            $code = $BML::ML_SCOPE . $code
                if rindex($code, '.', 0) == 0;
            return $getter->($lang, $code);
        };
    };
    
}

# multi-lang string
# note: sub is changed when BML::set_language is called
sub ml
{
    return "[ml_getter not defined]";
}

sub eurl
{
    my $a = $_[0];
    $a =~ s/([^a-zA-Z0-9_\-.\/\\\: ])/uc sprintf("%%%02x",ord($1))/eg;
    $a =~ tr/ /+/;
    return $a;
}

sub durl
{
    my ($a) = @_;
    $a =~ tr/+/ /;
    $a =~ s/%([a-fA-F0-9][a-fA-F0-9])/pack("C", hex($1))/eg;
    return $a;
}

sub randlist
{
    my @rlist = @_;
    my $size = scalar(@rlist);
    
    my $i;
    for ($i=0; $i<$size; $i++)
    {
        unshift @rlist, splice(@rlist, $i+int(rand()*($size-$i)), 1);
    }
    return @rlist;
}

sub page_newurl
{
    my $page = $_[0];
    my @pair = ();
    foreach (sort grep { $_ ne "page" } keys %BMLCodeBlock::FORM)
    {
        push @pair, (eurl($_) . "=" . eurl($BMLCodeBlock::FORM{$_}));
    }
    push @pair, "page=$page";
    return $Apache::BML::r->uri . "?" . join("&", @pair);
}

sub paging
{
    my ($listref, $page, $pagesize) = @_;
    $page = 1 unless ($page && $page==int($page));
    my %self;
    
    $self{'itemcount'} = scalar(@{$listref});
        
    $self{'pages'} = $self{'itemcount'} / $pagesize;
    $self{'pages'} = $self{'pages'}==int($self{'pages'}) ? $self{'pages'} : (int($self{'pages'})+1);

    $page = 1 if $page < 1;
    $page = $self{'pages'} if $page > $self{'pages'};
    $self{'page'} = $page;
    
    $self{'itemfirst'} = $pagesize * ($page-1) + 1;
    $self{'itemlast'} = $self{'pages'}==$page ? $self{'itemcount'} : ($pagesize * $page);
    
    $self{'items'} = [ @{$listref}[($self{'itemfirst'}-1)..($self{'itemlast'}-1)] ];
    
    unless ($page==1) { $self{'backlink'} = "<a href=\"" . page_newurl($page-1) . "\">&lt;&lt;&lt;</a>"; }
    unless ($page==$self{'pages'}) { $self{'nextlink'} = "<a href=\"" . page_newurl($page+1) . "\">&gt;&gt;&gt;</a>"; }
    
    return %self;
}

sub send_cookies {
    my $req = shift() || $Apache::BML::cur_req;
    foreach (values %{$req->{'cookies'}}) {
        $req->{'r'}->err_headers_out->add("Set-Cookie" => $_);
    }
    $req->{'cookies'} = {};
    $req->{'env'}->{'SentCookies'} = 1;
}

# $expires = 0  to expire when browser closes
# $expires = undef to delete cookie
sub set_cookie
{
    my ($name, $value, $expires, $path, $domain, $http_only) = @_;
    
    my BML::Request $req = $Apache::BML::cur_req;
    my $e = $req->{'env'};
    $path = $e->{'CookiePath'} unless defined $path;
    $domain = $e->{'CookieDomain'} unless defined $domain;

    # let the domain argument be an array ref, so callers can set
    # cookies in both .foo.com and foo.com, for some broken old browsers.
    if ($domain && ref $domain eq "ARRAY") {
        foreach (@$domain) {
            set_cookie($name, $value, $expires, $path, $_, $http_only);
        }
        return;
    }

    my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = gmtime($expires);
    $year+=1900;

    my @day = qw{Sunday Monday Tuesday Wednesday Thursday Friday Saturday};
    my @month = qw{Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec};
    
    my $cookie = eurl($name) . "=" . eurl($value);

    # this logic is confusing potentially
    unless (defined $expires && $expires==0) {
        $cookie .= sprintf("; expires=$day[$wday], %02d-$month[$mon]-%04d %02d:%02d:%02d GMT", 
                           $mday, $year, $hour, $min, $sec);
    }
    $cookie .= "; path=$path" if $path;
    $cookie .= "; domain=$domain" if $domain;
    $cookie .= "; HttpOnly" if $http_only && BML::http_only();

    # send a cookie directly or cache it for sending later?
    if ($e->{'SentCookies'}) {
        $req->{'r'}->err_headers_out->add("Set-Cookie" => $cookie);
    } else {
        $req->{'cookies'}->{"$name:$domain"} = $cookie;
    }

    if (defined $expires) {
        $BML::COOKIE_R{$name} = $value;
    } else {
        delete $BML::COOKIE_R{$name};
    }
}

# cookie support
package BML::Cookie;

sub TIEHASH {
    my $class = shift;
    my $self = {};
    bless $self;
    return $self;
}

sub FETCH {
    my ($t, $key) = @_;
    # we do this, and not use $Apache::BML::r directly because some non-BML
    # callers sometimes use %BML::COOKIE.
    my $r = BML::get_request();
    unless ($BML::COOKIES_PARSED) {
        foreach (split(/;\s+/, $r->header_in("Cookie"))) {
            next unless ($_ =~ /(.*)=(.*)/);
            my ($name, $value) = ($1, $2);

            # if the cookie already exists, we'll take the existing value as 
            # well as all new ones, and push them onto an arrayref in COOKIE_M
            if (exists $BML::COOKIE_R{$name}) {
                push @{$BML::COOKIE_M{$name}}, $BML::COOKIE_R{$name}
                    unless ref $BML::COOKIE_M{$name};

                push @{$BML::COOKIE_M{$name}}, $value;
            }

            $BML::COOKIE_R{BML::durl($name)} = BML::durl($value);
        }
        $BML::COOKIES_PARSED = 1;
    }

    # return scalar value, or arrayref if key has [] appended
    return $key =~ s/\[\]$// ?
        $BML::COOKIE_M{$key} || [$BML::COOKIE_R{$key}] : $BML::COOKIE_R{$key};
}

sub STORE {
    my ($t, $key, $val) = @_;
    my $etime = 0;
    my $http_only = 0;
    ($val, $etime, $http_only) = @$val if ref $val eq "ARRAY";
    $etime = undef unless $val ne "";
    BML::set_cookie($key, $val, $etime, undef, undef, $http_only);
}

sub DELETE {
    my ($t, $key) = @_;
    STORE($t, $key, undef);
}

sub CLEAR {
    my ($t) = @_;
    foreach (keys %BML::COOKIE_R) {
        STORE($t, $_, undef);
    }
}

sub EXISTS {
    my ($t, $key) = @_;
    return defined $BML::COOKIE_R{$key};
}

sub FIRSTKEY {
    my ($t) = @_;
    keys %BML::COOKIE_R;
    return each %BML::COOKIE_R;
}

sub NEXTKEY {
    my ($t, $key) = @_;
    return each %BML::COOKIE_R;
}

# provide %BML::ML & %BMLCodeBlock::ML support:
package BML::ML;

sub TIEHASH {
    my $class = shift;
    my $self = {};
    bless $self;
    return $self;
}

# note: sub is changed when BML::set_language is called.
sub FETCH {
    return "[ml_getter not defined]";
}

# do nothing
sub CLEAR { }

1;

# Local Variables:
# mode: perl
# c-basic-indent: 4
# indent-tabs-mode: nil
# End:
