#!/usr/bin/perl

use strict;
# use warnings;
use Test::More;
use DBI;
use Data::Dumper;

# $Class::Tables::SQL_DEBUG++;

############################
## get DB connection info ##
############################

use lib 'testconfig';
my $Config;
eval q[
    use Class::Tables::TestConfig;
    $Config = Class::Tables::TestConfig->Config;
];

######################
## import test data ##
######################

my $dbh = DBI->connect( @$Config{qw/dsn user password/} );

if (not $dbh) {
    plan skip_all => "Couldn't connect to the database for testing.\n"
                   . "Run `perl Makefile.PL -s` to configure the test DB.";
} elsif ($dbh->{Driver}->{Name} ne "mysql") {
    $dbh->disconnect;
    plan skip_all => "A MySQL database is required for Class::Tables";
} else {
    plan tests => 44;
}

my $q = $dbh->prepare("show tables");
$q->execute;
while ( my ($table) = $q->fetchrow_array ) {
    $dbh->do("drop table $table");
}
$q->finish;

$dbh->do($_) for (split /\s*;\s*/, <<'END_OF_SQL');
    create table departments (
        id            int not null primary key auto_increment,
        name          varchar(50) not null
    );
    create table employees (
        employee_id   int not null primary key auto_increment,
        name          varchar(50) not null unique,
        department_id int not null,
        photo         longblob
    );
    create table purchases (
        id            int not null primary key auto_increment,
        product_id    int not null,
        employee_id   int not null,
        quantity      int not null,
        date          date
    );
    create table products (
        id            int not null primary key auto_increment,
        name          varchar(50) not null,
        weight        int not null,
        price         decimal
    );
    insert into departments values (1,'Hobbiton Division');
    insert into departments values (2,'Bree Division');
    insert into departments values (3,'Buckland Division');
    insert into departments values (4,'Michel Delving Division');
    insert into employees   values (1,'Frodo Baggins',3,'');
    insert into employees   values (2,'Bilbo Baggins',3,'');
    insert into employees   values (3,'Samwise Gamgee',3,'');
    insert into employees   values (4,'Perigrin Took',2,'');
    insert into employees   values (5,'Fredegar Bolger',2,'');
    insert into employees   values (6,'Meriadoc Brandybuck',2,'');
    insert into employees   values (7,'Lotho Sackville-Baggins',4,'');
    insert into employees   values (8,'Ted Sandyman',4,'');
    insert into employees   values (9,'Will Whitfoot',4,'');
    insert into employees   values (10,'Bandobras Took',1,'');
    insert into employees   values (11,'Folco Boffin',1,'');
    insert into products    values (1,'Southfarthing Pipeweed',10,200);
    insert into products    values (2,'Prancing Pony Ale',150,300);
    insert into products    values (3,'Farmer Cotton Mushrooms',200,150);
    insert into products    values (4,'Green Dragon Ale',150,350);
    insert into purchases   values (1,2,6,6,'2002-12-10');
    insert into purchases   values (2,4,3,1,'2002-12-10');
    insert into purchases   values (3,1,2,20,'2002-12-09');
    insert into purchases   values (4,3,4,8,'2002-12-11');
    insert into purchases   values (5,1,1,1,'2002-12-13');
    insert into purchases   values (6,3,1,2,'2002-12-15');
    insert into purchases   values (7,3,3,3,'2002-12-12');
    insert into purchases   values (8,3,3,15,'2002-12-08');
    insert into purchases   values (9,2,6,11,'2002-12-08');
    insert into purchases   values (10,3,2,8,'2002-12-14')

END_OF_SQL

################
## real tests ##
################

my $timer = times;

use_ok('Class::Tables');
Class::Tables->dbh($dbh);

#print Dumper \%Class::Tables::CLASS;

for (qw/Departments Employees Products Purchases/) {
    no strict 'refs';
    is_deeply(
        \@{"$_\::ISA"},
        ['Class::Tables'],
        "$_ class created" );
}

## fetch class method

isa_ok(
    Employees->fetch(1),
    "Employees",
    "fetch result" );

is( Employees->fetch(234332),
    undef,
    "fetch returns undef on failure" );

## search class method

is( Employees->search(id => 1)->id,
    Employees->fetch(1)->id,
    "search on id is equivalent to fetch" );

my @emps = Employees->search;

ok( scalar @emps,
    "search with no args" );

is_deeply(
    [ grep { ! $_->isa("Employees") } @emps ],
    [],
    "search returns Employees objects" );

