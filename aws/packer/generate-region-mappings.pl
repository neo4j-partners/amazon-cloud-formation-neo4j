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
# echo "
# ap-northeast-1: ami-5100fc2f
# ap-southeast-1: ami-beefd2cf
# eu-central-1: ami-462e05ae
# eu-west-1: ami-259da35d
# sa-east-1: ami-ef39678d
# us-east-1: ami-5b7d1a2d
# us-east-2: ami-c2d2eead
# us-west-1: ami-b3acb4dd
# us-west-2: ami-c47b02bd
# " | ./deregister-ami-group.pl

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
