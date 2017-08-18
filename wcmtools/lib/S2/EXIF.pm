#!/usr/bin/perl
#
# This is a helper package, contains info about EXIF tag categories and how to print them
#

package S2::EXIF;
use strict;
use vars qw(@TAG_CAT %TAG_CAT);

# rough categories which can optionally be used to display tags
# with coherent ordering

@TAG_CAT = 
    (
     [ media => {
         name => 'Media Information',
         tags => [ qw (
                       PixelXDimension
                       PixelYDimension
                       ImageWidth
                       ImageLength
                       Compression
                       CompressedBitsPerPixel
                       )
                   ],
         },
       ],
     
     [ image => { 
         name => 'Image Information',
         tags => [ qw (
                       DateTime
                       DateTimeOriginal
                       ImageDescription
                       UserComment
                       Make
                       Software
                       Artist
                       Copyright
                       ExifVersion
                       FlashpixVersion
                       )
                   ],
         },
       ],
     
     [ exposure => {
         name => 'Exposure Settings',
         tags => [ qw(
                      Orientation
                      Flash
                      FlashEnergy
                      LightSource
                      ExposureTime
                      ExposureProgram
                      ExposureMode
                      DigitalZoomRatio
                      ShutterSpeedValue
                      ApertureValue
                      MeteringMode
                      WhiteBalance
                      Contrast
                      Saturation
                      Sharpness
                      SensingMethod
                      FocalLength
                      ISOSpeedRatings
                      FNumber
                      )
                   ],
         },
       ],
     
     [ gps => {
         name => 'GPS Information',
         tags => [ qw(
                      GPSLatitudeRef
                      GPSLatitude
                      GPSLongitudeRef
                      GPSLongitude
                      GPSAltitudeRef
                      GPSAltitude
                      GPSTimeStamp
                      GPSDateStamp
                      GPSDOP
                      GPSImgDirectionRef
                      GPSImgDirection
                      )
                   ],
         },
       ],
     );

# make mapping into array
%TAG_CAT = map { $_->[0] => $_->[1] } @TAG_CAT;

# return all tags in all categories
sub get_tag_info {

    my @ret = ();
    foreach my $currcat (@S2::EXIF::TAG_CAT) {
        push @ret, @{$currcat->[1]->{tags}};
    }

    return @ret;
}

# return hashref of category keys => names
sub get_cat_info {
    return { map { $_->[0] => $_->[1]->{name} } @S2::EXIF::TAG_CAT };
}

# return ordered array of category keys
sub get_cat_order {
    return map { $_->[0] } @S2::EXIF::TAG_CAT;
}

# return the name of a single category
sub get_cat_name {
    return () unless $TAG_CAT{$_[0]};
    return $TAG_CAT{$_[0]}->{name};
}

# return the tags in a given cateogry
sub get_cat_tags {
    return () unless $TAG_CAT{$_[0]};
    return @{$TAG_CAT{$_[0]}->{tags}};
}

# return all tags for all categories
sub get_all_tags {
    return map { @{$TAG_CAT{$_}->{tags}} } keys %TAG_CAT;
}

1;
