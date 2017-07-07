package Win32::Packer;

our $VERSION = '0.01';

use 5.010;
use Carp;
use Log::Any;
use Path::Tiny;
use Module::ScanDeps;
use Text::CSV_XS ();
use Data::Dumper;
use Config;
use Capture::Tiny qw(capture);
use Win32::Ldd qw(pe_dependencies);

use Win32::Packer::Helpers qw(mkpath to_bool to_array to_array_path to_aoh_path
                              assert_file assert_file_name assert_aoh_path_file
                              assert_dir assert_subsystem assert_aoh_path_dir
                              c_string_quote windows_directory to_loh_path);
use Win32::Packer::WrapperCCode;
use Win32::Packer::LoadPLCode;
our ($wrapper_c_code, $load_pl_code);

use Moo;
use namespace::autoclean;

extends 'Win32::Packer::Base';

has _OS            => ( is => 'ro', # _OS is a hack to enable compiling the module on non-windows OSs
                        isa => sub { $_[0] =~ /^MSWin32/i or croak "Unsupported OS" },
                        default => sub { $^O } );
has extra_module   => ( is => 'ro', coerce => \&to_array, default => sub { [] } );
has extra_inc      => ( is => 'ro', coerce => \&to_array_path, default => sub { [] } );
has scripts        => ( is => 'ro', coerce => \&to_aoh_path, default => sub { [] },
                        isa => sub { @{$_[0]} > 0 or croak "scripts argument missing" } );
has extra_exe      => ( is => 'ro', coerce => \&to_aoh_path, default => sub { [] },
                        isa => \&assert_aoh_path_file );
has extra_dll      => ( is => 'ro', coerce => \&to_aoh_path, default => sub { [] },
                        isa => \&assert_aoh_path_file );
has extra_dir      => ( is => 'ro', coerce => \&to_aoh_path, default => sub { [] },
                        isa => \&assert_aoh_path_dir );
has perl_exe       => ( is => 'lazy', isa => \&assert_file,
                        default => sub { path($^X)->realpath } );
has strawberry     => ( is => 'lazy', isa => \&assert_dir );
has windows        => ( is => 'lazy', isa => \&assert_dir,
                        default => \&windows_directory );
