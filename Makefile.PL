use strict;
use ExtUtils::MakeMaker;
use DBI;
use Data::Dumper;

unless (grep /mysql/, DBI->available_drivers) {
    die "Class::Tables requires DBD::mysql at this time";
}

use lib 'testconfig';
my $Config;
eval q[
    use Class::Tables::TestConfig;
    $Config = Class::Tables::TestConfig->Config;
];

if (defined $Config->{dsn} and not $ARGV[0] =~ /^-s(etup)?$/) {

    print qq[
        For the test suite, we use the database and user info specified
        during the previous run. If you want to change the values, run
        perl Makefile.PL -s.
        
        Current values:
            dsn      = $Config->{dsn}
            user     = $Config->{user}
            password = $Config->{password}
    \n];

} else {

    print qq[
        I need some the database info to run the test suite:
    \n];

    $Config->{dsn} = 'dbi:mysql:test'
        unless defined $Config->{dsn};
    
    $Config->{$_} = prompt "The $_ for tests:", $Config->{$_}
        for qw/dsn user password/;
}


mkdir $_, 0700
    for qw[testconfig testconfig/Class testconfig/Class/Tables];

open OUT, '>testconfig/Class/Tables/TestConfig.pm'
    or die "Error writing the TestConfig\n";

print OUT
    "package Class::Tables::TestConfig;\n",
    "sub Config {\n",
        Dumper($Config),
    "};\n1;\n";

close OUT;

WriteMakefile(
    NAME          => 'Class::Tables',
    VERSION_FROM  => 'lib/Class/Tables.pm',
    PREREQ_PM     => { DBI => 0,
                       Carp => 0,
                       overload => 0,
                       "Lingua::EN::Inflect" => 0,
                       "DBD::mysql" => 0 },
    clean         => { FILES => "testConfig" },
    ABSTRACT_FROM => 'lib/Class/Tables.pm',
    AUTHOR        => 'Mike Rosulek <mike@mikero.com>',
);
