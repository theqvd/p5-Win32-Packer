package Win32::Packer::InstallerMaker::msi;

use Win32::Packer::Helpers qw(guid);

use XML::LibXML;

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

    my $count = 0;
    my $ns = 'http://schemas.microsoft.com/wix/2006/wi';
    my $doc = XML::LibXML::Document->new('1.0', 'utf-8');

    my $ne = sub {
        my $name = shift;
        my $e = $doc->createElementNS($ns, $name);
        while (@_) {
            my ($k, $v) = splice @_, 0, 2;
            $e->setAttribute($k, $v) if defined $v;
        }
        $e
    };

    $doc->setDocumentElement(my $wxs = $ne->('Wxs'));
    $wxs->appendChild(my $product = $ne->('Product',
                                          Name => $self->versioned_app_name,
                                          Id => $self->app_id,
                                          Manufacturer => $self->app_vendor,
                                          Version => $self->app_version,
                                          Language => '1033', Codepage => '1252'));

    $product->appendChild($ne->('Package',
                                Description => $self->app_description,
                                Keywords => $self->app_keywords,
                                Comments => $self->app_comments,
                                Manufacturer => $self->app_vendor,
                                InstallerVersion => '0',
                                Languages => '1033',
                                Compressed => 'yes',
                                SummaryCodepage => '1252'));

    $product->appendChild($ne->('MediaTemplate', EmbedCab => 'yes'));

    if (defined(my $icon = $self->icon)) {
        $product->appendChild($ne->('Icon', Id => 'Icon.exe', SourceFile => $icon));
    }

    $product->appendChild(my $d0 = $ne->('Directory', Id => 'TARGETDIR', Name => 'SourceDir'));
    $d0->appendChild(my $d1 = $ne->('Directory', Id => 'ProgramFilesFolder', Name => 'PFiles'));
    $d1->appendChild(my $d2 = $ne->('Directory', Id => 'INSTALLDIR', Name => $self->app_name));

    my $fs = $self->_fs;
    for my $to (sort keys %$fs) {
        $self->log->debug("skipping $to"), next if $to =~ m|[/\\]|;
        my $obj = $fs->{$to};
        $self->log->debug("skipping not a file $to"), next unless $obj->{type} eq 'file';
        $count++;
        $d2->appendChild(my $c = $ne->('Component', Id => "File$count", Guid => guid));
        $c->appendChild($ne->('File', Name => $to, Source => $obj->{path}->canonpath));
    }

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