is( join(":" => sort { $emps[$a]->name cmp $emps[$b]->name } 0 .. $#emps),
    join(":" => 0 .. $#emps),
    "search results sorted" );

is( scalar Employees->search(name => "asdfasdfasdf"),
    undef,
    "search returns undef on failure" );

is_deeply(
    [ Employees->search(name => "asdfasdfasdf") ],
    [],
    "search returns empty list on failure" );

isa_ok(
    scalar Employees->search( name => "Frodo Baggins" ),
    "Employees",
    "search result" );

is( Employees->search( name => "Frodo Baggins" )->name,
    "Frodo Baggins",
    "search result consistent" );

ok( scalar Employees->search(department => Departments->fetch(3)),
    "search with object constraint on foreign key" );

## basic object accessors

my $h = Employees->fetch(1);

is( "$h",
    $h->name,
    "objects stringify to name column" );

isa_ok(
    $h->department,
    "Departments",
    "foreign key accessor" );

ok( ! ref $h->name,
    "normal accessor returns unblessed scalar" );

ok( scalar(() = $h->purchases) > 1,
    "indirect foreign key returns list" );

ok( do { eval { $h->age }; $@ },
    "die on bad accessor name" );

is( do { eval { $h->id(5) }; $h->id },
    1,
    "id accessor read-only" );

my $count = $Class::Tables::SQL_QUERIES;
(undef) = $h->photo;
ok( $count < $Class::Tables::SQL_QUERIES,
    "blob accessors lazy-loaded" );

my @p1 = $h->purchases;
my @p2 = $h->purchases(product => 3);
ok( @p1 > @p2,
    "additional search constraints in indirect key accessors" );

## basic mutators

my $dept = Departments->fetch(1);
$h->department($dept);

is( $h->department->id,
    $dept->id,
    "change foreign key correctly using object" );

$h->name("Frodo Nine-Fingers");

is( $h->name,
    "Frodo Nine-Fingers",
    "change normal column correctly" );

$h->department( $dept->id );

isa_ok(
    $h->department,
    "Departments",
    "change foreign key with id only" );

ok( scalar Employees->search(name => "Frodo Nine-Fingers", department => $dept),
    "changes visible in database" );

$h->department(0);
is( $h->department,
    undef,
    "dangling foreign key accessors return undef" );

$h->department($dept);

## this depends on MySQL version, sadly..
# $h->department("asdfasdf");
# ok( ref $h->department,                   "gracefully handle bad changes" );
# $h->department( $dept );

## concurrency

my $p1 = Purchases->fetch(1);
my $p2 = Purchases->fetch(1);
$p1->quantity(1);
$p2->quantity(99999);

is( $p2->quantity,
    $p1->quantity,
    "updates concurrently visible" );

## creating objects

is( Employees->new(name => "Samwise Gamgee"),
    undef,
    "new returns undef on failure" );

my $new = Employees->new(name => "Grima Wormtongue", department => $dept);

isa_ok(
    $new,
    "Employees",
    "new return value" );

is( $new->name,
    "Grima Wormtongue",
    "new creates object with initial info" );

is( $new->department->id,
    $dept->id,
    "new creates object using object for foreign key" );

## dump method

my $dump = $h->dump;

isa_ok(
    $dump,
    "HASH",
    "dump output" );

is( $dump->{'department.name'},
    $h->department->name,
    "dump output foreign keys inflated" );

isa_ok(
    $dump->{purchases},
    "ARRAY",
    "dump output indirect foreign key" );

is( $dump->{purchases}[0]{'product.name'},
    ($h->purchases)[0]->product->name,
    "dump output indirect foreign keys inflated" );

## deleting objects

my $id = $new->id;
$new->delete;

is( Employees->fetch($id),
    undef,
    "delete from database" );

@p1 = Purchases->search;
my $num = grep { $_->employee->id == 3 } @p1;

Employees->fetch(3)->delete;
is( scalar Purchases->search(employee => 3),
    undef,
    "cascading deletes turned on" );

@p2 = Purchases->search;
is( scalar @p1 - $num,
    scalar @p2,
    "cascading deletes leave the rest" );

{
    local $Class::Tables::CASCADE = 0;

    Employees->fetch(2)->delete;
    isnt(
        scalar Purchases->search(employee => 2),
        undef,
        "cascading deletes turned off" );
}

$_->delete for Employees->search;

is( scalar Employees->search,
    undef,
    "delete all in a table" );

# print Class::Tables->as_class_dbi("App");

$timer = times - $timer;
ok( 1,
    "summary: $Class::Tables::SQL_QUERIES queries, ${timer}s" );

## done!

END {
    if ($dbh) {
        $dbh->do($_) for (split /\s*;\s*/, <<'        END_OF_SQL');
            drop table if exists departments;
            drop table if exists employees;
            drop table if exists products;
            drop table if exists purchases
        END_OF_SQL

        $dbh->disconnect;
    }
}
