package Win32::Packer::InstallerMaker::msi;

use Win32::Packer::Helpers qw(guid);

use XML::FromPerl qw(xml_from_perl);

use Moo;
use namespace::autoclean;

extends 'Win32::Packer::InstallerMaker';

has _wxs => (is => 'lazy');

has wxs_dir => ( is => 'lazy' );
has wxs_fn  => ( is => 'lazy' );

has versioned_app_name => (is => 'lazy');

sub _build_versioned_app_name {
    my $self = shift;
    join ' ', grep defined, $self->app_name, $self->app_version;
}

sub _build_wxs_dir {
    my $self = shift;
    my $wxs_dir = $self->work_dir->child('wxs');
    $wxs_dir->mkpath;
    $wxs_dir;
}

sub _build_wxs_fn {
    my $self = shift;
    my $wxs_dir = $self->wxs_dir;
    $wxs_dir->child($self->app_name . ".wxs");
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
                                  InstallerVersion => '0',
                                  Languages => '1033',
                                  Compressed => 'yes',
                                  SummaryCodepage => '1252' } ],
                   [ Media => { Id => '1', Cabinet => 'media1.cab' } ],
                   [ Directory => { Id => 'TARGETDIR', Name => 'SourceDir' },
                     [ Directory => { Id => 'ProgramFilesFolder', Name => 'PFiles' },
                       my $install_dir =
                       [ Directory => { Id => 'INSTALLDIR', Name => $self->app_name } ] ]]] ];

    if (defined (my $icon = $self->icon)) {
        push @$product, [ Icon => { Id => 'Icon.exe', SourceFile => $icon } ]
    }

    my $count = 0;
    my $fs = $self->_fs;
    for my $to (sort keys %$fs) {
        $self->log->debug("skipping $to"), next if $to =~ m|[/\\]|;
        my $obj = $fs->{$to};
        $self->log->debug("skipping not a file $to"), next unless $obj->{type} eq 'file';
        $count++;
        push @$install_dir, [ Component => { Id => "File$count", Guid => guid },
                              [ File => { Name => $to, Source => $obj->{path}->canonpath } ] ];
    }

    my $doc = xml_from_perl $data;
    my $wxs_fn = $self->wxs_fn;
    $doc->toFile($wxs_fn, 2);
    $self->log->debug("Wxs file created at '$wxs_fn'");
    $wxs_fn
}

sub run {
    my $self = shift;
    my $wxs = $self->_wxs;
}

1;
