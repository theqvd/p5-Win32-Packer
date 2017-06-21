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

use Win32::Packer::WrapperCCode;
use Win32::Packer::LoadPLCode;

use Moo;


sub __to_bool;
sub __to_list;
sub __to_path_list;
sub __get_windows_directory;
sub __temp_dir;
sub __assert_dir;
sub __assert_file;
sub __assert_file_name;
sub __mkpath;
sub __merge_opts;

has _OS            => ( is => 'ro',
                        isa => sub { $_[0] =~ /^MSWin32/i or croak "Unsupported OS" },
                        default => sub { $^O } );
has log            => ( is => 'ro', default => sub { Log::Any->get_logger } );
has extra_modules  => ( is => 'ro', coerce => \&__to_list, default => sub { [] } );
has extra_inc      => ( is => 'ro', coerce => \&__to_list, default => sub { [] } );
has scripts        => ( is => 'ro', coerce => \&__to_path_list, default => sub { [] },
                        isa => sub { @{$_[0]} > 0 or croak "scripts argument missing" } );
has extra_exe      => ( is => 'ro', coerce => \&__to_path_list, default => sub { [] } );
has work_dir       => ( is => 'lazy', coerce => \&__mkpath, isa => \&__assert_dir );
has perl_exe       => ( is => 'lazy', isa => \&__assert_file,
                        default => sub { path($^X)->realpath } );
has strawberry     => ( is => 'lazy', isa => \&__assert_dir,
                        default => sub { shift->perl_exe->parent->parent->parent } );
has windows        => ( is => 'lazy', isa => \&__assert_dir,
                        default => \&__windows_directory );
has inc            => ( is => 'lazy', coerce => \&__to_list,
                        default => sub { [@{shift->extra_inc}, @INC] });
has scan_deps_opts => ( is => 'ro', default => sub { {} } );
has thick_scan     => ( is => 'ro', coerce => \&__to_bool );
has cache          => ( is => 'ro', coerce => \&__mkpath, isa => \&__assert_dir) ;
has clean_cache    => ( is => 'ro', coerce => \&__to_bool );
has app_name       => ( is => 'ro', default => sub { 'PerlApp' },
                        isa => \&__assert_file_name );
has _app_dir       => ( is => 'lazy', coerce => \&__mkpath,
                        isa => \&__assert_dir );
has keep_work_dir  => ( is => 'ro', coerce => \&__to_bool, default => sub { 0 } );
has output_dir     => ( is => 'ro', coerce => \&__mkpath, isa => \&__assert_dir,
                        default => sub { path('.')->realpath->stringify } );

has gcc_exe        => ( is => 'ro', isa => \&__assert_file } );
has ld_exe         => ( is => 'ro', isa => \&__assert_file } );

sub _build_gcc_exe {
    my $self = shift;
    path($self->strawberry)->child("c/gcc.exe")->realpath->stringify
}

sub _build_ld_exe {
    my $self = shift;
    path($self->strawberry)->child("c/ld.exe")->realpath->stringify
}

sub _build_work_dir {
    my $self = shift;
    my $keep = $self->keep_work_dir;
    $self->log->debug("would keep work dir") if $keep;
    my $p = Path::Tiny->tempdir("Win32-Packer-XXXXXX", CLEANUP => !$keep )->stringify;
    $self->log->debug("work dir: $p");
    $p
}

sub _build__app_dir {
    my $self = shift;
    my $p = path($self->work_dir)->child('app')->child($self->app_name);
    $p->mkpath;
    $p->realpath->stringify;
}

sub _die { croak shift->fatal(@_ ? join(': ', @_) : $@) }

sub build {
    my $self = shift;
    $self->_clean_work_dir;
    $self->_do_clean_cache if $self->clean_cache;
    my $deps = $self->_scan_deps;
    $self->_populate_app_dir($deps);
}

sub _do_clean_cache {
    my $self = shift;
    if (defined (my $cache = $self->cache)) {
        $self->log->debug("deleting cache");
        path($cache)->remove_tree({safe => 0, keep_root => 1});
    }
    else {
        $self->warn("clean_cache is set but cache directory is not defined");
    }
}

