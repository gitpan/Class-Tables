use 5.008;
use ExtUtils::MakeMaker;
# See lib/ExtUtils/MakeMaker.pm for details of how to influence
# the contents of the Makefile that is written.
WriteMakefile(
                    NAME          => 'Class::Tables',
                    VERSION_FROM  => 'lib/Class/Tables.pm',
                    PREREQ_PM     => { DBI => 0, Carp => 0, overload => 0,
                                       Lingua::EN::Inflect => 0 },
    ($] >= 5.005 ? (ABSTRACT_FROM => 'lib/Class/Tables.pm',
                    AUTHOR        => 'Mike Rosulek <mike@mikero.com>')
                 : ()),
);
