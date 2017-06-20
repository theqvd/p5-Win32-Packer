package Win32::Packer;

our $VERSION = '0.01';

use 5.010;
use strict;
use warnings;
use Carp;
use Log::Any;
use Path::Tiny;
use Module::ScanDeps ();
use Text::CSV_XS ();
use Data::Dumper;
use Moo;

sub __to_list;
sub __to_path_list;
sub __get_windows_directory;
sub __temp_dir;
sub __assert_dir;
sub __assert_file;
sub __merge_opts;

has _OS            => ( is => 'ro',
                        isa => sub { $_[0] =~ /^MSWin32/i or croak "Unsupported OS" },
                        default => sub { $^O } );
has log            => ( is => 'ro', default => sub { Log::Any->get_logger } );
has extra_modules  => ( is => 'ro', coerce => \&__to_list, default => sub { [] } );
has extra_inc      => ( is => 'ro', coerce => \&__to_list, default => sub { [] } );
has script         => ( is => 'ro', coerce => \&__to_path_list, default => sub { [] },
                        isa => sub { @{$_[0]} > 0 or croak "script argument missing" } );
has extra_exe      => ( is => 'ro', coerce => \&__to_path_list, default => sub { [] } );
has workdir        => ( is => 'lazy', default => \&__temp_dir );
has perl_exe       => ( is => 'lazy', isa => \&__assert_file,
                        default => sub { path($^X)->realpath } );
has strawberry     => ( is => 'lazy', isa => \&__assert_dir,
                        default => sub { shift->perl_exe->parent->parent->parent } );
has windows        => ( is => 'lazy', isa => \&__assert_dir,
                        default => \&__windows_directory );
has inc            => ( is => 'lazy', coerce => \&__to_list,
                        default => sub { [@{shift->extra_inc}, @INC] });
has scan_deps_opts => ( is => 'ro', default => sub { {} } );

sub _trace { shift->log->trace(@_) }

sub build {
    my $self = shift;

    $self->_scan_deps;
}

sub _module2file {
    my $self = shift;
    my $module = shift;
    my $file = $module;
    $file =~ s/::/\//g;
    $file .= ".pm";
    my @inc = @{$self->inc};
    for my $inc (@inc) {
        my $path = path($inc)->child($file)->stringify;
        if (-f $path) {
            $self->log->trace("module '$module' converted to path '$path'");
            return $path;
        }
    }
    croak "Module $module not found (inc: " . join(', ', @inc) . ")";
}

sub _scan_deps {
    my $self = shift;
    my %opts = ( files => [ map($_->{path}, $self->script),
                            map($self->_module2file($_), @{$self->modules}) ],
                 recurse => 1 );
    local @Module::ScanDeps::IncludeLibs = @{$self->inc};

    my $deps = scan_deps(__merge_opts($self->scan_deps_opts, %opts);
}




# helper functions
sub __assert_dir  { -d $_[0] or croak "$_[0] is not a directory" }
sub __assert_file { -f $_[0] or croak "$_[0] is not a file" }
sub __temp_dir { Path::Tiny->tempdir("w32p-XXXXXX", CLEANUP => 0) }
sub __to_list {
    return $_[0] if ref $_[0] eq 'ARRAY';
    return [$_[0]] if defined $_[0];
    []
}
sub __to_path_list {
    my $arg = shift;
    my @list = (ref $arg eq 'ARRAY' ? @$arg :
                defined $arg        ? $arg  : ());
    [ map { ref $_ eq 'HASH' ? { %$_ } : { path => $_ } } @list ]
}
sub __windows_directory {
    require Win32::API;
    state $fn = Win32::API->new("KERNEL32","GetWindowsDirectoryA","PN","N");
    my $buffer = "\0" x 255;
    $fn->Call($buffer, length $buffer);
    $buffer =~ tr/\0//d;
    path($buffer)->realpath;
}

sub __merge_opts {
    my ($defs, %opts) = @_;
    for my $k (keys %$defs) {
        my $v = $opts{$k};
        if (defined $v) {
            ref $v eq 'ARRAY' and $opts{$k} = [@$v, @{$defs{$k}}];
        }
        else {
            $opts{$k} = $defs{$k};
        }
    }
    %opts
}

1;
__END__
# Below is stub documentation for your module. You'd better edit it!

=head1 NAME

Win32::Packer - Perl extension for blah blah blah

=head1 SYNOPSIS

  use Win32::Packer;
  blah blah blah

=head1 DESCRIPTION

Stub documentation for Win32::Packer, created by h2xs. It looks like the
author of the extension was negligent enough to leave the stub
unedited.

Blah blah blah.

=head2 EXPORT

None by default.



=head1 SEE ALSO

Mention other useful documentation such as the documentation of
related modules or operating system documentation (such as man pages
in UNIX), or any relevant external documentation such as RFCs or
standards.

If you have a mailing list set up for your module, mention it here.

If you have a web site set up for your module, mention it here.

=head1 AUTHOR

Salvador Fandiño, E<lt>salva@E<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2017 by Salvador Fandiño

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.24.1 or,
at your option, any later version of Perl 5 you may have available.


=cut
