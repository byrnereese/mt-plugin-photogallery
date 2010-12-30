package PhotoGallery::Plugin;

use strict;
use MT::Util qw(relative_date);

sub in_gallery {
    local $@;
    return 0 if !MT->instance->blog;
    my $ts  = MT->instance->blog->template_set;
    my $app = MT::App->instance;
    return $app->registry('template_sets')->{$ts}->{'photo_gallery'};
}

sub unless_gallery {
    return !in_gallery();
}

sub plugin {
    return MT->component('PhotoGallery');
}

sub type_galleries {
    my $app = shift;
    my ( $ctx, $field_id, $field, $value ) = @_;
    my $out;

    my @sets;
    my $all_sets = $app->registry('template_sets');
    foreach my $set ( keys %$all_sets ) {
        push @sets, $set
          if $app->registry('template_sets')->{$set}->{'photo_gallery'};
    }
    my @blogs = MT->model('blog')->search_by_meta( 'template_set', \@sets );
    if ( $#blogs < 0 ) {
        return
'<p>There is no blog in your system that utilizes a photo gallery template set.</p>';
    }
    $out .= "      <select name=\"$field_id\">\n";
    $out .=
        "        <option value=\"0\" "
      . ( 0 == $value ? " selected" : "" )
      . ">None Selected</option>\n";
    foreach (@blogs) {
        $out .=
            "        <option value=\""
          . $_->id . "\" "
          . ( $value == $_->id ? " selected" : "" ) . ">"
          . $_->name
          . "</option>\n";
    }
    $out .= "      </select>\n";
    return $out;
}

sub suppress_create {
    my ( $cb, $app, $html_ref ) = @_;
    return
      unless in_gallery
          && plugin()
          ->get_config_value( 'suppress_create_entry',
              'blog:' . $app->blog->id );
    $$html_ref =~ s{<li id="create-entry" class="nav-link">.*</a></li>}{};
}

sub load_list_filters {
    if ( in_gallery() ) {
        my $core  = MT->component('Core');
        my $fltrs = $core->{registry}->{applications}->{cms}->{list_filters};
        delete $fltrs->{'entry'};

        my $mt = MT->instance;
        my @cats = MT::Category->load( { blog_id => $mt->blog->id },
            { sort => 'label' } );
        my $reg;

        my $i = 0;
        $reg->{'entry'}->{'all'} = {
            label   => 'All Photos',
            order   => $i++,
            handler => sub {
                my ( $terms, $args ) = @_;
                $terms->{blog_id} = $mt->blog->id;
            },
        };
        foreach my $c (@cats) {
            $reg->{'entry'}->{ $c->basename } = {
                label   => $c->label,
                order   => $i++,
                handler => sub {
                    my ( $terms, $args ) = @_;
                    $terms->{category_id} = $c->id;
                    $terms->{blog_id}     = $c->blog_id;
                },
            };
        }
        return $reg;
    }
    return {};
}

sub load_menus {
    if ( in_gallery() ) {
        my $sc = MT->component('StyleCatcher');
        delete $sc->{registry}->{applications}->{cms}->{menus};

        my $core  = MT->component('Core');
        my $menus = $core->{registry}->{applications}->{cms}->{menus};
        delete $menus->{'manage:asset'};
        delete $menus->{'manage:ping'};
        foreach my $key ( keys %$menus ) {
            if ( $key =~ /^create:/ ) {
                my $blog = ( MT->instance->blog ? MT->instance->blog : undef );
                unless (
                       $key =~ /entry/
                    && $blog
                    && !plugin()->get_config_value(
                        'suppress_create_entry', 'blog:' . $blog->id
                    )
                  )
                {
                    delete $menus->{$key};
                }
            }
        }
        return {
            'create:photo' => {
                label      => 'Upload Photo',
                order      => 100,
                dialog     => 'PhotoGallery.start',
                view       => "blog",
                permission => 'create_post',
            },
            'manage:photo' => {
                label => "Photos",
                mode  => 'PhotoGallery.photos',
                order => 100,
            },
            'manage:entry'    => { order => 2200, },
            'manage:category' => {
                label      => "Albums",
                mode       => 'list_cat',
                order      => 6000,
                permission => 'edit_categories',
                view       => "blog",
            },
        };
    }
    return {};
}

