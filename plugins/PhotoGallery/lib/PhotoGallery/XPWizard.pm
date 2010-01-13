# Copyright 2003-2005 Six Apart. This code cannot be redistributed without
# permission from www.sixapart.com.
#
# $Id$

package PhotoGallery::XPWizard;

use base qw( MT::App );
use strict;
use warnings;

#use MT::Gallery::Set;
#use MT::Gallery::Photo;
#use MT::Gallery::Publisher;
use File::Basename;

sub init {
    my $app = shift;
    $app->SUPER::init(@_) or return;
    $app->add_methods(
        'logout'       => \&logout,
        'welcome'      => \&welcome,
        'ready'        => \&ready,
        'new_album'    => \&new_album,
        'create_album' => \&create_album,
        'upload'       => \&upload,
        'reg_file'     => \&reg_file,
    );
    $app->{default_mode} = 'welcome';
    $app->{template_dir} = 'xp';
    $app;
}

#sub script { $_[0]->SUPER::script . '?__mode=xpwizard' }
sub parent_uri { $_[0]->path . $_[0]->SUPER::script }

sub is_authorized {
    $_[0]->{user}->has('xpwizard') && !$_[0]->{user}->status_is_suspended();
}

sub logout {
    my $app = shift;
    $app->SUPER::logout();
    $app->build_page( 'xp/login.tmpl', { logged_out => 1 } );
}

sub welcome { shift->build_page('xp/welcome.tmpl') }

sub ready {
    my $app    = shift;
    my $user   = $app->{user};
    my $set_id = $app->{query}->param('set_id') || 0;
    my $iter   = MT::Gallery::Set->load_iter( { user_id => $user->id } );
    my @sets;
    while ( my $set = $iter->() ) {
        next if $set->is_uncategorized;
        push @sets,
          {
            set_id       => $set->id,
            set_name     => $set->name,
            set_url      => $set->site_url,
            set_selected => $set_id == $set->id ? 1 : 0,
          };
    }
    my %param;
    $param{sets} = [ sort { $a->{set_name} cmp $b->{set_name} } @sets ];
    $app->build_page( 'xp/ready.tmpl', \%param );
}

sub new_album { shift->build_page('xp/new_album.tmpl') }

sub create_album {
    my $app  = shift;
    my $user = $app->{user};
    my $fmgr = $user->file_mgr or return $app->error( $user->errstr );

    my $q = $app->{query};
    my $name = $q->param('set_name') or return $app->error('No set_name');

    my $set = MT::Gallery::Set->new;
    $set->set_defaults;
    $set->set_design_defaults;
    $set->user_id( $user->id );
    $set->name( substr $name, 0, 50 );
    ## Build a unique directory name for the album.
    my $dirname = substr MT::Util::dirify( $set->name ), 0, 20;
    $dirname = 'album' if $dirname eq '';
    my $copy = $dirname;
    my $i    = 1;
    while ( $fmgr->exists( 'photos/' . $dirname ) ) {
        $dirname = $copy . '_' . $i++;
    }
    $set->dirname($dirname);
    $set->is_public( $q->param('set_is_public') ? 1 : 0 );
    $set->save
      or return $app->error( $set->errstr );

    # Commit the changes
    $set->commit;

    ## Republish index of albums.
    MT::Gallery::Publisher->publish_indexes( User => $app->{user} )
      or return $app->error( MT::Gallery::Publisher->errstr );
    ## Republish recent include, so includes on weblog etc don't break.
    MT::Gallery::Publisher->publish(
        Set  => $set,
        User => $app->{user},
        Only => { Recent => 1, Cover => 1 }
    ) or return $app->error( MT::Gallery::Publisher->errstr );

    $app->redirect( $app->uri . '?__mode=ready&set_id=' . $set->id );
}

sub upload {
    my $app  = shift;
    my $user = $app->{user};

    # Bail right away if they are over quota
    return $app->error('Over photo quota') if $user->photo_quota_exceeded;

    my $fh = $app->upload_fh('photo') or return;
    $app->upload_size('photo') or return;
    my $fname = $app->upload_filename('photo') or return;

    my $fmgr = $user->file_mgr or return $app->error( $user->errstr );

    my $q      = $app->{query};
    my $set_id = $q->param('set_id')
      or return $app->error('No set_id');
    my $set = MT::Gallery::Set->load($set_id);
    return $app->error('Permission denied')
      unless $set->user_id == $user->id;

    my $full =
      MT::Gallery::Photo->make_unique_filename( $set, $set->path . $fname );
    defined( $fmgr->put_data( $fh, $full, 'upload' ) )
      or return $app->error( $fmgr->errstr );
    seek $fh, 0, 0;    ## Rewind filehandle.
    my $photo =
      $set->add_photo( { filename => File::Basename::basename($full) }, $fh )
      or return $app->error( $set->errstr );

    # Commit the changes
    $photo->commit;

    MT::Gallery::Publisher->publish(
        Set   => $set,
        User  => $user,
        Photo => $photo,
    ) or return $app->error( MT::Gallery::Publisher->errstr );

    1;
}

sub reg_file {
    my $app = shift;
    my $uri = $app->base . $app->uri;
    $app->{no_print_body} = 1;
    $app->set_header(
        'Content-Disposition' => 'attachment; filename=wizard.reg' );
    $app->send_http_header('application/octet-stream; name=wizard.reg');
    $app->print( qq(Windows Registry Editor Version 5.00\r\n\r\n)
          . qq([HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\PublishingWizard\\PublishingWizard\\Providers\\PhotoGalleryPlugin]\r\n)
          . qq("Icon"="http://6a.typepad.com/favicon.ico"\r\n)
          . qq("DisplayName"="Photo Gallery"\r\n)
          . qq("Description"="A plugin for the Movable Type weblogging platform."\r\n)
          . qq("HREF"="$uri"\r\n) );
    1;
}

1;
