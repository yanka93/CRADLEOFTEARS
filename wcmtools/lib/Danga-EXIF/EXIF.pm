#!/usr/bin/perl
#
# Danga::EXIF - An all-perl EXIF extraction library
# Brad Whitaker (whitaker@danga.com) - Danga Interactive
#
# TODO:
#  - MakerNotes/UserNotes
#  - GPS Tags
#  - Handle more SubIFD/SubSubIFDs
#  - fix bugs?

package Danga::EXIF;

use strict;
use Carp;
use IO::File;

# print debugging information?
use constant DEBUG          => 0;

use constant MARK_SOI       => "\xFF\xD8";     # start of image
use constant MARK_EOI       => "\xFF\xD9";     # end of image
use constant MARK_SOS       => "\xFF\xDA";     # start of stream
use constant MARK_APP0_JFIF => "\xFF\xE0";     # App0 (JFIF) marker
use constant MARK_APP1_EXIF => "\xFF\xE1";     # App1 (EXIF) marker
use constant EXIF_HEADER    => "Exif\x00\x00"; # EXIF header
use constant EXIF_SUBIFD    => 0x8769;         # EXIF SubIFD Tag (numeric)
use constant TIFF_HEADER    => 0x002A;         # TIFF header marker
use constant ORDER_INTEL    => "II";           # Intel (little-endian) byte-order
use constant ORDER_MOTOROLA => "MM";           # Motorola (big-endian) byte-order

use fields qw(byte_order src filename buff offset tags);

sub debug { print STDERR "$_[0]\n" if DEBUG; }

sub new {
    my Danga::EXIF $self = shift;
    $self = fields::new($self) unless ref $self;

    my %args = @_;

    $self->{byte_order} = undef;
    $self->{src}        = $args{src};
    $self->{filename}   = undef;
    $self->{buff}       = undef;
    $self->{offset}     = 0;
    $self->{tags}       = [];

    # this is most of the work
    $self->process_file;

    return $self;
}

sub open_src
{
    my Danga::EXIF $self = shift;
    my $filename = shift;

    return length(${$self->{src}}) if ref $self->{src} eq 'SCALAR';
    return -s $self->{src} if ref $self->{src};

    # it's probably a scalar, open the file
    if ($self->{filename} = $self->{src}) {
        debug("open_src: file: $self->{filename}");
        $self->{src} = new IO::File $self->{filename}
            or croak "open_src: couldn't open file $self->{filename}: $!";
        return -s $self->{src};
    }

    return undef;
}

sub close_src
{
    my Danga::EXIF $self = shift;

    # close filehandle if we were the ones who opened it
    return close $self->{src}
         if $self->{filename} && ref $self->{src} eq 'IO::Handle';

    return 1;
}

# read a specified number of bytes from $self->{src}
sub read_src
{
    my Danga::EXIF $self = shift;
    my $len = shift;

    # src is scalarref
    if (ref $self->{src} eq 'SCALAR') {
        return substr(${$self->{src}}, 0, $len, '');
    }

    # src is probably filehandle
    my $n = read($self->{src}, $self->{buff}, $len);
    die "read failed: $!" unless defined $n;
    die "short read ($len/$n)" unless $n == $len;
    return $self->{buff};
}

# read the next n bytes from $self->{buff} and increment offset
sub read_buff
{
    my Danga::EXIF $self = shift;
    my $len = shift;

    my $rval = substr($self->{buff}, $self->{offset}, $len);
    $self->seek_buff($len);
    return $rval;
}

# move the offset pointer n bytes forward
sub seek_buff
{
    my Danga::EXIF $self = shift;

    return $self->{offset} += $_[0];
}

# return n bytes from $self->{buff} starting at a given offset
sub peek_buff
{
    my Danga::EXIF $self = shift;
    my ($offset, $len) = @_;

    return substr($self->{buff}, $offset, $len);
}

# unpacking mechanism which respects byte ordering
sub unpack
{
    my Danga::EXIF $self = shift;
    my ($tmpl, $data) = @_;

    croak "undefined byte order"
        unless defined $self->{byte_order};

    # flip order to little endian if necessary
    $tmpl =~ tr/vV/nN/
        unless $self->{byte_order} eq ORDER_INTEL;

    return CORE::unpack($tmpl, $data);
}

