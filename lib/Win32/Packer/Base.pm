package Win32::Packer::Base;

use Log::Any;
use Path::Tiny;
use Win32::Packer::Helpers qw(assert_dir assert_file_name mkpath);
use Carp;

use Moo;
use namespace::autoclean;

has log         => ( is => 'ro', default => sub { Log::Any->get_logger } );
has work_dir    => ( is => 'lazy', coerce => \&mkpath, isa => \&assert_dir );
has output_dir  => ( is => 'ro', coerce => \&mkpath, isa => \&assert_dir,
                        default => sub { path('.')->realpath } );
has app_name    => ( is => 'ro', default => sub { 'PerlApp' },
                        isa => \&assert_file_name );
has app_version => ( is => 'ro', isa => \&assert_file_name);

sub _die { croak shift->log->fatal(@_) }

sub _dief { croak shift->log->fatalf(@_) }

1;
