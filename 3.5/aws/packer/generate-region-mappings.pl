#!/usr/bin/perl
#
# Deregister a batch of AWS AMIs.   **Use with care!**
# In debugging, quite a few images may be created that ultimately aren't
# needed.  This script is just a utility to help clean up multi-zone litter
# which would otherwise be left behind.
# 
# Works nicely with the output of packer.
#
# Usage:
#echo "
# ap-northeast-1: ami-017a5e1e18a5e2cd3
# ap-northeast-2: ami-01b2b715a51a214fa
# ap-south-1: ami-013d4914738173cb6
# ap-southeast-1: ami-05d6fed64a93c06fd
# ap-southeast-2: ami-0a6878d4781d23a2f
# eu-central-1: ami-04c319e1e1676cec3
# eu-west-1: ami-0343904396e1868bb
# eu-west-3: ami-019b95a295df288c2
# sa-east-1: ami-00a912168a7ac3a25
# us-east-1: ami-0ada00a1aab49af6b
# us-east-2: ami-0b2b19e489fc25c21
# us-west-1: ami-06bae31a8e4d51b75
# us-west-2: ami-0af47029f185c3105
# " | ./generate-region-mappings.pl

print "{\n";
my $first = true;
while (my $line = <STDIN>) {
   chomp($line);
   if ($line =~ m/^([^\s]+): (ami-[^\s]+)$/) {
      if ($first) {
          $first = undef;
      } else {
          print ",\n";
      }

      my $region = $1;
      my $ami = $2;
      print "   \"$region\": {\n";
      print "         \"64\": \"$ami\"\n";
      print "   }";
   }
}
print "\n}\n";
