#!/use/bin/perl

use strict;
use warnings;
use Getopt::Long;
use Win32::Packer;
use Log::Any::Adapter;

my $app_name = 'PerlApp';;
my $keep_work_dir = 0;
my @extra_inc;
my @extra_modules;
my $fake_os = $^O;
my $log_file;
my $log_level = 'info';
my $work_dir;

GetOptions('app-name|a=s' => \$app_name,
           'work-dir|w=s' => \$work_dir,
           'keep-work-dir|k' => \$keep_work_dir,
           'extra-inc|I=s' => \@extra_inc,
           'extra-modules|M=s' => \@extra_modules,
           'fake-os|O=s' => \$fake_os,
           'log-file|l=s' => \$log_file,
           'log-level|L=s' => \$log_level,
          );

Log::Any::Adapter->set((defined $log_file ? ('File', $log_file) : 'Stderr'),
                       log_level => $log_level);

my $p = Win32::Packer->new(app_name => $app_name,
                           work_dir => $work_dir,
                           keep_work_dir => $keep_work_dir,
                           scripts => [ @ARGV ],
                           extra_inc => \@extra_inc,
                           extra_modules => \@extra_modules,
                           _OS => $fake_os );

$p->build;
