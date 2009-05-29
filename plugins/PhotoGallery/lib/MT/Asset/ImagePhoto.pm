# Copyright 2001-2008 Six Apart. This code cannot be redistributed without
# permission from www.sixapart.com.  For more information, consult your
# Movable Type license.
#
# $Id: $

package MT::Asset::ImagePhoto;

use strict;
use base qw( MT::Asset::Image );

__PACKAGE__->install_properties( { class_type => 'photo', } );

sub class_label { MT->translate('Photo'); }
sub class_label_plural { MT->translate('Photos'); }
sub extensions { undef }

sub insert_options {
    my $asset = shift;
    my ($param) = @_;

    my $app   = MT->instance;
    my $perms = $app->{perms};
    my $blog  = $asset->blog or return;

    $param->{thumbnail}  = $asset->thumbnail_url;
    $param->{video_id}   = $asset->video_id;
    $param->{align_left} = 1;
    $param->{html_head}  = '<link rel="stylesheet" href="'.$app->static_path.'plugins/PhotoGallery/styles/app.css" type="text/css" />';

    return $app->build_page( '../plugins/PhotoGallery/tmpl/dialog/asset_options.tmpl', $param );
}

1;
__END__

=head1 NAME

    MT::Asset::ImagePhoto

=head1 AUTHOR & COPYRIGHT

Please see the L<MT/"AUTHOR & COPYRIGHT"> for author, copyright, and
license information.

=cut