sub process_file
{
    my Danga::EXIF $self = shift;

    my $filesize = $self->open_src
        or croak "Couldn't open source file";
    debug("filesize: $filesize");
    debug("src: $self->{src}");

    my $pos = 0;
    
    my $do_read = sub {
        my $len = shift;
        debug("received len: $len");
        if ($pos + $len > $filesize) {
            $len = $filesize - $pos;
            debug("adjusing len: $len");
        }
        $pos += $len;
        debug("do_read, $pos > $filesize?");
        debug("yes, done") if $pos > $filesize;
        #last if $pos > $filesize;

        my $buf = $self->read_src($len);
        debug("nope, buf=" . length($buf));
        return $buf;
    };

    # need an SOI to make sure this file is valid
    my $soi = $self->read_src(2);
    $pos += 2;
    croak "Error reading EXIF header: SOI missing"
        unless $soi eq MARK_SOI;
    
    # read until end of header
    while ($pos + 4 <= $filesize) {

        debug("in loop");
        my ($mark, $len) = CORE::unpack("a2v", $do_read->(4));
        debug("mark=" . CORE::unpack("H4", $mark) . ", len=" . length($self->{buff}));
        last if $mark eq MARK_EOI || $mark eq MARK_SOS;
        last if $len < 2;
        
        # length contains the 2-byte data length descriptor,
        # so strip that to know how much to actually read

        $self->{buff} = $do_read->($len - 2);

        if ($mark eq MARK_APP0_JFIF) {
            debug("JFIF marker");
            
            # TODO: get info from here?
            next;
        }
        
        if ($mark eq MARK_APP1_EXIF) {
            debug("EXIF marker");
            $self->process_app1_exif;
            last;
        }
        
        # don't care about other markers
    }
    
    $self->close_src;

    return 1;
}

sub process_app1_exif
{
    my Danga::EXIF $self = shift;

    my $hdr = substr($self->{buff}, 0, 6, '');
    croak "invalid exif header"
        unless $hdr eq EXIF_HEADER;

    # Offset 0 is now beginning of TIFF header

    # determine byte order
    $self->{byte_order} = $self->read_buff(2);
    debug("byte order: $self->{byte_order}");
    croak "process_app1_exif: unknown byte order"
        unless ($self->{byte_order} eq ORDER_INTEL ||
                $self->{byte_order} eq ORDER_MOTOROLA);

    croak "process_app1_exif: invalid TIFF header"
        unless $self->unpack("v", $self->read_buff(2)) == TIFF_HEADER;

    my $ifd_offset = $self->unpack("V", $self->read_buff(4));

    # subtract 8 to account for the 8 bytes of tiff header
    # already read, but included in the offset
    $ifd_offset -= 8;

    # if the first ifd starts at an offset, skip to there
    # and throw away anything in between.
    debug("ifd offset: $ifd_offset");
    if ($ifd_offset > 0) {
        debug("seeking");
        $self->seek_buff($ifd_offset);
    }

    $self->process_ifds;
}

sub process_ifds
{
    my Danga::EXIF $self = shift;

    debug("processing ifd at offset: $self->{offset}");

    my $ifd_size = $self->unpack("v", $self->read_buff(2))
        or croak "process_ifds: empty ifd";

    debug("ifd_size: $ifd_size");

    foreach (1..$ifd_size) {

        my ($tagid, $type, $count) =
            $self->unpack("vvV", $self->read_buff(8));

        # next 4 bytes are either a value or an offset,
        # read them raw at first until we know how they
        # should be interpretted
        my $val = $self->read_buff(4);

        # if the tagid is the EXIF_SUBIFD tag, then the value
        # is a pointer to that IFD, which needs processing
        if ($tagid == EXIF_SUBIFD) {

            # FIXME: ghetto, do something smarter
            my $save_offset = $self->{offset};
            $self->{offset} = $self->unpack("V", $val);
            $self->process_ifds;
            $self->{offset} = $save_offset;
            next;
        }

        my $typeinf = Danga::EXIF::get_type_info($type);
        my $len = $count * $typeinf->{bytes};

        # if length is supposed to be less than 4 bytes, it'll be
        # left-aligned inside the value field
        if ($len < 4) {
            $val = substr($val, 0, $len);

        # if length is more than 4 bytes, then val is an offset
        # to the real value
        } elsif ($len > 4) {
            $val = $self->peek_buff($self->unpack("V", $val), $len);
        }

        # apply template if defined
        my $template = $typeinf->{template} || "a*";
        $template x= $count unless index($template, '*') >= 0;
        my @val = $self->unpack($template, $val);

        # register this tag
        if (Danga::EXIF::is_known_tag($tagid)) {
            push @{$self->{tags}}, Danga::EXIF::Tag->new
                ( tagid => $tagid, type => $type, value => \@val );
        }
    }
}

