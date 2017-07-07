package Win32::Packer::InstallerMaker::dir;

use Path::Tiny;
use Win32::Packer::Helpers qw(mkpath);

use Moo;
use namespace::autoclean;

extends 'Win32::Packer::InstallerMaker';

has target_dir => (is => 'lazy', coerce => \&mkpath);

sub _build_target_dir {
    my $self = shift;
    my $basename = join '-', grep defined, $self->app_name, $self->app_version;
    $self->output_dir->child($basename);
}

sub run {
    my $self = shift;

    my $target_dir = $self->target_dir;

    my $fs = $self->_fs;
    for my $to (sort keys %$fs) {
        my $topto = $target_dir->child($to);
        my $obj = $fs->{$to};
        my $type = $obj->{type};
        $self->log->trace("Adding object '$topto' of type $type");
        if ($type eq 'dir') {
            $topto->mkpath;
        }
        elsif ($type eq 'file') {
            path($obj->{path})->copy($topto);
        }
        else {
            $self->log->warn("Unknown file system object type '$type' for '$topto', ignoring it");
        }
    }
    $self->log->info("Application copied to directory $target_dir");
}

1;
