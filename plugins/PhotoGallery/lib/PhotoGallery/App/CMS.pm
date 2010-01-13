package PhotoGallery::App::CMS;

use strict;
use base qw( MT::App );

sub plugin { MT->component('PhotoGallery') }

use MT::Util
  qw( format_ts encode_url dirify archive_file_for iso2ts ts2iso epoch2ts );
use MT::ConfigMgr;

sub _read_info {
    my $asset = shift;

    eval 'use Image::ExifTool qw(:Public)';
    if ($@) {
        return undef;
    }
    my $cache_prop = $asset->{__exifinfo} || undef;
    unless ($cache_prop) {
        my $tool = new Image::ExifTool;
        ($cache_prop) = $tool->ImageInfo( $asset->file_path );
        return '' unless $cache_prop;
        $asset->{__exifInfo} = $cache_prop;
    }
    return $cache_prop;
}

sub update_timestamps {
    my $app  = shift;
    my $q    = $app->{query};
    my $blog = $app->blog;
    my $text;
    eval 'require Image::ExifTool';

    if ($@) {
        $text .= "Could not load Image::ExifTool";
    }
    else {
        my $iter = MT->model('entry')->load_iter( { blog_id => $blog->id } );
        while ( my $e = $iter->next ) {
            my $clause = '= asset_id';
            my @assets = MT->model('asset')->load(
                { class => '*' },
                {
                    join => MT->model('objectasset')->join_on(
                        undef,
                        {
                            asset_id  => \$clause,
                            object_ds => 'entry',
                            object_id => $e->id
                        }
                    )
                }
            );
            if (@assets) {
                my $a    = $assets[0];
                my $file = $a->file_path();
                if ( -r $file && -f $file ) {
                    $text .= $file . "\n";
                    if ( my $info = _read_info($a) ) {
                        my $date = $info->{'DateTimeOriginal'} || '';
                        $text .= '  Created: ' . $date . "\n";
                        if ($date) {
                            $date =~ s/[: ]//g;
                            $e->created_on($date);
                            $e->save;
                        }
                    }
                }
            }
        }
    }
    my $tmpl = $app->load_tmpl('dialog/upgrade.tmpl');
    $tmpl->param( blog_id => $blog->id );
    $tmpl->param( results => $text );
    return $app->build_page($tmpl);
}

sub upgrade {
    my $app  = shift;
    my $q    = $app->{query};
    my $blog = $app->blog;
    my $text = '';

    require MT::Asset::ImagePhoto;
    require File::MimeInfo;
    my @entries = MT->model('entry')->load( { blog_id => $blog->id } );
    foreach my $e (@entries) {
        $text .= "Processing " . $e->title . "<br />";
        my ( $alt, $src ) =
          ( $e->text =~ /<img alt="([^\"]*)" src="([^\"]*)"/ );
        ( my $orig = $src ) =~ s/-photo\./\./;
        my ($ext) = ( $alt =~ /\.([a-z]*)$/i );
        my $base  = $blog->site_path;
        my $url   = $blog->site_url;
        ( my $rel_path = $orig ) =~ s/^$url//;
        my $new_path = $base . $rel_path;
        my $exists   = -e $new_path;
        my $mime     = File::MimeInfo::mimetype($new_path);

        $text .= "  original: $orig<br>";
        $text .= "  relative path: $rel_path<br>";
        $text .= "  new path: $new_path<br>";
        $text .= "    file exists? " . ( $exists ? "yes" : "no" ) . "<br>";
        $text .= "    ext: $ext<br>";
        $text .= "    filename: $alt<br>";
        $text .= "    mime: $mime<br>";

        my $a = MT->model('asset.photo')->new;
        $a->blog_id( $e->blog_id );
        $a->label( $e->title );
        $a->created_on( $e->created_on );
        $a->created_by( $e->created_by );
        $a->url($orig);
        $a->file_path($new_path);
        $a->file_name($alt);
        $a->file_ext($ext);
        $a->mime_type($mime);

        #	$a->save();

        $e->text( $e->excerpt );
        $e->excerpt('');
        $e->text_more( $a->as_html );

        $e->title( $a->file_name );
        $e->text( $q->param('text') );
        $e->text_more( $a->as_html );
        $e->allow_comments( $q->param('allow_comments') );

        $e->save or die $e->errstr;

    }

    my $tmpl = $app->load_tmpl('dialog/upgrade.tmpl');
    $tmpl->param( blog_id => $blog->id );
    $tmpl->param( results => $text );
    return $app->build_page($tmpl);
}

