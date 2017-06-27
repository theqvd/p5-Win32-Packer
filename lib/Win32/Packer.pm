package Win32::Packer;

our $VERSION = '0.01';

use 5.010;
use strict;
use warnings;
use Carp;
use Log::Any;
use Path::Tiny;
use Module::ScanDeps;
use Text::CSV_XS ();
use Data::Dumper;
use Config;
use Capture::Tiny qw(capture);
use Win32::Ldd qw(pe_dependencies);

use Win32::Packer::WrapperCCode;
use Win32::Packer::LoadPLCode;
our ($wrapper_c_code, $load_pl_code);

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

has _OS            => ( is => 'ro',
                        isa => sub { $_[0] =~ /^MSWin32/i or croak "Unsupported OS" },
                        default => sub { $^O } );
has log            => ( is => 'ro', default => sub { Log::Any->get_logger } );
has extra_modules  => ( is => 'ro', coerce => \&__to_list, default => sub { [] } );
has extra_inc      => ( is => 'ro', coerce => \&__to_list, default => sub { [] } );
has scripts        => ( is => 'ro', coerce => \&__to_path_list, default => sub { [] },
                        isa => sub { @{$_[0]} > 0 or croak "scripts argument missing" } );
has extra_exe      => ( is => 'ro', coerce => \&__to_path_list, default => sub { [] } );
has extra_dll      => ( is => 'ro', coerce => \&__to_list, default => sub { [] } );
has work_dir       => ( is => 'lazy', coerce => \&__mkpath, isa => \&__assert_dir );
has perl_exe       => ( is => 'lazy', isa => \&__assert_file,
                        default => sub { path($^X)->realpath } );
has strawberry     => ( is => 'lazy', isa => \&__assert_dir );
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

has cc_exe         => ( is => 'lazy', isa => \&__assert_file );
has ld_exe         => ( is => 'lazy', isa => \&__assert_file );

has strawberry_c_bin => ( is => 'lazy', isa => \&__assert_dir );

has cygwin         => ( is => 'lazy', isa => \&__assert_dir );

