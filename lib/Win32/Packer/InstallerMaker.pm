package Win32::Packer::InstallerMaker;

use Path::Tiny;

use Moo;
use namespace::autoclean;

extends 'Win32::Packer::Base';

has _fs => ( is => 'ro', default => sub { {} } );

sub add_file {
    my $self = shift;
    my $from = shift;
    my $to = shift // $from->realpath->basename;

    $self->log->debug("Adding file '$from' as '$to'");

    $self->_add_obj($to, @_, type => 'file', path => $from);
}

sub add_tree {
    my $self = shift;
    my $from = shift;
    my $to = shift // path($from->realpath->basename);

    $self->log->debug("Adding dir '$from' as '$to'");

    $self->_add_tree($from, $to);
}

sub _add_tree {
    my ($self, $from, $to) = @_;

    if ($from->is_dir) {
        $self->_add_obj($to, type => 'dir');
        for my $c ($from->children) {
            $self->_add_tree($c, $to->child($c->basename));
        }
    }
    elsif ($from->is_file) {
        $self->_add_obj($to, type => 'file', path => $from);
    }
    else {
        $self->log->warn("Unsupported file system object at '$from'");
    }
}

sub _add_obj {
    my ($self, $to, %opts) = @_;
    return if $to eq '.' or $to eq '' or $to eq '/';

    my $parent = path($to)->parent;
    $self->_add_obj("$parent", type => 'dir');

    $self->_add_obj_norec($to, %opts);
}

sub _add_obj_norec {
    my ($self, $to, %opts) = @_;
    my $obj = $self->_fs->{$to} //= {};
    for my $k (keys %opts) {
        if (defined $opts{$k}) {
            if (defined $obj->{$k}) {
                $self->_die("fs object $to reinserted with a different value for $k: $opts{$k}, was: $obj->{$k}")
                    unless $obj->{$k} eq $opts{$k};
            }
            else {
                $obj->{$k} = $opts{$k}
            }
        }
    }
}

sub run {
    my $self = shift;
    $self->_dief("class %s does not implement virtual method run", ref $self);
}

1;