sub start_upload {
    my $app  = shift;
    my $q    = $app->{query};
    my $blog = $app->blog;
    my $tmpl = $app->load_tmpl('dialog/start.tmpl');
    my $iter = MT->model('category')->load_iter( { blog_id => $blog->id } );
    my @category_loop;
    while ( my $cat = $iter->() ) {
        push @category_loop,
          {
            category_id       => $cat->id,
            category_label    => $cat->label,
            category_selected => ( $cat->id == $q->param('category_id') ),
          };
    }
    @category_loop =
      sort { $a->{category_label} cmp $b->{category_label} } @category_loop;

    $tmpl->param( blog_id       => $blog->id );
    $tmpl->param( finish        => $q->param('finish') );
    $tmpl->param( category_loop => \@category_loop );
    return $app->build_page($tmpl);
}

sub save_photo {
    my $app = shift;

    my $q = $app->{query};

    my $asset = MT->model('asset.photo')->load( $q->param('asset_id') );

    my $entry = MT->model('entry')->load( $q->param('entry_id') );
    $entry->title( $q->param('label') );
    $entry->text( $q->param('caption') );
    $entry->allow_comments( $q->param('allow_comments') eq "1" ? 1 : 0 );
    $entry->allow_pings(0);
    $entry->basename( dirify( $entry->title ) );
    $entry->add_tags( $q->param('tags') );

    my $author = $app->user;
    my $blog   = $app->blog;
    my $cb     = $author->text_format || $blog->convert_paras;
    $cb = '__default__' if $cb eq '1';
    $entry->convert_breaks($cb);

    require MT::Tag;
    my $tags      = $app->param('tags');
    my $tag_delim = chr( $app->user->entry_prefs->{tag_delim} );
    my @tags      = MT::Tag->split( $tag_delim, $tags );
    if (@tags) {
        $entry->set_tags(@tags);
    }
    if ( $q->param('publish_date') ) {
        $entry->authored_on( $q->param('publish_date') );
        $entry->created_on( $q->param('publish_date') );
    }
    $entry->save();

    # TODO - trigger rebuild
    $app->rebuild_entry( Entry => $entry, BuildDependencies => 1 );

    start_upload($app);
}