sub xfrm_categories {
    return unless in_gallery();
    my ( $cb, $app, $output_ref ) = @_;
    $$output_ref =~ s/Create top level category/Create new photo album/g;
    $$output_ref =~
s/No categories could be found/Please create an album before uploading photos/g;
    $$output_ref =~ s/\bCategories\b/\bPhoto Albums\b/g;
    $$output_ref =~ s/\bYour category\b/\bYour photo album\b/g;
}

sub mode_delete {
    my $app = shift;
    $app->validate_magic or return;

    my @photos = $app->param('id');
    for my $entry_id (@photos) {
        my $e = MT->model('entry')->load($entry_id) or next;
        my $a = load_asset_from_entry($e);
        $e->remove();
        $a->remove();
    }
    $app->redirect(
        $app->uri(
            'mode' => 'PhotoGallery.photos',
            args   => {
                blog_id => $app->blog->id,
                deleted => 1,
            }
        )
    );
}

sub mode_edit {
    my $app   = shift;
    my %param = @_;
    my $q     = $app->{query};

    my $obj   = MT->model('entry')->load( $q->param('id') );
    my $asset = load_asset_from_entry($obj);

    my %arg;
    if ( $asset->image_width > $asset->image_height ) {
        $arg{Width} = 200;
    }
    else {
        $arg{Height} = 200;
    }
    my ( $url, $w, $h ) = $asset->thumbnail_url(%arg);

    my $tmpl = $app->load_tmpl('dialog/edit_photo.tmpl');
    $tmpl->param( blog_id        => $app->blog->id );
    $tmpl->param( entry_id       => $obj->id );
    $tmpl->param( fname          => $obj->title );
    $tmpl->param( caption        => $obj->text );
    $tmpl->param( allow_comments => $obj->allow_comments );
    $tmpl->param( thumbnail      => $url );
    $tmpl->param( asset_id       => $asset->id );
    $tmpl->param( is_image       => 1 );
    $tmpl->param( url            => $asset->url );
    $tmpl->param( category_id    => $obj->category->id );

    my $tag_delim = chr( $app->user->entry_prefs->{tag_delim} );
    my $tags = MT->model('tag')->join( $tag_delim, $obj->tags );
    $tmpl->param( tags => $tags );

    return $app->build_page($tmpl);
}

sub mode_manage {
    my $app   = shift;
    my $q     = $app->{query};
    my %param = @_;

    if ( !in_gallery() ) {
        $app->return_to_dashboard( redirect => 1 );
    }
    my $code = sub {
        my ( $obj, $row ) = @_;
        $row->{'title'}   = $obj->title;
        $row->{'caption'} = $obj->text;

        my $asset = load_asset_from_entry($obj);
        if ($asset && ($asset->isa('MT::Asset::Photo') || $asset->isa('MT::Asset::Image')) ) {
            my %arg;
            if ( $asset->image_width > $asset->image_height ) {
                $arg{Width} = 110;
            }
            else {
                $arg{Height} = 110;
            }
            my ( $url, $w, $h ) = $asset->thumbnail_url(%arg);
            $row->{'thumb_url'} = $url;
            $row->{'thumb_w'}   = $w;
            $row->{'thumb_h'}   = $h;
            $row->{'photo_id'}  = $obj->id;
            $row->{'photo'}     = $asset->url;
        }
        else {
            $row->{'thumb_url'} = File::Spec->catfile(
                $app->static_path, "plugins",
                "PhotoGallery",    "text-icon.gif"
            );
            $row->{'thumb_w'}  = 142;
            $row->{'thumb_h'}  = 133;
            $row->{'entry_id'} = $obj->id;
        }
        my $ts = $row->{created_on};
        $row->{date} = relative_date( $ts, time );
    };

    my %terms = ( blog_id => $app->blog->id, );

    my %args = (
        sort      => 'created_on',
        direction => 'descend',
    );

    my %params = ( deleted => $q->param('deleted'), );

    my $plugin = MT->component('PhotoGallery');

    $app->listing(
        {
            type           => 'entry',    # the ID of the object in the registry
            terms          => \%terms,
            args           => \%args,
            listing_screen => 1,
            code           => $code,
            template => $plugin->load_tmpl('manage.tmpl'),
            params   => \%params,
        }
    );
}

sub load_asset_from_entry {
    my ($obj) = @_;
    my $join = '= asset_id';
    my $asset = MT->model('asset')->load(
        { class => '*' },
        {
            lastn => 1,
            join  => MT->model('objectasset')->join_on(
                undef,
                {
                    asset_id  => \$join,
                    object_ds => 'entry',
                    object_id => $obj->id
                }
            )
        }
    );
    return $asset;
}

1;
