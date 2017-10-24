use 5.024001;
use ExtUtils::MakeMaker;
# See lib/ExtUtils/MakeMaker.pm for details of how to influence
# the contents of the Makefile that is written.
WriteMakefile( NAME              => 'Win32::Packer',
               VERSION_FROM      => 'lib/Win32/Packer.pm', # finds $VERSION, requires EU::MM from perl >= 5.5
               PREREQ_PM         => { "Log::Any" => 0,
                                      "Win32::Ldd" => 0 },
               ABSTRACT_FROM     => 'lib/Win32/Packer.pm', # retrieve abstract from module
               AUTHOR            => 'Salvador Fandiño <salva@>',
               LICENSE           => 'gpl3',
             );