sub _scan_deps {
    my $self = shift;

    $self->log->info("Calculating dependencies...");
    my $rv = {};
    do {
        $self->log->tracef("inc: %s, extra modules: %s, scripts: %s", $self->inc, $self->extra_modules, $self->scripts);
        local @Module::ScanDeps::IncludeLibs = @{$self->inc};
        $rv = Module::ScanDeps::add_deps(rv => $rv,
                                         modules => $self->extra_modules);

        my @more_args;
        push @more_args, cache_file => path($self->cache)->child('module_scan_deps.cache')->stringify
            if defined $self->cache;
        $rv = Module::ScanDeps::scan_deps(__merge_opts($self->scan_deps_opts,
                                                       rv => $rv,
                                                       recurse => 1,
                                                       files => [ map($_->{path}, @{$self->scripts})],
                                                       @more_args));
    };

    if ($self->thick_scan) {
        $self->_die('Thick scan nimplemented');
    }

    $self->log->debugf("dependencies: %s", $rv);

    # print STDERR Data::Dumper::Dumper($rv);

    $rv
}

sub _clean_work_dir {
    my $self = shift;
    $self->log->debug("cleaning work dir");
    path($self->work_dir)->remove_tree({safe => 0, keep_root => 1});
}

sub _populate_app_dir {
    my ($self, $deps) = @_;

    my $app_dir = path($self->_app_dir);

    $self->log->info("Populating app dir ($app_dir)...");

    my $lib_dir = $app_dir->child('lib');
    $lib_dir->mkpath;

    for my $dep (values %$deps) {
        my $path = path($dep->{file})->realpath;
        my $to = $lib_dir->child($dep->{key});
        $self->log->debugf("copying '%s' to '%s'", $path, $to);
        $to->parent->mkpath;
        $path->copy($to);
    }

    my @scripts = @{$self->scripts};
    if (@scripts) {
        my $scripts_dir = $app_dir->child('scripts');
        $scripts_dir->mkpath;

        my $wrapper_c = $self->_make_wrapper_c;
        my $wrapper_obj = $self->_make_wrapper_obj($wrapper_c);

        for my $script (@scripts) {
            my $path = path($script->{path})->realpath;
            my $basename = $path->basename;
            $basename =~ s/(?:\.\w+)?$//;
            my $to = $scripts_dir->child("$basename.pl");
            $self->log->debugf("copying '%s' to '%s'", $path, $to);
            $path->copy($to);

            my $wrapper = $self->_make_wrapper("$basename.exe", %$script);
            my $wrapper_to = $app_dir->child("$basename.exe");
            $self->log->debugf("copying '%s' to '%s'", $wrapper, $wrapper_to);

        }

        $self->_copy_load_pl;
    }
}

sub _wrapper_dir {
    my $self = shift;
    my $wd = path($self->work_dir)->wrapper;
    $wd->mkpath;
    $wd->realpath->stringify
}

sub make_wrapper_c {
    my $self = shift;
    my $wrapper_dir = $self->_wrapper_dir;
    my $p = path($wrapper_dir)->child("wrapper.c");
    $p->spew($wrapper_c_code);
    $p->realpath->stringify;
}

sub make_wrapper_obj {
    my ($self, $wrapper_c) = @_;
    my $wrapper_dir = $self->_wrapper_dir;
    my $p = path($wrapper_dir)->child("wrapper.obj");
    system 
}



sub _make_wrapper_exe {
    my ($self, $obj, %opts) = @_;

}

# helper functions
sub __assert_file { -f $_[0] or croak "$_[0] is not a file" }
sub __assert_file_name { $_[0] =~ tr{<>:"/\\|?*}{} and croak "$_[0] is not a valid Windows file name" }
sub __assert_dir  { -d $_[0] or croak "$_[0] is not a directory" }
sub __mkpath {
    my $p = path($_[0])->realpath;
    $p->mkpath;
    "$p"
}

sub __to_bool { $_[0] ? 1 : 0 }
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
            ref $v eq 'ARRAY' and $opts{$k} = [@$v, @{$defs->{$k}}];
        }
        else {
            $opts{$k} = $defs->{$k};
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