has inc            => ( is => 'lazy', coerce => \&to_array_path );
has scan_deps_opts => ( is => 'ro', default => sub { {} } );
has cache          => ( is => 'ro', coerce => \&mkpath, isa => \&assert_dir) ;
has clean_cache    => ( is => 'ro', coerce => \&to_bool );
has keep_work_dir  => ( is => 'ro', coerce => \&to_bool, default => sub { 0 } );
has cc_exe         => ( is => 'lazy', isa => \&assert_file, coerce => \&path );
has ld_exe         => ( is => 'lazy', isa => \&assert_file, coerce => \&path );
has strawberry_c_bin => ( is => 'lazy', isa => \&assert_dir, coerce => \&path );
has cygpath        => ( is => 'lazy', isa => \&assert_file, coerce => \&path );
has cygwin         => ( is => 'lazy', isa => \&assert_dir, coerce => \&path );
has cygwin_bin     => ( is => 'lazy', isa => \&assert_dir, coerce => \&path );
has system_drive   => ( is => 'lazy', isa => \&assert_dir, coerce => \&path,
                        default => sub { $ENV{SystemDrive} // 'C://' } );
has search_path    => ( is => 'ro', coerce => \&to_array_path, default => sub { [] } );
has icon           => ( is => 'ro', isa => \&assert_file, coerce => \&path );
has windres_exe    => ( is => 'lazy', isa => \&assert_file, coerce => \&path );
has app_subsystem  => ( is => 'ro', default => 'console',
                        isa => \&assert_subsystem );

has _pm_deps       => ( is => 'lazy' );
has _pe_deps       => ( is => 'lazy' );
has _wrapper_dir   => ( is => 'lazy', isa => \&assert_dir );

has _wrapper_c     => ( is => 'lazy', isa => \&assert_file );
has _wrapper_o     => ( is => 'lazy', isa => \&assert_file );

has _load_pl       => ( is => 'lazy', isa => \&assert_file );

has _script_wrappers => ( is => 'lazy' );

around new => sub {
    my $orig = shift;
    my $class = shift;
    my $self = $class->$orig(@_);
    $self->_clean_all;
    $self;
};

sub _clean_all {
    my $self = shift;
    if ($self->clean_cache) {
        if (defined (my $cache = $self->cache)) {
            $self->log->debug("deleting cache");
            $cache->remove_tree({safe => 0, keep_root => 1});
        }
        else {
            $self->warn("clean_cache is set but cache directory is not defined");
        }
    }

    $self->log->debug("cleaning work dir");
    eval { $self->work_dir->remove_tree({safe => 0, keep_root => 1}); 1 }
        or $self->log->warnf("Unable to remove old working dir completely: %s", $@);
}

sub _build_inc {
    my $self = shift;
    [ @{$self->extra_inc}, @INC ]
}

sub _build_cygwin_bin {
    my $self = shift;
    $self->cygwin->child('bin');
}

sub _build_cygwin {
    my $self = shift;

    my $cygpath = $self->{cygpath} // path('cygpath');
    my ($rc, $out, $err) = $self->_run_cmd($cygpath, -w => '/');
    if ($rc) {
        my $cygwin = $out;
        chomp $cygwin;
        return $cygwin if -d $cygwin;
    }

    require Win32::TieRegistry;
    my %reg;
    Win32::TieRegistry->import(TiedHash => \%reg);

    for my $dir ( $reg{'HKEY_CURRENT_USER\\SOFTWARE\\Cygwin\\setup\\rootdir'},
                  $reg{'HKEY_LOCAL_MACHINE\\SOFTWARE\\Cygwin\\setup\\rootdir'},
                  $self->system_drive->child('Cygwin') ) {
        defined $dir and -d $dir or next;
        return $dir;
    }

    croak "Cygwin directory not found";
}

sub _build_cygpath {
    my $self = shift;
    $self->cygwin->child('bin/cygpath.exe');
}

sub _build_strawberry {
    my $self = shift;
    my $p = $self->perl_exe->parent->parent->parent;
    $self->log->trace("Strawberry dir: $p");
    $p
}

sub _build_strawberry_c_bin {
    my $self = shift;
    $self->strawberry->child('c/bin');
}

sub _config2exe {
    my ($self, $name) = @_;
    my $base = $Config{$name};
    $base =~ s/(?:\.exe)?$/.exe/i;
    my $exe = path($base)->absolute($self->strawberry_c_bin);
    $self->log->debugf("exe for command '%s' is '%s'", $name, $exe);
    $exe
}

sub _build_cc_exe { shift->_config2exe('cc') }
sub _build_ld_exe { shift->_config2exe('ld') }

sub _build_windres_exe {
    my $self = shift;
    my $exe = $self->strawberry_c_bin->child('windres.exe');
    $self->log->debugf("exe for command 'windres' is '%s'", $exe);
    $exe;
}

sub _build_work_dir {
    my $self = shift;
    my $keep = $self->keep_work_dir;
    my $p = Path::Tiny->tempdir("Win32-Packer-XXXXXX", CLEANUP => !$keep )->realpath;
    $self->log->debug("Work dir: $p");
    $self->log->info("Would keep work dir '$p'") if $keep;
    $p;
}

sub _new_installer_maker {
    my $self = shift;
    my %opts = ((@_ & 1) ? (type => @_) : @_);

    my $type = delete $opts{type} // 'zip';
    $type =~ /^(?:msi|zip|dir|dirbat)$/ or $self->_die("Wrong installer type '$type'");
    my $backend = __PACKAGE__ . "::InstallerMaker::$type";
    eval "require $backend; 1" or $self->_die("Unable to load backend '$backend': $@");
    $self->log->debug("Package $backend loaded");

    for (qw(log app_name app_version work_dir output_dir)) {
        if (defined (my $v = $self->$_)) {
            $opts{$_} //= $v
        }
    }

    $backend->new(%opts);
}

sub installer_maker {
    my $self = shift;
    my $installer = $self->_new_installer_maker(@_);

    $self->_install_scripts($installer);
    $self->_install_load_pl($installer);
    $self->_install_wrappers($installer);
    $self->_install_extra_exe($installer);
    $self->_install_extra_dir($installer);
    $self->_install_pm_deps($installer);
    $self->_install_pe_deps($installer);

    $installer;
}

sub make_installer {
    my $self = shift;
    my $installer = $self->installer_maker(@_);
    $installer->run;
}

sub _install_scripts {
    my ($self, $installer) = @_;

    $self->log->info("Adding scripts");
    my $lib = path('lib');
    for (@{$self->scripts}) {
        my $to = $lib->child($_->{basename}.'.pl');
        $installer->add_file($_->{path}, $to);
    }
}

sub _install_load_pl {
    my ($self, $installer) = @_;
    $self->log->info("Adding load.pl");
    $installer->add_file($self->_load_pl);
}

sub _install_wrappers {
    my ($self, $installer) = @_;
    $self->log->info("Adding wrappers");
    for (@{$self->_script_wrappers}) {
        $installer->add_file($_);
    }
}

sub _install_extra_exe {
    my ($self, $installer) = @_;
    $self->log->info("Adding extra exe");
    for (@{$self->extra_exe}) {
        my $path = $_->{path};
        my $to = $path->basename;
        if (defined (my $subdir = $_->{subdir})) {
            $to = $subdir->child($to)
        }
        $installer->add_file($path, $to);
    }
}

sub _install_extra_dir {
    my ($self, $installer) = @_;
    $self->log->info("Adding extra dir");
    for (@{$self->extra_dir}) {
        my $path = $_->{path};
        my $to = $_->{subdir} // path($path->realpath->basename);
        $installer->add_tree($path, $to);
    }
}

sub _install_pm_deps {
    my ($self, $installer) = @_;
    $self->log->info("Adding pm deps");
    my $lib = path('lib');
    for (values %{$self->_pm_deps}) {
        my $path = $_->{file};
        my $to = $lib->child($_->{key});
        $installer->add_file($path, $to);
    }
}

sub _install_pe_deps {
    my ($self, $installer) = @_;
    $self->log->info("Adding pe deps");
    my $pe_deps = $self->_pe_deps;
    for my $pe (keys %$pe_deps) {
        my $path = path($pe_deps->{$pe});
        $installer->add_file($path, $pe);
    }
}

sub _module2pm {
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

sub _build__pm_deps {
    my $self = shift;

    $self->log->info("Calculating dependencies...");
    $self->log->tracef("inc: %s, extra modules: %s, scripts: %s", $self->inc, $self->extra_module, $self->scripts);
    my $rv = do {
        local @Module::ScanDeps::IncludeLibs = @{$self->inc};

        my @pm_files = map {
            Module::ScanDeps::_find_in_inc($self->_module2pm($_))
                    or $self->_die("module $_ not found")
                } @{$self->extra_module};
        $self->log->debugf("pm files: %s", \@pm_files);

        my @script_files = map $_->{path}->stringify, @{$self->scripts};
        $self->log->debugf("script files: %s", \@script_files);

        my @more_args;
        if (defined (my $cache = $self->cache)) {
            push @more_args, cache_file => $cache->child('module_scan_deps.cache')->stringify
        }

        Module::ScanDeps::scan_deps($self->_merge_opts($self->scan_deps_opts,
                                                       recurse => 1,
                                                       warn_missing => 1,
                                                       files => [@script_files, @pm_files],
                                                       @more_args));
    };
    $self->log->debugf("pm dependencies: %s", $rv);
    $rv
}

sub _push_pe_dependencies {
    my ($self, $pe_deps, $dt, $subdir) = @_;
    if ($dt->{resolved}) {
        my $module = $dt->{module};
        $module = $subdir->child($module)->stringify if defined $subdir;
        my $resolved_module = path($dt->{resolved_module});

        unless ($module =~ /\.(?:exe|xs\.dll)$/i or
                $self->windows->subsumes($resolved_module)) {
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

my %xs_dll_search_path_method = map { $_ => "_${_}_xs_dll_search_path" } map lc, qw(Wx);

sub _scan_xs_dll_deps {
    my ($self, $pe_deps) = @_;
    $self->log->info("Looking for DLL dependencies for XS modules");

    for my $dep (values %{$self->_pm_deps}) {
        if ($dep->{key} =~ m{\.xs\.dll$}i) {
            $self->log->debugf("looking for '%s' ('%s') DLL dependencies", $dep->{used_by}[0], $dep->{key});
            my @search_path = @{$self->search_path};
            if (my ($name) = $dep->{used_by}[0] =~ m{(.*)\.pm$}i) {
                if (defined (my $method = $xs_dll_search_path_method{lc $name})) {
                    my @special = $self->$method;
                    $self->log->debugf("using special search path: %s", \@special);
                    push @search_path, @special;
                }
            }
            my $file = path($dep->{file})->realpath;
            my $dt = do {
                local $ENV{PATH} = join(';', @search_path, $ENV{PATH}) if @search_path;
                pe_dependencies($file)
            };
            $self->_push_pe_dependencies($pe_deps, $dt);
        }
    }
}

sub _scan_exe_dll_deps {
    my ($self, $pe_deps) = @_;

    $self->log->info("Looking for DLL dependencies for EXE and extra DLL files");

    my @exes = ( to_loh_path($self->perl_exe),
                 @{$self->extra_exe},
                 @{$self->extra_dll} );
    for my $exe (@exes) {
        $self->log->debugf("looking for '%s' DLL dependencies", $exe);
        my $path = $exe->{path};
        my $subdir = $exe->{subdir};

        my @search_path = ($path->parent, @{$exe->{search_path}});
        push @search_path, $self->cygwin_bin if $exe->{cygwin};
        push @search_path, @{$self->search_path};

        my $dt = do {
            local $ENV{PATH} = join(';', @search_path, $ENV{PATH});
            # $self->log->tracef("PATH: %s", $ENV{PATH});
            pe_dependencies($path)
        };
        $self->_push_pe_dependencies($pe_deps, $dt, $subdir);
    }
}

sub _build__pe_deps {
    my $self = shift;
    my $pe_deps = {};
    $self->_scan_xs_dll_deps($pe_deps);
    $self->_scan_exe_dll_deps($pe_deps);
    $pe_deps
}

sub _build__script_wrappers {
    my $self = shift;
    [ map $self->_make_wrapper_exe($_), @{$self->{scripts}} ]
}

sub _change_exe_subsystem {
    my ($self, $exe, $subsystem) = @_;

    my $path = $exe->{path};
    $self->log->trace("Changing '$path' subsystem to $subsystem");

    require Win32::Exe;
    my $e = Win32::Exe->new("$path") // $self->_die("Unable to inspect '$path': $^E");

    if ($subsystem eq $e->get_subsystem) {
        $self->log->debug("App '$path' has already subsystem $subsystem");
        return $path
    }

    if ($subsystem eq 'console') {
        $e->set_subsystem_console
    }
    elsif ($subsystem eq 'windows') {
        $e->set_subsystem_windows
    }
    else {
        $self->_die("Unsupoprted Windows subsystem $subsystem");
    }

    my $tmpdir = $self->work_dir->child('modexe');
    if (defined (my $subdir = $exe->{subdir})) {
        $tmpdir = $tmpdir->child($subdir)
    }
    $tmpdir->mkpath;

    my $mod = $tmpdir->child($path->basename);
    $e->write("$mod");
    $self->log->debug("App subsystem for '$path' changed to $subsystem ($mod)");
    $mod;
}

sub _dir_copy {
    my ($self, $from, $to) = @_;
    $self->log->debugf("copying directory '%s' to '%s'", $from, $to);

    $to->mkpath;
    for my $c ($from->children) {
        if ($c->is_dir) {
            $self->_dir_copy($c, $to->child($c->basename));
        }
        elsif ($c->is_file) {
            $self->log->debugf("copying '%s' to '%s'", $c, $to);
            $c->copy($to);
        }
        else {
            $self->log->warnf("unable to copy file system object '%s'", $from);
        }
    }
}

sub _build__wrapper_dir { mkpath(shift->work_dir->child('wrapper'))->realpath }

sub _build__wrapper_c {
    my $p = shift->_wrapper_dir->child("wrapper.c");
    $p->spew($wrapper_c_code);
    $p
}

sub _build__wrapper_o {
    my ($self, $wrapper_c) = @_;
    my $wrapper_o = $self->_wrapper_dir->child("wrapper.obj");
    $self->_run_cmd($self->cc_exe, "-I$Config{archlibexp}/CORE", \$Config{ccflags}, '-c', $self->_wrapper_c, '-o', $wrapper_o)
        or $self->_die("unable to compile '$wrapper_c'");
    $wrapper_o
}

sub _make_wrapper_rco {
    my ($self, $script) = @_;
    if (defined (my $icon = $script->{icon} // $self->icon)) {
        $icon->is_file or $self->_die("Icon not found at '$icon'");
        my $basename = $script->{basename};
        my $wrapper_rc = $self->_wrapper_dir->child("$basename.rc");
        my $wrapper_rco = $self->_wrapper_dir->child("$basename.rco");
        $wrapper_rc->spew('2 ICON '.c_string_quote($icon->realpath)."\n");
        $self->_run_cmd($self->windres_exe,
                        -J => 'rc',  -i => "$wrapper_rc",
                        -O => 'coff', -o => "$wrapper_rco")
            or $self->_die("unable to compile resource file '$wrapper_rc'");
        return $wrapper_rco;
    }
    return ()
}

sub _make_wrapper_exe {
    my ($self, $script) = @_;
    my $basename = $script->{basename};
    my $wrapper_exe = $self->_wrapper_dir->child("$basename.exe");

    my @obj = ($self->_wrapper_o, $self->_make_wrapper_rco($script));

    my $app_subsystem = $script->{app_subsystem} // $self->app_subsystem;
    $app_subsystem =~ /^(?:console|windows)$/ or $self->_die("Bad app type $app_subsystem");

    my @libpth = split /\s+/, $Config{libpth};
    my $libperl = $Config{libperl};
    $libperl =~ s/^lib//i; $libperl =~ s/\.a$//i;
    $self->_run_cmd($self->ld_exe,
                    \$Config{ldflags},
                    "-m$app_subsystem",
                    @obj,
                    map("-L$_", @libpth),
                    "-l$libperl",
                    \$Config{perllibs},
                    -o => $wrapper_exe)
        or $self->_die("unable to link '$wrapper_exe'");
    $wrapper_exe
}

sub _build__load_pl {
    my $self = shift;
    my $p = $self->_wrapper_dir->child("load.pl");
    $p->spew($load_pl_code);
    $self->log->debug("load.pl saved to $p");
    $p
}

sub _run_cmd {
    my $self = shift;
    my @cmd = map { ref eq 'SCALAR' ? grep length, split /\s+/, $$_ : $_ } @_;
    $self->log->debugf("running command: %s", \@cmd);
    my ($out, $err, $rc) = capture {
        system @cmd;
    };
    $self->log->debugf("command rc: %s, out: %s, err: %s", $rc, \$out, \$err);
    wantarray ? (($rc == 0), $out, $err) : ($rc == 0)
}

# special search paths
sub _wx_xs_dll_search_path {
    my $self = shift;

    my ($wxcfg) = eval {         # get_configurations doesn't work right in scalar context!!!
        require Alien::wxWidgets;
        Alien::wxWidgets->get_configurations();
    };

    unless (defined $wxcfg) {
        $self->log->warnf('Unable to retrieve Alien::wxWidgets configuration: %s', $@);
        return;
    }

    my $wxkey = $wxcfg->{key};
    unless (defined $wxkey) {
        $self->log->warnf('"key" entry missing from Alien::wxWidgets configuration: %s', $wxcfg);
        return;
    }
    my $perl_path = $self->strawberry->child('perl');
    my @search_path;
    for (qw(site/lib vendor/lib lib)) {
        my $wxlib = $perl_path->child($_)->child('Alien/wxWidgets')->child($wxkey)->child('lib');
        push @search_path, $wxlib->realpath if -d $wxlib;
    }
    $self->log->warnf("Wx search path is empty, DLLs will be missing") unless @search_path;
    @search_path;
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