sub tags
{
    my Danga::EXIF $self = shift;

    # array context returns array of tags
    return @{$self->{tags}} if wantarray;

    # scalar context returns hashref of tag => value
    return { map { $_->tag => $_->value } grep { $_->value } @{$self->{tags}} };
}

sub is_known_tag
{
    my $tagid = shift;

    return exists $Danga::EXIF::TAG_INFO{$tagid} ? 1 : 0;
}

sub get_tag_info
{
    my $tagid = shift;

    return $Danga::EXIF::TAG_INFO{$tagid} || {
        tag  => $tagid,
        name => "Tag-" . sprintf("%4x", $tagid),
        disp => "none",
    };
}

sub get_type_info
{
    return $Danga::EXIF::TYPE_INFO{$_[0]} || {};
}

###############################################################################

package Danga::EXIF::Tag;

use strict;
use Carp;

use fields qw(tagid type value);

*debug = *Danga::EXIF::debug;

sub new
{
    my Danga::EXIF::Tag $self = shift;
    $self = fields::new($self) unless ref $self;

    my %args = @_;

    $self->{tagid} = $args{tagid} or croak "no tagid";
    $self->{type}  = $args{type}  or croak "no data type";;
    $self->{value} = $args{value} or croak "no value";

    return $self;
}

sub tag
{
    my Danga::EXIF::Tag $self = shift;

    return Danga::EXIF::get_tag_info($self->{tagid})->{tag};
}

sub name
{
    my Danga::EXIF::Tag $self = shift;

    return Danga::EXIF::get_tag_info($self->{tagid})->{name};
}

sub value
{
    my Danga::EXIF::Tag $self = shift;

    my $taginf = Danga::EXIF::get_tag_info($self->{tagid});
    my $disp = $taginf->{disp} || 'literal';

    if ($disp eq 'none') {
        return ''; # MakerNote, UserComment (for now)
    }

    if (ref $disp eq 'HASH') {
        my $key = join('', @{$self->{value}});
        return $disp->{$key};
    }

    if (ref $disp eq 'CODE') {
        return $disp->(@{$self->{value}});
    }

    my $typeinf = Danga::EXIF::get_type_info($self->{type});
    if (my $literal = $typeinf->{literal}) {
        return $literal->(@{$self->{value}});
    }

    # default literal behavior
    return join('', @{$self->{value}});
}


###############################################################################

package Danga::EXIF;

use strict;
use vars qw(%TYPE_INFO %TAG_INFO);

%TYPE_INFO =
    (
     # An 8-bit unsigned integer.
     0x0001 => {
         type     => "byte",
         bytes    => 1,
         template => "a",
     },

     # An 8-bit byte containing one 7-bit ASCII code. The final byte is terminated with NULL.
     0x0002 => {
         type     => "ascii",
         bytes     => 1,
         template => "A*",
     },

     # A 16-bit (2-byte) unsigned integer.
     0x0003 => {
         type     => "short",
         bytes    => 2,
         template => "v",
     },

     # A 32-bit (4-byte) unsigned integer.
     0x0004 => {
         type     => "long",
         bytes    => 4,
         template => "V",
     },

     # Two LONGs. The first LONG is the numerator and the second LONG expresses the denominator.
     0x0005 => {
         type     => "rational",
         bytes    => 8,
         template => "VV",
         literal  => sub { join("/", map { $_+0 } @_[0,1]) },
     },

     # An 8-bit byte that can take any value depending on the field definition.
     0x0007 => {
         type     => "undefined",
         bytes    => 1,
         template => "a*",
     },

     # A 32-bit (4-byte) signed integer (2's complement notation).
     0x0009 => {
         type     => "slong",
         bytes    => 4,
         template => "l",
     },

     # Two SLONGs. The first SLONG is the numerator and the second SLONG is the denominator.
     0x000a => {
         type     => "srational",
         bytes    => 8,
         template => "ll",
         literal  => sub { join("/", map { $_+0 } @_[0,1]) },

     },

     );

