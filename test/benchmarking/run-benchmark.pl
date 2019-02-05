#!/usr/bin/perl -w
#
# This script is glue for wiring together the different providers (AWS, GCP, GKE)
# to a benchmarking script.
#
# Calling this script creates a cluster using the provider, runs the benchmark,
# and deletes the cluster upon completion.
###################################################################################
use strict;
use Data::Dumper qw(Dumper);

my $provider = shift(@ARGV);
my $benchmark = shift(@ARGV);

sub usage {
    die "Usage: ./run-benchmark.pl <provider> <benchmark>\n";
}

if (!$provider) {
    usage();
} elsif (!$benchmark) {
    usage();
}

# Generate some random tag we can use for logging.
my $tag = `head -c 3 /dev/urandom | md5 | head -c 5`;
my $date = `date '+%Y-%m-%dT%H:%M:%S'`;
chomp($date);
# Given provider "provider/aws" we want providerShort=aws
my @p1 = split(/\//, $provider);
my $providerShort = $p1[scalar(@p1) - 1];
my @p2 = split(/\//, $benchmark);
my $benchmarkShort = $p2[scalar(@p2) - 1];
my $cwd = `pwd`;
chomp($cwd);
my $logfile = "$cwd/runlog-benchmark-$providerShort-$benchmarkShort-$tag-$date.log";

sub createStack {
    my $script = shift(@_);
    print "Creating stack...\n";

    my $cmd = "cd \"$provider\" && /bin/bash create-cluster.sh " . '2>&1 | tee -a "' . $logfile . '"';
    print "Running create stack command $cmd";
    my $output = `$cmd`;
    print $output;
    
    $output =~ m/^NEO4J_IP=([^\s]+)$/m;
    my $ip = $1;
    $output =~ m/^STACK_NAME=([^\s]+)$/m;
    my $stack = $1;
    $output =~ m/^NEO4J_PASSWORD=([^\s]+)$/m;
    my $password = $1;
    $output =~ m/^RUN_ID=([^\s]+)$/m;
    my $runID = $1;

    if (!$ip || !$stack || !$password) {
        print STDERR $output;
        die "Create cluster script failed to return ip, name, or password: $ip, $stack, $password\n";
    }

    return (
        "ip" => $ip,
        "stack" => $stack,
        "password" => $password,
        "run_id" => $runID
    );
}

sub deleteStack {
    my $script = shift(@_);
    my $hashref = shift(@_);

    print "Deleting stack...\n";

    my $cmd = "/bin/bash " . $script . " " . $hashref->{"stack"} . ' 2>&1 | tee -a "' . $logfile . '"';
    print "Executing $cmd\n";
    print `$cmd`;
}

sub runBenchmark {
    my $dir = shift(@_);
    my $script = shift(@_);
    my $hashref = shift(@_);

    my $ip = $hashref->{"ip"};
    my $password = $hashref->{"password"};

    if (!$ip || !$password) {
        print STDERR "Skipping benchmark run: missing IP or password from stack reference\n";
        return undef;
    }

    my $cmd = "cd \"$benchmark\" && /bin/bash ./benchmark.sh \"bolt+routing://$ip\" \"$password\" " . '2>&1 | tee -a "' . $logfile . '"';
    print "Running benchmark ... $cmd\n";
    my $output = `$cmd`;

    print "OVERALL BENCHMARK OUTPUT:\n";
    print $output;

    my %benchmarkOutputs = ();
    my @lines = split(/\n/, $output);
    for my $line (@lines) {
        chomp($line);
        if($line =~ m/^BENCHMARK_(.*?)=(.*)$/) {
            $benchmarkOutputs{$1} = $2;
        }
    }

    return %benchmarkOutputs;
}

sub extractResults {
    my $log = shift(@_);
    local $/ = undef;

    my $data = `cat "$log" | grep "^BENCHMARK_"`;
    my @lines = split(/\n/, $data);

    my %benchmarkOutputs = ();

    for my $line (@lines) {
        chomp($line);
        $line =~ m/^BENCHMARK_(.*?)=(.*)?$/;
        my $key = $1;
        my $value = $2;
        $benchmarkOutputs{$key} = $value;
    }

    return %benchmarkOutputs;
}

sub main {
    my $createCluster = "$provider/create-cluster.sh";
    my $deleteCluster = "$provider/delete-cluster.sh";
    my $benchmarkScript = "$benchmark/benchmark.sh";

    if (!(-f $createCluster)) {
        die "Invalid provider $provider: this provider does not know how to create a cluster\n";
    } elsif (!(-f $deleteCluster)) {
        die "Invalid provider $provider: this provider does not know how to delete a cluster\n";
    } elsif (!(-f $benchmarkScript)) {
        die "Invalid benchmark $benchmark: this benchmark does not have a run script\n";
    }

    my %hash = createStack($createCluster);
    print Dumper(\%hash);

    my %outputs = runBenchmark($benchmark, $benchmarkScript, \%hash);
    print Dumper(\%outputs);

    print "Results extraction phase.\n";
    my %results = extractResults($logfile);
    print Dumper(\%results);

    deleteStack($deleteCluster, \%hash);
    print "Done";
}

main();