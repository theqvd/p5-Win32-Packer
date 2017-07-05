package Win32::Packer::InstallerMaker;

use Moo;
extends 'Win32::Packer::Base';

has _fs_obj => ( is => 'ro', default => sub { {} } );

sub add_file {
    my $self = shift;
    my $from = shift;
    my $to = shift // $from->realpath->basename;

    $self->log->debug("Adding file '$from' to '$to'");

    $self->_add_file($from, $to);
}

sub add_tree {
    my $self = shift;
    my $from = shift;
    my $to = shift // path($from->realpath->basename);

    $self->log->debug("Adding dir '$from' to '$to'");

    $self->_add_tree($from, $to);
}

sub _add_tree {
    my ($self, $from, $to) = @_;

    if ($from->is_dir) {
        $self->_add_dir($from, $to);
        for my $c ($from->children) {
            $self->_add_tree($c, $to->child($c->basename));
        }
    }
    elsif ($from->is_file) {
        $self->_add_file($from, $to);
    }
    else {
        $self->log->warn("Unsupported file system object at '$from'");
    }
}

sub _add_dir {
    my ($self, $from, $to) = @_;
}

sub _add_file {
    my ($self, $from, $to) = @_;
}



1;