has system_drive   => ( is => 'lazy', isa => \&__assert_dir,
                        default => sub { $ENV{SystemDrive} // 'C://' } );

has cygpath        => ( is => 'lazy', isa => \&__assert_file );


sub _build_cygwin {
    my $self = shift;

    require Win32::TieRegistry;
    my %reg;
    Win32::TieRegistry->import(TiedHash => \%reg);

    for my $dir ( $reg{'HKEY_CURRENT_USER\\SOFTWARE\\Cygwin\\setup\\rootdir'},
                  $reg{'HKEY_LOCAL_MACHINE\\SOFTWARE\\Cygwin\\setup\\rootdir'},
                  path($self->system_drive)->child('Cygwin')->stringify ) {
        defined $dir and -d $dir or next;
        return $dir;
    }

    croak "Cygwin directory not found";
}

sub _build_cygpath {
    my $self = shift;
    path($self->cygwin)->child('bin/cygpath.exe')->stringify;
}

sub _build_strawberry {
    my $self = shift;
    my $p = $self->perl_exe->parent->parent->parent->stringify;
    $self->log->trace("Strawberry dir: $p");
    $p
}

sub _build_strawberry_c_bin {
    my $self = shift;
    path($self->strawberry)->child('c/bin')->stringify;
}

sub _config2exe {
    my ($self, $name) = @_;
    my $base = $Config{$name};
    $base =~ s/(?:\.exe)?$/.exe/i;
    my $exe = path($base)->absolute($self->strawberry_c_bin)->stringify;
    $self->log->debugf("exe for command '%s' is '%s'", $name, $exe);
    $exe
}

sub _build_cc_exe { shift->_config2exe('cc') }
sub _build_ld_exe { shift->_config2exe('ld') }

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

sub _die { croak shift->log->fatal(@_ ? join(': ', @_) : $@) }

sub build {
    my $self = shift;

    $self->log->tracef("Win32::Packer object before build: %s", $self);
    #$self->log->tracef("%INC: %s", \%INC);

    $self->_clean_work_dir;
    $self->_do_clean_cache if $self->clean_cache;
    my $pm_deps = $self->_scan_deps;

    my $pe_deps = $self->_scan_dll_deps($pm_deps);

    $self->_populate_app_dir($pm_deps, $pe_deps);
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

sub _module2path {
    my ($self, $mod) = @_;
    $mod =~ s/::/\//g;
    $mod =~ s{(\.\w+)?$}{$1 // '.pm'}ei;
    $mod
}

sub _merge_opts {
    my ($self, $defs, %opts) = @_;
    for my $k (keys %$defs) {
        my $v = $opts{$k};
        if (defined $v) {
            ref $v eq 'ARRAY' and $opts{$k} = [@$v, @{$defs->{$k}}];
        }
        else {
            $opts{$k} = $defs->{$k};
        }
    }

    $self->log->tracef("merged options: %s", \%opts);
    %opts
}

sub _scan_deps {
    my $self = shift;

    $self->log->info("Calculating dependencies...");
    $self->log->tracef("inc: %s, extra modules: %s, scripts: %s", $self->inc, $self->extra_modules, $self->scripts);
    my $rv = do {
        local @Module::ScanDeps::IncludeLibs = @{$self->inc};

        my @pm_files = map {
            Module::ScanDeps::_find_in_inc($self->_module2path($_))
                    or $self->_die("module $_ not found")
                } @{$self->extra_modules};
        $self->log->debugf("pm files: %s", \@pm_files);

        my @script_files = map $_->{path}, @{$self->scripts};
        $self->log->debugf("script files: %s", \@script_files);

        my @more_args;
        push @more_args, cache_file => path($self->cache)->child('module_scan_deps.cache')->stringify
            if defined $self->cache;

        Module::ScanDeps::scan_deps($self->_merge_opts($self->scan_deps_opts,
                                                       recurse => 1,
                                                       warn_missing => 1,
                                                       files => [@script_files, @pm_files],
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
    eval { path($self->work_dir)->remove_tree({safe => 0, keep_root => 1}) };
}

sub _push_pe_dependencies {
    my ($self, $pe_deps, $dt, $subdir) = @_;
    if ($dt->{resolved}) {
        my $module = $dt->{module};
        $module = path($subdir)->child($module)->stringify if defined $subdir;
        my $resolved_module = $dt->{resolved_module};

        unless ($module =~ /\.(?:exe|xs\.dll)$/i or
                path($self->windows)->subsumes($resolved_module)) {
            unless (defined $pe_deps->{$module}) {
                $self->log->tracef("resolving DLL dependency %s to %s (subdir: %s)", $module, $resolved_module, $subdir);
                $pe_deps->{$module} = $resolved_module
            }
        }
    }

    if (defined (my $children = $dt->{children})) {
        $self->_push_pe_dependencies($pe_deps, $_, $subdir) for @$children;
    }
}

sub _scan_xs_dll_deps {
    my ($self, $pe_deps, $pm_deps) = @_;

    $self->log->info("Looking for DLL dependencies for XS modules");

    for my $dep (values %$pm_deps) {
        if ($dep->{key} =~ /\.xs\.dll$/i) {
            $self->log->debug("looking for '$dep->{file}' DLL dependencies");
            my $file = path($dep->{file})->realpath;
            my $dt = pe_dependencies($file);
            $self->_push_pe_dependencies($pe_deps, $dt);
        }
    }
}

sub _scan_exe_dll_deps {
    my ($self, $pe_deps) = @_;

    $self->log->info("Looking for DLL dependencies for EXE and extra DLL files");

    my @exes = ( @{__to_path_list($self->perl_exe)},
                 @{$self->extra_exe},
                 @{$self->extra_dll} );
    for my $exe (@exes) {
        $self->log->debugf("looking for '%s' DLL dependencies", $exe);
        my $path = $exe->{path};
        my $subdir = $exe->{subdir};

        my $parent = path($path)->parent;
        my $dt = do {
            local $ENV{PATH} = "$parent;$ENV{PATH}";
            pe_dependencies($path)
        };
        $self->_push_pe_dependencies($pe_deps, $dt, $subdir);
    }
}

sub _scan_dll_deps {
    my ($self, $pm_deps) = @_;
    my $pe_deps = {};
    $self->_scan_xs_dll_deps($pe_deps, $pm_deps);
    $self->_scan_exe_dll_deps($pe_deps);
    $pe_deps
}

sub _populate_app_dir {
    my ($self, $pm_deps, $pe_deps) = @_;

    my $app_dir = path($self->_app_dir);

    $self->log->info("Populating app dir ($app_dir)...");

    my $lib_dir = $app_dir->child('lib');
    $lib_dir->mkpath;

    for my $dep (values %$pm_deps) {
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

            my $wrapper = $self->_make_wrapper_exe($wrapper_obj, %$script);
            my $wrapper_to = $app_dir->child("$basename.exe");
            $self->log->debugf("copying '%s' to '%s'", $wrapper, $wrapper_to);
            path($wrapper)->copy($wrapper_to);
        }

        my $load_pl = $self->_make_load_pl;
        my $to = $app_dir->child('load.pl');
        $self->log->debugf("copying '%s' to '%s'", $load_pl, $to);
        path($load_pl)->copy($to);
    }

    for my $dll (keys %$pe_deps) {
        my $from = $pe_deps->{$dll};
        my $to = $app_dir->child($dll);
        $self->log->debugf("copying '%s' to '%s'", $from, $to);
        $to->parent->mkpath;
        path($from)->copy($to);
    }

    for my $exe (@{$self->extra_exe}) {
        my $path = $exe->{path};
        my $subdir = $exe->{subdir};
        my $to = $app_dir;
        $to = $app_dir->child($subdir) if defined $subdir;
        $to = $to->child(path($path)->basename);
        $self->log->debugf("copying '%s' to '%s'", $path, $to);
        $to->parent->mkpath;
        path($path)->copy($to);
    }
}

sub _wrapper_dir {
    my $self = shift;
    my $wd = path($self->work_dir)->child('wrapper');
    $wd->mkpath;
    $wd->realpath->stringify
}

sub _make_wrapper_c {
    my $self = shift;
    my $wrapper_dir = $self->_wrapper_dir;
    my $p = path($wrapper_dir)->child("wrapper.c");
    $p->spew($wrapper_c_code);
    $p->realpath->stringify;
}

sub _make_wrapper_obj {
    my ($self, $wrapper_c) = @_;
    my $wrapper_dir = $self->_wrapper_dir;
    my $wrapper_obj = path($wrapper_dir)->child("wrapper.obj")->stringify;
    $self->_run_cmd($self->cc_exe, "-I$Config{archlibexp}/CORE", \$Config{ccflags}, '-c', $wrapper_c, '-o', $wrapper_obj)
        or $self->_die("unable to compile '$wrapper_c'");
    $wrapper_obj
}

sub _make_wrapper_exe {
    my ($self, $wrapper_obj, %opts) = @_;
    my $wrapper_dir = $self->_wrapper_dir;
    my $wrapper_exe = path($wrapper_dir)->child("wrapper.exe")->stringify;
    my @libpth = split /\s+/, $Config{libpth};
    my $libperl = $Config{libperl};
    $libperl =~ s/^lib//i; $libperl =~ s/\.a$//i;
    $self->_run_cmd($self->ld_exe,
                    \$Config{ldflags},
                    $wrapper_obj,
                    map("-L$_", @libpth),
                    "-l$libperl",
                    \$Config{perllibs},
                    -o => $wrapper_exe)
        or $self->_die("unable to link '$wrapper_obj'");
    $wrapper_exe
}

sub _make_load_pl {
    my $self = shift;
    my $wrapper_dir = $self->_wrapper_dir;
    my $p = path($wrapper_dir)->child("load.pl");
    $p->spew($load_pl_code);
    $self->log->debug("load.pl saved to $p");
    $p->realpath->stringify;
}

sub _run_cmd {
    my $self = shift;
    my @cmd = map { ref eq 'SCALAR' ? grep length, split /\s+/, $$_ : $_ } @_;
    $self->log->debugf("running command: %s", \@cmd);
    my ($out, $err, $rc) = capture {
        system @cmd;
    };
    $self->log->debugf("command rc: %s, out: %s, err: %s", $rc, $out, $err);
    wantarray ? (($rc == 0), $out, $err) : ($rc == 0)
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