#
# TagID => { tag  => "TagName",
#            name => "Display name",
#            disp => literal|none|hashref|subref,
#            }

%TAG_INFO = 
    (
     0x927c => {
         tag  => "MakerNote",
         name => "Manufacturer Notes",
         disp => "none",
     },
     0x9286 => {
         tag  => "UserComment",
         name => "User comments",
         disp => "none",
     },
     
     # FILE INFO
     0x0100 => {
         tag  => "ImageWidth",
         name => "Image width",
         disp => "literal",
     },
     0x0101 => {
         tag  => "ImageLength",
         name => "Image height",
         disp => "literal",
     },
     0x0102 => {
         tag  => "BitsPerSample",
         name =>  "Number of bits per component",
         disp => "literal",
     },
     0x0103 => {
         tag  => "Compression",
         name => "Compression scheme",
         disp => {
             1 => "Uncompressed",
             6 => "JPEG compression (thumbnails only)",
         },
     },
     0x0106 => {
         tag  => "PhotometricInterpretation",
         name => "Pixel composition",
         disp => {
             2 => "RGB",
             6 => "YCbCr",
         },
     },
     0x0112 => {
         tag  => "Orientation",
         name => "Orientation of image",
         disp => {
             1 => "The 0th row is at the visual top of the image, and the 0th column is the visual left-hand side",
             2 => "The 0th row is at the visual top of the image, and the 0th column is the visual right-hand side",
             3 => "The 0th row is at the visual bottom of the image, and the 0th column is the visual right-hand side",
             4 => "The 0th row is at the visual bottom of the image, and the 0th column is the visual left-hand side",
             5 => "The 0th row is the visual left-hand side of the image, and the 0th column is the visual top",
             6 => "The 0th row is the visual right-hand side of the image, and the 0th column is the visual top",
             7 => "The 0th row is the visual right-hand side of the image, and the 0th column is the visual bottom",
             8 => "The 0th row is the visual left-hand side of the image, and the 0th column is the visual bottom",
         },
     },
     0x0115 => {
         tag  => "SamplesPerPixel",
         name => "Number of components",
         disp => "literal",
     },
     0x011c => {
         tag  => "PlanarConfiguration",
         name => "Image data arrangement",
         disp => {
             1 => "Chunky format",
             2 => "Planar format",
         },
     },
     0x0212 => {
         tag  => "YCbCrSubSampling",
         name => "Subsampling ratio of Y to C",
         disp => {
             21 => "YCbCr4:2:2",
             22 => "YCbCr4:2:0",
         },
     },
     0x0213 => {
         tag  => "YCbCrPositioning",
         name => "Y and C positioning",
         disp => {
             1 => "Centered",
             2 => "Co-sited",
         },
     },
     0x011a => {
         tag  => "XResolution",
         name => "Image resolution in width direction",
         disp => "literal",
     },
     0x011b => {
         tag  => "YResolution",
         name => "Image resolution in height direction",
         disp => "literal",
     },
     0x0128 => {
         tag  => "ResolutionUnit",
         name => "Unit of X and Y resolution",
         disp => {
             1 => "Unspecified",
             2 => "Pixels/Inch",
             3 => "Pixels/Centimeter",
         },
     },
     0x0111 => {
         tag  => "StripOffsets",
         name => "Image data location",
         disp => "literal",
     },
     0x0116 => {
         tag  => "RowsPerStrip",
         name => "Number of rows per strip",
         disp => "literal",
     },
     0x0117 => {
         tag  => "StripByteCounts",
         name => "Bytes per compressed strip",
         disp => "literal",
     },
     0x0201 => {
         tag  => "JPEGInterchangeFormat",
         name => "Offset to JPEG SOI",
         disp => "literal",
     },
     0x0202 => {
         tag  => "JPEGInterchangeFormatLength",
         name => "Bytes of JPEG data",
         disp => "literal",
     },
     0x012d => {
         tag  => "TransferFunction",
         name => "Transfer function",
         disp => "literal",
     },
     0x013e => {
         tag  => "WhitePoint",
         name => "White point chromaticity",
         disp => "literal",
     },
     0x013f => {
         tag  => "PrimaryChromaticities",
         name => "Chromaticities of primaries",
         disp => "literal",
     },
     0x0211 => {
         tag  => "YCbCrCoefficients",
         name => "Color space transformation matrix coefficients",
         disp => "literal",
     },
     0x0214 => {
         tag  => "ReferenceBlackWhite",
         name => "Pair of black and white reference values",
         disp => "literal",
     },
     0xa001 => {
         tag  => "ColorSpace",
         name => "Color space information",
         disp => {
             1 => "sRGB",
             65535 => "Uncalibrated",
         },
     },
     0x9000 => {
         tag  => "ExifVersion",
         name => "Exif version",
         disp => "literal",
     },
     0xa000 => {
         tag  => "FlashpixVersion",
         name => "Supported Flashpix version",
         disp => {
             0100 => "Flashpix Format Version 1.0",
         },
     },
     0x0132 => {
         tag  => "DateTime",
         name => "File change date and time",
         disp => "literal",
     },
     0x010e => {
         tag  => "ImageDescription",
         name => "Image title",
         disp => "literal",
     },
     0x010f => {
         tag  => "Make",
         name => "Image input equipment manufacturer",
         disp => "literal",
     },
     0x0110 => {
         tag  => "Model",
         name => "Image input equipment model",
         disp => "literal",
     },
     0x0131 => {
         tag  => "Software",
         name => "Software used",
         disp => "literal",
     },
     0x013b => {
         tag  => "Artist",
         name => "Person who created the image",
         disp => "literal",
     },
     0x8298 => {
         tag  => "Copyright",
         name => "Copyright holder",
         disp => "literal",
     },
     0xa420 => {
         tag  => "ImageUniqueID",
         name => "Unique image ID",
         disp => "literal",
     },
     0x9101 => {
         tag  => "ComponentsConfiguration",
         name => "Meaning of each component",
         disp => sub {
             my $val = shift;

             my $map = {
                 1 => "Y",
                 2 => "Cb",
                 3 => "Cr",
                 4 => "R",
                 5 => "G",
                 6 => "B",
             };
             return join('', map { $map->{$_} } split('', $val));
         },
     },
     0x9102 => {
         tag  => "CompressedBitsPerPixel",
         name => "Image compression mode",
         disp => "literal",
     },
     0xa002 => {
         tag  => "PixelXDimension",
         name => "Valid image width",
         disp => "literal",
     },
     0xa003 => {
         tag  => "PixelYDimension",
         name => "Valid image height",
         disp => "literal",
     },
     0xa004 => {
         tag  => "RelatedSoundFile",
         name => "Related audio file",
         disp => "literal",
     },
     0xa005 => {
         tag  => "ExifInteroperabilityOffset",
         name => "Exif interoperability offset",
         disp => "literal",
     },
     0x9003 => {
         tag  => "DateTimeOriginal",
         name => "Date and time of original data generation",
         disp => "literal",
     },
     0x9004 => {
         tag  => "DateTimeDigitized",
         name => "Date and time of digital data generation",
         disp => "literal",
     },
     0x9290 => {
         tag  => "SubSecTime",
         name => "DateTime subseconds",
         disp => "literal",
     },
     0x9291 => {
         tag  => "SubSecTimeOriginal",
         name => "DateTimeOriginal subseconds",
         disp => "literal",
     },
     0x9292 => {
         tag  => "SubSecTimeDigitized",
         name => "DateTimeDigitized subseconds",
         disp => "literal",
     },
     0x829a => {
         tag  => "ExposureTime",
         name => "Exposure time",
         disp => "literal",
     },
     0x829d => {
         tag  => "FNumber",
         name => "FNumber",
         disp => "literal",
     },
     0x8822 => {
         tag  => "ExposureProgram",
         name => "Exposure program",
         disp => {
             1 => "Manual",
             2 => "Normal program",
             3 => "Aperture priority",
             4 => "Shutter priority",
             5 => "Creative program (biased toward depth of field)",
             6 => "Action program (biased toward fast shutter speed)",
             7 => "Portrait mode (for closeup photos with the background out of focus)",
             8 => "Landscape mode (for landscape photos with the background in focus)",
         },
     },
     0x8824 => {
         tag  => "SpectralSensitivity",
         name => "Spectral sensitivity",
         disp => "literal",
     },
     0x8827 => {
         tag  => "ISOSpeedRatings",
         name => "ISO speed rating",
         disp => "literal",
     },
     0x8828 => {
         tag  => "OECF",
         name => "Optoelectric conversion factor",
         disp => "literal",
     },
     0x9201 => {
         tag  => "ShutterSpeedValue",
         name => "Shutter speed",
         disp => "literal",
     },
     0x9202 => {
         tag  => "ApertureValue",
         name => "Aperture",
         disp => "literal",
     },
     0x9203 => {
         tag  => "BrightnessValue",
         name => "Brightness",
         disp => "literal",
     },
     0x9204 => {
         tag  => "ExposureBiasValue",
         name => "Exposure bias",
         disp => "literal",
     },
     0x9205 => {
         tag  => "MaxApertureValue",
         name => "Maximum lens aperture",
         disp => "literal",
     },
     0x9206 => {
         tag  => "SubjectDistance",
         name => "Subject distance",
         disp => "literal",
     },
     0x9207 => {
         tag  => "MeteringMode",
         name => "Metering mode",
         disp => {
             1 => "Average",
             2 => "CenterWeightedAverage",
             3 => "Spot",
             4 => "MultiSpot",
             5 => "Pattern",
             6 => "Partial",
             255 => "Other",
         },
     },
     0x9208 => {
         tag  => "LightSource",
         name => "Light source",
         disp => {
             1 => "Daylight",
             2 => "Fluorescent",
             3 => "Tungsten (incandescent light)",
             4 => "Flash",
             9 => "Fine weather",
             10 => "Cloudy weather",
             11 => "Shade",
             12 => "Daylight fluorescent (D 5700 - 7100K)",
             13 => "Day white fluorescent (N 4600 - 5400K)",
             14 => "Cool white fluorescent (W 3900 - 4500K)",
             15 => "White fluorescent (WW 3200 - 3700K)",
             17 => "Standard light A",
             18 => "Standard light B",
             19 => "Standard light C",
             20 => "D55",
             21 => "D65",
             22 => "D75",
             23 => "D50",
             24 => "ISO studio tungsten",
             255 => "Other light source",
         },
     },
     0x9209 => {
         tag  => "Flash",
         name => "Flash",
         disp => sub {
             my $val = shift;
             
             my $bit = sub {
                 return $val & (1 << $_[0]);
             };
             
             # bit 0
             my @ret = $bit->(0) ? ("Flash fired") : ("Flash did not fire");
             
             # bits 1-2
             if (! $bit->(1) && ! $bit->(2)) {
                 push @ret, "No strobe return detection function";
             } elsif ($bit->(1)) {
                 push @ret, "Strobe return light " . ($bit->(2) ? "" : "not") . " detected";
             }
             
             # bits 3-4
             if (! $bit->(3) && $bit->(4)) {
                 push @ret, "Compulsory flash firing";
             } elsif ($bit->(3) && ! $bit->(4)) {
                 push @ret, "Compulsory flash suppression";
             } elsif ($bit->(3) && $bit->(4)) {
                 push @ret, "Auto mode";
             }
             
             # bit 5
             push @ret, ($bit->(5) ? "No flash function" : "Flash function present");
             
             # bit 6
             push @ret, ($bit->(6) ? "Red-eye reduction supported" : "No red-eye reduction mode or unknown");
             
             return join("; ", @ret);
         },
     },
     0x920a => {
         tag  => "FocalLength",
         name => "Lens focal length",
         disp => "literal",
     },
     0x9214 => {
         tag  => "SubjectArea",
         name => "Subject area",
         disp => "literal",
     },
     0xa20b => {
         tag  => "FlashEnergy",
         name => "Flash energy",
         disp => "literal",
     },
     0xa20c => {
         tag  => "SpatialFrequencyResponse",
         name => "Spatial frequency response",
         disp => "literal",
     },
     0xa20e => {
         tag  => "FocalPlaneXResolution",
         name => "Focal plane X resolution",
         disp => "literal",
     },
     0xa20f => {
         tag  => "FocalPlaneYResolution",
         name => "Focal plane Y resolution",
         disp => "literal",
     },
     0xa210 => {
         tag  => "FocalPlaneResolutionUnit",
         name => "Focal plane resolution unit",
         disp => sub {
             return "$_[0] inch";
         },
     },
     0xa214 => {
         tag  => "SubjectLocation",
         name => "Subject location",
         disp => "literal",
     },
     0xa215 => {
         tag  => "ExposureIndex",
         name => "Exposure index",
         disp => "literal",
     },
     0xa217 => {
         tag  => "SensingMethod",
         name => "Sensing method",
         disp => {
             2 => "One-chip color area sensor",
             3 => "Two-chip color area sensor",
             4 => "Three-chip color area sensor",
             5 => "Color sequential area sensor",
             7 => "Trilinear sensor",
             8 => "Color sequential linear sensor",
         },
     },
     0xa300 => {
         tag  => "FileSource",
         name => "File source",
         disp => {
             3 => "DSC",
         },
     },
     0xa301 => {
         tag  => "SceneType",
         name => "Scene type",
         disp => {
             1 => "A directly photographed image",
         },
     },
     0xa302 => {
         tag  => "CFAPattern",
         name => "CFA pattern",
         disp => "literal",
     },
     0xa401 => {
         tag  => "CustomRendered",
         name => "Custom rendered",
         disp => {
             0 => "Normal process",
             1 => "Custom process",
         },
     },
     0xa402 => {
         tag  => "ExposureMode",
         name => "Exposure mode",
         disp => {
             0 => "Auto exposure",
             1 => "Manual exposure",
             2 => "Auto bracket",
         },
     },
     0xa403 => {
         tag  => "WhiteBalance",
         name => "White balance",
         disp => {
             0 => "Auto white balance",
             1 => "Manual white balance",
         },
     },
     0xa404 => {
         tag  => "DigitalZoomRatio",
         name => "Digital zoom ratio",
         disp => "literal",
     },
     0xa405 => {
         tag  => "FocalLengthIn35mmFilm",
         name => "Focal length in 35 mm film",
         disp => "literal",
     },
     0xa406 => {
         tag  => "SceneCaptureType",
         name => "Scene capture type",
         disp => {
             0 => "Standard",
             1 => "Landscape",
             2 => "Portrait",
             3 => "Night scene",
         },
     },
     0xa407 => {
         tag  => "GainControl",
         name => "Gain control",
         disp => {
             0 => "None",
             1 => "Low gain up",
             2 => "High gain up",
             3 => "Low gain down",
             4 => "High gain down",
         },
     },
     0xa408 => {
         tag  => "Contrast",
         name => "Contrast",
         disp => {
             0 => "Normal",
             1 => "Soft",
             2 => "Hard",
         },
     },
     0xa409 => {
         tag  => "Saturation",
         name => "Saturation",
         disp => {
             0 => "Normal",
             1 => "Low saturation",
             2 => "High saturation",
         },
     },
     0xa40a => {
         tag  => "Sharpness",
         name => "Sharpness",
         disp => {
             0 => "Normal",
             1 => "Soft",
             2 => "Hard",
         },
     },
     0xa40b => {
         tag  => "DeviceSettingDescription",
         name => "Device settings description",
         disp => "literal",
     },
     0xa40c => {
         tag  => "SubjectDistanceRange",
         name => "Subject distance range",
         disp => {
             0 => "Unknown",
             1 => "Macro",
             2 => "Close view",
             3 => "Distant view",
         },
     },
     
     # TODO:  GPS INFO
);
