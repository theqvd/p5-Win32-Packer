package Win32::Packer::InstallerMaker::msi;

use Win32::Packer::Helpers qw(guid);

use XML::FromPerl qw(xml_from_perl);
use Path::Tiny;
use Win32 ();
use Moo;
use namespace::autoclean;

extends 'Win32::Packer::InstallerMaker';

has _wxs => (is => 'lazy');
has _wixobj => ( is => 'lazy' );
has _msi => ( is => 'lazy' );

has wix_dir => ( is => 'lazy' );

has wxs_fn  => ( is => 'lazy' );
has wixobj_fn => ( is => 'lazy' );

has versioned_app_name => (is => 'lazy');

has wix_toolset => ( is => 'lazy' );

has candle_exe => ( is => 'lazy' );
has light_exe => ( is => 'lazy' );

has msi_fn => ( is => 'lazy' );

sub _build_msi_fn {
    my $self = shift;
    my $basename = join '-', grep defined, $self->app_name, $self->app_version;
    $self->output_dir->child("$basename.msi");
}

sub _build_wix_toolset {
    my $self = shift;
    my $pfiles = Win32::GetFolderPath(Win32::CSIDL_PROGRAM_FILES()) // 'C:\\Program Files\\';
    my @c = path($pfiles)->children(qr/Wix\s+Toolset\b/i);
    $c[0] // $self->_die("Wix Toolset not found in '$pfiles'");
}

sub _build_candle_exe { shift->wix_toolset->child('bin/candle.exe') }

sub _build_light_exe { shift->wix_toolset->child('bin/light.exe') }

sub _build_versioned_app_name {
    my $self = shift;
    join ' ', grep defined, $self->app_name, $self->app_version;
}

sub _build_wix_dir {
    my $self = shift;
    my $wix_dir = $self->work_dir->child('wix');
    $wix_dir->mkpath;
    $wix_dir;
}

sub _build_wixobj_fn {
    my $self = shift;
    $self->wix_dir->child($self->app_name . ".wixobj");
}

sub _build_wxs_fn {
    my $self = shift;
    $self->wix_dir->child($self->app_name . ".wxs");
}

sub _build__wxs {
    my $self = shift;

    my $data = [ Wix => { xmlns => 'http://schemas.microsoft.com/wix/2006/wi' },
                 my $product =
                 [ Product => { Name => $self->versioned_app_name,
                                Id => $self->app_id,
                                Manufacturer => $self->app_vendor,
                                Version => $self->app_version,
                                Language => '1033', Codepage => '1252' },
                   [ Package => { Description => $self->app_description,
                                  Keywords => $self->app_keywords,
                                  Comments => $self->app_comments,
                                  Manufacturer => $self->app_vendor,
                                  InstallerVersion => '405',
                                  Languages => '1033',
                                  Compressed => 'yes',
                                  SummaryCodepage => '1252' } ],
                   [ MediaTemplate => { EmbedCab => 'yes' } ],
                   my $target_dir = 
                   [ Directory => { Id => 'TARGETDIR', Name => 'SourceDir' },
                     [ Directory => { Id => 'ProgramFilesFolder', Name => 'PFiles' },
                       my $install_dir =
                       [ Directory => { Id => 'INSTALLDIR', Name => $self->app_name } ]]],
                   my $feature = 
                   [ Feature => { Id => 'MainProduct',
                                  Title => 'Main Product',
                                  Level => '1' } ] ] ];

    if (defined (my $icon = $self->icon)) {
        push @$product, ( [ Icon => { Id => 'Icon.ico', SourceFile => $icon } ],
                          [ Property => { Id => "ARPPRODUCTICON", Value => "Icon.ico" } ] );
    }

    my %dir = ('.' => $install_dir);
    my %dir_id = ('.' => 'INSTALLDIR');

    my $count = 0;
    my $fs = $self->_fs;
    my $menu_dir;
    for my $to (sort keys %$fs) {
        my $obj = $fs->{$to};
        my $parent = path($to)->parent;
        my $basename = path($to)->basename;
        my $type = $obj->{type};
        my $id = join '_', $count++, $basename;
        $id =~ s/\W/_/g;
        my $e;
        if ($type eq 'dir') {
            $dir{$to} = $e = [ Directory => { Id => "dir_$id",
                                              Name => $basename }];
            $dir_id{$to} = "dir_$id";
        }
        elsif ($type eq 'file') {
            $e = [ Component => { Id => "component_$id", Guid => guid },
                   [ File => { Name => $basename, Source => path($obj->{path})->canonpath, Id => "file_$id" } ] ];
            push @$feature, [ ComponentRef => { Id => "component_$id" }];

            if (defined(my $shortcut = $obj->{shortcut})) {
                unless (defined $menu_dir) {
                    $menu_dir = [ Directory => { Id => 'ProgramMenuFolder' } ];
                    push @$target_dir, [ Directory => { Id => 'ProgramMenuFolder' },
                                         $menu_dir =
                                         [ Directory => { Id => 'MyshortcutsDir',
                                                          Name => $self->app_name } ] ];
                }

                $count++;
                my $id = join '_', $count++, $basename;
                $id =~ s/\W/_/g;

                push @$menu_dir, [ Component => { Id => "component_$id", Guid => guid },
                                   [ Shortcut => { Id => "shortcut_$id",
                                                   Name => $shortcut,
                                                   Description => $shortcut,
                                                   Target => "[$dir_id{$parent}]$basename" } ],
                                   [ RemoveFolder => { Id => "remove_$id", On => 'uninstall' } ],
                                   [ RegistryValue => { Root => 'HKCU',
                                                        Key => join('\\', 'Software', $self->app_vendor, $self->app_name),
                                                        Name => 'installed',
                                                        Type => 'integer',
                                                        Value => '1',
                                                        KeyPath => 'yes' } ] ];
                push @$feature, [ ComponentRef => { Id => "component_$id" } ];
            }
        }
        else {
            $self->log->warn("Unknown object type '$type' for '$to', ignoring...");
            next;
        }
        my $parent_dir = $dir{$parent} // $self->_die("Parent directory '$parent' for '$to' not found");
        push @{$parent_dir}, $e;
    }

    my $doc = xml_from_perl $data;
    my $wxs_fn = $self->wxs_fn;
    $doc->toFile($wxs_fn, 2);
    $self->log->debug("Wxs file created at '$wxs_fn'");
    $wxs_fn
}

sub _build__wixobj {
    my $self = shift;
    my $out = $self->wixobj_fn;
    my $in = $self->_wxs;

    my $rc = $self->_run_cmd($self->candle_exe, $in, -out => $out)
        or $self->_die("unable to compile wxs file '$in'");
    $out;
}

sub _build__msi {
    my $self = shift;
    my $out = $self->msi_fn;
    my $in = $self->_wixobj;

    my $rc = $self->_run_cmd($self->light_exe, $in, -out => $out)
        or $self->_die("unable to link wixobj file '$in'");
    $out
}

sub run {
    my $self = shift;
    my $wxs = $self->_msi;
}

1;