sub upload_photo {
    my $app    = shift;
    my $plugin = $app->instance;
    my $q      = $app->{query};

    # Indicates to overwrite any duplicate files with the same name
    # Note: these should only be turned on if the file has previously
    #       been determined to exist.
    #$q->param('overwrite_yes', 0);
    #$q->param('overwrite_no', 0);

    # Directs the app to use a custom path
    $q->param( 'site_path', '1' );

    # selected when and if the user is uploading files into their archives
    #$q->param('extra_path_archive', '');

    # the path to append to the local path site
    #$q->param('extra_path_site', 'uploaded_photos');

    # Present if there is a need to point to the location of the temp
    # file created during the upload process
    #$q->param('temp', '');

    my $cat;
    my $cat_id = $q->param('category_id');
    if ( $cat_id eq "__new" ) {
        my $cat_name = $q->param('new_album_name') || 'Untitled';
        $cat = MT->model('category')->new;
        $cat->label($cat_name);
        $cat->blog_id( $app->blog->id );
        $cat->save;
    }
    else {
        $cat = MT->model('category')->load( $cat_id, { cached_ok => 1 } );
    }
    $q->param( 'extra_path_site', dirify( $cat->label ) ) if $cat;

    # I didn't have the patience to do this right. I simply
    # copy-and-pasted the contents of MT::App::CMS::upload_file into
    # this subroutine. Lame. I know.
    my ( $fh, $no_upload );
    if ( $ENV{MOD_PERL} ) {
        my $up = $q->upload('file');
        $no_upload = !$up || !$up->size;
        $fh = $up->fh if $up;
    }
    else {
        ## Older versions of CGI.pm didn't have an 'upload' method.
        eval { $fh = $q->upload('file') };
        if ( $@ && $@ =~ /^Undefined subroutine/ ) {
            $fh = $q->param('file');
        }
        $no_upload = !$fh;
    }
    my $has_overwrite = $q->param('overwrite_yes') || $q->param('overwrite_no');
    return $app->error(
        $app->translate("You did not choose a file to upload.") )
      if $no_upload && !$has_overwrite;
    my $basename = $q->param('file') || $q->param('fname');
    $basename =~ s!\\!/!g;    ## Change backslashes to forward slashes
    $basename =~ s!^.*/!!;    ## Get rid of full directory paths
    if ( $basename =~ m!\.\.|\0|\|! ) {
        return $app->error(
            $app->translate( "Invalid filename '[_1]'", $basename ) );
    }
    my $blog_id = $q->param('blog_id');
    my $blog    = $app->blog;
    my $fmgr    = $blog->file_mgr;

    ## Set up the full path to the local file; this path could start
    ## at either the Local Site Path or Local Archive Path, and could
    ## include an extra directory or two in the middle.
    my ( $root_path, $relative_path, $relative_url, $base_url, $asset_base_url,
        $asset_file, $mimetype, $local_file );

    $root_path = $blog->site_path;
    $relative_path = archive_file_for( undef, $blog, 'Category', $cat );
    $relative_path =~ s/\/[a-z\.]*$//;

    my $relative_path_save = $relative_path;
    my $path               = $root_path;
    if ($relative_path) {
        if ( $relative_path =~ m!\.\.|\0|\|! ) {
            return $app->error(
                $app->translate( "Invalid extra path '[_1]'", $relative_path )
            );
        }
        $path = File::Spec->catdir( $path, $relative_path );
        ## Untaint. We already checked for security holes in $relative_path.
        ($path) = $path =~ /(.+)/s;
        ## Build out the directory structure if it doesn't exist. DirUmask
        ## determines the permissions of the new directories.
        unless ( $fmgr->exists($path) ) {
            $fmgr->mkpath($path)
              or return $app->error(
                $app->translate(
                    "Can't make path '[_1]': [_2]",
                    $path, $fmgr->errstr
                )
              );
        }
    }

    $relative_url =
      File::Spec->catfile( $relative_path, encode_url($basename) );
    $relative_path =
      $relative_path
      ? File::Spec->catfile( $relative_path, $basename )
      : $basename;
    $asset_file = $q->param('site_path') ? '%r' : '%a';
    $asset_file = File::Spec->catfile( $asset_file, $relative_path );
    $local_file = File::Spec->catfile( $path,       $basename );
    $base_url =
        $app->param('site_path')
      ? $blog->site_url
      : $blog->archive_url;
    $asset_base_url = $app->param('site_path') ? '%r' : '%a';

    ## Untaint. We have already tested $basename and $relative_path for
    ## security issues above, and we have to assume that we can trust the
    ## user's Local Archive Path setting. So we should be safe.
    ($local_file) = $local_file =~ /(.+)/s;

    ## If $local_file already exists, we try to write the upload to a
    ## tempfile, then ask for confirmation of the upload.
    if ( $fmgr->exists($local_file) and 0 ) {
        if ($has_overwrite) {
            my $tmp = $q->param('temp');
            if ( $tmp =~ m!([^/]+)$! ) {
                $tmp = $1;
            }
            else {
                return $app->error(
                    $app->translate( "Invalid temp file name '[_1]'", $tmp ) );
            }
            my $tmp_dir = $app->config('TempDir');
            my $tmp_file = File::Spec->catfile( $tmp_dir, $tmp );
            if ( $q->param('overwrite_yes') ) {
                $fh = gensym();
                open $fh, $tmp_file
                  or return $app->error(
                    $app->translate(
                        "Error opening '[_1]': [_2]",
                        $tmp_file, "$!"
                    )
                  );
            }
            else {
                if ( -e $tmp_file ) {
                    unlink($tmp_file)
                      or return $app->error(
                        $app->translate(
                            "Error deleting '[_1]': [_2]",
                            $tmp_file, "$!"
                        )
                      );
                }
                return $app->start_upload;
            }
        }
        else {
            eval { require File::Temp };
            if ($@) {
                return $app->error(
                    $app->translate(
                        "File with name '[_1]' already exists. (Install "
                          . "File::Temp if you'd like to be able to overwrite "
                          . "existing uploaded files.)",
                        $basename
                    )
                );
            }
            my $tmp_dir = $app->config('TempDir');
            my ( $tmp_fh, $tmp_file );
            eval {
                ( $tmp_fh, $tmp_file ) =
                  File::Temp::tempfile( DIR => $tmp_dir );
            };
            if ($@) {    #!$tmp_fh) {
                return $app->errtrans(
                    "Error creating temporary file; please check your TempDir "
                      . "setting in mt.cfg (currently '[_1]') "
                      . "this location should be writable.",
                    (
                          $tmp_dir
                        ? $tmp_dir
                        : '[' . $app->translate('unassigned') . ']'
                    )
                );
            }
            defined( MT::App::CMS::_write_upload( $fh, $tmp_fh ) )
              or return $app->error(
                $app->translate(
                    "File with name '[_1]' already exists; Tried to write "
                      . "to tempfile, but open failed: [_2]",
                    $basename,
                    "$!"
                )
              );
            my ( $vol, $path, $tmp ) = File::Spec->splitpath($tmp_file);
            return $app->build_page(
                $plugin->load_tmpl('upload_confirm.tmpl'),
                {
                    blog_id    => $blog->id,
                    blog_name  => $blog->name,
                    site_path  => '1',
                    temp       => $tmp,
                    extra_path => $relative_path_save,
                    site_path  => scalar $q->param('site_path'),
                    fname      => $basename
                }
            );
        }
    }

    ## File does not exist, or else we have confirmed that we can overwrite.
    my $umask = oct $app->config('UploadUmask');
    my $old   = umask($umask);
    defined( my $bytes = $fmgr->put( $fh, $local_file, 'upload' ) )
      or return $app->error(
        $app->translate(
            "Error writing upload to '[_1]': [_2]", $local_file,
            $fmgr->errstr
        )
      );
    umask($old);

    ## Use Image::Size to check if the uploaded file is an image, and if so,
    ## record additional image info (width, height). We first rewind the
    ## filehandle $fh, then pass it in to imgsize.
    seek $fh, 0, 0;
    eval { require Image::Size; };
    return $app->error(
        $app->translate(
                "Perl module Image::Size is required to determine "
              . "width and height of uploaded images."
        )
    ) if $@;
    my ( $w, $h, $id ) = Image::Size::imgsize($fh);

    ## Close up the filehandle.
    close $fh;

    ## If we are overwriting the file, that means we still have a temp file
    ## lying around. Delete it.
    if ( $q->param('overwrite_yes') ) {
        my $tmp = $q->param('temp');
        if ( $tmp =~ m!([^/]+)$! ) {
            $tmp = $1;
        }
        else {
            return $app->error(
                $app->translate( "Invalid temp file name '[_1]'", $tmp ) );
        }
        my $tmp_file = File::Spec->catfile( $app->config('TempDir'), $tmp );
        unlink($tmp_file)
          or return $app->error(
            $app->translate( "Error deleting '[_1]': [_2]", $tmp_file, "$!" ) );
    }

    ## We are going to use $relative_path as the filename and as the url passed
    ## in to the templates. So, we want to replace all of the '\' characters
    ## with '/' characters so that it won't look like backslashed characters.
    ## Also, get rid of a slash at the front, if present.
    $relative_path =~ s!\\!/!g;
    $relative_path =~ s!^/!!;
    $relative_url  =~ s!\\!/!g;
    $relative_url  =~ s!^/!!;

    my $url = $base_url;
    $url .= '/' unless $url =~ m!/$!;
    $url .= $relative_url;
    my $asset_url = $asset_base_url . '/' . $relative_url;

    require File::Basename;
    my $local_basename = File::Basename::basename($local_file);
    my $ext =
      ( File::Basename::fileparse( $local_file, qr/[A-Za-z0-9]+$/ ) )[2];

    if ( defined($w) && defined($h) ) {
        eval { require MT::Image; MT::Image->new or die; };
    }

    my $asset = MT->model('asset.photo')->new();
    $asset->label($local_basename);
    $asset->file_path($asset_file);
    $asset->file_name($local_basename);
    $asset->file_ext($ext);
    $asset->blog_id($blog_id);
    $asset->created_by( $app->user->id );
    $asset->save();

    my $original = $asset->clone;
    $asset->url($asset_url);
    $asset->image_width($w);
    $asset->image_height($h);
    $asset->mime_type($mimetype) if $mimetype;
    $asset->save;
    $app->run_callbacks( 'cms_post_save.asset', $app, $asset, $original );

    $app->run_callbacks(
        'cms_upload_file.' . $asset->class,
        File  => $local_file,
        file  => $local_file,
        Url   => $url,
        url   => $url,
        Size  => $bytes,
        size  => $bytes,
        Asset => $asset,
        asset => $asset,
        Type  => 'image',
        type  => 'image',
        Blog  => $blog,
        blog  => $blog
    );
    $app->run_callbacks(
        'cms_upload_image',
        File       => $local_file,
        file       => $local_file,
        Url        => $url,
        url        => $url,
        Size       => $bytes,
        size       => $bytes,
        Asset      => $asset,
        asset      => $asset,
        Height     => $h,
        height     => $h,
        Width      => $w,
        width      => $w,
        Type       => 'image',
        type       => 'image',
        ImageType  => $id,
        image_type => $id,
        Blog       => $blog,
        blog       => $blog
    );

    my $entry = MT->model('entry')->new;
    $entry->blog_id( $app->blog->id );
    $entry->status( MT->model('entry')::RELEASE() );
    $entry->author_id( $app->{author}->id );
    $entry->title( $asset->file_name );
    $entry->category_id( $cat->id );
    $entry->text( $q->param('text') );
    $entry->text_more( $asset->as_html );
    $entry->allow_comments( $q->param('allow_comments') );

    eval 'require Image::ExifTool';
    my $exif_date;
    if ( !$@ ) {
        my $info = _read_info($asset);
        my $date = $info->{'DateTimeOriginal'} || '';
        if ($date) {
            $date =~ s/[: ]//g;
            $entry->created_on($date);
            $exif_date = $date;
        }
    }

    $entry->save or die $entry->errstr;
    if (MT->version_number >= 4.3) {
        # this must be done because MT 4.3 no longer processes a form tag to associate
        # assets to posts
        my $map = MT->model('objectasset')->new;
        $map->blog_id($entry->blog_id);
        $map->asset_id($asset->id);
        $map->object_ds('entry');
        $map->object_id($entry->id);
        $map->save;
    }

    if ( $q->param('is_favorite') ) { $entry->add_tags( ['@favorite'] ); }

    ## Now that the object is saved, we can be certain that it has an
    ## ID. So we can now add/update/remove the primary placement.
    $app->delete_param('category_id');

    my $place =
      MT->model('placement')->load( { entry_id => $entry->id, is_primary => 1 } );
    if ( $cat->id ) {
        unless ($place) {
            $place = MT->model('placement')->new;
            $place->entry_id( $entry->id );
            $place->blog_id( $entry->blog_id );
            $place->is_primary(1);
        }
        $place->category_id( $cat->id );
        $place->save;
    }
    else {
        if ($place) {
            $place->remove;
        }
    }

    # save secondary placements...
    my @place = MT->model('placement')->load(
        {
            entry_id   => $entry->id,
            is_primary => 0
        }
    );
    for my $place (@place) {
        $place->remove;
    }

    my %arg;
    if ( $asset->image_width > $asset->image_height ) {
        $arg{Width} = 200;
    }
    else {
        $arg{Height} = 200;
    }
    my ( $url, $w, $h ) = $asset->thumbnail_url(%arg);

    my $tmpl = $app->load_tmpl('dialog/edit_photo.tmpl');
    $tmpl->param( blog_id     => $blog->id );
    $tmpl->param( entry_id    => $entry->id );
    $tmpl->param( fname       => $asset->label );
    $tmpl->param( thumbnail   => $url );
    $tmpl->param( asset_id    => $asset->id );
    $tmpl->param( is_image    => 1 );
    $tmpl->param( url         => $asset->url );
    $tmpl->param( category_id => $cat->id );
    $tmpl->param( has_exif    => $exif_date ? 1 : 0 );
    if ( $tmpl->param('has_exif') ) {

        my $info = _read_info($asset);
        $tmpl->param( caption => $info->{'ImageDescription'} || '' );
        $tmpl->param( artist  => $info->{'Artist'}           || '' );

        my $date_format = "%Y.%m.%d";
        my @ts = MT::Util::offset_time_list( time, $blog->id );
        my $ts = sprintf '%04d%02d%02d%02d%02d%02d', $ts[5] + 1900, $ts[4] + 1,
          @ts[ 3, 2, 1, 0 ];
        $tmpl->param( date_taken => $exif_date );
        $tmpl->param( date_today => $ts );
        $tmpl->param(
            date_taken_fmt => format_ts(
                $date_format, $exif_date, $app->blog,
                $app->user ? $app->user->preferred_language : undef
            )
        );
        $tmpl->param(
            date_today_fmt => format_ts(
                $date_format, $ts, $app->blog,
                $app->user ? $app->user->preferred_language : undef
            )
        );
    }

    #    $tmpl->param(middle_path   => $app->param('middle_path') || '');
    #    $tmpl->param(extra_path    => $app->param('extra_path') || '');
    return $app->build_page($tmpl);
}

1;
__END__
